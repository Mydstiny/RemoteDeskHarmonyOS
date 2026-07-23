import { describe, it, expect } from '@ohos/hypium';
import {
  CURRENT_RELEASE_VERSION,
  pagesForReleasedVersion,
  ReleaseNotePage
} from '../main/ets/services/ReleaseNotesRegistry';

function containsPage(pages: ReleaseNotePage[], id: string): boolean {
  return pages.some((page: ReleaseNotePage): boolean => page.id === id);
}

export default function releaseNotesRegistryTest(): void {
  describe('ReleaseNotesRegistry', (): void => {
    it('describes_the_complete_1_0_8_update', 0, (): void => {
      const pages: ReleaseNotePage[] = pagesForReleasedVersion(CURRENT_RELEASE_VERSION);
      expect(pages.length).assertEqual(8);
      expect(containsPage(pages, 'background-video-pip')).assertTrue();
      expect(containsPage(pages, 'avsession-media-identity')).assertTrue();
      expect(containsPage(pages, 'native-vp9-background-crash')).assertTrue();
      expect(containsPage(pages, 'pip-frame-lifecycle')).assertTrue();
      expect(containsPage(pages, 'grip-permission-startup')).assertTrue();
      expect(containsPage(pages, 'onboarding-rewrite')).assertTrue();
      expect(containsPage(pages, 'responsive-guide-sheets')).assertTrue();
      expect(pages[pages.length - 1].id).assertEqual('welcome-1-0-8');
      expect(pages[pages.length - 1].title).assertEqual('欢迎使用 1.0.8');
    });

    it('does_not_advertise_removed_host_features', 0, (): void => {
      const pages: ReleaseNotePage[] = pagesForReleasedVersion(CURRENT_RELEASE_VERSION);
      pages.forEach((page: ReleaseNotePage): void => {
        const content = page.title + page.desc;
        expect(content.indexOf('收藏')).assertEqual(-1);
        expect(content.indexOf('最近使用')).assertEqual(-1);
        expect(content.indexOf('名称排序')).assertEqual(-1);
      });
    });

    it('returns_no_pages_for_unreleased_versions', 0, (): void => {
      expect(pagesForReleasedVersion('1.0.9').length).assertEqual(0);
    });
  });
}
