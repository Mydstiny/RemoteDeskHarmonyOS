import { recordDiagnosticEvent } from '../DiagnosticCaptureRuntime';

/** ai_request code: what went wrong (0 nothing). */
export const AI_REQUEST_OK: number = 0;
export const AI_REQUEST_NETWORK: number = 1;
export const AI_REQUEST_TIMEOUT: number = 2;
export const AI_REQUEST_AUTH: number = 3;
export const AI_REQUEST_RATE_LIMIT: number = 4;
export const AI_REQUEST_SERVER: number = 5;
export const AI_REQUEST_FORMAT: number = 6;
export const AI_REQUEST_EMPTY: number = 7;
export const AI_REQUEST_TOO_LARGE: number = 8;
export const AI_REQUEST_LOCAL_MODEL: number = 9;
export const AI_REQUEST_ENDPOINT: number = 10;
export const AI_REQUEST_POLICY: number = 11;
export const AI_REQUEST_OTHER: number = 12;

/** ai_request count: what the request was for. */
export const AI_MODE_ANSWER: number = 1;
export const AI_MODE_CONFIGURE: number = 2;
export const AI_MODE_DIAGNOSE: number = 3;
export const AI_MODE_FEEDBACK: number = 4;
export const AI_MODE_MODELS: number = 5;
/** 聊天模式: a general chat request (documents, writing), not about the app. */
export const AI_MODE_CHAT: number = 6;

export function diagnosticAiModeCode(mode: string): number {
  if (mode === 'configure') { return AI_MODE_CONFIGURE; }
  if (mode === 'diagnose') { return AI_MODE_DIAGNOSE; }
  if (mode === 'feedback') { return AI_MODE_FEEDBACK; }
  if (mode === 'chat') { return AI_MODE_CHAT; }
  return AI_MODE_ANSWER;
}

/** The category and HTTP status of an AI error (DIAGNOSTIC_AI_* messages). */
export function diagnosticAiErrorCategory(message: string): number[] {
  const match: RegExpMatchArray | null = message.match(/HTTP_(\d{3})/);
  const status: number = match !== null && match.length > 1 ? parseInt(match[1], 10) : 0;
  if (status === 401 || status === 403) { return [AI_REQUEST_AUTH, status]; }
  if (status === 413) { return [AI_REQUEST_TOO_LARGE, status]; }
  if (status === 429) { return [AI_REQUEST_RATE_LIMIT, status]; }
  if (status >= 500) { return [AI_REQUEST_SERVER, status]; }
  if (status >= 400) { return [AI_REQUEST_FORMAT, status]; }
  if (message.indexOf('TIMEOUT') >= 0) { return [AI_REQUEST_TIMEOUT, 0]; }
  if (message.indexOf('NETWORK') >= 0) { return [AI_REQUEST_NETWORK, 0]; }
  if (message.indexOf('EMPTY_RESULT') >= 0) { return [AI_REQUEST_EMPTY, 0]; }
  if (message.indexOf('LOCAL_MODEL') >= 0) { return [AI_REQUEST_LOCAL_MODEL, 0]; }
  if (message.indexOf('ENDPOINT') >= 0) { return [AI_REQUEST_ENDPOINT, 0]; }
  if (message.indexOf('POLICY') >= 0 || message.indexOf('USE_CASE') >= 0) { return [AI_REQUEST_POLICY, 0]; }
  return [AI_REQUEST_OTHER, status];
}

/** One AI request as remembered for the self-check. */
export class AiRequestRecord {
  mode: number;
  category: number;
  status: number;
  ms: number;
  at: number;

  constructor(mode: number, category: number, status: number, ms: number, at: number) {
    this.mode = mode;
    this.category = category;
    this.status = status;
    this.ms = ms;
    this.at = at;
  }
}

/**
 * Every AI request's outcome: into a running capture (ai_request) and into a short in-memory history the AI self-check
 * reads even when no capture ran (and when the AI itself is what fails).
 */
export class DiagnosticAiRequestLog {
  static recent: AiRequestRecord[] = [];

  static record(mode: number, error: Object | null, elapsedMs: number, bytes: number): void {
    const message: string = error === null ? '' : error instanceof Error ? (error as Error).message : String(error);
    const classified: number[] = error === null ? [AI_REQUEST_OK, 0] : diagnosticAiErrorCategory(message);
    const ms: number = Math.max(0, Math.round(elapsedMs));
    DiagnosticAiRequestLog.recent = DiagnosticAiRequestLog.recent
      .concat([new AiRequestRecord(mode, classified[0], classified[1], ms, Date.now())]).slice(-8);
    recordDiagnosticEvent('core.ai', 'ai_request',
      error === null ? 'succeeded' : classified[0] === AI_REQUEST_TIMEOUT ? 'timeout' : 'failed',
      0, classified[1], classified[0], ms, mode, Math.max(0, bytes));
  }
}

/** What a request failure means, in words the user reads in the self-check. */
export function diagnosticAiRequestCategoryLabel(category: number): string {
  switch (category) {
    case AI_REQUEST_OK: return '成功';
    case AI_REQUEST_NETWORK: return '网络连不上';
    case AI_REQUEST_TIMEOUT: return '超时';
    case AI_REQUEST_AUTH: return 'Key 无效或没有权限';
    case AI_REQUEST_RATE_LIMIT: return '请求太频繁被限流';
    case AI_REQUEST_SERVER: return '服务商暂时故障';
    case AI_REQUEST_FORMAT: return '模型不接受请求格式';
    case AI_REQUEST_EMPTY: return '返回了空结果';
    case AI_REQUEST_TOO_LARGE: return '请求内容过大';
    case AI_REQUEST_LOCAL_MODEL: return '端侧模型不可用';
    case AI_REQUEST_ENDPOINT: return '服务地址无效';
    case AI_REQUEST_POLICY: return '当前套餐或用途不允许';
    default: return '其它错误';
  }
}

/** ai_config: a configuration problem found before any request (1 key unreadable, 2 no service/model chosen). */
export function recordAiConfigProblem(code: number): void {
  recordDiagnosticEvent('core.ai', 'ai_config', 'failed', 0, 0, code);
}
