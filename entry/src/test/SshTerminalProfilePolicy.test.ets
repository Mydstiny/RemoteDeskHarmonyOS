import { common } from '@kit.AbilityKit';
import { afterAll, beforeEach, describe, it, expect } from '@ohos/hypium';
import {
  decodeSshTerminalProfileDocument,
  emptySshTerminalProfileDocument,
  emptySshTerminalProfileSettings,
  encodeSshTerminalProfileDocument,
  legacySshTerminalProfileDocument,
  resolveSshTerminalProfile,
  SshTerminalProfileDocumentV1,
  SshTerminalProfileSettingsV1,
  SshTerminalProfileV1,
  SshTerminalResolvedProfile
} from '../main/ets/services/ssh/profile/SshTerminalProfilePolicy';
import {
  setSshTerminalProfilePreferenceAdapterForTest,
  SSH_TERMINAL_PROFILE_PREFERENCES_KEY,
  SSH_TERMINAL_PROFILE_PREFERENCES_NAME,
  SshTerminalProfilePreferenceAdapter,
  SshTerminalProfilePreferenceRead,
  SshTerminalProfileStore
} from '../main/ets/services/ssh/profile/SshTerminalProfileStore';

class MemoryTerminalProfilePreferences implements SshTerminalProfilePreferenceAdapter {
  values: Map<string, string> = new Map<string, string>();
  failWrite: boolean = false;

  private storageKey(storeName: string, key: string): string {
    return storeName + '|' + key;
  }

  read(_context: common.Context, storeName: string,
    key: string): SshTerminalProfilePreferenceRead {
    return { ok: true, value: this.values.get(this.storageKey(storeName, key)) ?? '' };
  }

  write(_context: common.Context, storeName: string, key: string, value: string): boolean {
    if (this.failWrite) { return false; }
    this.values.set(this.storageKey(storeName, key), value);
    return true;
  }

  remove(_context: common.Context, storeName: string, key: string): boolean {
    if (this.failWrite) { return false; }
    this.values.delete(this.storageKey(storeName, key));
    return true;
  }

  raw(): string {
    return this.values.get(this.storageKey(
      SSH_TERMINAL_PROFILE_PREFERENCES_NAME, SSH_TERMINAL_PROFILE_PREFERENCES_KEY)) ?? '';
  }
}

function profile(id: string, name: string,
  mutate: (settings: SshTerminalProfileSettingsV1) => void): SshTerminalProfileV1 {
  const settings: SshTerminalProfileSettingsV1 = emptySshTerminalProfileSettings();
  mutate(settings);
  return { schemaVersion: 1, id, name, settings, updatedAtMs: 1 };
}

