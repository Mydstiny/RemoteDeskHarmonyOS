# API 26 基础版本 UI 升级与优化计划

- 日期：2026-09-07。
- 状态：前八批公共 UI 代码已提交并独立复核；第九批协议选择和 SSH 表单操作控件也已提交并独立复核。U0 基线及 API23/26 视觉、键盘、性能矩阵仍待验收，不能标记 U0-U4 完成。
- 权益归属：基础版本免费升级，所有用户可用，不属于 Pro，不要求购买、登录、联网验单或开启模拟 Pro。
- 关联：[总体路线图](2026-09-06-pro-product-roadmap.md)、[Pro M1/M2 实施准备](2026-09-07-pro-m1-m2-implementation.md)。

## 1. 产品边界

API 26 是技术和适配条件，不是收费依据。公共界面更新独立于 Pro 权益底座推进和发布，不等待验单后端或付费功能完工。

| 内容 | 归属与展示条件 |
|---|---|
| 标题栏、导航、列表、设置、弹层、工具栏的公共视觉和交互优化 | 基础版本免费；按设备/API 适配 |
| 深浅色、字体缩放、无障碍、键鼠/触屏、自适应窗口与性能改进 | 基础版本免费；所有用户受益 |
| 公共图标样式、间距、布局和动画修整 | 基础版本免费；不消耗 Pro 权益 |
| 同一页面中新增加的 Pro 专属操作 | 只对该操作鉴权；其余页面及公共样式免费 |
| 用户选择内置预设应用 Logo | 白底/透明底选择属于 Pro；默认及恢复默认免费；用户已明确取消自定义上传 |
| 碰一碰文件/连接分享、接续、安全密钥等新增能力 | 按各自 Pro 计划实施；它们使用的公共视觉组件不因此收费 |

免费/Pro/模拟模式切换时，公共界面外观和能力保持一致，只有专属操作入口改变。退款、退出账号、离线或验证暂不可用，不撤销基础 UI 升级。

## 2. 升级范围

| 界面/能力 | 工作内容 | 验收重点 |
|---|---|---|
| 连接首页与主机列表 | 标题、分区、行高、图标、状态、空态、搜索/筛选排布；卡片和经典列表统一基础规范 | 长列表滚动、文本截断、选中/悬停反馈，既有搜索和分组行为不变 |
| 设置页 | 统一分组间距、标题层级、说明文字、开关/跳转行、点击范围 | 免费设置全部保留，长说明/大字体不挤压，键盘可达 |
| 标题栏与导航 | Phone/Pad/PC 的返回、标题、窗口操作区与内容区协调 | 拖动窗口、最大化/还原、分屏、缩放后布局正确；命中区域不冲突 |
| bindSheet/弹窗/表单 | 统一材质、暗色背景、圆角、按钮层级、滚动与底部操作区，优化键盘避让 | 小窗口、软键盘、大字体可完成操作；关闭和焦点恢复正确 |
| 远程工具栏 | 分组、溢出菜单、触屏/鼠标命中、状态反馈、收起展开一致性 | 不误传点击/快捷键至远端；不遮挡关键内容、不改变免费操作权限 |
| 加载、错误、空态与任务反馈 | 文案层级、图标、进度与取消状态一致 | 不把加载失败误写成功，不重复弹窗、不泄露敏感内容 |
| 公共主题、动效与无障碍 | 颜色/间距/字号/圆角规范、对比度、焦点、屏幕阅读语义、克制动效 | 深浅色一致、系统字体变化可用、动画不阻塞输入 |
| 自适应与性能 | 窗口实时缩放、密度/显示比例适配、列表更新和绘制成本控制 | 不降低远程渲染/输入表现；材质效果有性能回退 |

Pro 面板可以复用新版公共组件，其基础显示和购买介绍入口仍面向所有用户；UI 工作线不改商品、价格、订单和权益逻辑。

## 3. API 26 接入策略

