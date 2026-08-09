import { expect } from '@ohos/hypium';
import { auditedDescribe as describe, auditedIt as it } from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  isRustDeskProChallengeSnapshotCurrent,
  RustDeskProChallengeRequiredError,
  RustDeskProChallengeSnapshot,
  RustDeskProChallengeSubmitGate,
  RustDeskProLoginOperationGate,
  shouldKeepRustDeskProChallengeAfterFailure,
  shouldPersistRustDeskProAccessToken
} from '../main/ets/services/RustDeskProSyncService';
import { RustDeskProApiError } from '../main/ets/services/RustDeskProApiPolicy';

function snapshot(deadline: number, challengeId: string = 'challenge-s1',
  receivedAt: number = 100): RustDeskProChallengeSnapshot {
  return {
    accountDraftId: 'draft-a', normalizedApiOrigin: 'https://pro.example.test',
    generation: 7, challengeId, kind: 'totp', responseType: 'email_check',
    tfaType: 'tfa_check', maskedDestination: '', maskedUsername: 'f***',
    receivedAt, deadline
  };
}

export default function rustDeskProSyncServiceTest(): void {
  describe('RustDeskProSyncService challenge lifecycle', (): void => {
    it('rejects_stale_origin_generation_and_expired_snapshots', 0, (): void => {
      const current: RustDeskProChallengeSnapshot = snapshot(5000);
      expect(isRustDeskProChallengeSnapshotCurrent(
        current, 'draft-a', 'https://pro.example.test', 7, 1000)).assertTrue();
      expect(isRustDeskProChallengeSnapshotCurrent(
        current, 'draft-a', 'https://other.example.test', 7, 1000)).assertFalse();
      expect(isRustDeskProChallengeSnapshotCurrent(
        current, 'draft-a', 'https://pro.example.test', 8, 1000)).assertFalse();
      expect(isRustDeskProChallengeSnapshotCurrent(
        current, 'draft-a', 'https://pro.example.test', 7, 5000)).assertFalse();
    });

    it('binds_deferred_submit_to_challenge_identity_after_same_scope_replacement', 0,
      async (): Promise<void> => {
        const first: RustDeskProChallengeSnapshot = snapshot(5000, 'challenge-s1', 100);
        const second: RustDeskProChallengeSnapshot = snapshot(6000, 'challenge-s2', 200);
        let active: RustDeskProChallengeSnapshot = first;
        let staleSubmitApplied: boolean = false;
        let resolveFirst: () => void = (): void => {};
        const firstSubmit: Promise<void> = new Promise<void>((resolve: () => void): void => {
          resolveFirst = resolve;
        }).then((): void => {
          staleSubmitApplied = isRustDeskProChallengeSnapshotCurrent(
            active, first.accountDraftId, first.normalizedApiOrigin, first.generation,
            1000, first.challengeId, first.receivedAt, first.deadline);
        });
        active = second;
        resolveFirst();
        await firstSubmit;
        expect(staleSubmitApplied).assertFalse();
        expect(active.challengeId).assertEqual('challenge-s2');
        expect(isRustDeskProChallengeSnapshotCurrent(
          active, second.accountDraftId, second.normalizedApiOrigin, second.generation,
          1000, second.challengeId, second.receivedAt, second.deadline)).assertTrue();
      });

    it('keeps_only_retryable_challenge_failures_in_memory', 0, (): void => {
      expect(shouldKeepRustDeskProChallengeAfterFailure('pro_totp_wrong_code')).assertTrue();
      expect(shouldKeepRustDeskProChallengeAfterFailure('pro_email_wrong_code')).assertTrue();
      expect(shouldKeepRustDeskProChallengeAfterFailure('pro_challenge_rate_limited')).assertTrue();
      expect(shouldKeepRustDeskProChallengeAfterFailure('network_error')).assertTrue();
      expect(shouldKeepRustDeskProChallengeAfterFailure('pro_challenge_expired')).assertFalse();
      expect(shouldKeepRustDeskProChallengeAfterFailure('pro_challenge_unsupported')).assertFalse();
    });

    it('compatibility_error_carries_safe_challenge_snapshot_only', 0, (): void => {
      const error = new RustDeskProChallengeRequiredError(snapshot(5000));
      expect(error.code).assertEqual('two_factor_required');
      expect(JSON.stringify(error.challenge).indexOf('secret')).assertEqual(-1);
      expect(error.challenge.generation).assertEqual(7);
    });

    it('persists_token_only_after_authenticated_post_login_work', 0, (): void => {
      expect(shouldPersistRustDeskProAccessToken('challenge', true)).assertFalse();
      expect(shouldPersistRustDeskProAccessToken('authenticated', false)).assertFalse();
      expect(shouldPersistRustDeskProAccessToken('authenticated', true)).assertTrue();
    });

    it('guards_deferred_login_and_duplicate_challenge_submit_races', 0,
      async (): Promise<void> => {
        const loginGate = new RustDeskProLoginOperationGate();
        const first = loginGate.begin(1);
        let duplicateCode: string = '';
        try { loginGate.begin(1); }
        catch (err) { duplicateCode = err instanceof RustDeskProApiError ? err.code : ''; }
        expect(duplicateCode).assertEqual('login_in_flight');

        let resolveFirst: () => void = (): void => {};
        const deferred: Promise<void> = new Promise<void>((resolve: () => void): void => {
          resolveFirst = resolve;
        });
        const staleCompletion: Promise<void> = deferred.then((): void => {
          // This is the old async finally/release arriving after replacement.
          loginGate.release(first.nonce);
        });
        loginGate.invalidate();
        const second = loginGate.begin(2);
        resolveFirst();
        await staleCompletion;
        expect(loginGate.isCurrent(first.nonce)).assertFalse();
        expect(loginGate.isCurrent(second.nonce)).assertTrue();
        loginGate.release(first.nonce);
        expect(loginGate.isCurrent(second.nonce)).assertTrue();
        loginGate.release(second.nonce);

        const submitGate = new RustDeskProChallengeSubmitGate();
        const firstSubmit: number = submitGate.begin();
        let submitDuplicateCode: string = '';
        try { submitGate.begin(); }
        catch (err) { submitDuplicateCode = err instanceof RustDeskProApiError ? err.code : ''; }
        expect(submitDuplicateCode).assertEqual('challenge_submit_in_flight');
        submitGate.invalidate();
        const secondSubmit: number = submitGate.begin();
        submitGate.release(firstSubmit);
        expect(submitGate.isCurrent(secondSubmit)).assertTrue();
        submitGate.release(secondSubmit);
      });
  });
}
