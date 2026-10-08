import { TransferStage } from './TransferSessionPolicy';

/**
 * FileTransferProgressModel — RDP/RustDesk 文件传输进度模型
 */

export type TransferProtocol = 'ssh' | 'rdp' | 'rustdesk';

export type TransferState = TransferStage;

export interface FileTransferProgressSnapshot {
  taskId: string;
  attemptId?: number;
  accountScopeId?: string;
  protocol: TransferProtocol;
  fileName: string;
  transferred: number;
  total: number;
  progressValue: number;
  state: TransferState;
  statusText: string;
}

export function clampTransferProgress(transferred: number, total: number): number {
  if (!Number.isFinite(total) || !Number.isFinite(transferred) || total <= 0 || transferred <= 0) {
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
  if (state === 'handedOff') {
    return name + ' 文件已交给远端';
  }
  if (state === 'interrupted') {
    return name + ' 文件传输中断';
  }
  return name + ' 文件传输';
}

export function makeTransferStatusText(snapshot: FileTransferProgressSnapshot): string {
  if (snapshot.statusText.length > 0) {
    return snapshot.statusText;
  }
  const percent: string = snapshot.progressValue.toString() + '%';
  if (snapshot.state === 'offered' || snapshot.state === 'ready') { return '文件已准备好，等待远端读取 ' + snapshot.fileName; }
  if (snapshot.state === 'senderCompleted') { return '发送结束，尚未验证目标 ' + snapshot.fileName; }
  if (snapshot.state === 'verifying') { return '正在校验 ' + snapshot.fileName; }
  if (snapshot.state === 'committing') { return '正在保存 ' + snapshot.fileName; }
  if (snapshot.state === 'commitUnknown') { return '目标保存结果待确认 ' + snapshot.fileName; }
  if (snapshot.state === 'waitingConnection') { return '等待重新连接 ' + snapshot.fileName; }
  if (snapshot.state === 'cancelling') { return '正在取消 ' + snapshot.fileName; }
  if (snapshot.state === 'expired') { return '文件任务已过期 ' + snapshot.fileName; }
  if (snapshot.state === 'paused') { return '已停止 ' + snapshot.fileName; }
  if (snapshot.state === 'handedOff') { return '已交给远端，可在远端粘贴或保存 ' + snapshot.fileName; }
  if (snapshot.state === 'interrupted') { return '传输中断 ' + snapshot.fileName; }
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
