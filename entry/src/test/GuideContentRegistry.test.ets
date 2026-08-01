import { describe, it, expect } from '@ohos/hypium';
import {
  firstInstallGuidePages,
  GuideContentPage,
  settingsUsageGuidePages
} from '../main/ets/services/GuideContentRegistry';

function containsPage(pages: GuideContentPage[], id: string): boolean {
  return pages.some((page: GuideContentPage): boolean => page.id === id);
}

export default function guideContentRegistryTest(): void {
  describe('GuideContentRegistry', (): void => {
    it('keeps_first_install_and_settings_guides_equal_except_final_page', 0, (): void => {
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
      expect(firstInstall[firstInstall.length - 1].title).assertEqual('从第一台主机开始');
      expect(settings[settings.length - 1].title).assertEqual('需要时随时回来');
    });

    it('covers_current_user_facing_capabilities', 0, (): void => {
      const pages: GuideContentPage[] = firstInstallGuidePages();
      expect(containsPage(pages, 'four-protocol-workspace')).assertTrue();
      expect(containsPage(pages, 'add-and-organize')).assertTrue();
      expect(containsPage(pages, 'verify-before-trust')).assertTrue();
      expect(containsPage(pages, 'session-controls')).assertTrue();
      expect(containsPage(pages, 'files-and-tools')).assertTrue();
      expect(containsPage(pages, 'cloud-and-backup')).assertTrue();
    });

    it('uses_unique_non_empty_page_content', 0, (): void => {
      const pages: GuideContentPage[] = firstInstallGuidePages();
      const ids = new Set<string>();
      pages.forEach((page: GuideContentPage): void => {
        expect(page.id.length > 0).assertTrue();
        expect(page.title.length > 0).assertTrue();
        expect(page.desc.length > 0).assertTrue();
        expect(ids.has(page.id)).assertFalse();
        ids.add(page.id);
      });
    });
  });
}
