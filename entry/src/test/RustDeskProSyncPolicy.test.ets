import { describe, it, expect } from '@ohos/hypium';
import { RemoteHost } from '../main/ets/model/RemoteHost';
import { RustDeskProPeer } from '../main/ets/model/RustDeskProModels';
import {
  isCorruptedAddressBookPassword,
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

    it('never_overwrites_a_saved_password_on_resync', 0, () => {
      const first = reconcileRustDeskProHosts([], 'relay-1', 'acct-1', [peer('123', 'Office')], 100);
      // 用户自己填的、能用的设备密码。
      first.hosts[0].password = 'my-real-password';
      first.hosts[0].rustdeskAuthMode = 'password';
      const fromServer = peer('123', 'Office');
      fromServer.password = 'address-book-value';
      const second = reconcileRustDeskProHosts(first.hosts, 'relay-1', 'acct-1', [fromServer], 200);
      expect(second.hosts[0].password).assertEqual('my-real-password');
      expect(second.hosts[0].rustdeskAuthMode).assertEqual('password');
    });

    it('fills_an_empty_password_from_the_address_book', 0, () => {
      const fromServer = peer('123', 'Office');
      fromServer.password = 'address-book-value';
      const result = reconcileRustDeskProHosts([], 'relay-1', 'acct-1', [fromServer], 100);
      expect(result.hosts[0].password).assertEqual('address-book-value');
      expect(result.hosts[0].rustdeskAuthMode).assertEqual('password');
    });

    it('clears_the_hash_derived_garbage_password_written_by_older_builds', 0, () => {
      const first = reconcileRustDeskProHosts([], 'relay-1', 'acct-1', [peer('123', 'Office')], 100);
      // 旧版本把地址簿 hash 摘要按 UTF-8 解码后存下来的结果。
      first.hosts[0].password = '��7��';
      first.hosts[0].rustdeskAuthMode = 'password';
      const second = reconcileRustDeskProHosts(first.hosts, 'relay-1', 'acct-1', [peer('123', 'Office')], 200);
      expect(second.hosts[0].password).assertEqual('');
      // 没有可用凭据时回落到官方的点击批准闭环。
      expect(second.hosts[0].rustdeskAuthMode).assertEqual('request_approval');
    });

    it('recognizes_only_replacement_char_passwords_as_corrupted', 0, () => {
      expect(isCorruptedAddressBookPassword('��')).assertTrue();
      expect(isCorruptedAddressBookPassword('P@ssw0rd!')).assertFalse();
      expect(isCorruptedAddressBookPassword('')).assertFalse();
      expect(isCorruptedAddressBookPassword('密码123')).assertFalse();
    });

    it('allows_a_managed_direct_host_to_edit_its_local_lan_endpoint', 0, () => {
      expect(shouldPreserveManagedRustDeskRoute(true, false)).assertTrue();
      expect(shouldPreserveManagedRustDeskRoute(true, true)).assertFalse();
      expect(shouldPreserveManagedRustDeskRoute(false, true)).assertFalse();
    });
  });
}
