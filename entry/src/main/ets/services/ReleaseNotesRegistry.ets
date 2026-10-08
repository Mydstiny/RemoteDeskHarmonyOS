import { PRO_TRIAL_STORY } from './ProTrialStory';

export const CURRENT_RELEASE_VERSION: string = '1.2.0';
export const CURRENT_RELEASE_VERSION_CODE: number = 1001008;

export interface ReleaseNotePage {
  id: string;
  symbol: ResourceStr;
  title: string;
  desc: string;
  /** 新功能 / 改进 / 修复 / 即将推出 — shown as a small label. */
  tag?: string;
  points?: string[];
  /** HarmonyOS system symbol drawn instead of `symbol` when present. */
  glyph?: Resource;
}

/** One-line summary shown under the version in the 1.1.6+ 「新功能」 list. */
export function releaseHeadline(version: string): string {
  if (version === '1.2.0') { return 'AI 助理与远程 AI 登场，全新视觉默认开启，SSH 与 PC 体验全面打磨；所有 Pro 功能免费试用。'; }
  if (version === '1.1.6') { return 'RDP 会话内传文件、VNC 多显示器切换、竖屏会话更顺手，连接、终端与设置体验全面打磨。'; }
  return '';
}

export function pagesForReleasedVersion(version: string): ReleaseNotePage[] {
  if (version === CURRENT_RELEASE_VERSION) { return currentReleasePages(); }
  if (version === '1.1.6') { return release116Pages(); }
  if (version === '1.1.5.1') { return release1151Pages(); }
  if (version === '1.1.5') { return release115Pages(); }
  if (version === '1.1.4') { return release114Pages(); }
  if (version === '1.1.3') { return release113Pages(); }
  return [];
}

export function currentReleasePageCount(): number {
  return currentReleasePages().length;
}

