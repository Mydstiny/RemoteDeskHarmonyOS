import { describe, it, expect } from '@ohos/hypium';
import {
  firstInstallGuidePages,
  GuideContentPage,
  settingsUsageGuidePages
} from '../../../main/ets/services/GuideContentRegistry';
import {
  CURRENT_RELEASE_VERSION,
  pagesForReleasedVersion,
  ReleaseNotePage
} from '../../../main/ets/services/ReleaseNotesRegistry';

function containsGuidePage(pages: GuideContentPage[], id: string): boolean {
  return pages.some((page: GuideContentPage): boolean => page.id === id);
}

function containsReleasePage(pages: ReleaseNotePage[], id: string): boolean {
  return pages.some((page: ReleaseNotePage): boolean => page.id === id);
}

export default function guideContentRegistryTest(): void {
  describe('GuideContentRegistry', (): void => {
    it('keeps_both_guides_equal_except_the_final_page', 0, (): void => {
      const firstInstall: GuideContentPage[] = firstInstallGuidePages();
      const settings: GuideContentPage[] = settingsUsageGuidePages();
      expect(firstInstall.length).assertEqual(7);
      expect(settings.length).assertEqual(firstInstall.length);
      for (let i = 0; i < firstInstall.length - 1; i++) {
        expect(settings[i].id).assertEqual(firstInstall[i].id);
        expect(settings[i].title).assertEqual(firstInstall[i].title);
        expect(settings[i].desc).assertEqual(firstInstall[i].desc);
      }
      expect(firstInstall[firstInstall.length - 1].id).assertEqual('start-first-host');
      expect(settings[settings.length - 1].id).assertEqual('revisit');
    });

    it('covers_current_features_and_the_complete_release', 0, (): void => {
      const guide: GuideContentPage[] = firstInstallGuidePages();
      const release: ReleaseNotePage[] = pagesForReleasedVersion(CURRENT_RELEASE_VERSION);
      expect(containsGuidePage(guide, 'welcome-five-protocols')).assertTrue();
      expect(containsGuidePage(guide, 'session-toolkit')).assertTrue();
      expect(containsGuidePage(guide, 'data-recovery-and-help')).assertTrue();
      expect(release.length).assertEqual(12);
      expect(containsReleasePage(release, 'release-1-1-3')).assertTrue();
      expect(containsReleasePage(release, 'release-moonlight-workflow')).assertTrue();
      expect(containsReleasePage(release, 'release-ssh-workspace')).assertTrue();
      expect(containsReleasePage(release, 'release-guidance')).assertTrue();
      expect(release[release.length - 1].id).assertEqual('welcome-1-1-3');
    });
  });
}
