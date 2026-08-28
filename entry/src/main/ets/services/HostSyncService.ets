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
  DataMutationResult,
  DataMutationStage
} from './DataMutationResult';
import {
  RustDeskRelayCloudSyncOutcome,
  RustDeskRelayCloudSyncState,
  RustDeskRelaySaveResult,
  rustDeskRelayCreatePayloadMatches,
  rustDeskRelayIdFingerprint
} from './RustDeskRelaySavePolicy';
import {
  serializedSnapshotChanged,
  shouldKeepDeletedHost,
  shouldKeepLocalHostConfig
} from './HostSyncMergePolicy';
import { RustDeskProCredentialStore } from './RustDeskProCredentialStore';
import {
  rustDeskRelayCapabilityIdentityChanged
} from './RustDeskControlPlaneCapabilityPolicy';
import { remoteHostCloudBaseChanged } from './HostLocalPersonalizationPolicy';
import { lanHostUsesLocalOnlyStorage } from './LanHostAddressPolicy';
import { KeyVaultService } from './KeyVaultService';
import { AccountSessionCoordinator } from './AccountSessionCoordinator';
import {
  hydrateRustDeskPeerTwoFactorHost,
  RUSTDESK_PEER_2FA_BINDING_VERSION,
  RustDeskPeerTwoFactorBinding,
  RustDeskPeerTwoFactorBindingStore,
  rustDeskPeerTwoFactorEndpointIdentity,
  scrubRustDeskPeerTwoFactorRuntime,
  shouldRemoveDanglingRustDeskPeerTwoFactorBinding
} from './RustDeskPeerTwoFactorBindingStore';
import {
  migrateRustDeskPeerTwoFactorLegacyCandidate,
  RustDeskPeerTwoFactorLegacyCandidate,
  RustDeskPeerTwoFactorLegacySource
} from './RustDeskPeerTwoFactorLegacyMigration';
import { RustDeskAuthDraftStore } from './RustDeskAuthDraftStore';

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
  private localRdpCredentialObservationAt: Map<string, number> = new Map();
  private deletedRdpCredentialAt: Map<string, number> = new Map();
  private localRelayObservationAt: Map<string, number> = new Map();
  private deletedRelayAt: Map<string, number> = new Map();
  private lastCloudSnapshotLoadedAt: number = 0;
  private relaySaveSequence: number = 0;
  private context: common.Context | null = null;
  private readonly peerTwoFactorBindings: RustDeskPeerTwoFactorBindingStore =
    RustDeskPeerTwoFactorBindingStore.getInstance();
  private keyVaultListenerBound: boolean = false;
  private pendingPeerTwoFactorLegacyCandidates:
    Map<string, RustDeskPeerTwoFactorLegacyCandidate> = new Map();

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
      this.context = context;
      await this.cloud.init(context);
      if (!this.bindPeerTwoFactorScope()) {
        hilog.warn(0x0001, 'CloudSync',
          'RustDesk Peer 2FA 本机绑定仓库未就绪；绑定保持安全关闭');
      }
      // CloudStore also publishes Moonlight local-overlay/cache changes.
      // Those rows are intentionally outside this service's ordinary host
      // signature, so force one downstream notification after a successful
      // reload event and let every host-card owner refresh its own protocol.
      this.cloud.onCloudChange(() => { this.loadFromCloud(true); });
      this.cloud.onCryptoReset(() => {
        RustDeskAuthDraftStore.getInstance().clearAll();
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
      if (!this.keyVaultListenerBound) {
        this.keyVaultListenerBound = true;
        KeyVaultService.getInstance().onDataChange((): void => {
          if (this.refreshRustDeskPeerTwoFactorRuntime(true)) {
            this.emitDataChange();
          }
        });
      }
      // 先恢复本地持久化缓存；云服务关闭/失败时也不能把 UI 变成空列表。
      this.loadFromCloud();
      this.debugDump('HostSyncService');
    } catch (err) {
      this.initPromise = null;
      hilog.error(0x0001, 'CloudSync', "HostSyncService init 失败: " + JSON.stringify(err));
    }
  }

  private loadFromCloud(forceEmit: boolean = false): void {
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
          this.hosts.set(next.id, local.runtimeClone());
          continue;
        }
        if (local !== undefined && observedAt > previousSnapshotAt) {
          // lastHealth/lastLatency 是本机连接观测，云回调不能用旧快照覆盖当前 UI。
          next.lastConnected = local.lastConnected;
          next.lastHealth = local.lastHealth;
          next.lastLatency = local.lastLatency;
          // RustDesk presence is also a local observation. Keep the complete
          // presence tuple together so a stale cloud callback cannot restore
          // “检测中” or an older online/offline result.
          next.rustdeskProLastSeenAt = local.rustdeskProLastSeenAt;
          next.rustdeskProSyncError = local.rustdeskProSyncError;
        }
        this.hosts.set(next.id, next);
      }
      const dynamicLanHosts: RemoteHost[] = this.cloud.loadAllDynamicLanHosts();
      for (let i = 0; i < dynamicLanHosts.length; i++) {
        const dynamicHost: RemoteHost = dynamicLanHosts[i];
        if (this.hosts.has(dynamicHost.id)) {
          hilog.warn(0x0001, 'CloudSync',
            '动态局域网主机 ID 与云主机冲突，已忽略本机副本 hostId=' +
            rustDeskRelayIdFingerprint(dynamicHost.id));
          continue;
        }
        const deletedAt: number = this.deletedHostAt.get(dynamicHost.id) ?? 0;
        if (!shouldKeepDeletedHost(deletedAt, previousSnapshotAt)) {
          this.hosts.set(dynamicHost.id, dynamicHost);
        }
      }
      // 本地新增后云快照可能暂时还没有该行；在没有更晚删除的情况下保留它。
      previousHosts.forEach((local: RemoteHost, hostId: string): void => {
        const configObservedAt: number = this.localHostConfigObservationAt.get(hostId) ?? 0;
        const deletedAt: number = this.deletedHostAt.get(hostId) ?? 0;
        if (!this.hosts.has(hostId) && shouldKeepLocalHostConfig(configObservedAt, previousSnapshotAt) &&
          !shouldKeepDeletedHost(deletedAt, previousSnapshotAt)) {
          this.hosts.set(hostId, local.runtimeClone());
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
        const next: RemoteHost = host.runtimeClone();
        next.port = RUSTDESK_PEER_TCP_PORT;
        next.rustdeskDirectPort = RUSTDESK_PEER_TCP_PORT;
        const localOnly: boolean = lanHostUsesLocalOnlyStorage(next);
        const persisted: boolean = !this.ready || (localOnly
          ? this.cloud.updateDynamicLanHost(next) : this.cloud.updateHost(next));
        if (!persisted) {
          hilog.warn(0x0001, 'CloudSync',
            'RustDesk 直连端口迁移写入失败 hostId=' +
            rustDeskRelayIdFingerprint(hostId));
          return;
        }
        this.hosts.set(hostId, next);
        migratedDirectHosts = migratedDirectHosts || !localOnly;
      });
      if (migratedDirectHosts && this.ready) { this.cloud.pushTable('remotehosts'); }
      this.refreshRustDeskPeerTwoFactorRuntime(true);
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
          ? localCredential.runtimeClone() : cloudCredential;
        this.rdpCredentials.set(next.id, next);
        loadedCredentialIds.add(next.id);
      }
      // 云端回调可能紧跟在本地写入之后；在本地观测更新的情况下，保留暂时缺失的行。
      previousCredentials.forEach((credential: RdpCredential, credentialId: string): void => {
        const observedAt: number = this.localRdpCredentialObservationAt.get(credentialId) ?? 0;
        const deletedAt: number = this.deletedRdpCredentialAt.get(credentialId) ?? 0;
        if (!loadedCredentialIds.has(credentialId) && observedAt > previousSnapshotAt &&
          deletedAt <= previousSnapshotAt) {
          this.rdpCredentials.set(credentialId, credential.runtimeClone());
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
        const next = host.runtimeClone();
        next.host = relay.idServer;
        next.port = relay.idServerPort;
        if (this.ready && !this.cloud.updateHost(next)) {
          hilog.warn(0x0001, 'CloudSync',
            'Pro 主机路由迁移写入失败 hostId=' +
            rustDeskRelayIdFingerprint(hostId));
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
    if (changed || forceEmit) {
      this.emitDataChange();
    } else {
      hilog.info(0x0001, 'CloudSync', 'HostSyncService.loadFromCloud: visible snapshot unchanged');
    }
  }

  private visibleDataSignature(): string {
    const hosts: string[] = [];
    const credentials: string[] = [];
    const relays: string[] = [];
    this.hosts.forEach((host: RemoteHost): void => {
      hosts.push(JSON.stringify(host.toJSON()) + '\n--runtime-secrets--\n' +
        host.runtimeSecretStateSignature());
    });
    this.rdpCredentials.forEach((credential: RdpCredential): void => {
      credentials.push(JSON.stringify(credential.toJSON()) + '\n--runtime-secrets--\n' +
        credential.runtimeSecretStateSignature());
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

  /** Drop every scope-derived cache before CloudStore switches physical files. */
  clearForScopeTransition(): void {
    RustDeskAuthDraftStore.getInstance().clearAll();
    this.hosts.clear();
    this.relays.clear();
    this.rdpCredentials.clear();
    this.localHostObservationAt.clear();
    this.localHostConfigObservationAt.clear();
    this.deletedHostAt.clear();
    this.localRdpCredentialObservationAt.clear();
    this.deletedRdpCredentialAt.clear();
    this.localRelayObservationAt.clear();
    this.deletedRelayAt.clear();
    this.lastCloudSnapshotLoadedAt = 0;
    this.pendingPeerTwoFactorLegacyCandidates.clear();
    this.peerTwoFactorBindings.clearMemoryForScopeTransition();
    this.emitDataChange();
  }

  /** Reload only after the new scope store has opened successfully. */
  reloadForScopeTransition(): void {
    this.clearForScopeTransition();
    if (!this.bindPeerTwoFactorScope()) {
      hilog.warn(0x0001, 'CloudSync',
        '账号切换后 RustDesk Peer 2FA 本机绑定仓库未就绪');
    }
    this.loadFromCloud();
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

  private bindPeerTwoFactorScope(): boolean {
    if (this.context === null) { return false; }
    const ownerScopeId: string =
      AccountSessionCoordinator.getInstance().currentScope().ownerScopeId;
    return this.peerTwoFactorBindings.bindContext(this.context, ownerScopeId);
  }

  private legacyPeerTwoFactorCandidate(
    host: RemoteHost
  ): RustDeskPeerTwoFactorLegacyCandidate | null {
    const entryId: string = host.rustdeskTotpEntryId.trim();
    const source: string = host.rustdeskTotpLegacySource.trim();
    if (host.protocol !== 'rustdesk' || entryId === '' ||
      (source !== 'remote_json' && source !== 'cloud_extension' &&
        source !== 'local_backup')) {
      return null;
    }
    return {
      ownerScopeId: host.userId,
      hostId: host.id,
      entryId,
      autoSubmit: host.rustdeskTotpAutoSubmit,
      sourceDeviceId: host.rustdeskTotpLegacyDeviceId,
      source: source as RustDeskPeerTwoFactorLegacySource
    };
  }

  /**
   * Rebuild only the runtime projection from the owner/device-local binding
   * store. Missing entries and stale endpoint identities always fail closed.
   */
  private refreshRustDeskPeerTwoFactorRuntime(removeDangling: boolean): boolean {
    let changed: boolean = false;
    const keyVault: KeyVaultService = KeyVaultService.getInstance();
    const stalePendingIds: string[] = [];
    this.pendingPeerTwoFactorLegacyCandidates.forEach(
      (_candidate: RustDeskPeerTwoFactorLegacyCandidate, hostId: string): void => {
        if (!this.hosts.has(hostId)) { stalePendingIds.push(hostId); }
      });
    stalePendingIds.forEach((hostId: string): void => {
      this.pendingPeerTwoFactorLegacyCandidates.delete(hostId);
    });
    this.hosts.forEach((host: RemoteHost): void => {
      if (host.protocol !== 'rustdesk') { return; }
      const beforeEntry: string = host.rustdeskTotpEntryId;
      const beforeAuto: boolean = host.rustdeskTotpAutoSubmit;
      const runtimeLegacy: RustDeskPeerTwoFactorLegacyCandidate | null =
        this.legacyPeerTwoFactorCandidate(host);
      const pendingLegacy: RustDeskPeerTwoFactorLegacyCandidate | undefined =
        this.pendingPeerTwoFactorLegacyCandidates.get(host.id);
      const legacy: RustDeskPeerTwoFactorLegacyCandidate | null =
        runtimeLegacy !== null ? runtimeLegacy : (pendingLegacy ?? null);
      if (legacy !== null && !this.peerTwoFactorBindings.isLoaded()) {
        this.pendingPeerTwoFactorLegacyCandidates.set(host.id, legacy);
      } else if (legacy !== null) {
        const migration = migrateRustDeskPeerTwoFactorLegacyCandidate(
          legacy, host, this.peerTwoFactorBindings,
          (entryId: string): boolean => keyVault.getTotpEntry(entryId) !== undefined);
        if (migration.status === 'persistence_failed') {
          hilog.warn(0x0001, 'CloudSync',
            'RustDesk Peer 2FA legacy binding migration persistence failed hostId=' +
            rustDeskRelayIdFingerprint(host.id));
        }
        if (migration.reason === 'legacy_totp_entry_missing' &&
          !keyVault.isTotpSnapshotReady()) {
          this.pendingPeerTwoFactorLegacyCandidates.set(host.id, legacy);
        } else {
          this.pendingPeerTwoFactorLegacyCandidates.delete(host.id);
        }
      }
      const endpoint: string = rustDeskPeerTwoFactorEndpointIdentity(host);
      const binding: RustDeskPeerTwoFactorBinding | null = endpoint === '' ? null :
        this.peerTwoFactorBindings.get(host.id, endpoint);
      const bindingEntryExists: boolean = binding !== null &&
        keyVault.getTotpEntry(binding.entryId) !== undefined;
      const hydrated: boolean = hydrateRustDeskPeerTwoFactorHost(
        host, binding,
        (entryId: string): boolean => keyVault.getTotpEntry(entryId) !== undefined,
        this.peerTwoFactorBindings.deviceIdentity());
      if (!hydrated && binding !== null &&
        shouldRemoveDanglingRustDeskPeerTwoFactorBinding(
          removeDangling, keyVault.isTotpSnapshotReady(), bindingEntryExists)) {
        if (!this.peerTwoFactorBindings.remove(host.id, endpoint)) {
          hilog.warn(0x0001, 'CloudSync',
            'RustDesk Peer 2FA dangling binding cleanup failed hostId=' +
            rustDeskRelayIdFingerprint(host.id));
        }
      } else if (!hydrated && binding !== null && removeDangling &&
        !keyVault.isTotpSnapshotReady()) {
        hilog.info(0x0001, 'CloudSync',
          'RustDesk Peer 2FA binding cleanup deferred until KeyVault snapshot is ready hostId=' +
          rustDeskRelayIdFingerprint(host.id));
      }
      changed = changed || beforeEntry !== host.rustdeskTotpEntryId ||
        beforeAuto !== host.rustdeskTotpAutoSubmit;
    });
    if (!this.peerTwoFactorBindings.isLoaded()) {
      this.hosts.forEach((host: RemoteHost): void => {
        if (host.protocol !== 'rustdesk') { return; }
        changed = changed || host.rustdeskTotpEntryId !== '' ||
          host.rustdeskTotpAutoSubmit;
        scrubRustDeskPeerTwoFactorRuntime(host);
      });
    }
    return changed;
  }

  setRustDeskPeerTwoFactorBinding(hostId: string, entryId: string,
    autoSubmit: boolean): boolean {
    const host: RemoteHost | undefined = this.hosts.get(hostId);
    const normalizedEntry: string = entryId.trim();
    if (host === undefined || host.protocol !== 'rustdesk' ||
      !this.peerTwoFactorBindings.isLoaded()) {
      return false;
    }
    if (normalizedEntry === '') { return this.clearRustDeskPeerTwoFactorBinding(hostId); }
    if (KeyVaultService.getInstance().getTotpEntry(normalizedEntry) === undefined) {
      return false;
    }
    const endpoint: string = rustDeskPeerTwoFactorEndpointIdentity(host);
    const ownerScopeId: string =
      AccountSessionCoordinator.getInstance().currentScope().ownerScopeId;
    if (endpoint === '' || ownerScopeId !== host.userId) { return false; }
    const binding: RustDeskPeerTwoFactorBinding = {
      version: RUSTDESK_PEER_2FA_BINDING_VERSION,
      ownerScopeId,
      hostId: host.id,
      endpointIdentity: endpoint,
      entryId: normalizedEntry,
      autoSubmit,
      deviceIdentity: this.peerTwoFactorBindings.deviceIdentity(),
      source: 'manual',
      migrationVersion: 0,
      updatedAt: Date.now()
    };
    if (!this.peerTwoFactorBindings.save(binding)) {
      scrubRustDeskPeerTwoFactorRuntime(host);
      this.refreshRustDeskPeerTwoFactorRuntime(false);
      this.emitDataChange();
      return false;
    }
    host.rustdeskTotpEntryId = normalizedEntry;
    host.rustdeskTotpAutoSubmit = autoSubmit;
    host.rustdeskTotpLegacyDeviceId = '';
    host.rustdeskTotpLegacySource = '';
    this.emitDataChange();
    return true;
  }

  clearRustDeskPeerTwoFactorBinding(hostId: string): boolean {
    const host: RemoteHost | undefined = this.hosts.get(hostId);
    if (host === undefined || host.protocol !== 'rustdesk' ||
      !this.peerTwoFactorBindings.isLoaded()) {
      return false;
    }
    const endpoint: string = rustDeskPeerTwoFactorEndpointIdentity(host);
    if (endpoint === '' || !this.peerTwoFactorBindings.remove(host.id, endpoint)) {
      if (this.refreshRustDeskPeerTwoFactorRuntime(false)) { this.emitDataChange(); }
      return false;
    }
    scrubRustDeskPeerTwoFactorRuntime(host);
    this.emitDataChange();
    return true;
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
    const localOnly: boolean = lanHostUsesLocalOnlyStorage(host);
    if (this.ready) {
      const ok: boolean = localOnly
        ? this.cloud.insertDynamicLanHost(host) : this.cloud.insertHost(host);
      if (!ok) {
        this.localHostConfigObservationAt.delete(host.id);
        hilog.error(0x0001, 'CloudSync',
          'HostSyncService.addHost: CloudStore 写入失败 hostId=' +
          rustDeskRelayIdFingerprint(host.id));
        return false;
      }
      if (!localOnly) { this.cloud.pushTable('remotehosts'); }
    }
    scrubRustDeskPeerTwoFactorRuntime(host);
    if (host.protocol === 'rustdesk' && this.peerTwoFactorBindings.isLoaded()) {
      const endpoint: string = rustDeskPeerTwoFactorEndpointIdentity(host);
      hydrateRustDeskPeerTwoFactorHost(
        host, endpoint === '' ? null : this.peerTwoFactorBindings.get(host.id, endpoint),
        (entryId: string): boolean =>
          KeyVaultService.getInstance().getTotpEntry(entryId) !== undefined,
        this.peerTwoFactorBindings.deviceIdentity());
    }
    this.hosts.set(host.id, host);
    hilog.info(0x0001, 'CloudSync',
      '主机已写入 hostId=' +
      rustDeskRelayIdFingerprint(host.id));
    this.emitDataChange();
    return true;
  }

  updateHost(host: RemoteHost): boolean {
    const current: RemoteHost | undefined = this.hosts.get(host.id);
    if (!current) { return false; }
    const previousPeerEndpoint: string =
      current.protocol === 'rustdesk' ? rustDeskPeerTwoFactorEndpointIdentity(current) : '';
    const nextPeerEndpoint: string =
      host.protocol === 'rustdesk' ? rustDeskPeerTwoFactorEndpointIdentity(host) : '';
    const currentLocalOnly: boolean = lanHostUsesLocalOnlyStorage(current);
    const nextLocalOnly: boolean = lanHostUsesLocalOnlyStorage(host);
    if (currentLocalOnly !== nextLocalOnly) {
      hilog.warn(0x0001, 'CloudSync',
        'HostSyncService.updateHost: 已拒绝隐式切换云/本机存储策略 hostId=' +
        rustDeskRelayIdFingerprint(host.id));
      return false;
    }
    const currentSnapshot: string = JSON.stringify(current.toJSON()) + '\n--runtime-secrets--\n' +
      current.runtimeSecretStateSignature();
    const nextSnapshot: string = JSON.stringify(host.toJSON()) + '\n--runtime-secrets--\n' +
      host.runtimeSecretStateSignature();
    if (!serializedSnapshotChanged(currentSnapshot, nextSnapshot)) {
      hilog.info(0x0001, 'CloudSync',
        'HostSyncService.updateHost: unchanged host skipped hostId=' +
        rustDeskRelayIdFingerprint(host.id));
      return true;
    }
    const observedAt: number = Date.now();
    let removedPeerBinding: RustDeskPeerTwoFactorBinding | null = null;
    if (previousPeerEndpoint !== '' && previousPeerEndpoint !== nextPeerEndpoint) {
      if (!this.peerTwoFactorBindings.isLoaded()) {
        hilog.warn(0x0001, 'CloudSync',
          'RustDesk endpoint change blocked because Peer 2FA store is unavailable hostId=' +
          rustDeskRelayIdFingerprint(host.id));
        return false;
      }
      removedPeerBinding = this.peerTwoFactorBindings.get(host.id, previousPeerEndpoint);
      if (removedPeerBinding !== null &&
        !this.peerTwoFactorBindings.remove(host.id, previousPeerEndpoint)) {
        hilog.warn(0x0001, 'CloudSync',
          'RustDesk endpoint change blocked because old Peer 2FA binding cleanup failed hostId=' +
          rustDeskRelayIdFingerprint(host.id));
        if (this.refreshRustDeskPeerTwoFactorRuntime(false)) { this.emitDataChange(); }
        return false;
      }
    }
    this.localHostConfigObservationAt.set(host.id, observedAt);
    this.deletedHostAt.delete(host.id);
    // Presence-only changes occur when an encrypted value is intentionally
    // cleared while its plaintext is unavailable. They must use the full
    // sensitive write path (and its unlock gate), not a personalization-only
    // update that would leave the encrypted column untouched.
    const cloudBaseChanged: boolean = remoteHostCloudBaseChanged(current, host) ||
      current.runtimeSecretStateSignature() !== host.runtimeSecretStateSignature();
    if (this.ready) {
      const ok: boolean = nextLocalOnly ? this.cloud.updateDynamicLanHost(host) :
        (cloudBaseChanged ? this.cloud.updateHost(host) :
          this.cloud.updateHostLocalPersonalization(host));
      if (!ok) {
        if (removedPeerBinding !== null &&
          !this.peerTwoFactorBindings.save(removedPeerBinding)) {
          hilog.error(0x0001, 'CloudSync',
            'failed to restore Peer 2FA binding after host update rollback hostId=' +
            rustDeskRelayIdFingerprint(host.id));
        }
        if (!this.peerTwoFactorBindings.isLoaded() &&
          this.refreshRustDeskPeerTwoFactorRuntime(false)) {
          this.emitDataChange();
        }
        this.localHostConfigObservationAt.delete(host.id);
        hilog.error(0x0001, 'CloudSync',
          'HostSyncService.updateHost: CloudStore 写入失败 hostId=' +
          rustDeskRelayIdFingerprint(host.id));
        return false;
      }
      if (!nextLocalOnly && cloudBaseChanged) { this.cloud.pushTable('remotehosts'); }
    }
    scrubRustDeskPeerTwoFactorRuntime(host);
    if (nextPeerEndpoint !== '' && this.peerTwoFactorBindings.isLoaded()) {
      hydrateRustDeskPeerTwoFactorHost(
        host, this.peerTwoFactorBindings.get(host.id, nextPeerEndpoint),
        (entryId: string): boolean =>
          KeyVaultService.getInstance().getTotpEntry(entryId) !== undefined,
        this.peerTwoFactorBindings.deviceIdentity());
    }
    this.hosts.set(host.id, host);
    this.emitDataChange();
    return true;
  }

  /** Accept only the fields an exact LAN discovery match is allowed to refresh. */
  updateDynamicLanAddress(host: RemoteHost): boolean {
    const current: RemoteHost | undefined = this.hosts.get(host.id);
    if (current === undefined || !lanHostUsesLocalOnlyStorage(current) ||
      !lanHostUsesLocalOnlyStorage(host) || current.protocol !== host.protocol ||
      current.lanDiscoveryIdentity !== host.lanDiscoveryIdentity) {
      return false;
    }
    const expected: RemoteHost = current.runtimeClone();
    expected.host = host.host;
    expected.port = host.port;
    expected.lanLastResolvedAt = host.lanLastResolvedAt;
    if (expected.protocol === 'rustdesk') {
      expected.rustdeskDirectHost = host.rustdeskDirectHost;
      expected.rustdeskDirectPort = host.rustdeskDirectPort;
    } else {
      expected.rdpCertificateRouteIdentity = host.rdpCertificateRouteIdentity;
    }
    if (JSON.stringify(expected.toJSON()) !== JSON.stringify(host.toJSON())) {
      hilog.warn(0x0001, 'CloudSync',
        'HostSyncService.updateDynamicLanAddress: non-address change rejected');
      return false;
    }
    if (this.ready && !this.cloud.updateDynamicLanHostAddress(expected)) {
      return false;
    }
    this.hosts.set(expected.id, expected);
    this.localHostConfigObservationAt.set(expected.id, Date.now());
    this.emitDataChange();
    return true;
  }

  setGroup(hostId: string, groupId: string): boolean {
    const host = this.hosts.get(hostId);
    if (!host) { return false; }
    const next = host.runtimeClone();
    next.groupId = normalizeGroupId(groupId);
    return this.updateHost(next);
  }

  setSortOrder(hostId: string, sortOrder: number): boolean {
    const host = this.hosts.get(hostId);
    if (!host || sortOrder < 0) { return false; }
    const next = host.runtimeClone();
    next.sortOrder = Math.floor(sortOrder);
    return this.updateHost(next);
  }

  removeHost(id: string): boolean {
    const current: RemoteHost | undefined = this.hosts.get(id);
    if (!current) { return false; }
    if (current.protocol === 'rustdesk' && !this.peerTwoFactorBindings.isLoaded()) {
      hilog.warn(0x0001, 'CloudSync',
        'RustDesk host deletion blocked because Peer 2FA store is unavailable hostId=' +
        rustDeskRelayIdFingerprint(id));
      return false;
    }
    const removedBindings: RustDeskPeerTwoFactorBinding[] =
      this.peerTwoFactorBindings.isLoaded() ?
        this.peerTwoFactorBindings.list().filter(
          (binding: RustDeskPeerTwoFactorBinding): boolean => binding.hostId === id) : [];
    if (removedBindings.length > 0 && !this.peerTwoFactorBindings.removeHost(id)) {
      hilog.warn(0x0001, 'CloudSync',
        'host deletion blocked because Peer 2FA binding cleanup failed hostId=' +
        rustDeskRelayIdFingerprint(id));
      if (this.refreshRustDeskPeerTwoFactorRuntime(false)) { this.emitDataChange(); }
      return false;
    }
    const localOnly: boolean = lanHostUsesLocalOnlyStorage(current);
    const observedAt: number = Date.now();
    this.deletedHostAt.set(id, observedAt);
    this.localHostConfigObservationAt.delete(id);
    if (this.ready && !(localOnly
      ? this.cloud.deleteDynamicLanHost(id) : this.cloud.deleteHost(id))) {
      for (let i = 0; i < removedBindings.length; i++) {
        if (!this.peerTwoFactorBindings.save(removedBindings[i])) {
          hilog.error(0x0001, 'CloudSync',
            'failed to restore Peer 2FA binding after host delete rollback hostId=' +
            rustDeskRelayIdFingerprint(id));
        }
      }
      if (!this.peerTwoFactorBindings.isLoaded() &&
        this.refreshRustDeskPeerTwoFactorRuntime(false)) {
        this.emitDataChange();
      }
      this.deletedHostAt.delete(id);
      return false;
    }
    const result: boolean = this.hosts.delete(id);
    if (result) {
      this.localHostObservationAt.delete(id);
      RustDeskAuthDraftStore.getInstance().clearHost(id);
      this.pendingPeerTwoFactorLegacyCandidates.delete(id);
    }
    if (result && this.ready && !localOnly) { this.cloud.pushTable('remotehosts'); }
    if (result) { this.emitDataChange(); }
    return result;
  }

  removeHosts(ids: string[]): number {
    const uniqueIds: Set<string> = new Set<string>();
    ids.forEach((id: string): void => { if (id !== '') { uniqueIds.add(id); } });
    let removed: number = 0;
    for (const id of uniqueIds) {
      if (this.removeHost(id)) { removed++; }
    }
    return removed;
  }

  async updateLastConnected(hostId: string): Promise<void> {
    const host = this.hosts.get(hostId);
    if (!host) { return; }
    const next: RemoteHost = host.runtimeClone();
    next.lastConnected = Date.now();
    this.persistLocalHostObservation(hostId, next, true);
  }

  async updateConnectionHealth(hostId: string, latencyMs: number, markConnected: boolean = false): Promise<void> {
    const host = this.hosts.get(hostId);
    if (!host) { return; }
    const next: RemoteHost = host.runtimeClone();
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

  /**
   * Store a presence probe locally before attempting a throttled cloud write.
   * Presence contains more than latency, so callers use this for RustDesk
   * pending/online/offline transitions as one atomic UI observation.
   */
  updateLocalHostObservation(host: RemoteHost): void {
    if (!this.hosts.has(host.id)) { return; }
    const next: RemoteHost = host.runtimeClone();
    this.persistLocalHostObservation(host.id, next, false);
  }

  private persistLocalHostObservation(hostId: string, next: RemoteHost, _forceCloud: boolean): void {
    const now: number = Date.now();
    this.localHostObservationAt.set(hostId, now);
    const localOnly: boolean = lanHostUsesLocalOnlyStorage(next);
    if (this.ready && !(localOnly
      ? this.cloud.updateDynamicLanHost(next) : this.cloud.updateHostLocalPersonalization(next))) {
      hilog.warn(0x0001, 'CloudSync',
        'HostSyncService.persistLocalHostObservation: 本机观测写入失败');
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
        const original: RemoteHost = host.runtimeClone();
        const next: RemoteHost = host.runtimeClone();
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
    const next: RemoteHost = current.runtimeClone();
    next.rustdeskRelayId = relay.id;
    const observedAt: number = Date.now();
    this.localHostConfigObservationAt.set(next.id, observedAt);
    if (this.ready && !this.cloud.updateHost(next)) {
      this.localHostConfigObservationAt.delete(next.id);
      hilog.warn(0x0001, 'CloudSync',
        'RustDesk 旧主机 relay 绑定写入失败 hostId=' +
        rustDeskRelayIdFingerprint(current.id));
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
    let cloudChanged = false;
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
        cloudChanged = true;
        return;
      }
      const cloudBaseChanged: boolean =
        remoteHostCloudBaseChanged(current, next);
      const persisted: boolean = !this.ready ||
        (cloudBaseChanged ? this.cloud.updateHost(next) :
          this.cloud.updateHostLocalPersonalization(next));
      if (!persisted) {
        this.localHostConfigObservationAt.delete(id);
        hilog.error(0x0001, 'CloudSync', 'Pro 主机更新失败: ' + id);
        return;
      }
      this.hosts.set(id, next);
      changed = true;
      cloudChanged = cloudChanged || cloudBaseChanged;
    });
    if (cloudChanged && this.ready) { this.cloud.pushTable('remotehosts'); }
    if (changed) { this.emitDataChange(); }
    return result;
  }

  private nextRelaySaveAttemptId(): string {
    this.relaySaveSequence++;
    return Date.now().toString(36) + '-' + this.relaySaveSequence.toString(36);
  }

  private completeRelayMutation(
    relay: RustDeskRelayConfig,
    attemptId: string,
    operation: string,
    mutation: DataMutationResult,
    previous: RustDeskRelayConfig | undefined
  ): RustDeskRelaySaveResult {
    const result: RustDeskRelaySaveResult =
      RustDeskRelaySaveResult.fromMutation(
        attemptId, relay.id, mutation,
        mutation.ok &&
          this.cloud.rustDeskRelayCloudSyncInitialState() ===
            'pending');
    if (!result.ok) {
      hilog.warn(0x0001, 'RustDeskSave',
        'attempt=' + attemptId + ' relay=' +
        rustDeskRelayIdFingerprint(relay.id) + ' stage=' +
        result.stage + ' code=' + result.code +
        ' committed=' + result.localCommitted.toString());
      return result;
    }
    const readback: RustDeskRelayConfig | null =
      this.cloud.loadRelayById(relay.id);
    if (readback === null) {
      return RustDeskRelaySaveResult.fromMutation(
        attemptId, relay.id,
        DataMutationResult.failure(
          relay.id, 'readback_not_found',
          '保存后无法刷新服务器记录',
          'verifying', true));
    }
    const observedAt: number = Date.now();
    this.localRelayObservationAt.set(readback.id, observedAt);
    this.deletedRelayAt.delete(readback.id);
    this.relays.set(readback.id, readback);
    if (previous !== undefined &&
      rustDeskRelayCapabilityIdentityChanged(
        previous, readback)) {
      RustDeskProCredentialStore.getInstance()
        .invalidateControlPlaneProofsForRelay(readback.id);
    }
    this.bindUniqueUnboundRustDeskHost(readback);
    this.emitDataChange();
    result.applyCloudSyncState(
      this.cloud.rustDeskRelayCloudSyncInitialState());
    hilog.info(0x0001, 'RustDeskSave',
      'attempt=' + attemptId + ' relay=' +
      rustDeskRelayIdFingerprint(readback.id) +
      ' operation=' + operation +
      ' stage=completed code=ok cloud=' +
      result.cloudSyncState);
    return result;
  }

  private observeRelayCloudSync(
    result: RustDeskRelaySaveResult,
    onCloudState:
      ((state: RustDeskRelayCloudSyncState,
        failureKind: string) => void) | null = null
  ): void {
    if (!result.ok) { return; }
    const initial: RustDeskRelayCloudSyncState =
      this.cloud.rustDeskRelayCloudSyncInitialState();
    result.applyCloudSyncState(initial);
    if (onCloudState !== null) {
      onCloudState(initial, '');
    }
    if (initial === 'not_configured') { return; }
    void this.cloud.syncRelaysToCloudAsync()
      .then((outcome: RustDeskRelayCloudSyncOutcome): void => {
        result.applyCloudSyncState(
          outcome.state, outcome.failureKind);
        if (onCloudState !== null) {
          onCloudState(
            outcome.state, outcome.failureKind);
        }
      });
  }

  async retryRelayCloudSync(): Promise<RustDeskRelayCloudSyncOutcome> {
    return await this.cloud.syncRelaysToCloudAsync();
  }

  addRelayResult(
    relay: RustDeskRelayConfig,
    attemptId: string = ''
  ): RustDeskRelaySaveResult {
    const resolvedAttemptId: string = attemptId.trim().length > 0
      ? attemptId : this.nextRelaySaveAttemptId();
    if (!relay.id) { relay.id = RustDeskRelayConfig.generateId(); }
    if (relay.createdAt <= 0) { relay.createdAt = Date.now(); }
    if (!this.ready) {
      return RustDeskRelaySaveResult.fromMutation(
        resolvedAttemptId, relay.id,
        DataMutationResult.failure(
          relay.id, 'not_ready', '本地数据库正在准备，草稿已保留', 'waiting_gate'));
    }
    const previous: RustDeskRelayConfig | undefined =
      this.relays.get(relay.id);
    if (previous !== undefined) {
      if (!rustDeskRelayCreatePayloadMatches(
        previous, relay)) {
        return RustDeskRelaySaveResult.fromMutation(
          resolvedAttemptId, relay.id,
          DataMutationResult.failure(
            relay.id, 'invalid_data',
            '该草稿 ID 已被另一条服务器配置占用',
            'validating'));
      }
      const unchanged: RustDeskRelaySaveResult =
        RustDeskRelaySaveResult.fromMutation(
          resolvedAttemptId, relay.id,
          DataMutationResult.success(
            relay.id, 'unchanged'));
      unchanged.applyCloudSyncState(
        this.cloud.rustDeskRelayCloudSyncInitialState());
      return unchanged;
    }
    const mutation: DataMutationResult =
      this.cloud.upsertRelayResult(relay, resolvedAttemptId);
    return this.completeRelayMutation(
      relay, resolvedAttemptId, 'add',
      mutation, previous);
  }

  addRelay(relay: RustDeskRelayConfig): boolean {
    const result: RustDeskRelaySaveResult =
      this.addRelayResult(relay);
    this.observeRelayCloudSync(result);
    return result.ok;
  }

  async addRelayResultAsync(
    relay: RustDeskRelayConfig,
    attemptId: string = '',
    onStage:
      ((stage: DataMutationStage) => void) | null = null,
    onCloudState:
      ((state: RustDeskRelayCloudSyncState,
        failureKind: string) => void) | null = null
  ): Promise<RustDeskRelaySaveResult> {
    const resolvedAttemptId: string =
      attemptId.trim().length > 0
        ? attemptId : this.nextRelaySaveAttemptId();
    if (!relay.id) {
      relay.id = RustDeskRelayConfig.generateId();
    }
    if (relay.createdAt <= 0) {
      relay.createdAt = Date.now();
    }
    if (!this.ready) {
      return RustDeskRelaySaveResult.fromMutation(
        resolvedAttemptId, relay.id,
        DataMutationResult.failure(
          relay.id, 'not_ready',
          '本地数据库正在准备，草稿已保留',
          'waiting_gate'));
    }
    const previous: RustDeskRelayConfig | undefined =
      this.relays.get(relay.id);
    if (previous !== undefined) {
      if (!rustDeskRelayCreatePayloadMatches(
        previous, relay)) {
        return RustDeskRelaySaveResult.fromMutation(
          resolvedAttemptId, relay.id,
          DataMutationResult.failure(
            relay.id, 'invalid_data',
            '该草稿 ID 已被另一条服务器配置占用',
            'validating'));
      }
      const unchanged: RustDeskRelaySaveResult =
        RustDeskRelaySaveResult.fromMutation(
          resolvedAttemptId, relay.id,
          DataMutationResult.success(
            relay.id, 'unchanged'));
      this.observeRelayCloudSync(
        unchanged, onCloudState);
      return unchanged;
    }
    const mutation: DataMutationResult =
      await this.cloud.upsertRelayResultAsync(
        relay, resolvedAttemptId, onStage);
    const result: RustDeskRelaySaveResult =
      this.completeRelayMutation(
        relay, resolvedAttemptId, 'add',
        mutation, previous);
    this.observeRelayCloudSync(result, onCloudState);
    return result;
  }

  updateRelayResult(
    relay: RustDeskRelayConfig,
    attemptId: string = ''
  ): RustDeskRelaySaveResult {
    const resolvedAttemptId: string = attemptId.trim().length > 0
      ? attemptId : this.nextRelaySaveAttemptId();
    const previous: RustDeskRelayConfig | undefined =
      this.relays.get(relay.id);
    if (previous === undefined) {
      return RustDeskRelaySaveResult.fromMutation(
        resolvedAttemptId, relay.id,
        DataMutationResult.failure(
          relay.id, 'not_found', '要编辑的服务器已不存在，请重新载入列表',
          'waiting_gate'));
    }
    if (!this.ready) {
      return RustDeskRelaySaveResult.fromMutation(
        resolvedAttemptId, relay.id,
        DataMutationResult.failure(
          relay.id, 'not_ready', '本地数据库正在准备，草稿已保留', 'waiting_gate'));
    }
    const mutation: DataMutationResult =
      this.cloud.upsertRelayResult(relay, resolvedAttemptId);
    return this.completeRelayMutation(
      relay, resolvedAttemptId, 'update',
      mutation, previous);
  }

  updateRelay(relay: RustDeskRelayConfig): boolean {
    const result: RustDeskRelaySaveResult =
      this.updateRelayResult(relay);
    this.observeRelayCloudSync(result);
    return result.ok;
  }

  async updateRelayResultAsync(
    relay: RustDeskRelayConfig,
    attemptId: string = '',
    onStage:
      ((stage: DataMutationStage) => void) | null = null,
    onCloudState:
      ((state: RustDeskRelayCloudSyncState,
        failureKind: string) => void) | null = null
  ): Promise<RustDeskRelaySaveResult> {
    const resolvedAttemptId: string =
      attemptId.trim().length > 0
        ? attemptId : this.nextRelaySaveAttemptId();
    const previous: RustDeskRelayConfig | undefined =
      this.relays.get(relay.id);
    if (previous === undefined) {
      return RustDeskRelaySaveResult.fromMutation(
        resolvedAttemptId, relay.id,
        DataMutationResult.failure(
          relay.id, 'not_found',
          '要编辑的服务器已不存在，请重新载入列表',
          'waiting_gate'));
    }
    if (!this.ready) {
      return RustDeskRelaySaveResult.fromMutation(
        resolvedAttemptId, relay.id,
        DataMutationResult.failure(
          relay.id, 'not_ready',
          '本地数据库正在准备，草稿已保留',
          'waiting_gate'));
    }
    const mutation: DataMutationResult =
      await this.cloud.upsertRelayResultAsync(
        relay, resolvedAttemptId, onStage);
    const result: RustDeskRelaySaveResult =
      this.completeRelayMutation(
        relay, resolvedAttemptId, 'update',
        mutation, previous);
    this.observeRelayCloudSync(result, onCloudState);
    return result;
  }

  removeRelay(id: string): boolean {
    if (!this.relays.has(id)) { return false; }
    const affected: RemoteHost[] = [];
    let allReferencesDetached: boolean = true;
    this.hosts.forEach((h: RemoteHost): void => {
      if (h.rustdeskRelayId === id) {
        const next: RemoteHost = h.runtimeClone();
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
      RustDeskProCredentialStore.getInstance()
        .invalidateControlPlaneProofsForRelay(id);
      this.localRelayObservationAt.delete(id);
      this.deletedRelayAt.set(id, Date.now());
      this.emitDataChange();
    }
    return result;
  }
}
