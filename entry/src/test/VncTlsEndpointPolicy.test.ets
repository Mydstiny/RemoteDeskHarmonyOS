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
      }
      expect(result.endpointBindingFingerprint.length).assertEqual(64);
    });

    it('rejects_secure_only_without_host_tls', 0, (): void => {
      const input: VncTlsHostInput = host();
      input.tls = false;
      const result = resolveVncTlsEndpoint(input, null);
      expect(result.ok).assertFalse();
      expect(result.errorCode).assertEqual('E-VNC-TLS-REQUIRED');
    });

    it('binds_repeater_tls_to_the_gateway_and_host_target', 0, (): void => {
      const result = resolveVncTlsEndpoint(host('ultravnc_repeater'), gateway());
      expect(result.ok).assertTrue();
      expect(result.endpointOwnerType).assertEqual('gateway');
      expect(result.endpointOwnerId).assertEqual('gateway-1');
      expect(result.connectHost).assertEqual('198.51.100.8');
      expect(result.repeaterTarget).assertEqual('desk-1');
      expect(result.usedLegacyTargetFallback).assertFalse();
    });

    it('does_not_accept_a_gateway_from_another_scope_or_transport', 0, (): void => {
      const otherScope: VncTlsGatewayInput = gateway();
      otherScope.userId = 'other-user';
      expect(resolveVncTlsEndpoint(host('ultravnc_repeater'), otherScope).errorCode)
        .assertEqual('E-VNC-ENDPOINT-OWNER');
      const wrongTransport: VncTlsGatewayInput = gateway();
      wrongTransport.transport = 'websocket_gateway';
      expect(resolveVncTlsEndpoint(host('ultravnc_repeater'), wrongTransport).errorCode)
        .assertEqual('E-VNC-GATEWAY-TRANSPORT');
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
