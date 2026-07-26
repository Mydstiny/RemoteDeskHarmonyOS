import { common } from '@kit.AbilityKit';
import { AuthService } from './AuthService';
import { CloudStore } from './CloudStore';
import { DataCrypto } from './DataCrypto';
import { VncRecord } from '../model/VncRecord';
import {
  VncSettingsValues,
  VncTransport,
  VncRepeaterMode,
  VncScalingMode,
  VncSecurityPolicy,
  defaultVncSettings,
  validVncPort,
  vncSettingsPayload,
  finalizeVncRecord
} from './VncModelPolicy';
import { VncCloudSyncService } from './VncCloudSyncService';
import { VncCloudSyncScope } from './VncCloudSyncSelectionPolicy';

export interface VncSettingsSaveResult {
  ok: boolean;
  message: string;
}

/** Owns only RemoteDesktopVncPrefs plus the VNC settings logical record. */
export class VncSettingsService {
  private static instance: VncSettingsService;
  private readonly cloud: CloudStore = CloudStore.getInstance();
  private readonly sync: VncCloudSyncService = VncCloudSyncService.getInstance();
  private values: VncSettingsValues = defaultVncSettings();
  private userId: string = 'local';
  private initialized: boolean = false;
  private listenerBound: boolean = false;
  private listeners: Array<() => void> = [];

  static getInstance(): VncSettingsService {
    if (!VncSettingsService.instance) { VncSettingsService.instance = new VncSettingsService(); }
    return VncSettingsService.instance;
  }

  init(context: common.Context): void {
    this.userId = this.currentUserId();
    this.sync.init(context);
    if (!this.listenerBound) {
      this.listenerBound = true;
      this.cloud.onCloudChange((): void => {
        this.load();
        this.emitChange();
      });
      DataCrypto.getInstance().onStateChange((_ready: boolean, _configured: boolean): void => {
        this.emitChange();
      });
    }
    this.initialized = true;
    this.load();
  }

  isReady(): boolean { return this.initialized && this.cloud.isReady(); }

  currentUserId(): string {
    const unionId: string = AuthService.getInstance().getUnionId();
    return unionId.trim() === '' ? 'local' : unionId.trim();
  }

  getUserId(): string { this.userId = this.currentUserId(); return this.userId; }

  get(): VncSettingsValues {
    const current: VncSettingsValues = this.values;
    return {
      defaultTransport: current.defaultTransport, defaultPort: current.defaultPort,
      connectTimeoutMs: current.connectTimeoutMs, authTimeoutMs: current.authTimeoutMs,
      firstFrameTimeoutMs: current.firstFrameTimeoutMs, viewOnly: current.viewOnly,
      scalingMode: current.scalingMode, clipboardEnabled: current.clipboardEnabled,
      securityPolicy: current.securityPolicy, defaultGatewayId: current.defaultGatewayId,
      repeaterMode: current.repeaterMode, syncPreferences: current.syncPreferences,
      syncHosts: current.syncHosts, syncGateways: current.syncGateways,
      syncSecrets: current.syncSecrets, syncTrust: current.syncTrust
    };
  }

  onChange(listener: () => void): () => void {
    if (this.listeners.indexOf(listener) < 0) { this.listeners.push(listener); }
    return (): void => {
      const index: number = this.listeners.indexOf(listener);
      if (index >= 0) { this.listeners.splice(index, 1); }
    };
  }

