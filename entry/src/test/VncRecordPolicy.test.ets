import { describe, it, expect } from '@ohos/hypium';
import { VncRecord } from '../main/ets/model/VncRecord';
import { vncPayloadHashSha256, vncRecordIsScopeTombstone, vncRecordIsValid,
  vncRecordFromCloudRow, vncSecretPayloadIsMetadataOnly, VNC_SCOPE_TOMBSTONE_PAYLOAD,
  VNC_CLOUD_TABLE, vncRecordHasActiveCiphertext, vncRecordHasActiveEncryptedCiphertext } from
  '../main/ets/services/VncRecordPolicy';
import {
  validateVncGateway,
  validateVncHost,
  vncGatewayPayload,
  vncHostPayload,
  vncTrustPayload
} from '../main/ets/services/VncModelPolicy';
import { encodePlainVncSecret } from '../main/ets/services/VncSecretStoragePolicy';

function validHostRecord(): VncRecord {
  const record = new VncRecord();
  record.id = 'vnchost-test';
  record.userId = 'user-test';
  record.recordType = 'host';
  record.ownerId = 'user-test';
  record.ownerType = 'account';
  record.updatedAt = 2;
  record.payload = vncHostPayload({
    label: 'Test host', host: '192.0.2.10', port: 5900, username: '', gatewayId: '',
    transport: 'direct_tcp', repeaterMode: 'mode12', rememberPassword: false, viewOnly: true,
    displayOverrideEnabled: false, scalingMode: 'fit', clipboardEnabled: false,
    securityPolicy: 'secure_only', tls: true, locked: false, lockType: 0
  });
  record.payloadHashSha256 = vncPayloadHashSha256(record.payload);
  return record;
}

