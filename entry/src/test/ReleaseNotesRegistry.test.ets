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
    it('describes_the_complete_1_1_0_update', 0, (): void => {
      const pages: ReleaseNotePage[] = pagesForReleasedVersion(CURRENT_RELEASE_VERSION);
      expect(pages.length).assertEqual(7);
      expect(containsPage(pages, 'release-1-1-0')).assertTrue();
      expect(containsPage(pages, 'release-four-protocols')).assertTrue();
      expect(containsPage(pages, 'release-input-performance')).assertTrue();
      expect(containsPage(pages, 'release-cloud-recovery')).assertTrue();
      expect(containsPage(pages, 'release-security-boundaries')).assertTrue();
      expect(containsPage(pages, 'release-rustdesk-workflow')).assertTrue();
      expect(pages[pages.length - 1].id).assertEqual('welcome-1-1-0');
      expect(pages[pages.length - 1].title).assertEqual('欢迎使用 1.1.0');
    });

    it('does_not_advertise_unverified_or_removed_features', 0, (): void => {
      const pages: ReleaseNotePage[] = pagesForReleasedVersion(CURRENT_RELEASE_VERSION);
      pages.forEach((page: ReleaseNotePage): void => {
        const content = page.title + page.desc;
        expect(content.indexOf('收藏')).assertEqual(-1);
        expect(content.indexOf('最近使用')).assertEqual(-1);
        expect(content.indexOf('名称排序')).assertEqual(-1);
        expect(content.indexOf('AUTO/P2P 已可用')).assertEqual(-1);
      });
    });

    it('returns_no_pages_for_unreleased_versions', 0, (): void => {
      expect(pagesForReleasedVersion('1.0.8').length).assertEqual(0);
      expect(pagesForReleasedVersion('1.0.10').length).assertEqual(0);
    });
  });
}
