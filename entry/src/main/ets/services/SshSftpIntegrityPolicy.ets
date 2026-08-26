/**
 * SSH-only SFTP integrity rules shared by the page transfer coordinator.
 *
 * This is deliberately a small, pure policy layer. It does not retain
 * credentials, picker grants, or file contents; those stay in the page/native
 * operation that owns the current transfer.
 */
export type SshSftpTransferDirection = 'upload' | 'download';

export interface SshSftpFileIdentity {
  size: number;
  mtime: number;
}

export interface SshSftpCheckpoint {
  direction: SshSftpTransferDirection;
  sourceRef: string;
  targetRef: string;
  sourceSize: number;
  sourceMtime: number;
  confirmedOffset: number;
  partialRef: string;
  partialSize: number;
  partialMtime: number;
  generation: number;
}

export interface SshSftpSkipRemovalDecision {
  committedSkip: boolean;
  clearCheckpoint: boolean;
  publishError: boolean;
}

export type SshSftpPayloadWriter = (payload: ArrayBuffer) => Promise<number>;

export type SshSftpCommittedDisposition =
  'normal' | 'cancelled-after-commit' | 'paused-after-commit' | 'request-stale';

/** Resume is fail-closed when either the source or the partial identity changed. */
export function sshSftpIdentityMatches(expected: SshSftpFileIdentity,
  observed: SshSftpFileIdentity): boolean {
  return Number.isFinite(expected.size) && Number.isFinite(observed.size) &&
    expected.size >= 0 && observed.size >= 0 && observed.size === expected.size &&
    Number.isFinite(expected.mtime) && Number.isFinite(observed.mtime) &&
    expected.mtime >= 0 && observed.mtime >= 0 && observed.mtime === expected.mtime;
}

/** A 0-byte file is a valid transfer; only negative or oversized values fail. */
export function sshSftpOffsetIsValid(offset: number, totalSize: number): boolean {
  return Number.isFinite(offset) && Number.isFinite(totalSize) &&
    offset >= 0 && totalSize >= 0 && offset <= totalSize;
}

export function sshSftpCommitSizeMatches(actualSize: number, expectedSize: number): boolean {
  return Number.isFinite(actualSize) && Number.isFinite(expectedSize) &&
    actualSize >= 0 && expectedSize >= 0 && actualSize === expectedSize;
}

/**
 * Removing the partial is the commit point for a conflict skip. Once it has
 * succeeded, a later pause/cancel must not retain a checkpoint for the file
 * that no longer exists. A replacement attempt never inherits that result.
 */
export function sshSftpSkipRemovalDecision(errorCode: number, attemptCurrent: boolean,
  requestStopped: boolean): SshSftpSkipRemovalDecision {
  if (errorCode < 0) {
    return {
      committedSkip: false,
      clearCheckpoint: false,
      publishError: attemptCurrent && !requestStopped
    };
  }
  if (!attemptCurrent) {
    return { committedSkip: false, clearCheckpoint: false, publishError: false };
  }
  return { committedSkip: true, clearCheckpoint: true, publishError: false };
}

/** A successful remote rename is authoritative even when a stop arrives immediately after it. */
export function sshSftpCommittedDisposition(commitReceiptStale: boolean,
  userCancellationRequested: boolean, userPauseRequested: boolean): SshSftpCommittedDisposition {
  if (userCancellationRequested) { return 'cancelled-after-commit'; }
  if (userPauseRequested) { return 'paused-after-commit'; }
  return commitReceiptStale ? 'request-stale' : 'normal';
}

/**
 * Opening a local export target with TRUNC crosses its irreversible boundary.
 * A stop before that open is honored; afterwards the current attempt must
 * finish the verified local copy instead of deliberately leaving a truncated
 * overwrite target. A replacement attempt always fences the old writer.
 */
export function sshSftpLocalExportShouldContinue(destinationOpened: boolean,
  attemptCurrent: boolean, stopRequested: boolean): boolean {
  if (!attemptCurrent) { return false; }
  return destinationOpened || !stopRequested;
}

/** Complete one bounded local-export payload across legal short writes. */
export async function writeSshSftpPayloadFully(payload: ArrayBuffer,
  writer: SshSftpPayloadWriter): Promise<boolean> {
  let offset: number = 0;
  while (offset < payload.byteLength) {
    const remaining: ArrayBuffer = offset === 0 ? payload : payload.slice(offset);
    let written: number = -1;
    try {
      written = await writer(remaining);
    } catch (_err) {
      return false;
    }
    if (!Number.isFinite(written) || !Number.isInteger(written) ||
      written <= 0 || written > remaining.byteLength) {
      return false;
    }
    offset += written;
  }
  return offset === payload.byteLength;
}

export function sshSftpPartialSuffix(taskId: string): string {
  let safe: string = '';
  for (let index = 0; index < taskId.length; index++) {
    const code: number = taskId.charCodeAt(index);
    const asciiLetter: boolean = (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
    const digit: boolean = code >= 48 && code <= 57;
    if (asciiLetter || digit || taskId.charAt(index) === '-' || taskId.charAt(index) === '_') {
      safe += taskId.charAt(index);
    }
  }
  return '.partial.' + (safe.length > 0 ? safe : 'task');
}

/** Remove only the generated suffix; an unknown URI is never treated as final. */
export function sshSftpFinalUriFromPartial(partialUri: string, suffix: string): string {
  if (partialUri.length <= suffix.length || !partialUri.endsWith(suffix)) { return ''; }
  return partialUri.substring(0, partialUri.length - suffix.length);
}