// 1.2.0: the free Pro trial leads, then AI 助理 and everything it can now do; 1.1.6 is summed up last for anyone
// updating straight from an older version.
function currentReleasePages(): ReleaseNotePage[] {
  return [
    {
      id: 'release-pro-trial', symbol: $rawfile('icons/key.svg'), glyph: $r('sys.symbol.star_fill'),
      tag: '免费试用', title: 'Pro 全部功能免费试用',
      desc: '所有用户都能免费使用已开发的全部 Pro 功能：AI 助理、远程 AI、工作区、高级主机管理、远端显示方案、个性化、同账号接续等。' +
        PRO_TRIAL_STORY
    },
    {
      id: 'release-ai-assistant', symbol: $rawfile('icons/cloud.svg'), glyph: $r('sys.symbol.wand_and_stars'),
      tag: '新功能', title: 'AI 助理：聊天与助理',
      desc: '聊天能写作、翻译、总结，读你添加的文档并生成 Word 和 Excel；助理专管 RemoteDesktop 的连接、设置和诊断。问题该归谁，它们会自己转交。'
    },
    {
      id: 'release-ai-voice', symbol: $rawfile('icons/command-line.svg'), glyph: $r('sys.symbol.mic_fill_waves_left_and_right'),
      tag: 'Beta', title: 'AI 语音',
      desc: '在「设置 → AI 语音」打开后，可以像 Siri 一样和 AI 说话：回答时随时插话打断，连续对话，说“回到文字”“拜拜”就切换或退出。朗读和识别都可选本机或云端。'
    },
    {
      id: 'release-ai-tools', symbol: $rawfile('icons/cog-6-tooth.svg'), glyph: $r('sys.symbol.checkmark_shield'),
      tag: '新功能', title: 'AI 能帮你动手',
      desc: '设提醒、查日程、联网搜索、分享、改设置、连接主机；它生成的文档、设的提醒、记住的事、对话记录和主机，也能查看、修改和删除。会改动数据的操作都先给你确认。'
    },
    {
      id: 'release-ai-session', symbol: $rawfile('icons/computer-desktop.svg'), glyph: $r('sys.symbol.smal_window_playback'),
      tag: '新功能', title: '连接中也能用 AI',
      desc: 'RDP、RustDesk、VNC、Moonlight 的侧栏和 SSH 的「更多」里都有 AI。它以悬浮球加小对话框出现：单击退出、双击说话、长按拖动，横竖屏都会避开侧栏。'
    },
    {
      id: 'release-ai-feedback', symbol: $rawfile('icons/shield-check.svg'), glyph: $r('sys.symbol.envelope_fill'),
      tag: '新功能', title: '需求收集与反馈邮件',
      desc: '你随口提的想法，AI 会记下来；说一声“把需求发给开发者”，就整理成邮件。诊断邮件也重新排版：初步诊断、详细诊断、逐条建议，诊断日志作为附件。'
    },
    {
      id: 'release-ai-layout', symbol: $rawfile('icons/computer-desktop.svg'), glyph: $r('sys.symbol.rectangle_on_rectangle'),
      tag: '改进', title: 'AI 始终在最上层，新增小艺风格',
      desc: '语音模式、AI 面板和悬浮球不再被设置页等弹窗挡住，手机横屏、平板分屏和 PC 小窗口里也不会超出窗口；PC 大屏上，AI 按钮移到左下角，和「+」并排。设置 › AI 动效里可以换成小艺风格：蓝紫渐变和随声音起伏的彩色光环。'
    },
    {
      id: 'release-remote-ai', symbol: $rawfile('icons/command-line.svg'), glyph: $r('sys.symbol.code_square'),
      tag: '新功能', title: '远程 AI：Codex、DSH、Pi',
      desc: '在手机和平板上接着用电脑上的 Codex、DSH 和 Pi：回复逐字显示，命令和改动可展开查看，操作审批直接点；运行中可以补充要求或打断重来。切到后台不再断开，审批也不会丢。电脑端插件可从 GitHub 或 Gitee 安装。'
    },
    {
      id: 'release-new-look', symbol: $rawfile('icons/cog-6-tooth.svg'), glyph: $r('sys.symbol.paintpalette_fill'),
      tag: '改进', title: '全新视觉默认开启',
      desc: '设置按用途分组、顶部可搜索、直接显示当前值；远程主机、密钥保险库和中继页一起换新外观，搜索框统一成玻璃胶囊。想要原来的样子，在「设置 → 个性化 → 全新视觉」关掉即可。应用图标里也多了一款「流光」。'
    },
    {
      id: 'release-touch-scroll', symbol: $rawfile('icons/computer-desktop.svg'), glyph: $r('sys.symbol.mouse'),
      tag: '改进', title: '三指滚动，滚轮随手调',
      desc: '开启双指缩放后，双指只用来缩放和移动画面，滚动改为三指上下滑动，不再和缩放抢手势；三指轻点不再打开控制面板。每个协议的滚轮方向和速度可以分别设置，RDP、RustDesk、VNC 连接中也能直接调。'
    },
    {
      id: 'release-rustdesk-display', symbol: $rawfile('icons/computer-desktop.svg'), glyph: $r('sys.symbol.display'),
      tag: '新功能', title: 'RustDesk 连接中调整显示',
      desc: '侧栏里直接切换远端显示器、分辨率、编解码和画质；Windows 被控端还能开隐私模式、插入虚拟显示器，断开后自动恢复。'
    },
    {
      id: 'release-ssh-polish', symbol: $rawfile('icons/command-line.svg'), glyph: $r('sys.symbol.folder_fill'),
      tag: '改进', title: 'SSH 与 SFTP 焕新',
      desc: 'SFTP 回到弹窗并重新设计，带过渡动画，可以直接把文件拖进来上传；命令面板的搜索框不再被输入法挡住；画中画多次退出到后台也都能出现。PC 上默认开启 SSH 工作台，「更多」里可以直接调终端字号。'
    },
    {
      id: 'release-pc-polish', symbol: $rawfile('icons/computer-desktop.svg'), glyph: $r('sys.symbol.display'),
      tag: '改进', title: 'PC 上更顺手',
      desc: 'RDP 默认按整块屏幕的分辨率连接，窗口怎么缩放都按比例显示；想让远端分辨率跟着窗口变，在 RDP 控制里打开「分辨率跟随窗口」。RDP、VNC、Moonlight 的顶栏不再把「断开」挤出框外，高级主机管理的弹窗居中显示，顶栏子菜单改为点按展开。修复部分 PC 上 RustDesk 硬件解码画面倒置。'
    },
    {
      id: 'release-pro-clarity', symbol: $rawfile('icons/key.svg'), glyph: $r('sys.symbol.checkmark_shield'),
      tag: '改进', title: 'Pro 写得更清楚',
      desc: 'Pro 页面逐项写明每个功能的状态，还没完成的说明原因，AI 助理也照此回答。价格页说明 Pro 是买断制；应用分身暂不支持 Pro，会直接说明，不再给出必然失败的购买入口。'
    },
    {
      id: 'release-1-1-6-summary', symbol: $rawfile('icons/folder-open.svg'), glyph: $r('sys.symbol.folder_fill'),
      tag: '改进', title: '也包含 1.1.6 的全部更新',
      desc: 'RDP 会话里直接传文件、VNC 多显示器切换、竖屏显示方式与侧栏高度、点按输入框弹出键盘、RDP 证书预检可跳过，以及 SSH、RustDesk 与设置页的多项打磨。'
    }
  ];
}

