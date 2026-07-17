const CLOUD_USER_SETTING_NAMES: string[] = [
  'accentColor',
  'currentTheme',
  'followSystem',
  'wallpaperColor',
  'wallpaperIdx',
  'haloColorLight',
  'haloColorDark',
  'ambientLightEffectEnabled',
  'liveViewEnabled',
  'liveViewMode',
  'hostAddMode',
  'terminalFgColor',
  'terminalFontSize',
  'useNativeTerminalCore',
  'rdpDesktopPreset',
  'rdpColorDepth',
  'rdpAudioEnabled',
  'rdpClipboardEnabled',
  'rdpDriveEnabled',
  'rdpDriveName',
  'rdpControlMode',
  'rdpAuthIdentityMode',
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

/** 仅同步可跨设备复用的体验/协议偏好；账号、锁屏状态和临时会话必须留在本机。 */
export function cloudUserSettingIsSyncable(key: string): boolean {
  return CLOUD_USER_SETTING_NAMES.indexOf(key) >= 0;
}
