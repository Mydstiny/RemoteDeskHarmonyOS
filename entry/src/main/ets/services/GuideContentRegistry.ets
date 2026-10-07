/**
 * GuideContentRegistry — 全应用引导的唯一内容源。
 *
 * 首次引导只回答“选什么、先做什么”；设置内的操作引导中心再按设备与协议
 * 展开步骤。这样既覆盖完整能力，也不会强迫新用户读完一部长手册。
 */
export interface GuideContentPage {
  id: string;
  symbol: ResourceStr;
  title: string;
  desc: string;
  /** Small label above the title, e.g. 「选择协议」 or 「新功能」. */
  tag?: string;
  /** Up to five short bullet lines shown under the description. */
  points?: string[];
  /** HarmonyOS system symbol drawn instead of `symbol` when present. */
  glyph?: Resource;
  /** Theme color (#RRGGBB) of this slide's artwork; the app accent is used when absent. */
  hue?: string;
}

export type GuideDevice = 'phone' | 'tablet' | 'desktop';
/** A guide category: 开始 (all), one protocol, 远程 AI (ai) or AI 助理 (assistant). */
export type GuideProtocol = 'all' | 'rdp' | 'rustdesk' | 'ssh' | 'vnc' | 'moonlight' | 'ai' | 'assistant';

export interface GuideProtocolOption {
  id: GuideProtocol;
  label: string;
  summary: string;
}

export interface GuideLesson {
  id: string;
  protocol: GuideProtocol;
  devices: GuideDevice[];
  title: string;
  summary: string;
  steps: string[];
  note: string;
  /** Where it starts in the app (设置 → 远程 AI), shown above the steps; empty when there is no single place. */
  path: string;
}

const ALL_DEVICES: GuideDevice[] = ['phone', 'tablet', 'desktop'];
const TOUCH_DEVICES: GuideDevice[] = ['phone', 'tablet'];

function clonePage(page: GuideContentPage): GuideContentPage {
  const copy: GuideContentPage = { id: page.id, symbol: page.symbol, title: page.title, desc: page.desc };
  if (page.tag !== undefined) { copy.tag = page.tag; }
  if (page.points !== undefined) { copy.points = page.points.slice(); }
  if (page.glyph !== undefined) { copy.glyph = page.glyph; }
  if (page.hue !== undefined) { copy.hue = page.hue; }
  return copy;
}

function cloneLesson(lesson: GuideLesson): GuideLesson {
  const devices: GuideDevice[] = [];
  const steps: string[] = [];
  lesson.devices.forEach((device: GuideDevice): void => { devices.push(device); });
  lesson.steps.forEach((step: string): void => { steps.push(step); });
  return {
    id: lesson.id,
    protocol: lesson.protocol,
    devices: devices,
    title: lesson.title,
    summary: lesson.summary,
    steps: steps,
    note: lesson.note,
    path: lesson.path
  };
}

export function guideDeviceFor(isDesktopDevice: boolean, isPadDevice: boolean,
  breakpoint: string): GuideDevice {
  if (isDesktopDevice) { return 'desktop'; }
  if (isPadDevice) { return 'tablet'; }
  // 设备类型不可用时才用窗口断点兜底；手机横屏不能因此永久变成 Pad。
  return breakpoint === 'lg' || breakpoint === 'xl' ? 'tablet' : 'phone';
}

export function guideDeviceLabel(device: GuideDevice): string {
  if (device === 'desktop') { return 'PC / 2in1'; }
  if (device === 'tablet') { return 'Pad / 展开态折叠屏'; }
  return '手机';
}

export function guideDeviceSummary(device: GuideDevice): string {
  if (device === 'desktop') { return '实体键鼠、独立会话窗口与拖放优先'; }
  if (device === 'tablet') { return '触控与外接键鼠并用，适合分栏和多任务'; }
  return '触控板手势、虚拟键盘与贴边控制栏优先';
}

export function guideProtocolOptions(): GuideProtocolOption[] {
  return [
    { id: 'all', label: '开始', summary: '主机、设置、安全与排障' },
    { id: 'rdp', label: 'RDP', summary: 'Windows 远程桌面' },
    { id: 'rustdesk', label: 'RustDesk', summary: '跨平台远控' },
    { id: 'ssh', label: 'SSH / SFTP', summary: '终端与文件' },
    { id: 'vnc', label: 'VNC', summary: '标准兼容远控' },
    { id: 'moonlight', label: 'Moonlight', summary: '低延迟串流' },
    { id: 'ai', label: '远程 AI', summary: '电脑上的 Codex、DSH、Pi' },
    { id: 'assistant', label: 'AI 助理', summary: '聊天、语音与诊断' }
  ];
}

