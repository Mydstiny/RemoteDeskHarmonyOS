/**
 * RemoteSessionBackgroundTaskService.ets — 远程会话后台长时任务 (T-251)
 *
 * 为 RDP/RustDesk 已连接会话提供后台保活:
 * - multiDeviceConnection: 远程会话连续运行
 * - audioPlayback: 仅在有真实远端音频或视频活动时叠加
 *
 * 不与 FileTransferLiveTaskService (dataTransfer) 冲突。
 * 禁止用 dataTransfer 伪装远程连接状态。
 */
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { backgroundModesForRemoteMedia } from './RemoteSessionMediaStatePolicy';

const TAG = 'RemoteSessionBgTask';
const DOMAIN = 0x0014;

// 通知 ID 基值 (与 FileTransferLiveTaskService 的 NOTIFY_BASE_ID=604200 隔离)
const SESSION_NOTIFY_BASE_ID = 605000;
const SESSION_NOTIFICATION_SLOT = notificationManager.SlotType.SERVICE_INFORMATION;

enum BgTaskState {
  idle = 'idle',
  running = 'running',
  rejected = 'rejected',
  stopped = 'stopped'
}

interface ActiveBgTask {
  sessionId: number;
  continuousTaskId: number;
  notificationId: number;
  state: BgTaskState;
  hasAudioTask: boolean;
  modes: string[];
}

export interface RemoteSessionBgInfo {
  hostId: string;
  sessionId: number;
  resumeRemoteSession: boolean;
  protocolLabel: string;
  hostAddress: string;
  hasAudio: boolean;
  hasVideo: boolean;
}

export class RemoteSessionBackgroundTaskService {
  private static instance: RemoteSessionBackgroundTaskService | null = null;
  private task: ActiveBgTask | null = null;

  static getInstance(): RemoteSessionBackgroundTaskService {
    if (RemoteSessionBackgroundTaskService.instance === null) {
      RemoteSessionBackgroundTaskService.instance = new RemoteSessionBackgroundTaskService();
    }
    return RemoteSessionBackgroundTaskService.instance;
  }

  /**
   * 启动远程会话后台任务。
   * 使用 multiDeviceConnection 模式。
   * @param context UIAbilityContext
   * @param info 会话摘要 (用于通知显示)
   */
  async startSessionTask(context: common.UIAbilityContext,
    info: RemoteSessionBgInfo): Promise<boolean> {
    if (this.task !== null && this.task.state === BgTaskState.running) {
      if (this.task.sessionId === info.sessionId) {
        hilog.info(DOMAIN, TAG, '[SESSION-BG] task already running, skip start');
        return true;
      }
      await this.stopSessionTask(context);
    }

    const notificationId: number = SESSION_NOTIFY_BASE_ID;
    try {
      const agentInfo: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: context.abilityInfo.bundleName,
          abilityName: context.abilityInfo.name,
          parameters: {
            'hostId': info.hostId,
            'sessionId': info.sessionId,
            'resumeRemoteSession': info.resumeRemoteSession
          }
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: notificationId,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(agentInfo);
      const modes: string[] = this.modesForMedia(info.hasAudio, info.hasVideo);

      const res: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.startBackgroundRunning(context, modes, agent);

      const taskId: number = res.continuousTaskId === undefined ? -1 : res.continuousTaskId;
      this.task = {
        sessionId: info.sessionId,
        continuousTaskId: taskId,
        notificationId: res.notificationId,
        state: BgTaskState.running,
        hasAudioTask: info.hasAudio || info.hasVideo,
        modes: modes
      };

      // 发布通知: "RDP 远程会话运行中"
      await this.publishSessionNotification(res.notificationId, info);

      hilog.info(DOMAIN, TAG, '[SESSION-BG] multiDeviceConnection task started id=' +
        taskId.toString() + ' notification=' + res.notificationId.toString());
      return true;
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.task = {
        sessionId: info.sessionId,
        continuousTaskId: -1,
        notificationId: notificationId,
        state: BgTaskState.rejected,
        hasAudioTask: false,
        modes: []
      };
      hilog.warn(DOMAIN, TAG, '[SESSION-BG-START] multiDeviceConnection rejected code=' +
        this.errorCode(be) + ' message=' + this.errorMessage(be));
      // 被拒绝时不静默伪装 — 记录错误码，不 fallback 到 dataTransfer
      return false;
    }
  }

  /**
   * 为真实远端音频叠加 audioPlayback 长时任务。
   * 仅在远端音频已确认开始播放后调用。
   */
  async startAudioPlaybackTask(context: common.UIAbilityContext,
    info: RemoteSessionBgInfo): Promise<void> {
    await this.updateAudioPlaybackMode(context, info);
  }

