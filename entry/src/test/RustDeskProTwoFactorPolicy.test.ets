import { expect } from '@ohos/hypium';
import { auditedDescribe as describe, auditedIt as it } from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  RustDeskProApiError,
  RustDeskProLoginOutcome,
  parseRustDeskProLoginResponse
} from '../main/ets/services/RustDeskProApiPolicy';
import {
  isRustDeskProChallengeOutcome,
  requireAuthenticatedRustDeskProLogin,
  shouldRetryRustDeskProMinimalLogin,
  rustDeskProChallengeReadsTotp,
  rustDeskProChallengeAutoDecision,
  rustDeskProChallengeFenceMatches,
  RustDeskProChallengeUiFence
} from '../main/ets/services/RustDeskProTwoFactorPolicy';
import { rustDeskProBindingForChallengeOutcome } from
  '../main/ets/services/RustDeskProTwoFactorBindingStore';
import { TotpAlgorithm, TotpCode, TotpEntry } from '../main/ets/model/TotpEntry';

export default function rustDeskProTwoFactorPolicyTest() {
  describe('RustDeskProTwoFactorPolicy', () => {
    it('does_not_treat_challenge_as_authenticated', 0, () => {
      const outcome: RustDeskProLoginOutcome = parseRustDeskProLoginResponse({
        type: 'email_check', secret: 'secret', user: { name: 'alice' }
      }, 200);
      expect(isRustDeskProChallengeOutcome(outcome)).assertEqual(true);
      let code = '';
      try { requireAuthenticatedRustDeskProLogin(outcome); }
      catch (err) { code = err instanceof RustDeskProApiError ? err.code : ''; }
      expect(code).assertEqual('two_factor_required');
    });

    it('does_not_retry_primary_body_for_challenge_continuation', 0, () => {
      const error = new RustDeskProApiError(
        'http_error', 'rejected', 400, 'extended_login_unsupported');
      expect(shouldRetryRustDeskProMinimalLogin('primary', error)).assertEqual(true);
      expect(shouldRetryRustDeskProMinimalLogin('challenge', error)).assertEqual(false);
    });

    it('email_challenge_never_reads_totp_and_totp_requires_explicit_entry', 0, () => {
      expect(rustDeskProChallengeReadsTotp('email')).assertFalse();
      expect(rustDeskProChallengeReadsTotp('totp')).assertTrue();
      const entry = new TotpEntry();
      entry.algorithm = TotpAlgorithm.SHA1;
      entry.digits = 6;
      entry.period = 30;
      const code: TotpCode = {
        code: '123456', remaining: 20, total: 30, progress: 0.3,
        counter: 10, validUntilMs: Date.now() + 20000, valid: true
      };
      expect(rustDeskProChallengeAutoDecision(
        'email', true, entry, code, Date.now() + 60000)).assertEqual('email_manual');
      expect(rustDeskProChallengeAutoDecision(
        'totp', false, entry, code, Date.now() + 60000)).assertEqual('totp_manual');
      expect(rustDeskProChallengeAutoDecision(
        'totp', true, entry, code, Date.now() + 60000)).assertEqual('totp_submit');
    });

    it('challenge_fence_rejects_replaced_or_expired_snapshot', 0, () => {
      const now: number = Date.now();
      const expected: RustDeskProChallengeUiFence = {
        accountDraftId: 'account', normalizedApiOrigin: 'https://pro.example',
        generation: 1, challengeId: 'c1', receivedAt: now, deadline: now + 60000
      };
      expect(rustDeskProChallengeFenceMatches(expected, expected, now + 1000)).assertTrue();
      const replaced: RustDeskProChallengeUiFence = {
        accountDraftId: expected.accountDraftId,
        normalizedApiOrigin: expected.normalizedApiOrigin,
        generation: expected.generation, challengeId: 'c2',
        receivedAt: expected.receivedAt + 1, deadline: expected.deadline
      };
      expect(rustDeskProChallengeFenceMatches(expected, replaced, now + 1000)).assertFalse();
      expect(rustDeskProChallengeFenceMatches(expected, expected, expected.deadline + 1)).assertFalse();
    });

    it('creates_account_binding_only_after_authenticated_second_step', 0, () => {
      expect(rustDeskProBindingForChallengeOutcome(
        'challenge', 'owner-a', 'account-a', 'entry-a', true, true)).assertNull();
      const binding = rustDeskProBindingForChallengeOutcome(
        'authenticated', 'owner-a', 'account-a', 'entry-a', true, true, 100);
      expect(binding !== null).assertTrue();
      if (binding !== null) {
        expect(binding.ownerScopeId).assertEqual('owner-a');
        expect(binding.accountId).assertEqual('account-a');
        expect(binding.entryId).assertEqual('entry-a');
        expect(JSON.stringify(binding).indexOf('password')).assertEqual(-1);
        expect(JSON.stringify(binding).indexOf('token')).assertEqual(-1);
      }
      expect(rustDeskProBindingForChallengeOutcome(
        'authenticated', 'owner-a', 'account-a', 'entry-a', true, false)).assertNull();
    });
  });
}