export default function vncRecordPolicyTest(): void {
  describe('VncRecordPolicy', (): void => {
    it('uses_the_single_vncrecord_cloud_table', 0, (): void => {
      expect(VNC_CLOUD_TABLE).assertEqual('vncrecordv2');
    });
    it('hashes_an_empty_legacy_payload_without_calling_a_zero_length_update',
      0, (): void => {
        expect(vncPayloadHashSha256('')).assertEqual(
          'e3b0c44298fc1c149afbf4c8996fb924' +
          '27ae41e4649b934ca495991b7852b855');
      });
    it('accepts_non_secret_host_rows_in_the_vnc_owner_domain', 0, (): void => {
      expect(vncRecordIsValid(validHostRecord())).assertTrue();
    });

    it('canonicalizes_global_ipv6_endpoints_and_keeps_repeater_target_ids_opaque', 0, (): void => {
      const direct = {
        label: 'IPv6', host: '[2001:0DB8:0:0:0:0:0:20]', port: 5900, username: '', gatewayId: '',
        transport: 'direct_tcp' as 'direct_tcp', repeaterMode: 'mode12' as 'mode12',
        rememberPassword: false, viewOnly: true, displayOverrideEnabled: false, scalingMode: 'fit' as 'fit',
        clipboardEnabled: false, securityPolicy: 'secure_only' as 'secure_only', tls: true,
        locked: false, lockType: 0
      };
      expect(validateVncHost(direct).length).assertEqual(0);
      expect(vncHostPayload(direct).indexOf('"host":"2001:db8::20"') >= 0).assertTrue();
      direct.host = 'fe80::20%wlan0';
      expect(validateVncHost(direct).length > 0).assertTrue();

      const repeater = {
        label: 'opaque', host: 'target:id/42', port: 5901, username: '', gatewayId: 'gateway-1',
        transport: 'ultravnc_repeater' as 'ultravnc_repeater', repeaterMode: 'mode12' as 'mode12',
        rememberPassword: false, viewOnly: true, displayOverrideEnabled: false, scalingMode: 'fit' as 'fit',
        clipboardEnabled: false, securityPolicy: 'secure_only' as 'secure_only', tls: true,
        locked: false, lockType: 0
      };
      expect(validateVncHost(repeater).length).assertEqual(0);
      expect(vncHostPayload(repeater).indexOf('"host":"target:id/42"') >= 0).assertTrue();

      const gateway = {
        label: 'gateway', transport: 'ultravnc_repeater' as 'ultravnc_repeater',
        host: '[2001:0DB8::30]', port: 5901, path: '', repeaterMode: 'mode12' as 'mode12',
        targetId: '42', tls: true, enabled: true
      };
      expect(validateVncGateway(gateway).length).assertEqual(0);
      expect(vncGatewayPayload(gateway).indexOf('"host":"2001:db8::30"') >= 0).assertTrue();
    });

    it('accepts_legacy_host_rows_without_clipboard_field', 0, (): void => {
      const record = validHostRecord();
      record.payload = '{"gatewayId":"","host":"192.0.2.10","label":"Test host","port":5900,' +
        '"repeaterMode":"mode12","scalingMode":"fit","securityPolicy":"secure_only",' +
        '"tls":true,"transport":"direct_tcp","username":"","viewOnly":true}';
      record.payloadHashSha256 = vncPayloadHashSha256(record.payload);
      expect(vncRecordIsValid(record)).assertTrue();
    });

    it('rejects_secret_owner_kind_substitution', 0, (): void => {
      const record = validHostRecord();
      record.recordType = 'secret';
      record.ownerId = 'host-1';
      record.ownerType = 'host';
      record.secretKind = 'gateway_token';
      record.payload = '{"kind":"gateway_token"}';
      record.ciphertext = 'v2:header:nonce:tag';
      record.envelopeVersion = 2;
      expect(vncRecordIsValid(record)).assertFalse();
    });

    it('rejects_sensitive_keys_from_secret_metadata_payload', 0, (): void => {
      expect(vncSecretPayloadIsMetadataOnly('{"kind":"gateway_token","label":"gateway"}')).assertTrue();
      expect(vncSecretPayloadIsMetadataOnly('{"kind":"gateway_token","token":"plaintext"}')).assertFalse();
      expect(vncSecretPayloadIsMetadataOnly('{"kind":"gateway_token","ciphertext":"plaintext"}')).assertFalse();
    });

    it('rejects_malformed_wire_values_and_hashes', 0, (): void => {
      const record = validHostRecord();
      record.recordType = 'unknown' as 'host';
      expect(vncRecordIsValid(record)).assertFalse();
      const valid = validHostRecord();
      valid.payloadHashSha256 = 'not-a-hash';
      expect(vncRecordIsValid(valid)).assertFalse();
      const row: Record<string, string> = {
        id: 'wire-host', userid: 'user-test', recordtype: 'not-a-record-type',
        ownerid: 'user-test', ownertype: 'account', secretkind: '', payload: '{}',
        ciphertext: '', envelopeversion: '0', cryptoversion: '0', keyversion: '0',
        aadversion: '0', payloadhashsha256: vncPayloadHashSha256('{}'), syncversion: '1',
        schemaversion: '1', resetepoch: '0', createdat: '1', updatedat: '2', deletedat: '0'
      };
      expect(vncRecordIsValid(vncRecordFromCloudRow(row))).assertFalse();
    });

    it('rejects_semantically_malformed_payloads_even_when_hash_matches', 0, (): void => {
      const host = validHostRecord();
      host.payload = '{"label":"host","host":"192.0.2.10","port":"5900"}';
      host.payloadHashSha256 = vncPayloadHashSha256(host.payload);
      expect(vncRecordIsValid(host)).assertFalse();

      const trust = validHostRecord();
      trust.recordType = 'trust';
      trust.ownerId = 'host-1';
      trust.ownerType = 'host';
      trust.payload = '{"confirmed":true,"confirmedAt":1,"fingerprintSha256":"aa"}';
      trust.payloadHashSha256 = vncPayloadHashSha256(trust.payload);
      expect(vncRecordIsValid(trust)).assertFalse();
    });

    it('accepts_host_and_gateway_trust_rows_only_with_endpoint_owner_metadata', 0, (): void => {
      const hostTrust = validHostRecord();
      hostTrust.recordType = 'trust';
      hostTrust.ownerId = 'host-1';
      hostTrust.ownerType = 'host';
      hostTrust.payload = vncTrustPayload('a'.repeat(64), true, 3, 'host',
        'b'.repeat(64), 'c'.repeat(64));
      hostTrust.payloadHashSha256 = vncPayloadHashSha256(hostTrust.payload);
      expect(vncRecordIsValid(hostTrust)).assertTrue();

      const gatewayTrust = validHostRecord();
      gatewayTrust.recordType = 'trust';
      gatewayTrust.ownerId = 'gateway-1';
      gatewayTrust.ownerType = 'gateway';
      gatewayTrust.payload = vncTrustPayload('a'.repeat(64), true, 3, 'gateway',
        'b'.repeat(64), 'c'.repeat(64));
      gatewayTrust.payloadHashSha256 = vncPayloadHashSha256(gatewayTrust.payload);
      expect(vncRecordIsValid(gatewayTrust)).assertTrue();

      gatewayTrust.payload = vncTrustPayload('a'.repeat(64), true, 3, 'host',
        'b'.repeat(64), 'c'.repeat(64));
      gatewayTrust.payloadHashSha256 = vncPayloadHashSha256(gatewayTrust.payload);
      expect(vncRecordIsValid(gatewayTrust)).assertFalse();
    });

    it('rejects_trust_rows_without_store_or_endpoint_binding', 0, (): void => {
      const trust = validHostRecord();
      trust.recordType = 'trust';
      trust.ownerId = 'gateway-1';
      trust.ownerType = 'gateway';
      trust.payload = '{"confirmed":true,"confirmedAt":3,"fingerprintSha256":"' +
        'a'.repeat(64) + '","ownerType":"gateway"}';
      trust.payloadHashSha256 = vncPayloadHashSha256(trust.payload);
      expect(vncRecordIsValid(trust)).assertFalse();
    });

    it('rejects_secret_rows_with_a_malformed_v2_envelope', 0, (): void => {
      const record = validHostRecord();
      record.recordType = 'secret';
      record.ownerId = 'host-1';
      record.ownerType = 'host';
      record.secretKind = 'vnc_password';
      record.payload = '{"kind":"vnc_password"}';
      record.ciphertext = '2:header-only';
      record.envelopeVersion = 2;
      record.cryptoVersion = 2;
      record.keyVersion = 1;
      record.aadVersion = 1;
      record.payloadHashSha256 = vncPayloadHashSha256(record.payload);
      expect(vncRecordIsValid(record)).assertFalse();
    });

    it('accepts_v3_and_legacy_v2_envelopes_for_controlled_migration', 0, (): void => {
      const record = validHostRecord();
      record.recordType = 'secret';
      record.ownerId = 'host-1';
      record.ownerType = 'host';
      record.secretKind = 'vnc_password';
      record.payload =
        '{"kind":"vnc_password","label":"host","storageMode":"encrypted_v3"}';
      record.ciphertext = '3:header:nonce:ciphertext';
      record.envelopeVersion = 3;
      record.cryptoVersion = 3;
      record.keyVersion = 1;
      record.aadVersion = 2;
      record.payloadHashSha256 = vncPayloadHashSha256(record.payload);
      expect(vncRecordIsValid(record)).assertTrue();
      expect(vncRecordHasActiveEncryptedCiphertext(record)).assertTrue();

      record.payload =
        '{"kind":"vnc_password","label":"host","storageMode":"encrypted_v2"}';
      record.ciphertext = '2:header:nonce:ciphertext';
      record.envelopeVersion = 2;
      record.cryptoVersion = 2;
      record.keyVersion = 1;
      record.aadVersion = 1;
      record.payloadHashSha256 = vncPayloadHashSha256(record.payload);
      expect(vncRecordIsValid(record)).assertTrue();
      expect(vncRecordHasActiveEncryptedCiphertext(record)).assertTrue();
    });

    it('accepts_explicit_plain_v1_secret_rows_without_marking_them_encrypted', 0, (): void => {
      const record = validHostRecord();
      record.recordType = 'secret';
      record.ownerId = 'host-1';
      record.ownerType = 'host';
      record.secretKind = 'vnc_password';
      record.payload = '{"kind":"vnc_password","label":"host","storageMode":"plain_explicit_v1"}';
      record.ciphertext = encodePlainVncSecret('测试-password');
      record.envelopeVersion = 1;
      record.cryptoVersion = 0;
      record.keyVersion = 0;
      record.aadVersion = 0;
      record.payloadHashSha256 = vncPayloadHashSha256(record.payload);
      expect(vncRecordIsValid(record)).assertTrue();
      expect(vncRecordHasActiveEncryptedCiphertext(record)).assertFalse();
    });

    it('rejects_malformed_plain_v1_secret_rows', 0, (): void => {
      const record = validHostRecord();
      record.recordType = 'secret';
      record.ownerId = 'host-1';
      record.ownerType = 'host';
      record.secretKind = 'vnc_password';
      record.payload = '{"kind":"vnc_password","label":"host","storageMode":"plain_explicit_v1"}';
      record.ciphertext = 'plain-v1:not-base64';
      record.envelopeVersion = 1;
      record.cryptoVersion = 0;
      record.keyVersion = 0;
      record.aadVersion = 0;
      record.payloadHashSha256 = vncPayloadHashSha256(record.payload);
      expect(vncRecordIsValid(record)).assertFalse();
    });

    it('rejects_account_rows_owned_by_another_user', 0, (): void => {
      const record = validHostRecord();
      record.ownerId = 'other-user';
      expect(vncRecordIsValid(record)).assertFalse();
    });

    it('recognizes_only_the_explicit_non_secret_scope_tombstone_marker', 0, (): void => {
      const record = validHostRecord();
      record.deletedAt = 3;
      record.payload = VNC_SCOPE_TOMBSTONE_PAYLOAD;
      record.payloadHashSha256 = vncPayloadHashSha256(record.payload);
      expect(vncRecordIsScopeTombstone(record)).assertTrue();
      record.deletedAt = 0;
      expect(vncRecordIsScopeTombstone(record)).assertFalse();
    });

    it('blocks_global_crypto_disable_for_any_live_vnc_ciphertext', 0, (): void => {
      const record = validHostRecord();
      record.recordType = 'secret';
      record.ownerId = 'host-1';
      record.ownerType = 'host';
      record.secretKind = 'vnc_password';
      record.ciphertext = '2:header:nonce:tag';
      expect(vncRecordHasActiveCiphertext(record)).assertTrue();
      record.deletedAt = 3;
      expect(vncRecordHasActiveCiphertext(record)).assertFalse();
      record.deletedAt = Number.NaN;
      expect(vncRecordHasActiveCiphertext(record)).assertTrue();
      record.recordType = 'host';
      record.deletedAt = 0;
      expect(vncRecordHasActiveCiphertext(record)).assertFalse();
    });
  });
}
