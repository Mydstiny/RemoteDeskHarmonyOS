import { describe, it, expect } from '@ohos/hypium';
import {
  formatDiagnosticBitrate,
  formatDiagnosticBytes,
  formatDiagnosticDurationUs,
  formatDiagnosticLatency,
  formatDiagnosticRate,
  rustDeskCodecLabel,
  shouldEnableRustDeskPro,
  shouldShowRustDeskDiagnostics
} from '../../../main/ets/services/RustDeskDiagnosticsPolicy';

export default function rustDeskDiagnosticsPolicyTest(): void {
  describe('RustDeskDiagnosticsPolicy', (): void => {
    it('diagnostics_requires_a_connected_rustdesk_session', 0, (): void => {
      expect(shouldShowRustDeskDiagnostics(false, true, 'rustdesk', 1)).assertEqual(false);
      expect(shouldShowRustDeskDiagnostics(true, false, 'rustdesk', 1)).assertEqual(false);
      expect(shouldShowRustDeskDiagnostics(true, true, 'rdp', 1)).assertEqual(false);
      expect(shouldShowRustDeskDiagnostics(true, true, 'rustdesk', 1)).assertEqual(true);
    });

    it('pro_is_a_child_switch_of_basic_diagnostics', 0, (): void => {
      expect(shouldEnableRustDeskPro(false, true)).assertEqual(false);
      expect(shouldEnableRustDeskPro(true, false)).assertEqual(false);
      expect(shouldEnableRustDeskPro(true, true)).assertEqual(true);
    });

    it('formats_unavailable_and_rate_boundaries_without_nan', 0, (): void => {
      expect(formatDiagnosticRate(0)).assertEqual('—');
      expect(formatDiagnosticRate(NaN)).assertEqual('—');
      expect(formatDiagnosticRate(Infinity)).assertEqual('—');
      expect(formatDiagnosticLatency(-1)).assertEqual('—');
      expect(formatDiagnosticBitrate(999)).assertEqual('999 Kbps');
      expect(formatDiagnosticBitrate(1000)).assertEqual('1.0 Mbps');
      expect(formatDiagnosticBytes(0)).assertEqual('—');
      expect(formatDiagnosticDurationUs(0)).assertEqual('—');
    });

    it('uses_the_public_codec_numbering_for_hud_labels', 0, (): void => {
      expect(rustDeskCodecLabel(0)).assertEqual('H264');
      expect(rustDeskCodecLabel(1)).assertEqual('H265');
      expect(rustDeskCodecLabel(2)).assertEqual('VP8');
      expect(rustDeskCodecLabel(3)).assertEqual('VP9');
      expect(rustDeskCodecLabel(4)).assertEqual('AV1');
      expect(rustDeskCodecLabel(-1)).assertEqual('—');
    });
  });
}
