# VNC 产品完整性、会话控制与 Sheet 布局 V2 完备修复计划

- 计划日期：2026-07-29（Asia/Shanghai）
- 审计仓库：`RemoteDeskHarmonyOS`
- 原始审计工作树：`codex/cloud-data-lifecycle-root-fix@6a9d430b1`
- 实施基线：`main@66fba4141`
- 实施分支：`codex/vnc-product-parity-sheet-remediation-v2`
- 文档状态：代码与自动化门禁已完成，首轮独立复核的四项发现已整改，同一复核者已明确 D-020 PASS，本地分支闭环进行中；真机/多端点验收仍为发布阻塞
- 云端前置：云数据生命周期分支已通过 D-020 并快进合并到本地 `main`
- 实施优先级：P0 保存动作可达与会话可控 → P1 UI/设置一致性 → P2 RFB 画面效率与光标能力
- 云端约束：继续只使用一张物理云表 `vncrecord`

## 实施检查点（2026-07-30）

已完成并提交：

- `6fd0e4539`：VNC-only Sheet 壳层、固定 footer、设置 owner 去重、主机与
  Gateway 两步流程；
- `6e47c052c`：VNC 独立会话工具栏、只读解释、独立性能看板、组合键面板
  `onDisappear`/测量后显现与碰撞约束；
- `b742f7b12`：Cursor `-239` 协商、有界 shape/mask/hotspot 解码和会话代际隔离；
- `90f51eed9`：连接级有界 ZRLE、Raw fallback、requested/effective 诊断、设置入口、
  zlib 许可证/provenance/SBOM。

当前自动化证据：

- native `168 passed, 0 failed`；
- `default@OhosTestCompileArkTS` 通过；
- `assembleHap` 通过并生成签名 HAP；
- Light 开源合规和 `git diff --check` 通过。

未被上述证据替代的发布验收：

- API 23 真机上的 360vp/大字体/输入法/安全区布局；
- 当前签名 HAP 对 macOS Screen Sharing 的持续帧、输入、Cursor 和 Retina ZRLE；
- TigerVNC 与 UltraVNC/LibVNCServer 互操作；
- RDP、RustDesk、SSH/SFTP 真机零回归；
- 单设备、双设备和账号切换云矩阵；
- `ohosTest@OhosTestCompileArkTS` 仍因任务未注册 `00306054` 不可执行。

因此本分支可在独立源码复核通过后完成本地合并，但发布状态保持 NO-GO，不能把编译或
host-side 测试写成上述真机验收已通过。

## 0. 结论先行

当前 VNC 已经不再是“完全没有实现”，但仍没有形成与 RDP、RustDesk、SSH 一致、可发现、
可操作、能力表述可信的完整产品闭环。问题不是单个按钮的 `margin`，而是四层契约同时不完整：

1. **Sheet 布局契约不统一**：VNC 设置叶子、现代主机添加、VNC Gateway 添加都把保存/下一步
   放在正文末尾；宿主又大量使用 `SheetSize.FIT_CONTENT`。在小屏、输入法、较大字体或长文案下，
   操作栏会被推到可视区外。
2. **VNC 信息架构仍有重复入口**：主设置页已经有独立 VNC 大分组和叶子 Sheet，但
   `VncSettingsPage` 仍同时承载设置、云同步、主机、Gateway 和 trust，造成新旧入口并存。
3. **会话能力存在，但入口不可发现**：VNC 已接入共享键盘、鼠标、三指控制台、修饰键面板和
   性能 HUD 条件分支，但用户需要知道隐藏手势或侧边胶囊，且“只读/可控制”状态没有在会话首屏
   清楚解释，因此体验上仍像“只有画面，没有鼠标和键盘”。
4. **界面能力与 native 实际能力不完全对齐**：当前 RFB engine 只协商
   Raw、CopyRect、DesktopSize、LastRect；没有 Cursor pseudo-encoding、ZRLE、Tight 或
   ContinuousUpdates。所谓“自动编码/画质”实际主要影响色深和请求节流，不能继续让用户误以为
   已具备完整自适应画质。

V2 的修复策略是：

- 新增 **VNC 专属 Sheet 壳层**，统一为“固定标题 + 可滚动正文 + 固定安全区操作栏”；
- 现代 VNC 添加流程压缩为两段式，编辑仍保持其他主机熟悉的经典卡片风格；
- VNC Gateway 只在第三页中继目录维护，且只开放当前真实可用的 UltraVNC Repeater viewer
  模式；
- VNC 会话增加可见工具栏，直接提供鼠标、键盘、组合键、缩放、性能看板和断开；
- native 按“先 Cursor 和能力真实性，再 ZRLE，最后评估 Tight/ContinuousUpdates”的顺序升级；
- 全程保持 VNC 数据、设置、secret、trust、Gateway、会话和云投影与其他协议隔离。

## 1. 实施前分支门禁

云数据生命周期任务已在 `main@66fba4141` 完成 D-020、快进合并和分支清理。工作树仍有
SSH、Moonlight、RustDesk、RDP 等用户自有计划文件；它们不属于本计划，不得在 VNC 实施中被
暂存、提交、覆盖、stash 或 reset。本计划文件本身从此作为 VNC 任务的实体计划纳入版本控制。

实施开始前必须满足：

1. `codex/cloud-data-lifecycle-root-fix` 已完成验证、复核、合并和清理。
2. 已重新读取 `docs/codex/CURRENT.md`、`QUEUE.md`、`DECISIONS.md`、
   `HANDOFF.md`，并确认剩余未提交文件均为不重叠的用户自有计划。
3. 已从最新本地 `main@66fba4141` 新建唯一任务分支：
   `codex/vnc-product-parity-sheet-remediation-v2`。
4. 记录合并后的账号 scope、云生命周期和 SensitiveDataBarrier 契约；VNC 不得绕回旧的
   `"local"` owner fallback。
5. 先在真机复现并保存一份脱敏基线：VNC 连接、首帧、持续帧、输入、光标、Sheet 截图和
   性能 HUD；不能用旧 session 日志代替新基线。

本计划不重新审查已经通过的事项：

