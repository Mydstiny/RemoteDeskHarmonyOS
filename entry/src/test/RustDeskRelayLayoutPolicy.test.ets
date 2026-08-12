import { describe, it, expect } from '@ohos/hypium';
import {
  rustDeskRelayDirectoryBottomClearance,
  rustDeskRelaySheetUsesResizeOnly
} from '../main/ets/services/RustDeskRelayLayoutPolicy';

export default function rustDeskRelayLayoutPolicyTest(): void {
  describe('RustDeskRelayLayoutPolicy', (): void => {
    it('keeps_the_phone_list_clear_of_the_fab', 0, (): void => {
      expect(rustDeskRelayDirectoryBottomClearance('sm')).assertEqual(200);
      expect(rustDeskRelayDirectoryBottomClearance('md')).assertEqual(120);
    });

    it('matches_host_add_keyboard_avoidance', 0, (): void => {
      expect(rustDeskRelaySheetUsesResizeOnly(10, 'md')).assertTrue();
      expect(rustDeskRelaySheetUsesResizeOnly(10, 'xl')).assertTrue();
      expect(rustDeskRelaySheetUsesResizeOnly(10, 'sm')).assertFalse();
      expect(rustDeskRelaySheetUsesResizeOnly(1, 'md')).assertFalse();
    });
  });
}