1. 先清点本机 API 26 SDK 与官方组件说明，记录候选接口、起始版本、支持设备和限制，避免只因名字更新就替换。
2. 当前已看到 ComposeTitleBarV2、ComposeListItemV2 等声明，将它们作为候选，不将所有页面强制迁移到 V2。核实状态管理、事件、主题与现有组件的互操作成本。
3. 建立公共适配入口：输入界面所需语义和数据，由能力判断选择 API 26 实现或现有兼容实现。公共适配入口不得引用 Pro 权益服务。
4. 评估 compile SDK 升级并保留 API 23 安装兼容目标；compile/target/compatible 分开核实，不为视觉升级直接提高最低安装版本。
5. 旧系统不得加载不可用接口；验证动态选择、导入/初始化和启动路径，而非仅检查按钮中 if(version)。
6. 现有系统也能使用的间距、主题、焦点、布局和性能修复同步提供给 API 23；API 26 独有组件/效果按设备能力增强。
7. 对性能代价明显或设备不支持的材质/动画提供稳定回退；保持文字可读和远程画面清晰，不追求全屏重材质。

本计划不预先指定未验证的 API 26 专有材质名称或承诺所有设备视觉完全一致。每个采用的新 API 在实施时附本机 SDK/官方依据。

## 4. 代码组织与改动边界

实施前优先核对现有 Theme、公共组件、HostListPage、设置叶弹层路由和远程工具栏，不为视觉升级重写协议状态机。

- 公共设计参数集中维护，避免页面散落新的颜色、尺寸与模式开关。
- 同一功能的新旧 UI 共用业务回调、数据和权限判断；不复制两套连接/购买/账号逻辑。
- 将可复用组件逐步抽出，控制 HostListPage 等大文件增量；不以本任务名义进行无关重构。
- 触摸事件拦截、键盘焦点、窗口坐标和远程输入映射是回归重点；纯 UI 调整也不能改变已有输入约定。
- 现有用户布局、主题和操作偏好保留；如需迁移，单独声明并验证，不自动清空。
- 只对真实新增 Pro 操作接统一策略；不把整个新版设置页、工具栏或导航容器包进 Pro 显示条件。

## 5. 独立里程碑

| 阶段 | 内容 | 完成条件 |
|---|---|---|
| U0：清点与基线 | SDK/组件能力清单、现有页面和主题清点、代表设备/页面截图、性能基线 | 明确采用与不采用的组件、回退路径和可比较证据 |
| U1：兼容与公共规范 | API 26 适配层、主题/尺寸规范，先做设置行或标题栏的最小完整样例 | API 23 正常启动和回退；API 26 样例通过；不依赖 Pro |
| U2：首页与设置 | 标题栏、列表、设置行、基础导航和表单逐批迁移 | 长列表、小窗口、大字体、深浅色与键鼠/触屏通过 |
| U3：弹层与远程工具栏 | 统一弹层及工具栏，补任务状态、焦点恢复和事件拦截 | 键盘避让、窗口变化、输入与远程交互不回归 |
| U4：全量回归与发布 | 多设备、性能、无障碍、免费/Pro 视角对照 | 基础 UI 独立验收，可随基础版本发布；不等待收费闭环 |

U0 可与 Pro M1/M2 的准备同步推进；应用代码实施遵守同一活动分支与文件协调规则，不并发修改同一大页面。实际提交按明确小范围顺序完成，不新建持久 worktree。U1 的公共能力适配可供后续 Pro 图标/协同复用，但 U 线的交付不依赖这些付费功能。

## 6. 验收矩阵与质量门

