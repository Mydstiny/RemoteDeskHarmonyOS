import { describe, it, expect } from '@ohos/hypium';
import {
  shouldHideRemoteNavigation,
  shouldReapplyRemoteNavigation,
  shouldRestoreRemoteNavigation
} from '../main/ets/services/RemoteImmersivePolicy';

export default function remoteImmersivePolicyTest(): void {
  describe('RemoteImmersivePolicy', (): void => {
    it('hides_navigation_only_for_connected_rdp_and_rustdesk', 0, (): void => {
      expect(shouldHideRemoteNavigation('rdp', true)).assertTrue();
      expect(shouldHideRemoteNavigation('rustdesk', true)).assertTrue();
      expect(shouldHideRemoteNavigation('ssh', true)).assertFalse();
      expect(shouldHideRemoteNavigation('vnc', true)).assertFalse();
      expect(shouldHideRemoteNavigation('rdp', false)).assertFalse();
    });

    it('reapplies_navigation_hide_after_preserved_foreground_restore', 0, (): void => {
      expect(shouldReapplyRemoteNavigation('rustdesk', true, true)).assertTrue();
      expect(shouldReapplyRemoteNavigation('rdp', true, false)).assertFalse();
      expect(shouldReapplyRemoteNavigation('ssh', true, true)).assertFalse();
      expect(shouldReapplyRemoteNavigation('rdp', false, true)).assertFalse();
    });

    it('restores_navigation_for_explicit_exit_but_not_background_preserve', 0, (): void => {
      expect(shouldRestoreRemoteNavigation('explicit-exit', false)).assertTrue();
      expect(shouldRestoreRemoteNavigation('pc-disconnect-button', false)).assertTrue();
      expect(shouldRestoreRemoteNavigation('connect-failed', false)).assertTrue();
      expect(shouldRestoreRemoteNavigation('background-preserve', true)).assertFalse();
    });
  });
}
