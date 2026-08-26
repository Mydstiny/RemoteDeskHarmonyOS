import { SshSftpTaskRecord, SshSftpTaskStage } from '../../SshSftpTaskPolicy';

export type SshTransferCenterFilter = 'all' | 'active' | 'attention' | 'completed';
export type SshTransferCenterAction = 'pause' | 'resume' | 'retry' | 'cancel' | 'clear';

export interface SshTransferCenterTaskView {
  taskId: string;
  batchId: string;
  hostAlias: string;
  title: string;
  directionLabel: string;
  stage: SshSftpTaskStage;
  stageLabel: string;
  progress: number;
  progressLabel: string;
  canPause: boolean;
  canResume: boolean;
  canRetry: boolean;
  canCancel: boolean;
  canClear: boolean;
  updatedAt: number;
}

export interface SshTransferCenterSummary {
  total: number;
  active: number;
  attention: number;
  completed: number;
}

export interface SshTransferHostAlias {
  hostId: string;
  alias: string;
}

const TERMINAL_STAGES: Array<SshSftpTaskStage> = ['completed', 'cancelled'];
const ATTENTION_STAGES: Array<SshSftpTaskStage> = [
  'failed', 'needsAuthorization', 'needsAuthentication', 'waitingForConnection',
  'awaitingConflictDecision'
];

function isTerminal(stage: SshSftpTaskStage): boolean {
  return TERMINAL_STAGES.indexOf(stage) >= 0;
}

function needsAttention(stage: SshSftpTaskStage): boolean {
  return ATTENTION_STAGES.indexOf(stage) >= 0;
}

export function sshTransferStageLabel(stage: SshSftpTaskStage): string {
  if (stage === 'queued') { return '排队中'; }
  if (stage === 'inspecting') { return '正在检查'; }
  if (stage === 'awaitingConflictDecision') { return '等待冲突处理'; }
  if (stage === 'transferring') { return '传输中'; }
  if (stage === 'paused') { return '已暂停'; }
  if (stage === 'waitingForConnection') { return '等待网络/连接'; }
  if (stage === 'verifying') { return '正在校验'; }
  if (stage === 'committing') { return '正在提交'; }
  if (stage === 'needsAuthorization') { return '需要文件授权'; }
  if (stage === 'needsAuthentication') { return '需要 SSH 鉴权'; }
  if (stage === 'failed') { return '失败'; }
  if (stage === 'cancelled') { return '已取消'; }
  return '已完成';
}

function safeAlias(hostId: string, aliases: Array<SshTransferHostAlias>): string {
  for (let index: number = 0; index < aliases.length; index++) {
    if (aliases[index].hostId !== hostId) { continue; }
    const alias: string = aliases[index].alias.trim().substring(0, 96);
    if (alias.length > 0 && alias !== hostId) { return alias; }
  }
  return 'SSH 主机';
}

function safeTitle(record: SshSftpTaskRecord): string {
  const name: string = record.fileName.trim().substring(0, 255);
  return name.length > 0 ? name : (record.isDirectory ? '目录传输' : '文件传输');
}

function progressFor(record: SshSftpTaskRecord): number {
  if (record.stage === 'completed') { return 1; }
  if (!Number.isFinite(record.totalBytes) || record.totalBytes <= 0 ||
    !Number.isFinite(record.verifiedOffset) || record.verifiedOffset <= 0) { return 0; }
  return Math.max(0, Math.min(1, record.verifiedOffset / record.totalBytes));
}

function progressLabel(record: SshSftpTaskRecord, progress: number): string {
  if (record.isDirectory && record.totalBytes <= 0) { return '目录'; }
  if (record.totalBytes < 0) { return '大小未知'; }
  return Math.floor(progress * 100).toString() + '%';
}

function matchesFilter(stage: SshSftpTaskStage, filter: SshTransferCenterFilter): boolean {
  if (filter === 'all') { return true; }
  if (filter === 'active') { return !isTerminal(stage) && !needsAttention(stage); }
  if (filter === 'attention') { return needsAttention(stage) || stage === 'paused'; }
  return isTerminal(stage);
}

function stagePriority(stage: SshSftpTaskStage): number {
  if (needsAttention(stage)) { return 0; }
  if (!isTerminal(stage)) { return 1; }
  return 2;
}

/**
 * Produce a path-free, address-free UI projection. The task store remains the
 * sole metadata owner and the transfer engine remains the sole I/O owner.
 */
export function buildSshTransferCenterViews(records: Array<SshSftpTaskRecord>,
  aliases: Array<SshTransferHostAlias>, filter: SshTransferCenterFilter = 'all',
  ownerHostId: string = ''): Array<SshTransferCenterTaskView> {
  const owner: string = ownerHostId.trim();
  const result: Array<SshTransferCenterTaskView> = [];
  for (let index: number = 0; index < records.length; index++) {
    const record: SshSftpTaskRecord = records[index];
    if ((owner.length > 0 && record.hostId !== owner) || !matchesFilter(record.stage, filter)) {
      continue;
    }
    const progress: number = progressFor(record);
    result.push({
      taskId: record.taskId,
      batchId: record.batchId,
      hostAlias: safeAlias(record.hostId, aliases),
      title: safeTitle(record),
      directionLabel: record.sourceEndpoint?.kind === 'ssh' && record.targetEndpoint?.kind === 'ssh'
        ? 'SSH → SSH' : (record.direction === 'upload' ? '上传' : '下载'),
      stage: record.stage,
      stageLabel: sshTransferStageLabel(record.stage),
      progress,
      progressLabel: progressLabel(record, progress),
      canPause: record.stage === 'transferring',
      canResume: record.stage === 'paused' || record.stage === 'waitingForConnection',
      canRetry: record.stage === 'failed' || record.stage === 'cancelled' ||
        record.stage === 'needsAuthorization' || record.stage === 'needsAuthentication' ||
        record.stage === 'awaitingConflictDecision',
      canCancel: !isTerminal(record.stage),
      canClear: isTerminal(record.stage),
      updatedAt: Number.isFinite(record.updatedAt) ? record.updatedAt : 0
    });
  }
  result.sort((left: SshTransferCenterTaskView, right: SshTransferCenterTaskView): number => {
    const priority: number = stagePriority(left.stage) - stagePriority(right.stage);
    if (priority !== 0) { return priority; }
    if (left.updatedAt !== right.updatedAt) { return right.updatedAt - left.updatedAt; }
    return left.taskId < right.taskId ? -1 : (left.taskId > right.taskId ? 1 : 0);
  });
  return result;
}

export function summarizeSshTransferCenter(records: Array<SshSftpTaskRecord>):
  SshTransferCenterSummary {
  let active: number = 0;
  let attention: number = 0;
  let completed: number = 0;
  for (let index: number = 0; index < records.length; index++) {
    const stage: SshSftpTaskStage = records[index].stage;
    if (isTerminal(stage)) { completed++; }
    else if (needsAttention(stage) || stage === 'paused') { attention++; }
    else { active++; }
  }
  return { total: records.length, active, attention, completed };
}

export function canExecuteSshTransferCenterAction(view: SshTransferCenterTaskView,
  action: SshTransferCenterAction): boolean {
  if (action === 'pause') { return view.canPause; }
  if (action === 'resume') { return view.canResume; }
  if (action === 'retry') { return view.canRetry; }
  if (action === 'cancel') { return view.canCancel; }
  return view.canClear;
}
