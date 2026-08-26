# RemoteDeskHarmonyOS 全应用 HarmonyOS 7 / API 26 UI 升级实施计划

> 状态：PLANNED_NOT_STARTED / INDEPENDENT_TRACK / API26_SDK_PENDING
> 类型：全应用 UI 独立实施计划 / 文档落盘，不代表功能已经实现
> 编制日期：2026-08-19
> 编制基线：348b28083（codex/moonlight-complete-upgrade）
> 当前产品基线：HarmonyOS 6.1 / targetSdkVersion 23；本机另有 DevEco 内置 API 24 SDK
> 目标产品基线：HarmonyOS 7 / API 26；官方当前公开资料为 26.0.0 Beta2，本机尚未安装 API 26 SDK
> 实施分支：尚未创建；必须等待当前任务闭环后，从最新 main 新建独立 codex/<task> 分支
> 计划权威：本文件统一管理非 SSH 工作台范围的全 APP 设计语言、UI 架构、导航、响应式、公共组件、迁移顺序和验收门禁
> 交付隔离：与 SSH Termius 化计划平行实施；不得共享实现分支、里程碑、feature flag、代码提交或完成判定
> 代码变更：本次只新增和校正文档，不修改 ArkTS、native、Rust、配置或测试代码

## 0. 执行结论

本次升级把 RemoteDeskHarmonyOS 的应用壳、公共组件和非 SSH 页面建设成一套面向 HarmonyOS 7 的 UI 平台。SSH Termius 化不再是本计划的子项目：它由独立计划、独立分支、独立 feature flag 和独立验收推进。本计划只定义 SSH 与 AppShell 之间的最小入口/返回/状态/主题接口，不实现 SSH 工作区、终端、SFTP 或生产力功能，也不把 SSH 里程碑计入本计划。

产品目标分为三层：

1. 平台层：完成 API 26 工具链升级，建立 AppDesignTokens、AppCapabilityPolicy、AppLayoutPolicy、AppNavigationGraph、AppVisualEffectAdapter 和公共 UI 组件目录。
2. 应用层：重建全局 AppShell、信息架构、页面 Scaffold、搜索、列表、表单、Sheet、Dialog、SnackBar、空态和错误态，并覆盖手机、折叠屏、平板和 PC。
3. 协议层：在不重写协议内核的前提下，迁移 RDP、RustDesk、VNC 和后续 Moonlight 的配置体验与会话 chrome；SSH 仅保留稳定集成边界，由 SSH 独立计划负责内部 UI。

HarmonyOS 7 的沉浸光感、光随指动、光线勾勒、受控非线性形变和可变字体用于表达空间、焦点和反馈，不作为全屏滤镜。新 UI 必须“看起来属于 HarmonyOS 7”，同时仍是一款专业远程工作工具：远程内容永远优先于 chrome，关键动作永远可预测，连接状态永远可辨认，键鼠和触控都能完整操作。

API 26 当前仍处公开 Beta 阶段，本机没有 API 26 SDK。因此计划先设置 U0 平台升级门禁：安装并冻结实际 SDK、阅读对应 release notes 和 .d.ts、决定 compatibleSdkVersion，再允许任何 API 24–26 import 进入产品代码。网页上的类型名只能作为候选清单，不能替代本地 SDK 证据。

## 1. 计划层级与边界

### 1.1 平行计划与接口关系

本文件是全应用 UI 升级的独立计划，负责：

- HarmonyOS 7 视觉与交互原则。
- API 26 能力采用和降级策略。
- 全局 token、公共组件、导航、窗口与响应式架构。
- 页面和协议模块的迁移顺序。
- feature flag、测试矩阵、性能预算、发布和回滚。

以下文档是平行计划或纵向正确性计划，不从属于本文件：

- docs/codex/plans/2026-08-19-ssh-termius-harmonyos7-api26-workbench-plan.md：独立的 SSH 工作区、终端生产力和 SFTP 计划。
- docs/SSH_MODULE_UPGRADE_PLAN_V2.md：SSH native、认证、连接与 SFTP 基础正确性。
- docs/superpowers/plans/2026-07-01-ssh-terminal-open-source-parity.md：终端行为与开源终端能力对齐。
- docs/codex/plans/2026-08-08-ssh-proxy-forwarding-sol-plan.md：SSH 代理、跳板和端口转发。
- 现有 RDP、RustDesk、VNC、Moonlight 计划：继续负责各自协议、native、编解码、输入和会话生命周期正确性。

发生冲突时：

1. 安全、协议和数据正确性优先。
2. 非 SSH 的全应用 token、导航、布局、公共组件和 UI 门禁以本文件为准。
3. SSH 工作台内部实体、视觉 token、终端和 SFTP 工作流以 SSH 独立计划为准。
4. 最终以项目 AGENTS.md、目标 SDK 的实际声明和当时的官方 release notes 为准。

两条计划只通过版本化接口协作：AppShell 提供 SSH 入口、返回目标、主题/字体缩放只读快照、窗口上下文和低频会话状态槽；SSH 返回不含 secret 的导航与任务状态。任一计划不得直接依赖另一计划尚未交付的组件目录，也不得以“顺手统一”为由跨范围修改。

### 1.2 本计划包含

- 引导、登录、主密码设置和锁屏。
- AppShell、首页、主机库、分组、搜索、收藏、最近使用和状态聚合。
- RDP、RustDesk、VNC、SSH、Moonlight 的新增、编辑、详情、设置和连接前流程。
- 密钥库、SSH Key、证书、TOTP、密码和安全提示。
- 账号、云同步、主题、外观、安全、关于、反馈和隐私设置。
- RDP/RustDesk/VNC 的远程会话 chrome。
- SSH 入口、返回、低频状态和主题快照的薄集成契约；不包含 SSH 工作台内部实现。
- Moonlight 主机、应用目录、设置和串流 chrome 的未来 UI 迁移。
- 传输中心、日志、诊断、错误恢复、空态、加载态和通知反馈。
- 手机、折叠屏、平板、PC、自由窗口、分屏、键鼠、触控和无障碍。

### 1.3 本计划不包含

- 无缺陷证据情况下重写协议内核、密码学、编解码器或连接状态机。
- 复制其他产品的品牌、素材、文案或 trade dress。
- 在本次文档任务中安装 SDK、修改 build-profile、改代码、运行迁移或提交 Git。
- 在当前未闭环 Moonlight 工作树上叠加 UI 实现。
- SSH 工作区、Tab/Pane、终端 Profile、Command Palette、Snippet、历史、日志、SFTP、ArkWeb 通道或 SSH 多窗口实现。
- 在同一分支、commit、PR 或阶段内同时实施本计划与 SSH 计划。
- 把 HarmonyOS 7 动效强加到远程视频、终端字符 Cell、密码输入或高频性能路径。

### 1.4 Moonlight 隔离规则

本计划覆盖最终全 APP，因此 Moonlight 不能永久排除；但当前 Moonlight 改动不属于本次工作范围。

- 本次只列出 Moonlight 未来需要继承的全局 token、AppShell、公共 Sheet/Dialog 和会话 chrome 契约。
- 不读取、不评价、不修改当前 Moonlight dirty diff。
- Moonlight UI 迁移必须等当前 Moonlight 任务完成、提交、复核并合并到 main 后，再从干净基线单独排期。
- 若父平台组件与 Moonlight 已有组件发生冲突，以适配器和渐进迁移解决，不在脏工作树里顺手重构。

## 2. 官方能力依据与事实边界

### 2.1 HarmonyOS 7 新设计方向

官方 HarmonyOS 7 能力页和设计中心给出的方向包括：

- 沉浸光感材质扩展到更多场景。
- 光随指动和光线勾勒用于表达可交互性、焦点和空间关系。
- 受控非线性形变用于短时按压或转场反馈。
- HarmonyOS Sans 可变字体用于更连续的字重、宽度和层级变化。
- 手机、折叠屏、平板和 PC 之间强调结构连续，而不是把同一页面机械拉伸。
- PC 强调自由窗口、键鼠、hover、窗口标题区和高信息密度。

