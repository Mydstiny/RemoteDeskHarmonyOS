/**
 * NotificationLiveViewStrategy — 远程会话普通后台通知策略
 *
 * API 23 不允许第三方应用直接创建 SYSTEM_LIVE_VIEW/LIVE_VIEW 通知；
 * 系统代理必须先创建同 ID 的实况窗，第三方应用只能更新它。远程连接
 * 没有系统代理，因此这里直接使用系统允许的 SERVICE_INFORMATION 普通通知。
 * 不使用 dataTransfer 后台任务伪造实况窗，远程连接仍由 multiDeviceConnection 保活。
 */
import { common } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LiveViewConnectionInfo, LiveViewStrategy } from './LiveViewTypes';

const TAG = 'NotifyLiveView';
const DOMAIN = 0x0015;
const NOTIFY_BASE_ID = 605100;

export class NotificationLiveViewStrategy implements LiveViewStrategy {
  private notificationId: number = 0;
  private notificationActive: boolean = false;
  private connectedAtMs: number = 0;
  private updateTimer: number = -1;
  private lastInfo: LiveViewConnectionInfo | null = null;

  async start(context: common.UIAbilityContext,
    info: LiveViewConnectionInfo): Promise<void> {
    this.lastInfo = info;
    this.connectedAtMs = info.connectedAtMs;
    this.notificationId = NOTIFY_BASE_ID + (info.sessionId % 100);

    await this.publishNotification(info);

    // 启动定时更新 (每 60 秒更新连接时长)
    this.startPeriodicUpdate();
  }

  async update(info: LiveViewConnectionInfo): Promise<void> {
    this.lastInfo = info;
    if (this.notificationActive) {
      await this.publishNotification(info);
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
    this.notificationActive = false;
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

  /** 发布系统允许第三方直接创建的普通后台通知。 */
  private async publishNotification(info: LiveViewConnectionInfo): Promise<void> {
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
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
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
      this.notificationActive = true;
      hilog.info(DOMAIN, TAG, 'background notification published id=' +
        this.notificationId.toString());
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      const code: string = be.code === undefined ? 'unknown' : be.code.toString();
      const message: string = be.message === undefined ? JSON.stringify(err) : be.message;
      hilog.warn(DOMAIN, TAG, '[BACKGROUND-NOTIFICATION-PUBLISH] failed code=' +
        code + ' message=' + message);
      throw new Error(message);
    }
  }

  private startPeriodicUpdate(): void {
    this.stopPeriodicUpdate();
    // 每 60 秒更新一次通知内容 (更新连接时长文本)
    this.updateTimer = setInterval((): void => {
      if (this.notificationActive && this.lastInfo !== null) {
        this.publishNotification(this.lastInfo).catch((err: Error): void => {
          hilog.warn(DOMAIN, TAG, '[BACKGROUND-NOTIFICATION-UPDATE] failed: ' +
            (err.message ? err.message : JSON.stringify(err)));
        });
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
