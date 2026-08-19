import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { AccountSessionLease } from './AccountScopePolicy';
import {
  MoonlightSessionRecoveryBinding,
  MoonlightSessionRecoveryDecodeResult,
  MoonlightSessionRecoveryMarker,
  MoonlightSessionRecoverySeed,
  MoonlightSessionRecoveryUpdate,
  createMoonlightSessionRecoveryMarker,
  decodeMoonlightSessionRecoveryMarker,
  encodeMoonlightSessionRecoveryMarker,
  moonlightSessionRecoveryBindingIsValid,
  moonlightSessionRecoveryMarkerMatchesBinding,
  updateMoonlightSessionRecoveryMarker
} from './MoonlightSessionRecoveryPolicy';
import {
  moonlightOwnerScopeShortId,
  moonlightStoreIdentityHash
} from './MoonlightRuntimeSupport';

export const MOONLIGHT_SESSION_RECOVERY_PREFERENCES_NAME: string =
  'RemoteDesktopMoonlightSessionRecoveryPrefsV1';

export interface MoonlightSessionRecoveryPreferenceRead {
  ok: boolean;
  value: string;
}

export interface MoonlightSessionRecoveryPreferenceAdapter {
  read(context: common.Context, storeName: string,
    key: string): MoonlightSessionRecoveryPreferenceRead;
  write(context: common.Context, storeName: string,
    key: string, value: string): boolean;
  remove(context: common.Context, storeName: string, key: string): boolean;
}

class HarmonyMoonlightSessionRecoveryPreferenceAdapter implements
  MoonlightSessionRecoveryPreferenceAdapter {
  read(context: common.Context, storeName: string,
    key: string): MoonlightSessionRecoveryPreferenceRead {
    try {
      const prefs = preferences.getPreferencesSync(context, { name: storeName });
      const value: Object = prefs.getSync(key, '') as Object;
      return typeof value === 'string' ?
        { ok: true, value: value as string } : { ok: false, value: '' };
    } catch (_error) { return { ok: false, value: '' }; }
  }

  write(context: common.Context, storeName: string,
    key: string, value: string): boolean {
    try {
      const prefs = preferences.getPreferencesSync(context, { name: storeName });
      prefs.putSync(key, value);
      prefs.flushSync();
      return true;
    } catch (_error) { return false; }
  }

  remove(context: common.Context, storeName: string, key: string): boolean {
    try {
      const prefs = preferences.getPreferencesSync(context, { name: storeName });
      prefs.deleteSync(key);
      prefs.flushSync();
      return true;
    } catch (_error) { return false; }
  }
}

let recoveryPreferenceAdapter: MoonlightSessionRecoveryPreferenceAdapter =
  new HarmonyMoonlightSessionRecoveryPreferenceAdapter();

export function setMoonlightSessionRecoveryPreferenceAdapterForTest(
  adapter: MoonlightSessionRecoveryPreferenceAdapter | null
): void {
  recoveryPreferenceAdapter = adapter === null ?
    new HarmonyMoonlightSessionRecoveryPreferenceAdapter() : adapter;
}

export function moonlightSessionRecoveryBinding(
  lease: AccountSessionLease
): MoonlightSessionRecoveryBinding {
  return {
    ownerScopeShortId: moonlightOwnerScopeShortId(lease.ownerScopeId),
    storeIdentityHash: moonlightStoreIdentityHash(lease.storeIdentity),
    storeGeneration: lease.generation
  };
}

export function moonlightSessionRecoveryPreferenceKey(
  binding: MoonlightSessionRecoveryBinding
): string {
  if (!moonlightSessionRecoveryBindingIsValid(binding)) { return ''; }
  return 'moonlight.session.recovery.v1:' + binding.ownerScopeShortId + ':' +
    binding.storeIdentityHash.slice(0, 32);
}

/**
 * Exact owner/store Preferences owner. Corrupt or too-new data remains intact
 * and blocks replacement until the current owner explicitly clears it.
 */
export class MoonlightSessionRecoveryStore {
  private context: common.Context | null = null;
  private binding: MoonlightSessionRecoveryBinding | null = null;
  private preferenceKey: string = '';
  private persistedRaw: string = '';
  private current: MoonlightSessionRecoveryMarker | null = null;
  private readable: boolean = false;
  private decodeCode: string = 'absent';

  bind(context: common.Context,
    lease: AccountSessionLease): MoonlightSessionRecoveryDecodeResult {
    const binding: MoonlightSessionRecoveryBinding =
      moonlightSessionRecoveryBinding(lease);
    const key: string = moonlightSessionRecoveryPreferenceKey(binding);
    this.context = context;
    this.binding = binding;
    this.preferenceKey = key;
    this.persistedRaw = '';
    this.current = null;
    this.readable = false;
    this.decodeCode = 'corrupt';
    if (key.length === 0) { return { code: 'corrupt', marker: null }; }
    const read: MoonlightSessionRecoveryPreferenceRead =
      recoveryPreferenceAdapter.read(
        context, MOONLIGHT_SESSION_RECOVERY_PREFERENCES_NAME, key);
    if (!read.ok) { return { code: 'corrupt', marker: null }; }
    this.persistedRaw = read.value;
    const decoded: MoonlightSessionRecoveryDecodeResult =
      decodeMoonlightSessionRecoveryMarker(read.value);
    this.decodeCode = decoded.code;
    if (decoded.code === 'absent') {
      this.readable = true;
      return decoded;
    }
    if (decoded.code !== 'ready' || decoded.marker === null ||
        !moonlightSessionRecoveryMarkerMatchesBinding(decoded.marker, binding)) {
      return decoded.code === 'ready' ?
        { code: 'corrupt', marker: null } : decoded;
    }
    this.current = decoded.marker;
    this.readable = true;
    return { code: 'ready', marker: this.clone(decoded.marker) };
  }

