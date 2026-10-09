import { describe, it, expect } from '@ohos/hypium';
import { WorkspaceStep, validateWorkspaceSteps } from '../main/ets/services/pro/workspace/WorkspacePolicy';
import {
  WorkspaceStepPick,
  WorkspaceStepRun,
  WorkspaceStepTarget,
  nextWorkspaceStep,
  setWorkspaceStepState,
  workspaceStepCdCommand,
  workspaceStepRunFor
} from '../main/ets/services/pro/workspace/WorkspaceStepPolicy';

export default function workspaceStepPolicyTest() {
  describe('WorkspaceStepPolicy', () => {
    it('validates_and_quotes', 0, () => {
      const cd: WorkspaceStep = { kind: 'cd', ref: '', path: '/srv', execute: false, requirePrevious: false };
      expect(validateWorkspaceSteps('ssh', [cd])).assertTrue();
      expect(validateWorkspaceSteps('rdp', [cd])).assertFalse();
      expect(workspaceStepCdCommand('/a b')).assertEqual('cd -- \'/a b\'');
    });
    it('skips_dependent_step_after_failure', 0, () => {
      const steps: WorkspaceStep[] = [
        { kind: 'forward', ref: 'f', path: '', execute: false, requirePrevious: false },
        { kind: 'cd', ref: '', path: '/b', execute: false, requirePrevious: true }
      ];
      const forwards: WorkspaceStepTarget[] = [{ id: 'f', title: 'F', usable: true }];
      let run: WorkspaceStepRun = workspaceStepRunFor('w', 'W', 1, 'h', steps, forwards, []);
      run = setWorkspaceStepState(run, 0, 'failed', 'x');
      const pick: WorkspaceStepPick = nextWorkspaceStep(run);
      expect(pick.index).assertEqual(-1);
      expect(pick.run.items[1].state).assertEqual('skipped');
    });
  });
}
