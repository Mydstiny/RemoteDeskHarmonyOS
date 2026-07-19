/**
 * HostSyncService.ets — 远程主机配置管理 (CloudStore RDB + 端云自动同步)
 */
import { ConnectionHealth, RemoteHost } from '../model/RemoteHost';
import { RustDeskRelayConfig } from '../model/RustDeskRelayConfig';
import { RdpCredential } from '../model/RdpCredential';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { CloudStore } from './CloudStore';
import { normalizeGroupId } from './HostWorkspacePolicy';
import { RustDeskProPeer } from '../model/RustDeskProModels';
import { reconcileRustDeskProHosts, RustDeskProReconcileResult } from './RustDeskProSyncPolicy';
import {
  normalizeRustDeskPort,
  RUSTDESK_PEER_TCP_PORT,
  shouldBindLegacyRustDeskHostToRelay
} from './RustDeskHostConfigPolicy';
import { shouldKeepDeletedRelay, shouldKeepLocalRelayConfig } from './RustDeskRelaySyncPolicy';
import {
  serializedSnapshotChanged,
  shouldKeepDeletedHost,
  shouldKeepLocalHostConfig
} from './HostSyncMergePolicy';

export class HostSyncService {
  private static instance: HostSyncService;
  private hosts: Map<string, RemoteHost> = new Map();
  private relays: Map<string, RustDeskRelayConfig> = new Map();
  private rdpCredentials: Map<string, RdpCredential> = new Map();
  private cloud: CloudStore = CloudStore.getInstance();
  private ready: boolean = false;
  private initPromise: Promise<void> | null = null;
  private dataChangeListeners: Array<() => void> = [];
  private localHostObservationAt: Map<string, number> = new Map();
  private localHostConfigObservationAt: Map<string, number> = new Map();
  private deletedHostAt: Map<string, number> = new Map();
  private healthCloudWriteAt: Map<string, number> = new Map();
  private localRdpCredentialObservationAt: Map<string, number> = new Map();
  private deletedRdpCredentialAt: Map<string, number> = new Map();
  private localRelayObservationAt: Map<string, number> = new Map();
  private deletedRelayAt: Map<string, number> = new Map();
  private lastCloudSnapshotLoadedAt: number = 0;

  static getInstance(): HostSyncService {
    if (!HostSyncService.instance) {
      HostSyncService.instance = new HostSyncService();
    }
    return HostSyncService.instance;
  }

  /** 初始化: 从 CloudStore RDB 恢复数据 */
  async init(context: common.Context): Promise<void> {
    if (this.ready) { return; }
    if (this.initPromise) {
      await this.initPromise;
      return;
    }
    this.initPromise = this.doInit(context);
    await this.initPromise;
  }

  private async doInit(context: common.Context): Promise<void> {
    try {
      await this.cloud.init(context);
      this.cloud.onCloudChange(() => { this.loadFromCloud(); });
      this.cloud.onCryptoReset(() => {
        this.hosts.clear();
        this.localHostConfigObservationAt.clear();
        this.deletedHostAt.clear();
        this.rdpCredentials.clear();
        this.relays.clear();
        this.localRdpCredentialObservationAt.clear();
        this.deletedRdpCredentialAt.clear();
        this.localRelayObservationAt.clear();
        this.deletedRelayAt.clear();
        this.lastCloudSnapshotLoadedAt = 0;
        this.emitDataChange();
        hilog.info(0x0001, 'CloudSync', 'HostSyncService: 收到加密重置通知, 内存数据已清空');
      });
      this.ready = true;
      // 先恢复本地持久化缓存；云服务关闭/失败时也不能把 UI 变成空列表。
      this.loadFromCloud();
      this.debugDump('HostSyncService');
    } catch (err) {
      this.initPromise = null;
      hilog.error(0x0001, 'CloudSync', "HostSyncService init 失败: " + JSON.stringify(err));
    }
  }