  snapshot(): MoonlightSessionRecoveryDecodeResult {
    if (!this.readable) {
      return { code: this.decodeCode === 'too_new' ? 'too_new' : 'corrupt', marker: null };
    }
    return this.current === null ? { code: 'absent', marker: null } :
      { code: 'ready', marker: this.clone(this.current) };
  }

  begin(seed: MoonlightSessionRecoverySeed,
    nowMs: number): MoonlightSessionRecoveryMarker | null {
    if (!this.readyToMutate() || this.current !== null) { return null; }
    const marker: MoonlightSessionRecoveryMarker | null =
      createMoonlightSessionRecoveryMarker(
        this.binding as MoonlightSessionRecoveryBinding, seed, nowMs);
    if (marker === null || !this.persist(marker)) { return null; }
    this.current = marker;
    return this.clone(marker);
  }

  update(sessionId: string,
    update: MoonlightSessionRecoveryUpdate): MoonlightSessionRecoveryMarker | null {
    if (!this.readyToMutate() || this.current === null ||
        this.current.sessionId !== sessionId.trim().toLowerCase()) { return null; }
    const next: MoonlightSessionRecoveryMarker | null =
      updateMoonlightSessionRecoveryMarker(this.current, update);
    if (next === null) { return null; }
    const unchanged: boolean = encodeMoonlightSessionRecoveryMarker(next) ===
      encodeMoonlightSessionRecoveryMarker(this.current);
    if (!unchanged && !this.persist(next)) { return null; }
    this.current = next;
    return this.clone(next);
  }

  clear(sessionId: string = ''): boolean {
    if (!this.readyToMutate()) { return false; }
    const expected: string = sessionId.trim().toLowerCase();
    if (expected.length > 0 &&
        (this.current === null || this.current.sessionId !== expected)) { return false; }
    if (this.persistedRaw.length === 0 && this.current === null) { return true; }
    if (!recoveryPreferenceAdapter.remove(
      this.context as common.Context,
      MOONLIGHT_SESSION_RECOVERY_PREFERENCES_NAME, this.preferenceKey)) {
      return false;
    }
    this.persistedRaw = '';
    this.current = null;
    this.decodeCode = 'absent';
    return true;
  }

  /** Explicit repair for malformed/too-new current-owner state only. */
  clearUnreadable(): boolean {
    if (this.context === null || this.preferenceKey.length === 0 || this.readable) {
      return false;
    }
    if (!recoveryPreferenceAdapter.remove(
      this.context, MOONLIGHT_SESSION_RECOVERY_PREFERENCES_NAME,
      this.preferenceKey)) { return false; }
    this.persistedRaw = '';
    this.current = null;
    this.readable = true;
    this.decodeCode = 'absent';
    return true;
  }

  private readyToMutate(): boolean {
    return this.context !== null && this.binding !== null &&
      this.preferenceKey.length > 0 && this.readable;
  }

  private persist(marker: MoonlightSessionRecoveryMarker): boolean {
    const raw: string = encodeMoonlightSessionRecoveryMarker(marker);
    if (raw.length === 0 || this.context === null) { return false; }
    if (recoveryPreferenceAdapter.write(
      this.context, MOONLIGHT_SESSION_RECOVERY_PREFERENCES_NAME,
      this.preferenceKey, raw)) {
      this.persistedRaw = raw;
      this.decodeCode = 'ready';
      return true;
    }
    // Restore the previous durable truth best-effort; never publish the new
    // in-memory marker after an uncertain Preferences flush.
    if (this.persistedRaw.length > 0) {
      recoveryPreferenceAdapter.write(
        this.context, MOONLIGHT_SESSION_RECOVERY_PREFERENCES_NAME,
        this.preferenceKey, this.persistedRaw);
    } else {
      recoveryPreferenceAdapter.remove(
        this.context, MOONLIGHT_SESSION_RECOVERY_PREFERENCES_NAME,
        this.preferenceKey);
    }
    return false;
  }

  private clone(marker: MoonlightSessionRecoveryMarker): MoonlightSessionRecoveryMarker {
    return {
      markerVersion: marker.markerVersion,
      ownerScopeShortId: marker.ownerScopeShortId,
      storeIdentityHash: marker.storeIdentityHash,
      storeGenerationAtLaunch: marker.storeGenerationAtLaunch,
      sessionId: marker.sessionId,
      hostId: marker.hostId,
      profileId: marker.profileId,
      appId: marker.appId,
      protocolCompatUniqueId: marker.protocolCompatUniqueId,
      launchedAt: marker.launchedAt,
      lastStage: marker.lastStage,
      lastHeartbeatAt: marker.lastHeartbeatAt,
      hostAppMayStillBeRunning: marker.hostAppMayStillBeRunning,
      inputMayBeStuck: marker.inputMayBeStuck,
      lastRequestedTerminalAction: marker.lastRequestedTerminalAction
    };
  }
}