// The 1.1.6 notes, as they shipped: Pro appeared only as a 即将推出 preview.
function release116Pages(): ReleaseNotePage[] {
  return [
    {
      id: 'release-rdp-file-transfer', symbol: $rawfile('icons/folder-open.svg'), glyph: $r('sys.symbol.folder_fill'),
      tag: '新功能', title: 'RDP 会话里直接传文件',
      desc: '会话工具栏新增文件传输入口；远端只允许下载时也能打开文件面板，剪贴板文件的接收状态会实时显示。'
    },
    {
      id: 'release-vnc-monitors', symbol: $rawfile('icons/computer-desktop.svg'), glyph: $r('sys.symbol.display'),
      tag: '新功能', title: 'VNC 多显示器切换',
      desc: '连接 UltraVNC 时可以从侧栏选择要查看的显示器，切换失败或超时后可以直接重试。'
    },
    {
      id: 'release-portrait-display', symbol: $rawfile('icons/computer-desktop.svg'), glyph: $r('sys.symbol.rectangle_rotate'),
      tag: '新功能', title: '手机竖屏可选显示方式',
      desc: 'RDP、RustDesk、VNC 与 Moonlight 在手机竖屏时可分别选择画面显示方式，并能开关会话侧栏。'
    },
    {
      id: 'release-portrait-sidebar', symbol: $rawfile('icons/computer-desktop.svg'), glyph: $r('sys.symbol.rectangle_on_rectangle'),
      tag: '新功能', title: '竖屏侧栏高度可调',
      desc: '手机竖屏会话的侧栏提供自动、紧凑、标准、高四档高度，在「设置 → 显示与交互」里按习惯选择。'
    },
    {
      id: 'release-tap-keyboard', symbol: $rawfile('icons/command-line.svg'), glyph: $r('sys.symbol.keyboard'),
      tag: '新功能', title: '点按输入框自动弹出键盘',
      desc: '在「键盘 → 输入行为」打开后，点按远端输入位置会自动弹出软键盘；横屏悬浮显示，竖屏正常避让。默认关闭。'
    },
    {
      id: 'release-rdp-cert-preflight', symbol: $rawfile('icons/shield-check.svg'), glyph: $r('sys.symbol.checkmark_shield'),
      tag: '新功能', title: 'RDP 证书预检可以跳过',
      desc: '在「设置 → Windows RDP」可关闭连接前的证书预检，直连更快；连接时仍会核验证书，未知或异常证书需要你确认。'
    },
    {
      id: 'release-rdp-connect', symbol: $rawfile('icons/globe-alt.svg'), glyph: $r('sys.symbol.link'),
      tag: '改进', title: 'RDP 更容易连上',
      desc: '域名解析失败时自动改用备用解析；连接前检查与实际连接走同一条线路；检查未通过时也可以确认风险后直接连接。'
    },
    {
      id: 'release-ssh-polish', symbol: $rawfile('icons/command-line.svg'), glyph: $r('sys.symbol.code_square'),
      tag: '改进', title: 'SSH 终端更清爽',
      desc: '手机默认字号更合适，登录后不再多出空行；终端里的弹窗按内容自动调整高度，标签栏与按钮重新对齐。'
    },
    {
      id: 'release-rustdesk-fixes', symbol: $rawfile('icons/cog-6-tooth.svg'), glyph: $r('sys.symbol.bolt_fill'),
      tag: '修复', title: 'RustDesk 画质与文件传输',
      desc: '画质档位重新对齐并在诊断中实时显示；修复手机上的文件传输面板，远端路径改用文件浏览器选择。'
    },
    {
      id: 'release-offline-account', symbol: $rawfile('icons/shield-check.svg'), glyph: $r('sys.symbol.person_crop_circle_fill'),
      tag: '修复', title: '没有网络也能进入应用',
      desc: '离线启动时保留上次登录的华为账号，主机列表和本机数据照常可用；VNC 新主机默认记住你输入的密码。'
    },
    {
      id: 'release-diagnostics', symbol: $rawfile('icons/cloud.svg'), glyph: $r('sys.symbol.performance'),
      tag: '改进', title: '诊断信息更完整',
      desc: '日志新增完整抓取档位，覆盖连接前的各项检查，排查问题更快；导出内容仍会自动脱敏。'
    },
    {
      id: 'release-smooth-settings', symbol: $rawfile('icons/cog-6-tooth.svg'), glyph: $r('sys.symbol.gearshape_fill'),
      tag: '改进', title: '设置页更流畅',
      desc: '设置页滑动更顺滑；动效只在屏幕上看得见时运行，并与屏幕刷新同步，更省电也不再卡顿。'
    },
    {
      id: 'release-onboarding', symbol: $rawfile('icons/computer-desktop.svg'), glyph: $r('sys.symbol.sun_max_fill'),
      tag: '改进', title: '新手引导焕新',
      desc: '引导扩充到 9 页，按手机、平板和 PC 分别排版；主页、安全锁与 2FA 都有介绍，随时可在「设置 → 教程」回看。'
    },
    {
      id: 'release-pro-preview', symbol: $rawfile('icons/key.svg'), glyph: $r('sys.symbol.star_fill'),
      tag: '即将推出', title: 'RemoteDesktop Pro 预告',
      desc: '同账号接续、工作区与布局、高级主机管理、远端显示方案、个性化与远程 AI 正在打磨，读完更新说明即可预览 Pro 功能介绍。'
    }
  ];
}

