import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  MOONLIGHT_CLOUD_TABLE,
  MoonlightRecord,
  moonlightRecordToCloudRow
} from '../main/ets/model/MoonlightRecord';
import {
  cloudDownloadValidationMode,
  cloudTableRowsAreDownloadCompatible,
  cloudTableRowsAreUploadSafe,
  moonlightCloudRowsCarryLiveIdentity,
  moonlightPhysicalMutationShouldRemainPending,
  moonlightPhysicalCloudRowsAreUploadSafe,
  moonlightSelectionAfterLocalCryptoTransition
} from '../main/ets/services/CloudSensitiveTransferPolicy';
import {
  MoonlightRecordMeta,
  moonlightPayloadWithMeta,
  moonlightRecordPayloadHashSha256
} from '../main/ets/services/MoonlightRecordPolicy';

function identityRecord(): MoonlightRecord {
  const meta: MoonlightRecordMeta = {
    mutationId: 'identity-mutation', originId: 'owner-a-origin',
    baseSyncVersion: 0, fieldVersions: {}
  };
  const payload = moonlightPayloadWithMeta({
    schemaVersion: 1, identityVersion: 1,
    certificateSha256: 'a'.repeat(64),
    storageMode: 'cloudEncryptedPending'
  }, meta, 'secret');
  const record = new MoonlightRecord();
  record.id = 'identity-1';
  record.userId = 'owner-a';
  record.recordType = 'secret';
  record.ownerId = 'owner-a';
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
  return record;
}

function hostRecord(owner: string = 'owner-a'): MoonlightRecord {
  const meta: MoonlightRecordMeta = {
    mutationId: 'host-mutation', originId: owner + '-origin',
    baseSyncVersion: 0, fieldVersions: { 'displayName': 1 }
  };
  const payload = moonlightPayloadWithMeta({
    schemaVersion: 1,
    serverUuid: 'server-host-1',
    displayName: 'Host 1',
    addresses: [{ host: '192.0.2.10', family: 'ipv4', port: 47989 }],
    preferredAddressKey: 'ipv4|192.0.2.10|47989',
    hostType: 'sunshine',
    wakeOnLan: { enabled: false, mac: '', broadcast: '' },
    userOrder: 0
  }, meta, 'host');
  const record = new MoonlightRecord();
  record.id = 'host-1';
  record.userId = owner;
  record.recordType = 'host';
  record.ownerId = owner;
  record.ownerType = 'account';
  record.payload = payload.canonical;
  record.syncVersion = 1;
  record.createdAt = 1;
  record.updatedAt = 1;
  record.payloadHashSha256 = moonlightRecordPayloadHashSha256(record);
  return record;
}

function trustRecord(): MoonlightRecord {
  const meta: MoonlightRecordMeta = {
    mutationId: 'trust-mutation', originId: 'owner-a-origin',
    baseSyncVersion: 0, fieldVersions: {}
  };
  const payload = moonlightPayloadWithMeta({
    schemaVersion: 1,
    hostId: 'host-1',
    serverUuid: 'server-host-1',
    serverCertificateSha256: 'b'.repeat(64),
    pairingGeneration: 1,
    candidateObservedAt: 1
  }, meta, 'trust');
  const record = new MoonlightRecord();
  record.id = 'trust-1';
  record.userId = 'owner-a';
  record.recordType = 'trust';
  record.ownerId = 'host-1';
  record.ownerType = 'host';
  record.payload = payload.canonical;
  record.syncVersion = 1;
  record.createdAt = 1;
  record.updatedAt = 1;
  record.payloadHashSha256 = moonlightRecordPayloadHashSha256(record);
  return record;
}

function identityCiphertext(value: string): boolean {
  return value === 'AQID';
}