项目采用这些方向时必须遵守三个边界：

1. 材质表示层级，不是装饰贴图。
2. 动效表示因果，不是持续抢占注意力。
3. 远程内容、终端字符、密码和密钥内容属于“无效果区”。

### 2.2 API 26 候选能力

下表是 U0 要在实际 API 26 SDK 中验证的候选清单，不是当前代码可直接使用的 allowlist。

| 能力 | 计划用途 | 当前决策 |
|---|---|---|
| HdsNavigation / HdsNavDestination | AppShell 页面级导航与标题区 | 候选；先核对 API、路由保存和 PC 行为 |
| HdsSideBar / HdsSideMenu | 平板与 PC 主导航、工具导航 | 候选；必须支持折叠、键盘焦点和无障碍 |
| HdsTabs | 少量固定一级分类 | 可复用；不承担动态远程会话标签 |
| HdsActionBar | 上下文动作 | 候选；避免与底部一级导航竞争 |
| HdsListItem / HdsListItemCard | 设置、主机和资源列表基元 | 候选；业务状态和密度仍由项目 token 控制 |
| HdsSnackBar | 非阻断反馈与可撤销动作 | 候选；错误升级规则由 AppFeedbackPolicy 统一 |
| HdsVisualComponent | HarmonyOS 7 视觉和材质承载 | API 26 SDK spike 后决定 |
| HdsColorPicker | 主题、终端 Profile、远程画质色彩设置 | API 26 候选；旧版本保留静态 picker |
| hdsEffect / hdsMaterial | 按压、hover、描边和材质 | 必须包在 AppVisualEffectAdapter 后 |
| hdsDrawable / symbolRegister | 图标与可缩放 drawable | 候选；优先官方 Symbol，再用自有矢量 |
| DynamicLayout | 同一子树跨布局算法切换并保留状态 | API 24+；目标 API 26 采用，先做生命周期 spike |
| ContainerReader | 组件按自身容器响应 | API 26 SDK 验证；不直接替代窗口拓扑 |
| LazyDynamicLayout / LazyLayoutAlgorithm | 大型自适应列表和异构布局 | API 26 Beta 候选；仅在性能证据成立时采用 |
| SelectionContainer | 日志、诊断、终端辅助文本的选择 | API 26 Beta 候选；终端主选区仍走终端引擎 |
| Accessibility 自定义焦点顺序 | PC、折叠屏和复杂工作台焦点环 | API 26 候选；必须有语义测试 |
| MultiWindowEntryInAPP | PC 分离窗口入口 | 只做可行性 spike；连接所有权必须唯一 |

### 2.3 当前仓库和本机事实

- 项目当前 targetSdkVersion 与 compatibleSdkVersion 基线是 API 23。
- /Users/mydestiny/Library/OpenHarmony/Sdk 当前只有 API 23。
- DevEco Studio 内置默认 SDK 当前为 HarmonyOS 6.1.1 / API 24。
- 本机没有 API 26 SDK，因此今天不能冻结 API 26 import、modifier、系统能力或最终降级方式。
- docs/codex/DECISIONS.md 当前明确禁止无依据引入 API 26 能力；U0 完成后必须用新 ADR/decision 正式更新，而不是绕过。
- 当前 Theme.ets 已有 Palette、明暗模式、间距、圆角、字体、布局和动效雏形。
- 当前 BreakpointUtil.ets 已有 sm/md/lg/xl、设备类型和折叠状态，不应另建一套互相竞争的全局断点。
- HostListPage 和 FeedbackSettingsSheet 已使用部分 HDS 组件，说明迁移应复用已有经验而非重新发明。

### 2.4 U0 必须作出的兼容决定

升级 targetSdkVersion 到 26 不等于自动决定最低兼容版本。U0 必须在产品、分发和测试证据基础上二选一：

| 方案 | compatibleSdkVersion | 优点 | 成本 |
|---|---:|---|---|
| A：保留旧设备 | 23 或经产品确认的旧版本 | 覆盖现有设备 | 所有 API 24–26 UI 必须可链接降级；测试矩阵显著扩大 |
| B：同步提升最低版本 | 26 | 架构简单，完整使用新 UI | 放弃旧设备，需明确发布和用户迁移影响 |

在决定落盘前：

- 不得假设新 API 可以用简单 if 判断安全加载。
- 不得在旧系统可达路径静态引用无法解析的类型。
- 不得把 API 23 static fallback 写成永久架构，除非方案 A 被正式选择。
- API 23 继续作为当前行为回归基线，但不是新设计上限。

## 3. 全应用 UI 现状盘点

### 3.1 页面与主要领域

当前主要页面包括：

- GuidePage.ets：首次引导。
- LoginPage.ets：登录。
- MasterPasswordSetupPage.ets：主密码创建和安全入口。
- HostListPage.ets：首页、主机、密钥库、设置及大量资源流程的聚合壳。
- KeyVaultPage.ets：密钥库内容。
- RustDeskRelayPage.ets：RustDesk Relay 配置。
- VncSettingsPage.ets：VNC 设置。
- RemoteDesktop.ets：RDP/RustDesk/VNC 远程会话主页面。
- SshTerminal.ets：SSH 终端工作台。
- MoonlightHostDetailPage.ets、MoonlightAppCatalogPage.ets、MoonlightSettingsPage.ets、MoonlightStreamPage.ets：Moonlight 领域页面。

路由清单与实际 @Entry/内嵌页面需要在 P1 做一次一致性审计。当前 main_pages.json、router 调用和内嵌页面不完全等价，不能只凭文件名迁移。

### 3.2 公共组件簇

现有组件已覆盖：

- 通用：AboutSettingsSheet、ColorPickerSheet、FeedbackSettingsSheet、GlassmorphicCard、HostCard、LockGate、QR 扫描。
- 密钥与 2FA：SshKeyCard、SshKeyInstallSheet、SshKeyManagerSheet、TotpCodeCard、TotpProgressBar。
- 添加资源：HostAddWizardSheet、HostProtocolPicker、RdpAddFlow、RustDeskAddFlow、SshAddFlow、VncAddFlow、MoonlightHostAddFlow。
- 资源管理：ResourceFabPicker、VncGatewayAddFlow、ModernKeyVaultAddFlow、RustDeskRelayConfigPasteSheet。
- 会话 chrome：RemoteSessionTopBar、RemoteModifierHandle/Panel、RemoteShortcutSurface、VirtualKeyBar、VncSessionToolbar、MoonlightSessionToolbar、控制中心、控制器 overlay、连接阶段 overlay。
- SSH 渲染：SshTerminalSurface、SshXtermSurface、TerminalEmulator、GpuTerminalRenderer。
- 设置与弹层：VncSettingsSheet、VncTrust、SshForwardingSheet、SshProxyEditor、VncSheetScaffold、RightPanelDialog、WarningCountdownDialog。

这些组件不是全部废弃。P0 会把它们分为：

1. 可直接收编到公共设计系统。
2. 保留业务层、替换视觉壳。
3. 仅服务单协议，继承公共 token。
4. 重复或不可访问，需要退役。

### 3.3 核心差距

