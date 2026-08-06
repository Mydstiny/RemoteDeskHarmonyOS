/** SshTerminalTabStore.test.ets - SSH tab ownership and cleanup policy. */

import { describe, it, expect } from '@ohos/hypium';
import { SshTerminalTabStore } from '../main/ets/services/SshTerminalTabStore';

export default function sshTerminalTabStoreTest(): void {
  describe('SshTerminalTabStore', (): void => {
    it('should_keep_one_tab_per_host_and_switch_active_host', 0, (): void => {
      const store: SshTerminalTabStore = new SshTerminalTabStore();
      store.open('host-a', 'A', 'root@a:22');
      store.open('host-b', 'B', 'root@b:22');
      store.activate('host-b');

      const views = store.views();
      expect(views.length).assertEqual(2);
      expect(views[0].active).assertFalse();
      expect(views[1].active).assertTrue();

      store.open('host-b', 'B updated', 'root@b:2222');
      expect(store.views().length).assertEqual(2);
      expect(store.views()[1].address).assertEqual('root@b:2222');
    });

    it('should_return_all_bound_sessions_when_closing', 0, (): void => {
      const store: SshTerminalTabStore = new SshTerminalTabStore();
      store.open('host-a', 'A', 'root@a:22');
      store.open('host-b', 'B', 'root@b:22');
      store.update('host-a', 'connected', 101);
      store.update('host-b', 'connected', 202);

      const sessionIds: number[] = store.closeAll();
      expect(sessionIds.length).assertEqual(2);
      expect(sessionIds[0]).assertEqual(101);
      expect(sessionIds[1]).assertEqual(202);
      expect(store.views().length).assertEqual(0);
    });

    it('should_serialize_route_navigation_until_the_previous_page_is_detached', 0, (): void => {
      const store: SshTerminalTabStore = new SshTerminalTabStore();
      store.open('host-a', 'A', 'root@a:22');
      store.open('host-b', 'B', 'root@b:22');

      expect(store.beginNavigation('host-b')).assertTrue();
      expect(store.beginNavigation('host-a')).assertFalse();
      expect(store.isNavigationPending()).assertTrue();

      store.completeNavigation();
      expect(store.isNavigationPending()).assertFalse();
      expect(store.beginNavigation('host-a')).assertTrue();
      store.cancelNavigation('host-a');
      expect(store.isNavigationPending()).assertFalse();
    });
  });
}
