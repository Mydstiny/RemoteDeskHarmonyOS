import { TransferStage } from './TransferSessionPolicy';
import { TransferProtocol } from './FileTransferProgressModel';

export type ManagedTransferEvidence = 'none' | 'offered' | 'senderCompleted' |
  'metadataVerified' | 'contentVerified' | 'exported';
/**
 * handedOff: the content was handed to the remote (RDP/RustDesk clipboard offer) and nothing more can be observed.
 * interrupted: the app stopped while the task ran; nothing will resume it.
 */
export type ManagedTransferResultStage = 'completed' | 'failed' | 'cancelled' | 'paused' | 'commitUnknown' |
  'handedOff' | 'interrupted';
export interface ManagedTransferOutcome {
  stage: ManagedTransferResultStage;
  evidence: ManagedTransferEvidence;
  diagnosticCode?: string;
}
export interface ManagedTransferProgress {
  stage?: TransferStage;
  readBytes?: number;
  sentBytes?: number;
  writtenBytes?: number;
  verifiedBytes?: number;
  totalBytes?: number;
}
/** Persisted projection: never add URI grants, source paths, payloads or credentials. */
export class ManagedTransferRecord {
  schemaVersion: number = 2;
  taskId: string = '';
  attemptId: number = 1;
  batchId: string = '';
  sourceKind: string = '';
  leaseId: string = '';
  accountScopeId: string = '';
  hostId: string = '';
  protocol: TransferProtocol = 'rdp';
  direction: 'upload' | 'download' = 'upload';
  fileName: string = '';
  totalBytes: number = 0;
  readBytes: number = 0;
  sentBytes: number = 0;
  writtenBytes: number = 0;
  verifiedBytes: number = 0;
  stage: TransferStage = 'preparing';
  evidence: ManagedTransferEvidence = 'none';
  commitStarted: boolean = false;
  diagnosticCode: string = '';
  createdAt: number = 0;
  updatedAt: number = 0;
}
export function managedTransferTerminal(stage: TransferStage): boolean {
  return stage === 'completed' || stage === 'failed' || stage === 'cancelled' || stage === 'expired' ||
    stage === 'handedOff' || stage === 'interrupted';
}
/** No runner moves the record again: a terminal stage, or a paused/unknown result its runner settled. */
export function managedTransferSettled(stage: TransferStage): boolean {
  return managedTransferTerminal(stage) || stage === 'paused' || stage === 'commitUnknown';
}
export function managedTransferInteger(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0;
}
export function managedTransferIdentifier(value: string): boolean {
  return typeof value === 'string' && value.length > 0 && value.length <= 256 &&
    /^[A-Za-z0-9_.:@-]+$/.test(value);
}
/**
 * A host id as the host list keeps it. Ids of hosts synced from RustDesk Pro are URL-encoded ('rdpro_…%3A…'), so this
 * only refuses what cannot be an id: empty, overlong, or control characters.
 */
export function managedTransferHostId(value: string): boolean {
  return typeof value === 'string' && value.length > 0 && value.length <= 1024 && !/[\x00-\x1f\x7f]/.test(value);
}
export function managedTransferCode(value: string | undefined): string {
  return value !== undefined && /^[a-z0-9_-]{1,80}$/.test(value) ? value : '';
}
export function managedTransferEvidenceValid(value: ManagedTransferEvidence): boolean {
  return value === 'none' || value === 'offered' || value === 'senderCompleted' ||
    value === 'metadataVerified' || value === 'contentVerified' || value === 'exported';
}
export function managedTransferStageValid(value: TransferStage): boolean {
  return ['preparing', 'ready', 'offered', 'transferring', 'senderCompleted', 'verifying',
    'committing', 'waitingConnection', 'waitingRemote', 'paused', 'cancelling', 'commitUnknown',
    'completed', 'failed', 'cancelled', 'expired', 'handedOff', 'interrupted'].indexOf(value) >= 0;
}
export function copyManagedTransferRecord(record: ManagedTransferRecord): ManagedTransferRecord {
  const result: ManagedTransferRecord = new ManagedTransferRecord();
  result.taskId = record.taskId; result.attemptId = record.attemptId; result.batchId = record.batchId;
  result.sourceKind = record.sourceKind; result.leaseId = record.leaseId;
  result.accountScopeId = record.accountScopeId; result.hostId = record.hostId;
  result.protocol = record.protocol; result.direction = record.direction; result.fileName = record.fileName;
  result.totalBytes = record.totalBytes; result.readBytes = record.readBytes; result.sentBytes = record.sentBytes;
  result.writtenBytes = record.writtenBytes; result.verifiedBytes = record.verifiedBytes;
  result.stage = record.stage; result.evidence = record.evidence; result.commitStarted = record.commitStarted; result.diagnosticCode = record.diagnosticCode;
  result.createdAt = record.createdAt; result.updatedAt = record.updatedAt;
  return result;
}
export function normalizeManagedTransferRecord(value: ManagedTransferRecord,
  accountScopeId: string): ManagedTransferRecord | null {
  if (value === null || typeof value !== 'object' || (value.schemaVersion !== 1 && value.schemaVersion !== 2) ||
    value.accountScopeId !== accountScopeId || !managedTransferIdentifier(value.taskId) ||
    !managedTransferHostId(value.hostId) || !managedTransferInteger(value.attemptId) || value.attemptId < 1 ||
    typeof value.sourceKind !== 'string' || (value.sourceKind.length > 0 && !managedTransferIdentifier(value.sourceKind)) ||
    typeof value.leaseId !== 'string' || (value.leaseId.length > 0 && !managedTransferIdentifier(value.leaseId)) ||
    typeof value.batchId !== 'string' || (value.batchId.length > 0 && !managedTransferIdentifier(value.batchId)) ||
    (value.protocol !== 'rdp' && value.protocol !== 'rustdesk' && value.protocol !== 'ssh') ||
    (value.direction !== 'upload' && value.direction !== 'download') ||
    typeof value.fileName !== 'string' || value.fileName.length > 255 || /[\\/\x00-\x1f]/.test(value.fileName) ||
    typeof value.commitStarted !== 'boolean' || !managedTransferStageValid(value.stage) || !managedTransferEvidenceValid(value.evidence) ||
    !managedTransferInteger(value.totalBytes) || !managedTransferInteger(value.readBytes) ||
    !managedTransferInteger(value.sentBytes) || !managedTransferInteger(value.writtenBytes) ||
    !managedTransferInteger(value.verifiedBytes) || !managedTransferInteger(value.createdAt) ||
    !managedTransferInteger(value.updatedAt)) { return null; }
  const result: ManagedTransferRecord = copyManagedTransferRecord(value);
  result.diagnosticCode = managedTransferCode(value.diagnosticCode);
  return result;
}
/**
 * A record found when the app starts belongs to no runner. An offer the remote received stays handed off; a task that
 * began saving is unknown; anything else was interrupted. Every result is settled, so old records can be evicted.
 */
