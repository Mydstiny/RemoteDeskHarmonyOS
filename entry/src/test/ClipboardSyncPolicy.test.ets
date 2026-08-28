import { describe, it, expect } from '@ohos/hypium';
import {
  clipboardSyncEnabledForProtocol,
  MAX_CLIPBOARD_TEXT_CHARS,
  resolveClipboardReadAccess,
  shouldForwardClipboard,
  validateClipboardText
} from
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
      expect(clipboardSyncEnabledForProtocol('vnc', true, true, true)).assertTrue();
      expect(clipboardSyncEnabledForProtocol('vnc', true, true, false)).assertFalse();
    });
    it('activates_local_reads_only_after_permission_is_granted', 0, (): void => {
      expect(resolveClipboardReadAccess(true, null).granted).assertTrue();
      expect(resolveClipboardReadAccess(false, 0).granted).assertTrue();
      expect(resolveClipboardReadAccess(false, -1).state).assertEqual('denied');
      expect(resolveClipboardReadAccess(false, null, true).state).assertEqual('unavailable');
    });
  });
}
