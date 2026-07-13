/**
 * ExtensionResult.ets — 类型化 NAPI 调用结果 (T-234)
 *
 * 替代当前 ExtensionLoader 中返回 -1 / 空字符串等魔数的错误处理。
 * 后台连续性 API 使用此类型提供可追溯的错误码和诊断信息。
 */

// ====== 错误码枚举 ======

export enum ExtensionErrorCode {
  OK = 'EXT_OK',
  ERR_NOT_CONNECTED = 'EXT_ERR_NOT_CONNECTED',
  ERR_ALREADY_CONNECTED = 'EXT_ERR_ALREADY_CONNECTED',
  ERR_INVALID_SESSION = 'EXT_ERR_INVALID_SESSION',
  ERR_NATIVE_CALL_FAILED = 'EXT_ERR_NATIVE_CALL_FAILED',
  ERR_RENDER_NOT_ATTACHED = 'EXT_ERR_RENDER_NOT_ATTACHED',
  ERR_RENDER_ALREADY_ATTACHED = 'EXT_ERR_RENDER_ALREADY_ATTACHED',
  ERR_AUDIO_NOT_ACTIVE = 'EXT_ERR_AUDIO_NOT_ACTIVE',
  ERR_BACKGROUND_TASK_REJECTED = 'EXT_ERR_BACKGROUND_TASK_REJECTED',
  ERR_SURFACE_INVALID = 'EXT_ERR_SURFACE_INVALID',
  ERR_NO_ACTIVE_SESSION = 'EXT_ERR_NO_ACTIVE_SESSION',
  ERR_UNKNOWN = 'EXT_ERR_UNKNOWN'
}

// ====== 类型化结果 ======

export interface ExtensionResult<T> {
  /** true = 操作成功 */
  ok: boolean;
  /** 成功时的数据 (ok=false 时为 undefined) */
  value: T | undefined;
  /** 错误码 (ok=true 时为 EXT_OK) */
  code: ExtensionErrorCode;
  /** 人类可读的错误描述 */
  message: string;
  /** 额外诊断信息 (可选) */
  detail: string;
}

// ====== 工厂函数 ======

export function okResult<T>(value: T): ExtensionResult<T> {
  return {
    ok: true,
    value: value,
    code: ExtensionErrorCode.OK,
    message: '',
    detail: ''
  };
}

export function okVoid(): ExtensionResult<void> {
  return {
    ok: true,
    value: undefined,
    code: ExtensionErrorCode.OK,
    message: '',
    detail: ''
  };
}

export function errResult<T>(code: ExtensionErrorCode, message: string,
  detail?: string): ExtensionResult<T> {
  return {
    ok: false,
    value: undefined,
    code: code,
    message: message,
    detail: detail ?? ''
  };
}

// ====== Native 会话快照 (从 ExtensionLoader 查询) ======

export interface NativeSessionSnapshot {
  sessionId: number;
  rendererReady: boolean;
  decoderReady: boolean;
  audioActive: boolean;
  protocolConnected: boolean;
  connectionState: number;
  lastMessage: string;
}
