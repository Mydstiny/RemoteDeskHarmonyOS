/**
 * Pure admission rules for SSH broadcast input. The policy owns no session,
 * credentials, or transport state; callers must re-build the plan immediately
 * before dispatch so a reconnect cannot receive stale input.
 */

export type SshBroadcastMode = 'insert' | 'execute';

export type SshBroadcastTargetBlockReason =
  | 'not_connected'
  | 'safety_unknown'
  | 'authentication'
  | 'raw_mode'
  | 'fullscreen'
  | 'invalid_identity';

export interface SshBroadcastTargetV1 {
  hostId: string;
  label: string;
  sessionId: number;
  generation: number;
  visible: boolean;
  connected: boolean;
  safetyKnown: boolean;
  authenticationPrompt: boolean;
  rawMode: boolean;
  fullscreenMode: boolean;
}

export interface SshBroadcastTargetDecisionV1 {
  target: SshBroadcastTargetV1;
  selected: boolean;
  eligible: boolean;
  reason: SshBroadcastTargetBlockReason | '';
}

export type SshBroadcastPlanCode =
  | 'ok'
  | 'empty_text'
  | 'no_targets'
  | 'no_eligible_targets'
  | 'too_many_targets'
  | 'invalid_text';

export interface SshBroadcastPlanV1 {
  ok: boolean;
  code: SshBroadcastPlanCode;
  text: string;
  mode: SshBroadcastMode;
  targets: Array<SshBroadcastTargetV1>;
  decisions: Array<SshBroadcastTargetDecisionV1>;
  requiresConfirmation: boolean;
  confirmationReason: string;
}

export const SSH_BROADCAST_MAX_TARGETS: number = 16;
export const SSH_BROADCAST_MAX_TEXT_CHARS: number = 4096;
export const SSH_BROADCAST_INPUT_FLAG_KEY: string = 'sshBroadcastInput';
export const SSH_BROADCAST_INPUT_DEFAULT_ENABLED: boolean = false;

/** High-risk broadcast never inherits the broader workbench rollout. */
export function resolveSshBroadcastInputEnabled(
  workbenchEnabled: boolean, broadcastFlagEnabled: boolean): boolean {
  return workbenchEnabled === true && broadcastFlagEnabled === true;
}

function emptyPlan(code: SshBroadcastPlanCode, mode: SshBroadcastMode,
  text: string = ''): SshBroadcastPlanV1 {
  return {
    ok: false, code, text, mode, targets: [], decisions: [],
    requiresConfirmation: false, confirmationReason: ''
  };
}

function validFinitePositive(value: number): boolean {
  return Number.isFinite(value) && Math.floor(value) > 0;
}

export function sshBroadcastTargetBlockReason(target: SshBroadcastTargetV1):
  SshBroadcastTargetBlockReason | '' {
  if (target.hostId.trim().length === 0 || !validFinitePositive(target.sessionId) ||
    !validFinitePositive(target.generation) || !target.visible) {
    return 'invalid_identity';
  }
  if (!target.connected) { return 'not_connected'; }
  if (!target.safetyKnown) { return 'safety_unknown'; }
  if (target.authenticationPrompt) { return 'authentication'; }
  if (target.rawMode) { return 'raw_mode'; }
  if (target.fullscreenMode) { return 'fullscreen'; }
  return '';
}

export function sshBroadcastTargetEligible(target: SshBroadcastTargetV1): boolean {
  return sshBroadcastTargetBlockReason(target) === '';
}

export function sshBroadcastTargetReasonText(reason: SshBroadcastTargetBlockReason | ''): string {
  switch (reason) {
    case 'not_connected': return '未连接';
    case 'safety_unknown': return '终端安全状态确认中';
    case 'authentication': return '认证/密码提示中';
    case 'raw_mode': return '全屏 TUI/raw 模式';
    case 'fullscreen': return '沉浸全屏中';
    case 'invalid_identity': return '会话身份不可用';
    default: return '可广播';
  }
}

