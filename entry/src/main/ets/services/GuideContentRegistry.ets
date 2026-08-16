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
    desc: 'RDP：在画面上三指轻点打开“控制面板”，再点“虚拟键盘”；RustDesk：手机或 Pad 可用同一控制面板，PC/Pad 也可点顶部或贴边工具栏的键盘图标，再选“打开虚拟键盘”；VNC：展开 VNC 工具栏后点“键盘”。SSH 点击终端输入区唤起系统软键盘；点“关闭键盘/收键盘”或系统返回即可收起，VNC 只读会话不能发送键盘。'
  },
  {
    id: 'hands-on-shortcuts',
    symbol: $rawfile('icons/key.svg'),
    title: '组合键和修饰键怎么用',
    desc: 'RDP/RustDesk：三指轻点打开“控制面板”后点“组合键”；VNC：展开会话工具栏后点“组合键”。先点 Ctrl、Alt、Shift、Fn 或 Windows 等修饰键，再点目标键；锁定态会保持到再次点击。Ctrl + Alt + Del 可在组合键面板选择，RustDesk 也可从“控制”菜单直接发送。'
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
    desc: 'VNC：展开会话工具栏，点击当前“触控板/触控/键鼠”按钮循环切换；RDP 和 RustDesk：在设置中打开对应协议的“操控模式”选择。桌面应用优先用触控板，触控设备优先用触控，接入实体鼠标键盘时用键鼠；VNC 只读会话不会发送输入。'
  },
  {
    id: 'hands-on-zoom',
    symbol: $rawfile('icons/computer-desktop.svg'),
    title: '双指分开或捏合来缩放',
    desc: '手机或 Pad 先到“设置 → 显示与交互”打开“双指画布缩放”，再在远程画面上两指分开即可放大、捏合即可缩小，缩放中心会跟随两指之间的焦点。RustDesk 若打开“远端应用双指缩放”，手势会发送给被控端应用而不是改变本地画布；本地缩放不会修改远端分辨率。'
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
    desc: 'RustDesk：打开工具栏“显示”菜单，选择“适应窗口、100%—200%或自定义缩放”，再点“重新居中画面”；VNC：展开工具栏点击当前显示比例，切换比例会重新居中；RDP：到“设置 → 显示与交互 → 本地显示缩放”重新选择比例。它们都只改变本地查看比例，不改变远端分辨率。'
  },
  {
    id: 'hands-on-desktop-file-transfer',
    symbol: $rawfile('icons/folder-open.svg'),
    title: 'RDP / RustDesk 发送文件',
    desc: '连接后用三指轻点打开会话控制面板，选择“发送文件到桌面”；RustDesk 也可从顶部/贴边工具栏的“控制”菜单选择“传输文件”。RDP 会通过远端剪贴板文件通道并向当前远端位置发送 Ctrl+V，先打开目标桌面或文件夹；RustDesk 需要打开“允许复制粘贴文件”，并等待被控端确认。PC 端可把文件拖到远程画面；VNC 不提供远程桌面文件传输。'
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
    desc: 'RDP：在“Windows RDP → 剪贴板同步”开启文本通道；RustDesk：在“控制”菜单开启“发送剪贴板按键”，并保持剪贴板允许；VNC：在 VNC 主机设置打开“剪贴板”，只读连接仍不能发送。SSH 当前不提供远程剪贴板同步，可使用终端自己的本地复制/粘贴。文件发送是独立入口，但 RDP 文件发送仍依赖文件剪贴板通道；按钮不可用时先检查连接、开关、权限和协议能力。'
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
