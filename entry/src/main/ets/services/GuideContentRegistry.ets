/**
 * GuideContentRegistry — 新用户引导与设置教程的唯一内容源。
 *
 * 两种入口共享全部功能介绍，只使用不同的收尾页。
 */
export interface GuideContentPage {
  id: string;
  symbol: ResourceStr;
  title: string;
  desc: string;
}

const SHARED_GUIDE_PAGES: GuideContentPage[] = [
  {
    id: 'four-protocol-workspace',
    symbol: $rawfile('icons/computer-desktop.svg'),
    title: '四种协议，一个工作台',
    desc: 'RDP 连接 Windows，RustDesk 负责跨平台远控，SSH/SFTP 管理服务器，VNC 连接标准兼容设备。先按目标设备选择协议。'
  },
  {
    id: 'vnc-first-steps',
    symbol: $rawfile('icons/globe-alt.svg'),
    title: 'VNC：先确认服务与端口',
    desc: '确认远端已启用 VNC 服务，再填写地址、端口和密码。连接质量不理想时，可在主机设置中调整画质、编码和输入选项。'
  },
  {
    id: 'add-and-organize',
    symbol: $rawfile('icons/folder-open.svg'),
    title: '添加、分组并观察主机',
    desc: '从统一“添加”入口选择协议并保存主机，再按类型分组整理设备。在线检测和性能监控都可按需开启，不使用时保持关闭即可。'
  },
  {
    id: 'verify-before-trust',
    symbol: $rawfile('icons/shield-check.svg'),
    title: '第一次连接，先确认身份',
    desc: '核对 RDP 证书、SSH 主机指纹或 RustDesk 被控端信息；密码、批准和二次验证只在来源可信时提交。'
  },
  {
    id: 'session-controls',
    symbol: $rawfile('icons/computer-desktop.svg'),
    title: '按设备选择操控方式',
    desc: '手机和 Pad 可使用虚拟触控板，PC 推荐实体键鼠。双指缩放画面；双指长按后拖动可平移画布，会话控制栏还能切换输入方式。'
  },
  {
    id: 'ssh-workspace',
    symbol: $rawfile('icons/command-line.svg'),
    title: 'SSH：多会话各自独立',
    desc: 'SSH 工作台可同时连接多台主机并保留各自终端。需要访问内网服务时，可为当前主机配置本地、远程或动态隧道转发。'
  },
  {
    id: 'files-and-tools',
    symbol: $rawfile('icons/folder-open.svg'),
    title: '用 SFTP 管理与传输文件',
    desc: '在 SSH 会话中打开 SFTP，可浏览本机和远端目录、上传下载或在两台 SSH 主机间传输。重要任务中断后可从任务记录继续处理。'
  },
  {
    id: 'two-factor-and-credentials',
    symbol: $rawfile('icons/key.svg'),
    title: '密钥、证书与 2FA 分开保管',
    desc: '验证器使用真实供应商 Logo 帮助识别动态口令；SSH 密钥、RDP 证书信任和 RustDesk 凭据仍独立保存，连接时只选择需要的凭据。'
  },
  {
    id: 'cloud-and-backup',
    symbol: $rawfile('icons/cloud.svg'),
    title: '同步前，先选数据和方向',
    desc: '华为账号云同步只处理你勾选的数据。恢复备份后，请明确选择“上传本机”或“下载云端”，确认方向后再执行。'
  }
];

/**
 * 面向已经进入会话的用户的实操教程。
 *
 * 这组内容故意不并入首次安装引导：首次引导说明“能做什么”，设置页的
 * 实操教程说明“具体怎么做”，并且可以随时从设置重新打开。
 */
