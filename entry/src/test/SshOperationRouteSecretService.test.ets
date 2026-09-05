import { describe, it, expect } from '@ohos/hypium';
import { RemoteHost } from '../main/ets/model/RemoteHost';
import { SshProxyProfileV1 } from '../main/ets/services/SshProxyProfilePolicy';
import { resolveSshProxyRuntimePlan } from '../main/ets/services/SshProxyRuntimePolicy';
import {
  SSH_OPERATION_ROUTE_SECRET_TTL_MS,
  sshOperationRouteHasNonReplayableAuthentication,
  sshOperationRouteSecretConsumeAllowed,
  sshOperationRouteSecretPublishAllowed,
  sshOperationRouteSecretsMatchPlan,
  SshOperationRouteSecretBinding,
  SshOperationRouteSecretBroker,
  SshOperationRouteSecretClock,
  SshOperationRouteSecretScope,
  SshOperationRouteSecretService,
  SshOperationRouteSecretTimer
} from
  '../main/ets/services/SshOperationRouteSecretService';

class FakeRouteSecretClock implements SshOperationRouteSecretClock {
  value: number = 1000;
  now(): number { return this.value; }
}

class FakeRouteSecretTimer implements SshOperationRouteSecretTimer {
  callback: (() => void) | null = null;
  currentId: number = -1;
  nextId: number = 0;
  lastDelayMs: number = -1;
  cancelCount: number = 0;

  schedule(callback: () => void, delayMs: number): number {
    this.nextId++;
    this.currentId = this.nextId;
    this.callback = callback;
    this.lastDelayMs = delayMs;
    return this.currentId;
  }

  cancel(timerId: number): void {
    if (timerId !== this.currentId) { return; }
    this.callback = null;
    this.currentId = -1;
    this.cancelCount++;
  }