function release1151Pages(): ReleaseNotePage[] {
  return [
    {
      id: 'release-1-1-5-1',
      symbol: $rawfile('icons/computer-desktop.svg'),
      title: '1.1.5.1：集中修复十二项用户反馈',
      desc: '本次更新集中完善鸿蒙 PC 画面、RDP 操控与缩放、RustDesk 工具栏和剪贴板、SSH 常用命令，以及键盘和退出保护。'
    },
    {
      id: 'release-flip-fallback-diagnostics',
      symbol: $rawfile('icons/computer-desktop.svg'),
      title: '1. PC 画面翻转与诊断',
      desc: 'Moonlight 增加与 RustDesk 一致的手动画面翻转兜底；硬件解码诊断同步记录生产者矩阵、渲染矩阵、代际和应用后的变换，便于复现时直接收敛根因。'
    },
    {
      id: 'release-rdp-ephemeral-auth',
      symbol: $rawfile('icons/shield-check.svg'),
      title: '2. RDP 连接凭据与断线归因',
      desc: 'RDP 可选择每次连接时输入账户和密码，临时凭据退出后即清理；只有服务器 ErrorInfo 才归因为服务器错误，客户端或网络失败不再默认误报为 0x10。'
    },
    {
      id: 'release-rdp-pointer-mapping',
      symbol: $rawfile('icons/cog-6-tooth.svg'),
      title: '3. 修正 RDP 全屏鼠标映射',
      desc: '统一画面布局、真实远端尺寸和输入坐标的代际校验，修复 PC 全屏模式下鼠标只能映射到左上角区域的问题。'
    },
    {
      id: 'release-rustdesk-toolbar',
      symbol: $rawfile('icons/cog-6-tooth.svg'),
      title: '4. RustDesk 工具栏更直观',
      desc: '可继续选择的工具项会展开二级菜单，画质和编解码等状态不再只读；鼠标悬停按钮时会直接显示名称。'
    },
    {
      id: 'release-rustdesk-codec-telemetry',
      symbol: $rawfile('icons/computer-desktop.svg'),
      title: '5. RustDesk 编解码选择与监控对齐',
      desc: '修复预鉴权连接遗漏编解码偏好的问题；选择 H.265 后会把请求完整传入协议协商，性能监控继续显示当前会话实际生效的编码与解码后端。'
    },
    {
      id: 'release-rdp-resolution-scaling',
      symbol: $rawfile('icons/computer-desktop.svg'),
      title: '6. 优化 RDP 分辨率与缩放',
      desc: '重新对齐控制端窗口、远端桌面尺寸、动态布局和显示缩放，自动模式优先填满可用区域，并减少比例不匹配造成的大黑边。'
    },
    {
      id: 'release-dock-input-fence',
      symbol: $rawfile('icons/cog-6-tooth.svg'),
      title: '7. Dock 最小化不再误触远端',
      desc: '鸿蒙 PC 窗口失焦、最小化和恢复期间会封锁并释放残留指针事务，避免点击 Dock 应用图标被转成远端右键。'
    },
    {
      id: 'release-ssh-common-commands',
      symbol: $rawfile('icons/command-line.svg'),
      title: '8. SSH 常用命令可编辑调用',
      desc: 'SSH“更多”中新增可维护的常用命令列表，可添加、修改和删除，并在终端中随时选择调用。'
    },
    {
      id: 'release-protected-exit',
      symbol: $rawfile('icons/shield-check.svg'),
      title: '9. 可关闭远程会话快捷退出',
      desc: '设置可要求只能通过明确按钮退出远程会话；启用后会保留顶栏或侧栏，避免误操作后失去安全退出入口。'
    },
    {
      id: 'release-rustdesk-clipboard',
      symbol: $rawfile('icons/command-line.svg'),
      title: '10. 修复 RustDesk 双向文本剪贴板',
      desc: '补全远端到本机的文本剪贴板接收、权限和防回环路径，本机与远端之间均可复制粘贴文本。'
    },
    {
      id: 'release-host-list-safe-area',
      symbol: $rawfile('icons/computer-desktop.svg'),
      title: '11. 主机列表避让悬浮按钮',
      desc: '经典主机模式增加底部滚动安全区，主机较多时最后一张卡片也能滑出悬浮按钮覆盖范围。'
    },
    {
      id: 'release-harmony-shortcut-capture',
      symbol: $rawfile('icons/key.svg'),
      title: '12. 按设备屏蔽鸿蒙快捷键',
      desc: '键盘设置新增简化后的设备分类开关和图标，明确说明打开即屏蔽鸿蒙快捷键；PC 默认屏蔽，选择会持久化保存。'
    },
    {
      id: 'welcome-1-1-5-1',
      symbol: $rawfile('icons/globe-alt.svg'),
      title: '更新完成，等待实机验收',
      desc: '以上能力已完成代码修复与构建复核；不同设备、协议和远端系统的最终效果仍以你的统一实机验收为准。'
    }
  ];
}

