import { describe, it, expect } from '@ohos/hypium';
import {
  clipboardReadPermissionErrorCode,
  clipboardSyncEnabledForProtocol,
  MAX_CLIPBOARD_TEXT_CHARS,
  RemoteClipboardDeliveryCheckpoint,
  remoteClipboardCheckpointAfterDelivery,
  remoteClipboardHashAfterDelivery,
  remoteClipboardHashForSession,
  resolveClipboardBridgeActivation,
  resolveClipboardReadAccess,
  shouldRestartClipboardBridge,
  shouldAttemptRemoteClipboard,
  shouldStartClipboardBridge,
  shouldStopClipboardBridgeForBackground,
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
    it('retries_the_same_remote_text_after_a_transient_system_write_failure', 0, (): void => {
      const candidateHash: number = 1907;
      let deliveredHash: number = 0;
      expect(shouldAttemptRemoteClipboard(deliveredHash, candidateHash, true)).assertTrue();
      deliveredHash = remoteClipboardHashAfterDelivery(deliveredHash, candidateHash, false);
      expect(deliveredHash).assertEqual(0);
      expect(shouldAttemptRemoteClipboard(deliveredHash, candidateHash, true)).assertTrue();
      deliveredHash = remoteClipboardHashAfterDelivery(deliveredHash, candidateHash, true);
      expect(deliveredHash).assertEqual(candidateHash);
      expect(shouldAttemptRemoteClipboard(deliveredHash, candidateHash, true)).assertFalse();
    });
    it('keeps_remote_deduplication_across_same_session_foreground_restore', 0, (): void => {
      const empty: RemoteClipboardDeliveryCheckpoint = {
        sessionId: -1, attemptId: -1, deliveredHash: 0
      };
      const checkpoint: RemoteClipboardDeliveryCheckpoint =
        remoteClipboardCheckpointAfterDelivery(empty, 41, 7, 1907);
      expect(remoteClipboardHashForSession(checkpoint, 41, 7)).assertEqual(1907);
      expect(shouldAttemptRemoteClipboard(
        remoteClipboardHashForSession(checkpoint, 41, 7), 1907, true)).assertFalse();
    });
    it('allows_the_same_remote_text_in_a_new_native_session', 0, (): void => {
      const checkpoint: RemoteClipboardDeliveryCheckpoint = {
        sessionId: 41, attemptId: 7, deliveredHash: 1907
      };
      const initialHash: number = remoteClipboardHashForSession(checkpoint, 42, 8);
      expect(initialHash).assertEqual(0);
      expect(shouldAttemptRemoteClipboard(initialHash, 1907, true)).assertTrue();
    });
    it('fences_delayed_bridge_start_after_background_or_toggle_off', 0, (): void => {
      const active = {
        requestedGeneration: 3,
        currentGeneration: 3,
        requestedSessionId: 41,
        currentSessionId: 41,
        requestedAttemptId: 7,
        currentAttemptId: 7,
        connected: true,
        background: false,
        stopping: false,
        enabled: true
      };
      expect(shouldStartClipboardBridge(active)).assertTrue();
      expect(shouldStartClipboardBridge({ ...active, currentGeneration: 4 })).assertFalse();
      expect(shouldStartClipboardBridge({ ...active, background: true })).assertFalse();
      expect(shouldStartClipboardBridge({ ...active, enabled: false })).assertFalse();
    });
    it('closes_clipboard_synchronously_on_background_entry', 0, (): void => {
      expect(shouldStopClipboardBridgeForBackground(true)).assertTrue();
      expect(shouldStopClipboardBridgeForBackground(false)).assertFalse();
    });
    it('restarts_after_foreground_return_even_when_preserve_did_not_finish', 0, (): void => {
      const foreground = {
        connected: true,
        sessionId: 41,
        bridgePresent: false,
        background: false,
        minimized: false,
        enabled: true
      };
      expect(shouldRestartClipboardBridge(foreground)).assertTrue();
      expect(shouldRestartClipboardBridge({ ...foreground, background: true })).assertFalse();
      expect(shouldRestartClipboardBridge({ ...foreground, minimized: true })).assertFalse();
      expect(shouldRestartClipboardBridge({ ...foreground, bridgePresent: true })).assertFalse();
      expect(shouldRestartClipboardBridge({ ...foreground, enabled: false })).assertFalse();
    });
  });
}