  private loadFromCloud(): void {
    if (!this.cloud.isReady()) { return; }
    const beforeSignature: string = this.visibleDataSignature();
    const previousSnapshotAt: number = this.lastCloudSnapshotLoadedAt;
    try {
      const previousHosts: Map<string, RemoteHost> = new Map();
      this.hosts.forEach((host: RemoteHost, hostId: string): void => {
        previousHosts.set(hostId, host);
      });
      const list: RemoteHost[] = this.cloud.loadAllHosts();
      hilog.info(0x0001, 'CloudSync', "HostSyncService.loadFromCloud: 主机=" + list.length.toString() + "条");
      this.hosts.clear();
      for (let i = 0; i < list.length; i++) {
        const next: RemoteHost = list[i];
        const deletedAt: number = this.deletedHostAt.get(next.id) ?? 0;
        if (shouldKeepDeletedHost(deletedAt, previousSnapshotAt)) { continue; }
        if (deletedAt > 0) { this.deletedHostAt.delete(next.id); }
        const local: RemoteHost | undefined = previousHosts.get(next.id);
        const configObservedAt: number = this.localHostConfigObservationAt.get(next.id) ?? 0;
        const observedAt: number = this.localHostObservationAt.get(next.id) ?? 0;
        if (local !== undefined && shouldKeepLocalHostConfig(configObservedAt, previousSnapshotAt)) {
          // 主机新增/编辑是本地配置写入，云回调可能紧跟着带回旧快照。
          this.hosts.set(next.id, RemoteHost.fromJSON(local.toJSON()));
          continue;
        }
        if (local !== undefined && observedAt > previousSnapshotAt) {
          // lastHealth/lastLatency 是本机连接观测，云回调不能用旧快照覆盖当前 UI。
          next.lastConnected = local.lastConnected;
          next.lastHealth = local.lastHealth;
          next.lastLatency = local.lastLatency;
        }
        this.hosts.set(next.id, next);
      }
      // 本地新增后云快照可能暂时还没有该行；在没有更晚删除的情况下保留它。
      previousHosts.forEach((local: RemoteHost, hostId: string): void => {
        const configObservedAt: number = this.localHostConfigObservationAt.get(hostId) ?? 0;
        const deletedAt: number = this.deletedHostAt.get(hostId) ?? 0;
        if (!this.hosts.has(hostId) && shouldKeepLocalHostConfig(configObservedAt, previousSnapshotAt) &&
          !shouldKeepDeletedHost(deletedAt, previousSnapshotAt)) {
          this.hosts.set(hostId, RemoteHost.fromJSON(local.toJSON()));
        }
      });
      // 旧版本把 RustDesk 直连 peer 端口默认写成 ID server 的 21116。
      // 官方 peer TCP 入口是 21118；仅迁移“直连开关开启且两个端口都仍为旧默认”的记录。
      let migratedDirectHosts: boolean = false;
      this.hosts.forEach((host: RemoteHost, hostId: string): void => {
        if (host.protocol !== 'rustdesk' || !host.rustdeskDirectEnabled ||
          host.rustdeskDirectPort !== 21116 || host.port !== 21116) {
          return;
        }
        const next: RemoteHost = RemoteHost.fromJSON(host.toJSON());
        next.port = RUSTDESK_PEER_TCP_PORT;
        next.rustdeskDirectPort = RUSTDESK_PEER_TCP_PORT;
        if (this.ready && !this.cloud.updateHost(next)) {
          hilog.warn(0x0001, 'CloudSync', 'RustDesk 直连端口迁移写入失败: ' + hostId);
          return;
        }
        this.hosts.set(hostId, next);
        migratedDirectHosts = true;
      });
      if (migratedDirectHosts && this.ready) { this.cloud.pushTable('remotehosts'); }
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', "HostSyncService.loadFromCloud 失败: " + JSON.stringify(err));
    }
    // 同时加载中继服务器配置
    try {
      const previousCredentials: Map<string, RdpCredential> = new Map();
      this.rdpCredentials.forEach((credential: RdpCredential, credentialId: string): void => {
        previousCredentials.set(credentialId, credential);
      });
      const credentials: RdpCredential[] = this.cloud.loadAllRdpCredentials();
      hilog.info(0x0001, 'CloudSync', 'HostSyncService.loadFromCloud: RDP凭据=' + credentials.length.toString() + '条');
      this.rdpCredentials.clear();
      const loadedCredentialIds: Set<string> = new Set<string>();
      for (let i = 0; i < credentials.length; i++) {
        const cloudCredential: RdpCredential = credentials[i];
        const deletedAt: number = this.deletedRdpCredentialAt.get(cloudCredential.id) ?? 0;
        if (deletedAt > previousSnapshotAt) { continue; }
        const localCredential: RdpCredential | undefined = previousCredentials.get(cloudCredential.id);
        const observedAt: number = this.localRdpCredentialObservationAt.get(cloudCredential.id) ?? 0;
        const next: RdpCredential = localCredential !== undefined && observedAt > previousSnapshotAt
          ? RdpCredential.fromJSON(localCredential.toJSON()) : cloudCredential;
        this.rdpCredentials.set(next.id, next);
        loadedCredentialIds.add(next.id);
      }
      // 云端回调可能紧跟在本地写入之后；在本地观测更新的情况下，保留暂时缺失的行。
      previousCredentials.forEach((credential: RdpCredential, credentialId: string): void => {
        const observedAt: number = this.localRdpCredentialObservationAt.get(credentialId) ?? 0;
        const deletedAt: number = this.deletedRdpCredentialAt.get(credentialId) ?? 0;
        if (!loadedCredentialIds.has(credentialId) && observedAt > previousSnapshotAt &&
          deletedAt <= previousSnapshotAt) {
          this.rdpCredentials.set(credentialId, RdpCredential.fromJSON(credential.toJSON()));
        }
      });
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', 'HostSyncService.loadRdpCredentials 失败: ' + JSON.stringify(err));
    }

    // 同时加载中继服务器配置
    try {
      const relays: RustDeskRelayConfig[] = this.cloud.loadAllRelays();
      hilog.info(0x0001, 'CloudSync', "HostSyncService.loadFromCloud: 中继=" + relays.length.toString() + "组");
      // Health probes are local observations. A distributed-table callback can
      // arrive with the previous cloud snapshot immediately after a local
      // probe was saved, so never roll a newer local result back to an older
      // health timestamp.
      const localRelays = new Map<string, RustDeskRelayConfig>();
      this.relays.forEach((relay: RustDeskRelayConfig): void => { localRelays.set(relay.id, relay); });
      this.relays.clear();
      const loadedRelayIds: Set<string> = new Set<string>();
      for (let i = 0; i < relays.length; i++) {
        const next = RustDeskRelayConfig.fromJSON(relays[i].toJSON());
        const deletedAt: number = this.deletedRelayAt.get(next.id) ?? 0;
        if (shouldKeepDeletedRelay(deletedAt, next.updatedAt, previousSnapshotAt)) {
          continue;
        }
        if (deletedAt > 0 && next.updatedAt >= deletedAt) {
          this.deletedRelayAt.delete(next.id);
        }
        const local = localRelays.get(next.id);
        const observedAt: number = this.localRelayObservationAt.get(next.id) ?? 0;
        let chosen: RustDeskRelayConfig = next;
        if (local && shouldKeepLocalRelayConfig(local.updatedAt, next.updatedAt, observedAt, previousSnapshotAt)) {
          chosen = RustDeskRelayConfig.fromJSON(local.toJSON());
        } else if (local && local.healthCheckedAt > next.healthCheckedAt) {
          // 健康探测属于本机观测，即便云端配置更新，也不能把卡片状态回滚。
          chosen.healthStatus = local.healthStatus;
          chosen.healthLatency = local.healthLatency;
          chosen.healthCheckedAt = local.healthCheckedAt;
        }
        this.relays.set(chosen.id, chosen);
        loadedRelayIds.add(chosen.id);
      }
      // 本地保存后云回调可能暂时缺少该行；在没有更晚删除的情况下保留本地配置。
      localRelays.forEach((local: RustDeskRelayConfig, relayId: string): void => {
        const observedAt: number = this.localRelayObservationAt.get(relayId) ?? 0;
        const deletedAt: number = this.deletedRelayAt.get(relayId) ?? 0;
        if (!loadedRelayIds.has(relayId) && observedAt > previousSnapshotAt && deletedAt <= previousSnapshotAt) {
          this.relays.set(relayId, RustDeskRelayConfig.fromJSON(local.toJSON()));
        }
      });
      // Migrate older Pro imports that were created before the relay endpoint
      // was stored on the host record. Keep explicit direct-connect hosts
      // untouched; managed rendezvous hosts inherit the bound ID server.
      let migratedProHosts = false;
      this.hosts.forEach((host: RemoteHost, hostId: string): void => {
        if (!host.rustdeskProManaged || host.sourceType !== 'rustdesk_pro' ||
          host.protocol !== 'rustdesk' || host.rustdeskDirectEnabled) { return; }
        const relay = this.relays.get(host.rustdeskRelayId);
        if (!relay || relay.idServer.length === 0 ||
          (host.host === relay.idServer && host.port === relay.idServerPort)) { return; }
        const next = RemoteHost.fromJSON(host.toJSON());
        next.host = relay.idServer;
        next.port = relay.idServerPort;
        if (this.ready && !this.cloud.updateHost(next)) {
          hilog.warn(0x0001, 'CloudSync', 'Pro 主机路由迁移写入失败: ' + hostId);
        }
        this.hosts.set(hostId, next);
        migratedProHosts = true;
      });
      if (migratedProHosts && this.ready) { this.cloud.pushTable('remotehosts'); }
      let migratedUnboundRustDeskHosts = false;
      this.relays.forEach((relay: RustDeskRelayConfig): void => {
        if (this.bindUniqueUnboundRustDeskHost(relay)) {
          migratedUnboundRustDeskHosts = true;
        }
      });
      if (migratedUnboundRustDeskHosts && this.ready) { this.cloud.pushTable('remotehosts'); }
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', "HostSyncService.loadRelays 失败: " + JSON.stringify(err));
    }
    this.lastCloudSnapshotLoadedAt = Date.now();
    const changed: boolean = serializedSnapshotChanged(beforeSignature, this.visibleDataSignature());
    if (changed) {
      this.emitDataChange();
    } else {
      hilog.info(0x0001, 'CloudSync', 'HostSyncService.loadFromCloud: visible snapshot unchanged');
    }
  }

