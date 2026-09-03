import { describe, it, expect } from '@ohos/hypium';
import {
  normalizeRdpRemoteUiScalePreference,
  rdpSessionOrientationPolicy,
  RDP_DYNAMIC_LAYOUT_SETTLE_MS,
  rdpCursorPositionRevisionAfterGeometryChange,
  rdpRendererAttachStabilityDelayMs,
  releaseRdpInputForGeometryChange,
  resumeRdpGeometryAfterRendererAttach,
  resolveRdpAdaptiveDisplay,
  resolveConfirmedRdpDesktopGeometry,
  resolveRdpDisplaySourceId,
  resolveRdpInputGeometryObservation,
  resolveRdpInputReadinessTransition,
  resolveRdpRemoteUiScale,
  shouldAttemptInitialRdpDynamicUpgrade,
  shouldPreserveLiveRdpGeometry,
  shouldUseRdpPcAdaptiveDisplay
} from '../main/ets/services/RdpAdaptiveDisplayPolicy';
import { RemoteModifierStateController } from '../main/ets/services/RemoteModifierStateController';

export default function rdpAdaptiveDisplayPolicyTest(): void {
  describe('RdpAdaptiveDisplayPolicy', (): void => {
    it('maps_density_to_windows_compatible_scale_factors', 0, (): void => {
      expect(resolveRdpRemoteUiScale('auto', 1)).assertEqual(100);
      expect(resolveRdpRemoteUiScale('auto', 1.25)).assertEqual(140);
      expect(resolveRdpRemoteUiScale('auto', 1.5)).assertEqual(140);
      expect(resolveRdpRemoteUiScale('auto', 2)).assertEqual(180);
      expect(resolveRdpRemoteUiScale('100', 2)).assertEqual(100);
      expect(normalizeRdpRemoteUiScalePreference('175')).assertEqual('auto');
    });

    it('limits_the_new_adaptive_contract_to_pc_auto_sessions', 0, (): void => {
      expect(shouldUseRdpPcAdaptiveDisplay(true, 'auto')).assertTrue();
      expect(shouldUseRdpPcAdaptiveDisplay(false, 'auto')).assertFalse();
      expect(shouldUseRdpPcAdaptiveDisplay(true, '1920x1080')).assertFalse();
      expect(rdpSessionOrientationPolicy(true, 'auto')).assertEqual('unspecified');
      expect(rdpSessionOrientationPolicy(false, 'auto')).assertEqual('landscape');
      expect(rdpSessionOrientationPolicy(true, '1920x1080')).assertEqual('landscape');
    });

    it('uses_the_window_display_and_attempts_initial_upgrade_once', 0, (): void => {
      expect(resolveRdpDisplaySourceId(7, 1)).assertEqual(7);
      expect(resolveRdpDisplaySourceId(-1, 1)).assertEqual(1);
      expect(shouldAttemptInitialRdpDynamicUpgrade(true, false, 0)).assertTrue();
      expect(shouldAttemptInitialRdpDynamicUpgrade(true, false, 1)).assertFalse();
      expect(shouldAttemptInitialRdpDynamicUpgrade(false, false, 0)).assertFalse();
      expect(shouldAttemptInitialRdpDynamicUpgrade(true, true, 0)).assertFalse();
    });

    it('adopts_only_a_renderer_and_freerdp_confirmed_desktop_geometry', 0, (): void => {
      const upgraded = resolveConfirmedRdpDesktopGeometry(2880, 1800, 2880, 1800);
      expect(upgraded === null).assertFalse();
      expect(upgraded?.width).assertEqual(2880);
      expect(upgraded?.height).assertEqual(1800);

      // During cbDesktopResize the renderer and completed lifecycle may be on
      // opposite sides of the transaction. Input must retain the old space.
      expect(resolveConfirmedRdpDesktopGeometry(2880, 1800, 1600, 1000) === null).assertTrue();
      expect(resolveConfirmedRdpDesktopGeometry(0, 1800, 2880, 1800) === null).assertTrue();
      expect(resolveConfirmedRdpDesktopGeometry(20000, 1800, 20000, 1800) === null).assertTrue();
    });

    it('fences_input_from_resize_mismatch_until_the_current_attempt_is_confirmed', 0, (): void => {
      const mismatch = resolveRdpInputGeometryObservation(
        9, 3, 9, 3, 2880, 1800, 1600, 1000,
        1600, 1000, false, true, true, false, true);
      expect(mismatch.status).assertEqual('pending');
      expect(mismatch.inputReady).assertFalse();

      // Both producers can still expose the old geometry while Display
      // Control is in flight. That is not permission to reopen input.
      const oldWhileQueued = resolveRdpInputGeometryObservation(
        9, 3, 9, 3, 1600, 1000, 1600, 1000,
        1600, 1000, true, false, false, true, true);
      expect(oldWhileQueued.status).assertEqual('pending');

      const confirmed = resolveRdpInputGeometryObservation(
        9, 3, 9, 3, 2880, 1800, 2880, 1800,
        1600, 1000, false, false, false, true, true);
      expect(confirmed.status).assertEqual('confirmed');
      expect(confirmed.geometryChanged).assertTrue();
      expect(confirmed.inputReady).assertTrue();
    });

    it('ignores_old_attempts_and_keeps_fixed_geometry_behind_the_stability_gate', 0,
      (): void => {
        const stale = resolveRdpInputGeometryObservation(
          11, 5, 11, 4, 1920, 1080, 1920, 1080,
          1920, 1080, false, false, false, true, true);
        expect(stale.status).assertEqual('stale');

        const fixedBeforeVideoStable = resolveRdpInputGeometryObservation(
          11, 5, 11, 5, 1920, 1080, 1920, 1080,
          1920, 1080, false, false, false, true, false);
        expect(fixedBeforeVideoStable.status).assertEqual('confirmed');
        expect(fixedBeforeVideoStable.geometryChanged).assertFalse();
        expect(fixedBeforeVideoStable.inputReady).assertFalse();
      });

    it('keeps_native_resize_authoritative_when_local_pending_state_is_lost', 0,
      (): void => {
        const reattachedWhileSent = resolveRdpInputGeometryObservation(
          31, 8, 31, 8, 1600, 1000, 1600, 1000,
          1600, 1000, false, true, false, true, true);
        expect(reattachedWhileSent.status).assertEqual('pending');

        const followUpQueuedAfterFirstCompletion = resolveRdpInputGeometryObservation(
          31, 8, 31, 8, 2560, 1600, 2560, 1600,
          1600, 1000, true, false, false, false, true);
        expect(followUpQueuedAfterFirstCompletion.status).assertEqual('pending');

        const firstInFlightAfterFollowUpCancel = resolveRdpInputGeometryObservation(
          31, 8, 31, 8, 1600, 1000, 1600, 1000,
          1600, 1000, false, true, false, true, true);
        expect(firstInFlightAfterFollowUpCancel.status).assertEqual('pending');

        const unsolicitedResize = resolveRdpInputGeometryObservation(
          31, 8, 31, 8, 1600, 1000, 1600, 1000,
          1600, 1000, false, false, true, false, true);
        expect(unsolicitedResize.status).assertEqual('pending');
      });

    it('retains_the_cold_stability_wait_only_for_a_fresh_independent_window', 0,
      (): void => {
        expect(rdpRendererAttachStabilityDelayMs('window-1', false)).assertEqual(2000);
        expect(rdpRendererAttachStabilityDelayMs('window-1', true)).assertEqual(0);
        expect(rdpRendererAttachStabilityDelayMs('', false)).assertEqual(0);
      });

    it('publishes_independent_window_ready_when_the_last_rdp_barrier_opens', 0,
      (): void => {
        const stabilityFirst = resolveRdpInputReadinessTransition(
          false, true, 21, true, false);
        expect(stabilityFirst.inputReady).assertFalse();
        expect(stabilityFirst.becameReady).assertFalse();
        const geometryLast = resolveRdpInputReadinessTransition(
          stabilityFirst.inputReady, true, 21, true, true);
        expect(geometryLast.inputReady).assertTrue();
        expect(geometryLast.becameReady).assertTrue();
        const stabilityFirstSteady = resolveRdpInputReadinessTransition(
          geometryLast.inputReady, true, 21, true, true);
        expect(stabilityFirstSteady.becameReady).assertFalse();

        const geometryFirst = resolveRdpInputReadinessTransition(
          false, true, 22, false, true);
        expect(geometryFirst.inputReady).assertFalse();
        expect(geometryFirst.becameReady).assertFalse();
        const stabilityLast = resolveRdpInputReadinessTransition(
          geometryFirst.inputReady, true, 22, true, true);
        expect(stabilityLast.inputReady).assertTrue();
        expect(stabilityLast.becameReady).assertTrue();
        const geometryFirstSteady = resolveRdpInputReadinessTransition(
          stabilityLast.inputReady, true, 22, true, true);
        expect(geometryFirstSteady.becameReady).assertFalse();
      });

    it('preserves_live_handoff_geometry_and_reobserves_a_static_cursor_revision', 0,
      (): void => {
        expect(shouldPreserveLiveRdpGeometry('rdp', true, 21)).assertTrue();
        expect(shouldPreserveLiveRdpGeometry('rdp', false, 21)).assertFalse();
        expect(shouldPreserveLiveRdpGeometry('vnc', true, 21)).assertFalse();
        expect(rdpCursorPositionRevisionAfterGeometryChange(17, true)).assertEqual(-1);
        expect(rdpCursorPositionRevisionAfterGeometryChange(17, false)).assertEqual(17);
      });

    it('restarts_geometry_monitors_before_a_restored_window_can_accept_input', 0,
      (): void => {
        const steps: string[] = [];
        resumeRdpGeometryAfterRendererAttach({
          blockInputUntilConfirmed: (): void => { steps.push('block'); },
          synchronizeGeometry: (): void => { steps.push('sync'); },
          startRenderWatchdog: (): void => { steps.push('watchdog'); },
          startNativeStateMonitor: (): void => { steps.push('monitor'); }
        });
        expect(steps.join(',')).assertEqual('block,sync,watchdog,monitor');
      });

    it('clears_locked_modifiers_and_pointer_sequences_at_the_geometry_barrier', 0,
      (): void => {
        const steps: string[] = [];
        const modifiers = new RemoteModifierStateController();
        modifiers.setDown('ctrl', true);
        modifiers.setDown('alt', true);
        releaseRdpInputForGeometryChange({
          discardPendingMouseMove: (): void => { steps.push('discard-move'); },
          releaseCanvasPinchInput: (): void => { steps.push('pinch'); },
          releaseAllHeldKeys: (): void => { steps.push('keys-up'); },
          releaseHeldPointerState: (): void => { steps.push('pointer-up'); },
          resetTouchGesture: (): void => { steps.push('touch-reset'); },
          resetAllLatches: (): void => {
            modifiers.reset();
            steps.push('latches-reset');
          },
          resetTouchpadState: (): void => { steps.push('touchpad-reset'); },
          invalidateViewport: (): void => { steps.push('viewport-reset'); }
        });
        expect(modifiers.snapshot().ctrl).assertFalse();
        expect(modifiers.snapshot().alt).assertFalse();
        expect(steps.join(',')).assertEqual(
          'discard-move,pinch,keys-up,pointer-up,touch-reset,latches-reset,touchpad-reset,viewport-reset');
      });

    it('keeps_physical_pixels_when_dpi_scaling_is_available', 0, (): void => {
      const result = resolveRdpAdaptiveDisplay({
        surfaceWidthPx: 3000,
        surfaceHeightPx: 2000,
        densityPixels: 2,
        densityDpi: 320,
        uiScalePreference: 'auto',
        dpiScaleSupported: true
      });
      expect(result.width).assertEqual(3000);
      expect(result.height).assertEqual(2000);
      expect(result.desktopScaleFactor).assertEqual(180);
      expect(result.deviceScaleFactor).assertEqual(180);
      expect(result.physicalWidthMm).assertEqual(238);
      expect(result.orientation).assertEqual(0);
      expect(result.usesDpiScale).assertTrue();
    });

    it('uses_same_axis_multiplier_for_the_readability_fallback', 0, (): void => {
      const result = resolveRdpAdaptiveDisplay({
        surfaceWidthPx: 2880,
        surfaceHeightPx: 1800,
        densityPixels: 2,
        densityDpi: 320,
        uiScalePreference: '180',
        dpiScaleSupported: false
      });
      expect(result.width).assertEqual(1600);
      expect(result.height).assertEqual(1000);
      expect(result.desktopScaleFactor).assertEqual(100);
      expect(result.fallbackReason).assertEqual('dpi_scale_unavailable');
    });

    it('preserves_common_window_ratios_without_padding', 0, (): void => {
      const widescreen = resolveRdpAdaptiveDisplay({
        surfaceWidthPx: 2560,
        surfaceHeightPx: 1440,
        densityPixels: 1.25,
        densityDpi: 200,
        uiScalePreference: 'auto',
        dpiScaleSupported: true
      });
      expect(widescreen.width).assertEqual(2560);
      expect(widescreen.height).assertEqual(1440);
      expect(widescreen.desktopScaleFactor).assertEqual(140);

      const threeByTwo = resolveRdpAdaptiveDisplay({
        surfaceWidthPx: 3000,
        surfaceHeightPx: 2000,
        densityPixels: 1.5,
        densityDpi: 240,
        uiScalePreference: 'auto',
        dpiScaleSupported: true
      });
      expect(threeByTwo.width).assertEqual(3000);
      expect(threeByTwo.height).assertEqual(2000);
    });

    it('preserves_narrow_window_orientation_and_caps_the_long_edge', 0, (): void => {
      const portrait = resolveRdpAdaptiveDisplay({
        surfaceWidthPx: 1201,
        surfaceHeightPx: 2001,
        densityPixels: 1.5,
        densityDpi: 240,
        uiScalePreference: '140',
        dpiScaleSupported: true
      });
      expect(portrait.width).assertEqual(1200);
      expect(portrait.height).assertEqual(2000);
      expect(portrait.orientation).assertEqual(90);

      const capped = resolveRdpAdaptiveDisplay({
        surfaceWidthPx: 6000,
        surfaceHeightPx: 4000,
        densityPixels: 2,
        densityDpi: 320,
        uiScalePreference: '180',
        dpiScaleSupported: true
      });
      expect(capped.width).assertEqual(3840);
      expect(capped.height).assertEqual(2560);
      expect(capped.fallbackReason).assertEqual('max_edge_limited');
      expect(RDP_DYNAMIC_LAYOUT_SETTLE_MS >= 500).assertTrue();
    });

    it('fails_safe_for_invalid_surface_geometry', 0, (): void => {
      const result = resolveRdpAdaptiveDisplay({
        surfaceWidthPx: 0,
        surfaceHeightPx: Number.NaN,
        densityPixels: 0,
        densityDpi: 0,
        uiScalePreference: 'auto',
        dpiScaleSupported: true
      });
      expect(result.width).assertEqual(1920);
      expect(result.height).assertEqual(1080);
      expect(result.fallbackReason).assertEqual('invalid_surface');
    });
  });
}
