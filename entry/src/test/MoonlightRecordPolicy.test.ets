import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
import { MoonlightRecord } from '../main/ets/model/MoonlightRecord';
import {
  defaultMoonlightSettings,
  normalizeMoonlightSettingsForLocalStorage
} from '../main/ets/model/MoonlightModels';
import {
  MOONLIGHT_CIPHERTEXT_MAX_BYTES,
  moonlightCanonicalizeJson,
  MoonlightRecordMeta,
  moonlightMutableFieldPaths,
  moonlightPayloadWithMeta,
  moonlightRecordMetaIsValid,
  moonlightRecordPayloadHashSha256,
  moonlightValidateRecord
} from '../main/ets/services/MoonlightRecordPolicy';

function baseMeta(): MoonlightRecordMeta {
  return {
    mutationId: 'mutation-1', originId: 'owner-store-origin-1',
    baseSyncVersion: 0, fieldVersions: { 'displayName': 1 }
  };
}

function validHostRecord(): MoonlightRecord {
  const payload = moonlightPayloadWithMeta({
    schemaVersion: 1,
    serverUuid: 'server-uuid-1',
    displayName: 'Living Room PC',
    addresses: [{ host: '192.0.2.10', family: 'ipv4', port: 47989 }],
    preferredAddressKey: 'ipv4|192.0.2.10|47989',
    hostType: 'sunshine',
    wakeOnLan: { enabled: false, mac: '', broadcast: '' },
    userOrder: 0
  }, baseMeta(), 'host');
  const record = new MoonlightRecord();
  record.id = 'moonlight-host-1';
  record.userId = 'owner-1';
  record.recordType = 'host';
  record.ownerId = 'owner-1';
  record.ownerType = 'account';
  record.payload = payload.canonical;
  record.syncVersion = 1;
  record.createdAt = 100;
  record.updatedAt = 101;
  record.payloadHashSha256 = moonlightRecordPayloadHashSha256(record);
  return record;
}

