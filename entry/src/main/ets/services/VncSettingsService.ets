import { common } from '@kit.AbilityKit';
import { AccountSessionCoordinator } from './AccountSessionCoordinator';
import { AccountSessionLease } from './AccountScopePolicy';
import { CloudStore } from './CloudStore';
import {
  CloudSyncCoordinator,
  CloudSyncOperationResult,
  ExclusiveSelectionCloudFirst
} from './CloudSyncCoordinator';
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
import {
  CloudSelectionReenablePhase,
  cloudSelectionTransitionNeedsCloudFirst
} from './CloudSelectionReenablePolicy';

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

  async save(
    next: VncSettingsValues
  ): Promise<VncSettingsSaveResult> {
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
    const executed: boolean =
      await CloudSyncCoordinator.getInstance()
        .runExclusiveVncSelectionMutation(
          async (
            lease: AccountSessionLease,
            cloudFirst:
              ExclusiveSelectionCloudFirst
          ): Promise<void> => {
            await this.saveWithinExclusive(
              normalized, result, lease,
              cloudFirst);
          });
    if (!executed && result.message === '') {
      result.message =
        'VNC 设置事务暂不可用，请等待当前云同步完成后重试';
    }
    return result;
  }

  private async saveWithinExclusive(
    normalized: VncSettingsValues,
    result: VncSettingsSaveResult,
    lease: AccountSessionLease,
    cloudFirst: ExclusiveSelectionCloudFirst
  ): Promise<void> {
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

    // The logical scope is a write boundary, not a UI-only preference. Apply
    // it before writing the settings row so disabling settings sync cannot
    // briefly upload the very row that turns the scope off. The cloud row is
    // never retracted by this transition; the owner remains local-only until
    // the scope is explicitly enabled again.
    const previousScopes: VncCloudSyncScope[] = this.sync.selectedScopes();
    const nextScopes: string[] = this.scopesFor(normalized);
    const selectionChanged: boolean = !this.sameScopes(previousScopes, nextScopes);
    const previousBarrier:
      CloudSelectionReenablePhase | null =
      this.cloud.selectionReenableBarrierPhase(
        VNC_CLOUD_TABLE);
    const needsCloudFirstBarrier: boolean =
      cloudSelectionTransitionNeedsCloudFirst(
        previousScopes, nextScopes,
        this.cloud.syncableTables().indexOf(
          VNC_CLOUD_TABLE) >= 0);
    if (needsCloudFirstBarrier &&
      !this.cloud
        .beginVncSelectionReenableTransaction(
          previousScopes, previousBarrier,
          record.id, lease)) {
      result.message =
        'VNC 同步范围事务建立失败，设置未修改';
      return;
    }
    if (selectionChanged &&
      !this.updateSyncSelection(
        normalized)) {
      const restored: boolean =
        needsCloudFirstBarrier
          ? await this.cloud
            .rollbackVncSelectionReenableTransaction(
              lease)
          : this.restoreSyncSelection(
            previousScopes, previousBarrier);
      result.message = 'VNC 同步选择保存失败，请检查本地数据状态后重试';
      if (!restored) {
        result.message +=
          '；事务恢复未完成，上传仍保持暂停';
      }
      return;
    }
    if (!this.cloud.upsertVncRecord(record)) {
      const mutationMessage: string =
        this.cloud.getLastMutationResult().message;
      const restored: boolean =
        needsCloudFirstBarrier
          ? await this.cloud
            .rollbackVncSelectionReenableTransaction(
              lease)
          : !selectionChanged ||
            this.restoreSyncSelection(
              previousScopes, previousBarrier);
      result.message = mutationMessage ||
        'VNC 设置保存失败';
      if (!restored) {
        result.message +=
          '；同步选择回滚未完成，上传仍保持暂停';
      }
      return;
    }
    if (needsCloudFirstBarrier) {
      const pulled: CloudSyncOperationResult =
        await cloudFirst(VNC_CLOUD_TABLE);
      const completed: CloudSyncOperationResult =
        await this.cloud
          .completeExclusiveVncSelectionCloudFirst(
            pulled, lease, true);
      if (!completed.ok) {
        if (!completed.rollbackFailed && !pulled.ok) {
          // Platform/table failure (e.g. AGC vncrecord missing primary key):
          // keep the already-persisted local scope selection, uploads stay
          // paused by the pending_pull barrier. Encryption and sync scope
          // remain the user's explicit choice, never app presumptions.
          this.values = normalized;
          result.ok = true;
          result.message =
            'VNC 同步范围已保存在本机；云端首次核对因平台错误未完成，上传保持暂停，请修复云端 vncrecord 表后重试';
          this.emitChange();
          return;
        }
        result.message =
          'VNC 同步范围的 cloud-first 核对未完成，设置未发布成功';
        if (completed.rollbackFailed) {
          result.message +=
            '；本地回滚未完整，上传仍保持暂停';
        }
        return;
      }
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
      return '普通云同步未勾选 vncrecord；VNC 数据仍保存在本机';
    }
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

  private updateSyncSelection(
    values: VncSettingsValues
  ): boolean {
    const scopes: string[] = this.scopesFor(values);
    // Stage first. The selector is not durable until the RDB projection has
    // completed, so a failed reconcile cannot leave a restart-time scope that
    // was never actually applied.
    this.sync.stageSelectedScopes(scopes);
    if (!this.cloud.reconcileVncSyncSelection() ||
      !this.sync.persistSelectedScopes()) {
      return false;
    }
    return true;
  }

  private restoreSyncSelection(
    scopes: VncCloudSyncScope[],
    previousBarrier:
      CloudSelectionReenablePhase | null,
    restoreBarrier: boolean = true
  ): boolean {
    this.sync.stageSelectedScopes(scopes);
    const projectionRestored: boolean =
      this.cloud.reconcileVncSyncSelection();
    const selectionRestored: boolean =
      this.sync.persistSelectedScopes();
    if (!projectionRestored ||
      !selectionRestored ||
      !restoreBarrier) {
      return false;
    }
    return this.cloud
      .restoreSelectionReenableBarrier(
        VNC_CLOUD_TABLE, previousBarrier);
  }

  private scopesFor(values: VncSettingsValues): string[] {
    const scopes: string[] = [];
    if (values.syncPreferences) { scopes.push('settings'); }
    if (values.syncHosts) { scopes.push('hosts'); }
    if (values.syncGateways) { scopes.push('gateways'); }
    if (values.syncSecrets) { scopes.push('secrets'); }
    if (values.syncTrust) { scopes.push('trust'); }
    return scopes;
  }

  private sameScopes(left: VncCloudSyncScope[], right: string[]): boolean {
    if (left.length !== right.length) { return false; }
    for (let i = 0; i < left.length; i++) {
      if (left[i] !== right[i]) { return false; }
    }
    return true;
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
