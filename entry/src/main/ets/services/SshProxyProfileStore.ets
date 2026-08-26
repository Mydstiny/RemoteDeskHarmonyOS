import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import {
  SshProxyHopMetadataV1,
  SshProxyProfileV1,
  deserializeSshProxyProfiles,
  serializeSshProxyProfiles
} from './SshProxyProfilePolicy';
import { SshJumpHop } from '../types/rdpnapi';

export const SSH_PROXY_PROFILE_PREFERENCES_NAME: string = 'RemoteDesktopSshProxyProfilePrefs';
export const SSH_PROXY_PROFILE_PREFERENCES_KEY: string = 'ssh.proxy.profiles.v1';

export interface SshProxyProfilePreferenceRead { ok: boolean; value: string; }
export interface SshProxyProfilePreferenceAdapter {
  read(context: common.Context, storeName: string, key: string): SshProxyProfilePreferenceRead;
  write(context: common.Context, storeName: string, key: string, value: string): boolean;
  remove(context: common.Context, storeName: string, key: string): boolean;
}

class HarmonySshProxyProfilePreferenceAdapter implements SshProxyProfilePreferenceAdapter {
  read(context: common.Context, storeName: string, key: string): SshProxyProfilePreferenceRead {
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

let proxyPreferenceAdapter: SshProxyProfilePreferenceAdapter =
  new HarmonySshProxyProfilePreferenceAdapter();

export function setSshProxyProfilePreferenceAdapterForTest(
  adapter: SshProxyProfilePreferenceAdapter | null
): void {
  proxyPreferenceAdapter = adapter === null
    ? new HarmonySshProxyProfilePreferenceAdapter() : adapter;
}

function cloneProfile(profile: SshProxyProfileV1): SshProxyProfileV1 {
  const hops: SshJumpHop[] = profile.route.hops.map((hop: SshJumpHop): SshJumpHop => {
    const result: SshJumpHop = {
      host: hop.host,
      port: hop.port,
      username: hop.username,
      authMethod: hop.authMethod,
      connectTimeoutMs: hop.connectTimeoutMs
    };
    if (hop.expectedHostKeyRawBase64 !== undefined) {
      result.expectedHostKeyRawBase64 = hop.expectedHostKeyRawBase64;
    }
    if (hop.expectedHostKeyFingerprintSha256 !== undefined) {
      result.expectedHostKeyFingerprintSha256 = hop.expectedHostKeyFingerprintSha256;
    }
    return result;
  });
  const result: SshProxyProfileV1 = {
    schemaVersion: 1,
    hostId: profile.hostId,
    route: {
      schemaVersion: profile.route.schemaVersion, type: profile.route.type,
      endpointHost: profile.route.endpointHost, endpointPort: profile.route.endpointPort,
      hops,
      connectTimeoutMs: profile.route.connectTimeoutMs
    }
  };
  if (profile.route.controlId !== undefined) { result.route.controlId = profile.route.controlId; }
  if (profile.proxyHost !== undefined) { result.proxyHost = profile.proxyHost; }
  if (profile.proxyPort !== undefined) { result.proxyPort = profile.proxyPort; }
  if (profile.proxyUsername !== undefined) { result.proxyUsername = profile.proxyUsername; }
  if (profile.proxyAuthRequired !== undefined) { result.proxyAuthRequired = profile.proxyAuthRequired; }
  if (profile.hopMetadata !== undefined) {
    result.hopMetadata = profile.hopMetadata.map(
      (item: SshProxyHopMetadataV1): SshProxyHopMetadataV1 => ({
        hopId: item.hopId, label: item.label, keyId: item.keyId,
        hostKeyPolicy: item.hostKeyPolicy, position: item.position
      }));
  }
  if (profile.updatedAtMs !== undefined) { result.updatedAtMs = profile.updatedAtMs; }
  return result;
}

export class SshProxyProfileStore {
  private context: common.Context | null = null;
  private profiles: SshProxyProfileV1[] = [];
  private initialized: boolean = false;
  private readable: boolean = false;
  private persistedRaw: string = '';

  init(context: common.Context): boolean {
    this.context = context; this.initialized = true; this.readable = false;
    this.profiles = []; this.persistedRaw = '';
    const read: SshProxyProfilePreferenceRead = proxyPreferenceAdapter.read(
      context, SSH_PROXY_PROFILE_PREFERENCES_NAME, SSH_PROXY_PROFILE_PREFERENCES_KEY);
    if (!read.ok) { return false; }
    const parsed: SshProxyProfileV1[] | null = deserializeSshProxyProfiles(read.value);
    if (parsed === null) { return false; }
    this.profiles = parsed; this.persistedRaw = read.value; this.readable = true; return true;
  }

  load(hostId: string): SshProxyProfileV1 | null {
    const id: string = hostId.trim();
    if (!this.readable || id.length === 0) { return null; }
    for (let index: number = 0; index < this.profiles.length; index++) {
      if (this.profiles[index].hostId === id) { return cloneProfile(this.profiles[index]); }
    }
    return null;
  }

  list(hostId: string = ''): SshProxyProfileV1[] {
    if (!this.readable) { return []; }
    const id: string = hostId.trim();
    return this.profiles.filter((profile: SshProxyProfileV1): boolean => id.length === 0 || profile.hostId === id)
      .map((profile: SshProxyProfileV1): SshProxyProfileV1 => cloneProfile(profile));
  }

  upsert(profile: SshProxyProfileV1): boolean {
    if (!this.initialized || !this.readable) { return false; }
    const encodedOne: string | null = serializeSshProxyProfiles([profile]);
    if (encodedOne === null) { return false; }
    const normalized: SshProxyProfileV1[] | null = deserializeSshProxyProfiles(encodedOne);
    if (normalized === null) { return false; }
    const next: SshProxyProfileV1[] = this.profiles.slice();
    const index: number = next.findIndex((item: SshProxyProfileV1): boolean => item.hostId === normalized[0].hostId);
    if (index >= 0) { next[index] = normalized[0]; } else { next.push(normalized[0]); }
    const snapshot: string | null = serializeSshProxyProfiles(next);
    if (snapshot === null || !this.write(snapshot)) { return false; }
    this.profiles = next; this.persistedRaw = snapshot; return true;
  }

  remove(hostId: string): boolean {
    if (!this.initialized || !this.readable) { return false; }
    const id: string = hostId.trim();
    const next: SshProxyProfileV1[] = this.profiles.filter((item): boolean => item.hostId !== id);
    if (next.length === this.profiles.length) { return true; }
    const snapshot: string | null = serializeSshProxyProfiles(next);
    if (snapshot === null || !this.write(snapshot)) { return false; }
    this.profiles = next; this.persistedRaw = snapshot; return true;
  }

  clear(): boolean {
    if (!this.initialized || !this.readable) { return false; }
    if (this.profiles.length === 0) { return true; }
    if (!proxyPreferenceAdapter.remove(this.context as common.Context,
      SSH_PROXY_PROFILE_PREFERENCES_NAME, SSH_PROXY_PROFILE_PREFERENCES_KEY)) { return false; }
    this.profiles = []; this.persistedRaw = ''; return true;
  }

  private write(snapshot: string): boolean {
    const ok: boolean = proxyPreferenceAdapter.write(this.context as common.Context,
      SSH_PROXY_PROFILE_PREFERENCES_NAME, SSH_PROXY_PROFILE_PREFERENCES_KEY, snapshot);
    if (ok) { return true; }
    if (this.persistedRaw.length > 0) {
      proxyPreferenceAdapter.write(this.context as common.Context,
        SSH_PROXY_PROFILE_PREFERENCES_NAME, SSH_PROXY_PROFILE_PREFERENCES_KEY, this.persistedRaw);
    } else {
      proxyPreferenceAdapter.remove(this.context as common.Context,
        SSH_PROXY_PROFILE_PREFERENCES_NAME, SSH_PROXY_PROFILE_PREFERENCES_KEY);
    }
    return false;
  }
}