| 领域 | 当前差距 | 目标 |
|---|---|---|
| 设计 token | Theme 已集中一部分颜色和尺寸，但页面仍有本地 pal()、硬编码字号/圆角/透明度 | 单一语义 token，资源与代码有明确边界 |
| 页面职责 | HostListPage、RemoteDesktop、SshTerminal 体量巨大，状态、业务、导航和 UI 交织 | AppShell + controller + V2 叶组件渐进拆分 |
| 响应式 | 以窗口断点为主，局部组件仍靠固定宽高或页面条件分支 | 窗口拓扑与容器响应分层 |
| 导航 | router.pushUrl/replaceUrl/back 分散，页面与会话导航混合 | AppNavigationGraph + NavPathStack 迁移适配 |
| 视觉效果 | 自有玻璃/光晕和 HDS 材质并存，缺乏适用边界 | 官方材质能力经 adapter 统一，提供纯色降级 |
| 组件一致性 | Sheet、Dialog、TopBar、Toolbar、空态、错误态各自实现 | 公共组件目录与验收规范 |
| 密度 | 手机和平板/PC 共用大量尺寸，窄窗和大窗都有浪费或拥挤 | compact/comfortable/productivity 三种语义密度 |
| 键鼠 | hover、右键、快捷键和焦点顺序覆盖不均 | 全应用 InputRouter 和可测试焦点环 |
| 无障碍 | label、role、状态朗读、焦点恢复不统一 | WCAG/HarmonyOS 语义门禁，复杂页面自定义焦点顺序 |
| 动效 | 局部动画和持续背景效果缺少统一预算 | Motion token、减少动效、低功耗和远程会话节流 |
| 状态反馈 | toast、dialog、inline error、状态文案并存 | 四级反馈模型和统一错误恢复 |
| 测试 | 页面状态测试和跨设备视觉验证不足 | policy 单测、语义测试、截图矩阵、真机性能证据 |

## 4. 目标设计语言

### 4.1 产品视觉命题

RemoteDeskHarmonyOS 的目标气质是“安静、精确、有空间感的专业远程工作台”。

- 安静：默认背景不持续闪烁或漂移；光效只在触摸、hover、焦点、状态转变时出现。
- 精确：连接状态、危险动作、当前输入目标和选中对象必须一眼可辨。
- 有空间感：导航、内容、上下文工具和临时浮层通过材质与层级分开，而不是靠更多边框。
- 专业：支持高密度信息、长时间使用、物理键盘、精确指针和可预测恢复。
- 原生：使用 HarmonyOS Symbol、系统字体、HDS 组件语义和多设备交互，不照搬 Android/iOS/桌面 Web。

### 4.2 三类表面

| 表面 | 用途 | 材质/效果规则 |
|---|---|---|
| Content Surface | 主机内容、设置正文、远程画面、终端、文件列表 | 稳定实色；可滚动；禁止持续光感覆盖 |
| Navigation Surface | 顶栏、侧栏、底栏、Tab Strip、会话工具 | 可使用沉浸光感、描边、hover 和轻量材质 |
| Transient Surface | Sheet、Dialog、Popover、Command Palette、SnackBar | 可使用更明显空间材质；必须处理模糊降级和对比度 |

### 4.3 无效果区

以下区域无论 API 26 能力多丰富，都默认禁止动态材质或非线性形变：

- RDP/RustDesk/VNC/Moonlight 的远程图像内容。
- SSH 终端字符网格和输入回显。
- 密码、主密码、私钥、TOTP 和恢复码。
- 二维码扫描取景和安全指纹比对。
- 高频滚动文件列表的每一行背景。
- 诊断日志正文。

可在无效果区外沿用静态状态描边，但不能修改内容像素或增加可感知输入延迟。

## 5. 全局 UI 平台架构

### 5.1 建议目录

P0 目标目录以职责命名，最终路径可在任务卡中微调：

    entry/src/main/ets/ui/
      tokens/
        AppColorTokens.ets
        AppTypographyTokens.ets
        AppSpacingTokens.ets
        AppShapeTokens.ets
        AppMotionTokens.ets
        AppDensityTokens.ets
      capability/
        AppCapabilityPolicy.ets
        AppVisualEffectAdapter.ets
        AppApi26Adapter.ets
      layout/
        AppLayoutPolicy.ets
        AppWindowTopology.ets
        AppContainerClass.ets
      navigation/
        AppNavigationGraph.ets
        AppNavigationState.ets
        LegacyRouterAdapter.ets
      scaffold/
        AppShell.ets
        AppPageScaffold.ets
        AppSessionScaffold.ets
      components/
        navigation/
        feedback/
        forms/
        content/
        session/
      testing/
        AppUiTestTags.ets
        AppUiFixtureFactory.ets

现有 common/Theme.ets 和 BreakpointUtil.ets 先作为输入源，不能在 P0 首日删除。迁移完成前维持兼容 facade，避免全仓同时改 import。

### 5.2 AppDesignTokens

新 token 必须是语义化契约，不以某个页面或某种玻璃效果命名。

| Token 组 | 示例语义 | 要求 |
|---|---|---|
| Color | bg.canvas、bg.surface、bg.elevated、text.primary、state.connected、state.warning | 明暗、高对比、壁纸/材质下均可读 |
| Typography | display、title、body、label、code、status | 支持字体缩放；终端 code 独立 |
| Spacing | xxs 至 3xl | 所有页面只用阶梯值和少量经批准例外 |
| Shape | control、card、sheet、dialog、floating | 圆角跟随表面语义，不按页面拍脑袋 |
| Size | touchTarget、icon、toolbar、sidebar、dialogMax | 手机最小触控与 PC 高密度分别定义 |
| Elevation | flat、raised、floating、modal | 由材质 adapter 翻译，不直接散落阴影值 |
| Motion | instant、fast、standard、emphasized | 尊重减少动效；远程会话降低预算 |
| Density | compact、comfortable、productivity | 根据输入方式与容器选择，不只看设备名 |

实现规则：

- 系统可资源化的颜色、字号、文案优先进入 resources。
- 需要运行时组合的语义 token 由 ArkTS 层生成。
- 禁止新页面再创建本地 buildDark/buildLight/pal 变体。
- Pantone、用户自定义主题和终端 Profile 通过 seed 映射到语义 token，不能直接覆盖状态色。
- 危险、警告、成功、连接中等状态色不可被用户主题混淆。

### 5.3 AppCapabilityPolicy

所有新 UI 能力通过单一策略对象读取：

- sdkApiLevel / targetApiLevel / compatibleApiLevel。
- deviceType、窗口模式、折叠状态和输入设备。
- supportsImmersiveLight、supportsDynamicLayout、supportsContainerReader。
- supportsMultiWindow、supportsHover、supportsRightClick、supportsDragDrop。
- reducedMotion、highContrast、fontScale、screenReader。
- powerSave、thermalLevel、remoteSessionActive、streamingLoadClass。

业务页面不得散落版本号和 system capability 判断。策略输出“产品能力”，例如 visualEffectMode = immersive/static/off，而不是让页面知道具体 API。

### 5.4 AppVisualEffectAdapter

该适配器负责把产品语义翻译成当前 SDK 可用实现：

| 产品语义 | API 26 目标 | fallback |
|---|---|---|
| navigationMaterial | HDS/系统导航材质 | 不透明语义背景 + 细描边 |
| floatingMaterial | HdsVisualComponent 或 hdsMaterial | elevated surface |
| pressFeedback | hdsEffect + 受控缩放/形变 | 透明度或颜色变化 |
| hoverFocus | 光线勾勒/描边 | focus ring |
| modalDepth | 系统材质 + 遮罩 | 实色 dialog + 标准遮罩 |

规则：

- Adapter 之外禁止直接使用不稳定 API 26 材质接口。
- reducedMotion、highContrast、powerSave 和高负载远程会话可强制 static/off。
- 同一层级只能有一种主材质，禁止多层 blur 叠加。
- effect 不得拦截 hit test、焦点、拖放或无障碍语义。

### 5.5 状态管理迁移

- 新平台组件和新叶组件优先 State Management V2。
- 巨型页面不做一次性 V1→V2 转换。
- controller/service 保持业务事实源，UI 只持有可展示状态。
- 连接、传输、认证、弹层和导航状态不能混入同一大对象。
- 每次拆分先添加纯策略测试，再移动 UI。
- 页面切换、布局算法切换和自由窗口变化不得重建连接 owner。

