# SSH Termius 化：HarmonyOS 7 / API 26 原生工作台完整实施计划

> 状态：`ACTIVE_M9` / `NON_API26_CLOSEOUT` / `API26_DEFERRED_BY_USER`
> 类型：SSH 工作台独立实施计划 / 不从属于全应用 UI 计划
> 编制日期：2026-08-19
> 编制基线：`348b28083`（`codex/moonlight-complete-upgrade`）
> 当前系统：HarmonyOS 6.1 / API 23；本机另有 DevEco 内置 API 24 SDK

> 执行指针（2026-08-20）：M0–M6 已在 SSH 范围内落地并通过双 Hvigor 门禁；M7 首个可运行增量已提交为 `66ded2ce6`（目标策略、红色广播 Sheet、16 会话上限、session/generation 重验、认证/raw/fullscreen 排除、危险/多行二次确认、Esc×2 停止及策略测试）；M8 已提交为 `7bb90ab6d`（版本化 WebMessagePort 信封、握手/generation/序列 ACK、优先级队列/背压策略）、`9d630d1a2`（结构化端口通道适配器及测试）、`4f5e9018`（SshXtermSurface/rawfile 的 API 23+ WebMessagePort 双栈接线、输出批次 ACK、输入/resize、生命周期与 generation 退回 JS proxy）、`eaf98531`（native/page JSON 类型白名单、超前 ACK 拒绝、UTF-8 字节队列预算与边界测试）、`4a2d10d9`（attach token/端口实例 fence，旧端口回调静默丢弃与重绑测试）及 `493601b1`（优先队列改为出队分配 wire sequence，控制帧优先但不再反转线上序号，ACK 不清理未发送帧）。共享 `RemoteSessionWindowCoordinator/RemoteSessionAbility` 已覆盖 SSH 的认证后窗口 handoff 入口，`e4b32688` 补齐了 SSH/RDP/RustDesk/VNC/Moonlight 的合法窗口 target/protocol 组合与跨协议拒绝测试；`41483b41` 收紧 SSH 多窗口交接为按 host 精确移除源标签，保留其余 SSH 标签并切换到下一个会话，避免交接一个主机时清空整个工作台；`2d1f06d6` 修复 PC SSH 主机添加 Sheet 的固定宽度溢出，实机模拟器布局树确认代理选项与下一步操作均未被截断；`d00511e55` 修复独立窗口内转发 Sheet 的输入焦点竞争；`60602d651` 将手机会话辅助操作收敛为官方 `bindPopup` 二级菜单，保留 Pad/PC 直接操作并完成 Phone HDC 连接、Host Key、公钥鉴权和语言弹层回归。API23 PC 模拟器已进一步验证：Host Key/ED25519 公钥鉴权成功后才创建独立窗口，终端回显、SFTP 实际传输、转发 payload、标题栏最大化、F11 沉浸全屏进出及左边缘 WMS 分屏均正常；API26/物理设备/剩余协议矩阵仍待验收。端口仍由 `webMessageBridgeEnabled=false` 默认关闭；当前使用白名单 JSON 字符串帧，ArrayBuffer 批量和默认放量等待 API 26 SDK/真机证据。API 26 SDK 仍未安装，因此 API 26-only UI Design Kit/Material 只能保持候选与兼容降级，不能宣称 API 26 完成。

> 执行指针（2026-08-24）：非 API26 SSH 工作台缺陷审计已完成。`150fcdf3b` 恢复升级前“ArkUI 隐藏输入锚点”为手机/Pad 唯一 IME 所有者，并覆盖 bar/block/underline/outline 光标闪烁；API24 手机端已完成连接后 `echo OK` 端到端回显、焦点保持和光标证据。`4c9a0809` 补齐手机/Pad 实体键盘模式下的显式终端手势静默聚焦，默认虚拟键盘与桌面路径保持不变；该增量独立复核为 P0/P1/P2/P3 零。两次增量均通过 `default@OhosTestCompileArkTS`、签名 `assembleHap`、Light 合规门，API24 PC/2in1 HDC 启动回归通过。API26 SDK/运行时及真实 Pad/实机验收按用户明确要求延期，不作为当前代码完成的宣称。
> 执行指针（2026-08-24 续）：移动端输入竞态与键盘默认值已按问题拆分提交：`82bf48390` 将升级缺失的 SSH 输入模式恢复为手机/Pad 虚拟键盘、桌面实体键鼠，并将隐藏 TextArea 固定为 `TextAreaType.NORMAL` + `AutoCapitalizationMode.NONE`；`bb78a0bc9` 停止已成功焦点请求的重复重试；`e7a692f29` 为实体键盘显式手势补齐 bounded retry；`2223c3815` 清理软件键盘 lease 的陈旧状态；`2f2ea27b3` 与 `0ee1abc7` 隔离旧 TextArea 的延迟 blur/editing 回调、重开请求窗口和浮动/分屏 IME 的 `AvoidArea.visible` 状态。最新增量均通过双 Hvigor 门禁和 Light 合规门，复用只读复核最终为 P0/P1/P2/P3 全零。系统 IME 的具体英文 subtype 仍由用户/系统设置控制，未引入受限的全局 IME 切换权限；SSH 本身关闭自动大写。真实手机/Pad运行验收与 API26 按用户明确要求延期，当前不宣称其 runtime PASS。
> 目标系统：HarmonyOS 7 / API 26；官方当前公开资料为 26.0.0 Beta2，本机尚未安装 API 26 SDK
> 实施分支：`codex/moonlight-complete-upgrade`（SSH 变更按独立路径和提交隔离；不触碰现有 Moonlight/VNC 脏改）
> 范围：独立推进 SSH 终端工作台、SFTP 工作流、会话生产力与 HarmonyOS 7 / API 26 原生体验
> 不在范围：Moonlight、RDP、RustDesk、VNC，以及对现有 SSH 传输/密码学内核的无理由重写
> 平行计划：`docs/codex/plans/2026-08-19-harmonyos7-api26-app-wide-ui-upgrade-plan.md`（仅接口参考，不是实施前置）
> 交付隔离：独立分支、独立 feature flag、独立提交、独立审查、独立完成判定

## 0. 执行摘要

本计划把“SSH 终端 Termius 化”定义为：借鉴 Termius 的工作区、会话标签、分屏、快速跳转、Snippet、历史、SFTP、会话日志和多端生产力模型，以 HarmonyOS 7 / API 26 为目标重做鸿蒙原生交互层；不复制 Termius 的品牌、素材、文案或视觉 trade dress，也不推翻仓库中已经可用的 SSH/native/SFTP/转发底座。

API 23 只再承担“当前可运行基线”和迁移期间的回归参照，不再作为新工作台的长期设计上限。目标 UI 采用 HarmonyOS 7 全新空间化设计语言：沉浸光感材质、光随指动、光线勾勒、受控非线性形变、可变字体以及更强的多设备/PC 空间层级。终端字符区仍保持不透明、稳定、高对比；新材质和动态效果只服务于导航、侧栏、标签、浮层和操作反馈，不能牺牲终端可读性或输入延迟。

API 26 当前仍是 Beta 资料且本机 SDK 缺失，因此计划采用“双门禁”而不是猜 API：先完成 API 26 SDK/DevEco 升级和 release notes 冻结，再以实际 `.d.ts`、系统能力和 API 26 真机为依据确定最终 import、modifier 和降级方式。在此之前，`@kit.uiMaterial`、新 `hdsEffect/hdsMaterial` 能力、`ContainerReader`、`LazyDynamicLayout` 等都属于候选能力，不允许依据网页片段直接写进产品代码。

当前产品已经具备可工作的 SSH 会话、认证、Host Key 校验、终端渲染、SFTP、端口转发、代理/跳板、后台保活和多标签基础，但它仍更接近“功能集合页”，而不是可持续工作的“SSH 工作台”。核心差距有两类：

1. 功能层缺少可持久化工作区、可关闭/排序/分离的标签、分屏、命令面板、终端搜索入口、Snippet/历史/补全、会话日志书签、完成通知、全局传输中心和安全广播输入。
2. UI 层缺少针对手机、折叠屏、平板、PC 的明确响应式信息架构；主页面职责过重，HDS 导航/侧栏/材质/Symbol/键鼠/拖放/多窗口等 HarmonyOS 原生能力没有形成统一设计系统，也没有面向 HarmonyOS 7 沉浸光感和空间化交互建立明确边界。

目标不是一次性“大爆炸重写”。实施顺序是：先在当前可运行基线上冻结 SSH 非回归契约并抽出纯策略/兼容壳，同时独立推进 SSH 自己的 API 26 工具链证据；随后交付工作台 chrome、终端搜索、Profile、快捷键和标签等高收益能力，再引入 SFTP 标签、工作区分屏、Snippet/历史/日志，最后迁移 ArkWeb 高频通道并评估 PC 多窗口。API 26-only import 必须等待真实 SDK，但纯策略、实体、Controller 和当前 API 可表达的 UI 不等待全 App UI 计划。每个阶段必须可独立回滚，并保持当前 SSH 连接核心可用。

## 1. 计划权威性与关联文档

本文件是 SSH “工作区、生产力与 UI”方向的独立执行权威。它可以消费已经发布且稳定的全 App 接口，但不继承全应用 UI 计划的阶段、组件实现或完成状态。已有文档继续承担各自范围，不应被本计划重复实现：

- `docs/codex/plans/2026-08-19-harmonyos7-api26-app-wide-ui-upgrade-plan.md`：平行的全 APP UI 计划；只通过入口/返回、主题快照和脱敏任务状态接口协作。
- `docs/SSH_MODULE_UPGRADE_PLAN_V2.md`：SSH native、认证、会话、终端正确性和 SFTP 基础架构。
- `docs/superpowers/plans/2026-07-01-ssh-terminal-open-source-parity.md`：终端行为与开源终端能力对齐。
- `docs/codex/plans/2026-08-08-ssh-proxy-forwarding-sol-plan.md`：代理、跳板和端口转发。
- 本计划：在上述能力之上建设可持久化、可组合、可响应式布局的 SSH 原生工作台。

如发生冲突，按以下优先级处理：安全/协议正确性与现有 native 约束优先；SSH Workspace/Tab/Pane、终端、SFTP、视觉 token 和生产力实体采用本计划；跨模块接口采用双方已冻结的版本化 DTO；最后以项目 `AGENTS.md`、目标分支实际 API 26 SDK 声明、官方 release notes 和当前代码为准。API 26 SDK 尚未安装时，不得用网页示例替代 SDK 证据。

实施隔离规则：

- SSH 计划拥有 `SshTerminal`、SSH workspace 组件/服务、SSH rawfile、SSH 测试和 `sshWorkbenchV2`。
- 全 App UI 计划拥有 AppShell 和非 SSH 页面；SSH 不直接 import 对方尚未稳定的 primitives。
- `EntryAbility.ets`、module 配置等共享文件只有在 SSH 系统能力确有需要时做最小接口改动，并必须补非 SSH smoke。
- 不允许一个 commit/PR 同时包含 SSH 工作台实现和全 App UI 改版。
- 两条计划都完成后再开独立集成任务；集成失败不能迫使任一计划回滚内部实体或复制实现。

## 2. 现状基线与差距

### 2.1 已有能力，不重复造轮子

当前实现已经覆盖：

- SSH 密码、私钥、keyboard-interactive/MFA 等认证路径。
- 目标主机及逐跳 Host Key 预检。
- 主机级 locale/LANG 设置。
- ArkWeb + xterm.js 渲染，以及 native 终端渲染/解析路径。
- 物理键盘、输入法、虚拟功能键栏、选择/复制、鼠标跟踪、缩放字体、bracketed paste 防护。
- 页面内多标签、重连、keepalive、延迟状态、后台和 PiP 生命周期。
- 本地与远端、SSH 与 SSH 之间的 SFTP；目录、重命名、删除、新建、批量、暂停、恢复、重试、完整性和持久任务元数据。
- 本地/远端/动态端口转发、直连、HTTP/SOCKS5/FRP 端点，以及最多三跳 SSH jump host。
- 加密保存主机和 SSH Key 的云数据底座。

这些能力是新工作台的基础依赖。除非有单独的缺陷证据，不在本计划中重写连接协议、认证状态机、转发引擎或 SFTP 数据通道。