- 系统与设备：API 23/26；Phone、Pad、PC/2in1 的真实支持组合；旧系统冷启动、恢复前台和页面导航。
- 用户状态：无账号免费、Pro 视角、模拟免费/Pro、退出账号、离线和撤权后；公共 UI 不因权益改变。真实后端尚未就绪时用受控测试状态验证界面一致性，记录为 UI 验收，不宣称真实购买/验单通过，不以收费后端作为基础 UI 发布前置条件。
- 视觉布局：深浅色、字体缩放、窄/宽窗口、分屏、最大化/还原、密度和显示比例变化；比对 U0 基线。
- 输入与可访问性：触屏、鼠标、键盘 Tab/方向键/Escape、软键盘避让、屏幕阅读语义；弹层关闭与隐藏操作后焦点正确。
- 协议回归：在已有协议连接中验证工具栏点击、焦点、快捷键和坐标映射，不将 UI 事件错误转发远端。
- 性能：相同设备、页面数据与远程负载下对比滚动、帧呈现、输入响应、CPU/内存；U0 固定测量方式和阈值后再判定，不能凭主观流畅声称通过。
- 失败路径：组件不可用、低性能回退、窗口销毁、快速开关弹层；不崩溃、不留遮罩、不丢用户配置。

每个实施增量运行当次 Hvigor default@OhosTestCompileArkTS、assembleHap、定向必要验证、Light、git diff --check；测试模块变化增加 ohosTest 编译。涉及 UI 交付必须有设备视觉/交互证据，构建通过不等于视觉验收。实际代码提交后独立复核，未完成设备项保留 blocker。

## 7. 发布与当前状态

在更新日志中单列“基础界面升级与优化”，不要放入 Pro 已购权益清单。API 26 限定效果说明为系统/设备适配要求，不展示为付费锁定。

U0 首轮清点（2026-09-07）：

| 对象 | 已确认事实 | 首轮采用策略 |
|---|---|---|
| ComposeTitleBarV2 | 本机 API 26 SDK `@ohos.arkui.advanced.ComposeTitleBarV2.d.ets`；since 26.0.0、ComponentV2，标题/副标题/左右菜单模型 | 先验证与现有 V1 页面的状态互通及弹层关闭/主题接口，不直接替换全部标题栏 |
| ComposeListItemV2 | 本机 API 26 SDK 存在相应声明 | 作为候选；现有主机行混有拖放、分组、鉴权与快捷操作，逐项验证后选择 |
| 当前兼容目标 | 工程 target/compatible 均为 6.1.0(23)，当前 DevEco SDK 含 API 26 声明 | 保留 API 23 安装目标；采用新接口前单独验证导入/初始化兼容 |
| 公共主题与页面 | Theme 的 Palette/buildLight/buildDark；HostListPage 标题覆盖层和设置分区；独立设置叶弹层 | 复用主题，优先抽取小范围公共标题/设置行，减少大页面重复样式 |
| 设备基线 | 当前连接设备报告 API 26、phone；已查看设置页基线 | 截图仅用于本地对照，不提交包含用户配置的图片；设备正用于 SSH 连接，后续视觉操作需避免打断会话 |

U1 首个代码增量：新增免费 `AppSheetHeader`，接入反馈页和 Pro 面板。共用 Theme 与字体，标题在剩余宽度内最多两行，关闭动作改用至少 44vp 的原生 Button，提供键盘焦点与读屏名称；反馈页消除标题/说明的重复横向内边距。此组件不导入 Pro、账号或联网服务。

暂不采用 ComposeTitleBarV2：当前样例是 V1 弹层，其关闭语义和既有主题可通过稳定组件直接满足；强制迁移 V2 没有经过验证的收益。这里不宣称使用了 API26 专属标题栏；新系统增强与 API23 冷启动验证仍需后续增量。

本轮门禁：default@OhosTestCompileArkTS `BUILD SUCCESSFUL in 26 s 998 ms`；signed assembleHap `BUILD SUCCESSFUL in 30 s 540 ms`。当前尚未取得 API23 真机冷启动、Pad/PC、字体/无障碍和量化性能基线，不宣称 U0/U1 已完成。公共 UI 单独提交和验收，不随 Pro 的权益状态改变。

## U1/U2 公共控件第一批（2026-09-08）

