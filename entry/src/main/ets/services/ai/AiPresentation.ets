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
/** Permission and collaboration modes the engines report, in words; an unknown mode keeps its own name. */
export function aiModeLabel(mode: string): string {
  switch (mode) {
    case 'read-only': case 'readOnly': return '只读';
    case 'workspace-write': case 'workspaceWrite': return '可写工作区';
    case 'danger-full-access': case 'dangerFullAccess': return '完全访问';
    case 'default': return '默认';
    case 'acceptEdits': return '自动接受修改';
    case 'plan': return '先做计划';
    case 'bypassPermissions': return '跳过确认';
    default: return mode;
  }
}
const AI_METHOD_LABELS: Record<string, string> = {
  'turn.start': '发送任务', 'turn.steer': '补充指令', 'turn.cancel': '停止回合', 'session.create': '新建会话',
  'session.update': '更新会话设置', 'session.fork': '分叉会话', 'session.compact': '压缩上下文',
  'session.archive': '归档会话', 'session.resume': '恢复会话', 'lease.acquire': '取得控制权', 'lease.release': '释放控制权',
  'lease.renew': '续期控制权', 'approval.answer': '回复审批', 'terminal.stop': '停止终端任务'
};
/** A pending write as a person reads it: what was sent and what is known about its result. */
export function aiOperationSummary(body: string, receipt: string): string[] {
  let method = '';
  try { method = aiString(aiRecord(JSON.parse(body) as Object)['method']); } catch (_error) { method = ''; }
  let status = '结果待确认';
  if (receipt !== '') {
    try {
      const value = aiString(aiRecord(JSON.parse(receipt) as Object)['status']);
      status = value === 'succeeded' ? '已完成' : value === 'rejected' ? '电脑端已拒绝' :
        value === 'not_found' ? '电脑端没有这条记录' : value === '' ? '结果待确认' : value;
    } catch (_error) { status = '结果待确认'; }
  }
  return [AI_METHOD_LABELS[method] ?? (method === '' ? '未知操作' : method), status];
}
/** 10-07 15:55:02 — the device locale formatted these as "10/7/2026, 3:55:02 PM". */
export function aiShortTime(at: number): string {
  const date = new Date(at);
  const two = (value: number): string => value.toString().padStart(2, '0');
  return two(date.getMonth() + 1) + '-' + two(date.getDate()) + ' ' + two(date.getHours()) + ':' +
    two(date.getMinutes()) + ':' + two(date.getSeconds());
}
/** The conversation list's time: 刚刚, 5 分钟前, 3 小时前, 昨天, 10-03 (or 2025-10-03 in an earlier year). */
export function aiRelativeTime(at: number, now: number = Date.now()): string {
  if (!Number.isFinite(at) || at <= 0) { return ''; }
  const minutes = Math.floor((now - at) / 60000);
  if (minutes < 1) { return '刚刚'; }
  if (minutes < 60) { return minutes.toString() + ' 分钟前'; }
  const date = new Date(at), today = new Date(now);
  const startOfToday = new Date(today.getFullYear(), today.getMonth(), today.getDate()).getTime();
  if (at >= startOfToday) { return Math.floor(minutes / 60).toString() + ' 小时前'; }
  if (at >= startOfToday - 86400000) { return '昨天'; }
  const two = (value: number): string => value.toString().padStart(2, '0');
  const day = two(date.getMonth() + 1) + '-' + two(date.getDate());
  return date.getFullYear() === today.getFullYear() ? day : date.getFullYear().toString() + '-' + day;
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
    const operation = aiFields(kind);
    const moved = aiString(operation['move_path'], aiString(operation['movePath']));
    const type = aiString(operation['type'], aiString(kind));
    return (type === 'add' ? '新增 ' : type === 'delete' ? '删除 ' : type === 'update' ? '修改 ' : type + ' ') + aiString(change['path']) + (moved !== '' ? ' → ' + moved : '') + '\n' +
      aiString(change['diff'], JSON.stringify(change, null, 2));
  }).join('\n\n');
}
const MAX_EDIT_PREVIEW: number = 20000;

/** The value as a record, or an empty one: an approval with a malformed field still renders. */
function aiFields(value: Object | undefined | null): Record<string, Object> {
  return value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value) ?
    value as Record<string, Object> : {};
}

function aiMarkedLines(text: string, mark: string): string {
  if (text === '') { return ''; }
  return text.split('\n').map((line: string): string => mark + line).join('\n');
}

/** A Claude Edit/MultiEdit/Write/NotebookEdit approval: the request carries the whole edit in its tool input. */
function aiClaudeFileChange(request: Record<string, Object>, reason: string): string {
  const tool = aiString(request['tool']);
  const input = aiFields(request['input']);
  const path = aiString(input['file_path'], aiString(input['notebook_path']));
  const head = [reason, aiString(request['description'])].filter((value: string): boolean => value !== '').join('\n');
  let body = '';
  if (tool === 'Edit') {
    body = '修改 ' + path + '\n' + [aiMarkedLines(aiString(input['old_string']), '- '),
      aiMarkedLines(aiString(input['new_string']), '+ ')].filter((value: string): boolean => value !== '').join('\n');
  } else if (tool === 'MultiEdit') {
    body = '修改 ' + path + aiArray(input['edits']).map((value: Object): string => {
      const edit = aiFields(value);
      return '\n@@\n' + [aiMarkedLines(aiString(edit['old_string']), '- '),
        aiMarkedLines(aiString(edit['new_string']), '+ ')].filter((part: string): boolean => part !== '').join('\n');
    }).join('');
  } else if (tool === 'Write') {
    body = '写入 ' + path + '\n' + aiMarkedLines(aiString(input['content']), '+ ');
  } else {
    body = (tool !== '' ? tool + ' ' : '') + path + '\n' + JSON.stringify(input, null, 2);
  }
  if (body.length > MAX_EDIT_PREVIEW) { body = body.slice(0, MAX_EDIT_PREVIEW) + '\n…（其余内容在电脑端）'; }
  return (head !== '' ? head + '\n\n' : '') + body;
}

export function aiApprovalDetails(request: Record<string, Object>): string {
  const kind = aiString(request['kind']);
  const reason = aiString(request['reason']);
  if (kind === 'fileChange' && aiString(request['engine']) === 'claudecode') { return aiClaudeFileChange(request, reason); }
  if (kind === 'fileChange') {
    if (request['nativeItemComplete'] !== true || request['nativeItem'] === undefined) { return '文件预览不可用，请取消本次请求后重试。'; }
    const item = aiFields(request['nativeItem']);
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
