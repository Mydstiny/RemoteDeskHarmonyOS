import { describe, expect, it } from '@ohos/hypium';
import {
  MOONLIGHT_CLOUD_TABLE,
  MoonlightRecord,
  moonlightRecordToCloudRow
} from '../main/ets/model/MoonlightRecord';
import {
  cloudTableRowsAreDownloadCompatible,
  cloudTableRowsAreUploadSafe,
  moonlightCloudRowsCarryLiveIdentity,
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

function identityCiphertext(value: string): boolean {
  return value === 'AQID';
}

export default function moonlightSensitiveTransferPolicyTest(): void {
  describe('MoonlightSensitiveTransferPolicy', (): void => {
    it('allows_an_empty_or_non_identity_snapshot_without_remote_crypto', 0,
      (): void => {
        expect(cloudTableRowsAreUploadSafe(
          MOONLIGHT_CLOUD_TABLE, [], false, identityCiphertext)).assertTrue();
        expect(cloudTableRowsAreDownloadCompatible(
          MOONLIGHT_CLOUD_TABLE, [], false, identityCiphertext)).assertTrue();
      });

    it('requires_configured_crypto_and_authenticated_ciphertext_for_live_identity_upload',
      0, (): void => {
        const rows: Array<Record<string, string>> = [
          moonlightRecordToCloudRow(identityRecord())
        ];
        expect(moonlightCloudRowsCarryLiveIdentity(rows)).assertTrue();
        expect(cloudTableRowsAreUploadSafe(
          MOONLIGHT_CLOUD_TABLE, rows, false, identityCiphertext)).assertFalse();
        expect(cloudTableRowsAreUploadSafe(
          MOONLIGHT_CLOUD_TABLE, rows, true, identityCiphertext)).assertTrue();
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

    it('pauses_only_the_moonlight_physical_table_when_identity_is_unsafe',
      0, (): void => {
        const selected: string[] = ['usersettings', MOONLIGHT_CLOUD_TABLE];
        const rows: Array<Record<string, string>> = [
          moonlightRecordToCloudRow(identityRecord())
        ];
        expect(moonlightSelectionAfterLocalCryptoTransition(
          selected, rows, false, identityCiphertext).join(','))
          .assertEqual('usersettings');
        expect(moonlightSelectionAfterLocalCryptoTransition(
          selected, rows, true, identityCiphertext).join(','))
          .assertEqual('usersettings,' + MOONLIGHT_CLOUD_TABLE);
      });
  });
}