- 免费公共 `AppUiMetrics`、`AppUiColorPolicy`、`AppSettingsSwitchRow` 与扩展 `AppSheetHeader`。本批迁移滚轮方向、双指缩放、会话侧栏/顶栏、密码回显和日志五类设置；原 draft/touched/save、快捷退出保护、即时持久化、日志抓取/导出及协议回调保持原逻辑。
- 将标题里的裸文本点击改为原生 Button，取消/保存及批量按钮最小高度 44 vp；开关取消视觉缩小，保留原生焦点、状态与单一 onChange。会话控制栏读屏标签明确为“隐藏”，与 isOn 含义一致。
- 标题支持副标题和独立主操作，文字自然换行；设置说明改用现有 text2，避免原 text3 的低对比度。保持卡片/滚动布局和当前主题偏好。
- 填色操作保留规范的自选六位 RGB 主题色，并在黑/白文字中选择对比更高的一项，覆盖纯白等浅色预设；不重写用户已保存的主题。计算依据为 [W3C 相对亮度与对比度定义](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html)。此计算不等于整页无障碍实机验收。
- 本地 SDK 中 ComposeTitleBarV2/ComposeListItemV2 自 API26 提供。当前公共控件继续使用 API23 已有的 Row/Text/Button/Toggle；不引入 API26-only 冷导入，V2 候选保留到跨版本加载与设备行为验证后再决定。装饰图标的 accessibilityLevel('no') 已核对 SDK since12。
- 本轮代码门禁：default@OhosTestCompileArkTS `BUILD SUCCESSFUL in 9 s 469 ms`；signed assembleHap `BUILD SUCCESSFUL in 1 min 3 s 511 ms`、SignHap 982 ms；两项 exit 0。Light/diff PASS；五页全部状态块及 40 个原业务/辅助方法逐字不变，实际颜色策略 4352 个 RGB 样本及无效输入边界 PASS。九个本批代码文件在最终代码门禁前后哈希一致。精确 checkpoint `c8240fd9` 已独立复核 PASS；复核额外确认第 41 个布局辅助方法仍相同，并独立执行 65800 个颜色样本。记录更新后另两门 PASS：testCompile 590 ms，signed assembleHap 1 min 8 s 189 ms、SignHap 1 s 109 ms；共享 HAP 中并行 AI/文件传输源不在本批复核范围。
- 未改变免费/Pro/离线权限，也未完成小窗口、字体缩放、读屏、键鼠、性能和真实 API23/26 设备矩阵。首页、其他设置、导航和 U3/U4 继续推进。

## U2 公共导航与其余叶页第二批（2026-09-08）

- 新增免费原生 Button 导航行 `AppSettingsActionRow`，用于设置顶级入口及关于页的三处外链卡片。主页面仅定点修改 `settingsAccordionHeader`、`settingsActionHeader`、`rustdeskSwitchRow` 与两个公共导入；保留 AI 接线、路由、展开状态、保存动画和业务回调。
- 关于页六类标题统一复用公共标题栏；翻页、设备/协议/课程选择改用原生按钮，保留原控制器与数据。键盘设置复用公共标题/开关，组合键类别改为两行，按键与常规操作最小高度 44 vp，现有滚动区承载内容；不改键码、存储、平台差异或系统输入法调用。
- VNC scaffold 保留原布局密度、action-only 和 FIT_CONTENT/滚动/页脚模式。返回/关闭按钮 44 vp，紧凑头上下各 4 vp，总按钮头 52 vp，与原 compact header estimate 一致；保持底部安全区和回调。
- 按钮填色沿用原主题选择并使用公共黑白前景策略；设置说明可换行，原生焦点和读屏名称补齐。当前最终代码门禁：testCompile `BUILD SUCCESSFUL in 11 s 644 ms`；signed assembleHap `BUILD SUCCESSFUL in 1 min 7 s 852 ms`、SignHap 1 s 169 ms；两项 exit 0。Light、About AGPL 展示检查和 diff PASS；三叶页全部状态块和 54 个原业务/辅助方法未改，外链目标不变。四完整源码及 HostList 三方法 hash 在最终两门前后固定；精确 checkpoint `d6e0f11c` 已独立复核 PASS。复核确认 HostList 仅约定三 helper/两导入，54 声明及完整状态段未改、原四个外链均保留，VNC compact 52 vp 与估算一致。记录后两门另 PASS：testCompile 18 s 295 ms；signed assembleHap 19 s 348 ms、SignHap 932 ms。不宣称真实设备视觉、字体或性能完成。

