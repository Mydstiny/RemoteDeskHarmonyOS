import { describe, expect, it } from '@ohos/hypium';
import { MoonlightRecordType } from '../main/ets/model/MoonlightRecord';
import {
  AccountSessionLease,
  accountSessionLeaseEquals,
  cloneAccountSessionLease
} from '../main/ets/services/AccountScopePolicy';
import {
  MOONLIGHT_CLOUD_SYNC_SELECTION_DEFAULT,
  MoonlightCloudSyncScope,
  isMoonlightRecordTypeSelected,
  moonlightIdentitySyncAllowed,
  moonlightRecordTypeToSyncScope,
  normalizeMoonlightCloudSyncSelection
} from '../main/ets/services/MoonlightCloudSyncSelectionPolicy';
import {
  MoonlightCloudSyncSelectionStore,
  MoonlightCloudSyncSelectionStorePort,
  moonlightCloudSyncSelectionPreferenceKey
} from '../main/ets/services/MoonlightCloudSyncSelectionStore';

function lease(owner: string, generation: number = 1,
  instance: number = 1): AccountSessionLease {
  return {
    ownerScopeId: owner, storeIdentity: 'store-' + owner,
    generation: generation, storeInstanceId: instance
  };
}

class MemorySelectionPort implements MoonlightCloudSyncSelectionStorePort {
  activeLease: AccountSessionLease | null = lease('owner-a');
  preferences: Map<string, string> = new Map<string, string>();
  events: string[] = [];
  projectionFailure: boolean = false;
  writeFailuresRemaining: number = 0;
  switchAfterProjection: boolean = false;

  currentAccountLease(): AccountSessionLease | null {
    return this.activeLease === null ? null :
      cloneAccountSessionLease(this.activeLease);
  }

  isLeaseCurrent(candidate: AccountSessionLease): boolean {
    return accountSessionLeaseEquals(this.activeLease, candidate);
  }

  readSelectionPreference(candidate: AccountSessionLease,
    key: string): string | null {
    if (!this.isLeaseCurrent(candidate)) { return null; }
    const value: string | undefined = this.preferences.get(key);
    return value === undefined ? null : value;
  }

  writeSelectionPreference(candidate: AccountSessionLease,
    key: string, value: string): boolean {
    this.events.push('persist:' + value);
    if (!this.isLeaseCurrent(candidate)) { return false; }
    if (this.writeFailuresRemaining > 0) {
      this.writeFailuresRemaining--;
      return false;
    }
    this.preferences.set(key, value);
    return true;
  }

  replaceMoonlightProjection(candidate: AccountSessionLease,
    previous: MoonlightCloudSyncScope[],
    next: MoonlightCloudSyncScope[]): boolean {
    this.events.push('project:' + previous.join('+') + '->' + next.join('+'));
    if (!this.isLeaseCurrent(candidate) || this.projectionFailure) {
      return false;
    }
    if (this.switchAfterProjection) {
      this.activeLease = lease('owner-b', candidate.generation + 1,
        candidate.storeInstanceId + 1);
    }
    return true;
  }
}

