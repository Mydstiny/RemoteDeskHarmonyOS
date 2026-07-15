import { describe, it, expect } from '@ohos/hypium';
import { resolveSessionCapabilities } from '../main/ets/services/RemoteSessionCapabilityPolicy';

export default function remoteSessionCapabilityPolicyTest(): void {
  describe('RemoteSessionCapabilityPolicy', (): void => {
    it('vnc_should_never_offer_a_connectable_session', 0, (): void => {
      const capabilities = resolveSessionCapabilities({
        protocol: 'vnc', connected: false, rdpDriveMounted: false, rdpClipboardReady: false, sftpConnected: false,
        rustDeskVerifiedPeer: false, rustDeskInboundClipboard: false, rustDeskTransferConfirmed: false
      });
      expect(capabilities.connect.enabled).assertFalse();
      expect(capabilities.connect.reason).assertEqual('当前版本尚未提供 VNC 连接支持');
    });

    it('rdp_should_offer_clipboard_upload_without_drive_mount', 0, (): void => {
      const capabilities = resolveSessionCapabilities({
        protocol: 'rdp', connected: true, rdpDriveMounted: false, rdpClipboardReady: true, sftpConnected: false,
        rustDeskVerifiedPeer: false, rustDeskInboundClipboard: false, rustDeskTransferConfirmed: false
      });
      expect(capabilities.fileUpload.enabled).assertTrue();
      expect(capabilities.fileDownload.enabled).assertFalse();
    });

    it('ssh_should_offer_sftp_upload_and_download_only_after_sftp_connects', 0, (): void => {
      const capabilities = resolveSessionCapabilities({
        protocol: 'ssh', connected: true, rdpDriveMounted: false, rdpClipboardReady: false, sftpConnected: true,
        rustDeskVerifiedPeer: false, rustDeskInboundClipboard: false, rustDeskTransferConfirmed: false
      });
      expect(capabilities.fileUpload.enabled).assertTrue();
      expect(capabilities.fileDownload.enabled).assertTrue();
    });

    it('rustdesk_should_require_an_inbound_clipboard_callback_to_receive_text', 0, (): void => {
      const capabilities = resolveSessionCapabilities({
        protocol: 'rustdesk', connected: true, rdpDriveMounted: false, rdpClipboardReady: false, sftpConnected: false,
        rustDeskVerifiedPeer: true, rustDeskInboundClipboard: false, rustDeskTransferConfirmed: false
      });
      expect(capabilities.clipboardSend.enabled).assertTrue();
      expect(capabilities.clipboardReceive.enabled).assertFalse();
      expect(capabilities.fileUpload.enabled).assertFalse();
    });
  });
}
