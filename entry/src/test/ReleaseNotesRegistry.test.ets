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
    it('describes_the_current_1_1_4_release_without_removing_1_1_3_pages', 0, (): void => {
      const pages: ReleaseNotePage[] = pagesForReleasedVersion(CURRENT_RELEASE_VERSION);
      expect(pages.length).assertEqual(22);
      expect(containsPage(pages, 'release-1-1-4')).assertTrue();
      expect(containsPage(pages, 'release-secret-visibility')).assertTrue();
      expect(containsPage(pages, 'release-clipboard-activation')).assertTrue();
      expect(containsPage(pages, 'release-app-clone')).assertTrue();
      expect(containsPage(pages, 'release-rustdesk-mobile')).assertTrue();
      expect(containsPage(pages, 'release-session-ui-stability')).assertTrue();
      expect(containsPage(pages, 'release-cloud-recovery')).assertTrue();
      expect(containsPage(pages, 'release-rustdesk-desktop-flip')).assertTrue();
      expect(containsPage(pages, 'release-wheel-direction')).assertTrue();
      expect(containsPage(pages, 'release-1-1-3')).assertTrue();
      expect(containsPage(pages, 'release-moonlight-workflow')).assertTrue();
      expect(containsPage(pages, 'release-moonlight-session')).assertTrue();
      expect(containsPage(pages, 'release-ssh-workspace')).assertTrue();
      expect(containsPage(pages, 'release-ssh-productivity')).assertTrue();
      expect(containsPage(pages, 'release-session-keyboard')).assertTrue();
      expect(containsPage(pages, 'release-device-layouts')).assertTrue();
      expect(containsPage(pages, 'release-lan-discovery')).assertTrue();
      expect(containsPage(pages, 'release-security-preflight')).assertTrue();
      expect(containsPage(pages, 'release-guidance')).assertTrue();
      expect(containsPage(pages, 'release-data-diagnostics')).assertTrue();
      expect(containsPage(pages, 'welcome-1-1-3')).assertTrue();
      expect(pages[pages.length - 1].id).assertEqual('welcome-1-1-4');
      expect(pages[pages.length - 1].title).assertEqual('欢迎使用 1.1.4');
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
      expect(pagesForReleasedVersion('1.1.1').length).assertEqual(0);
    });
  });
}
