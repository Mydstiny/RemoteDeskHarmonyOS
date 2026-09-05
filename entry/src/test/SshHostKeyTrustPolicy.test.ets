import { describe, it, expect } from '@ohos/hypium';
import { RemoteHost } from '../main/ets/model/RemoteHost';
import { SshProxyProfileV1 } from '../main/ets/services/SshProxyProfilePolicy';
import { resolveSshProxyRuntimePlan } from '../main/ets/services/SshProxyRuntimePolicy';
import {
  sshHostKeyPinsForRoute,
  sshHostKeyRouteBinding,
  sshHostKeyTrustIsCurrent
} from '../main/ets/services/SshHostKeyTrustPolicy';

function host(address: string = '2001:db8::10'): RemoteHost {
  const value: RemoteHost = new RemoteHost();
  value.id = 'host-a';
  value.protocol = 'ssh';
  value.host = address;
  value.port = 22;
  value.username = 'target-user';
  return value;
}

function directProfile(value: RemoteHost): SshProxyProfileV1 {
  return {
    schemaVersion: 1, hostId: value.id,
    route: {
      schemaVersion: 1, type: 'direct', endpointHost: value.host,
      endpointPort: value.port, hops: [], connectTimeoutMs: 10000
    }
  };
}

function jumpProfile(value: RemoteHost): SshProxyProfileV1 {
  return {
    schemaVersion: 1, hostId: value.id,
    route: {
      schemaVersion: 1, type: 'ssh_jump', endpointHost: value.host,
      endpointPort: value.port, connectTimeoutMs: 10000,
      hops: [
        { host: '2001:db8::20', port: 22, username: 'first',
          authMethod: 'publickey', expectedHostKeyFingerprintSha256: 'SHA256:hop-one',
          connectTimeoutMs: 9000 },
        { host: '2001:db8::30', port: 2222, username: 'second',
          authMethod: 'password', expectedHostKeyFingerprintSha256: 'SHA256:hop-two',
          connectTimeoutMs: 8000 }
      ]
    },
    hopMetadata: [
      { hopId: 'first', label: '第一跳', keyId: 'key-one',
        hostKeyPolicy: 'strict', position: 0 },
      { hopId: 'second', label: '第二跳', keyId: '',
        hostKeyPolicy: 'strict', position: 1 }
    ]
  };
}

export default function sshHostKeyTrustPolicyTest(): void {
  describe('SshHostKeyTrustPolicy', (): void => {
    it('binds_a_strict_target_pin_to_the_canonical_ipv6_endpoint', 0, (): void => {
      const value: RemoteHost = host();
      const plan = resolveSshProxyRuntimePlan(value, directProfile(value));
      const binding = sshHostKeyRouteBinding(value, plan);
      expect(binding.ok).assertTrue();
      expect(binding.identity.indexOf('endpoint-v2') >= 0).assertTrue();
      value.sshHostKeyTrustMode = 1;
      value.sshHostKeyRawBase64 = 'AAAAC3NzaC1lZDI1NTE5AAAA';
      value.sshHostKeyFingerprintSha256 = 'SHA256:target';
      value.sshHostKeyRouteIdentity = binding.identity;
      expect(sshHostKeyTrustIsCurrent(value, plan)).assertTrue();
      expect(value.runtimeClone().sshHostKeyRouteIdentity).assertEqual(binding.identity);
    });

    it('invalidates_legacy_trust_and_every_target_scope_or_port_change', 0, (): void => {
      const first: RemoteHost = host('fe80::10%wlan0');
      const firstPlan = resolveSshProxyRuntimePlan(first, directProfile(first));
      const firstBinding = sshHostKeyRouteBinding(first, firstPlan);
      first.sshHostKeyTrustMode = 1;
      first.sshHostKeyRawBase64 = 'raw';
      first.sshHostKeyFingerprintSha256 = 'SHA256:first';
      expect(sshHostKeyTrustIsCurrent(first, firstPlan)).assertFalse();
      first.sshHostKeyRouteIdentity = firstBinding.identity;
      expect(sshHostKeyTrustIsCurrent(first, firstPlan)).assertTrue();

      const moved: RemoteHost = host('fe80::10%eth0');
      moved.port = 2222;
      const movedBinding = sshHostKeyRouteBinding(
        moved, resolveSshProxyRuntimePlan(moved, directProfile(moved)));
      expect(movedBinding.ok).assertTrue();
      expect(movedBinding.identity === firstBinding.identity).assertFalse();
    });

    it('separates_direct_http_and_ordered_jump_routes_without_secrets', 0, (): void => {
      const value: RemoteHost = host('target.example');
      const direct = sshHostKeyRouteBinding(
        value, resolveSshProxyRuntimePlan(value, directProfile(value)));
      const httpProfile: SshProxyProfileV1 = {
        schemaVersion: 1, hostId: value.id,
        route: {
          schemaVersion: 1, type: 'http_connect', endpointHost: value.host,
          endpointPort: value.port, hops: [], connectTimeoutMs: 10000
        },
        proxyHost: '2001:db8::50', proxyPort: 8080,
        proxyUsername: 'proxy-user', proxyAuthRequired: true
      };
      const http = sshHostKeyRouteBinding(
        value, resolveSshProxyRuntimePlan(value, httpProfile));
      const jump = sshHostKeyRouteBinding(
        value, resolveSshProxyRuntimePlan(value, jumpProfile(value)));
      expect(direct.ok && http.ok && jump.ok).assertTrue();
      expect(direct.identity === http.identity).assertFalse();
      expect(http.identity === jump.identity).assertFalse();
      expect(http.identity.indexOf('password')).assertEqual(-1);
      expect(jump.identity.indexOf('key-one')).assertEqual(-1);
    });

    it('changes_for_hop_order_but_not_timeout_or_rotated_hop_pins', 0, (): void => {
      const value: RemoteHost = host('target.example');
      const profile: SshProxyProfileV1 = jumpProfile(value);
      const first = sshHostKeyRouteBinding(
        value, resolveSshProxyRuntimePlan(value, profile));
      profile.route.connectTimeoutMs = 30000;
      profile.route.hops[0].connectTimeoutMs = 15000;
      profile.route.hops[0].expectedHostKeyFingerprintSha256 = 'SHA256:rotated';
      const tuned = sshHostKeyRouteBinding(
        value, resolveSshProxyRuntimePlan(value, profile));
      expect(tuned.identity).assertEqual(first.identity);

      const firstHop = profile.route.hops[0];
      profile.route.hops[0] = profile.route.hops[1];
      profile.route.hops[1] = firstHop;
      profile.hopMetadata = [
        { hopId: 'second', label: '第二跳', keyId: '',
          hostKeyPolicy: 'strict', position: 0 },
        { hopId: 'first', label: '第一跳', keyId: 'key-one',
          hostKeyPolicy: 'strict', position: 1 }
      ];
      const reordered = sshHostKeyRouteBinding(
        value, resolveSshProxyRuntimePlan(value, profile));
      expect(reordered.ok).assertTrue();
      expect(reordered.identity === first.identity).assertFalse();
      expect(sshHostKeyPinsForRoute(value,
        resolveSshProxyRuntimePlan(value, profile)).trusted).assertFalse();
    });
  });
}