const HANDS_ON_GUIDE_PAGES: GuideContentPage[] = [
  {
    id: 'hands-on-start-connection',
    symbol: $rawfile('icons/computer-desktop.svg'),
    title: '先从主机卡片进入会话',
    desc: '在主机工作台点击“添加”，选择协议，填写地址、端口和凭据并保存，再点击主机卡片连接。第一次连接先核对证书、指纹或被控端批准。'
  },
  {
    id: 'hands-on-find-toolbar',
    symbol: $rawfile('icons/cog-6-tooth.svg'),
    title: '先找到会话工具栏',
    desc: '手机或平板点击画面边缘的箭头或控制柄展开工具栏，PC 端点击顶部控制条；VNC 工具栏自动收起后仍可点回。键盘、操控模式、组合键、显示和断开都从这里进入。'
  },
  {
    id: 'hands-on-keyboard',
    symbol: $rawfile('icons/key.svg'),
    title: '这样唤起和收起键盘',
    desc: 'RDP、RustDesk、VNC：展开工具栏后点击“键盘”；SSH：点击终端输入区，系统软键盘会跟随焦点出现，虚拟键栏也会显示。再次点“收键盘”或系统返回即可收起；接入实体键盘时直接输入。'
  },
  {
    id: 'hands-on-shortcuts',
    symbol: $rawfile('icons/key.svg'),
    title: '组合键和修饰键怎么用',
    desc: '需要 Ctrl、Alt、Shift、Fn 或 Windows 等组合键时，打开“组合键”或虚拟键栏，先点修饰键再点目标键；锁定态会保持到再次点击。RDP/RustDesk 的控制菜单可直接发送 Ctrl + Alt + Del。'
  },
  {
    id: 'hands-on-touchpad',
    symbol: $rawfile('icons/computer-desktop.svg'),
    title: '触控板的基本手势',
    desc: '触控板模式下：单指移动是移动光标，单指抬起是左键；单指长按约 1 秒后拖动是左键拖拽；双指轻点是右键，双指上下移动是滚轮，三指轻点打开或关闭会话控制面板。'
  },
  {
    id: 'hands-on-control-mode',
    symbol: $rawfile('icons/cog-6-tooth.svg'),
    title: '触控、触控板和键鼠可切换',
    desc: '点击工具栏上的操控模式按钮，在“触控板、触控、键鼠”之间切换：桌面应用优先用触控板，触控设备优先用触控，接入鼠标和键盘时用键鼠。VNC 只读会话不会发送输入。'
  },
  {
    id: 'hands-on-zoom',
    symbol: $rawfile('icons/computer-desktop.svg'),
    title: '双指分开或捏合来缩放',
    desc: '在支持画布缩放的远程桌面画面上，两指分开可放大、捏合可缩小，缩放中心会跟随两指之间的焦点。缩放只改变本地查看比例，不会修改远端分辨率。'
  },
  {
    id: 'hands-on-pan-canvas',
    symbol: $rawfile('icons/computer-desktop.svg'),
    title: '双指长按后拖动画布',
    desc: '画面放大后，两指同时按住约 0.4 秒，等到长按被识别，再向任意方向拖动即可平移画布；松手结束。双指立即移动会被识别为滚轮，因此“先按住、再拖动”很重要。'
  },
  {
    id: 'hands-on-display-reset',
    symbol: $rawfile('icons/computer-desktop.svg'),
    title: '画面偏了，如何恢复',
    desc: '打开“显示/画面”菜单可选择“适应窗口、100%—200%或自定义缩放”，点击“重新居中画面”恢复中心位置；窗口旋转或切换显示器后，也建议先重新居中再继续操作。'
  },
  {
    id: 'hands-on-desktop-file-transfer',
    symbol: $rawfile('icons/folder-open.svg'),
    title: 'RDP / RustDesk 发送文件',
    desc: '连接后打开会话控制面板，选择“发送文件到桌面”；RustDesk 也可在顶部工具栏的“控制”菜单选择“传输文件”，再从系统文件选择器挑选文件。PC 端还可直接把文件拖到远程画面。VNC 目前不提供远程桌面文件传输。'
  },
  {
    id: 'hands-on-sftp-file-transfer',
    symbol: $rawfile('icons/folder-open.svg'),
    title: 'SSH / SFTP 上传、下载与双主机传输',
    desc: 'SSH 会话顶部点击文件图标打开“SFTP 文件传输”：选择本机文件后点“上传到当前主机”，选中远端文件后点“下载”；Pad/PC 还可选择另一台 SSH 主机作为右侧端点，在两台主机间复制。'
  },
  {
    id: 'hands-on-clipboard',
    symbol: $rawfile('icons/folder-open.svg'),
    title: '文字剪贴板和文件传输要分开',
    desc: '文字复制粘贴需要在对应协议设置或会话菜单中开启；RustDesk 会话可打开“发送剪贴板按键”。文件发送走独立的文件传输入口，若按钮不可用，先检查连接状态、剪贴板/文件粘贴开关和协议能力。'
  },
  {
    id: 'hands-on-recover-and-exit',
    symbol: $rawfile('icons/shield-check.svg'),
    title: '中断后恢复，完成后断开',
    desc: 'SFTP 传输中可暂停、继续、取消或重试，断线后从“待恢复传输”继续；远程桌面传输会显示状态和进度。操作完成后点“断开”结束会话，避免在公共设备上留下凭据和未关闭的连接。'
  }
];

function sharedPages(): GuideContentPage[] {
  const pages: GuideContentPage[] = [];
  SHARED_GUIDE_PAGES.forEach((page: GuideContentPage): void => { pages.push(page); });
  return pages;
}

export function firstInstallGuidePages(): GuideContentPage[] {
  const pages: GuideContentPage[] = sharedPages();
  pages.push({
    id: 'start-first-host',
    symbol: $rawfile('icons/shield-check.svg'),
    title: '从第一台主机开始',
    desc: '准备好了。进入工作台，选择协议并添加第一台主机；遇到提示时先核对安全信息，再开始连接。'
  });
  return pages;
}

export function settingsUsageGuidePages(): GuideContentPage[] {
  const pages: GuideContentPage[] = sharedPages();
  pages.push({
    id: 'revisit',
    symbol: $rawfile('icons/cog-6-tooth.svg'),
    title: '需要时随时回来',
    desc: '从“设置 → 教程 → 简单使用教程”可以重新查看；协议部署、账号和服务端准备请继续打开“如何进行前置操作”。'
  });
  return pages;
}

export function handsOnUsageGuidePages(): GuideContentPage[] {
  const pages: GuideContentPage[] = [];
  HANDS_ON_GUIDE_PAGES.forEach((page: GuideContentPage): void => { pages.push(page); });
  return pages;
}