export function recoverManagedTransferRecord(value: ManagedTransferRecord): ManagedTransferRecord {
  const result: ManagedTransferRecord = copyManagedTransferRecord(value);
  if (managedTransferTerminal(result.stage)) { return result; }
  if (result.stage === 'paused' && result.evidence === 'offered') {
    result.stage = 'handedOff';
  } else if (result.stage === 'commitUnknown') {
    result.diagnosticCode = result.diagnosticCode.length > 0 ? result.diagnosticCode : 'interrupted_commit';
  } else if (result.commitStarted || result.stage === 'committing') {
    result.stage = 'commitUnknown'; result.diagnosticCode = 'interrupted_commit';
  } else {
    // A paused result keeps the reason its runner gave; a task that was still running gets 'interrupted'.
    result.diagnosticCode = result.stage === 'paused' && result.diagnosticCode.length > 0 ?
      result.diagnosticCode : 'interrupted';
    result.stage = 'interrupted';
  }
  return result;
}
/** Progress is monotonic per attempt; read/sent/written/verified stay independent. */
export function canTransitionManagedTransfer(from: TransferStage, to: TransferStage): boolean {
  if (from === to) { return true; }
  if (managedTransferTerminal(from) || from === 'commitUnknown' || from === 'cancelling') { return false; }
  if (to === 'paused' || to === 'waitingConnection') { return from !== 'committing'; }
  if (from === 'preparing') { return to === 'ready' || to === 'offered' || to === 'transferring'; }
  if (from === 'ready' || from === 'offered') { return to === 'transferring' || to === 'senderCompleted'; }
  if (from === 'transferring') { return to === 'senderCompleted' || to === 'verifying' || to === 'waitingRemote'; }
  if (from === 'senderCompleted') { return to === 'verifying' || to === 'waitingRemote'; }
  if (from === 'waitingRemote') { return to === 'verifying' || to === 'transferring' || to === 'senderCompleted'; }
  if (from === 'paused' || from === 'waitingConnection') { return to === 'preparing' || to === 'transferring'; }
  // A task of several files commits each file and then moves on to the next one.
  if (from === 'committing') { return to === 'transferring' || to === 'verifying'; }
  return false;
}
export function applyManagedTransferProgress(record: ManagedTransferRecord,
  progress: ManagedTransferProgress): ManagedTransferRecord | null {
  if (managedTransferTerminal(record.stage) || record.stage === 'cancelling' || record.stage === 'commitUnknown') { return null; }
  const next: ManagedTransferRecord = copyManagedTransferRecord(record);
  if (progress.stage !== undefined) {
    if (!managedTransferStageValid(progress.stage) || managedTransferTerminal(progress.stage) ||
      progress.stage === 'committing' || progress.stage === 'commitUnknown' || progress.stage === 'cancelling' ||
      !canTransitionManagedTransfer(record.stage, progress.stage)) { return null; }
    next.stage = progress.stage;
  }
  if (progress.totalBytes !== undefined) { next.totalBytes = progress.totalBytes; }
  if (progress.readBytes !== undefined) { next.readBytes = progress.readBytes; }
  if (progress.sentBytes !== undefined) { next.sentBytes = progress.sentBytes; }
  if (progress.writtenBytes !== undefined) { next.writtenBytes = progress.writtenBytes; }
  if (progress.verifiedBytes !== undefined) { next.verifiedBytes = progress.verifiedBytes; }
  if (!managedTransferInteger(next.totalBytes) || !managedTransferInteger(next.readBytes) ||
    !managedTransferInteger(next.sentBytes) || !managedTransferInteger(next.writtenBytes) ||
    !managedTransferInteger(next.verifiedBytes) || next.readBytes < record.readBytes ||
    next.sentBytes < record.sentBytes || next.writtenBytes < record.writtenBytes ||
    next.verifiedBytes < record.verifiedBytes || (next.totalBytes > 0 &&
    Math.max(next.readBytes, next.sentBytes, next.writtenBytes, next.verifiedBytes) > next.totalBytes)) { return null; }
  next.updatedAt = Date.now();
  return next;
}
