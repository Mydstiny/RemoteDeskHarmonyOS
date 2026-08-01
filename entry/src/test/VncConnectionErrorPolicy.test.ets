import { describe, it, expect } from '@ohos/hypium';
import { diagnoseVncConnectionError } from '../main/ets/services/VncConnectionErrorPolicy';

export default function vncConnectionErrorPolicyTest(): void {
  describe('VncConnectionErrorPolicy', (): void => {
    it('diagnoses_mac_plain_vnc_password_rejection', 0, (): void => {
      const diagnosis = diagnoseVncConnectionError('VNC security authentication failed');
      expect(diagnosis.code).assertEqual('E-VNC-AUTH-PASSWORD');
      expect(diagnosis.detail.indexOf('VNC viewers may control screen with password') >= 0).assertTrue();
    });

    it('diagnoses_tls_plain_rfb_mismatch', 0, (): void => {
      const diagnosis = diagnoseVncConnectionError('error:0A00010B:SSL routines::wrong version number');
      expect(diagnosis.code).assertEqual('E-VNC-TLS-VERSION');
    });

    it('keeps_unknown_native_detail_without_cross_protocol_mapping', 0, (): void => {
      const diagnosis = diagnoseVncConnectionError('socket operation timed out');
      expect(diagnosis.code).assertEqual('E-VNC-CONNECTION');
      expect(diagnosis.detail).assertEqual('socket operation timed out');
    });
  });
}
