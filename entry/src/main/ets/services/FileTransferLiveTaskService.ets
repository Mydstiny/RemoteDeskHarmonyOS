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
  finishing: boolean = false;
  tail: Promise<void> = Promise.resolve();
  finishPromise: Promise<void> | null = null;
  stopRetry: number = -1;
  stopAttempts: number = 0;
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
    const key: string = this.taskKey(snapshot);
    const existing: ActiveTransferTask | undefined = this.activeTasks.get(key);
    if (existing !== undefined) { await existing.tail; return; }
    const task: ActiveTransferTask = new ActiveTransferTask();
    task.taskId = key;
    task.notificationId = this.allocateNotificationId();
    this.activeTasks.set(key, task);
    task.tail = this.startLiveTask(context, task).then(async (): Promise<void> => {
      if (!task.finishing) { await this.publishProgress(task, snapshot); }
    });
    await task.tail;
  }

  async update(snapshot: FileTransferProgressSnapshot): Promise<void> {
    const task: ActiveTransferTask | undefined = this.activeTasks.get(this.taskKey(snapshot));
    if (task === undefined || task.finishing) { return; }
    task.tail = task.tail.then(async (): Promise<void> => {
      if (!task.finishing) { await this.publishProgress(task, snapshot); }
    });
    await task.tail;
  }

  async complete(context: common.UIAbilityContext, snapshot: FileTransferProgressSnapshot): Promise<void> {
    await this.finish(context, snapshot);
  }

  async fail(context: common.UIAbilityContext, snapshot: FileTransferProgressSnapshot): Promise<void> {
    await this.finish(context, snapshot);
  }

  private taskKey(snapshot: FileTransferProgressSnapshot): string {
    return JSON.stringify([snapshot.accountScopeId ?? '', snapshot.taskId,
      (snapshot.attemptId === undefined ? 0 : snapshot.attemptId).toString()]);
  }

  private async finish(context: common.UIAbilityContext, snapshot: FileTransferProgressSnapshot): Promise<void> {
    const key: string = this.taskKey(snapshot);
    const task: ActiveTransferTask | undefined = this.activeTasks.get(key);
    if (task === undefined) { return; }
    if (task.finishPromise !== null) { await task.finishPromise; return; }
    // Close update admission synchronously, then drain startup and pending publish.
    task.finishing = true;
    task.finishPromise = task.tail.then(async (): Promise<void> => {
      await this.publishProgress(task, snapshot);
      await this.releaseTask(context, task);
    });
    task.tail = task.finishPromise;
    await task.finishPromise;
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
      // API 21+ request overload allocates independent task IDs; the old array
      // overload permits only one continuous task per UIAbility.
      const request: backgroundTaskManager.ContinuousTaskRequest = new backgroundTaskManager.ContinuousTaskRequest();
      request.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_DATA_TRANSFER];
      request.wantAgent = agent;
      request.combinedTaskNotification = false;
      const res: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.startBackgroundRunning(context, request);
      task.notificationId = res.notificationId;
      task.continuousTaskId = res.continuousTaskId === undefined ? -1 : res.continuousTaskId;
      task.liveTaskStarted = true;
      hilog.info(0x0001, TAG, 'live task started id=' + task.continuousTaskId.toString() +
        ' notification=' + task.notificationId.toString());
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      task.fallbackOnly = true;
      hilog.warn(0x0001, TAG, '[FILE-LIVE-START] live task unavailable code=' +
        (typeof be.code === 'number' ? be.code.toString() : 'unknown'));
    }
  }

  private async releaseTask(context: common.UIAbilityContext, task: ActiveTransferTask): Promise<void> {
    if (await this.stopLiveTask(context, task)) {
      if (this.activeTasks.get(task.taskId) === task) { this.activeTasks.delete(task.taskId); }
      return;
    }
    // A failed stop remains owned and retries with bounded backoff, never a global stop.
    task.stopAttempts++;
    task.stopRetry = setTimeout(() => {
      task.stopRetry = -1;
      this.releaseTask(context, task).catch(() => {});
    }, Math.min(60000, 1000 * Math.pow(2, Math.min(6, task.stopAttempts - 1))));
  }

  private async stopLiveTask(context: common.UIAbilityContext, task: ActiveTransferTask): Promise<boolean> {
    if (!task.liveTaskStarted) { return true; }
    if (task.continuousTaskId < 0) { return false; }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context, task.continuousTaskId);
      task.liveTaskStarted = false;
      hilog.info(0x0001, TAG, 'live task stopped id=' + task.continuousTaskId.toString());
      return true;
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.warn(0x0001, TAG, '[FILE-LIVE-STOP] stop failed code=' +
        (typeof be.code === 'number' ? be.code.toString() : 'unknown'));
      return false;
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
          (typeof be.code === 'number' ? be.code.toString() : 'unknown'));
      }
    }

    try {
      await notificationManager.publish(this.makeFallbackRequest(task.notificationId, snapshot));
    } catch (err2) {
      const be2: BusinessError = err2 as BusinessError;
      hilog.warn(0x0001, TAG, '[FILE-NOTIFY-PUBLISH] fallback publish failed code=' +
        (typeof be2.code === 'number' ? be2.code.toString() : 'unknown'));
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
      tapDismissed: snapshot.state === 'completed' || snapshot.state === 'failed' || snapshot.state === 'cancelled',
      isAlertOnce: true,
      autoDeletedTime: snapshot.state === 'completed' || snapshot.state === 'failed' || snapshot.state === 'cancelled' ? Date.now() + 6000 : 0
    };
  }
}
