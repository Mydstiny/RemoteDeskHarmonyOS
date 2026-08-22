import { describe, it, expect } from '@ohos/hypium';
import {
  MoonlightAppCacheEntry,
  cloneMoonlightAppCacheEntry
} from '../main/ets/model/MoonlightAppCache';
import {
  AccountSessionLease,
  accountSessionLeaseEquals,
  cloneAccountSessionLease
} from '../main/ets/services/AccountScopePolicy';
import {
  MoonlightAppCachePort,
  MoonlightAppCacheService
} from '../main/ets/services/MoonlightAppCacheService';
import {
  MoonlightAccountLeasePort,
  MoonlightBridgeCapabilities,
  MoonlightHostContext,
  MoonlightHostService,
  MoonlightHostServiceResult,
  MoonlightNativeEvent,
  MoonlightNativePort,
  MoonlightNativeRequest,
  MoonlightNativeRequestKey,
  MoonlightNativeResult
} from '../main/ets/services/MoonlightHostService';
import { moonlightOwnerScopeFingerprint } from '../main/ets/services/MoonlightRuntimeSupport';
import {
  MoonlightRuntimeOwnerRegistry
} from '../main/ets/services/MoonlightRuntimeOwnerRegistry';

const OWNER_A_FP: string = moonlightOwnerScopeFingerprint('owner-a');

function copyBytes(value: Uint8Array): number[] {
  const result: number[] = [];
  for (let index: number = 0; index < value.length; index++) {
    result.push(value[index]);
  }
  return result;
}

function lease(owner: string = 'owner-a', generation: number = 1,
  storeInstanceId: number = generation): AccountSessionLease {
  return {
    ownerScopeId: owner,
    storeIdentity: 'store-' + owner,
    generation: generation,
    storeInstanceId: storeInstanceId
  };
}

function context(activeLease: AccountSessionLease = lease(), generation: number = 1,
  ownerToken: number = 1001): MoonlightHostContext {
  return {
    lease: cloneAccountSessionLease(activeLease),
    ownerScopeFingerprint: OWNER_A_FP,
    ownerToken: ownerToken,
    generation: generation,
    localHostId: 'host-a',
    hostId: 'host-a',
    serverUuid: 'SERVER-A',
    endpoint: {
      serverName: 'sunshine.local',
      addresses: [{ value: '192.0.2.10', family: 'ipv4' }],
      httpPort: 47989,
      httpsPort: 47984,
      pinnedTrustAvailable: true,
      allowHttpPairingCandidate: false
    },
    timeoutMs: 7000
  };
}

class DeferredValue<T> {
  readonly promise: Promise<T>;
  private resolveValue: (value: T) => void = (_value: T): void => {};

  constructor() {
    this.promise = new Promise<T>((resolve: (value: T) => void): void => {
      this.resolveValue = resolve;
    });
  }

  resolve(value: T): void { this.resolveValue(value); }
}

function nativeSuccess(request: MoonlightNativeRequest): MoonlightNativeResult {
  return {
    operation: request.operation,
    key: request.key,
    code: 'ok',
    terminalStage: 'complete',
    preflightTruth: 'confirmed',
    actionTruth: request.operation === 'catalog' ? 'not_attempted' : 'confirmed',
    postconditionTruth: request.operation === 'catalog' ? 'not_attempted' : 'confirmed',
    partialAppCount: 0,
    observedAtMs: 1000,
    idempotent: false,
    mutationMayHaveBeenSent: request.operation === 'launch' || request.operation === 'resume' ||
      request.operation === 'quit' || request.operation === 'unpair',
    identityExistingCount: 0,
    identityDeletedCount: 0,
    identityRemainingCount: 0,
    apps: [],
    asset: new ArrayBuffer(0),
    diagnostics: []
  };
}

class FakeNativePort implements MoonlightNativePort {
  requests: MoonlightNativeRequest[] = [];
  events: MoonlightNativeEvent[] = [];
  deferred: DeferredValue<MoonlightNativeResult> | null = null;
  throwOnRequest: boolean = false;
  cancelRequestCount: number = 0;
  cancelOwnerCount: number = 0;
  lastCancelledOwner: number = 0;
  capturedPin: number[] = [];
  resultFactory: (request: MoonlightNativeRequest) => MoonlightNativeResult = nativeSuccess;
  capabilitiesValue: MoonlightBridgeCapabilities = {
    bridgeCompiled: true,
    identityReady: false,
    identityDeletionReady: false,
    transportReady: false,
    trustReady: false,
    commitReady: false,
    pairingReady: false,
    hostControlReady: false,
    blocker: 'runtime_proof_required'
  };

