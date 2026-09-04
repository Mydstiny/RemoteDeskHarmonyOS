import { describe, it, expect } from '@ohos/hypium';
import {
  normalizeRdpErrorCode,
  RDP_CONNECT_FAILURE_UNCLASSIFIED,
  RDP_SESSION_END_UNCLASSIFIED,
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

    it('server_errorinfo_0x10_should_identify_a_real_remote_dwm_crash', 0, (): void => {
      const model = rdpSessionErrorFromNativeMessage(
        'RDP server ErrorInfo: ERRINFO_SERVER_DWM_CRASH [E-RDP-ERRINFO-0x00000010] The DWM process running in the remote session terminated unexpectedly.',
        RDP_SESSION_END_UNCLASSIFIED,
        RdpSessionErrorSource.TRANSPORT_FAILURE
      );
      expect(model.title).assertEqual('你的会话已断开');
      expect(model.message).assertEqual('远端 Windows 会话中的桌面窗口管理器（DWM）意外终止。');
      expect(model.code).assertEqual('0x10');
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

    it('server_errorinfo_0x01_is_rpc_disconnect_not_graphics_failure', 0, (): void => {
      const model = rdpSessionErrorFromNativeMessage(
        'RDP server ErrorInfo: ERRINFO_RPC_INITIATED_DISCONNECT [E-RDP-ERRINFO-0x00000001] The server initiated a remote disconnect.',
        '0x10'
      );
      expect(model.title).assertEqual('服务器请求断开会话');
      expect(model.message).assertEqual('服务器请求结束当前会话（RPC initiated disconnect）；这不是图形管线故障。');
      expect(model.code).assertEqual('0x01');
      expect(model.source).assertEqual(RdpSessionErrorSource.SERVER_ERROR_INFO);
    });

    it('local_no_frame_watchdog_should_be_recoverable_and_not_a_disconnect', 0, (): void => {
      const model = rdpNoFrameWatchdogError();
      expect(model.title).assertEqual('画面正在恢复');
      expect(model.message).assertEqual('连接仍保持，检测到本地送显暂时受阻，系统正在重试。');
      expect(model.code).assertEqual('RDP-LOCAL-RENDER-STALL');
      expect(model.source).assertEqual(RdpSessionErrorSource.LOCAL_RENDER_WATCHDOG);
    });

    it('connect_failure_without_server_errorinfo_should_not_claim_graphics_driver_failure', 0, (): void => {
      const model = rdpSessionErrorFromNativeMessage(
        'RDP 连接失败或被服务器拒绝：TCP connection failed [E-RDP-STATE-4]',
        RDP_CONNECT_FAILURE_UNCLASSIFIED
      );
      expect(model.title).assertEqual('你的会话已断开');
      expect(model.message).assertEqual('远程会话连接失败；没有收到服务器 ErrorInfo。');
      expect(model.code).assertEqual(RDP_CONNECT_FAILURE_UNCLASSIFIED);
      expect(model.source).assertEqual(RdpSessionErrorSource.CONNECT_FAILURE);
    });

    it('post_connect_transport_failure_should_never_invent_server_errorinfo_0x10', 0, (): void => {
      const model = rdpSessionErrorFromNativeMessage(
        'RDP transport ended after network change [E-RDP-STATE-4]',
        RDP_SESSION_END_UNCLASSIFIED,
        RdpSessionErrorSource.TRANSPORT_FAILURE
      );
      expect(model.message).assertEqual('RDP 连接在客户端或网络侧异常结束；没有收到服务器 ErrorInfo。');
      expect(model.code).assertEqual(RDP_SESSION_END_UNCLASSIFIED);
      expect(model.source).assertEqual(RdpSessionErrorSource.TRANSPORT_FAILURE);
    });

    it('preserves_native_symbolic_code_without_reading_unrelated_hex_flags', 0, (): void => {
      const model = rdpSessionErrorFromNativeMessage(
        'certificate callback flags=0x00000010 rejected [E-RDP-TARGET-CERT] [E-RDP-STATE-4]',
        RDP_CONNECT_FAILURE_UNCLASSIFIED
      );
      expect(model.code).assertEqual('E-RDP-TARGET-CERT');
      expect(model.source).assertEqual(RdpSessionErrorSource.CONNECT_FAILURE);
    });

    it('preserves_freerdp_connection_error_code_without_claiming_server_errorinfo', 0, (): void => {
      const model = rdpSessionErrorFromNativeMessage(
        'FreeRDP 连接错误: ERRCONNECT_CONNECT_FAILED [E-CONN-0x00020006]',
        RDP_CONNECT_FAILURE_UNCLASSIFIED
      );
      expect(model.code).assertEqual('0x20006');
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
      expect(normalizeRdpErrorCode('', RDP_CONNECT_FAILURE_UNCLASSIFIED))
        .assertEqual(RDP_CONNECT_FAILURE_UNCLASSIFIED);
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
