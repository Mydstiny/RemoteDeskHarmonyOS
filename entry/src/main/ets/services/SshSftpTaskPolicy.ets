/**
 * SSH-only durable transfer metadata. The persisted shape intentionally
 * excludes credentials, picker grants, local URI values and file contents.
 */
export type SshSftpTaskDirection = 'upload' | 'download';

export type SftpEndpointKind = 'local' | 'ssh';

export interface SftpEndpoint {
  kind: SftpEndpointKind;
  hostId?: string;
}

export interface SftpPartialIdentity {
  size: number;
  mtime: number;
  checksum?: string;
}

/** Explicit endpoint/path contract used by durable transfers. */
export interface SftpTransferSpec {
  schemaVersion: number;
  taskId: string;
  source: SftpEndpoint;
  target: SftpEndpoint;
  sourcePath: string;
  targetPath: string;
  direction: SshSftpTaskDirection;
  checksumPolicy: 'size_mtime' | 'sha256';
  partialIdentity?: SftpPartialIdentity;
}

export type SshSftpTaskStage =
  | 'queued'
  | 'inspecting'
  | 'awaitingConflictDecision'
  | 'transferring'
  | 'paused'
  | 'waitingForConnection'
  | 'verifying'
  | 'committing'
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

export type SshSftpTaskCommandKind =
  | 'pause'
  | 'resume'
  | 'cancel'
  | 'retry'
  | 'authorize'
  | 'authenticate'
  | 'detach'
  | 'complete';

export interface SshSftpTaskCommand {
  kind: SshSftpTaskCommandKind;
}

export type SshSftpTaskEventKind = 'restored' | 'changed' | 'removed';

export interface SshSftpTaskEvent {
  kind: SshSftpTaskEventKind;
  record: SshSftpTaskRecord;
}

export type SshSftpTaskListener = (event: SshSftpTaskEvent) => void;

export interface SshSftpTaskCommandResult {
  accepted: boolean;
  reason: string;
  record: SshSftpTaskRecord | null;
}

export interface SshSftpTaskRecord {
  schemaVersion?: number;
  taskId: string;
  batchId: string;
  relativePath: string;
  hostId: string;
  direction: SshSftpTaskDirection;
  isDirectory: boolean;
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
  sourceEndpoint?: SftpEndpoint;
  targetEndpoint?: SftpEndpoint;
  sourcePath?: string;
  targetPath?: string;
  partialIdentity?: SftpPartialIdentity;
  checksumPolicy?: 'size_mtime' | 'sha256';
  /** Atomic rename intent is durable before I/O; recovery checks target before source/partial. */
  commitState?: 'renaming' | 'renamed';
}

export interface SshSftpResumeContext {
  hasAuthorization: boolean;
  hasAuthentication: boolean;
  hasMatchingSession: boolean;
  hasMatchingPartial: boolean;
}

const MAX_TASKS: number = 64;
const MAX_TASK_ID_LENGTH: number = 96;
const MAX_BATCH_ID_LENGTH: number = 64;
const MAX_HOST_ID_LENGTH: number = 160;
const MAX_REMOTE_PATH_LENGTH: number = 2048;
const MAX_FILE_NAME_LENGTH: number = 255;
const SFTP_TASK_SCHEMA_VERSION: number = 4;

