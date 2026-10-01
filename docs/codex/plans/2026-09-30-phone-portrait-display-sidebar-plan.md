# 手机竖屏显示、画面横向缩小与会话侧栏联动实施计划

状态：IMPLEMENTED_PENDING_PHONE_DEVICE_VALIDATION
创建时间：2026-09-30 Asia/Shanghai
范围：手机本地窗口的竖屏显示、远端横向画面的等比缩小、显示与缩放设置、RDP/RustDesk/VNC/Moonlight 侧栏联动。
实现状态：核心实现已落地；真实手机方向、触控、侧栏拖动和多协议会话验收仍待设备矩阵执行。
实现提交：05d754e46（feat(ui): add phone portrait display and sidebar toggle）。
观察基线：codex/pro-purchase-foundation @ c8dcfdb36；本轮继续现有活动分支，保护共享工作区中的 Pro 并发改动，不创建新分支。

## 1. 目标和最终交互契约

### 1.1 用户可见行为

1. 手机进入指定协议会话后，可以锁定本机窗口为竖屏。
2. 远端通常是横向桌面时，画面在竖屏可视区域内按比例缩小并居中显示。允许出现上下留白，但不得拉伸、裁剪或把横向画面旋转成变形的竖向画面。
3. 在 设置 → 显示与交互 中，紧跟“双指缩放”下面增加“竖屏显示”设置项。副标题直接说明：竖屏会把远端横屏画面缩小完整显示，建议同时打开双指缩放。
4. “竖屏显示”打开协议选择页，只列出 RDP、RustDesk、VNC、Moonlight。SSH 不进入这个设置，也不进入新的侧栏功能；页面明确说明 SSH 使用自己的“切换横竖屏”。
5. 用户勾选某个协议后，该协议会话的既有工具栏/侧栏自动出现“翻转”入口。入口的实际语义是切换本机窗口的“竖屏显示”和“协议默认方向”，不是把远端内容做 180 度翻转。
6. 设置页和侧栏共享同一份偏好及版本号：
   - 设置页修改协议是否启用，立即改变侧栏入口是否出现。
   - 设置页或侧栏修改当前模式，活动会话立即应用；另一处在下一帧读到同一状态。
   - 侧栏入口在关闭竖屏功能后立即消失，活动会话恢复协议原有方向策略。
7. 竖屏侧栏默认使用手机右侧安全区域内的纵向 rail；用户可以拖动或切换左右位置。位置、展开/收起状态按协议和竖屏状态分别保存，并避让刘海、系统栏、输入法和其他面板。

### 1.2 状态分层

避免把“是否提供功能”和“当前是否竖屏”混成一个开关：

- enabled：协议是否启用本功能，决定设置摘要和侧栏入口是否存在。
- mode：协议当前模式，取 default 或 portrait。default 交给现有协议方向策略；portrait 请求本机竖屏。
- enabled=true、mode=default 时只显示侧栏入口，不改变现有连接方向；用户可在设置页或侧栏主动切到 portrait。
- enabled=false 时，活动会话必须回到 default；mode 可保留为用户最后选择，但运行时不得读取它。为避免隐藏状态造成意外旋转，重新启用时先以 default 起步，是否保留上次 mode 需在实现评审中确认，首版建议重置为 default。

## 2. 当前代码证据和复用边界

| 现状 | 代码入口 | 对计划的影响 |
|---|---|---|
| HostListPage 已有“显示与交互”分组和“双指缩放”行 | entry/src/main/ets/pages/HostListPage.ets | 直接在双指缩放行后插入“竖屏显示”行，沿用单 bindSheet 路由 |
| 双指缩放已按 RDP、RustDesk、SSH、VNC、Moonlight 拆分保存 | RemotePinchZoomPreferencePolicy.ets、RemotePinchZoomSettingsSheet.ets | 竖屏显示另建四协议策略；不把 SSH 加入新策略 |
| RDP、RustDesk、VNC 连接成功时已有方向策略和异步 generation fence | RemoteDesktop.ets 的 setPreferredOrientation、applyRdpOrientationPolicy、applyRustDeskOrientationPolicy | 复用请求串行化、代际检查和清理，不再散落新增 orientation writer |
| VNC 当前默认方向走 AUTO_ROTATION_LANDSCAPE；RDP/RustDesk 手机也保持横向优先 | RemoteDesktop.ets | portrait 模式只在 enabled 且 mode=portrait 时覆盖本机窗口；default 必须回到原策略 |
| Moonlight 手机流媒体当前横屏优先，控制栏是右边缘 rail | MoonlightStreamPage.ets、MoonlightUiPolicy.ets | 新增本机竖屏模式和等比 fit；不改 Sunshine、解码器或远端输入协议 |
| 画布已具备 containScale、rotation、pan、strictContentBounds、rebase | RemoteCanvasTransformPolicy.ets | 以现有 transform 为唯一几何来源，补充竖屏 fit 的测试和必要的纯策略辅助 |
| 侧栏已有通用安全区/占位/拖动策略，VNC 另有按 phone/pad 和 portrait/landscape 的位置键 | RemoteOverlayViewportPolicy.ets、RemoteSessionSidebarLayoutPolicy.ets、VncSessionUiPolicy.ets | 复用 placement 算法；新增 protocol 作用域，避免各协议各写一套避让逻辑 |
| RustDesk 已有“控制手机”的自适应翻转和 PC 桌面画面翻转 | RustDeskAddFlow.ets、RemoteDesktop.ets、RemoteHost.ets | 明确分离：新功能只控制本机手机窗口；不修改远端手机方向、不复用 PC flip mode |
| SSH 已有自己的“切换横竖屏” | SshTerminal.ets、SshTerminalOrientationPolicy.ets | 新设置、运行时控制器、侧栏 action、偏好键均不得读取 SSH |

