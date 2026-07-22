import { describe, it, expect } from '@ohos/hypium';
import {
  holdingHandStatusFromOperatingHandStatus,
  shouldIgnoreActivityMotionForHoldingHand,
  shouldFallbackToOperatingHandOnSubscribeFailure,
  shouldMarkGripMonitorStaleAfterWatchdog,
  shouldRebindGripMonitorOnPageShow,
  shouldRunForegroundSensor,
  shouldRestartGripMonitor,
  shouldUseGripFabAlignment,
  shouldUseGripMonitor
} from '../main/ets/services/GripMonitorLifecyclePolicy';

export default function gripMonitorLifecyclePolicyTest() {
  describe('GripMonitorLifecyclePolicy', (): void => {
    it('restarts_monitor_when_page_returns_with_permission', 0, (): void => {
      expect(shouldRestartGripMonitor(true, false, true)).assertTrue();
    });

    it('does_not_register_twice', 0, (): void => {
      expect(shouldRestartGripMonitor(true, true, true)).assertFalse();
    });

    it('rebinds_registered_monitor_on_page_show_to_clear_stale_system_listener', 0, (): void => {
      expect(shouldRebindGripMonitorOnPageShow(true, true, true)).assertTrue();
      expect(shouldRebindGripMonitorOnPageShow(false, true, true)).assertFalse();
      expect(shouldRebindGripMonitorOnPageShow(true, false, true)).assertFalse();
      expect(shouldRebindGripMonitorOnPageShow(true, true, false)).assertFalse();
    });

    it('does_not_block_holding_hand_monitor_when_activity_motion_is_denied', 0, (): void => {
      expect(shouldIgnoreActivityMotionForHoldingHand(true, false)).assertTrue();
      expect(shouldIgnoreActivityMotionForHoldingHand(true, true)).assertTrue();
      expect(shouldIgnoreActivityMotionForHoldingHand(false, true)).assertFalse();
    });

    it('falls_back_to_operating_hand_when_holding_subscription_is_unavailable', 0, (): void => {
      expect(shouldFallbackToOperatingHandOnSubscribeFailure(801)).assertTrue();
      expect(shouldFallbackToOperatingHandOnSubscribeFailure(31500002)).assertTrue();
      expect(shouldFallbackToOperatingHandOnSubscribeFailure(201)).assertFalse();
    });

    it('maps_operating_hand_status_to_fab_holding_alignment_status', 0, (): void => {
      expect(holdingHandStatusFromOperatingHandStatus(1, 16)).assertEqual(1);
      expect(holdingHandStatusFromOperatingHandStatus(2, 16)).assertEqual(2);
      expect(holdingHandStatusFromOperatingHandStatus(0, 3)).assertEqual(3);
    });

    it('marks_registered_monitor_stale_when_watchdog_gets_no_callback', 0, (): void => {
      expect(shouldMarkGripMonitorStaleAfterWatchdog(true, true, 0)).assertTrue();
      expect(shouldMarkGripMonitorStaleAfterWatchdog(true, true, 1)).assertFalse();
      expect(shouldMarkGripMonitorStaleAfterWatchdog(true, false, 0)).assertFalse();
    });

    it('uses_grip_alignment_only_on_non_pc_devices', 0, (): void => {
      expect(shouldUseGripFabAlignment(true, 'xl')).assertFalse();
      expect(shouldUseGripFabAlignment(true, 'sm')).assertFalse();
      expect(shouldUseGripFabAlignment(false, 'sm')).assertTrue();
      expect(shouldUseGripFabAlignment(false, 'md')).assertTrue();
    });

    it('starts_grip_monitor_only_on_non_pc_devices', 0, (): void => {
      expect(shouldUseGripMonitor(true)).assertFalse();
      expect(shouldUseGripMonitor(false)).assertTrue();
    });

    it('runs_foreground_sensors_only_when_page_is_active_and_app_is_foreground', 0, (): void => {
      expect(shouldRunForegroundSensor(true, false, true)).assertTrue();
      expect(shouldRunForegroundSensor(true, true, true)).assertFalse();
      expect(shouldRunForegroundSensor(false, false, true)).assertFalse();
      expect(shouldRunForegroundSensor(true, false, false)).assertFalse();
    });
  });
}
