import { expect } from '@ohos/hypium';
import { auditedDescribe as describe, auditedIt as it } from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  RDP_SESSION_CONTROL_ACCENT,
  RDP_SESSION_NEUTRAL_ACCENT,
  normalizeRdpSessionColorDepth,
  normalizeRdpSessionControlMode,
  normalizeRdpSessionDriveName,
  rdpSessionPerformanceSummary,
  rdpSessionSettingActivation
} from '../main/ets/services/RdpSessionSidebarPolicy';

export default function rdpSessionSidebarPolicyTest(): void {
  describe('RdpSessionSidebarPolicy', (): void => {
    it('normalizes_values_shared_by_settings_and_session_sidebar', 0, (): void => {
      expect(normalizeRdpSessionControlMode(2)).assertEqual(2);
      expect(normalizeRdpSessionControlMode(8)).assertEqual(0);
      expect(normalizeRdpSessionColorDepth(16)).assertEqual(16);
      expect(normalizeRdpSessionColorDepth(15)).assertEqual(32);
      expect(normalizeRdpSessionDriveName('My Drive/2026')).assertEqual('My_Drive_2026');
      expect(normalizeRdpSessionDriveName('***')).assertEqual('RemoteDesktop');
    });

    it('distinguishes_live_changes_from_reconnect_preferences', 0, (): void => {
      expect(rdpSessionSettingActivation('rdpControlMode')).assertEqual('live');
      expect(rdpSessionSettingActivation('rdpClipboardEnabled')).assertEqual('reconnect');
      expect(rdpSessionSettingActivation('rdpDesktopResolutionId')).assertEqual('reconnect');
      expect(rdpSessionSettingActivation('rdpAudioEnabled')).assertEqual('reconnect');
      expect(rdpSessionSettingActivation('rdpDriveEnabled')).assertEqual('reconnect');
    });

    it('summarizes_live_transport_health_for_toolbar_and_panel', 0, (): void => {
      const healthy = rdpSessionPerformanceSummary(0, 48, 840, true);
      expect(healthy.status).assertEqual('实时');
      expect(healthy.color).assertEqual(RDP_SESSION_CONTROL_ACCENT);
      expect(healthy.transport).assertEqual('GFX');
      expect(healthy.frameAge).assertEqual('48 ms');
      const stalled = rdpSessionPerformanceSummary(0, 3200, 2500, false);
      expect(stalled.status).assertEqual('画面停滞');
      expect(stalled.transport).assertEqual('GDI');
      const failed = rdpSessionPerformanceSummary(-3, 10, 100, true);
      expect(failed.status).assertEqual('恢复中');
      const pending = rdpSessionPerformanceSummary(0, -1, 0, false);
      expect(pending.status).assertEqual('待采样');
      expect(pending.color).assertEqual(RDP_SESSION_NEUTRAL_ACCENT);
      expect(pending.frameAge).assertEqual('—');
    });
  });
}
