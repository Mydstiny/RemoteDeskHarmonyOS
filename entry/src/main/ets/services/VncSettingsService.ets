import { common } from '@kit.AbilityKit';
import { AccountSessionCoordinator } from './AccountSessionCoordinator';
import { CloudStore } from './CloudStore';
import { DataCrypto } from './DataCrypto';
import { VncRecord } from '../model/VncRecord';
import {
  VncSettingsValues,
  VncTransport,
  VncRepeaterMode,
  VncScalingMode,
  VncSecurityPolicy,
  VncDisplayScaleMode,
  VncImageQualityPreset,
  VncPreferredEncoding,
  VncColorDepth,
  VncLocalCursorMode,
  defaultVncSettings,
  validVncPort,
  vncSettingsPayload,
  finalizeVncRecord
} from './VncModelPolicy';
import { VncCloudSyncService } from './VncCloudSyncService';
import { VncCloudSyncScope } from './VncCloudSyncSelectionPolicy';
import { VNC_CLOUD_TABLE } from './VncRecordPolicy';
import { VncGatewayService, VncGatewayView } from './VncGatewayService';
import { isSelectableVncDefaultGateway, VncSelectableGateway } from './VncHostDefaultsPolicy';
import {
  PERSONALIZATION_DEFAULTS_FRESH_INSTALL_KEY,
  personalizationDefaults
} from './PersonalizationDefaultsPolicy';

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
  private userId: string = 'device-local';
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
      AccountSessionCoordinator.getInstance().onChange((): void => {
        this.userId = this.currentUserId();
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
    return AccountSessionCoordinator.getInstance().currentScope().ownerScopeId;
  }

  getUserId(): string { this.userId = this.currentUserId(); return this.userId; }

  get(): VncSettingsValues {
    const current: VncSettingsValues = this.values;
    return {
      defaultTransport: current.defaultTransport, defaultPort: current.defaultPort,
      connectTimeoutMs: current.connectTimeoutMs, authTimeoutMs: current.authTimeoutMs,
      firstFrameTimeoutMs: current.firstFrameTimeoutMs, viewOnly: current.viewOnly,
      controlMode: current.controlMode, showDiagnostics: current.showDiagnostics,
      scalingMode: current.scalingMode, displayScaleMode: current.displayScaleMode,
      customScalePercent: current.customScalePercent,
      imageQualityPreset: current.imageQualityPreset,
      preferredEncoding: current.preferredEncoding, colorDepth: current.colorDepth,
      frameRateLimit: current.frameRateLimit, jpegQuality: current.jpegQuality,
      localCursorMode: current.localCursorMode, touchpadSpeed: current.touchpadSpeed,
      reverseWheel: current.reverseWheel, swapMouseButtons: current.swapMouseButtons,
      diagnosticsExpanded: current.diagnosticsExpanded,
      diagnosticsRefreshMs: current.diagnosticsRefreshMs,
      diagnosticsMetricMask: current.diagnosticsMetricMask,
      clipboardEnabled: current.clipboardEnabled,
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

  /** Remove a deleted or disabled Gateway from the default connection draft. */
  async clearDefaultGatewayIf(gatewayId: string): Promise<boolean> {
    const normalizedId: string = gatewayId.trim();
    const current: VncSettingsValues = this.get();
    if (normalizedId === '' || current.defaultGatewayId.trim() !== normalizedId) {
      return true;
    }
    current.defaultGatewayId = '';
    current.defaultTransport = 'direct_tcp';
    const result: VncSettingsSaveResult = await this.save(current);
    return result.ok;
  }

  async save(
    next: VncSettingsValues
  ): Promise<VncSettingsSaveResult> {
    const result: VncSettingsSaveResult = { ok: false, message: '' };
    const normalized: VncSettingsValues = this.normalize(next);
    if (normalized.defaultTransport === 'ultravnc_repeater' &&
      !this.isSelectableDefaultGateway(normalized.defaultGatewayId)) {
      result.message = 'VNC Repeater 默认必须选择当前账号下已启用的 mode12 Gateway';
      return result;
    }
    if (!validVncPort(normalized.defaultPort)) {
      result.message = 'VNC 默认端口必须在 1-65535 之间';
      return result;
    }
    if (normalized.connectTimeoutMs < 1000 || normalized.authTimeoutMs < 1000 ||
      normalized.firstFrameTimeoutMs < 1000) {
      result.message = 'VNC 超时时间不能小于 1000ms';
      return result;
    }
    this.saveRecord(normalized, result);
    return result;
  }

  private saveRecord(
    normalized: VncSettingsValues,
    result: VncSettingsSaveResult
  ): void {
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
      const mutationMessage: string =
        this.cloud.getLastMutationResult().message;
      result.message = mutationMessage ||
        'VNC 设置保存失败';
      return;
    }
    this.values = normalized;
    result.ok = true;
    this.emitChange();
  }

  selectedScopes(): VncCloudSyncScope[] { return this.sync.selectedScopes(); }

  cryptoReady(): boolean { return DataCrypto.getInstance().isReady(); }

  cloudSyncStatus(): string {
    if (!this.cloud.isCloudAvailable()) { return '华为云空间不可用，VNC 数据仍保存在本机'; }
    if (this.cloud.syncableTables().indexOf(VNC_CLOUD_TABLE) < 0) {
      return '普通云同步未勾选 vncrecordv2；VNC 数据仍保存在本机';
    }
    return 'vncrecordv2 已启用：设置、主机、网关、加密机密与 trust 统一同步';
  }

  async manualUpload(): Promise<boolean> { return (await this.sync.requestManualUpload()).ok; }

  async manualDownload(): Promise<boolean> { return (await this.sync.requestManualDownload()).ok; }

  private isSelectableDefaultGateway(gatewayId: string): boolean {
    const normalizedId: string = gatewayId.trim();
    if (normalizedId === '') { return false; }
    const gateway: VncGatewayView | null = VncGatewayService.getInstance().find(normalizedId);
    if (gateway === null) { return false; }
    const selectable: VncSelectableGateway = {
      id: gateway.id, userId: gateway.userId, transport: gateway.transport,
      repeaterMode: gateway.repeaterMode, enabled: gateway.enabled
    };
    return isSelectableVncDefaultGateway(selectable, this.getUserId());
  }

  private load(): void {
    const record: VncRecord | null = this.settingsRecord();
    if (record === null) {
      const freshInstall: boolean =
        AppStorage.get<boolean>(PERSONALIZATION_DEFAULTS_FRESH_INSTALL_KEY) ?? false;
      const isDesktopDevice: boolean = AppStorage.get<boolean>('isDesktopDevice') ?? false;
      this.values = defaultVncSettings(
        personalizationDefaults(freshInstall, isDesktopDevice).vncControlMode);
      return;
    }
    this.values = this.parsePayload(record.payload);
  }

  private settingsRecord(): VncRecord | null {
    const records: VncRecord[] = this.cloud.loadVncRecords(this.getUserId());
    for (let i = 0; i < records.length; i++) {
      if (records[i].recordType === 'settings' && records[i].deletedAt <= 0) { return records[i]; }
    }
    return null;
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
      controlMode: Number.isFinite(values.controlMode) ? Math.max(0, Math.min(2, Math.floor(values.controlMode))) : defaults.controlMode,
      showDiagnostics: values.showDiagnostics === true,
      scalingMode: values.scalingMode || defaults.scalingMode,
      displayScaleMode: values.displayScaleMode === '100' || values.displayScaleMode === 'integer' ||
        values.displayScaleMode === 'custom' ? values.displayScaleMode : 'fit',
      customScalePercent: Number.isFinite(values.customScalePercent) ?
        Math.max(50, Math.min(300, Math.floor(values.customScalePercent))) : defaults.customScalePercent,
      imageQualityPreset: values.imageQualityPreset === 'speed' ||
        values.imageQualityPreset === 'quality' ?
        values.imageQualityPreset : 'balanced',
      preferredEncoding: values.preferredEncoding === 'raw' ||
        values.preferredEncoding === 'zrle' ? values.preferredEncoding : 'auto',
      colorDepth: values.colorDepth === '32' || values.colorDepth === '16' ||
        values.colorDepth === '8' ? values.colorDepth : 'auto',
      frameRateLimit: values.frameRateLimit === 0 || values.frameRateLimit === 15 ||
        values.frameRateLimit === 60 ? values.frameRateLimit : 30,
      jpegQuality: Number.isFinite(values.jpegQuality) ?
        Math.max(0, Math.min(9, Math.floor(values.jpegQuality))) : defaults.jpegQuality,
      localCursorMode: values.localCursorMode === 'arrow' || values.localCursorMode === 'circle' ||
        values.localCursorMode === 'hidden' ? values.localCursorMode : 'auto',
      touchpadSpeed: Number.isFinite(values.touchpadSpeed) ?
        Math.max(50, Math.min(200, Math.floor(values.touchpadSpeed))) : defaults.touchpadSpeed,
      reverseWheel: values.reverseWheel === true,
      swapMouseButtons: values.swapMouseButtons === true,
      diagnosticsExpanded: values.diagnosticsExpanded === true,
      diagnosticsRefreshMs: values.diagnosticsRefreshMs === 250 ||
        values.diagnosticsRefreshMs === 1000 ? values.diagnosticsRefreshMs : 500,
      diagnosticsMetricMask: Number.isFinite(values.diagnosticsMetricMask) ?
        Math.max(0, Math.min(65535, Math.floor(values.diagnosticsMetricMask))) :
        defaults.diagnosticsMetricMask,
      clipboardEnabled: values.clipboardEnabled,
      securityPolicy: values.securityPolicy || defaults.securityPolicy,
      defaultGatewayId: values.defaultGatewayId || '',
      repeaterMode: values.repeaterMode || defaults.repeaterMode,
      // Preserve the payload fields for older builds, but publish the unified
      // physical-table contract so a legacy client never interprets a partial
      // 1.1.1 record as disabled data.
      syncPreferences: true,
      syncHosts: true,
      syncGateways: true,
      syncSecrets: true,
      syncTrust: true
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
      if (typeof values['controlMode'] === 'number') { result.controlMode = values['controlMode'] as number; }
      if (typeof values['showDiagnostics'] === 'boolean') { result.showDiagnostics = values['showDiagnostics'] as boolean; }
      if (typeof values['scalingMode'] === 'string') { result.scalingMode = values['scalingMode'] as VncScalingMode; }
      if (typeof values['displayScaleMode'] === 'string') {
        result.displayScaleMode = values['displayScaleMode'] as VncDisplayScaleMode;
      } else {
        result.displayScaleMode = result.scalingMode === 'one_to_one' ||
          result.scalingMode === 'pan' ? '100' :
          (result.scalingMode === 'integer' ? 'integer' : 'fit');
      }
      if (typeof values['customScalePercent'] === 'number') {
        result.customScalePercent = values['customScalePercent'] as number;
      }
      if (typeof values['imageQualityPreset'] === 'string') {
        result.imageQualityPreset = values['imageQualityPreset'] as VncImageQualityPreset;
      }
      if (typeof values['preferredEncoding'] === 'string') {
        result.preferredEncoding = values['preferredEncoding'] as VncPreferredEncoding;
      }
      if (typeof values['colorDepth'] === 'string') {
        result.colorDepth = values['colorDepth'] as VncColorDepth;
      }
      if (typeof values['frameRateLimit'] === 'number') {
        result.frameRateLimit = values['frameRateLimit'] as number;
      }
      if (typeof values['jpegQuality'] === 'number') {
        result.jpegQuality = values['jpegQuality'] as number;
      }
      if (typeof values['localCursorMode'] === 'string') {
        result.localCursorMode = values['localCursorMode'] as VncLocalCursorMode;
      }
      if (typeof values['touchpadSpeed'] === 'number') {
        result.touchpadSpeed = values['touchpadSpeed'] as number;
      }
      if (typeof values['reverseWheel'] === 'boolean') {
        result.reverseWheel = values['reverseWheel'] as boolean;
      }
      if (typeof values['swapMouseButtons'] === 'boolean') {
        result.swapMouseButtons = values['swapMouseButtons'] as boolean;
      }
      if (typeof values['diagnosticsExpanded'] === 'boolean') {
        result.diagnosticsExpanded = values['diagnosticsExpanded'] as boolean;
      }
      if (typeof values['diagnosticsRefreshMs'] === 'number') {
        result.diagnosticsRefreshMs = values['diagnosticsRefreshMs'] as number;
      }
      if (typeof values['diagnosticsMetricMask'] === 'number') {
        result.diagnosticsMetricMask = values['diagnosticsMetricMask'] as number;
      }
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
      controlMode: values.controlMode, showDiagnostics: values.showDiagnostics,
      scalingMode: values.scalingMode, displayScaleMode: values.displayScaleMode,
      customScalePercent: values.customScalePercent,
      imageQualityPreset: values.imageQualityPreset,
      preferredEncoding: values.preferredEncoding, colorDepth: values.colorDepth,
      frameRateLimit: values.frameRateLimit, jpegQuality: values.jpegQuality,
      localCursorMode: values.localCursorMode, touchpadSpeed: values.touchpadSpeed,
      reverseWheel: values.reverseWheel, swapMouseButtons: values.swapMouseButtons,
      diagnosticsExpanded: values.diagnosticsExpanded,
      diagnosticsRefreshMs: values.diagnosticsRefreshMs,
      diagnosticsMetricMask: values.diagnosticsMetricMask,
      clipboardEnabled: values.clipboardEnabled,
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
