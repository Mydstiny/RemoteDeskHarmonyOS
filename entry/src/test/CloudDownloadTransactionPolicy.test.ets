import { describe, expect, it } from '@ohos/hypium';
import {
  CloudDownloadTransactionEnvelope,
  cloudDownloadTransactionEnvelope,
  parseCloudDownloadTransactionEnvelope
} from '../main/ets/services/CloudDownloadTransactionPolicy';

export default function cloudDownloadTransactionPolicyTest():
  void {
  describe('CloudDownloadTransactionPolicy', (): void => {
    it('accepts_only_the_same_owner_store_and_a_non_future_generation',
      0, (): void => {
        const envelope: CloudDownloadTransactionEnvelope | null =
          cloudDownloadTransactionEnvelope(
            'manual_download',
            'owner-a',
            'store-a.db',
            7,
            '{"tables":{}}',
            100);
        expect(envelope === null).assertFalse();
        if (envelope === null) { return; }
        const raw: string = JSON.stringify(envelope);
        expect(parseCloudDownloadTransactionEnvelope(
          raw, 'owner-a', 'store-a.db', 7) !== null)
          .assertTrue();
        expect(parseCloudDownloadTransactionEnvelope(
          raw, 'owner-a', 'store-a.db', 8) !== null)
          .assertTrue();
        expect(parseCloudDownloadTransactionEnvelope(
          raw, 'owner-b', 'store-a.db', 8) === null)
          .assertTrue();
        expect(parseCloudDownloadTransactionEnvelope(
          raw, 'owner-a', 'store-b.db', 8) === null)
          .assertTrue();
        expect(parseCloudDownloadTransactionEnvelope(
          raw, 'owner-a', 'store-a.db', 6) === null)
          .assertTrue();
      });

    it('rejects_payload_tampering',
      0, (): void => {
        const envelope: CloudDownloadTransactionEnvelope | null =
          cloudDownloadTransactionEnvelope(
            'startup_bootstrap',
            'owner-a',
            'store-a.db',
            3,
            '{"before":"safe"}',
            100);
        expect(envelope === null).assertFalse();
        if (envelope === null) { return; }
        envelope.payloadJson = '{"before":"tampered"}';
        expect(parseCloudDownloadTransactionEnvelope(
          JSON.stringify(envelope),
          'owner-a', 'store-a.db', 3) === null)
          .assertTrue();
      });
  });
}
