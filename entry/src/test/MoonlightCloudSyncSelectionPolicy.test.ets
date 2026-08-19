import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
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
  moonlightCloudSyncSelectionExpands,
  moonlightIdentitySyncAllowed,
  moonlightProjectionLocalOnlyAfterReconcile,
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
  switchAfterPreferenceWrite: boolean = false;
  projectedScopes: MoonlightCloudSyncScope[] = [];

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
    if (this.switchAfterPreferenceWrite) {
      this.activeLease = lease('owner-b', candidate.generation + 1,
        candidate.storeInstanceId + 1);
    }
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
    this.projectedScopes = next.slice();
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
        expect(normalized.join(',')).assertEqual('settings,hosts');
      });

    it('drops_orphaned_profiles_without_silently_expanding_host_consent',
      0, (): void => {
        expect(normalizeMoonlightCloudSyncSelection(
          ['profiles']).length).assertEqual(0);
        expect(normalizeMoonlightCloudSyncSelection(
          ['profiles', 'hosts']).join(','))
          .assertEqual('hosts,profiles');
      });

    it('keeps_device_identity_and_pairing_trust_out_of_cloud_v1', 0,
      (): void => {
        expect(normalizeMoonlightCloudSyncSelection(
          ['identity'], false).length).assertEqual(0);
        expect(normalizeMoonlightCloudSyncSelection(
          ['identity'], true).length).assertEqual(0);
        expect(moonlightIdentitySyncAllowed(
          ['identity'], true, false)).assertFalse();
        expect(moonlightIdentitySyncAllowed(
          ['identity'], true, true)).assertFalse();
      });

    it('distinguishes_consent_expansion_from_an_offline_safe_reduction', 0,
      (): void => {
        expect(moonlightCloudSyncSelectionExpands(
          ['settings'], ['settings', 'hosts'])).assertTrue();
        expect(moonlightCloudSyncSelectionExpands(
          ['settings', 'hosts', 'profiles'], ['settings', 'hosts']))
          .assertFalse();
        expect(moonlightCloudSyncSelectionExpands(
          ['settings', 'hosts'], [])).assertFalse();
        // An orphan profile is normalized away and therefore cannot be
        // misclassified as new consent.
        expect(moonlightCloudSyncSelectionExpands(
          [], ['profiles'])).assertFalse();
      });

    it('treats_localonly_as_mutation_provenance_during_projection_reconcile',
      0, (): void => {
        expect(moonlightProjectionLocalOnlyAfterReconcile(
          1, true, true)).assertEqual(0);
        expect(moonlightProjectionLocalOnlyAfterReconcile(
          1, true, false)).assertEqual(1);
        expect(moonlightProjectionLocalOnlyAfterReconcile(
          0, true, false)).assertEqual(0);
        expect(moonlightProjectionLocalOnlyAfterReconcile(
          0, false, false)).assertEqual(0);
        expect(moonlightProjectionLocalOnlyAfterReconcile(
          2, true, true)).assertEqual(-1);
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
        'secret', ['identity'], true)).assertFalse();
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
        expect(store.selectedScopes().join(',')).assertEqual('hosts');
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
      expect(changed.selected.join(',')).assertEqual('hosts');
      expect(port.events[0]).assertEqual('project:->hosts');
      expect(port.events[1]).assertEqual('persist:["hosts"]');
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

    it('reconciles_durable_owner_intent_after_a_mid_projection_account_switch',
      0, (): void => {
        const port = new MemorySelectionPort();
        const store = new MoonlightCloudSyncSelectionStore(port);
        expect(store.init(lease('owner-a'))).assertTrue();
        port.switchAfterProjection = true;
        const stale = store.replaceSelectedScopes(
          lease('owner-a'), ['hosts']);
        expect(stale.code).assertEqual('reconcile_pending');
        expect(stale.durableChanged).assertFalse();
        expect(port.projectedScopes.join(',')).assertEqual('hosts');
        expect(port.preferences.size).assertEqual(0);

        port.switchAfterProjection = false;
        port.activeLease = lease('owner-a', 3, 3);
        expect(store.init(lease('owner-a', 3, 3))).assertTrue();
        expect(store.selectedScopes().length).assertEqual(0);
        expect(store.reconcileProjection(
          lease('owner-a', 3, 3))).assertTrue();
        expect(port.projectedScopes.length).assertEqual(0);
      });

    it('rehydrates_committed_intent_after_a_post_persist_account_switch',
      0, (): void => {
        const port = new MemorySelectionPort();
        const store = new MoonlightCloudSyncSelectionStore(port);
        expect(store.init(lease('owner-a'))).assertTrue();
        port.switchAfterPreferenceWrite = true;
        const pending = store.replaceSelectedScopes(
          lease('owner-a'), ['hosts']);
        expect(pending.ok).assertFalse();
        expect(pending.code).assertEqual('reconcile_pending');
        expect(pending.selected.join(',')).assertEqual('hosts');
        expect(pending.projectionChanged).assertTrue();
        expect(pending.durableChanged).assertTrue();
        expect(port.projectedScopes.join(',')).assertEqual('hosts');

        port.switchAfterPreferenceWrite = false;
        port.activeLease = lease('owner-a', 3, 3);
        expect(store.init(lease('owner-a', 3, 3))).assertTrue();
        expect(store.selectedScopes().join(',')).assertEqual('hosts');
        expect(store.reconcileProjection(
          lease('owner-a', 3, 3))).assertTrue();
        expect(port.projectedScopes.join(',')).assertEqual('hosts');
      });
  });
}
