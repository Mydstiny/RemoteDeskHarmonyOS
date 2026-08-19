import { describe, expect, it } from '@ohos/hypium';
import {
  MoonlightAddress,
  MoonlightHost,
  defaultMoonlightSettings,
  moonlightAddressKey
} from '../main/ets/model/MoonlightModels';
import {
  AccountSessionLease,
  accountSessionLeaseEquals,
  cloneAccountSessionLease
} from '../main/ets/services/AccountScopePolicy';
import {
  MoonlightBridgeCapabilities,
  MoonlightHostContext,
  MoonlightHostServiceResult
} from '../main/ets/services/MoonlightHostService';
import {
  MoonlightHostUnpairControlPort,
  MoonlightHostUnpairLeasePort,
  MoonlightHostUnpairRuntime,
  MoonlightHostUnpairSettingsPort,
  MoonlightHostUnpairViewPort
} from '../main/ets/services/MoonlightHostUnpairRuntime';
import {
  MoonlightHostLocalView
} from '../main/ets/services/MoonlightLocalViewService';
import {
  MoonlightLocalSettingsResult
} from '../main/ets/services/MoonlightSettingsLocalService';
import {
  MoonlightRuntimeOwnerTokenAllocator
} from '../main/ets/services/MoonlightRuntimeContextFactory';

const CERTIFICATE_SHA256: string = 'a'.repeat(64);

function lease(owner: string = 'owner-a', generation: number = 1,
  storeInstanceId: number = 1): AccountSessionLease {
  return {
    ownerScopeId: owner,
    storeIdentity: 'store-' + owner,
    generation,
    storeInstanceId
  };
}

function host(): MoonlightHost {
  const address: MoonlightAddress = {
    host: '192.0.2.10', family: 'ipv4', port: 47989
  };
  return {
    id: 'host-record',
    serverUuid: 'sunshine-server-uuid',
    displayName: 'Sunshine',
    addresses: [address],
    preferredAddressKey: moonlightAddressKey(address),
    hostType: 'sunshine',
    wakeOnLan: { enabled: false, mac: '', broadcast: '' },
    userOrder: 0
  };
}

function view(candidate: AccountSessionLease = lease()): MoonlightHostLocalView {
  return {
    ok: true,
    code: 'ok',
    lease: cloneAccountSessionLease(candidate),
    host: host(),
    paired: true,
    serverCertificateSha256: CERTIFICATE_SHA256,
    profiles: [],
    cacheEntries: [],
    catalogItems: [],
    updatedAt: 1
  };
}

class MemoryLeasePort implements MoonlightHostUnpairLeasePort {
  active: AccountSessionLease | null = lease();

  currentAccountLease(): AccountSessionLease | null {
    return this.active === null ? null : cloneAccountSessionLease(this.active);
  }

  isLeaseCurrent(candidate: AccountSessionLease): boolean {
    return accountSessionLeaseEquals(this.active, candidate);
  }
}

class MemoryViewPort implements MoonlightHostUnpairViewPort {
  value: MoonlightHostLocalView = view();
  requestedHostId: string = '';

  loadHost(hostId: string, _nowMs: number): MoonlightHostLocalView {
    this.requestedHostId = hostId;
    return this.value;
  }
}

class MemorySettingsPort implements MoonlightHostUnpairSettingsPort {
  value: MoonlightLocalSettingsResult = {
    ok: true,
    code: 'default',
    settings: defaultMoonlightSettings(),
    localCommitted: false
  };

  load(): MoonlightLocalSettingsResult {
    return this.value;
  }
}

function capabilities(ready: boolean = true): MoonlightBridgeCapabilities {
  return {
    bridgeCompiled: ready,
    identityReady: ready,
    identityDeletionReady: ready,
    transportReady: ready,
    trustReady: ready,
    commitReady: ready,
    pairingReady: ready,
    hostControlReady: ready,
    blocker: ready ? '' : 'runtime_proof_required'
  };
}

function serviceResult(context: MoonlightHostContext,
  ok: boolean = true): MoonlightHostServiceResult {
  const key = {
    requestId: 1,
    generation: context.generation,
    ownerToken: context.ownerToken
  };
  return {
    ok,
    code: ok ? 'ok' : 'transport_failure',
    nativeCode: ok ? 'ok' : 'transport_failure',
    key,
    stale: false,
    cacheCode: '',
    visibleApps: [],
    nativeResult: {
      operation: 'unpair',
      key,
      code: ok ? 'ok' : 'transport_failure',
      terminalStage: ok ? 'complete' : 'failed',
      preflightTruth: ok ? 'confirmed' : 'failed',
      actionTruth: ok ? 'confirmed' : 'failed',
      postconditionTruth: ok ? 'confirmed' : 'failed',
      partialAppCount: 0,
      observedAtMs: 1,
      idempotent: true,
      mutationMayHaveBeenSent: !ok,
      identityExistingCount: 0,
      identityDeletedCount: 0,
      identityRemainingCount: 0,
      apps: [],
      asset: new ArrayBuffer(0),
      diagnostics: []
    }
  };
}

