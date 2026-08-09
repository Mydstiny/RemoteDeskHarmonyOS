import { TotpAlgorithm, TotpCode, TotpEntry } from '../model/TotpEntry';
import { TotpEngine } from './TotpEngine';

// RustDesk's official TOTP generator currently uses SHA-1, 30 seconds, and
// six digits. Manual input also permits an explicit eight-digit custom Peer.
export const RUSTDESK_OFFICIAL_TOTP_PERIOD_SECONDS: number = 30;
export const RUSTDESK_OFFICIAL_TOTP_DIGITS: number = 6;
export const RUSTDESK_PEER_2FA_MIN_REMAINING_SECONDS: number = 5;
export const RUSTDESK_PEER_2FA_AUTH_BUDGET_MS: number = 3000;
export const RUSTDESK_PEER_2FA_SUBMIT_BUDGET_MS: number = 2000;
export const RUSTDESK_PEER_2FA_SAFE_WINDOW_JITTER_MS: number = 150;
/**
 * Native Peer 2FA currently exposes the pending state but not a portable
 * deadline.  Pages must capture the first observed challenge time once and
 * derive the local deadline through this policy; re-entering the page or
 * retrying an operation must never extend it.
 */
export const RUSTDESK_PEER_2FA_LOCAL_PENDING_TIMEOUT_MS: number = 60000;

export function rustDeskPeerTwoFactorPendingDeadlineFromReceivedAt(
  receivedAtMs: number,
  timeoutMs: number = RUSTDESK_PEER_2FA_LOCAL_PENDING_TIMEOUT_MS
): number {
  if (!Number.isFinite(receivedAtMs) || receivedAtMs <= 0 ||
    !Number.isFinite(timeoutMs) || timeoutMs <= 0) {
    return 0;
  }
  return Math.floor(receivedAtMs) + Math.floor(timeoutMs);
}

export function rustDeskPeerTwoFactorPendingDeadlineExpired(
  pendingDeadlineMs: number, nowMs: number
): boolean {
  return pendingDeadlineMs <= 0 || !Number.isFinite(pendingDeadlineMs) ||
    !Number.isFinite(nowMs) || nowMs >= pendingDeadlineMs;
}

export function isRustDeskPeerTwoFactorManualCode(code: string): boolean {
  if (code.length !== 6 && code.length !== 8) { return false; }
  for (let i = 0; i < code.length; i++) {
    const value: number = code.charCodeAt(i);
    if (value < 48 || value > 57) { return false; }
  }
  return true;
}

export function isRustDeskPeerTwoFactorAutoSubmitCompatible(entry: TotpEntry): boolean {
  return entry.algorithm === TotpAlgorithm.SHA1 &&
    entry.digits === RUSTDESK_OFFICIAL_TOTP_DIGITS &&
    entry.period === RUSTDESK_OFFICIAL_TOTP_PERIOD_SECONDS;
}

/** Returns a user-safe reason when an automatic submission must fall back to manual input. */
export function rustDeskPeerTwoFactorAutoSubmitError(entry: TotpEntry, code: TotpCode): string {
  if (!isRustDeskPeerTwoFactorAutoSubmitCompatible(entry)) {
    return '自动填写仅支持 RustDesk 官方默认的 SHA1、30 秒、6 位 TOTP，请手动输入验证码。';
  }
  if (code.code.length !== RUSTDESK_OFFICIAL_TOTP_DIGITS ||
    !isRustDeskPeerTwoFactorManualCode(code.code)) {
    return '已绑定的 2FA 条目未生成有效验证码，请手动输入验证码。';
  }
  if (!code.valid || code.validUntilMs <= Date.now()) {
    return '验证码已更新，请重新获取后再提交。';
  }
  if (code.remaining < RUSTDESK_PEER_2FA_MIN_REMAINING_SECONDS) {
    return '验证码即将更新。请等待下一组验证码后重试。';
  }
  return '';
}

export interface RustDeskPeerTwoFactorClock {
  now: () => number
  sleep: (milliseconds: number) => Promise<void>
}

const REAL_PEER_2FA_CLOCK: RustDeskPeerTwoFactorClock = {
  now: (): number => Date.now(),
  sleep: (milliseconds: number): Promise<void> => new Promise<void>(
    (resolve: () => void): void => { setTimeout(resolve, milliseconds); })
};

export interface RustDeskPeerTwoFactorOperationTicket {
  sessionId: string
  epoch: number
  entryId: string
  pendingDeadlineMs: number
}

