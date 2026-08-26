import { describe, it, expect } from '@ohos/hypium';
import {
  buildSshBroadcastPlan,
  reconcileSshBroadcastSelection,
  resolveSshBroadcastInputEnabled,
  sshBroadcastConfirmationStillValid,
  sshBroadcastTargetBlockReason,
  sshBroadcastTargetEligible,
  SSH_BROADCAST_INPUT_DEFAULT_ENABLED,
  SSH_BROADCAST_MAX_TARGETS,
  SshBroadcastTargetV1
} from '../main/ets/services/ssh/broadcast/SshBroadcastPolicy';

function target(hostId: string, connected: boolean = true,
  authenticationPrompt: boolean = false, rawMode: boolean = false,
  fullscreenMode: boolean = false, safetyKnown: boolean = true): SshBroadcastTargetV1 {
  return {
    hostId, label: hostId, sessionId: 100 + hostId.length, generation: 1,
    visible: true, connected, safetyKnown, authenticationPrompt, rawMode, fullscreenMode
  };
}

export default function sshBroadcastPolicyTest(): void {
  describe('SshBroadcastPolicy', (): void => {
    it('should_keep_broadcast_independently_disabled_by_default', 0, (): void => {
      expect(SSH_BROADCAST_INPUT_DEFAULT_ENABLED).assertFalse();
      expect(resolveSshBroadcastInputEnabled(true, false)).assertFalse();
      expect(resolveSshBroadcastInputEnabled(false, true)).assertFalse();
      expect(resolveSshBroadcastInputEnabled(true, true)).assertTrue();
    });

    it('should_block_disconnected_auth_raw_and_fullscreen_targets', 0, (): void => {
      expect(sshBroadcastTargetEligible(target('connected'))).assertTrue();
      expect(sshBroadcastTargetBlockReason(target('offline', false))).assertEqual('not_connected');
      expect(sshBroadcastTargetBlockReason(target('auth', true, true))).assertEqual('authentication');
      expect(sshBroadcastTargetBlockReason(target('raw', true, false, true))).assertEqual('raw_mode');
      expect(sshBroadcastTargetBlockReason(target('full', true, false, false, true))).assertEqual('fullscreen');
      expect(sshBroadcastTargetBlockReason(
        target('unknown', true, false, false, false, false))).assertEqual('safety_unknown');
    });

    it('should_dedupe_and_cap_targets_at_sixteen', 0, (): void => {
      const targets: Array<SshBroadcastTargetV1> = [];
      const selected: Array<string> = [];
      for (let index: number = 0; index < 20; index++) {
        const id: string = 'host-' + index.toString();
        targets.push(target(id));
        selected.push(id);
      }
      targets.push(target('host-0'));
      const plan = buildSshBroadcastPlan(targets, selected, 'echo ready', 'insert');
      expect(plan.ok).assertTrue();
      expect(plan.targets.length).assertEqual(SSH_BROADCAST_MAX_TARGETS);
    });

    it('should_require_confirmation_for_execute_multiline_and_risky_text', 0, (): void => {
      const safe = buildSshBroadcastPlan([target('host')], ['host'], 'echo ready', 'insert');
      expect(safe.requiresConfirmation).assertFalse();
      const execute = buildSshBroadcastPlan([target('host')], ['host'], 'echo ready', 'execute');
      expect(execute.requiresConfirmation).assertTrue();
      const multiline = buildSshBroadcastPlan([target('host')], ['host'], 'one\ntwo', 'insert');
      expect(multiline.requiresConfirmation).assertTrue();
      const risky = buildSshBroadcastPlan([target('host')], ['host'], 'sudo -S id', 'insert');
      expect(risky.requiresConfirmation).assertTrue();
    });

    it('should_bind_confirmation_to_payload_mode_and_exact_target_owners', 0, (): void => {
      const firstTarget: SshBroadcastTargetV1 = target('first');
      const secondTarget: SshBroadcastTargetV1 = target('second');
      const confirmed = buildSshBroadcastPlan(
        [firstTarget, secondTarget], ['first', 'second'], 'uptime', 'execute');
      const subset = buildSshBroadcastPlan(
        [firstTarget], ['first'], 'uptime', 'execute');
      expect(sshBroadcastConfirmationStillValid(confirmed, subset)).assertTrue();

      const changedText = buildSshBroadcastPlan(
        [firstTarget], ['first'], 'reboot', 'execute');
      expect(sshBroadcastConfirmationStillValid(confirmed, changedText)).assertFalse();
      const changedMode = buildSshBroadcastPlan(
        [firstTarget], ['first'], 'uptime\n', 'insert');
      expect(sshBroadcastConfirmationStillValid(confirmed, changedMode)).assertFalse();

      const reconnected: SshBroadcastTargetV1 = target('first');
      reconnected.generation = firstTarget.generation + 1;
      const changedOwner = buildSshBroadcastPlan(
        [reconnected], ['first'], 'uptime', 'execute');
      expect(sshBroadcastConfirmationStillValid(confirmed, changedOwner)).assertFalse();
      const added = buildSshBroadcastPlan(
        [firstTarget, target('new')], ['first', 'new'], 'uptime', 'execute');
      expect(sshBroadcastConfirmationStillValid(confirmed, added)).assertFalse();
    });

    it('should_omit_selected_blocked_targets_and_reject_empty_text', 0, (): void => {
      const plan = buildSshBroadcastPlan(
        [target('good'), target('bad', false)], ['good', 'bad'], 'echo ok', 'insert');
      expect(plan.ok).assertTrue();
      expect(plan.targets.length).assertEqual(1);
      expect(plan.targets[0].hostId).assertEqual('good');
      const empty = buildSshBroadcastPlan([target('good')], ['good'], '   ', 'insert');
      expect(empty.ok).assertFalse();
      expect(empty.code).assertEqual('empty_text');
    });

    it('should_reject_text_over_the_bound', 0, (): void => {
      let oversized: string = '';
      for (let index: number = 0; index < 4097; index++) { oversized += 'x'; }
      const plan = buildSshBroadcastPlan([target('host')], ['host'], oversized, 'insert');
      expect(plan.ok).assertFalse();
      expect(plan.code).assertEqual('invalid_text');
    });

    it('should_preselect_current_only_when_the_surface_first_opens', 0, (): void => {
      const targets: Array<SshBroadcastTargetV1> = [target('current'), target('other')];
      const opened: Array<string> = reconcileSshBroadcastSelection(
        targets, [], [], 'current', true);
      expect(opened.length).assertEqual(1);
      expect(opened[0]).assertEqual('current');

      const explicitEmpty: Array<string> = reconcileSshBroadcastSelection(
        targets, targets, [], 'current', false);
      expect(explicitEmpty.length).assertEqual(0);
    });

    it('should_not_replace_an_invalidated_explicit_target_during_send_refresh', 0, (): void => {
      const previous: Array<SshBroadcastTargetV1> = [target('current'), target('selected')];
      const refreshed: Array<string> = reconcileSshBroadcastSelection(
        [target('current'), target('selected', false)], previous,
        ['selected'], 'current', false);
      expect(refreshed.length).assertEqual(0);

      const preserved: Array<string> = reconcileSshBroadcastSelection(
        [target('current'), target('selected')], previous,
        ['selected', 'selected'], 'current', false);
      expect(preserved.length).assertEqual(1);
      expect(preserved[0]).assertEqual('selected');
    });

    it('should_drop_a_reconnected_target_with_a_new_generation', 0, (): void => {
      const previousTarget: SshBroadcastTargetV1 = target('selected');
      const reconnectedTarget: SshBroadcastTargetV1 = target('selected');
      reconnectedTarget.generation = previousTarget.generation + 1;
      const refreshed: Array<string> = reconcileSshBroadcastSelection(
        [target('current'), reconnectedTarget], [target('current'), previousTarget],
        ['selected'], 'current', false);
      expect(refreshed.length).assertEqual(0);
    });
  });
}
