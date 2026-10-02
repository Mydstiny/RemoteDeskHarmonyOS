import { common } from '@kit.AbilityKit';
import { describe, it, expect } from '@ohos/hypium';
import {
  defaultRemoteDisplayProfile
} from '../main/ets/services/RemoteDisplayProfilePolicy';
import {
  RemoteDisplayProfilePreferenceAdapter,
  RemoteDisplayProfilePreferenceRead,
  RemoteDisplayProfileMigrationScope,
  RemoteDisplayProfileScope,
  RemoteDisplayProfileStore,
  deserializeRemoteDisplayProfileEnvelope,
  remoteDisplayProfileLegacyMigrationKey,
  remoteDisplayProfileStorageKey,
  serializeRemoteDisplayProfileEnvelope,
  setRemoteDisplayProfilePreferenceAdapterForTest
} from '../main/ets/services/RemoteDisplayProfileStore';

class MemoryRemoteDisplayProfileAdapter implements RemoteDisplayProfilePreferenceAdapter {
  values: Map<string, string> = new Map<string, string>();
  failWrites: Set<string> = new Set<string>();

  read(_context: common.Context, _storeName: string, key: string): RemoteDisplayProfilePreferenceRead {
    const value: string | undefined = this.values.get(key);
    return value === undefined ? { ok: true, value: '' } : { ok: true, value };
  }

  write(_context: common.Context, _storeName: string, key: string, value: string): boolean {
    if (this.failWrites.has(key)) {
      return false;
    }
    this.values.set(key, value);
    return true;
  }

  remove(_context: common.Context, _storeName: string, key: string): boolean {
    this.values.delete(key);
    return true;
  }
}

export default function remoteDisplayProfileStoreTest(): void {
  describe('RemoteDisplayProfileStore', (): void => {
    it('separates_profiles_by_owner_host_and_device_scope', 0, (): void => {
      const adapter = new MemoryRemoteDisplayProfileAdapter();
      setRemoteDisplayProfilePreferenceAdapterForTest(adapter);
      const store = new RemoteDisplayProfileStore();
      store.init({} as common.Context);
      const base = defaultRemoteDisplayProfile('host-a', 'rdp', 'profile-a', 10);
      base.deviceScope = 'pc';
      base.displayScope = 'default';
      base.orientationScope = 'any';
      base.resolution.mode = 'custom';
      base.resolution.width = 2560;
      base.resolution.height = 1600;
      const pcScope: RemoteDisplayProfileScope = {
        ownerScopeId: 'owner-a', hostId: 'host-a', protocol: 'rdp', deviceScope: 'pc',
        displayScope: 'default', orientationScope: 'any'
      };
      const phoneScope: RemoteDisplayProfileScope = {
        ownerScopeId: 'owner-a', hostId: 'host-a', protocol: 'rdp', deviceScope: 'phone',
        displayScope: 'default', orientationScope: 'any'
      };
      const otherHostScope: RemoteDisplayProfileScope = {
        ownerScopeId: 'owner-a', hostId: 'host-b', protocol: 'rdp', deviceScope: 'pc',
        displayScope: 'default', orientationScope: 'any'
      };
      expect(store.upsert(pcScope, base)).assertTrue();
      expect(store.load(pcScope)?.resolution.width).assertEqual(2560);
      expect(store.load(phoneScope)).assertNull();
      expect(store.load(otherHostScope)).assertNull();
      expect(remoteDisplayProfileStorageKey(pcScope) !==
        remoteDisplayProfileStorageKey(phoneScope)).assertTrue();
      const rustDeskScope: RemoteDisplayProfileScope = {
        ownerScopeId: 'owner-a', hostId: 'host-a', protocol: 'rustdesk', deviceScope: 'pc',
        displayScope: 'default', orientationScope: 'any'
      };
      const rustDeskProfile = defaultRemoteDisplayProfile('host-a', 'rustdesk', 'profile-a', 10);
      rustDeskProfile.protocol = 'rustdesk';
      expect(store.upsert(rustDeskScope, rustDeskProfile)).assertTrue();
      expect(store.load(rustDeskScope)?.protocol).assertEqual('rustdesk');
      expect(remoteDisplayProfileStorageKey(pcScope) !==
        remoteDisplayProfileStorageKey(rustDeskScope)).assertTrue();
      expect(store.remove(pcScope)).assertTrue();
      expect(store.load(pcScope)).assertNull();
      setRemoteDisplayProfilePreferenceAdapterForTest(null);
    });

    it('rejects_malformed_or_scope_mismatched_profiles', 0, (): void => {
      expect(deserializeRemoteDisplayProfileEnvelope('{"schemaVersion":1,"profile":null}')).assertNull();
      const profile = defaultRemoteDisplayProfile('host-a', 'rdp', 'profile-a', 10);
      const raw: string | null = serializeRemoteDisplayProfileEnvelope(profile);
      expect(raw !== null).assertTrue();
      const parsed = deserializeRemoteDisplayProfileEnvelope(raw as string);
      expect(parsed?.hostId).assertEqual('host-a');
      const adapter = new MemoryRemoteDisplayProfileAdapter();
      setRemoteDisplayProfilePreferenceAdapterForTest(adapter);
      const store = new RemoteDisplayProfileStore();
      store.init({} as common.Context);
      const scope: RemoteDisplayProfileScope = {
        ownerScopeId: 'owner-a', hostId: 'host-b', protocol: 'rdp', deviceScope: 'pc',
        displayScope: 'default', orientationScope: 'any'
      };
      expect(store.upsert(scope, profile)).assertFalse();
      const invalidScope: RemoteDisplayProfileScope = {
        ownerScopeId: '', hostId: 'host-a', protocol: 'rdp', deviceScope: 'pc',
        displayScope: 'default', orientationScope: 'any'
      };
      expect(store.upsert(invalidScope, profile)).assertFalse();
      expect(store.remove(invalidScope)).assertFalse();
      expect(store.legacyFallbackConsumed({ ownerScopeId: 'owner-a', deviceScope: 'pc' }))
        .assertFalse();
      expect(store.markLegacyFallbackConsumed({ ownerScopeId: 'owner-a', deviceScope: 'pc' }))
        .assertTrue();
      expect(store.legacyFallbackConsumed({ ownerScopeId: 'owner-a', deviceScope: 'pc' }))
        .assertTrue();
      setRemoteDisplayProfilePreferenceAdapterForTest(null);
    });

    it('fails_closed_when_legacy_marker_cannot_be_persisted', 0, (): void => {
      const adapter = new MemoryRemoteDisplayProfileAdapter();
      const migrationScope: RemoteDisplayProfileMigrationScope = {
        ownerScopeId: 'owner-a', deviceScope: 'pc'
      };
      adapter.failWrites.add(remoteDisplayProfileLegacyMigrationKey(migrationScope));
      setRemoteDisplayProfilePreferenceAdapterForTest(adapter);
      const store = new RemoteDisplayProfileStore();
      store.init({} as common.Context);
      expect(store.legacyFallbackConsumed(migrationScope)).assertFalse();
      expect(store.tryClaimLegacyFallback(migrationScope)).assertFalse();
      expect(store.legacyFallbackConsumed(migrationScope)).assertTrue();
      setRemoteDisplayProfilePreferenceAdapterForTest(null);
    });
  });
}