export type RustDeskPeerTwoFactorAutoResultKind =
  'submitted' | 'manual' | 'cancelled' | 'auth_cancelled' |
  'keyvault_failed' | 'wrong_code' | 'already_submitted';

export interface RustDeskPeerTwoFactorAutoResult {
  kind: RustDeskPeerTwoFactorAutoResultKind
  reason: string
  counter: number
}

export interface RustDeskPeerTwoFactorAutoSubmitInput {
  loadEntry: () => TotpEntry | undefined
  authenticate: () => Promise<boolean>
  submit: (code: string) => Promise<boolean> | boolean
  clock?: RustDeskPeerTwoFactorClock
}

function scopedKey(ticket: RustDeskPeerTwoFactorOperationTicket): string {
  return ticket.sessionId + '\u001f' + ticket.epoch.toString() + '\u001f' + ticket.entryId;
}

function counterKey(ticket: RustDeskPeerTwoFactorOperationTicket, counter: number): string {
  return scopedKey(ticket) + '\u001f' + counter.toString();
}

function clearScopedState(
  ticket: RustDeskPeerTwoFactorOperationTicket,
  acceptedCounters: Set<string>, wrongScopes: Set<string>,
  inFlightScopes: Set<string>, manualRequiredScopes: Set<string>
): void {
  const scope: string = scopedKey(ticket);
  const counterPrefix: string = scope + '\u001f';
  const accepted: string[] = [];
  acceptedCounters.forEach((key: string): void => {
    if (key.indexOf(counterPrefix) === 0) { accepted.push(key); }
  });
  for (let index = 0; index < accepted.length; index++) {
    acceptedCounters.delete(accepted[index]);
  }
  wrongScopes.delete(scope);
  inFlightScopes.delete(scope);
  manualRequiredScopes.delete(scope);
}

function emptyRustDeskPeerTotpCode(): TotpCode {
  return {
    code: '', remaining: 0, total: 0, progress: 0,
    counter: -1, validUntilMs: 0, valid: false
  };
}

/**
 * Decide whether a near-boundary code may wait for the next counter.
 * `-1` means the pending native challenge cannot safely outlive the wait and
 * the UI must switch to manual entry without authenticating or submitting.
 */
export function rustDeskPeerTwoFactorSafeWindowWaitMs(
  code: TotpCode,
  pendingDeadlineMs: number,
  nowMs: number,
  authBudgetMs: number = RUSTDESK_PEER_2FA_AUTH_BUDGET_MS,
  submitBudgetMs: number = RUSTDESK_PEER_2FA_SUBMIT_BUDGET_MS
): number {
  if (pendingDeadlineMs <= nowMs || pendingDeadlineMs <= 0 || code.validUntilMs <= nowMs) {
    return -1;
  }
  if (code.remaining >= RUSTDESK_PEER_2FA_MIN_REMAINING_SECONDS) { return 0; }
  const nextWindowStart: number = code.validUntilMs + RUSTDESK_PEER_2FA_SAFE_WINDOW_JITTER_MS;
  const requiredDeadline: number = nextWindowStart +
    RUSTDESK_PEER_2FA_MIN_REMAINING_SECONDS * 1000 +
    Math.max(0, authBudgetMs) + Math.max(0, submitBudgetMs);
  if (pendingDeadlineMs < requiredDeadline) { return -1; }
  return Math.max(0, nextWindowStart - nowMs);
}

/**
 * Service/controller boundary for Peer 2FA. It owns the cancellation epoch,
 * safe-window wait, per-counter de-duplication and the no-repeat-after-wrong
 * rule. The controller never stores a secret or a generated code.
 */
export class RustDeskPeerTwoFactorController {
  private nextEpoch: number = 0;
  private active: RustDeskPeerTwoFactorOperationTicket | null = null;
  private readonly acceptedCounters: Set<string> = new Set<string>();
  private readonly wrongScopes: Set<string> = new Set<string>();
  private readonly inFlightScopes: Set<string> = new Set<string>();
  private readonly manualRequiredScopes: Set<string> = new Set<string>();