  private visibleDataSignature(): string {
    const hosts: string[] = [];
    const credentials: string[] = [];
    const relays: string[] = [];
    this.hosts.forEach((host: RemoteHost): void => { hosts.push(JSON.stringify(host.toJSON())); });
    this.rdpCredentials.forEach((credential: RdpCredential): void => {
      credentials.push(JSON.stringify(credential.toJSON()));
    });
    this.relays.forEach((relay: RustDeskRelayConfig): void => { relays.push(JSON.stringify(relay.toJSON())); });
    hosts.sort();
    credentials.sort();
    relays.sort();
    return hosts.join('\n') + '\n--credentials--\n' + credentials.join('\n') +
      '\n--relays--\n' + relays.join('\n');
  }

  isReady(): boolean {
    return this.ready;
  }

  async whenReady(): Promise<void> {
    if (this.ready) { return; }
    if (this.initPromise) {
      await this.initPromise;
    }
  }

  onDataChange(callback: () => void): () => void {
    if (this.dataChangeListeners.indexOf(callback) < 0) {
      this.dataChangeListeners.push(callback);
    }
    return (): void => {
      const index: number = this.dataChangeListeners.indexOf(callback);
      if (index >= 0) { this.dataChangeListeners.splice(index, 1); }
    };
  }

