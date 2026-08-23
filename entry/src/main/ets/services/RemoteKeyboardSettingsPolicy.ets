/**
 * Device-local virtual-keyboard preferences and the transport-safe shortcut
 * catalog shared by every graphical remote-session surface.
 */

export type RemoteShortcutPlatform = 'windows' | 'macos';
export type RemoteShortcutCategory = 'editing' | 'system' | 'navigation' | 'desktop' | 'capture';

export interface RemoteShortcutPreset {
  id: string;
  label: string;
  chord: string;
  category: RemoteShortcutCategory;
  keyCodes: Array<number>;
  dangerous: boolean;
}

export interface RemoteKeyboardPreferences {
  shortcutPlatform: RemoteShortcutPlatform;
  simpleKeyboardEnabled: boolean;
  functionKeysVisible: boolean;
  closePanelAfterShortcut: boolean;
}

export const REMOTE_KEYBOARD_SHORTCUT_PLATFORM_KEY: string = 'remoteShortcutPlatformMode';
export const REMOTE_KEYBOARD_SIMPLE_MODE_KEY: string = 'remoteSimpleKeyboardEnabled';
export const REMOTE_KEYBOARD_FUNCTION_KEYS_VISIBLE_KEY: string = 'remoteFunctionKeysVisible';
export const REMOTE_KEYBOARD_CLOSE_AFTER_SHORTCUT_KEY: string = 'remoteShortcutCloseAfterSend';
export const REMOTE_KEYBOARD_PREFERENCES_NAME: string = 'RemoteDesktopAppPrefs';

const CTRL: number = 2072;
const ALT: number = 2045;
const SHIFT: number = 2047;
const META: number = 2076;
const TAB: number = 2049;
const SPACE: number = 2050;
const ESC: number = 2070;
const FORWARD_DELETE: number = 2071;
const PRINT_SCREEN: number = 2079;
const LEFT: number = 2014;
const RIGHT: number = 2015;
const UP: number = 2012;
const DOWN: number = 2013;
const BACKSPACE: number = 2055;
const ENTER: number = 2054;
const PERIOD: number = 2044;
const GRAVE: number = 2056;
const MINUS: number = 2057;
const EQUAL: number = 2058;
const F3: number = 2092;
const F4: number = 2093;
const F5: number = 2094;
const F11: number = 2100;
const LEFT_BRACKET: number = 2059;
const RIGHT_BRACKET: number = 2060;
const COMMA: number = 2043;

function letter(value: string): number {
  const normalized: string = value.trim().toUpperCase();
  if (normalized.length !== 1) { return 0; }
  const code: number = normalized.charCodeAt(0);
  return code >= 65 && code <= 90 ? 2017 + code - 65 : 0;
}

function digit(value: number): number {
  return value >= 0 && value <= 9 ? 2000 + value : 0;
}

function shortcut(id: string, label: string, chord: string,
  category: RemoteShortcutCategory, keyCodes: Array<number>,
  dangerous: boolean = false): RemoteShortcutPreset {
  return { id, label, chord, category, keyCodes, dangerous };
}

function commonEditing(modifier: number, modifierLabel: string,
  redoKey: number, redoChord: string): Array<RemoteShortcutPreset> {
  return [
    shortcut('copy', '复制', modifierLabel + '+C', 'editing', [modifier, letter('C')]),
    shortcut('cut', '剪切', modifierLabel + '+X', 'editing', [modifier, letter('X')]),
    shortcut('paste', '粘贴', modifierLabel + '+V', 'editing', [modifier, letter('V')]),
    shortcut('undo', '撤销', modifierLabel + '+Z', 'editing', [modifier, letter('Z')]),
    shortcut('redo', '重做', redoChord, 'editing', redoKey === letter('Z') ?
      [modifier, SHIFT, redoKey] : [modifier, redoKey]),
    shortcut('selectAll', '全选', modifierLabel + '+A', 'editing', [modifier, letter('A')]),
    shortcut('save', '保存', modifierLabel + '+S', 'editing', [modifier, letter('S')]),
    shortcut('find', '查找', modifierLabel + '+F', 'editing', [modifier, letter('F')]),
    shortcut('print', '打印', modifierLabel + '+P', 'editing', [modifier, letter('P')]),
    shortcut('new', '新建', modifierLabel + '+N', 'editing', [modifier, letter('N')]),
    shortcut('open', '打开', modifierLabel + '+O', 'editing', [modifier, letter('O')]),
    shortcut('closeDocument', '关闭标签/窗口', modifierLabel + '+W', 'editing',
      [modifier, letter('W')]),
    shortcut('bold', '粗体', modifierLabel + '+B', 'editing', [modifier, letter('B')]),
    shortcut('italic', '斜体', modifierLabel + '+I', 'editing', [modifier, letter('I')]),
    shortcut('underline', '下划线', modifierLabel + '+U', 'editing', [modifier, letter('U')])
  ];
}

