import { describe, it, expect } from '@ohos/hypium';
import { RemoteHost } from '../main/ets/model/RemoteHost';
import { SshProxyProfileV1 } from '../main/ets/services/SshProxyProfilePolicy';
import { resolveSshProxyRuntimePlan } from '../main/ets/services/SshProxyRuntimePolicy';
import { SshOperationRouteSecretService } from
  '../main/ets/services/SshOperationRouteSecretService';

function host(): RemoteHost {
  const value: RemoteHost = new RemoteHost();
  value.id = 'route-secret-host';
  value.protocol = 'ssh';
  value.host = '2001:db8::90';
  value.port = 22;
  value.username = 'target';
  return value;
}

export default function sshOperationRouteSecretServiceTest(): void {
  describe('SshOperationRouteSecretService', (): void => {
    it('allows_a_scoped_direct_route_without_credentials', 0, (): void => {
      const value: RemoteHost = host();
      value.host = 'fe80::90%wlan0';
      const result = SshOperationRouteSecretService.getInstance().resolve(
        value, resolveSshProxyRuntimePlan(value, null));
      expect(result.ok).assertTrue();
      expect(result.secrets.jumpHandoffs.length).assertEqual(0);
    });

    it('fails_closed_when_a_profile_proxy_password_is_not_in_memory', 0, (): void => {
      const value: RemoteHost = host();
      const profile: SshProxyProfileV1 = {
        schemaVersion: 1, hostId: value.id,
        route: { schemaVersion: 1, type: 'http_connect', endpointHost: value.host,
          endpointPort: value.port, hops: [], connectTimeoutMs: 10000 },
        proxyHost: '2001:db8::91', proxyPort: 8080,
        proxyUsername: 'proxy', proxyAuthRequired: true
      };
      const result = SshOperationRouteSecretService.getInstance().resolve(
        value, resolveSshProxyRuntimePlan(value, profile));
      expect(result.ok).assertFalse();
      expect(result.code).assertEqual('E-SSH-OPERATION-PROXY-PASSWORD');
    });

    it('uses_only_a_trusted_legacy_jump_password', 0, (): void => {
      const value: RemoteHost = host();
      value.sshProxyType = 'ssh_jump';
      value.proxyHost = 'fe80::92%wlan0';
      value.proxyPort = 22;
      value.proxyUsername = 'jump';
      value.sshProxyAuthMethod = 'password';
      value.sshProxyPassword = 'one-shot';
      value.sshJumpHostKeyFingerprintSha256 = 'SHA256:jump';
      const result = SshOperationRouteSecretService.getInstance().resolve(
        value, resolveSshProxyRuntimePlan(value, null));
      expect(result.ok).assertTrue();
      expect(result.secrets.jumpHandoffs[0].password).assertEqual('one-shot');
    });
  });
}
