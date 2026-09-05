import { describe, it, expect } from '@ohos/hypium';
import {
  beginRustDeskDisplaySwitchState,
  idleRustDeskDisplaySwitchState,
  observeRustDeskDisplaySwitch,
  releaseRustDeskInputForDisplaySwitch,
  requestRustDeskDisplaySwitch,
  shouldRequestRustDeskDisplaySwitch
} from '../main/ets/services/RustDeskDisplaySwitchPolicy';

export default function rustDeskDisplaySwitchPolicyTest(): void {
  describe('RustDeskDisplaySwitchPolicy', (): void => {
    it('waits_for_the_exact_target_generation_and_keyframe_gate', 0, (): void => {
      const pending = beginRustDeskDisplaySwitchState(true, 4, 2, 1000);
      expect(pending.inputBlocked).assertTrue();

      const stale = observeRustDeskDisplaySwitch(pending, {
        currentDisplay: 2,
        readySwitchGeneration: 3,
        pendingDisplay: -1,
        confirmedDisplay: 0,
        inputBlocked: false
      }, 1100, 5000);
      expect(stale.adoptCapabilities).assertFalse();
      expect(stale.state.inputBlocked).assertTrue();

      const ready = observeRustDeskDisplaySwitch(stale.state, {
        currentDisplay: 2,
        readySwitchGeneration: 4,
        pendingDisplay: -1,
        confirmedDisplay: 2,
        inputBlocked: false
      }, 1200, 5000);
      expect(ready.adoptCapabilities).assertTrue();
      expect(ready.state.inputBlocked).assertFalse();
    });

    it('keeps_only_the_latest_rapid_selection', 0, (): void => {
      const first = beginRustDeskDisplaySwitchState(true, 7, 1, 1000);
      const latest = beginRustDeskDisplaySwitchState(true, 8, 3, 1050);
      const oldReady = observeRustDeskDisplaySwitch(latest, {
        currentDisplay: first.pendingDisplay,
        readySwitchGeneration: first.generation,
        pendingDisplay: -1,
        confirmedDisplay: 0,
        inputBlocked: false
      }, 1100, 5000);
      expect(oldReady.adoptCapabilities).assertFalse();
      expect(oldReady.state.generation).assertEqual(8);
      expect(oldReady.state.pendingDisplay).assertEqual(3);
    });

    it('reports_timeout_once_and_requests_the_confirmed_display_fallback', 0, (): void => {
      const pending = beginRustDeskDisplaySwitchState(true, 2, 1, 1000);
      const timeout = observeRustDeskDisplaySwitch(pending, {
        currentDisplay: 0,
        readySwitchGeneration: 0,
        pendingDisplay: 1,
        confirmedDisplay: 0,
        inputBlocked: true
      }, 7000, 5000);
      expect(timeout.notifyTimeout).assertTrue();
      expect(timeout.state.inputBlocked).assertTrue();
      expect(timeout.fallbackDisplay).assertEqual(0);

      const repeated = observeRustDeskDisplaySwitch(timeout.state, {
        currentDisplay: 0,
        readySwitchGeneration: 0,
        pendingDisplay: 1,
        confirmedDisplay: 0,
        inputBlocked: true
      }, 8000, 5000);
      expect(repeated.notifyTimeout).assertFalse();
      expect(repeated.fallbackDisplay).assertEqual(-1);
      expect(repeated.state.inputBlocked).assertTrue();
    });

    it('allows_the_same_target_to_retry_only_after_timeout', 0, (): void => {
      const pending = beginRustDeskDisplaySwitchState(true, 5, 1, 1000);
      expect(shouldRequestRustDeskDisplaySwitch(pending, 1, 0)).assertFalse();

      const timeout = observeRustDeskDisplaySwitch(pending, {
        currentDisplay: 0,
        readySwitchGeneration: 0,
        pendingDisplay: 1,
        confirmedDisplay: 0,
        inputBlocked: true
      }, 7000, 5000);
      expect(timeout.state.timeoutNotified).assertTrue();
      expect(shouldRequestRustDeskDisplaySwitch(timeout.state, 1, 0)).assertTrue();

      const retried = beginRustDeskDisplaySwitchState(true, 6, 1, 7001);
      expect(retried.generation).assertEqual(6);
      expect(retried.startedAtMs).assertEqual(7001);
      expect(retried.timeoutNotified).assertFalse();
      expect(retried.inputBlocked).assertTrue();
    });

    it('keeps_input_blocked_when_no_confirmed_display_exists_for_fallback', 0, (): void => {
      const pending = beginRustDeskDisplaySwitchState(true, 3, 2, 1000);
      const timeout = observeRustDeskDisplaySwitch(pending, {
        currentDisplay: 2,
        readySwitchGeneration: 0,
        pendingDisplay: 2,
        confirmedDisplay: -1,
        inputBlocked: true
      }, 7000, 5000);
      expect(timeout.notifyTimeout).assertTrue();
      expect(timeout.fallbackDisplay).assertEqual(-1);
      expect(timeout.state.inputBlocked).assertTrue();
    });

    it('releases_all_old_input_before_requesting_a_new_generation', 0, (): void => {
      const effects: string[] = [];
      const outcome = requestRustDeskDisplaySwitch(2, 3000, {
        releaseInput: (): void => {
          releaseRustDeskInputForDisplaySwitch({
            discardPendingMouseMove: (): void => {
              effects.push('discard-move');
            },
            releaseCanvasPinchInput: (): void => {
              effects.push('release-pinch');
            },
            resetTouchGesture: (): void => {
              effects.push('reset-touch');
            },
            releaseAllHeldKeys: (): void => {
              effects.push('release-held');
            },
            clearHeldPointerState: (): void => {
              effects.push('clear-pointer');
            },
            resetAllLatches: (): void => {
              effects.push('reset-latches');
            },
            resetTouchpadState: (): void => {
              effects.push('reset-touchpad');
            },
            invalidateViewport: (): void => {
              effects.push('invalidate-viewport');
            }
          });
        },
        requestDisplay: (display: number) => {
          effects.push('request-' + display.toString());
          return {
            accepted: true,
            generation: 9
          };
        }
      });
      expect(effects.join(',')).assertEqual(
        'discard-move,release-pinch,reset-touch,release-held,clear-pointer,' +
          'reset-latches,reset-touchpad,invalidate-viewport,request-2');
      expect(outcome.state.generation).assertEqual(9);
      expect(outcome.state.inputBlocked).assertTrue();
    });

    it('stays_idle_when_native_rejects_the_request', 0, (): void => {
      const rejected = beginRustDeskDisplaySwitchState(false, 0, 2, 1000);
      expect(rejected.inputBlocked).assertFalse();
      expect(rejected.pendingDisplay).assertEqual(
        idleRustDeskDisplaySwitchState().pendingDisplay);
    });
  });
}
