import { describe, it, expect } from '@ohos/hypium';
import {
  VncTrustEndpoint,
  vncStoreIdentityFingerprint,
  vncTrustEndpointIsValid,
  vncTrustStoreMatchesCurrent,
  vncTrustViewStateForStore,
  VncTrustService,
  vncTrustV2ReadBackMatches,
  vncTrustMigrationNeedsCleanup,
  vncTrustLegacyRowIsCleaned
} from '../main/ets/services/VncTrustService';
import { vncTrustPayload, VncTrustCertificateMetadata, finalizeVncRecord } from '../main/ets/services/VncModelPolicy';
import { vncTrustPayloadIsLegacy, vncRecordIsValid } from '../main/ets/services/VncRecordPolicy';
import { VncRecord } from '../main/ets/model/VncRecord';
import { AccountSessionCoordinator } from '../main/ets/services/AccountSessionCoordinator';

const STORE: string = 'a'.repeat(64);
const BINDING: string = 'b'.repeat(64);
const OTHER_STORE: string = 'c'.repeat(64);

function endpoint(ownerType: 'host' | 'gateway' = 'gateway'): VncTrustEndpoint {
  return {
    ownerType: ownerType,
    ownerId: ownerType === 'gateway' ? 'gateway-1' : 'host-1',
    userId: 'user-1',
    storeIdentityFingerprint: STORE,
    endpointBindingFingerprint: BINDING,
    localOnly: false
  };
}

