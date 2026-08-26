/** SshTerminalTabStore.test.ets - SSH tab ownership and cleanup policy. */

import { describe, it, expect } from '@ohos/hypium';
import {
  sshTerminalTabChromeRenderKey,
  SshTerminalTabStore
} from '../main/ets/services/SshTerminalTabStore';

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

    it('should_publish_new_active_tab_without_an_inactive_intermediate_state', 0, (): void => {
      const store: SshTerminalTabStore = new SshTerminalTabStore();
      let notifications: number = 0;
      store.subscribe((): void => { notifications++; });

      store.open('host-a', 'A', 'root@a:22');
      notifications = 0;
      store.openAndActivate('host-b', 'B', 'root@b:22');

      const views = store.views();
      expect(notifications).assertEqual(1);
      expect(views.length).assertEqual(2);
      expect(views[0].active).assertFalse();
      expect(views[1].active).assertTrue();
      expect(views[1].state).assertEqual('connecting');
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

    it('should_clear_old_session_identity_when_a_tab_reconnects', 0, (): void => {
      const store: SshTerminalTabStore = new SshTerminalTabStore();
      store.open('host-a', 'A', 'root@a:22');
      store.update('host-a', 'connected', 101, '', 9);

      store.beginConnection('host-a');
      expect(store.sessionId('host-a')).assertEqual(-1);
      expect(store.sessionGeneration('host-a')).assertEqual(0);
      expect(store.views()[0].state).assertEqual('connecting');

      store.update('host-a', 'connected', 202, '', 10);
      store.invalidateSession('host-a', 'error', 'closed');
      expect(store.sessionId('host-a')).assertEqual(-1);
      expect(store.sessionGeneration('host-a')).assertEqual(0);
      expect(store.views()[0].state).assertEqual('error');
    });

    it('should_rebuild_only_tab_chrome_when_visible_metadata_changes', 0, (): void => {
      const store: SshTerminalTabStore = new SshTerminalTabStore();
      store.openAndActivate('host-a', 'A', 'root@a:22');
      const connectingKey: string = sshTerminalTabChromeRenderKey(store.views()[0]);

      store.update('host-a', 'connected', 101, '', 9);
      const connectedKey: string = sshTerminalTabChromeRenderKey(store.views()[0]);
      expect(connectedKey === connectingKey).assertFalse();

      store.renameDisplayTitle('host-a', 'Production shell');
      const renamedKey: string = sshTerminalTabChromeRenderKey(store.views()[0]);
      expect(renamedKey === connectedKey).assertFalse();

      store.setPinned('host-a', true);
      const pinnedKey: string = sshTerminalTabChromeRenderKey(store.views()[0]);
      expect(pinnedKey === renamedKey).assertFalse();
    });

    it('should_clear_startup_fence_when_update_publishes_new_generation', 0, (): void => {
      const store: SshTerminalTabStore = new SshTerminalTabStore();
      store.open('host-a', 'A', 'root@a:22');
      store.update('host-a', 'connected', 101, '', 9);
      const oldKey: string = 'host-a:101:9';
      store.markStartupExecutionKey(oldKey);
      expect(store.hasStartupExecutionKey(oldKey)).assertTrue();

      store.update('host-a', 'connected', 101, '', 10);

      expect(store.sessionId('host-a')).assertEqual(101);
      expect(store.sessionGeneration('host-a')).assertEqual(10);
      expect(store.hasStartupExecutionKey(oldKey)).assertFalse();
    });

    it('should_keep_startup_fence_across_page_rebind_until_session_replacement', 0, (): void => {
      const store: SshTerminalTabStore = new SshTerminalTabStore();
      store.open('host-a', 'A', 'root@a:22');
      store.update('host-a', 'connected', 101, '', 9);
      const firstKey: string = 'host-a:101:9';
      store.markStartupExecutionKey(firstKey);
      expect(store.hasStartupExecutionKey(firstKey)).assertTrue();

      // A page detach/recreate keeps the same native session identity.
      store.clearStartupExecutionKeysForHost('host-a', firstKey);
      expect(store.hasStartupExecutionKey(firstKey)).assertTrue();

      // A new generation replaces the native session and drops the old fence.
      store.clearStartupExecutionKeysForHost('host-a', 'host-a:202:10');
      expect(store.hasStartupExecutionKey(firstKey)).assertFalse();
      store.update('host-a', 'connected', 202, '', 10);
      store.beginConnection('host-a');
      expect(store.hasStartupExecutionKey('host-a:202:10')).assertFalse();
    });

    it('should_close_background_and_disconnected_tabs_without_moving_focus', 0, (): void => {
      const store: SshTerminalTabStore = new SshTerminalTabStore();
      store.openAndActivate('host-a', 'A', 'root@a:22');
      store.update('host-a', 'connected', 101, '', 4);
      store.open('host-b', 'B', 'root@b:22');
      store.invalidateSession('host-b', 'error', 'offline');

      const closed = store.close('host-b');
      expect(closed.closed).assertTrue();
      expect(closed.wasActive).assertFalse();
      expect(closed.sessionId).assertEqual(-1);
      expect(closed.nextActiveHostId).assertEqual('host-a');
      expect(store.views().length).assertEqual(1);
      expect(store.views()[0].active).assertTrue();
      expect(store.sessionId('host-a')).assertEqual(101);
      expect(store.sessionGeneration('host-a')).assertEqual(4);
    });

    it('should_choose_the_right_neighbor_when_closing_the_active_tab', 0, (): void => {
      const store: SshTerminalTabStore = new SshTerminalTabStore();
      store.open('host-a', 'A', 'root@a:22');
      store.openAndActivate('host-b', 'B', 'root@b:22');
      store.open('host-c', 'C', 'root@c:22');
      store.update('host-b', 'connected', 202, '', 8);

      const closed = store.close('host-b');
      expect(closed.closed).assertTrue();
      expect(closed.wasActive).assertTrue();
      expect(closed.sessionId).assertEqual(202);
      expect(closed.generation).assertEqual(8);
      expect(closed.nextActiveHostId).assertEqual('host-c');
      expect(store.views()[1].hostId).assertEqual('host-c');
      expect(store.views()[1].active).assertTrue();
    });

    it('should_group_pinned_tabs_and_reorder_without_changing_session_identity', 0, (): void => {
      const store: SshTerminalTabStore = new SshTerminalTabStore();
      store.open('host-a', 'A', 'root@a:22');
      store.open('host-b', 'B', 'root@b:22');
      store.openAndActivate('host-c', 'C', 'root@c:22');
      store.update('host-b', 'connected', 222, '', 12);

      expect(store.setPinned('host-c', true)).assertTrue();
      expect(store.views()[0].hostId).assertEqual('host-c');
      expect(store.views()[0].pinned).assertTrue();
      expect(store.move('host-b', -1)).assertTrue();
      expect(store.views()[1].hostId).assertEqual('host-b');
      expect(store.sessionId('host-b')).assertEqual(222);
      expect(store.sessionGeneration('host-b')).assertEqual(12);
      expect(store.moveBefore('host-a', 'host-b')).assertTrue();
      expect(store.views()[1].hostId).assertEqual('host-a');
      expect(store.views()[2].hostId).assertEqual('host-b');
      expect(store.activeHost()).assertEqual('host-c');
      expect(store.renameDisplayTitle('host-b', 'Pinned production shell')).assertTrue();
      store.open('host-b', 'Host store label', 'root@b:22');
      expect(store.views()[2].label).assertEqual('Pinned production shell');
      expect(store.renameDisplayTitle('host-b', '   ')).assertFalse();
    });

    it('should_keep_twenty_tabs_ordered_and_return_every_live_session', 0, (): void => {
      const store: SshTerminalTabStore = new SshTerminalTabStore();
      for (let index: number = 0; index < 20; index++) {
        const hostId: string = 'host-' + index.toString();
        store.open(hostId, 'Host ' + index.toString(), 'user@host:' + index.toString());
        store.update(hostId, 'connected', 1000 + index, '', index + 1);
      }
      store.activate('host-19');
      expect(store.views().length).assertEqual(20);
      expect(store.views()[19].active).assertTrue();
      expect(store.sessionIds().length).assertEqual(20);
      expect(store.closeAll().length).assertEqual(20);
      expect(store.views().length).assertEqual(0);
    });
  });
}