## 6. 响应式与窗口体系

### 6.1 两级响应模型

全应用响应式分为两级：

1. Window Topology：由现有 BreakpointUtil、窗口模式、设备类型、折叠状态、安全区和输入设备决定整体 AppShell。
2. Container Class：由组件自身可用宽度决定局部布局；API 26 可评估 ContainerReader，旧路径使用受控测量适配。

页面和组件只消费 AppLayoutPolicy 的语义输出，不能让多个监听器直接改 UI。

### 6.2 统一断点语义

继续沿用当前产品断点，最终数值在 D0 用官方资源和真机冻结：

| 语义 | 当前参考 | AppShell | 内容策略 |
|---|---:|---|---|
| sm | < 600 vp | 单栏、底部一级导航或单页栈 | 全宽卡片/列表，Sheet 优先 |
| md | 600–839 vp | 可折叠 rail/侧栏 | 主从可切换，最多双栏 |
| lg | 840–1439 vp | 常驻侧栏 + 主内容 | 双栏，允许 Inspector |
| xl | ≥ 1440 vp | PC 高密度壳 | 三栏/多 Pane，但主内容不少于 60% |

额外约束：

- 360 vp 是支持的最小窄窗，不得出现横向不可达动作。
- 折叠屏展开/折叠不丢滚动、输入、选中项和连接状态。
- PC 自由窗口变化不靠固定尺寸猜测。
- 键盘弹出后，主要输入和提交动作必须仍可见。
- DynamicLayout 只用于保持子树状态的布局算法切换，不承担业务状态迁移。

### 6.3 各形态 AppShell

| 形态 | 一级导航 | 次级导航 | 临时动作 |
|---|---|---|---|
| 手机 | 底部固定分类或页面栈 | 顶栏/Sheet | FAB、底部 Sheet、Command Palette |
| 小折叠 | 同手机；展开时平滑升级 | 可折叠双栏 | Sheet/Popover 自适应 |
| 平板 | Navigation rail/SideBar | 主从或 Inspector | Popover/侧 Sheet |
| PC | 侧栏 + 沉浸标题区 | 可调子侧栏/Tab Strip | 菜单、右键、Popover、快捷键 |

活跃远程会话进入 AppSessionScaffold 后，普通 AppShell 导航默认隐藏或收缩，避免底部导航、终端输入栏、远程快捷键栏互相争抢空间。

## 7. 导航和信息架构

### 7.1 一级信息架构

建议统一为四个产品域，具体标签在 D0 用户任务审计后冻结：

1. 设备：主机、分组、收藏、最近使用、在线状态。
2. 工作：活跃会话、工作区、传输、近期日志。
3. 密钥库：密码、SSH Key、证书、TOTP 和敏感资源。
4. 设置：账号、云同步、外观、安全、协议默认值、关于和反馈。

手机可以只显示高频一级入口，把低频“工作”并入设备页的活跃任务入口；平板/PC 则完整显示。不能仅为了固定四项而牺牲小屏可理解性。

### 7.2 AppNavigationGraph

导航实体至少包含：

- routeId、destinationKind、requiredAuth、requiredVaultUnlock。
- presentation：page、sheet、dialog、inspector、session。
- supportedWindowClasses、restorable、deepLinkPolicy。
- sensitiveScreenPolicy、backBehavior、unsavedChangesGuard。

迁移方式：

1. 先给现有 router 路由建立清单和适配层。
2. 新页面通过 AppNavigationGraph 注册。
3. 逐个 destination 迁移到 Navigation/NavPathStack。
4. 在 P10 删除无调用的 router URL 和重复 back 逻辑。

不能在同一批次同时迁移导航、业务状态和所有视觉组件。每个页面迁移后要验证冷启动、深链、返回、进程恢复、锁屏和登出。

### 7.3 页面级导航与会话级导航

- AppNavigationGraph 管页面和全局域。
- RemoteSessionRegistry 管 RDP/RustDesk/VNC/SSH/Moonlight 会话。
- SSH Workspace/Tab/Pane 由平行的 SSH 独立计划管理。
- 文件传输可以是全局工作域 destination，也可以从会话上下文打开。
- 关闭 UI 页面不能隐式关闭仍允许后台运行的会话；退出确认由会话策略决定。

## 8. 公共组件目录

P0 先交付以下组件与契约，再开始批量页面重写。

### 8.1 Scaffold 与导航

- AppShell：一级导航、窗口拓扑、锁屏覆盖、全局任务入口。
- AppPageScaffold：标题、安全区、滚动、loading/error/empty、页面动作。
- AppSessionScaffold：远程内容区、会话 chrome、输入附件、系统避让。
- AppTitleBar：手机返回、PC 标题区、拖动区、窗口按钮避让。
- AppSideBar / AppBottomTabs：由同一导航模型渲染不同形态。
- AppFloatingToolbar：有动作上限、溢出、紧凑模式和键鼠提示。
- AppTabStrip：固定分类和动态会话分开实现。

### 8.2 内容与状态

- AppCard / AppListItem / AppListItemCard。
- AppSectionHeader / AppDivider / AppMetadataRow。
- AppStatusChip：连接、离线、同步、警告、只读。
- AppHostAvatar / AppProtocolBadge。
- AppEmptyState / AppLoadingState / AppErrorState。
- AppSearchField / AppFilterBar / AppSortMenu。
- AppSkeleton，仅用于能够稳定预测结构的加载。

### 8.3 表单与安全

- AppFormField、AppSecureField、AppSelectField、AppSwitchRow。
- AppValidationMessage、AppPermissionExplanation。
- AppFingerprintRow、AppSensitiveValue、AppRevealGuard。
- AppDangerConfirm、AppDestructiveActionRow。
- AppUnsavedChangesGuard。

### 8.4 临时表面与反馈

- AppSheetScaffold：手机底部 Sheet、宽屏侧 Sheet/Popover 的统一实体。
- AppDialog：确认、错误、表单三类；禁止任意宽高。
- AppContextMenu / AppCommandPalette。
- AppSnackBar：短反馈、可撤销动作。
- AppProgressBanner：长任务和连接阶段。
- AppGlobalTaskIndicator：传输、同步和后台连接。

### 8.5 会话公共组件

- AppConnectionStageOverlay。
- AppSessionTopBar / AppSessionToolbar。
- AppSessionStatusBar。
- AppInputAccessoryHost。
- AppRemoteModifierPanel。
- AppSessionDiagnosticsEntry。
- AppReconnectBanner。

协议模块可以注入动作和状态，但不得复制一套尺寸、材质、关闭逻辑或无障碍规则。

## 9. 页面与领域迁移蓝图

### 9.1 引导、登录、主密码和锁屏

目标：

- 引导从营销轮播转为三步任务引导：添加设备、理解安全、开始连接。
- 登录和主密码建立清晰的账号凭据、本地加密密码和生物认证边界。
- LockGate 成为 AppShell 层能力，敏感页面和后台恢复统一处理。
- 错误内联展示，网络/账号/本地解锁错误不混成一个 toast。

形态：

- 手机单列、键盘避让。
- 平板/PC 使用品牌说明区 + 紧凑表单，不拉宽输入框。
- 减少动效时关闭大面积转场和背景动效。

验收：

- 360 vp、横屏、字体 200%、读屏、物理键盘完整可用。
- 密码字段不进入截图、日志、最近任务缩略图。
- 进程恢复不会跳过锁屏。

### 9.2 AppShell、首页和主机库

HostListPage 当前承担过多职责，迁移目标是：

- AppShell 管一级导航、锁屏、全局搜索和任务入口。
- HostLibraryController 管主机、分组、过滤、排序和状态。
- HostLibraryView 只渲染列表/网格。
- KeyVault、Settings、AddFlow 不再作为 HostListPage 内部巨型条件分支。

目标体验：