  private emitDataChange(): void {
    const listeners: Array<() => void> = this.dataChangeListeners.slice();
    for (let i = 0; i < listeners.length; i++) {
      try {
        listeners[i]();
      } catch (err) {
        hilog.warn(0x0001, 'CloudSync', 'HostSyncService listener failed: ' + JSON.stringify(err));
      }
    }
  }

  getAllHosts(): RemoteHost[] {
    const result: RemoteHost[] = [];
    this.hosts.forEach((h: RemoteHost) => { result.push(h); });
    return result;
  }

  getHost(id: string): RemoteHost | undefined {
    return this.hosts.get(id);
  }

  addHost(host: RemoteHost): boolean {
    if (!host.id) { host.id = RemoteHost.generateId(); }
    host.createdAt = Date.now();
    const observedAt: number = Date.now();
    this.localHostConfigObservationAt.set(host.id, observedAt);
    this.deletedHostAt.delete(host.id);
    if (this.ready) {
      const ok: boolean = this.cloud.insertHost(host);
      if (!ok) {
        this.localHostConfigObservationAt.delete(host.id);
        hilog.error(0x0001, 'CloudSync', "HostSyncService.addHost: CloudStore 写入失败 " + host.label);
        return false;
      }
      this.cloud.pushTable('remotehosts');
    }
    this.hosts.set(host.id, host);
    hilog.info(0x0001, 'CloudSync', "主机已写入: " + host.label);
    this.emitDataChange();
    return true;
  }

