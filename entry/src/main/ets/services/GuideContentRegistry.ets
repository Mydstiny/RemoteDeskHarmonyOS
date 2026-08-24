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
}

export type GuideDevice = 'phone' | 'tablet' | 'desktop';
export type GuideProtocol = 'all' | 'rdp' | 'rustdesk' | 'ssh' | 'vnc' | 'moonlight';

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
}

const ALL_DEVICES: GuideDevice[] = ['phone', 'tablet', 'desktop'];
const TOUCH_DEVICES: GuideDevice[] = ['phone', 'tablet'];

function clonePage(page: GuideContentPage): GuideContentPage {
  return { id: page.id, symbol: page.symbol, title: page.title, desc: page.desc };
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
    note: lesson.note
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
    { id: 'all', label: '开始', summary: '工作台、数据与排障' },
    { id: 'rdp', label: 'RDP', summary: 'Windows 远程桌面' },
    { id: 'rustdesk', label: 'RustDesk', summary: '跨平台远控' },
    { id: 'ssh', label: 'SSH / SFTP', summary: '终端与文件' },
    { id: 'vnc', label: 'VNC', summary: '标准兼容远控' },
    { id: 'moonlight', label: 'Moonlight', summary: '低延迟串流' }
  ];
}

const SHARED_GUIDE_PAGES: GuideContentPage[] = [
  {
    id: 'welcome-five-protocols',
    symbol: $rawfile('icons/computer-desktop.svg'),
    title: '欢迎来到五协议工作台',
    desc: 'RDP 连接 Windows，RustDesk 负责跨平台远控，SSH/SFTP 管理服务器与文件，VNC 兼容标准远控服务，Moonlight 连接 Sunshine 进行低延迟串流。'
  },
  {
    id: 'choose-by-goal',
    symbol: $rawfile('icons/globe-alt.svg'),
    title: '先按目标选协议',
    desc: '要完整 Windows 桌面选 RDP；跨平台协助选 RustDesk；命令与文件选 SSH；已有 VNC Server 选 VNC；游戏、影音或高帧率桌面选 Moonlight。'
  },
  {
    id: 'connect-safely',
    symbol: $rawfile('icons/shield-check.svg'),
    title: '先准备服务，再安全连接',
    desc: '点击底部“+”添加主机，并确认远端服务已开启。首次连接要核对 RDP/VNC 证书、SSH 指纹、RustDesk 被控端信息或 Moonlight 配对码，只信任你能确认的设备。'
  },
  {
    id: 'session-toolkit',
    symbol: $rawfile('icons/cog-6-tooth.svg'),
    title: '会话工具各归其位',
    desc: 'RDP、RustDesk、VNC 与 Moonlight 从贴边入口打开键盘、快捷键和显示工具；SSH 使用标签、窗格、SFTP 与传输中心。Moonlight 退出时请区分“仅断开”和“结束主机应用”。'
  },
  {
    id: 'data-recovery-and-help',
    symbol: $rawfile('icons/cloud.svg'),
    title: '数据、恢复和诊断都有边界',
    desc: '云同步只处理明确勾选的数据，私钥、配对信任和证书按协议分别保存；恢复备份前先确认方向。遇到问题请保留错误码，再从“设置 → 日志”导出脱敏诊断。'
  }
];

function sharedPages(): GuideContentPage[] {
  const pages: GuideContentPage[] = [];
  SHARED_GUIDE_PAGES.forEach((page: GuideContentPage): void => { pages.push(clonePage(page)); });
  return pages;
}

function deviceGuidePage(device: GuideDevice): GuideContentPage {
  return {
    id: 'device-path-' + device,
    symbol: $rawfile('icons/computer-desktop.svg'),
    title: '已按' + guideDeviceLabel(device) + '准备引导',
    desc: guideDeviceSummary(device) + '。应用会保留相同的任务入口，但把常用操作放到更适合当前设备的位置。'
  };
}