## 3. 范围、非目标和默认决策

### 3.1 纳入范围

- 手机设备的本机窗口竖屏模式。
- RDP、RustDesk、VNC、Moonlight 的协议级选择。
- 远端横向画面在竖屏 viewport 中的等比缩小、居中、留白和双指放大后的受限平移。
- 设置行、协议选择页、保存/取消/失败回滚、版本迁移和实时同步。
- RDP/RustDesk 顶部工具栏或手机 edge rail、VNC toolbar、Moonlight toolbar 的条件 action。
- 竖屏时侧栏位置、展开状态、安全区、输入法和其他面板的布局。
- 前台/后台、重连、断开、画中画、独立会话窗口和窗口 resize 的清理与重应用。
- Phone 真机验收，以及 Pad/PC 的无回归验证。

### 3.2 明确不做

- SSH/SFTP 的新竖屏开关或新侧栏入口；保留现有 SSH 手动旋转。
- RustDesk 被控手机的方向命令和既有自适应翻转语义。
- 已有 PC 端 RustDesk/Moonlight 画面上下/左右翻转功能的替换。
- 远端视频内容的 90 度或 180 度旋转；本计划的“翻转”只表示本机窗口方向切换。
- 修改 RDP、RustDesk、VNC、Moonlight 的协议栈、解码器、Sunshine 或 native FFI。
- 把客户端留白误报成降低远端采集、编码或网络流量。
- 修改 Pad/PC 的产品方向策略；这些设备只做回归保护。

默认选择：

- 新安装和缺少新键的升级安装：四个协议 enabled=false、mode=default，保持当前产品行为。
- 用户第一次开启某协议只增加侧栏能力，不自动锁定窗口，避免设置保存后突然旋转；用户再选择“竖屏”才立即生效。
- 偏好是设备本地显示偏好，不进入主机 JSON、云同步或备份；若现有 owner/account scope 已包住应用偏好，则沿用其隔离边界。
- 新功能只在 phone 设备生效。设置行可以在其他设备显示并注明“仅手机会话生效”，但 Pad/PC 不请求 PORTRAIT。

## 4. 偏好、同步和生命周期设计

### 4.1 新数据模型

新增纯策略 RemotePortraitDisplayPreferencePolicy.ets：

- RemotePortraitProtocol：rdp、rustdesk、vnc、moonlight。
- RemotePortraitDisplayMode：default、portrait。
- RemotePortraitDisplayPreferences：四个协议各自的 enabled 和 mode。
- 版本键：remotePortraitDisplayPreferenceVersion。
- 每协议键建议采用显式名称：
  - rdpPortraitDisplayEnabled / rdpPortraitDisplayMode
  - rustdeskPortraitDisplayEnabled / rustdeskPortraitDisplayMode
  - vncPortraitDisplayEnabled / vncPortraitDisplayMode
  - moonlightPortraitDisplayEnabled / moonlightPortraitDisplayMode
- 纯函数负责协议白名单、默认值、模式归一化、摘要、touched-field 合并、迁移和未知协议拒绝。SSH 不出现在类型和 key 映射中。

新增 RemotePortraitDisplayStore.ets：

- 复用 RemoteDesktopAppPrefs 的 Preferences 容器。
- 统一提供 load、savePatch、setProtocolEnabled、setProtocolMode、revision 发布和失败回滚。
- 所有写入成功后再更新内存/AppStorage；部分写失败时恢复已经写入的键和内存快照。
- HostListPage、RemoteDesktop、MoonlightStreamPage 和侧栏组件只通过此 store 修改，不各自写 Preferences。
- revision 递增，设置页和活动会话用 StorageLink/订阅消费同一 revision，避免旧 Sheet 草稿覆盖侧栏刚刚提交的值。
- 账号/owner 切换、退出登录、冷启动时先重新加载 owner 对应快照；旧 owner 的 mode、侧栏位置和活动会话状态不得串入新 owner。

