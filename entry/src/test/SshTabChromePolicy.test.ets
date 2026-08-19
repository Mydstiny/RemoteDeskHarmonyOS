import { describe, it, expect } from '@ohos/hypium';
import {
  resolveSshTabChromeLayout,
  SSH_TAB_INLINE_MIN_VIEWPORT_VP,
  sshTabWidthVp
} from '../main/ets/services/ssh/workspace/SshTabChromePolicy';

export default function sshTabChromePolicyTest(): void {
  describe('SshTabChromePolicy', (): void => {
    it('keeps_fixed_edge_actions_reachable_at_a_360vp_pc_window', 0, (): void => {
      const layout = resolveSshTabChromeLayout(360, 'md');
      expect(layout.compact).assertTrue();
      expect(layout.inlineAllowed).assertFalse();
      expect(layout.edgeActionsWidthVp < 360).assertTrue();
      expect(layout.scrollViewportWidthVp >= 200).assertTrue();
      expect(layout.tabWidthVp).assertEqual(124);
    });

    it('uses_inline_normal_tabs_only_after_the_safe_width_threshold', 0, (): void => {
      const narrow = resolveSshTabChromeLayout(SSH_TAB_INLINE_MIN_VIEWPORT_VP - 1, 'lg');
      const wide = resolveSshTabChromeLayout(SSH_TAB_INLINE_MIN_VIEWPORT_VP, 'lg');
      expect(narrow.inlineAllowed).assertFalse();
      expect(wide.inlineAllowed).assertTrue();
      expect(wide.tabWidthVp).assertEqual(154);
      expect(wide.pinnedTabWidthVp).assertEqual(118);
    });

    it('keeps_twenty_tabs_in_the_scroll_region_instead_of_shrinking_hit_targets', 0,
      (): void => {
        const layout = resolveSshTabChromeLayout(360, 'sm');
        const contentWidth: number = 20 * sshTabWidthVp(true, false) + 19 * 6;
        expect(contentWidth > layout.scrollViewportWidthVp).assertTrue();
        expect(sshTabWidthVp(true, true)).assertEqual(104);
      });
  });
}
