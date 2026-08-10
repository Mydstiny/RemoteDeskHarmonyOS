import { describe, it, expect } from '@ohos/hypium';
import {
  resolveStartupMode,
  shouldPresentGuideAsBottomSheet,
  shouldPresentGuideAsCenterSheet,
  StartupMode
} from '../main/ets/services/ReleaseNotesPolicy';

export default function releaseNotesPolicyTest(): void {
  describe('ReleaseNotesPolicy', (): void => {
    it('selects_first_install_guide', 0, (): void => {
      expect(resolveStartupMode(false, '', '1.1.0', true)).assertEqual(StartupMode.FIRST_INSTALL_GUIDE);
    });
    it('selects_release_notes_once_after_upgrade', 0, (): void => {
      expect(resolveStartupMode(true, '', '1.1.0', true)).assertEqual(StartupMode.RELEASE_NOTES);
      expect(resolveStartupMode(true, '1.0.10', '1.1.0', true)).assertEqual(StartupMode.RELEASE_NOTES);
      expect(resolveStartupMode(true, '1.1.0', '1.1.0', true)).assertEqual(StartupMode.LOGIN);
      expect(resolveStartupMode(true, '1.1.0', '1.0.10', true)).assertEqual(StartupMode.LOGIN);
    });
    it('rejects_invalid_release_versions', 0, (): void => {
      expect(resolveStartupMode(true, 'bad', '1.1.0', true)).assertEqual(StartupMode.LOGIN);
    });
    it('forces_release_notes_for_explicit_acceptance_review', 0, (): void => {
      expect(resolveStartupMode(false, '', '1.1.0', true, true)).assertEqual(StartupMode.RELEASE_NOTES);
      expect(resolveStartupMode(true, '1.1.0', '1.1.0', true, true)).assertEqual(StartupMode.RELEASE_NOTES);
      expect(resolveStartupMode(true, '1.1.0', 'bad', true, true)).assertEqual(StartupMode.LOGIN);
      expect(resolveStartupMode(true, '1.1.0', '1.1.0', false, true)).assertEqual(StartupMode.LOGIN);
    });
    it('keeps_first_install_guide_in_page_content', 0, (): void => {
      expect(shouldPresentGuideAsBottomSheet(StartupMode.FIRST_INSTALL_GUIDE, 'sm')).assertFalse();
      expect(shouldPresentGuideAsCenterSheet(StartupMode.FIRST_INSTALL_GUIDE, 'md')).assertFalse();
      expect(shouldPresentGuideAsCenterSheet(StartupMode.FIRST_INSTALL_GUIDE, 'xl')).assertFalse();
    });
    it('uses_bottom_sheet_for_phone_release_notes', 0, (): void => {
      expect(shouldPresentGuideAsBottomSheet(StartupMode.RELEASE_NOTES, 'sm')).assertTrue();
      expect(shouldPresentGuideAsBottomSheet(StartupMode.RELEASE_NOTES, 'md')).assertFalse();
      expect(shouldPresentGuideAsBottomSheet(StartupMode.LOGIN, 'sm')).assertFalse();
    });
    it('uses_center_sheet_for_pad_and_pc_release_notes', 0, (): void => {
      expect(shouldPresentGuideAsCenterSheet(StartupMode.RELEASE_NOTES, 'md')).assertTrue();
      expect(shouldPresentGuideAsCenterSheet(StartupMode.RELEASE_NOTES, 'xl')).assertTrue();
      expect(shouldPresentGuideAsCenterSheet(StartupMode.LOGIN, 'xl')).assertFalse();
    });
  });
}