function windowsShortcuts(): Array<RemoteShortcutPreset> {
  const result: Array<RemoteShortcutPreset> = commonEditing(CTRL, 'Ctrl', letter('Y'), 'Ctrl+Y');
  result.push(
    shortcut('winRedoAlternate', '重做（兼容）', 'Ctrl+Shift+Z', 'editing',
      [CTRL, SHIFT, letter('Z')]),
    shortcut('winStart', '开始菜单', 'Win', 'system', [META]),
    shortcut('winSwitchApps', '切换应用', 'Alt+Tab', 'system', [ALT, TAB]),
    shortcut('winSwitchAppsReverse', '反向切换应用', 'Alt+Shift+Tab', 'system',
      [ALT, SHIFT, TAB]),
    shortcut('winCloseWindow', '关闭窗口', 'Alt+F4', 'system', [ALT, F4]),
    shortcut('winTaskManager', '任务管理器', 'Ctrl+Shift+Esc', 'system', [CTRL, SHIFT, ESC]),
    shortcut('winSecurity', '安全选项', 'Ctrl+Alt+Del', 'system',
      [CTRL, ALT, FORWARD_DELETE], true),
    shortcut('winRun', '运行', 'Win+R', 'system', [META, letter('R')]),
    shortcut('winExplorer', '文件资源管理器', 'Win+E', 'system', [META, letter('E')]),
    shortcut('winSettings', '系统设置', 'Win+I', 'system', [META, letter('I')]),
    shortcut('winSearch', '系统搜索', 'Win+S', 'system', [META, letter('S')]),
    shortcut('winQuickLink', '快捷链接菜单', 'Win+X', 'system', [META, letter('X')]),
    shortcut('winNotifications', '通知中心', 'Win+N', 'system', [META, letter('N')]),
    shortcut('winClipboard', '剪贴板历史', 'Win+V', 'system', [META, letter('V')]),
    shortcut('winEmoji', '表情与符号', 'Win+.', 'system', [META, PERIOD]),
    shortcut('winProject', '投影模式', 'Win+P', 'system', [META, letter('P')]),
    shortcut('winConnect', '连接无线显示器', 'Win+K', 'system', [META, letter('K')]),
    shortcut('winAccessibility', '辅助功能', 'Win+U', 'system', [META, letter('U')]),
    shortcut('winLock', '锁定电脑', 'Win+L', 'system', [META, letter('L')], true),
    shortcut('winDesktop', '显示桌面', 'Win+D', 'desktop', [META, letter('D')]),
    shortcut('winMinimizeAll', '最小化所有窗口', 'Win+M', 'desktop', [META, letter('M')]),
    shortcut('winRestoreAll', '还原最小化窗口', 'Win+Shift+M', 'desktop',
      [META, SHIFT, letter('M')]),
    shortcut('winTaskView', '任务视图', 'Win+Tab', 'desktop', [META, TAB]),
    shortcut('winSnapLeft', '窗口贴靠左侧', 'Win+←', 'desktop', [META, LEFT]),
    shortcut('winSnapRight', '窗口贴靠右侧', 'Win+→', 'desktop', [META, RIGHT]),
    shortcut('winMaximize', '最大化窗口', 'Win+↑', 'desktop', [META, UP]),
    shortcut('winRestoreMinimize', '还原/最小化窗口', 'Win+↓', 'desktop', [META, DOWN]),
    shortcut('winNewDesktop', '新建桌面', 'Win+Ctrl+D', 'desktop', [META, CTRL, letter('D')]),
    shortcut('winCloseDesktop', '关闭桌面', 'Win+Ctrl+F4', 'desktop', [META, CTRL, F4]),
    shortcut('winPreviousDesktop', '上一个桌面', 'Win+Ctrl+←', 'desktop', [META, CTRL, LEFT]),
    shortcut('winNextDesktop', '下一个桌面', 'Win+Ctrl+→', 'desktop', [META, CTRL, RIGHT]),
    shortcut('winPreviousTab', '上一个标签', 'Ctrl+Shift+Tab', 'navigation', [CTRL, SHIFT, TAB]),
    shortcut('winNextTab', '下一个标签', 'Ctrl+Tab', 'navigation', [CTRL, TAB]),
    shortcut('winNewTab', '新建标签', 'Ctrl+T', 'navigation', [CTRL, letter('T')]),
    shortcut('winReopenTab', '恢复关闭的标签', 'Ctrl+Shift+T', 'navigation',
      [CTRL, SHIFT, letter('T')]),
    shortcut('winAddress', '定位地址栏', 'Ctrl+L', 'navigation', [CTRL, letter('L')]),
    shortcut('winHistory', '打开历史记录', 'Ctrl+H', 'navigation', [CTRL, letter('H')]),
    shortcut('winDownloads', '打开下载内容', 'Ctrl+J', 'navigation', [CTRL, letter('J')]),
    shortcut('winFindNext', '查找下一个', 'F3', 'navigation', [F3]),
    shortcut('winBack', '后退', 'Alt+←', 'navigation', [ALT, LEFT]),
    shortcut('winForward', '前进', 'Alt+→', 'navigation', [ALT, RIGHT]),
    shortcut('winRefresh', '刷新', 'F5', 'navigation', [F5]),
    shortcut('winFullscreen', '全屏', 'F11', 'navigation', [F11]),
    shortcut('winCaptureArea', '区域截图', 'Win+Shift+S', 'capture', [META, SHIFT, letter('S')]),
    shortcut('winPrintScreen', '截取全屏', 'PrtSc', 'capture', [PRINT_SCREEN]),
    shortcut('winCaptureWindow', '截取当前窗口', 'Alt+PrtSc', 'capture', [ALT, PRINT_SCREEN]),
    shortcut('winGameBar', '游戏栏', 'Win+G', 'capture', [META, letter('G')]),
    shortcut('winRecord', '开始/停止录屏', 'Win+Alt+R', 'capture', [META, ALT, letter('R')])
  );
  return result;
}

