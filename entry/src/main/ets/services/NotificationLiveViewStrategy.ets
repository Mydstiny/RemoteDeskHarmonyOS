/**
 * NotificationLiveViewStrategy — 使用系统实况窗通知实现灵动岛
 *
 * 原理:
 * - 复用 FileTransferLiveTaskService 的模式: SlotType.LIVE_VIEW + SYSTEM_LIVE_VIEW 内容
 * - 尝试直接发布系统实况窗通知 (无需额外后台任务, 复用已有的 multiDeviceConnection 保活)
 * - 如果实况窗发布失败 (三方应用无系统代理), 自动降级为增强型普通通知
 *
 * 注意:
 * - 发布实况窗需要系统代理创建初始通知. 如果直接 publish 失败, 降级到普通通知.
 * - 不使用 dataTransfer 后台任务, 避免与 RemoteSessionBackgroundTaskService 冲突.
 * - 使用独立的 notification ID (605100 基值), 与文件传输 (604200) 和会话保活 (605000) 隔离.
 */
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LiveViewConnectionInfo, LiveViewStrategy } from './LiveViewTypes';

const TAG = 'NotifyLiveView';
const DOMAIN = 0x0015;
const NOTIFY_BASE_ID = 605100;

export class NotificationLiveViewStrategy implements LiveViewStrategy {
  private notificationId: number = 0;
  private liveViewActive: boolean = false;
  private fallbackActive: boolean = false;
  private connectedAtMs: number = 0;
  private updateTimer: number = -1;
  private lastInfo: LiveViewConnectionInfo | null = null;

  async start(context: common.UIAbilityContext,
    info: LiveViewConnectionInfo): Promise<void> {
    this.lastInfo = info;
    this.connectedAtMs = info.connectedAtMs;
    this.notificationId = NOTIFY_BASE_ID + (info.sessionId % 100);

    // 尝试发布实况窗通知
    const liveOk: boolean = await this.tryPublishLiveView(info);
    if (!liveOk) {
      // 降级: 发布增强型普通通知 (无灵动岛但通知栏可见)
      await this.tryPublishFallback(info);
    }

    // 启动定时更新 (每 60 秒更新连接时长)
    this.startPeriodicUpdate();
  }

  async update(info: LiveViewConnectionInfo): Promise<void> {
    this.lastInfo = info;
    if (this.liveViewActive) {
      await this.tryPublishLiveView(info);
    } else if (this.fallbackActive) {
      await this.tryPublishFallback(info);
    }
  }

  async stop(_context: common.UIAbilityContext): Promise<void> {
    this.stopPeriodicUpdate();
    if (this.notificationId > 0) {
      try {
        await notificationManager.cancel(this.notificationId);
        hilog.info(DOMAIN, TAG, 'notification cancelled id=' + this.notificationId.toString());
      } catch (_e) {
        // 取消失败不影响
      }
    }
    this.liveViewActive = false;
    this.fallbackActive = false;
    this.notificationId = 0;
    this.lastInfo = null;
  }

  // ---- 私有方法 ----

  private getDurationText(): string {
    if (this.connectedAtMs <= 0) {
      return '';
    }
    const elapsed: number = Math.floor((Date.now() - this.connectedAtMs) / 1000);
    const hours: number = Math.floor(elapsed / 3600);
    const mins: number = Math.floor((elapsed % 3600) / 60);
    const secs: number = elapsed % 60;
    if (hours > 0) {
      return hours.toString() + 'h ' + mins.toString() + 'm';
    }
    if (mins > 0) {
      return mins.toString() + 'm ' + secs.toString() + 's';
    }
    return secs.toString() + 's';
  }

  /**
   * 尝试发布系统实况窗通知 (灵动岛胶囊)。
   * 如果系统代理未创建初始通知, 此调用会失败, 返回 false。
   */
  private async tryPublishLiveView(info: LiveViewConnectionInfo): Promise<boolean> {
    if (this.notificationId <= 0) {
      return false;
    }

    try {
      const title: string = info.protocolLabel + ' 远程连接';
      const durationText: string = this.getDurationText();
      const text: string = info.hostAddress +
        (durationText.length > 0 ? ' · ' + durationText : '') +
        (info.hasAudio ? ' · 含音频' : '');

      const request: notificationManager.NotificationRequest = {
        content: {
          notificationContentType:
            notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
          systemLiveView: {
            typeCode: 9, // 自定义业务类型码: 远程连接
            title: title,
            text: text,
            // 计时: 正计时显示连接时长
            time: {
              initialTime: this.connectedAtMs,
              isCountDown: false,
              isPaused: false,
              isInTitle: false
            }
          }
        },
        id: this.notificationId,
        notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
        tapDismissed: false,
        isAlertOnce: true
      };

      await notificationManager.publish(request);
      this.liveViewActive = true;
      this.fallbackActive = false;
      hilog.info(DOMAIN, TAG, 'live view notification published id=' +
        this.notificationId.toString());
      return true;
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, '[LIVE-VIEW-PUBLISH] live view rejected code=' +
        be.code.toString() + ' message=' + be.message +
        ' — 可能缺少系统代理, 降级到普通通知');
      return false;
    }
  }

  /**
   * 降级: 发布增强型普通通知 (通知栏可见但无灵动岛胶囊)。
   */
  private async tryPublishFallback(info: LiveViewConnectionInfo): Promise<void> {
    if (this.notificationId <= 0) {
      return;
    }

    try {
      const title: string = info.protocolLabel + ' 远程连接运行中';
      const durationText: string = this.getDurationText();
      const text: string = '已连接 ' + info.hostAddress +
        (durationText.length > 0 ? ' · ' + durationText : '') +
        (info.hasAudio ? ' · 含音频' : '');

      const request: notificationManager.NotificationRequest = {
        content: {
          notificationContentType:
            notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: title,
            text: text,
            additionalText: durationText.length > 0 ? '已持续 ' + durationText : ''
          }
        },
        id: this.notificationId,
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
        tapDismissed: false,
        isAlertOnce: true
      };

      await notificationManager.publish(request);
      this.liveViewActive = false;
      this.fallbackActive = true;
      hilog.info(DOMAIN, TAG, 'fallback notification published id=' +
        this.notificationId.toString());
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, '[FALLBACK-PUBLISH] failed code=' +
        be.code.toString() + ' message=' + be.message);
    }
  }

  private startPeriodicUpdate(): void {
    this.stopPeriodicUpdate();
    // 每 60 秒更新一次通知内容 (更新连接时长文本)
    this.updateTimer = setInterval((): void => {
      if ((this.liveViewActive || this.fallbackActive) && this.lastInfo !== null) {
        if (this.liveViewActive) {
          this.tryPublishLiveView(this.lastInfo);
        } else {
          this.tryPublishFallback(this.lastInfo);
        }
      }
    }, 60000);
  }

  private stopPeriodicUpdate(): void {
    if (this.updateTimer >= 0) {
      clearInterval(this.updateTimer);
      this.updateTimer = -1;
    }
  }
}
