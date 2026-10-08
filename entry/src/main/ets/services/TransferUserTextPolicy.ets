import { TransferStage } from './TransferSessionPolicy';

/**
 * 文件任务给用户看的说明：任务列表、实况窗只显示这里的白话，诊断码只进日志。
 * A code without its own sentence falls back to a sentence for the task's stage.
 */
export interface TransferTaskTextInput {
  stage: TransferStage;
  direction: 'upload' | 'download';
  evidence: string;
  diagnosticCode: string;
  /** Waiting for a free lane (another transfer of the same session is running). */
  queued: boolean;
}

const REASONS: Map<string, string> = new Map<string, string>();
function reason(code: string, text: string): void { REASONS.set(code, text); }
reason('transfer_space_limit', '本机存储空间不足，清理空间后重试');
reason('transfer_size_limit', '单个文件超过 2GB，暂不支持');
reason('transfer_batch_size_limit', '这一批文件合计超过 2GB，请分批传输');
reason('transfer_source_changed', '传输期间源文件被修改，请重新选择后重试');
reason('transfer_batch_unavailable', '上一批文件仍在准备，请稍后重试');
reason('task_admission_rejected', '任务太多或任务记录不可用，请清除已完成的任务后重试');
reason('enqueue_failed', '同时进行的文件任务太多，请等前面的任务完成');
reason('lease_revoked', '连接已断开或重新建立，传输已停止');
reason('session_changed', '连接已断开或重新建立，传输已停止');
reason('lease_or_cancel_before_start', '开始前连接已变化或已取消');
reason('transfer_deadline', '长时间没有进展，已停止');
reason('cancelled_by_user', '已取消');
reason('cancelled_before_start', '已取消');
reason('cancel_drain_pending', '已请求停止，远端没有及时确认，请检查目标文件');
reason('interrupted', '应用退出时传输中断，请重新传输');
reason('interrupted_commit', '应用退出时正在保存，请检查目标文件');
reason('target_exists', '远端已有同名文件');
reason('transfer_target_exists', '目标位置已有同名文件');
reason('receive_rejected', '远端复制的文件已失效，请在远端重新复制后再试');
reason('receive_incomplete', '远端发送中断，请重试');
reason('receive_retired', '连接变化，接收已停止');
reason('download_rejected', '远端拒绝了这个文件，请检查权限后重试');
reason('download_incomplete', '远端发送中断，请重试');
reason('download_retired', '连接变化，接收已停止');
reason('staging_incomplete', '读取本机文件失败，请重新选择');
reason('directory_staging_incomplete', '读取本机文件夹失败，请重新选择');
reason('shared_file_changed', '共享文件夹里的文件仍在变化，请稍后再取');
reason('offer_ack_unconfirmed', '远端没有确认收到文件清单，请重试');
reason('clipboard_offer_unavailable', '远端剪贴板暂不可用，请重试');
reason('clipboard_not_ready', '剪贴板通道尚未就绪，请稍后重试');
reason('export_destination_cleared', '保存未完成，已删除写了一半的文件');
reason('export_destination_retained', '保存未完成，所选位置可能留下不完整的文件');
reason('export_not_committed', '保存未完成');
reason('transfer_export_target_unavailable', '无法写入所选位置，请换一个位置');
reason('manifest_write_failed', '本机记录写入失败，请检查存储空间');
reason('directory_target_unavailable', '目标文件夹不可用，请换一个文件夹');
reason('directory_path_invalid', '目标路径无效');
reason('directory_create_unconfirmed', '远端没有确认已创建文件夹');
reason('target_write_unconfirmed', '');

/** The sentence for a diagnostic code, or '' when it has none. */
export function transferFailureReason(code: string): string {
  return REASONS.get(code) ?? '';
}

export function transferTaskDescription(input: TransferTaskTextInput): string {
  const reason: string = transferFailureReason(input.diagnosticCode);
  const download: boolean = input.direction === 'download';
  switch (input.stage) {
    case 'completed':
      if (input.evidence === 'exported') { return '已保存到所选位置'; }
      if (input.evidence === 'contentVerified') { return download ? '已接收，内容已校验' : '已发送，远端内容已校验'; }
      if (input.evidence === 'metadataVerified') { return download ? '已接收' : '已发送，远端大小与时间已核对'; }
      return '已发送，远端尚未确认保存';
    case 'handedOff':
      return download ? '已交给本机剪贴板' : '已交给远端，可在远端粘贴或保存';
    case 'interrupted':
      return reason.length > 0 ? reason : '传输中断，请重新传输';
    case 'commitUnknown':
      return reason.length > 0 ? reason : '保存结果未知，请检查目标文件';
    case 'paused':
      return reason.length > 0 ? reason : '已停止，请重新选择文件后重试';
    case 'cancelled':
      return '已取消';
    case 'failed':
      return reason.length > 0 ? '未完成：' + reason : (download ? '接收未完成，请重试' : '发送未完成，请重试');
    case 'expired':
      return '任务已过期';
    case 'cancelling':
      return '正在停止';
    case 'verifying':
      return '正在校验';
    case 'committing':
      return '正在保存';
    case 'offered':
    case 'ready':
      return '已准备好，等待远端读取';
    case 'waitingRemote':
      return '等待远端确认';
    case 'waitingConnection':
      return '等待重新连接';
    default:
      if (input.queued) { return '排队中，等前面的传输完成'; }
      if (input.stage === 'preparing') { return '正在准备'; }
      return download ? '正在接收' : '正在发送';
  }
}

/** Whether the task list offers 取消: not before a result, and never while received data is being saved. */
export function transferTaskCancellable(stage: TransferStage): boolean {
  return ['preparing', 'ready', 'offered', 'transferring', 'senderCompleted', 'verifying', 'waitingRemote',
    'waitingConnection'].indexOf(stage) >= 0;
}
