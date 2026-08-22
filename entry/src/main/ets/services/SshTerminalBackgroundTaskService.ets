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
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  buildSshBackgroundNotificationContent,
  SshBackgroundNotificationContent
} from './ssh/notification/SshNotificationService';
import { sshDiagnosticErrorCode } from './ssh/observability/SshDiagnosticPolicy';

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

export interface SshTerminalBackgroundSnapshot {
  sessionId: number;
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

export enum SshBackgroundSignalAction {
  none = 0,
  start = 1,
  stop = 2
}

/**
 * A normal Home/lock transition keeps the ArkUI page mounted, so
 * aboutToDisappear cannot be the only continuous-task trigger. Page teardown
 * remains the owner while terminalClosing is true; otherwise the live Ability
 * background signal starts the current sessions and the matching foreground
 * signal stops only tasks registered by that page.
 */
export function decideSshBackgroundSignalAction(isBackground: boolean,
  terminalClosing: boolean, activeSessionCount: number,
  pageTrackedTaskCount: number): SshBackgroundSignalAction {
  if (terminalClosing) { return SshBackgroundSignalAction.none; }
  if (isBackground) {
    return activeSessionCount > 0 ? SshBackgroundSignalAction.start :
      SshBackgroundSignalAction.none;
  }
  return pageTrackedTaskCount > 0 ? SshBackgroundSignalAction.stop :
    SshBackgroundSignalAction.none;
}

export class SshTerminalBackgroundTaskService {
  private static instance: SshTerminalBackgroundTaskService | null = null;
  private readonly tasks: Map<string, ActiveSshTask> = new Map<string, ActiveSshTask>();
  private operationTail: Promise<void> = Promise.resolve();
  private requestSequence: number = 0;
  private continuousTaskId: number = -1;
  private continuousNotificationId: number = -1;

  static getInstance(): SshTerminalBackgroundTaskService {
    if (SshTerminalBackgroundTaskService.instance === null) {
      SshTerminalBackgroundTaskService.instance = new SshTerminalBackgroundTaskService();
    }
    return SshTerminalBackgroundTaskService.instance;
  }

  async start(context: common.UIAbilityContext,
    info: SshTerminalBackgroundInfo): Promise<boolean> {
    return this.enqueueOperation<boolean>(async (): Promise<boolean> => {
      const hostId: string = info.hostId.trim();
      if (hostId.length === 0 || info.sessionId <= 0) {
        return false;
      }
      const key: string = this.taskKey(hostId, info.sessionId);
      const existing: ActiveSshTask | undefined = this.tasks.get(key);
      if (existing !== undefined && existing.state === 'running') {
        existing.hostLabel = info.hostLabel;
        existing.hostAddress = info.hostAddress;
        await this.publishAggregateNotification();
        return true;
      }
      // A rejected entry is a status record. A new start is an explicit retry.
      if (existing !== undefined) { this.tasks.delete(key); }

      // The OS continuous-task slot is shared by the SSH session collection.
      // Adding another session must not ask the system for a second slot.
      if (this.continuousTaskId >= 0) {
        this.tasks.set(key, {
          sessionId: info.sessionId,
          continuousTaskId: this.continuousTaskId,
          notificationId: this.continuousNotificationId,
          hostId,
          hostLabel: info.hostLabel,
          hostAddress: info.hostAddress,
          state: 'running'
        });
        await this.publishAggregateNotification();
        return true;
      }

      try {
        const agentInfo: wantAgent.WantAgentInfo = {
          wants: [{
            bundleName: context.abilityInfo.bundleName,
            abilityName: context.abilityInfo.name,
            parameters: {
              'hostId': hostId,
              'sessionId': info.sessionId,
              'resumeSshSession': true,
              'protocol': 'ssh'
            }
          }],
          actionType: wantAgent.OperationType.START_ABILITY,
          requestCode: this.nextRequestCode(),
          wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
        };
        const agent: WantAgent = await wantAgent.getWantAgent(agentInfo);
        const res: backgroundTaskManager.ContinuousTaskNotification =
          await backgroundTaskManager.startBackgroundRunning(
            context, ['multiDeviceConnection'], agent);
        const taskId: number = res.continuousTaskId === undefined ? -1 : res.continuousTaskId;
        if (taskId < 0) {
          this.tasks.set(key, {
            sessionId: info.sessionId,
            continuousTaskId: -1,
            notificationId: SSH_NOTIFICATION_ID,
            hostId,
            hostLabel: info.hostLabel,
            hostAddress: info.hostAddress,
            state: 'rejected'
          });
          await this.publishAggregateNotification();
          hilog.warn(DOMAIN, TAG, 'SSH background task returned invalid id');
          return false;
        }
        this.continuousTaskId = taskId;
        this.continuousNotificationId = res.notificationId;
        this.tasks.set(key, {
          sessionId: info.sessionId,
          continuousTaskId: taskId,
          notificationId: res.notificationId,
          hostId,
          hostLabel: info.hostLabel,
          hostAddress: info.hostAddress,
          state: 'running'
        });
        await this.publishAggregateNotification();
        hilog.info(DOMAIN, TAG, 'SSH background task started id=' + taskId.toString());
        return true;
      } catch (err) {
        this.tasks.set(key, {
          sessionId: info.sessionId,
          continuousTaskId: -1,
          notificationId: SSH_NOTIFICATION_ID,
          hostId,
          hostLabel: info.hostLabel,
          hostAddress: info.hostAddress,
          state: 'rejected'
        });
        await this.publishAggregateNotification();
        hilog.warn(DOMAIN, TAG, 'SSH background task rejected code=' +
          sshDiagnosticErrorCode(err));
        return false;
      }
    });
  }

