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
  // 'virtualMouseStyle', // 发布版本暂时固定圆环，恢复官方光标开关后再启用
  'showVirtualMouse',
  'showVirtualJoystick',
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