function release115Pages(): ReleaseNotePage[] {
  const introduction: ReleaseNotePage[] = [
    {
      id: 'release-1-1-5',
      symbol: $rawfile('icons/computer-desktop.svg'),
      title: '1.1.5：连接、显示与网络适配再升级',
      desc: '本次更新在五协议工作台现有能力上，继续完善会话画面控制、PC 显示适配、RustDesk 多显示器、连接恢复与脱敏诊断。'
    }
  ];
  const additions: ReleaseNotePage[] = [
    {
      id: 'release-session-view-controls',
      symbol: $rawfile('icons/cog-6-tooth.svg'),
      title: '远程画面操作可按协议调整',
      desc: 'RDP、RustDesk、VNC 与 Moonlight 可分别保存双指缩放偏好，并从会话控制区恢复画面状态；选择项、隐藏项和恢复入口都按协议保持一致。'
    },
    {
      id: 'release-rustdesk-quality-displays',
      symbol: $rawfile('icons/computer-desktop.svg'),
      title: 'RustDesk 质量与多显示器更完整',
      desc: '会话可选择低延迟、均衡或最佳质量；HarmonyOS PC 的实验多画布模式最多同时查看两块远端显示器，异常时会安全回退到单画布。'
    },
    {
      id: 'release-rdp-adaptive-display',
      symbol: $rawfile('icons/computer-desktop.svg'),
      title: 'RDP 更好适配高 DPI 与多屏 PC',
      desc: 'PC 端会结合活动显示器密度、窗口尺寸和方向请求合适的远端画面；跨屏或服务端不支持动态调整时，会保留可用会话并采用兼容回退。'
    },
    {
      id: 'release-network-diagnostics',
      symbol: $rawfile('icons/globe-alt.svg'),
      title: '连接恢复与双栈诊断更清晰',
      desc: '网络切换会淘汰过期的连接和重连任务，Moonlight 添加入口不再被可选探测临时置灰；抓日志可按连接记录脱敏 IPv4/IPv6 地址族与作用域，不导出原始地址。'
    },
    {
      id: 'welcome-1-1-5',
      symbol: $rawfile('icons/globe-alt.svg'),
      title: '准备就绪，开始连接',
      desc: '五协议工作台会继续按真实运行能力开放入口；需要回看本次变化时，可随时打开“设置 → 教程 → 本版本更新日志”。'
    }
  ];
  return introduction.concat(release114FeaturePages()).concat(additions);
}

