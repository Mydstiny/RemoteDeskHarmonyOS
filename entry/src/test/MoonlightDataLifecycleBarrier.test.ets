import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
import { AccountSessionLease } from '../main/ets/services/AccountScopePolicy';
import {
  MoonlightBarrierResult,
  MoonlightDataLifecyclePort,
  executeMoonlightDataLifecycleDrain
} from '../main/ets/services/MoonlightDataLifecycleBarrier';

class MemoryLifecyclePort implements MoonlightDataLifecyclePort {
  events: string[] = [];
  failStep: string = '';
  throwStep: string = '';

  closeMutationAndLaunchGate(_reason: string): boolean {
    this.events.push('close_gate');
    return this.failStep !== 'close_gate';
  }

  async stopSession(_timeoutMs: number): Promise<boolean> {
    this.events.push('session');
    if (this.throwStep === 'session') { throw new Error('session'); }
    return this.failStep !== 'session';
  }

  async cancelPairing(_timeoutMs: number): Promise<boolean> {
    this.events.push('pairing');
    return this.failStep !== 'pairing';
  }

  async cancelIdentityRestore(_timeoutMs: number): Promise<boolean> {
    this.events.push('identity_restore');
    return this.failStep !== 'identity_restore';
  }

  async drainCloudAndJournal(_timeoutMs: number): Promise<boolean> {
    this.events.push('cloud_and_journal');
    return this.failStep !== 'cloud_and_journal';
  }

  clearRuntimeSecrets(): boolean {
    this.events.push('runtime_secrets');
    return this.failStep !== 'runtime_secrets';
  }

  restorePreviousScopeGate(): boolean {
    this.events.push('restore_gate');
    return true;
  }

  bindScope(_lease: AccountSessionLease): boolean {
    this.events.push('bind');
    return true;
  }
}

export default function moonlightDataLifecycleBarrierTest(): void {
  describe('MoonlightDataLifecycleBarrier', (): void => {
    it('drains_in_security_order_and_keeps_the_gate_closed_for_rebind', 0,
      async (): Promise<void> => {
        const port = new MemoryLifecyclePort();
        const result: MoonlightBarrierResult =
          await executeMoonlightDataLifecycleDrain(
            port, 'account-switch', 10000);
        expect(result.ok).assertTrue();
        expect(result.gateClosed).assertTrue();
        expect(port.events.join(',')).assertEqual(
          'close_gate,session,pairing,identity_restore,cloud_and_journal,runtime_secrets');
      });

    it('fails_before_runtime_work_when_the_gate_cannot_close', 0,
      async (): Promise<void> => {
        const port = new MemoryLifecyclePort();
        port.failStep = 'close_gate';
        const result = await executeMoonlightDataLifecycleDrain(
          port, 'logout', 10000);
        expect(result.failedStep).assertEqual('close_gate');
        expect(port.events.join(',')).assertEqual('close_gate');
      });

    it('stops_at_each_failed_async_owner_and_restores_the_previous_gate', 0,
      async (): Promise<void> => {
        const steps: string[] = [
          'session', 'pairing', 'identity_restore', 'cloud_and_journal'
        ];
        for (let i = 0; i < steps.length; i++) {
          const port = new MemoryLifecyclePort();
          port.failStep = steps[i];
          const result = await executeMoonlightDataLifecycleDrain(
            port, 'switch', 10000);
          expect(result.failedStep).assertEqual(steps[i]);
          expect(port.events[port.events.length - 1]).assertEqual('restore_gate');
        }
      });

    it('treats_thrown_teardown_as_failure_and_reopens_only_the_old_scope', 0,
      async (): Promise<void> => {
        const port = new MemoryLifecyclePort();
        port.throwStep = 'session';
        const result = await executeMoonlightDataLifecycleDrain(
          port, 'switch', 10000);
        expect(result.ok).assertFalse();
        expect(result.failedStep).assertEqual('session');
        expect(port.events.join(',')).assertEqual(
          'close_gate,session,restore_gate');
      });

    it('blocks_completion_when_ephemeral_secret_cleanup_fails', 0,
      async (): Promise<void> => {
        const port = new MemoryLifecyclePort();
        port.failStep = 'runtime_secrets';
        const result = await executeMoonlightDataLifecycleDrain(
          port, 'switch', 10000);
        expect(result.ok).assertFalse();
        expect(result.failedStep).assertEqual('runtime_secrets');
        expect(port.events[port.events.length - 1]).assertEqual('restore_gate');
      });
  });
}
