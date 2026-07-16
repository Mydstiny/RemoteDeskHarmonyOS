/**
 * HostSyncService.ets — 远程主机配置管理 (CloudStore RDB + 端云自动同步)
 */
import { RemoteHost } from '../model/RemoteHost';
import { RustDeskRelayConfig } from '../model/RustDeskRelayConfig';
import { RdpCredential } from '../model/RdpCredential';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { CloudStore } from './CloudStore';
import { normalizeGroupId } from './HostWorkspacePolicy';
import { RustDeskProPeer } from '../model/RustDeskProModels';
import { reconcileRustDeskProHosts, RustDeskProReconcileResult } from './RustDeskProSyncPolicy';

export class HostSyncService {
  private static instance: HostSyncService;
  private hosts: Map<string, RemoteHost> = new Map();
  private relays: Map<string, RustDeskRelayConfig> = new Map();
  private rdpCredentials: Map<string, RdpCredential> = new Map();
  private cloud: CloudStore = CloudStore.getInstance();
  private ready: boolean = false;
  private initPromise: Promise<void> | null = null;
  private dataChangeListeners: Array<() => void> = [];

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
        this.rdpCredentials.clear();
        this.relays.clear();
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
    try {
      const list: RemoteHost[] = this.cloud.loadAllHosts();
      hilog.info(0x0001, 'CloudSync', "HostSyncService.loadFromCloud: 主机=" + list.length.toString() + "条");
      this.hosts.clear();
      for (let i = 0; i < list.length; i++) {
        this.hosts.set(list[i].id, list[i]);
      }
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', "HostSyncService.loadFromCloud 失败: " + JSON.stringify(err));
    }
    // 同时加载中继服务器配置
    try {
      const credentials: RdpCredential[] = this.cloud.loadAllRdpCredentials();
      hilog.info(0x0001, 'CloudSync', 'HostSyncService.loadFromCloud: RDP凭据=' + credentials.length.toString() + '条');
      this.rdpCredentials.clear();
      for (let i = 0; i < credentials.length; i++) {
        this.rdpCredentials.set(credentials[i].id, credentials[i]);
      }
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', 'HostSyncService.loadRdpCredentials 失败: ' + JSON.stringify(err));
    }

    // 同时加载中继服务器配置
    try {
      const relays: RustDeskRelayConfig[] = this.cloud.loadAllRelays();
      hilog.info(0x0001, 'CloudSync', "HostSyncService.loadFromCloud: 中继=" + relays.length.toString() + "组");
      this.relays.clear();
      for (let i = 0; i < relays.length; i++) {
        this.relays.set(relays[i].id, relays[i]);
      }
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', "HostSyncService.loadRelays 失败: " + JSON.stringify(err));
    }
    this.emitDataChange();
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
    if (this.ready) {
      const ok: boolean = this.cloud.insertHost(host);
      if (!ok) {
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
    if (!this.hosts.has(host.id)) { return false; }
    if (this.ready) {
      const ok: boolean = this.cloud.updateHost(host);
      if (!ok) {
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
    if (this.ready && !this.cloud.deleteHost(id)) { return false; }
    const result: boolean = this.hosts.delete(id);
    if (result && this.ready) { this.cloud.pushTable('remotehosts'); }
    if (result) { this.emitDataChange(); }
    return result;
  }

  async updateLastConnected(hostId: string): Promise<void> {
    const host = this.hosts.get(hostId);
    if (!host || !this.ready) { return; }
    const next: RemoteHost = RemoteHost.fromJSON(host.toJSON());
    next.lastConnected = Date.now();
    if (!this.cloud.updateHost(next)) {
      hilog.warn(0x0001, 'CloudSync', 'HostSyncService.updateLastConnected: CloudStore 写入失败');
      return;
    }
    this.hosts.set(hostId, next);
    this.cloud.pushTable('remotehosts');
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
    if (this.ready) { this.cloud.pushTable('rdpcredentials'); }
    this.emitDataChange();
    return true;
  }

  updateRdpCredential(credential: RdpCredential): boolean {
    if (!this.rdpCredentials.has(credential.id)) { return false; }
    if (this.ready && !this.cloud.updateRdpCredential(credential)) { return false; }
    this.rdpCredentials.set(credential.id, credential);
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
   * 将 Server Pro 地址簿 reconcile 到统一主机列表。
   * 只创建/更新 sourceType=rustdesk_pro 的记录，绝不接管同 ID 的手动主机，
   * 也不因一次同步缺少设备而删除已有记录。
   */
  reconcileRustDeskProHosts(relayId: string, accountId: string, peers: RustDeskProPeer[],
    syncedAt: number = Date.now()): RustDeskProReconcileResult {
    const result = reconcileRustDeskProHosts(this.getAllHosts(), relayId, accountId, peers, syncedAt);
    const changedIds: Set<string> = new Set<string>();
    result.addedIds.forEach((id: string): void => { changedIds.add(id); });
    result.updatedIds.forEach((id: string): void => { changedIds.add(id); });
    result.missingIds.forEach((id: string): void => { changedIds.add(id); });
    let changed = false;
    changedIds.forEach((id: string): void => {
      const next = result.hosts.find((host: RemoteHost): boolean => host.id === id);
      if (!next) { return; }
      const current = this.hosts.get(id);
      if (!current) {
        if (this.ready && !this.cloud.insertHost(next)) {
          hilog.error(0x0001, 'CloudSync', 'Pro 主机写入失败: ' + id);
          return;
        }
        this.hosts.set(id, next);
        changed = true;
        return;
      }
      if (this.ready && !this.cloud.updateHost(next)) {
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
    this.relays.set(relay.id, relay);
    this.emitDataChange();
    return true;
  }

  updateRelay(relay: RustDeskRelayConfig): boolean {
    if (!this.relays.has(relay.id)) { return false; }
    if (this.ready && !this.cloud.upsertRelay(relay)) { return false; }
    this.relays.set(relay.id, relay);
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
    if (result) { this.emitDataChange(); }
    return result;
  }
}