  updateHost(host: RemoteHost): boolean {
    const current: RemoteHost | undefined = this.hosts.get(host.id);
    if (!current) { return false; }
    if (!serializedSnapshotChanged(JSON.stringify(current.toJSON()), JSON.stringify(host.toJSON()))) {
      hilog.info(0x0001, 'CloudSync', 'HostSyncService.updateHost: unchanged host skipped id=' + host.id);
      return true;
    }
    const observedAt: number = Date.now();
    this.localHostConfigObservationAt.set(host.id, observedAt);
    this.deletedHostAt.delete(host.id);
    if (this.ready) {
      const ok: boolean = this.cloud.updateHost(host);
      if (!ok) {
        this.localHostConfigObservationAt.delete(host.id);
        hilog.error(0x0001, 'CloudSync', "HostSyncService.updateHost: CloudStore 写入失败 " + host.label);
        return false;
      }
      this.cloud.pushTable('remotehosts');
    }
    this.hosts.set(host.id, host);
    this.emitDataChange();
    return true;
  }

  setGroup(hostId: string, groupId: string): boolean {
    const host = this.hosts.get(hostId);
    if (!host) { return false; }
    const next = RemoteHost.fromJSON(host.toJSON());
    next.groupId = normalizeGroupId(groupId);
    return this.updateHost(next);
  }

  setSortOrder(hostId: string, sortOrder: number): boolean {
    const host = this.hosts.get(hostId);
    if (!host || sortOrder < 0) { return false; }
    const next = RemoteHost.fromJSON(host.toJSON());
    next.sortOrder = Math.floor(sortOrder);
    return this.updateHost(next);
  }

  removeHost(id: string): boolean {
    if (!this.hosts.has(id)) { return false; }
    const observedAt: number = Date.now();
    this.deletedHostAt.set(id, observedAt);
    this.localHostConfigObservationAt.delete(id);
    if (this.ready && !this.cloud.deleteHost(id)) {
      this.deletedHostAt.delete(id);
      return false;
    }
    const result: boolean = this.hosts.delete(id);
    if (result) {
      this.localHostObservationAt.delete(id);
      this.healthCloudWriteAt.delete(id);
    }
    if (result && this.ready) { this.cloud.pushTable('remotehosts'); }
    if (result) { this.emitDataChange(); }
    return result;
  }

  removeHosts(ids: string[]): number {
    const uniqueIds: Set<string> = new Set<string>();
    ids.forEach((id: string): void => { if (id !== '') { uniqueIds.add(id); } });
    let removed: number = 0;
    for (const id of uniqueIds) {
      if (!this.hosts.has(id)) { continue; }
      const deletedAt: number = Date.now();
      this.deletedHostAt.set(id, deletedAt);
      this.localHostConfigObservationAt.delete(id);
      if (this.ready && !this.cloud.deleteHost(id)) {
        this.deletedHostAt.delete(id);
        hilog.warn(0x0001, 'CloudSync', 'HostSyncService.removeHosts: cloud delete failed');
        continue;
      }
      if (this.hosts.delete(id)) {
        this.localHostObservationAt.delete(id);
        this.healthCloudWriteAt.delete(id);
        removed++;
      }
    }
    if (removed > 0 && this.ready) { this.cloud.pushTable('remotehosts'); }
    if (removed > 0) { this.emitDataChange(); }
    return removed;
  }

  async updateLastConnected(hostId: string): Promise<void> {
    const host = this.hosts.get(hostId);
    if (!host) { return; }
    const next: RemoteHost = RemoteHost.fromJSON(host.toJSON());
    next.lastConnected = Date.now();
    this.persistLocalHostObservation(hostId, next, true);
  }

