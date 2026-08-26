import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import {
  SshForwardingProfile,
  validateSshForwardingProfiles
} from './SshForwardingPolicy';

export const SSH_FORWARDING_PROFILE_PREFERENCES_NAME: string = 'RemoteDesktopSshForwardingProfilePrefs';
const SSH_FORWARDING_PROFILE_KEY_PREFIX: string = 'ssh.forwarding.profiles.v1:';

export interface SshForwardingProfilesEnvelopeV1 {
  schemaVersion: 1;
  profiles: SshForwardingProfile[];
  updatedAtMs: number;
}
export interface SshForwardingPreferenceRead { ok: boolean; value: string; }
export interface SshForwardingPreferenceAdapter {
  read(context: common.Context, storeName: string, key: string): SshForwardingPreferenceRead;
  write(context: common.Context, storeName: string, key: string, value: string): boolean;
  remove(context: common.Context, storeName: string, key: string): boolean;
}

class HarmonySshForwardingPreferenceAdapter implements SshForwardingPreferenceAdapter {
  read(context: common.Context, storeName: string, key: string): SshForwardingPreferenceRead {
    try {
      const prefs = preferences.getPreferencesSync(context, { name: storeName });
      const value: Object = prefs.getSync(key, '') as Object;
      return typeof value === 'string' ? { ok: true, value: value as string } : { ok: false, value: '' };
    } catch (_err) { return { ok: false, value: '' }; }
  }
  write(context: common.Context, storeName: string, key: string, value: string): boolean {
    try {
      const prefs = preferences.getPreferencesSync(context, { name: storeName });
      prefs.putSync(key, value); prefs.flushSync(); return true;
    } catch (_err) { return false; }
  }
  remove(context: common.Context, storeName: string, key: string): boolean {
    try {
      const prefs = preferences.getPreferencesSync(context, { name: storeName });
      prefs.deleteSync(key); prefs.flushSync(); return true;
    } catch (_err) { return false; }
  }
}

let forwardingPreferenceAdapter: SshForwardingPreferenceAdapter =
  new HarmonySshForwardingPreferenceAdapter();

export function setSshForwardingPreferenceAdapterForTest(
  adapter: SshForwardingPreferenceAdapter | null
): void {
  forwardingPreferenceAdapter = adapter === null
    ? new HarmonySshForwardingPreferenceAdapter() : adapter;
}

export function forwardingProfilePreferenceKey(ownerHostId: string): string {
  return SSH_FORWARDING_PROFILE_KEY_PREFIX + encodeURIComponent(ownerHostId.trim());
}

const PROFILE_KEYS: string[] = [
  'id', 'mode', 'bindHost', 'bindPort', 'targetHost', 'targetPort', 'maxConnections',
  'enabled', 'startPolicy', 'allowPublicBind', 'minBindPort', 'maxBindPort', 'maxBytes', 'expiresAtMs'
];

function hasOnlyProfileKeys(profile: SshForwardingProfile): boolean {
  const keys: string[] = Object.keys(profile as Object);
  for (let index: number = 0; index < keys.length; index++) {
    if (PROFILE_KEYS.indexOf(keys[index]) < 0) { return false; }
  }
  return true;
}

function validTimestamp(value: number): boolean {
  return Number.isFinite(value) && Number.isInteger(value) && value >= 0;
}

export function serializeSshForwardingProfilesEnvelope(
  envelope: SshForwardingProfilesEnvelopeV1
): string | null {
  const raw: Object = envelope as Object;
  const record: Record<string, Object> = raw as Record<string, Object>;
  const keys: string[] = Object.keys(record);
  if (keys.some((key: string): boolean =>
    ['schemaVersion', 'profiles', 'updatedAtMs'].indexOf(key) < 0) ||
    record['schemaVersion'] !== 1 || !Array.isArray(record['profiles']) ||
    typeof record['updatedAtMs'] !== 'number' || !validTimestamp(record['updatedAtMs'] as number)) {
    return null;
  }
  const profiles: SshForwardingProfile[] = record['profiles'] as SshForwardingProfile[];
  for (let index: number = 0; index < profiles.length; index++) {
    if (!hasOnlyProfileKeys(profiles[index])) { return null; }
  }
  const validation = validateSshForwardingProfiles(profiles);
  if (!validation.valid) { return null; }
  try {
    return JSON.stringify({ schemaVersion: 1, profiles: validation.profiles, updatedAtMs: record['updatedAtMs'] });
  } catch (_err) { return null; }
}

export function deserializeSshForwardingProfilesEnvelope(
  raw: string
): SshForwardingProfilesEnvelopeV1 | null {
  try {
    if (raw.trim().length === 0) {
      return { schemaVersion: 1, profiles: [], updatedAtMs: 0 };
    }
    const parsed: Object = JSON.parse(raw) as Object;
    const record: Record<string, Object> = parsed as Record<string, Object>;
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) { return null; }
    const keys: string[] = Object.keys(record);
    if (keys.some((key: string): boolean =>
      ['schemaVersion', 'profiles', 'updatedAtMs'].indexOf(key) < 0) ||
      record['schemaVersion'] !== 1 || !Array.isArray(record['profiles']) ||
      typeof record['updatedAtMs'] !== 'number' || !validTimestamp(record['updatedAtMs'] as number)) {
      return null;
    }
    const profiles: SshForwardingProfile[] = record['profiles'] as SshForwardingProfile[];
    for (let index: number = 0; index < profiles.length; index++) {
      if (!hasOnlyProfileKeys(profiles[index])) { return null; }
    }
    const validation = validateSshForwardingProfiles(profiles);
    return validation.valid ? {
      schemaVersion: 1, profiles: validation.profiles,
      updatedAtMs: record['updatedAtMs'] as number
    } : null;
  } catch (_err) { return null; }
}

