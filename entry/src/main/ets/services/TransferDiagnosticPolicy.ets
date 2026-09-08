import { ManagedTransferRecord } from './ManagedTransferTaskPolicy';

export interface TransferDiagnosticSnapshot {
  task: string;
  attempt: number;
  hostScope: string;
  protocol: string;
  direction: string;
  sourceKind: string;
  leaseGeneration: string;
  stage: string;
  readBytes: number;
  sentBytes: number;
  writtenBytes: number;
  verifiedBytes: number;
  totalBytes: number;
  code: string;
  evidence: string;
}

const PROTOCOLS: string[] = ['rdp', 'rustdesk', 'ssh'];
const DIRECTIONS: string[] = ['upload', 'download'];
const SOURCES: string[] = ['picker', 'file-picker', 'drop', 'deferred-drop', 'system-clipboard', 'authorized-file', 'authorized-directory-tree',
  'remote-clipboard', 'shared-drive', 'remote-directory', 'remote-directory-tree', 'local-export',
  'local-directory-export', 'explicit-legacy-recovery'];
const STAGES: string[] = ['preparing', 'ready', 'offered', 'transferring', 'senderCompleted', 'verifying',
  'committing', 'waitingConnection', 'waitingRemote', 'paused', 'cancelling', 'commitUnknown',
  'completed', 'failed', 'cancelled', 'expired'];
const EVIDENCE: string[] = ['none', 'offered', 'senderCompleted', 'metadataVerified', 'contentVerified', 'exported'];
// Unknown codes are not echoed: even a syntactically safe string can contain a secret.
const CODES: string[] = ['task_admission_rejected', 'runner_failed', 'cancelled_by_user', 'cancelled_before_start',
  'manifest_write_failed', 'lease_or_cancel_before_start', 'lease_revoked', 'transfer_deadline',
  'cancel_drain_pending', 'invalid_completion_evidence', 'finalize_cleanup_failed', 'interrupted_commit',
  'interrupted_requires_authorization', 'offer_ack_unconfirmed', 'target_write_unconfirmed', 'staging_incomplete',
  'source_changed', 'enqueue_failed', 'transfer_owner_unavailable', 'session_changed', 'file_transfer_failed',
  'directory_staging_incomplete', 'directory_target_unavailable', 'target_exists', 'directory_create_unconfirmed',
  'directory_path_invalid', 'receive_rejected', 'receive_incomplete', 'receive_retired', 'receive_failed',
  'shared_file_changed', 'download_rejected', 'download_incomplete', 'download_retired', 'download_failed',
  'directory_tree_incomplete', 'legacy_import_incomplete', 'clipboard_offer_unavailable', 'clipboard_staging_failed',
  'clipboard_receive_rejected', 'clipboard_receive_incomplete', 'clipboard_receive_retired', 'clipboard_receive_failed',
  'export_destination_retained', 'export_not_committed', 'transfer_directory_close_unknown',
  'transfer_directory_export_failed', 'transfer_directory_not_attempted'];

function allowed(value: string, values: string[], fallback: string): string {
  return typeof value === 'string' && values.indexOf(value) >= 0 ? value : fallback;
}

function safeInteger(value: number): number {
  return Number.isSafeInteger(value) && value >= 0 ? value : 0;
}

function identifier(value: string): boolean {
  return typeof value === 'string' && value.length > 0 && value.length <= 256;
}

/** FNV-1a over UTF-16 code units, for bounded diagnostic correlation only.
 * This is not a cryptographic hash, authorization identity or credential.
 * Length framing keeps different account/host splits distinct before hashing.
 */
function diagnosticHash(domain: string, first: string, second: string): string {
  const framed: string = domain + ':' + first.length.toString() + ':' + first + ':' +
    second.length.toString() + ':' + second;
  let value: number = 2166136261;
  for (let i: number = 0; i < framed.length; i++) {
    value = Math.imul(value ^ framed.charCodeAt(i), 16777619) >>> 0;
  }
  return value.toString(16).padStart(8, '0');
}

function numericLease(value: string): string {
  if (typeof value !== 'string' || value.length > 67 || !/^\d{1,16}([.:_-]\d{1,16}){0,3}$/.test(value)) {
    return 'unknown';
  }
  const parts: string[] = value.split(/[.:_-]/);
  const accepted: string[] = [];
  for (const part of parts) {
    const number: number = Number(part);
    if (!Number.isSafeInteger(number) || number < 0) { return 'unknown'; }
    accepted.push(number.toString());
  }
  return accepted.join(':');
}

/** Only these scalar fields may leave the task record for logging. */
export function projectTransferDiagnostic(record: ManagedTransferRecord): TransferDiagnosticSnapshot {
  return {
    task: identifier(record.taskId) ? 'task-' + diagnosticHash('task', record.taskId, '') : 'unknown',
    attempt: safeInteger(record.attemptId),
    hostScope: identifier(record.accountScopeId) && identifier(record.hostId) ?
      'host-' + diagnosticHash('host', record.accountScopeId, record.hostId) : 'unknown',
    protocol: allowed(record.protocol, PROTOCOLS, 'unknown'),
    direction: allowed(record.direction, DIRECTIONS, 'unknown'),
    sourceKind: allowed(record.sourceKind, SOURCES, 'other'),
    leaseGeneration: numericLease(record.leaseId),
    stage: allowed(record.stage, STAGES, 'unknown'),
    readBytes: safeInteger(record.readBytes),
    sentBytes: safeInteger(record.sentBytes),
    writtenBytes: safeInteger(record.writtenBytes),
    verifiedBytes: safeInteger(record.verifiedBytes),
    totalBytes: safeInteger(record.totalBytes),
    code: record.diagnosticCode === '' ? 'none' : allowed(record.diagnosticCode, CODES, 'other'),
    evidence: allowed(record.evidence, EVIDENCE, 'unknown')
  };
}

export function transferDiagnosticLine(record: ManagedTransferRecord): string {
  // Never stringify the original record, spread it, or invoke its toJSON hook.
  return JSON.stringify(projectTransferDiagnostic(record));
}
