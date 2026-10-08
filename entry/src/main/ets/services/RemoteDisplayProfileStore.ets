import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import {
  RemoteDisplayDeviceScope,
  RemoteDisplayOrientationScope,
  RemoteDisplayProfile,
  RemoteDisplayProtocol,
  isRdpDeviceScalePercent,
  normalizeRdpDesktopScalePercent,
  validateRemoteDisplayGeometry
} from './RemoteDisplayProfilePolicy';

export const REMOTE_DISPLAY_PROFILE_STORAGE_NAME: string = 'RemoteDesktopAppPrefs';
export const REMOTE_DISPLAY_PROFILE_STORAGE_KEY_PREFIX: string = 'remoteDisplayProfile.v1:';
export const REMOTE_DISPLAY_PROFILE_LEGACY_MIGRATION_KEY_PREFIX: string =
  'remoteDisplayProfile.v1:legacy-migration:';

export interface RemoteDisplayProfileScope {
  ownerScopeId: string;
  hostId: string;
  protocol: RemoteDisplayProtocol;
  deviceScope: RemoteDisplayDeviceScope;
  displayScope: string;
  orientationScope: RemoteDisplayOrientationScope;
}

export interface RemoteDisplayProfileMigrationScope {
  ownerScopeId: string;
  deviceScope: RemoteDisplayDeviceScope;
}

export interface RemoteDisplayProfileEnvelopeV1 {
  schemaVersion: 1;
  profile: RemoteDisplayProfile;
}

export interface RemoteDisplayProfilePreferenceRead {
  ok: boolean;
  value: string;
}

export interface RemoteDisplayProfilePreferenceAdapter {
  read(context: common.Context, storeName: string, key: string): RemoteDisplayProfilePreferenceRead;
  write(context: common.Context, storeName: string, key: string, value: string): boolean;
  remove(context: common.Context, storeName: string, key: string): boolean;
}

class HarmonyRemoteDisplayProfilePreferenceAdapter implements RemoteDisplayProfilePreferenceAdapter {
  read(context: common.Context, storeName: string, key: string): RemoteDisplayProfilePreferenceRead {
    try {
      const prefs = preferences.getPreferencesSync(context, { name: storeName });
      const raw: Object = prefs.getSync(key, '') as Object;
      return typeof raw === 'string' ? { ok: true, value: raw as string } : { ok: false, value: '' };
    } catch (_error) {
      return { ok: false, value: '' };
    }
  }

  write(context: common.Context, storeName: string, key: string, value: string): boolean {
    try {
      const prefs = preferences.getPreferencesSync(context, { name: storeName });
      prefs.putSync(key, value);
      prefs.flushSync();
      return true;
    } catch (_error) {
      return false;
    }
  }

  remove(context: common.Context, storeName: string, key: string): boolean {
    try {
      const prefs = preferences.getPreferencesSync(context, { name: storeName });
      prefs.deleteSync(key);
      prefs.flushSync();
      return true;
    } catch (_error) {
      return false;
    }
  }
}

let remoteDisplayProfilePreferenceAdapter: RemoteDisplayProfilePreferenceAdapter =
  new HarmonyRemoteDisplayProfilePreferenceAdapter();

export function setRemoteDisplayProfilePreferenceAdapterForTest(
  adapter: RemoteDisplayProfilePreferenceAdapter | null
): void {
  remoteDisplayProfilePreferenceAdapter = adapter === null ?
    new HarmonyRemoteDisplayProfilePreferenceAdapter() : adapter;
}

function nonEmpty(value: string, maximum: number): boolean {
  return typeof value === 'string' && value.trim().length > 0 && value.trim().length <= maximum;
}

function validTimestamp(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0;
}

function validDeviceScope(value: string): boolean {
  return value === 'phone' || value === 'tablet' || value === 'pc' || value === 'unknown';
}

function validOrientationScope(value: string): boolean {
  return value === 'landscape' || value === 'portrait' || value === 'any';
}

function validProfileScope(scope: RemoteDisplayProfileScope): boolean {
  return nonEmpty(scope.ownerScopeId, 256) && nonEmpty(scope.hostId, 256) &&
    (scope.protocol === 'rdp' || scope.protocol === 'rustdesk') &&
    validDeviceScope(scope.deviceScope) && nonEmpty(scope.displayScope, 128) &&
    validOrientationScope(scope.orientationScope);
}

function validMigrationScope(scope: RemoteDisplayProfileMigrationScope): boolean {
  return nonEmpty(scope.ownerScopeId, 256) && validDeviceScope(scope.deviceScope);
}

function validResolutionMode(value: string): boolean {
  return value === 'auto' || value === 'preset' || value === 'custom';
}

function validDesktopScaleMode(value: string): boolean {
  return value === 'auto' || value === 'preset' || value === 'custom';
}

function validDeviceScaleMode(value: string): boolean {
  return value === 'auto' || value === 'fixed';
}

