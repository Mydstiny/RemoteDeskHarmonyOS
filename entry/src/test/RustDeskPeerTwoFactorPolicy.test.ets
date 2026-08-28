import { expect } from '@ohos/hypium';
import { common } from '@kit.AbilityKit';
import { TotpAlgorithm, TotpCode, TotpEntry } from '../main/ets/model/TotpEntry';
import { TotpEngine } from '../main/ets/services/TotpEngine';
import { RemoteHost, RemoteHostJSON } from '../main/ets/model/RemoteHost';
import {
  copyRustDeskPeerTwoFactorRuntime,
  hydrateRustDeskPeerTwoFactorHost,
  scrubRustDeskPeerTwoFactorRuntime,
  rustDeskPeerTwoFactorBindingFromHost,
  RustDeskPeerTwoFactorBinding,
  RustDeskPeerTwoFactorBindingMemory,
  RustDeskPeerTwoFactorPreferenceAdapter,
  RustDeskPeerTwoFactorPreferenceRead,
  RustDeskPeerTwoFactorBindingStore,
  rustDeskPeerTwoFactorEndpointIdentity,
  setRustDeskPeerTwoFactorPreferenceAdapterForTest,
  shouldRemoveDanglingRustDeskPeerTwoFactorBinding
} from '../main/ets/services/RustDeskPeerTwoFactorBindingStore';
import { RustDeskAuthDraftStore } from '../main/ets/services/RustDeskAuthDraftStore';
import {
  decodeRustDeskPeerTwoFactorLegacyBackupRows,
  decodeRustDeskPeerTwoFactorLegacyDisplayConfig,
  migrateRustDeskPeerTwoFactorLegacyCandidate,
  RustDeskPeerTwoFactorLegacyCandidate
} from '../main/ets/services/RustDeskPeerTwoFactorLegacyMigration';
import {
  RustDeskPeerTwoFactorController,
  RustDeskPeerTwoFactorClock,
  isRustDeskPeerTwoFactorAutoSubmitCompatible,
  isRustDeskPeerTwoFactorManualCode,
  rustDeskPeerTwoFactorSafeWindowWaitMs,
  rustDeskPeerTwoFactorAutoSubmitError,
  RUSTDESK_PEER_2FA_MIN_REMAINING_SECONDS,
  rustDeskPeerTwoFactorPendingDeadlineFromReceivedAt,
  rustDeskPeerTwoFactorPendingDeadlineExpired
} from '../main/ets/services/RustDeskPeerTwoFactorPolicy';
import { auditedDescribe as describe, auditedIt as it } from '../main/ets/services/FocusedTestRegistrationAudit';

function makeLegacyPeerHost(hostId: string): RemoteHost {
  const host: RemoteHost = new RemoteHost();
  host.id = hostId;
  host.userId = 'owner-a';
  host.protocol = 'rustdesk';
  host.host = 'peer-' + hostId;
  host.rustdeskRelayId = 'relay-a';
  return host;
}

class MemoryPeerTwoFactorPreferences implements RustDeskPeerTwoFactorPreferenceAdapter {
  private values: Map<string, string> = new Map<string, string>();

  read(_context: common.Context, storeName: string,
    key: string): RustDeskPeerTwoFactorPreferenceRead {
    return { ok: true, value: this.values.get(storeName + '\u001f' + key) ?? '' };
  }

  write(_context: common.Context, storeName: string,
    key: string, value: string): boolean {
    this.values.set(storeName + '\u001f' + key, value);
    return true;
  }
}