  save(next: VncSettingsValues): VncSettingsSaveResult {
    const result: VncSettingsSaveResult = { ok: false, message: '' };
    const normalized: VncSettingsValues = this.normalize(next);
    if (!validVncPort(normalized.defaultPort)) {
      result.message = 'VNC 默认端口必须在 1-65535 之间';
      return result;
    }
    if (normalized.connectTimeoutMs < 1000 || normalized.authTimeoutMs < 1000 ||
      normalized.firstFrameTimeoutMs < 1000) {
      result.message = 'VNC 超时时间不能小于 1000ms';
      return result;
    }
    const current: VncRecord | null = this.settingsRecord();
    const record: VncRecord = new VncRecord();
    const now: number = Date.now();
    record.id = current === null ? 'vncsettings_' + this.getUserId() : current.id;
    record.userId = this.getUserId();
    record.recordType = 'settings';
    record.ownerId = record.userId;
    record.ownerType = 'account';
    record.secretKind = '';
    record.payload = vncSettingsPayload(normalized);
    record.createdAt = current === null ? now : current.createdAt;
    record.updatedAt = now;
    record.syncVersion = current === null ? 1 : current.syncVersion + 1;
    finalizeVncRecord(record);
    if (!this.cloud.upsertVncRecord(record)) {
      result.message = this.cloud.getLastMutationResult().message || 'VNC 设置保存失败';
      return result;
    }
    this.values = normalized;
    this.updateSyncSelection(normalized);
    result.ok = true;
    this.emitChange();
    return result;
  }

  selectedScopes(): VncCloudSyncScope[] { return this.sync.selectedScopes(); }

  cryptoReady(): boolean { return DataCrypto.getInstance().isReady(); }

  cloudSyncStatus(): string {
    if (!this.cloud.isCloudAvailable()) { return '华为云空间不可用，VNC 数据仍保存在本机'; }
    const scopes: VncCloudSyncScope[] = this.sync.selectedScopes();
    return scopes.length === 0 ? 'VNC 云同步已关闭' : '已选择 ' + scopes.length.toString() + ' 类 VNC 数据同步';
  }

  async manualUpload(): Promise<boolean> { return (await this.sync.requestManualUpload()).ok; }

  async manualDownload(): Promise<boolean> { return (await this.sync.requestManualDownload()).ok; }

  private load(): void {
    const record: VncRecord | null = this.settingsRecord();
    if (record === null) { this.values = defaultVncSettings(); return; }
    this.values = this.parsePayload(record.payload);
  }

  private settingsRecord(): VncRecord | null {
    const records: VncRecord[] = this.cloud.loadVncRecords(this.getUserId());
    for (let i = 0; i < records.length; i++) {
      if (records[i].recordType === 'settings' && records[i].deletedAt <= 0) { return records[i]; }
    }
    return null;
  }

  private updateSyncSelection(values: VncSettingsValues): void {
    const scopes: string[] = [];
    if (values.syncPreferences) { scopes.push('settings'); }
    if (values.syncHosts) { scopes.push('hosts'); }
    if (values.syncGateways) { scopes.push('gateways'); }
    if (values.syncSecrets) { scopes.push('secrets'); }
    if (values.syncTrust) { scopes.push('trust'); }
    if (!this.sync.replaceSelectedScopes(scopes)) { return; }
    if (!this.cloud.reconcileVncSyncSelection()) { return; }
    // A scope can be turned off after its mirror was already uploaded. The
    // reconciliation keeps the local owner and leaves the shared cloud row
    // untouched; only an explicitly selected scope is uploaded.
    void this.sync.requestSelectionReconcile();
  }

  private normalize(values: VncSettingsValues): VncSettingsValues {
    const defaults = defaultVncSettings();
    return {
      defaultTransport: values.defaultTransport || defaults.defaultTransport,
      defaultPort: Number.isFinite(values.defaultPort) ? Math.floor(values.defaultPort) : defaults.defaultPort,
      connectTimeoutMs: Number.isFinite(values.connectTimeoutMs) ? Math.floor(values.connectTimeoutMs) : defaults.connectTimeoutMs,
      authTimeoutMs: Number.isFinite(values.authTimeoutMs) ? Math.floor(values.authTimeoutMs) : defaults.authTimeoutMs,
      firstFrameTimeoutMs: Number.isFinite(values.firstFrameTimeoutMs) ? Math.floor(values.firstFrameTimeoutMs) : defaults.firstFrameTimeoutMs,
      viewOnly: values.viewOnly,
      scalingMode: values.scalingMode || defaults.scalingMode,
      clipboardEnabled: values.clipboardEnabled,
      securityPolicy: values.securityPolicy || defaults.securityPolicy,
      defaultGatewayId: values.defaultGatewayId || '',
      repeaterMode: values.repeaterMode || defaults.repeaterMode,
      syncPreferences: values.syncPreferences,
      syncHosts: values.syncHosts,
      syncGateways: values.syncGateways,
      syncSecrets: values.syncSecrets,
      syncTrust: values.syncTrust
    };
  }

