export type SshTerminalSearchDirection = 'next' | 'previous';
export type SshTerminalSearchErrorCode =
  | ''
  | 'empty_query'
  | 'query_too_long'
  | 'invalid_regex'
  | 'search_unavailable'
  | 'execution_failed'
  | 'stale_result'
  | 'invalid_result';

export interface SshTerminalSearchOptions {
  caseSensitive: boolean;
  wholeWord: boolean;
  regex: boolean;
}

export interface SshTerminalSearchRequest {
  requestId: number;
  query: string;
  direction: SshTerminalSearchDirection;
  options: SshTerminalSearchOptions;
}

export interface SshTerminalSearchValidation {
  valid: boolean;
  errorCode: SshTerminalSearchErrorCode;
  message: string;
}

export interface SshTerminalSearchResult {
  requestId: number;
  found: boolean;
  resultIndex: number;
  resultCount: number;
  elapsedMs: number;
  errorCode: SshTerminalSearchErrorCode;
}

export const SSH_TERMINAL_SEARCH_MAX_QUERY_LENGTH: number = 512;
export const SSH_TERMINAL_SEARCH_RESULT_WARN_MS: number = 16;
export const SSH_TERMINAL_SEARCH_HIGHLIGHT_LIMIT: number = 500;
export const SSH_TERMINAL_SEARCH_DEBOUNCE_MS: number = 120;

export function defaultSshTerminalSearchOptions(): SshTerminalSearchOptions {
  return { caseSensitive: false, wholeWord: false, regex: false };
}

export function validateSshTerminalSearchQuery(query: string,
  options: SshTerminalSearchOptions): SshTerminalSearchValidation {
  if (query.length === 0) {
    return { valid: false, errorCode: 'empty_query', message: '' };
  }
  if (query.length > SSH_TERMINAL_SEARCH_MAX_QUERY_LENGTH) {
    return {
      valid: false,
      errorCode: 'query_too_long',
      message: '搜索内容不能超过 512 个字符'
    };
  }
  if (options.regex) {
    try {
      new RegExp(query, options.caseSensitive ? '' : 'i');
    } catch (_err) {
      return { valid: false, errorCode: 'invalid_regex', message: '正则表达式无效' };
    }
  }
  return { valid: true, errorCode: '', message: '' };
}

export function createSshTerminalSearchRequest(requestId: number, query: string,
  direction: SshTerminalSearchDirection,
  options: SshTerminalSearchOptions): SshTerminalSearchRequest | null {
  const normalizedId: number = Number.isFinite(requestId) ? Math.floor(requestId) : 0;
  if (normalizedId <= 0 || (direction !== 'next' && direction !== 'previous') ||
    !validateSshTerminalSearchQuery(query, options).valid) {
    return null;
  }
  return {
    requestId: normalizedId,
    query,
    direction,
    options: {
      caseSensitive: options.caseSensitive === true,
      wholeWord: options.wholeWord === true,
      regex: options.regex === true
    }
  };
}

export function encodeSshTerminalSearchRequest(request: SshTerminalSearchRequest): string {
  const clean: SshTerminalSearchRequest | null = createSshTerminalSearchRequest(
    request.requestId, request.query, request.direction, request.options);
  return clean === null ? '' : JSON.stringify(clean);
}

/** Decode only the page-bridge schema; unknown properties never reach ArkWeb. */
export function decodeSshTerminalSearchRequest(raw: string): SshTerminalSearchRequest | null {
  try {
    const source: SshTerminalSearchRequest = JSON.parse(raw) as SshTerminalSearchRequest;
    if (source === null || source === undefined || typeof source !== 'object' ||
      typeof source.requestId !== 'number' || !Number.isInteger(source.requestId) ||
      typeof source.query !== 'string' ||
      (source.direction !== 'next' && source.direction !== 'previous') ||
      source.options === null || source.options === undefined ||
      typeof source.options !== 'object' ||
      typeof source.options.caseSensitive !== 'boolean' ||
      typeof source.options.wholeWord !== 'boolean' ||
      typeof source.options.regex !== 'boolean') {
      return null;
    }
    return createSshTerminalSearchRequest(
      source.requestId, source.query, source.direction, source.options);
  } catch (_err) {
    return null;
  }
}

