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
    info: LiveViewConnectionInfo): Promise<boolean> {
    const enabled: boolean = AppStorage.get<boolean>('liveViewEnabled') ?? true;
    if (!enabled) {
      hilog.info(DOMAIN, TAG, 'liveView disabled, skip start');
      return false;
    }

    // 如果已有活跃策略, 先停掉
    if (this.activeStrategy !== null) {
      await this.stop(context);
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
          this.activeStrategy = this.avSessionStrategy;
        } catch (err) {
          hilog.warn(DOMAIN, TAG, '[LIVE-VIEW-AVSESSION-FALLBACK] start failed, using notification: ' +
            JSON.stringify(err));
          if (this.notificationStrategy === null) {
            this.notificationStrategy = new NotificationLiveViewStrategy();
          }
          await this.notificationStrategy.start(context, normalizedInfo);
          this.currentMode = LiveViewMode.NOTIFICATION;
          this.activeStrategy = this.notificationStrategy;
        }
      } else if (delivery === RemoteSessionLiveViewDelivery.BACKGROUND_NOTIFICATION) {
        if (this.notificationStrategy === null) {
          this.notificationStrategy = new NotificationLiveViewStrategy();
        }
        await this.notificationStrategy.start(context, normalizedInfo);
        this.activeStrategy = this.notificationStrategy;
      } else {
        hilog.info(DOMAIN, TAG, 'liveView mode is OFF, skip');
        this.resetState();
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
      this.resetState();
      return false;
    }
  }

  async reconcile(context: common.UIAbilityContext,
    info: LiveViewConnectionInfo): Promise<boolean> {
    const enabled: boolean = AppStorage.get<boolean>('liveViewEnabled') ?? true;
    if (!enabled) {
      await this.stop(context);
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
    const audioChanged: boolean = normalizedInfo.hasAudio !== this.currentHasAudio;
    const videoChanged: boolean = (normalizedInfo.hasVideo === true) !== this.currentHasVideo;

    if (this.activeStrategy === null || modeChanged || mediaRestartRequired) {
      return await this.start(context, normalizedInfo);
    }

    if (audioChanged || videoChanged || nextMediaKind !== this.currentMediaKind) {
      this.currentMediaKind = nextMediaKind;
      this.currentHasAudio = normalizedInfo.hasAudio;
      this.currentHasVideo = normalizedInfo.hasVideo === true;
    }
    await this.update(normalizedInfo);
    return this.activeStrategy !== null;
  }

  /**
   * 连接状态更新时调用 (如音频状态变化)。
   */
  async update(info: LiveViewConnectionInfo): Promise<void> {
    const normalizedInfo: LiveViewConnectionInfo = this.normalizeInfo(info);
    this.lastInfo = normalizedInfo;
    if (this.activeStrategy === null) {
      return;
    }
    try {
      await this.activeStrategy.update(normalizedInfo);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '[LIVE-VIEW-UPDATE] failed: ' + JSON.stringify(err));
    }
  }

  /**
   * 前台恢复或断连时调用 — 移除实况窗。
   */
  async stop(context: common.UIAbilityContext): Promise<void> {
    if (this.activeStrategy === null) {
      return;
    }
    try {
      await this.activeStrategy.stop(context);
      hilog.info(DOMAIN, TAG, 'liveView stopped mode=' + this.currentMode.toString());
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '[LIVE-VIEW-STOP] failed: ' + JSON.stringify(err));
    } finally {
      this.activeStrategy = null;
      this.lastInfo = null;
      this.currentMode = LiveViewMode.OFF;
      this.currentMediaKind = RemoteSessionMediaKind.NONE;
      this.currentHasAudio = false;
      this.currentHasVideo = false;
    }
  }

  /**
   * 检查实况窗当前是否活跃。
   */
  isActive(): boolean {
    return this.activeStrategy !== null;
  }

  /**
   * 设置静音控制回调 (仅 AVSession 策略有效)。
   * 由 RemoteDesktop 在启动实况窗后注入原生静音实现。
   * @param callback mute=true→静音, mute=false→取消静音
   */
  setMuteCommandCallback(callback: (mute: boolean) => void): void {
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

  private resetState(): void {
    this.activeStrategy = null;
    this.lastInfo = null;
    this.currentMode = LiveViewMode.OFF;
    this.currentMediaKind = RemoteSessionMediaKind.NONE;
    this.currentHasAudio = false;
    this.currentHasVideo = false;
  }
}