function release114FeaturePages(): ReleaseNotePage[] {
  return [
    {
      id: 'release-secret-visibility',
      symbol: $rawfile('icons/shield-check.svg'),
      title: '保存的敏感信息由你决定是否显示',
      desc: '“数据与安全”新增本机显示策略，可按凭据类型隐藏已保存密码；修改主机其他信息时不会误清空原密码，应用锁定和高敏感凭据仍优先保持隐藏。'
    },
    {
      id: 'release-clipboard-activation',
      symbol: $rawfile('icons/command-line.svg'),
      title: '文本剪贴板连接后即可使用',
      desc: 'RDP、RustDesk 与 VNC 会在会话开始时正确激活系统剪贴板读取，无需先传输文件；仅接收模式、权限拒绝提示、断线重连与防回环行为继续保持。'
    },
    {
      id: 'release-app-clone',
      symbol: $rawfile('icons/folder-open.svg'),
      title: '支持系统应用分身',
      desc: '在支持该能力的 HarmonyOS 手机和平板上，可创建一个本地分身并独立保存主机、凭据、密钥和设置；分身默认不登录云账号、不参与云同步，也不启用自动剪贴板桥接。'
    },
    {
      id: 'release-rustdesk-mobile',
      symbol: $rawfile('icons/computer-desktop.svg'),
      title: '控制手机时画面和触控更准确',
      desc: 'RustDesk 修正手机横竖屏切换、纹理方向、缩放和平移坐标；直接触控的点击、滑动、长按与双指手势更贴近手机语义，异常中断时也会主动释放残留输入。'
    },
    {
      id: 'release-session-ui-stability',
      symbol: $rawfile('icons/key.svg'),
      title: '键盘侧栏与会话界面更可靠',
      desc: '图形会话的贴边入口可统一打开或关闭键盘界面，新增 Delete 编辑键；自定义快捷键编辑器会适应横屏、分屏和 PC 窗口，手机沉浸栏与设置折叠区域也更稳定。'
    },
    {
      id: 'release-cloud-recovery',
      symbol: $rawfile('icons/cloud.svg'),
      title: '云服务异常不再阻断本地数据',
      desc: '登录后的权限竞争或历史数据迁移失败时，会优先保留当前账号的本地读取与保存能力，并在条件恢复后安全重试；删除、清空和离线修改不会被旧云数据静默复活。'
    },
    {
      id: 'release-rustdesk-desktop-flip',
      symbol: $rawfile('icons/cog-6-tooth.svg'),
      title: 'PC 端新增 RustDesk 桌面翻转',
      desc: 'HarmonyOS PC 控制电脑时，可从顶部工具栏分别切换画面与控制层的上下、左右翻转或一键复位；选择按主机保存在本机，重连、画中画和窗口恢复后继续生效。'
    },
    {
      id: 'release-wheel-direction',
      symbol: $rawfile('icons/cog-6-tooth.svg'),
      title: '五种协议可分别设置滚轮方向',
      desc: '“显示与交互”现在可独立设置 RDP、RustDesk、SSH、VNC 与 Moonlight 的正常或反向滚动，并提供全部正常、全部反向操作；SFTP 文件列表不受影响。'
    }
  ];
}

function release114Pages(): ReleaseNotePage[] {
  const introduction: ReleaseNotePage[] = [
    {
      id: 'release-1-1-4',
      symbol: $rawfile('icons/computer-desktop.svg'),
      title: '1.1.4：连接、输入与数据恢复更稳',
      desc: '在保留 1.1.3 全部五协议能力的基础上，集中完善敏感信息保护、剪贴板、会话操控、应用分身和云数据恢复。'
    }
  ];
  const conclusion: ReleaseNotePage[] = [
    {
      id: 'welcome-1-1-4',
      symbol: $rawfile('icons/globe-alt.svg'),
      title: '欢迎使用 1.1.4',
      desc: '本次更新延续五协议工作台，并把会话操控、敏感数据和异常恢复做得更稳。需要回看全部变化时，可随时打开“设置 → 教程 → 本版本更新日志”。'
    }
  ];
  return introduction.concat(release114FeaturePages()).concat(conclusion);
}

