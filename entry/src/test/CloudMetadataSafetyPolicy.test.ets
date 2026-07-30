import { describe, expect, it } from '@ohos/hypium';
import {
  CloudMetadataReadResult,
  cloudMetadataAbsentProven,
  cloudMetadataBoundaryReadable,
  cloudMetadataCheckpointBlocks,
  readCloudMetadataState
} from '../main/ets/services/CloudMetadataSafetyPolicy';
import {
  CloudSelectionReenablePhase,
  VncSelectionFinalizeResult,
  cloudSelectionNativeFirstAllowed,
  vncSelectionPostCommitUploadAllowed
} from '../main/ets/services/CloudSelectionReenablePolicy';

export default function cloudMetadataSafetyPolicyTest():
  void {
  describe('CloudMetadataSafetyPolicy', (): void => {
    it('distinguishes_present_absent_and_query_error',
      0, (): void => {
        const present: CloudMetadataReadResult =
          readCloudMetadataState(
            (): string => '');
        const absent: CloudMetadataReadResult =
          readCloudMetadataState(
            (): string | null => null);
        const failed: CloudMetadataReadResult =
          readCloudMetadataState(
            (): string => {
              throw new Error(
                'injected querySync failure');
            });

        expect(present.state)
          .assertEqual('present');
        expect(absent.state)
          .assertEqual('absent');
        expect(failed.state)
          .assertEqual('error');
        expect(cloudMetadataAbsentProven(
          present)).assertFalse();
        expect(cloudMetadataCheckpointBlocks(
          present)).assertTrue();
        expect(cloudMetadataAbsentProven(
          absent)).assertTrue();
        expect(cloudMetadataAbsentProven(
          failed)).assertFalse();
      });

    it('fails_closed_for_barriers_checkpoints_and_post_commit_checks_on_query_error',
      0, (): void => {
        const failed: CloudMetadataReadResult =
          readCloudMetadataState(
            (): string => {
              throw new Error(
                'injected querySync failure');
            });

        expect(cloudMetadataBoundaryReadable(
          failed)).assertFalse();
        expect(cloudMetadataCheckpointBlocks(
          failed)).assertTrue();

        const failClosedBarrier:
          CloudSelectionReenablePhase | null =
          cloudMetadataBoundaryReadable(failed)
            ? null : 'pending_pull';
        expect(cloudSelectionNativeFirstAllowed(
          failClosedBarrier)).assertFalse();
        const promotionAllowed: boolean =
          cloudMetadataBoundaryReadable(failed);
        const retryAllowed: boolean =
          cloudMetadataBoundaryReadable(failed);
        expect(promotionAllowed).assertFalse();
        expect(retryAllowed).assertFalse();

        const committed:
          VncSelectionFinalizeResult = {
          ok: true,
          failedStep: 'none'
        };
        expect(vncSelectionPostCommitUploadAllowed(
          committed,
          !cloudMetadataAbsentProven(failed),
          failClosedBarrier)).assertFalse();
      });
  });
}
