# 全协议双指缩放与放大画布光标跟随实施计划

状态：研究与代码勘察完成，尚未修改功能代码。

## 目标

在 `设置 → 显示与交互` 增加一个可点击的“双指缩放”设置项，打开协议选择弹窗，分别控制 RDP、RustDesk、SSH、VNC 和 Moonlight，并持久化保存。图形协议统一获得以双指焦点为锚的平滑缩放、同一手势内的画布平移，以及放大后移动鼠标/虚拟触控板时光标与画布协同移动的体验；SSH 保留“捏合调整终端字号”的协议语义。SFTP 文件列表不受影响。

本计划只描述后续实现，不在本轮修改 ArkTS、C++、Rust、测试或资源代码。

## 官方 RustDesk 研究结论

研究基线为 RustDesk 官方仓库 `master@03a7fc5992069cc5bc9f7c36b872483dddf4f472`，提交时间 `2026-08-27T16:33:58+08:00`。

1. 官方移动端把双指缩放与平移放在同一条 `ScaleGesture` 流中。每次更新使用“本次累计 scale / 上次累计 scale”得到相对倍率，以当前焦点保持远端内容锚定，再叠加焦点位移；抬手只重置手势内累计倍率，不重置会话画布。[官方双指处理](https://github.com/rustdesk/rustdesk/blob/03a7fc5992069cc5bc9f7c36b872483dddf4f472/flutter/lib/common/widgets/remote_input.dart#L449-L516)
2. `CanvasModel` 独立维护画布位置、倍率和可视区域；当前版本还提供会话内 `Lock canvas`，锁定后阻止普通缩放/平移。这说明“用户明确决定协议是否允许画布手势”与官方交互方向一致，但本项目需要进一步做到按协议持久化。[官方 CanvasModel](https://github.com/rustdesk/rustdesk/blob/03a7fc5992069cc5bc9f7c36b872483dddf4f472/flutter/lib/models/model.dart#L2204-L2271) · [官方画布锁定入口](https://github.com/rustdesk/rustdesk/blob/03a7fc5992069cc5bc9f7c36b872483dddf4f472/flutter/lib/mobile/pages/remote_page.dart#L1275-L1288)
3. 官方触控板模式并非让画布始终紧贴光标：光标先在可视区域内移动；越过可视区域中心且该方向仍有隐藏内容时，继续移动远端光标并反向平移画布，使光标与画面协同前进；画布或远端边界到达后停止对应分量。[官方 CursorModel.updatePan](https://github.com/rustdesk/rustdesk/blob/03a7fc5992069cc5bc9f7c36b872483dddf4f472/flutter/lib/models/model.dart#L3223-L3315)
4. 官方还存在两条补充路径：移动端物理指针可按光标位置调整画布；Floating Mouse 到达屏幕边缘后以 30 ms 定时步进画布，并在远端或画布边界停止。[官方移动端画布跟随](https://github.com/rustdesk/rustdesk/blob/03a7fc5992069cc5bc9f7c36b872483dddf4f472/flutter/lib/models/model.dart#L2517-L2546) · [官方 Floating Mouse 边缘滚动](https://github.com/rustdesk/rustdesk/blob/03a7fc5992069cc5bc9f7c36b872483dddf4f472/flutter/lib/mobile/widgets/floating_mouse.dart#L41-L189)
5. 官方历史反馈表明“画布过于紧跟鼠标”会妨碍精确点选，因此本项目不照搬持续吸附，而采用安全区和边缘区两级策略。[RustDesk issue #997](https://github.com/rustdesk/rustdesk/issues/997)；相关移动鼠标范围修复见 [PR #9811](https://github.com/rustdesk/rustdesk/pull/9811)，边缘区改进见 [PR #13410](https://github.com/rustdesk/rustdesk/pull/13410)。

本地 Firecrawl 研究缓存位于 `.firecrawl/developer-rustdesk-mobile-canvas-zoom.json`、`.firecrawl/developer-rustdesk-pointer-canvas-follow.json` 和 `.firecrawl/search-rustdesk-canvas-source.json`，已加入忽略规则，不进入产品或发布产物。

## 当前项目基线

### 已有能力

- `RemoteCanvasTransformPolicy.ets` 已定义跨协议 `CanvasTransform { scale, panX, panY, rotation }`，包含 Fit/固定倍率、旋转、缩放上下限、焦点锚定、平移约束和窗口/码流变化后的重投影。
- `GLRenderer::SetCanvasTransform` 已支持非阻塞提交、保留帧立即重绘和统一 viewport；RDP、RustDesk、VNC 正在复用该渲染链路，Moonlight 也使用相同 `rdpnapi` renderer，可以在不改解码器和协议栈的前提下接入。
- `RemoteDesktop.ets` 已让 RDP、RustDesk、VNC 共用双指所有权状态机和 renderer viewport 输入映射。缩放、画布、远端光标覆盖层使用同一几何来源。
- SSH 已有双指捏合字号：12–32 vp、实时提示、普通会话结束时保存；`SshXtermSurface.zoomAccess(false)` 明确由 ArkUI 手势拥有缩放。
- `RemoteWheelPreferencePolicy.ets` 与 `RemoteWheelDirectionSettingsSheet.ets` 已提供五协议设置的成熟模板：版本迁移、协议键映射、touched-field 合并、多键保存回滚、摘要和设置叶弹窗。

### 当前缺口

- `canvasGestureZoomEnabled` 是 RDP、RustDesk、VNC 共用的单一开关，无法按协议选择；RustDesk 控制栏也会写同一全局值。
- 现有图形协议在完成缩放后，需要先抬手，再双指静止约 400 ms 才能拖动画布。快速双指平移会继续成为滚轮，缩放和平移不连续。
- 虚拟触控板和物理鼠标只更新远端光标，不会在放大画布中主动揭示光标前方的隐藏内容。
- RustDesk 另有 `rustdeskRemoteAppTouchScaleEnabled`，它发送远端协议 `TouchScale/TouchPan`。该功能和本地画布缩放互斥，但当前互斥动作会误伤 RDP/VNC 的全局开关。
- Moonlight 当前没有本地画布变换。双指移动固定发送滚轮、双指轻点发送右键；加入捏合时必须保留这些既有语义并解决所有权竞争。
- SSH 双指字号缩放始终启用，没有协议级门控；命名配置会话中的字号又是会话态，不能被新开关误写成全局值。

## 最终交互契约

### 设置入口

- 在 `显示与交互` 保留一行“双指缩放”，整行和尾部“选择协议”按钮都可打开叶弹窗，不再使用全局即时开关。
- 行摘要为：`全部协议关闭`、`全部协议开启`，或 `已开启：RDP、RustDesk…`。
- 弹窗列出五项：
  - RDP：远程画布捏合缩放、双指移动画布、放大后光标跟随。
  - RustDesk：本地画布能力；提示与“远端 App 原生触控缩放”互斥。
  - SSH 终端：双指调整终端字号，不启用画布或光标跟随。
  - VNC：与 RDP 相同的本地画布能力。
  - Moonlight：串流画布捏合、画布移动和光标跟随。
- 提供“全部开启”“全部关闭”“取消”“保存”。保存仅提交用户实际触碰的协议，避免弹窗打开期间其他入口的修改被旧草稿覆盖。
- 设置行在所有设备形态显示；功能只响应 `SourceTool.Finger` 的触屏双指。实体触控板 pinch、滚轮和系统缩放快捷键仍走各自已有路径。

### 图形协议双指手势

1. 两指落下进入 `candidate`，记录焦点、指间距、时间和当前协议开关；不立即发送滚轮或右键。
2. 指间距变化达到阈值后立即声明 `canvas-pinch`，当前同一手势同时处理相对倍率和焦点位移，不要求抬手，也不再发送该手势的滚轮或右键。
3. 画布已超出可视区域时，两指同向移动直接声明 `canvas-pan` 并平移画布，取消现有 400 ms 长按等待。
4. 画布仍为 Fit 且没有明确捏合时，双指移动继续作为远端滚轮；短、静止的双指释放继续作为右键，保持现有高频操作。
5. 一旦手势归属缩放或画布平移，归属保持到最后一根相关手指抬起或 Cancel，禁止中途跳回滚轮/右键。
6. 三指以上、手指数突变、旋转/窗口/PIP 重绑定、协议切换、退后台、断线和开关变化都统一结束手势、清空累计倍率并释放可能按下的远端按钮。
7. 关闭当前协议开关时，立即终止正在进行的本地画布手势，并把图形协议恢复到当前 `显示比例` 对应的基础画布，避免用户被留在无法平移的放大状态。

### 放大后的光标与画布协同

增加纯策略 `RemoteCanvasPointerFollowPolicy.ets`，不把跟随逻辑散落到各协议发送函数中。

输入：当前 canvas transform、严格内容边界 viewport、远端逻辑光标、请求的远端增量或本地绝对指针、输入来源、旋转和时间。输出：受约束的远端光标、下一 canvas transform、未被画布吸收的剩余量和诊断原因。

行为分两类：

- 虚拟触控板/相对指针：光标在中央安全区内自由移动；预测光标越过安全区且该方向还有隐藏内容时，远端光标照常前进，画布按屏幕空间反方向平移，使光标稳定停留在安全区边缘。画布到边界后，剩余移动让光标继续到真实远端边缘。
- 实体鼠标/绝对指针：只有指针先进入内部区域后，进入外沿边缘区才启动画布移动，防止鼠标从窗口外进入时立刻拖动画布。事件持续时按最新值合并；指针停在边缘而远端仍可移动时，使用有界的帧节拍续移，并在离开边缘、输入失焦、画布/远端边界或会话终止时停止。

默认参数由纯策略统一定义并通过真机数据调整：中央安全区取可视区域中部约 60%–70%，外沿物理指针边缘区取 48–100 vp 的受限值；不提供新的用户滑杆。这样保留官方“光标带动画布”的核心，又避免 issue #997 所描述的紧贴感。

关键约束：

- 仅在当前协议开关开启、画布确有隐藏内容且 transform 已偏离基础显示比例时介入；Fit/完整可见状态完全不改变鼠标行为。
- 跟随使用严格内容边界，不使用 RDP 手势的 0.45 surface 自由平移余量，禁止自动跟随制造黑边。
- 远端坐标、旋转和本地 pan 在一个不可变 viewport 快照中计算；先更新 ArkTS viewport cache，再提交同事件的远端鼠标，避免几何代际混用和跳点。
- 本地光标覆盖层、嵌入码流的 Moonlight 光标和实际远端输入共享同一 transform。Moonlight 默认码流光标存在网络时延时，只用本地预测状态驱动画布，不额外绘制一个虚假箭头；选择圆形虚拟鼠标时继续显示已有覆盖层。
- 画布跟随不持久化 pan/scale；设置只持久化“该协议是否允许双指缩放”。会话重连、远端分辨率变化和新 renderer 按现有显示比例重新建立或重投影画布。

## 持久化与迁移

新增纯策略 `RemotePinchZoomPreferencePolicy.ets`：

```text
remotePinchZoomPreferenceVersion
rdpPinchZoomEnabled
rustdeskPinchZoomEnabled
sshPinchZoomEnabled
vncPinchZoomEnabled
moonlightPinchZoomEnabled
```

- 所有键通过 `RemoteDesktopAppPrefs` 保存并通过 `AppStorage` 实时发布。
- 所有键和版本标记加入 `CloudSyncSettingsPolicy` 的 device-local 列表，不进入云端 usersettings。
- 迁移幂等，已存在的协议键永远优先；旧键只作为缺失值的种子，不删除，便于降级版本仍保持原行为。
- RDP、RustDesk、VNC 缺失时继承已解析的旧 `canvasGestureZoomEnabled`，完整保留升级前观察到的开/关状态。
- SSH 缺失时默认为开启，因为当前版本的终端 pinch 始终可用。
- Moonlight 缺失时默认为关闭，因为当前版本没有画布缩放，避免升级后把既有双指滚轮突然改成画布手势。
- 新安装也遵循现有产品基线：RDP/RustDesk/VNC 使用旧偏好解析出的新装默认，SSH 开启，Moonlight 关闭；用户可在同一弹窗一键调整。
- 保存使用 touched-field patch 与最新 AppStorage 值合并，逐键写入失败时尽力回滚 Preferences 和内存值；只有全部目标键成功才关闭弹窗。
- 开启 RustDesk 本地缩放时，原子关闭 `rustdeskRemoteAppTouchScaleEnabled`；以后从 RustDesk 原生触控入口开启远端 TouchScale 时，只关闭 `rustdeskPinchZoomEnabled`，不得改变其他四个协议。

## 协议落点

### RDP / RustDesk / VNC

- `RemoteDesktop.ets` 根据当前协议读取 `rdpPinchZoomEnabled`、`rustdeskPinchZoomEnabled` 或 `vncPinchZoomEnabled`，替代共享 `canvasGestureZoomEnabled` 的运行时判定。
- 重构 `RemoteCanvasGesturePolicy.ets` 为阈值驱动的单所有权状态机；`RemoteCanvasPinchInputPolicy.ets` 继续负责 draining，避免已被 ArkUI 手势取得的 finger stream 泄漏到远端。
- `RemoteCanvasTransformPolicy.ets` 保持缩放数学的唯一来源；只增加可复用的严格内容边界/显示点换算辅助，不复制 GL 公式。
- RDP、RustDesk、VNC 的虚拟触控板相对移动在最终协议发送前调用 pointer-follow 策略；物理绝对指针在 viewport 映射层调用边缘跟随策略。
- RustDesk 的远端 App `TouchScale/TouchPan` 保持现有协议发送和排空逻辑，不进入本地 `CanvasTransform`；两种缩放通过单一互斥策略切换。
- RustDesk 桌面翻转和所有协议画面旋转继续先通过 `RemoteSurfaceTransformPolicy` 转换，pointer-follow 只消费转换后的统一表面坐标。

### SSH / SFTP

- `SshTerminal.ets` 用 `@StorageLink('sshPinchZoomEnabled')` 门控现有 `PinchGesture`。
- 开启时保留 12–32 vp 限制、实时“字号 xx vp”提示和普通会话保存逻辑；关闭时不回退当前字号，只禁止后续捏合。
- 命名配置会话继续只修改会话字号，不因为开关保存而覆盖全局 SSH 字号。
- SFTP 页面、文件列表、预览和滚动均不读取该键。

### Moonlight

- `MoonlightStreamPage.ets` 引入与 `RemoteDesktop` 相同的 canvas transform、viewport cache 和 renderer 重绑定策略；复用现有 `setRendererCanvasTransform`，不修改 Moonlight common-c、Sunshine 输入协议或解码器。
- renderer 创建、恢复前台、PIP 进入/退出、surface resize、重连和首帧几何确定后都重新提交 transform，并使 absolute pointer geometry cache 与 transform version 一起失效。
- 在现有 `handleMoonlightTrackpad` 上增加独立两指所有权：明确 pinch 后由画布消费；放大可平移时双指移动画布；Fit 且未 pinch 时保持滚轮；短静止双指仍右键。
- 相对触控板继续使用已有速度曲线、合帧和 Sunshine relative wire path。pointer-follow 读取 `trackpadCursorX/Y` 预测并更新 canvas，不改变协议增量单位。
- 物理鼠标继续走已有 renderer viewport absolute geometry；边缘跟随改变 transform 后必须立即失效并重建 geometry generation，避免用旧 content rect 发送绝对坐标。

### 缩放复位入口（2026-08-29 增量）

- 不新增可自由拖动的独立悬浮按钮，避免与键盘、修饰键、诊断 HUD 和协议侧栏争抢边缘位置；复位入口附着于各协议既有工具栏或控制中心。
- RDP 与 Moonlight 在画布以 epsilon 明显偏离当前显示基线后，向既有工具栏插入高亮“复位”快捷项；各自控制中心同时保留稳定的“复位画面”入口。Moonlight 的窄 PC 顶栏按 viewport 限宽并横向滚动，复位、控制和断开均保持可达。
- VNC 没有独立控制中心，因此在现有可拖动侧栏中常驻“复位”，画布偏离基线时使用活动色提示；窄 PC 顶栏同样按 viewport 限宽并横向滚动。
- RustDesk 复用“显示与画质”中的复位项；画布偏离基线时显示按钮变色，菜单文案标记“已缩放”。
- 图形协议复位只清除手势 scale/pan，保留当前 Fit/100%/自定义显示模式、RustDesk 翻转/旋转、显示器和分辨率选择；执行前结束双指所有权并清除实体鼠标边缘跟随，避免下一帧把画布再次推离基线。
- SSH 不创建画布按钮；“恢复终端字号”收进现有“更多”菜单。Profile pinch 以 `host:generation` 内存 override 隔离，活动和保留 Xterm surface 读取同一有效字号；复位删除 override、恢复当前解析配置字号且不改 Profile。legacy 会话恢复并持久化默认 18 号字；SFTP 不受影响。

## 计划修改文件

| 范围 | 主要文件 | 预期变化 |
|---|---|---|
| 偏好与迁移 | `services/RemotePinchZoomPreferencePolicy.ets`（新增）、`CloudSyncSettingsPolicy.ets`、`PersonalizationDefaultsPolicy.ets` | 五协议键、迁移、摘要、device-local 契约 |
| 设置弹窗 | `components/RemotePinchZoomSettingsSheet.ets`（新增）、`pages/HostListPage.ets`、`services/SettingsSheetRoutePolicy.ets` | 可点击设置行、五协议弹窗、保存/回滚、RustDesk 互斥 |
| 通用手势 | `services/RemoteCanvasGesturePolicy.ets`、`RemoteCanvasPinchInputPolicy.ets` | 同手势 pinch+pan、scroll/right-click 仲裁、生命周期清理 |
| 通用画布跟随 | `services/RemoteCanvasPointerFollowPolicy.ets`（新增）、`RemoteCanvasTransformPolicy.ets` | 安全区、边缘区、严格边界、旋转换算 |
| RDP/RustDesk/VNC | `pages/RemoteDesktop.ets`、相关控制栏/控制中心组件 | 按当前协议取值、相对/绝对指针跟随、互斥收敛 |
| SSH | `pages/SshTerminal.ets` | 门控既有字号 pinch，不改变 SFTP |
| Moonlight | `pages/MoonlightStreamPage.ets` | renderer transform、两指仲裁、pointer geometry 代际同步 |
| 复位入口 | `components/RemoteSessionTopBar.ets`、`VncSessionToolbar.ets`、`rdp/*`、`moonlight/*`、`pages/SshTerminal.ets` | 侧栏/控制中心复位、状态提示、SSH 更多菜单 |
| 测试 | `ohosTest/...` 对应 policy/UI wiring tests 与两套测试入口 | 迁移、数学、所有权、路由和协议接线覆盖 |

除非实现期发现 renderer viewport 缺少必要版本信息，否则不修改 C++、Rust、FFI、协议 protobuf、第三方依赖、SBOM 或许可文件。

## 分阶段实施

### 阶段 1：偏好模型和设置入口

1. 建立五协议纯偏好策略、默认值、幂等迁移、touched merge、摘要和键映射测试。
2. 在应用偏好初始化中完成一次迁移并发布五个 AppStorage 值。
3. 增加设置叶路由和五协议弹窗；实现取消、全开、全关、保存、失败回滚和 RustDesk 互斥。
4. 将旧全局设置行替换为可点击摘要行；保留旧键只读兼容，不再作为会话运行时真值。

### 阶段 2：统一图形手势

1. 给现有所有权状态机增加距离比例阈值和“已放大直接平移”分支，删除 400 ms 画布平移等待。
2. 让 PinchGesture 在同一 update 中提交 relative scale 与 focal delta；校验快速 pinch、慢 pinch、纯平移、二指轻点、Cancel 和第三指加入。
3. RDP、RustDesk、VNC 按协议开关接入；开关关闭或切换协议时恢复基础显示比例并清理输入。
4. 收敛 RustDesk 本地画布与远端 App TouchScale 的互斥和 UI 提示。

### 阶段 3：光标跟随画布

1. 实现纯 pointer-follow 策略和四边/四角/旋转/边界/安全区测试。
2. 接入 RDP、RustDesk、VNC 虚拟触控板的预测光标；保证 transform、cursor overlay 和 wire input 使用同一 viewport generation。
3. 接入物理鼠标边缘跟随、内部区 armed 状态和停止条件；不影响未放大画布。
4. 对 RDP 自动跟随使用严格内容边界，手工双指平移仍保留现有自由平移余量。

### 阶段 4：SSH 与 Moonlight

1. 给 SSH 既有字体 pinch 加协议开关和中途关闭清理测试，验证命名配置与普通会话持久化边界。
2. 给 Moonlight 补齐 canvas transform 生命周期，先验证 renderer/PIP/重连/resize 的 transform 与 geometry generation。
3. 接入 Moonlight pinch/scroll/right-click 所有权和相对触控板 pointer-follow，再接入物理鼠标边缘跟随。
4. 验证 Sunshine 码流光标与圆形本地光标两种样式，不制造双光标或位置欺骗。

### 阶段 5：收尾

1. 更新 CURRENT/QUEUE 和必要的长期决策说明；不扩展无关设置或协议功能。
2. 跑定向策略测试、两项强制 Hvigor、`git diff --check` 和 Light 合规门。
3. 按设备矩阵完成真机验收；只有实际执行的设备/协议组合才标为通过。

## 自动化验证矩阵

### 偏好与设置

- 旧全局 true/false 分别正确播种 RDP、RustDesk、VNC；SSH=true、Moonlight=false；重复启动不二次覆盖。
- 任一新协议键存在时优先于旧值；未知协议返回关闭；摘要顺序固定为 RDP、RustDesk、SSH、VNC、Moonlight。
- stale sheet 只合并 touched 字段；部分 Preferences 写失败时回滚内存和已写键。
- RustDesk 两种缩放任一开启时另一种关闭，失败不产生“双开”或其他协议被关闭。
- 所有新键被判为 device-local 且不可云同步。

### 画布数学与光标跟随

- 以中心、四角和任意焦点做相对缩放，焦点下远端像素漂移不超过浮点容差；连续累计 scale 不跳变。
- 0°/90°/180°/270°、超宽/竖屏、多显示器原点和窗口 resize 后 pan/scale 均合法。
- 安全区内不移动画布；越界只在存在隐藏内容的轴上跟随；到边界后剩余光标量正确；四角对角移动无轴间污染。
- RDP 手工自由平移边界与自动严格边界分离；VNC/RustDesk/Moonlight 不产生黑边。
- viewport generation 变化会拒绝/刷新旧 absolute geometry，不会出现瞬间远端跳点。

### 手势所有权

- 快速 pinch、慢速 pinch、pinch 同时平移、已放大纯平移、Fit 双指滚动和静止双指右键各只有一个 owner。
- owner 一旦确定直到终止不切换；Cancel、第三指、开关关闭、PIP、旋转、断线均清空状态和按钮。
- 开关关闭时 RDP/RustDesk/VNC/Moonlight 保持原双指滚轮/右键；SSH 不响应 pinch；实体触控板路径不被触屏设置劫持。

## 真机验收矩阵

每个图形协议至少覆盖 Phone 与 Pad；有触屏 PC 时补充 PC，实体鼠标/触控板至少在 Pad 或 PC 覆盖。

1. 设置：逐协议开关、全部开/关、取消、保存失败提示、杀进程重启、升级迁移；修改一个协议不得改变另外四个。
2. RDP/RustDesk/VNC：Fit、100%、200%、自定义比例；快速/慢速 pinch；同手势平移；后续双指平移；滚轮与右键保留；虚拟触控板和实体鼠标在四边/四角带动画布；点击/拖动坐标准确。
3. RustDesk：Windows/macOS/Linux 桌面目标与 Android/iOS App 目标；本地缩放和远端 App TouchScale 互斥；桌面翻转、显示器切换、PIP/前台恢复后几何一致。
4. Moonlight：虚拟触控板 relative、实体鼠标 absolute、码流光标和圆形本地光标；双指滚轮/右键不误触；PIP、分屏、旋转、重连和码流分辨率变化后不跳点。
5. SSH：普通会话字号实时变化并按原规则保存；命名配置保持会话态；关闭时字号不回退且 pinch 无效；alternate buffer、鼠标跟踪和软键盘不受影响。
6. SFTP：列表滚动、拖放、预览完全不受 SSH 双指开关影响。

通过标准：

- pinch 起始无突跳；同一焦点下内容视觉漂移不超过 2 个本地像素。
- 已放大时光标能连续抵达整个远端桌面；安全区内精确点选不拖动画布；到四边/四角无抖动、回弹或黑边。
- 开关关闭后不再消费对应双指缩放，且没有残留按键、滚轮或触控流。
- 画面、光标覆盖层和远端点击在 renderer/PIP/旋转/分辨率代际切换后仍使用同一几何。
- 应用重启后五协议选择准确恢复。

## 必须执行的交付门禁

实现完成后按仓库门禁执行并记录：

```sh
source scripts/macos_env.sh
hvigorw --mode module -p module=entry -p product=default default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon
hvigorw --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --no-daemon
git diff --check
pwsh -NoProfile -File scripts/verify_open_source_release.ps1 -Mode Light -RepositoryRoot .
```

若实现期没有 C++/Rust/FFI/依赖变化，不增加 native ABI、供应链或发布级门禁；若实际跨入这些范围，再按仓库规则补对应验证。

## 授权增量：深色 bindSheet 表面统一

用户在当前活动工作树上授权追加以下相邻 UI 一致性增量：

1. 盘点全仓 37 个 `.bindSheet(` 调用，并把深色模式下的原生 Sheet 容器统一到 `Theme.sheetBg`（`#1C1C1F`）。
2. 同步修改实际覆盖原生容器的 Sheet 内容根层，避免原生深灰外壳仍被纯黑、浅灰或其他深灰内容覆盖。
3. 保留浅色模式语义；Moonlight 连接 Sheet 在浅色模式继续使用原品牌暗色表面，仅深色模式切换到 `sheetBg`。
4. 不修改 `promptAction.showDialog`、`AlertDialog`、`bindPopup`、普通页面背景、远程画布、终端画布和其他非 `bindSheet` 表面。
5. 以 37/37 原生背景静态审计、内容根层复核、两项强制 Hvigor、`git diff --check`、Light 合规和独立 reviewer PASS 作为完成标准；真机深色视觉巡检作为后续验收项。

## 非目标

- 不把 RustDesk 的远端 App TouchScale 改造成通用协议能力。
- 不给 SSH/SFTP 制造不存在的画布或光标跟随语义。
- 不持久化会话 pan/scale、光标位置或边缘滚动状态。
- 不新增可调安全区、速度、灵敏度等设置，先用真机证据稳定默认策略。
- 不重写 GLRenderer、Moonlight common-c、RustDesk FFI、VNC/RDP 协议栈或第三方依赖。