export default function sshTerminalProfilePolicyTest(): void {
  describe('SshTerminalProfilePolicy', (): void => {
    let adapter: MemoryTerminalProfilePreferences = new MemoryTerminalProfilePreferences();
    const context: common.Context = undefined as common.Context;

    beforeEach((): void => {
      adapter = new MemoryTerminalProfilePreferences();
      setSshTerminalProfilePreferenceAdapterForTest(adapter);
    });

    afterAll((): void => {
      setSshTerminalProfilePreferenceAdapterForTest(null);
    });

    it('resolves_session_over_host_over_global_over_builtin', 0, (): void => {
      const global: SshTerminalProfileV1 = profile('global', 'Global',
        (settings: SshTerminalProfileSettingsV1): void => {
          settings.fontSize = 20;
          settings.backgroundColor = '#111111';
        });
      const host: SshTerminalProfileV1 = profile('host-a-profile', 'Host A',
        (settings: SshTerminalProfileSettingsV1): void => {
          settings.fontSize = 22;
          settings.cursorStyle = 'block';
        });
      const session: SshTerminalProfileV1 = profile('session', 'Session',
        (settings: SshTerminalProfileSettingsV1): void => {
          settings.fontSize = 24;
          settings.cursorBlink = false;
        });
      const document: SshTerminalProfileDocumentV1 = {
        schemaVersion: 1,
        globalProfileId: global.id,
        profiles: [global, host],
        hostAssignments: [{ hostId: 'host-a', profileId: host.id }]
      };
      const resolved: SshTerminalResolvedProfile =
        resolveSshTerminalProfile(document, 'host-a', session);
      expect(resolved.fontSize).assertEqual(24);
      expect(resolved.backgroundColor).assertEqual('#111111');
      expect(resolved.cursorStyle).assertEqual('block');
      expect(resolved.cursorBlink).assertFalse();
      expect(resolved.foregroundColor).assertEqual('#33FF33');
      expect(resolved.appliedProfileIds.join(',')).assertEqual('global,host-a-profile,session');
    });

    it('migrates_existing_appearance_without_changing_values', 0, (): void => {
      const migrated: SshTerminalProfileDocumentV1 = legacySshTerminalProfileDocument({
        foregroundColor: '#AABBCC', fontSize: 26, lineSpacing: 1.3
      });
      const resolved: SshTerminalResolvedProfile =
        resolveSshTerminalProfile(migrated, 'any-host');
      expect(resolved.foregroundColor).assertEqual('#AABBCC');
      expect(resolved.fontSize).assertEqual(26);
      expect(resolved.lineSpacing).assertEqual(1.3);
    });

    it('whitelists_profile_json_and_isolates_malformed_items', 0, (): void => {
      const raw: string = JSON.stringify({
        schemaVersion: 1,
        globalProfileId: 'safe',
        profiles: [
          {
            schemaVersion: 1,
            id: 'safe',
            name: 'Safe',
            settings: { fontSize: 19, password: 'secret', privateKey: '/private/key' },
            updatedAtMs: 1,
            terminalOutput: 'do-not-save'
          },
          {
            schemaVersion: 1,
            id: 'bad',
            name: 'Bad',
            settings: { scrollback: -1 },
            updatedAtMs: 1
          },
          {
            schemaVersion: 1,
            id: 'wrong-type',
            name: 'Wrong type',
            settings: { foregroundColor: 42, palette: [1, 2, 3] },
            updatedAtMs: 1
          }
        ],
        hostAssignments: [
          { hostId: 'host-a', profileId: 'safe' },
          { hostId: '', profileId: 'safe' },
          { hostId: 'host-b', profileId: 'bad' }
        ],
        sessionId: 88
      });
      const decoded: SshTerminalProfileDocumentV1 | null =
        decodeSshTerminalProfileDocument(raw);
      expect(decoded !== null).assertTrue();
      expect(decoded!.profiles.length).assertEqual(1);
      expect(decoded!.hostAssignments.length).assertEqual(1);
      const encoded: string = encodeSshTerminalProfileDocument(decoded!) as string;
      expect(encoded.indexOf('password')).assertEqual(-1);
      expect(encoded.indexOf('privateKey')).assertEqual(-1);
      expect(encoded.indexOf('terminalOutput')).assertEqual(-1);
      expect(encoded.indexOf('sessionId')).assertEqual(-1);
    });

    it('persists_named_profiles_and_host_assignments_transactionally', 0, (): void => {
      const store: SshTerminalProfileStore = new SshTerminalProfileStore();
      expect(store.init(context, {
        foregroundColor: '#33FF33', fontSize: 18, lineSpacing: 1.12
      })).assertTrue();
      const hostProfile: SshTerminalProfileV1 = profile('ops', 'Ops',
        (settings: SshTerminalProfileSettingsV1): void => {
          settings.fontFamily = 'Menlo';
          settings.scrollback = 50000;
        });
      expect(store.upsertProfile(hostProfile)).assertTrue();
      expect(store.assignHost('host-a', hostProfile.id)).assertTrue();
      expect(store.hostProfileId('host-a')).assertEqual('ops');
      expect(store.resolve('host-a').fontFamily).assertEqual('Menlo');
      const beforeFailure: string = adapter.raw();
      adapter.failWrite = true;
      expect(store.assignHost('host-b', hostProfile.id)).assertFalse();
      expect(store.hostProfileId('host-b')).assertEqual('');
      expect(adapter.raw()).assertEqual(beforeFailure);
    });

    it('rejects_corrupt_store_without_overwriting_raw_data', 0, (): void => {
      adapter.values.set(SSH_TERMINAL_PROFILE_PREFERENCES_NAME + '|' +
        SSH_TERMINAL_PROFILE_PREFERENCES_KEY, '{not-json');
      const store: SshTerminalProfileStore = new SshTerminalProfileStore();
      expect(store.init(context, {
        foregroundColor: '#33FF33', fontSize: 18, lineSpacing: 1.12
      })).assertFalse();
      expect(store.listProfiles().length).assertEqual(0);
      expect(adapter.raw()).assertEqual('{not-json');
      expect(store.snapshot().profiles.length).assertEqual(
        emptySshTerminalProfileDocument().profiles.length);
    });
  });
}
