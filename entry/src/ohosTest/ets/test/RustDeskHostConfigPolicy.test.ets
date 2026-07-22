/**
 * RustDeskHostConfigPolicy.test.ets - RustDesk add-host endpoint resolution
 */
import { describe, it, expect } from '@ohos/hypium';
import { RustDeskRelayConfig } from '../../../main/ets/model/RustDeskRelayConfig';
import {
  resolveRustDeskHostEndpoint,
  rustDeskConnectionError,
  rustDeskServerKeyError,
  rustDeskAuthModeForConnection,
  rustDeskCardEndpoint,
  shouldAdoptRustDeskDirectPort
} from '../../../main/ets/services/RustDeskHostConfigPolicy';
import {
  resolveRustDeskRelayKey,
  rustDeskRelayKeyForStorage,
  rustDeskRelayKeyFromStorage
} from '../../../main/ets/services/RustDeskRelayKeyPolicy';

function makeRelay(): RustDeskRelayConfig {
  const relay = new RustDeskRelayConfig();
  relay.id = 'relay-1';
  relay.idServer = 'id.example.com';
  relay.idServerPort = 21117;
  return relay;
}

const VALID_SERVER_KEY: string = 'OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=';

export default function rustDeskHostConfigPolicyTest(): void {
  describe('RustDeskHostConfigPolicy', (): void => {
    it('direct_mode_should_use_direct_host_and_port', 0, (): void => {
      const endpoint = resolveRustDeskHostEndpoint(null, '', true, '192.168.1.20', 21118);
      expect(endpoint.host).assertEqual('192.168.1.20');
      expect(endpoint.port).assertEqual(21118);
    });

    it('direct_mode_invalid_port_should_use_peer_default', 0, (): void => {
      const endpoint = resolveRustDeskHostEndpoint(null, '', true, '192.168.1.20', 0);
      expect(endpoint.port).assertEqual(21118);
    });

    it('relay_mode_should_use_selected_id_server', 0, (): void => {
      const endpoint = resolveRustDeskHostEndpoint(makeRelay(), '', false, '', 21116);
      expect(endpoint.host).assertEqual('id.example.com');
      expect(endpoint.port).assertEqual(21117);
    });

    it('oss_relay_should_allow_empty_server_key', 0, (): void => {
      expect(rustDeskServerKeyError('', false)).assertEqual('');
      expect(rustDeskConnectionError({
        directEnabled: false,
        directHost: '',
        directPort: 21118,
        relayId: 'relay-1',
        relayExists: true,
        relayHost: 'id.example.com',
        relayPort: 21117,
        relayKey: '',
        proManaged: false
      })).assertEqual('');
    });

    it('server_key_should_accept_standard_32_byte_public_key', 0, (): void => {
      expect(rustDeskServerKeyError(VALID_SERVER_KEY, true)).assertEqual('');
    });

    it('server_key_should_reject_locked_ciphertext', 0, (): void => {
      expect(rustDeskServerKeyError('1:encrypted-value', false)).assertContain('未解锁');
    });

    it('explicit_public_key_mode_should_reject_wrong_format', 0, (): void => {
      expect(rustDeskServerKeyError('not-a-public-key', false, 'server_public_key')).assertContain('格式无效');
    });

    it('shared_access_key_should_preserve_every_protocol_character', 0, (): void => {
      const raw: string = ' =tenant-key:42/abc=\n';
      const result = resolveRustDeskRelayKey(raw, 'shared_access_key', false);
      expect(result.ok).assertTrue();
      expect(result.mode).assertEqual('shared_access_key');
      expect(result.value).assertEqual(raw);
      expect(result.requiresInsecureConnectionWarning).assertTrue();
    });

    it('auto_key_should_identify_non_public_legacy_value_as_shared_access_key', 0, (): void => {
      const result = resolveRustDeskRelayKey('1:custom-access-key', 'auto', false);
      // An imported raw `1:` value is valid; only persisted connection data
      // has enough context to be treated as locked storage.
      expect(result.ok).assertTrue();
      expect(result.mode).assertEqual('shared_access_key');
      expect(result.value).assertEqual('1:custom-access-key');
      const stored = rustDeskRelayKeyForStorage('1:custom-access-key', 'shared_access_key');
      const restored = rustDeskRelayKeyFromStorage(stored);
      expect(restored.mode).assertEqual('shared_access_key');
      expect(restored.key).assertEqual('1:custom-access-key');
      expect(rustDeskServerKeyError('not-a-public-key', false)).assertEqual('');
    });

    it('shared_access_key_should_reject_nul_without_trimming_other_text', 0, (): void => {
      const invalid = resolveRustDeskRelayKey('safe\0unsafe', 'shared_access_key', false);
      expect(invalid.ok).assertFalse();
      expect(invalid.error).assertContain('NUL');
      expect(rustDeskServerKeyError(' =custom= ', false, 'shared_access_key')).assertEqual('');
    });

    it('connection_preflight_should_not_reinterpret_explicit_shared_1_prefix', 0, (): void => {
      expect(rustDeskConnectionError({
        directEnabled: false,
        directHost: '',
        directPort: 21118,
        relayId: 'relay-1',
        relayExists: true,
        relayHost: 'id.example.com',
        relayPort: 21117,
        relayKey: '1:tenant-key',
        relayKeyMode: 'shared_access_key',
        proManaged: false
      })).assertEqual('');
    });

    it('pro_relay_should_require_a_server_key', 0, (): void => {
      expect(rustDeskConnectionError({
        directEnabled: false,
        directHost: '',
        directPort: 21118,
        relayId: 'relay-1',
        relayExists: true,
        relayHost: 'id.example.com',
        relayPort: 21117,
        relayKey: '',
        proManaged: true
      })).assertEqual('Server Pro 中继缺少服务器密钥');
    });

    it('empty_fallback_should_stay_empty_for_validation', 0, (): void => {
      const endpoint = resolveRustDeskHostEndpoint(null, '', false, '', 21116);
      expect(endpoint.host).assertEqual('');
      expect(endpoint.port).assertEqual(21116);
    });

    it('direct_mode_should_force_device_password_auth', 0, (): void => {
      expect(rustDeskAuthModeForConnection(true, 'request_approval')).assertEqual('password');
    });

    it('relay_mode_should_keep_approval_auth', 0, (): void => {
      expect(rustDeskAuthModeForConnection(false, 'request_approval')).assertEqual('request_approval');
    });

    it('direct_card_should_show_direct_endpoint', 0, (): void => {
      const endpoint = rustDeskCardEndpoint(true, '192.168.1.20', 21117, 'relay.example.com', 21116);
      expect(endpoint).assertEqual('192.168.1.20:21117');
    });

    it('default_port_change_should_only_update_hosts_following_old_default', 0, (): void => {
      expect(shouldAdoptRustDeskDirectPort(true, 21118, 21118)).assertTrue();
      expect(shouldAdoptRustDeskDirectPort(true, 22000, 21118)).assertFalse();
      expect(shouldAdoptRustDeskDirectPort(false, 21118, 21118)).assertFalse();
    });
  });
}