  async stop(context: common.UIAbilityContext): Promise<void> {
    await this.enqueueOperation<void>(async (): Promise<void> => {
      await this.stopAllInternal(context);
    });
  }

  async stopSession(context: common.UIAbilityContext, sessionId: number,
    hostId: string = ''): Promise<void> {
    await this.enqueueOperation<void>(async (): Promise<void> => {
      const normalizedHostId: string = hostId.trim();
      const keys: string[] = [];
      this.tasks.forEach((task: ActiveSshTask, key: string): void => {
        if (task.sessionId === sessionId &&
          (normalizedHostId.length === 0 || task.hostId === normalizedHostId)) {
          keys.push(key);
        }
      });
      for (let index = 0; index < keys.length; index++) {
        this.tasks.delete(keys[index]);
      }
      await this.stopContinuousIfUnused(context);
      await this.publishAggregateNotification();
    });
  }

  private async stopAllInternal(context: common.UIAbilityContext): Promise<void> {
    this.tasks.clear();
    await this.stopContinuousIfUnused(context);
    await this.publishAggregateNotification();
  }

  private async stopContinuousIfUnused(context: common.UIAbilityContext): Promise<void> {
    let hasRunningSession: boolean = false;
    this.tasks.forEach((task: ActiveSshTask): void => {
      if (task.state === 'running') { hasRunningSession = true; }
    });
    if (hasRunningSession) { return; }
    const taskId: number = this.continuousTaskId;
    const notificationId: number = this.continuousNotificationId;
    this.continuousTaskId = -1;
    this.continuousNotificationId = -1;
    if (taskId >= 0) {
      try {
        await backgroundTaskManager.stopBackgroundRunning(context, taskId);
        hilog.info(DOMAIN, TAG, 'SSH background task stopped id=' + taskId.toString());
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'SSH background task stop failed code=' +
          sshDiagnosticErrorCode(err));
      }
    }
    if (notificationId > 0 && notificationId !== SSH_NOTIFICATION_ID) {
      try {
        await notificationManager.cancel(notificationId);
      } catch (_err) {
        // Notification cleanup is best effort during Ability teardown.
      }
    }
  }

  isRunning(): boolean {
    let running: boolean = false;
    this.tasks.forEach((task: ActiveSshTask): void => {
      if (task.state === 'running') { running = true; }
    });
    return running;
  }

  activeCount(): number {
    let count: number = 0;
    this.tasks.forEach((task: ActiveSshTask): void => {
      if (task.state === 'running') { count++; }
    });
    return count;
  }

  isBackgroundLimited(sessionId: number, hostId: string = ''): boolean {
    const normalizedHostId: string = hostId.trim();
    let limited: boolean = false;
    this.tasks.forEach((task: ActiveSshTask): void => {
      if (task.sessionId === sessionId &&
        (normalizedHostId.length === 0 || task.hostId === normalizedHostId) &&
        task.state === 'rejected') {
        limited = true;
      }
    });
    return limited;
  }

  snapshot(): SshTerminalBackgroundSnapshot[] {
    const result: SshTerminalBackgroundSnapshot[] = [];
    this.tasks.forEach((task: ActiveSshTask): void => {
      result.push({
        sessionId: task.sessionId,
        hostId: task.hostId,
        hostLabel: task.hostLabel,
        hostAddress: task.hostAddress,
        state: task.state
      });
    });
    return result;
  }

  private async publishAggregateNotification(): Promise<void> {
    const snapshots: SshTerminalBackgroundSnapshot[] = this.snapshot();
    if (snapshots.length === 0) {
      try { await notificationManager.cancel(SSH_NOTIFICATION_ID); } catch (_err) { /* best effort */ }
      return;
    }
    const runningCount: number = snapshots.filter(
      (snapshot: SshTerminalBackgroundSnapshot): boolean => snapshot.state === 'running').length;
    const limitedCount: number = snapshots.length - runningCount;
    const content: SshBackgroundNotificationContent =
      buildSshBackgroundNotificationContent(runningCount, limitedCount);
    const request: notificationManager.NotificationRequest = {
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: content.title,
          text: content.text
        }
      },
      id: SSH_NOTIFICATION_ID,
      notificationSlotType: SSH_NOTIFICATION_SLOT,
      tapDismissed: false,
      isAlertOnce: true
    };
    try {
      await notificationManager.publish(request);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'SSH notification publish failed code=' +
        sshDiagnosticErrorCode(err));
    }
  }

  private taskKey(hostId: string, sessionId: number): string {
    return hostId + '#' + sessionId.toString();
  }

  private nextRequestCode(): number {
    this.requestSequence = (this.requestSequence + 1) % 10000;
    return SSH_NOTIFICATION_ID + this.requestSequence;
  }

  private enqueueOperation<T>(operation: () => Promise<T>): Promise<T> {
    const queued: Promise<T> = this.operationTail.then(operation, operation);
    this.operationTail = queued.then((): void => undefined, (): void => undefined);
    return queued;
  }
}