## U3 会话工具栏第三批（2026-09-08）

- VNC 填色按钮共用主题色与黑白前景策略，修正白色等浅主题下不可读的图标/文字；手机浅色侧栏的“只读”提示改为深色。手机/PC 收起动作使用原生 Button，PC 收起最小高度补到 44 vp。
- Moonlight 侧栏操作/固定/收起按钮从 40 vp 补到公共 44 vp；滚动预算同步扣除两个固定按钮、两处间隔、外侧 padding 与 border，避免小窗口退出/收起被推出边界。现有 176 vp 展开阈值、菜单、自动收起和所有业务回调保留。
- 四协议复用的收起手柄点击范围由 40 vp 统一为公共 44 vp；22 vp 可见手柄不变，现有位置计算随常量更新。维持原 focusable(false)、focusOnTouch(false)、远程输入平面及现有 hit-test 约定，不用普通设置页焦点规则替换会话输入。
- 当前代码门禁 testCompile `BUILD SUCCESSFUL in 9 s 412 ms`，signed assembleHap `BUILD SUCCESSFUL in 11 s 276 ms`、SignHap 912 ms，均 exit 0；Light/diff PASS。34 个原普通方法、两组件状态块和事件/焦点/命中调用行未改；实际滚动函数 24600 个布局组合（176–1200 vp、1–24 操作）通过固定操作区边界验证。三源码 hash 与 checkpoint `6e8de5b3` 一致，精确增量独立复核 PASS；复核额外运行 Phone/Pad × 四断点的 196800 个布局组合。记录后两门 PASS：testCompile 8 s 543 ms；signed assembleHap 10 s 508 ms、SignHap 980 ms。
- U0 模拟器进展：在任务临时目录创建独立 API24 Phone 实例，未使用用户现有模拟器数据。启动被华为许可确认阻止，已向用户申请，尚未接受、安装 App 或取得布局证据。API24 可补充兼容布局证据，不能代替要求的 API23/26、真实设备或协议输入验收。

## U2 首页导航与经典列表第四批（2026-09-08）

- 桌面侧栏保留原协议/分组/AI 路由，四类导航改原生 Button 与已选读屏语义；自然行高和独立滚动适应较矮窗口，底部设置仍单独可达。已选项及添加按钮采用现有主题色与公共黑白前景，保留所有添加模式/弹层/权限回调。
- 两种断点复用同一搜索 builder：清除按钮 44 vp，原立即清除与 debounce 输入保持不变，清除后尝试归还输入焦点；字段已离开组件树时安全忽略焦点异常。标题自然测高只用于列表顶部避让，原系统安全区下限保留。无匹配文案区分搜索/分组筛选，避免宣称用户没有任何主机。
- 分组筛选使用原数据/切换函数并支持横向滚动，长标签截断且读屏保留完整名称；批量工具栏只改允许换行、44 vp 与填色前景，原选择/删除/排序/取消回调不变。经典远程与 Moonlight 行仅调整图标前景、44 vp 菜单/探测命中、读屏名称和锁定提示对比度，保留隐私遮蔽、长按/拖放/滑动与缓存边界。分组卡片的整体布局另行推进。
- 本地 API26 SDK 确认 FocusController/getFocusController 自 API12，accessibilitySelected 自 API13，均早于保留的 API23 安装目标；没有新 API26-only 冷导入。
- 当前代码两门：testCompile `BUILD SUCCESSFUL in 10 s 203 ms`；signed assembleHap `BUILD SUCCESSFUL in 11 s 413 ms`、SignHap 917 ms，均 exit 0；Light/diff PASS。完整源码范围核对仅七处 UI 区块、两个 UI helper、一处测量状态与一个 import；317 个原事件调用核对，差异限于合并重复搜索、清除焦点与新增标题测量，其他回调及账号/协议/存储/隐私投影代码未改。精确 checkpoint `84d80efe` 与后续 `e37c5efc` 独立复核 PASS；原 P2 横向手势冲突已关闭：HdsTabs 使用自 API20 支持的 scrollable(false)，保留禁止滑动切页并让子筛选条滚动。修复后两门 testCompile 9 s 160 ms、signed assembleHap 10 s 251 ms、SignHap 883 ms，Light/diff PASS。独立复核覆盖 333 个 on* 调用、38424 个实际标题测量组合和清除焦点异常边界；真实字体/键盘/窗口/长列表性能仍待验收。