export default function vncTrustServiceTest(): void {
  describe('VncTrustService endpoint contract', (): void => {
    it('accepts_gateway_and_host_endpoint_owners', 0, (): void => {
      expect(vncTrustEndpointIsValid(endpoint('gateway'), 'user-1', STORE)).assertTrue();
      expect(vncTrustEndpointIsValid(endpoint('host'), 'user-1', STORE)).assertTrue();
    });

    it('rejects_scope_store_and_binding_mismatches', 0, (): void => {
      const wrongScope: VncTrustEndpoint = endpoint();
      wrongScope.userId = 'other-user';
      expect(vncTrustEndpointIsValid(wrongScope, 'user-1', STORE)).assertFalse();

      const missingStore: VncTrustEndpoint = endpoint();
      missingStore.storeIdentityFingerprint = '';
      expect(vncTrustEndpointIsValid(missingStore, 'user-1', STORE)).assertFalse();

      const missingBinding: VncTrustEndpoint = endpoint();
      missingBinding.endpointBindingFingerprint = 'not-a-fingerprint';
      expect(vncTrustEndpointIsValid(missingBinding, 'user-1', STORE)).assertFalse();

      const wrongPhysicalStore: VncTrustEndpoint = endpoint();
      expect(vncTrustEndpointIsValid(wrongPhysicalStore, 'user-1', OTHER_STORE)).assertFalse();
    });

    it('rejects_blank_owner_and_account_scope', 0, (): void => {
      const blankOwner: VncTrustEndpoint = endpoint();
      blankOwner.ownerId = ' ';
      expect(vncTrustEndpointIsValid(blankOwner, 'user-1', STORE)).assertFalse();
      expect(vncTrustEndpointIsValid(endpoint(), '', STORE)).assertFalse();
    });

    it('derives_a_stable_current_store_fingerprint_and_rejects_blank_store', 0, (): void => {
      expect(vncStoreIdentityFingerprint('store-a')).assertEqual(
        vncStoreIdentityFingerprint('store-a'));
      expect(vncStoreIdentityFingerprint('')).assertEqual('');
    });

    it('downgrades_old_store_rows_and_rejects_owner_only_queries', 0, (): void => {
      expect(vncTrustStoreMatchesCurrent(STORE, STORE)).assertTrue();
      expect(vncTrustStoreMatchesCurrent(STORE, OTHER_STORE)).assertFalse();
      expect(vncTrustStoreMatchesCurrent('not-a-fingerprint', STORE)).assertFalse();
      const staleView = vncTrustViewStateForStore(true, true, OTHER_STORE, STORE);
      expect(staleView.confirmed).assertFalse();
      expect(staleView.cloudCandidate).assertTrue();
      const currentView = vncTrustViewStateForStore(true, true, STORE, STORE);
      expect(currentView.confirmed).assertTrue();
      expect(currentView.cloudCandidate).assertFalse();

      const service: VncTrustService = VncTrustService.getInstance();
      const scope = AccountSessionCoordinator.getInstance().currentScope();
      const staleEndpoint: VncTrustEndpoint = {
        ownerType: 'gateway',
        ownerId: 'gateway-1',
        userId: scope.ownerScopeId,
        storeIdentityFingerprint: OTHER_STORE,
        endpointBindingFingerprint: BINDING,
        localOnly: false
      };
      expect(service.trustForEndpoint(staleEndpoint) === null).assertTrue();
      expect(service.isTrusted(staleEndpoint, 'd'.repeat(64))).assertFalse();
      expect(service.trustedFingerprint(staleEndpoint)).assertEqual('');
    });

    it('keeps_v1_rows_as_candidates_and_writes_v2_metadata', 0, (): void => {
      const legacyPayload: string = JSON.stringify({
        fingerprintSha256: 'd'.repeat(64), confirmed: true, confirmedAt: 1700000000000,
        ownerType: 'gateway'
      });
      expect(vncTrustPayloadIsLegacy(legacyPayload, 'gateway')).assertTrue();
      const legacy = new VncRecord();
      legacy.id = 'legacy-trust'; legacy.userId = 'user-1'; legacy.recordType = 'trust';
      legacy.ownerId = 'gateway-1'; legacy.ownerType = 'gateway'; legacy.payload = legacyPayload;
      legacy.createdAt = 1700000000000; legacy.updatedAt = 1700000000000;
      finalizeVncRecord(legacy);
      expect(vncRecordIsValid(legacy)).assertTrue();

      const metadata: VncTrustCertificateMetadata = {
        endpointLabel: 'Office Gateway', commonName: 'vnc.example.test',
        subject: 'CN=vnc.example.test', issuer: 'CN=Test CA',
        notBeforeMs: 1700000000000, notAfterMs: 1800000000000,
        rootTrusted: true, hostMismatch: false
      };
      const upgraded: string = vncTrustPayload('d'.repeat(64), true, 1700000000000,
        'gateway', STORE, BINDING, metadata);
      expect(vncTrustPayloadIsLegacy(upgraded, 'gateway')).assertFalse();
      const upgradedView: Record<string, Object> = JSON.parse(upgraded) as Record<string, Object>;
      expect(upgradedView['payloadVersion'] as number).assertEqual(2);
      expect(upgradedView['endpointLabel'] as string).assertEqual('Office Gateway');

      const v2Record = new VncRecord();
      v2Record.id = 'v2-trust'; v2Record.userId = 'user-1'; v2Record.recordType = 'trust';
      v2Record.ownerId = 'gateway-1'; v2Record.ownerType = 'gateway'; v2Record.payload = upgraded;
      v2Record.createdAt = 1700000000000; v2Record.updatedAt = 1700000000000;
      finalizeVncRecord(v2Record);
      expect(vncRecordIsValid(v2Record)).assertTrue();

      const unknownVersion: Record<string, Object> = JSON.parse(upgraded) as Record<string, Object>;
      unknownVersion['payloadVersion'] = 3;
      const malformed = new VncRecord();
      malformed.id = 'v3-trust'; malformed.userId = 'user-1'; malformed.recordType = 'trust';
      malformed.ownerId = 'gateway-1'; malformed.ownerType = 'gateway';
      malformed.payload = JSON.stringify(unknownVersion);
      malformed.createdAt = 1700000000000; malformed.updatedAt = 1700000000000;
      finalizeVncRecord(malformed);
      expect(vncRecordIsValid(malformed)).assertFalse();
      expect(vncTrustMigrationNeedsCleanup('legacy-id', 'v2-id')).assertTrue();
      expect(vncTrustMigrationNeedsCleanup('v2-id', 'v2-id')).assertFalse();
      expect(vncTrustLegacyRowIsCleaned([legacy], legacy.id)).assertFalse();
      const tombstone = new VncRecord();
      tombstone.id = legacy.id;
      tombstone.deletedAt = 1700000000001;
      expect(vncTrustLegacyRowIsCleaned([tombstone], legacy.id)).assertTrue();
      expect(vncTrustLegacyRowIsCleaned([], legacy.id)).assertTrue();
      expect(vncTrustV2ReadBackMatches(v2Record, 'gateway', 'gateway-1', 'user-1',
        'd'.repeat(64), STORE, BINDING)).assertTrue();
      expect(vncTrustV2ReadBackMatches(legacy, 'gateway', 'gateway-1', 'user-1',
        'd'.repeat(64), STORE, BINDING)).assertFalse();

      const markerPayload: Record<string, Object> = JSON.parse(upgraded) as Record<string, Object>;
      markerPayload['localConfirmationMarker'] = true;
      const markerRecord = new VncRecord();
      markerRecord.id = 'marker-trust'; markerRecord.userId = 'user-1';
      markerRecord.recordType = 'trust'; markerRecord.ownerId = 'gateway-1';
      markerRecord.ownerType = 'gateway'; markerRecord.payload = JSON.stringify(markerPayload);
      markerRecord.createdAt = 1700000000000; markerRecord.updatedAt = 1700000000000;
      finalizeVncRecord(markerRecord);
      expect(vncRecordIsValid(markerRecord)).assertFalse();
    });
  });
}
