import { describe, it, expect } from '@ohos/hypium';
import {
  removeVncTrustMarkersForEndpoint,
  removeVncTrustMarkersForOwner,
  vncGatewayTrustEndpointChanged,
  vncHostTrustEndpointChanged,
  vncTrustMarkerKey,
  vncTrustMarkerLoadState,
  vncTrustPersistenceCommitState
} from '../main/ets/services/VncTrustInvalidationPolicy';
import { VncGatewayValues, VncHostValues } from '../main/ets/services/VncModelPolicy';

const STORE: string = 'a'.repeat(64);
const BINDING: string = 'b'.repeat(64);
const ROTATED: string = 'c'.repeat(64);

function host(): VncHostValues {
  return {
    label: 'host', host: '192.0.2.10', port: 5900, username: '', gatewayId: '',
    transport: 'direct_tcp', repeaterMode: 'mode12', rememberPassword: false,
    viewOnly: false, displayOverrideEnabled: true, scalingMode: 'fit',
    clipboardEnabled: false, securityPolicy: 'secure_only', tls: true,
    locked: false, lockType: 0
  };
}

function repeaterHost(): VncHostValues {
  const value: VncHostValues = host();
  value.host = 'target-one';
  value.gatewayId = 'gateway-1';
  value.transport = 'ultravnc_repeater';
  return value;
}

function gateway(): VncGatewayValues {
  return {
    label: 'gateway', transport: 'ultravnc_repeater', host: '198.51.100.10', port: 5901,
    path: '/vnc', repeaterMode: 'mode12', targetId: 'legacy-target', tls: true, enabled: true
  };
}

export default function vncTrustInvalidationPolicyTest(): void {
  describe('VncTrustInvalidationPolicy', (): void => {
    it('writes_owner_type_aware_markers_and_reads_legacy_markers', 0, (): void => {
      const marker: string = vncTrustMarkerKey({
        userId: 'user-1', storeIdentityFingerprint: STORE, ownerType: 'gateway',
        ownerId: 'gateway-1', fingerprintSha256: ROTATED,
        endpointBindingFingerprint: BINDING
      });
      expect(marker.split('|').length).assertEqual(6);
      const legacy: string = 'user-1|' + STORE + '|gateway-1|' + ROTATED + '|' + BINDING;
      const old: string = 'user-1|gateway-1|' + ROTATED;
      expect(removeVncTrustMarkersForOwner(
        [marker, legacy, old], 'user-1', 'gateway', 'gateway-1', STORE).length)
        .assertEqual(1);
    });

    it('removes_only_the_rotated_endpoint_and_keeps_other_bindings', 0, (): void => {
      const first: string = vncTrustMarkerKey({
        userId: 'user-1', storeIdentityFingerprint: STORE, ownerType: 'host', ownerId: 'host-1',
        fingerprintSha256: ROTATED, endpointBindingFingerprint: BINDING
      });
      const otherBinding: string = vncTrustMarkerKey({
        userId: 'user-1', storeIdentityFingerprint: STORE, ownerType: 'host', ownerId: 'host-1',
        fingerprintSha256: ROTATED, endpointBindingFingerprint: 'd'.repeat(64)
      });
      const kept = removeVncTrustMarkersForEndpoint(
        [first, otherBinding], 'user-1', 'host', 'host-1', BINDING, STORE);
      expect(kept.length).assertEqual(1);
      expect(kept[0]).assertEqual(otherBinding);
    });

    it('never_removes_a_marker_from_another_physical_store', 0, (): void => {
      const stale: string = vncTrustMarkerKey({
        userId: 'user-1', storeIdentityFingerprint: 'd'.repeat(64), ownerType: 'host',
        ownerId: 'host-1', fingerprintSha256: ROTATED, endpointBindingFingerprint: BINDING
      });
      const current: string = vncTrustMarkerKey({
        userId: 'user-1', storeIdentityFingerprint: STORE, ownerType: 'host',
        ownerId: 'host-1', fingerprintSha256: ROTATED, endpointBindingFingerprint: BINDING
      });
      const kept = removeVncTrustMarkersForEndpoint(
        [stale, current], 'user-1', 'host', 'host-1', BINDING, STORE);
      expect(kept.length).assertEqual(1);
      expect(kept[0]).assertEqual(stale);
    });

    it('keeps_restart_fail_closed_when_an_invalidation_journal_survives', 0, (): void => {
      const marker: string = vncTrustMarkerKey({
        userId: 'user-1', storeIdentityFingerprint: STORE, ownerType: 'gateway',
        ownerId: 'gateway-1', fingerprintSha256: ROTATED, endpointBindingFingerprint: BINDING
      });
      const loaded = vncTrustMarkerLoadState(JSON.stringify([marker]),
        '{"ownerType":"gateway","ownerId":"gateway-1"}');
      expect(loaded.failClosed).assertTrue();
      expect(loaded.markers.length).assertEqual(0);
      const clean = vncTrustMarkerLoadState(JSON.stringify([marker]), '');
      expect(clean.failClosed).assertFalse();
      expect(clean.markers.length).assertEqual(1);
    });

    it('treats_every_preferences_write_failure_as_fail_closed', 0, (): void => {
      const journalFailure = vncTrustPersistenceCommitState(false, false, false);
      expect(journalFailure.ok).assertFalse();
      expect(journalFailure.failClosed).assertTrue();
      expect(journalFailure.restorePrevious).assertTrue();
      const markerFailure = vncTrustPersistenceCommitState(true, false, false);
      expect(markerFailure.ok).assertFalse();
      expect(markerFailure.failClosed).assertTrue();
      expect(markerFailure.restorePrevious).assertTrue();
      const clearFailure = vncTrustPersistenceCommitState(true, true, false);
      expect(clearFailure.ok).assertFalse();
      expect(clearFailure.failClosed).assertTrue();
      expect(clearFailure.restorePrevious).assertFalse();
      expect(vncTrustMarkerLoadState('{malformed', '').failClosed).assertTrue();
    });

    it('changes_direct_host_identity_but_not_repeater_target', 0, (): void => {
      const previous: VncHostValues = host();
      const next: VncHostValues = host();
      next.host = '192.0.2.11';
      expect(vncHostTrustEndpointChanged(previous, next)).assertTrue();
      const oldRepeater: VncHostValues = repeaterHost();
      const nextRepeater: VncHostValues = repeaterHost();
      nextRepeater.host = 'target-two';
      expect(vncHostTrustEndpointChanged(oldRepeater, nextRepeater)).assertFalse();
      nextRepeater.tls = false;
      expect(vncHostTrustEndpointChanged(oldRepeater, nextRepeater)).assertTrue();
    });

    it('changes_gateway_identity_for_endpoint_and_availability_fields', 0, (): void => {
      const previous: VncGatewayValues = gateway();
      const labelOnly: VncGatewayValues = gateway();
      labelOnly.label = 'renamed';
      expect(vncGatewayTrustEndpointChanged(previous, labelOnly)).assertFalse();
      const changed: VncGatewayValues = gateway();
      changed.host = '198.51.100.11';
      expect(vncGatewayTrustEndpointChanged(previous, changed)).assertTrue();
      const disabled: VncGatewayValues = gateway();
      disabled.enabled = false;
      expect(vncGatewayTrustEndpointChanged(previous, disabled)).assertTrue();
    });
  });
}
