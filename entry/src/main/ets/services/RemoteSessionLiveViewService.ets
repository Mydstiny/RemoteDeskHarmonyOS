/**
 * RemoteSessionLiveViewService — 远程会话后台展示统一服务
 *
 * 提供两种后台展示策略:
 * - AVSession: 有真实音视频时注册系统媒体身份/播控胶囊
 * - Notification: 使用系统允许的普通后台通知
 *
 * 实际视频帧由 RemoteSessionPipService 承载；AVSession 和正式 Live View
 * Kit 都不会把远程桌面帧自动绘制到系统胶囊中。
 *
 * 通过 AppStorage key 'liveViewEnabled' / 'liveViewMode' 在运行时切换.
 * 模式: 0=关闭, 1=AVSession, 2=后台通知
 */
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LiveViewMode, LiveViewConnectionInfo, LiveViewStrategy } from './LiveViewTypes';
import { AvSessionLiveViewStrategy } from './AvSessionLiveViewStrategy';
import { NotificationLiveViewStrategy } from './NotificationLiveViewStrategy';
import {
  RemoteSessionLiveViewDelivery,
  resolveRemoteSessionLiveViewDelivery
} from './RemoteSessionLiveViewPolicy';
import {
  RemoteSessionMediaKind,
  resolveRemoteSessionMediaKind,
  shouldRestartLiveViewForMediaChange
} from './RemoteSessionMediaStatePolicy';
import {
  RemoteSessionServiceLease,
  RemoteSessionServiceProtocol,
  cloneRemoteSessionServiceLease,
  remoteSessionServiceLeaseCanClaim,
  remoteSessionServiceLeaseEquals,
  remoteSessionServiceLeaseIsValid,
  remoteSessionServiceLeaseMatchesSession
} from './RemoteSessionServiceLeasePolicy';

const TAG = 'LiveViewService';
const DOMAIN = 0x0015;

// 重新导出类型供外部使用 (兼容旧导入路径)
export { LiveViewMode, LiveViewConnectionInfo, LiveViewStrategy } from './LiveViewTypes';

export class RemoteSessionLiveViewService {
  private static instance: RemoteSessionLiveViewService | null = null;
  private avSessionStrategy: AvSessionLiveViewStrategy | null = null;
  private notificationStrategy: NotificationLiveViewStrategy | null = null;
  private activeStrategy: LiveViewStrategy | null = null;
  private currentMode: LiveViewMode = LiveViewMode.OFF;
  private currentMediaKind: number = RemoteSessionMediaKind.NONE;
  private currentHasAudio: boolean = false;
  private currentHasVideo: boolean = false;
  private lastInfo: LiveViewConnectionInfo | null = null;
  private currentLease: RemoteSessionServiceLease | null = null;
  private currentContext: common.UIAbilityContext | null = null;
  private operationGeneration: number = 0;
  private operationTail: Promise<void> = Promise.resolve();

  static getInstance(): RemoteSessionLiveViewService {
    if (RemoteSessionLiveViewService.instance === null) {
      RemoteSessionLiveViewService.instance = new RemoteSessionLiveViewService();
    }
    return RemoteSessionLiveViewService.instance;
  }

  /**
   * 连接建立或切后台时调用 — 启实况窗。
   * 根据当前设置的模式自动选择策略。
   * @returns true only after a strategy has actually started.
   */
  async start(context: common.UIAbilityContext,
    info: LiveViewConnectionInfo,
    lease: RemoteSessionServiceLease): Promise<boolean> {
    if (!remoteSessionServiceLeaseIsValid(lease)) { return false; }
    const captured: RemoteSessionServiceLease = cloneRemoteSessionServiceLease(lease);
    return this.enqueueOperation<boolean>(() => this.startInternal(context, info, captured));
  }