function hasControlCharacters(value: string): boolean {
  for (let index: number = 0; index < value.length; index++) {
    const code: number = value.charCodeAt(index);
    if ((code < 0x20 && code !== 0x09 && code !== 0x0A && code !== 0x0D) || code === 0x7F) {
      return true;
    }
  }
  return false;
}

function isHighRiskCommand(value: string): boolean {
  const normalized: string = value.trim().toLowerCase();
  if (normalized.length === 0) { return false; }
  return /(^|[;&|\s])(sudo|su|rm\s+-rf|shutdown|reboot|mkfs|dd\s+if=)([;&|\s]|$)/.test(normalized);
}

function needsSecondConfirmation(value: string, mode: SshBroadcastMode): string {
  if (mode === 'execute') { return '执行模式会向所有已选会话发送回车'; }
  if (value.indexOf('\n') >= 0 || value.indexOf('\r') >= 0) {
    return '多行粘贴会同时写入多个会话';
  }
  if (hasControlCharacters(value)) { return '内容包含控制字符'; }
  if (isHighRiskCommand(value)) { return '内容可能包含高风险命令'; }
  return '';
}

function normalizedTargets(targets: Array<SshBroadcastTargetV1>): Array<SshBroadcastTargetV1> {
  const result: Array<SshBroadcastTargetV1> = [];
  const seen: Set<string> = new Set<string>();
  for (let index: number = 0; index < targets.length; index++) {
    const target: SshBroadcastTargetV1 = targets[index];
    const hostId: string = target.hostId.trim();
    if (hostId.length === 0 || seen.has(hostId)) { continue; }
    seen.add(hostId);
    result.push({
      hostId,
      label: target.label.trim().slice(0, 96),
      sessionId: Math.floor(target.sessionId),
      generation: Math.floor(target.generation),
      visible: target.visible === true,
      connected: target.connected === true,
      safetyKnown: target.safetyKnown === true,
      authenticationPrompt: target.authenticationPrompt === true,
      rawMode: target.rawMode === true,
      fullscreenMode: target.fullscreenMode === true
    });
    if (result.length >= SSH_BROADCAST_MAX_TARGETS) { break; }
  }
  return result;
}

/**
 * Preserve only explicit, currently eligible selections. The current host may
 * be preselected once when the broadcast surface opens, but a later refresh
 * must never replace a disconnected/unsafe target with another session.
 */
export function reconcileSshBroadcastSelection(
  targets: Array<SshBroadcastTargetV1>, previousTargets: Array<SshBroadcastTargetV1>,
  selectedHostIds: Array<string>,
  currentHostId: string, preselectCurrentWhenEmpty: boolean): Array<string> {
  const normalizedTargetsValue: Array<SshBroadcastTargetV1> = normalizedTargets(targets);
  const eligible: Map<string, SshBroadcastTargetV1> = new Map<string, SshBroadcastTargetV1>();
  for (let index: number = 0; index < normalizedTargetsValue.length; index++) {
    const target: SshBroadcastTargetV1 = normalizedTargetsValue[index];
    if (sshBroadcastTargetEligible(target)) { eligible.set(target.hostId, target); }
  }
  const priorEligible: Map<string, SshBroadcastTargetV1> =
    new Map<string, SshBroadcastTargetV1>();
  const normalizedPrevious: Array<SshBroadcastTargetV1> = normalizedTargets(previousTargets);
  for (let index: number = 0; index < normalizedPrevious.length; index++) {
    const target: SshBroadcastTargetV1 = normalizedPrevious[index];
    if (sshBroadcastTargetEligible(target)) { priorEligible.set(target.hostId, target); }
  }
  const result: Array<string> = [];
  const seen: Set<string> = new Set<string>();
  for (let index: number = 0; index < selectedHostIds.length; index++) {
    const hostId: string = selectedHostIds[index].trim();
    const currentTarget: SshBroadcastTargetV1 | undefined = eligible.get(hostId);
    const previousTarget: SshBroadcastTargetV1 | undefined = priorEligible.get(hostId);
    // A reconnect can become eligible again before this refresh runs. Keep
    // the selection only when the exact session/generation fence is unchanged;
    // a new native owner always requires another explicit user gesture.
    if (hostId.length === 0 || seen.has(hostId) || currentTarget === undefined ||
      previousTarget === undefined || currentTarget.sessionId !== previousTarget.sessionId ||
      currentTarget.generation !== previousTarget.generation) { continue; }
    seen.add(hostId);
    result.push(hostId);
    if (result.length >= SSH_BROADCAST_MAX_TARGETS) { break; }
  }
  const current: string = currentHostId.trim();
  if (result.length === 0 && preselectCurrentWhenEmpty && eligible.has(current)) {
    result.push(current);
  }
  return result;
}