- 首页首屏显示最近/收藏/在线和继续工作，不堆叠所有设置入口。
- 搜索可跨主机、别名、协议、标签和工作区，但敏感值不进入索引。
- 手机使用列表或紧凑卡片；平板/PC 允许列表/网格切换和右侧 Inspector。
- 主机卡统一标题隐私、协议状态、最后连接和快捷动作。
- 批量选择通过显式选择模式进入，避免普通点击和多选冲突。

### 9.3 新增和编辑资源

所有协议 AddFlow 继承统一向导骨架：

1. 选择协议/来源。
2. 输入连接信息。
3. 认证和安全。
4. 高级设置。
5. 测试连接和保存。

规则：

- 各协议可以跳过不需要的步骤，但步骤语义一致。
- 验证在字段旁发生；网络测试结果和保存结果分开。
- 草稿 local-only，退出时提供保存/丢弃。
- QR、剪贴板、配置粘贴和导入必须先预览。
- 手机用全屏/Sheet；宽屏用定宽表单 + 说明 Inspector。
- 危险的证书忽略、Host Key 覆盖、Relay 安全降级必须单独确认。

### 9.4 密钥库与 2FA

目标：

- 密钥库成为独立 destination，不依赖首页内部 tab。
- 密码、SSH Key、证书、TOTP 用统一资源模型和不同内容模板。
- 列表不直接显示敏感值；显式 reveal 有超时和重新认证策略。
- 支持批量、标签、过期/弱安全提示，但不自动上传新增敏感数据。
- TOTP 动态进度不制造持续高功耗；读屏只在用户请求时朗读代码。
- 大屏使用资源列表 + 详情 Inspector；手机使用栈导航。

### 9.5 设置、账号、同步和关于

目标结构：

- 账号与订阅。
- 同步与数据。
- 外观与可访问性。
- 安全与隐私。
- 协议默认设置。
- 通知与后台。
- 关于、诊断和反馈。

统一 AppSettingsSection 和 AppSwitchRow，禁止同类 Toggle 在不同页面采用不同描述、确认和失败回滚逻辑。异步开关必须有 pending 态，取消/失败恢复视觉状态。高风险设置显示影响范围与恢复方法。

API 26 HdsColorPicker 仅在 U0 验证后用于主题和 Profile；旧系统走 adapter。主题预览必须同时展示状态色、文本对比和远程内容边界。

### 9.6 协议配置页

RDP、RustDesk、VNC、SSH、Moonlight 配置页面共享：

- Connection 段：地址、端口、显示名称。
- Authentication 段：凭据、Key、证书、一次性码。
- Display/Quality 段：按协议暴露。
- Input 段：键鼠、触控、控制器。
- Network 段：代理、Gateway、Relay、带宽。
- Security 段：证书、Host Key、加密与信任。
- Advanced 段：低频设置。

共享段只统一视觉和交互，不强行统一不同协议的业务语义。设置摘要必须让用户知道哪些值是全局默认、主机级覆盖或仅本次会话。

### 9.7 远程会话 chrome：RDP、RustDesk、VNC

RemoteDesktop 保持远程内容单一 owner，UI 迁移目标：

- 会话顶栏、修饰键面板、快捷键面板、虚拟键栏和诊断入口统一进入 AppSessionScaffold。
- 手机默认沉浸；边缘 handle 打开独立面板。
- 平板/PC 顶栏支持紧凑/完整模式和溢出菜单。
- 连接中、重连、只读、输入捕获和网络差有一致状态语言。
- 隐藏工具栏后仍保留可发现、可键盘触发、可无障碍恢复的入口。
- 360 vp 窄窗下断开、返回、输入模式等关键动作不得裁切。
- 光感效果只在 chrome，绝不覆盖远程画面。

### 9.8 SSH 集成边界（不实施 SSH UI）

SSH 的实体、工作区、Tab/Pane、Search、Profile、Snippet、历史、日志、SFTP 和多窗口完全由 SSH 独立计划定义。本计划只冻结下列窄接口：

- AppShell 可导航到 SSH 入口，并接收明确的返回目标；不得持有 SSH session handle。
- 主题、字体缩放、减少动效和高对比以只读快照传入，SSH 可通过本地 adapter 选择采纳或降级。
- 全局任务区只接收脱敏、低频、可撤销的 SSH 任务摘要；终端输出、命令、路径和 secret 不跨边界。
- App 计划不得修改 `SshTerminal.ets`、SSH workspace 组件、SSH 服务、xterm rawfile 或 SSH 数据 schema。
- SSH 计划不得等待 AppDesignTokens/AppSessionScaffold 才开始，也不得直接 import 尚未稳定的 App UI primitives。
- 两条计划都完成后，另开一个只做接口接线与回归的集成任务；不在任一主体阶段夹带对方实现。

### 9.9 Moonlight

在当前 Moonlight 任务闭环后的独立迁移批次中：

- HostDetail、AppCatalog、Settings 和 Stream 页面继承 AppShell 和公共组件。
- 应用目录适合评估 LazyDynamicLayout，但只有在 API 26 真机性能优于现有实现时采用。
- Stream 页使用 AppSessionScaffold，共享连接阶段、状态栏、诊断和退出确认。
- 控制中心、控制器 overlay 和启动 Sheet 只替换 UI 壳，不干预串流/解码/输入正确性。
- 不在本次文档任务中接触任何 Moonlight 实现差异。

### 9.10 传输、日志和诊断

建立全局 Work destination：

- 传输中心聚合 SFTP 和未来协议传输；显示来源、目标、进度、状态、失败恢复。
- 日志按会话和用户显式开启策略管理，默认不记录敏感输入。
- 诊断分为用户可读摘要和可导出技术信息。
- API 26 SelectionContainer 可用于普通日志/诊断文本；终端选择仍走终端实现。
- 长任务用全局任务入口和通知；短反馈用 SnackBar；阻断错误才用 Dialog。

## 10. 交互、键鼠与无障碍规范

### 10.1 输入模型

统一 AppInputRouter，按优先级分发：

1. 系统保留组合键。
2. 远程会话捕获策略。
3. AppShell 全局快捷键。
4. 当前 destination 快捷键。
5. 当前组件。

所有快捷键必须能在设置或命令面板中发现。PC 支持 hover、右键和拖放时，触控等价路径仍必须存在。

### 10.2 焦点

- 每个页面定义初始焦点和返回后的恢复目标。
- Sheet/Dialog 打开后焦点陷入，关闭后回到触发器。
- 复杂页面按导航→内容→Inspector→临时动作形成明确顺序。
- API 26 自定义焦点顺序只经 AppFocusPolicy 使用。
- 远程内容捕获键盘时提供明确退出组合键和可见提示。

### 10.3 无障碍门禁

- 所有图标按钮有 label、role、state 和 action。
- 连接、同步、传输状态变化按优先级朗读，避免高频刷屏。
- 触控目标满足平台最小尺寸；紧凑 PC 密度只缩视觉，不缩可点击语义区到不可用。
- 支持 200% 字体、粗体文本、高对比、减少动效。
- 颜色不作为唯一状态信号。
- 动态时间、TOTP、网络延迟和帧率不持续抢占读屏。
- 测试焦点顺序、返回恢复、弹层陷入和屏幕旋转。

## 11. 动效、性能和功耗预算

### 11.1 动效等级

| 等级 | 示例 | 预算 |
|---|---|---|
| L0 即时 | hover、按压、focus ring | 最短，不排队 |
| L1 标准 | Sheet、Popover、导航切换 | 单一主转场 |
| L2 强调 | 首次展开、重要状态变化 | 少量使用，可跳过 |
| 禁止 | 持续背景漂移、远程画面滤镜、终端 cell 形变 | 不实现 |

### 11.2 自动降级

以下任一条件成立，AppVisualEffectAdapter 至少降一级：

