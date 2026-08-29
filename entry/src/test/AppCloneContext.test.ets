import { describe, expect, it } from '@ohos/hypium';
import {
  appCloneAccountTransitionAllowed,
  appCloneClipboardBridgeAllowed,
  appCloneCloudOperationAllowed,
  appCloneLocalDataSheetReturnCloses,
  appClonePolicyForIndex,
  appClonePolicyFromIndexReader,
  normalizeAppCloneIndex
} from '../main/ets/services/AppCloneContext';

export default function appCloneContextTest(): void {
  describe('AppCloneContext', (): void => {
    it('keeps_the_main_application_cloud_policy_unchanged', 0, (): void => {
      const policy = appClonePolicyForIndex(0);
      expect(policy.detected).assertTrue();
      expect(policy.isClone).assertFalse();
      expect(policy.localOnly).assertFalse();
      expect(policy.cloudSyncAllowed).assertTrue();
      expect(policy.accountKitAllowed).assertTrue();
    });

    it('forces_every_clone_index_into_local_only_mode', 0, (): void => {
      const first = appClonePolicyForIndex(1);
      const later = appClonePolicyForIndex(5);
      expect(first.isClone).assertTrue();
      expect(first.localOnly).assertTrue();
      expect(first.cloudSyncAllowed).assertFalse();
      expect(first.accountKitAllowed).assertFalse();
      expect(first.statusText.indexOf('应用分身 #1') >= 0).assertTrue();
      expect(later.isClone).assertTrue();
      expect(later.cloudSyncAllowed).assertFalse();
    });

    it('fails_closed_for_invalid_or_unconfirmed_platform_results', 0, (): void => {
      expect(normalizeAppCloneIndex(-1)).assertEqual(-1);
      expect(normalizeAppCloneIndex(1.5)).assertEqual(-1);
      expect(normalizeAppCloneIndex(Number.NaN)).assertEqual(-1);
      expect(normalizeAppCloneIndex(Number.POSITIVE_INFINITY)).assertEqual(-1);
      const policy = appClonePolicyForIndex(Number.NaN);
      expect(policy.detected).assertFalse();
      expect(policy.localOnly).assertTrue();
      expect(policy.cloudSyncAllowed).assertFalse();
      expect(policy.accountKitAllowed).assertFalse();
    });

    it('fails_closed_when_the_runtime_clone_index_probe_throws', 0, (): void => {
      const detected = appClonePolicyFromIndexReader((): number => 0);
      const failed = appClonePolicyFromIndexReader((): number => {
        throw new Error('platform probe unavailable');
      });
      expect(detected.detected).assertTrue();
      expect(detected.localOnly).assertFalse();
      expect(failed.detected).assertFalse();
      expect(failed.localOnly).assertTrue();
    });

    it('keeps_account_cloud_clipboard_and_sheet_guards_fail_closed', 0, (): void => {
      const main = appClonePolicyForIndex(0);
      const clone = appClonePolicyForIndex(1);
      expect(appCloneAccountTransitionAllowed(main)).assertTrue();
      expect(appCloneCloudOperationAllowed(main)).assertTrue();
      expect(appCloneClipboardBridgeAllowed(main)).assertTrue();
      expect(appCloneLocalDataSheetReturnCloses(main)).assertFalse();
      expect(appCloneAccountTransitionAllowed(clone)).assertFalse();
      expect(appCloneCloudOperationAllowed(clone)).assertFalse();
      expect(appCloneClipboardBridgeAllowed(clone)).assertFalse();
      expect(appCloneLocalDataSheetReturnCloses(clone)).assertTrue();
    });
  });
}
