import { describe, it, expect } from '@ohos/hypium';
import {
  SshJumpHop,
  SshRoute,
  SshRouteType
} from '../main/ets/types/rdpnapi';
import {
  SshLegacyRemoteHostInput,
  SshProxyProfileV1,
  SSH_PROXY_MAX_JUMP_HOPS,
  deserializeSshProxyProfile,
  mapLegacyRemoteHostToSshProxyProfile,
  serializeSshProxyProfile,
  validateSshProxyProfile,
  validateSshRoute
} from '../main/ets/services/SshProxyProfilePolicy';

function directRoute(): SshRoute {
  return {
    schemaVersion: 1,
    type: 'direct',
    endpointHost: 'target.example',
    endpointPort: 22,
    hops: [],
    connectTimeoutMs: 10000
  };
}

function jumpHop(index: number): SshJumpHop {
  return {
    host: 'jump-' + index.toString() + '.example',
    port: 22,
    username: 'jump-user',
    authMethod: 'publickey',
    expectedHostKeyFingerprintSha256: 'SHA256:jump-' + index.toString(),
    connectTimeoutMs: 10000
  };
}

function profile(hostId: string = 'host-a'): SshProxyProfileV1 {
  return {
    schemaVersion: 1,
    hostId,
    route: directRoute(),
    proxyUsername: 'proxy-user',
    updatedAtMs: 10
  };
}