function cloneProfile(profile: RemoteDisplayProfile): RemoteDisplayProfile {
  return {
    schemaVersion: 1,
    profileId: profile.profileId,
    hostId: profile.hostId,
    protocol: profile.protocol,
    targetDisplay: profile.targetDisplay,
    deviceScope: profile.deviceScope,
    displayScope: profile.displayScope,
    orientationScope: profile.orientationScope,
    resolution: {
      mode: profile.resolution.mode,
      presetId: profile.resolution.presetId,
      width: profile.resolution.width,
      height: profile.resolution.height
    },
    rdpScale: {
      desktopMode: profile.rdpScale.desktopMode,
      desktopPercent: profile.rdpScale.desktopPercent,
      deviceMode: profile.rdpScale.deviceMode,
      devicePercent: profile.rdpScale.devicePercent
    },
    localViewMode: profile.localViewMode,
    localViewCustomPercent: profile.localViewCustomPercent,
    createdAt: profile.createdAt,
    updatedAt: profile.updatedAt
  };
}

export function normalizeRemoteDisplayProfile(profile: RemoteDisplayProfile): RemoteDisplayProfile | null {
  const raw: Object = profile as Object;
  if (profile === null || typeof profile !== 'object' || Array.isArray(raw)) {
    return null;
  }
  const record: Record<string, Object> = raw as Record<string, Object>;
  const rawResolution: Object = record['resolution'];
  const rawScale: Object = record['rdpScale'];
  if (rawResolution === null || typeof rawResolution !== 'object' || Array.isArray(rawResolution) ||
      rawScale === null || typeof rawScale !== 'object' || Array.isArray(rawScale)) {
    return null;
  }
  if (profile.schemaVersion !== 1 ||
      !nonEmpty(profile.profileId, 128) || !nonEmpty(profile.hostId, 256) ||
      (profile.protocol !== 'rdp' && profile.protocol !== 'rustdesk') ||
      !Number.isSafeInteger(profile.targetDisplay) || profile.targetDisplay < -1 ||
      !validDeviceScope(profile.deviceScope) || !nonEmpty(profile.displayScope, 128) ||
      !validOrientationScope(profile.orientationScope) || !validResolutionMode(profile.resolution.mode) ||
      !nonEmpty(profile.resolution.presetId, 128) ||
      !validDesktopScaleMode(profile.rdpScale.desktopMode) ||
      !validDeviceScaleMode(profile.rdpScale.deviceMode) ||
      !validTimestamp(profile.createdAt) || !validTimestamp(profile.updatedAt) ||
      profile.updatedAt < profile.createdAt || !nonEmpty(profile.localViewMode, 32) ||
      !Number.isFinite(profile.localViewCustomPercent)) {
    return null;
  }
  const geometry = validateRemoteDisplayGeometry(profile.resolution.width, profile.resolution.height);
  if (!geometry.accepted || !Number.isSafeInteger(profile.resolution.width) ||
      !Number.isSafeInteger(profile.resolution.height) ||
      profile.rdpScale.desktopPercent !== normalizeRdpDesktopScalePercent(profile.rdpScale.desktopPercent) ||
      !isRdpDeviceScalePercent(profile.rdpScale.devicePercent)) {
    return null;
  }
  return cloneProfile(profile);
}

export function remoteDisplayProfileStorageKey(scope: RemoteDisplayProfileScope): string {
  const parts: string[] = [
    scope.ownerScopeId.trim(), scope.hostId.trim(), scope.protocol, scope.deviceScope,
    scope.displayScope.trim(), scope.orientationScope
  ];
  return REMOTE_DISPLAY_PROFILE_STORAGE_KEY_PREFIX + encodeURIComponent(parts.join('|'));
}

export function remoteDisplayProfileLegacyMigrationKey(
  scope: RemoteDisplayProfileMigrationScope
): string {
  return REMOTE_DISPLAY_PROFILE_LEGACY_MIGRATION_KEY_PREFIX + encodeURIComponent(
    scope.ownerScopeId.trim() + '|' + scope.deviceScope);
}

export function serializeRemoteDisplayProfileEnvelope(
  profile: RemoteDisplayProfile
): string | null {
  const normalized: RemoteDisplayProfile | null = normalizeRemoteDisplayProfile(profile);
  if (normalized === null) { return null; }
  try {
    return JSON.stringify({ schemaVersion: 1, profile: normalized });
  } catch (_error) {
    return null;
  }
}

export function deserializeRemoteDisplayProfileEnvelope(
  raw: string
): RemoteDisplayProfile | null {
  try {
    if (raw.trim().length === 0) { return null; }
    const parsed: Object = JSON.parse(raw) as Object;
    const record: Record<string, Object> = parsed as Record<string, Object>;
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed) ||
        record['schemaVersion'] !== 1 || record['profile'] === null ||
        typeof record['profile'] !== 'object') {
      return null;
    }
    return normalizeRemoteDisplayProfile(record['profile'] as RemoteDisplayProfile);
  } catch (_error) {
    return null;
  }
}

interface CachedProfile {
  readable: boolean;
  profile: RemoteDisplayProfile | null;
}