  async updateConnectionHealth(hostId: string, latencyMs: number, markConnected: boolean = false): Promise<void> {
    const host = this.hosts.get(hostId);
    if (!host) { return; }
    const next: RemoteHost = RemoteHost.fromJSON(host.toJSON());
    const validLatency: boolean = latencyMs >= 0;
    next.lastLatency = validLatency ? Math.max(1, Math.floor(latencyMs)) : 0;
    if (!validLatency) {
      next.lastHealth = ConnectionHealth.UNKNOWN;
    } else if (latencyMs < 20) {
      next.lastHealth = ConnectionHealth.EXCELLENT;
    } else if (latencyMs < 50) {
      next.lastHealth = ConnectionHealth.GOOD;
    } else if (latencyMs < 100) {
      next.lastHealth = ConnectionHealth.FAIR;
    } else if (latencyMs < 200) {
      next.lastHealth = ConnectionHealth.POOR;
    } else {
      next.lastHealth = ConnectionHealth.BAD;
    }
    if (markConnected) { next.lastConnected = Date.now(); }
    if (!markConnected && next.lastHealth === host.lastHealth && next.lastLatency === host.lastLatency) {
      return;
    }
    this.persistLocalHostObservation(hostId, next, markConnected);
  }

  private persistLocalHostObservation(hostId: string, next: RemoteHost, forceCloud: boolean): void {
    const now: number = Date.now();
    this.localHostObservationAt.set(hostId, now);
    let cloudSaved: boolean = false;
    const lastCloudWrite: number = this.healthCloudWriteAt.get(hostId) ?? 0;
    if (this.ready && (forceCloud || now - lastCloudWrite >= 30000)) {
      cloudSaved = this.cloud.updateHost(next);
      if (cloudSaved) {
        this.healthCloudWriteAt.set(hostId, now);
        this.cloud.pushTable('remotehosts');
      } else {
        hilog.warn(0x0001, 'CloudSync', 'HostSyncService.persistLocalHostObservation: CloudStore 写入失败');
      }
    }
    // 即使云写入暂时失败，列表卡片也必须先看到本次本机观测。
    this.hosts.set(hostId, next);
    this.emitDataChange();
  }

  getHostCount(): number { return this.hosts.size; }

  getLockedHostCount(): number {
    let count: number = 0;
    this.hosts.forEach((h: RemoteHost): void => { if (h.locked) { count++; } });
    return count;
  }

  searchHosts(query: string): RemoteHost[] {
    const q: string = query.toLowerCase();
    return this.getAllHosts().filter((h: RemoteHost): boolean => {
      return h.label.toLowerCase().includes(q) || h.host.toLowerCase().includes(q);
    });
  }

  getRdpCount(): number {
    let count: number = 0;
    this.hosts.forEach((h: RemoteHost): void => { if (h.protocol === 'rdp') { count++; } });
    return count;
  }

  getAllRdpCredentials(): RdpCredential[] {
    const result: RdpCredential[] = [];
    this.rdpCredentials.forEach((c: RdpCredential) => { result.push(c); });
    return result;
  }

  getRdpCredential(id: string): RdpCredential | undefined {
    return this.rdpCredentials.get(id);
  }

  addRdpCredential(credential: RdpCredential): boolean {
    if (!credential.id) { credential.id = RdpCredential.generateId(); }
    credential.createdAt = Date.now();
    if (this.ready && !this.cloud.insertRdpCredential(credential)) { return false; }
    this.rdpCredentials.set(credential.id, credential);
    this.localRdpCredentialObservationAt.set(credential.id, Date.now());
    this.deletedRdpCredentialAt.delete(credential.id);
    if (this.ready) { this.cloud.pushTable('rdpcredentials'); }
    this.emitDataChange();
    return true;
  }

  updateRdpCredential(credential: RdpCredential): boolean {
    if (!this.rdpCredentials.has(credential.id)) { return false; }
    if (this.ready && !this.cloud.updateRdpCredential(credential)) { return false; }
    this.rdpCredentials.set(credential.id, credential);
    this.localRdpCredentialObservationAt.set(credential.id, Date.now());
    this.deletedRdpCredentialAt.delete(credential.id);
    if (this.ready) { this.cloud.pushTable('rdpcredentials'); }
    this.emitDataChange();
    return true;
  }

