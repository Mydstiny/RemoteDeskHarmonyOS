/**
 * SSH terminal background continuity.
 *
 * This service deliberately owns only SSH terminal sessions. The shared
 * RemoteSessionBackgroundTaskService is reserved for RDP/RustDesk/VNC and is
 * never stopped or replaced from this module.
 */
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'SshTerminalBgTask';
const DOMAIN = 0x0016;
const SSH_NOTIFICATION_ID = 606000;
const SSH_NOTIFICATION_SLOT = notificationManager.SlotType.SERVICE_INFORMATION;

interface ActiveSshTask {
  sessionId: number;
  continuousTaskId: number;
  notificationId: number;
  hostId: string;
  hostLabel: string;
  hostAddress: string;
  state: 'running' | 'rejected';
}

export interface SshTerminalBackgroundInfo {
  hostId: string;
  sessionId: number;
  hostLabel: string;
  hostAddress: string;
}

export class SshTerminalBackgroundTaskService {
  private static instance: SshTerminalBackgroundTaskService | null = null;
  private task: ActiveSshTask | null = null;
  private operationTail: Promise<void> = Promise.resolve();

  static getInstance(): SshTerminalBackgroundTaskService {
    if (SshTerminalBackgroundTaskService.instance === null) {
      SshTerminalBackgroundTaskService.instance = new SshTerminalBackgroundTaskService();
    }
    return SshTerminalBackgroundTaskService.instance;
  }

  async start(context: common.UIAbilityContext,
    info: SshTerminalBackgroundInfo): Promise<boolean> {
    return this.enqueueOperation<boolean>(async (): Promise<boolean> => {
      if (this.task !== null && this.task.state === 'running') {
        if (this.task.sessionId === info.sessionId) {
          return true;
        }
        await this.stopInternal(context);
      }

      try {
        const agentInfo: wantAgent.WantAgentInfo = {
          wants: [{
            bundleName: context.abilityInfo.bundleName,
            abilityName: context.abilityInfo.name,
            parameters: {
              'hostId': info.hostId,
              'sessionId': info.sessionId,
              'resumeSshSession': true,
              'protocol': 'ssh'
            }
          }],
          actionType: wantAgent.OperationType.START_ABILITY,
          requestCode: SSH_NOTIFICATION_ID,
          wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
        };
        const agent: WantAgent = await wantAgent.getWantAgent(agentInfo);
        const res: backgroundTaskManager.ContinuousTaskNotification =
          await backgroundTaskManager.startBackgroundRunning(
            context, ['multiDeviceConnection'], agent);
        const taskId: number = res.continuousTaskId === undefined ? -1 : res.continuousTaskId;
        this.task = {
          sessionId: info.sessionId,
          continuousTaskId: taskId,
          notificationId: res.notificationId,
          hostId: info.hostId,
          hostLabel: info.hostLabel,
          hostAddress: info.hostAddress,
          state: 'running'
        };
        await this.publishNotification(res.notificationId, info);
        hilog.info(DOMAIN, TAG, 'SSH background task started id=' + taskId.toString());
        return true;
      } catch (err) {
        const be: BusinessError = err as BusinessError;
        this.task = {
          sessionId: info.sessionId,
          continuousTaskId: -1,
          notificationId: SSH_NOTIFICATION_ID,
          hostId: info.hostId,
          hostLabel: info.hostLabel,
          hostAddress: info.hostAddress,
          state: 'rejected'
        };
        hilog.warn(DOMAIN, TAG, 'SSH background task rejected code=' +
          this.errorCode(be) + ' message=' + this.errorMessage(be));
        return false;
      }
    });
  }

  async stop(context: common.UIAbilityContext): Promise<void> {
    await this.enqueueOperation<void>(async (): Promise<void> => {
      await this.stopInternal(context);
    });
  }

  private async stopInternal(context: common.UIAbilityContext): Promise<void> {
    const task: ActiveSshTask | null = this.task;
    this.task = null;
    if (task === null) {
      return;
    }
    if (task.state === 'running' && task.continuousTaskId >= 0) {
      try {
        await backgroundTaskManager.stopBackgroundRunning(context, task.continuousTaskId);
        hilog.info(DOMAIN, TAG, 'SSH background task stopped id=' +
          task.continuousTaskId.toString());
      } catch (err) {
        const be: BusinessError = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'SSH background task stop failed code=' +
          this.errorCode(be) + ' message=' + this.errorMessage(be));
      }
    }
    if (task.notificationId > 0) {
      try {
        await notificationManager.cancel(task.notificationId);
      } catch (_err) {
        // Notification cleanup is best effort during Ability teardown.
      }
    }
  }

  isRunning(): boolean {
    return this.task !== null && this.task.state === 'running';
  }

  private async publishNotification(notificationId: number,
    info: SshTerminalBackgroundInfo): Promise<void> {
    const hostName: string = info.hostLabel.length > 0 ? info.hostLabel : info.hostAddress;
    const request: notificationManager.NotificationRequest = {
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: 'SSH 终端运行中',
          text: '已连接 ' + hostName + ' · ' + info.hostAddress
        }
      },
      id: notificationId,
      notificationSlotType: SSH_NOTIFICATION_SLOT,
      tapDismissed: false,
      isAlertOnce: true
    };
    try {
      await notificationManager.publish(request);
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'SSH notification publish failed code=' +
        this.errorCode(be) + ' message=' + this.errorMessage(be));
    }
  }

  private enqueueOperation<T>(operation: () => Promise<T>): Promise<T> {
    const queued: Promise<T> = this.operationTail.then(operation, operation);
    this.operationTail = queued.then((): void => undefined, (): void => undefined);
    return queued;
  }

  private errorCode(error: BusinessError): string {
    return error.code === undefined ? 'unknown' : error.code.toString();
  }

  private errorMessage(error: BusinessError): string {
    return error.message === undefined ? JSON.stringify(error) : error.message;
  }
}