- VNC 主机投影到经典主机卡片的方案；
- VNC 卡片已有的编辑、上锁/解锁、删除和连接分流；
- 密码“不记住也可连接”、未启用应用加密时的明确风险确认；
- `vncrecord` 单表、五种逻辑记录、云同步选择和 trust 本机确认；
- 上一轮 framebuffer 几何同步和悬浮面板横竖屏比例迁移；
- UltraVNC Repeater viewer mode12 的既有协议边界；
- WebSocket Gateway/SSH tunnel 二阶段服务端与 transport 计划。

若新实机证据证明上述实现仍有缺陷，只针对证据指向的最小范围补充任务，不得重新设计整个
已通过模块。

## 2. 当前代码事实与根因矩阵

### 2.1 保存按钮过低

| 表面 | 当前事实 | 根因 | V2 处理 |
| --- | --- | --- | --- |
| VNC 设置叶子 | `VncSettingsSheet.ets` 的连接、超时、显示、输入、性能、剪贴板、安全、云同步共 8 个保存按钮都位于内部 `Scroll` 内容末尾 | 外层最大高度约 620vp，保存动作与正文一起滚动 | 保存/取消移到固定 footer，正文只承载字段 |
| 现代 VNC 主机添加 | `VncAddFlow.ets` 为 4 步；`actionBar()` 在正文之后，组件自身没有受约束的滚动正文 | `HostListPage` 对现代 VNC 使用 `FIT_CONTENT`，长步骤、输入法和错误文案可把操作栏推出屏幕 | 两步式 + VNC Sheet 壳层 + `RESIZE_ONLY` |
| 经典 VNC 编辑 | 已使用 `SheetSize.LARGE`、VNC 内容区滚动和外部 footer | 近期修复方向正确 | 保留经典风格，只补统一验收，不重做已通过布局 |
| VNC Gateway 添加 | `VncGatewayAddFlow.ets` 为 3 步；操作栏在正文后；第三页宿主使用 `FIT_CONTENT` | 类型卡、端点字段、令牌、安全状态累积后高度超限 | 两步式 + 固定 footer；不改 RustDesk 原中继表单 |
| 旧 VNC 主机管理页 | `VncSettingsPage.ets` 的主机 flow 使用 `FIT_CONTENT`，页面内还保留设置、云同步和 Gateway 保存按钮 | 新旧信息架构并存，布局与 owner 入口重复 | 退化为 VNC 主机目录，不再维护重复设置/Gateway 表单 |
| 会话密码 Sheet | `RemoteDesktop.ets` 使用 `FIT_CONTENT` | 当前内容较短，但输入法、错误文案和大字体仍需验证 | 纳入统一可达性测试；只有实测失败才迁移壳层 |

“把按钮上移 20vp”不是可接受修复。正确不变量是：

```text
Sheet 可用高度
  = 固定标题
  + 可滚动正文（layoutWeight=1）
  + 固定操作栏
  + 底部系统安全区
```

正文内容再长，也只能压缩正文 viewport，不能挤走操作栏。

### 2.2 与其他主机 UI 的差距

| 维度 | RDP | RustDesk | SSH | 当前 VNC | 目标 |
| --- | --- | --- | --- | --- | --- |
| 现代添加节奏 | 2 步 | 3 步 | 2 步 | 4 步 | 2 步，复杂项折叠 |
| 编辑风格 | 经典主机表单 | 经典主机表单 | 经典主机表单 | 已接入经典表单 | 保留，不改回独立大页 |
| 主机卡操作 | 编辑/锁/删除/连接 | 同左 | 同左并有 SSH 特有动作 | 已复用同一卡片动作 | 保持投影，不自建第二套卡片 |
| 设置位置 | 独立协议分组 | 独立协议分组 | 独立协议分组 | 已位于 SSH 下方 | 保持顺序，不移入云端数据 |
| 中继资源 | 不适用 | 第三页原生目录 | 不适用 | 已进入第三页，但添加流过长 | 仅给 VNC 卡打标签，不增加页级切换 |
| 会话控制 | 可见/成熟 | 顶栏、鼠标、键盘、看板 | 终端原生输入 | 依赖隐藏手势/胶囊 | VNC 可见工具栏 + 保留手势快捷入口 |

V2 不要求把 RDP/RustDesk/SSH 的所有 Sheet 一并重构。新增壳层只服务 VNC，以避免把
VNC 修复扩大为其他协议的 UI 回归。

### 2.3 VNC 设置的信息架构问题

主设置页已有合理的 VNC 独立分组和叶子入口，但叶子字段仍重复：

- “连接”叶子同时包含默认 transport、默认端口、三个 timeout 和安全策略；
- “超时”叶子再次包含三个 timeout；
- “安全”叶子再次包含安全策略；
- `VncSettingsPage` 又保留一份大而全的设置和 Gateway 表单。

因此用户会看到多个“看起来都能改同一件事”的入口。V2 必须固定单一 owner：

| 责任 | 唯一 UI owner |
| --- | --- |
| 默认 transport、端口、默认 Gateway | VNC／连接默认值 Sheet |
| connect/auth/first-frame timeout | VNC／超时 Sheet |
| 本地缩放、画质、编码、色深、帧率 | VNC／显示与画面 Sheet |
| 控制模式、光标、速度、滚轮、按键交换、只读默认 | VNC／输入与光标 Sheet |
| HUD、采样频率、指标范围 | VNC／性能监视 Sheet |
| 文本剪贴板 | VNC／剪贴板 Sheet |
| TLS、安全策略 | VNC／安全 Sheet |
| trust | VNC／Trust Sheet |
| 云同步 scope | VNC／云同步 Sheet |
| 主机 CRUD | 远程主机页经典卡片 + VNC 主机目录 |
| Gateway CRUD | 第三页中继服务器目录 |

导航型叶子（主机目录、Gateway 目录、trust 空态）不显示伪“保存”按钮。

### 2.4 会话 UI 与输入问题

代码已经允许 VNC 进入以下共享能力：

- 触控板、直接触控、键鼠三种控制模式；
- 虚拟键盘和组合键；
- 三指点击打开本地控制台；
- 侧边修饰键胶囊及快捷键面板；
- VNC 独立的 HUD 开关、采样频率和指标 mask；
- view-only 时阻止 native 键鼠发送；
- server cursor 不可用时的本地圆点/箭头回退。

但当前可发现性不足：