  private async startInternal(context: common.UIAbilityContext,
    info: LiveViewConnectionInfo,
    lease: RemoteSessionServiceLease): Promise<boolean> {
    if (!this.claimLease(lease)) {
      hilog.warn(DOMAIN, TAG, '[LIVE-VIEW-LEASE] start rejected for non-owner');
      return false;
    }
    this.currentContext = context;
    const generation: number = ++this.operationGeneration;
    const enabled: boolean = AppStorage.get<boolean>('liveViewEnabled') ?? true;
    if (!enabled) {
      hilog.info(DOMAIN, TAG, 'liveView disabled, skip start');
      this.resetState(true);
      return false;
    }

    // 如果已有活跃策略, 先停掉
    if (this.activeStrategy !== null) {
      const previous: LiveViewStrategy = this.activeStrategy;
      await this.stopStrategy(context, previous);
      if (!this.operationIsCurrent(generation, lease)) { return false; }
      if (this.activeStrategy === previous) { this.clearPresentationState(); }
    }

    const normalizedInfo: LiveViewConnectionInfo = this.normalizeInfo(info);
    const mode: number = AppStorage.get<number>('liveViewMode') ?? LiveViewMode.AVSESSION;
    const delivery: RemoteSessionLiveViewDelivery = resolveRemoteSessionLiveViewDelivery(
      enabled,
      mode,
      normalizedInfo.hasAudio,
      normalizedInfo.hasVideo === true
    );
    this.currentMode = this.liveViewModeForDelivery(delivery);
    this.lastInfo = normalizedInfo;

    try {
      if (delivery === RemoteSessionLiveViewDelivery.AVSESSION) {
        if (this.avSessionStrategy === null) {
          this.avSessionStrategy = new AvSessionLiveViewStrategy();
        }
        try {
          await this.avSessionStrategy.start(context, normalizedInfo);
          if (!this.operationIsCurrent(generation, lease)) {
            await this.stopStrategy(context, this.avSessionStrategy);
            return false;
          }
          this.activeStrategy = this.avSessionStrategy;
        } catch (err) {
          if (!this.operationIsCurrent(generation, lease)) { return false; }
          hilog.warn(DOMAIN, TAG, '[LIVE-VIEW-AVSESSION-FALLBACK] start failed, using notification: ' +
            JSON.stringify(err));
          if (this.notificationStrategy === null) {
            this.notificationStrategy = new NotificationLiveViewStrategy();
          }
          await this.notificationStrategy.start(context, normalizedInfo);
          if (!this.operationIsCurrent(generation, lease)) {
            await this.stopStrategy(context, this.notificationStrategy);
            return false;
          }
          this.currentMode = LiveViewMode.NOTIFICATION;
          this.activeStrategy = this.notificationStrategy;
        }
      } else if (delivery === RemoteSessionLiveViewDelivery.BACKGROUND_NOTIFICATION) {
        if (this.notificationStrategy === null) {
          this.notificationStrategy = new NotificationLiveViewStrategy();
        }
        await this.notificationStrategy.start(context, normalizedInfo);
        if (!this.operationIsCurrent(generation, lease)) {
          await this.stopStrategy(context, this.notificationStrategy);
          return false;
        }
        this.activeStrategy = this.notificationStrategy;
      } else {
        hilog.info(DOMAIN, TAG, 'liveView mode is OFF, skip');
        this.resetState(true);
        return false;
      }

      this.currentMediaKind = normalizedInfo.mediaKind ?? RemoteSessionMediaKind.NONE;
      this.currentHasAudio = normalizedInfo.hasAudio;
      this.currentHasVideo = normalizedInfo.hasVideo === true;
      hilog.info(DOMAIN, TAG, 'liveView started mode=' + this.currentMode.toString() +
        ' kind=' + this.currentMediaKind.toString() +
        ' protocol=' + normalizedInfo.protocolLabel);
      return true;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '[LIVE-VIEW-START] failed mode=' + this.currentMode.toString() +
        ' code=' + JSON.stringify(err));
      if (this.operationIsCurrent(generation, lease)) { this.resetState(true); }
      return false;
    }
  }

  async reconcile(context: common.UIAbilityContext,
    info: LiveViewConnectionInfo,
    lease: RemoteSessionServiceLease): Promise<boolean> {
    if (!remoteSessionServiceLeaseIsValid(lease)) { return false; }
    const captured: RemoteSessionServiceLease = cloneRemoteSessionServiceLease(lease);
    return this.enqueueOperation<boolean>(() => this.reconcileInternal(context, info, captured));
  }

  private async reconcileInternal(context: common.UIAbilityContext,
    info: LiveViewConnectionInfo,
    lease: RemoteSessionServiceLease): Promise<boolean> {
    if (!this.claimLease(lease)) {
      hilog.warn(DOMAIN, TAG, '[LIVE-VIEW-LEASE] reconcile rejected for non-owner');
      return false;
    }
    this.currentContext = context;
    const enabled: boolean = AppStorage.get<boolean>('liveViewEnabled') ?? true;
    if (!enabled) {
      await this.stopInternal(context, lease, false);
      return false;
    }

    const normalizedInfo: LiveViewConnectionInfo = this.normalizeInfo(info);
    const preferredMode: number = AppStorage.get<number>('liveViewMode') ?? LiveViewMode.AVSESSION;
    const nextDelivery: RemoteSessionLiveViewDelivery = resolveRemoteSessionLiveViewDelivery(
      enabled,
      preferredMode,
      normalizedInfo.hasAudio,
      normalizedInfo.hasVideo === true
    );
    const nextMode: LiveViewMode = this.liveViewModeForDelivery(nextDelivery);
    const nextMediaKind: number = normalizedInfo.mediaKind ?? RemoteSessionMediaKind.NONE;
    const modeChanged: boolean = nextMode !== this.currentMode;
    const mediaRestartRequired: boolean = shouldRestartLiveViewForMediaChange(
      this.currentMode,
      this.currentMediaKind,
      nextMode,
      nextMediaKind as RemoteSessionMediaKind
    );
    if (this.activeStrategy === null || modeChanged || mediaRestartRequired) {
      return await this.startInternal(context, normalizedInfo, lease);
    }

    const generation: number = ++this.operationGeneration;
    const strategy: LiveViewStrategy = this.activeStrategy;
    try {
      await strategy.update(normalizedInfo);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '[LIVE-VIEW-UPDATE] failed: ' + JSON.stringify(err));
      return false;
    }
    if (!this.operationIsCurrent(generation, lease) || this.activeStrategy !== strategy) {
      return false;
    }
    this.lastInfo = normalizedInfo;
    this.currentMediaKind = nextMediaKind;
    this.currentHasAudio = normalizedInfo.hasAudio;
    this.currentHasVideo = normalizedInfo.hasVideo === true;
    return true;
  }

  /**
   * 连接状态更新时调用 (如音频状态变化)。
   */
  async update(info: LiveViewConnectionInfo,
    lease: RemoteSessionServiceLease): Promise<boolean> {
    if (!remoteSessionServiceLeaseIsValid(lease)) { return false; }
    const captured: RemoteSessionServiceLease = cloneRemoteSessionServiceLease(lease);
    return this.enqueueOperation<boolean>(async (): Promise<boolean> => {
      if (!remoteSessionServiceLeaseEquals(this.currentLease, captured) ||
          this.activeStrategy === null) { return false; }
      const generation: number = ++this.operationGeneration;
      const strategy: LiveViewStrategy = this.activeStrategy;
      const normalizedInfo: LiveViewConnectionInfo = this.normalizeInfo(info);
      try {
        await strategy.update(normalizedInfo);
      } catch (err) {
        hilog.warn(DOMAIN, TAG, '[LIVE-VIEW-UPDATE] failed: ' + JSON.stringify(err));
        return false;
      }
      if (!this.operationIsCurrent(generation, captured) ||
          this.activeStrategy !== strategy) { return false; }
      this.lastInfo = normalizedInfo;
      this.currentMediaKind = normalizedInfo.mediaKind ?? RemoteSessionMediaKind.NONE;
      this.currentHasAudio = normalizedInfo.hasAudio;
      this.currentHasVideo = normalizedInfo.hasVideo === true;
      return true;
    });
  }

  /**
   * 前台恢复或断连时调用 — 移除实况窗。
   */
  async stop(context: common.UIAbilityContext,
    lease?: RemoteSessionServiceLease): Promise<void> {
    const captured: RemoteSessionServiceLease | null = lease === undefined ? null :
      cloneRemoteSessionServiceLease(lease);
    if (captured !== null && !remoteSessionServiceLeaseEquals(this.currentLease, captured)) {
      return;
    }
    // Invalidate an in-flight start/update before this stop reaches the
    // serialized strategy operation queue.
    this.operationGeneration += 1;
    await this.enqueueOperation<void>(() => this.stopInternal(context, captured, captured === null));
  }

  /** Snapshot the exact predecessor owner for a registry restore CAS. */
  leaseForMatchingSession(protocol: RemoteSessionServiceProtocol,
    hostId: string, sessionId: number): RemoteSessionServiceLease | null {
    if (!remoteSessionServiceLeaseMatchesSession(
        this.currentLease, protocol, hostId, sessionId)) {
      return null;
    }
    return cloneRemoteSessionServiceLease(
      this.currentLease as RemoteSessionServiceLease);
  }

  /**
   * A disappearing page may no longer expose a UIContext. The service retains
   * only the context of its exact active lease so that owner cleanup can still
   * remove AVSession/notification state without a global stop.
   */
  async stopOwned(lease: RemoteSessionServiceLease): Promise<void> {
    const captured: RemoteSessionServiceLease = cloneRemoteSessionServiceLease(lease);
    if (!remoteSessionServiceLeaseEquals(this.currentLease, captured) ||
        this.currentContext === null) {
      return;
    }
    await this.stop(this.currentContext, captured);
  }

  private async stopInternal(context: common.UIAbilityContext,
    lease: RemoteSessionServiceLease | null, force: boolean): Promise<void> {
    if (!force && !remoteSessionServiceLeaseEquals(this.currentLease, lease)) { return; }
    const strategy: LiveViewStrategy | null = this.activeStrategy;
    if (strategy === null) {
      if (force || remoteSessionServiceLeaseEquals(this.currentLease, lease)) {
        this.resetState(true);
      }
      return;
    }
    try {
      await strategy.stop(context);
      hilog.info(DOMAIN, TAG, 'liveView stopped mode=' + this.currentMode.toString());
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '[LIVE-VIEW-STOP] failed: ' + JSON.stringify(err));
    } finally {
      if (this.activeStrategy === strategy &&
        (force || remoteSessionServiceLeaseEquals(this.currentLease, lease))) {
        this.resetState(true);
      }
    }
  }

  /**
   * 检查实况窗当前是否活跃。
   */
  isActive(lease: RemoteSessionServiceLease): boolean {
    return this.activeStrategy !== null &&
      remoteSessionServiceLeaseEquals(this.currentLease, lease);
  }

  /**
   * 设置静音控制回调 (仅 AVSession 策略有效)。
   * 由 RemoteDesktop 在启动实况窗后注入原生静音实现。
   * @param callback mute=true→静音, mute=false→取消静音
   */
  setMuteCommandCallback(callback: (mute: boolean) => void,
    lease: RemoteSessionServiceLease): void {
    if (!remoteSessionServiceLeaseEquals(this.currentLease, lease)) { return; }
    if (this.currentMode === LiveViewMode.AVSESSION &&
      this.currentHasAudio &&
      this.avSessionStrategy !== null) {
      this.avSessionStrategy.setMuteCommandHandler(callback);
      hilog.info(DOMAIN, TAG, 'mute command callback registered for AVSession strategy');
    }
  }

  private normalizeInfo(info: LiveViewConnectionInfo): LiveViewConnectionInfo {
    const hasVideo: boolean = info.hasVideo === true;
    const mediaKind: number = hasVideo ? RemoteSessionMediaKind.VIDEO :
      (info.mediaKind ?? resolveRemoteSessionMediaKind({
        hasAudio: info.hasAudio,
        hasVideo: hasVideo
      }));
    return {
      hostId: info.hostId,
      sessionId: info.sessionId,
      protocolLabel: info.protocolLabel,
      hostAddress: info.hostAddress,
      hasAudio: info.hasAudio,
      hasVideo: hasVideo,
      mediaKind: mediaKind,
      connectedAtMs: info.connectedAtMs
    };
  }

  private liveViewModeForDelivery(delivery: RemoteSessionLiveViewDelivery): LiveViewMode {
    if (delivery === RemoteSessionLiveViewDelivery.AVSESSION) {
      return LiveViewMode.AVSESSION;
    }
    if (delivery === RemoteSessionLiveViewDelivery.BACKGROUND_NOTIFICATION) {
      return LiveViewMode.NOTIFICATION;
    }
    return LiveViewMode.OFF;
  }

  private claimLease(lease: RemoteSessionServiceLease): boolean {
    if (!remoteSessionServiceLeaseCanClaim(this.currentLease, lease)) { return false; }
    if (this.currentLease === null) {
      this.currentLease = cloneRemoteSessionServiceLease(lease);
    }
    return true;
  }

  private operationIsCurrent(generation: number,
    lease: RemoteSessionServiceLease): boolean {
    return generation === this.operationGeneration &&
      remoteSessionServiceLeaseEquals(this.currentLease, lease);
  }

  private async stopStrategy(context: common.UIAbilityContext,
    strategy: LiveViewStrategy): Promise<void> {
    try { await strategy.stop(context); } catch (_) {}
  }

  private clearPresentationState(): void {
    this.activeStrategy = null;
    this.lastInfo = null;
    this.currentMode = LiveViewMode.OFF;
    this.currentMediaKind = RemoteSessionMediaKind.NONE;
    this.currentHasAudio = false;
    this.currentHasVideo = false;
  }

  private resetState(clearLease: boolean): void {
    this.clearPresentationState();
    if (clearLease) {
      this.currentLease = null;
      this.currentContext = null;
    }
  }

  private enqueueOperation<T>(operation: () => Promise<T>): Promise<T> {
    const queued: Promise<T> = this.operationTail.then(
      (): Promise<T> => operation(),
      (): Promise<T> => operation());
    this.operationTail = queued.then(
      (): void => { return; },
      (): void => { return; });
    return queued;
  }
}