class MemoryControlPort implements MoonlightHostUnpairControlPort {
  ready: boolean = true;
  succeed: boolean = true;
  context: MoonlightHostContext | null = null;
  disposeCount: number = 0;

  capabilities(): MoonlightBridgeCapabilities {
    return capabilities(this.ready);
  }

  async unpair(context: MoonlightHostContext): Promise<MoonlightHostServiceResult> {
    this.context = context;
    return serviceResult(context, this.succeed);
  }

  disposeOwner(_ownerToken: number): number {
    this.disposeCount++;
    return 0;
  }
}

export default function moonlightHostUnpairRuntimeTest(): void {
  describe('MoonlightHostUnpairRuntime', (): void => {
    it('uses_the_pretransaction_trust_snapshot_after_local_revocation', 0,
      async (): Promise<void> => {
        MoonlightRuntimeOwnerTokenAllocator.getInstance().resetForTest();
        const leases = new MemoryLeasePort();
        const views = new MemoryViewPort();
        const control = new MemoryControlPort();
        const current: AccountSessionLease = lease();
        const runtime = new MoonlightHostUnpairRuntime(
          leases, views, new MemorySettingsPort(), control);
        expect(runtime.isHostUnpairReady(current, 'host-record')).assertTrue();
        // Simulate the deletion command committing local trust removal before
        // the best-effort Sunshine request starts.
        views.value = {
          ok: false, code: 'host_not_found', lease: current, host: null,
          paired: false, serverCertificateSha256: '', profiles: [],
          cacheEntries: [], catalogItems: [], updatedAt: 0
        };
        expect(await runtime.requestHostUnpair(current, 'host-record')).assertTrue();
        expect(views.requestedHostId).assertEqual('host-record');
        expect(control.context?.hostId).assertEqual('sunshine-server-uuid');
        expect(control.context?.pinnedCertificateSha256)
          .assertEqual(CERTIFICATE_SHA256);
        expect(control.context?.endpoint.addresses[0].value)
          .assertEqual('192.0.2.10');
        expect(control.disposeCount).assertEqual(1);
      });

    it('rejects_missing_transport_capability_without_a_remote_request', 0,
      async (): Promise<void> => {
        const control = new MemoryControlPort();
        control.ready = false;
        const runtime = new MoonlightHostUnpairRuntime(
          new MemoryLeasePort(), new MemoryViewPort(),
          new MemorySettingsPort(), control);
        expect(runtime.isHostUnpairReady(lease(), 'host-record')).assertFalse();
        expect(await runtime.requestHostUnpair(lease(), 'host-record')).assertFalse();
        expect(control.context === null).assertTrue();
        expect(control.disposeCount).assertEqual(0);
      });

    it('drops_the_captured_request_after_an_account_switch', 0,
      async (): Promise<void> => {
        const leases = new MemoryLeasePort();
        const control = new MemoryControlPort();
        const current: AccountSessionLease = lease();
        const runtime = new MoonlightHostUnpairRuntime(
          leases, new MemoryViewPort(), new MemorySettingsPort(), control);
        expect(runtime.isHostUnpairReady(current, 'host-record')).assertTrue();
        leases.active = lease('owner-b', 2, 2);
        expect(await runtime.requestHostUnpair(current, 'host-record')).assertFalse();
        expect(control.context === null).assertTrue();
        expect(control.disposeCount).assertEqual(0);
      });

    it('reports_remote_failure_and_always_retires_the_owner', 0,
      async (): Promise<void> => {
        const control = new MemoryControlPort();
        control.succeed = false;
        const runtime = new MoonlightHostUnpairRuntime(
          new MemoryLeasePort(), new MemoryViewPort(),
          new MemorySettingsPort(), control);
        const current: AccountSessionLease = lease();
        expect(runtime.isHostUnpairReady(current, 'host-record')).assertTrue();
        expect(await runtime.requestHostUnpair(current, 'host-record')).assertFalse();
        expect(control.disposeCount).assertEqual(1);
      });
  });
}
