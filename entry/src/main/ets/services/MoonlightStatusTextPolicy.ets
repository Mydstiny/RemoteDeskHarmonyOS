/**
 * Plain words for the status codes the Moonlight settings and data pages used to print as-is
 * (for example "本地设置状态：read_failed"). A code this table does not know keeps its name in
 * brackets, so a report still identifies it.
 */
export function moonlightStatusText(code: string): string {
  switch (code) {
    case 'account_changed':
    case 'stale_account':
    case 'stale_lease':
      return '账号已切换，请重新打开此页';
    case 'local_save_exception':
      return '本机保存出错，请重试';
    case 'readback_failed':
    case 'pending_local_verification':
      return '已写入本机，正在等待回读确认';
    case 'invalid_record':
    case 'corrupt':
    case 'invalid_data':
      return '本机记录格式异常';
    case 'invalid_settings':
    case 'settings_invalid':
      return '设置内容无效，请检查后重新保存';
    case 'not_ready':
      return '本机存储还没准备好，请稍后再试';
    case 'read_failed':
    case 'record_read_failed':
    case 'cache_read_failed':
      return '读取本机记录失败';
    case 'version_exhausted':
      return '本机记录版本异常，请重新保存';
    case 'too_new':
      return '记录来自更新版本的应用，请先升级';
    case 'invalid_request':
      return '请求无效，请重新打开此页';
    case 'not_found':
      return '没有找到对应的记录';
    case 'cloud_unavailable':
      return '云端暂时不可用，请稍后再试';
    case 'internal_failure':
      return '内部错误，请稍后再试';
    default:
      return '状态异常（' + code + '）';
  }
}
