import { describe, it, expect } from '@ohos/hypium';
import {
  beginVncDisplaySwitchState,
  idleVncDisplaySwitchState,
  observeVncDisplaySwitch,
  releaseVncInputForDisplaySwitch,
  shouldRequestVncDisplaySwitch,
  vncMonitorLabel
} from '../main/ets/services/VncDisplaySwitchPolicy';

export default function vncDisplaySwitchPolicyTest(): void {
  describe('VncDisplaySwitchPolicy', (): void => {
    it('waits_for_the_target_frame_after_a_generation_request', 0, (): void => {
      const pending = beginVncDisplaySwitchState(true, 4, 1, 1000);
      const stale = observeVncDisplaySwitch(pending, {
        currentMonitor: 0, pendingMonitor: 1, switchGeneration: 4,
        inputBlocked: true, lastResult: 'requested'
      }, 1100, 5000);
      expect(stale.adopt).assertFalse();
      const ready = observeVncDisplaySwitch(stale.state, {
        currentMonitor: 1, pendingMonitor: -1, switchGeneration: 4,
        inputBlocked: false, lastResult: 'confirmed'
      }, 1200, 5000);
      expect(ready.adopt).assertTrue();
      expect(ready.state.inputBlocked).assertFalse();
    });

    it('serializes_target_and_reports_timeout_once', 0, (): void => {
      const first = beginVncDisplaySwitchState(true, 7, 1, 1000);
      const latest = beginVncDisplaySwitchState(true, 8, 2, 1050);
      const stale = observeVncDisplaySwitch(latest, {
        currentMonitor: 1, pendingMonitor: -1, switchGeneration: 7,
        inputBlocked: false, lastResult: 'confirmed'
      }, 1100, 5000);
      expect(stale.adopt).assertFalse();
      expect(stale.state.generation).assertEqual(8);
      expect(stale.state.pendingMonitor).assertEqual(2);
      const timeout = observeVncDisplaySwitch(first, {
        currentMonitor: 0, pendingMonitor: 1, switchGeneration: 7,
        inputBlocked: true, lastResult: 'requested'
      }, 7000, 5000);
      expect(timeout.notifyTimeout).assertTrue();
      const repeated = observeVncDisplaySwitch(timeout.state, {
        currentMonitor: 0, pendingMonitor: 1, switchGeneration: 7,
        inputBlocked: true, lastResult: 'requested'
      }, 8000, 5000);
      expect(repeated.notifyTimeout).assertFalse();
      expect(shouldRequestVncDisplaySwitch(timeout.state, 1, 0)).assertTrue();
      expect(shouldRequestVncDisplaySwitch(timeout.state, 2, 0)).assertFalse();
    });

    it('blocks_same_target_until_timeout_and_releases_input_in_order', 0, (): void => {
      const pending = beginVncDisplaySwitchState(true, 3, 1, 1000);
      expect(shouldRequestVncDisplaySwitch(pending, 1, 0)).assertFalse();
      const effects: string[] = [];
      releaseVncInputForDisplaySwitch({
        discardPendingMouseMove: (): void => { effects.push('move'); },
        releaseCanvasPinchInput: (): void => { effects.push('pinch'); },
        resetTouchGesture: (): void => { effects.push('touch'); },
        releaseAllHeldKeys: (): void => { effects.push('keys'); },
        clearHeldPointerState: (): void => { effects.push('pointer'); },
        resetAllLatches: (): void => { effects.push('latches'); },
        resetTouchpadState: (): void => { effects.push('touchpad'); },
        invalidateViewport: (): void => { effects.push('viewport'); }
      });
      expect(effects.join(',')).assertEqual(
        'move,pinch,touch,keys,pointer,latches,touchpad,viewport');
      expect(vncMonitorLabel(0)).assertEqual('显示器 1');
    });

    it('rejects_invalid_requests_to_idle_state', 0, (): void => {
      const rejected = beginVncDisplaySwitchState(false, 0, 2, 1000);
      expect(rejected.generation).assertEqual(idleVncDisplaySwitchState().generation);
      expect(rejected.pendingMonitor).assertEqual(-1);
    });
  });
}
