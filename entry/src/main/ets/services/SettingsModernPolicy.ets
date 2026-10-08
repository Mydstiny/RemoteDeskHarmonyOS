import {
  SETTINGS_SECTION_ABOUT,
  SETTINGS_SECTION_AI,
  SETTINGS_SECTION_APPEARANCE,
  SETTINGS_SECTION_CLOUD_SYNC,
  SETTINGS_SECTION_CONNECTION_LIVE,
  SETTINGS_SECTION_DIAGNOSTICS,
  SETTINGS_SECTION_DISPLAY_INTERACTION,
  SETTINGS_SECTION_HOME,
  SETTINGS_SECTION_MOONLIGHT,
  SETTINGS_SECTION_PRO,
  SETTINGS_SECTION_RDP,
  SETTINGS_SECTION_RUSTDESK,
  SETTINGS_SECTION_SECURITY,
  SETTINGS_SECTION_SSH,
  SETTINGS_SECTION_TUTORIAL,
  SETTINGS_SECTION_VIRTUAL_KEYBOARD,
  SETTINGS_SECTION_VNC
} from './SettingsAccordionPolicy';

/**
 * 全新视觉 (设置 → 个性化). The classic settings page is left exactly as it was; everything here only applies when
 * the new look is on: how the sections are grouped, where a section sits in the list (to scroll to it), and the
 * words and icons the new rows show.
 */

/** The pseudo-section of the 反馈 / 评价 / RemoteDesk Pro rows at the end of 帮助. */
export const SETTINGS_MODERN_ACTIONS: string = 'actions';
/** A Pro-off Debug build shows a lone state row between AI 助理 and Pro. */
export const SETTINGS_MODERN_PRO_DEBUG: string = 'proDebug';

export interface SettingsModernGroup {
  title: string;
  sections: string[];
}

export interface SettingsModernVisibility {
  remoteAi: boolean;
  proDebug: boolean;
  pro: boolean;
}

/** Group headings and their sections, in the order HostListPage.settingsModernSections() renders them. */
export function settingsModernGroups(): SettingsModernGroup[] {
  return [
    { title: '通用', sections: [SETTINGS_SECTION_APPEARANCE, SETTINGS_SECTION_HOME, SETTINGS_SECTION_CONNECTION_LIVE,
      SETTINGS_SECTION_DISPLAY_INTERACTION, SETTINGS_SECTION_VIRTUAL_KEYBOARD] },
    { title: '连接协议', sections: [SETTINGS_SECTION_RDP, SETTINGS_SECTION_RUSTDESK, SETTINGS_SECTION_SSH,
      SETTINGS_SECTION_VNC, SETTINGS_SECTION_MOONLIGHT] },
    { title: 'AI 与 Pro', sections: [SETTINGS_SECTION_DIAGNOSTICS, SETTINGS_SECTION_AI, SETTINGS_MODERN_PRO_DEBUG,
      SETTINGS_SECTION_PRO] },
    { title: '安全与数据', sections: [SETTINGS_SECTION_CLOUD_SYNC, SETTINGS_SECTION_SECURITY] },
    { title: '帮助', sections: [SETTINGS_SECTION_TUTORIAL, SETTINGS_SECTION_ABOUT, SETTINGS_MODERN_ACTIONS] }
  ];
}

/** The classic page's section order (HostListPage.settingsContent()). */
export function settingsClassicSectionOrder(): string[] {
  return [SETTINGS_SECTION_APPEARANCE, SETTINGS_SECTION_HOME, SETTINGS_SECTION_CLOUD_SYNC, SETTINGS_SECTION_CONNECTION_LIVE,
    SETTINGS_SECTION_DISPLAY_INTERACTION, SETTINGS_SECTION_VIRTUAL_KEYBOARD, SETTINGS_SECTION_RDP, SETTINGS_SECTION_RUSTDESK,
    SETTINGS_SECTION_SSH, SETTINGS_SECTION_VNC, SETTINGS_SECTION_MOONLIGHT, SETTINGS_SECTION_AI, SETTINGS_SECTION_PRO,
    SETTINGS_SECTION_SECURITY, SETTINGS_SECTION_TUTORIAL, SETTINGS_SECTION_ABOUT, SETTINGS_SECTION_DIAGNOSTICS];
}

/** Whether `upper` comes before `lower` on the page, in the classic or the grouped order. */
export function settingsSectionIsAbove(upper: string, lower: string, modern: boolean): boolean {
  const order: string[] = [];
  if (modern) {
    const groups: SettingsModernGroup[] = settingsModernGroups();
    for (let g = 0; g < groups.length; g++) {
      for (let s = 0; s < groups[g].sections.length; s++) { order.push(groups[g].sections[s]); }
    }
  } else {
    const classic: string[] = settingsClassicSectionOrder();
    for (let i = 0; i < classic.length; i++) { order.push(classic[i]); }
  }
  const upperIndex: number = order.indexOf(upper);
  const lowerIndex: number = order.indexOf(lower);
  return upperIndex >= 0 && lowerIndex >= 0 && upperIndex < lowerIndex;
}

