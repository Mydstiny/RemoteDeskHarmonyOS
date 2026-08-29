import { describe, it, expect } from '@ohos/hypium';
import {
  normalizeRdpRemoteUiScalePreference,
  RDP_DYNAMIC_LAYOUT_SETTLE_MS,
  resolveRdpAdaptiveDisplay,
  resolveRdpRemoteUiScale
} from '../main/ets/services/RdpAdaptiveDisplayPolicy';

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
