import {
  SETTINGS_SECTION_ABOUT,
  SETTINGS_SECTION_AI,
  SETTINGS_SECTION_APPEARANCE,
  SETTINGS_SECTION_CLOUD_SYNC,
  SETTINGS_SECTION_CONNECTION_LIVE,
  SETTINGS_SECTION_DIAGNOSTICS,
  SETTINGS_SECTION_DISPLAY_INTERACTION,
  SETTINGS_SECTION_FEEDBACK,
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
 * 设置搜索 (全新视觉). One entry per settings row: its title, words people use for it, the section it sits in,
 * what a tap does and when the row exists.
 * - action: '' expands the section and scrolls to it; 'ai:N' opens AI 助理 section N; anything else is an app
 *   action id (DiagnosticAiAppActionPolicy), the same one the AI uses to open that settings sheet.
 * - requires: '' always shown; otherwise a visibility flag the host page answers (Pro features, device kind…), so a
 *   search never offers a row the page itself hides.
 */
export interface SettingsSearchEntry {
  title: string;
  keywords: string;
  section: string;
  action: string;
  requires: string;
}

function entry(section: string, title: string, keywords: string, action: string = '',
  requires: string = ''): SettingsSearchEntry {
  return { title: title, keywords: keywords, section: section, action: action, requires: requires };
}

const ENTRIES: SettingsSearchEntry[] = [
  // 个性化
  entry(SETTINGS_SECTION_APPEARANCE, '全新视觉', '设置外观 新版设置 经典设置 分组 搜索 界面'),
  entry(SETTINGS_SECTION_APPEARANCE, '主题色', '强调色 颜色 配色 主色 accent', 'settings.appearance'),
  entry(SETTINGS_SECTION_APPEARANCE, '应用图标', '图标 桌面图标 icon', 'settings.appIcon', 'appIcon'),
  entry(SETTINGS_SECTION_APPEARANCE, '深色模式', '暗色 夜间 黑色主题 浅色 dark 主题'),
  entry(SETTINGS_SECTION_APPEARANCE, '跟随系统', '自动深色 系统主题 外观'),
  entry(SETTINGS_SECTION_APPEARANCE, '壁纸', '背景 背景色', 'settings.wallpaper'),
  entry(SETTINGS_SECTION_APPEARANCE, '光晕颜色', '沉浸光晕 光效 光晕', 'settings.haloColor'),
  entry(SETTINGS_SECTION_APPEARANCE, '环境光调节光效', '沉浸光感 光感 环境光 玻璃'),
  entry(SETTINGS_SECTION_APPEARANCE, '隐藏主机卡片敏感信息', '隐私 地址 用户名 端口 隐藏 卡片'),
  // 主页与主机列表
  entry(SETTINGS_SECTION_HOME, 'RustDesk 在线检测', '在线 状态 检测 离线'),
  entry(SETTINGS_SECTION_HOME, '添加主机样式', '加号 添加入口 fab 新版 经典'),
  entry(SETTINGS_SECTION_HOME, '按主机类型分组', '分组卡片 主机分组 协议分组'),
  // 云同步
  entry(SETTINGS_SECTION_CLOUD_SYNC, '管理云同步', '云空间 上传 下载 同步 华为云', 'cloud.sync', 'cloud'),
  entry(SETTINGS_SECTION_CLOUD_SYNC, '本地备份', '备份 导出 文件'),
  entry(SETTINGS_SECTION_CLOUD_SYNC, '从本地恢复', '恢复 导入 还原'),
  entry(SETTINGS_SECTION_CLOUD_SYNC, '允许分身同步剪贴板', '分身 剪贴板 应用分身', '', 'clone'),
  // 连接实况窗
  entry(SETTINGS_SECTION_CONNECTION_LIVE, '后台连接展示', '后台 保持连接 实况窗 状态栏 灵动岛'),
  // 显示与交互
  entry(SETTINGS_SECTION_DISPLAY_INTERACTION, '本地缩放', '缩放 显示比例 画面大小'),
  entry(SETTINGS_SECTION_DISPLAY_INTERACTION, '远程滚轮方向', '滚轮 反转 滚动方向 自然滚动 鼠标', 'settings.remoteWheel'),
  entry(SETTINGS_SECTION_DISPLAY_INTERACTION, '双指缩放', '捏合 放大 缩小 手势', 'settings.remotePinch'),
  entry(SETTINGS_SECTION_DISPLAY_INTERACTION, '竖屏显示', '竖屏 旋转 方向 横屏', 'settings.remotePortrait'),
  entry(SETTINGS_SECTION_DISPLAY_INTERACTION, '关闭快捷退出', '返回 退出 误触 防误退'),
  entry(SETTINGS_SECTION_DISPLAY_INTERACTION, '会话侧栏与顶栏', '控制栏 工具栏 侧栏 顶栏 隐藏 显示', 'settings.controlBar'),
  entry(SETTINGS_SECTION_DISPLAY_INTERACTION, '触控板鼠标样式', '虚拟鼠标 光标 圆环 箭头 指针', '', 'touchDevice'),
  entry(SETTINGS_SECTION_DISPLAY_INTERACTION, '握持手感知对齐', '左手 右手 按钮位置 单手'),
  // 键盘
  entry(SETTINGS_SECTION_VIRTUAL_KEYBOARD, '系统输入法', '输入法 键盘 中文输入', 'settings.keyboard'),
  entry(SETTINGS_SECTION_VIRTUAL_KEYBOARD, '输入行为', '自动弹出 键盘 实体键盘', 'settings.keyboardBehavior'),
  entry(SETTINGS_SECTION_VIRTUAL_KEYBOARD, '快捷键平台', 'windows mac 快捷键 系统', 'settings.keyboardShortcuts'),
  entry(SETTINGS_SECTION_VIRTUAL_KEYBOARD, '功能键与面板', 'f1 esc tab 功能键 面板', 'settings.keyboardFunctions'),
  entry(SETTINGS_SECTION_VIRTUAL_KEYBOARD, '屏蔽鸿蒙快捷键', '系统快捷键 冲突 harmonyos', 'settings.harmonyShortcut'),
  entry(SETTINGS_SECTION_VIRTUAL_KEYBOARD, '自定义组合键', '组合键 宏 快捷键 按键序列', 'settings.keyboardCustom',
    'personalization'),
  // Windows RDP
  entry(SETTINGS_SECTION_RDP, '远端显示方案', '分辨率 缩放 桌面尺寸 dpi', 'settings.rdpDisplay', 'rdpAdvanced'),
  entry(SETTINGS_SECTION_RDP, '远端桌面尺寸', '分辨率 桌面大小 屏幕尺寸', '', 'rdpBasic'),
  entry(SETTINGS_SECTION_RDP, '远端界面大小', '缩放 dpi 字体 windows 缩放', '', 'rdpBasic'),
  entry(SETTINGS_SECTION_RDP, 'RDP 色深', '颜色 位深 画质 32 位 16 位'),
  entry(SETTINGS_SECTION_RDP, 'RDP 操控方式', '触控板 触控 键鼠 鼠标模式'),
  entry(SETTINGS_SECTION_RDP, 'RDP 账号格式', '用户名 邮箱 域 domain 登录'),
  entry(SETTINGS_SECTION_RDP, '跳过连接前证书预检', '证书 预检 安全'),
  entry(SETTINGS_SECTION_RDP, 'TLS 兼容登录', 'nla tls 登录 兼容'),
  entry(SETTINGS_SECTION_RDP, 'RDP 远端音频', '声音 音频 扬声器'),
  entry(SETTINGS_SECTION_RDP, 'RDP 剪贴板同步', '复制 粘贴 剪贴板'),
  entry(SETTINGS_SECTION_RDP, '性能监视与诊断日志', '诊断 帧率 延迟 gfx'),
  entry(SETTINGS_SECTION_RDP, '文件共享盘', '驱动器 共享文件夹 tsclient 文件'),
  entry(SETTINGS_SECTION_RDP, 'Windows 凭据', '账号 密码 凭据 登录信息', 'rdp.credentials'),
  // RustDesk
  entry(SETTINGS_SECTION_RUSTDESK, 'RustDesk 图像质量', '画质 速度 清晰'),
  entry(SETTINGS_SECTION_RUSTDESK, 'RustDesk 编码', 'codec h264 h265 vp8 vp9 av1'),
  entry(SETTINGS_SECTION_RUSTDESK, 'RustDesk 操控方式', '触控板 触控 键鼠'),
  entry(SETTINGS_SECTION_RUSTDESK, '允许隐私模式', '黑屏 隐私 隐藏远端屏幕'),
  entry(SETTINGS_SECTION_RUSTDESK, 'RustDesk 远端音频', '声音 音频'),
  entry(SETTINGS_SECTION_RUSTDESK, '远端应用双指缩放', 'touchscale 双指 缩放'),
  entry(SETTINGS_SECTION_RUSTDESK, '显示连接诊断信息', '诊断 延迟 帧率 码率'),
  entry(SETTINGS_SECTION_RUSTDESK, 'LAN 发现', '局域网 扫描 发现设备'),
  // SSH 终端
  entry(SETTINGS_SECTION_SSH, '管理 SSH 主机', 'ssh 主机 服务器'),
  entry(SETTINGS_SECTION_SSH, 'SSH 密钥保险库', '私钥 密钥 key', 'ssh.keys'),
  entry(SETTINGS_SECTION_SSH, '终端字体颜色', '文字颜色 前景色 颜色', 'settings.terminalColor'),
  entry(SETTINGS_SECTION_SSH, '终端字体大小', '字号 字体 大小', 'settings.terminalFontSize'),
  entry(SETTINGS_SECTION_SSH, '终端行距', '行高 行间距', 'settings.terminalSpacing'),
  entry(SETTINGS_SECTION_SSH, '终端皮肤', '主题 配色 字体 外观', 'settings.sshSkin', 'personalization'),
  entry(SETTINGS_SECTION_SSH, '新 SSH 工作台', '工作台 多会话'),
  entry(SETTINGS_SECTION_SSH, 'SSH 系统通知', '通知 提醒 后台'),
  entry(SETTINGS_SECTION_SSH, 'SSH 输入方式', '输入 键盘 命令'),
  entry(SETTINGS_SECTION_SSH, '终端显示', '恢复默认 重置 终端'),
  // VNC
  entry(SETTINGS_SECTION_VNC, 'VNC 连接默认值', '端口 5900 repeater 直连', 'settings.vncConnection'),
  entry(SETTINGS_SECTION_VNC, 'VNC 超时与连接行为', '超时 重连 等待', 'settings.vncTimeout'),
  entry(SETTINGS_SECTION_VNC, 'VNC 安全策略与 TLS', '加密 明文 安全 tls', 'settings.vncSecurity'),
  entry(SETTINGS_SECTION_VNC, 'VNC 显示与画面', '缩放 画质 编码 色深', 'settings.vncDisplay'),
  entry(SETTINGS_SECTION_VNC, 'VNC 输入与光标', '鼠标 键盘 只读 光标', 'settings.vncInput'),
  entry(SETTINGS_SECTION_VNC, 'VNC 性能监视看板', '性能 帧率 诊断', 'settings.vncPerformance'),
  entry(SETTINGS_SECTION_VNC, 'VNC 剪贴板', '复制 粘贴', 'settings.vncClipboard'),
  entry(SETTINGS_SECTION_VNC, 'VNC 证书管理', 'trust 证书 指纹 信任', 'settings.vncTrust'),
  entry(SETTINGS_SECTION_VNC, '管理 VNC 主机', 'vnc 主机', 'settings.vncHosts'),
  entry(SETTINGS_SECTION_VNC, '管理 VNC Gateway', '网关 gateway', 'settings.vncGateway'),
  // Moonlight
  entry(SETTINGS_SECTION_MOONLIGHT, 'Moonlight 画面', '分辨率 帧率 码率 hdr 编码 串流', 'settings.moonlightVideo'),
  entry(SETTINGS_SECTION_MOONLIGHT, 'Moonlight 音频', '声音 环绕声 音频', 'settings.moonlightAudio'),
  entry(SETTINGS_SECTION_MOONLIGHT, 'Moonlight 控制与手柄', '手柄 游戏手柄 鼠标 键盘 触控', 'settings.moonlightInput'),
  entry(SETTINGS_SECTION_MOONLIGHT, 'Moonlight 网络与安全', '网络 安全 局域网', 'settings.moonlightNetwork'),
  entry(SETTINGS_SECTION_MOONLIGHT, 'Moonlight 诊断', '诊断 统计 日志', 'settings.moonlightDiagnostics'),
  entry(SETTINGS_SECTION_MOONLIGHT, 'Moonlight 配对与信任', '配对 pin 信任 证书', 'settings.moonlightTrust'),
  entry(SETTINGS_SECTION_MOONLIGHT, 'Moonlight 数据管理', '删除 数据 清理', 'settings.moonlightData'),
  // 远程 AI
  entry(SETTINGS_SECTION_AI, '远程 AI 连接与配对', 'codex dsh claude 配对 主机 默认 ai', 'settings.aiHosts', 'aiPro'),
  entry(SETTINGS_SECTION_AI, '远程 AI 显示与恢复', '界面风格 claude 风格 codex 风格 文字大小 工具过程', 'settings.aiDisplay',
    'aiPro'),
  entry(SETTINGS_SECTION_AI, '远程 AI 本机数据管理', '导出 导入 操作记录', 'settings.aiData', 'aiPro'),
  entry(SETTINGS_SECTION_AI, '远程 AI 电脑端安装', '插件 安装 电脑端', 'settings.aiInstall', 'aiPro'),
  // AI 助理
  entry(SETTINGS_SECTION_DIAGNOSTICS, '辅助 AI 配置', 'api key 模型 服务商 deepseek 通义 配置', 'ai:0', 'aiConfig'),
  entry(SETTINGS_SECTION_DIAGNOSTICS, '启动 AI 辅助', 'ai 助理 助手 聊天 提问', 'ai:1', 'aiAssistant'),
  entry(SETTINGS_SECTION_DIAGNOSTICS, 'AI 用量监控', 'token 费用 用量 统计', 'ai:3', 'aiAssistant'),
  entry(SETTINGS_SECTION_DIAGNOSTICS, 'AI 个性化设置', '名字 性格 风格 记忆 偏好', 'ai:4', 'aiAssistant'),
  entry(SETTINGS_SECTION_DIAGNOSTICS, 'AI 对话记录', '历史 会话 对话', 'ai:5', 'aiAssistant'),
  entry(SETTINGS_SECTION_DIAGNOSTICS, 'AI 动效', '动画 悬浮球 小艺风格 siri 风格', 'ai:6', 'aiAssistant'),
  entry(SETTINGS_SECTION_DIAGNOSTICS, 'AI 工具与技能', '技能 工具 插件', 'ai:7', 'aiAssistant'),
  entry(SETTINGS_SECTION_DIAGNOSTICS, 'AI 语音', '语音 朗读 按住说话 音色', 'ai:8', 'aiAssistant'),
  entry(SETTINGS_SECTION_DIAGNOSTICS, '传统日志抓取', '日志 诊断 抓取 导出', 'diagnosticAi.classicLogs'),
  // Pro 功能
  entry(SETTINGS_SECTION_PRO, 'Pro 标识', '标识 徽标 样式', 'settings.proBadge', 'proManager'),
  entry(SETTINGS_SECTION_PRO, '手机通行密钥', '通行密钥 passkey 登录', 'pro.phonePasskey', 'proManager'),
  entry(SETTINGS_SECTION_PRO, '安全密钥重定向', 'usb 安全密钥 webauthn fido', 'pro.securityKey', 'proManager'),
  // 数据安全
  entry(SETTINGS_SECTION_SECURITY, '端到端加密', '加密 主密码 aes 解锁'),
  entry(SETTINGS_SECTION_SECURITY, '密码与秘密回显', '回显 隐藏密码 显示密码', 'settings.secretVisibility'),
  entry(SETTINGS_SECTION_SECURITY, 'SSH 主机指纹', '指纹 known_hosts 信任'),
  entry(SETTINGS_SECTION_SECURITY, 'RDP 证书信任', '证书 信任 windows'),
  entry(SETTINGS_SECTION_SECURITY, 'VNC TLS 证书信任', '证书 信任 tls'),
  entry(SETTINGS_SECTION_SECURITY, 'RustDesk 认证信任', '认证 信任 设备'),
  entry(SETTINGS_SECTION_SECURITY, 'TOTP 隐私保护', '2fa 验证器 锁 身份验证 totp'),
  entry(SETTINGS_SECTION_SECURITY, '2FA 验证器头像', 'logo 首字母 头像'),
  // 教程
  entry(SETTINGS_SECTION_TUTORIAL, '本版本更新日志', '更新 新功能 版本 更新说明', '', 'releaseNotes'),
  entry(SETTINGS_SECTION_TUTORIAL, '快速认识应用', '教程 入门 新手'),
  entry(SETTINGS_SECTION_TUTORIAL, 'Pro 功能介绍', 'pro 会员 功能'),
  entry(SETTINGS_SECTION_TUTORIAL, '操作引导中心', '帮助 步骤 怎么用 引导'),
  entry(SETTINGS_SECTION_TUTORIAL, '连接前准备', '准备 sunshine 服务端 开启远程桌面'),
  // 关于
  entry(SETTINGS_SECTION_ABOUT, '关于应用', '开源 许可 作者 联系方式'),
  entry(SETTINGS_SECTION_ABOUT, '隐私政策', '隐私 权限 数据收集'),
  // 反馈
  entry(SETTINGS_SECTION_FEEDBACK, '反馈', '邮件 群聊 建议 问题 联系', 'feedback')
];

/** Section titles as the settings page shows them; a search result names where its row lives. */
export function settingsSectionTitle(section: string): string {
  if (section === SETTINGS_SECTION_APPEARANCE) { return '个性化'; }
  if (section === SETTINGS_SECTION_HOME) { return '主页与主机列表'; }
  if (section === SETTINGS_SECTION_CLOUD_SYNC) { return '云同步'; }
  if (section === SETTINGS_SECTION_CONNECTION_LIVE) { return '连接实况窗'; }
  if (section === SETTINGS_SECTION_DISPLAY_INTERACTION) { return '显示与交互'; }
  if (section === SETTINGS_SECTION_VIRTUAL_KEYBOARD) { return '键盘'; }
  if (section === SETTINGS_SECTION_RDP) { return 'Windows RDP'; }
  if (section === SETTINGS_SECTION_RUSTDESK) { return 'RustDesk'; }
  if (section === SETTINGS_SECTION_SSH) { return 'SSH 终端'; }
  if (section === SETTINGS_SECTION_VNC) { return 'VNC'; }
  if (section === SETTINGS_SECTION_MOONLIGHT) { return 'Moonlight'; }
  if (section === SETTINGS_SECTION_AI) { return '远程 AI'; }
  if (section === SETTINGS_SECTION_DIAGNOSTICS) { return 'AI 助理'; }
  if (section === SETTINGS_SECTION_PRO) { return 'Pro 功能'; }
  if (section === SETTINGS_SECTION_SECURITY) { return '数据安全'; }
  if (section === SETTINGS_SECTION_TUTORIAL) { return '教程'; }
  if (section === SETTINGS_SECTION_ABOUT) { return '关于'; }
  if (section === SETTINGS_SECTION_FEEDBACK) { return '反馈'; }
  return '设置';
}

export function settingsSearchEntries(): SettingsSearchEntry[] {
  return ENTRIES.slice();
}

function normalized(text: string): string {
  return text.toLowerCase().replace(/\s+/g, '');
}

interface ScoredEntry {
  entry: SettingsSearchEntry;
  score: number;
  order: number;
}

/**
 * Entries matching `query`, best first: the title itself, then words people use for it, then the section's name.
 * Several words separated by spaces must all match somewhere (RDP 音频).
 */
export function settingsSearchMatches(query: string, entries: SettingsSearchEntry[],
  limit: number = 30): SettingsSearchEntry[] {
  const words: string[] = query.toLowerCase().split(/\s+/).filter((word: string): boolean => word.length > 0);
  if (words.length === 0) { return []; }
  const whole: string = words.join('');
  const scored: ScoredEntry[] = [];
  for (let i = 0; i < entries.length; i++) {
    const item: SettingsSearchEntry = entries[i];
    const title: string = normalized(item.title);
    const keywords: string = item.keywords.toLowerCase();
    const section: string = normalized(settingsSectionTitle(item.section));
    let score: number = -1;
    if (title === whole) { score = 100; }
    else if (title.startsWith(whole)) { score = 80; }
    else if (title.indexOf(whole) >= 0) { score = 60; }
    else if (normalized(keywords).indexOf(whole) >= 0) { score = 40; }
    else if (section.indexOf(whole) >= 0) { score = 20; }
    else if (words.length > 1 && words.every((word: string): boolean =>
      title.indexOf(word) >= 0 || keywords.indexOf(word) >= 0 || section.indexOf(word) >= 0)) { score = 30; }
    if (score >= 0) { scored.push({ entry: item, score: score, order: i }); }
  }
  scored.sort((a: ScoredEntry, b: ScoredEntry): number => b.score !== a.score ? b.score - a.score : a.order - b.order);
  return scored.slice(0, Math.max(0, limit)).map((value: ScoredEntry): SettingsSearchEntry => value.entry);
}