export default function moonlightSensitiveTransferPolicyTest(): void {
  describe('MoonlightSensitiveTransferPolicy', (): void => {
    it('isolates_bad_moonlight_rows_without_weakening_legacy_table_checks',
      0, (): void => {
        expect(cloudDownloadValidationMode(MOONLIGHT_CLOUD_TABLE))
          .assertEqual('record_isolation');
        expect(cloudDownloadValidationMode('remotehosts'))
          .assertEqual('whole_snapshot');
        expect(cloudDownloadValidationMode('cryptoparams'))
          .assertEqual('whole_snapshot');
      });

    it('allows_an_empty_or_non_identity_snapshot_without_remote_crypto', 0,
      (): void => {
        expect(cloudTableRowsAreUploadSafe(
          MOONLIGHT_CLOUD_TABLE, [], false, identityCiphertext)).assertTrue();
        expect(cloudTableRowsAreDownloadCompatible(
          MOONLIGHT_CLOUD_TABLE, [], false, identityCiphertext)).assertTrue();
      });

    it('never_uploads_device_bound_identity_even_when_encrypted',
      0, (): void => {
        const rows: Array<Record<string, string>> = [
          moonlightRecordToCloudRow(identityRecord())
        ];
        expect(moonlightCloudRowsCarryLiveIdentity(rows)).assertTrue();
        expect(cloudTableRowsAreUploadSafe(
          MOONLIGHT_CLOUD_TABLE, rows, false, identityCiphertext)).assertFalse();
        expect(cloudTableRowsAreUploadSafe(
          MOONLIGHT_CLOUD_TABLE, rows, true, identityCiphertext)).assertFalse();
        expect(cloudTableRowsAreUploadSafe(
          MOONLIGHT_CLOUD_TABLE, rows, true, (_value: string): boolean => false))
          .assertFalse();
      });

    it('retains_existing_authenticated_ciphertext_as_download_compatible_after_reset',
      0, (): void => {
        const rows: Array<Record<string, string>> = [
          moonlightRecordToCloudRow(identityRecord())
        ];
        expect(cloudTableRowsAreDownloadCompatible(
          MOONLIGHT_CLOUD_TABLE, rows, false, identityCiphertext)).assertTrue();
        expect(cloudTableRowsAreDownloadCompatible(
          MOONLIGHT_CLOUD_TABLE, rows, false,
          (_value: string): boolean => false)).assertFalse();
      });

    it('rejects_missing_unknown_and_semantically_tampered_envelopes', 0,
      (): void => {
        const missing: Record<string, string> =
          moonlightRecordToCloudRow(identityRecord());
        delete missing['aadversion'];
        expect(cloudTableRowsAreUploadSafe(
          MOONLIGHT_CLOUD_TABLE, [missing], true, identityCiphertext)).assertFalse();
        const extra: Record<string, string> =
          moonlightRecordToCloudRow(identityRecord());
        extra['privatekey'] = 'never';
        expect(cloudTableRowsAreDownloadCompatible(
          MOONLIGHT_CLOUD_TABLE, [extra], true, identityCiphertext)).assertFalse();
        const tampered: Record<string, string> =
          moonlightRecordToCloudRow(identityRecord());
        tampered['payloadhashsha256'] = 'b'.repeat(64);
        expect(cloudTableRowsAreUploadSafe(
          MOONLIGHT_CLOUD_TABLE, [tampered], true, identityCiphertext)).assertFalse();
      });

    it('rejects_cross_owner_and_device_bound_rows_at_the_physical_boundary',
      0, (): void => {
        const selected: string[] = ['usersettings', MOONLIGHT_CLOUD_TABLE];
        const rows: Array<Record<string, string>> = [
          moonlightRecordToCloudRow(identityRecord())
        ];
        expect(moonlightPhysicalCloudRowsAreUploadSafe(
          [], 'owner-a', false, identityCiphertext)).assertTrue();
        expect(moonlightPhysicalCloudRowsAreUploadSafe(
          [], '', false, identityCiphertext)).assertFalse();
        expect(moonlightPhysicalCloudRowsAreUploadSafe(
          rows, 'owner-a', true, identityCiphertext)).assertFalse();
        expect(moonlightPhysicalCloudRowsAreUploadSafe(
          [moonlightRecordToCloudRow(trustRecord())], 'owner-a', true,
          identityCiphertext)).assertFalse();
        const foreign: Record<string, string> =
          moonlightRecordToCloudRow(hostRecord('owner-b'));
        expect(moonlightPhysicalCloudRowsAreUploadSafe(
          [foreign], 'owner-a', true, identityCiphertext)).assertFalse();
        expect(moonlightPhysicalCloudRowsAreUploadSafe(
          [moonlightRecordToCloudRow(hostRecord())], 'owner-a', false,
          identityCiphertext)).assertTrue();
        const liveHostRow: Record<string, string> =
          moonlightRecordToCloudRow(hostRecord());
        expect(moonlightPhysicalCloudRowsAreUploadSafe(
          [liveHostRow], 'owner-a', false, identityCiphertext,
          ['settings'])).assertFalse();
        expect(moonlightPhysicalCloudRowsAreUploadSafe(
          [liveHostRow], 'owner-a', false, identityCiphertext,
          ['settings'], [])).assertTrue();
        expect(moonlightPhysicalCloudRowsAreUploadSafe(
          [liveHostRow], 'owner-a', false, identityCiphertext,
          ['settings'], ['host-1'])).assertFalse();
        expect(moonlightPhysicalCloudRowsAreUploadSafe(
          [liveHostRow], 'owner-a', false, identityCiphertext,
          ['settings'], ['__table__'])).assertFalse();
        expect(moonlightPhysicalCloudRowsAreUploadSafe(
          [liveHostRow], 'owner-a', false, identityCiphertext,
          ['hosts'])).assertTrue();
        const deletedHost: MoonlightRecord = hostRecord();
        deletedHost.payload = '{}';
        deletedHost.syncVersion += 1;
        deletedHost.updatedAt = 2;
        deletedHost.deletedAt = 2;
        deletedHost.payloadHashSha256 =
          moonlightRecordPayloadHashSha256(deletedHost);
        expect(moonlightPhysicalCloudRowsAreUploadSafe(
          [moonlightRecordToCloudRow(deletedHost)], 'owner-a', false,
          identityCiphertext, ['settings'])).assertTrue();
        expect(moonlightSelectionAfterLocalCryptoTransition(
          selected, rows, false, identityCiphertext).join(','))
          .assertEqual('usersettings');
        expect(moonlightSelectionAfterLocalCryptoTransition(
          selected, rows, true, identityCiphertext).join(','))
          .assertEqual('usersettings');
      });

    it('retires_only_deselected_live_physical_mutations_after_cloud_first',
      0, (): void => {
        expect(moonlightPhysicalMutationShouldRemainPending(
          'host', 0, ['settings'])).assertFalse();
        expect(moonlightPhysicalMutationShouldRemainPending(
          'host', 0, ['hosts'])).assertTrue();
        expect(moonlightPhysicalMutationShouldRemainPending(
          'host', 20, ['settings'])).assertTrue();
        expect(moonlightPhysicalMutationShouldRemainPending(
          'host', -1, ['settings'])).assertTrue();
      });
  });
}
