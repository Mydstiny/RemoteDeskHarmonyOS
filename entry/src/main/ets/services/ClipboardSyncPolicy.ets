export const MAX_CLIPBOARD_TEXT_CHARS: number = 65536;
export type ClipboardSource = 'local' | 'remote' | 'remoteEcho';
export interface ClipboardForwardInput {
  source: ClipboardSource;
  sendEnabled: boolean;
  receiveEnabled: boolean;
}
export interface ClipboardValidation { ok: boolean; diagnosticCode: string; }
export type ClipboardProtocol = 'rdp' | 'rustdesk' | 'vnc' | string;
export type ClipboardReadAccessState = 'granted' | 'denied' | 'unavailable';
export interface ClipboardReadAccessDecision {
  state: ClipboardReadAccessState;
  granted: boolean;
  diagnosticCode: string;
  userMessage: string;
}
export type ClipboardBridgeMode = 'disabled' | 'bidirectional' | 'receive_only';
export interface ClipboardBridgeActivationDecision {
  start: boolean;
  requestLocalRead: boolean;
  mode: ClipboardBridgeMode;
}

export function resolveClipboardReadAccess(alreadyGranted: boolean,
  requestResult: number | null, requestFailed: boolean = false): ClipboardReadAccessDecision {
  if (alreadyGranted || requestResult === 0) {
    return {
      state: 'granted',
      granted: true,
      diagnosticCode: '',
      userMessage: ''
    };
  }
  if (requestFailed || requestResult === null || requestResult !== -1) {
    return {
      state: 'unavailable',
      granted: false,
      diagnosticCode: 'clipboard_read_permission_unavailable',
      userMessage: '当前签名或系统不支持读取本机剪贴板'
    };
  }
  return {
    state: 'denied',
    granted: false,
    diagnosticCode: 'clipboard_read_permission_denied',
    userMessage: '允许读取剪贴板后才能同步本机复制内容'
  };
}

export function clipboardReadPermissionErrorCode(errorCode: number | undefined): string {
  return typeof errorCode === 'number' ? errorCode.toString() : 'unknown';
}

export function resolveClipboardBridgeActivation(protocol: ClipboardProtocol,
  configured: boolean, sendReady: boolean,
  receiveReady: boolean): ClipboardBridgeActivationDecision {
  if (!configured) {
    return { start: false, requestLocalRead: false, mode: 'disabled' };
  }
  if (sendReady) {
    return { start: true, requestLocalRead: true, mode: 'bidirectional' };
  }
  // VNC does not report clipboard receive readiness until the first
  // ServerCutText arrives. Start its receive-only poll before that event so
  // view-only sessions cannot deadlock behind the capability snapshot.
  if (receiveReady || protocol === 'vnc') {
    return { start: true, requestLocalRead: false, mode: 'receive_only' };
  }
  return { start: false, requestLocalRead: false, mode: 'disabled' };
}

export function clipboardSyncEnabledForProtocol(protocol: ClipboardProtocol, rdpEnabled: boolean,
  rustDeskEnabled: boolean, vncEnabled: boolean = false): boolean {
  if (protocol === 'rustdesk') { return rustDeskEnabled; }
  if (protocol === 'rdp') { return rdpEnabled; }
  return protocol === 'vnc' && vncEnabled;
}

export function shouldForwardClipboard(input: ClipboardForwardInput): boolean {
  if (input.source === 'remoteEcho') { return false; }
  return input.source === 'local' ? input.sendEnabled : input.receiveEnabled;
}

export function validateClipboardText(text: string): ClipboardValidation {
  if (text.length === 0) { return { ok: false, diagnosticCode: 'clipboard_empty' }; }
  if (text.length > MAX_CLIPBOARD_TEXT_CHARS) {
    return { ok: false, diagnosticCode: 'clipboard_text_too_large' };
  }
  return { ok: true, diagnosticCode: '' };
}