- reducedMotion。
- highContrast 与材质对比不足。
- powerSave。
- thermalLevel 达到阈值。
- 活跃远程视频/游戏串流处于高负载。
- 终端输入或渲染延迟超过冻结阈值。
- 窗口处于后台或不可见。

### 11.3 性能门禁

D0/U0 在参考设备冻结当前静态基线，P0 后冻结新 UI 预算：

- 启动、首页首屏、列表滚动、Sheet 打开、窗口 resize。
- RDP/RustDesk/VNC/Moonlight 会话帧率和输入延迟。
- SSH 终端吞吐、键入延迟、滚动和选择。
- 材质启用/关闭时 CPU、GPU、内存、功耗差。
- 动画结束后不得保留无必要 timer、display sync 或持续重绘。

没有真机数据时不填写虚假的百分比阈值；阈值由 U0/D0 的基线任务冻结并写入测试配置。

## 12. 隐私、安全和数据原则

- UI 迁移不扩大云同步范围。
- 搜索索引不得包含密码、私钥正文、TOTP secret、恢复码或未脱敏日志。
- 任务切换缩略图、通知、SnackBar 和诊断默认隐藏敏感主机信息。
- 截图和录屏策略在密钥库、登录、主密码和敏感确认页统一。
- 复制敏感值有明确提示、超时清理策略和审计边界。
- Material/blur 不能让背景敏感内容在弹层下仍可识别。
- 新遥测只记录匿名性能、错误类别和 feature flag，不记录主机名、地址、命令、路径或远程画面。
- 广播输入、批量删除、信任覆盖、证书忽略等高风险动作使用全局 DangerConfirm 契约。

## 13. Feature flag 与回滚

所有阶段先以内部 flag 交付：

| Flag | 控制范围 |
|---|---|
| appHarmony7DesignSystem | 新 token 和公共组件 |
| appHarmony7Shell | 新 AppShell |
| appNavigationV2 | Navigation/NavPathStack 新图 |
| appApi26DynamicLayout | DynamicLayout/ContainerReader 路径 |
| appImmersiveLightEffects | HDS/系统光感材质 |
| appSharedSheetsV2 | 公共 Sheet/Dialog/Popover |
| appHostLibraryV2 | 首页和主机库 |
| appVaultV2 | 密钥库 |
| appSettingsV2 | 设置 |
| appSessionChromeV2 | RDP/RustDesk/VNC 会话 chrome |
| appSshIntegrationBridge | 仅 SSH 入口/返回/低频状态接口；SSH 工作台 flag 由 SSH 计划独立拥有 |
| appMoonlightUiV2 | Moonlight 后续迁移 |
| appWorkCenterV2 | 传输、日志和诊断 |

回滚规则：

- flag 只切 UI 路径，不复制连接/密钥/传输事实源。
- 新旧 UI 读取同一稳定数据契约。
- schema 迁移必须向前兼容；回滚不丢用户数据。
- API 26 adapter 失败时回退静态实现，不让页面崩溃。
- 会话进行中不热切换 Scaffold；下一次进入生效。

## 14. 分阶段实施计划

### APP-UI-U0：API 26 平台升级门禁（1–2 周）

目标：建立真实可编译、可运行的 HarmonyOS 7 / API 26 基线，不混入页面改版。

交付：

- 安装并固定支持 API 26 的 DevEco、SDK、toolchain、Hvigor 和 UI Design Kit。
- 记录版本、校验和、sdk-pkg.json、release notes 和 .d.ts 证据。
- 决定 targetSdkVersion=26 后的 compatibleSdkVersion。
- 建立 AppCapabilityPolicy 的契约草案和 API 26 capability spike。
- 针对 DynamicLayout、ContainerReader、HdsVisualComponent、hdsEffect/hdsMaterial、HdsColorPicker、SelectionContainer、自定义焦点和 MultiWindow 做最小 spike。
- 更新 DECISIONS/ADR，替代当前“禁止 API 26”临时约束。
- 产出 API 26 allowlist、beta watchlist、fallback 矩阵。

代码范围：仅平台/构建 spike 分支；不改业务页面。

验收：

- 两项强制 Hvigor 门禁在 API 26 工具链明确通过。
- API 26 指定真机或官方云设备可安装、启动和打开现有核心页面。
- 若保留旧 compatible，旧设备可安装启动且不会因新类型链接失败。
- 每个候选 API 有采用/拒绝/等待的证据。

回滚：恢复原构建配置和 adapter flag；不得回滚用户数据。

### APP-UI-D0：全应用设计审计与 token 冻结（1 周）

目标：在写页面前冻结语义语言。

交付：

- 页面、组件、颜色、字号、圆角、间距、材质、图标和动效清单。
- HarmonyOS 2026 手机/折叠屏/平板/PC 设计资源对照。
- AppDesignTokens v1。
- 无效果区、危险状态色、密度、触控目标和响应式 wireframe。
- 关键屏幕基线截图：360 手机、展开折叠屏、平板、360 PC 窄窗、xl PC。

验收：

- 同一语义没有两个冲突 token。
- 状态色在明暗、高对比和主题 seed 下均可辨。
- 评审覆盖设计、协议、可访问性和性能。

### APP-UI-P0：平台 primitives 与适配器（2–3 周）

目标：让后续页面只组合公共能力。

交付：

- AppDesignTokens、AppCapabilityPolicy、AppLayoutPolicy、AppVisualEffectAdapter。
- AppPageScaffold、AppSheetScaffold、AppDialog、AppSnackBar。
- AppCard/ListItem、表单、状态、空/错/加载态。
- AppUiTestTags 和组件测试 fixture。
- Theme.ets/BreakpointUtil 兼容 facade。

验收：

- Story/demo destination 覆盖明暗、主题、高对比、减少动效和三种密度。
- 360 vp 到 xl 无裁切。
- material off 与 API 26 path 均可用。
- 纯策略单测和 UI 语义测试通过。

### APP-UI-P1：AppShell 与导航（2–4 周）

目标：建立全局信息架构，不立即迁移所有页面内部。

交付：

- AppNavigationGraph、LegacyRouterAdapter、AppShell。
- 手机底部导航、平板/PC SideBar、沉浸标题区。
- 全局搜索入口、任务指示器、锁屏覆盖。
- route inventory 与恢复/深链契约。

验收：

- 所有现有页面仍可从新壳到达并正确返回。
- 登录、锁屏、登出、进程恢复无绕过。
- 360 窄窗、折叠切换和 PC resize 不丢导航状态。

### APP-UI-P2：引导、认证与锁屏（1–2 周）

交付：GuidePage、LoginPage、MasterPasswordSetupPage、LockGate 的新壳与语义。

验收：键盘避让、200% 字体、读屏、敏感内容保护、恢复路径全部通过。

### APP-UI-P3：首页、主机库、搜索与添加资源（3–5 周）

交付：

- 从 HostListPage 抽离 HostLibraryController 和 HostLibraryView。
- 最近/收藏/在线、分组、过滤、排序、批量选择。
- AppSearch、右侧 Inspector、列表/网格响应式。
- 统一 HostAddWizard 和各协议步骤壳。

验收：

- 现有主机数据、连接入口和协议配置无回归。
- 隐私模式不泄露 ID/地址。
- 1k 主机列表滚动、搜索和窗口 resize 达标。

### APP-UI-P4：密钥库、设置与公共弹层（3–5 周）

交付：

- KeyVault 独立 destination。
- SSH Key、证书、TOTP 和敏感 reveal 契约。
- 设置 IA、AppSettingsSection、异步 Toggle pending/rollback。
- About、Feedback、ColorPicker 等 Sheet 迁到公共 Scaffold。

验收：

- 敏感内容、剪贴板、截图/缩略图和重新认证符合策略。
- 设置失败不会出现视觉状态与持久值不一致。

### APP-UI-P5：协议配置体验（3–5 周）

交付：