1. VNC 没有会话内常驻/自动收起工具栏，用户不知道三指手势和长按胶囊。
2. view-only 状态没有在画面上持续显示，用户可能把“配置为只读”理解成鼠标故障。
3. HUD 使用名为 `RustDeskDiagnosticsHud` 的组件，即使设置来源独立，代码语义和后续维护仍
   容易串线。
4. 从控制 Sheet 打开组合键悬浮面板依赖固定延时；Sheet 尚未完成退场或面板尚未测量时，
   可能以 fallback 尺寸定位，随后再重排，看起来就是“展开后漂移”。
5. 当前浮层 viewport 主要使用 Surface 尺寸和固定顶部/底部 margin；输入法、安全区、HUD、
   会话工具栏和不同字体尺寸的碰撞需要统一建模。

### 2.5 画面、光标与性能能力差距

当前 native RFB engine 的 `SetEncodings` 只请求：

- Raw `0`
- CopyRect `1`
- DesktopSize `-223`
- LastRect `-224`

并且收到未知 framebuffer encoding 时直接失败。现状的优点是小、可审计、fail-closed；
缺点是：

- 远端高分辨率 Mac 使用 Raw 时，单个完整画面可能达到数十 MB，容易出现高带宽、高 CPU、
  解码/送显背压和明显卡顿；
- 未请求 Cursor `-239`，无法可靠得到服务器真实 cursor shape；
- `preferredEncoding=auto` 与 `raw` 在 native 中没有可观察差异；
- “画质预设”主要改变色深，并不等于 Tight/JPEG 或完整自适应画质；
- 没有 capability/effective 值时，HUD 只能显示“请求值”，不能解释服务器最终实际行为。

RFB 标准明确规定 framebuffer 更新、PointerEvent、KeyEvent、Cursor 和 DesktopSize；
Cursor 由客户端请求后可在本地绘制，能显著改善慢链路的感知性能。ZRLE 是 RFC 6143 标准
压缩编码；Tight 和 ContinuousUpdates 属于注册扩展，不能在没有解析器、边界检查和互操作
测试时直接打开。

## 3. 官方依据与采用结论

### 3.1 RFB/VNC

