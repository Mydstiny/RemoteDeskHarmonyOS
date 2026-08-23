import { describe, it, expect } from '@ohos/hypium';
import {
  resolveSshTabChromeLayout,
  SSH_TAB_INLINE_MIN_VIEWPORT_VP,
  SSH_TAB_STRIP_HEIGHT_VP,
  SSH_WORKSPACE_CONTROL_HIT_SIZE_VP,
  sshCompactChromeEnabled,
  sshTabWidthVp
} from '../main/ets/services/ssh/workspace/SshTabChromePolicy';

export default function sshTabChromePolicyTest(): void {
  describe('SshTabChromePolicy', (): void => {
    it('gives_the_scrollable_tabs_the_full_width_after_menu_consolidation', 0, (): void => {
      const layout = resolveSshTabChromeLayout(360, 'md');
      expect(layout.compact).assertTrue();
      expect(layout.inlineAllowed).assertFalse();
      expect(layout.edgeActionsWidthVp < 360).assertTrue();
      expect(layout.edgeActionsWidthVp).assertEqual(12);
      expect(layout.scrollViewportWidthVp).assertEqual(348);
      expect(layout.tabWidthVp).assertEqual(124);
      expect(SSH_TAB_STRIP_HEIGHT_VP).assertEqual(56);
      expect(SSH_WORKSPACE_CONTROL_HIT_SIZE_VP).assertEqual(48);
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

    it('never_enables_compact_chrome_while_the_workbench_flag_is_off', 0, (): void => {
      expect(sshCompactChromeEnabled(false, 360, 'md')).assertFalse();
      expect(sshCompactChromeEnabled(false, 360, 'sm')).assertFalse();
      expect(sshCompactChromeEnabled(true, 360, 'md')).assertTrue();
    });
  });
}
