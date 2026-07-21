export const SETTINGS_SECTION_NONE: string = '';
export const SETTINGS_SECTION_APPEARANCE: string = 'appearance';
export const SETTINGS_SECTION_CLOUD_SYNC: string = 'cloudSync';
export const SETTINGS_SECTION_CONNECTION_LIVE: string = 'connectionLive';
export const SETTINGS_SECTION_DISPLAY_INTERACTION: string = 'displayInteraction';
export const SETTINGS_SECTION_RDP: string = 'windowsRdp';
export const SETTINGS_SECTION_RUSTDESK: string = 'rustdesk';
export const SETTINGS_SECTION_SECURITY: string = 'security';
export const SETTINGS_SECTION_TUTORIAL: string = 'tutorial';
export const SETTINGS_SECTION_ABOUT: string = 'about';
export const SETTINGS_SECTION_FEEDBACK: string = 'feedback';
export const SETTINGS_SECTION_RATING: string = 'rating';

export const SETTINGS_SUPPORT_EMAIL: string = 'lijiong1219@petalmail.com';
export const SETTINGS_SUPPORT_SUBJECT: string = 'RemoteDesktop 用户反馈';
export const SETTINGS_APP_BUNDLE_NAME: string = 'com.example.remotedesktop';
export const SETTINGS_RATING_SUBTITLE: string = '前往应用市场为 RemoteDesktop 评分';
export const SETTINGS_EMAIL_PANEL_TYPE: string = 'mail';
export const SETTINGS_EMAIL_SEND_TO_ACTION: string = 'ohos.want.action.sendToData';
export const SETTINGS_APPGALLERY_REVIEW_ACTION: string = 'ohos.want.action.appdetail';
export const SETTINGS_BROWSER_VIEW_ACTION: string = 'ohos.want.action.viewData';

export interface SettingsFeedbackWantSpec {
  action: string;
  uri: string;
  entities: string[];
}

export type SettingsFeedbackLaunchKind = 'want' | 'mailPanel';

export interface SettingsFeedbackLaunchAttempt {
  kind: SettingsFeedbackLaunchKind;
  action: string;
  uri: string;
  entities: string[];
}

export type SettingsActionKind = 'none' | 'feedback' | 'rating';

export function settingsSectionIsAction(section: string): boolean {
  return section === SETTINGS_SECTION_FEEDBACK || section === SETTINGS_SECTION_RATING;
}

export function settingsActionKind(section: string): SettingsActionKind {
  if (section === SETTINGS_SECTION_FEEDBACK) {
    return 'feedback';
  }
  if (section === SETTINGS_SECTION_RATING) {
    return 'rating';
  }
  return 'none';
}

export function settingsNextExpandedSection(current: string, selected: string): string {
  if (settingsSectionIsAction(selected)) {
    return current;
  }
  return current === selected ? SETTINGS_SECTION_NONE : selected;
}

export function settingsFeedbackBody(versionName: string, breakpoint: string, isDesktopDevice: boolean): string {
  const deviceMode: string = isDesktopDevice ? 'PC/2in1' : 'Phone/Pad';
  return '请在这里描述你遇到的问题或建议：\n\n\n' +
    '---\n' +
    'App 版本：' + versionName + '\n' +
    '包名：' + SETTINGS_APP_BUNDLE_NAME + '\n' +
    '设备模式：' + deviceMode + '\n' +
    '断点：' + breakpoint + '\n' +
    '可选：请附上复现步骤、截图或日志。';
}

export function settingsFeedbackMailtoUri(versionName: string, breakpoint: string, isDesktopDevice: boolean): string {
  return 'mailto:' + SETTINGS_SUPPORT_EMAIL +
    '?subject=' + encodeURIComponent(SETTINGS_SUPPORT_SUBJECT) +
    '&body=' + encodeURIComponent(settingsFeedbackBody(versionName, breakpoint, isDesktopDevice));
}

export function settingsFeedbackMailPanelParams(
  versionName: string,
  breakpoint: string,
  isDesktopDevice: boolean
): Record<string, Object> {
  const params: Record<string, Object> = {};
  params['sceneType'] = 1;
  params['email'] = [encodeURI(SETTINGS_SUPPORT_EMAIL)];
  params['subject'] = encodeURI(SETTINGS_SUPPORT_SUBJECT);
  params['body'] = encodeURI(settingsFeedbackBody(versionName, breakpoint, isDesktopDevice));
  return params;
}

export function settingsFeedbackFallbackWantSpecs(
  versionName: string,
  breakpoint: string,
  isDesktopDevice: boolean
): SettingsFeedbackWantSpec[] {
  const uri: string = settingsFeedbackMailtoUri(versionName, breakpoint, isDesktopDevice);
  return [
    { action: SETTINGS_EMAIL_SEND_TO_ACTION, uri: uri, entities: [] },
    { action: SETTINGS_BROWSER_VIEW_ACTION, uri: uri, entities: ['entity.system.browsable'] }
  ];
}

export function settingsFeedbackLaunchAttempts(
  versionName: string,
  breakpoint: string,
  isDesktopDevice: boolean
): SettingsFeedbackLaunchAttempt[] {
  const fallbackSpecs: SettingsFeedbackWantSpec[] =
    settingsFeedbackFallbackWantSpecs(versionName, breakpoint, isDesktopDevice);
  return [
    {
      kind: 'want',
      action: fallbackSpecs[0].action,
      uri: fallbackSpecs[0].uri,
      entities: fallbackSpecs[0].entities
    },
    {
      kind: 'mailPanel',
      action: SETTINGS_EMAIL_PANEL_TYPE,
      uri: '',
      entities: []
    },
    {
      kind: 'want',
      action: fallbackSpecs[1].action,
      uri: fallbackSpecs[1].uri,
      entities: fallbackSpecs[1].entities
    }
  ];
}

export function settingsRatingUriCandidates(): string[] {
  return [
    'store://appgallery.huawei.com/app/detail?id=' + SETTINGS_APP_BUNDLE_NAME + '&action=write-review',
    'appmarket://comment?packageName=' + SETTINGS_APP_BUNDLE_NAME,
    'appmarket://details?id=' + SETTINGS_APP_BUNDLE_NAME,
    'market://details?id=' + SETTINGS_APP_BUNDLE_NAME
  ];
}

export function settingsRatingWantAction(uri: string): string {
  if (uri.indexOf('store://appgallery.huawei.com/app/detail') === 0) {
    return SETTINGS_APPGALLERY_REVIEW_ACTION;
  }
  return SETTINGS_BROWSER_VIEW_ACTION;
}
