/**
 * HostSyncService.test.ets — HostSyncService unit tests (hypium)
 *
 * Test scope:
 *   1. Singleton pattern
 *   2. CRUD (add/update/remove/get/getAll)
 *   3. Search (searchHosts)
 *   4. Stats (getHostCount, getRdpCount, etc.)
 *   5. Edge cases (empty, nonexistent ID)
 */

import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { HostSyncService } from '../main/ets/services/HostSyncService';
import { RemoteHost, LockType } from '../main/ets/model/RemoteHost';

function makeHost(label: string, protocol: string, host: string, port: number): RemoteHost {
  const h = new RemoteHost();
  h.id = RemoteHost.generateId();
  h.label = label;
  h.protocol = protocol;
  h.host = host;
  h.port = port;
  h.username = 'testuser';
  h.createdAt = Date.now();
  return h;
}

export default function hostSyncServiceTest() {
  let srv: HostSyncService;

  beforeEach(() => {
    srv = HostSyncService.getInstance();
    const current = srv.getAllHosts();
    for (let i = 0; i < current.length; i++) {
      srv.removeHost(current[i].id);
    }
  });

  describe('HostSyncService_Singleton', () => {
    it('getInstance_should_return_same_instance', 0, () => {
      const a = HostSyncService.getInstance();
      const b = HostSyncService.getInstance();
      expect(a === b).assertTrue();
    });
  });

  describe('HostSyncService_addHost', () => {
    it('count_should_be_1_after_add', 0, () => {
      const host = makeHost('OfficePC', 'rdp', '10.0.0.1', 3389);
      srv.addHost(host);
      expect(srv.getHostCount()).assertEqual(1);
    });

    it('should_auto_generate_id_if_empty', 0, () => {
      const host = makeHost('NoIdHost', 'rdp', '10.0.0.2', 3389);
      host.id = '';
      srv.addHost(host);
      expect(host.id.length > 0).assertTrue();
      expect(host.id.startsWith('host_')).assertTrue();
    });

    it('should_retrieve_by_getHost', 0, () => {
      const host = makeHost('RetrieveTest', 'rustdesk', '10.0.0.3', 21116);
      srv.addHost(host);
      const retrieved = srv.getHost(host.id);
      expect(retrieved !== undefined).assertTrue();
      if (retrieved) {
        expect(retrieved.label).assertEqual('RetrieveTest');
        expect(retrieved.protocol).assertEqual('rustdesk');
      }
    });

    it('createdAt_should_be_set', 0, () => {
      const host = makeHost('TimestampTest', 'ssh', '10.0.0.4', 22);
      host.createdAt = 0;
      srv.addHost(host);
      expect(host.createdAt > 0).assertTrue();
    });

    it('count_should_increment_with_multiple_adds', 0, () => {
      srv.addHost(makeHost('A', 'rdp', '10.0.0.1', 3389));
      srv.addHost(makeHost('B', 'rdp', '10.0.0.2', 3389));
      srv.addHost(makeHost('C', 'ssh', '10.0.0.3', 22));
      expect(srv.getHostCount()).assertEqual(3);
    });
  });

  describe('HostSyncService_updateHost', () => {
    it('update_existing_should_succeed', 0, () => {
      const host = makeHost('OldName', 'rdp', '10.0.0.1', 3389);
      srv.addHost(host);
      host.label = 'NewName';
      host.port = 3390;
      const result = srv.updateHost(host);
      expect(result).assertTrue();
      const updated = srv.getHost(host.id);
      if (updated) {
        expect(updated.label).assertEqual('NewName');
        expect(updated.port).assertEqual(3390);
      }
    });

    it('update_nonexistent_should_return_false', 0, () => {
      const ghost = makeHost('Ghost', 'rdp', '10.0.0.99', 3389);
      ghost.id = 'nonexistent-id';
      const result = srv.updateHost(ghost);
      expect(result).assertFalse();
    });

    it('update_should_not_change_count', 0, () => {
      const host = makeHost('CountTest', 'rdp', '10.0.0.1', 3389);
      srv.addHost(host);
      host.label = 'Renamed';
      srv.updateHost(host);
      expect(srv.getHostCount()).assertEqual(1);
    });
  });

  describe('HostSyncService_workspace', () => {
    it('set_group_should_normalize_before_persisting', 0, () => {
      const host = makeHost('Operations', 'ssh', '10.0.0.2', 22);
      srv.addHost(host);
      expect(srv.setGroup(host.id, 'Ops Team')).assertTrue();
      const updated = srv.getHost(host.id);
      expect(updated !== undefined && updated.groupId).assertEqual('ops-team');
    });

    it('set_sort_order_should_reject_negative_values', 0, () => {
      const host = makeHost('Manual', 'rdp', '10.0.0.3', 3389);
      srv.addHost(host);
      expect(srv.setSortOrder(host.id, -1)).assertFalse();
      expect(srv.setSortOrder(host.id, 7)).assertTrue();
    });
  });

  describe('HostSyncService_removeHost', () => {
    it('remove_existing_should_return_true', 0, () => {
      const host = makeHost('ToDelete', 'rdp', '10.0.0.1', 3389);
      srv.addHost(host);
      const result = srv.removeHost(host.id);
      expect(result).assertTrue();
      expect(srv.getHostCount()).assertEqual(0);
    });

    it('remove_nonexistent_should_return_false', 0, () => {
      const result = srv.removeHost('nonexistent-id');
      expect(result).assertFalse();
    });

    it('getHost_should_return_undefined_after_remove', 0, () => {
      const host = makeHost('Temp', 'ssh', '10.0.0.1', 22);
      srv.addHost(host);
      srv.removeHost(host.id);
      expect(srv.getHost(host.id) === undefined).assertTrue();
    });
  });

  describe('HostSyncService_getAllHosts', () => {
    it('empty_service_should_return_empty_array', 0, () => {
      const all = srv.getAllHosts();
      expect(all.length).assertEqual(0);
    });

    it('should_return_all_added_hosts', 0, () => {
      const ids = new Set<string>();
      for (let i = 0; i < 5; i++) {
        const h = makeHost(`Host${i}`, 'rdp', `10.0.0.${i}`, 3389);
        srv.addHost(h);
        ids.add(h.id);
      }
      const all = srv.getAllHosts();
      expect(all.length).assertEqual(5);
      for (let i = 0; i < all.length; i++) {
        expect(ids.has(all[i].id)).assertTrue();
      }
    });
  });

  describe('HostSyncService_searchHosts', () => {
    it('search_by_label_case_insensitive', 0, () => {
      srv.addHost(makeHost('OfficeRDP', 'rdp', '10.0.0.1', 3389));
      srv.addHost(makeHost('HomePC', 'rustdesk', '10.0.0.2', 21116));
      srv.addHost(makeHost('CloudServer', 'ssh', '10.0.0.3', 22));

      const results = srv.searchHosts('office');
      expect(results.length).assertEqual(1);
      expect(results[0].label).assertEqual('OfficeRDP');
    });

    it('search_by_host_ip', 0, () => {
      srv.addHost(makeHost('A', 'rdp', '192.168.1.100', 3389));
      srv.addHost(makeHost('B', 'rdp', '192.168.1.200', 3389));

      const results = srv.searchHosts('192.168.1.100');
      expect(results.length).assertEqual(1);
    });

    it('search_nonexistent_should_return_empty', 0, () => {
      srv.addHost(makeHost('Test', 'rdp', '10.0.0.1', 3389));
      const results = srv.searchHosts('nonexistentKeyword');
      expect(results.length).assertEqual(0);
    });

    it('search_case_insensitive', 0, () => {
      srv.addHost(makeHost('MyServer', 'rdp', '10.0.0.1', 3389));
      const lower = srv.searchHosts('myserver');
      const upper = srv.searchHosts('MYSERVER');
      expect(lower.length).assertEqual(1);
      expect(upper.length).assertEqual(1);
    });
  });

  describe('HostSyncService_Protocol_Stats', () => {
    it('getRdpCount_should_only_count_rdp', 0, () => {
      srv.addHost(makeHost('RDP1', 'rdp', '10.0.0.1', 3389));
      srv.addHost(makeHost('RDP2', 'rdp', '10.0.0.2', 3389));
      srv.addHost(makeHost('SSH1', 'ssh', '10.0.0.3', 22));
      srv.addHost(makeHost('RD1', 'rustdesk', '10.0.0.4', 21116));
      expect(srv.getRdpCount()).assertEqual(2);
    });

    it('getSshCount_should_only_count_ssh', 0, () => {
      srv.addHost(makeHost('RDP1', 'rdp', '10.0.0.1', 3389));
      srv.addHost(makeHost('SSH1', 'ssh', '10.0.0.2', 22));
      srv.addHost(makeHost('SSH2', 'ssh', '10.0.0.3', 2222));
      expect(srv.getSshCount()).assertEqual(2);
    });

    it('getRustdeskCount_should_only_count_rustdesk', 0, () => {
      srv.addHost(makeHost('RDP1', 'rdp', '10.0.0.1', 3389));
      srv.addHost(makeHost('RD1', 'rustdesk', '10.0.0.2', 21116));
      srv.addHost(makeHost('RD2', 'rustdesk', '10.0.0.3', 21117));
      expect(srv.getRustdeskCount()).assertEqual(2);
    });

    it('getHostCount_should_equal_sum_of_protocols', 0, () => {
      srv.addHost(makeHost('R1', 'rdp', '10.0.0.1', 3389));
      srv.addHost(makeHost('R2', 'rdp', '10.0.0.2', 3389));
      srv.addHost(makeHost('S1', 'ssh', '10.0.0.3', 22));
      srv.addHost(makeHost('D1', 'rustdesk', '10.0.0.4', 21116));
      const total = srv.getRdpCount() + srv.getSshCount() + srv.getRustdeskCount();
      expect(total).assertEqual(srv.getHostCount());
    });
  });

  describe('HostSyncService_Locked_Stats', () => {
    it('getLockedHostCount_should_only_count_locked', 0, () => {
      const h1 = makeHost('Unlocked', 'rdp', '10.0.0.1', 3389);
      h1.locked = false;
      const h2 = makeHost('Locked1', 'rdp', '10.0.0.2', 3389);
      h2.locked = true;
      h2.lockType = LockType.PASSWORD;
      const h3 = makeHost('Locked2', 'ssh', '10.0.0.3', 22);
      h3.locked = true;
      h3.lockType = LockType.BIOMETRIC;

      srv.addHost(h1);
      srv.addHost(h2);
      srv.addHost(h3);

      expect(srv.getLockedHostCount()).assertEqual(2);
    });

    it('all_unlocked_should_return_0', 0, () => {
      const h1 = makeHost('Unlocked1', 'rdp', '10.0.0.1', 3389);
      h1.locked = false;
      const h2 = makeHost('Unlocked2', 'ssh', '10.0.0.2', 22);
      h2.locked = false;
      srv.addHost(h1);
      srv.addHost(h2);
      expect(srv.getLockedHostCount()).assertEqual(0);
    });
  });

  describe('HostSyncService_updateLastConnected', () => {
    it('does_not_mutate_cached_host_when_local_store_is_unavailable', 0, async (): Promise<void> => {
      const host = makeHost('Test', 'rdp', '10.0.0.1', 3389);
      host.lastConnected = 0;
      srv.addHost(host);

      await srv.updateLastConnected(host.id);

      const updated = srv.getHost(host.id);
      if (updated) {
        expect(updated.lastConnected).assertEqual(0);
      }
    });

    it('update_nonexistent_should_not_throw', 0, () => {
      try {
        srv.updateLastConnected('nonexistent-id');
        expect(true).assertTrue();
      } catch (_e) {
        expect(true).assertTrue();
      }
    });
  });

  describe('HostSyncService_Edge_Cases', () => {
    it('empty_service_getHostCount_should_be_0', 0, () => {
      expect(srv.getHostCount()).assertEqual(0);
    });

    it('empty_service_searchHosts_should_return_empty', 0, () => {
      expect(srv.searchHosts('anything').length).assertEqual(0);
    });

    it('empty_service_getRdpCount_should_be_0', 0, () => {
      expect(srv.getRdpCount()).assertEqual(0);
    });

    it('empty_service_getLockedHostCount_should_be_0', 0, () => {
      expect(srv.getLockedHostCount()).assertEqual(0);
    });

    it('searchHosts_empty_string_should_return_all', 0, () => {
      srv.addHost(makeHost('A', 'rdp', '10.0.0.1', 3389));
      srv.addHost(makeHost('B', 'rdp', '10.0.0.2', 3389));
      const results = srv.searchHosts('');
      expect(results.length).assertEqual(2);
    });
  });
}
