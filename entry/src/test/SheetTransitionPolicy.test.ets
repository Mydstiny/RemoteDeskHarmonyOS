import { describe, it, expect } from '@ohos/hypium';
import {
  SHEET_DISMISS_GUARD_MS,
  sheetOpenDelayMsAfterDismiss,
  shouldDelaySheetOpen,
  noteSshSftpSheetDismissed,
  sshSftpSheetOpenDelayMs,
  sftpPeerPickerExitPending,
  shouldMountSftpPeerPicker,
  shouldCommitSftpPeerSelection,
  shouldAllowSftpRootSheetDismiss,
  shouldUseSftpExpandedWorkspace,
  sftpExpandedWorkspaceMinHeight,
  shouldDriveSftpNativeDismissAction
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

    it('shares_sftp_exit_guard_with_the_host_list_route', 0, (): void => {
      noteSshSftpSheetDismissed(2000);
      expect(sshSftpSheetOpenDelayMs(2080)).assertEqual(SHEET_DISMISS_GUARD_MS - 80);
      expect(sshSftpSheetOpenDelayMs(2320)).assertEqual(0);
    });

    it('keeps_parent_mounted_until_nested_picker_disappears', 0, (): void => {
      expect(sftpPeerPickerExitPending(true, false)).assertTrue();
      expect(sftpPeerPickerExitPending(false, true)).assertTrue();
      expect(sftpPeerPickerExitPending(false, false)).assertFalse();
    });

    it('mounts_nested_picker_only_after_parent_surface_is_live', 0, (): void => {
      const base = {
        openRequested: true,
        parentVisible: true,
        parentSurfaceReady: true,
        rootSheetVisible: true,
        rootSheetRequired: true,
        rootClosing: false,
        closeRootAfterPicker: false,
        pickerVisible: false,
        pickerClosing: false
      };
      expect(shouldMountSftpPeerPicker(base)).assertTrue();
      expect(shouldMountSftpPeerPicker({ ...base, rootSheetVisible: false })).assertFalse();
      expect(shouldMountSftpPeerPicker({ ...base, parentSurfaceReady: false })).assertFalse();
      expect(shouldMountSftpPeerPicker({ ...base, openRequested: false })).assertFalse();
      expect(shouldMountSftpPeerPicker({ ...base, pickerClosing: true })).assertFalse();
    });

    it('commits_peer_selection_only_after_child_sheet_disappears', 0, (): void => {
      const base = {
        pendingHostId: 'host-oracle',
        pendingSelectionEpoch: 7,
        activeSelectionEpoch: 7,
        parentVisible: true,
        rootClosing: false,
        pickerVisible: false,
        pickerClosing: false
      };
      expect(shouldCommitSftpPeerSelection(base)).assertTrue();
      expect(shouldCommitSftpPeerSelection({ ...base, pickerVisible: true })).assertFalse();
      expect(shouldCommitSftpPeerSelection({ ...base, pickerClosing: true })).assertFalse();
      expect(shouldCommitSftpPeerSelection({ ...base, rootClosing: true })).assertFalse();
      expect(shouldCommitSftpPeerSelection({ ...base, activeSelectionEpoch: 8 })).assertFalse();
      expect(shouldCommitSftpPeerSelection({ ...base, pendingHostId: '' })).assertFalse();
    });

    it('defers_interactive_root_dismissal_until_surface_is_ready', 0, (): void => {
      const base = {
        mountMatches: true,
        rootSurfaceReady: true,
        programmaticClose: false,
        transferBusy: false
      };
      expect(shouldAllowSftpRootSheetDismiss({ ...base, rootSurfaceReady: false })).assertFalse();
      expect(shouldAllowSftpRootSheetDismiss({ ...base, transferBusy: true })).assertFalse();
      expect(shouldAllowSftpRootSheetDismiss(base)).assertTrue();
    });

    it('allows_an_explicit_root_close_during_open_or_transfer', 0, (): void => {
      expect(shouldAllowSftpRootSheetDismiss({
        mountMatches: true,
        rootSurfaceReady: false,
        programmaticClose: true,
        transferBusy: true
      })).assertTrue();
      expect(shouldAllowSftpRootSheetDismiss({
        mountMatches: false,
        rootSurfaceReady: true,
        programmaticClose: true,
        transferBusy: false
      })).assertFalse();
    });

    it('uses_a_compact_pad_pc_workspace_when_either_axis_is_narrow', 0, (): void => {
      expect(shouldUseSftpExpandedWorkspace(true, false, 1280, 760)).assertTrue();
      expect(shouldUseSftpExpandedWorkspace(false, true, 800, 760)).assertFalse();
      expect(shouldUseSftpExpandedWorkspace(true, false, 1280, 500)).assertFalse();
      expect(shouldUseSftpExpandedWorkspace(false, false, 1280, 760)).assertFalse();
    });

    it('keeps_footer_actions_reachable_in_short_wide_workspaces', 0, (): void => {
      expect(sftpExpandedWorkspaceMinHeight(false, false)).assertEqual(150);
      expect(sftpExpandedWorkspaceMinHeight(true, false)).assertEqual(150);
      expect(sftpExpandedWorkspaceMinHeight(false, true)).assertEqual(150);
    });

    it('uses_only_one_native_dismiss_driver', 0, (): void => {
      expect(shouldDriveSftpNativeDismissAction(true, false)).assertTrue();
      expect(shouldDriveSftpNativeDismissAction(true, true)).assertFalse();
      expect(shouldDriveSftpNativeDismissAction(false, false)).assertFalse();
    });
  });
}
