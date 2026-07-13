import { describe, it, expect } from '@ohos/hypium';
import { clipboardSyncEnabledForProtocol, MAX_CLIPBOARD_TEXT_CHARS, shouldForwardClipboard, validateClipboardText } from
  '../main/ets/services/ClipboardSyncPolicy';

export default function clipboardSyncPolicyTest(): void {
  describe('ClipboardSyncPolicy', (): void => {
    it('forwards_enabled_local_text', 0, (): void => {
      expect(shouldForwardClipboard({ source: 'local', sendEnabled: true, receiveEnabled: true })).assertTrue();
    });
    it('blocks_disabled_remote_text_and_echo', 0, (): void => {
      expect(shouldForwardClipboard({ source: 'remote', sendEnabled: true, receiveEnabled: false })).assertFalse();
      expect(shouldForwardClipboard({ source: 'remoteEcho', sendEnabled: true, receiveEnabled: true })).assertFalse();
    });
    it('enforces_plain_text_limit', 0, (): void => {
      expect(validateClipboardText('x'.repeat(MAX_CLIPBOARD_TEXT_CHARS)).ok).assertTrue();
      expect(validateClipboardText('x'.repeat(MAX_CLIPBOARD_TEXT_CHARS + 1)).ok).assertFalse();
    });
    it('uses_the_protocol_specific_clipboard_switch', 0, (): void => {
      expect(clipboardSyncEnabledForProtocol('rdp', true, false)).assertTrue();
      expect(clipboardSyncEnabledForProtocol('rustdesk', false, true)).assertTrue();
      expect(clipboardSyncEnabledForProtocol('rustdesk', true, false)).assertFalse();
    });
  });
}
