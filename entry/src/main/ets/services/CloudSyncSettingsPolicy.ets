const CLOUD_USER_SETTING_NAMES: string[] = [
  'accentColor',
  'currentTheme',
  'followSystem',
  'wallpaperColor',
  'wallpaperIdx',
  'haloColorLight',
  'haloColorDark',
  'hostAddMode',
  'totpLogoMode'
];

/**
 * These keys existed in the legacy cloud usersettings allowlist.  They remain
 * readable from device Preferences after an upgrade, but must not be uploaded
 * or applied from cloud because their correct value depends on the local
 * screen, input devices, network, performance or protocol runtime.
 */
const DEVICE_LOCAL_USER_SETTING_NAMES: string[] = [
  'secretPresentationPolicyV1',
  'ambientLightEffectEnabled',
  'liveViewEnabled',
  'liveViewMode',
  'virtualMouseStyle',
  'sshTerminalForegroundColor',
  'sshTerminalFontSize',
  'sshTerminalLineSpacing',
  'terminalFgColor',
  'terminalFontSize',
  'terminalLineSpacing',
  'useNativeTerminalCore',
  'rdpDesktopPreset',
  'rdpColorDepth',
  'rdpAudioEnabled',
  'rdpClipboardEnabled',
  'rdpDriveEnabled',
  'rdpDriveName',
  'rdpControlMode',
  'rdpAuthIdentityMode',
  'remoteWheelPreferenceVersion',
  'rdpReverseWheel',
  'rustdeskReverseWheel',
  'sshReverseWheel',
  'vncReverseWheel',
  'moonlightReverseWheel',
  'rustdeskImageQuality',
  'rustdeskCodec',
  'rustdeskDirectIp',
  'rustdeskDirectPort',
  'rustdeskLanDiscovery',
  'rustdeskPrivacyMode',
  'rustdeskAudioEnabled',
  'rustdeskClipboardEnabled',
  'rustdeskFilePasteEnabled',
  'rustdeskControlMode'
];

export type CloudUserSettingValue = string | number | boolean;

export function cloudUserSettingNames(): string[] {
  return CLOUD_USER_SETTING_NAMES.slice();
}

export function deviceLocalUserSettingNames(): string[] {
  return DEVICE_LOCAL_USER_SETTING_NAMES.slice();
}

export function cloudUserSettingIsDeviceLocal(key: string): boolean {
  return DEVICE_LOCAL_USER_SETTING_NAMES.indexOf(key) >= 0;
}

/** 仅同步可跨设备复用的外观偏好；设备、协议运行时、账号和临时会话状态留在本机。 */
export function cloudUserSettingIsSyncable(key: string): boolean {
  return CLOUD_USER_SETTING_NAMES.indexOf(key) >= 0;
}
