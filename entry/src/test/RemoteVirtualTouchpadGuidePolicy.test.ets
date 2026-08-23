import { describe, expect, it } from '@ohos/hypium';
import {
  remoteVirtualTouchpadKeyboardGuide,
  shouldRetryRemoteVirtualTouchpadKeyboardGuide,
  shouldShowRemoteVirtualTouchpadKeyboardGuide
} from '../main/ets/services/RemoteVirtualTouchpadGuidePolicy';

export default function remoteVirtualTouchpadGuidePolicyTest(): void {
  describe('RemoteVirtualTouchpadGuidePolicy', (): void => {
    it('shows_only_for_connected_writable_touchpad_sessions', 0, (): void => {
      expect(shouldShowRemoteVirtualTouchpadKeyboardGuide(
        'rdp', true, 0, false, false, false)).assertTrue();
      expect(shouldShowRemoteVirtualTouchpadKeyboardGuide(
        'rustdesk', true, 1, false, false, false)).assertFalse();
      expect(shouldShowRemoteVirtualTouchpadKeyboardGuide(
        'vnc', true, 0, false, false, true)).assertFalse();
      expect(shouldShowRemoteVirtualTouchpadKeyboardGuide(
        'ssh', true, 0, false, false, false)).assertFalse();
    });

    it('does_not_repeat_or_overlap_an_active_prompt', 0, (): void => {
      expect(shouldShowRemoteVirtualTouchpadKeyboardGuide(
        'rdp', true, 0, true, false, false)).assertFalse();
      expect(shouldShowRemoteVirtualTouchpadKeyboardGuide(
        'rdp', true, 0, false, true, false)).assertFalse();
      expect(shouldShowRemoteVirtualTouchpadKeyboardGuide(
        'rdp', false, 0, false, false, false)).assertFalse();
    });

    it('honors_the_durable_marker_and_session_override', 0, (): void => {
      expect(shouldShowRemoteVirtualTouchpadKeyboardGuide(
        'rdp', true, 0, false, false, false, true, false)).assertFalse();
      expect(shouldShowRemoteVirtualTouchpadKeyboardGuide(
        'rdp', true, 0, false, false, false, true, true)).assertTrue();
      expect(shouldShowRemoteVirtualTouchpadKeyboardGuide(
        'rdp', true, 0, true, false, false, true, true)).assertFalse();
    });

    it('bounds_dialog_presentation_retries', 0, (): void => {
      expect(shouldRetryRemoteVirtualTouchpadKeyboardGuide(true, 0)).assertTrue();
      expect(shouldRetryRemoteVirtualTouchpadKeyboardGuide(true, 1)).assertTrue();
      expect(shouldRetryRemoteVirtualTouchpadKeyboardGuide(true, 2)).assertFalse();
      expect(shouldRetryRemoteVirtualTouchpadKeyboardGuide(false, 0)).assertFalse();
    });

    it('provides_protocol_specific_keyboard_entry_instructions', 0, (): void => {
      const rdp = remoteVirtualTouchpadKeyboardGuide('rdp');
      const vnc = remoteVirtualTouchpadKeyboardGuide('vnc');
      expect(rdp.message.indexOf('三指轻点') >= 0).assertTrue();
      expect(rdp.message.indexOf('虚拟键盘') >= 0).assertTrue();
      expect(vnc.message.indexOf('VNC 控制栏') >= 0).assertTrue();
      expect(vnc.message.indexOf('键盘') >= 0).assertTrue();
    });
  });
}