const SHARED_GUIDE_PAGES: GuideContentPage[] = [
  {
    id: 'welcome-five-protocols',
    symbol: $rawfile('icons/computer-desktop.svg'),
    glyph: $r('sys.symbol.desktop_fill'),
    tag: '欢迎',
    hue: '#4F7CFF',
    title: '一个应用，连接你的所有电脑',
    desc: '远程桌面、服务器终端和游戏串流都在同一个工作台里，手机、平板和鸿蒙 PC 用法一致。',
    points: ['五种协议：RDP、RustDesk、SSH/SFTP、VNC、Moonlight', '主机、凭据和密钥可选择云同步', '每台设备按自己的屏幕和输入方式排布']
  },
  {
    id: 'choose-by-goal',
    symbol: $rawfile('icons/globe-alt.svg'),
    glyph: $r('sys.symbol.list_bullet'),
    tag: '选择协议',
    hue: '#7B61FF',
    title: '按要做的事选协议',
    desc: '不确定时就照下面选，之后随时可以给同一台电脑再加一种连接方式。',
    points: ['RDP · 完整的 Windows 桌面', 'RustDesk · 跨平台远程协助', 'SSH / SFTP · 命令行与文件管理', 'VNC · 已经装好 VNC 服务的电脑', 'Moonlight · 游戏与高帧率串流']
  },
  {
    id: 'home-at-a-glance',
    symbol: $rawfile('icons/computer-desktop.svg'),
    glyph: $r('sys.symbol.house_fill'),
    tag: '工作台',
    hue: '#FF8A3D',
    title: '主机一目了然',
    desc: '主页按协议把主机分好类，搜索和在线状态帮你很快找到要连的那一台。',
    points: ['按协议分类展示，也可以换回传统列表', '搜索名称或地址，按在线、离线筛选', 'RustDesk 主机会自动检测是否在线', '局域网发现：找到附近已开启的远程服务']
  },
  {
    id: 'connect-safely',
    symbol: $rawfile('icons/shield-check.svg'),
    glyph: $r('sys.symbol.lock_shield_fill'),
    tag: '安全连接',
    hue: '#2BB673',
    title: '第一次连接，先核对身份',
    desc: '远端服务开好后点底部「+」添加主机。首次连接会请你确认对方身份，只信任你能核对的设备。',
    points: ['RDP / VNC 核对证书，SSH 核对指纹', 'RustDesk 核对被控端，Moonlight 输入配对码', '密码与私钥加密保存在本机']
  },
  {
    id: 'security-locks',
    symbol: $rawfile('icons/shield-check.svg'),
    glyph: $r('sys.symbol.lock_fill'),
    tag: '隐私与安全',
    hue: '#E25B8A',
    title: '应用锁、主机锁与 2FA',
    desc: '给整个应用或单台主机加一道验证；常用的两步验证码也能放在这里，随手复制。',
    points: ['应用锁：打开应用时验证身份', '主机锁：连接重要主机前再验证一次', '内置 2FA 验证码，可选加密云同步', '敏感信息默认隐藏，需要时再显示']
  },
  {
    id: 'session-toolkit',
    symbol: $rawfile('icons/cog-6-tooth.svg'),
    glyph: $r('sys.symbol.keyboard'),
    tag: '会话中',
    hue: '#00A3A3',
    title: '常用工具都在手边',
    desc: '远程画面的边缘有控制入口，键盘、快捷键、显示和文件传输都从这里打开。',
    points: ['贴边入口：键盘、组合键、显示与画质', '三指上下滑动滚动，滚轮方向和速度在会话栏里直接调', 'RDP 与 RustDesk 会话里直接收发文件', 'SSH：多标签、SFTP 文件和传输中心']
  },
  {
    id: 'ai-assistant',
    symbol: $rawfile('icons/cloud.svg'),
    glyph: $r('sys.symbol.wand_and_stars'),
    tag: 'AI 助理',
    hue: '#8B5CF6',
    title: 'AI 助理随时帮忙',
    desc: '配置好你自己的 AI 服务后，主页、设置和连接中都能叫它：问问题、改设置、排查连接，也能接着用电脑上的 AI。',
    points: ['聊天与语音：写作、翻译、读文档、设提醒', '连接中以悬浮球出现，不挡远程画面', '远程 AI：在手机上继续和审批电脑上的 Codex、DSH、Pi', 'Pro 功能，现在全部免费试用']
  },
  {
    id: 'data-recovery-and-help',
    symbol: $rawfile('icons/cloud.svg'),
    glyph: $r('sys.symbol.cloud_fill'),
    tag: '数据与帮助',
    hue: '#3BA7FF',
    title: '数据由你掌控，问题有迹可查',
    desc: '云同步只同步你勾选的数据；配对信任和证书按协议分别保存在本机。',
    points: ['设置 → 云同步：选择要同步的数据', '恢复备份前先确认方向，避免覆盖', '遇到问题记下错误码，在「设置 → 日志」导出脱敏诊断']
  }
];

function sharedPages(): GuideContentPage[] {
  const pages: GuideContentPage[] = [];
  SHARED_GUIDE_PAGES.forEach((page: GuideContentPage): void => { pages.push(clonePage(page)); });
  return pages;
}

function devicePoints(device: GuideDevice): string[] {
  if (device === 'desktop') {
    return ['每个远程会话一个独立窗口，可并排摆放', '实体键鼠直通，鸿蒙快捷键可按需屏蔽', '文件可直接拖放到 SFTP 和远程会话'];
  }
  if (device === 'tablet') {
    return ['触控与外接键鼠可以随时切换', '主机列表和设置按两栏排布', '分屏、悬浮窗里也能保持会话'];
  }
  return ['单指移动光标，轻点即点击，三指上下滑动滚动', '贴边控制柄随时呼出键盘和工具', '横竖屏都能用，输入法弹出时画面自动避让'];
}

function deviceGuidePage(device: GuideDevice): GuideContentPage {
  return {
    id: 'device-path-' + device,
    symbol: $rawfile('icons/computer-desktop.svg'),
    glyph: device === 'desktop' ? $r('sys.symbol.display') : device === 'tablet' ? $r('sys.symbol.rectangle_on_rectangle') :
      $r('sys.symbol.mouse'),
    tag: '为' + guideDeviceLabel(device) + '优化',
    hue: '#00A3FF',
    title: device === 'desktop' ? '在 PC 上，像本地一样操作' : device === 'tablet' ? '在平板上，触控键鼠两相宜' :
      '在手机上，一只手也能操控',
    desc: guideDeviceSummary(device) + '。常用操作已放在最顺手的位置。',
    points: devicePoints(device)
  };
}

export function firstInstallGuidePages(device: GuideDevice = 'phone'): GuideContentPage[] {
  const pages: GuideContentPage[] = sharedPages();
  pages.splice(3, 0, deviceGuidePage(device));
  pages.push({
    id: 'start-first-host',
    symbol: $rawfile('icons/shield-check.svg'),
    glyph: $r('sys.symbol.plus_circle_fill'),
    tag: '开始',
    hue: '#4F7CFF',
    title: '添加第一台主机',
    desc: '准备好了。进入工作台后，三步就能连上第一台电脑。',
    points: ['点底部「+」，按用途选择协议', '填写地址和登录信息，高级选项先保持默认', '保存后点主机卡片即可连接']
  });
  return pages;
}

/**
 * Swiper 的内容在首帧、设备识别刷新和版本说明切换时都必须保持非空。
 * 返回副本，避免 UI 状态意外修改注册表或调用方持有的数组。
 */
export function ensureGuidePages(pages: GuideContentPage[],
  fallbackDevice: GuideDevice = 'phone'): GuideContentPage[] {
  const source: GuideContentPage[] = pages.length > 0 ? pages : firstInstallGuidePages(fallbackDevice);
  const result: GuideContentPage[] = [];
  source.forEach((page: GuideContentPage): void => { result.push(clonePage(page)); });
  return result;
}

/** Keeps Swiper state valid when adaptive content is replaced during a layout change. */
export function clampGuidePageIndex(index: number, pageCount: number): number {
  if (!Number.isSafeInteger(index) || !Number.isSafeInteger(pageCount) || pageCount <= 0) { return 0; }
  if (index < 0) { return 0; }
  return index >= pageCount ? pageCount - 1 : index;
}

export function settingsUsageGuidePages(device: GuideDevice = 'phone'): GuideContentPage[] {
  const pages: GuideContentPage[] = sharedPages();
  pages.splice(3, 0, deviceGuidePage(device));
  pages.push({
    id: 'revisit',
    symbol: $rawfile('icons/cog-6-tooth.svg'),
    glyph: $r('sys.symbol.info_circle_fill'),
    tag: '随时查看',
    hue: '#9B5DE5',
    title: '复杂操作不必一次记住',
    desc: '在「设置 → 教程」里可以按设备和协议，逐步查看每项操作。',
    points: ['操作引导中心：连接、操控、文件、安全与排障', '连接前准备：各协议服务端如何开启', '本版本更新日志：这一版改了什么']
  });
  return pages;
}

