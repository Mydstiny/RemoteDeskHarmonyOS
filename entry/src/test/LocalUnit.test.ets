/**
 * LocalUnit.test.ets — Local unit tests (hypium)
 *
 * Test scope: data models, service logic, utilities
 */

import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import {
  RemoteHost,
  LockType,
  normalizeRdpCredentialParts,
  normalizeRdpNtlmHash,
  rdpRouteIdentityForValues
} from '../main/ets/model/RemoteHost';
import { UserAccount } from '../main/ets/model/UserAccount';
import { RdpCredential } from '../main/ets/model/RdpCredential';
import { normalizeRdpClientHostname } from '../main/ets/services/RdpConnectionIdentityPolicy';

export default function localUnitTest() {
  describe('RemoteHost_Data_Model', () => {
    it('should_create_valid_RemoteHost', 0, () => {
      const host = new RemoteHost();
      host.label = 'OfficePC';
      host.protocol = 'rdp';
      host.host = '192.168.1.100';
      host.port = 3389;
      host.username = 'admin';
      host.customHostname = 'server.example.test';
      host.rdpClientHostname = 'HARMONY-CLIENT';

      expect(host.isValid()).assertTrue();
    });

    it('should_reject_invalid_port', 0, () => {
      const host = new RemoteHost();
      host.label = 'Test';
      host.host = '10.0.0.1';
      host.port = 99999;
      host.username = 'user';

      const errors = host.getValidationErrors();
      expect(errors.length > 0).assertTrue();
      expect(host.isValid()).assertFalse();
    });

    it('should_reject_empty_label', 0, () => {
      const host = new RemoteHost();
      host.host = '10.0.0.1';
      host.username = 'user';

      const errors = host.getValidationErrors();
      expect(errors.includes('主机名称不能为空')).assertTrue();
    });

    it('serialization_roundtrip_should_be_consistent', 0, () => {
      const host = new RemoteHost();
      host.id = 'test_id_123';
      host.label = 'TestHost';
      host.protocol = 'rustdesk';
      host.host = 'myhost.com';
      host.port = 21116;
      host.username = 'admin';
      host.locked = true;
      host.lockType = LockType.PASSWORD;

      const json = host.toJSON();
      const restored = RemoteHost.fromJSON(json as Record<string, Object>);

      expect(restored.id).assertEqual(host.id);
      expect(restored.label).assertEqual(host.label);
      expect(restored.protocol).assertEqual(host.protocol);
      expect(restored.host).assertEqual(host.host);
      expect(restored.port).assertEqual(host.port);
      expect(restored.username).assertEqual(host.username);
      expect(restored.customHostname).assertEqual(host.customHostname);
      expect(restored.rdpClientHostname).assertEqual(host.rdpClientHostname);
      expect(restored.locked).assertEqual(host.locked);
      expect(restored.lockType).assertEqual(host.lockType);
    });

    it('keeps_rdp_client_hostname_separate_from_server_identity', 0, () => {
      expect(normalizeRdpClientHostname('')).assertEqual('');
      expect(normalizeRdpClientHostname('HARMONY-CLIENT')).assertEqual('HARMONY-CLIENT');
      expect(normalizeRdpClientHostname('client.example.test')).assertEqual('client.example.test');
      expect(normalizeRdpClientHostname('2001:db8::10')).assertNull();
      expect(normalizeRdpClientHostname('client name')).assertNull();
      expect(normalizeRdpClientHostname('-client')).assertNull();
      expect(normalizeRdpClientHostname('client.example.')).assertNull();
    });

    it('runtime_clone_should_keep_secret_presence_out_of_serialized_json', 0, () => {
      const host = new RemoteHost();
      host.passwordConfigured = true;
      host.sshKeyDataConfigured = true;
      host.sshKeyPassphraseConfigured = true;
      host.sshProxyPasswordConfigured = true;
      host.sshProxyKeyPassphraseConfigured = true;
      const serialized: Record<string, Object> = host.toJSON() as Record<string, Object>;
      expect(serialized['passwordConfigured']).assertUndefined();
      expect(serialized['sshKeyDataConfigured']).assertUndefined();
      expect(serialized['sshKeyPassphraseConfigured']).assertUndefined();
      expect(serialized['sshProxyPasswordConfigured']).assertUndefined();
      expect(serialized['sshProxyKeyPassphraseConfigured']).assertUndefined();
      const clone: RemoteHost = host.runtimeClone();
      expect(clone.passwordConfigured).assertTrue();
      expect(clone.sshKeyDataConfigured).assertTrue();
      expect(clone.sshKeyPassphraseConfigured).assertTrue();
      expect(clone.sshProxyPasswordConfigured).assertTrue();
      expect(clone.sshProxyKeyPassphraseConfigured).assertTrue();
      expect(clone.runtimeSecretStateSignature()).assertEqual('1|1|1|1|1');

      host.passwordConfigured = false;
      host.sshKeyDataConfigured = false;
      host.sshKeyPassphraseConfigured = false;
      host.sshProxyPasswordConfigured = false;
      host.sshProxyKeyPassphraseConfigured = false;
      const clearedClone: RemoteHost = host.runtimeClone();
      expect(clearedClone.passwordConfigured).assertFalse();
      expect(clearedClone.sshKeyDataConfigured).assertFalse();
      expect(clearedClone.sshKeyPassphraseConfigured).assertFalse();
      expect(clearedClone.sshProxyPasswordConfigured).assertFalse();
      expect(clearedClone.sshProxyKeyPassphraseConfigured).assertFalse();
      expect(clearedClone.runtimeSecretStateSignature()).assertEqual('0|0|0|0|0');

      const credential = new RdpCredential();
      credential.passwordConfigured = true;
      const credentialJson: Record<string, Object> =
        credential.toJSON() as Record<string, Object>;
      expect(credentialJson['passwordConfigured']).assertUndefined();
      expect(credential.runtimeClone().passwordConfigured).assertTrue();
      credential.passwordConfigured = false;
      expect(credential.runtimeClone().passwordConfigured).assertFalse();
      expect(credential.runtimeSecretStateSignature()).assertEqual('0');
    });

    it('RDP_default_port_should_be_3389', 0, () => {
      expect(RemoteHost.getDefaultPort('rdp')).assertEqual(3389);
    });

    it('RDP_blank_password_should_allow_an_explicit_empty_password', 0, () => {
      const host = new RemoteHost();
      host.label = 'BlankPasswordPc';
      host.protocol = 'rdp';
      host.host = '192.0.2.10';
      host.username = '.\\localuser';
      host.rdpAuthMode = 'blank_password';
      host.passwordConfigured = true;
      host.password = 'must-clear';
      host.normalizeRdpAuthentication();

      expect(host.getValidationErrors().length).assertEqual(0);
      expect(host.isValid()).assertTrue();
      expect(host.passwordConfigured).assertFalse();
    });

    it('RDP_restricted_admin_should_clear_ordinary_credentials', 0, () => {
      const host = new RemoteHost();
      host.protocol = 'rdp';
      host.rdpAuthMode = 'restricted_admin';
      host.password = 'must-not-survive';
      host.rdpCredentialId = 'credential-1';

      host.normalizeRdpAuthentication();

      expect(host.password).assertEqual('');
      expect(host.rdpCredentialId).assertEqual('');
    });

    it('RDP_legacy_json_should_default_to_password_mode', 0, () => {
      const host = new RemoteHost();
      host.protocol = 'rdp';
      const json = host.toJSON();
      json.rdpAuthMode = undefined;
      json.rdpRestrictedAdminSecretSource = undefined;

      const restored = RemoteHost.fromJSON(json);

      expect(restored.rdpAuthMode).assertEqual('password');
      expect(restored.rdpRestrictedAdminSecretSource).assertEqual('ntlm_hash');
    });

    it('RDP_connect_time_credentials_should_never_serialize', 0, () => {
      const host = new RemoteHost();
      host.label = 'PromptEveryTime';
      host.protocol = 'rdp';
      host.host = '192.0.2.20';
      host.rdpAuthMode = 'password';
      host.rdpCredentialStorageMode = 'connect_time';
      host.username = 'must-not-persist';
      host.password = 'must-not-persist';
      host.passwordConfigured = true;
      host.rdpCredentialId = 'must-not-persist';
      expect(host.isValid()).assertFalse();
      expect(host.getValidationErrors().length).assertEqual(1);

      const serialized: Record<string, Object> = host.toJSON() as Record<string, Object>;
      expect(serialized['username']).assertEqual('');
      expect(serialized['password']).assertEqual('');
      expect(serialized['rdpCredentialId']).assertEqual('');
      expect(serialized['rdpCredentialStorageMode']).assertEqual('connect_time');

      const restored: RemoteHost = RemoteHost.fromJSON(host.toJSON());
      expect(restored.username).assertEqual('');
      expect(restored.password).assertEqual('');
      expect(restored.passwordConfigured).assertFalse();
      expect(restored.rdpCredentialId).assertEqual('');
      expect(restored.getValidationErrors().length).assertEqual(0);
      expect(restored.isValid()).assertTrue();
      expect(host.runtimeClone().passwordConfigured).assertFalse();
    });

    it('RDP_non_password_modes_should_force_saved_storage_policy', 0, () => {
      const host = new RemoteHost();
      host.protocol = 'rdp';
      host.rdpAuthMode = 'restricted_admin';
      host.rdpCredentialStorageMode = 'connect_time';
      host.normalizeRdpAuthentication();
      expect(host.rdpCredentialStorageMode).assertEqual('saved');
    });

    it('RDP_legacy_empty_password_hash_should_require_a_real_hash', 0, () => {
      const host = new RemoteHost();
      host.protocol = 'rdp';
      host.rdpAuthMode = 'restricted_admin';
      const json = host.toJSON();
      json.rdpRestrictedAdminSecretSource = 'empty_password_hash';

      const restored = RemoteHost.fromJSON(json);

      expect(restored.rdpAuthMode).assertEqual('restricted_admin');
      expect(restored.rdpRestrictedAdminSecretSource).assertEqual('ntlm_hash');
    });

    it('RDP_effective_identity_should_match_native_domain_normalization', 0, () => {
      const microsoft = normalizeRdpCredentialParts('user@example.com', 1);
      expect(microsoft.username).assertEqual('user@example.com');
      expect(microsoft.domain).assertEqual('MicrosoftAccount');

      const azure = normalizeRdpCredentialParts('.\\AzureAD\\user@example.com', 3);
      expect(azure.username).assertEqual('AzureAD\\user@example.com');
      expect(azure.domain).assertEqual('.');
    });

    it('RDP_NTLM_hash_should_normalize_only_32_hex_characters', 0, () => {
      expect(normalizeRdpNtlmHash(' 0123456789abcdef0123456789abcdef '))
        .assertEqual('0123456789ABCDEF0123456789ABCDEF');
      expect(normalizeRdpNtlmHash('not-a-hash')).assertEqual('');
    });

    it('RDP_route_identity_should_not_collide_on_IPv6_delimiters', 0, () => {
      const first: string = rdpRouteIdentityForValues(
        'direct_rdp', '2001:db8::1', 3389, '443:1::2', '', 0, '', 'auto');
      const second: string = rdpRouteIdentityForValues(
        'direct_rdp', '2001:db8::1:3389', 443, '1::2', '', 0, '', 'auto');

      expect(first).assertEqual(
        'rdp-route-v2|10:direct_rdp11:2001:db8::14:33898:443:1::20:1:00:4:auto');
      expect(first === second).assertFalse();
    });

    it('RustDesk_default_port_should_be_21116', 0, () => {
      expect(RemoteHost.getDefaultPort('rustdesk')).assertEqual(21116);
    });

    it('generated_IDs_should_be_unique', 0, () => {
      const id1 = RemoteHost.generateId();
      const id2 = RemoteHost.generateId();
      expect(id1 === id2).assertFalse();
    });
  });

  describe('UserAccount_Data_Model', () => {
    it('should_create_and_serialize_correctly', 0, () => {
      const account = new UserAccount();
      account.setLoggedIn('union_123', 'TestUser', '', 'token_abc');

      expect(account.isLoggedIn).assertTrue();
      expect(account.unionId).assertEqual('union_123');
      expect(account.displayName).assertEqual('TestUser');

      const json: Record<string, Object> = account.toJSON();
      const restored = UserAccount.fromJSON(json);

      expect(restored.isLoggedIn).assertTrue();
      expect(restored.unionId).assertEqual('union_123');
    });

    it('logout_should_clear_state', 0, () => {
      const account = new UserAccount();
      account.setLoggedIn('u1', 'user', '', 'token');
      account.setLoggedOut();

      expect(account.isLoggedIn).assertFalse();
      expect(account.authToken).assertEqual('');
    });
  });

  describe('LockType_Enum', () => {
    it('NONE_should_be_0', 0, () => {
      expect(LockType.NONE).assertEqual(0);
    });

    it('BIOMETRIC_should_be_1', 0, () => {
      expect(LockType.BIOMETRIC).assertEqual(1);
    });

    it('PASSWORD_should_be_3', 0, () => {
      expect(LockType.PASSWORD).assertEqual(3);
    });
  });
}