- [RFC 6143 — The Remote Framebuffer Protocol](https://www.rfc-editor.org/rfc/rfc6143.html)：
  采用版本协商、SetEncodings、FramebufferUpdate、PointerEvent、KeyEvent、ZRLE、
  Cursor 和 DesktopSize 的标准语义。
- [IANA RFB Registry](https://www.iana.org/assignments/rfb/rfb.xhtml)：
  采用 Raw `0`、CopyRect `1`、ZRLE `16`、Cursor `-239`、DesktopSize `-223` 的注册值；
  Tight `7`、ContinuousUpdates `-313` 必须作为显式扩展能力处理。
- [RealVNC 移动端控制说明](https://help.realvnc.com/hc/en-us/articles/360018541231-Using-RealVNC-Viewer-for-Mobile-to-control-a-remote-device)：
  移动 viewer 应提供可见工具栏、虚拟键盘、特殊键栏、鼠标模式、缩放、点击、拖动和滚动，
  不能只依赖用户猜测手势。
- [RealVNC 画质与性能说明](https://help.realvnc.com/hc/en-us/articles/360002321097-What-can-I-do-to-boost-picture-quality-or-performance)：
  画质和性能是可解释的权衡；Quality、ColorLevel、PreferredEncoding 必须映射到真实能力。
- [RealVNC Viewer 参数参考](https://help.realvnc.com/hc/en-us/articles/360002254618-RealVNC-Viewer-Parameter-Reference)：
  采用 scaling、pointer、quality 和编码概念，但不照搬桌面版不可用于移动端的参数。
- [TigerVNC 官方仓库](https://github.com/TigerVNC/tigervnc)及
  [官方 release](https://github.com/TigerVNC/tigervnc/releases)：
  参考快捷键系统、系统键转发、标准箭头 fallback 和更细缩放，不复制其 UI 或代码。
- [UltraVNC 官方仓库](https://github.com/ultravnc/UltraVNC)及
  [Repeater 说明](https://sc.uvnc.com/docs/ultravnc-repeater.html)：
  继续把 Repeater 作为独立 VNC 资源；viewer/server 角色不可混淆。

采用边界：

- 不把 RealVNC/TigerVNC 专有云服务、账号体系或许可证代码移入项目。
- 上游只作为协议、交互和测试基准；native 实现继续走本项目可审计边界。
- Tight/ZRLE 不能只增加 UI 选项；必须先完成 decoder、安全边界、fuzz 和真实服务端互操作。

### 3.2 macOS

- [Apple：打开或关闭 Mac 屏幕共享](https://support.apple.com/en-lb/guide/mac-help/mh11848/mac)：
  Mac 必须打开屏幕共享、关闭冲突的 Remote Management，并允许 VNC viewer 使用密码控制。
- [Apple：屏幕共享连接设置](https://support.apple.com/en-gb/guide/mac-help/mchl67d5398b/mac)：
  标准 Mac 屏幕共享默认端口为 5900。

产品结论：

- 正常的 VNC→Mac 体验应是持续显示 Mac 当前桌面，并能发送鼠标和键盘输入。
- 本地“适应窗口/100%/缩放/平移”只改变 viewer 呈现，不改变 Mac 的远端分辨率。
- 标准 RFB 的 DesktopSize 是服务端报告尺寸，不等于 viewer 可强制 Mac 切换分辨率。
- Apple High Performance Screen Sharing、虚拟显示和 Apple 账户认证不在本 VNC 标准模式承诺内。

### 3.3 HarmonyOS API 23

- [华为：开发应用沉浸式效果](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/arkts-develop-apply-immersive-effects)：
  可交互元素不应落入底部导航避让区；`safeAreaPadding` 可为组件提供安全区，Scroll/List 可利用
  该约束。
- 本地 API 23 `common.d.ts` 已确认：
  `SheetSize.FIT_CONTENT` 随内容适配；`SheetKeyboardAvoidMode.RESIZE_ONLY` 只调整 Sheet
  可用内容高度；默认键盘避让为 `TRANSLATE_AND_SCROLL`；`safeAreaPadding` 自 API 14 可用。

采用结论：

- VNC 长表单不能把 `FIT_CONTENT` 当成“永远能完整显示”的保证。
- 移动端长 Sheet 使用受控大高度或最大可用高度；输入法出现时只收缩正文 viewport。
- footer 必须在 Sheet 内容结构内固定并使用底部安全区，不能靠增大 bottom margin 猜测导航栏。
- 所有 API 先以本地 API 23 declaration 和两项 Hvigor 门禁为准。

## 4. 目标产品体验

### 4.1 VNC→Mac 正常会话

连接成功后，用户应直接看到：

1. 持续刷新的 Mac 当前桌面，不停留在第一帧。
2. 一个默认自动收起但可重新唤出的 VNC 工具栏。
3. 当前状态标签：`可控制` 或 `只读`，以及 `直连`/`Repeater`。
4. 触控板模式下始终可见的本地预测光标；服务器 cursor 可用时显示真实 shape。
5. 工具栏直接提供：键盘、鼠标模式、组合键、显示、性能、更多/断开。
6. 三指控制台和侧边胶囊继续作为快捷方式，而不是唯一入口。
7. 缩放/旋转/远端 DesktopSize 后，画面、点击坐标、光标和 HUD 使用同一 framebuffer 几何。

### 4.2 VNC 设置

设置页顺序固定为：

```text
Windows RDP
RustDesk
SSH 终端
VNC
数据安全
```

VNC 大分组保留以下叶子：

1. 连接默认值
2. 超时
3. 显示与画面
4. 输入与光标
5. 性能监视
6. 剪贴板
7. 安全
8. Trust
9. VNC 云同步范围
10. VNC 主机目录
11. 前往第三页管理 VNC Gateway

每个设置叶子只出现一个固定 footer。字段未变化时保存禁用；变化后保存始终可见。保存失败保留
草稿和错误，退出时沿用现有“继续编辑/放弃修改”生命周期。

### 4.3 现代 FAB 添加

现代 VNC 添加压缩为两步：

#### 第一步：主机

- 连接方式：TCP 直连或已保存的 VNC Repeater；
- 名称；
- 直连时：地址、端口；
- Repeater 时：Gateway、target ID，端口由 Gateway owner 显示为只读摘要；
- 没有可用 Gateway 时，提供“前往第三页添加”，先关闭 Sheet，待 `onDisappear` 后跳转。

#### 第二步：访问与控制

- VNC 密码；
- 记住密码；
- TLS/安全策略；
- 默认控制状态：可控制或只读；
- 文本剪贴板；
- “高级显示”折叠项：是否覆盖全局缩放；
- 页面内显示非敏感摘要，不再单独占一个“确认”步骤；
- 固定 footer：上一步、保存、保存并连接。

人因规则：

- 默认值与设置 service 一致，文案不能再出现 `viewOnly=false` 却写“默认只读”的矛盾。
- 密码不回显，留空保留已保存密码；关闭记住密码后保存会按既有 owner 规则清除。
- 云同步 scope 不出现在主机添加流程；保存密码与是否同步继续解耦。
- 保存并连接必须等待 Sheet `onDisappear`，只传稳定 VNC host ID 和短生命周期 handoff。

### 4.4 经典主机编辑

从主机卡片点“编辑”继续使用经典主机表单，不强制用户进入两步向导。实现时：

- 复用同一 `VncHostDraft`、校验器和字段 section builder；
- 经典编辑只改变呈现方式，不复制保存、secret 或 cloud 逻辑；
- 固定 footer 始终可见；
- 更改名称、地址、端口、控制、显示、安全等任一字段都能保存，不依赖密码输入；
- 保留主机卡既有编辑、锁、删除、连接图标和经典卡片外观；
- 不改变 RDP/RustDesk/SSH 的经典表单。

### 4.5 第三页 VNC Gateway

第三页不增加“VNC/RustDesk”页级切换。目录卡片只通过协议标签区分：

- `RustDesk 中继`
- `VNC Gateway`

RustDesk 原添加、导入、Server Pro、账户、健康检测和编辑流程保持原样。

VNC Gateway 添加压缩为两步：

1. **端点**：名称、服务器地址、端口、target ID；
2. **安全与启用**：TLS、启用状态、非敏感摘要、保存。

当前只允许创建/启用 `UltraVNC Repeater viewer mode12`。WebSocket Gateway 和 SSH tunnel
在二阶段真正完成前：

- 不作为可点击的 transport 卡；
- 可在只读“规划能力”说明中展示，但不能进入下一步或保存为“看似可用”；
- 已有旧记录仍可在卡片上显示“不可用原因”，运行时继续 fail-closed。
- mode12 表单不展示没有进入当前 pairing/transport 的 Gateway token；已有 token 保持
  write-only，不删除、不回显。只有未来 WebSocket Gateway 服务端契约正式启用后，才在其
  专属流程中展示 token 输入。

## 5. VNC 专属 Sheet 架构

新增 VNC-only 组合组件，建议命名为：

```text
entry/src/main/ets/components/vnc/VncSheetScaffold.ets
```

职责仅限布局，不读取 VNC service 或其他协议状态：

```text
VncSheetScaffold
├── header（固定）
├── body Scroll（layoutWeight=1）
│   └── content builder
└── footer（固定 + safeAreaPadding bottom）
    └── actions builder
```

接口应包含：

- `title`、`subtitle`、`icon`；
- `onClose/onBack`；
- `contentBuilder`；
- `footerBuilder`；
- `busy/dirty/errorSummary`；
- 断点和 keyboard state 所需的纯布局输入；
- footer 按钮最小高度、焦点和无障碍 label。

约束：

1. Scaffold 不调用 `VncSettingsService`、`VncHostService` 或 `VncGatewayService`。
2. 不抽成全协议公共组件，不修改 RDP/RustDesk/SSH Sheet。
3. 小屏使用大 Sheet/最大可用高度，Pad/PC 使用居中最大宽度与受控最大高度。
4. 宿主使用 `SheetKeyboardAvoidMode.RESIZE_ONLY`。
5. header/footer 不在 Scroll 内；错误可放在正文顶部或 footer 上方的稳定区域。
6. footer 背景延伸到导航区域，按钮本身位于 `safeAreaPadding` 内。
7. 关闭、返回和系统 dismiss 都由现有单一 Sheet owner 收尾，不嵌套第二个 `bindSheet`。
8. 字体 200%、输入法打开和 360vp 宽度下，至少一个主动作完整可见并可点击。

## 6. 会话控制架构

### 6.1 VNC 专属会话工具栏

建议新增 `VncSessionToolbar.ets`，只在 `isVncSession()` 且已连接时渲染。它只接收状态快照和
动作回调，不读取 RustDesk/RDP 设置。

最小动作：

- 显示/隐藏虚拟键盘；
- 切换触控板/直接触控/键鼠；
- 打开修饰键与组合键；
- 打开显示菜单：适应、100%、整数缩放、自定义；
- 当前会话显示/隐藏性能看板；
- 打开完整控制台；
- 断开。

工具栏 20 秒无操作后收起为可见手柄；首次 VNC 连接完成时显示一次短提示。三指手势和侧边胶囊
保留，但帮助文案必须能在控制台内再次查看。

### 6.2 view-only 可解释

- 会话左上角或工具栏显示 `只读` 标签。
- 鼠标/键盘动作禁用时显示原因，不静默吞掉。
- “切换为可控制”只能改变当前 host/session 的 VNC 设置，不得绕过服务端权限。
- 若 Mac 未允许 VNC viewer 控制，native/服务端拒绝必须显示为权限问题，而不是鼠标故障。

### 6.3 组合键悬浮面板漂移

不替换上一轮已通过的横竖屏比例存储，只修复打开时序和碰撞：

1. 控制 Sheet 中点击“组合键”时只写入 `pendingFloatingPanelAction` 并请求关闭 Sheet。
2. 在控制 Sheet `onDisappear` 中确认当前 session/generation 后再 mount 面板；删除固定
   `200ms` 猜测。
3. 首次 mount 等待面板 `onAreaChange` 得到真实尺寸，再从 handle anchor 计算最终位置。
4. 未测量前保持不可见或轻量占位，不先显示 fallback 位置再跳动。
5. viewport 同时扣除状态栏、导航区、输入法、VNC 工具栏和已展开 HUD。
6. shortcut companion 优先放在 modifier panel 对侧；空间不足时上下翻转，再做 clamp。
7. Surface、方向、字体、键盘高度或 HUD 状态变化时，仅重新 clamp；用户主动拖动过的位置继续
   使用当前方向的比例。
8. 无效/旧版比例只清理 VNC/当前方向对应键，不清除其他协议用户位置。

### 6.4 VNC 性能看板隔离

新增 `VncDiagnosticsHud.ets` 或 VNC adapter + 协议中立的纯显示层。最低要求：

- VNC 设置来源只读 `VncSettingsService`；
- RustDesk 的 Pro entitlement、刷新频率和展开状态不能影响 VNC；
- 显示 requested/effective 两组能力：
  - 编码；
  - 色深；
  - 帧率上限；
  - 实际 framebuffer；
- 显示连接/首帧时间、server updates、rectangles、decoded/presented frames、FPS、最近帧年龄、
  timeout、drop/backpressure；
- 默认关闭，用户可在设置或当前会话工具栏打开；
- HUD 位置只保存在本机，不进入 `vncrecord`。

为了隔离风险，优先新建 VNC 组件；只有确认现有 RustDesk HUD 纯显示层完全无业务耦合时，才
允许抽取协议中立 view，并必须通过 RustDesk 截图/行为回归。

## 7. native RFB 分阶段修复

### 7.1 P0：能力真实性和持续画面证据

在改编码前先完成可观测性和持续帧验收：

- 为每次 SetEncodings 记录脱敏的 requested/effective 列表；
- 区分 server framebuffer update、decoded frame、renderer accepted、presented frame；
- 记录最近帧年龄、请求序号和连接 generation；
- request/receive/present 任一阶段停滞都给稳定错误分类；
- frame-rate limit 不得在接收线程上造成不可取消的长阻塞；
- Mac 大尺寸 Raw update 下验证内存上限、脏区合并和 Surface 重建；
- HUD 不再把 `auto` 显示成未知的高性能编码，当前 effective 应明确为 `Raw/CopyRect`。

若实机仍“只有第一帧”，先凭上述四段计数确定断点，再修改最小链路；不能先假定是 Mac、
网络、解码器或 renderer。

### 7.2 P0：Cursor pseudo-encoding

优先实现 RFC 6143 Cursor `-239`：

- SetEncodings 中请求 Cursor；
- 有界解析 cursor width/height、hotspot、pixel data 和 mask；
- 0×0 cursor 语义、透明 mask、畸形长度和超大 cursor fail-closed；
- generation-safe 地发布 cursor shape/revision；
- server cursor 可用时显示真实 shape；
- server 不支持、shape 为空或解析失败时回退本地箭头/圆点；
- 任何模式都不得同时隐藏系统指针和本地/远端 VNC 指针。

### 7.3 P1：ZRLE

ZRLE `16` 是首选压缩升级：

1. 固定 zlib 依赖、许可证、SBOM 和安全版本；
2. 实现连接级连续 zlib stream；
3. 严格限制压缩长度、解压长度、tile 数、palette、run length 和像素乘法；
4. 对 truncated、zip bomb、非法 subencoding、边界 tile、色深变体增加单元测试和 fuzz corpus；
5. 与 macOS Screen Sharing、TigerVNC、UltraVNC/LibVNCServer 各至少一个真实端点互操作；
6. `auto` 仅在 ZRLE 通过 capability gate 时优先 ZRLE，否则回退 Raw；
7. HUD 显示最终 server 选中的 effective encoding。

### 7.4 P2：Tight 与 ContinuousUpdates

Tight `7` 和 ContinuousUpdates `-313` 不与 ZRLE 同批强行上线：

- Tight 先完成协议/安全/许可证评审，尤其 JPEG 质量映射和畸形数据边界；
- ContinuousUpdates 先确认服务端支持、enable/disable 消息、断线和背压；
- 未通过完整门禁前不显示可选项；
- 不支持时继续使用标准 FramebufferUpdateRequest；
- native 顶部注释必须与真实支持编码一致，删除“已支持 Tight/ZRLE”的错误表述。

## 8. 设置字段与能力表述

当前已有设置字段优先复用，不为 UI 重排新增同义字段：

| UI | 当前字段 | V2 语义 |
| --- | --- | --- |
| 本地缩放 | `displayScaleMode/customScalePercent/scalingMode` | viewer 本地呈现，不承诺改变 Mac 分辨率 |
| 画质预设 | `imageQualityPreset` | 显示“传输负载/色深策略”；只有真实编码支持后才升级为完整画质 |
| 编码 | `preferredEncoding` | requested；HUD 同时显示 effective |
| 色深 | `colorDepth` | requested/effective 分开 |
| 帧率 | `frameRateLimit` | 请求节流上限，不承诺服务器固定 FPS |
| 光标 | `localCursorMode` | 服务器 cursor + 本地 fallback 策略 |
| 控制模式 | `controlMode` | 触控板/直接触控/键鼠 |
| 性能看板 | `showDiagnostics` 等 | VNC 独立，不读取 RustDesk 设置 |

显示与画面 Sheet 的能力分层：

- **本地显示**：立即可用——适应、100%、整数、自定义缩放；
- **传输**：按 native capability 动态可用——Raw、ZRLE、未来 Tight；
- **远端尺寸**：只读显示 server reported framebuffer；
- **远端分辨率控制**：标准 Mac VNC 中明确“不支持由 viewer 强制切换”。

## 9. 云同步、加密和数据边界

本计划不增加第二张云表，也不要求用户修改 AGC 表结构。

唯一物理表：

```text
vncrecord
```

逻辑记录继续为：

```text
settings / host / gateway / secret / trust
```

V2 规则：

1. 纯 UI 布局、工具栏、HUD 位置、悬浮面板位置不进入云端。
2. 当前设置字段已存在时，不升级 payload schema。
3. 只有真正新增持久字段时才提升 payload schemaVersion；旧行缺失字段使用安全默认值。
4. requested/effective 的 runtime capability 中，只有用户 requested 设置可进入 `settings`；
   effective/server capability 永远本机临时保存。
5. 密码和 Gateway token 继续服从“记住密码/令牌 + crypto 状态 + 用户确认”，不因云同步开关
   自动要求启用应用加密。
6. `settings/hosts/gateways` 元数据同步不依赖 secret scope。
7. 新设备 cloud-first、owner scope、reset epoch、quarantine 和 SensitiveDataBarrier 以当前云
   生命周期分支最终契约为准；VNC 不另建旁路。
8. trust 云记录只同步观察值，新设备仍需本机确认。
9. 不写 `remotehosts`、`rustdeskrelays`、`usersettings` 或 SSH key 表。
10. 不修改现有 `vncrecord` 物理字段；若实施发现必须改物理 schema，立即停止并另行评审。

## 10. 分阶段实施任务

### 阶段 A：冻结基线与新增失败测试

目标：在不改产品行为前，把问题变成可判定门禁。

任务：

- 记录当前分支、SDK、真机、Mac、VNC server、分辨率和网络拓扑；
- 补 `VncSheetLayoutPolicy` 纯策略测试：
  - 小屏/大字体/键盘时 footer 可达；
  - header/footer 高度和 body 最小高度；
  - bottom safe area；
- 补 VNC add/gateway step policy 测试；
- 补 pending panel action/onDisappear 生命周期测试；
- 补浮层与 safe area/keyboard/HUD 碰撞测试；
- 补 requested/effective capability policy 测试；
- 保存 360vp、Pad、PC 的当前 UI 截图作为差异基线。

验收：

- 测试能在旧实现上准确暴露至少一个 footer/时序失败；
- 不修改 RDP/RustDesk/SSH snapshot；
- 脱敏日志不含密码、token、完整 fingerprint 或 target secret。

### 阶段 B：VNC Sheet 壳层与按钮可达性

目标：一次解决全部“按钮太低”。

修改范围：

- 新增 `components/vnc/VncSheetScaffold.ets`；
- `VncSettingsSheet.ets`；
- `HostListPage.ets` 中 VNC settings/add 的 Sheet 参数；
- `VncAddFlow.ets`；
- `VncGatewayAddFlow.ets`；
- `RustDeskRelayPage.ets` 仅调整 VNC `sheetContent=10` 的宿主参数；
- 必要时 `VncSettingsPage.ets` 的 VNC host flow。

禁止：

- 改 RustDesk relay editor builder；
- 改 RDP/RustDesk/SSH add flow；
- 修改保存、crypto、cloud 或 native。

验收：

- 任一 VNC 表单打开后无需滚动即可看到主动作；
- 输入法出现后 footer 完整可见；
- 正文可滚动但 footer 不动；
- 关闭未保存设置仍触发现有拦截；
- 360vp、字体 200%、三键导航下按钮未被吃掉。

### 阶段 C：设置去重与主机/Gateway 流程

目标：把 VNC 产品入口固定为单一 owner。

任务：

- “连接默认值”移除 timeout 和安全字段；
- timeout、安全、显示、输入、性能、剪贴板分别只保存自己的字段；
- 现代主机添加改为两步；
- 经典编辑保留单页并复用相同 draft/validator；
- `VncSettingsPage` 改为 VNC 主机目录，删除重复设置和 Gateway CRUD 呈现；
- Gateway 添加改为两步，只开放 mode12；
- WebSocket/SSH tunnel 从可点击 transport 中移除；
- 设置页到第三页跳转等待 Sheet `onDisappear`；
- 清理矛盾的 view-only 默认文案。

验收：

- 同一字段只有一个设置入口；
- 编辑任一非密码字段都能保存；
- 保存密码和云同步选择继续解耦；
- RustDesk 中继添加流程截图与行为无变化；
- 第三页没有页级协议切换，卡片标签足以区分 owner。

### 阶段 D：VNC 会话工具栏与悬浮面板稳定性

目标：连接后无需学习隐藏手势即可控制。

任务：

- 新增 `VncSessionToolbar.ets`；
- 接入键盘、鼠标模式、组合键、显示、HUD、控制台、断开；
- 显示 `只读/可控制`；
- 用 `onDisappear + pending action` 替代固定延时；
- 等待面板真实尺寸后再显示；
- 扩展浮层 viewport 碰撞模型；
- 保留三指控制台和侧边胶囊。

验收：

- VNC 连接后 1 秒内看得到控制入口；
- 虚拟键盘、特殊键、左/右/中键、滚轮、拖动均可达；
- 组合键面板首次展开不跳位；
- 横竖屏、输入法和 HUD 开关后面板仍在可视区；
- view-only 的禁用原因明确。

### 阶段 E：VNC 性能看板隔离

目标：VNC 有自己的可验证性能实况。

任务：

- 新增 VNC diagnostics view/adapter；
- requested/effective 分开；
- 接入 update/decode/present/frame age/backpressure；
- 会话工具栏支持临时开关；
- 设置页支持默认开关、展开和采样；
- HUD 位置本地化存储。

验收：

- 关闭 RustDesk Pro 或修改 RustDesk HUD 不影响 VNC；
- VNC HUD 不读取 RustDesk setting；
- HUD 显示真实 Mac framebuffer；
- `auto` 能显示最终 Raw/ZRLE；
- HUD 本身不造成可测的明显帧率下降。

### 阶段 F：Cursor 与 native 持续画面

目标：任何可控会话都有可见鼠标，持续画面链路可诊断。

任务：

- 增加 Cursor pseudo-encoding；
- 补 shape/mask/hotspot 安全解析；
- 接入现有 remote cursor snapshot；
- 统一 fallback；
- 补四段 frame 计数和稳定错误分类；
- 修正 native 能力注释。

验收：

- Mac 有 cursor shape 时显示真实指针；
- 无 cursor shape 时仍有本地指针；
- 点击坐标与指针位置一致；
- 窗口拖动、Dock、菜单、文本输入持续刷新；
- 断开/重连/旋转无旧 cursor 或旧 frame 污染。

### 阶段 G：ZRLE

目标：高分辨率 Mac 不再长期依赖高开销 Raw。

任务：

- zlib provenance/合规；
- ZRLE decoder、bounds、fuzz；
- capability negotiation 和 fallback；
- 设置/HUD effective 映射；
- 多服务端互操作。

验收：

- 2940×1912 或更高分辨率下带宽/CPU/帧延迟相对 Raw 有明确改善；
- malformed 数据 fail-closed；
- 不支持 ZRLE 的服务端自动使用 Raw；
- 不因编码切换破坏 CopyRect/DesktopSize；
- 没有新增不受控内存增长。

### 阶段 H：完整回归、复核和分支闭环

任务：

- 两项 Hvigor 强制门禁；
- ArkTS policy/unit tests；
- native protocol/security tests；
- `git diff --check`；
- Light 开源合规、NOTICE/SBOM；
- API 23 真机测试；
- Mac、TigerVNC、UltraVNC/LibVNCServer 互操作；
- 独立 reviewer 按隔离、UI、native、安全四个维度复核；
- 修复发现后重新执行全量门禁；
- 合并回本地 `main`，清理任务分支；
- 未经用户授权不 push、不创建 PR、不合并远端 `main`。

## 11. 目标文件清单

### VNC UI

- `entry/src/main/ets/components/vnc/VncSheetScaffold.ets`（新增）
- `entry/src/main/ets/components/vnc/VncSessionToolbar.ets`（新增）
- `entry/src/main/ets/components/vnc/VncDiagnosticsHud.ets`（新增或 VNC adapter）
- `entry/src/main/ets/components/VncSettingsSheet.ets`
- `entry/src/main/ets/components/hostadd/VncAddFlow.ets`
- `entry/src/main/ets/components/resourceadd/VncGatewayAddFlow.ets`
- `entry/src/main/ets/pages/HostListPage.ets`
- `entry/src/main/ets/pages/VncSettingsPage.ets`
- `entry/src/main/ets/pages/RustDeskRelayPage.ets`（只允许 VNC sheet host 的最小 hunk）
- `entry/src/main/ets/pages/RemoteDesktop.ets`

### 纯策略与测试

- `entry/src/main/ets/services/VncSheetLayoutPolicy.ets`（建议新增）
- `entry/src/main/ets/services/VncHostFlowPolicy.ets`（按需要新增）
- `entry/src/main/ets/services/RemoteFloatingPanelPlacementPolicy.ets`（只做兼容扩展）
- 对应 `entry/src/test` 和 `entry/src/ohosTest/ets/test` 测试；
- 不把 VNC policy 写入 RustDesk settings/service。

### native

- `entry/src/main/cpp/vnc/vnc_rfb_engine.h/.cpp`
- `entry/src/main/cpp/vnc/vnc_rfb_protocol.h/.cpp`
- `entry/src/main/cpp/vnc/vnc_adapter.cpp`
- VNC cursor/frame diagnostics 的 N-API 边界；
- `entry/src/main/cpp/test/vnc_*`
- fuzz corpus/target（按项目现有 native 测试框架落位）。

## 12. 建议提交序列

每个提交只包含当前任务列出的文件：

1. `test(vnc): cover sheet reachability and session capability policies`
2. `fix(vnc-ui): keep every vnc sheet action visible`
3. `refactor(vnc-ui): simplify host and gateway flows`
4. `fix(vnc-ui): remove duplicate vnc settings owners`
5. `feat(vnc-session): expose complete in-session controls`
6. `fix(vnc-session): stabilize modifier and shortcut panel placement`
7. `feat(vnc): isolate diagnostics hud and effective capabilities`
8. `feat(vnc-native): negotiate and render server cursor`
9. `feat(vnc-native): add bounded zrle decoding`
10. `test(vnc): complete mac and cross-protocol regression coverage`
11. `docs(vnc): record verified product parity and limitations`

Cursor 和 ZRLE 不得压成同一个不可审查的大提交。任何提交若包含无关云生命周期改动，停止并重新
拆分。

## 13. 验证矩阵

### 13.1 UI

| 变量 | 覆盖值 |
| --- | --- |
| 宽度 | 360/373vp、小屏主流、Pad、PC/2-in-1 |
| 方向 | 竖屏、横屏、旋转中 |
| 字体 | 100%、130%、200% |
| 导航 | 手势导航、三键导航 |
| 输入法 | 关闭、打开、切换输入框、隐藏 |
| 主题 | Light、Dark、跟随系统 |
| Sheet | bottom、center、退出动画、系统 dismiss |
| 表单 | 空值、长域名、长错误、已有密码提示、Gateway 多卡 |

硬性断言：

- footer 全程完整可见；
- 操作按钮触控区域至少 44vp；
- 错误不覆盖 footer；
- 输入法不把保存按钮推到屏幕外；
- 所有 Sheet 可返回/关闭且无双 Sheet；
- 大字体不截断安全警告的关键含义。

### 13.2 会话

- 触控板移动、左击、双击、右击、中键；
- 按住拖动、文本选择、窗口拖动；
- 双指滚轮、反转滚轮、左右键交换；
- 直接触控；
- 虚拟键盘、硬件键盘、Ctrl/Alt/Shift/Win/Fn、功能键；
- 三指控制台；
- 修饰键胶囊短按/长按；
- 横竖屏独立位置；
- HUD 展开/收起/拖动；
- view-only 禁用；
- Surface 重建、前后台、断开、重连。

### 13.3 Mac

基线配置：

1. Mac `系统设置 → 通用 → 共享 → 屏幕共享` 已打开；
2. 冲突的 Remote Management 已关闭；
3. 已启用“VNC viewer 可使用密码控制”；
4. 允许测试用户；
5. 默认端口 5900；
6. Mac 不处于睡眠，手机与 Mac 网络可达。

场景：

- 登录桌面、菜单、Dock、窗口移动；
- Retina 高分辨率；
- 多显示器 server-reported geometry；
- 动画/视频高变化；
- 小区域文本输入；
- 分辨率由 Mac 端改变后触发 DesktopSize；
- Mac 端关闭控制权限后的错误解释；
- 标准 Screen Sharing 与其他 VNC server 的差异。

### 13.4 native 安全

- rectangle 坐标和乘法溢出；
- Cursor 尺寸/mask/hotspot；
- ZRLE 压缩长度、解压上限、tile、palette、run；
- truncated/unknown encoding；
- timeout/cancel；
- generation 过期；
- disconnect 中的 worker、Surface 和 callback 释放；
- 高帧率下背压；
- secret 不进入日志或 diagnostics。

### 13.5 其他协议零回归

至少验证：

- RDP 添加、编辑、锁、删、连接、键盘、鼠标；
- RustDesk 原中继添加/编辑/导入/账户/Pro、主机连接和 HUD；
- SSH 添加、known-host、密钥、终端、SFTP；
- 设置页协议顺序与图标；
- 云同步管理中的 `vncrecord` 选择；
- 经典主机卡片图标和操作样式。

## 14. 强制门禁

每个代码里程碑和最终合并前运行：

```sh
source scripts/macos_env.sh
hvigorw --mode module -p module=entry -p product=default \
  default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon
hvigorw --mode module -p module=entry -p product=default \
  assembleHap --analyze=normal --parallel --incremental --no-daemon
```

同时要求：

- `git diff --check`
- ArkTS 测试注册清单完整
- native VNC tests
- Light 合规
- API 23 HAP 安装和启动
- 真机用例记录
- 独立 reviewer 结论

`ohosTest` 若仍报 `00306054` 任务未注册，只能记录为设备测试模块 blocker；不能把
`default@OhosTestCompileArkTS` 或 `assembleHap` 成功写成设备用例已通过。实现阶段应在
DevEco 中创建/注册测试模块后，再执行真机 ohosTest。

## 15. 停止条件与回滚

出现以下任一情况立即停止当前阶段：

- 需要修改第二张 VNC 云表或 `vncrecord` 物理字段；
- 需要把 VNC host 写入 `remotehosts`；
- 需要修改 RustDesk relay model 才能保存 VNC Gateway；
- WebSocket/SSH tunnel 被要求在服务端契约未完成时打开；
- ZRLE/Tight 解析器没有上限或 fuzz 证据；
- VNC Sheet 修复导致其他协议 Sheet 行为变化；
- 当前云生命周期分支尚未闭环；
- 无法在 API 23 编译；
- 密码/token/fingerprint 出现在普通日志。

回滚按提交边界进行：

- UI 壳层、流程重排、会话工具栏、Cursor、ZRLE 分别可独立回滚；
- 不使用 `git reset --hard` 或覆盖用户工作树；
- ZRLE 出现互操作问题时 capability gate 回退 Raw，不回滚 VNC CRUD/云同步；
- Cursor 出现服务端兼容问题时停止请求 Cursor 并保留本地 fallback；
- 新 UI 不稳定时回滚到经典 VNC editor，但不恢复重复 Gateway/设置 owner。

## 16. 完成定义

只有全部满足才可宣称 VNC V2 完成：

- [ ] 所有 VNC Sheet 的保存/下一步固定可见，输入法和安全区不遮挡（代码/策略已完成，真机待验）；
- [x] 现代添加为两步，经典编辑保持经典卡片风格；
- [x] 设置字段无重复 owner；
- [x] 第三页只用卡片标签区分 RustDesk/VNC，RustDesk 原流程无变化；
- [x] VNC Gateway 只开放真实可用 mode12；
- [x] 会话内有可见鼠标、键盘、组合键、显示、HUD 和断开入口；
- [x] view-only 明确可见；
- [ ] 组合键面板首次展开不漂移（生命周期/布局策略已完成，真机待验）；
- [x] VNC 性能看板与 RustDesk 设置完全隔离；
- [x] 软键盘文本使用有界 RFB KeyEvent，不再依赖或冒充剪贴板同步；
- [x] 连接失败释放回调所有权，不让适配器与会话形成强引用环；
- [x] 桌面经典新增读取 VNC 独立默认值，现代流程和其他协议路由不变；
- [x] 同一独立复核者完成整改、RAW_BGRA、隔离和 zlib ABI 终审，无 P0/P1/P2；
- [ ] Mac 画面持续刷新；
- [ ] 画面、输入、光标和 HUD 使用同一 framebuffer 几何（代码/策略已完成，真机待验）；
- [x] Cursor pseudo-encoding 或本地 fallback 保证鼠标可见；
- [x] requested/effective 编码、色深和帧率表述真实；
- [ ] ZRLE 通过安全和互操作门禁后才开放（安全/边界测试已通过，多端点互操作待验）；
- [x] 标准 Mac VNC 不提供虚假的远端分辨率选择；
- [x] 仍只有一张 `vncrecord`，无云物理 schema 变化；
- [ ] 单设备、多设备和账号切换不破坏 VNC owner；
- [ ] RDP、RustDesk、SSH/SFTP 回归通过；
- [ ] 两项 Hvigor、native tests、合规、真机和独立复核全部通过（自动化已通过，真机/复核待完成）；
- [ ] 任务分支已合并回本地 `main` 并清理；
- [x] 未经用户授权没有 push、PR 或远端合并。
