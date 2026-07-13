/**
 * FileTransferLiveTaskService — RDP/RustDesk 文件传输实况窗/通知进度
 */
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  FileTransferProgressSnapshot,
  makeTransferStatusText,
  makeTransferTitle
} from './FileTransferProgressModel';

const TAG = 'FileTransferLiveTask';
const NOTIFY_BASE_ID = 604200;
const LIVE_VIEW_TYPE_UPLOAD_DOWNLOAD = 8;

class ActiveTransferTask {
  taskId: string = '';
  notificationId: number = 0;
  continuousTaskId: number = -1;
  liveTaskStarted: boolean = false;
  fallbackOnly: boolean = false;
}

export class FileTransferLiveTaskService {
  private static instance: FileTransferLiveTaskService | null = null;
  private activeTasks: Map<string, ActiveTransferTask> = new Map<string, ActiveTransferTask>();
  private nextFallbackId: number = NOTIFY_BASE_ID;

  static getInstance(): FileTransferLiveTaskService {
    if (FileTransferLiveTaskService.instance === null) {
      FileTransferLiveTaskService.instance = new FileTransferLiveTaskService();
    }
    return FileTransferLiveTaskService.instance;
  }

  async begin(context: common.UIAbilityContext, snapshot: FileTransferProgressSnapshot): Promise<void> {
    const task: ActiveTransferTask = new ActiveTransferTask();
    task.taskId = snapshot.taskId;
    task.notificationId = this.allocateNotificationId();
    this.activeTasks.set(snapshot.taskId, task);
    await this.startLiveTask(context, task);
    await this.publishProgress(task, snapshot);
  }

  async update(snapshot: FileTransferProgressSnapshot): Promise<void> {
    const task: ActiveTransferTask | undefined = this.activeTasks.get(snapshot.taskId);
    if (!task) {
      return;
    }
    await this.publishProgress(task, snapshot);
  }

  async complete(context: common.UIAbilityContext, snapshot: FileTransferProgressSnapshot): Promise<void> {
    const task: ActiveTransferTask | undefined = this.activeTasks.get(snapshot.taskId);
    if (!task) {
      return;
    }
    await this.publishProgress(task, snapshot);
    await this.stopLiveTask(context, task);
    this.activeTasks.delete(snapshot.taskId);
  }

  async fail(context: common.UIAbilityContext, snapshot: FileTransferProgressSnapshot): Promise<void> {
    const task: ActiveTransferTask | undefined = this.activeTasks.get(snapshot.taskId);
    if (!task) {
      return;
    }
    await this.publishProgress(task, snapshot);
    await this.stopLiveTask(context, task);
    this.activeTasks.delete(snapshot.taskId);
  }

  private allocateNotificationId(): number {
    this.nextFallbackId++;
    if (this.nextFallbackId > NOTIFY_BASE_ID + 1000) {
      this.nextFallbackId = NOTIFY_BASE_ID + 1;
    }
    return this.nextFallbackId;
  }

  private async startLiveTask(context: common.UIAbilityContext, task: ActiveTransferTask): Promise<void> {
    try {
      const agentInfo: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: context.abilityInfo.bundleName,
          abilityName: context.abilityInfo.name
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: task.notificationId,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(agentInfo);
      const modes: string[] = ['dataTransfer'];
      const res: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.startBackgroundRunning(context, modes, agent);
      task.notificationId = res.notificationId;
      task.continuousTaskId = res.continuousTaskId === undefined ? -1 : res.continuousTaskId;
      task.liveTaskStarted = true;
      hilog.info(0x0001, TAG, 'live task started id=' + task.continuousTaskId.toString() +
        ' notification=' + task.notificationId.toString());
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      task.fallbackOnly = true;
      hilog.warn(0x0001, TAG, '[FILE-LIVE-START] live task unavailable code=' +
        be.code.toString() + ' message=' + be.message);
    }
  }

  private async stopLiveTask(context: common.UIAbilityContext, task: ActiveTransferTask): Promise<void> {
    if (!task.liveTaskStarted || task.continuousTaskId < 0) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context, task.continuousTaskId);
      hilog.info(0x0001, TAG, 'live task stopped id=' + task.continuousTaskId.toString());
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.warn(0x0001, TAG, '[FILE-LIVE-STOP] stop failed code=' +
        be.code.toString() + ' message=' + be.message);
    }
  }

  private async publishProgress(task: ActiveTransferTask, snapshot: FileTransferProgressSnapshot): Promise<void> {
    if (!task.fallbackOnly) {
      try {
        await notificationManager.publish(this.makeLiveRequest(task.notificationId, snapshot));
        return;
      } catch (err) {
        const be: BusinessError = err as BusinessError;
        task.fallbackOnly = true;
        hilog.warn(0x0001, TAG, '[FILE-LIVE-PUBLISH] live publish failed code=' +
          be.code.toString() + ' message=' + be.message);
      }
    }

    try {
      await notificationManager.publish(this.makeFallbackRequest(task.notificationId, snapshot));
    } catch (err2) {
      const be2: BusinessError = err2 as BusinessError;
      hilog.warn(0x0001, TAG, '[FILE-NOTIFY-PUBLISH] fallback publish failed code=' +
        be2.code.toString() + ' message=' + be2.message);
    }
  }

  private makeLiveRequest(notificationId: number,
    snapshot: FileTransferProgressSnapshot): notificationManager.NotificationRequest {
    const title: string = makeTransferTitle(snapshot.protocol, snapshot.state);
    const text: string = makeTransferStatusText(snapshot);
    const template: notificationManager.NotificationTemplate = {
      name: 'downloadTemplate',
      data: {
        title,
        fileName: snapshot.fileName,
        progressValue: snapshot.progressValue
      }
    };
    return {
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
        systemLiveView: {
          typeCode: LIVE_VIEW_TYPE_UPLOAD_DOWNLOAD,
          title,
          text
        }
      },
      id: notificationId,
      notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
      template,
      tapDismissed: false,
      isAlertOnce: true
    };
  }

  private makeFallbackRequest(notificationId: number,
    snapshot: FileTransferProgressSnapshot): notificationManager.NotificationRequest {
    const title: string = makeTransferTitle(snapshot.protocol, snapshot.state);
    const text: string = makeTransferStatusText(snapshot);
    const template: notificationManager.NotificationTemplate = {
      name: 'downloadTemplate',
      data: {
        title,
        fileName: snapshot.fileName,
        progressValue: snapshot.progressValue
      }
    };
    return {
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title,
          text,
          additionalText: snapshot.progressValue.toString() + '%'
        }
      },
      id: notificationId,
      notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
      template,
      tapDismissed: snapshot.state === 'completed' || snapshot.state === 'failed',
      isAlertOnce: true,
      autoDeletedTime: snapshot.state === 'completed' || snapshot.state === 'failed' ? Date.now() + 6000 : 0
    };
  }
}