const STAGES: SshSftpTaskStage[] = [
  'queued', 'inspecting', 'awaitingConflictDecision', 'transferring', 'paused',
  'waitingForConnection', 'verifying', 'committing', 'needsAuthorization',
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

function endpointValue(value: Object, fallbackKind: SftpEndpointKind,
  fallbackHostId: string): SftpEndpoint | null {
  if (value === null || typeof value !== 'object') {
    return { kind: fallbackKind, hostId: fallbackKind === 'ssh' ? fallbackHostId : undefined };
  }
  const raw: Record<string, Object> = value as Record<string, Object>;
  const kind: SftpEndpointKind = raw['kind'] === 'ssh' ? 'ssh' : 'local';
  const hostId: string = boundedText(raw['hostId'], MAX_HOST_ID_LENGTH);
  if (kind === 'ssh' && hostId.length === 0) { return null; }
  return { kind, hostId: kind === 'ssh' ? hostId : undefined };
}

export function sftpEndpointKey(endpoint: SftpEndpoint): string {
  return endpoint.kind === 'ssh' ? 'ssh:' + (endpoint.hostId || '').trim() : 'local';
}

export function sftpEndpointPathIsSame(left: SftpEndpoint, leftPath: string,
  right: SftpEndpoint, rightPath: string): boolean {
  return sftpEndpointKey(left) === sftpEndpointKey(right) && leftPath.trim() === rightPath.trim();
}

export function isValidSftpTransferSpec(spec: SftpTransferSpec): boolean {
  const sameEndpointPath: boolean = sftpEndpointPathIsSame(
    spec.source, spec.sourcePath, spec.target, spec.targetPath);
  if (spec.schemaVersion <= 0 || spec.taskId.trim().length === 0 ||
    spec.sourcePath.trim().length === 0 || spec.targetPath.trim().length === 0 || sameEndpointPath) {
    return false;
  }
  if (spec.source.kind === 'ssh' && (spec.source.hostId || '').trim().length === 0) { return false; }
  if (spec.target.kind === 'ssh' && (spec.target.hostId || '').trim().length === 0) { return false; }
  return true;
}

/** Normalize untrusted persisted JSON and reject records without a stable key. */
export function normalizeSshSftpTaskRecord(value: Object): SshSftpTaskRecord | null {
  if (value === null || typeof value !== 'object') { return null; }
  const raw: Record<string, Object> = value as Record<string, Object>;
  const taskId: string = boundedText(raw['taskId'], MAX_TASK_ID_LENGTH);
  const batchId: string = boundedText(raw['batchId'], MAX_BATCH_ID_LENGTH);
  const relativePath: string = boundedText(raw['relativePath'], MAX_REMOTE_PATH_LENGTH);
  const hostId: string = boundedText(raw['hostId'], MAX_HOST_ID_LENGTH);
  const remotePath: string = boundedText(raw['remotePath'], MAX_REMOTE_PATH_LENGTH);
  const fileName: string = boundedText(raw['fileName'], MAX_FILE_NAME_LENGTH);
  if (taskId.length === 0 || hostId.length === 0 || remotePath.length === 0 || fileName.length === 0) {
    return null;
  }
  const direction: SshSftpTaskDirection = directionValue(raw['direction']);
  const sourceEndpoint: SftpEndpoint | null = endpointValue(
    raw['sourceEndpoint'], direction === 'upload' ? 'local' : 'ssh', hostId);
  const targetEndpoint: SftpEndpoint | null = endpointValue(
    raw['targetEndpoint'], direction === 'upload' ? 'ssh' : 'local', hostId);
  if (sourceEndpoint === null || targetEndpoint === null) { return null; }
  const sourcePath: string = boundedText(raw['sourcePath'], MAX_REMOTE_PATH_LENGTH) ||
    (direction === 'upload' ? relativePath || fileName : remotePath);
  const targetPath: string = boundedText(raw['targetPath'], MAX_REMOTE_PATH_LENGTH) ||
    (direction === 'upload' ? remotePath : relativePath || fileName);
  let partialIdentity: SftpPartialIdentity | undefined = undefined;
  const partialValue: Object = raw['partialIdentity'];
  if (partialValue !== null && typeof partialValue === 'object') {
    const partialObject: Record<string, Object> = partialValue as Record<string, Object>;
    partialIdentity = {
      size: finiteNonNegative(partialObject['size']),
      mtime: finiteNonNegative(partialObject['mtime']),
      checksum: boundedText(partialObject['checksum'], 128)
    };
  }
  const checksumPolicy: 'size_mtime' | 'sha256' = raw['checksumPolicy'] === 'sha256'
    ? 'sha256' : 'size_mtime';
  const spec: SftpTransferSpec = {
    schemaVersion: SFTP_TASK_SCHEMA_VERSION,
    taskId,
    source: sourceEndpoint,
    target: targetEndpoint,
    sourcePath,
    targetPath,
    direction,
    checksumPolicy,
    partialIdentity
  };
  if (!isValidSftpTransferSpec(spec)) { return null; }
  const totalBytes: number = finiteNonNegative(raw['totalBytes']);
  const verifiedOffset: number = finiteNonNegative(raw['verifiedOffset'], 0);
  // Keep an unknown total unknown. Treating it as zero can turn a truncated
  // or legacy record into a seemingly valid zero-byte resume.
  const safeTotal: number = totalBytes;
  const safeOffset: number = safeTotal < 0 ? -1 : Math.min(verifiedOffset, safeTotal);
  return {
    taskId,
    schemaVersion: SFTP_TASK_SCHEMA_VERSION,
    batchId,
    relativePath,
    hostId,
    direction,
    isDirectory: raw['isDirectory'] === true,
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
    updatedAt: finiteNonNegative(raw['updatedAt'], 0),
    sourceEndpoint,
    targetEndpoint,
    sourcePath,
    targetPath,
    partialIdentity,
    checksumPolicy,
    commitState: raw['commitState'] === 'renamed' ? 'renamed' :
      (raw['commitState'] === 'renaming' ? 'renaming' : undefined)
  };
}

/**
 * A process restart destroys the executor and all native session bindings.
 * Persisted in-flight stages therefore cannot remain authoritative: presenting
 * them as active would leave the UI stuck at "transferring" with no pump that
 * owns the task. Preserve the durable checkpoint and endpoint identity, but
 * require an explicit session rebind before the task can be queued again.
 */
export function recoverInterruptedSshSftpTaskRecord(record: SshSftpTaskRecord,
  recoveredAt: number = Date.now()): SshSftpTaskRecord {
  const interrupted: boolean = record.stage === 'inspecting' || record.stage === 'transferring' ||
    record.stage === 'verifying' || record.stage === 'committing';
  if (!interrupted) { return record; }
  const timestamp: number = Number.isFinite(recoveredAt) && recoveredAt >= 0
    ? recoveredAt : Date.now();
  return {
    schemaVersion: record.schemaVersion,
    taskId: record.taskId,
    batchId: record.batchId,
    relativePath: record.relativePath,
    hostId: record.hostId,
    direction: record.direction,
    isDirectory: record.isDirectory,
    remotePath: record.remotePath,
    fileName: record.fileName,
    totalBytes: record.totalBytes,
    verifiedOffset: record.verifiedOffset,
    sourceSize: record.sourceSize,
    sourceMtime: record.sourceMtime,
    partialSize: record.partialSize,
    partialMtime: record.partialMtime,
    stage: 'waitingForConnection',
    sessionGeneration: 0,
    sequence: Math.max(record.sequence + 1, timestamp),
    updatedAt: timestamp,
    sourceEndpoint: record.sourceEndpoint,
    targetEndpoint: record.targetEndpoint,
    sourcePath: record.sourcePath,
    targetPath: record.targetPath,
    partialIdentity: record.partialIdentity,
    checksumPolicy: record.checksumPolicy,
    commitState: record.commitState
  };
}

export function makeSftpTransferSpec(taskId: string, source: SftpEndpoint,
  target: SftpEndpoint, sourcePath: string, targetPath: string,
  direction: SshSftpTaskDirection, checksumPolicy: 'size_mtime' | 'sha256' = 'size_mtime'):
  SftpTransferSpec | null {
  const spec: SftpTransferSpec = {
    schemaVersion: SFTP_TASK_SCHEMA_VERSION,
    taskId: taskId.trim(),
    source,
    target,
    sourcePath: sourcePath.trim(),
    targetPath: targetPath.trim(),
    direction,
    checksumPolicy
  };
  return isValidSftpTransferSpec(spec) ? spec : null;
}

export function canTransitionSshSftpTask(from: SshSftpTaskStage,
  to: SshSftpTaskStage): boolean {
  if (from === to) { return true; }
  if (from === 'completed') { return false; }
  if (from === 'cancelled') { return to === 'queued'; }
  if (from === 'failed') {
    return to === 'queued' || to === 'needsAuthorization' || to === 'needsAuthentication' ||
      to === 'cancelled';
  }
  if (from === 'needsAuthorization') { return to === 'queued' || to === 'cancelled'; }
  if (from === 'needsAuthentication') { return to === 'queued' || to === 'cancelled'; }
  if (from === 'committing') {
    return to === 'completed' || to === 'failed' || to === 'waitingForConnection';
  }
  if (from === 'verifying') { return to === 'committing' || to === 'failed' || to === 'cancelled'; }
  if (from === 'paused') {
    return to === 'queued' || to === 'transferring' || to === 'waitingForConnection' || to === 'cancelled';
  }
  if (from === 'waitingForConnection') {
    return to === 'queued' || to === 'transferring' || to === 'cancelled' || to === 'needsAuthentication';
  }
  if (from === 'queued') {
    return to === 'inspecting' || to === 'waitingForConnection' || to === 'cancelled' ||
      to === 'needsAuthorization' || to === 'needsAuthentication' || to === 'completed';
  }
  if (from === 'inspecting') {
    return to === 'awaitingConflictDecision' || to === 'transferring' ||
      to === 'waitingForConnection' || to === 'needsAuthorization' ||
      to === 'needsAuthentication' || to === 'failed' || to === 'cancelled';
  }
  if (from === 'awaitingConflictDecision') {
    return to === 'queued' || to === 'transferring' || to === 'cancelled' ||
      to === 'failed' || to === 'needsAuthorization' || to === 'needsAuthentication';
  }
  return to === 'paused' || to === 'waitingForConnection' || to === 'verifying' ||
    to === 'failed' || to === 'cancelled';
}

/** Map a user/lifecycle command to one explicit durable stage transition. */
export function sshSftpTaskCommandTarget(stage: SshSftpTaskStage,
  command: SshSftpTaskCommand): SshSftpTaskStage | null {
  if (command.kind === 'complete') {
    return stage === 'queued' ? 'completed' : null;
  }
  if (command.kind === 'cancel') {
    return stage === 'completed' || stage === 'cancelled' ? null : 'cancelled';
  }
  if (command.kind === 'pause') {
    return stage === 'transferring' ? 'paused' : null;
  }
  if (command.kind === 'resume') {
    return stage === 'paused' || stage === 'waitingForConnection' ? 'queued' : null;
  }
  if (command.kind === 'retry') {
    return stage === 'failed' || stage === 'cancelled' || stage === 'paused' ||
      stage === 'waitingForConnection' || stage === 'needsAuthorization' ||
      stage === 'needsAuthentication' || stage === 'awaitingConflictDecision' ? 'queued' : null;
  }
  if (command.kind === 'authorize') {
    return stage === 'needsAuthorization' ? 'queued' : null;
  }
  if (command.kind === 'authenticate') {
    return stage === 'needsAuthentication' ? 'queued' : null;
  }
  if (command.kind === 'detach') {
    return stage === 'queued' || stage === 'inspecting' || stage === 'transferring' ||
      stage === 'verifying' || stage === 'committing' || stage === 'paused' ||
      stage === 'awaitingConflictDecision' ? 'waitingForConnection' : null;
  }
  return null;
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

/**
 * A durable update is ordered by the task sequence first and wall-clock time
 * second. Equal timestamps are intentionally not allowed to replace a record:
 * a late callback must not win merely because it arrived last.
 */
export function isNewerSshSftpTaskUpdate(current: SshSftpTaskRecord,
  next: SshSftpTaskRecord): boolean {
  if (next.sequence !== current.sequence) { return next.sequence > current.sequence; }
  return next.updatedAt > current.updatedAt;
}

/** Progress may pause, but a durable checkpoint must never move backwards. */
export function isMonotonicSshSftpTaskProgress(current: SshSftpTaskRecord,
  next: SshSftpTaskRecord): boolean {
  if (current.verifiedOffset >= 0 && next.verifiedOffset >= 0 &&
    next.verifiedOffset < current.verifiedOffset) {
    return false;
  }
  if (next.totalBytes >= 0 && next.verifiedOffset > next.totalBytes) { return false; }
  return true;
}

/** Replace by id, keep newest sequence first, and cap durable growth. */
export function upsertSshSftpTask(records: SshSftpTaskRecord[],
  next: SshSftpTaskRecord): SshSftpTaskRecord[] {
  const result: SshSftpTaskRecord[] = [];
  let replaced: boolean = false;
  for (let index = 0; index < records.length; index++) {
    const current: SshSftpTaskRecord = records[index];
    if (current.taskId !== next.taskId) {
      result.push(current);
      continue;
    }
    if (isNewerSshSftpTaskUpdate(current, next) &&
      isMonotonicSshSftpTaskProgress(current, next)) {
      result.push(next);
    } else {
      result.push(current);
    }
    replaced = true;
  }
  if (!replaced) { result.push(next); }
  result.sort((a: SshSftpTaskRecord, b: SshSftpTaskRecord): number => b.sequence - a.sequence);
  return result.slice(0, MAX_TASKS);
}

export function sshSftpTaskMaxCount(): number {
  return MAX_TASKS;
}