### 4.2 迁移和失效规则

- 版本缺失或低于当前版本时写入四协议默认值；不从现有 RustDesk adaptive、PC flip、SSH orientation 推断新值。
- 非法 mode、非白名单协议、超长字符串和损坏的偏好按 default/false 修复。
- disabled 协议的活动会话收到 revision 后立即结束竖屏显示手势、恢复 default，并隐藏入口。
- 方向请求、页面切换、断线、PIP、窗口销毁的异步回调必须携带 session generation、preference revision 和 orientation request generation；旧回调不能覆盖新会话。
- 清理阶段沿用现有 UNSPECIFIED/协议默认清理路径，不把本次 PORTRAIT 请求遗留到主机列表或下一个协议。

## 5. 设置界面计划

### 5.1 HostListPage 入口

修改 entry/src/main/ets/pages/HostListPage.ets：

1. 在显示与交互分组中，紧跟 remotePinchZoomRow() 后新增 remotePortraitDisplayRow()。
2. 行标题为“竖屏显示”；副标题动态显示“未选择协议”或“已开启：RDP、VNC”等，并补充“竖屏时建议打开双指缩放”。
3. 点击整行或“选择协议”按钮进入新叶 Sheet；沿用 settingsLeafSheetMode、单 bindSheet、dismiss generation 和 keyboard avoid 流程。
4. 新增 StorageLink/Store 快照，不复制一套不会更新的本地变量。
5. 不把该行塞进 RustDesk 主机编辑或 SSH 设置页，避免与既有协议专属旋转混淆。

### 5.2 RemotePortraitDisplaySettingsSheet

新增 entry/src/main/ets/components/RemotePortraitDisplaySettingsSheet.ets：

- 四个协议行：RDP、RustDesk、VNC、Moonlight。
- 每行包含“启用竖屏显示”开关；启用后显示“默认方向 / 竖屏”二段选择，方便用户从设置直接改变活动会话模式。
- SSH 不显示为可选协议；底部说明“SSH 使用终端内的切换横竖屏”。
- 顶部提示：横屏远端画面会等比缩小到竖屏区域；竖屏使用时建议同时开启双指缩放。
- 保存使用 touched-field patch，合并 Sheet 打开期间其他入口的修改；保存失败保留 Sheet 和原值并显示错误。
- 取消不写入任何 enabled、mode 或 revision。
- 设置页显示每协议的当前模式摘要；活动会话的侧栏状态更新后，重新打开 Sheet 必须读到新值。
- 不提供“全部开启”作为默认动作；如保留批量按钮，必须只作用于四个协议且保存前显示实际变更。

### 5.3 路由和高度

修改 entry/src/main/ets/services/SettingsSheetRoutePolicy.ets：

- 增加 SETTINGS_SHEET_REMOTE_PORTRAIT_DISPLAY 常量、路由识别和手机/Pad/PC 高度策略。
- 选择页内容可滚动，固定头部和底部按钮，键盘弹出时不遮挡最后一行。
- 修改 HostListPage 的 settingsLeafSheetHeight() 与 settingsLeafSheet() 分支。
- RemotePinchZoomSettingsSheet 保持 SSH 的字号缩放设置；新 Sheet 不改变它的协议集合。

## 6. 运行时方向和画布计划

### 6.1 统一本机方向控制

修改 entry/src/main/ets/pages/RemoteDesktop.ets 和 entry/src/main/ets/pages/MoonlightStreamPage.ets：

1. 连接前、连接成功、页面 appear、前台恢复、PIP 进出、窗口 resize、重连和断开都调用同一 policy，输入当前协议、设备类型、enabled、mode、session generation 和 preference revision。
2. phone + enabled + portrait 时请求 window.Orientation.PORTRAIT。
3. 其他情况调用原有 RDP/RustDesk/VNC/Moonlight default orientation policy；不直接写一个新的横屏常量覆盖旧行为。
4. 方向切换前释放远端按键、鼠标按钮、触摸序列、双指所有权和待处理 pointer；切换完成并观察到新 viewport 后再恢复输入。
5. 方向切换必须等待 window/XComponent 的新宽高和 safe-area generation，再重算画布、光标、绝对坐标和侧栏 placement；旧尺寸事件不得覆盖新尺寸。
6. 断开、返回、后台销毁和 PIP 不可见时恢复既有清理方向；新功能不得改变 SSH 的 orientation owner。

RustDesk 特别规则：

- 新的 local portrait mode 只控制当前 HarmonyOS 查看器窗口。
- rustdeskAdaptiveOrientation 仍只代表“控制手机”语义。
- rustdeskDesktopFlipMode 仍只代表 PC 查看器的内容/控制层翻转。
- 三者在诊断和 UI 文案中分开命名；不能用一个 boolean 互相覆盖。