## U2 自然高度分组卡片第五批（2026-09-08）

- 协议和 Moonlight 分组标题采用原生 Button，保留原展开状态/控制器，标题、副标题、统计与父行只设最小高度。展开详情移除卡片、Grid 与面板的层层固定高度，使用自然高度的 Flex 单/双列；列数仍由既有断点策略决定，数据、顺序与 ForEach key 不变。
- 探测/应用目录、编辑、锁定、删除放到可换行的独立操作行，各按钮 44 vp，内容区可读宽度增加。主机图标改为可聚焦原生按钮并应用公共黑白前景；原隐私投影、协议显示、连接/选择回调、长按和 AI 不支持锁定的规则保持。详情文字与空态使用 text2，标签宽度可随文字扩展。
- 收起详情使用 Visibility.None，避免零高度内残留可聚焦操作；仍直接读取展开状态，保留原状态动画与外观配置。Flex spacing/LengthMetrics 自 API12 提供，本批未引入 API26-only 加载路径。全应用字体策略、实际动态字体与触控/读屏/性能验收仍待后续验证。
- 当前代码门禁：testCompile `BUILD SUCCESSFUL in 9 s 263 ms`，signed assembleHap `BUILD SUCCESSFUL in 10 s 447 ms`、SignHap 916 ms，均 exit 0；共享首页手势修复后另两门 9 s 160 ms / 10 s 251 ms、SignHap 883 ms。源码冻结核对、318 个原事件顺序/回调逐字核对、既有主机分组策略 8 项与 Light/diff PASS。精确 checkpoint `87e384cc` 独立复核 PASS，318 事件及全部 331 个 on* 调用不变；原生容器 None 焦点规则、Flex 宽度/祖先滚动与隐私/AI边界均已核对。元数据门禁 4 s 371 ms / signed 5 s 501 ms、SignHap 913 ms，均 exit 0；不把源码检查视为设备视觉或性能证明。

## U2 主题色面板第六批（2026-09-08）

- 复用免费公共标题，增加明确关闭动作、当前色预览与受实际窗口高度约束的滚动；预设以原生 Button 和 1/2/4 自适应列排列，长标签可换行，提供颜色名称/值及已选读屏语义。选中标签与色样标记共用黑白前景策略，保留全部既有预设。
- 修正色板始终按 300 vp、旧色相条按 280 vp 计算的窗口误差；二维色板使用自身实测宽/高，忽略无有效布局、空手势和非有限坐标，越界仍按原规则截断。色相改原生 Slider，饱和度/亮度增加等价原生 Slider，灰阶保留原原生路径；支持键盘及可访问性基础语义，实际系统输入/读屏需设备确认。
- 原 11 个生命周期、RGB/HSV 转换、主题持久化/同步和通知方法逐字保留，原坐标转换仅增加无效输入保护。HostList 只传当前可用高度及已有关闭回调；不修改任何用户已有颜色、预设、购买条件或主题保存时机。
- 当前 testCompile `BUILD SUCCESSFUL in 9 s 200 ms`；signed assembleHap `BUILD SUCCESSFUL in 10 s 441 ms`、SignHap 876 ms，均 exit 0。6 组生产方法检查覆盖不同窗口同一归一化位置、完整右边界、越界、无效/未测量/空输入以及原 HSV/灰阶通知；持久化设备 API 由宿主 mock，不能据此宣称真实保存/云同步通过。源码冻结供提交复核；代码独立复核及 API23/26 字体、键盘、读屏、窗口矩阵仍待完成。

