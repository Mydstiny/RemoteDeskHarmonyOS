import { common } from '@kit.AbilityKit';
import { afterAll, beforeEach, describe, it, expect } from '@ohos/hypium';
import { SshRoute } from '../main/ets/types/rdpnapi';
import {
  SshProxyProfileV1,
  serializeSshProxyProfiles,
  validateSshProxyProfile
} from '../main/ets/services/SshProxyProfilePolicy';
import {
  SshProxyProfilePreferenceAdapter,
  SshProxyProfilePreferenceRead,
  SshProxyProfileStore,
  SSH_PROXY_PROFILE_PREFERENCES_KEY,
  SSH_PROXY_PROFILE_PREFERENCES_NAME,
  setSshProxyProfilePreferenceAdapterForTest
} from '../main/ets/services/SshProxyProfileStore';

class MemoryProxyPreferences implements SshProxyProfilePreferenceAdapter {
  readonly values: Map<string, string> = new Map<string, string>();
  failRead: boolean = false;
  failWrite: boolean = false;
  failRemove: boolean = false;

  private key(storeName: string, key: string): string {
    return storeName + '|' + key;
  }

  read(_context: common.Context, storeName: string, key: string): SshProxyProfilePreferenceRead {
    if (this.failRead) { return { ok: false, value: '' }; }
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

  raw(): string {
    return this.values.get(this.key(SSH_PROXY_PROFILE_PREFERENCES_NAME,
      SSH_PROXY_PROFILE_PREFERENCES_KEY)) || '';
  }
}

function proxyProfile(hostId: string): SshProxyProfileV1 {
  const route: SshRoute = {
    schemaVersion: 1, type: 'direct', endpointHost: hostId + '.example', endpointPort: 22,
    hops: [], connectTimeoutMs: 10000
  };
  return { schemaVersion: 1, hostId, route, updatedAtMs: 1 };
}

function jumpProxyProfile(hostId: string): SshProxyProfileV1 {
  const route: SshRoute = {
    schemaVersion: 1, type: 'ssh_jump', endpointHost: hostId + '.example', endpointPort: 22,
    hops: [{
      host: 'jump.example', port: 22, username: 'operator', authMethod: 'password',
      expectedHostKeyFingerprintSha256: 'SHA256:jump-fingerprint', connectTimeoutMs: 10000
    }], connectTimeoutMs: 10000
  };
  return {
    schemaVersion: 1, hostId, route,
    hopMetadata: [{
      hopId: 'jump-1', label: 'Jump 1', keyId: '', hostKeyPolicy: 'strict', position: 0
    }], updatedAtMs: 1
  };
}

export default function sshProxyProfileStoreTest(): void {
  describe('SshProxyProfileStore', (): void => {
    let adapter: MemoryProxyPreferences = new MemoryProxyPreferences();
    const context: common.Context = undefined as common.Context;

    beforeEach((): void => {
      adapter = new MemoryProxyPreferences();
      setSshProxyProfilePreferenceAdapterForTest(adapter);
    });

    afterAll((): void => {
      setSshProxyProfilePreferenceAdapterForTest(null);
    });

    it('keeps_profiles_isolated_by_host_and_makes_upsert_remove_idempotent', 0, (): void => {
      const store: SshProxyProfileStore = new SshProxyProfileStore();
      expect(store.init(context)).assertTrue();
      expect(store.upsert(proxyProfile('host-a'))).assertTrue();
      expect(store.upsert(proxyProfile('host-b'))).assertTrue();
      expect(store.list('host-a').length).assertEqual(1);
      expect(store.load('host-a')?.hostId).assertEqual('host-a');
      expect(store.list('host-b').length).assertEqual(1);
      expect(store.list('missing').length).assertEqual(0);
      expect(store.upsert(proxyProfile('host-a'))).assertTrue();
      expect(store.list().length).assertEqual(2);
      expect(store.remove('host-a')).assertTrue();
      expect(store.remove('host-a')).assertTrue();
      expect(store.load('host-a')).assertNull();
      expect(store.clear()).assertTrue();
      expect(store.clear()).assertTrue();
      expect(store.list().length).assertEqual(0);
    });

    it('preserves_absent_optional_jump_host_key_fields_after_persisted_load', 0, (): void => {
      const first: SshProxyProfileStore = new SshProxyProfileStore();
      expect(first.init(context)).assertTrue();
      expect(first.upsert(jumpProxyProfile('host-jump'))).assertTrue();

      const restarted: SshProxyProfileStore = new SshProxyProfileStore();
      expect(restarted.init(context)).assertTrue();
      const loaded: SshProxyProfileV1 | null = restarted.load('host-jump');
      expect(loaded === null).assertFalse();
      if (loaded === null) { return; }
      const hopKeys: string[] = Object.keys(loaded.route.hops[0]);
      expect(hopKeys.indexOf('expectedHostKeyRawBase64')).assertEqual(-1);
      expect(hopKeys.indexOf('expectedHostKeyFingerprintSha256') >= 0).assertTrue();
      expect(validateSshProxyProfile(loaded).valid).assertTrue();
    });

    it('does_not_overwrite_valid_data_when_read_json_is_corrupt_unknown_or_duplicated', 0, (): void => {
      const valid: SshProxyProfileV1 = proxyProfile('host-a');
      const validRaw: string = serializeSshProxyProfiles([valid]) as string;
      const invalidPayloads: string[] = [
        '{not-json',
        JSON.stringify([{ ...valid, schemaVersion: 2 }]),
        JSON.stringify([valid, valid]),
        JSON.stringify([{ ...valid, token: 'secret' }])
      ];
      for (let index: number = 0; index < invalidPayloads.length; index++) {
        adapter = new MemoryProxyPreferences();
        adapter.values.set(SSH_PROXY_PROFILE_PREFERENCES_NAME + '|' +
          SSH_PROXY_PROFILE_PREFERENCES_KEY, invalidPayloads[index]);
        setSshProxyProfilePreferenceAdapterForTest(adapter);
        const store: SshProxyProfileStore = new SshProxyProfileStore();
        expect(store.init(context)).assertFalse();
        expect(store.list().length).assertEqual(0);
        expect(adapter.raw()).assertEqual(invalidPayloads[index]);
        expect(store.upsert(valid)).assertFalse();
        expect(adapter.raw()).assertEqual(invalidPayloads[index]);
      }
      expect(validRaw.length > 0).assertTrue();
    });
  });
}