### 2.2 功能差距矩阵

| 领域 | 当前状态 | 目标状态 | 优先级 |
|---|---|---|---|
| 工作区 | 标签仅是页面内内存态 | 工作区可命名、持久布局、恢复为未连接占位、显式重连 | P0 |
| 标签管理 | 缺少完整关闭、排序、拖动、分离语义 | 可关闭、固定、排序、跨 Pane 移动，PC 可条件分离 | P0 |
| 多任务 | 单一主工作面 | 横/纵分屏、焦点模式、Pane 树持久化 | P1 |
| 快速操作 | 操作分散在按钮/Sheet | 命令面板、主机快速跳转、统一快捷键 | P0 |
| 终端搜索 | xterm 已加载 SearchAddon，ArkTS 无入口 | 当前会话搜索、上下一个、大小写/正则选项 | P0 |
| 终端 Profile | 仅少量颜色、字号、行距、locale | 完整主题、字体、光标、滚屏、铃声、链接和输入栏配置 | P1 |
| Snippet | 无统一模型 | 变量化命令片段、作用域、预览、启动命令 | P1 |
| 历史/补全 | 无本地生产力层 | 可信命令历史、搜索、可关闭补全、shell integration 优先 | P1 |
| SFTP | 以 Sheet/流程为主 | 一等标签、双栏/单栏响应式浏览、拖放、传输中心 | P0/P1 |
| 会话日志 | 仅有限内存 transcript | 用户主动开启的加密日志、暂停/脱敏、书签、保留策略 | P1 |
| 完成提醒 | 主要依赖前台状态 | shell integration 驱动完成提醒，后台通知默认隐藏敏感信息 | P1 |
| 广播输入 | 无 | 明示目标、安全门禁、紧急停止、敏感态禁用 | P2 |
| 多窗口 | 页面单实例 | PC 条件支持分离窗口，连接只保留单一所有者 | P2 |
| 新协议/安全 | 传统 SSH 能力为主 | SSH cert/FIDO2/agent/PQ/Mosh 独立可行性项目 | Future |

### 2.3 UI 差距矩阵

| 领域 | 当前问题 | 目标设计 |
|---|---|---|
| 页面架构 | `SshTerminal.ets` 同时承担大量状态、业务和 UI | 兼容壳 + WorkspaceController + V2 叶组件，逐步拆分 |
| 手机 | 操作密度高，核心任务与辅助设置竞争空间 | 活跃会话全屏优先；紧凑标题、浮层操作、IME 上方输入附件 |
| 折叠屏 | 缺少折叠/展开状态连续性的明确策略 | 展开自动升级双栏；输入、滚动、焦点、Pane 状态连续 |
| 平板 | 没有稳定的主从/侧栏工作模式 | 可折叠侧栏 + 标签工作区 + 可选 Inspector |
| PC | 未形成自由窗口、键鼠、hover、拖放、分屏完整体验 | 沉浸标题栏、可调侧栏、浏览器式标签、Pane、状态栏、多窗口 |
| 设计语言 | 仍以 API 23/6.1 能力上限约束新设计 | 以 HarmonyOS 7 空间化设计为目标，API 23 仅作迁移参照 |
| 视觉层级 | 终端、工具与弹层的材质/背景规则不统一 | 沉浸光感只用于 chrome/浮层；终端 Cell 区保持不透明高对比 |
| 光感与动效 | 材质、按压和 hover 反馈分散 | 统一材质、光随指动、光线勾勒和轻量形变规则，并提供减少动效/纯色降级 |
| 字体与图标 | 字重、图标和状态密度缺少跨设备 token | HarmonyOS Sans 可变字体、Symbol/分层图标、设备密度 token |
| 响应式实现 | 页面级宽度监听为主 | API 26 目标采用 DynamicLayout/ContainerReader 等能力，状态跨布局保留 |
| 导航 | 页面导航和会话导航混合 | HdsNavigation 负责页面壳，动态会话由自定义 Tab Strip 管理 |
| 反馈 | Sheet/Dialog/Toast 分散 | SnackBar、状态栏、任务中心和通知形成四级反馈体系 |
| 键鼠 | 全局快捷键有限，焦点所有权不清晰 | 快捷键路由器、终端保留键策略、F6/Shift+Tab 焦点环、hover |
| 无障碍 | 图标、焦点、动态输出语义不统一 | 所有动作可读、可聚焦；不把终端字节流当实时朗读区域 |

## 3. 官方能力依据与 API 23 → API 26 双基线

### 3.1 设计依据

