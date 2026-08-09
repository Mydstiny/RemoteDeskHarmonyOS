import { describe, it, expect } from '@ohos/hypium';
import {
  makeSshXtermTabCoreKey,
  shouldReloadSshXtermTab,
  sshXtermTabRenderRevision
} from '../main/ets/services/SshXtermTabSurfacePolicy';

export default function sshXtermTabSurfacePolicyTest(): void {
  describe('SshXtermTabSurfacePolicy', (): void => {
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
  });
}