- RDP/RustDesk/VNC/SSH/Moonlight 的统一配置段和主机级覆盖摘要。
- RustDesk Relay、VNC Settings/Trust、SSH Proxy/Forwarding 等进入公共表单/Sheet。
- 测试连接、保存和安全确认分离。

验收：

- 不改变协议默认值和安全语义。
- 每种协议至少覆盖密码、证书/Key、网络失败和取消保存。

### APP-UI-P6：远程会话公共 chrome（4–7 周）

交付：

- AppSessionScaffold。
- RDP/RustDesk/VNC 共用顶栏、连接状态、输入附件、快捷键、诊断和退出确认。
- 手机沉浸、平板/PC 完整/紧凑工具栏。
- 远程会话负载驱动的效果降级。

验收：

- 不改变连接 owner、画面、输入、剪贴板、音频或会话生命周期。
- 360 vp 下所有关键动作可达。
- 远程画面像素不被材质处理。
- 高频输入与画面性能不低于冻结预算。

### APP-UI-P7：SSH 集成契约验证（2–4 天，不实施 SSH UI）

交付：

- 冻结 AppShell → SSH 的入口/返回参数和窗口上下文。
- 冻结主题/字体缩放/减少动效/高对比只读快照。
- 冻结 SSH → 全局任务区的脱敏低频状态 DTO。
- 提供 fake SSH adapter 完成 AppShell 集成测试，不依赖真实 SSH 工作台实现。

验收：

- App 计划测试可用 fake adapter 独立通过。
- 不修改任何 SSH 内部文件、schema、连接、终端或 SFTP 行为。
- SSH 计划未开始、进行中或回滚时，本计划都能独立构建和发布。

### APP-UI-P8：传输、日志与诊断中心（2–4 周）

交付：

- Work destination、全局传输中心、会话日志入口、用户/技术诊断视图。
- 普通文本选择、导出脱敏和失败恢复。

验收：

- 任务可从来源定位、暂停/恢复/重试。
- 导出物无密码、Key、TOTP、命令和未授权路径泄漏。

### APP-UI-P9：折叠屏、PC、多窗口与输入精修（2–4 周）

交付：

- 折叠连续性、PC titlebar、自由窗口、hover、右键、拖放和完整快捷键。
- MultiWindowEntryInAPP 可行性结论。
- API 26 自定义焦点顺序。

验收：

- 360 窄窗到 xl PC 的截图和交互矩阵。
- 连接 owner 在布局/窗口变化下唯一。
- 所有动作有触控和键盘等价路径。

### APP-UI-P10：旧 UI 清理与发布（2–3 周）

交付：

- 删除无引用的旧 router、重复 token、重复 Sheet/Dialog 和局部材质实现。
- 关闭兼容 facade，更新开发文档。
- 分批 rollout、遥测看板、回滚 runbook。

验收：

- rg 规则阻止新增硬编码主题、散落 API level 和直接不稳定材质 import。
- 所有 flag 有默认值、owner、退出条件。
- 旧 UI 删除前完成等价功能和数据回滚验证。

## 15. 测试与验收矩阵

### 15.1 自动化层

| 层 | 内容 |
|---|---|
| 纯策略单测 | token 映射、layout、capability、导航、feedback、隐私、密度 |
| 组件测试 | Scaffold、Card、Field、Sheet、Dialog、SnackBar、Toolbar |
| 页面状态测试 | loading/empty/error/content、锁屏、权限、网络失败、恢复 |
| 导航测试 | 冷启动、深链、返回、unsaved guard、进程恢复、登出 |
| 无障碍测试 | label、role、state、焦点顺序、弹层陷入、恢复目标 |
| 截图测试 | 明暗、高对比、三种密度、360/md/lg/xl、字体缩放 |
| 协议回归 | 配置值、连接入口、会话 owner、输入、剪贴板、退出 |
| 性能测试 | 首屏、滚动、resize、材质、远程会话和终端延迟 |

### 15.2 设备矩阵

最低目标：

- HarmonyOS 7 / API 26 手机，360 vp 最小窗口和标准宽度。
- 小折叠折叠态与展开态。
- 大折叠或平板。
- HarmonyOS PC/2in1，自由窗口 360、md、lg、xl。
- 触控、触控板、鼠标、物理键盘和软键盘。
- 若 compatible 保留旧版本：至少 API 23 当前真机和 API 24/中间版本覆盖。

### 15.3 视觉与可访问性验收

- 明暗模式、壁纸/主题 seed、高对比和减少动效。
- 字体 100%、130%、160%、200%。
- 中文、英文和最长文案；布局不依赖固定字符串宽度。
- 颜色对比、状态非纯颜色表达、触控目标。
- 焦点可见、顺序稳定、弹层关闭后恢复。
- 360 vp 关键动作不裁切、不只能横向滚动才能到达。

### 15.4 构建门禁

任何代码、ArkTS、native、Rust、测试、配置或流程文件改动，在每个实施阶段完成前都必须执行：

    source scripts/macos_env.sh
    hvigorw --mode module -p module=entry -p product=default default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon
    hvigorw --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --no-daemon

U0 后日志必须证明解析到已冻结 API 26 SDK/toolchain；命令退出 0 但实际使用 API 23/24 不算 API 26 门禁通过。

## 16. 发布、遥测与回滚

发布顺序：

1. 内部开发 flag。
2. API 26 指定设备 dogfood，material 默认可关闭。
3. P0/P1 平台与 AppShell 小范围启用。
4. 非会话页面先扩量。
5. 协议配置和远程会话 chrome 后扩量。
6. SSH 与 Moonlight 按各自独立计划单独放量。
7. 旧 UI 只有在功能等价、性能和回滚证据齐全后删除。

允许的遥测：

- 页面打开成功/失败类别。
- 导航恢复失败。
- UI flag、设备类别、窗口类别。
- 匿名帧耗时、输入延迟分桶、内存和 effect 降级原因。
- Sheet/Dialog 异常、不可达动作和崩溃。

禁止：

- 主机名、IP、账号、命令、路径、远程画面、剪贴板、密钥和 TOTP。
- 用遥测替代本地真机/人工可访问性验收。

回滚：

- 服务端/本地 flag 回旧 UI。
- 新旧 UI 共用数据事实源。
- schema 变化具备向前读取和迁移日志。
- 活跃会话在结束或下次进入时切换，不强制热替换。

## 17. 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| API 26 仍为 Beta，最终 SDK 改名或删能力 | 返工、无法编译 | U0 以实际 .d.ts 冻结；所有 Beta 能力经 adapter |
| compatibleSdkVersion 决策过晚 | 架构反复 | U0 第一周形成产品/分发 ADR |
| 直接在巨型页面上换 UI | 回归难定位 | 平台先行，controller/叶组件渐进拆分 |
| HDS 与自有 glass/effect 混用 | 视觉混乱、性能下降 | 单一 AppVisualEffectAdapter 和表面分类 |
| DynamicLayout 切换重建会话/WebView | 连接、输入或选区丢失 | owner 外置、稳定 key、生命周期 spike 和压力测试 |
| ContainerReader 与全局断点互相触发 | 布局震荡 | AppLayoutPolicy 单一输出 |
| Navigation 与 router 双栈失控 | 返回、恢复错误 | 路由清单、LegacyRouterAdapter、逐 destination 迁移 |
| 材质降低远程内容可读性 | 核心体验退化 | 明确无效果区，chrome-only |
| 动效增加输入延迟和功耗 | 会话不可用 | 性能预算、自动降级、后台停止 |
| 可变字体造成布局抖动 | 工具栏裁切 | 冻结级别、测量长文案、溢出菜单 |
| PC 高密度压缩触控区域 | 可访问性退化 | 视觉密度与命中区域分离 |
| 设置异步保存视觉不同步 | 用户误判 | 统一 pending/rollback 契约 |
| 全局搜索泄露敏感数据 | 隐私事故 | 明确索引 allowlist、脱敏和本地策略 |
| Moonlight 当前任务未闭环 | 代码冲突 | 等 clean main 后单独迁移，不碰当前 dirty diff |
| 设备/SDK 缺失 | 只能静态推断 | 记录 blocker，不宣称端到端完成 |

