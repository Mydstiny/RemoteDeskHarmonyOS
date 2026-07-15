import { describe, it, expect } from '@ohos/hypium';
import { shouldInitializeRemoteVideoDecoder } from '../main/ets/services/RemoteVideoDecoderPolicy';

export default function remoteVideoDecoderPolicyTest(): void {
  describe('RemoteVideoDecoderPolicy', (): void => {
    it('rustdesk_should_create_the_shared_video_decoder', 0, (): void => {
      expect(shouldInitializeRemoteVideoDecoder('rustdesk')).assertTrue();
    });

    it('rdp_should_use_its_own_gdi_or_rdpgfx_pipeline', 0, (): void => {
      expect(shouldInitializeRemoteVideoDecoder('rdp')).assertFalse();
    });

    it('non_video_protocols_should_not_create_a_decoder', 0, (): void => {
      expect(shouldInitializeRemoteVideoDecoder('ssh')).assertFalse();
      expect(shouldInitializeRemoteVideoDecoder('vnc')).assertFalse();
    });
  });
}
