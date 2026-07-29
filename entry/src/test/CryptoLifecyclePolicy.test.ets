import { describe, expect, it } from '@ohos/hypium';
import { AccountSessionLease } from '../main/ets/services/AccountScopePolicy';
import {
  CryptoCommittedState,
  CryptoLifecycleDurableState,
  cryptoLifecycleCanConfigure,
  cryptoLifecycleCanDisable,
  cryptoLifecycleCanReset,
  cryptoLifecycleMemoryStateChanged,
  cryptoLifecycleOperationCommitted,
  cryptoLifecycleOperationFailed,
  cryptoLifecycleOperationStarted,
  cryptoLifecycleSensitiveWriteAllowed,
  newCryptoLifecycleDurableState,
  recoverCryptoLifecycleDurableState
} from '../main/ets/services/CryptoLifecyclePolicy';

function lease(generation: number = 3): AccountSessionLease {
  return {
    ownerScopeId: 'owner-a',
    storeIdentity: 'remotedesktop_owner-a.db',
    generation,
    storeInstanceId: 9
  };
}

function committed(
  status: string = '', configured: boolean = false
): CryptoCommittedState {
  return {
    status,
    configured,
    kdfVersion: configured ? 2 : 0,
    kdfIterations: configured ? 600000 : 0,
    keyVersion: configured ? 1 : 0,
    verifierVersion: configured ? 2 : 0,
    envelopeVersion: configured ? 3 : 0
  };
}

export default function cryptoLifecyclePolicyTest(): void {
  describe('CryptoLifecyclePolicy', (): void => {
    it('starts_disabled_and_only_allows_configuration_or_reset_from_safe_states',
      0, (): void => {
        const state: CryptoLifecycleDurableState =
          newCryptoLifecycleDurableState(lease(), committed(), 1);
        expect(state.phase).assertEqual('disabled');
        expect(cryptoLifecycleCanConfigure(state)).assertTrue();
        expect(cryptoLifecycleCanDisable(state)).assertFalse();
        expect(cryptoLifecycleCanReset(state)).assertFalse();
        expect(cryptoLifecycleSensitiveWriteAllowed(
          state, false, false)).assertTrue();
      });

    it('recovers_interrupted_configuration_from_the_atomic_committed_side',
      0, (): void => {
        const initial: CryptoLifecycleDurableState =
          newCryptoLifecycleDurableState(lease(), committed(), 1);
        const configuring: CryptoLifecycleDurableState =
          cryptoLifecycleOperationStarted(
            initial, 'configuring', 'tx-1', 2);
        const rolledBack: CryptoLifecycleDurableState =
          recoverCryptoLifecycleDurableState(
            configuring, lease(4), committed(), 3);
        expect(rolledBack.phase).assertEqual('disabled');

        const committedActive: CryptoLifecycleDurableState =
          recoverCryptoLifecycleDurableState(
            configuring, lease(4), committed('active', true), 4);
        expect(committedActive.phase).assertEqual('active_locked');
      });

    it('never_persists_an_unlocked_key_across_process_restart', 0, (): void => {
      let state: CryptoLifecycleDurableState =
        newCryptoLifecycleDurableState(
          lease(), committed('active', true), 1);
      state = cryptoLifecycleMemoryStateChanged(state, true, 2);
      expect(state.phase).assertEqual('active_unlocked');
      const recovered: CryptoLifecycleDurableState =
        recoverCryptoLifecycleDurableState(
          state, lease(4), committed('active', true), 3);
      expect(recovered.phase).assertEqual('active_locked');
    });

    it('commits_disable_only_with_cleared_crypto_parameters', 0, (): void => {
      let state: CryptoLifecycleDurableState =
        newCryptoLifecycleDurableState(
          lease(), committed('active', true), 1);
      state = cryptoLifecycleMemoryStateChanged(state, true, 2);
      expect(cryptoLifecycleCanDisable(state)).assertTrue();
      state = cryptoLifecycleOperationStarted(
        state, 'disabling', 'tx-disable', 3);
      state = cryptoLifecycleOperationCommitted(
        state, 'disabled', committed('disabled', false), 4);
      expect(state.phase).assertEqual('disabled');
      expect(state.kdfIterations).assertEqual(0);
    });

    it('fails_closed_on_bad_state_and_stale_transaction_completion',
      0, (): void => {
        const initial: CryptoLifecycleDurableState =
          newCryptoLifecycleDurableState(
            lease(), committed('active', true), 1);
        const migrating: CryptoLifecycleDurableState =
          cryptoLifecycleOperationStarted(
            initial, 'migrating', 'tx-current', 2);
        const stale: CryptoLifecycleDurableState =
          cryptoLifecycleOperationFailed(
            migrating, 'tx-old', 'ignored', 3);
        expect(stale.phase).assertEqual('migrating');
      const failed: CryptoLifecycleDurableState =
          cryptoLifecycleOperationFailed(
            stale, 'tx-current', 'row_context_mismatch', 4);
      expect(failed.phase).assertEqual('recovery_required');
      expect(cryptoLifecycleCanReset(failed)).assertTrue();
      expect(cryptoLifecycleSensitiveWriteAllowed(
        failed, true, true)).assertFalse();
      });

    it('treats_unknown_persisted_phases_as_recovery_required', 0, (): void => {
      const invalid: CryptoLifecycleDurableState =
        newCryptoLifecycleDurableState(
          lease(), committed('active', true), 1);
      invalid.phase = 'future' as never;
      const recovered: CryptoLifecycleDurableState =
        recoverCryptoLifecycleDurableState(
          invalid, lease(4), committed('active', true), 2);
      expect(recovered.phase).assertEqual('recovery_required');
    });
  });
}
