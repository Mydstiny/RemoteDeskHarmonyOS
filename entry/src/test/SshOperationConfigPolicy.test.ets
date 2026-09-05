import { describe, it, expect } from '@ohos/hypium';
import { RemoteHost } from '../main/ets/model/RemoteHost';
import {
  buildDirectSshHostKeyProbeConfig,
  buildSshOperationSessionConfig,
  classifySshJumpHostKeyProbeTrust,
  SshOperationRouteSecrets,
  SshOperationTargetAuth
} from '../main/ets/services/SshOperationConfigPolicy';
import { SshProxyProfileV1 } from '../main/ets/services/SshProxyProfilePolicy';
import { resolveSshProxyRuntimePlan } from '../main/ets/services/SshProxyRuntimePolicy';
import { sshHostKeyRouteBinding } from '../main/ets/services/SshHostKeyTrustPolicy';

function host(): RemoteHost {
  const value: RemoteHost = new RemoteHost();
  value.id = 'ssh-operation-host';
  value.protocol = 'ssh';
  value.host = '2001:db8::40';
  value.port = 22;
  value.username = 'target';
  return value;
}

function emptyAuth(): SshOperationTargetAuth {
  return {
    authMethod: 'password', password: '', privateKeyPem: '',
    privateKeyPassphrase: '', keyboardInteractiveResponses: []
  };
}

function emptyRouteSecrets(): SshOperationRouteSecrets {
  return { proxyPassword: '', jumpHandoffs: [] };
}

function trustTarget(value: RemoteHost, profile: SshProxyProfileV1): void {
  const plan = resolveSshProxyRuntimePlan(value, profile);
  const binding = sshHostKeyRouteBinding(value, plan);
  value.sshHostKeyTrustMode = 1;
  value.sshHostKeyRawBase64 = 'AAAATARGET';
  value.sshHostKeyFingerprintSha256 = 'SHA256:target';
  value.sshHostKeyRouteIdentity = binding.identity;
}

