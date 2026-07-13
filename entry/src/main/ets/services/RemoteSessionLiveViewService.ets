/**
 * RemoteSessionLiveViewService — 远程会话实况窗统一服务
 *
 * 提供两种实况窗展示策略:
 * - AVSession (audio): 系统自动生成媒体播控胶囊
 * - Notification (LIVE_VIEW): 系统代理创建实况窗通知后更新内容
 *
 * 通过 AppStorage key 'liveViewEnabled' / 'liveViewMode' 在运行时切换.
 * 模式: 0=关闭, 1=AVSession, 2=通知实况窗
 */
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LiveViewMode, LiveViewConnectionInfo, LiveViewStrategy, resolveLiveViewMode } from './LiveViewTypes';
import { AvSessionLiveViewStrategy } from './AvSessionLiveViewStrategy';
import { NotificationLiveViewStrategy } from './NotificationLiveViewStrategy';
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
   */
  async start(context: common.UIAbilityContext,
    info: LiveViewConnectionInfo): Promise<void> {
    const enabled: boolean = AppStorage.get<boolean>('liveViewEnabled') ?? true;
    if (!enabled) {
      hilog.info(DOMAIN, TAG, 'liveView disabled, skip start');
      return;
    }

    // 如果已有活跃策略, 先停掉
    if (this.activeStrategy !== null) {
      await this.stop(context);
    }

    const normalizedInfo: LiveViewConnectionInfo = this.normalizeInfo(info);
    const mode: number = AppStorage.get<number>('liveViewMode') ?? LiveViewMode.AVSESSION;
    this.currentMode = resolveLiveViewMode(mode, normalizedInfo.hasAudio,
      normalizedInfo.hasVideo === true);
    this.lastInfo = normalizedInfo;

    try {
      if (this.currentMode === LiveViewMode.AVSESSION) {
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
      } else if (this.currentMode === LiveViewMode.NOTIFICATION) {
        if (this.notificationStrategy === null) {
          this.notificationStrategy = new NotificationLiveViewStrategy();
        }
        await this.notificationStrategy.start(context, normalizedInfo);
        this.activeStrategy = this.notificationStrategy;
      } else {
        hilog.info(DOMAIN, TAG, 'liveView mode is OFF, skip');
        return;
      }

      this.currentMediaKind = normalizedInfo.mediaKind ?? RemoteSessionMediaKind.NONE;
      this.currentHasAudio = normalizedInfo.hasAudio;
      this.currentHasVideo = normalizedInfo.hasVideo === true;
      hilog.info(DOMAIN, TAG, 'liveView started mode=' + this.currentMode.toString() +
        ' kind=' + this.currentMediaKind.toString() +
        ' protocol=' + normalizedInfo.protocolLabel);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '[LIVE-VIEW-START] failed mode=' + this.currentMode.toString() +
        ' code=' + JSON.stringify(err));
      this.activeStrategy = null;
    }
  }

  async reconcile(context: common.UIAbilityContext,
    info: LiveViewConnectionInfo): Promise<void> {
    const enabled: boolean = AppStorage.get<boolean>('liveViewEnabled') ?? true;
    if (!enabled) {
      await this.stop(context);
      return;
    }

    const normalizedInfo: LiveViewConnectionInfo = this.normalizeInfo(info);
    const preferredMode: number = AppStorage.get<number>('liveViewMode') ?? LiveViewMode.AVSESSION;
    const nextMode: LiveViewMode = resolveLiveViewMode(preferredMode, normalizedInfo.hasAudio,
      normalizedInfo.hasVideo === true);
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
      await this.start(context, normalizedInfo);
      return;
    }

    if (audioChanged || videoChanged || nextMediaKind !== this.currentMediaKind) {
      this.currentMediaKind = nextMediaKind;
      this.currentHasAudio = normalizedInfo.hasAudio;
      this.currentHasVideo = normalizedInfo.hasVideo === true;
    }
    await this.update(normalizedInfo);
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
      this.currentMediaKind === RemoteSessionMediaKind.AUDIO &&
      this.avSessionStrategy !== null) {
      this.avSessionStrategy.setMuteCommandHandler(callback);
      hilog.info(DOMAIN, TAG, 'mute command callback registered for AVSession strategy');
    }
  }

  private normalizeInfo(info: LiveViewConnectionInfo): LiveViewConnectionInfo {
    const hasVideo: boolean = info.hasVideo === true;
    const mediaKind: number = info.mediaKind ?? resolveRemoteSessionMediaKind({
      hasAudio: info.hasAudio,
      hasVideo: hasVideo
    });
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
}