- 精确 `5ce6e5f7` + `089c9415` 已独立复核 PASS；中途 RDP 两笔提交不在本范围。按系统 fingerList 可含空索引的声明，补充跳过空槽并仅处理第一个有效触点；最后两门为 testCompile 7 s 245 ms、signed assembleHap 8 s 379 ms、SignHap 993 ms，Light/diff PASS。独立核对 875 坐标、33 无效输入、2377 列宽和 10230 标题/窗口组合，执行四个 Slider 回调及 11 稀疏/多点输入边界；实际持久化方法在平台 mock 中检查写入顺序和异常回退。设备、真实云写入与整体 U0–U4 仍待验收。

## U2 主要设置第七批（2026-09-08）

- 免费公共 `AppSettingsChoiceButton` 使用原生 Button、44 vp 最小触控尺寸、选中读屏状态与现有主题黑白前景策略。十个协议选项 builder 和三个内联偏好选项组复用该控件；原选项值、选择状态、保存函数和可用性边界保留。
- 画质、编码、远端界面、色深、操控、账号格式与 SSH 输入方式改为说明加可换行选项；移除固定像素平移的选中底板。分辨率与本地缩放仍保留全部选项和横向滚动，改为自然高度。自定义缩放、共享盘名及直连端口保留原输入校验，补足触控高度并调整窄窗口布局。
- 15 个设置折叠内容容器使用原生 Visibility.None，展开时按实际内容排版，避免旧 maxHeight 裁掉换行控件；原分区状态、折叠动画、List 滚动和偏好存储方法保留。主要行取消固定内容高度，七个内联开关和快捷退出开关取消视觉缩小，读屏名称明确；跟随系统禁用手动主题及 TOTP 身份验证回调保持。
- 通用操作行、11 个内联行、Windows 凭据和实况模式使用可聚焦原生按钮；四个加密文本操作补为 44 vp 按钮。滚轮、控制栏和缩放入口复用通用行，合并两个原有的父子重复点击。实况模式选中时自动启用、退出设置保存失败提示、账号/备份/认证路径保持原行为。
- 当前代码门禁 testCompile `BUILD SUCCESSFUL in 9 s 690 ms`；signed assembleHap `BUILD SUCCESSFUL in 11 s 32 ms`、SignHap 928 ms，均 exit 0；Light/diff PASS。首次默认沙箱编译在 DevEco 缓存 open 返回 EPERM，按授权权限重跑成功。源码检查覆盖 46 个声明 builder、55 个保持顺序与内容的事件回调，另两处相同父子动作合并；六组 selector 值序列不变，所有范围外源码（含全部业务、存储、账号和协议方法）逐字相同。两份源码 SHA256 冻结；提交后的独立复核及 API23/26 设备字体、输入、读屏和性能仍待完成。

- 第七批 `4719e6dc` 已由原 reviewer 独立复核 PASS，无待修问题。独立检查 46 个 builder 范围、55 个回调、全部 enabled 条件、八组选项序列和 15 个原生折叠容器；十个实际 choice builder 的 20 个渲染及十个回调参数/单次调用通过。另十组实际内联回调覆盖主题禁用、TOTP 认证拒绝/成功、快捷退出保存失败及实况自动启用顺序，平台认证/存储使用 mock。元数据门禁 testCompile 4 s 619 ms、signed assembleHap 5 s 713 ms、SignHap 901 ms，Light/diff PASS；API23/26 真机和整体 U0–U4 未验收。


## U2/U3 Pro 面板第八批（2026-09-08）

