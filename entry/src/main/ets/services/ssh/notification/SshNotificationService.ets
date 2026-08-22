import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'SshNotification';
const DOMAIN: number = 0x0016;
const SSH_COMPLETION_NOTIFICATION_ID_MIN: number = 606101;
const SSH_COMPLETION_NOTIFICATION_ID_MAX: number = 607124;
const MIN_COMPLETION_DURATION_MS: number = 5000;

export interface SshCommandCompletionInfoV1 {
  enabled: boolean;
  hostLabel: string;
  exitCode: number | null;
  durationMs: number;
}

export function sshCompletionNotificationAllowed(info: SshCommandCompletionInfoV1): boolean {
  const label: string = info.hostLabel.trim();
  const duration: number = Number.isFinite(info.durationMs) ? Math.max(0, info.durationMs) : 0;
  // A short successful command is not useful enough to interrupt the user.
  // Failures are always eligible, but neither branch includes command text.
  return info.enabled === true && label.length > 0 &&
    (info.exitCode !== 0 && info.exitCode !== null ||
    duration >= MIN_COMPLETION_DURATION_MS);
}

export function buildSshCompletionNotificationText(info: SshCommandCompletionInfoV1): string {
  const duration: number = Math.max(0, Math.floor(info.durationMs / 1000));
  const durationText: string = duration > 0 ? ' · ' + duration.toString() + ' 秒' : '';
  if (info.exitCode === null) { return '命令已结束' + durationText; }
  return info.exitCode === 0
    ? '命令完成 · 成功' + durationText
    : '命令完成 · 退出码 ' + Math.floor(info.exitCode).toString() + durationText;
}

/**
 * Preserve concurrent completion alerts instead of replacing every session's
 * notification under one fixed id. The bounded ring prevents unbounded ids;
 * only a wrap after 1024 eligible alerts may replace an older entry.
 */
export function nextSshCompletionNotificationId(previous: number): number {
  const normalized: number = Number.isFinite(previous) ? Math.floor(previous) : 0;
  if (normalized < SSH_COMPLETION_NOTIFICATION_ID_MIN ||
    normalized >= SSH_COMPLETION_NOTIFICATION_ID_MAX) {
    return SSH_COMPLETION_NOTIFICATION_ID_MIN;
  }
  return normalized + 1;
}

/**
 * Thin SSH-only adapter over Notification Kit. It deliberately does not own
 * the shared RDP/RustDesk/VNC background notification or request host address,
 * user name, path, or command text from callers.
 */
export class SshNotificationService {
  private static instance: SshNotificationService | null = null;
  private completionNotificationId: number = SSH_COMPLETION_NOTIFICATION_ID_MIN - 1;

  static getInstance(): SshNotificationService {
    if (SshNotificationService.instance === null) {
      SshNotificationService.instance = new SshNotificationService();
    }
    return SshNotificationService.instance;
  }

  async publishCommandCompletion(info: SshCommandCompletionInfoV1): Promise<boolean> {
    const label: string = info.hostLabel.trim().slice(0, 96);
    const safeInfo: SshCommandCompletionInfoV1 = {
      enabled: info.enabled === true,
      hostLabel: label,
      exitCode: info.exitCode === null || !Number.isFinite(info.exitCode)
        ? null : Math.floor(info.exitCode),
      durationMs: Number.isFinite(info.durationMs) ? Math.max(0, Math.floor(info.durationMs)) : 0
    };
    if (!sshCompletionNotificationAllowed(safeInfo)) { return false; }
    this.completionNotificationId =
      nextSshCompletionNotificationId(this.completionNotificationId);
    const request: notificationManager.NotificationRequest = {
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: 'SSH · ' + safeInfo.hostLabel,
          text: buildSshCompletionNotificationText(safeInfo)
        }
      },
      id: this.completionNotificationId,
      notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
      tapDismissed: true,
      isAlertOnce: true
    };
    try {
      await notificationManager.publish(request);
      return true;
    } catch (err) {
      const business: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'completion notification rejected code=' +
        (business.code === undefined ? 'unknown' : business.code.toString()));
      return false;
    }
  }
}