  /**
   * 更新远程会话后台任务类型。
   * API-12 startBackgroundRunning 同一 UIAbility 同时只应有一个任务,
   * 因此音频出现/消失时更新既有任务的 mode 列表, 不再启动第二个任务。
   */
  async updateAudioPlaybackMode(context: common.UIAbilityContext,
    info: RemoteSessionBgInfo): Promise<void> {
    if (this.task === null || this.task.state !== BgTaskState.running) {
      hilog.warn(DOMAIN, TAG, '[SESSION-BG-AUDIO] main session task not running, skip audio task');
      return;
    }
    const nextModes: string[] = this.modesForMedia(info.hasAudio, info.hasVideo);
    if (this.sameModes(this.task.modes, nextModes)) {
      return;
    }

    try {
      const res: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.updateBackgroundRunning(context, nextModes);

      this.task.modes = nextModes;
      this.task.hasAudioTask = info.hasAudio || info.hasVideo;
      if (res.notificationId !== undefined && res.notificationId > 0) {
        this.task.notificationId = res.notificationId;
      }
      await this.publishSessionNotification(this.task.notificationId, info);
      const audioTaskId: number = res.continuousTaskId === undefined ? -1 : res.continuousTaskId;
      hilog.info(DOMAIN, TAG, '[SESSION-BG-AUDIO] background modes updated id=' +
        audioTaskId.toString() + ' modes=' + nextModes.join(','));
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, '[SESSION-BG-AUDIO-UPDATE] audioPlayback update rejected code=' +
        this.errorCode(be) + ' message=' + this.errorMessage(be));
      // audioPlayback 更新失败不阻断主保活任务
    }
  }

  /**
   * 停止远程会话后台任务 (前台恢复或完全断连时调用)。
   */
  async stopSessionTask(context: common.UIAbilityContext): Promise<void> {
    if (this.task === null) {
      return;
    }

    if (this.task.state === BgTaskState.running && this.task.continuousTaskId >= 0) {
      try {
        await backgroundTaskManager.stopBackgroundRunning(context, this.task.continuousTaskId);
        hilog.info(DOMAIN, TAG, '[SESSION-BG] task stopped id=' +
          this.task.continuousTaskId.toString());
      } catch (err) {
        const be: BusinessError = err as BusinessError;
        hilog.warn(DOMAIN, TAG, '[SESSION-BG-STOP] stop failed code=' +
          this.errorCode(be) + ' message=' + this.errorMessage(be));
      }
    }

    // 尝试取消通知
    if (this.task.notificationId > 0) {
      try {
        await notificationManager.cancel(this.task.notificationId);
      } catch (_e) {
        // 取消通知失败不影响
      }
    }

    this.task = null;
  }

  /**
   * 检查后台任务是否已启动且正在运行。
   */
  isRunning(): boolean {
    return this.task !== null && this.task.state === BgTaskState.running;
  }

  /**
   * 检查后台任务是否被拒绝。
   */
  wasRejected(): boolean {
    return this.task !== null && this.task.state === BgTaskState.rejected;
  }

  // ---- 私有方法 ----

  private async publishSessionNotification(notificationId: number,
    info: RemoteSessionBgInfo): Promise<void> {
    try {
      const title: string = info.protocolLabel + ' 远程会话运行中';
      const mediaSuffix: string = info.hasAudio ? ' (含音频)' :
        (info.hasVideo ? ' (视频保活)' : '');
      const text: string = '已连接 ' + info.hostAddress + mediaSuffix;
      const request: notificationManager.NotificationRequest = {
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: title,
            text: text
          }
        },
        id: notificationId,
        notificationSlotType: SESSION_NOTIFICATION_SLOT,
        tapDismissed: false,
        isAlertOnce: true
      };
      await notificationManager.publish(request);
      hilog.info(DOMAIN, TAG, '[SESSION-BG] notification published: ' + title);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '[SESSION-BG-NOTIFY] publish failed: ' + JSON.stringify(err));
    }
  }

  private modesForMedia(hasAudio: boolean, hasVideo: boolean): string[] {
    return backgroundModesForRemoteMedia({ hasAudio, hasVideo });
  }

  private sameModes(a: string[], b: string[]): boolean {
    if (a.length !== b.length) {
      return false;
    }
    for (let i = 0; i < a.length; i++) {
      if (a[i] !== b[i]) {
        return false;
      }
    }
    return true;
  }

  private errorCode(error: BusinessError): string {
    return error.code === undefined ? 'unknown' : error.code.toString();
  }

  private errorMessage(error: BusinessError): string {
    return error.message === undefined ? JSON.stringify(error) : error.message;
  }
}