/** ListItems a section renders: a header and a card, 连接实况窗 has two cards, the end rows are three. */
export function settingsModernSectionItemCount(section: string, visibility: SettingsModernVisibility): number {
  if (section === SETTINGS_SECTION_AI) { return visibility.remoteAi ? 2 : 0; }
  if (section === SETTINGS_MODERN_PRO_DEBUG) { return visibility.proDebug ? 1 : 0; }
  if (section === SETTINGS_SECTION_PRO) { return visibility.pro ? 2 : 0; }
  if (section === SETTINGS_SECTION_CONNECTION_LIVE) { return 3; }
  if (section === SETTINGS_MODERN_ACTIONS) { return 3; }
  return 2;
}

/** Items above the first group: the title spacer, the search field and the account card. */
export const SETTINGS_MODERN_LEADING_ITEMS: number = 3;

/** The List index of a section's header in the grouped list, or -1 when the section is not shown. */
export function settingsModernSectionIndex(section: string, visibility: SettingsModernVisibility): number {
  let index: number = SETTINGS_MODERN_LEADING_ITEMS;
  const groups: SettingsModernGroup[] = settingsModernGroups();
  for (let g = 0; g < groups.length; g++) {
    index += 1; // the group heading
    for (let s = 0; s < groups[g].sections.length; s++) {
      const current: string = groups[g].sections[s];
      const count: number = settingsModernSectionItemCount(current, visibility);
      if (current === section) { return count > 0 ? index : -1; }
      index += count;
    }
  }
  return -1;
}

/** Section icons in the new look: no two sections share one (classic reuses a few). */
export function settingsModernSectionSymbol(section: string, fallback: Resource): Resource {
  if (section === SETTINGS_SECTION_HOME) { return $r('sys.symbol.house_fill'); }
  if (section === SETTINGS_SECTION_CONNECTION_LIVE) { return $r('sys.symbol.smal_window_playback'); }
  if (section === SETTINGS_SECTION_DISPLAY_INTERACTION) { return $r('sys.symbol.slider_horizontal_2'); }
  if (section === SETTINGS_SECTION_AI) { return $r('sys.symbol.computer_host_fill'); }
  if (section === SETTINGS_SECTION_DIAGNOSTICS) { return $r('sys.symbol.ellipsis_bubble'); }
  if (section === SETTINGS_SECTION_ABOUT) { return $r('sys.symbol.info_circle'); }
  return fallback;
}

/**
 * Row icons in the new look, by row title: each row gets its own symbol instead of the shared desktop / info /
 * terminal images. A title not listed keeps the row's own icon.
 */
export function settingsModernRowSymbol(title: string): Resource | null {
  switch (title) {
    case '后台连接展示': return $r('sys.symbol.smal_window_playback');
    case 'RustDesk 在线检测': return $r('sys.symbol.link');
    case '跳过连接前证书预检': return $r('sys.symbol.checkmark_shield');
    case 'TLS 兼容登录': return $r('sys.symbol.lock_open');
    case '远端音频': return $r('sys.symbol.speaker_wave_2_fill');
    case '剪贴板同步': return $r('sys.symbol.text_clipboard');
    case '性能监视与诊断日志': return $r('sys.symbol.performance');
    case '文件共享盘': return $r('sys.symbol.folder_fill');
    case '允许隐私模式': return $r('sys.symbol.eye_slash');
    case '远端应用双指缩放': return $r('sys.symbol.arrow_up_left_and_arrow_down_right');
    case '显示连接诊断信息': return $r('sys.symbol.performance');
    case '专业性能数据（Pro）': return $r('sys.symbol.slider_horizontal_2');
    case '管理 SSH 主机': return $r('sys.symbol.code_square');
    case 'SSH 密钥保险库': return $r('sys.symbol.key_fill');
    case '连接默认值': return $r('sys.symbol.link');
    case '超时与连接行为': return $r('sys.symbol.timer');
    case '安全策略与 TLS': return $r('sys.symbol.lock_shield');
    case '显示与画面': return $r('sys.symbol.display');
    case '输入与光标': return $r('sys.symbol.mouse');
    case '性能监视看板': return $r('sys.symbol.performance');
    case '剪贴板': return $r('sys.symbol.text_clipboard');
    case 'Trust / 证书管理': return $r('sys.symbol.checkmark_shield');
    case '管理 VNC 主机': return $r('sys.symbol.computer_host_fill');
    case '管理 VNC Gateway': return $r('sys.symbol.arrowshape_right_fill');
    case '画面': return $r('sys.symbol.display');
    case '音频': return $r('sys.symbol.speaker_wave_2_fill');
    case '控制与手柄': return $r('sys.symbol.gamecontroller_fill');
    case '网络与安全': return $r('sys.symbol.lock_shield');
    case '诊断': return $r('sys.symbol.performance');
    case '配对与信任': return $r('sys.symbol.link');
    case '数据管理': return $r('sys.symbol.folder');
    case '连接与配对': return $r('sys.symbol.link');
    case '显示与恢复': return $r('sys.symbol.eye');
    case '本机数据管理': return $r('sys.symbol.folder');
    case '电脑端安装': return $r('sys.symbol.computer_host_fill');
    case '密码与秘密回显': return $r('sys.symbol.eye_slash');
    case 'SSH 主机指纹': return $r('sys.symbol.key_fill');
    case 'RDP 证书信任': return $r('sys.symbol.desktop_fill');
    case 'VNC TLS 证书信任': return $r('sys.symbol.display');
    case 'RustDesk 认证信任': return $r('sys.symbol.checkmark_shield');
    case '版本': return $r('sys.symbol.info_circle');
    case '关于应用': return $r('sys.symbol.doc_text');
    case '隐私政策': return $r('sys.symbol.lock_shield');
    case '本版本更新日志': return $r('sys.symbol.bolt_fill');
    case '快速认识应用': return $r('sys.symbol.info_circle_fill');
    case 'Pro 功能介绍': return $r('sys.symbol.star');
    case '操作引导中心': return $r('sys.symbol.list_bullet');
    case '连接前准备': return $r('sys.symbol.checkmark_circle');
    default: return null;
  }
}