export default function sshProxyProfilePolicyTest(): void {
  describe('SshProxyProfilePolicy', (): void => {
    it('accepts_v1_routes_and_rejects_legacy_gateway', 0, (): void => {
      const accepted = validateSshRoute(directRoute());
      expect(accepted.valid).assertTrue();
      expect(accepted.route.schemaVersion).assertEqual(1);

      const legacy: SshRoute = directRoute();
      legacy.type = 'legacy_gateway' as SshRouteType;
      expect(validateSshRoute(legacy).valid).assertFalse();
      expect(validateSshRoute(legacy).code).assertEqual('E-SSH-PROXY-LEGACY-GATEWAY');
    });

    it('allows_at_most_three_jump_hops_and_rejects_a_fourth', 0, (): void => {
      const route: SshRoute = directRoute();
      route.type = 'ssh_jump';
      for (let index: number = 1; index <= SSH_PROXY_MAX_JUMP_HOPS; index++) {
        route.hops.push(jumpHop(index));
      }
      expect(validateSshRoute(route).valid).assertTrue();
      route.hops.push(jumpHop(4));
      expect(validateSshRoute(route).valid).assertFalse();
      expect(validateSshRoute(route).code).assertEqual('E-SSH-PROXY-HOP-LIMIT');
    });

    it('rejects_hops_for_non_jump_routes_and_invalid_schema', 0, (): void => {
      const route: SshRoute = directRoute();
      route.hops.push(jumpHop(1));
      expect(validateSshRoute(route).code).assertEqual('E-SSH-PROXY-HOPS-NOT-ALLOWED');
      route.hops = [];
      route.schemaVersion = 2;
      expect(validateSshRoute(route).code).assertEqual('E-SSH-PROXY-ROUTE-SCHEMA');
    });

    it('maps_legacy_remote_host_fields_without_reading_or_copying_secrets', 0, (): void => {
      const legacy: SshLegacyRemoteHostInput = {
        id: 'host-a',
        host: 'target.example',
        port: 2222,
        username: 'target-user',
        authMethod: 'password',
        keyId: 'target-key-id',
        sshProxyType: 'ssh_jump',
        proxyHost: 'bastion.example',
        proxyPort: 2200,
        proxyUsername: 'jump-user',
        sshProxyAuthMethod: 'publickey',
        sshProxyKeyId: 'jump-key-id',
        sshJumpHostKeyFingerprintSha256: 'SHA256:bastion'
      };
      const legacyWithSecrets: Record<string, Object> = legacy as Record<string, Object>;
      legacyWithSecrets['sshProxyPassword'] = 'must-not-copy';
      legacyWithSecrets['sshProxyKeyPassphrase'] = 'must-not-copy';
      legacyWithSecrets['privateKeyPem'] = '-----BEGIN ' + 'PRIVATE KEY-----';
      const mapped: SshProxyProfileV1 | null =
        mapLegacyRemoteHostToSshProxyProfile(legacy as SshLegacyRemoteHostInput);
      expect(mapped !== null).assertTrue();
      expect(mapped?.hostId).assertEqual('host-a');
      expect(mapped?.route.type).assertEqual('ssh_jump');
      expect(mapped?.route.endpointHost).assertEqual('target.example');
      expect(mapped?.route.hops.length).assertEqual(1);
      expect(mapped?.route.hops[0].host).assertEqual('bastion.example');
      expect(mapped?.hopMetadata?.[0].keyId).assertEqual('jump-key-id');
      const serialized: string = JSON.stringify(mapped);
      expect(serialized.indexOf('must-not-copy')).assertEqual(-1);
      expect(serialized.indexOf('privateKeyPem')).assertEqual(-1);
    });

    it('persists_proxy_endpoints_and_rejects_embedded_frp_control_plane_routes', 0, (): void => {
      const http: SshProxyProfileV1 = profile('http-host');
      http.route.type = 'http_connect';
      http.proxyHost = 'proxy.example';
      http.proxyPort = 8080;
      http.proxyAuthRequired = true;
      expect(validateSshProxyProfile(http).valid).assertTrue();
      expect(validateSshProxyProfile(http).profile?.proxyPort).assertEqual(8080);
      const visitor: SshProxyProfileV1 = profile('visitor-host');
      visitor.route.type = 'frp_visitor';
      expect(validateSshProxyProfile(visitor).code).assertEqual('E-SSH-PROXY-FRP-CONTROL-PLANE');
    });

    it('keeps_interface_scope_in_the_local_connection_namespace_only', 0, (): void => {
      const direct: SshRoute = directRoute();
      direct.endpointHost = 'fe80::20%wlan0';
      expect(validateSshRoute(direct).valid).assertTrue();

      const http: SshRoute = directRoute();
      http.type = 'http_connect';
      http.endpointHost = 'fe80::20%wlan0';
      expect(validateSshRoute(http).valid).assertFalse();
      expect(validateSshRoute(http).code).assertEqual('E-SSH-PROXY-ENDPOINT-HOST');

      const jump: SshRoute = directRoute();
      jump.type = 'ssh_jump';
      jump.endpointHost = 'target.example';
      jump.hops = [jumpHop(1)];
      jump.hops[0].host = 'fe80::30%wlan0';
      expect(validateSshRoute(jump).valid).assertTrue();
      jump.endpointHost = 'fe80::20%wlan0';
      expect(validateSshRoute(jump).valid).assertFalse();
    });

    it('uses_only_canonical_profile_fields_and_denies_secret_fields', 0, (): void => {
      const valid: SshProxyProfileV1 = profile();
      expect(validateSshProxyProfile(valid).valid).assertTrue();
      const encoded: string | null = serializeSshProxyProfile(valid);
      expect(encoded !== null).assertTrue();
      expect((encoded as string).indexOf('password')).assertEqual(-1);
      expect(deserializeSshProxyProfile(encoded as string)?.hostId).assertEqual('host-a');

      const withSecret: Record<string, Object> = valid as Record<string, Object>;
      withSecret['password'] = 'secret';
      expect(serializeSshProxyProfile(withSecret as SshProxyProfileV1)).assertNull();
      const malformed: string = JSON.stringify({
        schemaVersion: 1,
        hostId: 'host-a',
        route: directRoute(),
        privateKeyPem: 'secret'
      });
      expect(deserializeSshProxyProfile(malformed)).assertNull();
      expect(deserializeSshProxyProfile(JSON.stringify({
        ...valid,
        schemaVersion: 2
      }))).assertNull();
    });
  });
}
