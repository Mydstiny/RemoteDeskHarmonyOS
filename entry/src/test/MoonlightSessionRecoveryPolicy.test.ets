import { common } from '@kit.AbilityKit';
import { afterAll, beforeEach, describe, expect, it } from '@ohos/hypium';
import { AccountSessionLease } from '../main/ets/services/AccountScopePolicy';
import {
  MOONLIGHT_SESSION_RECOVERY_MARKER_VERSION,
  MoonlightSessionRecoveryBinding,
  MoonlightSessionRecoveryMarker,
  createMoonlightSessionRecoveryMarker,
  decodeMoonlightSessionRecoveryMarker,
  encodeMoonlightSessionRecoveryMarker,
  moonlightSessionRecoveryHostState,
  moonlightSessionRecoveryMarkerMatchesBinding,
  moonlightSessionRecoveryRequiresRemoteReset,
  updateMoonlightSessionRecoveryMarker
} from '../main/ets/services/MoonlightSessionRecoveryPolicy';
import {
  MOONLIGHT_SESSION_RECOVERY_PREFERENCES_NAME,
  MoonlightSessionRecoveryPreferenceAdapter,
  MoonlightSessionRecoveryPreferenceRead,
  MoonlightSessionRecoveryStore,
  moonlightSessionRecoveryBinding,
  moonlightSessionRecoveryHostPreferenceKey,
  moonlightSessionRecoveryPreferenceKey,
  setMoonlightSessionRecoveryPreferenceAdapterForTest
} from '../main/ets/services/MoonlightSessionRecoveryStore';
import {
  MoonlightSessionRecoveryRuntime
} from '../main/ets/services/MoonlightSessionRecoveryRuntime';
import { MoonlightNativeStreamSnapshot } from '../main/ets/services/MoonlightHostService';

class MemoryRecoveryPreferences implements MoonlightSessionRecoveryPreferenceAdapter {
  readonly values: Map<string, string> = new Map<string, string>();
  failRead: boolean = false;
  failWrite: boolean = false;
  failRemove: boolean = false;

  private composite(storeName: string, key: string): string {
    return storeName + '|' + key;
  }

  read(_context: common.Context, storeName: string,
    key: string): MoonlightSessionRecoveryPreferenceRead {
    if (this.failRead) { return { ok: false, value: '' }; }
    return {
      ok: true,
      value: this.values.get(this.composite(storeName, key)) || ''
    };
  }

  write(_context: common.Context, storeName: string,
    key: string, value: string): boolean {
    if (this.failWrite) { return false; }
    this.values.set(this.composite(storeName, key), value);
    return true;
  }

  remove(_context: common.Context, storeName: string, key: string): boolean {
    if (this.failRemove) { return false; }
    this.values.delete(this.composite(storeName, key));
    return true;
  }

  raw(binding: MoonlightSessionRecoveryBinding,
    hostId: string = 'host-a'): string {
    return this.values.get(this.composite(
      MOONLIGHT_SESSION_RECOVERY_PREFERENCES_NAME,
      moonlightSessionRecoveryHostPreferenceKey(binding, hostId))) || '';
  }

  legacyRaw(binding: MoonlightSessionRecoveryBinding): string {
    return this.values.get(this.composite(
      MOONLIGHT_SESSION_RECOVERY_PREFERENCES_NAME,
      moonlightSessionRecoveryPreferenceKey(binding))) || '';
  }
}

function lease(owner: string = 'owner-a', store: string = 'store-a.db',
  generation: number = 1): AccountSessionLease {
  return {
    ownerScopeId: owner,
    storeIdentity: store,
    generation: generation,
    storeInstanceId: generation
  };
}

function marker(binding: MoonlightSessionRecoveryBinding,
  nowMs: number = 1000): MoonlightSessionRecoveryMarker {
  return createMoonlightSessionRecoveryMarker(binding, {
    sessionId: '00112233445566778899aabbccddeeff',
    hostId: 'host-a',
    profileId: 'profile-a',
    appId: '7'
  }, nowMs) as MoonlightSessionRecoveryMarker;
}

