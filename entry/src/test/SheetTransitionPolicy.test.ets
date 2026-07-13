import { describe, it, expect } from '@ohos/hypium';
import {
  SHEET_DISMISS_GUARD_MS,
  sheetOpenDelayMsAfterDismiss,
  shouldDelaySheetOpen
} from '../main/ets/services/SheetTransitionPolicy';

export default function sheetTransitionPolicyTest() {
  describe('SheetTransitionPolicy', (): void => {
    it('delays_open_while_previous_sheet_is_dismissing', 0, (): void => {
      expect(shouldDelaySheetOpen(1080, 1000)).assertTrue();
      expect(sheetOpenDelayMsAfterDismiss(1080, 1000)).assertEqual(SHEET_DISMISS_GUARD_MS - 80);
    });

    it('opens_immediately_after_guard_window', 0, (): void => {
      expect(shouldDelaySheetOpen(1400, 1000)).assertFalse();
      expect(sheetOpenDelayMsAfterDismiss(1400, 1000)).assertEqual(0);
    });

    it('opens_immediately_without_previous_dismiss', 0, (): void => {
      expect(sheetOpenDelayMsAfterDismiss(1000, 0)).assertEqual(0);
    });
  });
}