  getCapabilities(): MoonlightBridgeCapabilities { return this.capabilitiesValue; }

  requestAsync(request: MoonlightNativeRequest): Promise<MoonlightNativeResult> {
    if (this.throwOnRequest) { throw new Error('native failure'); }
    this.requests.push(request);
    if (request.pin !== undefined) { this.capturedPin = copyBytes(request.pin); }
    if (this.deferred !== null) { return this.deferred.promise; }
    return Promise.resolve(this.resultFactory(request));
  }

  cancelRequest(_key: MoonlightNativeRequestKey): boolean {
    this.cancelRequestCount++;
    return true;
  }

  cancelOwner(ownerToken: number): number {
    this.cancelOwnerCount++;
    this.lastCancelledOwner = ownerToken;
    return 1;
  }

  pollEvents(_ownerToken: number, _afterSequence: number,
    _limit: number): MoonlightNativeEvent[] {
    return this.events;
  }
}

class MemoryLeaseAndCachePort implements MoonlightAccountLeasePort, MoonlightAppCachePort {
  activeLease: AccountSessionLease | null = lease();
  rows: Map<string, MoonlightAppCacheEntry> = new Map<string, MoonlightAppCacheEntry>();
  commitCount: number = 0;
  writeFailure: boolean = false;
  throwOnCommit: boolean = false;

  currentAccountLease(): AccountSessionLease | null {
    return this.activeLease === null ? null : cloneAccountSessionLease(this.activeLease);
  }

  isLeaseCurrent(candidate: AccountSessionLease): boolean {
    return accountSessionLeaseEquals(this.activeLease, candidate);
  }

  loadMoonlightAppCacheEntries(candidate: AccountSessionLease,
    hostId: string = ''): MoonlightAppCacheEntry[] | null {
    if (!this.isLeaseCurrent(candidate)) { return null; }
    const result: MoonlightAppCacheEntry[] = [];
    this.rows.forEach((row: MoonlightAppCacheEntry): void => {
      if (row.userId === candidate.ownerScopeId &&
          (hostId === '' || row.hostId === hostId)) {
        result.push(cloneMoonlightAppCacheEntry(row));
      }
    });
    return result;
  }

  commitMoonlightAppCacheRefresh(candidate: AccountSessionLease,
    hostId: string, hostRows: MoonlightAppCacheEntry[],
    evictedIds: string[]): boolean {
    if (this.throwOnCommit) { throw new Error('cache failure'); }
    if (this.writeFailure || !this.isLeaseCurrent(candidate)) { return false; }
    const remove: string[] = [];
    this.rows.forEach((row: MoonlightAppCacheEntry, id: string): void => {
      if (row.userId === candidate.ownerScopeId && row.hostId === hostId) {
        remove.push(id);
      }
    });
    for (let i = 0; i < remove.length; i++) { this.rows.delete(remove[i]); }
    for (let i = 0; i < hostRows.length; i++) {
      this.rows.set(hostRows[i].id, cloneMoonlightAppCacheEntry(hostRows[i]));
    }
    for (let i = 0; i < evictedIds.length; i++) { this.rows.delete(evictedIds[i]); }
    this.commitCount++;
    return true;
  }
}

function fixture(): {
  native: FakeNativePort,
  port: MemoryLeaseAndCachePort,
  service: MoonlightHostService
} {
  const native = new FakeNativePort();
  const port = new MemoryLeaseAndCachePort();
  const service = new MoonlightHostService(
    native, port, new MoonlightAppCacheService(port), null);
  return { native: native, port: port, service: service };
}

