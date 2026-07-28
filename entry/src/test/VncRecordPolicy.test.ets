import { describe, it, expect } from '@ohos/hypium';
import { VncRecord } from '../main/ets/model/VncRecord';
import { vncPayloadHashSha256, vncRecordIsScopeTombstone, vncRecordIsValid,
  vncRecordFromCloudRow, vncSecretPayloadIsMetadataOnly, VNC_SCOPE_TOMBSTONE_PAYLOAD,
  VNC_CLOUD_TABLE, vncRecordHasActiveCiphertext } from
  '../main/ets/services/VncRecordPolicy';
import { vncHostPayload } from '../main/ets/services/VncModelPolicy';

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
    transport: 'direct_tcp', repeaterMode: 'mode12', viewOnly: true, scalingMode: 'fit', clipboardEnabled: false,
    securityPolicy: 'secure_only', tls: true
  });
  record.payloadHashSha256 = vncPayloadHashSha256(record.payload);
  return record;
}

export default function vncRecordPolicyTest(): void {
  describe('VncRecordPolicy', (): void => {
    it('uses_the_single_vncrecord_cloud_table', 0, (): void => {
      expect(VNC_CLOUD_TABLE).assertEqual('vncrecord');
    });
    it('accepts_non_secret_host_rows_in_the_vnc_owner_domain', 0, (): void => {
      expect(vncRecordIsValid(validHostRecord())).assertTrue();
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