interface OwnerState {
  profiles: SshForwardingProfile[];
  raw: string;
  readable: boolean;
}

function cloneProfile(profile: SshForwardingProfile): SshForwardingProfile {
  return {
    id: profile.id, mode: profile.mode, bindHost: profile.bindHost, bindPort: profile.bindPort,
    targetHost: profile.targetHost, targetPort: profile.targetPort,
    maxConnections: profile.maxConnections, enabled: profile.enabled,
    startPolicy: profile.startPolicy, allowPublicBind: profile.allowPublicBind,
    minBindPort: profile.minBindPort, maxBindPort: profile.maxBindPort,
    maxBytes: profile.maxBytes, expiresAtMs: profile.expiresAtMs
  };
}

export class SshForwardingProfileStore {
  private context: common.Context | null = null;
  private initialized: boolean = false;
  private readonly owners: Map<string, OwnerState> = new Map<string, OwnerState>();

  init(context: common.Context): boolean {
    this.context = context; this.initialized = true; this.owners.clear(); return true;
  }

  load(ownerHostId: string): SshForwardingProfile[] {
    const state: OwnerState | null = this.owner(ownerHostId);
    return state === null || !state.readable ? [] : state.profiles.map(cloneProfile);
  }

  list(ownerHostId: string): SshForwardingProfile[] { return this.load(ownerHostId); }

  upsert(ownerHostId: string, profile: SshForwardingProfile): boolean {
    const owner: string = ownerHostId.trim();
    const state: OwnerState | null = this.owner(owner);
    if (state === null || !state.readable || !hasOnlyProfileKeys(profile)) { return false; }
    const validation = validateSshForwardingProfiles([profile]);
    if (!validation.valid) { return false; }
    const next: SshForwardingProfile[] = state.profiles.slice();
    const index: number = next.findIndex((item: SshForwardingProfile): boolean => item.id === validation.profiles[0].id);
    if (index >= 0) { next[index] = validation.profiles[0]; } else { next.push(validation.profiles[0]); }
    return this.persist(owner, state, next);
  }

  remove(ownerHostId: string, id: string): boolean {
    const owner: string = ownerHostId.trim();
    const state: OwnerState | null = this.owner(owner);
    if (state === null || !state.readable) { return false; }
    const next: SshForwardingProfile[] = state.profiles.filter((item): boolean => item.id !== id.trim());
    return next.length === state.profiles.length ? true : this.persist(owner, state, next);
  }

  clear(ownerHostId: string): boolean {
    const owner: string = ownerHostId.trim();
    const state: OwnerState | null = this.owner(owner);
    if (state === null || !state.readable) { return false; }
    if (state.profiles.length === 0) { return true; }
    if (!forwardingPreferenceAdapter.remove(this.context as common.Context,
      SSH_FORWARDING_PROFILE_PREFERENCES_NAME, forwardingProfilePreferenceKey(owner))) { return false; }
    state.profiles = []; state.raw = ''; return true;
  }

  private owner(ownerHostId: string): OwnerState | null {
    const owner: string = ownerHostId.trim();
    if (!this.initialized || owner.length === 0) { return null; }
    const cached: OwnerState | undefined = this.owners.get(owner);
    if (cached !== undefined) { return cached; }
    const key: string = forwardingProfilePreferenceKey(owner);
    const read: SshForwardingPreferenceRead = forwardingPreferenceAdapter.read(
      this.context as common.Context, SSH_FORWARDING_PROFILE_PREFERENCES_NAME, key);
    if (!read.ok) { return null; }
    const parsed: SshForwardingProfilesEnvelopeV1 | null = deserializeSshForwardingProfilesEnvelope(read.value);
    const state: OwnerState = { profiles: parsed === null ? [] : parsed.profiles, raw: read.value, readable: parsed !== null };
    this.owners.set(owner, state);
    return state;
  }

  private persist(owner: string, state: OwnerState, profiles: SshForwardingProfile[]): boolean {
    const envelope: SshForwardingProfilesEnvelopeV1 = {
      schemaVersion: 1, profiles, updatedAtMs: Date.now()
    };
    const snapshot: string | null = serializeSshForwardingProfilesEnvelope(envelope);
    if (snapshot === null) { return false; }
    const key: string = forwardingProfilePreferenceKey(owner);
    if (!forwardingPreferenceAdapter.write(this.context as common.Context,
      SSH_FORWARDING_PROFILE_PREFERENCES_NAME, key, snapshot)) {
      if (state.raw.length > 0) {
        forwardingPreferenceAdapter.write(this.context as common.Context,
          SSH_FORWARDING_PROFILE_PREFERENCES_NAME, key, state.raw);
      } else {
        forwardingPreferenceAdapter.remove(this.context as common.Context,
          SSH_FORWARDING_PROFILE_PREFERENCES_NAME, key);
      }
      return false;
    }
    state.profiles = profiles; state.raw = snapshot; return true;
  }
}
