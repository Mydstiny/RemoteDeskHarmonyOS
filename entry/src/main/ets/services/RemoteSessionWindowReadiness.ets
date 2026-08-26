/**
 * Process-local readiness barrier for authenticated independent session windows.
 *
 * A successful startAbility call only means that the launch request was
 * accepted. The originating page may relinquish its native session only after
 * the target page owns a valid viewport, renderer and input path.
 */

export const REMOTE_SESSION_WINDOW_READY_TIMEOUT_MS: number = 15000;

export interface RemoteSessionWindowReadySnapshot {
  protocolConnected: boolean;
  visualOwnerAttached: boolean;
  viewportWidth: number;
  viewportHeight: number;
  inputReady: boolean;
}

export function remoteSessionWindowReadySnapshotIsUsable(
  snapshot: RemoteSessionWindowReadySnapshot
): boolean {
  return snapshot.protocolConnected && snapshot.visualOwnerAttached &&
    Number.isFinite(snapshot.viewportWidth) && Number.isFinite(snapshot.viewportHeight) &&
    snapshot.viewportWidth >= 1 && snapshot.viewportHeight >= 1 && snapshot.inputReady;
}

export type RemoteSessionWindowReadinessState = 'waiting' | 'ready' | 'failed';

interface RemoteSessionWindowReadinessWaiter {
  completed: boolean;
  timer: number;
  resolve: (ready: boolean) => void;
}

export class RemoteSessionWindowReadinessBarrier {
  private state: RemoteSessionWindowReadinessState = 'waiting';
  private waiters: RemoteSessionWindowReadinessWaiter[] = [];

  currentState(): RemoteSessionWindowReadinessState { return this.state; }

  wait(timeoutMs: number = REMOTE_SESSION_WINDOW_READY_TIMEOUT_MS): Promise<boolean> {
    if (this.state === 'ready') { return Promise.resolve(true); }
    if (this.state === 'failed') { return Promise.resolve(false); }
    const boundedTimeoutMs: number = Math.max(1, Math.floor(timeoutMs));
    return new Promise<boolean>((resolve: (ready: boolean) => void): void => {
      const waiter: RemoteSessionWindowReadinessWaiter = {
        completed: false,
        timer: -1,
        resolve
      };
      waiter.timer = setTimeout((): void => {
        if (waiter.completed) { return; }
        waiter.completed = true;
        waiter.resolve(false);
      }, boundedTimeoutMs);
      this.waiters.push(waiter);
    });
  }

  markReady(): boolean { return this.settle('ready', true); }

  fail(): boolean { return this.settle('failed', false); }

  private settle(next: RemoteSessionWindowReadinessState, ready: boolean): boolean {
    if (this.state !== 'waiting') { return this.state === next; }
    this.state = next;
    const pending: RemoteSessionWindowReadinessWaiter[] = this.waiters;
    this.waiters = [];
    for (let index: number = 0; index < pending.length; index++) {
      const waiter: RemoteSessionWindowReadinessWaiter = pending[index];
      if (waiter.completed) { continue; }
      waiter.completed = true;
      if (waiter.timer >= 0) { clearTimeout(waiter.timer); }
      waiter.resolve(ready);
    }
    return true;
  }
}
