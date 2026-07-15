import { describe, it, expect } from '@ohos/hypium';
import {
  settingsLeafSheetClosedState,
  settingsLeafSheetDismissRequestedState,
  settingsLeafSheetPendingMode,
  shouldQueueSettingsLeafSheetOpen,
  shouldOpenRestoreConfirmation
} from '../main/ets/services/SettingsLeafSheetLifecyclePolicy';

export default function settingsLeafSheetLifecyclePolicyTest(): void {
  describe('SettingsLeafSheetLifecyclePolicy', (): void => {
    it('resets_the_leaf_sheet_after_an_external_system_dismissal', 0, (): void => {
      const state = settingsLeafSheetClosedState();
      expect(state.visible).assertFalse();
      expect(state.mode).assertEqual(0);
      expect(state.cancelPendingOpen).assertTrue();
    });

    it('keeps_the_current_builder_mode_until_dismissal_finishes', 0, (): void => {
      const state = settingsLeafSheetDismissRequestedState(7);
      expect(state.visible).assertFalse();
      expect(state.mode).assertEqual(7);
      expect(state.cancelPendingOpen).assertTrue();
    });

    it('queues_an_open_while_a_leaf_is_visible_or_dismissing', 0, (): void => {
      expect(shouldQueueSettingsLeafSheetOpen(true, false)).assertTrue();
      expect(shouldQueueSettingsLeafSheetOpen(false, true)).assertTrue();
      expect(shouldQueueSettingsLeafSheetOpen(false, false)).assertFalse();
    });

    it('keeps_only_the_last_rapidly_requested_mode', 0, (): void => {
      expect(settingsLeafSheetPendingMode(2, 7)).assertEqual(7);
      expect(settingsLeafSheetPendingMode(7, 11)).assertEqual(11);
    });

    it('opens_restore_confirmation_only_for_a_valid_backup', 0, (): void => {
      expect(shouldOpenRestoreConfirmation(false)).assertFalse();
      expect(shouldOpenRestoreConfirmation(true)).assertTrue();
    });
  });
}
