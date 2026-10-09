/**
 * 连接后步骤 (Pro, plan 2026-10-09 §3): resolving a workspace entry's steps against what is saved now, the order they
 * run in, and the words the run card and the confirmations show. Pure: no ArkUI, stores or terminal.
 */
import { WorkspaceStep, WorkspaceStepKind } from './WorkspacePolicy';

const SKIPPED_AFTER_FAILURE: string = '上一步没有成功，已跳过';

/** What a step refers to, as the session sees it now. */
export interface WorkspaceStepTarget {
  id: string;
  title: string;
  /** A saved command that renders without secrets or missing variables (forwards: always true). */
  usable: boolean;
}

export type WorkspaceStepState = 'pending' | 'running' | 'done' | 'failed' | 'skipped' | 'invalid';

export interface WorkspaceStepRunItem {
  kind: WorkspaceStepKind;
  ref: string;
  path: string;
  execute: boolean;
  requirePrevious: boolean;
  label: string;
  state: WorkspaceStepState;
  message: string;
}

export interface WorkspaceStepRun {
  workspaceId: string;
  workspaceName: string;
  /** The workspace version the steps came from: an edit since then stops the run. */
  workspaceUpdatedAt: number;
  hostId: string;
  items: WorkspaceStepRunItem[];
  paused: boolean;
  cancelled: boolean;
}

/** The directory step's command: the path single-quoted, so nothing in it is read by the shell. */
export function workspaceStepCdCommand(path: string): string {
  return 'cd -- \'' + path.split('\'').join('\'\\\'\'') + '\'';
}

function stepLabel(step: WorkspaceStep, target: WorkspaceStepTarget | undefined): string {
  if (step.kind === 'cd') { return '进入目录 ' + step.path; }
  const title: string = target === undefined ? '' : target.title;
  if (step.kind === 'forward') { return '启用转发 ' + (title !== '' ? title : '（已失效）'); }
  return (step.execute ? '执行命令 ' : '插入命令 ') + (title !== '' ? title : '（已失效）');
}

/** The run of an entry's steps; a step whose forward or command is gone (or needs input) is 已失效 from the start. */
export function workspaceStepRunFor(workspaceId: string, workspaceName: string, workspaceUpdatedAt: number,
  hostId: string, steps: WorkspaceStep[], forwards: WorkspaceStepTarget[],
  snippets: WorkspaceStepTarget[]): WorkspaceStepRun {
  const items: WorkspaceStepRunItem[] = steps.map((step: WorkspaceStep): WorkspaceStepRunItem => {
    const pool: WorkspaceStepTarget[] = step.kind === 'forward' ? forwards : step.kind === 'snippet' ? snippets : [];
    const target: WorkspaceStepTarget | undefined = step.kind === 'cd' ? undefined :
      pool.find((item: WorkspaceStepTarget): boolean => item.id === step.ref);
    const invalid: boolean = step.kind !== 'cd' && (target === undefined || !target.usable);
    return {
      kind: step.kind, ref: step.ref, path: step.path, execute: step.execute, requirePrevious: step.requirePrevious,
      label: stepLabel(step, target), state: invalid ? 'invalid' : 'pending',
      message: invalid ? (target === undefined ? '已失效：引用的' + (step.kind === 'forward' ? '转发' : '命令') + '已删除' :
        '已失效：命令需要填写变量或含密钥，不能自动插入') : ''
    };
  });
  return { workspaceId, workspaceName, workspaceUpdatedAt, hostId, items, paused: false, cancelled: false };
}

function copyRun(run: WorkspaceStepRun, items: WorkspaceStepRunItem[]): WorkspaceStepRun {
  return { workspaceId: run.workspaceId, workspaceName: run.workspaceName, workspaceUpdatedAt: run.workspaceUpdatedAt,
    hostId: run.hostId, items, paused: run.paused, cancelled: run.cancelled };
}

function copyItem(item: WorkspaceStepRunItem): WorkspaceStepRunItem {
  return { kind: item.kind, ref: item.ref, path: item.path, execute: item.execute,
    requirePrevious: item.requirePrevious, label: item.label, state: item.state, message: item.message };
}

export function setWorkspaceStepState(run: WorkspaceStepRun, index: number, state: WorkspaceStepState,
  message: string): WorkspaceStepRun {
  return copyRun(run, run.items.map((item: WorkspaceStepRunItem, at: number): WorkspaceStepRunItem => {
    const next: WorkspaceStepRunItem = copyItem(item);
    if (at === index) { next.state = state; next.message = message; }
    return next;
  }));
}

export function setWorkspaceStepRunPaused(run: WorkspaceStepRun, paused: boolean): WorkspaceStepRun {
  const next: WorkspaceStepRun = copyRun(run, run.items.map((item: WorkspaceStepRunItem): WorkspaceStepRunItem => copyItem(item)));
  next.paused = paused;
  return next;
}

