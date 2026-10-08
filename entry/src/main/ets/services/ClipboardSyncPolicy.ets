/** Wire budget is UTF-8 bytes. Keep the legacy export for callers/tests. */
export const MAX_CLIPBOARD_TEXT_BYTES: number = 65536;
export const MAX_CLIPBOARD_TEXT_CHARS: number = MAX_CLIPBOARD_TEXT_BYTES;
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
export interface RemoteClipboardDeliveryCheckpoint {
  sessionId: number;
  attemptId: number;
  deliveredHash: number;
}
export interface ClipboardBridgeStartGuardInput {
  continuousAuthorized?: boolean;
  requestedGeneration: number;
  currentGeneration: number;
  requestedSessionId: number;
  currentSessionId: number;
  requestedAttemptId: number;
  currentAttemptId: number;
  connected: boolean;
  background: boolean;
  stopping: boolean;
  enabled: boolean;
}
export interface ClipboardBridgeRestartGuardInput {
  continuousAuthorized?: boolean;
  connected: boolean;
  sessionId: number;
  bridgePresent: boolean;
  background: boolean;
  minimized: boolean;
  enabled: boolean;
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

/** Return -1 for malformed UTF-16; never silently replace or truncate input. */
export function clipboardUtf8Bytes(text: string): number {
  let bytes: number = 0;
  for (let i: number = 0; i < text.length; i++) {
    const value: number = text.charCodeAt(i);
    if (value >= 0xD800 && value <= 0xDBFF) {
      if (i + 1 >= text.length) { return -1; }
      const low: number = text.charCodeAt(++i);
      if (low < 0xDC00 || low > 0xDFFF) { return -1; }
      bytes += 4;
    } else if (value >= 0xDC00 && value <= 0xDFFF) {
      return -1;
    } else {
      bytes += value < 0x80 ? 1 : (value < 0x800 ? 2 : 3);
    }
  }
  return bytes;
}

export function validateClipboardText(text: string, allowEmpty: boolean = false): ClipboardValidation {
  if (text.length === 0 && !allowEmpty) { return { ok: false, diagnosticCode: 'clipboard_empty' }; }
  if (text.indexOf('\u0000') >= 0) { return { ok: false, diagnosticCode: 'clipboard_embedded_nul' }; }
  const bytes: number = clipboardUtf8Bytes(text);
  if (bytes < 0) { return { ok: false, diagnosticCode: 'clipboard_invalid_unicode' }; }
  if (bytes > MAX_CLIPBOARD_TEXT_BYTES) {
    return { ok: false, diagnosticCode: 'clipboard_text_too_large' };
  }
  return { ok: true, diagnosticCode: '' };
}

export function shouldAttemptRemoteClipboard(lastDeliveredHash: number,
  candidateHash: number, valid: boolean): boolean {
  return valid && candidateHash !== 0 && candidateHash !== lastDeliveredHash;
}

/** Advance deduplication only after the system pasteboard confirms delivery. */
export function remoteClipboardHashAfterDelivery(lastDeliveredHash: number,
  candidateHash: number, delivered: boolean): number {
  return delivered ? candidateHash : lastDeliveredHash;
}

/** Reuse deduplication only while the exact native session attempt is alive. */
export function remoteClipboardHashForSession(checkpoint: RemoteClipboardDeliveryCheckpoint,
  sessionId: number, attemptId: number): number {
  return checkpoint.sessionId === sessionId && checkpoint.attemptId === attemptId
    ? checkpoint.deliveredHash : 0;
}

/** Persist a successful delivery across foreground bridge reconstruction. */
export function remoteClipboardCheckpointAfterDelivery(
  checkpoint: RemoteClipboardDeliveryCheckpoint,
  sessionId: number, attemptId: number, deliveredHash: number): RemoteClipboardDeliveryCheckpoint {
  if (deliveredHash === 0) {
    return checkpoint;
  }
  return { sessionId, attemptId, deliveredHash };
}

/** Fence delayed bridge startup against toggle, disconnect and background races. */
export function shouldStartClipboardBridge(input: ClipboardBridgeStartGuardInput): boolean {
  return input.requestedGeneration === input.currentGeneration &&
    input.requestedSessionId > 0 && input.requestedSessionId === input.currentSessionId &&
    input.requestedAttemptId === input.currentAttemptId && input.connected &&
    (!input.background || input.continuousAuthorized === true) && !input.stopping && input.enabled;
}

/** A presentation transition cannot revoke an explicitly authorized continuous owner. */
export function shouldStopClipboardBridgeForBackground(isBackground: boolean, continuousAuthorized: boolean = false): boolean {
  return isBackground && !continuousAuthorized;
}

/** Restart after foreground return, including preserve/init failure paths. */
export function shouldRestartClipboardBridge(input: ClipboardBridgeRestartGuardInput): boolean {
  return input.connected && input.sessionId > 0 && !input.bridgePresent &&
    ((!input.background && !input.minimized) || input.continuousAuthorized === true) && input.enabled;
}
