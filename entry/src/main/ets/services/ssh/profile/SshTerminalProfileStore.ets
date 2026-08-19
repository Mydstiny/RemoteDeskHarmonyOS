import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { SshTerminalAppearance } from '../../SshSettingsPolicy';
import {
  cloneSshTerminalProfile,
  decodeSshTerminalProfileDocument,
  emptySshTerminalProfileDocument,
  encodeSshTerminalProfileDocument,
  legacySshTerminalProfileDocument,
  normalizeSshTerminalProfile,
  resolveSshTerminalProfile,
  SSH_TERMINAL_PROFILE_MAX_HOST_ASSIGNMENTS,
  SSH_TERMINAL_PROFILE_MAX_PROFILES,
  SshTerminalHostProfileAssignmentV1,
  SshTerminalProfileDocumentV1,
  SshTerminalProfileV1,
  SshTerminalResolvedProfile
} from './SshTerminalProfilePolicy';

export const SSH_TERMINAL_PROFILE_PREFERENCES_NAME: string =
  'RemoteDesktopSshTerminalProfilePrefs';
export const SSH_TERMINAL_PROFILE_PREFERENCES_KEY: string = 'ssh.terminal.profiles.v1';

export interface SshTerminalProfilePreferenceRead { ok: boolean; value: string; }

export interface SshTerminalProfilePreferenceAdapter {
  read(context: common.Context, storeName: string, key: string): SshTerminalProfilePreferenceRead;
  write(context: common.Context, storeName: string, key: string, value: string): boolean;
  remove(context: common.Context, storeName: string, key: string): boolean;
}

class HarmonySshTerminalProfilePreferenceAdapter
  implements SshTerminalProfilePreferenceAdapter {
  read(context: common.Context, storeName: string, key: string): SshTerminalProfilePreferenceRead {
    try {
      const prefs = preferences.getPreferencesSync(context, { name: storeName });
      const value: Object = prefs.getSync(key, '') as Object;
      return typeof value === 'string' ?
        { ok: true, value: value as string } : { ok: false, value: '' };
    } catch (_err) {
      return { ok: false, value: '' };
    }
  }

  write(context: common.Context, storeName: string, key: string, value: string): boolean {
    try {
      const prefs = preferences.getPreferencesSync(context, { name: storeName });
      prefs.putSync(key, value);
      prefs.flushSync();
      return true;
    } catch (_err) {
      return false;
    }
  }

  remove(context: common.Context, storeName: string, key: string): boolean {
    try {
      const prefs = preferences.getPreferencesSync(context, { name: storeName });
      prefs.deleteSync(key);
      prefs.flushSync();
      return true;
    } catch (_err) {
      return false;
    }
  }
}

let terminalProfilePreferenceAdapter: SshTerminalProfilePreferenceAdapter =
  new HarmonySshTerminalProfilePreferenceAdapter();

export function setSshTerminalProfilePreferenceAdapterForTest(
  adapter: SshTerminalProfilePreferenceAdapter | null
): void {
  terminalProfilePreferenceAdapter = adapter === null ?
    new HarmonySshTerminalProfilePreferenceAdapter() : adapter;
}

function cloneDocument(document: SshTerminalProfileDocumentV1): SshTerminalProfileDocumentV1 {
  return {
    schemaVersion: 1,
    globalProfileId: document.globalProfileId,
    profiles: document.profiles.map(
      (profile: SshTerminalProfileV1): SshTerminalProfileV1 =>
        cloneSshTerminalProfile(profile)),
    hostAssignments: document.hostAssignments.map(
      (item: SshTerminalHostProfileAssignmentV1): SshTerminalHostProfileAssignmentV1 => ({
        hostId: item.hostId,
        profileId: item.profileId
      }))
  };
}

export class SshTerminalProfileStore {
  private context: common.Context | null = null;
  private document: SshTerminalProfileDocumentV1 = emptySshTerminalProfileDocument();
  private initialized: boolean = false;
  private readable: boolean = false;
  private persistedRaw: string = '';

  init(context: common.Context, legacyAppearance: SshTerminalAppearance): boolean {
    this.context = context;
    this.initialized = true;
    this.readable = false;
    this.persistedRaw = '';
    this.document = emptySshTerminalProfileDocument();
    const read: SshTerminalProfilePreferenceRead = terminalProfilePreferenceAdapter.read(
      context, SSH_TERMINAL_PROFILE_PREFERENCES_NAME, SSH_TERMINAL_PROFILE_PREFERENCES_KEY);
    if (!read.ok) { return false; }
    if (read.value.trim().length === 0) {
      const migrated: SshTerminalProfileDocumentV1 =
        legacySshTerminalProfileDocument(legacyAppearance);
      const encoded: string | null = encodeSshTerminalProfileDocument(migrated);
      if (encoded === null || !terminalProfilePreferenceAdapter.write(
        context, SSH_TERMINAL_PROFILE_PREFERENCES_NAME,
        SSH_TERMINAL_PROFILE_PREFERENCES_KEY, encoded)) {
        return false;
      }
      this.document = migrated;
      this.persistedRaw = encoded;
      this.readable = true;
      return true;
    }
    const decoded: SshTerminalProfileDocumentV1 | null =
      decodeSshTerminalProfileDocument(read.value);
    if (decoded === null) { return false; }
    this.document = decoded;
    this.persistedRaw = read.value;
    this.readable = true;
    return true;
  }

  isReady(): boolean {
    return this.initialized && this.readable;
  }

  snapshot(): SshTerminalProfileDocumentV1 {
    return cloneDocument(this.document);
  }

  listProfiles(): SshTerminalProfileV1[] {
    if (!this.readable) { return []; }
    return this.document.profiles.map(
      (profile: SshTerminalProfileV1): SshTerminalProfileV1 =>
        cloneSshTerminalProfile(profile));
  }

