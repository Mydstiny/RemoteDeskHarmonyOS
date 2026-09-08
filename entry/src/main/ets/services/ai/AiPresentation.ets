import { aiArray, aiRecord, aiString } from './AiWirePolicy';
import { aiContentText } from './AiTranscript';

export function aiStatusLabel(status: string): string {
  switch (status) {
    case 'idle': return '空闲';
    case 'running': case 'inProgress': return '正在执行';
    case 'background': return '仍有后台任务';
    case 'blocked': return '执行状态待核对';
    case 'completed': return '已完成';
    case 'interrupted': return '已中断';
    case 'failed': return '执行失败';
    default: return status;
  }
}
export function aiRequestTitle(kind: string): string {
  switch (kind) {
    case 'command': return '运行命令';
    case 'fileChange': return '修改文件';
    case 'permissions': return '申请额外权限';
    case 'questions': return '需要你的回答';
    default: return '需要你的确认';
  }
}
export function aiFileChanges(value: Object | undefined): string {
  return aiArray(value).map((value: Object): string => {
    if (value === null || typeof value !== 'object' || Array.isArray(value)) { return JSON.stringify(value); }
    const change = aiRecord(value);
    const kind = change['kind'];
    const operation = kind !== undefined && typeof kind === 'object' ? aiRecord(kind) : {} as Record<string, Object>;
    const moved = aiString(operation['move_path'], aiString(operation['movePath']));
    const type = aiString(operation['type'], aiString(kind));
    return (type === 'add' ? '新增 ' : type === 'delete' ? '删除 ' : type === 'update' ? '修改 ' : type + ' ') + aiString(change['path']) + (moved !== '' ? ' → ' + moved : '') + '\n' +
      aiString(change['diff'], JSON.stringify(change, null, 2));
  }).join('\n\n');
}
export function aiApprovalDetails(request: Record<string, Object>): string {
  const kind = aiString(request['kind']);
  const reason = aiString(request['reason']);
  if (kind === 'fileChange') {
    if (request['nativeItemComplete'] !== true || request['nativeItem'] === undefined) { return '文件预览不可用，请取消本次请求后重试。'; }
    const item = aiRecord(request['nativeItem']);
    const changes = aiFileChanges(item['changes']);
    return (reason !== '' ? reason + '\n\n' : '') + (changes || JSON.stringify(item, null, 2));
  }
  if (kind === 'command') {
    const command = aiContentText(request['command']);
    return (reason !== '' ? reason + '\n\n' : '') +
      (command !== '' ? command + '\n\n' : '') +
      (aiString(request['cwd']) !== '' ? '工作目录：' + aiString(request['cwd']) + '\n\n' : '') +
      (request['tools'] !== undefined ? JSON.stringify(request['tools'], null, 2) : command === '' ? JSON.stringify(request, null, 2) : '');
  }
  if (kind === 'permissions') {
    return (reason !== '' ? reason + '\n\n' : '') + '仅授予当前回合\n' + JSON.stringify(request['permissions'] ?? request, null, 2);
  }
  if (kind === 'questions') { return '请逐项作答，未选择的选项不会自动提交。'; }
  return JSON.stringify(request, null, 2);
}