  removeRdpCredential(id: string): boolean {
    if (!this.rdpCredentials.has(id)) { return false; }
    const detachedOriginals: RemoteHost[] = [];
    let detached: boolean = true;
    this.hosts.forEach((host: RemoteHost): void => {
      if (host.rdpCredentialId === id) {
        const original: RemoteHost = RemoteHost.fromJSON(host.toJSON());
        const next: RemoteHost = RemoteHost.fromJSON(host.toJSON());
        next.rdpCredentialId = '';
        if (this.updateHost(next)) { detachedOriginals.push(original); }
        else { detached = false; }
      }
    });
    if (!detached) {
      for (let i = 0; i < detachedOriginals.length; i++) { this.updateHost(detachedOriginals[i]); }
      return false;
    }
    if (this.ready && !this.cloud.deleteRdpCredential(id)) {
      for (let i = 0; i < detachedOriginals.length; i++) { this.updateHost(detachedOriginals[i]); }
      return false;
    }
    const result: boolean = this.rdpCredentials.delete(id);
    if (!result) { return false; }
    this.localRdpCredentialObservationAt.delete(id);
    this.deletedRdpCredentialAt.set(id, Date.now());
    if (this.ready) { this.cloud.pushTable('rdpcredentials'); }
    this.emitDataChange();
    return true;
  }

  getRustdeskCount(): number {
    let count: number = 0;
    this.hosts.forEach((h: RemoteHost): void => { if (h.protocol === 'rustdesk') { count++; } });
    return count;
  }

  getSshCount(): number {
    let count: number = 0;
    this.hosts.forEach((h: RemoteHost): void => { if (h.protocol === 'ssh') { count++; } });
    return count;
  }

  /** 调试: 打印本地数据库行数 (init 后调用) */
  debugDump(tag: string): void {
    const dump: string = this.cloud.debugDump();
    hilog.info(0x0001, 'CloudSync', "[" + tag + "] " + dump);
  }

  // ==================== RustDesk 中继服务器配置 ====================

  getAllRelays(): RustDeskRelayConfig[] {
    const result: RustDeskRelayConfig[] = [];
    this.relays.forEach((r: RustDeskRelayConfig) => { result.push(r); });
    return result;
  }

  getRelayCount(): number { return this.relays.size; }

  getHostCountForRelay(relayId: string): number {
    let count: number = 0;
    this.hosts.forEach((h: RemoteHost): void => {
      if (h.rustdeskRelayId === relayId) { count++; }
    });
    return count;
  }

  /**
   * 将旧版“只有 endpoint、没有 relayId”的普通 RustDesk 主机安全绑定到 relay。
   * 只有 endpoint+port 唯一命中时才迁移；多个同 endpoint 配置保持未绑定，交给用户选择。
   */
  private bindUniqueUnboundRustDeskHost(relay: RustDeskRelayConfig): boolean {
    const relayHost: string = relay.idServer.trim().toLowerCase();
    if (relayHost.length === 0) { return false; }
    const relayPort: number = normalizeRustDeskPort(relay.idServerPort);
    const candidates: RemoteHost[] = [];
    this.hosts.forEach((host: RemoteHost): void => {
      if (shouldBindLegacyRustDeskHostToRelay(
        host.protocol,
        host.rustdeskDirectEnabled,
        host.rustdeskRelayId,
        host.host,
        host.port,
        relayHost,
        relayPort
      )) {
        candidates.push(host);
      }
    });
    if (candidates.length !== 1) { return false; }
    const current: RemoteHost = candidates[0];
    const next: RemoteHost = RemoteHost.fromJSON(current.toJSON());
    next.rustdeskRelayId = relay.id;
    const observedAt: number = Date.now();
    this.localHostConfigObservationAt.set(next.id, observedAt);
    if (this.ready && !this.cloud.updateHost(next)) {
      this.localHostConfigObservationAt.delete(next.id);
      hilog.warn(0x0001, 'CloudSync', 'RustDesk 旧主机 relay 绑定写入失败: ' + current.id);
      return false;
    }
    this.hosts.set(next.id, next);
    return true;
  }