const GUIDE_LESSONS: GuideLesson[] = [
  {
    id: 'common-first-host', protocol: 'all', devices: ALL_DEVICES, path: '主机列表 → 底部“+”',
    title: '添加并连接第一台主机', summary: '从“+”到首次安全连接',
    steps: [
      '在主机列表点底部“+”，按用途选择 RDP、RustDesk、SSH、VNC、Moonlight 或远程 AI。',
      '填写地址、端口和当前协议要求的凭据；不确定的高级选项先保留默认值。填了内容后关闭或下滑，会先问是否放弃。',
      '保存后点主机卡片连接；首次连接出现证书、指纹、配对码或远端批准时，先在目标设备上核对。',
      '进入会话后只调整影响当前问题的设置；画面、输入和网络设置可分别恢复默认。'
    ], note: '不要在来源不明的提示中提交密码、动态口令或信任变更。'
  },
  {
    id: 'common-phone-controls', protocol: 'all', devices: ['phone'], path: '会话中 → 贴边控制柄',
    title: '手机上的通用操控', summary: '触控板手势、虚拟键盘与滚轮',
    steps: [
      '远程桌面默认用触控板映射：单指移动光标、轻点左键、双指轻点右键、三指上下滑动滚动。',
      '开启双指缩放时，双指只用来缩放和移动画面；没开缩放时双指上下滑动也能滚动。',
      '需要键盘或组合键时，点贴边控制柄或会话栏（三指轻点不再打开控制面板）。',
      '滚得太快或太慢，在会话栏里直接调滚轮方向和速度（RDP 控制中心、RustDesk「鼠标与触控」、VNC「滚轮」），或到“设置 → 显示与交互 → 远程滚轮”。'
    ], note: '若手势与远端应用冲突，可在“显示与交互”或协议设置中关闭本地画布缩放。'
  },
  {
    id: 'common-tablet-controls', protocol: 'all', devices: ['tablet'], path: '会话中 → 顶部或贴边工具栏',
    title: 'Pad 与展开态折叠屏', summary: '触控、键鼠与多任务配合',
    steps: [
      '纯触控时先用触控板模式处理桌面应用，需要直接点按时再切到触控模式。',
      '连接实体键盘或鼠标后切到键鼠模式；系统快捷键是否转发由各协议设置决定。',
      '横屏或展开态会显示更多会话工具；窗口尺寸变化时，当前连接和未提交输入会保持。',
      'SSH/SFTP 可利用宽屏分栏；鼠标滚轮的方向和速度在“设置 → 显示与交互 → 远程滚轮”按协议调整。'
    ], note: '折叠或旋转设备时先完成正在进行的拖拽、文件选择或安全确认。'
  },
  {
    id: 'common-desktop-controls', protocol: 'all', devices: ['desktop'], path: '会话窗口 → 顶部工具栏',
    title: 'PC / 2in1 上的通用操控', summary: '独立窗口、键鼠与拖放',
    steps: [
      '从主机卡片发起连接并完成认证后，远程会话进入独立窗口；主工作台仍可继续管理其他主机。',
      '优先使用实体键鼠；组合键、系统快捷键和显示比例由会话顶部工具栏控制。',
      'RDP、RustDesk 支持时可把本地文件拖入远程画面；SSH 文件请从 SFTP 工作区传输。',
      '主机卡片支持右键菜单，内容与“⋯”菜单相同；关闭窗口前先用会话内“断开”。'
    ], note: '自由窗口过窄时界面会切换到紧凑布局，但设备仍按 PC 的键鼠行为处理。'
  },
  {
    id: 'common-workspace', protocol: 'all', devices: ALL_DEVICES, path: '底部栏：主机、密钥、中继',
    title: '整理主机、密钥、2FA 和中继', summary: '知道每类资料放在哪里',
    steps: [
      '主机列表保存连接入口；右滑或卡片的“⋯”菜单（PC 和全新视觉）可编辑、上锁、检测、多选或删除；搜索覆盖名称、地址和 RustDesk ID。',
      '密钥保险库保存 SSH 私钥和 2FA 验证码；可先添加密钥，再从 SSH 主机选择或部署对应公钥。',
      '中继页管理 RustDesk 中继与 VNC Gateway；测试会分别显示 ID 服务器和中继是否可达。',
      '多选后批量删除会先确认；含已上锁的主机或密钥时，统一验证一次身份。'
    ], note: '删除主机不等于删除密钥、证书或远端数据；安全资料在“设置 → 安全”单独管理。'
  },
  {
    id: 'common-settings', protocol: 'all', devices: ALL_DEVICES, path: '设置 → 顶部搜索',
    title: '找到并修改设置', summary: '搜索、全新视觉与按协议保存',
    steps: [
      '在设置顶部搜索框输入“滚轮”“画质”“配对”等关键词，直接跳到对应设置。',
      '“设置 → 个性化 → 全新视觉”可切换新外观：设置分为通用、连接协议、AI 与 Pro、安全与数据、帮助五组，各项直接显示当前值。',
      '显示与交互里的远程滚轮、双指缩放、竖屏显示、会话侧栏与顶栏都按协议设置，改了就保存并提示“已保存”。',
      '也可以直接对 AI 助理说“把 VNC 滚轮速度调到 200%”，确认后由它替你修改，每项都能撤销。'
    ], note: '经典外观和全新视觉的功能、保存方式完全相同，可以随时切换。'
  },
  {
    id: 'common-security', protocol: 'all', devices: ALL_DEVICES, path: '设置 → 安全',
    title: '主机锁、密钥锁与隐私', summary: '敏感资料先验证身份',
    steps: [
      '在主机或密钥的“⋯”菜单里上锁；上锁的条目查看、编辑、删除前都要验证人脸、指纹或锁屏密码。',
      '2FA 验证码解锁后，应用进入后台会自动重新上锁。',
      '“设置 → 安全”管理端到端加密、密码回显、SSH 主机指纹、各协议的证书信任和 2FA 隐私保护。',
      '同步来的已锁定条目，在本机验证身份后即可使用。'
    ], note: '上锁只保护本机查看和修改，不会改变远端服务器的密码或权限。'
  },
  {
    id: 'common-cloud', protocol: 'all', devices: ALL_DEVICES, path: '设置 → 云同步',
    title: '云同步、备份与换机', summary: '先选范围，再确认方向',
    steps: [
      '先登录华为账号并确认云空间可用，再进入“设置 → 云同步”选择数据范围。',
      '上传表示以本机为准写入云端；下载表示从云端恢复到当前账号的数据域。',
      '导出备份用于离线留档，导入会先校验版本并安全合并；不要把备份文件交给不可信的人。',
      'Moonlight 的配对信任、证书与客户端私钥，以及远程 AI 的配对凭据都只留在本机，换机后需要重新配对。'
    ], note: '任何覆盖或清空操作都会二次确认；方向不明确时先导出备份。'
  },
  {
    id: 'common-diagnostics', protocol: 'all', devices: ALL_DEVICES, path: '设置 → 日志 / AI 助理',
    title: '连接失败时的排查顺序', summary: '从可达性到脱敏日志',
    steps: [
      '先确认目标设备开机、服务已启动，地址和端口可从当前网络访问。',
      '再核对协议、凭据、证书、指纹或配对状态，以及 VPN、防火墙和中继配置。',
      '画面或输入异常时先恢复该协议的显示、编码与操控默认值，然后重新连接。',
      '仍失败时让 AI 助理诊断并抓取脱敏日志，或到“设置 → 日志”手动抓取，再通过“反馈”发送。'
    ], note: '诊断默认脱敏；提交前仍应检查说明中是否包含你手动输入的主机名称。'
  },
  {
    id: 'rdp-prepare', protocol: 'rdp', devices: ALL_DEVICES, path: '主机列表 → “+” → RDP',
    title: '准备 Windows 与首次连接', summary: '远程桌面、账户与证书',
    steps: [
      '在 Windows 专业版或企业版开启“远程桌面”，确认允许的用户并放行 TCP 3389 或自定义端口。',
      '添加 RDP 主机时填写地址、用户名，并选择密码、Windows 凭据、空密码确认或 Restricted Admin Hash 等实际认证方式。',
      '首次连接核对证书主机名与指纹；证书变化时先确认目标机是否重装、换证或被代理。',
      '通过公网连接优先使用 VPN，不建议直接暴露 RDP 端口。'
    ], note: 'Windows 家庭版通常不能作为 RDP 服务端；应用不会替你修改远端安全策略。'
  },
  {
    id: 'rdp-control', protocol: 'rdp', devices: ALL_DEVICES, path: '会话中 → 控制面板',
    title: 'RDP 操控、键盘与组合键', summary: '控制面板和输入模式',
    steps: [
      '从贴边会话栏（PC 为顶部会话栏）打开控制中心，进入键盘、组合键、显示和滚轮设置。',
      '桌面软件优先触控板；需要直接点击触控界面时选触控；外接键鼠或 PC 选键鼠模式。',
      '虚拟键盘用于文本输入；Ctrl、Alt、Shift、Windows 与 Ctrl+Alt+Del 从组合键面板发送。',
      '滚轮每格滚一行太慢或太快时，到“设置 → 显示与交互 → 远程滚轮 → RDP”调速度。'
    ], note: '系统级快捷键能否被远端接收，还取决于 HarmonyOS 窗口焦点和“转发系统快捷键”设置。'
  },
  {
    id: 'rdp-display', protocol: 'rdp', devices: ALL_DEVICES, path: '设置 → Windows RDP',
    title: 'RDP 画面与网络调优', summary: '分辨率、缩放和色深',
    steps: [
      '“远端桌面大小”决定 Windows 会话分辨率；“本地显示缩放”只改变当前设备的查看比例。',
      '网络较慢时先降低色深、分辨率和视觉效果；画面稳定后再逐项提高。',
      '手机可开启双指画布缩放；画面偏移时重新选择“适应窗口”即可居中。',
      '重连后仍异常，再检查网关、VPN、MTU 与远端会话策略。'
    ], note: '同时修改多项画质设置会让问题难以定位，建议一次只改一项。'
  },
  {
    id: 'rdp-files', protocol: 'rdp', devices: ALL_DEVICES, path: '会话中 → 控制面板 → 发送文件',
    title: 'RDP 剪贴板与文件发送', summary: '文本通道和文件通道分开理解',
    steps: [
      '在“设置 → Windows RDP”确认剪贴板同步已开启。',
      '发送文件前先在远端打开目标桌面或文件夹，再从控制面板选择“发送文件到桌面”。',
      'PC 支持时可把本地文件拖入远程画面；应用通过文件剪贴板通道并在远端执行粘贴。',
      '按钮不可用时依次检查连接状态、剪贴板开关、文件权限和远端策略。'
    ], note: '文件传输依赖 RDP 剪贴板能力；敏感文件传完后建议清理两端剪贴板。'
  },
  {
    id: 'rustdesk-prepare', protocol: 'rustdesk', devices: ALL_DEVICES, path: '主机列表 → “+” → RustDesk',
    title: '准备 RustDesk 与认证方式', summary: 'ID、中继、密码和远端批准',
    steps: [
      '在被控端安装并启动 RustDesk，取得设备 ID；可设置永久密码，或使用远端点击批准。',
      '同一局域网可尝试直连；跨网或受限网络先在中继页配置 ID 服务器、中继、API 与 Key，并点“测试”确认两端都可达。',
      '添加主机时选择与被控端一致的认证方式；请求批准模式可不保存空密码。',
      '首次连接核对被控端显示的信息，二次验证只提交当前目标设备生成的验证码。'
    ], note: '自建中继改善可达性，但不会绕过被控端权限、密码或批准。'
  },
  {
    id: 'rustdesk-control', protocol: 'rustdesk', devices: ALL_DEVICES, path: '会话中 → 贴边栏',
    title: 'RustDesk 会话工具与操控', summary: '贴边栏、控制菜单和键盘',
    steps: [
      '顶部或贴边栏进入键盘、控制、显示、鼠标与触控（含滚轮方向和速度）与断开。',
      '在设置中选择触控板、触控或键鼠；远端应用需要原生双指缩放时，开启“远端应用双指缩放”。',
      '“控制”菜单可发送组合键、切换剪贴板按键并进入文件传输。',
      'PC 端工具栏会保持紧凑，指针离开后仍可从窗口边缘重新唤出。'
    ], note: '远端应用双指缩放与本地画布缩放是两条不同手势路径，不建议同时开启。'
  },
  {
    id: 'rustdesk-display', protocol: 'rustdesk', devices: ALL_DEVICES, path: '会话中 → 显示',
    title: 'RustDesk 显示、画质与编码', summary: '远端显示器、分辨率和画质',
    steps: [
      '“显示”菜单可缩放、复位画面、切换远端显示器，并修改远端电脑的分辨率（最后一个连接断开后远端自动恢复）。',
      '画质分速度优先、平衡、画质优先；切换后侧栏会按远端报告的码率提示是否生效。',
      '编解码可在连接中立即请求远端改用，远端不支持时继续用当前编码；虚拟显示器只支持带驱动的 Windows 被控端。',
      '隐私模式和远端音频也在“显示”菜单里；没开音频的连接要重连后才能开启。'
    ], note: '画质和编码受被控端、当前设备解码器和网络共同限制；文字锐利度还受远端分辨率和本地缩放影响。'
  },
  {
    id: 'rustdesk-files', protocol: 'rustdesk', devices: ALL_DEVICES, path: '会话中 → 控制 → 传输文件',
    title: 'RustDesk 剪贴板与文件', summary: '权限、确认与传输进度',
    steps: [
      '在协议设置和会话“控制”菜单确认剪贴板及文件复制已允许。',
      '从控制面板或“控制 → 传输文件”选择本地文件；PC 支持时也可拖入远程画面。',
      '等待被控端授权，并在传输状态中确认成功、失败或取消。',
      '远端拒绝时不要反复提交，先在被控端检查隐私与文件权限。'
    ], note: '文本剪贴板、剪贴板按键与文件复制是不同能力，任一关闭都可能影响对应操作。'
  },
  {
    id: 'ssh-prepare', protocol: 'ssh', devices: ALL_DEVICES, path: '主机列表 → “+” → SSH',
    title: '添加 SSH 主机与认证', summary: '密码、密钥、代理和指纹',
    steps: [
      '确认目标主机 SSH 服务已启动并记录端口；Windows 需安装并启用 OpenSSH Server。',
      '添加主机时选择密码或密钥；密钥先导入保险库，加密私钥的口令可连接时再输入。',
      '需要跳板机时配置代理主机及其独立凭据，不要把目标主机密码复用为代理密码。',
      '首次连接逐字核对主机指纹；指纹变化必须先在服务器侧确认。'
    ], note: '优先使用 Ed25519 或受保护的 RSA 密钥，并限制 authorized_keys 权限。'
  },
  {
    id: 'ssh-terminal', protocol: 'ssh', devices: ALL_DEVICES, path: '会话中 → 工具菜单',
    title: '终端、多会话与语言', summary: '输入、会话切换和工作区',
    steps: [
      '点终端输入区即可输入；手机从会话工具菜单切换语言、SFTP 或隧道，Pad 和 PC 使用顶部工具。',
      '每台主机有独立终端状态；切换标签不会把输入发送到其他会话。',
      '中日韩字符或快捷键异常时，先核对会话语言、服务器 locale 与当前终端配置。',
      '断开前确认命令已完成；长任务建议使用 tmux 或 screen，避免依赖前台连接。'
    ], note: 'SSH 终端没有远程桌面的剪贴板同步开关，复制粘贴由本地终端选择与系统剪贴板完成。'
  },
  {
    id: 'ssh-workspace', protocol: 'ssh', devices: ALL_DEVICES, path: '会话中 → Pane 工具',
    title: 'SSH 标签、分屏与会话恢复', summary: '工作区会恢复，连接不会擅自重建',
    steps: [
      '用主机标签切换终端；在 Pane 工具中创建水平或垂直分屏，并先确认当前焦点位置。',
      '应用重开后会恢复工作区布局，原会话只显示“恢复占位”，不会自动连接服务器。',
      '核对主机后点击手动恢复；关闭标签前留意它是关闭一个 Pane、一个标签还是活动连接。',
      '画中画、后台通知和持续任务受系统权限与隐私设置限制。'
    ], note: '恢复布局不等于恢复远端进程；敏感会话必须由你明确重新连接。'
  },
  {
    id: 'ssh-productivity', protocol: 'ssh', devices: ALL_DEVICES, path: '会话中 → 命令面板',
    title: 'SSH 搜索、命令、广播与日志', summary: '效率功能先确认范围再执行',
    steps: [
      '终端搜索只查当前会话内容；终端配置可调整字号、行距和渲染，不会修改服务器设置。',
      '从命令面板使用启动命令、片段或历史记录；插入后先检查，再决定是否发送。',
      '安全广播只发送到你勾选且仍在线的会话；执行模式会二次确认，密码和密钥不要广播。',
      '会话日志仅在本机加密保存，认证与敏感输入阶段会暂停；导出前仍要检查并脱敏。'
    ], note: '广播执行不可撤销；生产环境建议先用“仅插入”预览每个目标会话。'
  },
  {
    id: 'ssh-sftp', protocol: 'ssh', devices: ALL_DEVICES, path: '会话中 → SFTP 文件传输',
    title: 'SFTP 上传、下载与双主机传输', summary: '传输箱、冲突处理和任务恢复',
    steps: [
      '连接后打开“SFTP 文件传输”；本机文件先进入受控传输箱，Pad 和 PC 也可拖放文件或目录。',
      '上传、下载或双 SSH 复制前核对左右端点与目录；同名冲突可逐项决定或设置本批次策略。',
      '从 SSH 传输中心查看批量任务、进度和失败原因，可暂停、继续、取消或重试。',
      '断线后从“待恢复传输”重新绑定本机授权或 SSH 端点；身份或完整性不匹配时会拒绝续传。'
    ], note: '覆盖与续传都可能改变目标文件；开始前确认权限、空间、来源身份和批次范围。'
  },
  {
    id: 'ssh-forwarding', protocol: 'ssh', devices: ALL_DEVICES, path: '会话中 → 隧道',
    title: 'SSH 本地、远程与动态隧道', summary: '先理解监听在哪一端',
    steps: [
      '本地转发：在当前设备监听端口，把访问转到 SSH 服务器可达的目标。',
      '远程转发：在服务器侧监听端口，把流量转回当前设备可达的目标。',
      '动态转发：创建 SOCKS 代理，由使用方决定每次连接的目的地址。',
      '保存后查看监听状态与流量；报错时检查端口占用、GatewayPorts 与服务器转发策略。'
    ], note: '不要把监听地址设为所有网卡，除非你明确需要并已配置防火墙与访问控制。'
  },
  {
    id: 'vnc-prepare', protocol: 'vnc', devices: ALL_DEVICES, path: '主机列表 → “+” → VNC',
    title: '准备 VNC Server 与连接方式', summary: 'TCP 直连或 Repeater mode12',
    steps: [
      '在目标设备启动 VNC Server，确认认证方式、显示编号与端口；常见端口为 5900。',
      '同网或 VPN 内优先 TCP 直连；使用 UltraVNC Repeater 时先在中继页添加 Gateway。',
      '当前 Viewer 只支持 Repeater mode12；添加主机时填写 target ID 并选择可用 Gateway。',
      'TLS 启用时分别核对 Gateway 与目标端证书，证书变化后不要直接沿用旧信任。'
    ], note: 'VNC 的加密与认证能力取决于服务端；公网连接应使用 TLS、VPN 或可信中继。'
  },
  {
    id: 'vnc-control', protocol: 'vnc', devices: ALL_DEVICES, path: '会话中 → VNC 控制栏',
    title: 'VNC 工具栏与输入模式', summary: '键盘、鼠标、组合键和只读',
    steps: [
      '连接后展开 VNC 控制栏；自动收起时点回贴边控制柄。',
      '点当前模式在触控板、触控和键鼠之间切换；只读会话不会发送键盘或指针输入。',
      '键盘、组合键和「滚轮」（方向与速度）都从控制栏进入；触屏上三指上下滑动滚动。',
      'VNC 服务器每格滚动的距离差别很大：嫌快调低，macOS 屏幕共享或 UltraVNC 滚得少可在“远程滚轮”里调到 400%–1000%。'
    ], note: '只读模式适合监看；需要操作时必须编辑主机设置并重新连接。'
  },
  {
    id: 'vnc-display', protocol: 'vnc', devices: ALL_DEVICES, path: '会话中 → VNC 控制栏',
    title: 'VNC 画质、编码与剪贴板', summary: '按服务端能力逐项调整',
    steps: [
      '弱网先降低画质与颜色质量，再尝试更适合服务端的编码；不要一次开启全部高级选项。',
      '从工具栏切换显示比例，切换后画面会重新居中。',
      '需要文本互传时在主机设置开启剪贴板；只读连接不能向远端发送内容。',
      '性能监视只在排障时开启，确认后关闭以减少界面占用。'
    ], note: 'VNC 不提供远程桌面文件传输；需要文件操作时改用 SSH/SFTP 或其他受控通道。'
  },
  {
    id: 'vnc-gateway', protocol: 'vnc', devices: ALL_DEVICES, path: '中继 → “+” → VNC Gateway',
    title: 'VNC Gateway、TLS 与信任', summary: '先测网关，再连目标',
    steps: [
      '到中继页添加 UltraVNC Repeater，填写地址、端口、TLS 与可选令牌。',
      '先执行网关测试；测试通过后，再从 VNC 主机选择它并填写 target ID。',
      '证书管理会区分 Gateway 与目标端信任；卡片或详情里的“确认证书”会重新检查对应端点。',
      '连接失败先看网关健康状态，再检查 target ID 是否已在 Repeater 服务端注册。'
    ], note: '当前新增连接路径以 TCP 直连和 Repeater mode12 为准。'
  },
  {
    id: 'moonlight-prepare', protocol: 'moonlight', devices: ALL_DEVICES, path: '主机列表 → “+” → Moonlight',
    title: '准备 Sunshine 并完成配对', summary: '发现、校验、PIN 与信任',
    steps: [
      '在目标电脑安装并启动 Sunshine，完成 Web 管理端初始化并添加可串流应用。',
      '确保当前设备与主机网络可达；添加 Moonlight 主机时可等待局域网发现，也可手动输入地址。',
      '先校验主机身份，再把应用显示的 PIN 输入 Sunshine；配对完成后保存主机。',
      '主机证书变化时停止连接，确认 Sunshine 是否重装或重置后再重新配对。'
    ], note: 'Moonlight 私钥、配对信任和证书始终保存在本机，不会随云同步迁移。'
  },
  {
    id: 'moonlight-catalog', protocol: 'moonlight', devices: ALL_DEVICES, path: '主机卡片 → 应用目录',
    title: '应用目录、收藏与启动', summary: '刷新目录并处理占用状态',
    steps: [
      '从主机卡片打开应用目录并刷新 Sunshine 发布的应用；离线时会保留并标记上次目录。',
      '可收藏和筛选常用应用；启动前确认主机在线、应用可用且没有冲突会话。',
      '计费网络策略为“每次询问”时，确认本次流量后再启动。',
      '检测到上次未完成会话时，先按恢复提示选择继续、仅清理本机记录或结束主机应用。'
    ], note: '删除本机恢复提示不会自动结束 Sunshine 主机上的应用。'
  },
  {
    id: 'moonlight-control', protocol: 'moonlight', devices: TOUCH_DEVICES, path: '串流中 → 控制中心',
    title: 'Moonlight 键鼠、触控板与虚拟手柄', summary: '移动设备的自适应输入',
    steps: [
      '从串流顶部或贴边工具栏打开控制中心，切换自适应、键鼠或虚拟触控板。',
      '自适应模式在触摸画面时用虚拟触控板，在实体键盘、鼠标或触控板活动时切回键鼠。',
      '键盘入口用于文本与常用按键；修饰键柄可发送 Ctrl、Alt、Shift、Windows 和组合键。',
      '需要游戏控制时打开虚拟手柄；编辑模式可调整布局，完成后退出编辑再开始输入。',
      '连接实体手柄后优先使用物理通道；切换输入方式时先松开正在按住的按键。'
    ], note: '虚拟手柄或实体手柄未就绪时，工具栏会说明原因，不会静默吞掉输入。'
  },
  {
    id: 'moonlight-desktop-control', protocol: 'moonlight', devices: ['desktop'], path: '串流窗口 → 顶部工具栏',
    title: 'PC 上的 Moonlight 输入', summary: '键鼠、手柄与独立窗口',
    steps: [
      '串流在独立窗口中运行，点击画面取得焦点后使用实体键鼠。',
      '从顶部工具栏打开键盘、组合键、手柄、画面或诊断；需要时切换窗口全屏。',
      '实体手柄连接后确认工具栏显示输入就绪，再启动对手柄有要求的游戏。',
      '退出时选择“仅断开”保留主机应用，或“结束主机应用并断开”。'
    ], note: '先从会话内安全断开，再关闭独立窗口，可避免主机应用状态不明确。'
  },
  {
    id: 'moonlight-quality', protocol: 'moonlight', devices: ALL_DEVICES, path: '设置 → Moonlight',
    title: 'Moonlight 画面、音频与网络', summary: '分辨率、帧率、码率和重连',
    steps: [
      '先使用 1080p、60 FPS 与中等码率建立稳定基线，再按设备解码能力提升。',
      '卡顿时优先降低码率，其次降低分辨率或帧率；不要在弱网强制高码率。',
      '音频可选择本机播放、主机同时播放与后台音频；进入画中画前确认系统允许。',
      '网络设置可控制计费网络、自动重连预算、地址族与串流加密兼容性。'
    ], note: '允许旧 SHA-1 是高风险兼容项，只有确认旧 Sunshine 环境确有需要时才开启。'
  },
  {
    id: 'moonlight-lifecycle', protocol: 'moonlight', devices: ALL_DEVICES, path: '串流中 → 退出',
    title: 'Moonlight 画中画、重连与退出', summary: '分清本地串流和主机应用',
    steps: [
      '启动确认会列出主机、应用和画质快照；检查无误后再进入串流。',
      '进入画中画或后台音频前确认系统权限；控制能力可能暂停，返回前不要假设输入仍在发送。',
      '网络中断只在设置的预算内自动重连；超时后返回应用目录，核对主机状态再重试。',
      '“仅断开”保留主机应用；“结束主机应用并断开”会请求 Sunshine 终止，失败时保留恢复记录。'
    ], note: '直接关闭窗口可能让主机状态不明确；优先使用会话内的安全退出入口。'
  },
  {
    id: 'moonlight-data', protocol: 'moonlight', devices: ALL_DEVICES, path: '设置 → Moonlight → 数据',
    title: 'Moonlight 数据、诊断与删除', summary: '区分可同步配置和本机信任',
    steps: [
      '设置、主机和配置档只有在云同步中逐项勾选后才会跨设备；默认不会自动开启。',
      '配对信任、证书、客户端身份与私钥始终留在本机；换机恢复后重新配对。',
      '串流问题可临时打开性能 HUD，并从诊断复制脱敏指标。',
      '忘记主机、解除配对、删除本地数据和删除安全身份含义不同，按确认说明选择。'
    ], note: '删除安全身份会使现有配对失效；执行前先确认没有仍需使用的主机。'
  },
  {
    id: 'ai-install', protocol: 'ai', devices: ALL_DEVICES, path: '设置 → 远程 AI → 电脑端安装',
    title: '在电脑上装好插件', summary: '把安装提示词交给电脑上的 AI',
    steps: [
      '远程 AI 是 Pro 功能：用手机或平板查看和操控电脑上的编程 AI——Codex（端口 9443）、DSH（9444）或 Pi（9445）。',
      '在“电脑端安装”选择要连的 AI 和“局域网连接”，点“预览安装提示词”，再点“复制给 Agent 的安装提示词”。',
      '把提示词发给电脑上的 AI 编程助手（如 Codex、Pi），由它按固定版本安装插件、配置后台服务和本机控制面板；项目目录、自启动和费用都要你在电脑上确认。',
      '装好后，电脑浏览器里会有控制面板（127.0.0.1:9543 / 9544 / 9545），之后在这里生成配对二维码。'
    ], note: 'Pi 用你电脑上已安装、已登录的 Pi；原来的 Claude Agent 已换成 Pi，旧主机要重新配对。'
  },
  {
    id: 'ai-pair', protocol: 'ai', devices: ALL_DEVICES, path: '设置 → 远程 AI → 添加主机',
    title: '添加主机并扫码配对', summary: '二维码 120 秒有效、只能用一次',
    steps: [
      '在电脑的控制面板“生成邀请”，选择项目和权限；想看到 Codex App、DSH、pi-gui 里的项目，就勾选“全部项目（含电脑 App 里的项目）”。',
      '在 App 里添加 AI 主机：选 Codex、DSH 或 Pi，填电脑的局域网 IP 和端口。',
      '在“配对与保存”点“扫描电脑上的配对二维码”（也能从相册识别截图），然后点“配对并连接”。',
      'PC 上没有扫码：在控制面板复制配对链接，粘贴到“链接配对”。'
    ], note: '项目授权在配对时固定；以后想多看项目，要重新生成邀请再配对。目前只支持局域网连接。'
  },
  {
    id: 'ai-conversations', protocol: 'ai', devices: ALL_DEVICES, path: '主机列表 → 远程 AI → 主机',
    title: '对话列表', summary: '按项目分组，电脑上的对话也在',
    steps: [
      '进入主机先看到对话列表：按项目分组，电脑上开过的对话也会列出并标明来自电脑。',
      '顶部可以切换项目、搜索对话；下拉刷新。列表和对话内容有缓存，再次打开会很快。',
      '点对话进入聊天页；点“新对话”开始，项目不止一个时会先让你选项目。',
      '在聊天页点左上角返回回到对话列表，再返回回到主机列表。'
    ], note: '只读配对的设备只能查看，不能发送或批准。'
  },
  {
    id: 'ai-chat', protocol: 'ai', devices: ALL_DEVICES, path: '对话 → 底部输入框',
    title: '发送任务与批准操作', summary: '像 Codex、Claude 手机 App 一样聊天',
    steps: [
      '在底部输入框写任务并发送；运行中可以继续补充要求，或点停止按钮结束这一轮。',
      '回复逐字出现；思考过程和连续的工具步骤会折叠成一行，点开看命令、输出和代码改动。',
      'AI 要运行命令或修改文件时会弹出审批，看清内容后批准或拒绝。',
      '“+”可以附带照片和文件；右上角“⋯”里有会话设置、查看改动、待确认操作、压缩上下文和归档。'
    ], note: '发送时会自动取得控制权，不需要单独接管；同一对话同时只有一台设备能发送。'
  },
  {
    id: 'ai-model', protocol: 'ai', devices: ALL_DEVICES, path: '对话 → 模型按钮 / 权限按钮',
    title: '模型、思考强度与权限', summary: '选模型、看上下文、定能做什么',
    steps: [
      '点输入框旁的模型按钮选择模型和思考强度，并查看上下文已用多少；快满时可以在“⋯”里压缩上下文。',
      'Codex 的权限：只读、可写工作区、完全访问。',
      'Pi 的权限：只读（默认，只能查看和搜索）、修改前询问（每条命令、每次改文件都先在手机上批准）、完全访问。',
      '新对话默认用电脑上的默认模型（Pi 为你最近一次用的模型）；改动对之后的回复生效。'
    ], note: '“完全访问”不再询问就会运行命令和改文件，只在你信任当前任务时使用。'
  },
  {
    id: 'ai-trouble', protocol: 'ai', devices: ALL_DEVICES, path: '设置 → 远程 AI',
    title: '远程 AI 连不上时', summary: '服务、地址、证书和配对',
    steps: [
      '先确认电脑上的插件服务在运行：电脑浏览器能打开控制面板，面板显示服务已就绪。',
      '电脑换了局域网 IP 时，要在电脑上重新签发证书，再回到这里编辑主机地址并重新配对。',
      '提示证书与二维码不一致，说明地址填错或电脑重新生成了证书，核对后重新配对。',
      'pi-gui 会一直占用它打开过的对话，直到在 pi-gui 里关闭该对话或退出 pi-gui；这期间手机只能查看，可以点输入框上方的「复制到新对话继续」。',
      '切到别的 App 或锁屏再回来，对话、草稿和待审批都还在，会自动续上；只是错过了续期的审批，回来后照常可以批。'
    ], note: '还是不行，可以让 AI 助理诊断并整理脱敏日志。'
  },
  {
    id: 'assistant-start', protocol: 'assistant', devices: ALL_DEVICES, path: '主机列表标题栏 AI 按钮（PC 在左下角）',
    title: '打开 AI 助理', summary: '聊天与助理两种模式',
    steps: [
      'AI 入口在主机列表标题栏（PC 在左下角）、设置和各协议连接的侧栏里。',
      '聊天是通用助手：写作翻译、读文档、生成 Word 和 Excel、提醒日程、联网搜索、改设置、管理主机。',
      '助理专管 RemoteDesktop 的连接、设置、诊断、抓日志和问题反馈；两者会按问题自动转交。',
      '说“开个新对话”开始新对话，之前的对话保存在对话记录里；说“拜拜”“退出”会关闭 AI。'
    ], note: 'AI 的模型和服务在“设置 → AI 助理 → AI 配置”里设置。'
  },
  {
    id: 'assistant-voice', protocol: 'assistant', devices: ALL_DEVICES, path: '设置 → AI 语音',
    title: '语音与悬浮球', summary: '像 Siri 一样说话，随时打断',
    steps: [
      '打开“设置 → AI 语音”（Beta）后可以直接说话，回答时可随时插话打断，连续对话。',
      '说“缩成悬浮球”让 AI 停在屏幕边上；单击回到对话，双击打开或收起小对话框，长按开始听。',
      '朗读可选系统或云端音色，识别可选本机或云端。',
      '说“回到文字”“切到语音模式”“切到助理”即可切换模式。'
    ], note: '开启“按住说话”时，按住悬浮球说话、松手发送。'
  },
  {
    id: 'assistant-session', protocol: 'assistant', devices: ALL_DEVICES, path: '连接中 → 侧栏 AI（SSH 在“更多”）',
    title: '连接中使用 AI', summary: '边远控边问',
    steps: [
      'RDP、RustDesk、VNC、Moonlight 的侧栏和 SSH 的“更多”里有 AI 入口，点开先出现 AI 控制面板。',
      '面板里可以设置语音模式、模型、回答风格和长度、联网搜索和朗读；底部按钮启动或关闭 AI。',
      'AI 以悬浮球加小对话框出现；连接断开或重连时 AI 不会关闭，回到主机列表后也能接着用。',
      '打开“点 AI 按钮直接启动”后，点 AI 按钮直接启动或关闭，长按才打开面板。'
    ], note: '连接中没有语音大球，回答由悬浮球读出；读不读可在“AI 语音 → 连接中语音回答”设置。'
  },
  {
    id: 'assistant-actions', protocol: 'assistant', devices: ALL_DEVICES, path: '对 AI 说出要做的事',
    title: '让 AI 帮你改设置和排障', summary: '确认后才执行，每项可撤销',
    steps: [
      '直接说要做什么，例如“VNC 滚轮速度调到 200%”“远程 AI 换成 Codex 风格”“新主机默认用 Pi”。',
      'AI 会列出要改的设置，点按钮应用；多条时有“全部应用”，每条都能撤销。',
      '连接出问题时说“帮我诊断”，AI 会抓取脱敏日志并给出步骤；需要时整理成反馈邮件，由你检查后发送。',
      '它也能列出、连接、编辑主机，管理它生成的文档、提醒和记忆；删除前都会确认。'
    ], note: '密码、密钥、Token 等敏感信息 AI 不会代填，也不会读取。'
  }
];

