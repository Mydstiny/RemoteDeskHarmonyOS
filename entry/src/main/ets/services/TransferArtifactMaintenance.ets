import { hilog } from '@kit.PerformanceAnalysisKit';
import { reconcileTransferArtifactStorage, TransferArtifactCleanupResult } from './TransferArtifactStore';

/** Maintenance walks every stored copy; it runs at most this often unless a caller forces it. */
const MAINTENANCE_INTERVAL_MS: number = 10 * 60 * 1000;
let maintenanceRunning: boolean = false;
let maintenanceRanAt: number = 0;

/**
 * Clears transfer copies nobody can use any more (see reconcileTransferArtifactStorage) in the background: after the app
 * starts and when a file panel opens. Never runs twice at once.
 */
export function scheduleTransferArtifactMaintenance(filesDir: string, delayMs: number = 0): void {
  if (maintenanceRunning || filesDir.length === 0 || Date.now() - maintenanceRanAt < MAINTENANCE_INTERVAL_MS) { return; }
  maintenanceRunning = true;
  setTimeout((): void => {
    reconcileTransferArtifactStorage(filesDir).then((result: TransferArtifactCleanupResult): void => {
      hilog.info(0x0001, 'TransferMaintenance', 'removedFiles=%{public}d removedBytes=%{public}d retained=%{public}d invalid=%{public}d',
        result.removedFiles, result.removedBytes, result.retainedBatches, result.invalidBatches);
    }).catch((): void => { /* The next run retries. */ }).finally((): void => {
      maintenanceRunning = false; maintenanceRanAt = Date.now();
    });
  }, Math.max(0, delayMs));
}
