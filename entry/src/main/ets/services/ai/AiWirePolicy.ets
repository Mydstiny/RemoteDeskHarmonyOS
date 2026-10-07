import { AiEvent, AiInvite, aiIdValid } from './AiModels';
import { util } from '@kit.ArkTS';

export function aiRecord(value: Object | undefined | null): Record<string, Object> {
  if (value === null || value === undefined || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('AI_RESPONSE_INVALID');
  }
  return value as Record<string, Object>;
}
export function aiString(value: Object | undefined | null, fallback: string = ''): string {
  return typeof value === 'string' ? value : fallback;
}
export function aiNumber(value: Object | undefined | null, fallback: number = 0): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback;
}
export function aiArray(value: Object | undefined | null): Object[] {
  return Array.isArray(value) ? value as Object[] : [];
}
const AI_CA_SHA256_PATTERN: RegExp = /^[A-Za-z0-9_-]{43}$/;
function parseRawAiInvite(raw: Record<string, Object>, now: number): AiInvite {
  const keys = Object.keys(raw).sort().join(',');
  const compact = keys === 'caSha256,code,expires,serverInstance';
  if (keys !== 'ca,code,expires,serverInstance' && !compact) { throw new Error('AI_INVITE_INVALID'); }
  const invite: AiInvite = { ca: aiString(raw['ca']), caSha256: aiString(raw['caSha256']), code: aiString(raw['code']),
    expires: aiNumber(raw['expires']), serverInstance: aiString(raw['serverInstance']) };
  const trustValid = compact ? AI_CA_SHA256_PATTERN.test(invite.caSha256) :
    invite.ca.length <= 65536 && invite.ca.includes('-----BEGIN CERTIFICATE-----');
  if (!aiIdValid(invite.code) || !aiIdValid(invite.serverInstance) ||
    !Number.isSafeInteger(invite.expires) || !Number.isFinite(now) || invite.expires <= now || !trustValid) {
    throw new Error('AI_INVITE_EXPIRED_OR_INVALID');
  }
  return invite;
}

function unwrapPairingLink(text: string): string {
  const match: RegExpExecArray | null = /^remotedesk:\/\/pair\?data=([A-Za-z0-9_-]+)$/.exec(text.trim());
  if (match === null || match[1].length > 120000) { throw new Error('AI_INVITE_INVALID'); }
  const padded: string = match[1] + '='.repeat((4 - match[1].length % 4) % 4);
  try {
    const decoded: Uint8Array = new util.Base64Helper().decodeSync(padded);
    const parsed: Object = JSON.parse(new util.TextDecoder().decodeToString(decoded)) as Object;
    const envelope = aiRecord(parsed);
    if (envelope['type'] !== 'remotedesk-pair' || envelope['version'] !== 1) {
      throw new Error('AI_INVITE_INVALID');
    }
    return JSON.stringify(aiRecord(envelope['invite']));
  } catch (_error) {
    throw new Error('AI_INVITE_INVALID');
  }
}