/** 触控板 / 触控 / 键鼠, as the RDP, RustDesk and VNC control-mode pickers name them. */
export function settingsControlModeLabel(mode: number): string {
  if (mode === 1) { return '触控'; }
  if (mode === 2) { return '键鼠'; }
  return '触控板';
}

export function settingsRustDeskQualityLabel(quality: number): string {
  if (quality === 0) { return '速度优先'; }
  if (quality === 2) { return '画质优先'; }
  return '平衡';
}

export function settingsRustDeskCodecLabel(codec: number): string {
  const names: string[] = ['自动', 'VP8', 'VP9', 'AV1', 'H264', 'H265'];
  return codec >= 0 && codec < names.length ? names[codec] : '自动';
}

export function settingsThemeLabel(followSystem: boolean, theme: string): string {
  if (followSystem) { return '跟随系统'; }
  return theme === 'dark' ? '深色' : '浅色';
}

export function settingsVncTransportLabel(transport: string): string {
  if (transport === 'ultravnc_repeater') { return 'Repeater'; }
  if (transport === 'websocket_gateway') { return 'WebSocket'; }
  if (transport === 'ssh_tunnel') { return 'SSH 隧道'; }
  return 'TCP 直连';
}

export function settingsVncSecurityLabel(policy: string): string {
  if (policy === 'secure_only') { return '仅加密连接'; }
  if (policy === 'allow_plaintext') { return '允许明文'; }
  return '可信网络可明文';
}

/** VNC 显示与画面 as its sheet names the choice (displayScaleMode, not the legacy scalingMode). */
export function settingsVncDisplayScaleLabel(mode: string, customPercent: number): string {
  if (mode === '100') { return '100%'; }
  if (mode === 'integer') { return '整数倍率'; }
  if (mode === 'custom') { return '自定义 ' + Math.round(customPercent).toString() + '%'; }
  return '适应窗口';
}

/** Seconds with at most one decimal (10000 → 10 秒, 1500 → 1.5 秒). */
export function settingsSecondsLabel(ms: number): string {
  if (!Number.isFinite(ms) || ms <= 0) { return '—'; }
  const seconds: number = Math.round(ms / 100) / 10;
  return (Number.isInteger(seconds) ? seconds.toFixed(0) : seconds.toFixed(1)) + ' 秒';
}

/** 1080p · 60 帧 · 20 Mbps style summary for Moonlight 画面. */
export function settingsMoonlightVideoLabel(resolutionMode: string, customWidth: number, customHeight: number,
  fps: number, bitrateKbps: number): string {
  let resolution: string = resolutionMode;
  if (resolutionMode === 'custom') {
    resolution = customWidth.toString() + '×' + customHeight.toString();
  } else if (resolutionMode === 'host' || resolutionMode === 'auto' || resolutionMode === 'native') {
    resolution = '自适应';
  }
  const mbps: number = Math.round(bitrateKbps / 100) / 10;
  return resolution + ' · ' + fps.toString() + ' 帧 · ' +
    (Number.isInteger(mbps) ? mbps.toFixed(0) : mbps.toFixed(1)) + ' Mbps';
}
