import { describe, it, expect } from '@ohos/hypium';
import {
  normalizeRdpErrorCode,
  rdpNoFrameWatchdogError,
  rdpSessionErrorFromNativeMessage,
  rdpSessionErrorSheetPrefersLandscapeCenter,
  RdpSessionErrorSource,
  shouldCleanupRdpSessionBeforeErrorDismiss,
  shouldShowRdpSessionErrorAfterControlPanelDismiss
} from '../main/ets/services/RdpSessionErrorPolicy';

export default function rdpSessionErrorPolicyTest() {
  describe('RdpSessionErrorPolicy', (): void => {
    it('server_errorinfo_0x11_should_match_microsoft_graphics_driver_dialog', 0, (): void => {
      const model = rdpSessionErrorFromNativeMessage(
        'RDP server ErrorInfo: ERRINFO_CLOSE_STACK_ON_DRIVER_FAILURE [E-RDP-ERRINFO-0x00000011] The display driver in the remote session was unable to complete all the tasks required for startup.',
        '0x10'
      );
      expect(model.title).assertEqual('你的会话已断开');
      expect(model.message).assertEqual('远程会话中的图形显示组件启动失败。');
      expect(model.code).assertEqual('0x11');
      expect(model.source).assertEqual(RdpSessionErrorSource.SERVER_ERROR_INFO);
    });

    it('server_errorinfo_0x112f_should_not_be_collapsed_to_0x11', 0, (): void => {
      const model = rdpSessionErrorFromNativeMessage(
        'RDP server ErrorInfo: ERRINFO_GRAPHICS_SUBSYSTEM_FAILED [E-RDP-ERRINFO-0x0000112F] The server-side graphics subsystem is in an error state and unable to continue graphics encoding.',
        '0x10'
      );
      expect(model.title).assertEqual('你的会话已断开');
      expect(model.message).assertEqual('远程会话图形子系统出现错误，无法继续图形编码。');
      expect(model.code).assertEqual('0x112F');
      expect(model.source).assertEqual(RdpSessionErrorSource.SERVER_ERROR_INFO);
    });

    it('local_no_frame_watchdog_should_remain_fallback_0x11', 0, (): void => {
      const model = rdpNoFrameWatchdogError();
      expect(model.title).assertEqual('你的会话已断开');
      expect(model.message).assertEqual('远程会话中的图形显示组件启动失败。');
      expect(model.code).assertEqual('0x11');
      expect(model.source).assertEqual(RdpSessionErrorSource.LOCAL_RENDER_WATCHDOG);
    });

    it('connect_failure_without_server_errorinfo_should_not_claim_graphics_driver_failure', 0, (): void => {
      const model = rdpSessionErrorFromNativeMessage(
        'RDP 连接失败或被服务器拒绝：TCP connection failed [E-RDP-STATE-4]',
        '0x10'
      );
      expect(model.title).assertEqual('你的会话已断开');
      expect(model.message).assertEqual('远程会话连接失败。');
      expect(model.code).assertEqual('0x10');
      expect(model.source).assertEqual(RdpSessionErrorSource.CONNECT_FAILURE);
    });

    it('restricted_admin_secret_required_should_keep_a_specific_user_action', 0, (): void => {
      const model = rdpSessionErrorFromNativeMessage(
        '此设备未保存该 Restricted Admin 主机的 NTLM Hash，请重新输入 [E-RDP-AUTH-SECRET-REQUIRED]',
        '0x10'
      );
      expect(model.code).assertEqual('E-RDP-AUTH-SECRET-REQUIRED');
      expect(model.message).assertEqual('本机没有保存该主机的 NTLM Hash，请在主机编辑中重新输入。');
      expect(model.source).assertEqual(RdpSessionErrorSource.CONNECT_FAILURE);
    });

    it('restricted_admin_identity_mismatch_should_not_be_collapsed_to_generic_failure', 0, (): void => {
      const model = rdpSessionErrorFromNativeMessage(
        '主机地址或用户名已改变，请重新输入 NTLM Hash [E-RDP-AUTH-IDENTITY-MISMATCH]',
        '0x10'
      );
      expect(model.code).assertEqual('E-RDP-AUTH-IDENTITY-MISMATCH');
      expect(model.message).assertEqual('主机地址、用户名或登录身份模式已改变，请重新输入该主机的 NTLM Hash。');
    });

    it('normalize_should_shorten_8_digit_server_codes_for_dialog', 0, (): void => {
      expect(normalizeRdpErrorCode('0x00000011', '0x10')).assertEqual('0x11');
      expect(normalizeRdpErrorCode('0x0000112F', '0x10')).assertEqual('0x112F');
      expect(normalizeRdpErrorCode('', '0x10')).assertEqual('0x10');
    });

    it('error_sheet_should_wait_for_user_disconnect_before_cleanup', 0, (): void => {
      expect(shouldCleanupRdpSessionBeforeErrorDismiss()).assertFalse();
    });

    it('error_sheet_should_defer_until_control_panel_dismisses_when_panel_visible', 0, (): void => {
      expect(shouldShowRdpSessionErrorAfterControlPanelDismiss(true)).assertTrue();
      expect(shouldShowRdpSessionErrorAfterControlPanelDismiss(false)).assertFalse();
    });

    it('rdp_error_sheet_should_prefer_landscape_center_layout', 0, (): void => {
      expect(rdpSessionErrorSheetPrefersLandscapeCenter(true)).assertTrue();
      expect(rdpSessionErrorSheetPrefersLandscapeCenter(false)).assertFalse();
    });
  });
}
