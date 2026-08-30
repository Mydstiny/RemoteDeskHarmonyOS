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

    it('classifies_keyboard_interactive_jump_auth_as_transient', 0, (): void => {
      const profile: SshProxyProfileV1 = {
        schemaVersion: 1,
        hostId: 'host-a',
        route: {
          schemaVersion: 1, type: 'ssh_jump', endpointHost: 'target.example',
          endpointPort: 22, connectTimeoutMs: 10000,
          hops: [{
            host: 'jump.example', port: 22, username: 'jump',
            authMethod: 'kbd-interactive',
            expectedHostKeyFingerprintSha256: 'SHA256:jump', connectTimeoutMs: 10000
          }]
        },
        hopMetadata: [{
          hopId: 'jump', label: '跳板', keyId: '', hostKeyPolicy: 'strict', position: 0
        }]
      };
      expect(sshProxyRuntimeNeedsTerminalSecrets(
        resolveSshProxyRuntimePlan(host(), profile))).assertTrue();
    });

    it('preserves_a_three_hop_profile_and_its_per_hop_key_references', 0,
      (): void => {
        const profile: SshProxyProfileV1 = {
          schemaVersion: 1,
          hostId: 'host-a',
          route: {
            schemaVersion: 1, type: 'ssh_jump', endpointHost: 'target.example',
            endpointPort: 22, connectTimeoutMs: 12000,
            hops: [
              { host: '2001:db8::10', port: 22, username: 'one',
                authMethod: 'publickey',
                expectedHostKeyFingerprintSha256: 'SHA256:first',
                connectTimeoutMs: 9000 },
              { host: 'jump-2.example', port: 2222, username: 'two',
                authMethod: 'password',
                expectedHostKeyFingerprintSha256: 'SHA256:second',
                connectTimeoutMs: 8000 },
              { host: '2001:db8::30', port: 2200, username: 'three',
                authMethod: 'kbd-interactive',
                expectedHostKeyFingerprintSha256: 'SHA256:third',
                connectTimeoutMs: 7000 }
            ]
          },
          hopMetadata: [
            { hopId: 'one', label: '第一跳', keyId: 'key-one',
              hostKeyPolicy: 'strict', position: 0 },
            { hopId: 'two', label: '第二跳', keyId: '',
              hostKeyPolicy: 'strict', position: 1 },
            { hopId: 'three', label: '第三跳', keyId: '',
              hostKeyPolicy: 'strict', position: 2 }
          ]
        };
        const plan = resolveSshProxyRuntimePlan(host(), profile);
        expect(plan.valid).assertTrue();
        expect(plan.route.hops.length).assertEqual(3);
        expect(plan.route.hops[0].host).assertEqual('2001:db8::10');
        expect(plan.route.hops[1].port).assertEqual(2222);
        expect(plan.route.hops[2].authMethod).assertEqual('kbd-interactive');
        expect(plan.hopKeyIds.join(',')).assertEqual('key-one,,');
        expect(sshProxyRuntimeHasStrictJumpBindings(plan)).assertTrue();

        profile.route.hops[0].host = 'mutated-after-resolve.example';
        if (profile.hopMetadata !== undefined) {
          profile.hopMetadata[0].keyId = 'mutated-key';
        }
        expect(plan.route.hops[0].host).assertEqual('2001:db8::10');
        expect(plan.hopKeyIds[0]).assertEqual('key-one');
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
