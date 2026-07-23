import { describe, it, expect } from '@ohos/hypium';
import {
  cloudUserSettingIsSyncable,
  cloudUserSettingNames
} from '../main/ets/services/CloudSyncSettingsPolicy';

export default function cloudSyncSettingsPolicyTest() {
  describe('CloudSyncSettingsPolicy', (): void => {
    it('syncs_personalization_and_protocol_preferences_but_not_device_or_account_state', 0, (): void => {
      const names: string[] = cloudUserSettingNames();
      expect(names.indexOf('accentColor') >= 0).assertTrue();
      expect(names.indexOf('wallpaperColor') >= 0).assertTrue();
      expect(names.indexOf('rdpColorDepth') >= 0).assertTrue();
      expect(names.indexOf('rustdeskImageQuality') >= 0).assertTrue();
      expect(names.indexOf('virtualMouseStyle') >= 0).assertTrue();
      expect(names.indexOf('showVirtualMouse') >= 0).assertFalse();
      expect(names.indexOf('showVirtualJoystick') >= 0).assertFalse();
      expect(cloudUserSettingIsSyncable('showVirtualMouse')).assertFalse();
      expect(cloudUserSettingIsSyncable('showVirtualJoystick')).assertFalse();
      expect(cloudUserSettingIsSyncable('loginMode')).assertFalse();
      expect(cloudUserSettingIsSyncable('totpLocked')).assertFalse();
      expect(cloudUserSettingIsSyncable('remoteDesktopBgFlag')).assertFalse();
      expect(cloudUserSettingIsSyncable('virtualMouseSession')).assertFalse();
    });
  });
}