  /**
   * 将 Server Pro 地址簿 reconcile 到统一主机列表。
   * 只创建/更新 sourceType=rustdesk_pro 的记录，绝不接管同 ID 的手动主机，
   * 也不因一次同步缺少设备而删除已有记录。
   */
  reconcileRustDeskProHosts(relayId: string, accountId: string, peers: RustDeskProPeer[],
    syncedAt: number = Date.now(), relayHost: string = '', relayPort: number = 21116): RustDeskProReconcileResult {
    let endpointHost = relayHost;
    let endpointPort = relayPort;
    if (endpointHost.length === 0) {
      const relay = this.relays.get(relayId);
      if (relay) {
        endpointHost = relay.idServer;
        endpointPort = relay.idServerPort;
      }
    }
    const result = reconcileRustDeskProHosts(this.getAllHosts(), relayId, accountId, peers, syncedAt,
      endpointHost, endpointPort);
    const changedIds: Set<string> = new Set<string>();
    result.addedIds.forEach((id: string): void => { changedIds.add(id); });
    result.updatedIds.forEach((id: string): void => { changedIds.add(id); });
    result.missingIds.forEach((id: string): void => { changedIds.add(id); });
    let changed = false;
    changedIds.forEach((id: string): void => {
      const next = result.hosts.find((host: RemoteHost): boolean => host.id === id);
      if (!next) { return; }
      const current = this.hosts.get(id);
      const observedAt: number = Date.now();
      this.localHostConfigObservationAt.set(id, observedAt);
      this.deletedHostAt.delete(id);
      if (!current) {
        if (this.ready && !this.cloud.insertHost(next)) {
          this.localHostConfigObservationAt.delete(id);
          hilog.error(0x0001, 'CloudSync', 'Pro 主机写入失败: ' + id);
          return;
        }
        this.hosts.set(id, next);
        changed = true;
        return;
      }
      if (this.ready && !this.cloud.updateHost(next)) {
        this.localHostConfigObservationAt.delete(id);
        hilog.error(0x0001, 'CloudSync', 'Pro 主机更新失败: ' + id);
        return;
      }
      this.hosts.set(id, next);
      changed = true;
    });
    if (changed && this.ready) { this.cloud.pushTable('remotehosts'); }
    if (changed) { this.emitDataChange(); }
    return result;
  }

  addRelay(relay: RustDeskRelayConfig): boolean {
    if (!relay.id) { relay.id = RustDeskRelayConfig.generateId(); }
    relay.createdAt = Date.now();
    if (this.ready && !this.cloud.upsertRelay(relay)) { return false; }
    const observedAt: number = Date.now();
    if (relay.updatedAt <= 0) { relay.updatedAt = observedAt; }
    this.localRelayObservationAt.set(relay.id, observedAt);
    this.deletedRelayAt.delete(relay.id);
    this.relays.set(relay.id, relay);
    this.bindUniqueUnboundRustDeskHost(relay);
    this.emitDataChange();
    return true;
  }

  updateRelay(relay: RustDeskRelayConfig): boolean {
    if (!this.relays.has(relay.id)) { return false; }
    if (this.ready && !this.cloud.upsertRelay(relay)) { return false; }
    const observedAt: number = Date.now();
    if (relay.updatedAt <= 0) { relay.updatedAt = observedAt; }
    this.localRelayObservationAt.set(relay.id, observedAt);
    this.deletedRelayAt.delete(relay.id);
    this.relays.set(relay.id, relay);
    this.bindUniqueUnboundRustDeskHost(relay);
    this.emitDataChange();
    return true;
  }

  removeRelay(id: string): boolean {
    if (!this.relays.has(id)) { return false; }
    const affected: RemoteHost[] = [];
    let allReferencesDetached: boolean = true;
    this.hosts.forEach((h: RemoteHost): void => {
      if (h.rustdeskRelayId === id) {
        const next: RemoteHost = RemoteHost.fromJSON(h.toJSON());
        next.rustdeskRelayId = '';
        if (this.updateHost(next)) { affected.push(h); }
        else { allReferencesDetached = false; }
      }
    });
    if (!allReferencesDetached) {
      for (let i = 0; i < affected.length; i++) { this.updateHost(affected[i]); }
      return false;
    }
    if (this.ready && !this.cloud.deleteRelay(id)) {
      for (let i = 0; i < affected.length; i++) { this.updateHost(affected[i]); }
      return false;
    }
    const result: boolean = this.relays.delete(id);
    if (result) {
      this.localRelayObservationAt.delete(id);
      this.deletedRelayAt.set(id, Date.now());
      this.emitDataChange();
    }
    return result;
  }
}
