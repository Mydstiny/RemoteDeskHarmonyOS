import { describe, it, expect } from '@ohos/hypium';
import { RemoteHost } from '../main/ets/model/RemoteHost';
import { RustDeskProPeer } from '../main/ets/model/RustDeskProModels';
import {
  reconcileRustDeskProHosts,
  rustDeskProHostId,
  shouldPreserveManagedRustDeskRoute
} from '../main/ets/services/RustDeskProSyncPolicy';

function peer(id: string, alias: string, platform: string = ''): RustDeskProPeer {
  const value = new RustDeskProPeer();
  value.id = id;
  value.alias = alias;
  value.platform = platform;
  return value;
}

function manualHost(id: string): RemoteHost {
  const host = new RemoteHost();
  host.id = id;
  host.protocol = 'rustdesk';
  host.customHostname = '123';
  host.label = '手动主机';
  host.host = '10.0.0.1';
  host.port = 21116;
  return host;
}

export default function rustDeskProSyncPolicyTest() {
  describe('RustDeskProSyncPolicy', () => {
    it('creates_stable_managed_hosts', 0, () => {
      const result = reconcileRustDeskProHosts([], 'relay-1', 'acct-1', [peer('123', 'Office', 'Windows')], 100);
      expect(result.addedIds.length).assertEqual(1);
      expect(result.hosts.length).assertEqual(1);
      expect(result.hosts[0].id).assertEqual(rustDeskProHostId('relay-1', 'acct-1', '123'));
      expect(result.hosts[0].sourceType).assertEqual('rustdesk_pro');
      expect(result.hosts[0].rustdeskProManaged).assertTrue();
      expect(result.hosts[0].rustdeskProPlatform).assertEqual('Windows');
      expect(result.hosts[0].label).assertEqual('Office');
    });

    it('stores_relay_endpoint_for_imported_hosts', 0, () => {
      const result = reconcileRustDeskProHosts([], 'relay-1', 'acct-1', [peer('123', 'Office')], 100,
        'relay.example.com', 21116);
      expect(result.hosts[0].host).assertEqual('relay.example.com');
      expect(result.hosts[0].port).assertEqual(21116);
    });

    it('does_not_take_over_same_id_manual_host', 0, () => {
      const result = reconcileRustDeskProHosts([manualHost('manual-1')], 'relay-1', 'acct-1', [peer('123', 'Office')], 100);
      expect(result.hosts.length).assertEqual(2);
      expect(result.hosts[0].id).assertEqual('manual-1');
      expect(result.hosts[0].sourceType).assertEqual('manual');
    });

    it('preserves_local_display_fields_on_resync', 0, () => {
      const first = reconcileRustDeskProHosts([], 'relay-1', 'acct-1', [peer('123', 'Office')], 100);
      first.hosts[0].label = '我的别名';
      first.hosts[0].groupId = 'ops';
      const second = reconcileRustDeskProHosts(first.hosts, 'relay-1', 'acct-1', [peer('123', 'Renamed')], 200);
      expect(second.updatedIds.length).assertEqual(1);
      expect(second.hosts[0].label).assertEqual('我的别名');
      expect(second.hosts[0].groupId).assertEqual('ops');
      expect(second.hosts[0].rustdeskProLastSeenAt).assertEqual(200);
    });

    it('marks_missing_peer_without_deleting_it', 0, () => {
      const first = reconcileRustDeskProHosts([], 'relay-1', 'acct-1', [peer('123', 'Office')], 100);
      const second = reconcileRustDeskProHosts(first.hosts, 'relay-1', 'acct-1', [], 200);
      expect(second.hosts.length).assertEqual(1);
      expect(second.missingIds.length).assertEqual(1);
      expect(second.hosts[0].rustdeskProSyncError).assertEqual('not_seen');
    });

    it('allows_a_managed_direct_host_to_edit_its_local_lan_endpoint', 0, () => {
      expect(shouldPreserveManagedRustDeskRoute(true, false)).assertTrue();
      expect(shouldPreserveManagedRustDeskRoute(true, true)).assertFalse();
      expect(shouldPreserveManagedRustDeskRoute(false, true)).assertFalse();
    });
  });
}
