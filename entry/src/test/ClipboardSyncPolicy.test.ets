import { describe, it, expect } from '@ohos/hypium';
import {
  clipboardReadPermissionErrorCode,
  clipboardSyncEnabledForProtocol,
  MAX_CLIPBOARD_TEXT_CHARS,
  resolveClipboardBridgeActivation,
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
      expect(resolveClipboardReadAccess(false, 2).state).assertEqual('unavailable');
      expect(resolveClipboardReadAccess(false, null, true).state).assertEqual('unavailable');
      expect(clipboardReadPermissionErrorCode(201)).assertEqual('201');
      expect(clipboardReadPermissionErrorCode(undefined)).assertEqual('unknown');
    });
    it('starts_vnc_view_only_bridge_without_local_read', 0, (): void => {
      const decision = resolveClipboardBridgeActivation('vnc', true, false, false);
      expect(decision.start).assertTrue();
      expect(decision.requestLocalRead).assertFalse();
      expect(decision.mode).assertEqual('receive_only');
    });
    it('waits_for_non_vnc_carrier_and_disables_unconfigured_bridge', 0, (): void => {
      expect(resolveClipboardBridgeActivation('rdp', true, false, false).start).assertFalse();
      expect(resolveClipboardBridgeActivation('rustdesk', false, true, true).start).assertFalse();
      expect(resolveClipboardBridgeActivation('rustdesk', true, true, false).requestLocalRead).assertTrue();
    });
  });
}