export default function rustDeskPeerTwoFactorPolicyTest(): void {
  describe('RustDeskPeerTwoFactorPolicy', (): void => {
    it('accepts_only_the_supported_manual_code_lengths', 0, (): void => {
      expect(isRustDeskPeerTwoFactorManualCode('123456')).assertTrue();
      expect(isRustDeskPeerTwoFactorManualCode('12345678')).assertTrue();
      expect(isRustDeskPeerTwoFactorManualCode('12345')).assertFalse();
      expect(isRustDeskPeerTwoFactorManualCode('1234567')).assertFalse();
      expect(isRustDeskPeerTwoFactorManualCode('12345x')).assertFalse();
    });

    it('limits_automatic_submission_to_the_official_rustdesk_totp_shape', 0, (): void => {
      const entry = new TotpEntry();
      entry.algorithm = TotpAlgorithm.SHA1;
      entry.digits = 6;
      entry.period = 30;
      expect(isRustDeskPeerTwoFactorAutoSubmitCompatible(entry)).assertTrue();
      entry.digits = 8;
      expect(isRustDeskPeerTwoFactorAutoSubmitCompatible(entry)).assertFalse();
      entry.digits = 6;
      entry.algorithm = TotpAlgorithm.SHA256;
      expect(isRustDeskPeerTwoFactorAutoSubmitCompatible(entry)).assertFalse();
    });

    it('falls_back_to_manual_input_at_the_totp_period_boundary', 0, (): void => {
      const entry = new TotpEntry();
      const safe: TotpCode = {
        code: '123456', remaining: RUSTDESK_PEER_2FA_MIN_REMAINING_SECONDS,
        total: 30, progress: 0.5, counter: 10,
        validUntilMs: Date.now() + 10000, valid: true
      };
      expect(rustDeskPeerTwoFactorAutoSubmitError(entry, safe)).assertEqual('');
      const expiring: TotpCode = {
        code: '123456', remaining: RUSTDESK_PEER_2FA_MIN_REMAINING_SECONDS - 1,
        total: 30, progress: 0.9, counter: 10,
        validUntilMs: Date.now() + 10000, valid: true
      };
      expect(rustDeskPeerTwoFactorAutoSubmitError(entry, expiring).indexOf('即将更新') >= 0)
        .assertTrue();
    });

    it('exposes_runtime_counter_and_validity_without_changing_entry_json', 0, (): void => {
      const entry = new TotpEntry();
      entry.secret = 'JBSWY3DPEHPK3PXP';
      entry.algorithm = TotpAlgorithm.SHA1;
      entry.digits = 6;
      entry.period = 30;
      const generated: TotpCode = TotpEngine.generateCodeAt(entry, 29000);
      expect(generated.counter).assertEqual(0);
      expect(generated.validUntilMs).assertEqual(30000);
      expect(generated.valid).assertTrue();
      const json: Record<string, Object> = entry.toJSON() as Record<string, Object>;
      expect(json['counter']).assertUndefined();
      expect(json['validUntilMs']).assertUndefined();
      expect(json['valid']).assertUndefined();
    });

    it('waits_for_a_safe_next_counter_when_pending_deadline_allows_it', 0,
      async (): Promise<void> => {
        const entry: TotpEntry = new TotpEntry();
        entry.id = 'peer-totp';
        entry.secret = 'JBSWY3DPEHPK3PXP';
        let nowMs: number = 29000;
        let authCalls: number = 0;
        let submitCalls: number = 0;
        const clock: RustDeskPeerTwoFactorClock = {
          now: (): number => nowMs,
          sleep: async (milliseconds: number): Promise<void> => { nowMs += milliseconds; }
        };
        const controller: RustDeskPeerTwoFactorController = new RustDeskPeerTwoFactorController();
        const ticket = controller.begin('session-a', entry.id, 50000);
        const result = await controller.attempt(ticket, {
          clock,
          loadEntry: (): TotpEntry => entry,
          authenticate: async (): Promise<boolean> => { authCalls++; return true; },
          submit: (_code: string): boolean => { submitCalls++; return true; }
        });
        expect(result.kind).assertEqual('submitted');
        expect(authCalls).assertEqual(1);
        expect(submitCalls).assertEqual(1);
        expect(nowMs >= 30000).assertTrue();
      });

    it('near_boundary_with_short_deadline_goes_manual_without_auth_or_submit', 0,
      async (): Promise<void> => {
        const entry: TotpEntry = new TotpEntry();
        entry.id = 'peer-totp-short';
        entry.secret = 'JBSWY3DPEHPK3PXP';
        let authCalls: number = 0;
        let submitCalls: number = 0;
        const controller: RustDeskPeerTwoFactorController = new RustDeskPeerTwoFactorController();
        const ticket = controller.begin('session-short', entry.id, 32000);
        const result = await controller.attempt(ticket, {
          clock: {
            now: (): number => 29000,
            sleep: async (_milliseconds: number): Promise<void> => {}
          },
          loadEntry: (): TotpEntry => entry,
          authenticate: async (): Promise<boolean> => { authCalls++; return true; },
          submit: (_code: string): boolean => { submitCalls++; return true; }
        });
        expect(result.kind).assertEqual('manual');
        expect(authCalls).assertEqual(0);
        expect(submitCalls).assertEqual(0);
        expect(rustDeskPeerTwoFactorSafeWindowWaitMs(
          { code: '123456', remaining: 1, total: 30, progress: 0.96,
            counter: 0, validUntilMs: 30000, valid: true },
          32000, 29000)).assertEqual(-1);
        expect(rustDeskPeerTwoFactorSafeWindowWaitMs(
          { code: '123456', remaining: 20, total: 30, progress: 0.3,
            counter: 0, validUntilMs: 60000, valid: true },
          32000, 29000)).assertEqual(-1);
      });

    it('cancel_during_wait_invalidates_late_auth_and_submit', 0,
      async (): Promise<void> => {
        const entry: TotpEntry = new TotpEntry();
        entry.id = 'peer-totp-cancel';
        entry.secret = 'JBSWY3DPEHPK3PXP';
        const controller: RustDeskPeerTwoFactorController = new RustDeskPeerTwoFactorController();
        const ticket = controller.begin('session-cancel', entry.id, 50000);
        const resultPromise = controller.attempt(ticket, {
          clock: {
            now: (): number => 29000,
            sleep: async (_milliseconds: number): Promise<void> => { controller.cancel(ticket); }
          },
          loadEntry: (): TotpEntry => entry,
          authenticate: async (): Promise<boolean> => true,
          submit: (_code: string): boolean => true
        });
        const result = await resultPromise;
        expect(result.kind).assertEqual('cancelled');
      });

    it('authentication_cancel_does_not_consume_counter_or_block_user_retry', 0,
      async (): Promise<void> => {
        const entry = new TotpEntry();
        entry.id = 'peer-totp-auth-cancel';
        entry.secret = 'JBSWY3DPEHPK3PXP';
        const controller: RustDeskPeerTwoFactorController =
          new RustDeskPeerTwoFactorController();
        const ticket = controller.begin('session-auth-cancel', entry.id, 100000);
        let authenticateCalls: number = 0;
        const input = {
          clock: { now: (): number => 1000,
            sleep: async (_milliseconds: number): Promise<void> => {} },
          loadEntry: (): TotpEntry => entry,
          authenticate: async (): Promise<boolean> => {
            authenticateCalls++;
            return authenticateCalls > 1;
          },
          submit: (_code: string): boolean => true
        };
        const cancelled = await controller.attempt(ticket, input);
        expect(cancelled.kind).assertEqual('auth_cancelled');
        expect(controller.hasAcceptedCounter(ticket, cancelled.counter)).assertFalse();
        const retried = await controller.attempt(ticket, input, true);
        expect(retried.kind).assertEqual('submitted');
      });

    it('fences_repeated_auth_cancelled_polling_until_explicit_user_retry', 0,
      async (): Promise<void> => {
        const entry: TotpEntry = new TotpEntry();
        entry.id = 'peer-totp-auth-fence';
        entry.secret = 'JBSWY3DPEHPK3PXP';
        const controller: RustDeskPeerTwoFactorController =
          new RustDeskPeerTwoFactorController();
        const ticket = controller.begin('session-auth-fence', entry.id, 100000);
        let authenticateCalls: number = 0;
        let submitCalls: number = 0;
        let authenticationAllowed: boolean = false;
        const input = {
          clock: { now: (): number => 1000,
            sleep: async (_milliseconds: number): Promise<void> => {} },
          loadEntry: (): TotpEntry => entry,
          authenticate: async (): Promise<boolean> => {
            authenticateCalls++;
            return authenticationAllowed;
          },
          submit: (_code: string): boolean => { submitCalls++; return true; }
        };
        expect((await controller.attempt(ticket, input)).kind).assertEqual('auth_cancelled');
        expect(controller.isManualRequired(ticket)).assertTrue();
        expect((await controller.attempt(ticket, input)).kind).assertEqual('manual');
        expect((await controller.attempt(ticket, input)).kind).assertEqual('manual');
        expect((await controller.attempt(ticket, input)).kind).assertEqual('manual');
        expect(authenticateCalls).assertEqual(1);
        expect(submitCalls).assertEqual(0);
        authenticationAllowed = true;
        expect((await controller.attempt(ticket, input, true)).kind).assertEqual('submitted');
        expect(authenticateCalls).assertEqual(2);
        expect(submitCalls).assertEqual(1);
      });

    it('fences_repeated_keyvault_failure_until_explicit_user_retry', 0,
      async (): Promise<void> => {
        const entry: TotpEntry = new TotpEntry();
        entry.id = 'peer-totp-keyvault-fence';
        entry.secret = 'JBSWY3DPEHPK3PXP';
        const controller: RustDeskPeerTwoFactorController =
          new RustDeskPeerTwoFactorController();
        const ticket = controller.begin('session-keyvault-fence', entry.id, 100000);
        let loadCalls: number = 0;
        let available: boolean = false;
        const input = {
          clock: { now: (): number => 1000,
            sleep: async (_milliseconds: number): Promise<void> => {} },
          loadEntry: (): TotpEntry | undefined => {
            loadCalls++;
            return available ? entry : undefined;
          },
          authenticate: async (): Promise<boolean> => true,
          submit: (_code: string): boolean => true
        };
        expect((await controller.attempt(ticket, input)).kind).assertEqual('keyvault_failed');
        expect((await controller.attempt(ticket, input)).kind).assertEqual('manual');
        expect((await controller.attempt(ticket, input)).kind).assertEqual('manual');
        expect(loadCalls).assertEqual(1);
        available = true;
        expect((await controller.attempt(ticket, input, true)).kind).assertEqual('submitted');
        expect(loadCalls).assertEqual(3);
      });

    it('fences_authentication_exception_fail_closed_until_explicit_user_retry', 0,
      async (): Promise<void> => {
        const entry: TotpEntry = new TotpEntry();
        entry.id = 'peer-totp-auth-exception';
        entry.secret = 'JBSWY3DPEHPK3PXP';
        const controller: RustDeskPeerTwoFactorController =
          new RustDeskPeerTwoFactorController();
        const ticket = controller.begin('session-auth-exception', entry.id, 100000);
        let authenticateCalls: number = 0;
        let shouldThrow: boolean = true;
        const input = {
          clock: { now: (): number => 1000,
            sleep: async (_milliseconds: number): Promise<void> => {} },
          loadEntry: (): TotpEntry => entry,
          authenticate: async (): Promise<boolean> => {
            authenticateCalls++;
            if (shouldThrow) { throw new Error('test auth failure'); }
            return true;
          },
          submit: (_code: string): boolean => true
        };
        const first = await controller.attempt(ticket, input);
        expect(first.kind).assertEqual('manual');
        expect(first.reason).assertEqual('automatic_attempt_failed_manual_retry');
        expect(controller.isManualRequired(ticket)).assertTrue();
        expect((await controller.attempt(ticket, input)).kind).assertEqual('manual');
        expect(authenticateCalls).assertEqual(1);
        shouldThrow = false;
        expect((await controller.attempt(ticket, input, true)).kind).assertEqual('submitted');
        expect(authenticateCalls).assertEqual(2);
      });

    it('reuses_the_same_epoch_and_deadline_for_repeated_native_polling', 0, (): void => {
      const controller: RustDeskPeerTwoFactorController =
        new RustDeskPeerTwoFactorController();
      const first = controller.begin('session-same-poll', 'entry-same-poll', 90000);
      const second = controller.begin('session-same-poll', 'entry-same-poll', 90000);
      expect(second.epoch).assertEqual(first.epoch);
      expect(second.pendingDeadlineMs).assertEqual(first.pendingDeadlineMs);
      expect(controller.isCurrent(second)).assertTrue();
    });

    it('wrong_native_result_stops_unattended_retry_but_user_retry_is_allowed', 0,
      async (): Promise<void> => {
        const entry: TotpEntry = new TotpEntry();
        entry.id = 'peer-totp-wrong';
        entry.secret = 'JBSWY3DPEHPK3PXP';
        const controller: RustDeskPeerTwoFactorController = new RustDeskPeerTwoFactorController();
        const ticket = controller.begin('session-wrong', entry.id, 100000);
        let submissions: number = 0;
        const input = {
          clock: { now: (): number => 1000,
            sleep: async (_milliseconds: number): Promise<void> => {} },
          loadEntry: (): TotpEntry => entry,
          authenticate: async (): Promise<boolean> => true,
          submit: (_code: string): boolean => { submissions++; return submissions > 1; }
        };
        expect((await controller.attempt(ticket, input)).kind).assertEqual('wrong_code');
        expect((await controller.attempt(ticket, input)).kind).assertEqual('manual');
        expect((await controller.attempt(ticket, input, true)).kind).assertEqual('submitted');
      expect(submissions).assertEqual(2);
    });

    it('coalesces_same_scope_concurrent_submit_and_keeps_the_late_result_owned', 0,
      async (): Promise<void> => {
        const entry = new TotpEntry();
        entry.id = 'peer-totp-race';
        entry.secret = 'JBSWY3DPEHPK3PXP';
        const controller: RustDeskPeerTwoFactorController =
          new RustDeskPeerTwoFactorController();
        const ticket = controller.begin('session-race', entry.id, 100000);
        let authStarted: (() => void) | null = null;
        let releaseAuth: (() => void) | null = null;
        const started: Promise<void> = new Promise<void>((resolve: () => void): void => {
          authStarted = resolve;
        });
        const authGate: Promise<void> = new Promise<void>((resolve: () => void): void => {
          releaseAuth = resolve;
        });
        let submitCalls: number = 0;
        const input = {
          clock: { now: (): number => 1000,
            sleep: async (_milliseconds: number): Promise<void> => {} },
          loadEntry: (): TotpEntry => entry,
          authenticate: async (): Promise<boolean> => {
            if (authStarted !== null) { authStarted(); authStarted = null; }
            await authGate;
            return true;
          },
          submit: (_code: string): boolean => { submitCalls++; return true; }
        };
        const first = controller.attempt(ticket, input);
        await started;
        const second = await controller.attempt(ticket, input);
        expect(second.kind).assertEqual('already_submitted');
        if (releaseAuth !== null) { releaseAuth(); releaseAuth = null; }
        const firstResult = await first;
        expect(firstResult.kind).assertEqual('submitted');
        expect(submitCalls).assertEqual(1);
      });

    it('replacement_epoch_blocks_stale_completion_without_clearing_new_state', 0,
      async (): Promise<void> => {
        const entry = new TotpEntry();
        entry.id = 'peer-totp-replacement';
        entry.secret = 'JBSWY3DPEHPK3PXP';
        const controller = new RustDeskPeerTwoFactorController();
        const first = controller.begin('session-replacement', entry.id, 5000);
        let authenticationStarted: (() => void) | null = null;
        let releaseAuthentication: (() => void) | null = null;
        const started = new Promise<void>((resolve: () => void): void => {
          authenticationStarted = resolve;
        });
        const authenticationGate = new Promise<void>((resolve: () => void): void => {
          releaseAuthentication = resolve;
        });
        let submitCalls: number = 0;
        const firstAttempt = controller.attempt(first, {
          clock: { now: (): number => 1000,
            sleep: async (_milliseconds: number): Promise<void> => {} },
          loadEntry: (): TotpEntry => entry,
          authenticate: async (): Promise<boolean> => {
            if (authenticationStarted !== null) {
              authenticationStarted();
              authenticationStarted = null;
            }
            await authenticationGate;
            return true;
          },
          submit: (_code: string): boolean => { submitCalls++; return true; }
        });
        await started;
        const second = controller.begin('session-replacement', entry.id, 6000);
        const secondResult = await controller.attempt(second, {
          clock: { now: (): number => 1000,
            sleep: async (_milliseconds: number): Promise<void> => {} },
          loadEntry: (): TotpEntry => entry,
          authenticate: async (): Promise<boolean> => true,
          submit: (_code: string): boolean => { submitCalls++; return true; }
        });
        expect(secondResult.kind).assertEqual('submitted');
        expect(controller.hasAcceptedCounter(second, secondResult.counter)).assertTrue();
        if (releaseAuthentication !== null) {
          releaseAuthentication();
          releaseAuthentication = null;
        }
        const firstResult = await firstAttempt;
        expect(firstResult.kind).assertEqual('cancelled');
        expect(controller.isCurrent(second)).assertTrue();
        expect(controller.hasAcceptedCounter(second, secondResult.counter)).assertTrue();
        expect(submitCalls).assertEqual(1);
        controller.cancel(second);
        expect(controller.hasAcceptedCounter(second, secondResult.counter)).assertFalse();
      });

    it('derives_one_local_pending_deadline_and_treats_the_boundary_as_expired', 0, (): void => {
      expect(rustDeskPeerTwoFactorPendingDeadlineFromReceivedAt(1000, 60000))
        .assertEqual(61000);
      expect(rustDeskPeerTwoFactorPendingDeadlineFromReceivedAt(1000, 60000))
        .assertEqual(61000);
      expect(rustDeskPeerTwoFactorPendingDeadlineExpired(61000, 60999)).assertFalse();
      expect(rustDeskPeerTwoFactorPendingDeadlineExpired(61000, 61000)).assertTrue();
      expect(rustDeskPeerTwoFactorPendingDeadlineFromReceivedAt(0, 60000)).assertEqual(0);
    });

    it('crosses_pending_deadline_after_authentication_without_calling_submit', 0,
      async (): Promise<void> => {
        const entry = new TotpEntry();
        entry.id = 'peer-totp-auth-deadline';
        entry.secret = 'JBSWY3DPEHPK3PXP';
        let nowMs: number = 1000;
        let submitCalls: number = 0;
        const controller = new RustDeskPeerTwoFactorController();
        const ticket = controller.begin('session-auth-deadline', entry.id, 5000);
        const result = await controller.attempt(ticket, {
          clock: {
            now: (): number => nowMs,
            sleep: async (_milliseconds: number): Promise<void> => {}
          },
          loadEntry: (): TotpEntry => entry,
          authenticate: async (): Promise<boolean> => {
            nowMs = 5000;
            return true;
          },
          submit: (_code: string): boolean => { submitCalls++; return true; }
        });
        expect(result.kind).assertEqual('manual');
        expect(result.reason).assertEqual('pending_deadline_expired_after_authentication');
        expect(submitCalls).assertEqual(0);
      });

    it('crosses_pending_deadline_after_keyvault_load_without_auth_or_submit', 0,
      async (): Promise<void> => {
        const entry = new TotpEntry();
        entry.id = 'peer-totp-load-deadline';
        entry.secret = 'JBSWY3DPEHPK3PXP';
        let nowMs: number = 1000;
        let loadCalls: number = 0;
        let authenticateCalls: number = 0;
        let submitCalls: number = 0;
        const controller = new RustDeskPeerTwoFactorController();
        const ticket = controller.begin('session-load-deadline', entry.id, 5000);
        const result = await controller.attempt(ticket, {
          clock: {
            now: (): number => nowMs,
            sleep: async (_milliseconds: number): Promise<void> => {}
          },
          loadEntry: (): TotpEntry => {
            loadCalls++;
            nowMs = 5000;
            return entry;
          },
          authenticate: async (): Promise<boolean> => { authenticateCalls++; return true; },
          submit: (_code: string): boolean => { submitCalls++; return true; }
        });
        expect(result.kind).assertEqual('manual');
        expect(result.reason).assertEqual('pending_deadline_expired_after_keyvault_load');
        expect(loadCalls).assertEqual(1);
        expect(authenticateCalls).assertEqual(0);
        expect(submitCalls).assertEqual(0);
      });

    it('crosses_pending_deadline_after_post_auth_generation_without_calling_submit', 0,
      async (): Promise<void> => {
        const entry = new TotpEntry();
        entry.id = 'peer-totp-generation-deadline';
        entry.secret = 'JBSWY3DPEHPK3PXP';
        let nowMs: number = 1000;
        let loads: number = 0;
        let submitCalls: number = 0;
        const controller = new RustDeskPeerTwoFactorController();
        const ticket = controller.begin('session-generation-deadline', entry.id, 5000);
        const result = await controller.attempt(ticket, {
          clock: {
            now: (): number => nowMs,
            sleep: async (_milliseconds: number): Promise<void> => {}
          },
          loadEntry: (): TotpEntry => {
            loads++;
            if (loads === 2) { nowMs = 5000; }
            return entry;
          },
          authenticate: async (): Promise<boolean> => true,
          submit: (_code: string): boolean => { submitCalls++; return true; }
        });
        expect(result.kind).assertEqual('manual');
        expect(result.reason).assertEqual('pending_deadline_expired_after_authentication_generation');
        expect(submitCalls).assertEqual(0);
      });

    it('checks_the_submit_boundary_with_a_fake_clock', 0,
      async (): Promise<void> => {
        const entry = new TotpEntry();
        entry.id = 'peer-totp-submit-deadline';
        entry.secret = 'JBSWY3DPEHPK3PXP';
        let nowMs: number = 1000;
        let clockReads: number = 0;
        let submitCalls: number = 0;
        const controller = new RustDeskPeerTwoFactorController();
        const ticket = controller.begin('session-submit-deadline', entry.id, 5000);
        const result = await controller.attempt(ticket, {
          clock: {
            now: (): number => {
              clockReads++;
              // The eighth read is the immediate pre-submit fence: the
              // controller also rechecks after post-auth generation.
              return clockReads >= 8 ? 5000 : nowMs;
            },
            sleep: async (_milliseconds: number): Promise<void> => {}
          },
          loadEntry: (): TotpEntry => entry,
          authenticate: async (): Promise<boolean> => true,
          submit: (_code: string): boolean => { submitCalls++; return true; }
        });
        expect(result.kind).assertEqual('manual');
        expect(result.reason).assertEqual('pending_deadline_expired_before_submit');
        expect(submitCalls).assertEqual(0);
      });

    it('clears_epoch_fences_on_cancel_but_stale_cancel_cannot_touch_new_epoch', 0,
      async (): Promise<void> => {
        const entry = new TotpEntry();
        entry.id = 'peer-totp-cleanup';
        entry.secret = 'JBSWY3DPEHPK3PXP';
        const controller = new RustDeskPeerTwoFactorController();
        const first = controller.begin('session-cleanup', entry.id, 100000);
        let submissions: number = 0;
        const input = {
          clock: { now: (): number => 1000,
            sleep: async (_milliseconds: number): Promise<void> => {} },
          loadEntry: (): TotpEntry => entry,
          authenticate: async (): Promise<boolean> => true,
          submit: (_code: string): boolean => { submissions++; return true; }
        };
        expect((await controller.attempt(first, input)).kind).assertEqual('submitted');
        expect(controller.hasAcceptedCounter(first, 0)).assertTrue();
        controller.cancel(first);
        expect(controller.hasAcceptedCounter(first, 0)).assertFalse();
        const second = controller.begin('session-cleanup', entry.id, 100000);
        controller.cancel(first);
        expect(controller.isCurrent(second)).assertTrue();
        expect((await controller.attempt(second, input)).kind).assertEqual('submitted');
        expect(submissions).assertEqual(2);
        controller.cancel(second);
      });

    it('keeps_peer_binding_in_owner_local_runtime_and_clears_dangling_restore', 0, (): void => {
      const host = new RemoteHost();
      host.id = 'host-a';
      host.userId = 'owner-a';
      host.protocol = 'rustdesk';
      host.host = 'peer-a';
      host.rustdeskTotpEntryId = 'entry-a';
      host.rustdeskTotpAutoSubmit = true;
      const binding = rustDeskPeerTwoFactorBindingFromHost('owner-a', host);
      expect(binding !== null).assertTrue();
      expect(JSON.stringify(host.toJSON()).indexOf('rustdeskTotpEntryId')).assertEqual(-1);
      const memory = new RustDeskPeerTwoFactorBindingMemory();
      memory.bind('owner-a');
      if (binding !== null) {
        binding.deviceIdentity = 'test-device';
        expect(memory.save(binding)).assertTrue();
      }
      const restored = RemoteHost.fromJSON(host.toJSON());
      expect(hydrateRustDeskPeerTwoFactorHost(
        restored, memory.get(host.id, binding === null ? '' : binding.endpointIdentity),
        (_entryId: string): boolean => true, 'test-device')).assertTrue();
      expect(restored.rustdeskTotpEntryId).assertEqual('entry-a');
      expect(hydrateRustDeskPeerTwoFactorHost(
        restored, memory.get(host.id, binding === null ? '' : binding.endpointIdentity),
        (_entryId: string): boolean => false, 'test-device')).assertFalse();
      expect(restored.rustdeskTotpEntryId).assertEqual('');
      expect(restored.rustdeskTotpAutoSubmit).assertFalse();
    });

    it('defers_dangling_binding_cleanup_until_keyvault_snapshot_is_authoritative', 0,
      (): void => {
        expect(shouldRemoveDanglingRustDeskPeerTwoFactorBinding(
          true, false, false)).assertFalse();
        expect(shouldRemoveDanglingRustDeskPeerTwoFactorBinding(
          true, true, false)).assertTrue();
        expect(shouldRemoveDanglingRustDeskPeerTwoFactorBinding(
          true, true, true)).assertFalse();
        expect(shouldRemoveDanglingRustDeskPeerTwoFactorBinding(
          false, true, false)).assertFalse();
      });

    it('restores_device_local_peer_binding_from_preferences_after_store_restart', 0,
      (): void => {
        const adapter: MemoryPeerTwoFactorPreferences =
          new MemoryPeerTwoFactorPreferences();
        setRustDeskPeerTwoFactorPreferenceAdapterForTest(adapter);
        try {
          const context: common.Context = undefined as common.Context;
          const first: RustDeskPeerTwoFactorBindingStore =
            new RustDeskPeerTwoFactorBindingStore();
          expect(first.bindContext(context, 'owner-a')).assertTrue();
          const host: RemoteHost = makeLegacyPeerHost('persistent-binding-host');
          host.rustdeskTotpEntryId = 'persistent-entry';
          host.rustdeskTotpAutoSubmit = true;
          const binding: RustDeskPeerTwoFactorBinding | null =
            rustDeskPeerTwoFactorBindingFromHost('owner-a', host);
          expect(binding === null).assertFalse();
          if (binding !== null) {
            binding.deviceIdentity = first.deviceIdentity();
            expect(first.save(binding)).assertTrue();
          }

          const restored: RustDeskPeerTwoFactorBindingStore =
            new RustDeskPeerTwoFactorBindingStore();
          expect(restored.bindContext(context, 'owner-a')).assertTrue();
          expect(restored.deviceIdentity()).assertEqual(first.deviceIdentity());
          const saved: RustDeskPeerTwoFactorBinding | null = restored.get(
            host.id, rustDeskPeerTwoFactorEndpointIdentity(host));
          expect(saved === null).assertFalse();
          if (saved !== null) {
            expect(saved.entryId).assertEqual('persistent-entry');
            expect(saved.autoSubmit).assertTrue();
            expect(saved.deviceIdentity).assertEqual(first.deviceIdentity());
          }
        } finally {
          setRustDeskPeerTwoFactorPreferenceAdapterForTest(null);
        }
      });

    it('copies_local_peer_binding_only_when_a_session_clone_needs_it', 0, (): void => {
      const source: RemoteHost = makeLegacyPeerHost('runtime-copy-host');
      source.rustdeskTotpEntryId = 'runtime-entry';
      source.rustdeskTotpAutoSubmit = true;
      const target: RemoteHost = RemoteHost.fromJSON(source.toJSON());
      expect(target.rustdeskTotpEntryId).assertEqual('');
      copyRustDeskPeerTwoFactorRuntime(source, target);
      expect(target.rustdeskTotpEntryId).assertEqual('runtime-entry');
      expect(target.rustdeskTotpAutoSubmit).assertTrue();
      expect(JSON.stringify(target.toJSON()).indexOf('runtime-entry')).assertEqual(-1);
    });

    it('keeps_password_drafts_in_memory_and_fences_them_by_owner_generation', 0, (): void => {
      const drafts: RustDeskAuthDraftStore = new RustDeskAuthDraftStore();
      expect(drafts.save({
        ownerScopeId: 'owner-a', accountGeneration: 3, hostId: 'draft-host',
        authChoice: 'password', password: 'temporary-secret', passwordMode: 1,
        keepsStoredPassword: false,
        rememberPassword: false, updatedAt: 0
      })).assertTrue();
      const sameScope = drafts.load('owner-a', 3, 'draft-host');
      expect(sameScope === null).assertFalse();
      if (sameScope !== null) {
        expect(sameScope.password).assertEqual('temporary-secret');
        expect(sameScope.keepsStoredPassword).assertFalse();
        expect(sameScope.rememberPassword).assertFalse();
      }
      expect(drafts.load('owner-b', 3, 'draft-host') === null).assertTrue();
      expect(drafts.load('owner-a', 4, 'draft-host') === null).assertTrue();
      expect(drafts.save({
        ownerScopeId: 'owner-a', accountGeneration: 3, hostId: 'invalidated-host',
        authChoice: 'password', password: '', passwordMode: 0,
        keepsStoredPassword: false,
        rememberPassword: true, updatedAt: 0
      })).assertTrue();
      const invalidated = drafts.load('owner-a', 3, 'invalidated-host');
      expect(invalidated !== null && invalidated.passwordMode === 0).assertTrue();
      expect(invalidated !== null && invalidated.keepsStoredPassword).assertFalse();
      drafts.clearHost('draft-host');
      expect(drafts.load('owner-a', 3, 'draft-host') === null).assertTrue();
      expect(drafts.save({
        ownerScopeId: 'owner-a', accountGeneration: 3, hostId: 'scope-transition-host',
        authChoice: 'password', password: 'must-be-cleared', passwordMode: 0,
        keepsStoredPassword: false,
        rememberPassword: true, updatedAt: 0
      })).assertTrue();
      drafts.clearAll();
      expect(drafts.load('owner-a', 3, 'scope-transition-host') === null).assertTrue();
    });

    it('scrubs_runtime_binding_when_store_persistence_fails', 0, (): void => {
      const store: RustDeskPeerTwoFactorBindingStore =
        new RustDeskPeerTwoFactorBindingStore();
      store.bindForTest('owner-a');
      store.setPersistenceFailureForTest('persist');
      const host: RemoteHost = makeLegacyPeerHost('legacy-persist-failure');
      host.rustdeskTotpEntryId = 'entry-persist-failure';
      host.rustdeskTotpAutoSubmit = true;
      host.rustdeskTotpLegacyDeviceId = 'test-device';
      host.rustdeskTotpLegacySource = 'remote_json';
      const candidate: RustDeskPeerTwoFactorLegacyCandidate = {
        ownerScopeId: 'owner-a', hostId: host.id, entryId: 'entry-persist-failure',
        autoSubmit: true, sourceDeviceId: 'test-device', source: 'remote_json'
      };
      const result = migrateRustDeskPeerTwoFactorLegacyCandidate(
        candidate, host, store, (_entryId: string): boolean => true);
      expect(result.status).assertEqual('persistence_failed');
      expect(host.rustdeskTotpEntryId).assertEqual('');
      expect(host.rustdeskTotpAutoSubmit).assertFalse();
      expect(host.rustdeskTotpLegacyDeviceId).assertEqual('');
      expect(host.rustdeskTotpLegacySource).assertEqual('');
      expect(store.list().length).assertEqual(0);
      expect(store.isLoaded()).assertFalse();
    });

    it('compares_migration_marker_version_and_rehydrates_only_matching_device', 0, (): void => {
      const store: RustDeskPeerTwoFactorBindingStore =
        new RustDeskPeerTwoFactorBindingStore();
      store.bindForTest('owner-a');
      const host: RemoteHost = makeLegacyPeerHost('legacy-marker-upgrade');
      const endpoint: string = rustDeskPeerTwoFactorEndpointIdentity(host);
      store.setLegacyMigrationMarkerForTest(host.id, endpoint, 'remote_json', 0);
      const candidate: RustDeskPeerTwoFactorLegacyCandidate = {
        ownerScopeId: 'owner-a', hostId: host.id, entryId: 'entry-marker-upgrade',
        autoSubmit: true, sourceDeviceId: 'test-device', source: 'remote_json'
      };
      const result = migrateRustDeskPeerTwoFactorLegacyCandidate(
        candidate, host, store, (_entryId: string): boolean => true);
      expect(result.status).assertEqual('migrated');
      const binding = store.get(host.id, endpoint);
      expect(binding === null).assertFalse();
      if (binding !== null) { expect(binding.migrationVersion).assertEqual(1); }

      const mismatchedHost: RemoteHost = makeLegacyPeerHost('legacy-hydrate-device');
      mismatchedHost.rustdeskTotpEntryId = 'legacy-runtime-entry';
      mismatchedHost.rustdeskTotpAutoSubmit = true;
      mismatchedHost.rustdeskTotpLegacyDeviceId = 'other-device';
      const mismatchedBinding: RustDeskPeerTwoFactorBinding | null =
        rustDeskPeerTwoFactorBindingFromHost('owner-a', mismatchedHost);
      expect(mismatchedBinding === null).assertFalse();
      if (mismatchedBinding !== null) {
        mismatchedBinding.deviceIdentity = 'other-device';
      }
      expect(hydrateRustDeskPeerTwoFactorHost(
        mismatchedHost, mismatchedBinding, (_entryId: string): boolean => true,
        'test-device')).assertFalse();
      expect(mismatchedHost.rustdeskTotpEntryId).assertEqual('');
      expect(mismatchedHost.rustdeskTotpAutoSubmit).assertFalse();
      expect(mismatchedHost.rustdeskTotpLegacyDeviceId).assertEqual('');
      expect(mismatchedHost.rustdeskTotpLegacySource).assertEqual('');
    });

    it('scrub_helper_is_fail_closed_for_unverified_runtime_fields', 0, (): void => {
      const host: RemoteHost = makeLegacyPeerHost('legacy-scrub-helper');
      host.rustdeskTotpEntryId = 'entry-runtime';
      host.rustdeskTotpAutoSubmit = true;
      host.rustdeskTotpLegacyDeviceId = 'device-runtime';
      host.rustdeskTotpLegacySource = 'remote_json';
      scrubRustDeskPeerTwoFactorRuntime(host);
      expect(host.rustdeskTotpEntryId).assertEqual('');
      expect(host.rustdeskTotpAutoSubmit).assertFalse();
      expect(host.rustdeskTotpLegacyDeviceId).assertEqual('');
      expect(host.rustdeskTotpLegacySource).assertEqual('');
    });

    it('reads_legacy_json_before_owner_store_and_never_writes_it', 0, (): void => {
      const legacy: RemoteHostJSON = new RemoteHost().toJSON();
      legacy.id = 'legacy-json-host';
      legacy.userId = 'owner-a';
      legacy.protocol = 'rustdesk';
      legacy.host = 'peer-legacy-json';
      legacy.rustdeskTotpEntryId = 'entry-legacy-json';
      legacy.rustdeskTotpAutoSubmit = 'true';
      legacy.rustdeskTotpDeviceId = 'test-device';
      const restored: RemoteHost = RemoteHost.fromJSON(legacy);
      expect(restored.rustdeskTotpEntryId).assertEqual('entry-legacy-json');
      expect(restored.rustdeskTotpAutoSubmit).assertTrue();
      expect(restored.rustdeskTotpLegacyDeviceId).assertEqual('test-device');
      expect(restored.rustdeskTotpLegacySource).assertEqual('remote_json');
      const serialized: string = JSON.stringify(restored.toJSON());
      expect(serialized.indexOf('rustdeskTotpEntryId')).assertEqual(-1);
      expect(serialized.indexOf('rustdeskTotpAutoSubmit')).assertEqual(-1);
      expect(serialized.indexOf('rustdeskTotpDeviceId')).assertEqual(-1);
    });

    it('decodes_legacy_cloud_extension_before_adapter_allowlist_filtering', 0, (): void => {
      const raw: string = JSON.stringify({
        _remoteDeskExtensionV1: {
          rustdeskTotpEntryId: 'entry-cloud-legacy',
          rustdeskTotpAutoSubmit: true,
          rustdeskTotpDeviceId: 'test-device'
        }
      });
      const candidate: RustDeskPeerTwoFactorLegacyCandidate | null =
        decodeRustDeskPeerTwoFactorLegacyDisplayConfig(raw, 'owner-a', 'cloud-host');
      expect(candidate === null).assertFalse();
      if (candidate !== null) {
        expect(candidate.source).assertEqual('cloud_extension');
        expect(candidate.entryId).assertEqual('entry-cloud-legacy');
        expect(candidate.autoSubmit).assertTrue();
        expect(candidate.sourceDeviceId).assertEqual('test-device');
      }
    });

    it('migrates_same_owner_device_once_and_is_idempotent', 0, (): void => {
      const store: RustDeskPeerTwoFactorBindingStore =
        new RustDeskPeerTwoFactorBindingStore();
      store.bindForTest('owner-a');
      const host: RemoteHost = makeLegacyPeerHost('legacy-migrate-host');
      const candidate: RustDeskPeerTwoFactorLegacyCandidate = {
        ownerScopeId: 'owner-a', hostId: host.id, entryId: 'entry-migrate',
        autoSubmit: true, sourceDeviceId: 'test-device', source: 'remote_json'
      };
      const first = migrateRustDeskPeerTwoFactorLegacyCandidate(
        candidate, host, store, (_entryId: string): boolean => true);
      expect(first.status).assertEqual('migrated');
      expect(host.rustdeskTotpEntryId).assertEqual('');
      expect(host.rustdeskTotpAutoSubmit).assertFalse();
      const endpoint: string = rustDeskPeerTwoFactorEndpointIdentity(host);
      const binding = store.get(host.id, endpoint);
      expect(binding === null).assertFalse();
      if (binding !== null) {
        expect(binding.entryId).assertEqual('entry-migrate');
        expect(binding.autoSubmit).assertTrue();
        expect(binding.source).assertEqual('legacy:remote_json');
        expect(binding.deviceIdentity).assertEqual('test-device');
      }
      const replayHost: RemoteHost = makeLegacyPeerHost(host.id);
      const replay = migrateRustDeskPeerTwoFactorLegacyCandidate(
        candidate, replayHost, store, (_entryId: string): boolean => true);
      expect(replay.status).assertEqual('already_migrated');
      expect(store.list().length).assertEqual(1);
    });

    it('never_restores_backup_auto_submit_even_when_legacy_row_requested_it', 0, (): void => {
      const store: RustDeskPeerTwoFactorBindingStore =
        new RustDeskPeerTwoFactorBindingStore();
      store.bindForTest('owner-a');
      const host: RemoteHost = makeLegacyPeerHost('legacy-backup-host');
      const backupRows: Array<Record<string, string>> = [{
        id: host.id,
        rustdeskTotpEntryId: 'entry-backup',
        rustdeskTotpAutoSubmit: '1'
      }];
      const backupExtensions: Array<Record<string, string>> = [];
      const candidates: RustDeskPeerTwoFactorLegacyCandidate[] =
        decodeRustDeskPeerTwoFactorLegacyBackupRows(
          backupRows, backupExtensions, 'owner-a');
      expect(candidates.length).assertEqual(1);
      const candidate: RustDeskPeerTwoFactorLegacyCandidate = candidates[0];
      expect(candidate.autoSubmit).assertFalse();
      const result = migrateRustDeskPeerTwoFactorLegacyCandidate(
        candidate, host, store, (_entryId: string): boolean => true);
      expect(result.status).assertEqual('migrated');
      const binding = store.get(host.id, rustDeskPeerTwoFactorEndpointIdentity(host));
      expect(binding === null).assertFalse();
      if (binding !== null) { expect(binding.autoSubmit).assertFalse(); }
    });

    it('fails_closed_for_unproven_device_or_missing_entry_and_clears_legacy_input', 0, (): void => {
      const store: RustDeskPeerTwoFactorBindingStore =
        new RustDeskPeerTwoFactorBindingStore();
      store.bindForTest('owner-a');
      const deviceHost: RemoteHost = makeLegacyPeerHost('legacy-device-host');
      const deviceCandidate: RustDeskPeerTwoFactorLegacyCandidate = {
        ownerScopeId: 'owner-a', hostId: deviceHost.id, entryId: 'entry-device',
        autoSubmit: true, sourceDeviceId: 'other-device', source: 'remote_json'
      };
      const deviceResult = migrateRustDeskPeerTwoFactorLegacyCandidate(
        deviceCandidate, deviceHost, store, (_entryId: string): boolean => true);
      expect(deviceResult.status).assertEqual('unbound');
      expect(deviceResult.reason).assertEqual('legacy_device_identity_not_proven');
      expect(deviceHost.rustdeskTotpEntryId).assertEqual('');
      const missingHost: RemoteHost = makeLegacyPeerHost('legacy-missing-host');
      const missingCandidate: RustDeskPeerTwoFactorLegacyCandidate = {
        ownerScopeId: 'owner-a', hostId: missingHost.id, entryId: 'entry-missing',
        autoSubmit: true, sourceDeviceId: 'test-device', source: 'remote_json'
      };
      const missingResult = migrateRustDeskPeerTwoFactorLegacyCandidate(
        missingCandidate, missingHost, store, (_entryId: string): boolean => false);
      expect(missingResult.status).assertEqual('unbound');
      expect(missingResult.reason).assertEqual('legacy_totp_entry_missing');
      expect(missingHost.rustdeskTotpEntryId).assertEqual('');
      expect(store.list().length).assertEqual(0);
    });
  });
}