  begin(sessionId: string | number, entryId: string, pendingDeadlineMs: number):
    RustDeskPeerTwoFactorOperationTicket {
    const normalizedSession: string = sessionId.toString();
    const normalizedEntry: string = entryId.trim();
    if (this.active !== null && this.active.sessionId === normalizedSession &&
      this.active.entryId === normalizedEntry &&
      this.active.pendingDeadlineMs === pendingDeadlineMs) {
      return {
        sessionId: this.active.sessionId, epoch: this.active.epoch,
        entryId: this.active.entryId, pendingDeadlineMs: this.active.pendingDeadlineMs
      };
    }
    this.cancel();
    this.nextEpoch += 1;
    if (this.nextEpoch <= 0) { this.nextEpoch = 1; }
    this.active = {
      sessionId: normalizedSession, epoch: this.nextEpoch,
      entryId: normalizedEntry, pendingDeadlineMs
    };
    return {
      sessionId: normalizedSession, epoch: this.nextEpoch,
      entryId: normalizedEntry, pendingDeadlineMs
    };
  }

  cancel(ticket?: RustDeskPeerTwoFactorOperationTicket): void {
    if (ticket === undefined) {
      const current: RustDeskPeerTwoFactorOperationTicket | null = this.active;
      this.active = null;
      if (current !== null) {
        clearScopedState(current, this.acceptedCounters,
          this.wrongScopes, this.inFlightScopes, this.manualRequiredScopes);
      }
      return;
    }
    // A stale completion may call cancel with its old ticket.  Clear only its
    // epoch; never clear the newer active operation.
    if (this.isCurrent(ticket)) { this.active = null; }
    clearScopedState(ticket, this.acceptedCounters,
      this.wrongScopes, this.inFlightScopes, this.manualRequiredScopes);
  }

  isCurrent(ticket: RustDeskPeerTwoFactorOperationTicket): boolean {
    return this.active !== null && this.active.sessionId === ticket.sessionId &&
      this.active.epoch === ticket.epoch && this.active.entryId === ticket.entryId &&
      this.active.pendingDeadlineMs === ticket.pendingDeadlineMs;
  }

  hasAcceptedCounter(ticket: RustDeskPeerTwoFactorOperationTicket, counter: number): boolean {
    return this.acceptedCounters.has(counterKey(ticket, counter));
  }

  isManualRequired(ticket: RustDeskPeerTwoFactorOperationTicket): boolean {
    return this.isCurrent(ticket) && this.manualRequiredScopes.has(scopedKey(ticket));
  }

  /**
   * A direct user action is the only page-level operation allowed to clear a
   * manual-required fence.  Native polling never calls this method.
   */
  allowUserInitiatedRetry(ticket: RustDeskPeerTwoFactorOperationTicket): boolean {
    if (!this.isCurrent(ticket)) { return false; }
    const scope: string = scopedKey(ticket);
    this.manualRequiredScopes.delete(scope);
    this.wrongScopes.delete(scope);
    return true;
  }

  /** Keep automatic polling stopped after a direct user submission fails. */
  requireManualRetry(ticket: RustDeskPeerTwoFactorOperationTicket): void {
    if (this.isCurrent(ticket)) { this.manualRequiredScopes.add(scopedKey(ticket)); }
  }

  /**
   * Try one unattended submission. A user-triggered retry may pass
   * `userInitiated=true` after a wrong native response; unattended retries are
   * then blocked for the session/epoch/entry until a new operation begins.
   */
  async attempt(ticket: RustDeskPeerTwoFactorOperationTicket,
    input: RustDeskPeerTwoFactorAutoSubmitInput,
    userInitiated: boolean = false): Promise<RustDeskPeerTwoFactorAutoResult> {
    const operationKey: string = scopedKey(ticket);
    if (!this.isCurrent(ticket)) {
      clearScopedState(ticket, this.acceptedCounters,
        this.wrongScopes, this.inFlightScopes, this.manualRequiredScopes);
      return { kind: 'cancelled', reason: 'session_or_epoch_changed', counter: -1 };
    }
    if (!userInitiated && this.manualRequiredScopes.has(operationKey)) {
      return { kind: 'manual', reason: 'manual_retry_required', counter: -1 };
    }
    if (userInitiated) {
      this.allowUserInitiatedRetry(ticket);
    }
    if (this.inFlightScopes.has(operationKey)) {
      return { kind: 'already_submitted', reason: 'operation_in_flight', counter: -1 };
    }
    this.inFlightScopes.add(operationKey);
    try {
      const result: RustDeskPeerTwoFactorAutoResult =
        await this.attemptInternal(ticket, input, userInitiated);
      if (this.isCurrent(ticket) &&
        (result.kind === 'auth_cancelled' || result.kind === 'keyvault_failed')) {
        this.manualRequiredScopes.add(operationKey);
      }
      return result;
    } catch (_error) {
      // Authentication, KeyVault and native adapter exceptions are not a
      // reason to re-enter unattended mode.  Convert them to a bounded,
      // user-safe result and fence this scope until an explicit retry.
      if (this.isCurrent(ticket)) { this.manualRequiredScopes.add(operationKey); }
      return {
        kind: 'manual', reason: 'automatic_attempt_failed_manual_retry', counter: -1
      };
    } finally {
      this.inFlightScopes.delete(operationKey);
      // Accepted counters and wrong-code fences are deliberately retained
      // while their ticket remains active so a duplicate native event cannot
      // submit twice.  Once the epoch is stale, no state may survive it.
      if (!this.isCurrent(ticket)) {
        clearScopedState(ticket, this.acceptedCounters,
          this.wrongScopes, this.inFlightScopes, this.manualRequiredScopes);
      }
    }
  }

