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
 * Current recovery owner: one marker per exact owner/store/host route.
 *
 * Sunshine owns one running application per host, so applications on the same
 * host deliberately share a recovery boundary. Different hosts must never
 * block one another merely because an older build used one account-wide key.
 */
export function moonlightSessionRecoveryHostPreferenceKey(
  binding: MoonlightSessionRecoveryBinding,
  hostId: string
): string {
  const normalizedHostId: string = hostId.trim();
  if (!moonlightSessionRecoveryBindingIsValid(binding) ||
      normalizedHostId.length === 0 || normalizedHostId.length > 128) {
    return '';
  }
  const hostHash: string = moonlightStoreIdentityHash(
    'RemoteDeskHarmonyOS:moonlight-recovery-host:v2:' + normalizedHostId);
  if (hostHash.length !== 64) { return ''; }
  return 'moonlight.session.recovery.v2:' + binding.ownerScopeShortId + ':' +
    binding.storeIdentityHash.slice(0, 32) + ':' + hostHash.slice(0, 32);
}

/**
 * Exact owner/store/host Preferences owner. Corrupt or too-new data in the
 * current host route remains intact until explicitly cleared. The legacy
 * owner/store-wide key is migrated only when its decoded host matches this
 * route; foreign or unreadable legacy state is preserved but cannot block a
 * different host.
 */
export class MoonlightSessionRecoveryStore {
  private context: common.Context | null = null;
  private binding: MoonlightSessionRecoveryBinding | null = null;
  private preferenceKey: string = '';
  private legacyPreferenceKey: string = '';
  private migratedLegacyShadowRaw: string = '';
  private hostId: string = '';
  private persistedRaw: string = '';
  private current: MoonlightSessionRecoveryMarker | null = null;
  private readable: boolean = false;
  private decodeCode: string = 'absent';

  bind(context: common.Context, lease: AccountSessionLease,
    hostId: string): MoonlightSessionRecoveryDecodeResult {
    const binding: MoonlightSessionRecoveryBinding =
      moonlightSessionRecoveryBinding(lease);
    const normalizedHostId: string = hostId.trim();
    const key: string = moonlightSessionRecoveryHostPreferenceKey(
      binding, normalizedHostId);
    this.context = context;
    this.binding = binding;
    this.preferenceKey = key;
    this.legacyPreferenceKey = moonlightSessionRecoveryPreferenceKey(binding);
    this.migratedLegacyShadowRaw = '';
    this.hostId = normalizedHostId;
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
      return this.readAndMigrateLegacy();
    }
    if (decoded.code !== 'ready' || decoded.marker === null ||
        !moonlightSessionRecoveryMarkerMatchesBinding(decoded.marker, binding) ||
        decoded.marker.hostId !== normalizedHostId) {
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
    if (!this.readyToMutate() || this.current !== null ||
        seed.hostId.trim() !== this.hostId) { return null; }
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
    // If an upgrade successfully established the v2 host key but could not
    // remove its matching v1 shadow, clear the shadow first. Otherwise a
    // later bind could resurrect the already-finished session from v1.
    if (this.migratedLegacyShadowRaw.length > 0 &&
        !recoveryPreferenceAdapter.remove(
          this.context as common.Context,
          MOONLIGHT_SESSION_RECOVERY_PREFERENCES_NAME,
          this.legacyPreferenceKey)) {
      return false;
    }
    this.migratedLegacyShadowRaw = '';
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
      this.preferenceKey.length > 0 && this.hostId.length > 0 && this.readable;
  }

  private readAndMigrateLegacy(): MoonlightSessionRecoveryDecodeResult {
    if (this.context === null || this.binding === null ||
        this.legacyPreferenceKey.length === 0) {
      return { code: 'corrupt', marker: null };
    }
    const legacyRead: MoonlightSessionRecoveryPreferenceRead =
      recoveryPreferenceAdapter.read(
        this.context, MOONLIGHT_SESSION_RECOVERY_PREFERENCES_NAME,
        this.legacyPreferenceKey);
    if (!legacyRead.ok) { return { code: 'corrupt', marker: null }; }
    const legacy: MoonlightSessionRecoveryDecodeResult =
      decodeMoonlightSessionRecoveryMarker(legacyRead.value);
    // An owner-wide record from an older build has no safe route when it is
    // unreadable. Preserve it for forward compatibility, but do not let that
    // ambiguity deadlock every host in the account.
    if (legacy.code !== 'ready' || legacy.marker === null ||
        !moonlightSessionRecoveryMarkerMatchesBinding(
          legacy.marker, this.binding) || legacy.marker.hostId !== this.hostId) {
      this.readable = true;
      this.decodeCode = 'absent';
      return { code: 'absent', marker: null };
    }
    const raw: string = encodeMoonlightSessionRecoveryMarker(legacy.marker);
    if (raw.length === 0 || !recoveryPreferenceAdapter.write(
      this.context, MOONLIGHT_SESSION_RECOVERY_PREFERENCES_NAME,
      this.preferenceKey, raw)) {
      // The exact old record still protects this host. Do not start a second
      // session when migration itself could not be made durable.
      this.decodeCode = 'corrupt';
      return { code: 'corrupt', marker: null };
    }
    this.persistedRaw = raw;
    this.current = legacy.marker;
    this.readable = true;
    this.decodeCode = 'ready';
    // Route-key durability is already established. Legacy cleanup is best
    // effort so an interrupted upgrade cannot lose recovery truth.
    const legacyRemoved: boolean = recoveryPreferenceAdapter.remove(
      this.context, MOONLIGHT_SESSION_RECOVERY_PREFERENCES_NAME,
      this.legacyPreferenceKey);
    this.migratedLegacyShadowRaw = legacyRemoved ? '' : raw;
    return { code: 'ready', marker: this.clone(legacy.marker) };
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
