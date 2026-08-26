import { describe, it, expect } from '@ohos/hypium';
import {
  resolveSshTabChromeLayout,
  resolveSshHostPickerSheetLayout,
  resolveSshTopChromeLayout,
  SSH_SESSION_HEADER_BASE_HEIGHT_VP,
  SSH_TAB_INLINE_MIN_VIEWPORT_VP,
  SSH_TAB_STRIP_HEIGHT_VP,
  SSH_WORKSPACE_CONTROL_HIT_SIZE_VP,
  sshCompactChromeEnabled,
  sshHeaderUsesSingleActionMenu,
  sshTabStripShowsStandaloneNewSessionAction,
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
      expect(layout.tabWidthVp).assertEqual(136);
      expect(SSH_TAB_STRIP_HEIGHT_VP).assertEqual(56);
      expect(SSH_WORKSPACE_CONTROL_HIT_SIZE_VP).assertEqual(48);
    });

    it('places_standalone_tabs_below_the_safe_area_header', 0, (): void => {
      const stacked = resolveSshTopChromeLayout(24, true);
      expect(stacked.headerTopInsetVp).assertEqual(24);
      expect(stacked.standaloneTabTopInsetVp).assertEqual(0);
      expect(stacked.tabStripBelowHeader).assertTrue();
      expect(stacked.totalHeightVp).assertEqual(
        SSH_SESSION_HEADER_BASE_HEIGHT_VP + 24 + SSH_TAB_STRIP_HEIGHT_VP);

      const inline = resolveSshTopChromeLayout(24, false);
      expect(inline.tabStripBelowHeader).assertFalse();
      expect(inline.totalHeightVp).assertEqual(SSH_SESSION_HEADER_BASE_HEIGHT_VP + 24);
    });

    it('sizes_phone_and_pad_host_picker_from_content_and_live_viewport', 0, (): void => {
      const phone = resolveSshHostPickerSheetLayout(360, 780, 4, true);
      expect(phone.bottomAnchored).assertTrue();
      expect(phone.widthVp).assertEqual(360);
      expect(phone.heightVp).assertEqual(324);

      const phoneLandscape = resolveSshHostPickerSheetLayout(780, 360, 20, true);
      expect(phoneLandscape.heightVp).assertEqual(336);

      const pad = resolveSshHostPickerSheetLayout(1024, 720, 2, false);
      expect(pad.bottomAnchored).assertFalse();
      expect(pad.widthVp).assertEqual(620);
      expect(pad.heightVp).assertEqual(240);

      const compactPad = resolveSshHostPickerSheetLayout(420, 300, 12, false);
      expect(compactPad.widthVp).assertEqual(388);
      expect(compactPad.heightVp).assertEqual(252);
    });

    it('uses_inline_normal_tabs_only_after_the_safe_width_threshold', 0, (): void => {
      const narrow = resolveSshTabChromeLayout(SSH_TAB_INLINE_MIN_VIEWPORT_VP - 1, 'lg');
      const wide = resolveSshTabChromeLayout(SSH_TAB_INLINE_MIN_VIEWPORT_VP, 'lg');
      expect(narrow.inlineAllowed).assertFalse();
      expect(wide.inlineAllowed).assertTrue();
      expect(wide.tabWidthVp).assertEqual(188);
      expect(wide.pinnedTabWidthVp).assertEqual(164);
    });

    it('keeps_twenty_tabs_in_the_scroll_region_instead_of_shrinking_hit_targets', 0,
      (): void => {
        const layout = resolveSshTabChromeLayout(360, 'sm');
        const contentWidth: number = 20 * sshTabWidthVp(true, false) + 19 * 6;
        expect(contentWidth > layout.scrollViewportWidthVp).assertTrue();
        expect(sshTabWidthVp(true, true)).assertEqual(126);
      });

    it('never_enables_compact_chrome_while_the_workbench_flag_is_off', 0, (): void => {
      expect(sshCompactChromeEnabled(false, 360, 'md')).assertFalse();
      expect(sshCompactChromeEnabled(false, 360, 'sm')).assertFalse();
      expect(sshCompactChromeEnabled(true, 360, 'md')).assertTrue();
    });

    it('moves_the_legacy_new_session_action_into_the_header_menu', 0, (): void => {
      expect(sshTabStripShowsStandaloneNewSessionAction(true)).assertFalse();
      expect(sshTabStripShowsStandaloneNewSessionAction(false)).assertTrue();
    });

    it('uses_one_header_menu_on_every_device_shape_and_rollout_state', 0, (): void => {
      expect(sshHeaderUsesSingleActionMenu(false, true, false)).assertTrue();
      expect(sshHeaderUsesSingleActionMenu(false, false, true)).assertTrue();
      expect(sshHeaderUsesSingleActionMenu(false, false, false)).assertTrue();
      expect(sshHeaderUsesSingleActionMenu(true, true, false)).assertTrue();
    });
  });
}
