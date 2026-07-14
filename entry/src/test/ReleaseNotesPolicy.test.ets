import { describe, it, expect } from '@ohos/hypium';
import {
  resolveStartupMode,
  shouldPresentReleaseNotesAsDialog,
  StartupMode
} from '../main/ets/services/ReleaseNotesPolicy';

export default function releaseNotesPolicyTest(): void {
  describe('ReleaseNotesPolicy', (): void => {
    it('selects_first_install_guide', 0, (): void => {
      expect(resolveStartupMode(false, '', '1.0.6', true)).assertEqual(StartupMode.FIRST_INSTALL_GUIDE);
    });
    it('selects_release_notes_once_after_upgrade', 0, (): void => {
      expect(resolveStartupMode(true, '', '1.0.6', true)).assertEqual(StartupMode.RELEASE_NOTES);
      expect(resolveStartupMode(true, '1.0.5', '1.0.6', true)).assertEqual(StartupMode.RELEASE_NOTES);
      expect(resolveStartupMode(true, '1.0.6', '1.0.6', true)).assertEqual(StartupMode.LOGIN);
      expect(resolveStartupMode(true, '1.0.6', '1.0.5', true)).assertEqual(StartupMode.LOGIN);
    });
    it('rejects_invalid_release_versions', 0, (): void => {
      expect(resolveStartupMode(true, 'bad', '1.0.6', true)).assertEqual(StartupMode.LOGIN);
    });
    it('uses_dialog_for_release_notes_on_every_breakpoint', 0, (): void => {
      expect(shouldPresentReleaseNotesAsDialog(StartupMode.RELEASE_NOTES, 'sm')).assertTrue();
      expect(shouldPresentReleaseNotesAsDialog(StartupMode.RELEASE_NOTES, 'md')).assertTrue();
      expect(shouldPresentReleaseNotesAsDialog(StartupMode.RELEASE_NOTES, 'xl')).assertTrue();
      expect(shouldPresentReleaseNotesAsDialog(StartupMode.FIRST_INSTALL_GUIDE, 'xl')).assertFalse();
    });
  });
}