- 按用户当前“继续本地推进、暂缓网络风险操作”的范围，只改 `ProPurchaseSheet` 与 `ProAppIconPanel` 展示；没有部署、真实购买、联网配对或安全检查绕过。现有 M6 未提交源码和既有审查记录不属于本增量。
- 购买状态说明、价格说明、购买和恢复按钮并入同一可滚动内容区；关闭标题栏仍固定在外。操作按钮改为原生 Button 内自然高度 Text，至少 44 vp，长文本不再被固定 48 vp 高度限制。
- 功能标题/发布状态使用可换行 Flex；移除固定行高，所有文字使用公共字体。标题徽标与主要按钮复用已有主题前景对比策略，说明和操作权限没有变更。
- 图标选项采用宽度不超过 120 vp 的可换行卡片，标签不再限制两行；恢复默认和重新读取仍为原有独立操作，免费/已购/未加载/忙状态的边界保持。
- 两组件的状态、订阅及全部非 Builder 业务方法与基线 `7277a86d3` 逐字一致；8 个 onClick 与 8 个 enabled 参数逐项一致，关闭回调、ProFeatureGate 和商品/图标参数保留。单 Scroll 内的状态、购买和恢复按钮位置已核对。
- 本地 API23/API26 SDK 均支持所用 Flex wrap/space（space since12）、LengthMetrics 和公共尺寸属性；没有新增权限、协议或依赖。
- 定向 27 项 Pro runtime/policy 检查 PASS，平台调用为 mock。testCompile `BUILD SUCCESSFUL in 9 s 785 ms`；signed assembleHap `BUILD SUCCESSFUL in 8 s 865 ms`、SignHap 890 ms，均 exit 0；Light/diff PASS。
- 代码 checkpoint `dc19ebcf`；Release `BUILD SUCCESSFUL in 23 s 437 ms`、SignHap 890 ms，exit 0；冻结实包的 Pro runtime、USB Debug 与 sandbox 门剪枝 PASS，ABC `321c5bed296f91fff81120bc0793ff88ece658ff2996fcb2a129de9e5f0500a4`。独立 `/root/review_pro_ui8` 对精确两文件 PASS，无待修 finding：35 个状态/普通方法声明、8 个点击回调、8 个 enabled 条件保持；独立执行全部点击回调与 busy/product/testing 边界，27 runtime 通过，冻结 Release ABC 哈希与日志一致。实际 API23/26 Phone/Pad/PC 大字体、窄窗/矮窗、触控/键盘/读屏和图标状态未验收；本批不代表 U0–U4 全量完成。


## U2/U3 主机入口与 SSH 表单第九批（2026-09-19）

- 范围：`HostProtocolPicker.ets` 与 `SshAddFlow.ets`；checkpoint `12f342cb`，基线 `5ddda2ce8`。协议及密钥卡片改用原生 Button，协议状态放入可换行内容列；SSH 六个操作按钮改为自然高度、最小 44vp，保留父 Sheet 的 FIT_CONTENT/键盘滚动控制。
- 共享字体、主按钮黑白对比色、返回/关闭 44vp 与读屏名称、认证/密钥选中语义。状态/业务方法逐字一致；11 个 onClick、1 个 onChange 和 1 个 onError 回调 token 一致。没有主动连接、读剪贴板或云写入。
- 当前代码门禁：testCompile `BUILD SUCCESSFUL in 9 s 741 ms`；signed assembleHap `BUILD SUCCESSFUL in 11 s 346 ms`、SignHap 938 ms，均 exit 0；49 SSH + 27 分享回归、Light 和 diff PASS。
- API23/26 原生 Button/constraintSize/focusable/accessibilityText/accessibilitySelected 已核对本地声明；不引入 API26 专属依赖。实际大字体、键盘、系统 Sheet 滚动、键鼠、读屏与设备验收 NOT RUN；输入框和代理子表单并未在本批全量改造。
- 独立复核：`/root/review_pro_ui8` 复用做本次精确两文件审查，精确两文件 PASS，无待修 finding；原 M6 未提交硬化及他人审查凭据不属于本批。

- 独立复核结果：PASS exact 5ddda2ce8..12f342cb two-file scope; no findings. Independently verified 38 state/business declarations and 11 click/1 change/1 error callbacks unchanged; executed 24 protocol states, all SSH actions, five invalid-input categories and four password/key save combinations using production endpoint/proxy/business code with mocked model/vault. Independently reran 49 SSH and 27 share checks; current compile/signed HAP/Light logs and API23 compatibility verified. Device, original inputs/proxy editor/Sheet scrolling and shared M6 changes excluded.
