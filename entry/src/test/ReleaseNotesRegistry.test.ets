import { describe, it, expect } from '@ohos/hypium';
import {
  CURRENT_RELEASE_VERSION,
  currentReleasePageCount,
  pagesForReleasedVersion,
  ReleaseNotePage
} from '../main/ets/services/ReleaseNotesRegistry';

function containsPage(pages: ReleaseNotePage[], id: string): boolean {
  return pages.some((page: ReleaseNotePage): boolean => page.id === id);
}

export default function releaseNotesRegistryTest(): void {
  describe('ReleaseNotesRegistry', (): void => {
    it('describes_the_current_1_1_5_1_release_in_exactly_fourteen_pages', 0, (): void => {
      const pages: ReleaseNotePage[] = pagesForReleasedVersion(CURRENT_RELEASE_VERSION);
      expect(pages.length).assertEqual(14);
      expect(currentReleasePageCount()).assertEqual(pages.length);
      expect(pages.length <= 14).assertTrue();
      expect(containsPage(pages, 'release-1-1-5-1')).assertTrue();
      expect(containsPage(pages, 'release-flip-fallback-diagnostics')).assertTrue();
      expect(containsPage(pages, 'release-rdp-ephemeral-auth')).assertTrue();
      expect(containsPage(pages, 'release-rdp-pointer-mapping')).assertTrue();
      expect(containsPage(pages, 'release-rustdesk-toolbar')).assertTrue();
      expect(containsPage(pages, 'release-rustdesk-codec-telemetry')).assertTrue();
      expect(containsPage(pages, 'release-rdp-resolution-scaling')).assertTrue();
      expect(containsPage(pages, 'release-dock-input-fence')).assertTrue();
      expect(containsPage(pages, 'release-ssh-common-commands')).assertTrue();
      expect(containsPage(pages, 'release-protected-exit')).assertTrue();
      expect(containsPage(pages, 'release-rustdesk-clipboard')).assertTrue();
      expect(containsPage(pages, 'release-host-list-safe-area')).assertTrue();
      expect(containsPage(pages, 'release-harmony-shortcut-capture')).assertTrue();
      expect(containsPage(pages, 'release-1-1-5')).assertFalse();
      expect(containsPage(pages, 'release-1-1-4')).assertFalse();
      expect(containsPage(pages, 'welcome-1-1-4')).assertFalse();
      expect(containsPage(pages, 'release-1-1-3')).assertFalse();
      expect(containsPage(pages, 'welcome-1-1-3')).assertFalse();
      expect(pages[pages.length - 1].id).assertEqual('welcome-1-1-5-1');
      expect(pages[pages.length - 1].title).assertEqual('更新完成，等待实机验收');
      let currentVersionPages: number = 0;
      pages.forEach((page: ReleaseNotePage): void => {
        const content: string = page.title + page.desc;
        if (content.indexOf(CURRENT_RELEASE_VERSION) >= 0) { currentVersionPages += 1; }
      });
      expect(currentVersionPages).assertEqual(1);
    });

    it('keeps_the_1_1_5_pages_available_only_for_their_version', 0, (): void => {
      const pages: ReleaseNotePage[] = pagesForReleasedVersion('1.1.5');
      expect(pages.length).assertEqual(14);
      expect(pages[0].id).assertEqual('release-1-1-5');
      expect(containsPage(pages, 'release-secret-visibility')).assertTrue();
      expect(containsPage(pages, 'release-rustdesk-desktop-flip')).assertTrue();
      expect(containsPage(pages, 'release-rdp-adaptive-display')).assertTrue();
      expect(containsPage(pages, 'release-1-1-5-1')).assertFalse();
      expect(pages[pages.length - 1].id).assertEqual('welcome-1-1-5');
    });

    it('keeps_the_1_1_4_pages_available_only_for_their_version', 0, (): void => {
      const pages: ReleaseNotePage[] = pagesForReleasedVersion('1.1.4');
      expect(pages.length).assertEqual(10);
      expect(pages[0].id).assertEqual('release-1-1-4');
      expect(containsPage(pages, 'release-secret-visibility')).assertTrue();
      expect(containsPage(pages, 'release-rustdesk-desktop-flip')).assertTrue();
      expect(containsPage(pages, 'release-network-diagnostics')).assertFalse();
      expect(pages[pages.length - 1].id).assertEqual('welcome-1-1-4');
    });

    it('keeps_the_1_1_3_pages_available_only_for_their_version', 0, (): void => {
      const pages: ReleaseNotePage[] = pagesForReleasedVersion('1.1.3');
      expect(pages.length).assertEqual(12);
      expect(pages[0].id).assertEqual('release-1-1-3');
      expect(containsPage(pages, 'release-moonlight-workflow')).assertTrue();
      expect(containsPage(pages, 'release-ssh-workspace')).assertTrue();
      expect(containsPage(pages, 'release-guidance')).assertTrue();
      expect(pages[pages.length - 1].id).assertEqual('welcome-1-1-3');
    });

    it('does_not_advertise_unverified_or_removed_features', 0, (): void => {
      const pages: ReleaseNotePage[] = pagesForReleasedVersion(CURRENT_RELEASE_VERSION);
      pages.forEach((page: ReleaseNotePage): void => {
        const content = page.title + page.desc;
        expect(content.indexOf('收藏')).assertEqual(-1);
        expect(content.indexOf('最近使用')).assertEqual(-1);
        expect(content.indexOf('排序')).assertEqual(-1);
        expect(content.indexOf('AUTO/P2P 已可用')).assertEqual(-1);
      });
    });

    it('returns_no_pages_for_unreleased_versions', 0, (): void => {
      expect(pagesForReleasedVersion('1.0.8').length).assertEqual(0);
      expect(pagesForReleasedVersion('1.1.1').length).assertEqual(0);
    });
  });
}