function macShortcuts(): Array<RemoteShortcutPreset> {
  const result: Array<RemoteShortcutPreset> = commonEditing(META, 'Cmd', letter('Z'), 'Cmd+Shift+Z');
  result.push(
    shortcut('macPasteMatchStyle', '粘贴并匹配样式', 'Option+Shift+Cmd+V', 'editing',
      [ALT, SHIFT, META, letter('V')]),
    shortcut('macSwitchApps', '切换应用', 'Cmd+Tab', 'system', [META, TAB]),
    shortcut('macSwitchAppsReverse', '反向切换应用', 'Cmd+Shift+Tab', 'system',
      [META, SHIFT, TAB]),
    shortcut('macSwitchWindows', '切换同一应用窗口', 'Cmd+`', 'system', [META, GRAVE]),
    shortcut('macQuitApp', '退出应用', 'Cmd+Q', 'system', [META, letter('Q')], true),
    shortcut('macForceQuit', '强制退出', 'Cmd+Option+Esc', 'system', [META, ALT, ESC], true),
    shortcut('macMinimize', '最小化窗口', 'Cmd+M', 'system', [META, letter('M')]),
    shortcut('macHideApp', '隐藏应用', 'Cmd+H', 'system', [META, letter('H')]),
    shortcut('macHideOthers', '隐藏其他应用', 'Option+Cmd+H', 'system',
      [ALT, META, letter('H')]),
    shortcut('macSpotlight', '聚焦搜索', 'Cmd+Space', 'system', [META, SPACE]),
    shortcut('macFullscreen', '进入/退出全屏', 'Ctrl+Cmd+F', 'system',
      [CTRL, META, letter('F')]),
    shortcut('macLock', '锁定屏幕', 'Ctrl+Cmd+Q', 'system', [CTRL, META, letter('Q')], true),
    shortcut('macPreferences', '应用设置', 'Cmd+,', 'system', [META, COMMA]),
    shortcut('macLogout', '退出登录', 'Shift+Cmd+Q', 'system',
      [SHIFT, META, letter('Q')], true),
    shortcut('macMissionControl', '调度中心', 'Ctrl+↑', 'desktop', [CTRL, UP]),
    shortcut('macAppExpose', '应用窗口', 'Ctrl+↓', 'desktop', [CTRL, DOWN]),
    shortcut('macPreviousDesktop', '上一个空间', 'Ctrl+←', 'desktop', [CTRL, LEFT]),
    shortcut('macNextDesktop', '下一个空间', 'Ctrl+→', 'desktop', [CTRL, RIGHT]),
    shortcut('macNewFolder', '新建文件夹', 'Shift+Cmd+N', 'system', [SHIFT, META, letter('N')]),
    shortcut('macGetInfo', '显示简介', 'Cmd+I', 'system', [META, letter('I')]),
    shortcut('macMoveTrash', '移到废纸篓', 'Cmd+Delete', 'system', [META, BACKSPACE], true),
    shortcut('macQuickLook', '快速查看', 'Space', 'navigation', [SPACE]),
    shortcut('macRename', '重命名', 'Enter', 'navigation', [ENTER]),
    shortcut('macDuplicate', '制作副本', 'Cmd+D', 'navigation', [META, letter('D')]),
    shortcut('macGoFolder', '前往文件夹', 'Shift+Cmd+G', 'navigation', [SHIFT, META, letter('G')]),
    shortcut('macPreviousTab', '上一个标签', 'Ctrl+Shift+Tab', 'navigation', [CTRL, SHIFT, TAB]),
    shortcut('macNextTab', '下一个标签', 'Ctrl+Tab', 'navigation', [CTRL, TAB]),
    shortcut('macNewTab', '新建标签', 'Cmd+T', 'navigation', [META, letter('T')]),
    shortcut('macReopenTab', '恢复关闭的标签', 'Cmd+Shift+T', 'navigation',
      [META, SHIFT, letter('T')]),
    shortcut('macAddress', '定位地址栏', 'Cmd+L', 'navigation', [META, letter('L')]),
    shortcut('macHistory', '打开历史记录', 'Cmd+Y', 'navigation', [META, letter('Y')]),
    shortcut('macDownloads', '打开下载内容', 'Option+Cmd+L', 'navigation',
      [ALT, META, letter('L')]),
    shortcut('macBack', '后退', 'Cmd+[', 'navigation', [META, LEFT_BRACKET]),
    shortcut('macForward', '前进', 'Cmd+]', 'navigation', [META, RIGHT_BRACKET]),
    shortcut('macLineStart', '行首', 'Cmd+←', 'navigation', [META, LEFT]),
    shortcut('macLineEnd', '行尾', 'Cmd+→', 'navigation', [META, RIGHT]),
    shortcut('macZoomIn', '放大', 'Cmd+=', 'navigation', [META, EQUAL]),
    shortcut('macZoomOut', '缩小', 'Cmd+-', 'navigation', [META, MINUS]),
    shortcut('macCaptureFull', '截取全屏', 'Shift+Cmd+3', 'capture', [SHIFT, META, digit(3)]),
    shortcut('macCaptureArea', '选区截图', 'Shift+Cmd+4', 'capture', [SHIFT, META, digit(4)]),
    shortcut('macCaptureToolbar', '截图工具栏', 'Shift+Cmd+5', 'capture', [SHIFT, META, digit(5)]),
    shortcut('macCaptureClipboard', '全屏截图到剪贴板', 'Ctrl+Shift+Cmd+3', 'capture',
      [CTRL, SHIFT, META, digit(3)]),
    shortcut('macAreaClipboard', '选区截图到剪贴板', 'Ctrl+Shift+Cmd+4', 'capture',
      [CTRL, SHIFT, META, digit(4)])
  );
  return result;
}

