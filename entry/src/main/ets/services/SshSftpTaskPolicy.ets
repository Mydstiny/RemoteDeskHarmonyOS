/**
 * SSH-only durable transfer metadata. The persisted shape intentionally
 * excludes credentials, picker grants, local URI values and file contents.
 */
export type SshSftpTaskDirection = 'upload' | 'download';

export type SshSftpTaskStage =
  | 'queued'
  | 'transferring'
  | 'waitingForConnection'
  | 'needsAuthorization'
  | 'needsAuthentication'
  | 'failed'
  | 'cancelled'
  | 'completed';

export type SshSftpResumeDisposition =
  | 'NeedsAuthorization'
  | 'NeedsAuthentication'
  | 'ReadyToResume'
  | 'NotResumable';

export interface SshSftpTaskRecord {
  taskId: string;
  hostId: string;
  direction: SshSftpTaskDirection;
  remotePath: string;
  fileName: string;
  totalBytes: number;
  verifiedOffset: number;
  sourceSize: number;
  sourceMtime: number;
  partialSize: number;
  partialMtime: number;
  sessionGeneration: number;
  sequence: number;
  stage: SshSftpTaskStage;
  updatedAt: number;
}

export interface SshSftpResumeContext {
  hasAuthorization: boolean;
  hasAuthentication: boolean;
  hasMatchingSession: boolean;
  hasMatchingPartial: boolean;
}

const MAX_TASKS: number = 64;
const MAX_TASK_ID_LENGTH: number = 96;
const MAX_HOST_ID_LENGTH: number = 160;
const MAX_REMOTE_PATH_LENGTH: number = 2048;
const MAX_FILE_NAME_LENGTH: number = 255;

const STAGES: SshSftpTaskStage[] = [
  'queued', 'transferring', 'waitingForConnection', 'needsAuthorization',
  'needsAuthentication', 'failed', 'cancelled', 'completed'
];

function boundedText(value: Object, maxLength: number): string {
  if (typeof value !== 'string') { return ''; }
  const text: string = value as string;
  return text.trim().substring(0, maxLength);
}

function finiteNonNegative(value: Object, fallback: number = -1): number {
  if (typeof value !== 'number') { return fallback; }
  const numberValue: number = value as number;
  return Number.isFinite(numberValue) && numberValue >= 0 ? numberValue : fallback;
}

function stageValue(value: Object): SshSftpTaskStage {
  if (typeof value === 'string' && STAGES.indexOf(value as SshSftpTaskStage) >= 0) {
    return value as SshSftpTaskStage;
  }
  return 'failed';
}

function directionValue(value: Object): SshSftpTaskDirection {
  return value === 'download' ? 'download' : 'upload';
}

/** Normalize untrusted persisted JSON and reject records without a stable key. */
export function normalizeSshSftpTaskRecord(value: Object): SshSftpTaskRecord | null {
  if (value === null || typeof value !== 'object') { return null; }
  const raw: Record<string, Object> = value as Record<string, Object>;
  const taskId: string = boundedText(raw['taskId'], MAX_TASK_ID_LENGTH);
  const hostId: string = boundedText(raw['hostId'], MAX_HOST_ID_LENGTH);
  const remotePath: string = boundedText(raw['remotePath'], MAX_REMOTE_PATH_LENGTH);
  const fileName: string = boundedText(raw['fileName'], MAX_FILE_NAME_LENGTH);
  if (taskId.length === 0 || hostId.length === 0 || remotePath.length === 0 || fileName.length === 0) {
    return null;
  }
  const totalBytes: number = finiteNonNegative(raw['totalBytes']);
  const verifiedOffset: number = finiteNonNegative(raw['verifiedOffset'], 0);
  // Keep an unknown total unknown. Treating it as zero can turn a truncated
  // or legacy record into a seemingly valid zero-byte resume.
  const safeTotal: number = totalBytes;
  const safeOffset: number = safeTotal < 0 ? -1 : Math.min(verifiedOffset, safeTotal);
  return {
    taskId,
    hostId,
    direction: directionValue(raw['direction']),
    remotePath,
    fileName,
    totalBytes: safeTotal,
    verifiedOffset: safeOffset,
    sourceSize: finiteNonNegative(raw['sourceSize']),
    sourceMtime: finiteNonNegative(raw['sourceMtime']),
    partialSize: finiteNonNegative(raw['partialSize']),
    partialMtime: finiteNonNegative(raw['partialMtime']),
    sessionGeneration: finiteNonNegative(raw['sessionGeneration'], 0),
    sequence: finiteNonNegative(raw['sequence'], 0),
    stage: stageValue(raw['stage']),
    updatedAt: finiteNonNegative(raw['updatedAt'], 0)
  };
}

export function canTransitionSshSftpTask(from: SshSftpTaskStage,
  to: SshSftpTaskStage): boolean {
  if (from === to) { return true; }
  if (from === 'completed') { return false; }
  if (from === 'cancelled') { return to === 'queued'; }
  if (from === 'failed') { return to === 'queued' || to === 'needsAuthorization' || to === 'needsAuthentication'; }
  if (from === 'needsAuthorization') { return to === 'queued' || to === 'cancelled'; }
  if (from === 'needsAuthentication') { return to === 'queued' || to === 'cancelled'; }
  if (from === 'waitingForConnection') {
    return to === 'queued' || to === 'transferring' || to === 'cancelled' || to === 'needsAuthentication';
  }
  if (from === 'queued') { return to === 'transferring' || to === 'cancelled' || to === 'needsAuthorization' || to === 'needsAuthentication'; }
  return to === 'waitingForConnection' || to === 'failed' || to === 'cancelled' || to === 'completed';
}

export function sshSftpResumeDisposition(record: SshSftpTaskRecord,
  context: SshSftpResumeContext): SshSftpResumeDisposition {
  if (!context.hasAuthorization) { return 'NeedsAuthorization'; }
  if (!context.hasAuthentication) { return 'NeedsAuthentication'; }
  if (!context.hasMatchingSession || !context.hasMatchingPartial ||
    record.totalBytes < 0 || record.totalBytes !== record.sourceSize ||
    record.verifiedOffset < 0 || record.verifiedOffset > record.totalBytes ||
    record.sourceSize < 0 || record.sourceMtime < 0 ||
    record.partialSize !== record.verifiedOffset || record.partialMtime < 0) {
    return 'NotResumable';
  }
  return 'ReadyToResume';
}

/** Replace by id, keep newest sequence first, and cap durable growth. */
export function upsertSshSftpTask(records: SshSftpTaskRecord[],
  next: SshSftpTaskRecord): SshSftpTaskRecord[] {
  const result: SshSftpTaskRecord[] = [];
  for (let index = 0; index < records.length; index++) {
    if (records[index].taskId !== next.taskId) { result.push(records[index]); }
  }
  result.push(next);
  result.sort((a: SshSftpTaskRecord, b: SshSftpTaskRecord): number => b.sequence - a.sequence);
  return result.slice(0, MAX_TASKS);
}

export function sshSftpTaskMaxCount(): number {
  return MAX_TASKS;
}
