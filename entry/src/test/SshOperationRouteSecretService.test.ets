import { describe, it, expect } from '@ohos/hypium';
import { RemoteHost } from '../main/ets/model/RemoteHost';
import { SshProxyProfileV1 } from '../main/ets/services/SshProxyProfilePolicy';
import { resolveSshProxyRuntimePlan } from '../main/ets/services/SshProxyRuntimePolicy';
import {
  SSH_OPERATION_ROUTE_SECRET_TTL_MS,
  SshOperationRouteSecretBinding,
  SshOperationRouteSecretBroker,
  SshOperationRouteSecretClock,
  SshOperationRouteSecretScope,
  SshOperationRouteSecretService
} from
  '../main/ets/services/SshOperationRouteSecretService';

class FakeRouteSecretClock implements SshOperationRouteSecretClock {
  value: number = 1000;
  now(): number { return this.value; }
}

function scope(ownerScopeId: string = 'owner-a', storeIdentity: string = 'store-a.db',
  accountGeneration: number = 7): SshOperationRouteSecretScope {
  return { ownerScopeId, storeIdentity, accountGeneration };
}

function binding(): SshOperationRouteSecretBinding {
  return {
    ownerScopeId: 'owner-a', storeIdentity: 'store-a.db', accountGeneration: 7,
    hostId: 'route-secret-host', routeIdentity: 'ssh-route-a'
  };
}

function host(): RemoteHost {
  const value: RemoteHost = new RemoteHost();
  value.id = 'route-secret-host';
  value.protocol = 'ssh';
  value.host = '2001:db8::90';
  value.port = 22;
  value.username = 'target';
  value.userId = 'owner-a';
  return value;
}

function authenticatedHttpProfile(value: RemoteHost): SshProxyProfileV1 {
  return {
    schemaVersion: 1, hostId: value.id,
    route: { schemaVersion: 1, type: 'http_connect', endpointHost: value.host,
      endpointPort: value.port, hops: [], connectTimeoutMs: 10000 },
    proxyHost: '2001:db8::91', proxyPort: 8080,
    proxyUsername: 'proxy', proxyAuthRequired: true
  };
}

function keyboardInteractiveJumpProfile(value: RemoteHost): SshProxyProfileV1 {
  return {
    schemaVersion: 1, hostId: value.id,
    route: {
      schemaVersion: 1, type: 'ssh_jump', endpointHost: value.host,
      endpointPort: value.port, connectTimeoutMs: 10000,
      hops: [{
        host: '2001:db8::92', port: 22, username: 'jump',
        authMethod: 'kbd-interactive', connectTimeoutMs: 10000,
        expectedHostKeyFingerprintSha256: 'SHA256:jump'
      }]
    },
    hopMetadata: [{
      hopId: 'hop-1', label: 'jump', keyId: '', hostKeyPolicy: 'strict', position: 0
    }]
  };
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
      const profile: SshProxyProfileV1 = authenticatedHttpProfile(value);
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

    it('binds_a_broker_entry_to_owner_store_generation_host_and_route', 0, (): void => {
      const clock: FakeRouteSecretClock = new FakeRouteSecretClock();
      const broker: SshOperationRouteSecretBroker = new SshOperationRouteSecretBroker(clock);
      const exact: SshOperationRouteSecretBinding = binding();
      expect(broker.put(exact, {
        proxyPassword: 'proxy-one-shot', jumpHandoffs: []
      })).assertTrue();
      expect(broker.take({ ...exact, ownerScopeId: 'owner-b' })).assertNull();
      expect(broker.take({ ...exact, storeIdentity: 'store-b.db' })).assertNull();
      expect(broker.take({ ...exact, accountGeneration: 8 })).assertNull();
      expect(broker.take({ ...exact, routeIdentity: 'ssh-route-b' })).assertNull();
      expect(broker.take(exact)?.proxyPassword).assertEqual('proxy-one-shot');
      expect(broker.take(exact)).assertNull();
    });

    it('expires_and_clears_route_secrets_without_replay', 0, (): void => {
      const clock: FakeRouteSecretClock = new FakeRouteSecretClock();
      const broker: SshOperationRouteSecretBroker = new SshOperationRouteSecretBroker(clock);
      expect(broker.put(binding(), {
        proxyPassword: 'expires', jumpHandoffs: []
      })).assertTrue();
      clock.value += SSH_OPERATION_ROUTE_SECRET_TTL_MS + 1;
      expect(broker.take(binding())).assertNull();
      expect(broker.put(binding(), {
        proxyPassword: 'clear-me', jumpHandoffs: []
      })).assertTrue();
      broker.clearAll();
      expect(broker.take(binding())).assertNull();
    });

    it('clones_inputs_and_never_brokers_private_key_material', 0, (): void => {
      const broker: SshOperationRouteSecretBroker = new SshOperationRouteSecretBroker();
      const responses: string[] = ['otp'];
      const secrets = {
        proxyPassword: '',
        jumpHandoffs: [{
          password: '', privateKeyPem: 'PRIVATE', privateKeyPassphrase: 'key-pass',
          keyboardInteractiveResponses: responses
        }]
      };
      expect(broker.put(binding(), secrets)).assertTrue();
      secrets.jumpHandoffs[0].privateKeyPassphrase = 'mutated';
      responses[0] = 'mutated';
      const taken = broker.take(binding());
      expect(taken?.jumpHandoffs[0].privateKeyPem).assertEqual('');
      expect(taken?.jumpHandoffs[0].privateKeyPassphrase).assertEqual('key-pass');
      expect(taken?.jumpHandoffs[0].keyboardInteractiveResponses?.[0]).assertEqual('otp');
    });

    it('consumes_a_profile_proxy_password_once_in_the_exact_account_scope', 0, (): void => {
      const service: SshOperationRouteSecretService =
        SshOperationRouteSecretService.getInstance();
      service.clearAll();
      const value: RemoteHost = host();
      const plan = resolveSshProxyRuntimePlan(value, authenticatedHttpProfile(value));
      expect(service.stage(value, plan, scope(), {
        proxyPassword: 'profile-proxy', jumpHandoffs: []
      })).assertTrue();
      expect(service.resolve(value, plan, '', scope('owner-a', 'other.db', 7)).ok)
        .assertFalse();
      const first = service.resolve(value, plan, '', scope());
      expect(first.ok).assertTrue();
      expect(first.secrets.proxyPassword).assertEqual('profile-proxy');
      expect(service.resolve(value, plan, '', scope()).ok).assertFalse();
    });

    it('replays_captured_profile_jump_keyboard_responses_once', 0, (): void => {
      const service: SshOperationRouteSecretService =
        SshOperationRouteSecretService.getInstance();
      service.clearAll();
      const value: RemoteHost = host();
      const plan = resolveSshProxyRuntimePlan(value, keyboardInteractiveJumpProfile(value));
      expect(service.stage(value, plan, scope(), {
        proxyPassword: '',
        jumpHandoffs: [{
          password: '', privateKeyPem: '', privateKeyPassphrase: '',
          keyboardInteractiveResponses: ['password', 'otp']
        }]
      })).assertTrue();
      const result = service.resolve(value, plan, '', scope());
      expect(result.ok).assertTrue();
      expect(result.secrets.jumpHandoffs[0].keyboardInteractiveResponses?.length)
        .assertEqual(2);
      expect(result.secrets.jumpHandoffs[0].keyboardInteractiveResponses?.[1])
        .assertEqual('otp');
      expect(service.resolve(value, plan, '', scope()).ok).assertFalse();
    });
  });
}