export function parseAiInvite(text: string, now: number = Date.now()): AiInvite {
  if (text.length > 120000) { throw new Error('AI_INVITE_INVALID'); }
  const normalized: string = text.trim().startsWith('remotedesk://pair?data=') ? unwrapPairingLink(text) : text;
  let parsed: Object;
  try {
    parsed = JSON.parse(normalized) as Object;
  } catch (_error) {
    throw new Error('AI_INVITE_INVALID');
  }
  return parseRawAiInvite(aiRecord(parsed), now);
}
/** Handles fragmented SSE and multiline data; HTTP framing is owned by native. */
export class AiEventDecoder {
  private buffer: string = '';
  private readonly onEvent: (event: AiEvent) => void;
  constructor(onEvent: (event: AiEvent) => void) { this.onEvent = onEvent; }
  feed(text: string): void {
    this.buffer += text;
    if (this.buffer.length > 8 * 1024 * 1024) { throw new Error('AI_STREAM_FRAME_TOO_LARGE'); }
    for (;;) {
      const match = /\r?\n\r?\n/.exec(this.buffer);
      if (match === null) { return; }
      const frame = this.buffer.slice(0, match.index);
      this.buffer = this.buffer.slice(match.index + match[0].length);
      const data: string[] = [];
      let id = '';
      for (const line of frame.split(/\r?\n/)) {
        if (line.startsWith('data:')) { data.push(line.slice(5).replace(/^ /, '')); }
        if (line.startsWith('id:')) { id = line.slice(3).trim(); }
      }
      if (data.length === 0) { continue; }
      const raw = aiRecord(JSON.parse(data.join('\n')));
      const event: AiEvent = { cursor: aiNumber(raw['cursor'], -1), session: aiString(raw['session']),
        project: aiString(raw['project']), runtime: aiString(raw['runtime']), event: aiRecord(raw['event']) };
      if (!Number.isSafeInteger(event.cursor) || event.cursor < 0 || !aiIdValid(event.runtime) ||
        (id !== '' && id !== event.cursor.toString())) { throw new Error('AI_EVENT_INVALID'); }
      this.onEvent(event);
    }
  }
}
export function aiErrorText(code: string): string {
  if (code.includes('CLAUDE_API_KEY_REQUIRED')) { return '电脑端 Claude Agent 尚未配置 Anthropic API Key，请在电脑设置页填写后重试'; }
  if (code.includes('CLAUDE_QUERY_FAILED')) { return 'Claude Agent 执行失败，请检查电脑端 API Key、网络与额度后重试'; }
  if (code.includes('AI_MODEL_IMAGE')) { return '当前模型未声明图片能力，请选择支持图片的模型'; }
  if (code.includes('AI_ATTACHMENT')) { return '附件读取失败，请选择 500 KB 以内的 PNG、JPEG 或 UTF-8 文本'; }
  if (code.includes('AI_QUESTION_ANSWER')) { return '请填写所有问题的回答'; }
  if (code.includes('RECONNECT_REQUIRED')) { return '请重新连接后再取得控制权'; }
  if (code.includes('OPERATION_STORAGE_FULL')) { return '操作记录空间不足，请先核对待确认操作，并在 AI 设置中清理已确认记录'; }
  if (code.includes('ACCOUNT')) { return '账号已变化或暂不可用，请返回主机列表重试'; }
  if (code.includes('PRO_ACCESS')) { return '此功能需要有效 Pro 权益；当前尚未开放的功能仅供开发验证'; }
  if (code.includes('CA_FINGERPRINT_MISMATCH')) { return '电脑证书与二维码不一致，请核对地址或在电脑上重新生成邀请'; }
  if (code.includes('TLS') || code.includes('CA_INVALID') || code.includes('IDENTITY')) {
    return '电脑身份校验失败，请核对地址、证书名称和配对信息';
  }
  if (code.includes('INVITE')) { return '配对邀请无效或已过期，请在电脑上生成新邀请'; }
  if (code.includes('DEVICE_REVOKED') || code.includes('DEVICE_UNAUTHORIZED')) { return '此设备未获授权或已被撤销，请重新配对'; }
  if (code.includes('LEASE_BUSY')) { return '另一台设备正在控制此会话，可继续查看历史'; }
  if (code.includes('LEASE') || code.includes('APPROVAL_STALE')) { return '控制权或审批已失效，请刷新会话'; }
  if (code.includes('PROJECT_BUSY')) { return '此项目仍有运行中的任务，请等待或停止原任务'; }
  if (code.includes('UNKNOWN') || code.includes('RECONCILE') || code.includes('TIMEOUT')) {
    return '操作结果尚未确认，请核对原操作回执与会话记录，避免重复发送';
  }
  if (code.includes('CANCELLED')) { return '连接已取消'; }
  if (code.includes('RESET_REQUIRED')) { return '服务状态已更新，正在重新读取会话'; }
  if (code.includes('STORE') || code.includes('STORAGE')) { return '本机数据暂不可用，请重试；未确认操作不会自动重发'; }
  if (code.includes('HOST_CHANGED')) { return '主机已在其他窗口修改，请重新打开'; }
  return '操作未完成，请检查电脑服务和网络后重试';
}

export function aiParams(keys: string[], values: Object[]): Record<string, Object> {
  const params: Record<string, Object> = {};
  keys.forEach((key: string, index: number): void => { params[key] = values[index]; });
  return params;
}
