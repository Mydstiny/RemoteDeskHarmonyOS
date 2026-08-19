export type MoonlightReconnectAction =
  'attempt' | 'wait_network' | 'wait_backoff' | 'give_up';

export interface MoonlightReconnectWindow {
  generation: number;
  enabled: boolean;
  startedAtMs: number;
  deadlineAtMs: number;
  failedAttempts: number;
  nextAttemptAtMs: number;
}

export interface MoonlightReconnectDecision {
  action: MoonlightReconnectAction;
  delayMs: number;
  attemptNumber: number;
  remainingMs: number;
}

const MAX_RECONNECT_ATTEMPTS: number = 6;
const BACKOFF_MS: number[] = [250, 750, 1500, 3000, 5000, 8000];

function safeTime(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0;
}

function safeGeneration(value: number): boolean {
  return Number.isSafeInteger(value) && value > 0;
}

export function createMoonlightReconnectWindow(enabled: boolean, budgetMs: number,
  nowMs: number, generation: number): MoonlightReconnectWindow {
  const safeNow: number = safeTime(nowMs) ? nowMs : 0;
  const safeBudget: number = Number.isSafeInteger(budgetMs) && budgetMs >= 0 &&
    budgetMs <= 120000 ? budgetMs : 0;
  const safeEnabled: boolean = enabled && safeBudget > 0 && safeGeneration(generation);
  return {
    generation: safeGeneration(generation) ? generation : 0,
    enabled: safeEnabled,
    startedAtMs: safeNow,
    deadlineAtMs: safeEnabled ? safeNow + safeBudget : safeNow,
    failedAttempts: 0,
    nextAttemptAtMs: safeNow
  };
}

export function moonlightReconnectDecision(window: MoonlightReconnectWindow,
  nowMs: number, networkAvailable: boolean): MoonlightReconnectDecision {
  const now: number = safeTime(nowMs) ? nowMs : window.deadlineAtMs;
  const remaining: number = Math.max(0, window.deadlineAtMs - now);
  if (!window.enabled || !safeGeneration(window.generation) || remaining <= 0 ||
      window.failedAttempts >= MAX_RECONNECT_ATTEMPTS) {
    return { action: 'give_up', delayMs: 0,
      attemptNumber: window.failedAttempts + 1, remainingMs: remaining };
  }
  if (!networkAvailable) {
    return { action: 'wait_network', delayMs: Math.min(500, remaining),
      attemptNumber: window.failedAttempts + 1, remainingMs: remaining };
  }
  if (now < window.nextAttemptAtMs) {
    return { action: 'wait_backoff',
      delayMs: Math.min(window.nextAttemptAtMs - now, remaining),
      attemptNumber: window.failedAttempts + 1, remainingMs: remaining };
  }
  return { action: 'attempt', delayMs: 0,
    attemptNumber: window.failedAttempts + 1, remainingMs: remaining };
}

export function moonlightReconnectAfterFailure(window: MoonlightReconnectWindow,
  nowMs: number): MoonlightReconnectWindow {
  const now: number = safeTime(nowMs) ? nowMs : window.deadlineAtMs;
  const failures: number = Math.min(MAX_RECONNECT_ATTEMPTS, window.failedAttempts + 1);
  const backoffIndex: number = Math.min(BACKOFF_MS.length - 1, Math.max(0, failures - 1));
  return {
    generation: window.generation,
    enabled: window.enabled,
    startedAtMs: window.startedAtMs,
    deadlineAtMs: window.deadlineAtMs,
    failedAttempts: failures,
    nextAttemptAtMs: Math.min(window.deadlineAtMs, now + BACKOFF_MS[backoffIndex])
  };
}

export function moonlightReconnectWindowIsCurrent(window: MoonlightReconnectWindow | null,
  generation: number): boolean {
  return window !== null && window.enabled && window.generation === generation;
}

export function moonlightReconnectAttemptTimeoutMs(decision: MoonlightReconnectDecision): number {
  if (decision.action !== 'attempt' || decision.remainingMs <= 0) { return 0; }
  return Math.max(100, Math.min(5000, decision.remainingMs));
}