### 6.2 竖屏画面 fit/缩放

优先复用 RemoteCanvasTransformPolicy.ets：

- portrait viewport 使用 sourceWidth/sourceHeight 的 contain scale，rotation 默认 0，pan 默认 0，strictContentBounds=true。
- 远端 16:9、16:10、4:3、超宽和本身竖向的码流都使用同一 contain 公式，保持像素比例。
- 远端尺寸或窗口尺寸变化时 rebase 到新 viewport；若旧 transform 越界则回到合法 fit，不使用旧的黑边 pan。
- 双指缩放开启时，继续使用现有 per-protocol pinch gate；捏合以当前焦点为锚，放大后允许受限平移。关闭双指缩放不应破坏基础 fit，也不应吞掉既有协议的滚轮/右键语义。
- 画布、远端光标覆盖层、触摸/鼠标坐标映射和 Moonlight 的 absolute geometry 必须消费同一个 transform 和 viewport generation。
- 不在渲染器或协议层新增一套缩放矩阵；只有在现有策略缺少严格 contain/letterbox 辅助时才扩展纯策略。

### 6.3 各协议接线

RDP：

- 在 RemoteDesktop 的 RDP orientation policy 和 RDP toolbar/control center action 中接入 enabled/mode。
- 手机竖屏时保留 RDP 远端分辨率和输入映射语义；只改变本机 viewport 和缩放。
- RDP control center 的“翻转” action 与顶栏入口共用同一个 toggle，不产生两个状态。

RustDesk：

- 在 RemoteSessionTopBar 及 phone rail 中增加条件 action。
- 本地画布 fit 与 RustDesk 远端 App TouchScale 继续互斥；新竖屏模式不能偷偷开启远端 TouchScale。
- 桌面 peer、手机 peer、显示器切换、重连和 PIP 均验证 local portrait 与 peer orientation 独立。

VNC：

- 在 VncSessionToolbar/VncSessionUiPolicy 中增加 portrait action，沿用 VNC 当前 view-only、toolbar orientation 和 input release 规则。
- 单一 VNC framebuffer 在 portrait viewport 中等比缩小；不把它表述为服务端裁剪或带宽优化。
- toolbar 的新 action、已有 displayScale、keyboard、controlMode、diagnostics、disconnect 顺序在 Phone/Pad/PC 之间保持可解释。

Moonlight：

- MoonlightStreamPage 引入相同 preference revision、orientation policy 和 CanvasTransform fit。
- 码流仍由 common-c/Sunshine 提供；只改变本机显示窗口和本地 viewport，保留现有右侧控制 rail、滚轮、右键和 PIP 语义。
- 竖屏时确保画面 fit 与工具栏可达；码流光标和本地预测光标共用 geometry，不绘制第二个虚假光标。

## 7. 竖屏侧栏、位置和显示规则

### 7.1 action 规则

新增纯策略 RemotePortraitSidebarPolicy.ets，或扩展 RemoteSessionSidebarLayoutPolicy.ets：

- supportedProtocol 只接受 rdp、rustdesk、vnc、moonlight。
- shouldShowPortraitAction = connected && phone && enabled[currentProtocol]。
- action 文案随 mode 变化：default 状态显示“竖屏显示”，portrait 状态显示“恢复默认方向”；辅助说明可保留“翻转”二字，但不得暗示 180 度内容旋转。
- side rail、top bar、control center 和 VNC/Moonlight toolbar 都调用同一个 action id 和 toggle 回调。
- SSH、SFTP、Remote AI、未连接会话和 Pad/PC 会话不显示此 action；PC 已有的既有 flip action 不受影响。

### 7.2 portrait rail 布局

复用 RemoteOverlayViewportPolicy.ets 的 placement、cutout、keyboard 和 occupiedRects 算法，并补充：

- 竖屏默认 rail：右侧，宽度和折叠 handle 不遮挡远端画面主要可视区；打开菜单后优先向左展开，空间不足时折叠或转为 bottom sheet。
- 位置偏好键按 protocol、deviceClass、orientation、mode scope 区分，例如 portrait-rail-rdp-phone-portrait-side 和对应 yRatio；实际 key 必须统一由纯策略生成，不能在组件中手拼。
- 用户拖动后保存 side、yRatio 和 collapsed；窗口 resize、safe-area 变化、输入法出现、刘海/导航栏变化后重新夹紧到可达区域。
- 横屏和竖屏使用不同位置 scope；从竖屏返回 default 时不覆盖用户的横屏位置。
- 远端画布、键盘、修饰键、快捷键、诊断面板和断开入口被视为 occupiedRects；找不到合法位置时至少保留可达的折叠 handle，不能完全失去控制入口。
- mode 或 enabled 改变时，侧栏 visibility、placement generation 和 action list 原子更新，避免“入口已消失但旧面板仍可点”。

