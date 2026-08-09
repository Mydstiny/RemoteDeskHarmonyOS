import {
  AccountSessionLease,
  cloneAccountSessionLease
} from './AccountScopePolicy';

export type MoonlightBarrierStep =
  'none' | 'close_gate' | 'session' | 'pairing' | 'identity_restore' |
  'cloud_and_journal' | 'runtime_secrets' | 'complete';

export interface MoonlightBarrierResult {
  ok: boolean;
  failedStep: MoonlightBarrierStep;
  gateClosed: boolean;
}

export interface MoonlightDataLifecyclePort {
  closeMutationAndLaunchGate(reason: string): boolean;
  stopSession(timeoutMs: number): Promise<boolean>;
  cancelPairing(timeoutMs: number): Promise<boolean>;
  cancelIdentityRestore(timeoutMs: number): Promise<boolean>;
  drainCloudAndJournal(timeoutMs: number): Promise<boolean>;
  clearRuntimeSecrets(): boolean;
  restorePreviousScopeGate(): boolean;
  bindScope(lease: AccountSessionLease): boolean;
}

function failed(
  step: MoonlightBarrierStep, gateClosed: boolean
): MoonlightBarrierResult {
  return { ok: false, failedStep: step, gateClosed: gateClosed };
}

/** Pure ordered drain used by the singleton and isolated lifecycle tests. */
export async function executeMoonlightDataLifecycleDrain(
  port: MoonlightDataLifecyclePort,
  reason: string,
  timeoutMs: number
): Promise<MoonlightBarrierResult> {
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0 ||
      reason.trim() === '') { return failed('none', false); }
  if (!port.closeMutationAndLaunchGate(reason)) {
    return failed('close_gate', false);
  }
  const operations: Array<() => Promise<boolean>> = [
    (): Promise<boolean> => port.stopSession(timeoutMs),
    (): Promise<boolean> => port.cancelPairing(timeoutMs),
    (): Promise<boolean> => port.cancelIdentityRestore(timeoutMs),
    (): Promise<boolean> => port.drainCloudAndJournal(timeoutMs)
  ];
  const steps: MoonlightBarrierStep[] = [
    'session', 'pairing', 'identity_restore', 'cloud_and_journal'
  ];
  for (let i = 0; i < operations.length; i++) {
    let completed: boolean = false;
    try { completed = await operations[i](); } catch (_error) {}
    if (!completed) {
      port.restorePreviousScopeGate();
      return failed(steps[i], true);
    }
  }
  if (!port.clearRuntimeSecrets()) {
    port.restorePreviousScopeGate();
    return failed('runtime_secrets', true);
  }
  return { ok: true, failedStep: 'complete', gateClosed: true };
}

/**
 * Before N1 registers a runtime port, Moonlight owns no session, pairing,
 * identity restore or cloud task, so drain is a safe no-op. Once registered,
 * failure blocks the account transition and reopens only the previous gate.
 */
export class MoonlightDataLifecycleBarrier {
  private static instance: MoonlightDataLifecycleBarrier;
  private port: MoonlightDataLifecyclePort | null = null;

  static getInstance(): MoonlightDataLifecycleBarrier {
    if (!MoonlightDataLifecycleBarrier.instance) {
      MoonlightDataLifecycleBarrier.instance =
        new MoonlightDataLifecycleBarrier();
    }
    return MoonlightDataLifecycleBarrier.instance;
  }

  registerPort(port: MoonlightDataLifecyclePort): void {
    this.port = port;
  }

  unregisterPort(port: MoonlightDataLifecyclePort): void {
    if (this.port === port) { this.port = null; }
  }

  async drain(reason: string,
    timeoutMs: number = 10000): Promise<boolean> {
    if (this.port === null) { return true; }
    const outcome: MoonlightBarrierResult =
      await executeMoonlightDataLifecycleDrain(
        this.port, reason, timeoutMs);
    return outcome.ok;
  }

  bindScope(lease: AccountSessionLease): boolean {
    if (this.port === null) { return true; }
    return this.port.bindScope(cloneAccountSessionLease(lease));
  }
}