## 18. 人力、依赖与里程碑

### 18.1 粗略工作量

| 阶段 | 单线估算 |
|---|---:|
| U0 API 26 平台 | 1–2 周 |
| D0 设计审计 | 1 周 |
| P0 UI primitives | 2–3 周 |
| P1 AppShell/导航 | 2–4 周 |
| P2 引导/认证 | 1–2 周 |
| P3 首页/主机/添加 | 3–5 周 |
| P4 密钥库/设置 | 3–5 周 |
| P5 协议配置 | 3–5 周 |
| P6 会话 chrome | 4–7 周 |
| P7 SSH 集成契约 | 2–4 天，仅 fake adapter 与接口验证 |
| P8 传输/日志/诊断 | 2–4 周 |
| P9 折叠/PC/多窗口 | 2–4 周 |
| P10 清理/发布 | 2–3 周 |

单人串行完成本计划约 5–9 工程月；SSH 独立计划不计入该估算。两条计划可并行，但不得共用实现分支或把对方里程碑作为主体实施前置；最终接线由独立集成任务完成。

### 18.2 硬依赖

- 支持 API 26 的 DevEco Studio、SDK、toolchain 和 UI Design Kit。
- HarmonyOS 7 手机、折叠屏/平板、PC/2in1 或官方云调试设备。
- 当前协议真实测试环境。
- 官方 2026 设计资源和最终 API 26 release notes。
- 当前 Moonlight 任务闭环和干净 main。
- 设计、无障碍、性能和协议 reviewer。

## 19. 完成定义

全应用 UI 升级只有同时满足以下条件才算完成：

1. targetSdkVersion 26 和 compatibleSdkVersion 决策有 ADR，构建确实使用冻结 API 26 SDK。
2. 全应用使用统一 AppDesignTokens、AppCapabilityPolicy、AppLayoutPolicy 和 AppVisualEffectAdapter。
3. AppShell、导航、公共 Scaffold、Sheet、Dialog、反馈和表单完成迁移。
4. 引导、认证、首页、主机库、添加资源、密钥库、设置、非 SSH 协议配置、远程会话、Moonlight、传输和诊断均纳入统一 UI；SSH 入口通过稳定集成契约可达，但 SSH 内部完成度不计入本计划。
5. 360 手机、折叠、平板、PC 自由窗口全部通过视觉和交互矩阵。
6. 明暗、高对比、减少动效、200% 字体、读屏、键鼠和触控通过。
7. 远程画面和终端字符区没有装饰性材质，核心输入/渲染性能不低于冻结预算。
8. 新旧 UI 可按阶段回滚，回滚不丢主机、密钥、设置、会话或传输数据。
9. API 26 Beta 能力都有 adapter、fallback 或明确的 API26-only 产品决定。
10. 所有实施阶段两项 Hvigor 门禁通过，并完成对应真机/云设备证据。
11. 无未处理的高/中等级 UI、无障碍、隐私、性能和协议回归 finding。
12. 旧 router、重复 token、重复 Sheet/Dialog 和废弃 flag 已按 P10 清理。

## 20. 第一张可执行任务卡

当前任务闭环并回到干净 main 后，第一张全局任务卡必须是：

> APP-UI-U0 — HarmonyOS 7 / API 26 SDK、兼容边界与新 UI 能力冻结

只做以下工作：

1. 安装/选择 API 26 DevEco、SDK、toolchain 和 UI Design Kit。
2. 记录完整版本与实际解析路径。
3. 让当前应用在 API 26 下先保持视觉不变地编译、安装、启动。
4. 决定 compatibleSdkVersion。
5. 对候选 API 做最小独立 spike，读取实际 .d.ts 和 @since。
6. 输出 allowlist、beta watchlist、fallback 矩阵和 ADR。
7. 执行两项 Hvigor 门禁及 API 26 设备 smoke。

明确禁止：

- 顺手重做首页或 SSH。
- 在 U0 中迁移 Moonlight。
- 依据网页猜 import。
- 同时改业务 schema。
- 在没有旧设备证据时宣称兼容 API 23。

U0 通过后才创建 APP-UI-D0/P0。SSH 计划不等待 APP-UI-D0/P0，可按自己的基线立即推进；两者只在单独的 APP-UI-P7 集成任务中对接稳定接口。

## 21. 每阶段执行模板

每个实施阶段都必须按下列顺序：

1. 从最新 main 创建独立 codex/<task> 分支，先确认没有继承未闭环 dirty scope。
2. 更新本阶段实体、文件范围、排除项和 rollback。
3. 复核实际 API 26 SDK 声明与官方 release notes。
4. 先写纯策略/状态测试，再改 UI。
5. 用公共 token、capability、layout 和 Scaffold，不新增本地替代品。
6. 验证 360、md、lg、xl 以及明暗/高对比/减少动效。
7. 验证键鼠、触控、读屏和字体缩放。
8. 对协议页面补连接/输入/退出回归。
9. 执行两项强制 Hvigor 门禁。
10. 由独立 reviewer 只审本阶段增量。
11. 修复 finding、重新验证、提交、合并、清理分支。
12. 更新 CURRENT、QUEUE、STATE 和 review receipt，未验证项记录 blocker。

## 22. 官方资料索引

- HarmonyOS 7 新能力：https://developer.huawei.com/consumer/cn/features/
- HarmonyOS 7 / API 26 版本变更：https://developer.huawei.com/consumer/cn/doc/harmonyos-releases/changelogs-600
- 2026 年 7 月开发者月报：https://developer.huawei.com/consumer/cn/monthly/202607
- HarmonyOS Design：https://developer.huawei.com/consumer/cn/design
- 设计资源：https://developer.huawei.com/consumer/cn/design/resource
- UI Design Kit ArkTS 组件：https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/ui-design-arkts-component
- API 26 HdsColorPicker：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ui-design-color-picker-favorites
- HDS 视觉效果示例：https://developer.huawei.com/consumer/en/doc/harmonyos-guides/ui-design-visual-effect-background-color
- DynamicLayout：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-layout-development-dynamiclayout
- LazyLayoutAlgorithm / LazyDynamicLayout：https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-arkui-lazylayoutalgorithm
- SelectionContainer：https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ts-basic-components-selectioncontainer
- 工具栏设计：https://developer.huawei.com/consumer/cn/doc/doccenter-ux-design/toolbar-0000001929683232
- 大屏 UX：https://developer.huawei.com/consumer/cn/doc/doccenter-ux-design/ux-guidelines-large-screen-0000001807707561
- 多设备布局：https://developer.huawei.com/consumer/cn/doc/best-practices/bpta-multi-device-screen-layout
- 折叠屏 UX：https://developer.huawei.com/consumer/cn/doc/doccenter-ux-design/ux-guidelines-foldable-screen-0000001807866557
- 沉浸窗口：https://developer.huawei.com/consumer/cn/doc/best-practices/bpta-multi-device-window-immersive
- PC 开发入口：https://developer.huawei.com/consumer/cn/multidevice/pc/get-started/
- HarmonyOS Symbol：https://developer.huawei.com/consumer/en/design/harmonyos-symbol/

## 23. 本次文档任务的退出条件

- 本独立计划已落盘。
- SSH 计划与本计划为平行交付线，范围、分支、flag、里程碑和完成定义均已解耦。
- API 23 当前基线、API 24 本机 SDK、API 26 目标和 Beta 状态表述一致。
- Moonlight 当前代码和文档 dirty diff 未被读取、修改或评价。
- git diff --check 对本次计划文件通过。
- 不运行构建，不把文档计划表述为已实现功能。
