import { describe, expect, it } from '@ohos/hypium';
import {
  CloudStartupFinalizationHooks,
  CloudStartupFinalizationResult,
  finalizeCloudStartupDownload
} from '../main/ets/services/CloudStartupFinalizationPolicy';

class FinalizationHooks implements CloudStartupFinalizationHooks {
  reconcileAllowed: boolean = true;
  markAllowed: boolean = true;
  prepareAllowed: boolean = true;
  clearAllowed: boolean = true;
  releaseAllowed: boolean = true;
  calls: string[] = [];

  reconcileMutationJournal(): boolean {
    this.calls.push('reconcile');
    return this.reconcileAllowed;
  }

  markSelectionPulled(): boolean {
    this.calls.push('mark');
    return this.markAllowed;
  }

  prepareSelectionPromotions(): boolean {
    this.calls.push('prepare');
    return this.prepareAllowed;
  }

  clearDownloadCheckpoint(): boolean {
    this.calls.push('clear');
    return this.clearAllowed;
  }

  releaseSelectionBarriers(): boolean {
    this.calls.push('release');
    return this.releaseAllowed;
  }
}

export default function cloudStartupFinalizationPolicyTest(): void {
  describe('CloudStartupFinalizationPolicy', (): void => {
    it('rolls_back_only_when_a_data_transaction_boundary_fails',
      0, (): void => {
        const journal: FinalizationHooks = new FinalizationHooks();
        journal.reconcileAllowed = false;
        const journalResult: CloudStartupFinalizationResult =
          finalizeCloudStartupDownload(journal);
        expect(journalResult.ok).assertFalse();
        expect(journalResult.rollbackRequired).assertTrue();
        expect(journalResult.failureStep)
          .assertEqual('journal_reconcile');
        expect(journal.calls.join(','))
          .assertEqual('reconcile');

        const checkpoint: FinalizationHooks = new FinalizationHooks();
        checkpoint.clearAllowed = false;
        const checkpointResult: CloudStartupFinalizationResult =
          finalizeCloudStartupDownload(checkpoint);
        expect(checkpointResult.ok).assertFalse();
        expect(checkpointResult.rollbackRequired).assertTrue();
        expect(checkpointResult.failureStep)
          .assertEqual('checkpoint_clear');
        expect(checkpoint.calls.join(','))
          .assertEqual('reconcile,mark,prepare,clear');
      });

    it('commits_download_and_defers_failed_selection_metadata',
      0, (): void => {
        const mark: FinalizationHooks = new FinalizationHooks();
        mark.markAllowed = false;
        const markResult: CloudStartupFinalizationResult =
          finalizeCloudStartupDownload(mark);
        expect(markResult.ok).assertTrue();
        expect(markResult.rollbackRequired).assertFalse();
        expect(markResult.deferredSelectionStep)
          .assertEqual('mark_pulled');
        expect(mark.calls.join(','))
          .assertEqual('reconcile,mark,clear');

        const release: FinalizationHooks = new FinalizationHooks();
        release.releaseAllowed = false;
        const releaseResult: CloudStartupFinalizationResult =
          finalizeCloudStartupDownload(release);
        expect(releaseResult.ok).assertTrue();
        expect(releaseResult.deferredSelectionStep)
          .assertEqual('release_barriers');
        expect(release.calls.join(','))
          .assertEqual('reconcile,mark,prepare,clear,release');
      });
  });
}
