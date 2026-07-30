import { describe, it, expect } from '@ohos/hypium';
import {
  shouldOpenVncFloatingPanelAfterSheetDisappear
} from '../main/ets/services/VncFloatingPanelLifecyclePolicy';

export default function vncFloatingPanelLifecyclePolicyTest(): void {
  describe('VncFloatingPanelLifecyclePolicy', (): void => {
    it('opens_only_after_sheet_disappears_for_the_same_live_session', 0, (): void => {
      expect(shouldOpenVncFloatingPanelAfterSheetDisappear(true, true, 7, 7)).assertTrue();
      expect(shouldOpenVncFloatingPanelAfterSheetDisappear(false, true, 7, 7)).assertFalse();
      expect(shouldOpenVncFloatingPanelAfterSheetDisappear(true, false, 7, 7)).assertFalse();
      expect(shouldOpenVncFloatingPanelAfterSheetDisappear(true, true, 7, 8)).assertFalse();
    });
  });
}