function release113Pages(): ReleaseNotePage[] {
  return [
    {
      id: 'release-1-1-3',
      symbol: $rawfile('icons/computer-desktop.svg'),
      title: '1.1.3：五协议工作台持续优化',
      desc: '在 1.1.2 的五协议工作台基础上，继续优化会话操控、设备适配、安全校验和操作引导。'
    },
    {
      id: 'release-moonlight-workflow',
      symbol: $rawfile('icons/globe-alt.svg'),
      title: 'Moonlight 加入主机工作台',
      desc: '可发现或手动添加 Sunshine 主机，完成身份核对与配对，再浏览应用目录并发起串流；主机详情、应用缓存与连接设置都归入统一入口。'
    },
    {
      id: 'release-moonlight-session',
      symbol: $rawfile('icons/computer-desktop.svg'),
      title: '串流、输入与生命周期更完整',
      desc: 'Moonlight 会话接入画面、声音、键鼠、触控和控制器输入，并处理重连、画中画、前后台恢复以及“仅断开/结束主机应用”的不同退出语义。'
    },
    {
      id: 'release-ssh-workspace',
      symbol: $rawfile('icons/command-line.svg'),
      title: 'SSH 升级为多窗格工作台',
      desc: '标签页、侧栏、终端窗格、检查器和状态栏重新组织；宽屏可并行处理多会话，手机和窄窗口则保留清晰的单任务路径与稳定输入焦点。'
    },
    {
      id: 'release-ssh-productivity',
      symbol: $rawfile('icons/folder-open.svg'),
      title: 'SSH/SFTP 工具集中到手边',
      desc: '新增终端搜索、常用命令、广播输入、配置档案与快捷键；端口转发、SFTP 双栏和传输中心也统一呈现进度、重试与完整性结果。'
    },
    {
      id: 'release-session-keyboard',
      symbol: $rawfile('icons/key.svg'),
      title: '图形会话共用远程键盘',
      desc: 'RDP、RustDesk、VNC 与 Moonlight 共用贴边入口，可切换 Windows/macOS 键位、发送功能键与导航键，并保存常用组合键；手机横屏和输入法弹出时仍可触达。'
    },
    {
      id: 'release-device-layouts',
      symbol: $rawfile('icons/computer-desktop.svg'),
      title: '手机、Pad 与 PC 各得其所',
      desc: '手机优先触控和贴边控制，Pad 兼顾触控与键鼠，PC 使用独立会话窗口和多窗格工作区；弹窗、侧栏和控制面板会随可用窗口尺寸调整。'
    },
    {
      id: 'release-lan-discovery',
      symbol: $rawfile('icons/globe-alt.svg'),
      title: '局域网主机更容易找到',
      desc: 'RDP 与 RustDesk 可从局域网发现结果创建主机；保存时明确选择固定地址同步，或保留动态地址仅在本机自动刷新，避免 DHCP 变化污染云端记录。'
    },
    {
      id: 'release-security-preflight',
      symbol: $rawfile('icons/shield-check.svg'),
      title: '连接前校验路径更一致',
      desc: '主机锁、RDP 证书、VNC TLS/明文决策与凭据重试统一在进入会话前完成；一次性凭据不会重复询问，服务器身份发生变化时也不会静默沿用旧信任。'
    },
    {
      id: 'release-guidance',
      symbol: $rawfile('icons/cog-6-tooth.svg'),
      title: '引导只在真正需要时出现',
      desc: '首次教程按设备说明协议选择和安全连接；SSH、Moonlight 与远程触控提示默认各显示一次。需要反复查看时，可在“设置 → 教程”开启“始终显示引导”。'
    },
    {
      id: 'release-data-diagnostics',
      symbol: $rawfile('icons/cloud.svg'),
      title: '数据边界与排障更可靠',
      desc: 'Moonlight 主机删除不再依赖华为云空间在线：无账号、未开通云空间或断网时都会先安全保存到本机，云恢复后自动同步删除状态；配对信任仍只留在本机。'
    },
    {
      id: 'welcome-1-1-3',
      symbol: $rawfile('icons/globe-alt.svg'),
      title: '欢迎使用 1.1.3',
      desc: '现在可以从主机工作台体验五种协议。第一次尝试新能力时先按界面核对服务端、身份与网络条件；完整步骤可从“设置 → 教程 → 操作引导中心”随时查看。'
    }
  ];
}
