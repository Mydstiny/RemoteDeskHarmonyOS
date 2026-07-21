import { describe, it, expect } from '@ohos/hypium';
import {
  formatDiagnosticBitrate,
  formatDiagnosticBytes,
  formatDiagnosticDurationUs,
  formatDiagnosticFrameRate,
  formatDiagnosticLatency,
  formatDiagnosticRate,
  resolveRustDeskProDiagnosticsToggle,
  rustDeskDiagnosticsStreamState,
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

    it('pro_is_active_only_with_basic_diagnostics', 0, (): void => {
      expect(shouldEnableRustDeskPro(false, true)).assertEqual(false);
      expect(shouldEnableRustDeskPro(true, false)).assertEqual(false);
      expect(shouldEnableRustDeskPro(true, true)).assertEqual(true);
    });

    it('enabling_pro_also_enables_the_base_monitor', 0, (): void => {
      const enabled = resolveRustDeskProDiagnosticsToggle(false, false, true);
      expect(enabled.showDiagnostics).assertEqual(true);
      expect(enabled.showProDiagnostics).assertEqual(true);

      const disabled = resolveRustDeskProDiagnosticsToggle(true, true, false);
      expect(disabled.showDiagnostics).assertEqual(true);
      expect(disabled.showProDiagnostics).assertEqual(false);
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

    it('keeps_video_sampling_stall_and_unavailable_states_distinct', 0, (): void => {
      expect(formatDiagnosticFrameRate(0, false, false, false)).assertEqual('等待视频流');
      expect(formatDiagnosticFrameRate(0, false, true, false)).assertEqual('采样中');
      expect(formatDiagnosticFrameRate(0, false, true, true)).assertEqual('已停滞');
      expect(formatDiagnosticFrameRate(0, true, true, true)).assertEqual('已停滞');
      expect(formatDiagnosticFrameRate(0, true, true, false)).assertEqual('0.0');
      expect(rustDeskDiagnosticsStreamState(false, -1)).assertEqual('等待视频流');
      expect(rustDeskDiagnosticsStreamState(true, 2999)).assertEqual('正在接收');
      expect(rustDeskDiagnosticsStreamState(true, 3000)).assertEqual('已停滞');
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