  private async attemptInternal(ticket: RustDeskPeerTwoFactorOperationTicket,
    input: RustDeskPeerTwoFactorAutoSubmitInput,
    userInitiated: boolean): Promise<RustDeskPeerTwoFactorAutoResult> {
    const clock: RustDeskPeerTwoFactorClock = input.clock ?? REAL_PEER_2FA_CLOCK;
    if (!this.isCurrent(ticket)) {
      return { kind: 'cancelled', reason: 'session_or_epoch_changed', counter: -1 };
    }
    if (rustDeskPeerTwoFactorPendingDeadlineExpired(ticket.pendingDeadlineMs, clock.now())) {
      return { kind: 'manual', reason: 'pending_deadline_expired_before_keyvault', counter: -1 };
    }
    if (!userInitiated && this.wrongScopes.has(scopedKey(ticket))) {
      return { kind: 'manual', reason: 'wrong_code_requires_manual_retry', counter: -1 };
    }
    let entry: TotpEntry | undefined;
    let generated: TotpCode = emptyRustDeskPeerTotpCode();
    let code: string = '';
    try {
      entry = input.loadEntry();
      if (rustDeskPeerTwoFactorPendingDeadlineExpired(ticket.pendingDeadlineMs, clock.now())) {
        entry = undefined;
        return { kind: 'manual', reason: 'pending_deadline_expired_after_keyvault_load', counter: -1 };
      }
      if (entry === undefined || entry.secret.length === 0) {
        entry = undefined;
        return { kind: 'keyvault_failed', reason: 'totp_entry_unavailable', counter: -1 };
      }
    if (!isRustDeskPeerTwoFactorAutoSubmitCompatible(entry)) {
      entry = undefined;
      return { kind: 'manual', reason: 'unsupported_totp_parameters', counter: -1 };
    }
    generated = TotpEngine.generateCodeAt(entry, clock.now());
    if (rustDeskPeerTwoFactorPendingDeadlineExpired(ticket.pendingDeadlineMs, clock.now())) {
      return { kind: 'manual', reason: 'pending_deadline_expired_after_generation', counter: generated.counter };
    }
    const waitMs: number = rustDeskPeerTwoFactorSafeWindowWaitMs(
      generated, ticket.pendingDeadlineMs, clock.now());
    if (waitMs < 0) {
      entry = undefined;
      return { kind: 'manual', reason: 'pending_deadline_cannot_reach_safe_window', counter: generated.counter };
    }
    if (waitMs > 0) {
      await clock.sleep(waitMs);
      if (!this.isCurrent(ticket)) {
        entry = undefined;
        return { kind: 'cancelled', reason: 'cancelled_during_safe_window_wait', counter: generated.counter };
      }
      entry = input.loadEntry();
      if (rustDeskPeerTwoFactorPendingDeadlineExpired(ticket.pendingDeadlineMs, clock.now())) {
        entry = undefined;
        return { kind: 'manual', reason: 'pending_deadline_expired_after_safe_window_load', counter: -1 };
      }
      if (entry === undefined || entry.secret.length === 0) {
        entry = undefined;
        return { kind: 'keyvault_failed', reason: 'totp_entry_unavailable_after_wait', counter: -1 };
      }
      if (!isRustDeskPeerTwoFactorAutoSubmitCompatible(entry)) {
        entry = undefined;
        return { kind: 'manual', reason: 'unsupported_totp_parameters_after_wait', counter: -1 };
      }
      generated = TotpEngine.generateCodeAt(entry, clock.now());
      if (rustDeskPeerTwoFactorPendingDeadlineExpired(ticket.pendingDeadlineMs, clock.now())) {
        entry = undefined;
        return { kind: 'manual', reason: 'pending_deadline_expired_after_safe_window', counter: generated.counter };
      }
    }
    if (!this.isCurrent(ticket)) {
      entry = undefined;
      return { kind: 'cancelled', reason: 'cancelled_before_authentication', counter: generated.counter };
    }
    if (this.hasAcceptedCounter(ticket, generated.counter)) {
      entry = undefined;
      return { kind: 'already_submitted', reason: 'counter_already_accepted', counter: generated.counter };
    }
    const authenticated: boolean = await input.authenticate();
    if (!this.isCurrent(ticket)) {
      entry = undefined;
      return { kind: 'cancelled', reason: 'cancelled_during_authentication', counter: generated.counter };
    }
    // The check is intentionally immediately after the await.  A biometric
    // dialog may remain open past the native pending lifetime.
    if (rustDeskPeerTwoFactorPendingDeadlineExpired(ticket.pendingDeadlineMs, clock.now())) {
      entry = undefined;
      return { kind: 'manual', reason: 'pending_deadline_expired_after_authentication', counter: generated.counter };
    }
    if (!authenticated) {
      entry = undefined;
      return { kind: 'auth_cancelled', reason: 'system_authentication_cancelled', counter: generated.counter };
    }
    entry = input.loadEntry();
    if (rustDeskPeerTwoFactorPendingDeadlineExpired(ticket.pendingDeadlineMs, clock.now())) {
      entry = undefined;
      return { kind: 'manual', reason: 'pending_deadline_expired_after_authentication_load', counter: -1 };
    }
    if (entry === undefined || entry.secret.length === 0) {
      entry = undefined;
      return { kind: 'keyvault_failed', reason: 'totp_entry_unavailable_after_authentication', counter: -1 };
    }
    if (!isRustDeskPeerTwoFactorAutoSubmitCompatible(entry)) {
      entry = undefined;
      return { kind: 'manual', reason: 'unsupported_totp_parameters_after_authentication', counter: -1 };
    }
    generated = TotpEngine.generateCodeAt(entry, clock.now());
    if (rustDeskPeerTwoFactorPendingDeadlineExpired(ticket.pendingDeadlineMs, clock.now())) {
      entry = undefined;
      return { kind: 'manual', reason: 'pending_deadline_expired_after_authentication_generation', counter: generated.counter };
    }
    if (!generated.valid || generated.remaining < RUSTDESK_PEER_2FA_MIN_REMAINING_SECONDS) {
      entry = undefined;
      return { kind: 'manual', reason: 'code_near_boundary_after_authentication', counter: generated.counter };
    }
    const submittedCounter: number = generated.counter;
    code = generated.code;
    entry = undefined;
    if (rustDeskPeerTwoFactorPendingDeadlineExpired(ticket.pendingDeadlineMs, clock.now())) {
      code = '';
      generated = emptyRustDeskPeerTotpCode();
      return { kind: 'manual', reason: 'pending_deadline_expired_before_submit', counter: submittedCounter };
    }
    let accepted: boolean = false;
    try {
      accepted = await input.submit(code);
    } finally {
      code = '';
      // The local variable is no longer used after the native call.
      generated = emptyRustDeskPeerTotpCode();
    }
    if (!accepted) {
      this.wrongScopes.add(scopedKey(ticket));
      return { kind: 'wrong_code', reason: 'native_rejected_code_manual_retry', counter: submittedCounter };
    }
    // A successful native acceptance is the only point at which an attempt is
    // recorded. A failed auth/key lookup/boundary wait never consumes it.
    this.acceptedCounters.add(counterKey(ticket, submittedCounter));
    if (!this.isCurrent(ticket)) {
      return { kind: 'cancelled', reason: 'cancelled_after_native_acceptance', counter: submittedCounter };
    }
    return { kind: 'submitted', reason: 'native_accepted_code', counter: submittedCounter };
    } finally {
      // All cancellation, boundary, authentication, native and exception
      // paths pass through one scrub fence. The KeyVault entry itself is not
      // mutated; only operation-local references and code are cleared.
      entry = undefined;
      code = '';
      generated = emptyRustDeskPeerTotpCode();
    }
  }
}
