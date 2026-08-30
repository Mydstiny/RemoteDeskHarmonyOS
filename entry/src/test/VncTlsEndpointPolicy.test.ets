import { describe, it, expect } from '@ohos/hypium';
import {
  resolveVncTlsEndpoint,
  VncTlsGatewayInput,
  VncTlsHostInput
} from '../main/ets/services/VncTlsEndpointPolicy';

function host(transport: 'direct_tcp' | 'ultravnc_repeater' = 'direct_tcp'): VncTlsHostInput {
  return {
    id: 'host-1', userId: 'user-1', storeIdentityFingerprint: 'e'.repeat(64), label: 'Host',
    host: '192.0.2.10', port: 5900,
    username: '', gatewayId: transport === 'direct_tcp' ? '' : 'gateway-1',
    transport: transport, repeaterMode: 'mode12', targetId: transport === 'direct_tcp' ? '' : 'desk-1',
    securityPolicy: 'secure_only', tls: true
  };
}

function gateway(): VncTlsGatewayInput {
  return {
    id: 'gateway-1', userId: 'user-1', storeIdentityFingerprint: 'e'.repeat(64), label: 'Repeater',
    transport: 'ultravnc_repeater',
    host: '198.51.100.8', port: 5901, repeaterMode: 'mode12', legacyTargetId: '', tls: true,
    enabled: true
  };
}

