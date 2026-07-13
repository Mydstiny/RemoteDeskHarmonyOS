import { TransferStage } from './TransferSessionPolicy';

/**
 * FileTransferProgressModel — RDP/RustDesk 文件传输进度模型
 */

export type TransferProtocol = 'ssh' | 'rdp' | 'rustdesk';

export type TransferState = TransferStage;

export interface FileTransferProgressSnapshot {
  taskId: string;
  protocol: TransferProtocol;
  fileName: string;
  transferred: number;
  total: number;
  progressValue: number;
  state: TransferState;
  statusText: string;
}

export function clampTransferProgress(transferred: number, total: number): number {
  if (total <= 0 || transferred <= 0) {
    return 0;
  }
  if (transferred >= total) {
    return 100;
  }
  const raw: number = Math.floor((transferred * 100) / total);
  return Math.max(0, Math.min(99, raw));
}

export function transferProtocolName(protocol: TransferProtocol): string {
  if (protocol === 'rdp') {
    return 'RDP';
  }
  if (protocol === 'ssh') {
    return 'SSH';
  }
  return 'RustDesk';
}

export function makeTransferTitle(protocol: TransferProtocol, state: TransferState): string {
  const name: string = transferProtocolName(protocol);
  if (state === 'completed') {
    return name + ' 文件传输完成';
  }
  if (state === 'failed') {
    return name + ' 文件传输失败';
  }
  if (state === 'cancelled') {
    return name + ' 文件传输已取消';
  }
  return name + ' 文件传输';
}

export function makeTransferStatusText(snapshot: FileTransferProgressSnapshot): string {
  if (snapshot.statusText.length > 0) {
    return snapshot.statusText;
  }
  const percent: string = snapshot.progressValue.toString() + '%';
  if (snapshot.state === 'preparing') {
    return '正在准备 ' + snapshot.fileName;
  }
  if (snapshot.state === 'waitingRemote') {
    return '正在等待远端确认 ' + snapshot.fileName;
  }
  if (snapshot.state === 'completed') {
    return '已完成 ' + snapshot.fileName;
  }
  if (snapshot.state === 'failed') {
    return '传输失败 ' + snapshot.fileName;
  }
  if (snapshot.state === 'cancelled') {
    return '已取消 ' + snapshot.fileName;
  }
  return '正在传输 ' + snapshot.fileName + ' ' + percent;
}

export function createTransferSnapshot(taskId: string, protocol: TransferProtocol, fileName: string,
  transferred: number, total: number, state: TransferState, statusText: string = ''): FileTransferProgressSnapshot {
  const progressValue: number = state === 'completed' ? 100 : clampTransferProgress(transferred, total);
  return {
    taskId,
    protocol,
    fileName,
    transferred,
    total,
    progressValue,
    state,
    statusText
  };
}
