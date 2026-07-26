export const MAX_CLIPBOARD_TEXT_CHARS: number = 65536;
export type ClipboardSource = 'local' | 'remote' | 'remoteEcho';
export interface ClipboardForwardInput {
  source: ClipboardSource;
  sendEnabled: boolean;
  receiveEnabled: boolean;
}
export interface ClipboardValidation { ok: boolean; diagnosticCode: string; }
export type ClipboardProtocol = 'rdp' | 'rustdesk' | 'vnc' | string;

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
