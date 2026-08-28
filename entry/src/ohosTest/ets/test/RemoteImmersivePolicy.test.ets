import { describe, it, expect } from '@ohos/hypium';
import {
  shouldHideRemoteNavigation,
  shouldHideRemoteStatusBar,
  shouldReapplyRemoteNavigation,
  shouldRestoreRemoteNavigation
} from '../../../main/ets/services/RemoteImmersivePolicy';

export default function remoteImmersivePolicyTest(): void {
  describe('RemoteImmersivePolicy', (): void => {
    it('hides_navigation_for_every_connected_remote_desktop_protocol', 0, (): void => {
      expect(shouldHideRemoteNavigation('rdp', true)).assertTrue();
      expect(shouldHideRemoteNavigation('rustdesk', true)).assertTrue();
      expect(shouldHideRemoteNavigation('vnc', true)).assertTrue();
      expect(shouldHideRemoteNavigation('moonlight', true)).assertTrue();
      expect(shouldHideRemoteNavigation('ssh', true)).assertTrue();
      expect(shouldHideRemoteNavigation('rdp', false)).assertFalse();
    });

    it('hides_status_bar_for_every_mobile_remote_session_mode', 0, (): void => {
      expect(shouldHideRemoteStatusBar('rustdesk', true, false, 'sm', 2)).assertTrue();
      expect(shouldHideRemoteStatusBar('rustdesk', true, false, 'lg', 2)).assertTrue();
      expect(shouldHideRemoteStatusBar('rustdesk', true, false, 'sm', 0)).assertTrue();
      expect(shouldHideRemoteStatusBar('rustdesk', true, true, 'xl', 2)).assertFalse();
      expect(shouldHideRemoteStatusBar('rdp', true, false, 'sm', 0)).assertTrue();
      expect(shouldHideRemoteStatusBar('rdp', true, false, 'lg', 2)).assertTrue();
      expect(shouldHideRemoteStatusBar('vnc', true, false, 'sm', 0)).assertTrue();
      expect(shouldHideRemoteStatusBar('vnc', true, false, 'lg', 2)).assertTrue();
      expect(shouldHideRemoteStatusBar('vnc', true, true, 'xl', 2)).assertFalse();
      expect(shouldHideRemoteStatusBar('rdp', true, true, 'xl', 0)).assertFalse();
      expect(shouldHideRemoteStatusBar('moonlight', true, false, 'sm', 0)).assertTrue();
      expect(shouldHideRemoteStatusBar('ssh', true, false, 'sm', 0)).assertTrue();
      expect(shouldHideRemoteStatusBar('ssh', true, true, 'xl', 0)).assertFalse();
      expect(shouldHideRemoteStatusBar('rustdesk', false, false, 'sm', 2)).assertFalse();
    });

    it('reapplies_navigation_hide_after_preserved_foreground_restore', 0, (): void => {
      expect(shouldReapplyRemoteNavigation('rustdesk', true, true)).assertTrue();
      expect(shouldReapplyRemoteNavigation('vnc', true, true)).assertTrue();
      expect(shouldReapplyRemoteNavigation('rdp', true, false)).assertFalse();
      expect(shouldReapplyRemoteNavigation('ssh', true, true)).assertTrue();
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
