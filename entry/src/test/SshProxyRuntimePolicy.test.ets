import { describe, it, expect } from '@ohos/hypium';
import { RemoteHost } from '../main/ets/model/RemoteHost';
import { SshProxyProfileV1 } from '../main/ets/services/SshProxyProfilePolicy';
import {
  resolveSshProxyRuntimePlan,
  sshProxyRuntimeHasStrictJumpBindings,
  sshProxyRuntimeNeedsTerminalSecrets
} from '../main/ets/services/SshProxyRuntimePolicy';

function host(): RemoteHost {
  const value: RemoteHost = new RemoteHost();
  value.id = 'host-a';
  value.protocol = 'ssh';
  value.host = 'target.example';
  value.port = 22;
  value.username = 'target-user';
  return value;
}

export default function sshProxyRuntimePolicyTest(): void {
  describe('SshProxyRuntimePolicy', (): void => {
    it('prefers_a_matching_profile_and_never_copies_secrets', 0, (): void => {
      const profile: SshProxyProfileV1 = {
        schemaVersion: 1,
        hostId: 'host-a',
        route: {
          schemaVersion: 1, type: 'http_connect', endpointHost: 'target.example',
          endpointPort: 22, hops: [], connectTimeoutMs: 10000
        },
        proxyHost: 'proxy.example', proxyPort: 8080,
        proxyUsername: 'proxy-user', proxyAuthRequired: true
      };
      const plan = resolveSshProxyRuntimePlan(host(), profile);
      expect(plan.valid).assertTrue();
      expect(plan.source).assertEqual('profile');
      expect(plan.proxyHost).assertEqual('proxy.example');
      expect(sshProxyRuntimeNeedsTerminalSecrets(plan)).assertTrue();
      expect(JSON.stringify(plan).indexOf('password')).assertEqual(-1);
    });

    it('rejects_a_profile_after_target_endpoint_changes', 0, (): void => {
      const profile: SshProxyProfileV1 = {
        schemaVersion: 1,
        hostId: 'host-a',
        route: {
          schemaVersion: 1, type: 'direct', endpointHost: 'old.example',
          endpointPort: 22, hops: [], connectTimeoutMs: 10000
        }
      };
      const plan = resolveSshProxyRuntimePlan(host(), profile);
      expect(plan.valid).assertFalse();
      expect(plan.code).assertEqual('E-SSH-PROXY-RUNTIME-ENDPOINT');
    });

    it('requires_a_strict_binding_for_every_jump_hop', 0, (): void => {
      const profile: SshProxyProfileV1 = {
        schemaVersion: 1,
        hostId: 'host-a',
        route: {
          schemaVersion: 1, type: 'ssh_jump', endpointHost: 'target.example',
          endpointPort: 22, connectTimeoutMs: 10000,
          hops: [
            { host: 'jump-1', port: 22, username: 'one', authMethod: 'password',
              expectedHostKeyFingerprintSha256: 'SHA256:first', connectTimeoutMs: 10000 },
            { host: 'jump-2', port: 22, username: 'two', authMethod: 'kbd-interactive',
              connectTimeoutMs: 10000 }
          ]
        },
        hopMetadata: [
          { hopId: 'one', label: '第一跳', keyId: '', hostKeyPolicy: 'strict', position: 0 },
          { hopId: 'two', label: '第二跳', keyId: '', hostKeyPolicy: 'strict', position: 1 }
        ]
      };
      const plan = resolveSshProxyRuntimePlan(host(), profile);
      expect(plan.valid).assertTrue();
      expect(sshProxyRuntimeHasStrictJumpBindings(plan)).assertFalse();
      profile.route.hops[1].expectedHostKeyFingerprintSha256 = 'SHA256:second';
      expect(sshProxyRuntimeHasStrictJumpBindings(
        resolveSshProxyRuntimePlan(host(), profile))).assertTrue();
    });

    it('maps_legacy_flat_routes_only_when_no_profile_exists', 0, (): void => {
      const value: RemoteHost = host();
      value.sshProxyType = 'frp_tcp';
      value.proxyHost = 'frp.example';
      value.proxyPort = 60022;
      const plan = resolveSshProxyRuntimePlan(value, null);
      expect(plan.valid).assertTrue();
      expect(plan.source).assertEqual('legacy');
      expect(plan.route.type).assertEqual('frp_tcp');
      expect(plan.proxyPort).assertEqual(60022);
    });
  });
}
