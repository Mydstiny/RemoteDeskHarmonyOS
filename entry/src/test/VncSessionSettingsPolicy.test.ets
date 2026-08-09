import { describe, it, expect } from '@ohos/hypium';
import {
  defaultVncSettings,
  VncHostValues,
  VncSettingsValues
} from '../main/ets/services/VncModelPolicy';
import { resolveEffectiveVncSessionSettings } from '../main/ets/services/VncSessionSettingsPolicy';

function hostWithScaling(scalingMode: 'fit' | 'integer' | 'one_to_one' | 'pan',
  displayOverrideEnabled: boolean): VncHostValues {
  return {
    label: 'Mac', host: '192.0.2.10', port: 5900, username: '', gatewayId: '',
    transport: 'direct_tcp', repeaterMode: 'mode12', rememberPassword: false,
    viewOnly: false, displayOverrideEnabled, scalingMode, clipboardEnabled: true,
    securityPolicy: 'trusted_network', tls: false, locked: false, lockType: 0
  };
}

export default function vncSessionSettingsPolicyTest(): void {
  describe('VncSessionSettingsPolicy', (): void => {
    it('accepts_device_class_control_defaults_for_new_users', 0, (): void => {
      expect(defaultVncSettings().controlMode).assertEqual(0);
      expect(defaultVncSettings(2).controlMode).assertEqual(2);
      expect(defaultVncSettings(9).controlMode).assertEqual(0);
    });

    it('keeps_an_explicit_host_scale_choice', 0, (): void => {
      const settings: VncSettingsValues = defaultVncSettings();
      const effective = resolveEffectiveVncSessionSettings(settings, hostWithScaling('one_to_one', true));
      expect(effective.displayScaleMode).assertEqual('100');
    });

    it('upgrades_a_host_still_using_the_current_default_to_custom_scale', 0, (): void => {
      const settings: VncSettingsValues = defaultVncSettings();
      settings.displayScaleMode = 'custom';
      settings.customScalePercent = 135;
      const effective = resolveEffectiveVncSessionSettings(settings, hostWithScaling('fit', false));
      expect(effective.displayScaleMode).assertEqual('custom');
      expect(effective.customScalePercent).assertEqual(135);
    });

    it('keeps_host_security_and_global_runtime_preferences_isolated', 0, (): void => {
      const settings: VncSettingsValues = defaultVncSettings();
      settings.touchpadSpeed = 145;
      settings.imageQualityPreset = 'quality';
      settings.showDiagnostics = true;
      const host: VncHostValues = hostWithScaling('fit', false);
      host.viewOnly = true;
      const effective = resolveEffectiveVncSessionSettings(settings, host);
      expect(effective.viewOnly).assertTrue();
      expect(effective.clipboardEnabled).assertTrue();
      expect(effective.securityPolicy).assertEqual('trusted_network');
      expect(effective.touchpadSpeed).assertEqual(145);
      expect(effective.imageQualityPreset).assertEqual('quality');
      expect(effective.showDiagnostics).assertTrue();
    });

    it('keeps_inheriting_after_the_global_default_changes', 0, (): void => {
      const settings: VncSettingsValues = defaultVncSettings();
      const host: VncHostValues = hostWithScaling('fit', false);
      settings.displayScaleMode = 'integer';
      expect(resolveEffectiveVncSessionSettings(settings, host).displayScaleMode).assertEqual('integer');
      settings.displayScaleMode = '100';
      expect(resolveEffectiveVncSessionSettings(settings, host).displayScaleMode).assertEqual('100');
    });

    it('keeps_an_explicit_override_even_when_it_equals_the_old_default', 0, (): void => {
      const settings: VncSettingsValues = defaultVncSettings();
      const host: VncHostValues = hostWithScaling('fit', true);
      settings.displayScaleMode = 'custom';
      settings.customScalePercent = 150;
      expect(resolveEffectiveVncSessionSettings(settings, host).displayScaleMode).assertEqual('fit');
    });
  });
}
