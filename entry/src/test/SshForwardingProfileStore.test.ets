import { common } from '@kit.AbilityKit';
import { afterAll, beforeEach, describe, it, expect } from '@ohos/hypium';
import {
  SshForwardingMode,
  SshForwardingProfile,
  validateSshForwardingProfile
} from '../main/ets/services/SshForwardingPolicy';
import {
  SshForwardingPreferenceAdapter,
  SshForwardingPreferenceRead,
  SshForwardingProfileStore,
  SSH_FORWARDING_PROFILE_PREFERENCES_NAME,
  forwardingProfilePreferenceKey,
  serializeSshForwardingProfilesEnvelope,
  setSshForwardingPreferenceAdapterForTest
} from '../main/ets/services/SshForwardingProfileStore';

class MemoryForwardingPreferences implements SshForwardingPreferenceAdapter {
  readonly values: Map<string, string> = new Map<string, string>();
  failWrite: boolean = false;
  failRemove: boolean = false;

  private key(storeName: string, key: string): string {
    return storeName + '|' + key;
  }

  read(_context: common.Context, storeName: string, key: string): SshForwardingPreferenceRead {
    return { ok: true, value: this.values.get(this.key(storeName, key)) || '' };
  }

  write(_context: common.Context, storeName: string, key: string, value: string): boolean {
    if (this.failWrite) { return false; }
    this.values.set(this.key(storeName, key), value);
    return true;
  }

  remove(_context: common.Context, storeName: string, key: string): boolean {
    if (this.failRemove) { return false; }
    this.values.delete(this.key(storeName, key));
    return true;
  }

  raw(ownerHostId: string): string {
    return this.values.get(this.key(SSH_FORWARDING_PROFILE_PREFERENCES_NAME,
      forwardingProfilePreferenceKey(ownerHostId))) || '';
  }
}

function forwardingProfile(id: string): SshForwardingProfile {
  const mode: SshForwardingMode = 'local';
  return {
    id, mode, bindHost: '127.0.0.1', bindPort: 8022,
    targetHost: 'target.example', targetPort: 22, maxConnections: 4,
    enabled: true, allowPublicBind: false
  };
}

export default function sshForwardingProfileStoreTest(): void {
  describe('SshForwardingProfileStore', (): void => {
    let adapter: MemoryForwardingPreferences = new MemoryForwardingPreferences();
    const context: common.Context = undefined as common.Context;

    beforeEach((): void => {
      adapter = new MemoryForwardingPreferences();
      setSshForwardingPreferenceAdapterForTest(adapter);
    });

    afterAll((): void => {
      setSshForwardingPreferenceAdapterForTest(null);
    });

    it('reuses_the_existing_forwarding_policy_and_preserves_bind_port_zero_behavior', 0, (): void => {
      const dynamic: SshForwardingProfile = forwardingProfile('dynamic');
      dynamic.mode = 'dynamic';
      dynamic.bindPort = 1080;
      dynamic.targetHost = '';
      dynamic.targetPort = 0;
      expect(validateSshForwardingProfile(dynamic).valid).assertTrue();
      const zeroPort: SshForwardingProfile = forwardingProfile('zero');
      zeroPort.bindPort = 0;
      expect(validateSshForwardingProfile(zeroPort).valid).assertFalse();
      const store: SshForwardingProfileStore = new SshForwardingProfileStore();
      expect(store.init(context)).assertTrue();
      expect(store.upsert('host-a', zeroPort)).assertFalse();
      expect(store.list('host-a').length).assertEqual(0);
    });

    it('isolates_owners_and_makes_save_load_remove_clear_idempotent', 0, (): void => {
      const store: SshForwardingProfileStore = new SshForwardingProfileStore();
      expect(store.init(context)).assertTrue();
      expect(store.upsert('host-a', forwardingProfile('rule-a'))).assertTrue();
      expect(store.upsert('host-b', forwardingProfile('rule-b'))).assertTrue();
      expect(store.load('host-a').length).assertEqual(1);
      expect(store.load('  host-a  ')[0].id).assertEqual('rule-a');
      expect(store.list('  host-a  ')[0].id).assertEqual('rule-a');
      expect(store.list('host-a')[0].id).assertEqual('rule-a');
      expect(store.list('host-b')[0].id).assertEqual('rule-b');
      expect(store.list('host-a').some((item: SshForwardingProfile): boolean =>
        item.id === 'rule-b')).assertFalse();
      expect(store.upsert('host-a', forwardingProfile('rule-a'))).assertTrue();
      expect(store.remove('host-a', 'rule-a')).assertTrue();
      expect(store.remove('host-a', 'rule-a')).assertTrue();
      expect(store.clear('host-a')).assertTrue();
      expect(store.clear('host-a')).assertTrue();
      expect(store.list('host-b').length).assertEqual(1);
    });

    it('fails_closed_for_corrupt_unknown_schema_duplicate_and_secret_payloads', 0, (): void => {
      const valid: SshForwardingProfile = forwardingProfile('rule-a');
      const invalidPayloads: string[] = [
        '{not-json',
        JSON.stringify({ schemaVersion: 2, profiles: [valid], updatedAtMs: 1 }),
        JSON.stringify({ schemaVersion: 1, profiles: [valid, valid], updatedAtMs: 1 }),
        JSON.stringify({ schemaVersion: 1, profiles: [{ ...valid, password: 'secret' }], updatedAtMs: 1 })
      ];
      for (let index: number = 0; index < invalidPayloads.length; index++) {
        adapter = new MemoryForwardingPreferences();
        adapter.values.set(SSH_FORWARDING_PROFILE_PREFERENCES_NAME + '|' +
          forwardingProfilePreferenceKey('host-a'), invalidPayloads[index]);
        setSshForwardingPreferenceAdapterForTest(adapter);
        const store: SshForwardingProfileStore = new SshForwardingProfileStore();
        expect(store.init(context)).assertTrue();
        expect(store.load('host-a').length).assertEqual(0);
        expect(adapter.raw('host-a')).assertEqual(invalidPayloads[index]);
        expect(store.upsert('host-a', valid)).assertFalse();
        expect(adapter.raw('host-a')).assertEqual(invalidPayloads[index]);
      }
    });

    it('serializes_only_the_schema_versioned_forwarding_wrapper', 0, (): void => {
      const envelope = {
        schemaVersion: 1 as 1,
        profiles: [forwardingProfile('rule-a')],
        updatedAtMs: 12
      };
      const encoded: string | null = serializeSshForwardingProfilesEnvelope(envelope);
      expect(encoded !== null).assertTrue();
      expect((encoded as string).indexOf('ownerHostId')).assertEqual(-1);
      expect((encoded as string).indexOf('password')).assertEqual(-1);
    });
  });
}
