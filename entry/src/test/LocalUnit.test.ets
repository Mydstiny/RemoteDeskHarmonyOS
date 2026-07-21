/**
 * LocalUnit.test.ets — Local unit tests (hypium)
 *
 * Test scope: data models, service logic, utilities
 */

import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import {
  RemoteHost,
  LockType,
  normalizeRdpNtlmHash
} from '../main/ets/model/RemoteHost';
import { UserAccount } from '../main/ets/model/UserAccount';

export default function localUnitTest() {
  describe('RemoteHost_Data_Model', () => {
    it('should_create_valid_RemoteHost', 0, () => {
      const host = new RemoteHost();
      host.label = 'OfficePC';
      host.protocol = 'rdp';
      host.host = '192.168.1.100';
      host.port = 3389;
      host.username = 'admin';

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
      expect(restored.locked).assertEqual(host.locked);
      expect(restored.lockType).assertEqual(host.lockType);
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

      expect(host.getValidationErrors().length).assertEqual(0);
      expect(host.isValid()).assertTrue();
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

    it('RDP_NTLM_hash_should_normalize_only_32_hex_characters', 0, () => {
      expect(normalizeRdpNtlmHash(' 0123456789abcdef0123456789abcdef '))
        .assertEqual('0123456789ABCDEF0123456789ABCDEF');
      expect(normalizeRdpNtlmHash('not-a-hash')).assertEqual('');
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