export default function sshOperationConfigPolicyTest(): void {
  describe('SshOperationConfigPolicy', (): void => {
    it('keeps_a_scoped_ipv6_direct_probe_on_the_canonical_route', 0, (): void => {
      const value: RemoteHost = host();
      value.host = 'fe80::40%wlan0';
      const profile: SshProxyProfileV1 = {
        schemaVersion: 1, hostId: value.id,
        route: { schemaVersion: 1, type: 'direct', endpointHost: value.host,
          endpointPort: 22, hops: [], connectTimeoutMs: 7000 }
      };
      const result = buildSshOperationSessionConfig(value,
        resolveSshProxyRuntimePlan(value, profile), 'probe', emptyAuth(), emptyRouteSecrets());
      expect(result.ok).assertTrue();
      expect(result.config?.host).assertEqual('fe80::40%wlan0');
      expect(result.config?.sshRoute?.endpointHost).assertEqual('fe80::40%wlan0');
      expect(result.config?.expectedHostKeyRawBase64).assertEqual('');
    });

    it('requires_http_proxy_credentials_without_changing_the_target_route', 0, (): void => {
      const value: RemoteHost = host();
      const profile: SshProxyProfileV1 = {
        schemaVersion: 1, hostId: value.id,
        route: { schemaVersion: 1, type: 'http_connect', endpointHost: value.host,
          endpointPort: 22, hops: [], connectTimeoutMs: 9000 },
        proxyHost: '2001:db8::50', proxyPort: 8080,
        proxyUsername: 'proxy-user', proxyAuthRequired: true
      };
      const plan = resolveSshProxyRuntimePlan(value, profile);
      expect(buildSshOperationSessionConfig(value, plan, 'probe', emptyAuth(),
        emptyRouteSecrets()).code).assertEqual('E-SSH-OPERATION-PROXY-PASSWORD');
      const secrets: SshOperationRouteSecrets = { proxyPassword: 'one-shot', jumpHandoffs: [] };
      const result = buildSshOperationSessionConfig(value, plan, 'probe', emptyAuth(), secrets);
      expect(result.ok).assertTrue();
      expect(result.config?.sshProxyHost).assertEqual('2001:db8::50');
      expect(result.config?.sshProxyPassword).assertEqual('one-shot');
      expect(result.config?.host).assertEqual(value.host);
    });

    it('preserves_three_strict_jump_hops_and_one_shot_handoffs', 0, (): void => {
      const value: RemoteHost = host();
      const profile: SshProxyProfileV1 = {
        schemaVersion: 1, hostId: value.id,
        route: { schemaVersion: 1, type: 'ssh_jump', endpointHost: value.host,
          endpointPort: 22, connectTimeoutMs: 10000, hops: [
            { host: 'fe80::1%wlan0', port: 22, username: 'one', authMethod: 'password',
              expectedHostKeyFingerprintSha256: 'SHA256:one', connectTimeoutMs: 8000 },
            { host: '2001:db8::2', port: 22, username: 'two', authMethod: 'publickey',
              expectedHostKeyFingerprintSha256: 'SHA256:two', connectTimeoutMs: 8000 },
            { host: 'jump-three.example', port: 2222, username: 'three',
              authMethod: 'kbd-interactive', expectedHostKeyFingerprintSha256: 'SHA256:three',
              connectTimeoutMs: 8000 }
          ] },
        hopMetadata: [
          { hopId: 'one', label: 'one', keyId: '', hostKeyPolicy: 'strict', position: 0 },
          { hopId: 'two', label: 'two', keyId: 'key-two', hostKeyPolicy: 'strict', position: 1 },
          { hopId: 'three', label: 'three', keyId: '', hostKeyPolicy: 'strict', position: 2 }
        ]
      };
      const secrets: SshOperationRouteSecrets = { proxyPassword: '', jumpHandoffs: [
        { password: 'hop-one' },
        { privateKeyPem: 'PRIVATE TWO' },
        { keyboardInteractiveResponses: ['response-three'] }
      ] };
      const result = buildSshOperationSessionConfig(value,
        resolveSshProxyRuntimePlan(value, profile), 'probe', emptyAuth(), secrets);
      expect(result.ok).assertTrue();
      expect(result.config?.sshRoute?.hops.length).assertEqual(3);
      expect(result.config?.sshJumpHopHandoffs?.length).assertEqual(3);
      expect(result.config?.sshJumpHopHandoffs?.[1].privateKeyPem).assertEqual('PRIVATE TWO');
    });

    it('refuses_key_auth_until_target_trust_matches_the_same_route', 0, (): void => {
      const value: RemoteHost = host();
      const profile: SshProxyProfileV1 = {
        schemaVersion: 1, hostId: value.id,
        route: { schemaVersion: 1, type: 'direct', endpointHost: value.host,
          endpointPort: 22, hops: [], connectTimeoutMs: 10000 }
      };
      const auth: SshOperationTargetAuth = {
        authMethod: 'publickey', password: '', privateKeyPem: 'PRIVATE TARGET',
        privateKeyPassphrase: '', keyboardInteractiveResponses: []
      };
      const plan = resolveSshProxyRuntimePlan(value, profile);
      expect(buildSshOperationSessionConfig(value, plan, 'key_auth', auth,
        emptyRouteSecrets()).code).assertEqual('E-SSH-OPERATION-TARGET-HOSTKEY');
      trustTarget(value, profile);
      const result = buildSshOperationSessionConfig(value, plan, 'key_auth', auth,
        emptyRouteSecrets());
      expect(result.ok).assertTrue();
      expect(result.config?.expectedHostKeyFingerprintSha256).assertEqual('SHA256:target');
      expect(result.config?.sshHostKeyPromptEnabled).assertFalse();
    });

    it('builds_a_direct_bootstrap_probe_without_bracket_or_scope_rewrites', 0, (): void => {
      const config = buildDirectSshHostKeyProbeConfig('fe80::7%wlan0', 2222);
      expect(config.host).assertEqual('fe80::7%wlan0');
      expect(config.sshRoute?.endpointHost).assertEqual('fe80::7%wlan0');
      expect(config.sshRoute?.endpointPort).assertEqual(2222);
    });

    it('requires_jump_trust_before_any_route_credentials_are_sent', 0, (): void => {
      const value: RemoteHost = host();
      expect(classifySshJumpHostKeyProbeTrust(value, 'AAAAFIRST')).assertEqual('trust_first');
      value.sshJumpHostKeyTrustMode = 1;
      value.sshJumpHostKeyRawBase64 = 'AAAAFIRST';
      expect(classifySshJumpHostKeyProbeTrust(value, 'AAAAFIRST')).assertEqual('trusted');
      expect(classifySshJumpHostKeyProbeTrust(value, 'AAAACHANGED')).assertEqual('changed');
    });
  });
}