export function guideLessonsFor(device: GuideDevice, protocol: GuideProtocol): GuideLesson[] {
  const lessons: GuideLesson[] = [];
  GUIDE_LESSONS.forEach((lesson: GuideLesson): void => {
    const deviceMatches: boolean = lesson.devices.indexOf(device) >= 0;
    // “开始” owns the cross-protocol workflow. Once a protocol is selected,
    // show that protocol immediately instead of placing five generic cards in
    // front of the requested task.
    const protocolMatches: boolean = lesson.protocol === protocol;
    if (deviceMatches && protocolMatches) { lessons.push(cloneLesson(lesson)); }
  });
  return lessons;
}

/** How many lessons a category has for a device (shown on its chip). */
export function guideLessonCount(device: GuideDevice, protocol: GuideProtocol): number {
  return guideLessonsFor(device, protocol).length;
}

/** The category's label (开始, RDP, 远程 AI…), or the id itself. */
export function guideProtocolLabel(protocol: GuideProtocol): string {
  const option: GuideProtocolOption | undefined = guideProtocolOptions().find(
    (item: GuideProtocolOption): boolean => item.id === protocol);
  return option !== undefined ? option.label : protocol;
}

/**
 * Lessons for the device whose title, summary, entry path, steps or note contain every word of `query` (case-
 * insensitive, spaces separate words), across all categories in catalog order. An empty query finds nothing.
 */
