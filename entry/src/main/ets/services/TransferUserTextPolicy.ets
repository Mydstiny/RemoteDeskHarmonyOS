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
reason('export_destination_emptied', '保存未完成，所选位置留下了一个空文件，可以删除');
reason('export_not_committed', '保存未完成');
reason('transfer_export_target_unavailable', '无法写入所选位置，请换一个位置');
reason('manifest_write_failed', '本机记录写入失败，请检查存储空间');
reason('directory_target_unavailable', '目标文件夹不可用，请换一个文件夹');
reason('directory_path_invalid', '目标路径无效');
reason('directory_create_unconfirmed', '远端没有确认已创建文件夹');
reason('target_write_unconfirmed', '');
reason('remote_read_partial', '远端只读取了一部分，可能取消了粘贴');
reason('peer_prelogin', '被控端 RustDesk 认为当前没有用户登录桌面，文件服务没有启动');
reason('peer_file_service_unavailable', '被控端 RustDesk 的文件服务没有响应，可能没有运行');
reason('remote_file_transfer_disabled', '被控端关闭了文件传输');
reason('remote_one_way_transfer', '被控端设置为单向文件传输');
reason('remote_path_not_found', '远端没有这个文件或文件夹');
reason('remote_permission_denied', '被控端没有权限访问这个位置');
reason('remote_disk_full', '被控端磁盘空间不足');

/** Reasons the RustDesk native layer reports as "file_transfer:<code>" (see file_transfer::REPORTED_FILE_ERRORS). */
const RUSTDESK_REPORTED_CODES: string[] = ['peer_prelogin', 'peer_file_service_unavailable',
  'remote_file_transfer_disabled', 'remote_one_way_transfer', 'remote_path_not_found', 'remote_permission_denied',
  'remote_disk_full'];

/** A RustDesk job's diagnostic as the task's code: a reason the user can act on, or `fallback`. */
export function rustDeskTransferFailureCode(diagnostic: string, fallback: string): string {
  if (diagnostic === 'file_transfer:AlreadyExists') { return 'target_exists'; }
  const code: string = diagnostic.startsWith('file_transfer:') ? diagnostic.substring('file_transfer:'.length) : '';
  return RUSTDESK_REPORTED_CODES.indexOf(code) >= 0 ? code : fallback;
}

/** The sentence for a diagnostic code, or '' when it has none. */
export function transferFailureReason(code: string): string {
  return REASONS.get(code) ?? '';
}

export function transferTaskDescription(input: TransferTaskTextInput): string {
  const reason: string = transferFailureReason(input.diagnosticCode);
  const download: boolean = input.direction === 'download';
  switch (input.stage) {
    case 'completed':
      if (input.diagnosticCode === 'remote_read_all') { return '远端已取走全部内容'; }
      if (input.evidence === 'exported') { return '已保存到所选位置'; }
      if (input.evidence === 'contentVerified') { return download ? '已接收，内容已校验' : '已发送，远端内容已校验'; }
      if (input.evidence === 'metadataVerified') { return download ? '已接收' : '已发送，远端大小与时间已核对'; }
      return '已发送，远端尚未确认保存';
    case 'handedOff':
      if (input.diagnosticCode === 'remote_read_partial') { return reason; }
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

/** What to do on the controlled computer when its RustDesk file service is not running. */
function rustDeskFileServiceAdvice(platformCategory: string): string {
  if (platformCategory === 'macos') {
    return '请确认被控 Mac 已登录桌面；若仍不行，在被控 Mac 上注销后重新登录，或重启电脑。';
  }
  if (platformCategory === 'windows') {
    return '请确认被控电脑已登录 Windows 桌面、RustDesk 托盘程序在运行；必要时重启被控端的 RustDesk。';
  }
  if (platformCategory === 'linux') {
    return '请确认被控电脑已登录图形桌面，并且当前用户的 RustDesk 在运行。';
  }
  return '请确认被控端已登录桌面，并重启被控端的 RustDesk 后再试。';
}

/**
 * A RustDesk file job's diagnostic ("file_transfer:<code>" from the native layer, or a client-side code) as a sentence
 * for the file panel, with advice for the controlled computer's platform where the cause is on that side.
 */
export function rustDeskFileFailureText(diagnostic: string, platformCategory: string): string {
  const code: string = diagnostic.startsWith('file_transfer:') ? diagnostic.substring('file_transfer:'.length) : diagnostic;
  switch (code) {
    case 'peer_prelogin':
      return '被控端 RustDesk 认为当前没有用户登录桌面，文件服务没有启动。' + rustDeskFileServiceAdvice(platformCategory);
    case 'peer_file_service_unavailable':
      return '被控端 RustDesk 没有响应文件请求，它的文件服务可能没有运行。请稍后点「刷新」重试；若一直如此，' +
        rustDeskFileServiceAdvice(platformCategory);
    case 'remote_file_transfer_disabled':
      return '被控端关闭了文件传输，请在被控端 RustDesk 的设置里允许文件传输。';
    case 'remote_one_way_transfer':
      return '被控端设置为单向文件传输，不能向它发送或在它上面修改文件。';
    case 'remote_path_not_found':
      return '远端没有这个文件夹，请检查路径。';
    case 'remote_permission_denied':
      return platformCategory === 'macos' ?
        '被控 Mac 不允许 RustDesk 读写这个位置。可在被控 Mac 的“系统设置 → 隐私与安全性 → 完全磁盘访问权限”中允许 RustDesk。' :
        '被控端没有权限访问这个位置。';
    case 'remote_disk_full':
      return '被控端磁盘空间不足。';
    case 'TimedOut':
      return '远端长时间没有回应，请稍后重试。';
    case 'PermissionDenied':
      return '文件会话没有获得授权，或被被控端拒绝。';
    case 'AlreadyExists':
      return '远端已有同名文件。';
    case 'enqueue_failed':
      return '同时进行的文件任务太多，请等前面的任务完成。';
    default:
      return '读取远端目录失败，请稍后重试。';
  }
}
