import { describe, it, expect } from '@ohos/hypium';
import {
  makeSshXtermTabCoreKey,
  matchesSshXtermCopyFence,
  shouldMountSshXtermTab,
  shouldReloadSshXtermTab,
  shouldRestoreSshXtermTabTranscript,
  sshXtermTabRenderRevision
} from '../main/ets/services/SshXtermTabSurfacePolicy';

export default function sshXtermTabSurfacePolicyTest(): void {
  describe('SshXtermTabSurfacePolicy', (): void => {
    it('mounts_only_the_visible_xterm_document_on_touch_devices', 0, (): void => {
      expect(shouldMountSshXtermTab(false, true)).assertTrue();
      expect(shouldMountSshXtermTab(false, false)).assertFalse();
      expect(shouldMountSshXtermTab(true, true)).assertTrue();
      expect(shouldMountSshXtermTab(true, false)).assertTrue();
    });

    it('keeps_the_document_identity_when_only_active_tab_changes', 0, (): void => {
      const coreKey: string = makeSshXtermTabCoreKey('host-a');
      expect(coreKey).assertEqual('host-a:xterm');
      expect(shouldReloadSshXtermTab(coreKey, coreKey, 7, 7)).assertFalse();
    });

    it('reloads_only_when_the_host_or_session_revision_changes', 0, (): void => {
      const coreKey: string = makeSshXtermTabCoreKey('host-a');
      expect(shouldReloadSshXtermTab(coreKey, coreKey, 7, 8)).assertTrue();
      expect(shouldReloadSshXtermTab(coreKey, makeSshXtermTabCoreKey('host-b'), 7, 7))
        .assertTrue();
      expect(sshXtermTabRenderRevision(-3)).assertEqual(0);
      expect(sshXtermTabRenderRevision(8.9)).assertEqual(8);
    });

    it('restores_the_transcript_when_a_touch_tab_document_is_remounted', 0, (): void => {
      expect(shouldRestoreSshXtermTabTranscript(undefined, 1, false)).assertFalse();
      expect(shouldRestoreSshXtermTabTranscript(0, 1, false)).assertTrue();
      expect(shouldRestoreSshXtermTabTranscript(1, 1, false)).assertFalse();
      expect(shouldRestoreSshXtermTabTranscript(1, 1, true)).assertTrue();
    });

    it('rejects_copy_results_from_replaced_or_superseded_documents', 0, (): void => {
      expect(matchesSshXtermCopyFence(
        4, 'host-a:xterm:render:7', 9,
        4, 'host-a:xterm:render:7', 9, true)).assertTrue();
      expect(matchesSshXtermCopyFence(
        4, 'host-a:xterm:render:7', 9,
        5, 'host-a:xterm:render:7', 9, true)).assertFalse();
      expect(matchesSshXtermCopyFence(
        4, 'host-a:xterm:render:7', 9,
        4, 'host-b:xterm:render:7', 9, true)).assertFalse();
      expect(matchesSshXtermCopyFence(
        4, 'host-a:xterm:render:7', 9,
        4, 'host-a:xterm:render:7', 10, true)).assertFalse();
      expect(matchesSshXtermCopyFence(
        4, 'host-a:xterm:render:7', 9,
        4, 'host-a:xterm:render:7', 9, false)).assertFalse();
    });
  });
}