export function normalizeRemoteShortcutPlatform(value: string): RemoteShortcutPlatform {
  const normalized: string = value.trim().toLowerCase();
  return normalized === 'macos' || normalized === 'mac' || normalized === 'command' ?
    'macos' : 'windows';
}

export function defaultRemoteKeyboardPreferences(): RemoteKeyboardPreferences {
  return {
    shortcutPlatform: 'windows',
    simpleKeyboardEnabled: false,
    functionKeysVisible: true,
    closePanelAfterShortcut: false
  };
}

export function normalizeRemoteKeyboardPreferences(
  shortcutPlatform: string,
  simpleKeyboardEnabled: boolean,
  functionKeysVisible: boolean,
  closePanelAfterShortcut: boolean
): RemoteKeyboardPreferences {
  return {
    shortcutPlatform: normalizeRemoteShortcutPlatform(shortcutPlatform),
    simpleKeyboardEnabled,
    functionKeysVisible,
    closePanelAfterShortcut
  };
}

export function remoteShortcutCategories(): Array<RemoteShortcutCategory> {
  return ['editing', 'system', 'navigation', 'desktop', 'capture'];
}

export function remoteShortcutCategoryLabel(category: RemoteShortcutCategory): string {
  if (category === 'editing') { return '编辑'; }
  if (category === 'system') { return '系统与窗口'; }
  if (category === 'navigation') { return '导航'; }
  if (category === 'desktop') { return '桌面与空间'; }
  return '截图';
}

export function remoteShortcutPresets(
  platform: RemoteShortcutPlatform,
  category?: RemoteShortcutCategory
): Array<RemoteShortcutPreset> {
  const source: Array<RemoteShortcutPreset> = platform === 'macos' ?
    macShortcuts() : windowsShortcuts();
  if (category === undefined) { return source; }
  return source.filter((item: RemoteShortcutPreset): boolean => item.category === category);
}
