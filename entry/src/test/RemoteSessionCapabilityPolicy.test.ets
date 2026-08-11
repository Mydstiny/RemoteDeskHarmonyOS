import { describe, it, expect } from '@ohos/hypium';
import { resolveSessionCapabilities } from '../main/ets/services/RemoteSessionCapabilityPolicy';

export default function remoteSessionCapabilityPolicyTest(): void {
  describe('RemoteSessionCapabilityPolicy', (): void => {
    it('vnc_should_offer_rfb_connect_but_not_file_transfer', 0, (): void => {
      const capabilities = resolveSessionCapabilities({
        protocol: 'vnc', connected: false, rdpDriveMounted: false, rdpClipboardEnabled: true,
        rdpClipboardReady: false, sftpConnected: false,
        rustDeskVerifiedPeer: false, rustDeskInboundClipboard: false, rustDeskTransferConfirmed: false,
        vncClipboardEnabled: false, vncClipboardReady: false, vncViewOnly: true
      });
      expect(capabilities.connect.enabled).assertTrue();
      expect(capabilities.fileUpload.enabled).assertFalse();
      expect(capabilities.fileDownload.enabled).assertFalse();
    });

    it('vnc_should_gate_clipboard_by_view_only_and_vnc_setting', 0, (): void => {
      const viewOnly = resolveSessionCapabilities({
        protocol: 'vnc', connected: true, rdpDriveMounted: false, rdpClipboardEnabled: true,
        rdpClipboardReady: false, sftpConnected: false,
        rustDeskVerifiedPeer: false, rustDeskInboundClipboard: false, rustDeskTransferConfirmed: false,
        vncClipboardEnabled: true, vncClipboardReady: true, vncViewOnly: true
      });
      expect(viewOnly.clipboardSend.enabled).assertFalse();
      expect(viewOnly.clipboardReceive.enabled).assertTrue();
      const writable = resolveSessionCapabilities({
        protocol: 'vnc', connected: true, rdpDriveMounted: false, rdpClipboardEnabled: true,
        rdpClipboardReady: false, sftpConnected: false,
        rustDeskVerifiedPeer: false, rustDeskInboundClipboard: false, rustDeskTransferConfirmed: false,
        vncClipboardEnabled: true, vncClipboardReady: true, vncViewOnly: false
      });
      expect(writable.clipboardSend.enabled).assertTrue();
    });

    it('rdp_should_offer_clipboard_upload_without_drive_mount', 0, (): void => {
      const capabilities = resolveSessionCapabilities({
        protocol: 'rdp', connected: true, rdpDriveMounted: false, rdpClipboardEnabled: true,
        rdpClipboardReady: true, sftpConnected: false,
        rustDeskVerifiedPeer: false, rustDeskInboundClipboard: false, rustDeskTransferConfirmed: false,
        vncClipboardEnabled: false, vncClipboardReady: false, vncViewOnly: true
      });
      expect(capabilities.fileUpload.enabled).assertTrue();
      expect(capabilities.fileDownload.enabled).assertFalse();
    });

    it('rdp_should_disable_all_clipboard_capabilities_when_setting_is_off', 0, (): void => {
      const capabilities = resolveSessionCapabilities({
        protocol: 'rdp', connected: true, rdpDriveMounted: true, rdpClipboardEnabled: false,
        rdpClipboardReady: true, sftpConnected: false,
        rustDeskVerifiedPeer: false, rustDeskInboundClipboard: false, rustDeskTransferConfirmed: false,
        vncClipboardEnabled: false, vncClipboardReady: false, vncViewOnly: false
      });
      expect(capabilities.clipboardSend.enabled).assertFalse();
      expect(capabilities.clipboardReceive.enabled).assertFalse();
      expect(capabilities.fileUpload.enabled).assertFalse();
      expect(capabilities.fileDownload.enabled).assertTrue();
    });

    it('rdp_should_not_offer_clipboard_send_before_cliprdr_is_ready', 0, (): void => {
      const capabilities = resolveSessionCapabilities({
        protocol: 'rdp', connected: true, rdpDriveMounted: false, rdpClipboardEnabled: true,
        rdpClipboardReady: false, sftpConnected: false,
        rustDeskVerifiedPeer: false, rustDeskInboundClipboard: false, rustDeskTransferConfirmed: false,
        vncClipboardEnabled: false, vncClipboardReady: false, vncViewOnly: false
      });
      expect(capabilities.clipboardSend.enabled).assertFalse();
      expect(capabilities.clipboardReceive.enabled).assertFalse();
      expect(capabilities.fileUpload.enabled).assertFalse();
    });

    it('ssh_should_offer_sftp_upload_and_download_only_after_sftp_connects', 0, (): void => {
      const capabilities = resolveSessionCapabilities({
        protocol: 'ssh', connected: true, rdpDriveMounted: false, rdpClipboardEnabled: true,
        rdpClipboardReady: false, sftpConnected: true,
        rustDeskVerifiedPeer: false, rustDeskInboundClipboard: false, rustDeskTransferConfirmed: false,
        vncClipboardEnabled: false, vncClipboardReady: false, vncViewOnly: true
      });
      expect(capabilities.fileUpload.enabled).assertTrue();
      expect(capabilities.fileDownload.enabled).assertTrue();
    });

    it('rustdesk_should_require_an_inbound_clipboard_callback_to_receive_text', 0, (): void => {
      const capabilities = resolveSessionCapabilities({
        protocol: 'rustdesk', connected: true, rdpDriveMounted: false, rdpClipboardEnabled: true,
        rdpClipboardReady: false, sftpConnected: false,
        rustDeskVerifiedPeer: true, rustDeskInboundClipboard: false, rustDeskTransferConfirmed: false,
        vncClipboardEnabled: false, vncClipboardReady: false, vncViewOnly: true
      });
      expect(capabilities.clipboardSend.enabled).assertTrue();
      expect(capabilities.clipboardReceive.enabled).assertFalse();
      expect(capabilities.fileUpload.enabled).assertFalse();
    });

    it('rustdesk_should_expose_display_control_after_native_catalog_is_ready', 0, (): void => {
      const capabilities = resolveSessionCapabilities({
        protocol: 'rustdesk', connected: true, rdpDriveMounted: false, rdpClipboardEnabled: true,
        rdpClipboardReady: false, sftpConnected: false,
        rustDeskVerifiedPeer: true, rustDeskInboundClipboard: true, rustDeskTransferConfirmed: true,
        rustDeskDisplaySupported: true,
        vncClipboardEnabled: false, vncClipboardReady: false, vncViewOnly: true
      });
      expect(capabilities.multiDisplay.enabled).assertTrue();
    });

    it('moonlight_should_keep_common_capabilities_closed_until_runtime_and_host_control_are_ready',
      0, (): void => {
        const blocked = resolveSessionCapabilities({
          protocol: 'moonlight', connected: true, rdpDriveMounted: false,
          rdpClipboardEnabled: false, rdpClipboardReady: false, sftpConnected: false,
          rustDeskVerifiedPeer: false, rustDeskInboundClipboard: false,
          rustDeskTransferConfirmed: false, vncClipboardEnabled: false,
          vncClipboardReady: false, vncViewOnly: false
        });
        expect(blocked.connect.enabled).assertFalse();
        expect(blocked.fileUpload.enabled).assertFalse();
        expect(blocked.multiDisplay.enabled).assertFalse();
        const ready = resolveSessionCapabilities({
          protocol: 'moonlight', connected: true, rdpDriveMounted: false,
          rdpClipboardEnabled: false, rdpClipboardReady: false, sftpConnected: false,
          rustDeskVerifiedPeer: false, rustDeskInboundClipboard: false,
          rustDeskTransferConfirmed: false, vncClipboardEnabled: false,
          vncClipboardReady: false, vncViewOnly: false,
          moonlightRuntimeAvailable: true, moonlightHostControlReady: true
        });
        expect(ready.connect.enabled).assertTrue();
        expect(ready.clipboardSend.enabled).assertFalse();
        expect(ready.fileDownload.enabled).assertFalse();
      });
  });
}
