import { describe, it, expect } from '@ohos/hypium';
import {
  rustDeskRelayDirectoryBottomClearance,
  rustDeskRelaySheetUsesLargeLayout
} from '../main/ets/services/RustDeskRelayLayoutPolicy';

export default function rustDeskRelayLayoutPolicyTest(): void {
  describe('RustDeskRelayLayoutPolicy', (): void => {
    it('keeps_the_phone_list_clear_of_the_fab', 0, (): void => {
      expect(rustDeskRelayDirectoryBottomClearance('sm')).assertEqual(200);
      expect(rustDeskRelayDirectoryBottomClearance('md')).assertEqual(120);
    });

    it('fits_the_collapsed_relay_editor_and_expands_advanced_content', 0, (): void => {
      expect(rustDeskRelaySheetUsesLargeLayout(1, false)).assertFalse();
      expect(rustDeskRelaySheetUsesLargeLayout(1, true)).assertTrue();
    });

    it('keeps_the_vnc_gateway_editor_large', 0, (): void => {
      expect(rustDeskRelaySheetUsesLargeLayout(10, false)).assertTrue();
      expect(rustDeskRelaySheetUsesLargeLayout(5, true)).assertFalse();
    });
  });
}