  fire(): void {
    const pending: (() => void) | null = this.callback;
    this.callback = null;
    this.currentId = -1;
    if (pending !== null) { pending(); }
  }
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

function authenticatedSocksProfile(value: RemoteHost): SshProxyProfileV1 {
  return {
    schemaVersion: 1, hostId: value.id,
    route: { schemaVersion: 1, type: 'socks5', endpointHost: value.host,
      endpointPort: value.port, hops: [], connectTimeoutMs: 10000 },
    proxyHost: 'fe80::91%wlan0', proxyPort: 1080,
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

function mixedJumpProfile(value: RemoteHost, includeKbi: boolean): SshProxyProfileV1 {
  return {
    schemaVersion: 1, hostId: value.id,
    route: {
      schemaVersion: 1, type: 'ssh_jump', endpointHost: value.host,
      endpointPort: value.port, connectTimeoutMs: 10000,
      hops: [
        {
          host: 'fe80::92%wlan0', port: 22, username: 'one',
          authMethod: 'password', connectTimeoutMs: 10000,
          expectedHostKeyFingerprintSha256: 'SHA256:one'
        },
        {
          host: '2001:db8::93', port: 2222, username: 'two',
          authMethod: 'publickey', connectTimeoutMs: 9000,
          expectedHostKeyFingerprintSha256: 'SHA256:two'
        },
        {
          host: 'jump-three.example', port: 2200, username: 'three',
          authMethod: includeKbi ? 'kbd-interactive' : 'password', connectTimeoutMs: 8000,
          expectedHostKeyFingerprintSha256: 'SHA256:three'
        }
      ]
    },
    hopMetadata: [
      { hopId: 'one', label: 'one', keyId: '', hostKeyPolicy: 'strict', position: 0 },
      { hopId: 'two', label: 'two', keyId: 'key-two', hostKeyPolicy: 'strict', position: 1 },
      { hopId: 'three', label: 'three', keyId: '', hostKeyPolicy: 'strict', position: 2 }
    ]
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

    it('actively_scrubs_at_the_exact_ttl_and_cancels_the_timer_on_clear', 0, (): void => {
      const clock: FakeRouteSecretClock = new FakeRouteSecretClock();
      const timer: FakeRouteSecretTimer = new FakeRouteSecretTimer();
      const broker: SshOperationRouteSecretBroker =
        new SshOperationRouteSecretBroker(clock, timer);
      expect(broker.put(binding(), {
        proxyPassword: 'expires', jumpHandoffs: []
      })).assertTrue();
      expect(broker.pendingCountForTest()).assertEqual(1);
      expect(timer.lastDelayMs).assertEqual(SSH_OPERATION_ROUTE_SECRET_TTL_MS);
      clock.value += SSH_OPERATION_ROUTE_SECRET_TTL_MS;
      timer.fire();
      expect(broker.pendingCountForTest()).assertEqual(0);
      expect(broker.take(binding())).assertNull();
      expect(broker.put(binding(), {
        proxyPassword: 'clear-me', jumpHandoffs: []
      })).assertTrue();
      broker.clearAll();
      expect(timer.cancelCount).assertEqual(1);
      expect(broker.pendingCountForTest()).assertEqual(0);
      expect(broker.take(binding())).assertNull();
    });

    it('clones_inputs_and_never_brokers_private_keys_or_kbi_answers', 0, (): void => {
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
      expect(taken?.jumpHandoffs[0].keyboardInteractiveResponses?.length).assertEqual(0);
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

    it('refuses_to_stage_or_replay_keyboard_interactive_answers', 0, (): void => {
      const service: SshOperationRouteSecretService =
        SshOperationRouteSecretService.getInstance();
      service.clearAll();
      const value: RemoteHost = host();
      const plan = resolveSshProxyRuntimePlan(value, keyboardInteractiveJumpProfile(value));
      expect(sshOperationRouteHasNonReplayableAuthentication(plan)).assertTrue();
      expect(service.stage(value, plan, scope(), {
        proxyPassword: '',
        jumpHandoffs: [{
          password: '', privateKeyPem: '', privateKeyPassphrase: '',
          keyboardInteractiveResponses: ['password', 'otp']
        }]
      })).assertFalse();
      const result = service.resolve(value, plan, '', scope());
      expect(result.ok).assertFalse();
      expect(result.code).assertEqual('E-SSH-OPERATION-HOP-INTERACTIVE-NONREPLAYABLE');
    });

    it('validates_http_socks_and_three_hop_replayable_secret_shapes', 0, (): void => {
      const value: RemoteHost = host();
      const httpPlan = resolveSshProxyRuntimePlan(value, authenticatedHttpProfile(value));
      const socksPlan = resolveSshProxyRuntimePlan(value, authenticatedSocksProfile(value));
      expect(sshOperationRouteSecretsMatchPlan(httpPlan, {
        proxyPassword: 'http-password', jumpHandoffs: []
      })).assertTrue();
      expect(sshOperationRouteSecretsMatchPlan(socksPlan, {
        proxyPassword: 'socks-password', jumpHandoffs: []
      })).assertTrue();
      expect(sshOperationRouteSecretsMatchPlan(socksPlan, {
        proxyPassword: '', jumpHandoffs: []
      })).assertFalse();

      const replayablePlan = resolveSshProxyRuntimePlan(value, mixedJumpProfile(value, false));
      expect(sshOperationRouteSecretsMatchPlan(replayablePlan, {
        proxyPassword: '',
        jumpHandoffs: [
          { password: 'one', privateKeyPem: '', privateKeyPassphrase: '',
            keyboardInteractiveResponses: [] },
          { password: '', privateKeyPem: '', privateKeyPassphrase: 'two',
            keyboardInteractiveResponses: [] },
          { password: 'three', privateKeyPem: '', privateKeyPassphrase: '',
            keyboardInteractiveResponses: [] }
        ]
      })).assertTrue();
      const nonReplayablePlan = resolveSshProxyRuntimePlan(value, mixedJumpProfile(value, true));
      expect(sshOperationRouteSecretsMatchPlan(nonReplayablePlan, {
        proxyPassword: '',
        jumpHandoffs: [
          { password: 'one' }, { privateKeyPassphrase: 'two' },
          { keyboardInteractiveResponses: ['password', 'otp'] }
        ]
      })).assertFalse();
    });

    it('publishes_only_after_exact_authenticated_owner_route_and_session_match', 0,
      (): void => {
        const exact = {
          authenticated: true,
          expectedHostId: 'route-secret-host', actualHostId: 'route-secret-host',
          expectedRouteIdentity: 'route-fe80-wlan0', actualRouteIdentity: 'route-fe80-wlan0',
          expectedSessionId: 41, actualSessionId: 41,
          expectedGeneration: 9, actualGeneration: 9,
          hostOwnerScopeId: 'owner-a', currentOwnerScopeId: 'owner-a'
        };
        expect(sshOperationRouteSecretPublishAllowed(exact)).assertTrue();
        expect(sshOperationRouteSecretPublishAllowed({ ...exact, authenticated: false }))
          .assertFalse();
        expect(sshOperationRouteSecretPublishAllowed({ ...exact, actualHostId: 'other-host' }))
          .assertFalse();
        expect(sshOperationRouteSecretPublishAllowed({
          ...exact, actualRouteIdentity: 'route-fe80-eth0'
        })).assertFalse();
        expect(sshOperationRouteSecretPublishAllowed({ ...exact, actualSessionId: 42 }))
          .assertFalse();
        expect(sshOperationRouteSecretPublishAllowed({ ...exact, actualGeneration: 10 }))
          .assertFalse();
        expect(sshOperationRouteSecretPublishAllowed({
          ...exact, currentOwnerScopeId: 'owner-b'
        })).assertFalse();
      });

    it('allows_only_foreground_explicit_consumption_and_clear_all_invalidates_singleton', 0,
      (): void => {
        expect(sshOperationRouteSecretConsumeAllowed({
          explicitUserAction: true, appInBackground: false
        })).assertTrue();
        expect(sshOperationRouteSecretConsumeAllowed({
          explicitUserAction: false, appInBackground: false
        })).assertFalse();
        expect(sshOperationRouteSecretConsumeAllowed({
          explicitUserAction: true, appInBackground: true
        })).assertFalse();

        const service: SshOperationRouteSecretService =
          SshOperationRouteSecretService.getInstance();
        service.clearAll();
        const value: RemoteHost = host();
        const plan = resolveSshProxyRuntimePlan(value, authenticatedHttpProfile(value));
        expect(service.stage(value, plan, scope(), {
          proxyPassword: 'clear-on-background-or-account-change', jumpHandoffs: []
        })).assertTrue();
        service.clearAll();
        expect(service.resolve(value, plan, '', scope()).ok).assertFalse();
      });

    it('keeps_scoped_ipv6_route_changes_from_consuming_the_original_handoff', 0,
      (): void => {
        const service: SshOperationRouteSecretService =
          SshOperationRouteSecretService.getInstance();
        service.clearAll();
        const value: RemoteHost = host();
        value.host = 'fe80::90%wlan0';
        const originalPlan = resolveSshProxyRuntimePlan(value, authenticatedHttpProfile(value));
        expect(service.stage(value, originalPlan, scope(), {
          proxyPassword: 'scoped-route', jumpHandoffs: []
        })).assertTrue();

        const changed: RemoteHost = value.runtimeClone();
        changed.host = 'fe80::90%eth0';
        const changedPlan = resolveSshProxyRuntimePlan(changed, authenticatedHttpProfile(changed));
        expect(service.resolve(changed, changedPlan, '', scope()).ok).assertFalse();
        const original = service.resolve(value, originalPlan, '', scope());
        expect(original.ok).assertTrue();
        expect(original.secrets.proxyPassword).assertEqual('scoped-route');
      });
  });
}