  private parsePayload(payload: string): VncSettingsValues {
    const defaults = defaultVncSettings();
    const result: VncSettingsValues = this.getDefaultCopy(defaults);
    try {
      const parsed: Object = JSON.parse(payload) as Object;
      const values: Record<string, Object> = parsed as Record<string, Object>;
      if (typeof values['defaultTransport'] === 'string') { result.defaultTransport = values['defaultTransport'] as VncTransport; }
      if (typeof values['defaultPort'] === 'number') { result.defaultPort = values['defaultPort'] as number; }
      if (typeof values['connectTimeoutMs'] === 'number') { result.connectTimeoutMs = values['connectTimeoutMs'] as number; }
      if (typeof values['authTimeoutMs'] === 'number') { result.authTimeoutMs = values['authTimeoutMs'] as number; }
      if (typeof values['firstFrameTimeoutMs'] === 'number') { result.firstFrameTimeoutMs = values['firstFrameTimeoutMs'] as number; }
      if (typeof values['viewOnly'] === 'boolean') { result.viewOnly = values['viewOnly'] as boolean; }
      if (typeof values['scalingMode'] === 'string') { result.scalingMode = values['scalingMode'] as VncScalingMode; }
      if (typeof values['clipboardEnabled'] === 'boolean') { result.clipboardEnabled = values['clipboardEnabled'] as boolean; }
      if (typeof values['securityPolicy'] === 'string') { result.securityPolicy = values['securityPolicy'] as VncSecurityPolicy; }
      if (typeof values['defaultGatewayId'] === 'string') { result.defaultGatewayId = values['defaultGatewayId'] as string; }
      if (typeof values['repeaterMode'] === 'string') { result.repeaterMode = values['repeaterMode'] as VncRepeaterMode; }
      if (typeof values['syncPreferences'] === 'boolean') { result.syncPreferences = values['syncPreferences'] as boolean; }
      if (typeof values['syncHosts'] === 'boolean') { result.syncHosts = values['syncHosts'] as boolean; }
      if (typeof values['syncGateways'] === 'boolean') { result.syncGateways = values['syncGateways'] as boolean; }
      if (typeof values['syncSecrets'] === 'boolean') { result.syncSecrets = values['syncSecrets'] as boolean; }
      if (typeof values['syncTrust'] === 'boolean') { result.syncTrust = values['syncTrust'] as boolean; }
    } catch (_e) {}
    return this.normalize(result);
  }

  private getDefaultCopy(values: VncSettingsValues): VncSettingsValues {
    return {
      defaultTransport: values.defaultTransport, defaultPort: values.defaultPort,
      connectTimeoutMs: values.connectTimeoutMs, authTimeoutMs: values.authTimeoutMs,
      firstFrameTimeoutMs: values.firstFrameTimeoutMs, viewOnly: values.viewOnly,
      scalingMode: values.scalingMode, clipboardEnabled: values.clipboardEnabled,
      securityPolicy: values.securityPolicy, defaultGatewayId: values.defaultGatewayId,
      repeaterMode: values.repeaterMode, syncPreferences: values.syncPreferences,
      syncHosts: values.syncHosts, syncGateways: values.syncGateways,
      syncSecrets: values.syncSecrets, syncTrust: values.syncTrust
    };
  }

  private emitChange(): void {
    const callbacks: Array<() => void> = this.listeners.slice();
    for (let i = 0; i < callbacks.length; i++) { try { callbacks[i](); } catch (_e) {} }
  }
}