export class RemoteDisplayProfileStore {
  private context: common.Context | null = null;
  private initialized: boolean = false;
  private readonly cache: Map<string, CachedProfile> = new Map<string, CachedProfile>();
  private readonly legacyFallbackBlocked: Set<string> = new Set<string>();

  init(context: common.Context): boolean {
    this.context = context;
    this.initialized = true;
    this.cache.clear();
    this.legacyFallbackBlocked.clear();
    return true;
  }

  load(scope: RemoteDisplayProfileScope): RemoteDisplayProfile | null {
    if (!this.initialized || this.context === null || !validProfileScope(scope)) {
      return null;
    }
    const key: string = remoteDisplayProfileStorageKey(scope);
    const cached: CachedProfile | undefined = this.cache.get(key);
    if (cached !== undefined) {
      return cached.profile === null ? null : cloneProfile(cached.profile);
    }
    const read: RemoteDisplayProfilePreferenceRead = remoteDisplayProfilePreferenceAdapter.read(
      this.context, REMOTE_DISPLAY_PROFILE_STORAGE_NAME, key);
    if (!read.ok) {
      this.cache.set(key, { readable: false, profile: null });
      return null;
    }
    const profile: RemoteDisplayProfile | null = deserializeRemoteDisplayProfileEnvelope(read.value);
    if (profile === null || profile.protocol !== scope.protocol ||
        profile.hostId !== scope.hostId.trim() ||
        profile.deviceScope !== scope.deviceScope || profile.displayScope !== scope.displayScope ||
        profile.orientationScope !== scope.orientationScope) {
      this.cache.set(key, { readable: profile === null, profile: null });
      return null;
    }
    this.cache.set(key, { readable: true, profile });
    return cloneProfile(profile);
  }

  upsert(scope: RemoteDisplayProfileScope, profile: RemoteDisplayProfile): boolean {
    if (!this.initialized || this.context === null || !validProfileScope(scope) ||
      profile.protocol !== scope.protocol || profile.hostId !== scope.hostId.trim() ||
        profile.deviceScope !== scope.deviceScope || profile.displayScope !== scope.displayScope ||
        profile.orientationScope !== scope.orientationScope) {
      return false;
    }
    const snapshot: string | null = serializeRemoteDisplayProfileEnvelope(profile);
    if (snapshot === null) { return false; }
    const key: string = remoteDisplayProfileStorageKey(scope);
    if (!remoteDisplayProfilePreferenceAdapter.write(
      this.context, REMOTE_DISPLAY_PROFILE_STORAGE_NAME, key, snapshot)) {
      return false;
    }
    this.cache.set(key, { readable: true, profile: deserializeRemoteDisplayProfileEnvelope(snapshot) });
    return true;
  }

  /**
   * Legacy global display preferences may seed exactly one scoped profile per
   * account/device.  Once consumed, a newly seen host starts from safe Auto
   * defaults instead of inheriting another host's last global values.
   */
  legacyFallbackConsumed(scope: RemoteDisplayProfileMigrationScope): boolean {
    if (!this.initialized || this.context === null || !validMigrationScope(scope)) {
      return true;
    }
    const key: string = remoteDisplayProfileLegacyMigrationKey(scope);
    if (this.legacyFallbackBlocked.has(key)) {
      return true;
    }
    const read: RemoteDisplayProfilePreferenceRead = remoteDisplayProfilePreferenceAdapter.read(
      this.context, REMOTE_DISPLAY_PROFILE_STORAGE_NAME, key);
    if (!read.ok) {
      this.legacyFallbackBlocked.add(key);
      return true;
    }
    return read.value === '1';
  }

  markLegacyFallbackConsumed(scope: RemoteDisplayProfileMigrationScope): boolean {
    if (!this.initialized || this.context === null || !validMigrationScope(scope)) {
      return false;
    }
    const key: string = remoteDisplayProfileLegacyMigrationKey(scope);
    if (this.legacyFallbackBlocked.has(key)) {
      return false;
    }
    const written: boolean = remoteDisplayProfilePreferenceAdapter.write(
      this.context, REMOTE_DISPLAY_PROFILE_STORAGE_NAME, key, '1');
    if (!written) {
      // A failed marker write means the legacy value cannot be safely claimed.
      // Keep this scope fail-closed for the rest of the process.
      this.legacyFallbackBlocked.add(key);
    }
    return written;
  }

  tryClaimLegacyFallback(scope: RemoteDisplayProfileMigrationScope): boolean {
    if (this.legacyFallbackConsumed(scope)) {
      return false;
    }
    return this.markLegacyFallbackConsumed(scope);
  }

  remove(scope: RemoteDisplayProfileScope): boolean {
    if (!this.initialized || this.context === null || !validProfileScope(scope)) { return false; }
    const key: string = remoteDisplayProfileStorageKey(scope);
    if (!remoteDisplayProfilePreferenceAdapter.remove(
      this.context, REMOTE_DISPLAY_PROFILE_STORAGE_NAME, key)) {
      return false;
    }
    this.cache.delete(key);
    return true;
  }
}