export default function moonlightRecordPolicyTest(): void {
  describe('MoonlightRecordPolicy', (): void => {
    it('canonicalizes_nested_json_and_normalizes_unicode', 0, (): void => {
      const result = moonlightCanonicalizeJson('{"z":1,"a":{"y":2,"x":"e\\u0301"}}');
      expect(result.ok).assertTrue();
      expect(result.canonical).assertEqual('{"a":{"x":"é","y":2},"z":1}');
    });

    it('rejects_duplicate_keys_before_json_parse_can_drop_them', 0, (): void => {
      const exact = moonlightCanonicalizeJson('{"host":"a","host":"b"}');
      expect(exact.ok).assertFalse();
      expect(exact.reason).assertEqual('duplicate_json_key');
      const normalized = moonlightCanonicalizeJson('{"é":1,"e\\u0301":2}');
      expect(normalized.ok).assertFalse();
      expect(normalized.reason).assertEqual('duplicate_json_key');
    });

    it('injects_only_policy_owned_meta_with_stable_field_paths', 0, (): void => {
      const result = moonlightPayloadWithMeta({ schemaVersion: 1 }, baseMeta(), 'host');
      expect(result.ok).assertTrue();
      expect(result.canonical.indexOf('"mutationId":"mutation-1"') >= 0).assertTrue();
      const invalid = baseMeta();
      invalid.fieldVersions = { 'serverUuid': 1 };
      expect(moonlightPayloadWithMeta({ schemaVersion: 1 }, invalid, 'host').reason)
        .assertEqual('invalid_meta');
      expect(moonlightPayloadWithMeta({ _meta: {}, schemaVersion: 1 }, baseMeta(), 'host').reason)
        .assertEqual('invalid_meta');
    });

    it('does_not_expose_common_display_or_pip_paths_as_moonlight_mutations', 0, (): void => {
      const paths: string[] = moonlightMutableFieldPaths('settings');
      expect(paths.indexOf('video.scalingMode') < 0).assertTrue();
      expect(paths.indexOf('background.allowPip') < 0).assertTrue();
      expect(paths.indexOf('input.controlMode') >= 0).assertTrue();
      expect(paths.indexOf('input.keyboardTarget') >= 0).assertTrue();
      expect(paths.indexOf('background.noSurfaceVideo') >= 0).assertTrue();
      expect(moonlightMutableFieldPaths('host').indexOf('httpsPort') >= 0).assertTrue();
    });

    it('reads_legacy_settings_meta_and_normalizes_before_new_writes', 0, (): void => {
      const legacyMeta: MoonlightRecordMeta = {
        mutationId: 'legacy-settings-mutation', originId: 'owner-store-origin-1',
        baseSyncVersion: 0,
        fieldVersions: { 'video.scalingMode': 1, 'background.allowPip': 1 }
      };
      expect(moonlightRecordMetaIsValid(legacyMeta, 'settings')).assertTrue();
      const settings = defaultMoonlightSettings();
      settings.video.scalingMode = 'fill';
      settings.background.allowPip = true;
      const legacyValues: Record<string, Object> =
        JSON.parse(JSON.stringify(settings)) as Record<string, Object>;
      legacyValues['_meta'] = legacyMeta as Object;
      const canonical = moonlightCanonicalizeJson(JSON.stringify(legacyValues));
      expect(canonical.ok).assertTrue();
      const record = new MoonlightRecord();
      record.id = 'moonlight-settings-legacy';
      record.userId = 'owner-1';
      record.recordType = 'settings';
      record.ownerId = 'owner-1';
      record.ownerType = 'account';
      record.payload = canonical.canonical;
      record.syncVersion = 1;
      record.createdAt = 100;
      record.updatedAt = 101;
      record.payloadHashSha256 = moonlightRecordPayloadHashSha256(record);
      expect(moonlightValidateRecord(record).valid).assertTrue();
      const normalized = normalizeMoonlightSettingsForLocalStorage(settings);
      expect(normalized.video.scalingMode === undefined).assertTrue();
      expect(normalized.background.allowPip === undefined).assertTrue();
      expect(moonlightPayloadWithMeta({ schemaVersion: 1 }, legacyMeta, 'settings').reason)
        .assertEqual('invalid_meta');
    });

    it('validates_a_canonical_live_host_and_rejects_tampering', 0, (): void => {
      const record = validHostRecord();
      expect(record.ciphertext).assertEqual('');
      // Rows written before custom Sunshine control ports were persisted stay valid.
      expect(moonlightValidateRecord(record).valid).assertTrue();
      record.payload = record.payload.replace('Living Room PC', 'Other PC');
      expect(moonlightValidateRecord(record).reason).assertEqual('hash_mismatch');
    });

    it('accepts_a_custom_https_port_and_rejects_invalid_port_semantics', 0, (): void => {
      const record = validHostRecord();
      const customPort = moonlightPayloadWithMeta({
        schemaVersion: 1,
        serverUuid: 'server-uuid-1',
        displayName: 'Living Room PC',
        addresses: [{ host: '192.0.2.10', family: 'ipv4', port: 47989 }],
        preferredAddressKey: 'ipv4|192.0.2.10|47989',
        httpsPort: 48084,
        hostType: 'sunshine',
        wakeOnLan: { enabled: false, mac: '', broadcast: '' },
        userOrder: 0
      }, baseMeta(), 'host');
      record.payload = customPort.canonical;
      record.payloadHashSha256 = moonlightRecordPayloadHashSha256(record);
      expect(moonlightValidateRecord(record).valid).assertTrue();

      const invalidPort = moonlightPayloadWithMeta({
        schemaVersion: 1,
        serverUuid: 'server-uuid-1',
        displayName: 'Living Room PC',
        addresses: [{ host: '192.0.2.10', family: 'ipv4', port: 47989 }],
        preferredAddressKey: 'ipv4|192.0.2.10|47989',
        httpsPort: 0,
        hostType: 'sunshine',
        wakeOnLan: { enabled: false, mac: '', broadcast: '' },
        userOrder: 0
      }, baseMeta(), 'host');
      record.payload = invalidPort.canonical;
      record.payloadHashSha256 = moonlightRecordPayloadHashSha256(record);
      expect(moonlightValidateRecord(record).reason).assertEqual('invalid_payload_semantics');
    });

    it('fails_closed_on_owner_reference_and_newer_schema', 0, (): void => {
      const record = validHostRecord();
      record.ownerId = 'another-owner';
      expect(moonlightValidateRecord(record).reason).assertEqual('reference_mismatch');
      record.ownerId = 'owner-1';
      record.schemaVersion = 2;
      expect(moonlightValidateRecord(record).reason).assertEqual('schema_too_new');
    });

    it('uses_content_free_tombstones_with_envelope_order_fields', 0, (): void => {
      const record = validHostRecord();
      record.payload = '{}';
      record.deletedAt = 200;
      record.syncVersion = 2;
      record.payloadHashSha256 = moonlightRecordPayloadHashSha256(record);
      expect(moonlightValidateRecord(record).valid).assertTrue();
      record.payload = '{"serverUuid":"must-not-survive"}';
      record.payloadHashSha256 = moonlightRecordPayloadHashSha256(record);
      expect(moonlightValidateRecord(record).reason).assertEqual('invalid_tombstone');
    });

    it('accepts_only_authenticated_secret_bytes_and_metadata', 0, (): void => {
      const meta: MoonlightRecordMeta = {
        mutationId: 'secret-mutation', originId: 'owner-store-origin-1',
        baseSyncVersion: 0, fieldVersions: {}
      };
      const payload = moonlightPayloadWithMeta({
        schemaVersion: 1, identityVersion: 1,
        certificateSha256: 'a'.repeat(64), storageMode: 'cloudEncryptedPending'
      }, meta, 'secret');
      const record = new MoonlightRecord();
      record.id = 'identity-1';
      record.userId = 'owner-1';
      record.recordType = 'secret';
      record.ownerId = 'owner-1';
      record.ownerType = 'account';
      record.secretKind = 'client_identity';
      record.payload = payload.canonical;
      record.ciphertext = 'AQID';
      record.envelopeVersion = 1;
      record.cryptoVersion = 1;
      record.keyVersion = 1;
      record.aadVersion = 1;
      record.syncVersion = 1;
      record.createdAt = 1;
      record.updatedAt = 1;
      record.payloadHashSha256 = moonlightRecordPayloadHashSha256(record);
      expect(moonlightValidateRecord(record).valid).assertTrue();

      const unsafe = moonlightPayloadWithMeta({
        schemaVersion: 1, identityVersion: 1, privateKey: 'plaintext'
      }, meta, 'secret');
      record.payload = unsafe.canonical;
      record.payloadHashSha256 = moonlightRecordPayloadHashSha256(record);
      expect(moonlightValidateRecord(record).reason).assertEqual('secret_plaintext_forbidden');
    });

    it('rejects_ciphertext_above_the_envelope_ascii_bound_before_hashing', 0, (): void => {
      const record = validHostRecord();
      record.ciphertext = 'A'.repeat(MOONLIGHT_CIPHERTEXT_MAX_BYTES * 2);
      expect(moonlightValidateRecord(record).reason).assertEqual('invalid_envelope');
      record.ciphertext += 'A';
      expect(moonlightValidateRecord(record).reason).assertEqual('ciphertext_too_large');
    });

    it('rejects_nested_secret_material_and_invalid_business_shapes', 0, (): void => {
      const meta: MoonlightRecordMeta = {
        mutationId: 'secret-nested', originId: 'owner-store-origin-1',
        baseSyncVersion: 0, fieldVersions: {}
      };
      const record = new MoonlightRecord();
      record.id = 'identity-2';
      record.userId = 'owner-1';
      record.recordType = 'secret';
      record.ownerId = 'owner-1';
      record.ownerType = 'account';
      record.secretKind = 'client_identity';
      record.payload = moonlightPayloadWithMeta({
        schemaVersion: 1, identityVersion: 1, certificateSha256: 'b'.repeat(64),
        storageMode: 'cloudEncryptedPending', recoveryState: { privateKey: 'nested-plaintext' }
      }, meta, 'secret').canonical;
      record.ciphertext = 'AQID';
      record.envelopeVersion = 1;
      record.cryptoVersion = 1;
      record.keyVersion = 1;
      record.aadVersion = 1;
      record.syncVersion = 1;
      record.createdAt = 1;
      record.updatedAt = 1;
      record.payloadHashSha256 = moonlightRecordPayloadHashSha256(record);
      expect(moonlightValidateRecord(record).reason).assertEqual('secret_plaintext_forbidden');

      const host = validHostRecord();
      const invalidHost = moonlightPayloadWithMeta({
        schemaVersion: 1, serverUuid: 'server-uuid-1', displayName: 'Living Room PC',
        addresses: [], preferredAddressKey: '', hostType: 'sunshine',
        wakeOnLan: { enabled: false, mac: '', broadcast: '' }, userOrder: 0
      }, baseMeta(), 'host');
      host.payload = invalidHost.canonical;
      host.payloadHashSha256 = moonlightRecordPayloadHashSha256(host);
      expect(moonlightValidateRecord(host).reason).assertEqual('invalid_payload_semantics');

      const malformedAddress = moonlightPayloadWithMeta({
        schemaVersion: 1, serverUuid: 'server-uuid-1', displayName: 'Living Room PC',
        addresses: [{ host: 7, family: 'ipv4', port: 47989 }], preferredAddressKey: '',
        hostType: 'sunshine', wakeOnLan: { enabled: false, mac: '', broadcast: '' }, userOrder: 0
      }, baseMeta(), 'host');
      host.payload = malformedAddress.canonical;
      host.payloadHashSha256 = moonlightRecordPayloadHashSha256(host);
      expect(moonlightValidateRecord(host).reason).assertEqual('invalid_payload_semantics');
    });
  });
}
