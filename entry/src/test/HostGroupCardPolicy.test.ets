import { describe, it, expect } from '@ohos/hypium';
import { ConnectionHealth, RemoteHost } from '../main/ets/model/RemoteHost';
import {
  HOST_PRESENCE_ONLINE_TTL_MS,
  HOST_PRESENCE_RECENT_WINDOW_MS,
  buildHostGroupCards,
  formatRustDeskId,
  hostGroupDetailInsertionRow,
  hostGroupColumnsForBreakpoint,
  hostGroupRowForType,
  hostIdentifier,
  hostPresenceState,
  rustDeskHostId,
  shouldUseGroupedHostCards
} from '../main/ets/services/HostGroupCardPolicy';

function makeHost(id: string, protocol: string): RemoteHost {
  const host: RemoteHost = new RemoteHost();
  host.id = id;
  host.label = id;
  host.protocol = protocol;
  host.host = id + '.example.test';
  host.port = protocol === 'ssh' ? 22 : 3389;
  host.username = 'operator';
  return host;
}

export default function hostGroupCardPolicyTest(): void {
  describe('HostGroupCardPolicy', (): void => {
    it('should_keep_four_groups_in_fixed_order_and_keep_empty_groups', 0, (): void => {
      const hosts: RemoteHost[] = [makeHost('ssh-a', 'ssh'), makeHost('rdp-a', 'rdp')];
      const cards = buildHostGroupCards(hosts, 100000, '');
      expect(cards.length).assertEqual(4);
      expect(cards[0].type).assertEqual('rdp');
      expect(cards[1].type).assertEqual('rustdesk');
      expect(cards[2].type).assertEqual('ssh');
      expect(cards[3].type).assertEqual('vnc');
      expect(cards[0].hosts.length).assertEqual(1);
      expect(cards[1].hosts.length).assertEqual(0);
      expect(cards[3].summary.unknown).assertEqual(0);
    });

    it('should_prefer_pro_peer_id_and_format_numeric_rustdesk_id', 0, (): void => {
      const host: RemoteHost = makeHost('rustdesk-a', 'rustdesk');
      host.customHostname = '999 888 777';
      host.rustdeskProPeerId = '123456789';
      expect(rustDeskHostId(host)).assertEqual('123 456 789');
      expect(formatRustDeskId(' 123 456 789 ')).assertEqual('123 456 789');
      expect(hostIdentifier(host)).assertEqual('123 456 789');
    });

    it('should_show_missing_rustdesk_id_without_inventing_an_endpoint', 0, (): void => {
      const host: RemoteHost = makeHost('rustdesk-a', 'rustdesk');
      expect(rustDeskHostId(host)).assertEqual('');
      expect(hostIdentifier(host)).assertEqual('ID 未获取');
    });

    it('should_keep_manual_rustdesk_presence_unknown_without_a_peer_source', 0, (): void => {
      const host: RemoteHost = makeHost('rustdesk-a', 'rustdesk');
      host.lastConnected = 100000 - 1000;
      host.lastHealth = ConnectionHealth.EXCELLENT;
      expect(hostPresenceState(host, 100000, false)).assertEqual('recently_online');
      host.lastConnected = 0;
      host.lastHealth = ConnectionHealth.UNKNOWN;
      expect(hostPresenceState(host, 100000, false)).assertEqual('unknown');
    });

    it('should_map_authoritative_pro_peer_observations_conservatively', 0, (): void => {
      const host: RemoteHost = makeHost('rustdesk-a', 'rustdesk');
      host.rustdeskProLastSeenAt = 100000 - 1000;
      expect(hostPresenceState(host, 100000, false)).assertEqual('online');
      host.rustdeskProLastSeenAt = 100000 - HOST_PRESENCE_ONLINE_TTL_MS - 1000;
      expect(hostPresenceState(host, 100000, false)).assertEqual('recently_online');
      host.rustdeskProLastSeenAt = 100000 - HOST_PRESENCE_RECENT_WINDOW_MS - 1000;
      host.rustdeskProSyncError = 'not_seen';
      expect(hostPresenceState(host, 100000, false)).assertEqual('offline');
      expect(hostPresenceState(host, 100000, true)).assertEqual('online');
    });

    it('should_count_presence_per_group_without_cross_protocol_leakage', 0, (): void => {
      const rdp: RemoteHost = makeHost('rdp-a', 'rdp');
      rdp.lastConnected = 100000 - 1000;
      rdp.lastHealth = ConnectionHealth.GOOD;
      const rustdesk: RemoteHost = makeHost('rustdesk-a', 'rustdesk');
      rustdesk.rustdeskProSyncError = 'not_seen';
      const cards = buildHostGroupCards([rdp, rustdesk], 100000, 'rdp-a');
      expect(cards[0].summary.online).assertEqual(1);
      expect(cards[1].summary.offline).assertEqual(1);
      expect(cards[2].summary.unknown).assertEqual(0);
      expect(cards[3].summary.unknown).assertEqual(0);
    });

    it('should_insert_details_after_the_selected_row', 0, (): void => {
      expect(hostGroupRowForType('rdp', 2)).assertEqual(0);
      expect(hostGroupRowForType('rustdesk', 2)).assertEqual(0);
      expect(hostGroupRowForType('ssh', 2)).assertEqual(1);
      expect(hostGroupRowForType('vnc', 2)).assertEqual(1);
      expect(hostGroupDetailInsertionRow('vnc', 1)).assertEqual(3);
    });

    it('should_keep_large_desktop_in_the_original_categorized_mode', 0, (): void => {
      expect(shouldUseGroupedHostCards(true, true, 'xl')).assertFalse();
      expect(shouldUseGroupedHostCards(true, true, 'lg')).assertTrue();
      expect(shouldUseGroupedHostCards(true, false, 'xl')).assertTrue();
      expect(shouldUseGroupedHostCards(false, false, 'sm')).assertFalse();
      expect(hostGroupColumnsForBreakpoint('sm')).assertEqual(1);
      expect(hostGroupColumnsForBreakpoint('md')).assertEqual(2);
      expect(hostGroupColumnsForBreakpoint('lg')).assertEqual(2);
    });
  });
}