- [HarmonyOS 7 新能力一览](https://developer.huawei.com/consumer/cn/features/) 明确了新设计语言的空间化方向：沉浸光感组件扩展到更多场景，并加入光随指动、光线勾勒和非线性形变；同时提供更连续的可变字体。它们是目标体验，不是要求每个控件都发光或形变。
- [HarmonyOS Design](https://developer.huawei.com/consumer/cn/design) 将材质视为具有光学行为、空间属性和交互响应的独立界面物质，并强调手机、折叠屏、平板和 PC 的体验连续性。本计划把沉浸光感用于导航、侧栏、浮层和状态 chrome，不侵入终端字符背景。
- [HarmonyOS 7 / API 26 官方版本与能力页](https://developer.huawei.com/consumer/cn/doc/harmonyos-releases/changelogs-600) 当前列出 26.0.0 Beta1/Beta2 的 ArkUI、ArkWeb、UI Design Kit 等变更。由于仍为 Beta，最终采用列表必须以安装后的目标 SDK 和准备发布时的 release notes 再冻结一次。
- [UI Design Kit ArkTS 组件索引](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/ui-design-arkts-component) 当前提供 `HdsNavigation`、`HdsNavDestination`、`HdsSideBar`、`HdsSideMenu`、`HdsActionBar`、`HdsTabs`、`HdsSnackBar`、`HdsListItem`、`HdsListItemCard`、`HdsVisualComponent`、`MultiWindowEntryInAPP` 和 API 26 `HdsColorPicker` 等组件。
- [HarmonyOS 6.1 工具栏设计](https://developer.huawei.com/consumer/cn/doc/doccenter-ux-design/toolbar-0000001929683232) 要求控制操作数量、使用 Symbol、处理横竖屏响应式，并避免底部页签和底部工具栏竞争；因此活跃终端页不同时呈现全局底部 Tab 与输入工具栏。
- [大屏 UX 指南](https://developer.huawei.com/consumer/cn/doc/doccenter-ux-design/ux-guidelines-large-screen-0000001807707561) 要求充分利用宽屏、支持键鼠/hover/多窗口，并约束侧栏与主内容比例；本计划保证宽屏主内容不少于 60%。
- [多设备屏幕布局最佳实践](https://developer.huawei.com/consumer/cn/doc/best-practices/bpta-multi-device-screen-layout) 给出基于断点的 Navigation、SideBar、GridRow 和三栏模式；本计划沿用项目现有 `BreakpointUtil`，不另建互相冲突的断点体系。
- [折叠屏 UX 指南](https://developer.huawei.com/consumer/cn/doc/doccenter-ux-design/ux-guidelines-foldable-screen-0000001807866557) 要求折叠/展开连续，页面状态、滚动位置和输入不能无故丢失。
- [沉浸式窗口最佳实践](https://developer.huawei.com/consumer/cn/doc/best-practices/bpta-multi-device-window-immersive) 覆盖安全区、避让区、PC 自由窗口标题按钮等约束；标题栏不能用固定 padding 猜测系统按钮区域。
- [PC 应用设计与开发入口](https://developer.huawei.com/consumer/cn/multidevice/pc/get-started/) 将自由窗口、分屏、键鼠和窗口连续性作为 PC 基线能力。
- [HarmonyOS Symbol](https://developer.huawei.com/consumer/en/design/harmonyos-symbol/) 是导航和动作图标首选；没有匹配 Symbol 时才回退自有矢量资源。
- [HarmonyOS 设计资源](https://developer.huawei.com/consumer/cn/design/resource) 已提供 2026 年更新的手机/折叠屏/平板/电脑组件资源；实现前应将官方 PIX/Sketch token 与代码 token 做一次对照，不凭截图估算圆角、间距或光感参数。

### 3.2 当前 API 23 稳定基线

下表用于保证 API 26 升级前的当前产品仍可回归，也为升级后提供 fallback 对照。它不再限制新工作台的最终体验。每项 API 仍须在实际 SDK `.d.ts` 中逐个复核 modifier 的 `@since`；组件存在不代表它的全部 modifier 都可用。

| 能力 | 允许用途 | 约束 |
|---|---|---|
| `HdsNavigation` / `HdsNavDestination` | 页面壳、标题、返回和页面级动作 | 动态会话标签不用它模拟 |
| `HdsSideBar` / `HdsSideMenu` | 平板/PC 主机、工作区、工具导航 | 折叠态必须仍可键盘访问 |
| `HdsActionBar` | 上下文动作区 | 手机活跃终端不得与底部全局 Tab 叠加 |
| `HdsTabs` | 稳定的一级模式 | 动态可关闭会话使用自定义 List/Repeat Tab Strip |
| `HdsSnackBar` | 重连、传输、撤销和完成反馈 | 敏感命令/主机信息默认不进入消息文案 |
| `hdsMaterial` | 标题、侧栏、浮层、工具条 | 先查询系统支持；终端字符区禁用透明材质 |
| ArkUI `Navigation` / `NavPathStack` | 页面路由、恢复路径 | 路由对象不得持有 native session handle |
| `GridRow` / `GridCol` | 响应式区域排布 | 断点以现有 `BreakpointUtil` 为单一真值 |
| `RowSplit` / `ColumnSplit` | 工作区横纵 Pane | 比例钳制、最小尺寸和持久化必须由策略层控制 |
| `keyboardShortcut` | 允许的全局动作 | 系统保留组合键与终端输入所有权优先 |
| `onKeyEvent` / `onKeyPreIme` / focus APIs | 终端、Palette、Pane 焦点路由 | 不拦截密码输入或系统 IME 必要事件 |
| drag/drop + UDMF | 标签排序、文件拖放、SFTP 上传下载 | 校验 MIME/数据类型；外部文件需沙箱导入 |
| `bindContextMenu` | PC/平板右键/长按菜单 | 同一动作必须有非右键入口 |
| State Management V2 | 新的叶组件和小型状态模型 | 根页面先保留 V1 兼容，不一次性迁移 |
| `WebMessagePort` | ArkTS 与 xterm 双向消息通道 | API 23 支持 string/ArrayBuffer；必须握手、关闭和背压 |
| Preferences / RDB / Asset Store | UI 偏好、结构化业务数据、短秘密 | 三者职责严格分离 |
| Core File Kit | 文件选择、导入/导出 | 权限、URI 生命周期和失败恢复明确 |
| Background Tasks / Notification Kit | 传输和长任务状态、完成提醒 | 遵循后台限制；通知默认只显示别名 |
| Stage / Window / MultiWindowEntryInAPP | PC 分离窗口和自由窗口适配 | 能力检测后启用；单一会话所有权 |

### 3.3 API 24–26 目标能力清单

| 能力 | 起始/公开状态 | SSH 工作台用途 | 采用结论 |
|---|---|---|---|
| `DynamicLayout` | API 24 | 在手机单 Pane、平板双栏、PC 三栏间切换布局算法，并保持子组件输入、滚动等状态 | M0/M4 正式采用；参考[动态布局指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-layout-development-dynamiclayout) |
| `ContainerReader` | 最新文档已列出，本机 API 23 无声明 | Tab Strip、Inspector、SFTP Pane 等组件按自身容器而非整窗宽度响应 | API 26 SDK spike 后决定；避免与全局 `BreakpointUtil` 双重触发 |
| `LazyDynamicLayout` / `LazyLayoutAlgorithm` | API 26 Beta | 大型主机列表、命令历史、日志搜索结果和大目录自定义懒加载布局 | 只用于真正大列表；终端 Pane 树不使用；参考[LazyLayoutAlgorithm](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-arkui-lazylayoutalgorithm) |
| `SelectionContainer` | API 26 Beta | 日志、书签说明、命令帮助等多节点文本选择与扩展菜单 | 不用于 xterm 字符区；参考[SelectionContainer](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ts-basic-components-selectioncontainer) |
| State Management V2 完整能力 | API 26 目标 SDK 复核 | Workspace chrome、Pane 模型、视图快照和叶组件 | 新 UI 默认 V2；高频 output 仍绕开响应式状态 |
| UI Design Kit `hdsEffect` / `hdsMaterial` | 目标 SDK 复核 | 按压阴影、点光源、边缘/背景流光、沉浸光感材质 | 由 SSH capability/style policy 独立封装；若未来消费稳定的 App 主题接口，只通过版本化 adapter 接入 |
| `HdsVisualComponent` | 最新 UI Design Kit 索引 | 承载官方支持的视觉效果而非手写近似 shader | 仅在 API 26 SDK 与真机验证效果、性能、无障碍后采用 |
| `HdsColorPicker` | API 26，Phone/Tablet | Terminal Profile 主题颜色选择和收藏 | Profile 编辑页可采用；PC 必须保留自有/系统 Picker 降级 |
| UI Design Kit 新列表/侧栏/页签样式 | 目标 SDK 复核 | 新空间化导航、悬浮页签、列表卡片、侧栏 | 优先官方组件；动态可关闭 terminal tab 仍用自定义语义组件 |
| 可变字体与新版 HarmonyOS Sans | HarmonyOS 7 设计语言 | chrome 标题、状态和数字信息连续字重 | 终端 monospace 字体不替换；用户设置、可读性和字宽稳定优先 |
| 自定义无障碍走焦顺序 | API 26 新指南 | PC/平板复杂工作区的 F6/读屏焦点顺序 | 与 Workspace Focus Policy 统一建模并真机读屏验证 |
| 智慧手势 | API 26 Beta 指南 | 系统级选中、滚动、返回等辅助交互 | 不接管终端字节输入；仅作为可选辅助能力评估 |

目标 SDK 安装后，还要检查 UI Design Kit 的 `hdsDrawable`、`symbolRegister`、`hdsEffect`、`hdsMaterial` 以及 ArkUI native material 是否发生命名、权限或设备范围变化。任何网页未完整公开、需要账号权限或仍标记 Beta 的接口，都不能在 G0 前被写成稳定契约。

ArkUI、ArkTS 和 Stage 的官方入口分别为 [ArkUI](https://developer.huawei.com/consumer/cn/arkui/)、[ArkTS](https://developer.huawei.com/consumer/cn/arkts/) 和 [Stage 模型](https://developer.huawei.com/consumer/cn/arkui/arkui-stage)。键盘快捷键参考[通用 keyboardShortcut 属性](https://developer.huawei.com/consumer/cn/doc/harmonyos-references-v5/ts-universal-events-keyboardshortcut-V5)，拖放参考[拖拽事件与属性](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ts-universal-attributes-drag-drop)，ArkWeb 通道参考[应用侧与网页侧数据通道](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/web-app-page-data-channel)。

### 3.4 明确禁用、条件采用或延期

| API/方案 | 结论 | 原因 |
|---|---|---|
| `DynamicLayout` | API 26 目标采用 | 从 API 24 起可用，适合跨形态切换且保留子组件状态；在 target 升级前不得落入 API 23 产品代码 |
| `ContainerReader` | 条件采用 | 目标是组件级断点；必须等 API 26 SDK 确认声明、触发语义和与 `BreakpointUtil` 的单一真值方案 |
| `LazyDynamicLayout` | 条件采用 | API 26 Beta；只解决大列表/大结果集，不用于小型 Pane 或标签条 |
| `@CustomEnv` | 条件采用 | API 26 SDK 安装后评估是否适合注入主题/尺寸环境；不能把业务状态塞入环境对象 |
| `@kit.uiMaterial` 或新 material import | 条件采用 | 现有项目记录为 API 26-only 候选，但公开文档与 SDK 尚未在本机核验；最终 import 以 API 26 `.d.ts` 为准，不预设包名 |
| `hdsEffect` / `hdsMaterial` / native material | 条件采用 | 只用于工作台 chrome，必须做能力检测、对比度、减少动效、低功耗和纯色降级 |
| API 26 Beta modifier | 默认不开生产 | Beta API 必须有 feature flag、目标真机证据和 release 版再确认 |
| Live View 展示 SSH 会话 | 不采用 | 使用场景、时长和审核限制不适合作为任意 SSH 命令状态容器；采用常规通知/持续任务通知。参考 [Live View 介绍](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V13/liveview-introduction-V13) |
| 用 `@State` 承载终端字节流 | 禁用 | 高频输出会触发不必要的 UI 响应式更新 |
| 用 PersistenceV2 保存日志或秘密 | 禁用 | 它不是日志数据库或安全凭据仓库 |
| 自动恢复后盲目重连所有主机 | 默认禁用 | 网络、费用、隐私和意外命令风险 |

### 3.5 SDK 升级与复核规则

当前项目编译目标是 API 23，本机 DevEco 默认 SDK 为 HarmonyOS 6.1.1 / API 24，独立 OpenHarmony SDK 只有 API 23；没有 API 26 本地声明。因此 API 26-only 实现前必须完成 SSH-U0。SSH-U0 是本计划自己的工具链门禁，可以复用已安装 SDK 和全仓兼容事实，但不等待、调用或修改全 App UI 计划：

1. 安装与计划发布版本一致的 DevEco Studio、API 26 SDK、toolchains、模拟器/预览器；记录 `sdk-pkg.json`、DevEco build 和工具链版本。
2. 阅读 26.0.0 Beta1/Beta2 及最终 Release 的 OS 行为变更、ArkUI、ArkWeb、UI Design Kit、Window、Accessibility、Background Tasks 和 NDK/N-API 变更。
3. 单独提交 SDK/build-profile 升级，不与 SSH UI 功能混在一个 commit；完成全仓双门禁和已知协议回归。
4. 明确 `targetSdkVersion = 26` 后 `compatibleSdkVersion` 的产品决策：若仍兼容 API 23，所有 API 24–26 UI 必须通过可链接的 adapter/能力分支并在 API 23 真机验证；若最低版本同步升 26，则删除伪 fallback，明确上架与设备覆盖影响。
5. 对每个组件、modifier、enum 和 import 检查实际 API 26 `.d.ts`、`@since`、系统能力、设备范围、Beta 状态和权限。
6. 至少一台 API 26 手机、一台大屏/折叠设备和一台 PC/2in1 完成真机或官方云真机验证；Previewer/模拟器不能替代材质、键鼠、窗口和性能证据。
7. API 23 回归是否继续保留由第 4 步决定；在决定落盘前，当前 API 23 行为仍是不可破坏的比较基线。
8. 可选能力必须有 runtime capability check、减少动效/高对比/低功耗策略和纯色/旧布局降级路径。

官方 [2026 年 7 月开发者月刊](https://developer.huawei.com/consumer/cn/monthly/202607) 已说明 26.0.0 Beta2 配套文档与工具，并列出 ArkUI 的智慧手势、LazyDynamicLayout 和 Accessibility 自定义走焦等新增资源；这证明升级方向已公开，但不等于 Beta API 已可直接作为生产稳定接口。

## 4. 产品目标与非目标

### 4.1 产品目标

1. 用户能把多个终端、SFTP 和辅助视图组织为可命名工作区，并安全恢复布局。
2. 手机上维持“当前终端优先”，平板/折叠屏/PC 上升级为侧栏 + 标签 + Pane 工作台。
3. 常用任务可通过命令面板、快捷键、搜索和 Snippet 在少量操作内完成。
4. 传输、日志和通知具备明确的隐私默认值、进度、失败恢复和审计边界。
5. ArkWeb 终端的输入/输出通道可测、可限流、可回退，不把高频数据送入 ArkUI 响应式状态。
6. 所有新增能力在 API 26 可编译、可真机运行、可通过 feature flag 回滚；是否继续支持 API 23 由升级门禁明确决定并形成独立兼容矩阵。

### 4.2 第一阶段非目标

- 不复制 Termius 的商标、Logo、插图、具体布局像素或专有文案。
- 不实现团队 Vault、多人实时协作、AI 命令生成或云端命令分析。
- 不在本计划内承诺 Telnet、Serial、本地 Shell、Mosh、SSH Agent Forwarding、SSH Certificate、FIDO2 或后量子算法。
- 不把会话日志、Snippet、命令历史直接加入现有云同步结构。
- 不重写当前 SSH native 会话、SFTP 传输和端口转发引擎。
- 不通过扩大系统权限来换取便利。

## 5. 目标信息架构

### 5.1 一级结构

SSH 模块采用“资源层 + 工作区层 + 任务层”三层结构：

```text
SSH Home
├── Hosts / Groups / Tags
├── Workspaces
├── Snippets
├── Transfers
├── Session Logs
└── Settings / Profiles

Active Workspace
├── Workspace navigation / command palette
├── Session tab strip
├── Pane tree
│   ├── Terminal pane
│   ├── SFTP pane
│   └── Inspector / transfer detail
├── Context actions
└── Status / mobile input accessory
```

活跃工作区是执行任务的核心；Hosts 是连接资源库；Transfers、Logs 是跨会话任务中心。用户不需要退出终端页才能查看传输状态或切换主机。

### 5.2 响应式断点

产品断点仍由统一 `SshLayoutPolicy` 输出；当前 API 23 路径以现有 `BreakpointUtil` 为窗口级输入，API 26 路径可用 `ContainerReader` 提供局部容器输入，但不能让两个监听器分别直接改 UI。下表是统一产品语义：

| 语义断点 | 参考宽度 | 布局 |
|---|---:|---|
| `sm` | `< 600vp` | 单 Pane，全屏终端；侧栏/日志/SFTP 以导航页或 Sheet 进入 |
| `md` | `600–839vp` | 可折叠窄侧栏，主 Pane；横屏可短时显示 Inspector |
| `lg` | `840–1439vp` | 侧栏 + 主工作区，可选右侧 Inspector，支持分屏 |
| `xl` | `>= 1440vp` | 完整侧栏 + 多 Pane + Inspector，PC 自由窗口规则 |

API 26 响应式实现规则：

- `BreakpointUtil/windowSizeChange` 只判断应用窗口拓扑：手机、双栏、三栏和自由窗口模式。
- `ContainerReader` 只判断局部组件可用空间，例如 Tab Strip 是否折叠、Inspector 是否切为 Drawer、SFTP 双栏是否降为单栏。
- `DynamicLayout` 持有 shell 布局算法，使 `sm/md/lg/xl` 切换时保留输入、滚动和子组件状态；不依赖销毁/重建 WebView 来换布局。
- `RowSplit/ColumnSplit` 继续表达用户主动创建的 terminal Pane 树；它们不负责整页设备适配。
- `LazyDynamicLayout` 只服务主机、日志、历史和大目录结果集，不用于 terminal tab strip 或 4 Pane 工作区。
- 所有输入先归一为 `SshLayoutMode` 和组件级 `SshContainerClass`，组件不得自行散落宽度阈值。

窗口尺寸必须在页面可见后从正确的 Window/size change 生命周期获取，不能只在 `aboutToAppear` 猜测。参考官方[窗口尺寸获取 FAQ](https://developer.huawei.com/consumer/cn/doc/harmonyos-faqs/faqs-arkui-190)。

### 5.3 手机布局

```text
┌──────────────────────────┐
│ ‹  alias / cwd      ⋯    │  紧凑 HdsNavigation
├──────────────────────────┤
│                          │
│       Terminal Pane      │  不透明、高对比、占据最大空间
│                          │
├──────────────────────────┤
│ Esc Ctrl Alt Tab  ↑  …   │  IME 上方输入附件，按用户配置滚动
└──────────────────────────┘
```

- 左右滑动不直接切会话，避免与终端鼠标/应用手势冲突；通过标题会话切换器或命令面板切换。
- 活跃终端不显示全局底部 Tab Bar，避免与输入附件/IME 形成双底栏。
- 搜索、Snippet、主机跳转、SFTP 和传输中心从标题动作、更多菜单或命令面板进入。
- 折叠/展开、横竖屏和前后台切换必须保存焦点 Pane、滚动锚点、选区和未发送输入。

### 5.4 折叠屏与平板布局

```text
┌──────────┬──────────────────────────┬─────────────┐
│ 72/240vp │ Session tabs             │ Inspector   │
│ sidebar  ├──────────────────────────┤ optional    │
│          │ Terminal / SFTP workspace│ 280–320vp   │
│          │                          │             │
└──────────┴──────────────────────────┴─────────────┘
```

- 折叠态沿用手机模型；展开态升级为侧栏 + 主 Pane，不能重新创建连接。
- 侧栏折叠后仍保留 Symbol、Tooltip/accessibility label 和键盘焦点。
- Inspector 只在主内容仍大于 60% 且终端达到最小列宽时出现。
- API 26 shell 通过 `DynamicLayout` 在单/双/三栏间切换并保留子树状态；用户创建的 terminal Pane 仍由 `RowSplit`/`ColumnSplit` 管理，不通过绝对坐标模拟分栏。

### 5.5 PC 布局

```text
┌───────────────────────────────────────────────────────────┐
│  immersive title / workspace / search / window controls   │ 48–56vp
├────────────┬──────────────────────────────────┬────────────┤
│ sidebar    │ closable/reorderable tabs        │ inspector  │
│ 240–320vp  ├──────────────┬───────────────────┤ 300–360vp │
│ resizeable │ terminal A   │ terminal/SFTP B   │ optional   │
│            │              │                   │            │
├────────────┴──────────────┴───────────────────┴────────────┤
│ status: connection / latency / encoding / transfer         │ 24–28vp
└───────────────────────────────────────────────────────────┘
```

- 支持自由窗口最小宽度场景；宽度不足时按 `xl → lg → md → sm` 自动降级，不允许右侧动作被裁掉。
- 侧栏最大不超过总宽度 40%；主内容至少 60%。
- 标题栏依据系统标题按钮矩形和安全区避让，不硬编码右上角空白。
- 鼠标 hover、右键菜单、滚轮、拖放和键盘快捷键均有完整路径。
- 终端标签条使用自定义组件，支持关闭、固定、排序、未读/重连状态；不把 `HdsTabs` 强行改造成浏览器标签。

## 6. UI 设计系统

### 6.1 HarmonyOS 7 空间化设计原则

HarmonyOS 7 的新语言应用到 SSH 工具时，重点是“用材质表达层级和可操作性”，而不是把专业终端做成高反射展示页：

1. **内容是锚点**：终端字符、文件名、日志和 Host Key 信息属于稳定内容层，保持不透明、无形变、无持续光效。
2. **材质表达空间**：标题、侧栏、悬浮 Tab、Palette、Search 和移动输入附件可使用沉浸光感，让操作层浮于内容层之上。
3. **光只响应交互**：光随指动、光线勾勒只在 hover、按压、拖放目标和焦点迁移时出现；无输入时回到安静状态。
4. **形变表达直接操控**：非线性形变只用于拖动标签、拉开 Pane、按压主动作等短暂反馈，不能改变文字基线、命中区域或终端网格。
5. **字体表达层级**：HarmonyOS Sans 可变字体用于工作区名称、状态和数字信息；terminal monospace 字体由 Profile 决定，不做连续字重动画。
6. **一多一致、密度有别**：手机强调单手触控和当前任务，PC 强调信息密度、hover、右键和键盘；语义、状态色和动作 ID 保持一致。
7. **效果可关闭**：减少动效、高对比、低功耗、远程桌面投屏或设备不支持时，自动切为纯色、静态阴影和标准字体。

API 26 视觉能力映射：

| 官方方向/候选能力 | 使用位置 | 明确不用的位置 | 验收重点 |
|---|---|---|---|
| 沉浸光感材质 / `hdsMaterial` | TitleBar、SideBar、浮动 Tab、Palette、Search、输入附件 | terminal cell surface、日志正文、Host Key 指纹正文 | 对比度、功耗、暗色主题、降级一致性 |
| `hdsEffect` 点光源/按压阴影 | 主按钮、标签关闭、Pane handle、拖放目标 | 每个文件行、每个终端字符 | hover/press 时延、键盘焦点等价反馈 |
| 双边/背景流光 | 活跃拖放边界、短暂连接成功/完成状态 | 持续连接状态、错误文本、广播输入警示 | 只运行一次、减少动效关闭、状态不只靠颜色 |
| 光随指动 | 悬浮 ActionBar、PC toolbar、可拖动标签 | 手机滚动终端、SFTP 大列表 | 不抢手势、不导致掉帧 |
| 非线性形变 | tab drag、Pane split preview、主动作 press | 文本、终端 viewport、危险确认 | 幅度克制、命中框稳定、释放后精确归位 |
| 可变字体 | chrome 标题、状态数字、层级切换 | terminal monospace、日志原文 | 字宽变化不引发布局抖动 |
| HdsVisualComponent | 官方已支持的视觉容器 | 自行模拟未公开 shader | SDK/真机效果与无障碍树均通过 |

SSH 使用已有 `Theme.ets`、`BreakpointUtil.ets` 和系统组件作为当前兼容基线，并由 `SshTerminalStylePolicy` 负责 ANSI palette、monospace、光标、Cell、Pane、连接状态和 SSH chrome 语义；不另造一套全局主题系统。未来 App UI 计划发布稳定的主题/能力只读快照后，可经版本化 adapter 消费，但 SSH 业务组件不直接 import 对方实现。业务组件只能请求诸如 `workspaceChrome`、`terminalCell`、`activePane` 的语义，不直接选择具体光效枚举。

### 6.2 视觉层级

| 层 | 表面 | 规则 |
|---|---|---|
| L0 | 终端 Cell Surface | 不透明；背景由 Terminal Profile 决定；不使用模糊材质 |
| L1 | 工作区 chrome | 标题、侧栏、Tab Strip、状态栏；可用轻量材质/纯色 |
| L2 | 浮动工具 | Search、Palette、Snippet Picker；可用 `hdsMaterial`，必须有不透明回退 |
| L3 | 模态/危险确认 | 删除、广播输入、日志导出、Host Key 变化；明确阻断背景交互 |

`hdsMaterial` 或 API 26 最终 material 接口只在目标 SDK/系统能力确认支持且对比度合格时启用。深色终端主题下，chrome 颜色从系统主题与用户 Profile 共同计算，不从远端 ANSI 背景取样。

### 6.3 尺寸、圆角与密度

- 触控动作最小命中区域 48vp；PC 紧凑视觉可为 32–36vp，但命中区和焦点框不能缩小到不可用。
- 手机标题 48–56vp；PC 沉浸标题 48–56vp；动态标签 40–44vp；状态栏 24–28vp。
- 终端最小可用宽度由字体 metrics 和最小 40 列共同决定，不能只按 vp 判断。
- Pane 分隔条可见宽度保持克制，但命中宽度至少 8–12vp，并提供键盘调整。
- 所有尺寸通过 token/policy 计算，不在多个组件内散落 magic number。
- 圆角、描边、阴影和材质层级从 HarmonyOS 7 官方设计资源导出为 token；不得凭视觉截图在代码中近似。
- 浮动工具条遵循官方操作数量与导航条避让规则；底部全局页签和工具条不同时出现。

### 6.4 Symbol、分层图标、反馈和动效

- 连接、断开、搜索、分屏、SFTP、上传、下载、设置等动作优先使用 HarmonyOS Symbol。
- API 26 目标 SDK 支持且视觉规范需要时，可通过 `hdsDrawable`/`symbolRegister` 使用分层图标和官方描边处理；不得把所有普通工具图标做成应用图标式彩色卡片。
- hover 用轻量 backplate；当前 Pane 用焦点边框/底色，不只依赖颜色点。
- 动效只表达结构变化：侧栏展开、Pane 分裂/合并、标签移动、折叠屏模式迁移。
- 光随指动和形变均从 pointer/press 生命周期派生，不写入业务持久状态。
- 重连、Host Key、传输失败等状态不得被装饰动效延迟。
- 尊重系统减少动效与字体缩放设置。

### 6.5 无障碍与焦点

- 每个纯图标按钮提供可本地化的 accessibility text/description。
- 焦点顺序：标题动作 → 侧栏 → 标签 → Pane → Inspector → 状态栏，并可使用 F6 循环区域。
- `Shift+Tab` 保留为从终端捕获区逃离的既有路径；屏幕阅读器开启时提供等价显式动作。
- 不把高速终端输出标记为持续 live region；只播报连接变化、危险提示、传输完成等语义事件。
- 颜色不是唯一状态载体；连接状态同时使用 Symbol/文本。
- API 26 Accessibility 自定义走焦能力只由统一 Focus Policy 使用；视觉层级变化后读屏顺序仍保持任务语义，不按绘制 z-order 盲目排序。
- 无障碍属性参考 OpenHarmony 官方[通用无障碍属性](https://gitee.com/openharmony/docs/blob/7084dbcbc98086006a81c83224e0c45fa7f4d342/zh-cn/application-dev/reference/apis-arkui/arkui-ts/ts-universal-attributes-accessibility.md)。

## 7. 交互与功能规格

### 7.1 工作区、标签和 Pane

#### 工作区

- 新建、重命名、复制、归档、删除工作区。
- 工作区保存标签顺序、Pane 树、侧栏/Inspector 状态、选中 Pane 和非敏感 Profile 引用。
- 应用恢复时先创建“未连接占位”，默认不自动连接。
- 用户可按工作区设置 `never`、`ask`、`afterUnlock` 三种恢复策略；第一版只开放 `never` 和 `ask`。
- 连接失败不破坏布局，标签进入可重试状态。

#### 标签

- 类型首期支持 `terminal` 与 `sftp`；后续可加入 `log`/`transferDetail`。
- 支持新建、关闭、关闭其他、关闭右侧、固定、重命名显示标题、排序、跨 Pane 移动。
- 关闭仍有前台任务的标签时，展示“断开并关闭 / 保留后台任务 / 取消”语义，不用模糊的“确定”。
- 标签身份与 native session 身份分离；同一 native session 不得被两个独立 owner 重复释放。

#### Pane

- 支持横向、纵向分裂；叶节点引用一个 tab。
- 每个 split ratio 钳制到 `0.2–0.8`，并受子 Pane 最小尺寸二次约束。
- 最大同时可见 Pane 初始为 4；超出时引导创建新工作区/标签，不无限分裂。
- 支持焦点模式，退出后恢复原 Pane 树和比例。
- 窗口降级到手机宽度时保留 Pane 树，但只显示活动叶节点；再次展开恢复。

### 7.2 命令面板与快捷键

命令面板统一承载主机跳转、工作区、会话、SFTP、Snippet、设置和页面动作。每项动作必须有稳定 ID、可本地化标题、关键词、可用条件、危险等级和执行函数，不允许组件自行拼接一套搜索列表。

建议默认快捷键：

| 动作 | Windows/Linux 键盘 | macOS 风格键盘 | 备注 |
|---|---|---|---|
| 新建会话 | `Ctrl+T` | `Meta+T` | 终端全屏应用可在 Profile 中关闭全局接管 |
| 关闭标签 | `Ctrl+W` | `Meta+W` | 有前台任务时确认 |
| 关闭工作区 | `Ctrl+Shift+W` | `Meta+Shift+W` | 危险动作 |
| 命令面板/快速跳转 | `Ctrl+J` | `Meta+J` | 避免与常用远端组合键冲突，可配置 |
| 当前终端搜索 | `Ctrl+F` | `Meta+F` | 打开 SearchAddon UI |
| 会话日志搜索 | `Ctrl+Shift+F` | `Meta+Shift+F` | 仅日志功能开启时 |
| 切换标签 | `Alt+1…9` | `Alt+1…9` | 不发送到远端时才接管 |
| 纵向分屏 | `Ctrl+\` | `Meta+\` | 可配置 |
| 横向分屏 | `Ctrl+Shift+\` | `Meta+Shift+\` | 可配置 |
| 区域焦点循环 | `F6` | `F6` | 侧栏/标签/Pane/Inspector |
| 退出终端焦点 | `Shift+Tab` | `Shift+Tab` | 延续现有行为 |

规则：

- `Ctrl+C/V/A/X/Z/Y` 等系统/编辑常用组合不得通过 `keyboardShortcut` 粗暴接管；终端聚焦时默认发送给远端，只有存在本地选区或显式编辑控件时走本地动作。
- 快捷键路由按 `modal > palette/search > text editor > terminal > workspace` 优先级判定。
- 用户配置冲突时立即提示，不保存两个同作用域的相同组合。
- 所有快捷键动作必须有鼠标/触控等价入口。

### 7.3 终端搜索与 Profile

当前 xterm rawfile 已加载 SearchAddon，应先补齐低风险的 UI/bridge，不重复引入搜索引擎。

搜索规格：

- 当前会话搜索、上一项、下一项、结果计数。
- 可选大小写、全词、正则；无效正则即时反馈。
- Search UI 关闭后不改变远端输入焦点；搜索文本不写入命令历史。
- 长 scrollback 搜索需限时/分片，不阻塞 UI。

Terminal Profile 首期字段：

- 前景/背景、16 色和扩展 palette。
- 字体族、字号、行距、字重；字体缺失时可预测回退。
- 光标形状、闪烁、宽度。
- scrollback 上限、铃声、链接点击策略。
- 复制选择、右键粘贴、bracketed paste、鼠标报告策略。
- 手机输入附件按键顺序与显示密度。

Profile 可全局默认、主机覆盖、当前会话临时覆盖；合并优先级为 `session > host > global > built-in`。

### 7.4 Snippet、历史与补全

#### Snippet

- 支持名称、描述、命令体、标签、主机/组作用域和变量定义。
- 变量类型首期为 `text`、`choice`、`hostField`、`secretRef`。
- 执行前显示最终命令预览；`secretRef` 只在发送前从 Asset Store 解引用，绝不写回 Snippet、历史、日志或 UI snapshot。
- 支持“插入到终端”与“确认后执行”，默认插入，不默认立即执行。
- 启动命令必须由用户按主机/工作区显式配置，Host Key 校验和认证完成前绝不执行。

#### 命令历史

- 默认仅本地；用户可按主机禁用。
- 不通过回显猜测密码输入；只在 shell integration 明确标记命令边界，或用户显式保存时记录。
- 支持搜索、固定、删除、按主机/目录筛选和保留期限。
- 自动过滤已知敏感模式只能作为补充，不能替代边界识别和用户关闭能力。

#### 补全

- P1 先提供历史、Snippet、主机元数据和常用命令的本地候选。
- 远端文件/命令补全只在用户主动触发时请求，并设置超时与取消。
- 不向云端发送命令上下文；AI 补全不属于本计划。
- 处于密码提示、全屏 TUI、raw mode 或 bracketed paste 时自动停用本地补全。

### 7.5 SFTP 工作台与传输中心

SFTP 从 Sheet 升级为一等工作区标签，但复用现有传输引擎。

手机：

- 单栏文件浏览，标题可切换本地/远端。
- 长按进入多选；底部上下文工具条只在选中时出现。
- 传输任务通过全局 Transfer Center 查看，不阻塞文件浏览。

平板/PC：

- 双栏本地/远端或远端/远端；栏宽可调。
- 支持拖放上传、下载、移动和标签间文件投递。
- 外部拖入使用 UDMF/Core File Kit 解析；先复制/读取到允许的沙箱范围，再交给传输引擎。
- 拖放结束前展示目标路径和动作语义；覆盖、跨文件系统移动、符号链接均需独立策略。

传输中心：

- 统一展示排队、运行、暂停、等待网络、失败、校验和完成状态。
- 支持批量暂停/恢复/重试/清除已完成。
- 退出标签不取消后台传输；退出应用按后台任务能力和用户设置处理。
- 完成通知只显示用户别名与数量，默认不显示真实主机、IP、远端路径。
- 远程编辑延后到 P2：下载临时副本、检测冲突、上传临时名、原子替换；不直接在半写状态覆盖远端文件。

### 7.6 会话日志、书签与完成提醒

日志默认关闭，开启时必须明确显示持续状态。规格：

- 日志按会话分块保存，包含时间、方向、事件类型和经过脱敏的文本；原始控制序列不直接作为搜索索引。
- 支持暂停记录、插入书签、为书签写本地备注、按时间/关键词跳转。
- 进入密码提示、MFA、私钥口令、sudo password 等敏感态时自动暂停；用户可手动延长暂停。
- 默认本地加密，设置空间上限与保留天数；导出前再次确认并允许二次脱敏。
- 首期不云同步、不团队共享。

完成提醒以 shell integration 的命令开始/结束标记为首选，退出码和耗时达到用户阈值才通知。没有可信集成时只提供“铃声/长时间静默后活动”弱提醒，并明确不是命令完成判断。

### 7.7 广播输入

广播输入是高风险 P2 能力，只在以下门禁全部满足时开放：

- 最多 16 个目标 Pane，目标列表始终可见。
- 顶部/底部持续显示红色广播条，包含目标数和一键停止。
- 默认只广播可见终端；新增目标必须显式勾选。
- 处于认证、密码提示、Host Key 变化、raw/fullscreen TUI 的会话自动移出广播。
- 粘贴、多行、控制字符、`sudo`/删除类高风险命令要求二次确认。
- 支持只插入和确认执行两种模式，默认只插入。
- 断线/重连不会自动重新加入广播。
- `Esc Esc` 或可配置独立快捷键立即停止广播，且不会发送这组按键到远端。

### 7.8 PC 多窗口与分离

P2 在 API 26 目标能力和设备支持确认后提供：

- 标签拖出后新建窗口，或使用“移到新窗口”。
- native session 保持单一 owner；窗口只附着 view，或通过显式协议转移 owner。
- 每条消息携带 session/generation，旧窗口关闭后不能释放新 owner 的连接。
- 不支持多窗口时，动作降级为新工作区/新 Pane。
- 窗口状态只保存位置/尺寸/工作区引用，不持久化 native handle。

## 8. 状态、实体与持久化设计

### 8.1 状态分层

| 层 | 内容 | 生命周期 | 禁止内容 |
|---|---|---|---|
| UI Local State | hover、弹层、当前搜索词、临时选择 | 组件/页面 | session handle、终端输出 |
| Workspace Snapshot | 标签、Pane 树、活动 ID、非敏感 UI 设置 | 工作区 | 密码、私钥、解密后的 secret |
| Runtime Store | native session、channel、generation、连接状态 | 进程/页面运行期 | 持久化 handle |
| RDB | workspace/snippet/history/log index/bookmark | 本地持久 | 明文 secret、无限日志 blob |
| File chunks | 加密日志块、可选导出临时文件 | 沙箱文件 | 未加密敏感会话 |
| Asset Store | secretRef 指向的短秘密 | 安全持久 | 普通 UI 配置、日志 |
| Preferences/PersistenceV2 | 小型偏好、最后工作区 ID | 本地持久 | 业务关系、日志、凭据 |

### 8.2 建议实体

```ts
type SshWorkspaceV1 = {
  schemaVersion: 1
  id: string
  name: string
  tabOrder: string[]
  paneRoot: SshPaneNodeV1
  activeTabId: string
  activePaneId: string
  reconnectPolicy: 'never' | 'ask'
  createdAt: number
  updatedAt: number
}

type SshWorkspaceTabV1 = {
  tabId: string
  kind: 'terminal' | 'sftp'
  hostId: string
  titleOverride?: string
  cwdHint?: string
  profileId?: string
  pinned: boolean
}

type SshPaneNodeV1 = {
  nodeId: string
  kind: 'leaf' | 'split'
  tabId?: string
  direction?: 'horizontal' | 'vertical'
  ratio?: number
  first?: SshPaneNodeV1
  second?: SshPaneNodeV1
}

type SshTerminalProfileV1 = {
  id: string
  name: string
  paletteId: string
  fontFamily: string
  fontSize: number
  lineHeight: number
  cursor: 'block' | 'bar' | 'underline'
  cursorBlink: boolean
  scrollback: number
  bell: 'off' | 'visual' | 'system'
  linkPolicy: 'confirm' | 'allow'
  mobileAccessoryKeys: string[]
}

type SshSnippetV1 = {
  id: string
  name: string
  body: string
  variables: SshSnippetVariableV1[]
  scope: 'global' | 'group' | 'host'
  scopeId?: string
  tags: string[]
  startup: boolean
}
```

补充实体：

- `SshCommandHistoryV1`：hostId、cwd、command、exitCode、startedAt、duration、pinned、redaction state。
- `SshSessionLogIndexV1`：logId、host alias、startedAt、endedAt、chunk count、size、encryption metadata、retention。
- `SshSessionBookmarkV1`：logId、timestamp、label、note、line anchor。
- `SshTransferViewStateV1`：只保存筛选/排序，不复制传输引擎任务实体。

### 8.3 数据迁移

- 所有实体都有 `schemaVersion`，解码采用逐字段默认和坏记录隔离，单个坏项不能清空全库。
- 当前 in-memory tab 只在新功能开启后映射为临时 Workspace；用户首次显式保存时才持久化。
- 旧颜色/字号/行距偏好迁移到 built-in Profile 的 override；迁移可重复执行。
- 未知新版本记录只读隔离，不做破坏性降级写回。
- RDB migration 失败时关闭 `sshWorkbenchV2` 并回到旧页面，保留原始数据库备份。

## 9. ArkUI 状态管理与组件架构

### 9.1 迁移原则

`SshTerminal.ets` 当前是大型 V1 `@Entry @Component`。第一阶段不直接把整个页面改为 V2，而采用以下边界：

1. 保留现有入口和连接生命周期作为兼容壳。
2. 先抽取无副作用纯策略与 immutable snapshot。
3. 新的 Tab Strip、Palette、Search、SideBar、Pane Header 等叶组件使用 `@ComponentV2`、`@Param`、`@Event`、`@Local`。
4. 共享可观察模型只在必要处用 `@ObservedV2/@Trace`；终端输出不进入这些模型。
5. 根页面是否迁移 V2 在 M4 后单独评审，以行为测试和性能数据为依据。

### 9.2 建议组件边界

```text
SshTerminal.ets                         # 兼容入口，逐步变薄
└── SshWorkspaceShell
    ├── SshWorkspaceTitleBar
    ├── SshWorkspaceSideBar
    ├── SshWorkspaceTabStrip
    ├── SshWorkspacePaneHost
    │   ├── SshTerminalPane
    │   └── SshSftpPane
    ├── SshSessionInspector
    ├── SshTransferCenter
    ├── SshCommandPalette
    ├── SshTerminalSearchBar
    ├── SshSnippetPicker
    ├── SshSessionLogView
    └── SshMobileInputAccessory
```

组件只发出语义事件，例如 `onCloseTab(tabId)`、`onSplitPane(paneId, direction)`，不直接操作 native session 或 RDB。

### 9.3 Controller 边界

`SshWorkspaceController` 是 UI 与现有服务之间的唯一协调层：

- 接收纯语义 action。
- 调用 WorkspacePolicy 生成新 snapshot。
- 调用 RuntimeStore 创建/附着/释放会话。
- 调用 Store 做异步持久化。
- 把错误归一为 UI 可显示状态。
- 通过 sessionId + generation 拒绝旧回调。

Controller 不解析 ANSI、不保存密码、不直接渲染组件，也不把 ArkWeb 回调逐字节转换为 `@State`。

## 10. ArkWeb/xterm 通道升级

### 10.1 当前问题

现有 `SshXtermSurface.ets` 使用 JavaScript Proxy 和多次 `runJavaScript` 推送，生命周期包含 ready、reload、watchdog 和批处理。它可用，但在多 Pane、高吞吐和页面恢复下容易形成：

- 高频字符串拼接和 JS 注入开销。
- 回调缺少统一版本、序列、generation 和能力握手。
- reload 后旧消息误投递新页面。
- 背压、丢包诊断和关闭顺序不够显式。

### 10.2 目标协议

API 23 的 `WebMessagePort` 支持 string/ArrayBuffer 双向通道。新协议使用统一 envelope：

```ts
type SshWebEnvelope = {
  protocolVersion: 1
  sessionId: string
  hostId: string
  generation: number
  sequence: number
  kind: 'hello' | 'ready' | 'output' | 'input' | 'resize' |
        'search' | 'selection' | 'focus' | 'ack' | 'error' | 'dispose'
  payload: string | ArrayBuffer
}
```

流程：

1. ArkTS 创建端口，把网页端端口通过 `postMessage` 发送给 xterm 页面。
2. 网页发送 `hello` 和 capability；ArkTS 校验 protocolVersion/generation。
3. 输出按大小/时间批处理，以 ArrayBuffer 为主；输入与控制消息可用短字符串。
4. 每个方向维护 sequence、队列上限和 ack 水位；超限合并输出或触发受控重载，不无限积压。
5. resize、搜索等控制消息与 output 分离，不能被大输出饿死。
6. 页面销毁前双方发送 `dispose` 并关闭 port；旧 generation 的所有消息丢弃。
7. `sshWebMessageBridge` flag 关闭时回退当前 JS proxy/runJavaScript 路径。

### 10.3 线程与性能边界

- native I/O 不在 ArkUI 线程做阻塞处理。
- N-API 回调遵循官方[线程安全使用指南](https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/napi/use-napi-thread-safety.md)。
- TaskPool/Worker 仅承担可序列化、CPU 型或文件索引任务；session handle 不跨线程无约束传递。
- xterm resize 经 50–100ms 合并后更新 PTY；最终尺寸必须可靠送达。
- 高频输出直接进入 renderer/bridge 队列，ArkUI 只接收低频统计快照。

## 11. 底层能力复用与未来边界

### 11.1 本计划直接复用

- 现有 SSH native transport、认证和 Host Key 状态机。
- 现有 SFTP transfer engine 与持久任务数据。
- 现有 forwarding/proxy/jump host 服务。
- 现有 TranscriptStore 作为过渡期内存回看，不把它冒充持久日志。
- 现有 `BreakpointUtil`、后台任务服务、通知基础、云端主机/Key 存储。
- 网络能力遵循官方 [Socket 连接指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/socket-connection) 与当前 native 实现约束。

### 11.2 单独立项的 native 能力

以下功能需要 native 库、服务端兼容、密钥硬件或协议层调研，不能以 UI 开关假装完成：

| 能力 | 前置验证 | 输出 |
|---|---|---|
| SSH Agent Forwarding | libssh2/当前 native 能力、agent channel 生命周期、安全确认 | ADR + 原型 + 威胁模型 |
| SSH Certificate | 证书解析、CA trust、到期/更新、Host/User cert | 兼容矩阵 + 测试向量 |
| FIDO2/设备绑定 Key | HarmonyOS 硬件/认证 API、libssh2 支持、用户在场 | 可行性报告 |
| 后量子 KEX | 服务端/OpenSSH 兼容、依赖库版本、性能 | 独立升级计划 |
| Mosh | UDP、漫游、server helper、后台限制 | 产品/网络/合规评估 |
| 本地终端 | PTY/shell 沙箱和权限 | 独立安全评审 |

这些项目不能阻塞 M0–M8 的工作台建设。

## 12. 安全、隐私与合规

### 12.1 默认值

- 会话日志默认关闭。
- 命令历史默认本地，可按主机关闭。
- 工作区恢复默认不自动联网。
- 通知默认只显示用户设置的别名和任务状态。
- Snippet 默认“插入不执行”。
- 广播输入默认关闭，并受 feature flag 控制。
- 所有新数据首期不进入云同步。

### 12.2 敏感数据边界

- 密码、私钥明文、MFA、解引用 secret、认证提示输入不得进入 UI snapshot、日志、历史、通知、Crash metadata。
- `secretRef` 只保存安全存储引用，实际值仅存在于最短必要作用域，并在发送后释放引用。
- Host Key 变化、代理认证失败和证书错误不得被“自动重试”掩盖。
- 外部链接默认确认域名/完整 URL；OSC 8 链接不得绕过用户策略。
- 文件拖放必须校验类型、大小、目标、覆盖和软链接语义。
- 日志导出使用临时文件，分享/退出后按生命周期删除；失败时可恢复且不留下明文副本。

### 12.3 隐私模式

提供工作区/标签级隐私模式：

- 标题、最近任务、通知和任务切换缩略图隐藏真实主机/IP/用户名/路径。
- 不改变 SSH 实际连接参数。
- 切换开启立即刷新所有 chrome，不等待下次连接。
- 截屏/录屏限制是否启用由平台能力与用户设置决定，必须清楚告知副作用。

## 13. 代码与文件落点

### 13.1 建议新增

```text
entry/src/main/ets/pages/
└── SshWorkspacePage.ets

entry/src/main/ets/components/ssh/workspace/
├── SshWorkspaceShell.ets
├── SshWorkspaceTitleBar.ets
├── SshWorkspaceSideBar.ets
├── SshWorkspaceTabStrip.ets
├── SshWorkspacePaneHost.ets
├── SshTerminalPane.ets
├── SshSftpPane.ets
├── SshTransferCenter.ets
├── SshSessionInspector.ets
├── SshCommandPalette.ets
├── SshTerminalSearchBar.ets
├── SshMobileInputAccessory.ets
├── SshSnippetPicker.ets
└── SshSessionLogView.ets

entry/src/main/ets/services/ssh/workspace/
├── SshWorkspaceCapabilityPolicy.ets
├── SshTerminalStylePolicy.ets
├── SshLayoutPolicy.ets
├── SshWorkspacePolicy.ets
├── SshWorkspaceController.ets
├── SshWorkspaceStore.ets
├── SshWorkspaceMigrationPolicy.ets
├── SshWorkspaceRuntimeStore.ets
├── SshShortcutPolicy.ets
├── SshTerminalProfilePolicy.ets
├── SshTerminalProfileStore.ets
├── SshCommandHistoryPolicy.ets
├── SshCommandHistoryStore.ets
├── SshSnippetPolicy.ets
├── SshSnippetStore.ets
├── SshSessionLogPolicy.ets
├── SshSessionLogStore.ets
├── SshShellIntegrationPolicy.ets
├── SshNotificationService.ets
└── SshArkWebBridgePolicy.ets
```

最终目录名应与项目既有命名规范对齐；执行 M0 时先用 `rg` 复核相邻模块，不机械创建全部空文件。

### 13.2 预计修改

- `entry/src/main/ets/pages/SshTerminal.ets`：兼容入口、逐步委托到 WorkspaceShell。
- `entry/src/main/ets/components/SshXtermSurface.ets`：Search bridge、WebMessagePort flag、生命周期。
- `entry/src/main/resources/rawfile/ssh-terminal/index.html`：搜索 API、消息端口和 shell integration 解析。
- `entry/src/main/ets/services/SshTerminalTabStore.ets`：适配 tab/runtime 身份边界。
- 当前 SFTP/transfer/background/notification 服务：只增加工作台 adapter，不复制引擎。
- `EntryAbility.ets` 和 module 配置：仅在通知、多窗口或系统能力确实要求时最小修改。
- 对应 `entry/src/test/` 和 `entry/src/ohosTest/` 注册文件。

禁止顺手修改 Moonlight、RDP、RustDesk 或 VNC 文件。

## 14. 分阶段实施计划

所有阶段遵循：读门禁 → 建独立 task branch → 小步实现 → 单元测试 → 两项 Hvigor 门禁 → 只审本阶段增量 → 修复 → commit。后续阶段不得建立在未通过门禁的前一阶段之上。

### S0：SSH 当前基线、复用清单与非回归契约（立即执行，2–4 天）

目标：不改变用户路径，先冻结现有 SSH 能力、所有权、测试入口和可复用实现，防止后续重写已有能力或影响其他协议。

交付：

- SSH 页面、组件、服务、native/N-API、rawfile、测试和 feature flag 的范围清单。
- 认证、Host Key、ProxyJump、locale、标签、终端渲染、SFTP、转发、后台、独立窗口的非回归契约。
- “复用 / 包装 / 延后 / 禁止重写”矩阵，以及跨模块文件最小 allowlist。
- 当前模拟器 HDC UI 基线：手机/PC 可达路径、焦点、窗口、键盘、SFTP 和错误态截图/日志索引。
- S0 执行账本，记录每个后续阶段的输入、输出、构建 receipt 和 reviewer 结论，避免重复审查循环。

验收：

- 不修改非 SSH 业务行为；所有共享文件改动均有必要性和 smoke 证据。
- 当前双 Hvigor 门禁通过；可用 SSH 测试主机完成连接/退出/独立窗口 smoke。
- 已有实现均有明确复用点，M0 不创建重复 Store、Renderer、SFTP 或认证状态机。

### SSH-U0：SSH 独立 API 26 工具链与能力门禁（1–2 周，可与 S0/M0 的纯策略工作并行）

目标：为 SSH 工作台建立真实 API 26 编译与设备证据，不混入全 App UI 改版。

交付：

- 安装并冻结 DevEco、API 26 SDK、toolchain、target/compatible 决策和全仓兼容 smoke。
- 交付 SSH 自己的 `SshWorkspaceCapabilityPolicy`、API 26 allowlist、Beta watchlist 和 fallback 矩阵。
- 验证终端、ArkWeb、Workspace、SFTP、键鼠、通知和多窗口所需声明；不创建全 App UI primitives。

测试：

- 在明确解析到 API 26 工具链时执行两项 Hvigor 和设备 smoke。
- 追加 native 双 ABI、N-API、ArkWeb、后台、通知、窗口、文件和网络 smoke。

验收：

- 实际 API 26 SDK 声明可检索，target/compatible、设备覆盖、adapter 和 rollback 已落盘。
- SSH-U0 未闭环时不得提交 API 26-only import；但 S0、M0 纯策略和当前 API 可表达的功能可继续推进并保持 flag 关闭。
- 不以全 App UI 计划的状态作为本阶段通过或失败条件。

### G0：API 26 新设计与体验原型门禁（3–5 天）

目标：在不改业务行为前，证明 API 26 新设计组件、响应式能力和关键交互在真实目标设备可用。

交付：

- API 26 allowlist/denylist 检查表，记录每个 HDS/ArkUI import、modifier、enum 的 `@since`、Beta、SysCap 和设备范围。
- 独立样例验证 HdsNavigation、HdsSideBar、HdsVisualComponent、`hdsEffect/hdsMaterial` 或目标 SDK 最终 material API、DynamicLayout、ContainerReader、RowSplit/ColumnSplit、keyboardShortcut、drag/drop 和 WebMessagePort。
- 对沉浸光感、光随指动、光线勾勒、形变、可变字体建立“正常 / 减少动效 / 高对比 / 低功耗 / 不支持”五态视觉矩阵。
- 验证 terminal cell surface 保持不透明、固定字符网格，所有新效果只作用于 chrome。
- 手机、折叠屏、平板、PC 线框与交互说明；确认 360vp PC 自由窗口退化策略。
- 终端焦点与全局快捷键冲突表。

验收：

- API 26 compile 与手机、大屏/折叠、PC/2in1 样例通过。
- 无未核验包名、Beta modifier 或禁用 API 偷渡。
- 材质/动效不降低文本对比度，不造成持续 GPU 动画或终端输入卡顿。
- 对不支持的 HDS/Material/Window 能力有静态 ArkUI/单窗口降级。

### M0：兼容壳、纯策略与可观测性（1–2 周）

目标：降低大页面耦合，不改变用户可见行为。

交付：

- 抽取 `SshWorkspacePolicy`、immutable snapshot、action/error 类型。
- 建立 `SshWorkspaceRuntimeStore`，明确 tab/session/channel/generation 所有权。
- 建立 `SshWorkspaceCapabilityPolicy`、`SshLayoutPolicy` 和 `SshTerminalStylePolicy`；只依赖稳定系统事实和 SSH 设置。未来如消费全 App 只读主题快照，必须经 SSH adapter，不直接依赖其组件实现。
- 新建 WorkspaceShell 薄壳，默认 feature flag 关闭。
- 为现有连接、标签、SFTP、转发生命周期添加低频结构化诊断，不记录敏感内容。

测试：

- tab/session owner 不重复释放。
- generation fencing 丢弃旧回调。
- feature flag 关闭时 UI/连接行为与基线一致。
- snapshot 不含 handle/secret/output。
- effect/layout adapter 的 API 26 与 static fallback 产生相同语义树、焦点顺序和命中区域。

验收与回滚：

- 两项 Hvigor 门禁通过。
- 旧页面作为完整回滚路径保留。
- 连接、重连、前后台、PiP、SFTP、转发回归通过。

### M1：终端搜索、Profile 与快捷键路由（1–2 周）

目标：先交付低风险、高频使用价值。

交付：

- SearchAddon ArkTS UI/bridge。
- Terminal Profile 实体、合并策略和旧设置迁移。
- API 26 Phone/Tablet 可使用 `HdsColorPicker` 编辑主题色，PC 和不支持设备走等价 Picker；保存结果只进入 Profile，不进入系统收藏的未授权范围。
- `SshShortcutPolicy` 与焦点优先级。
- 手机输入附件 Profile 化；PC hover/tooltip/accessibility label。

测试：

- 搜索前后项、大小写、正则失败、reload 后搜索。
- Profile global/host/session 合并和坏值钳制。
- 快捷键冲突、终端保留键、IME/文本输入优先级。
- API 26 真机物理键盘与手机软键盘；若 compatible 保留旧版本，再验证旧设备 static fallback。

验收：

- 搜索不污染远端输入和命令历史。
- Ctrl+C/V 等不被全局错误截获。
- flag 关闭恢复当前 UI。

### M2：命令面板和浏览器式会话标签（2–3 周）

目标：建立工作台的快速导航和会话管理骨架。

交付：

- Command Registry/Palette，支持主机、会话、动作搜索。
- 自定义 Tab Strip：关闭、固定、排序、状态、右键/长按菜单。
- API 26 Tab chrome 使用语义材质 token、光随指动/拖动形变和静态 fallback；标签文本与关闭命中框不参与形变。
- 手机标题会话切换器；平板/PC 顶部标签。
- 标签拖动只改变 UI/runtime 映射，不重建连接。

测试：

- 关闭活动/后台/断线标签。
- 快速连续开关、排序、固定、恢复焦点。
- 搜索 ranking 稳定且不可用动作不会执行。
- 窄窗下动作可达、不会裁切关闭/断开按钮。

验收：

- 20 个标签仍可操作，溢出有滚动/列表入口。
- 标签重排不丢输出、不重连。
- 危险动作语义明确。

### M3：SFTP 一等标签与传输中心（2–3 周）

目标：把文件工作流纳入工作台。

交付：

- `SshSftpPane` 手机单栏、平板/PC 双栏。
- SFTP 标签与 terminal 标签切换。
- Transfer Center 全局入口与任务过滤。
- UDMF/Core File Kit 拖放 adapter；传输引擎保持单一实现。

测试：

- 本地↔远端、远端↔远端、批量、暂停/恢复/重试。
- 外部文件 URI、无权限、目标冲突、覆盖和取消。
- 标签关闭/窗口变化时任务继续与状态同步。
- 大文件、目录、多选拖放和网络切换。

验收：

- 任何 UI 退出不制造幽灵任务或重复上传。
- 通知不泄露真实路径/主机。
- 不回归现有传输完整性门禁。

### M4：可持久工作区、分屏和焦点模式（3–5 周）

目标：形成真正的多会话工作台。

交付：

- Workspace RDB schema、migration、store。
- Pane tree 横/纵分裂、比例调整、跨 Pane 移动、焦点模式。
- API 26 `DynamicLayout` 驱动的 sm/md/lg/xl 响应式壳，局部 `ContainerReader` policy 与折叠/展开连续性。
- 恢复未连接占位和手动批量重连。

测试：

- Pane tree 的 split/merge/move/close property tests。
- ratio/min size/最大可见 Pane。
- schema 升级、坏记录隔离、断电/写失败恢复。
- 手机↔展开态↔PC 窗口变化，不重复创建 session。
- 工作区恢复不自动发送命令。

验收：

- 4 Pane、20 标签、跨断点切换稳定。
- 应用冷启动 500ms 内展示工作区壳和占位（不含网络连接）。
- 旧页面/旧数据可回退。

### M5：Snippet、历史、启动配置与本地补全（3–5 周）

目标：降低重复操作成本，同时建立可信敏感边界。

交付：

- Snippet Store/Picker/变量表单/预览。
- host/group/global 作用域和启动命令。
- shell integration 最小协议（OSC 133/633 能力协商与解析）。
- 本地命令历史、搜索和历史/Snippet 补全。

测试：

- secretRef 不进入日志、历史、snapshot、Crash 输出。
- shell marker 分片、乱序文本、恶意远端输出、tmux/screen 场景。
- 密码/raw/fullscreen 模式自动禁用 capture/补全。
- startup 仅在认证与 Host Key 完成后执行一次。

验收：

- 没有 shell integration 时安全降级，不猜测密码边界。
- 用户可全局/按主机关闭历史和补全。
- Snippet 默认只插入，执行前可见。

### M6：日志、书签和完成通知（2–4 周）

目标：提供可追溯性，但坚持 opt-in 和本地隐私。

交付：

- 加密分块日志、RDB 索引、空间/保留策略。
- 暂停、脱敏、书签、搜索和安全导出。
- shell integration 完成事件和 Notification Service。

测试：

- 崩溃/断电后 chunk 恢复和索引修复。
- 敏感态暂停、脱敏、导出临时文件清理。
- 后台、锁屏、通知权限关闭和多会话并发。
- 日志 quota、LRU/保留策略不删除固定记录。

验收：

- 默认安装不记录日志。
- 10MiB+ 日志搜索不阻塞 ArkUI。
- 通知默认不含命令、IP、用户名、远端路径。

### M7：安全广播输入（2–3 周）

目标：为运维批量任务提供可控多会话输入。

交付：

- 目标选择、持续广播状态条、安全过滤、紧急停止。
- 多行/粘贴/高风险命令确认。
- session/generation 目标快照，断线后不自动重加。

测试：

- 目标加入/移除/断线/重连/关闭竞态。
- 认证和 raw/fullscreen 模式强制排除。
- 16 Pane 压力、不同延迟、部分写失败。
- 紧急停止不向远端泄漏停止组合键。

验收：

- 广播状态在所有宽度下始终可见。
- 任一目标安全状态不明时默认不发送。
- flag 默认关闭，独立安全复核通过后才开放。

### M8：WebMessagePort 通道迁移（2–4 周）

目标：支撑多 Pane 高频终端的可测通道。

交付：

- versioned envelope、握手、sequence、ack/backpressure。
- 已接入 xterm 的 output JSON batching、应用层 ACK、输入/resize 与 native/page generation fence；控制消息继续沿用优先队列。
- output ArrayBuffer batching 保留为 API 26 设备矩阵通过后的优化，不在当前 API 23 默认路径启用。
- reload/dispose/generation fencing。
- 当前 JS proxy/runJavaScript 双栈与按设备回退。

测试：

- 10MiB burst、持续输出、Unicode 分片、二进制边界。
- reload、前后台、折叠展开、WebView 销毁竞态。
- 丢 ack、乱序、队列溢出和协议版本不匹配。
- 两条通道结果一致性对比。
- JSON 字段必须保持原生类型；超前 ACK、单帧超限和 UTF-8 字节预算溢出均 fail-closed。

验收：

- 无无限队列、无旧 generation 写入、无销毁后回调。
- 性能达到第 16 节预算。
- API 26 真机稳定后才逐步提高 flag 百分比；若 compatible 保留旧版本，再以旧设备 fallback 证据作为扩量前置。

### M9：PC 标签分离与多窗口（2–4 周）

目标：完成 PC 原生工作流，非支持设备安全降级。

交付：

- MultiWindow capability adapter。
- tab → new window / window → workspace 的所有权转移协议。
- 自由窗口标题栏、安全区和窗口状态恢复。

测试：

- 创建/关闭/崩溃/多次转移/系统回收。
- 360vp 最小窗口、分屏、最大化、多显示区域。
- 不支持多窗口时的无损降级。

验收：

- 一个 native session 始终只有一个 owner。
- 关闭旧窗口不释放已转移连接。
- 不引入新增后台连接或重复通知。

### N1：下一代 native/security 可行性（5–10+ 周，独立项目）

按 Agent、Certificate、FIDO2、PQ、Mosh 分别形成 ADR、威胁模型、兼容矩阵、原型和真机证据。没有证据前不在产品 UI 显示不可用开关。

## 15. Feature Flag 与发布策略

建议 flags：

- `sshWorkbenchV2`
- `sshHarmony7Chrome`
- `sshApi26DynamicLayout`
- `sshImmersiveLightEffects`
- `sshTerminalSearchV2`
- `sshCommandPalette`
- `sshWorkspaceSplit`
- `sshSftpTabs`
- `sshSessionLogs`
- `sshBroadcastInput`
- `sshWebMessageBridge`
- `sshDetachedWindow`

发布顺序：

1. 开发/测试构建开启，生产默认关闭。
2. API 26 指定手机、大屏/折叠和 PC/2in1 小范围 dogfood；若仍兼容 API 23，同步验证 static fallback。
3. 先开 `sshHarmony7Chrome` 的纯 token/静态层，再开 material/effect；效果异常可独立回退而不关闭工作台功能。
4. 只读/低风险能力先开：Search、Profile、Palette。
5. Workspace/SFTP 分阶段开启，监控 crash、ANR、session leak、transfer duplicate、GPU/功耗和 frame jank。
6. Logs/Broadcast/MultiWindow 单独开关并单独安全复核。
7. 任一阶段回退 flag 不应要求降级数据库；新表保留但不读取即可。

## 16. 测试、性能和质量门禁

### 16.1 纯策略单元测试

- Breakpoint → layout mode、侧栏/Inspector 可见性和宽度钳制。
- API capability → DynamicLayout/ContainerReader/material/static fallback；任何 Beta/缺失 SysCap 必须落入确定分支。
- Design token 在暗色、亮色、高对比、减少动效、低功耗和各设备密度下的完整映射。
- Pane tree split/merge/move/close、tab reorder/pin/restore。
- Shortcut routing、冲突和终端保留键。
- Profile merge/migration/clamp。
- Snippet 变量、secretRef、history capture/redaction。
- Log quota/retention/bookmark/migration。
- Web envelope sequence/generation/backpressure。
- 坏 JSON/坏 RDB item 必须逐项隔离，不清空有效数据。

### 16.2 UI/集成测试

- HDS/ArkUI 组件渲染、焦点、键鼠、hover、右键、拖放。
- HarmonyOS 7 material/effect 的 hover/press/drag/focus 生命周期、静态回退和效果销毁。
- DynamicLayout 跨算法切换保留 WebView、输入、选区、scroll anchor 和 Pane owner；ContainerReader 不产生断点震荡。
- 正常/暗色/高对比/减少动效/字体放大/低功耗 UI 截图与可读性检查。
- ArkWeb search、selection、输入、resize、reload、bridge fallback。
- native SSH 连接、重连、认证、Host Key、locale、转发和 SFTP 回归。
- 工作区冷恢复、前后台、锁屏、PiP、折叠/展开和多窗口。
- Notification/Background Task 权限拒绝与系统回收路径。

### 16.3 设备矩阵

| 类型 | 必测场景 |
|---|---|
| API 26 手机 | 竖屏/横屏、IME、物理键盘、后台/锁屏、弱网、沉浸光感/减少动效 |
| API 26 折叠屏 | 折叠↔展开、半折、焦点/选区/滚动/Pane 连续、材质跨形态连续 |
| API 26 平板 | 分屏、多窗口、键鼠、双栏 SFTP、拖放、ContainerReader 局部降级 |
| API 26 PC/2in1 | 360vp 最小自由窗口、常规/最大化、键鼠、hover、右键、外部文件拖放、标题按钮避让 |
| API 23 旧设备 | 仅当 `compatibleSdkVersion` 保留 23 时强制；安装/启动/核心 SSH/static fallback |
| API 24 中间版本 | 仅当兼容范围包含 24 时验证 DynamicLayout 与 API 26 effect 缺失降级 |

### 16.4 性能预算

- ArkUI 主线程中单次工作块目标 `<= 8ms`，硬门槛不持续超过 `16ms`。
- 输入 admission（进入 native/bridge 队列）参考设备 p95 `<= 8ms`、p99 `<= 16ms`，不把网络 RTT 计入。
- retained tab 切换到可见终端目标 `<= 250ms`。
- 冷恢复工作区壳和占位目标 `<= 500ms`，不含网络连接。
- 终端 resize 合并窗口 `50–100ms`，稳定后最终 PTY size 必达。
- 10MiB burst 输出不得 OOM，不得出现由应用造成的连续 `>100ms` UI 卡死。
- 高频 output 不进入 `@State/@Trace`；UI 统计更新频率不高于必要的 4–10Hz。
- 日志索引、加密和大目录排序不得阻塞 ArkUI 线程。
- 光随指动、流光、形变在 terminal 高输出时自动降级或停止，不与 renderer 抢持续帧预算。
- 新 chrome 与效果相对静态基线不得造成可感知输入延迟回退；G0 建立 CPU/GPU/frame/power 基线，具体阈值以 API 26 参考设备实测冻结。
- 无 pointer/press/transition 时不得存在仅为装饰持续运行的动画或帧请求。

### 16.5 强制构建门禁

任何代码、ArkTS、native、Rust、测试、配置或流程文件改动完成前，必须运行并记录：

```sh
source scripts/macos_env.sh
hvigorw --mode module -p module=entry -p product=default default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon
hvigorw --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --no-daemon
```

随后必须进行仅针对本阶段增量的复核。真机要求不能用上述构建结果替代。

U0 完成后，`scripts/macos_env.sh` 和构建日志必须明确解析到已冻结的 API 26 SDK/toolchain；如果仍实际使用 API 24 或 API 23，即使命令退出 0 也不构成 API 26 门禁通过。若继续支持旧 compatible 版本，还要保留相应旧设备运行门禁。

## 17. 可观测性与问题定位

结构化事件仅记录非敏感元数据：

- workspace/tab/pane action ID、结果和耗时。
- sessionId 的随机本地短 ID，不记录 host/user/IP。
- generation、queue depth、bridge protocol、batch bytes、dropped stale messages。
- transfer task 本地 ID、方向、字节数、错误类别；不记录路径。
- layout mode、window size bucket、focus owner。

禁止记录：终端输入/输出、命令、URL query、密码、Key、MFA、host/IP、远端路径、Snippet 解引用值。

关键告警指标：

- native session owner 重复/泄漏。
- stale generation message 非零执行数。
- Web bridge queue 超限/重载率。
- 工作区 migration 失败率。
- SFTP 重复任务/校验失败率。
- UI freeze/ANR、WebView crash、后台任务意外终止。

## 18. 风险、依赖与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| API 26 仍处 Beta、网页与最终 SDK 可能变化 | 预写接口失效或行为改变 | U0 安装目标 SDK，G0 查 `.d.ts`/release notes，Release 前二次冻结 |
| target 26 与 compatible 最低版本未决定 | fallback 设计、设备覆盖和测试范围漂移 | U0 形成显式产品决策与兼容矩阵，不让各组件自行判断 |
| API 26 SDK 本机缺失、当前默认仅 API 24 | 无法证明任何 API 26 编译结论 | 把 SDK/DevEco 安装作为硬 blocker，旧 SDK PASS 不算目标门禁 |
| 大页面直接 V2 重写 | 生命周期/连接回归面过大 | V1 兼容壳，V2 叶组件，M4 后再评审根迁移 |
| 多 Pane 放大 WebView/内存成本 | OOM、卡顿、后台回收 | 最多 4 可见 Pane、retention policy、M8 通道与压力测试 |
| DynamicLayout/ContainerReader 切换引发 WebView 重建或震荡 | 连接/选区/输入丢失、反复布局 | 统一 LayoutPolicy、稳定 key/owner、G0/M4 跨算法生命周期压力测试 |
| 沉浸光感、流光和形变占用持续帧 | 终端输入掉帧、功耗上升 | chrome-only、事件期动画、输出高压自动降级、静态 flag 回滚 |
| 材质降低暗色终端 chrome 对比度 | 状态和动作不可读 | 语义 token、对比度门禁、高对比/纯色 fallback，不从 ANSI 色取样 |
| shell integration 被远端伪造 | 错误历史/通知/敏感泄漏 | 能力协商、严格解析、只作辅助、敏感态关闭 |
| 日志泄密 | 高危隐私事件 | 默认关、本地加密、自动暂停、配额、导出确认 |
| 广播误操作 | 多主机破坏 | 默认关、目标常显、危险确认、紧急停止、断线不重加 |
| 多窗口 session 双 owner | 重复释放/幽灵连接 | 显式转移协议、generation fencing、能力降级 |
| SFTP 拖放 URI/覆盖语义复杂 | 数据丢失 | 类型/权限/目标确认、临时文件、原子替换 |
| 云同步扩张 | 数据归属/兼容风险 | 工作区生产力数据首期 local-only，另立同步 ADR |

外部 blocker：API 26 SDK/DevEco/toolchain、HarmonyOS 7 手机、折叠屏/平板、PC/2in1 或官方云真机，真实 SSH/SFTP/代理/跳板测试主机，以及通知/后台权限和多窗口能力。若兼容版本保留 23，还需要 API 23 真机。缺少这些条件时只能记录为 blocker，不能宣称端到端完成。

## 19. 里程碑与粗略工作量

以下是单个熟悉仓库的工程师在依赖稳定时的数量级估算，不是交付承诺：

| 里程碑 | 阶段 | 估算 |
|---|---|---:|
| Baseline freeze | S0 | 2–4 天，立即执行 |
| SSH platform uplift | SSH-U0 | 1–2 周，独立 SSH 工具链任务 |
| Design/API proof | G0 | 3–5 天 |
| Foundation | M0 | 1–2 周 |
| Fast productivity | M1 + M2 | 3–5 周 |
| File workbench | M3 | 2–3 周 |
| Workspace core | M4 | 3–5 周 |
| Productivity data | M5 + M6 | 5–9 周 |
| Advanced operations | M7 + M8 | 4–7 周 |
| PC native windowing | M9 | 2–4 周 |
| Native next generation | N1 | 5–10+ 周，独立评估 |

S0 是所有工作的硬前置；SSH-U0 只硬阻断 API 26-only import 和最终 API 26 发布，可与 M0 纯策略并行。M0 是工作台共同前置；M3 在 M2 的 Tab 模型稳定后开始；M5/M6 可在 M4 schema 稳定后部分并行；M8 可先做实验，但生产迁移必须等 M2/M4 多 Pane 压力场景存在。单人完成 S0–M9 的现实范围约 4.5–7.5 个月，团队可在 SSH 工具链、数据、SFTP、ArkWeb 通道四条线并行，但每条线仍需统一 capability、Controller 和实体契约。

## 20. 完成定义

只有同时满足以下条件，才能把“SSH Termius 化工作台”标记完成：

1. 手机、折叠屏、平板、PC 四类布局符合本计划，最小窗口无不可达动作。
2. 工作区、标签、分屏、Palette、Search、Profile、SFTP、Snippet/历史、日志/书签均达到各阶段验收；Broadcast/MultiWindow 若未交付必须明确保持 flag 关闭，不能暗示已完成。
3. 当前 SSH 认证、Host Key、重连、终端输入/输出、转发和 SFTP 无回归。
4. API 26 SDK 编译与 API 26 目标设备证据齐全；所有 Beta/可选 API 有 adapter、fallback 或明确的 API26-only 决策；若 compatible 保留旧版本，再补相应旧设备证据。
5. 日志、历史、通知、Snippet secret 和工作区恢复通过隐私/安全复核。
6. 无障碍、键鼠、IME、折叠/窗口变化和后台生命周期测试通过。
7. 两项 Hvigor 门禁逐阶段通过，review receipt 与实际 HEAD/范围匹配。
8. feature flag 回滚、数据 migration/backup、故障恢复路径已验证。
9. 文档、用户设置说明和迁移提示同步完成。

## 21. 每阶段执行清单

开始前：

- 读取根/项目 `AGENTS.md`、`CURRENT.md`、`QUEUE.md`。
- 运行 `scripts/sync_workspace.sh status`。
- 不读取、评价或覆盖其他任务的未提交范围；共享脏工作树中只能推进可证明隔离的 SSH 范围，不能据此混合提交。
- 从最新 `main` 创建一个且仅一个 SSH task branch。
- 复核本阶段涉及的实际 API 26 `.d.ts`（若已安装）、SSH allowlist、现有服务和测试注册计数。

实现中：

- 一次只实现本阶段范围，不顺手重构其他协议。
- 纯策略优先，UI 组件只发送语义事件。
- native/session 所有权和 generation 明写在测试中。
- 新持久数据先做 schema/migration/坏记录隔离。
- 新能力必须同时提供键鼠、触控和无障碍入口。
- 每个高风险能力带独立 flag。

完成前：

- 运行相关单元/ohosTest。
- 运行两项强制 Hvigor 门禁。
- 按设备矩阵完成本阶段真机验证。
- 检查敏感日志、权限、通知和临时文件。
- 仅审本阶段增量，修复 finding 后重跑门禁。
- commit、更新状态记录，再进入下一阶段。

## 22. 产品参考与官方资料

### HarmonyOS 官方

- [HarmonyOS Design](https://developer.huawei.com/consumer/cn/design)
- [HarmonyOS 开发文档中心](https://developer.huawei.com/consumer/cn/doc/)
- [ArkUI](https://developer.huawei.com/consumer/cn/arkui/)
- [ArkTS](https://developer.huawei.com/consumer/cn/arkts/)
- [UI Design Kit ArkTS 组件索引](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/ui-design-arkts-component)
- [Navigation 与 NavDestination](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/arkts-navigation-navdestination)
- [HarmonyOS 6.1 工具栏设计](https://developer.huawei.com/consumer/cn/doc/doccenter-ux-design/toolbar-0000001929683232)
- [大屏 UX 指南](https://developer.huawei.com/consumer/cn/doc/doccenter-ux-design/ux-guidelines-large-screen-0000001807707561)
- [多设备屏幕布局最佳实践](https://developer.huawei.com/consumer/cn/doc/best-practices/bpta-multi-device-screen-layout)
- [折叠屏 UX 指南](https://developer.huawei.com/consumer/cn/doc/doccenter-ux-design/ux-guidelines-foldable-screen-0000001807866557)
- [沉浸式窗口最佳实践](https://developer.huawei.com/consumer/cn/doc/best-practices/bpta-multi-device-window-immersive)
- [PC 应用入口](https://developer.huawei.com/consumer/cn/multidevice/pc/get-started/)
- [应用与网页数据通道](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/web-app-page-data-channel)
- [拖拽事件与属性](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ts-universal-attributes-drag-drop)
- [Socket 连接指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/socket-connection)
- [应用规划与核心能力](https://developer.huawei.com/consumer/cn/app/planning)

### Termius 产品基准

以下只用于分析工作流与能力差距，不作为复制其品牌/界面的授权：

- [Termius 产品主页](https://www.termius.com/)
- [Workspaces: focus without losing context](https://termius.com/blog/workspaces-focus-without-losing-context)
- [Broadcast input](https://termius.com/blog/broadcast-input)
- [New touch terminal on iOS](https://termius.com/blog/new-touch-terminal-on-ios)
- [Rethinking SFTP for mobile](https://termius.com/blog/rethinking-sftp-for-mobile)
- [Session log bookmarks](https://termius.com/blog/remember-what-was-done-with-bookmarks-for-session-logs)
- [Auto reconnect](https://termius.com/blog/stay-connected-with-auto-reconnect)
- [Autocomplete: Helium vs Hydrogen](https://termius.com/blog/autocomplete-helium-vs-hydrogen)
- [SSH ID / passkeys](https://termius.com/blog/ssh-id-passkeys-for-ssh)
- [Post-quantum cryptography](https://www.termius.com/blog/post-quantum-cryptography)

## 23. SSH 独立计划第一张可执行任务卡

本计划不等待全 App UI 阶段。第一张任务卡立即从当前可运行基线开始：

> **SSH-WB-S0 — 当前 SSH 基线、复用边界与非回归契约冻结**

范围仅包括：

1. 盘点并链接已有 SSH 认证、Host Key、终端渲染、Tab、SFTP、转发、后台和独立窗口实现，形成禁止重复实现清单。
2. 冻结 `SshWorkspaceSnapshot`、`SshWorkspaceAction`、`SshRuntimeSessionRef`、session owner 和 generation 契约草案。
3. 建立 SSH-only 文件 allowlist、共享文件例外规则和非 SSH smoke 清单。
4. 通过 HDC 记录当前手机/PC UI、键盘焦点、窗口与错误态基线。
5. 不改变现有 SSH 用户路径，不迁移数据，不开启生产 flag，不修改全 App UI。

完成证据：当前双 Hvigor 门禁、模拟器 HDC 基线、范围/复用矩阵、契约测试清单和一次只审 S0 增量的 review receipt。S0 未通过前不得进入 M0；API 26 专属证据由 SSH-U0/G0 独立补齐。
