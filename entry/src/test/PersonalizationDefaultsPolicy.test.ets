import { describe, it, expect } from '@ohos/hypium';
import {
  PERSONALIZATION_DEFAULTS_PROFILE_VERSION,
  personalizationDefaults,
  resolvePersonalizationDefaultsProfile
} from '../main/ets/services/PersonalizationDefaultsPolicy';

export default function personalizationDefaultsPolicyTest(): void {
  describe('PersonalizationDefaultsPolicy', (): void => {
    it('classifies a clean install before LoginPage writes its marker', 0, (): void => {
      const profile = resolvePersonalizationDefaultsProfile(0, false, false);
      expect(profile.version).assertEqual(PERSONALIZATION_DEFAULTS_PROFILE_VERSION);
      expect(profile.freshInstall).assertTrue();
    });

    it('classifies an existing installation as an update', 0, (): void => {
      const profile = resolvePersonalizationDefaultsProfile(0, false, true);
      expect(profile.freshInstall).assertFalse();
    });

    it('keeps the captured profile stable on later launches', 0, (): void => {
      const profile = resolvePersonalizationDefaultsProfile(
        PERSONALIZATION_DEFAULTS_PROFILE_VERSION, true, true);
      expect(profile.freshInstall).assertTrue();
    });

    it('uses touchpad-oriented defaults on a new Phone or Pad', 0, (): void => {
      const defaults = personalizationDefaults(true, false);
      expect(defaults.canvasGestureZoomEnabled).assertFalse();
      expect(defaults.virtualMouseStyle).assertEqual('arrow');
      expect(defaults.rdpControlMode).assertEqual(0);
      expect(defaults.rustdeskControlMode).assertEqual(0);
      expect(defaults.vncControlMode).assertEqual(0);
      expect(defaults.sshInputMode).assertEqual(1);
      expect(defaults.rustdeskPresenceDetectionEnabled).assertFalse();
      expect(defaults.groupedHostCards).assertFalse();
      expect(defaults.liveViewEnabled).assertTrue();
      expect(defaults.liveViewMode).assertEqual(1);
      expect(defaults.totpLogoMode).assertEqual('logo');
    });

    it('uses physical input defaults on a new PC', 0, (): void => {
      const defaults = personalizationDefaults(true, true);
      expect(defaults.rdpControlMode).assertEqual(2);
      expect(defaults.rustdeskControlMode).assertEqual(2);
      expect(defaults.vncControlMode).assertEqual(2);
      expect(defaults.sshInputMode).assertEqual(2);
    });

    it('restores device-safe SSH input defaults for missing update keys', 0, (): void => {
      const mobileDefaults = personalizationDefaults(false, false);
      expect(mobileDefaults.virtualMouseStyle).assertEqual('circle');
      expect(mobileDefaults.rustdeskPresenceDetectionEnabled).assertTrue();
      expect(mobileDefaults.rdpControlMode).assertEqual(0);
      expect(mobileDefaults.rustdeskControlMode).assertEqual(0);
      expect(mobileDefaults.vncControlMode).assertEqual(0);
      expect(mobileDefaults.sshInputMode).assertEqual(1);
      expect(mobileDefaults.liveViewEnabled).assertTrue();
      expect(mobileDefaults.liveViewMode).assertEqual(1);

      const desktopDefaults = personalizationDefaults(false, true);
      expect(desktopDefaults.sshInputMode).assertEqual(2);
    });
  });
}
