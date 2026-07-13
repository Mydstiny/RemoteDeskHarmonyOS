export type TransferStage = 'preparing' | 'transferring' | 'waitingRemote' | 'completed' | 'failed' | 'cancelled';

export interface TransferSession {
  id: string;
  protocol: 'ssh' | 'rdp' | 'rustdesk';
  direction: 'upload' | 'download';
  fileName: string;
  totalBytes: number;
  transferredBytes: number;
  stage: TransferStage;
  canCancel: boolean;
  diagnosticCode: string;
}

export function canTransition(from: TransferStage, to: TransferStage): boolean {
  if (from === 'preparing') {
    return to === 'transferring' || to === 'failed' || to === 'cancelled';
  }
  if (from === 'transferring') {
    return to === 'waitingRemote' || to === 'completed' || to === 'failed' || to === 'cancelled';
  }
  if (from === 'waitingRemote') {
    return to === 'completed' || to === 'failed' || to === 'cancelled';
  }
  return false;
}

export function isRemoteCompletionConfirmed(stage: TransferStage): boolean {
  return stage === 'completed';
}

export function cancelTransfer(session: TransferSession): TransferSession {
  if (!session.canCancel || !canTransition(session.stage, 'cancelled')) {
    return session;
  }
  return {
    id: session.id, protocol: session.protocol, direction: session.direction, fileName: session.fileName,
    totalBytes: session.totalBytes, transferredBytes: session.transferredBytes, stage: 'cancelled',
    canCancel: false,
    diagnosticCode: 'cancelled-by-user'
  };
}

/** 可取消传输需要为操作按钮保留额外垂直空间，避免在进度容器中被裁剪。 */
export function transferProgressPanelHeight(session: TransferSession | null): number {
  if (session !== null && session.canCancel && session.stage === 'transferring') {
    return 116;
  }
  return 70;
}

export function shouldShowTransferCancelAction(session: TransferSession | null): boolean {
  return session !== null && session.canCancel && session.stage === 'transferring';
}

/**
 * The SFTP write bridge reports the number of bytes durably accepted by the
 * native layer.  A retry may only seek the local source to that offset.
 */
export function uploadResumeOffset(remoteConfirmedBytes: number, sourceBytes: number): number {
  if (remoteConfirmedBytes < 0 || sourceBytes <= 0 || remoteConfirmedBytes > sourceBytes) {
    return -1;
  }
  return remoteConfirmedBytes;
}

/**
 * Advances the retry offset only by bytes that the native SFTP write reports
 * as accepted. Invalid or failed writes leave the prior confirmed offset intact.
 */
export function recordConfirmedUploadWrite(confirmedBytes: number, nativeWriteBytes: number,
  requestedBytes: number): number {
  if (confirmedBytes < 0 || requestedBytes <= 0 || nativeWriteBytes <= 0 ||
    nativeWriteBytes > requestedBytes) {
    return confirmedBytes;
  }
  return confirmedBytes + nativeWriteBytes;
}

/**
 * Downloads have no native persistent-confirmation query.  The local file
 * length is therefore the only safe resume point and is written at explicitly.
 */
export function downloadResumeOffset(_recordedBytes: number, localBytes: number, totalBytes: number): number {
  if (localBytes < 0 || totalBytes <= 0 || localBytes > totalBytes) {
    return -1;
  }
  return localBytes;
}
