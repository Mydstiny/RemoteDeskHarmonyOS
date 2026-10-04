import { describe, expect, it } from '@ohos/hypium';
import {
  CloudSyncCoordinator,
  CloudSyncCoordinatorHooks,
  CloudSyncOperationResult,
  CloudSyncRetryClock,
  CloudSyncRetryTimerTask,
  CloudSyncSelectionSource,
  VncCloudSyncSelectionSource
} from '../main/ets/services/CloudSyncCoordinator';
import { CloudSyncDirection } from '../main/ets/services/CloudSyncPolicy';
import { CloudSyncFailureKind } from '../main/ets/services/CloudSyncCoordinatorPolicy';
import { CloudSyncDurableState } from '../main/ets/services/CloudSyncLifecyclePolicy';
import { AccountSessionLease } from '../main/ets/services/AccountScopePolicy';
import { CloudAccountBinding } from '../main/ets/services/CloudLifecycleSafetyPolicy';

class PauseSelection implements CloudSyncSelectionSource {
  private readonly tables: string[];

  constructor(tables: string[]) {
    this.tables = tables.slice();
  }

  selectedBusinessTables(): string[] {
    return this.tables.slice();
  }
}

class NoVncSelection implements VncCloudSyncSelectionSource {
  hasSelection(): boolean { return false; }

  needsCrypto(_cryptoConfigured: boolean): boolean { return false; }
}

class IdleClock implements CloudSyncRetryClock {
  now(): number { return 1000; }

  schedule(_task: CloudSyncRetryTimerTask, _delayMs: number): number { return 1; }

  cancel(_timerId: number): void {}
}

class PauseHooks implements CloudSyncCoordinatorHooks {
  paused: string[] = [];
  durableState: CloudSyncDurableState | null = null;

  beginManualDownload(): boolean { return true; }

  async rollbackManualDownload(): Promise<boolean> { return true; }

  completeManualDownload(_tables: string[]): boolean { return true; }

  beginStartupDownload(): boolean { return true; }

  async rollbackStartupDownload(): Promise<boolean> { return true; }

  completeStartupDownload(_dirtyTables: string[], _completedTables: string[]): boolean { return true; }

  setRestorePending(_pending: boolean): void {}

  failureKindForTable(_table: string): CloudSyncFailureKind { return 'network'; }

  hasRestoredNotUploaded(): boolean { return false; }

  pendingRestoreTables(): string[] | null { return []; }

  hasCloudBootstrapCompleted(): boolean { return true; }

  markCloudBootstrapCompleted(): boolean { return true; }

  loadDurableState(): CloudSyncDurableState | null { return this.durableState; }

  persistDurableState(state: CloudSyncDurableState): boolean {
    this.durableState = state;
    return true;
  }

  selectionReenableBlocked(_table: string): boolean { return false; }

  cryptoResetUploadBlocked(table: string): boolean { return this.paused.indexOf(table) >= 0; }
}

function pauseLease(): AccountSessionLease {
  return {
    ownerScopeId: 'owner-reset-pause',
    storeIdentity: 'remotedesktop_owner-reset-pause.db',
    generation: 5,
    storeInstanceId: 2
  };
}

function pauseBinding(): CloudAccountBinding {
  return {
    state: 'bound',
    ownerScopeId: 'owner-reset-pause',
    storeIdentity: 'remotedesktop_owner-reset-pause.db',
    generation: 5,
    platformIdentityFingerprint: 'b'.repeat(64)
  };
}

export default function cloudSyncResetPauseTest(): void {
  describe('CloudSyncResetPause', (): void => {
    it('pauses_reset_blocked_uploads_without_stopping_downloads_or_other_tables', 0,
      async (): Promise<void> => {
        const hooks: PauseHooks = new PauseHooks();
        hooks.paused = ['remotehosts', 'cryptoparams'];
        const coordinator: CloudSyncCoordinator = new CloudSyncCoordinator(
          new PauseSelection(['cryptoparams', 'usersettings', 'remotehosts']),
          new IdleClock(), new NoVncSelection());
        const executed: string[] = [];
        expect(coordinator.bind(pauseLease(), pauseBinding(),
          async (table: string, direction: CloudSyncDirection, _label: string): Promise<boolean> => {
            executed.push(direction + ':' + table);
            return true;
          }, (_tables: string[]): void => {}, hooks)).assertTrue();
        expect((await coordinator.requestStartupPull()).ok).assertTrue();

        // A non-sensitive push no longer drags the paused cryptoparams along.
        executed.splice(0);
        const settings: CloudSyncOperationResult = await coordinator.requestAutomaticPush('usersettings');
        expect(settings.ok).assertTrue();
        expect(executed.indexOf('nativeFirst:usersettings') >= 0).assertTrue();
        expect(executed.indexOf('nativeFirst:cryptoparams')).assertEqual(-1);

        // A paused table is skipped (not failed), so it is not marked as a conflict.
        executed.splice(0);
        await coordinator.requestAutomaticPush('remotehosts');
        expect(executed.length).assertEqual(0);

        // Downloads still include every selected table.
        executed.splice(0);
        expect((await coordinator.requestForegroundPull()).ok).assertTrue();
        expect(executed.indexOf('cloudFirst:remotehosts') >= 0).assertTrue();
        expect(executed.indexOf('cloudFirst:usersettings') >= 0).assertTrue();

        // A manual upload leaves paused tables out.
        executed.splice(0);
        await coordinator.requestManualUpload();
        expect(executed.indexOf('nativeFirst:remotehosts')).assertEqual(-1);
        expect(executed.indexOf('nativeFirst:cryptoparams')).assertEqual(-1);

        // After the explicit release the table uploads with its parameters.
        hooks.paused = [];
        executed.splice(0);
        expect((await coordinator.requestAutomaticPush('remotehosts')).ok).assertTrue();
        expect(executed.indexOf('nativeFirst:remotehosts') >= 0).assertTrue();
        expect(executed.indexOf('nativeFirst:cryptoparams') >= 0).assertTrue();
        expect(await coordinator.dispose(pauseLease(), 1000)).assertTrue();
      });
  });
}
