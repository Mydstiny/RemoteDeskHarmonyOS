import { describe, it, expect } from '@ohos/hypium';
import {
  cloudUserSettingIsDeviceLocal,
  cloudUserSettingIsSyncable,
  cloudUserSettingNames,
  deviceLocalUserSettingNames
} from '../main/ets/services/CloudSyncSettingsPolicy';

export default function cloudSyncSettingsPolicyTest() {
  describe('CloudSyncSettingsPolicy', (): void => {
    it('syncs_only_cross_device_appearance_preferences', 0, (): void => {
      const names: string[] = cloudUserSettingNames();
      expect(names.indexOf('accentColor') >= 0).assertTrue();
      expect(names.indexOf('wallpaperColor') >= 0).assertTrue();
      expect(names.indexOf('hostAddMode') >= 0).assertTrue();
      expect(names.indexOf('totpLogoMode') >= 0).assertTrue();
      expect(names.indexOf('rdpColorDepth') >= 0).assertFalse();
      expect(names.indexOf('rustdeskImageQuality') >= 0).assertFalse();
      expect(names.indexOf('virtualMouseStyle') >= 0).assertFalse();
      expect(names.indexOf('showVirtualMouse') >= 0).assertFalse();
      expect(names.indexOf('showVirtualJoystick') >= 0).assertFalse();
    });

    it('keeps_protocol_input_display_quality_and_capability_preferences_local', 0, (): void => {
      const localNames: string[] = deviceLocalUserSettingNames();
      expect(localNames.indexOf('rustdeskControlMode') >= 0).assertTrue();
      expect(localNames.indexOf('rustdeskImageQuality') >= 0).assertTrue();
      expect(localNames.indexOf('rdpControlMode') >= 0).assertTrue();
      expect(localNames.indexOf('rdpColorDepth') >= 0).assertTrue();
      expect(localNames.indexOf('sshTerminalFontSize') >= 0).assertTrue();
      expect(localNames.indexOf('liveViewMode') >= 0).assertTrue();
      expect(localNames.indexOf('virtualMouseStyle') >= 0).assertTrue();
      expect(localNames.indexOf('secretPresentationPolicyV1') >= 0).assertTrue();
      expect(cloudUserSettingIsDeviceLocal('rustdeskControlMode')).assertTrue();
      expect(cloudUserSettingIsDeviceLocal('rdpControlMode')).assertTrue();
      expect(cloudUserSettingIsDeviceLocal('accentColor')).assertFalse();
      expect(cloudUserSettingIsSyncable('rustdeskControlMode')).assertFalse();
      expect(cloudUserSettingIsSyncable('rdpControlMode')).assertFalse();
      expect(cloudUserSettingIsSyncable('sshTerminalFontSize')).assertFalse();
      expect(cloudUserSettingIsSyncable('liveViewMode')).assertFalse();
      expect(cloudUserSettingIsSyncable('virtualMouseStyle')).assertFalse();
      expect(cloudUserSettingIsDeviceLocal('secretPresentationPolicyV1')).assertTrue();
      expect(cloudUserSettingIsSyncable('secretPresentationPolicyV1')).assertFalse();
    });

    it('does_not_treat_account_or_transient_runtime_state_as_settings', 0, (): void => {
      expect(cloudUserSettingIsSyncable('showVirtualMouse')).assertFalse();
      expect(cloudUserSettingIsSyncable('showVirtualJoystick')).assertFalse();
      expect(cloudUserSettingIsSyncable('loginMode')).assertFalse();
      expect(cloudUserSettingIsSyncable('totpLocked')).assertFalse();
      expect(cloudUserSettingIsSyncable('remoteDesktopBgFlag')).assertFalse();
      expect(cloudUserSettingIsSyncable('virtualMouseSession')).assertFalse();
    });
  });
}