### 7.3 具体组件

- RemoteSessionTopBar.ets：为 RDP/RustDesk 手机会话增加 action 属性和模式状态。
- VncSessionToolbar.ets、VncSessionUiPolicy.ets：增加 action、portrait 高度和位置 scope。
- MoonlightSessionToolbar.ets、MoonlightUiPolicy.ets：增加 action、portrait 可达性和 PIP/键盘避让。
- RdpControlCenter.ets：把 action 作为同一会话控制中心的即时切换，不复制持久化。
- RemoteOverlayViewportPolicy.ets、RemoteSessionSidebarLayoutPolicy.ets：统一安全区、placement、drag 和 generation 计算。
- 现有 PC 顶栏只在有 phone edge rail 的场景复用 action；不得把手机 portrait action 添加到 PC 专属 flip 菜单。

## 8. 分阶段实施

### P0：冻结契约和验证样本

- 确认“翻转”最终文案表示本机 portrait/default，不表示内容 180 度旋转。
- 固定 phone 设备判定、Pad/PC 回归边界和 default orientation 回退表。
- 准备 16:9、16:10、4:3、超宽、远端竖向分辨率及窗口 resize 样本。
- 明确 enabled 与 mode 的保存、禁用时回退和首次开启不自动旋转规则。

出口：策略接口、键名、默认值、生命周期 owner 和验收样本经评审确认。

### P1：偏好、迁移和设置

- 新增 RemotePortraitDisplayPreferencePolicy.ets、RemotePortraitDisplayStore.ets。
- 在 HostListPage 增加 StorageLink、初始化、迁移、保存回滚和新设置行。
- 新增 RemotePortraitDisplaySettingsSheet.ets 和 SettingsSheetRoutePolicy 路由。
- 加入四协议选择、mode 选择、SSH 说明、双指缩放建议、取消/保存和 touched merge。
- 完成 store/revision/owner 切换测试。

出口：冷启动、升级、杀进程重启、保存失败和两个入口同时修改时状态稳定。

### P2：RemoteDesktop 本机 portrait 和 fit

- 在 RemoteDesktop 中接入统一 policy、PORTRAIT/default 请求、generation fence 和 cleanup。
- 接入 RDP、RustDesk、VNC 的 viewport fit、transform rebase、输入释放和恢复。
- 仅在当前协议 enabled 时插入侧栏 action。
- 完成画布数学、窗口 resize、断线、PIP、后台恢复和 per-protocol isolation 测试。

出口：三种协议在 phone 模拟的 portrait viewport 中无拉伸/裁剪，输入坐标与画面一致。

### P3：Moonlight

- 接入 MoonlightStreamPage 的 preference revision、portrait/default orientation 和 fit transform。
- 处理 common-c surface、码流分辨率变化、PIP、键盘和控制 rail。
- 保持滚轮、右键、码流光标和既有 PC flip 行为。
- 完成 Moonlight 专用单元/集成测试。

出口：Moonlight 竖屏画面可完整显示，控制入口和退出路径始终可达。

### P4：侧栏布局和联动

- 实现共享 action id/toggle、竖屏 rail 默认位置、拖动保存、safe-area/keyboard/cutout 避让。
- 让设置 enabled/mode、活动会话、侧栏入口和摘要消费同一 revision。
- 验证 orientation transition 中旧 rail、旧菜单和旧 hit-test owner 全部失效。
- 验证 RDP/RustDesk/VNC/Moonlight 各自的位置 scope 不互相覆盖。

出口：设置页、侧栏、实时方向和位置保存能够双向观察到同一状态。

### P5：构建、代码复核和设备验收

- 先跑纯策略/ArkTS 定向测试、静态审计和双指缩放回归。
- 执行仓库强制 Hvigor 门禁、diff 检查和 Light 合规。
- 使用与最终 commit 对应的新 HAP 按设备矩阵顺序安装；每次切换协议或 HAP 前清理上一轮进程。
- 记录实际设备、commit、HAP 哈希、日志、截图和结果，不用编译或模拟器结果代替手机验收。

## 9. 计划修改文件