/** Cancelled: whatever has not run is marked skipped. */
export function cancelWorkspaceStepRun(run: WorkspaceStepRun, reason: string): WorkspaceStepRun {
  const next: WorkspaceStepRun = copyRun(run, run.items.map((item: WorkspaceStepRunItem): WorkspaceStepRunItem => {
    const copied: WorkspaceStepRunItem = copyItem(item);
    if (copied.state === 'pending' || copied.state === 'running') { copied.state = 'skipped'; copied.message = reason; }
    return copied;
  }));
  next.cancelled = true;
  return next;
}

export interface WorkspaceStepPick {
  run: WorkspaceStepRun;
  index: number;
}

/**
 * The next step to run, or -1 (paused, cancelled, a step running, or none left). Steps that need the one before to
 * have succeeded are skipped on the way when it did not.
 */
export function nextWorkspaceStep(run: WorkspaceStepRun): WorkspaceStepPick {
  if (run.paused || run.cancelled ||
    run.items.some((item: WorkspaceStepRunItem): boolean => item.state === 'running')) {
    const idle: WorkspaceStepPick = { run, index: -1 };
    return idle;
  }
  let current: WorkspaceStepRun = run;
  for (let index = 0; index < current.items.length; index++) {
    const item: WorkspaceStepRunItem = current.items[index];
    if (item.state !== 'pending') { continue; }
    const previous: WorkspaceStepRunItem | undefined = index > 0 ? current.items[index - 1] : undefined;
    if (item.requirePrevious && previous !== undefined && previous.state !== 'done') {
      current = setWorkspaceStepState(current, index, 'skipped', SKIPPED_AFTER_FAILURE);
      continue;
    }
    const pick: WorkspaceStepPick = { run: current, index };
    return pick;
  }
  const done: WorkspaceStepPick = { run: current, index: -1 };
  return done;
}

export function workspaceStepRunFinished(run: WorkspaceStepRun): boolean {
  return run.cancelled || run.items.every((item: WorkspaceStepRunItem): boolean =>
    item.state !== 'pending' && item.state !== 'running');
}

/** A step that presses Enter for the user: the run asks first, every time. */
export function workspaceStepsNeedConfirmation(run: WorkspaceStepRun): boolean {
  return run.items.some((item: WorkspaceStepRunItem): boolean =>
    item.state === 'pending' && item.kind === 'snippet' && item.execute);
}

/** Each step on its own line, for the preview before the first run and the confirmation of auto-run commands. */
export function workspaceStepPreview(run: WorkspaceStepRun): string {
  return run.items.map((item: WorkspaceStepRunItem, index: number): string =>
    (index + 1).toString() + '. ' + item.label + (item.state === 'invalid' ? '（已失效，不会执行）' : '') +
      (item.requirePrevious && index > 0 ? '（上一步成功才继续）' : '')).join('\n');
}

/** The preview is shown once per workspace version (and again after an edit). */
export function workspaceStepPreviewKey(workspaceId: string, workspaceUpdatedAt: number, hostId: string): string {
  return workspaceId + '|' + Math.floor(workspaceUpdatedAt).toString() + '|' + hostId;
}

export function workspaceStepRunSummary(run: WorkspaceStepRun): string {
  const count = (state: WorkspaceStepState): number =>
    run.items.filter((item: WorkspaceStepRunItem): boolean => item.state === state).length;
  const parts: string[] = [];
  if (count('done') > 0) { parts.push(count('done').toString() + ' 步完成'); }
  if (count('failed') > 0) { parts.push(count('failed').toString() + ' 步失败'); }
  if (count('skipped') + count('invalid') > 0) { parts.push((count('skipped') + count('invalid')).toString() + ' 步跳过'); }
  if (count('pending') + count('running') > 0) { parts.push((count('pending') + count('running')).toString() + ' 步待执行'); }
  return parts.join(' · ');
}

export function workspaceStepStateLabel(state: WorkspaceStepState): string {
  switch (state) {
    case 'pending': return '等待';
    case 'running': return '执行中';
    case 'done': return '完成';
    case 'failed': return '失败';
    case 'skipped': return '已跳过';
    default: return '已失效';
  }
}


/** 跳过下一步: the next waiting step is skipped by hand. */
export function skipNextWorkspaceStep(run: WorkspaceStepRun): WorkspaceStepRun {
  const index: number = run.items.findIndex((item: WorkspaceStepRunItem): boolean => item.state === 'pending');
  return index < 0 ? run : setWorkspaceStepState(run, index, 'skipped', '已手动跳过');
}

/** 重试: failed steps, and the ones skipped because of them, wait again (a cancelled run stays cancelled). */
export function retryWorkspaceSteps(run: WorkspaceStepRun): WorkspaceStepRun {
  if (run.cancelled) { return run; }
  const next: WorkspaceStepRun = copyRun(run, run.items.map((item: WorkspaceStepRunItem): WorkspaceStepRunItem => {
    const copied: WorkspaceStepRunItem = copyItem(item);
    if (copied.state === 'failed' || (copied.state === 'skipped' && copied.message === SKIPPED_AFTER_FAILURE)) {
      copied.state = 'pending';
      copied.message = '';
    }
    return copied;
  }));
  next.paused = false;
  return next;
}