export function guideLessonsMatching(device: GuideDevice, query: string): GuideLesson[] {
  const words: string[] = query.toLowerCase().split(/\s+/).filter((word: string): boolean => word.length > 0);
  if (words.length === 0) { return []; }
  const lessons: GuideLesson[] = [];
  GUIDE_LESSONS.forEach((lesson: GuideLesson): void => {
    if (lesson.devices.indexOf(device) < 0) { return; }
    const text: string = [lesson.title, lesson.summary, lesson.path, lesson.note, guideProtocolLabel(lesson.protocol)]
      .concat(lesson.steps).join('\n').toLowerCase();
    if (words.every((word: string): boolean => text.indexOf(word) >= 0)) { lessons.push(cloneLesson(lesson)); }
  });
  return lessons;
}

/**
 * 保留旧接口供首次安装兼容检查与第三方调用；设置 UI 已改用可筛选的 lesson 模型。
 */
export function handsOnUsageGuidePages(): GuideContentPage[] {
  const pages: GuideContentPage[] = [];
  GUIDE_LESSONS.forEach((lesson: GuideLesson): void => {
    if (lesson.protocol === 'all' && lesson.devices.indexOf('phone') < 0) { return; }
    const desc: string = lesson.steps.length > 0 ? lesson.steps[0] +
      (lesson.note.length > 0 ? ' ' + lesson.note : '') : lesson.summary;
    pages.push({
      id: lesson.id,
      symbol: lesson.protocol === 'ssh' ? $rawfile('icons/command-line.svg') :
        (lesson.protocol === 'all' ? $rawfile('icons/cog-6-tooth.svg') :
          $rawfile('icons/computer-desktop.svg')),
      title: lesson.title,
      desc: desc
    });
  });
  return pages;
}