| 层级 | 文件 | 计划变化 |
|---|---|---|
| 偏好模型 | entry/src/main/ets/services/RemotePortraitDisplayPreferencePolicy.ets（新增） | 四协议类型、enabled/mode、版本、默认值、迁移、摘要、touched merge |
| 偏好存储 | entry/src/main/ets/services/RemotePortraitDisplayStore.ets（新增） | Preferences 原子写、回滚、revision、owner 隔离、AppStorage 发布 |
| 设置入口 | entry/src/main/ets/pages/HostListPage.ets | 新行、StorageLink、初始化、保存、设置 Sheet 路由接线 |
| 设置 Sheet | entry/src/main/ets/components/RemotePortraitDisplaySettingsSheet.ets（新增） | 四协议选择、模式选择、SSH 说明、双指缩放建议 |
| Sheet 路由 | entry/src/main/ets/services/SettingsSheetRoutePolicy.ets | 新 mode、高度、底部 Sheet/滚动策略 |
| 方向/会话 | entry/src/main/ets/pages/RemoteDesktop.ets | RDP/RustDesk/VNC 方向、revision、fit、输入释放、侧栏 action、cleanup |
| Moonlight | entry/src/main/ets/pages/MoonlightStreamPage.ets | 本机 portrait、fit、码流 geometry、侧栏 action、PIP/重连 |
| 画布几何 | entry/src/main/ets/services/RemoteCanvasTransformPolicy.ets | 必要时补 portrait contain/strict-bound 辅助；保持唯一数学来源 |
| 侧栏布局 | entry/src/main/ets/services/RemotePortraitSidebarPolicy.ets（新增）或 RemoteSessionSidebarLayoutPolicy.ets、RemoteOverlayViewportPolicy.ets | action 白名单、portrait rail 指标、protocol scope、位置键、避让和 fallback |
| RDP/RustDesk UI | entry/src/main/ets/components/RemoteSessionTopBar.ets、entry/src/main/ets/components/rdp/RdpControlCenter.ets | 条件 action、模式状态、统一 toggle |
| VNC UI | entry/src/main/ets/components/VncSessionToolbar.ets、entry/src/main/ets/services/VncSessionUiPolicy.ets | action 集合、portrait 高度、位置/可达性和 view-only 兼容 |
| Moonlight UI | entry/src/main/ets/components/moonlight/MoonlightSessionToolbar.ets、entry/src/main/ets/services/MoonlightUiPolicy.ets | action、portrait rail、键盘/PIP 避让 |
| 测试 | entry/src/ohosTest/ets/test/RemotePortraitDisplayPreferencePolicy.test.ets（新增）、RemotePortraitDisplayPolicy.test.ets（新增）、RemotePortraitSidebarPolicy.test.ets（新增）、RemoteCanvasTransformPolicy.test.ets、VncSessionGeometryPolicy.test.ets、MoonlightSunshineInteropIntegration.test.ets | 迁移、模式同步、画布数学、布局、生命周期和协议回归 |
| 源码契约测试 | scripts/tests/test_phone_portrait_display.cjs（新增，必要时） | 检查 SSH 排除、统一 action、RustDesk peer/local 分离和页面接线 |

除非实现期发现 renderer viewport 缺少必要代际信息，否则不修改 C++、Rust、FFI、协议 protobuf、第三方依赖、SBOM 或 NOTICE。

## 10. 测试与验收标准

### 10.1 偏好和设置

- 新安装默认四协议关闭、default 模式；旧安装迁移后现有方向行为不变。
- 逐个开启/关闭 RDP、RustDesk、VNC、Moonlight，只改变对应协议。
- Sheet 取消不保存；保存失败恢复 Preferences 和 AppStorage；旧草稿不会覆盖别的入口刚写入的协议。
- 杀进程、冷启动、owner/account 切换后值不串；不出现 SSH 新 key。
- 设置页明确给出“双指缩放建议”，协议选择页只包含四项，SSH 说明准确。

### 10.2 画面、缩放和输入

每个协议至少验证：

- 远端 16:9、16:10、4:3、超宽和竖向源在手机 portrait viewport 中等比缩小并居中。
- 画面不拉伸、不裁剪；fit 状态 pan 为零或严格合法，双指放大后 pan 不越界、不制造不可恢复黑边。
- 双指缩放开关开启/关闭时，既有滚轮、右键和协议手势语义不误切；关闭后不残留放大手势或按键。
- 点击、拖动、虚拟触控板、实体鼠标和远端光标使用同一 transform；viewport generation 变化后旧绝对坐标被拒绝或重算。
- 快速方向切换、窗口 resize、首帧前后、重连、后台/前台、PIP、断线和返回都没有旧帧、旧输入或旧 overlay 穿透。

协议专项：

- RDP：默认动态布局/分辨率策略未被 portrait 覆盖，恢复 default 后回到原横向策略。
- RustDesk：桌面 peer、手机 peer、远端 App TouchScale、既有 phone adaptive 和本机 portrait 相互独立。
- VNC：view-only、单 framebuffer、toolbar 既有动作和缩放模式不回归。
- Moonlight：common-c 码流、码流分辨率变化、滚轮/右键、码流光标/本地光标、PIP 不回归。
- SSH：原有终端内切换横竖屏仍有效；不出现新设置项、新侧栏项或 portrait store 读写。

### 10.3 侧栏