function nativeTerminal(code: string,
  inputMayBeStuck: boolean = false): MoonlightNativeStreamSnapshot {
  return {
    matched: true, code: code, sessionId: 42, generation: 7, ownerToken: 11,
    transportReady: false, videoReady: false, audioReady: false,
    inputReady: false, controllerReady: false, physicalControllerReady: false,
    inputMayBeStuck: inputMayBeStuck, firstFrameReady: false,
    terminal: true, lastSequence: 12
  };
}

export default function moonlightSessionRecoveryPolicyTest(): void {
  describe('MoonlightSessionRecoveryPolicy', (): void => {
    let adapter: MemoryRecoveryPreferences = new MemoryRecoveryPreferences();
    const context: common.Context = undefined as common.Context;

    beforeEach((): void => {
      adapter = new MemoryRecoveryPreferences();
      setMoonlightSessionRecoveryPreferenceAdapterForTest(adapter);
    });

    afterAll((): void => {
      setMoonlightSessionRecoveryPreferenceAdapterForTest(null);
    });

    it('encodes_only_the_exact_non_secret_owner_store_marker', 0, (): void => {
      const binding: MoonlightSessionRecoveryBinding =
        moonlightSessionRecoveryBinding(lease());
      const source: MoonlightSessionRecoveryMarker = marker(binding);
      const raw: string = encodeMoonlightSessionRecoveryMarker(source);
      const decoded = decodeMoonlightSessionRecoveryMarker(raw);
      expect(decoded.code).assertEqual('ready');
      expect(decoded.marker?.sessionId).assertEqual(source.sessionId);
      expect(raw.indexOf('owner-a')).assertEqual(-1);
      expect(raw.indexOf('store-a.db')).assertEqual(-1);
      expect(raw.indexOf('pin')).assertEqual(-1);
      expect(raw.indexOf('riKey')).assertEqual(-1);
      expect(raw.indexOf('endpoint')).assertEqual(-1);
    });

    it('distinguishes_too_new_and_rejects_extra_secret_or_malformed_fields', 0, (): void => {
      const binding: MoonlightSessionRecoveryBinding =
        moonlightSessionRecoveryBinding(lease());
      const source: MoonlightSessionRecoveryMarker = marker(binding);
      const tooNew: Record<string, Object> =
        JSON.parse(encodeMoonlightSessionRecoveryMarker(source)) as Record<string, Object>;
      tooNew['markerVersion'] = MOONLIGHT_SESSION_RECOVERY_MARKER_VERSION + 1;
      expect(decodeMoonlightSessionRecoveryMarker(JSON.stringify(tooNew)).code)
        .assertEqual('too_new');
      const secret: Record<string, Object> =
        JSON.parse(encodeMoonlightSessionRecoveryMarker(source)) as Record<string, Object>;
      secret['pin'] = '1234';
      expect(decodeMoonlightSessionRecoveryMarker(JSON.stringify(secret)).code)
        .assertEqual('corrupt');
      expect(decodeMoonlightSessionRecoveryMarker('{broken').code)
        .assertEqual('corrupt');
    });

    it('matches_owner_and_store_but_not_the_ephemeral_generation', 0, (): void => {
      const oldBinding: MoonlightSessionRecoveryBinding =
        moonlightSessionRecoveryBinding(lease('owner-a', 'store-a.db', 1));
      const source: MoonlightSessionRecoveryMarker = marker(oldBinding);
      const restarted: MoonlightSessionRecoveryBinding =
        moonlightSessionRecoveryBinding(lease('owner-a', 'store-a.db', 99));
      expect(moonlightSessionRecoveryMarkerMatchesBinding(source, restarted)).assertTrue();
      expect(moonlightSessionRecoveryMarkerMatchesBinding(source,
        moonlightSessionRecoveryBinding(lease('owner-b', 'store-a.db', 99))))
        .assertFalse();
      expect(moonlightSessionRecoveryMarkerMatchesBinding(source,
        moonlightSessionRecoveryBinding(lease('owner-a', 'store-b.db', 99))))
        .assertFalse();
    });

    it('persists_only_input_neutrality_boundaries_and_maps_read_only_host_truth', 0,
      (): void => {
        const binding: MoonlightSessionRecoveryBinding =
          moonlightSessionRecoveryBinding(lease());
        const source: MoonlightSessionRecoveryMarker = marker(binding);
        const active: MoonlightSessionRecoveryMarker =
          updateMoonlightSessionRecoveryMarker(source, {
            stage: 'streaming', heartbeatAt: 1100,
            hostAppMayStillBeRunning: true, inputMayBeStuck: true,
            terminalAction: 'none'
          }) as MoonlightSessionRecoveryMarker;
        expect(moonlightSessionRecoveryRequiresRemoteReset(active)).assertTrue();
        const neutral: MoonlightSessionRecoveryMarker =
          updateMoonlightSessionRecoveryMarker(active, {
            stage: 'streaming', heartbeatAt: 1200,
            hostAppMayStillBeRunning: true, inputMayBeStuck: false,
            terminalAction: 'none'
          }) as MoonlightSessionRecoveryMarker;
        expect(moonlightSessionRecoveryRequiresRemoteReset(neutral)).assertFalse();
        expect(moonlightSessionRecoveryHostState('confirmation_required', false))
          .assertEqual('matching_app_running');
        expect(moonlightSessionRecoveryHostState('ok', true)).assertEqual('host_stopped');
        expect(moonlightSessionRecoveryHostState('stale', false))
          .assertEqual('different_app_running');
        expect(moonlightSessionRecoveryHostState('transport_failure', false))
          .assertEqual('host_unreachable');
      });

    it('keeps_preferences_exactly_owner_scoped_and_survives_generation_restart', 0,
      (): void => {
        const firstLease: AccountSessionLease = lease('owner-a', 'store-a.db', 1);
        const store: MoonlightSessionRecoveryStore = new MoonlightSessionRecoveryStore();
        expect(store.bind(context, firstLease, 'host-a').code).assertEqual('absent');
        const created = store.begin({
          sessionId: '00112233445566778899aabbccddeeff',
          hostId: 'host-a', profileId: '', appId: '7'
        }, 1000);
        expect(created !== null).assertTrue();
        const rebound: MoonlightSessionRecoveryStore = new MoonlightSessionRecoveryStore();
        const read = rebound.bind(
          context, lease('owner-a', 'store-a.db', 8), 'host-a');
        expect(read.code).assertEqual('ready');
        expect(read.marker?.storeGenerationAtLaunch).assertEqual(1);
        const other: MoonlightSessionRecoveryStore = new MoonlightSessionRecoveryStore();
        expect(other.bind(
          context, lease('owner-b', 'store-a.db', 8), 'host-a').code)
          .assertEqual('absent');
      });

    it('does_not_publish_failed_updates_or_overwrite_corrupt_or_too_new_data', 0,
      (): void => {
        const currentLease: AccountSessionLease = lease();
        const binding: MoonlightSessionRecoveryBinding =
          moonlightSessionRecoveryBinding(currentLease);
        const store: MoonlightSessionRecoveryStore = new MoonlightSessionRecoveryStore();
        store.bind(context, currentLease, 'host-a');
        const created = store.begin({
          sessionId: '00112233445566778899aabbccddeeff',
          hostId: 'host-a', profileId: '', appId: '7'
        }, 1000) as MoonlightSessionRecoveryMarker;
        const before: string = adapter.raw(binding);
        adapter.failWrite = true;
        expect(store.update(created.sessionId, {
          stage: 'streaming', heartbeatAt: 1100,
          hostAppMayStillBeRunning: true, inputMayBeStuck: true,
          terminalAction: 'none'
        })).assertNull();
        expect(adapter.raw(binding)).assertEqual(before);
        expect(store.snapshot().marker?.inputMayBeStuck).assertFalse();

        adapter = new MemoryRecoveryPreferences();
        const key: string = moonlightSessionRecoveryHostPreferenceKey(
          binding, 'host-a');
        adapter.values.set(MOONLIGHT_SESSION_RECOVERY_PREFERENCES_NAME + '|' + key,
          '{corrupt');
        setMoonlightSessionRecoveryPreferenceAdapterForTest(adapter);
        const corrupt: MoonlightSessionRecoveryStore = new MoonlightSessionRecoveryStore();
        expect(corrupt.bind(context, currentLease, 'host-a').code)
          .assertEqual('corrupt');
        expect(corrupt.begin({
          sessionId: 'ffeeddccbbaa99887766554433221100',
          hostId: 'host-a', profileId: '', appId: '7'
        }, 1200)).assertNull();
        expect(adapter.raw(binding)).assertEqual('{corrupt');
        expect(corrupt.clearUnreadable()).assertTrue();
        expect(adapter.raw(binding)).assertEqual('');
      });

    it('preserves_too_new_state_until_the_exact_owner_explicitly_resets_it', 0,
      (): void => {
        const currentLease: AccountSessionLease = lease('owner-a', 'store-a.db', 1);
        const binding: MoonlightSessionRecoveryBinding =
          moonlightSessionRecoveryBinding(currentLease);
        const tooNew: Record<string, Object> = JSON.parse(
          encodeMoonlightSessionRecoveryMarker(marker(binding))) as Record<string, Object>;
        tooNew['markerVersion'] = MOONLIGHT_SESSION_RECOVERY_MARKER_VERSION + 1;
        const key: string = moonlightSessionRecoveryHostPreferenceKey(
          binding, 'host-a');
        adapter.values.set(MOONLIGHT_SESSION_RECOVERY_PREFERENCES_NAME + '|' + key,
          JSON.stringify(tooNew));
        const foreignBinding: MoonlightSessionRecoveryBinding =
          moonlightSessionRecoveryBinding(lease('owner-b', 'store-a.db', 1));
        const foreignKey: string = moonlightSessionRecoveryPreferenceKey(foreignBinding);
        adapter.values.set(MOONLIGHT_SESSION_RECOVERY_PREFERENCES_NAME + '|' + foreignKey,
          '{foreign-corrupt');

        const store: MoonlightSessionRecoveryStore = new MoonlightSessionRecoveryStore();
        expect(store.bind(context, currentLease, 'host-a').code)
          .assertEqual('too_new');
        expect(store.clear()).assertFalse();
        expect(adapter.raw(binding).length > 0).assertTrue();
        expect(store.clearUnreadable()).assertTrue();
        expect(adapter.raw(binding)).assertEqual('');
        expect(adapter.legacyRaw(foreignBinding)).assertEqual('{foreign-corrupt');
      });

    it('migrates_only_the_matching_legacy_host_and_never_blocks_another_host', 0,
      (): void => {
        const currentLease: AccountSessionLease = lease();
        const binding: MoonlightSessionRecoveryBinding =
          moonlightSessionRecoveryBinding(currentLease);
        const legacy: MoonlightSessionRecoveryMarker = marker(binding);
        adapter.values.set(
          MOONLIGHT_SESSION_RECOVERY_PREFERENCES_NAME + '|' +
            moonlightSessionRecoveryPreferenceKey(binding),
          encodeMoonlightSessionRecoveryMarker(legacy));

        const otherHost: MoonlightSessionRecoveryStore =
          new MoonlightSessionRecoveryStore();
        expect(otherHost.bind(context, currentLease, 'host-b').code)
          .assertEqual('absent');
        expect(otherHost.begin({
          sessionId: 'ffeeddccbbaa99887766554433221100',
          hostId: 'host-b', profileId: '', appId: '9'
        }, 1100) !== null).assertTrue();
        expect(adapter.legacyRaw(binding).length > 0).assertTrue();

        const matchingHost: MoonlightSessionRecoveryStore =
          new MoonlightSessionRecoveryStore();
        const migrated = matchingHost.bind(context, currentLease, 'host-a');
        expect(migrated.code).assertEqual('ready');
        expect(migrated.marker?.hostId).assertEqual('host-a');
        expect(adapter.raw(binding, 'host-a').length > 0).assertTrue();
        expect(adapter.raw(binding, 'host-b').length > 0).assertTrue();
        expect(adapter.legacyRaw(binding)).assertEqual('');
      });

    it('clears_a_matching_legacy_shadow_before_retiring_the_v2_host_marker', 0,
      (): void => {
        const currentLease: AccountSessionLease = lease();
        const binding: MoonlightSessionRecoveryBinding =
          moonlightSessionRecoveryBinding(currentLease);
        const legacy: MoonlightSessionRecoveryMarker = marker(binding);
        adapter.values.set(
          MOONLIGHT_SESSION_RECOVERY_PREFERENCES_NAME + '|' +
            moonlightSessionRecoveryPreferenceKey(binding),
          encodeMoonlightSessionRecoveryMarker(legacy));
        adapter.failRemove = true;
        const store: MoonlightSessionRecoveryStore =
          new MoonlightSessionRecoveryStore();
        expect(store.bind(context, currentLease, 'host-a').code)
          .assertEqual('ready');
        expect(adapter.raw(binding, 'host-a').length > 0).assertTrue();
        expect(adapter.legacyRaw(binding).length > 0).assertTrue();

        adapter.failRemove = false;
        expect(store.clear(legacy.sessionId)).assertTrue();
        expect(adapter.raw(binding, 'host-a')).assertEqual('');
        expect(adapter.legacyRaw(binding)).assertEqual('');

        const rebound: MoonlightSessionRecoveryStore =
          new MoonlightSessionRecoveryStore();
        expect(rebound.bind(context, currentLease, 'host-a').code)
          .assertEqual('absent');
      });

    it('clears_only_after_an_explicit_clean_typed_native_terminal', 0, (): void => {
      const currentLease: AccountSessionLease = lease();
      const binding: MoonlightSessionRecoveryBinding =
        moonlightSessionRecoveryBinding(currentLease);
      const store: MoonlightSessionRecoveryStore = new MoonlightSessionRecoveryStore();
      expect(store.bind(context, currentLease, 'host-a').code).assertEqual('absent');
      const created: MoonlightSessionRecoveryMarker = store.begin({
        sessionId: '00112233445566778899aabbccddeeff',
        hostId: 'host-a', profileId: '', appId: '7'
      }, 1000) as MoonlightSessionRecoveryMarker;
      const runtime: MoonlightSessionRecoveryRuntime =
        new MoonlightSessionRecoveryRuntime();
      expect(runtime.bind(context, currentLease, created.sessionId,
        created.hostId, created.appId)).assertEqual('ready');
      expect(runtime.markerSnapshot()?.inputMayBeStuck).assertTrue();

      runtime.acceptNativeTerminal('owner-a', 1, 'host-a', '7',
        nativeTerminal('cancelled'), 1100);
      expect(adapter.raw(binding).length > 0).assertTrue();
      expect(runtime.markerSnapshot()?.lastStage).assertEqual('terminal_uncertain');

      expect(runtime.requestTerminal('disconnect', 1200)).assertTrue();
      runtime.acceptNativeTerminal('owner-a', 1, 'host-a', '7',
        nativeTerminal('cancelled'), 1300);
      expect(adapter.raw(binding)).assertEqual('');
      expect(runtime.markerSnapshot()).assertNull();
    });

    it('retains_foreign_or_input_unsafe_receipts_and_accepts_clean_network_terminal', 0,
      (): void => {
      const currentLease: AccountSessionLease = lease();
      const binding: MoonlightSessionRecoveryBinding =
        moonlightSessionRecoveryBinding(currentLease);
      const store: MoonlightSessionRecoveryStore = new MoonlightSessionRecoveryStore();
      store.bind(context, currentLease, 'host-a');
      const created: MoonlightSessionRecoveryMarker = store.begin({
        sessionId: '00112233445566778899aabbccddeeff',
        hostId: 'host-a', profileId: '', appId: '7'
      }, 1000) as MoonlightSessionRecoveryMarker;
      const runtime: MoonlightSessionRecoveryRuntime =
        new MoonlightSessionRecoveryRuntime();
      expect(runtime.bind(context, currentLease, created.sessionId,
        created.hostId, created.appId)).assertEqual('ready');
      expect(runtime.requestTerminal('disconnect', 1100)).assertTrue();

      runtime.acceptNativeTerminal('owner-b', 1, 'host-a', '7',
        nativeTerminal('cancelled'), 1200);
      expect(adapter.raw(binding).length > 0).assertTrue();
      runtime.acceptNativeTerminal('owner-a', 1, 'host-a', '7',
        nativeTerminal('connection_terminated', true), 1300);
      expect(adapter.raw(binding).length > 0).assertTrue();
      expect(runtime.markerSnapshot()?.lastStage).assertEqual('terminal_uncertain');
      expect(runtime.markerSnapshot()?.inputMayBeStuck).assertTrue();
      expect(runtime.markerSnapshot()?.lastRequestedTerminalAction)
        .assertEqual('disconnect');
      runtime.acceptNativeTerminal('owner-a', 1, 'host-a', '7',
        nativeTerminal('connection_terminated'), 1400);
      expect(adapter.raw(binding)).assertEqual('');
      expect(runtime.markerSnapshot()).assertNull();
    });

    it('requires_native_terminal_and_host_postcondition_before_clearing_quit', 0,
      (): void => {
        const currentLease: AccountSessionLease = lease();
        const binding: MoonlightSessionRecoveryBinding =
          moonlightSessionRecoveryBinding(currentLease);
        const store: MoonlightSessionRecoveryStore = new MoonlightSessionRecoveryStore();
        store.bind(context, currentLease, 'host-a');
        const created: MoonlightSessionRecoveryMarker = store.begin({
          sessionId: '00112233445566778899aabbccddeeff',
          hostId: 'host-a', profileId: '', appId: '7'
        }, 1000) as MoonlightSessionRecoveryMarker;
        const runtime: MoonlightSessionRecoveryRuntime =
          new MoonlightSessionRecoveryRuntime();
        expect(runtime.bind(context, currentLease, created.sessionId,
          created.hostId, created.appId)).assertEqual('ready');
        expect(runtime.requestTerminal('quit', 1100)).assertTrue();

        // A host receipt cannot bypass common-c teardown/input neutrality.
        expect(runtime.acceptHostQuitReceipt('owner-a', 1, 'host-a', '7', {
          code: 'ok', preflightTruth: 'confirmed', actionTruth: 'confirmed',
          postconditionTruth: 'confirmed', idempotent: false
        }, 1150)).assertFalse();
        expect(adapter.raw(binding).length > 0).assertTrue();

        runtime.acceptNativeTerminal('owner-a', 1, 'host-a', '7',
          nativeTerminal('cancelled'), 1200);
        expect(adapter.raw(binding).length > 0).assertTrue();
        expect(runtime.markerSnapshot()?.lastStage).assertEqual('terminal_pending');
        expect(runtime.markerSnapshot()?.inputMayBeStuck).assertFalse();

        expect(runtime.acceptHostQuitReceipt('owner-a', 1, 'host-a', '7', {
          code: 'ok', preflightTruth: 'confirmed', actionTruth: 'confirmed',
          postconditionTruth: 'confirmed', idempotent: false
        }, 1300)).assertTrue();
        expect(adapter.raw(binding)).assertEqual('');
        expect(runtime.markerSnapshot()).assertNull();
      });

    it('retains_host_uncertainty_after_a_clean_stream_terminal', 0, (): void => {
      const currentLease: AccountSessionLease = lease();
      const binding: MoonlightSessionRecoveryBinding =
        moonlightSessionRecoveryBinding(currentLease);
      const store: MoonlightSessionRecoveryStore = new MoonlightSessionRecoveryStore();
      store.bind(context, currentLease, 'host-a');
      const created: MoonlightSessionRecoveryMarker = store.begin({
        sessionId: 'ffeeddccbbaa99887766554433221100',
        hostId: 'host-a', profileId: '', appId: '7'
      }, 1000) as MoonlightSessionRecoveryMarker;
      const runtime: MoonlightSessionRecoveryRuntime =
        new MoonlightSessionRecoveryRuntime();
      expect(runtime.bind(context, currentLease, created.sessionId,
        created.hostId, created.appId)).assertEqual('ready');
      expect(runtime.requestTerminal('quit', 1100)).assertTrue();
      runtime.acceptNativeTerminal('owner-a', 1, 'host-a', '7',
        nativeTerminal('terminal'), 1200);
      expect(runtime.acceptHostQuitReceipt('owner-a', 1, 'host-a', '7', {
        code: 'outcome_unknown', preflightTruth: 'confirmed',
        actionTruth: 'unknown', postconditionTruth: 'unknown', idempotent: false
      }, 1300)).assertFalse();
      expect(adapter.raw(binding).length > 0).assertTrue();
      expect(runtime.markerSnapshot()?.lastStage).assertEqual('terminal_uncertain');
      expect(runtime.markerSnapshot()?.inputMayBeStuck).assertFalse();
      expect(runtime.markerSnapshot()?.lastRequestedTerminalAction).assertEqual('quit');
    });

    it('treats_a_never_started_runtime_as_an_explicit_input_neutral_boundary', 0,
      (): void => {
      const currentLease: AccountSessionLease = lease();
      const binding: MoonlightSessionRecoveryBinding =
        moonlightSessionRecoveryBinding(currentLease);
      const store: MoonlightSessionRecoveryStore = new MoonlightSessionRecoveryStore();
      store.bind(context, currentLease, 'host-a');
      const created: MoonlightSessionRecoveryMarker = store.begin({
        sessionId: '0123456789abcdeffedcba9876543210',
        hostId: 'host-a', profileId: '', appId: '7'
      }, 1000) as MoonlightSessionRecoveryMarker;
      const runtime: MoonlightSessionRecoveryRuntime =
        new MoonlightSessionRecoveryRuntime();
      expect(runtime.bind(context, currentLease, created.sessionId,
        created.hostId, created.appId)).assertEqual('ready');
      expect(runtime.requestTerminal('quit', 1100)).assertTrue();
      runtime.acceptNoRuntimeTerminal('owner-a', 1, 'host-a', '7', 1200);
      expect(runtime.markerSnapshot()?.lastStage).assertEqual('terminal_pending');
      expect(runtime.markerSnapshot()?.inputMayBeStuck).assertFalse();
      expect(runtime.acceptHostQuitReceipt('owner-a', 1, 'host-a', '7', {
        code: 'ok', preflightTruth: 'confirmed', actionTruth: 'not_attempted',
        postconditionTruth: 'confirmed', idempotent: true
      }, 1300)).assertTrue();
      expect(adapter.raw(binding)).assertEqual('');
    });
  });
}