  profile(profileId: string): SshTerminalProfileV1 | null {
    const id: string = profileId.trim();
    if (!this.readable || id.length === 0) { return null; }
    for (let index: number = 0; index < this.document.profiles.length; index++) {
      if (this.document.profiles[index].id === id) {
        return cloneSshTerminalProfile(this.document.profiles[index]);
      }
    }
    return null;
  }

  globalProfileId(): string {
    return this.readable ? this.document.globalProfileId : '';
  }

  hostProfileId(hostId: string): string {
    const id: string = hostId.trim();
    if (!this.readable || id.length === 0) { return ''; }
    for (let index: number = 0; index < this.document.hostAssignments.length; index++) {
      const assignment: SshTerminalHostProfileAssignmentV1 =
        this.document.hostAssignments[index];
      if (assignment.hostId === id) { return assignment.profileId; }
    }
    return '';
  }

  resolve(hostId: string,
    sessionProfile: SshTerminalProfileV1 | null = null): SshTerminalResolvedProfile {
    return resolveSshTerminalProfile(this.document, hostId, sessionProfile);
  }

  upsertProfile(profile: SshTerminalProfileV1): boolean {
    if (!this.isReady()) { return false; }
    const normalized: SshTerminalProfileV1 | null = normalizeSshTerminalProfile(profile);
    if (normalized === null) { return false; }
    const next: SshTerminalProfileDocumentV1 = cloneDocument(this.document);
    const index: number = next.profiles.findIndex(
      (item: SshTerminalProfileV1): boolean => item.id === normalized.id);
    if (index < 0 && next.profiles.length >= SSH_TERMINAL_PROFILE_MAX_PROFILES) { return false; }
    if (index >= 0) { next.profiles[index] = normalized; }
    else { next.profiles.push(normalized); }
    return this.commit(next);
  }

  removeProfile(profileId: string): boolean {
    if (!this.isReady()) { return false; }
    const id: string = profileId.trim();
    if (id.length === 0) { return true; }
    const next: SshTerminalProfileDocumentV1 = cloneDocument(this.document);
    next.profiles = next.profiles.filter(
      (profile: SshTerminalProfileV1): boolean => profile.id !== id);
    if (next.profiles.length === this.document.profiles.length) { return true; }
    if (next.globalProfileId === id) { next.globalProfileId = ''; }
    next.hostAssignments = next.hostAssignments.filter(
      (item: SshTerminalHostProfileAssignmentV1): boolean => item.profileId !== id);
    return this.commit(next);
  }

  setGlobalProfile(profileId: string): boolean {
    if (!this.isReady()) { return false; }
    const id: string = profileId.trim();
    if (id.length > 0 && this.profile(id) === null) { return false; }
    const next: SshTerminalProfileDocumentV1 = cloneDocument(this.document);
    next.globalProfileId = id;
    return this.commit(next);
  }

  assignHost(hostId: string, profileId: string): boolean {
    if (!this.isReady()) { return false; }
    const host: string = hostId.trim();
    const profile: string = profileId.trim();
    if (host.length === 0 || host.length > 128 ||
      (profile.length > 0 && this.profile(profile) === null)) { return false; }
    const next: SshTerminalProfileDocumentV1 = cloneDocument(this.document);
    const index: number = next.hostAssignments.findIndex(
      (item: SshTerminalHostProfileAssignmentV1): boolean => item.hostId === host);
    if (profile.length === 0) {
      if (index >= 0) { next.hostAssignments.splice(index, 1); }
      else { return true; }
    } else if (index >= 0) {
      next.hostAssignments[index] = { hostId: host, profileId: profile };
    } else {
      if (next.hostAssignments.length >= SSH_TERMINAL_PROFILE_MAX_HOST_ASSIGNMENTS) {
        return false;
      }
      next.hostAssignments.push({ hostId: host, profileId: profile });
    }
    return this.commit(next);
  }

  clear(): boolean {
    if (!this.isReady()) { return false; }
    if (!terminalProfilePreferenceAdapter.remove(this.context as common.Context,
      SSH_TERMINAL_PROFILE_PREFERENCES_NAME, SSH_TERMINAL_PROFILE_PREFERENCES_KEY)) {
      return false;
    }
    this.document = emptySshTerminalProfileDocument();
    this.persistedRaw = '';
    return true;
  }

  private commit(next: SshTerminalProfileDocumentV1): boolean {
    const encoded: string | null = encodeSshTerminalProfileDocument(next);
    if (encoded === null || !this.write(encoded)) { return false; }
    const decoded: SshTerminalProfileDocumentV1 | null =
      decodeSshTerminalProfileDocument(encoded);
    if (decoded === null) { return false; }
    this.document = decoded;
    this.persistedRaw = encoded;
    return true;
  }

  private write(snapshot: string): boolean {
    const context: common.Context = this.context as common.Context;
    const ok: boolean = terminalProfilePreferenceAdapter.write(
      context, SSH_TERMINAL_PROFILE_PREFERENCES_NAME,
      SSH_TERMINAL_PROFILE_PREFERENCES_KEY, snapshot);
    if (ok) { return true; }
    if (this.persistedRaw.length > 0) {
      terminalProfilePreferenceAdapter.write(
        context, SSH_TERMINAL_PROFILE_PREFERENCES_NAME,
        SSH_TERMINAL_PROFILE_PREFERENCES_KEY, this.persistedRaw);
    } else {
      terminalProfilePreferenceAdapter.remove(
        context, SSH_TERMINAL_PROFILE_PREFERENCES_NAME,
        SSH_TERMINAL_PROFILE_PREFERENCES_KEY);
    }
    return false;
  }
}
