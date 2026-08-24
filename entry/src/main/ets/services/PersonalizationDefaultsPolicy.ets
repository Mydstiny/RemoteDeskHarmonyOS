/**
 * 1.1.1 personalization bootstrap.
 *
 * The profile is captured before LoginPage writes its first-launch marker, so
 * a clean install can receive the new defaults without turning an app update
 * into a settings migration. Once captured, the profile is stable and every
 * explicitly persisted preference remains authoritative.
 */
export const PERSONALIZATION_DEFAULTS_PROFILE_VERSION: number = 1;
export const PERSONALIZATION_DEFAULTS_PROFILE_VERSION_KEY: string =
  'personalizationDefaultsProfileVersion';
export const PERSONALIZATION_DEFAULTS_FRESH_INSTALL_KEY: string =
  'personalizationDefaultsFreshInstall';

export interface PersonalizationDefaultsProfile {
  version: number;
  freshInstall: boolean;
}

export interface PersonalizationDefaults {
  canvasGestureZoomEnabled: boolean;
  virtualMouseStyle: string;
  liveViewEnabled: boolean;
  totpLogoMode: string;
  rustdeskPresenceDetectionEnabled: boolean;
  groupedHostCards: boolean;
  rdpControlMode: number;
  rustdeskControlMode: number;
  vncControlMode: number;
  sshInputMode: number;
}

export function resolvePersonalizationDefaultsProfile(storedVersion: number,
  storedFreshInstall: boolean, firstLaunchMarkerPresent: boolean): PersonalizationDefaultsProfile {
  if (Number.isFinite(storedVersion) &&
    storedVersion >= PERSONALIZATION_DEFAULTS_PROFILE_VERSION) {
    return {
      version: PERSONALIZATION_DEFAULTS_PROFILE_VERSION,
      freshInstall: storedFreshInstall
    };
  }
  return {
    version: PERSONALIZATION_DEFAULTS_PROFILE_VERSION,
    freshInstall: !firstLaunchMarkerPresent
  };
}

/**
 * Missing keys on an update receive the same device-class SSH input default as
 * a clean install. Callers still use Preferences.hasSync first, so saved user
 * choices always win.
 */
export function personalizationDefaults(freshInstall: boolean,
  isDesktopDevice: boolean): PersonalizationDefaults {
  if (!freshInstall) {
    return {
      canvasGestureZoomEnabled: !isDesktopDevice,
      virtualMouseStyle: 'circle',
      liveViewEnabled: true,
      totpLogoMode: 'logo',
      rustdeskPresenceDetectionEnabled: true,
      groupedHostCards: false,
      rdpControlMode: 0,
      rustdeskControlMode: 0,
      vncControlMode: 0,
      // A phone/Pad must not infer its input owner from a built-in keyboard
      // device that the platform may report as physical. Desktop keeps the
      // explicit hardware path, matching the clean-install default.
      sshInputMode: isDesktopDevice ? 2 : 1
    };
  }
  const remoteControlMode: number = isDesktopDevice ? 2 : 0;
  return {
    canvasGestureZoomEnabled: false,
    virtualMouseStyle: 'arrow',
    liveViewEnabled: true,
    totpLogoMode: 'logo',
    rustdeskPresenceDetectionEnabled: false,
    groupedHostCards: false,
    rdpControlMode: remoteControlMode,
    rustdeskControlMode: remoteControlMode,
    vncControlMode: remoteControlMode,
    // SSH has no touchpad mode. Phone/Pad use its explicit software-keyboard
    // path while PC uses the physical keyboard/mouse path.
    sshInputMode: isDesktopDevice ? 2 : 1
  };
}