function unwrapJsonString(raw: string): string {
  let value: string = raw.trim();
  for (let depth = 0; depth < 2 && value.length > 0; depth++) {
    try {
      const decoded: Object = JSON.parse(value) as Object;
      if (typeof decoded !== 'string') { return value; }
      value = decoded as string;
    } catch (_err) {
      return value;
    }
  }
  return value;
}

function validSearchErrorCode(value: string): SshTerminalSearchErrorCode {
  if (value === '' || value === 'empty_query' || value === 'query_too_long' ||
    value === 'invalid_regex' || value === 'search_unavailable' ||
    value === 'execution_failed' || value === 'stale_result' ||
    value === 'invalid_result') {
    return value;
  }
  return 'invalid_result';
}

export function invalidSshTerminalSearchResult(requestId: number,
  errorCode: SshTerminalSearchErrorCode = 'invalid_result'): SshTerminalSearchResult {
  return {
    requestId: Number.isFinite(requestId) ? Math.max(0, Math.floor(requestId)) : 0,
    found: false,
    resultIndex: -1,
    resultCount: 0,
    elapsedMs: 0,
    errorCode
  };
}

export function decodeSshTerminalSearchResult(raw: string,
  expectedRequestId: number): SshTerminalSearchResult {
  try {
    const source: SshTerminalSearchResult = JSON.parse(unwrapJsonString(raw)) as
      SshTerminalSearchResult;
    if (source === null || source === undefined || typeof source !== 'object' ||
      typeof source.requestId !== 'number' || !Number.isInteger(source.requestId) ||
      typeof source.found !== 'boolean' || typeof source.resultIndex !== 'number' ||
      typeof source.resultCount !== 'number' || typeof source.elapsedMs !== 'number' ||
      typeof source.errorCode !== 'string') {
      return invalidSshTerminalSearchResult(expectedRequestId);
    }
    if (source.requestId !== expectedRequestId) {
      return invalidSshTerminalSearchResult(expectedRequestId, 'stale_result');
    }
    const resultCount: number = Number.isFinite(source.resultCount) ?
      Math.max(0, Math.floor(source.resultCount)) : 0;
    const resultIndex: number = Number.isFinite(source.resultIndex) && source.resultIndex >= 0 ?
      Math.floor(source.resultIndex) : -1;
    return {
      requestId: source.requestId,
      found: source.found === true && resultCount > 0,
      resultIndex: resultIndex >= resultCount ? -1 : resultIndex,
      resultCount,
      elapsedMs: Number.isFinite(source.elapsedMs) ?
        Math.max(0, Math.round(source.elapsedMs * 10) / 10) : 0,
      errorCode: validSearchErrorCode(source.errorCode)
    };
  } catch (_err) {
    return invalidSshTerminalSearchResult(expectedRequestId);
  }
}

export function sshTerminalSearchResultLabel(result: SshTerminalSearchResult | null): string {
  if (result === null) { return ''; }
  if (result.errorCode === 'invalid_regex') { return '正则无效'; }
  if (result.errorCode === 'search_unavailable') { return '搜索不可用'; }
  if (result.errorCode !== '') { return '搜索失败'; }
  if (!result.found || result.resultCount === 0) { return '0 / 0'; }
  const index: number = result.resultIndex >= 0 ? result.resultIndex + 1 : 1;
  const capped: string = result.resultCount >= SSH_TERMINAL_SEARCH_HIGHLIGHT_LIMIT ? '+' : '';
  return index.toString() + ' / ' + result.resultCount.toString() + capped;
}