export default function moonlightCloudSyncSelectionPolicyTest(): void {
  describe('MoonlightCloudSyncSelectionPolicy', (): void => {
    it('defaults_to_no_logical_scope_and_normalizes_in_stable_order', 0,
      (): void => {
        expect(MOONLIGHT_CLOUD_SYNC_SELECTION_DEFAULT.length).assertEqual(0);
        const normalized: MoonlightCloudSyncScope[] =
          normalizeMoonlightCloudSyncSelection([
            'trust', 'hosts', 'unknown', 'hosts', 'settings'
          ]);
        expect(normalized.join(',')).assertEqual('settings,hosts,trust');
      });

    it('clips_identity_until_both_capability_and_crypto_are_ready', 0,
      (): void => {
        expect(normalizeMoonlightCloudSyncSelection(
          ['identity'], false).length).assertEqual(0);
        expect(normalizeMoonlightCloudSyncSelection(
          ['identity'], true).join(',')).assertEqual('identity');
        expect(moonlightIdentitySyncAllowed(
          ['identity'], true, false)).assertFalse();
        expect(moonlightIdentitySyncAllowed(
          ['identity'], true, true)).assertTrue();
      });

    it('maps_each_record_type_to_one_logical_scope', 0, (): void => {
      const types: MoonlightRecordType[] = [
        'settings', 'host', 'profile', 'trust', 'secret'
      ];
      const expected: string[] = [
        'settings', 'hosts', 'profiles', 'trust', 'identity'
      ];
      for (let i = 0; i < types.length; i++) {
        expect(moonlightRecordTypeToSyncScope(types[i])).assertEqual(expected[i]);
      }
      expect(isMoonlightRecordTypeSelected(
        'secret', ['identity'], false)).assertFalse();
      expect(isMoonlightRecordTypeSelected(
        'secret', ['identity'], true)).assertTrue();
    });

    it('uses_a_distinct_owner_scoped_preference_key', 0, (): void => {
      expect(moonlightCloudSyncSelectionPreferenceKey('owner-a'))
        .assertEqual('moonlightCloudSyncRecordScopes:owner-a');
      expect(moonlightCloudSyncSelectionPreferenceKey('owner-b'))
        .assertEqual('moonlightCloudSyncRecordScopes:owner-b');
      expect(moonlightCloudSyncSelectionPreferenceKey('')).assertEqual('');
    });

    it('loads_only_the_active_owner_and_fails_closed_on_malformed_preferences',
      0, (): void => {
        const port = new MemorySelectionPort();
        port.preferences.set(
          moonlightCloudSyncSelectionPreferenceKey('owner-a'),
          '["hosts","trust"]');
        const store = new MoonlightCloudSyncSelectionStore(port);
        expect(store.init(lease('owner-a'))).assertTrue();
        expect(store.selectedScopes().join(',')).assertEqual('hosts,trust');
        port.preferences.set(
          moonlightCloudSyncSelectionPreferenceKey('owner-a'),
          '["identity"]');
        expect(store.init(lease('owner-a'), false)).assertTrue();
        expect(store.selectedScopes().length).assertEqual(0);
        port.preferences.set(
          moonlightCloudSyncSelectionPreferenceKey('owner-a'), '{bad');
        expect(store.init(lease('owner-a'))).assertTrue();
        expect(store.selectedScopes().length).assertEqual(0);
        expect(store.init(lease('owner-b'))).assertFalse();
      });

    it('orders_stage_projection_and_durable_persist', 0, (): void => {
      const port = new MemorySelectionPort();
      const store = new MoonlightCloudSyncSelectionStore(port);
      expect(store.init(lease('owner-a'))).assertTrue();
      const changed = store.replaceSelectedScopes(
        lease('owner-a'), ['trust', 'hosts']);
      expect(changed.ok).assertTrue();
      expect(changed.selected.join(',')).assertEqual('hosts,trust');
      expect(port.events[0]).assertEqual('project:->hosts+trust');
      expect(port.events[1]).assertEqual('persist:["hosts","trust"]');
    });

    it('restores_memory_when_projection_fails', 0, (): void => {
      const port = new MemorySelectionPort();
      const store = new MoonlightCloudSyncSelectionStore(port);
      expect(store.init(lease('owner-a'))).assertTrue();
      port.projectionFailure = true;
      const changed = store.replaceSelectedScopes(
        lease('owner-a'), ['hosts']);
      expect(changed.ok).assertFalse();
      expect(changed.code).assertEqual('projection_failed');
      expect(store.selectedScopes().length).assertEqual(0);
      expect(port.preferences.size).assertEqual(0);
    });

    it('rolls_back_projection_on_persist_failure_and_rejects_stale_owner',
      0, (): void => {
        const port = new MemorySelectionPort();
        const store = new MoonlightCloudSyncSelectionStore(port);
        expect(store.init(lease('owner-a'))).assertTrue();
        port.writeFailuresRemaining = 1;
        const failed = store.replaceSelectedScopes(
          lease('owner-a'), ['hosts']);
        expect(failed.ok).assertFalse();
        expect(failed.code).assertEqual('persist_failed');
        expect(store.selectedScopes().length).assertEqual(0);
        expect(port.events[2]).assertEqual('project:hosts->');
        port.activeLease = lease('owner-b', 2, 2);
        expect(store.replaceSelectedScopes(
          lease('owner-a'), ['trust']).code).assertEqual('stale_lease');
      });
  });
}
