import { describe, it, expect } from '@ohos/hypium';
import {
  SHEET_DISMISS_GUARD_MS,
  sheetOpenDelayMsAfterDismiss,
  shouldDelaySheetOpen,
  noteSshSftpSheetDismissed,
  sshSftpSheetOpenDelayMs,
  sftpPeerPickerExitPending,
  shouldMountSftpPeerPicker
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
        rootSheetVisible: true,
        rootSheetRequired: true,
        rootClosing: false,
        closeRootAfterPicker: false,
        pickerVisible: false,
        pickerClosing: false
      };
      expect(shouldMountSftpPeerPicker(base)).assertTrue();
      expect(shouldMountSftpPeerPicker({ ...base, rootSheetVisible: false })).assertFalse();
      expect(shouldMountSftpPeerPicker({ ...base, openRequested: false })).assertFalse();
      expect(shouldMountSftpPeerPicker({ ...base, pickerClosing: true })).assertFalse();
    });
  });
}