- enabled=false 时没有新入口；enabled=true 时连接后自动出现。
- default/portrait 切换从设置和侧栏都能即时生效，另一处读到同一模式和文案。
- Phone portrait 下 rail 位于安全区域，展开菜单不遮挡键盘、断开和主要控制；空间不足时按 fallback 收起或 bottom sheet。
- 拖动后的 side、yRatio、collapsed 在同一协议的下次 portrait 会话恢复；RDP/RustDesk/VNC/Moonlight 和横屏位置互不覆盖。
- 刘海、系统栏、键盘、分屏/窗口 resize、旋转过渡和面板打开关闭后始终至少保留一个可达 handle。
- 同一 action 不在 top bar、control center、toolbar 重复触发两次；SSH 没有新 action。

### 10.4 手机设备矩阵

在 API 26 基线的实际手机上，用匹配本次 commit 的新 HAP 顺序验证：

1. RDP：横向 Windows 桌面，portrait fit、pinch、侧栏 toggle、恢复 default。
2. RustDesk：桌面 peer 和控制手机 peer，各自验证本机 portrait 与既有 peer adaptive。
3. VNC：4:3 或 16:9 framebuffer、view-only 和输入法展开。
4. Moonlight：码流分辨率变化、PIP/恢复、右侧 rail。
5. 设置迁移、杀进程重启、owner/account 切换和侧栏位置恢复。

Pad/PC 只需证明新入口不改变既有方向和 PC flip；不能把 Pad/PC 结果写成手机竖屏通过。

## 11. 强制验证和交付门禁

实现阶段必须顺序执行并记录准确退出码、时间、commit、HAP 路径和哈希：

    source scripts/macos_env.sh
    hvigorw --mode module -p module=entry -p product=default default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon
    hvigorw --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --no-daemon

若改动 ohosTest，再加：

    hvigorw --mode module -p module=entry -p product=default ohosTest@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon

同时执行：

- 受影响的定向策略和 UI wiring 测试。
- git diff --check。
- scripts/verify_open_source_release.ps1 -Mode Light -RepositoryRoot .。
- 设备验收只使用实际安装并确认来源的 HAP；编译成功、监听器、模拟器或已有日志不能代替真实手机证据。
- 本功能未涉及 native/依赖/签名时，不增加 ABI、供应链或 release 级门禁；若实现期跨入这些范围，按 AGENTS.md 补充 clean clone、双 ABI 和发布证据。

本计划已进入实现增量；不声称任何手机、网络、支付或生产验收已通过。实现和提交继续沿用当前 Pro 活动任务分支，遵守“一次只保留一个日常 codex 分支”。

## 12. 风险、决策点和停止条件

1. “翻转”若最终要求远端内容 180 度或 90 度旋转，需另开 canvasRotation 需求；本计划不会把本机 PORTRAIT 与内容旋转混用。
2. 若某协议的 renderer 不接受 portrait viewport，先修复 viewport/geometry generation；不要在协议层硬编码拉伸或裁剪。
3. 若系统方向锁、PIP 或独立窗口拒绝 PORTRAIT，诊断中记录请求/应用/失败原因，界面回退到 default 并保留可达侧栏；不得把请求成功当作设备方向已改变。
4. 若设置页和活动会话的 owner/revision 不一致，停止保存并提示重新加载，禁止用旧草稿覆盖新状态。
5. 若侧栏没有合法安全位置，保留折叠 handle 或 bottom sheet；不能把 action 隐藏后宣称功能可用。
6. 若实际产品需要服务端缩放、带宽优化、远端手机旋转或 SSH 统一旋转，另立计划，不扩大本次实现范围。

## 13. 完成定义

- 计划中的偏好、设置、运行时方向、画布 fit、侧栏布局、同步、测试和设备证据全部有对应实现或明确的阻塞记录。
- 四个协议在手机 portrait 下均能完整、等比、可交互地显示横向远端画面；SSH 行为保持原样。
- 设置和侧栏的 enabled/mode/visibility/position 由同一 store 和 revision 驱动。
- 强制 Hvigor、定向测试、Light 合规和实际手机矩阵全部有本次变更对应的证据。
- 代码复核通过后才进入 push/PR/required check/merge；未完成时留在当前活动任务，不用旧日志替代本次证据。

## 14. 本轮落地记录（2026-10-01）

已完成：

- 新增 `RemotePortraitDisplayPreferencePolicy`、`RemotePortraitDisplayStore` 和 `RemotePortraitSidebarPolicy`；四协议使用独立 `enabled/mode`、版本号和 revision，SSH 不进入白名单，写入失败会回滚。
- HostListPage 在“双指缩放”后新增“竖屏显示”入口和四协议设置 Sheet；保存/取消、touched-field 合并、迁移默认值、本机偏好同步和“双指缩放”建议已接线。
- RemoteDesktop 接入 RDP、RustDesk、VNC 的本机 `PORTRAIT/default` 方向策略、统一 revision 观察、画布手势释放、竖屏 fit 的严格 RDP pan 边界和现有默认方向回退。
- RDP、RustDesk、VNC、Moonlight 工具栏在手机且协议已启用时出现同一语义的“竖屏显示/恢复横屏”入口；Moonlight 页面也接入方向、fit 和 revision 生命周期。Pad/PC 与 SSH 保持原行为。
- 新增偏好和侧栏策略测试，并注册到 `entry/src/test/List.test.ets`；新键已加入设备本地设置名单，避免云同步。