export default function moonlightHostServiceTest(): void {
  describe('MoonlightHostService', (): void => {
    it('reports_bridge_without_promoting_runtime_capability', 0, (): void => {
      const value = fixture();
      const capabilities: MoonlightBridgeCapabilities = value.service.capabilities();
      expect(capabilities.bridgeCompiled).assertTrue();
      expect(capabilities.identityReady).assertFalse();
      expect(capabilities.transportReady).assertFalse();
      expect(capabilities.hostControlReady).assertFalse();
      expect(capabilities.blocker).assertEqual('runtime_proof_required');
    });

    it('rejects_stale_account_before_native_call', 0, async (): Promise<void> => {
      const value = fixture();
      const staleLease: AccountSessionLease = lease('owner-a', 2, 2);
      const result = await value.service.catalog(context(staleLease, 2));
      expect(result.code).assertEqual('invalid_context');
      expect(value.native.requests.length).assertEqual(0);
      expect(value.port.commitCount).assertEqual(0);
    });

    it('rejects_host_control_while_the_moonlight_lifecycle_gate_is_closed', 0,
      async (): Promise<void> => {
        const native = new FakeNativePort();
        const port = new MemoryLeaseAndCachePort();
        const owners = new MoonlightRuntimeOwnerRegistry();
        const service = new MoonlightHostService(
          native, port, new MoonlightAppCacheService(port), owners);
        const blocked = await service.catalog(context());
        expect(blocked.code).assertEqual('lifecycle_closed');
        expect(native.requests.length).assertEqual(0);
        owners.bindScope(lease());
        expect((await service.catalog(context())).code).assertEqual('ok');
        owners.closeGate();
        expect((await service.catalog(context())).code).assertEqual('lifecycle_closed');
        expect(native.requests.length).assertEqual(1);
      });

    it('rejects_owner_fingerprint_not_derived_from_the_captured_lease', 0,
      async (): Promise<void> => {
        const value = fixture();
        const wrong: MoonlightHostContext = context();
        wrong.ownerScopeFingerprint = moonlightOwnerScopeFingerprint('owner-b');
        const result = await value.service.catalog(wrong);
        expect(result.code).assertEqual('invalid_context');
        expect(value.native.requests.length).assertEqual(0);
      });

    it('commits_only_complete_confirmed_catalog_to_existing_cache', 0,
      async (): Promise<void> => {
        const value = fixture();
        value.native.resultFactory = (request: MoonlightNativeRequest): MoonlightNativeResult => {
          const result: MoonlightNativeResult = nativeSuccess(request);
          result.apps = [
            { id: 42, title: 'Desktop', hdrSupported: true },
            { id: 77, title: 'Steam' }
          ];
          return result;
        };
        const result = await value.service.catalog(context());
        expect(result.ok).assertTrue();
        expect(result.cacheCode).assertEqual('ok');
        expect(result.visibleApps.length).assertEqual(2);
        expect(value.port.commitCount).assertEqual(1);
        expect(value.port.rows.size).assertEqual(2);
        expect(result.visibleApps[0].userId).assertEqual('owner-a');
        expect(result.visibleApps[0].hostId).assertEqual('host-a');
      });

    it('keeps_the_native_pairing_identity_separate_from_the_local_cache_owner', 0,
      async (): Promise<void> => {
        const value = fixture();
        value.native.resultFactory = (request: MoonlightNativeRequest): MoonlightNativeResult => {
          const result: MoonlightNativeResult = nativeSuccess(request);
          result.apps = [{ id: 42, title: 'Desktop' }];
          return result;
        };
        const separated: MoonlightHostContext = context();
        separated.hostId = 'sunshine-server-uuid';
        separated.localHostId = 'host-record-a';
        const result = await value.service.catalog(separated);
        expect(result.ok).assertTrue();
        expect(value.native.requests[0].hostId).assertEqual('sunshine-server-uuid');
        expect(result.visibleApps[0].hostId).assertEqual('host-record-a');
      });

    it('rejects_catalog_cache_commit_without_a_durable_local_host_id', 0,
      async (): Promise<void> => {
        const value = fixture();
        value.native.resultFactory = (request: MoonlightNativeRequest): MoonlightNativeResult => {
          const result: MoonlightNativeResult = nativeSuccess(request);
          result.apps = [{ id: 42, title: 'Desktop' }];
          return result;
        };
        const missingLocalId: MoonlightHostContext = context();
        missingLocalId.localHostId = undefined;
        const result = await value.service.catalog(missingLocalId);
        expect(result.code).assertEqual('invalid_context');
        expect(value.native.requests.length).assertEqual(1);
        expect(value.port.commitCount).assertEqual(0);
      });

    it('partial_or_duplicate_catalog_never_mutates_cache', 0,
      async (): Promise<void> => {
        const value = fixture();
        value.native.resultFactory = (request: MoonlightNativeRequest): MoonlightNativeResult => {
          const result: MoonlightNativeResult = nativeSuccess(request);
          result.partialAppCount = 1;
          result.apps = [{ id: 42, title: 'Desktop' }];
          return result;
        };
        const partial = await value.service.catalog(context());
        expect(partial.code).assertEqual('invalid_catalog');
        expect(value.port.commitCount).assertEqual(0);
        value.native.resultFactory = (request: MoonlightNativeRequest): MoonlightNativeResult => {
          const result: MoonlightNativeResult = nativeSuccess(request);
          result.apps = [{ id: 42, title: 'A' }, { id: 42, title: 'B' }];
          return result;
        };
        const duplicate = await value.service.catalog(context());
        expect(duplicate.code).assertEqual('invalid_catalog');
        expect(value.port.commitCount).assertEqual(0);
      });

    it('drops_owner_switch_completion_before_cache_commit', 0,
      async (): Promise<void> => {
        const value = fixture();
        value.native.deferred = new DeferredValue<MoonlightNativeResult>();
        const pending: Promise<MoonlightHostServiceResult> = value.service.catalog(context());
        const request: MoonlightNativeRequest = value.native.requests[0];
        value.port.activeLease = lease('owner-b', 2, 2);
        value.native.deferred.resolve(nativeSuccess(request));
        const result = await pending;
        expect(result.code).assertEqual('stale_lease');
        expect(value.service.staleCompletions()).assertEqual(1);
        expect(value.port.commitCount).assertEqual(0);
      });

    it('drops_same_owner_store_instance_reopen_completion', 0,
      async (): Promise<void> => {
        const value = fixture();
        value.native.deferred = new DeferredValue<MoonlightNativeResult>();
        const pending = value.service.catalog(context());
        const request: MoonlightNativeRequest = value.native.requests[0];
        value.port.activeLease = lease('owner-a', 1, 99);
        value.native.deferred.resolve(nativeSuccess(request));
        const result = await pending;
        expect(result.code).assertEqual('stale_lease');
        expect(value.port.commitCount).assertEqual(0);
      });

    it('rejects_mismatched_native_result_identity', 0,
      async (): Promise<void> => {
        const value = fixture();
        value.native.resultFactory = (request: MoonlightNativeRequest): MoonlightNativeResult => {
          const result: MoonlightNativeResult = nativeSuccess(request);
          result.key = {
            requestId: request.key.requestId,
            generation: request.key.generation + 1,
            ownerToken: request.key.ownerToken
          };
          return result;
        };
        const result = await value.service.catalog(context());
        expect(result.code).assertEqual('protocol_failure');
        expect(value.port.commitCount).assertEqual(0);
      });

    it('reports_cache_failure_without_rewriting_native_truth', 0,
      async (): Promise<void> => {
        const value = fixture();
        value.port.writeFailure = true;
        const result = await value.service.catalog(context());
        expect(result.code).assertEqual('cache_failed');
        expect(result.nativeCode).assertEqual('ok');
        expect(result.cacheCode).assertEqual('write_failed');
        expect(result.ok).assertFalse();
        const thrown = fixture();
        thrown.port.throwOnCommit = true;
        const thrownResult = await thrown.service.catalog(context());
        expect(thrownResult.code).assertEqual('cache_failed');
        expect(thrownResult.nativeCode).assertEqual('ok');
      });

    it('launch_forwards_only_non_secret_configuration', 0,
      async (): Promise<void> => {
        const value = fixture();
        const result = await value.service.launch(
          context(), 42, { width: 1920, height: 1080, refreshRate: 60 });
        expect(result.ok).assertTrue();
        expect(value.native.requests.length).assertEqual(2);
        expect(value.native.requests[0].operation).assertEqual('catalog');
        expect(value.native.requests[1].operation).assertEqual('launch');
        expect(value.native.requests[0].key.generation)
          .assertEqual(value.native.requests[1].key.generation);
        expect(value.native.requests[0].key.ownerToken)
          .assertEqual(value.native.requests[1].key.ownerToken);
        expect(value.native.requests[1].catalogGeneration).assertEqual(1);
        expect(value.native.requests[1].launchConfiguration?.width).assertEqual(1920);
      });

    it('launch_never_mutates_host_when_authenticated_catalog_refresh_fails', 0,
      async (): Promise<void> => {
        const value = fixture();
        value.native.resultFactory = (request: MoonlightNativeRequest): MoonlightNativeResult => {
          const result: MoonlightNativeResult = nativeSuccess(request);
          if (request.operation === 'catalog') {
            result.code = 'transport_failure';
            result.terminalStage = 'failed';
            result.preflightTruth = 'failed';
          }
          return result;
        };
        const result = await value.service.launch(
          context(), 42, { width: 1920, height: 1080, refreshRate: 60 });
        expect(result.code).assertEqual('transport_failure');
        expect(value.native.requests.length).assertEqual(1);
        expect(value.native.requests[0].operation).assertEqual('catalog');
      });

    it('pair_uses_an_ephemeral_pin_copy', 0, async (): Promise<void> => {
      const value = fixture();
      const pairContext: MoonlightHostContext = context();
      pairContext.endpoint = {
        serverName: 'sunshine.local',
        addresses: [{ value: '192.0.2.10', family: 'ipv4' }],
        allowHttpPairingCandidate: true,
        pinnedTrustAvailable: false
      };
      const callerPin: Uint8Array = new Uint8Array([49, 50, 51, 52]);
      const result = await value.service.pair(pairContext, 'install-a', callerPin);
      expect(result.ok).assertTrue();
      expect(value.native.capturedPin[0]).assertEqual(49);
      expect(callerPin[0]).assertEqual(49);
      const forwardedPin: Uint8Array | undefined = value.native.requests[0].pin;
      expect(forwardedPin !== undefined).assertTrue();
      if (forwardedPin !== undefined) {
        expect(forwardedPin[0]).assertEqual(0);
      }
    });

    it('unpair_forwards_exact_trust_and_clamps_standard_timeout', 0,
      async (): Promise<void> => {
        const value = fixture();
        const unpairContext: MoonlightHostContext = context();
        unpairContext.installationId = 'install-a';
        unpairContext.pinnedCertificateSha256 = 'c'.repeat(64);
        unpairContext.timeoutMs = 120000;
        const result = await value.service.unpair(unpairContext);
        expect(result.ok).assertTrue();
        expect(value.native.requests.length).assertEqual(1);
        expect(value.native.requests[0].operation).assertEqual('unpair');
        expect(value.native.requests[0].timeoutMs).assertEqual(30000);
        expect(value.native.requests[0].pinnedCertificateSha256)
          .assertEqual('c'.repeat(64));
      });

    it('pair_keeps_extended_timeout_while_catalog_is_bounded', 0,
      async (): Promise<void> => {
        const pairFixture = fixture();
        const pairContext: MoonlightHostContext = context();
        pairContext.timeoutMs = 120000;
        pairContext.endpoint.pinnedTrustAvailable = false;
        pairContext.endpoint.allowHttpPairingCandidate = true;
        const pin: Uint8Array = new Uint8Array([49, 50, 51, 52]);
        await pairFixture.service.pair(pairContext, 'install-a', pin);
        expect(pairFixture.native.requests[0].timeoutMs).assertEqual(120000);

        const catalogFixture = fixture();
        const catalogContext: MoonlightHostContext = context();
        catalogContext.timeoutMs = 120000;
        await catalogFixture.service.catalogRuntime(catalogContext);
        expect(catalogFixture.native.requests[0].timeoutMs).assertEqual(30000);
      });

    it('dispose_owner_cancels_and_late_completion_stays_disposed', 0,
      async (): Promise<void> => {
        const value = fixture();
        value.native.deferred = new DeferredValue<MoonlightNativeResult>();
        const pending = value.service.catalog(context());
        const request: MoonlightNativeRequest = value.native.requests[0];
        expect(value.service.disposeOwner(1001)).assertEqual(1);
        expect(value.native.lastCancelledOwner).assertEqual(1001);
        value.native.deferred.resolve(nativeSuccess(request));
        const result = await pending;
        expect(result.code).assertEqual('disposed');
        expect(value.service.disposeOwner(1001)).assertEqual(1);
        const blocked = await value.service.catalog(context());
        expect(blocked.code).assertEqual('disposed');
        expect(value.native.requests.length).assertEqual(1);
      });

    it('event_poll_filters_generation_and_accounts_for_stale_events', 0, (): void => {
      const value = fixture();
      value.native.events = [
        {
          sequence: 1, monotonicTimestampMs: 100, operation: 'catalog',
          key: { requestId: 1, generation: 0, ownerToken: 1001 },
          code: 'stale', terminalStage: 'failed'
        },
        {
          sequence: 2, monotonicTimestampMs: 101, operation: 'catalog',
          key: { requestId: 2, generation: 1, ownerToken: 1001 },
          code: 'ok', terminalStage: 'complete'
        }
      ];
      const events: MoonlightNativeEvent[] = value.service.pollEvents(context());
      expect(events.length).assertEqual(1);
      expect(events[0].sequence).assertEqual(2);
      expect(value.service.staleEvents()).assertEqual(1);
    });

    it('native_exception_and_explicit_quit_are_stable_and_separate', 0,
      async (): Promise<void> => {
        const value = fixture();
        value.native.throwOnRequest = true;
        const failed = await value.service.catalog(context());
        expect(failed.code).assertEqual('native_exception');
        value.native.throwOnRequest = false;
        const quit = await value.service.quit(context(), 42, true);
        expect(quit.ok).assertTrue();
        expect(value.native.requests[0].operation).assertEqual('quit');
        expect(value.native.requests[0].expectedCurrentAppId).assertEqual(42);
        expect(value.native.requests[0].userConfirmedTermination).assertTrue();
      });
  });
}