export function buildSshBroadcastPlan(
  targets: Array<SshBroadcastTargetV1>, selectedHostIds: Array<string>,
  text: string, mode: SshBroadcastMode): SshBroadcastPlanV1 {
  const normalizedText: string = text.slice(0, SSH_BROADCAST_MAX_TEXT_CHARS);
  if (normalizedText.trim().length === 0) { return emptyPlan('empty_text', mode); }
  if (text.length > SSH_BROADCAST_MAX_TEXT_CHARS) {
    return emptyPlan('invalid_text', mode, normalizedText);
  }
  const normalizedTargetsValue: Array<SshBroadcastTargetV1> = normalizedTargets(targets);
  if (normalizedTargetsValue.length === 0) { return emptyPlan('no_targets', mode, normalizedText); }
  const selected: Set<string> = new Set<string>();
  for (let index: number = 0; index < selectedHostIds.length; index++) {
    const hostId: string = selectedHostIds[index].trim();
    if (hostId.length > 0) { selected.add(hostId); }
  }
  const decisions: Array<SshBroadcastTargetDecisionV1> = [];
  const allowed: Array<SshBroadcastTargetV1> = [];
  for (let index: number = 0; index < normalizedTargetsValue.length; index++) {
    const target: SshBroadcastTargetV1 = normalizedTargetsValue[index];
    const isSelected: boolean = selected.has(target.hostId);
    const reason: SshBroadcastTargetBlockReason | '' =
      sshBroadcastTargetBlockReason(target);
    const eligible: boolean = reason === '';
    decisions.push({ target, selected: isSelected, eligible, reason });
    if (isSelected && eligible) { allowed.push(target); }
  }
  if (allowed.length === 0) {
    return {
      ok: false, code: 'no_eligible_targets', text: normalizedText, mode,
      targets: [], decisions, requiresConfirmation: false, confirmationReason: ''
    };
  }
  const confirmationReason: string = needsSecondConfirmation(normalizedText, mode);
  return {
    ok: true, code: 'ok', text: normalizedText, mode, targets: allowed, decisions,
    requiresConfirmation: confirmationReason.length > 0,
    confirmationReason
  };
}

/**
 * A confirmation may be reused only for the same payload/mode and an exact
 * identity subset of the targets shown before the system dialog. Targets may
 * disappear while waiting, but a new/reconnected owner must be reconfirmed.
 */
export function sshBroadcastConfirmationStillValid(
  confirmedPlan: SshBroadcastPlanV1, currentPlan: SshBroadcastPlanV1): boolean {
  if (!confirmedPlan.ok || !confirmedPlan.requiresConfirmation || !currentPlan.ok ||
    confirmedPlan.text !== currentPlan.text || confirmedPlan.mode !== currentPlan.mode ||
    !currentPlan.requiresConfirmation || currentPlan.targets.length === 0) {
    return false;
  }
  for (let currentIndex: number = 0; currentIndex < currentPlan.targets.length; currentIndex++) {
    const current: SshBroadcastTargetV1 = currentPlan.targets[currentIndex];
    let matched: boolean = false;
    for (let confirmedIndex: number = 0;
      confirmedIndex < confirmedPlan.targets.length; confirmedIndex++) {
      const confirmed: SshBroadcastTargetV1 = confirmedPlan.targets[confirmedIndex];
      if (current.hostId === confirmed.hostId && current.sessionId === confirmed.sessionId &&
        current.generation === confirmed.generation) {
        matched = true;
        break;
      }
    }
    if (!matched) { return false; }
  }
  return true;
}