本轮验证：

- `default@OhosTestCompileArkTS`：通过，exit 0。
- `assembleHap`：通过，exit 0；签名产物为 `entry/build/default/outputs/default/entry-default-signed.hap`，SHA-256 `9265e26c9a366461f59aeb15880d314042ddd9c3d8d3c9717eba08a83b2161b2`。
- `git diff --check`：通过；纯源码 wiring 检查通过；Light 合规门 `scripts/verify_open_source_release.ps1 -Mode Light`：通过。
- `ohosTest@OhosTestCompileArkTS`：当前工程任务未注册，返回 `00306054 task not found`，不记为测试通过；Smoke 脚本的额外 pre-push 临时 commit 检查受沙箱禁止临时文件影响，独立 Light 门本身已通过。

未完成/边界：

- 尚未在真实手机上安装本轮 HAP，未取得四协议的实际方向、画面比例、触控坐标、侧栏拖动/安全区和重连/PIP 证据；不能把编译或 HAP 打包当作手机验收。
- 当前分支仍有并发 Pro 任务和未提交改动；提交、独立复核、PR、required check 和 merge 需按现有活动任务流程继续执行。

## 15. 后续增量：可调竖屏侧栏和点击唤起软键盘（2026-10-01）

实现提交：本次功能已独立提交，最终提交哈希以当前分支 `git log -1` 为准。

### 15.1 已实现的交互

- `RemotePortraitSidebarPolicy` 新增 `auto/compact/standard/tall` 四档高度模式。设置页在四协议选择卡片下方显示“竖屏侧栏高度”，模式保存在设备本地 Preferences，并通过 `remotePortraitDisplayRevision` 发布给活动会话。
- RDP、RustDesk、VNC、Moonlight 的手机竖屏侧栏消费同一高度策略：自动保持内容所需高度，紧凑/标准/高分别限制为安全区域的 45%/65%/85%，始终保留至少 68vp 或当前可用高度。键盘、系统栏、safe-area 和窗口 resize 仍由现有 placement 计算处理。
- HostListPage 摘要显示当前侧栏高度，设置保存与取消不改变旧草稿；高度键列入设备本地设置名单，不进入云同步。侧栏 action 和设置页继续共享协议 enabled/mode/revision。
- “键盘 → 输入行为”新增“点击远端输入框自动弹起键盘”开关，默认关闭。RDP、RustDesk、VNC、Moonlight 在单指/左键点击完成后延迟唤起虚拟键盘；拖动、多指、右键、view-only 和实体键盘代理路径不会唤起。该实现使用远端单击作为输入框候选，因为通用协议没有可依赖的控件语义回调。
- 横屏唤起时临时使用 `KeyboardAvoidMode.NONE`，让软键盘覆盖页面形成悬浮式显示；竖屏使用 `KeyboardAvoidMode.RESIZE`，让页面按正常键盘避让。键盘关闭、断开、后台和窗口切换时恢复原页面避让模式。

### 15.2 本轮验证

- `default@OhosTestCompileArkTS`：通过，exit 0，2026-10-01；编译包含键盘、Moonlight、RemoteDesktop、HostListPage 和策略测试 wiring。
- `assembleHap`：通过，exit 0，2026-10-01；签名产物为 `entry/build/default/outputs/default/entry-default-signed.hap`，SHA-256 `d281f219a9a29a65b5c472a0ebe07575dee0f58b0e19e86fdf33766840a43bc2`。
- `git diff --check`：通过。
- `scripts/verify_open_source_release.ps1 -Mode Light`：通过。
- 新增侧栏高度边界断言和键盘开关默认值/归一化断言，已注册在既有 ArkTS test list；独立 ohosTest 任务仍未注册，沿用 `00306054 task not found` 边界，不记为通过。

### 15.3 仍需设备验收

- 尚未在真实手机上安装匹配本轮 HAP，因此未证明横屏悬浮式/竖屏正常键盘的系统 IME 实际外观、输入框焦点命中、侧栏高度触控可达性、四协议方向切换、重连和 PIP 行为。
- “远端点击输入框”当前采用单击候选策略；若某协议能提供稳定的远端文本光标/控件焦点事件，应在设备验收后将候选条件收紧为该协议证据，不能把当前 host-side build 证据写成控件级命中通过。