export default function vncTlsEndpointPolicyTest(): void {
  describe('VncTlsEndpointPolicy', (): void => {
    it('binds_direct_tls_to_the_host_owner', 0, (): void => {
      const result = resolveVncTlsEndpoint(host(), null);
      expect(result.ok).assertTrue();
      expect(result.endpointOwnerType).assertEqual('host');
      expect(result.endpointOwnerId).assertEqual('host-1');
      expect(result.connectHost).assertEqual('192.0.2.10');
      expect(result.trustOwner === null).assertFalse();
      if (result.trustOwner !== null) {
        expect(result.trustOwner.ownerType).assertEqual('host');
        expect(result.trustOwner.storeIdentityFingerprint).assertEqual('e'.repeat(64));
        expect(result.trustOwner.endpointBindingFingerprint)
          .assertEqual(result.endpointBindingFingerprint);
      }
      expect(result.endpointBindingFingerprint.length).assertEqual(64);
    });

    it('separates_scoped_ipv6_connect_host_from_tls_identity', 0, (): void => {
      const input: VncTlsHostInput = host();
      input.host = '[fe80:0:0::10%wlan0]';
      const result = resolveVncTlsEndpoint(input, null);
      expect(result.ok).assertTrue();
      expect(result.connectHost).assertEqual('fe80::10%wlan0');
      expect(result.serverName).assertEqual('fe80::10');
      expect(result.trustOwner === null ? false : result.trustOwner.localOnly).assertTrue();

      const repeater: VncTlsHostInput = host('ultravnc_repeater');
      const scopedGateway: VncTlsGatewayInput = gateway();
      scopedGateway.host = 'fe80::8%eth0';
      const gatewayResult = resolveVncTlsEndpoint(repeater, scopedGateway);
      expect(gatewayResult.ok).assertTrue();
      expect(gatewayResult.connectHost).assertEqual('fe80::8%eth0');
      expect(gatewayResult.serverName).assertEqual('fe80::8');
      expect(gatewayResult.trustOwner === null ? false : gatewayResult.trustOwner.localOnly)
        .assertTrue();
    });

    it('rejects_secure_only_without_host_tls', 0, (): void => {
      const input: VncTlsHostInput = host();
      input.tls = false;
      const result = resolveVncTlsEndpoint(input, null);
      expect(result.ok).assertFalse();
      expect(result.errorCode).assertEqual('E-VNC-TLS-REQUIRED');
    });

    it('changes_binding_when_tls_mode_changes', 0, (): void => {
      const secure: VncTlsHostInput = host();
      secure.securityPolicy = 'allow_plaintext';
      const tlsResult = resolveVncTlsEndpoint(secure, null);
      expect(tlsResult.ok).assertTrue();
      secure.tls = false;
      const plaintextResult = resolveVncTlsEndpoint(secure, null);
      expect(plaintextResult.ok).assertTrue();
      expect(tlsResult.endpointBindingFingerprint ===
        plaintextResult.endpointBindingFingerprint).assertFalse();
    });

    it('binds_repeater_tls_to_the_gateway_and_host_target', 0, (): void => {
      const result = resolveVncTlsEndpoint(host('ultravnc_repeater'), gateway());
      expect(result.ok).assertTrue();
      expect(result.endpointOwnerType).assertEqual('gateway');
      expect(result.endpointOwnerId).assertEqual('gateway-1');
      expect(result.connectHost).assertEqual('198.51.100.8');
      expect(result.repeaterTarget).assertEqual('desk-1');
      expect(result.usedLegacyTargetFallback).assertFalse();
      expect(result.trustOwner === null).assertFalse();
      if (result.trustOwner !== null) {
        expect(result.trustOwner.ownerType).assertEqual('gateway');
        expect(result.trustOwner.ownerId).assertEqual('gateway-1');
        expect(result.trustOwner.userId).assertEqual('user-1');
        expect(result.trustOwner.storeIdentityFingerprint).assertEqual('e'.repeat(64));
        expect(result.trustOwner.endpointBindingFingerprint)
          .assertEqual(result.endpointBindingFingerprint);
      }
    });

    it('changes_repeater_binding_when_gateway_tls_changes', 0, (): void => {
      const repeaterHost: VncTlsHostInput = host('ultravnc_repeater');
      repeaterHost.securityPolicy = 'allow_plaintext';
      const secureGateway: VncTlsGatewayInput = gateway();
      const secure = resolveVncTlsEndpoint(repeaterHost, secureGateway);
      expect(secure.ok).assertTrue();
      secureGateway.tls = false;
      const plaintext = resolveVncTlsEndpoint(repeaterHost, secureGateway);
      expect(plaintext.ok).assertTrue();
      expect(secure.endpointBindingFingerprint === plaintext.endpointBindingFingerprint)
        .assertFalse();
    });

    it('does_not_accept_a_gateway_from_another_scope_or_transport', 0, (): void => {
      const otherScope: VncTlsGatewayInput = gateway();
      otherScope.userId = 'other-user';
      expect(resolveVncTlsEndpoint(host('ultravnc_repeater'), otherScope).errorCode)
        .assertEqual('E-VNC-ENDPOINT-OWNER');
      const otherStore: VncTlsGatewayInput = gateway();
      otherStore.storeIdentityFingerprint = 'f'.repeat(64);
      expect(resolveVncTlsEndpoint(host('ultravnc_repeater'), otherStore).errorCode)
        .assertEqual('E-VNC-ENDPOINT-OWNER');
      const wrongTransport: VncTlsGatewayInput = gateway();
      wrongTransport.transport = 'websocket_gateway';
      expect(resolveVncTlsEndpoint(host('ultravnc_repeater'), wrongTransport).errorCode)
        .assertEqual('E-VNC-GATEWAY-TRANSPORT');
    });

    it('fails_closed_for_invalid_direct_and_repeater_combinations', 0, (): void => {
      const direct: VncTlsHostInput = host();
      expect(resolveVncTlsEndpoint(direct, gateway()).errorCode)
        .assertEqual('E-VNC-ENDPOINT-OWNER');
      const invalidStore: VncTlsHostInput = host();
      invalidStore.storeIdentityFingerprint = 'not-a-fingerprint';
      expect(resolveVncTlsEndpoint(invalidStore, null).errorCode)
        .assertEqual('E-VNC-ENDPOINT-OWNER');
      const noTlsGateway: VncTlsGatewayInput = gateway();
      noTlsGateway.tls = false;
      expect(resolveVncTlsEndpoint(host('ultravnc_repeater'), noTlsGateway).errorCode)
        .assertEqual('E-VNC-TLS-REQUIRED');
      const disabledGateway: VncTlsGatewayInput = gateway();
      disabledGateway.enabled = false;
      expect(resolveVncTlsEndpoint(host('ultravnc_repeater'), disabledGateway).errorCode)
        .assertEqual('E-VNC-GATEWAY-DISABLED');
      const wrongMode: VncTlsGatewayInput = gateway();
      wrongMode.repeaterMode = 'mode2';
      expect(resolveVncTlsEndpoint(host('ultravnc_repeater'), wrongMode).errorCode)
        .assertEqual('E-VNC-GATEWAY-TRANSPORT');
      const noTarget: VncTlsHostInput = host('ultravnc_repeater');
      noTarget.targetId = '';
      expect(resolveVncTlsEndpoint(noTarget, gateway()).errorCode)
        .assertEqual('E-VNC-REPEATER-TARGET');
    });

    it('uses_legacy_gateway_target_only_as_a_compatibility_fallback', 0, (): void => {
      const input: VncTlsHostInput = host('ultravnc_repeater');
      input.targetId = '';
      const oldGateway: VncTlsGatewayInput = gateway();
      oldGateway.legacyTargetId = 'legacy-desk';
      const result = resolveVncTlsEndpoint(input, oldGateway);
      expect(result.ok).assertTrue();
      expect(result.repeaterTarget).assertEqual('legacy-desk');
      expect(result.usedLegacyTargetFallback).assertTrue();
    });

    it('keeps_unimplemented_transports_fail_closed', 0, (): void => {
      const input: VncTlsHostInput = host();
      input.transport = 'websocket_gateway';
      expect(resolveVncTlsEndpoint(input, null).errorCode).assertEqual('E-VNC-ENDPOINT-TRANSPORT');
    });
  });
}