export function firstInstallGuidePages(device: GuideDevice = 'phone'): GuideContentPage[] {
  const pages: GuideContentPage[] = sharedPages();
  pages.splice(3, 0, deviceGuidePage(device));
  pages.push({
    id: 'start-first-host',
    symbol: $rawfile('icons/shield-check.svg'),
    title: '现在添加第一台主机',
    desc: '进入工作台，点击“+”并按用途选择协议。高级选项不确定时先保留默认值；需要逐步说明，可到“设置 → 教程 → 操作引导中心”按设备和协议查看。'
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
    title: '复杂操作不必一次记住',
    desc: '在“设置 → 教程 → 操作引导中心”选择设备和协议，可查看连接、操控、文件、安全、恢复与排障步骤；服务端部署请打开“连接前准备”。'
  });
  return pages;
}

const GUIDE_LESSONS: GuideLesson[] = [
  {
    id: 'common-first-host', protocol: 'all', devices: ALL_DEVICES,
    title: '添加并连接第一台主机', summary: '从“+”到首次安全连接',
    steps: [
      '在主机工作台点击底部“+”，按用途选择 RDP、RustDesk、SSH、VNC 或 Moonlight。',
      '填写地址、端口和当前协议要求的凭据；不确定的高级选项先保留默认值。',
      '保存后点击主机卡片；首次连接出现证书、指纹、配对码或远端批准时，先在目标设备上核对。',
      '进入会话后只调整影响当前问题的设置；画面、输入和网络设置可分别恢复默认。'
    ], note: '不要在来源不明的提示中提交密码、动态口令或信任变更。'
  },
  {
    id: 'common-phone-controls', protocol: 'all', devices: ['phone'],
    title: '手机上的通用操控', summary: '单手入口、触控板与虚拟键盘',
    steps: [
      '远程桌面默认优先使用触控板映射：单指移动光标、轻点左键、双指轻点右键、双指上下滚动。',
      '需要键盘或组合键时，点贴边控制柄；RDP/RustDesk/VNC 也可三指轻点打开控制面板。',
      '画面放大后，先双指按住约 0.4 秒再拖动来平移；立即移动仍会作为滚轮。',
      '输入完成后收起键盘和面板，把最大空间留给远端画面。'
    ], note: '若手势与远端应用冲突，可在“显示与交互”或协议设置中关闭本地画布缩放。'
  },
  {
    id: 'common-tablet-controls', protocol: 'all', devices: ['tablet'],
    title: 'Pad 与展开态折叠屏', summary: '触控、键鼠与多任务配合',
    steps: [
      '纯触控时先用触控板模式处理桌面应用，需要直接点按时再切到触控模式。',
      '连接实体键盘或鼠标后切到键鼠模式，系统快捷键是否转发由各协议设置决定。',
      '横屏或展开态会显示更多会话工具；窗口尺寸变化时，当前连接和未提交输入会保持。',
      'SSH/SFTP 可利用宽屏分栏；远程桌面仍建议一次只打开一个主要控制面板。'
    ], note: '折叠或旋转设备时先完成正在进行的拖拽、文件选择或安全确认。'
  },
  {
    id: 'common-desktop-controls', protocol: 'all', devices: ['desktop'],
    title: 'PC / 2in1 上的通用操控', summary: '独立窗口、键鼠与拖放',
    steps: [
      '从主机卡片发起连接并完成认证后，远程会话会进入独立窗口；主工作台仍可继续管理其他主机。',
      '优先使用实体键鼠；组合键、系统快捷键和显示比例由会话顶部工具栏控制。',
      'RDP/RustDesk 支持时可把本地文件拖入远程画面；SSH 文件请从 SFTP 工作区传输。',
      '关闭窗口前使用会话内“断开”；Moonlight 还需区分“仅断开”与“结束主机应用”。'
    ], note: '自由窗口过窄时界面会切换到紧凑布局，但设备仍按 PC 的键鼠行为处理。'
  },
  {
    id: 'common-workspace', protocol: 'all', devices: ALL_DEVICES,
    title: '整理主机、密钥和 2FA', summary: '知道每类资料放在哪里',
    steps: [
      '主机工作台保存连接入口；长按或更多菜单可编辑、上锁、排序、分组或删除。',
      '密钥保险库保存 SSH 私钥；可先添加密钥，再从 SSH 主机选择或部署对应公钥。',
      '2FA 验证器保存动态口令条目；连接需要二次验证时，再选择或输入当前验证码。',
      '中继服务器页管理 RustDesk 中继与 VNC Gateway，它们不会替代具体主机记录。'
    ], note: '删除主机不等于删除密钥、证书或远端数据；安全资料可在“设置 → 安全”单独管理。'
  },
  {
    id: 'common-cloud', protocol: 'all', devices: ALL_DEVICES,
    title: '云同步、备份与换机', summary: '先选范围，再确认方向',
    steps: [
      '先登录华为账号并确认云空间可用，再进入“设置 → 云同步”选择数据范围。',
      '上传表示以本机为准写入云端；下载表示从云端恢复到当前账号的数据域。',
      '导出备份用于离线留档，导入会先校验版本并安全合并；不要把备份文件交给不可信的人。',
      'Moonlight 的配对信任、证书与客户端私钥始终留在本机，换机后需要重新配对。'
    ], note: '任何覆盖或清空操作都会二次确认；方向不明确时先导出备份。'
  },
  {
    id: 'common-diagnostics', protocol: 'all', devices: ALL_DEVICES,
    title: '连接失败时的排查顺序', summary: '从可达性到脱敏日志',
    steps: [
      '先确认目标设备开机、服务已启动，地址和端口可从当前网络访问。',
      '再核对协议、凭据、证书/指纹/配对状态，以及 VPN、防火墙和中继配置。',
      '画面或输入异常时先恢复该协议的显示、编码与操控默认值，然后重新连接。',
      '仍失败时记录页面错误码，到“设置 → 日志”抓取脱敏诊断，再通过“反馈”发送。'
    ], note: '诊断默认脱敏；提交前仍应检查说明中是否包含你手动输入的主机名称。'
  },
  {
    id: 'rdp-prepare', protocol: 'rdp', devices: ALL_DEVICES,
    title: '准备 Windows 与首次连接', summary: '远程桌面、账户与证书',
    steps: [
      '在 Windows 专业版/企业版开启“远程桌面”，确认允许的用户并放行 TCP 3389 或自定义端口。',
      '添加 RDP 主机时填写地址、用户名并选择密码、Windows 凭据、空密码确认或 Restricted Admin Hash 等实际认证方式。',
      '首次连接核对证书主机名与指纹；证书变化时先确认目标机是否重装、换证或被代理。',
      '通过公网连接优先使用 VPN，不建议直接暴露 RDP 端口。'
    ], note: 'Windows 家庭版通常不能作为 RDP 服务端；应用不会替你修改远端安全策略。'
  },
  {
    id: 'rdp-control', protocol: 'rdp', devices: ALL_DEVICES,
    title: 'RDP 操控、键盘与组合键', summary: '控制面板和输入模式',
    steps: [
      '触屏设备三指轻点远程画面打开控制面板；PC 从顶部会话栏进入键盘、组合键和显示操作。',
      '桌面软件优先触控板；需要直接点击触控界面时选触控；外接键鼠或 PC 选键鼠模式。',
      '虚拟键盘用于文本输入；Ctrl、Alt、Shift、Windows 与 Ctrl+Alt+Del 从组合键面板发送。',
      '失去焦点、切换模式或断开时，应用会释放仍按下的修饰键。'
    ], note: '系统级快捷键能否被远端接收，还取决于 HarmonyOS 窗口焦点和“转发系统快捷键”设置。'
  },
  {
    id: 'rdp-display', protocol: 'rdp', devices: ALL_DEVICES,
    title: 'RDP 画面与网络调优', summary: '分辨率、缩放和色深',
    steps: [
      '“远端桌面大小”决定 Windows 会话分辨率；“本地显示缩放”只改变当前设备的查看比例。',
      '网络较慢时先降低色深、分辨率和视觉效果；画面稳定后再逐项提高。',
      '手机可开启双指画布缩放；画面偏移时重新选择“适应窗口”即可居中。',
      '重连后仍异常，再检查网关、VPN、MTU 与远端会话策略。'
    ], note: '同时修改多项画质设置会让问题难以定位，建议一次只改一项。'
  },
  {
    id: 'rdp-files', protocol: 'rdp', devices: ALL_DEVICES,
    title: 'RDP 剪贴板与文件发送', summary: '文本通道和文件通道分开理解',
    steps: [
      '在“设置 → Windows RDP”确认剪贴板同步已开启。',
      '发送文件前先在远端打开目标桌面或文件夹，再从控制面板选择“发送文件到桌面”。',
      'PC 支持时可把本地文件拖入远程画面；应用通过文件剪贴板通道并在远端执行粘贴。',
      '按钮不可用时依次检查连接状态、剪贴板开关、文件权限和远端策略。'
    ], note: '文件传输依赖 RDP 剪贴板能力；敏感文件传完后建议清理两端剪贴板。'
  },
  {
    id: 'rustdesk-prepare', protocol: 'rustdesk', devices: ALL_DEVICES,
    title: '准备 RustDesk 与认证方式', summary: 'ID、中继、密码和远端批准',
    steps: [
      '在被控端安装并启动 RustDesk，取得设备 ID；可设置永久密码，或使用远端点击批准。',
      '同一局域网可尝试直连；跨网或受限网络先在中继服务器页配置 Rendezvous/Relay/API 与 Key。',
      '添加主机时选择与被控端一致的认证方式；请求批准模式可不保存空密码。',
      '首次连接核对被控端显示的信息，二次验证只提交当前目标设备生成的验证码。'
    ], note: '自建中继改善可达性，但不会绕过被控端权限、密码或批准。'
  },
  {
    id: 'rustdesk-control', protocol: 'rustdesk', devices: ALL_DEVICES,
    title: 'RustDesk 会话工具与操控', summary: '贴边栏、控制菜单和键盘',
    steps: [
      '手机/Pad 三指轻点可打开控制面板；顶部或贴边栏也可进入键盘、控制、显示与断开。',
      '在设置中选择触控板、触控或键鼠；远端应用需要原生双指缩放时，开启“远端应用双指缩放”。',
      '“控制”菜单可发送组合键、切换剪贴板按键并进入文件传输。',
      'PC 端工具栏会保持紧凑，指针离开后仍可从窗口边缘重新唤出。'
    ], note: '远端应用双指缩放与本地画布缩放是两条不同手势路径，不建议同时开启。'
  },
  {
    id: 'rustdesk-display', protocol: 'rustdesk', devices: ALL_DEVICES,
    title: 'RustDesk 画质、编码与显示', summary: '先稳定，再追求清晰',
    steps: [
      '一般使用“自动/平衡”；长时间连接可优先尝试 H.264 或 H.265。',
      '卡顿时先降低图像质量，再检查中继延迟；只有双方能力都满足时才强制高阶编码。',
      '从“显示”菜单选择适应窗口、100%—200% 或自定义缩放，并可重新居中画面。',
      '旋转或切换窗口后画面异常时，先恢复“适应窗口”，再重新连接。'
    ], note: '编码选择受被控端、当前设备解码器和网络共同限制。'
  },
  {
    id: 'rustdesk-files', protocol: 'rustdesk', devices: ALL_DEVICES,
    title: 'RustDesk 剪贴板与文件', summary: '权限、确认与传输进度',
    steps: [
      '在协议设置和会话“控制”菜单确认剪贴板及文件复制允许。',
      '从控制面板或“控制 → 传输文件”选择本地文件；PC 支持时也可拖入远程画面。',
      '等待被控端授权，并在传输状态中确认成功、失败或取消。',
      '远端拒绝时不要反复提交，先在被控端检查隐私与文件权限。'
    ], note: '文本剪贴板、剪贴板按键与文件复制是不同能力，任一关闭都可能影响对应操作。'
  },
  {
    id: 'ssh-prepare', protocol: 'ssh', devices: ALL_DEVICES,
    title: '添加 SSH 主机与认证', summary: '密码、密钥、代理和指纹',
    steps: [
      '确认目标主机 SSH 服务已启动并记录端口；Windows 需安装并启用 OpenSSH Server。',
      '添加主机时选择密码或密钥；密钥先导入保险库，加密私钥的口令可连接时再输入。',
      '需要跳板机时配置代理主机及其独立凭据，不要把目标主机密码复用为代理密码。',
      '首次连接逐字核对主机指纹；指纹变化必须先在服务器侧确认。'
    ], note: '优先使用 Ed25519 或受保护的 RSA 密钥，并限制 authorized_keys 权限。'
  },
  {
    id: 'ssh-terminal', protocol: 'ssh', devices: ALL_DEVICES,
    title: '终端、多会话与语言', summary: '输入、会话切换和工作区',
    steps: [
      '点击终端输入区即可输入；手机从会话工具菜单切换语言、SFTP 或隧道，Pad/PC 使用顶部工具。',
      '每台主机有独立终端状态；切换标签不会把输入发送到其他会话。',
      '中日韩字符或快捷键异常时，先核对会话语言、服务器 locale 与当前终端配置。',
      '断开前确认命令已完成；长任务建议使用 tmux/screen，避免依赖前台连接。'
    ], note: 'SSH 终端没有远程桌面的剪贴板同步开关，复制粘贴由本地终端选择与系统剪贴板完成。'
  },
  {
    id: 'ssh-workspace', protocol: 'ssh', devices: ALL_DEVICES,
    title: 'SSH 标签、分屏与会话恢复', summary: '工作区会恢复，连接不会擅自重建',
    steps: [
      '用主机标签切换终端；在 Pane 工具中创建水平或垂直分屏，并先确认当前焦点位置。',
      '应用重开后会恢复工作区布局，原会话只显示“恢复占位”，不会自动连接服务器。',
      '核对主机后点击手动恢复；关闭标签前留意它是关闭一个 Pane、一个标签还是活动连接。',
      '长任务优先使用 tmux/screen；画中画、后台通知和持续任务受系统权限与隐私设置限制。'
    ], note: '恢复布局不等于恢复远端进程；敏感会话必须由你明确重新连接。'
  },
  {
    id: 'ssh-productivity', protocol: 'ssh', devices: ALL_DEVICES,
    title: 'SSH 搜索、命令、广播与日志', summary: '效率功能先确认范围再执行',
    steps: [
      '终端搜索只查当前会话内容；终端配置可调整字号、行距和渲染，不会修改服务器设置。',
      '从命令面板使用启动命令、片段或历史记录；插入后先检查，再决定是否发送。',
      '安全广播只发送到你勾选且仍在线的会话；执行模式会二次确认，密码和密钥不要广播。',
      '会话日志仅在本机加密保存，认证与敏感输入阶段会暂停；导出前仍要检查并脱敏。'
    ], note: '广播执行不可撤销；生产环境建议先用“仅插入”预览每个目标会话。'
  },
  {
    id: 'ssh-sftp', protocol: 'ssh', devices: ALL_DEVICES,
    title: 'SFTP 上传、下载与双主机传输', summary: '传输箱、冲突处理和任务恢复',
    steps: [
      '连接后打开“SFTP 文件传输”；本机文件先进入受控传输箱，Pad/PC 也可拖放文件或目录。',
      '上传、下载或双 SSH 复制前核对左右端点与目录；同名冲突可逐项决定或设置本批次策略。',
      '从 SSH 传输中心查看批量任务、进度和失败原因，可暂停、继续、取消或重试。',
      '断线后从“待恢复传输”重新绑定本机授权或 SSH 端点；身份或完整性不匹配时会拒绝续传。'
    ], note: '覆盖与续传都可能改变目标文件；开始前确认权限、空间、来源身份和批次范围。'
  },
  {
    id: 'ssh-forwarding', protocol: 'ssh', devices: ALL_DEVICES,
    title: 'SSH 本地、远程与动态隧道', summary: '先理解监听在哪一端',
    steps: [
      '本地转发：在当前设备监听端口，把访问转到 SSH 服务器可达的目标。',
      '远程转发：在服务器侧监听端口，把流量转回当前设备可达的目标。',
      '动态转发：创建 SOCKS 代理，由使用方决定每次连接的目的地址。',
      '保存后查看监听状态与流量；报错时检查端口占用、GatewayPorts 与服务器转发策略。'
    ], note: '不要把监听地址设为所有网卡，除非你明确需要并已配置防火墙与访问控制。'
  },
  {
    id: 'vnc-prepare', protocol: 'vnc', devices: ALL_DEVICES,
    title: '准备 VNC Server 与连接方式', summary: 'TCP 直连或 Repeater mode12',
    steps: [
      '在目标设备启动 VNC Server，确认认证方式、显示编号与端口；常见端口为 5900。',
      '同网或 VPN 内优先 TCP 直连；使用 UltraVNC Repeater 时先在中继页添加 Gateway。',
      '当前 Viewer 只支持 Repeater mode12；添加主机时填写 target ID 并选择可用 Gateway。',
      'TLS 启用时分别核对 Gateway 与目标端证书，证书变化后不要直接沿用旧信任。'
    ], note: 'VNC 的加密与认证能力取决于服务端；公网连接应使用 TLS、VPN 或可信中继。'
  },
  {
    id: 'vnc-control', protocol: 'vnc', devices: ALL_DEVICES,
    title: 'VNC 工具栏与输入模式', summary: '键盘、鼠标、组合键和只读',
    steps: [
      '连接后展开 VNC 控制栏；自动收起时点回贴边控制柄。',
      '点击当前模式在触控板、触控和键鼠之间切换；只读会话不会发送键盘或指针输入。',
      '键盘与组合键从控制栏进入；三指轻点也可打开通用控制面板。',
      '指针偏移时先恢复适应窗口，再确认服务端缩放与旋转设置。'
    ], note: '只读模式适合监看；需要操作时必须编辑主机设置并重新连接。'
  },
  {
    id: 'vnc-display', protocol: 'vnc', devices: ALL_DEVICES,
    title: 'VNC 画质、编码与剪贴板', summary: '按服务端能力逐项调整',
    steps: [
      '弱网先降低画质与颜色质量，再尝试更适合服务端的编码；不要一次开启全部高级选项。',
      '从工具栏切换显示比例，切换后画面会重新居中。',
      '需要文本互传时在主机设置开启剪贴板；只读连接不能向远端发送内容。',
      '性能监视只在排障时开启，确认后关闭以减少界面占用。'
    ], note: 'VNC 不提供远程桌面文件传输；需要文件操作时改用 SSH/SFTP 或其他受控通道。'
  },
  {
    id: 'vnc-gateway', protocol: 'vnc', devices: ALL_DEVICES,
    title: 'VNC Gateway、TLS 与信任', summary: '先测网关，再连目标',
    steps: [
      '到中继服务器页添加 UltraVNC Repeater，填写地址、端口、TLS 与可选令牌。',
      '先执行网关测试；测试通过后，再从 VNC 主机选择它并填写 target ID。',
      '证书管理页会区分 Gateway 与目标端信任，重新检查时确认对应端点。',
      '连接失败先看网关健康状态，再检查 target ID 是否已在 Repeater 服务端注册。'
    ], note: 'WebSocket Gateway 与 SSH Tunnel 记录可被旧数据识别，但当前新增连接路径以 TCP 直连和 Repeater mode12 为准。'
  },
  {
    id: 'moonlight-prepare', protocol: 'moonlight', devices: ALL_DEVICES,
    title: '准备 Sunshine 并完成配对', summary: '发现、校验、PIN 与信任',
    steps: [
      '在目标电脑安装并启动 Sunshine，完成 Web 管理端初始化并添加可串流应用。',
      '确保当前设备与主机网络可达；添加 Moonlight 主机时可等待局域网发现，也可手动输入地址。',
      '先校验主机身份，再把应用显示的 PIN 输入 Sunshine；配对完成后保存主机。',
      '主机证书变化时停止连接，确认 Sunshine 是否重装或重置后再重新配对。'
    ], note: 'Moonlight 私钥、配对信任和证书始终保存在本机，不会随云同步迁移。'
  },
  {
    id: 'moonlight-catalog', protocol: 'moonlight', devices: ALL_DEVICES,
    title: '应用目录、收藏与启动', summary: '刷新目录并处理占用状态',
    steps: [
      '从主机卡片打开应用目录 Sheet 并刷新 Sunshine 发布的应用；离线时会保留并标记上次目录。',
      '可收藏和筛选常用应用；启动前确认主机在线、应用可用且没有冲突会话。',
      '计费网络策略为“每次询问”时，确认本次流量后再启动。',
      '检测到上次未完成会话时，先按恢复提示选择继续、仅清理本机记录或结束主机应用。'
    ], note: '删除本机恢复提示不会自动结束 Sunshine 主机上的应用。'
  },
  {
    id: 'moonlight-control', protocol: 'moonlight', devices: TOUCH_DEVICES,
    title: 'Moonlight 触控、键盘与虚拟手柄', summary: '移动设备的三类输入',
    steps: [
      '从串流顶部或贴边工具栏打开控制中心，切换直接触控或触控板。',
      '键盘入口用于文本与常用按键；修饰键柄可发送 Ctrl、Alt、Shift、Windows 和组合键。',
      '需要游戏控制时打开虚拟手柄；编辑模式可调整布局，完成后退出编辑再开始输入。',
      '连接实体手柄后优先使用物理通道；切换输入方式时先松开正在按住的按键。'
    ], note: '虚拟手柄或实体手柄未就绪时，工具栏会说明原因，不会静默吞掉输入。'
  },
  {
    id: 'moonlight-desktop-control', protocol: 'moonlight', devices: ['desktop'],
    title: 'PC 上的 Moonlight 输入', summary: '键鼠、手柄与独立窗口',
    steps: [
      '串流在独立窗口中运行，点击画面取得焦点后使用实体键鼠。',
      '从顶部工具栏打开键盘、组合键、手柄、画面或诊断；需要时切换窗口全屏。',
      '实体手柄连接后确认工具栏显示输入就绪，再启动对手柄有要求的游戏。',
      '退出时选择“仅断开”保留主机应用，或“结束主机应用并断开”。'
    ], note: '先从会话内安全断开，再关闭独立窗口，可避免主机应用状态不明确。'
  },
  {
    id: 'moonlight-quality', protocol: 'moonlight', devices: ALL_DEVICES,
    title: 'Moonlight 画面、音频与网络', summary: '分辨率、帧率、码率和重连',
    steps: [
      '先使用 1080p、60 FPS 与中等码率建立稳定基线，再按设备解码能力提升。',
      '卡顿时优先降低码率，其次降低分辨率或帧率；不要在弱网强制高码率。',
      '音频可选择本机播放、主机同时播放与后台音频；进入画中画前确认系统允许。',
      '网络设置可控制计费网络、自动重连预算、地址族与串流加密兼容性。'
    ], note: '允许旧 SHA-1 是高风险兼容项，只有确认旧 Sunshine 环境确有需要时才开启。'
  },
  {
    id: 'moonlight-lifecycle', protocol: 'moonlight', devices: ALL_DEVICES,
    title: 'Moonlight 画中画、重连与退出', summary: '分清本地串流和主机应用',
    steps: [
      '启动确认会列出主机、应用和画质快照；检查无误后再进入串流，避免把设置应用到错误主机。',
      '进入画中画或后台音频前确认系统权限；控制能力可能暂停，返回前不要假设输入仍在发送。',
      '网络中断只在设置的预算内自动重连；超时后返回应用目录，核对主机状态再重试。',
      '“仅断开”会保留主机应用；“结束主机应用并断开”会请求 Sunshine 终止，失败时保留恢复记录。'
    ], note: '直接关闭窗口可能让主机状态不明确；优先使用会话内的安全退出入口。'
  },
  {
    id: 'moonlight-data', protocol: 'moonlight', devices: ALL_DEVICES,
    title: 'Moonlight 数据、诊断与删除', summary: '区分可同步配置和本机信任',
    steps: [
      '设置、主机和配置档只有在云同步中逐项勾选后才会跨设备；默认不会自动开启。',
      '配对信任、证书、客户端身份与私钥始终留在本机；换机恢复后重新配对。',
      '串流问题可临时打开性能 HUD，并从诊断复制脱敏指标。',
      '忘记主机、解除配对、删除本地数据和删除安全身份含义不同，按确认说明选择。'
    ], note: '删除安全身份会使现有配对失效；执行前先确认没有仍需使用的主机。'
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
