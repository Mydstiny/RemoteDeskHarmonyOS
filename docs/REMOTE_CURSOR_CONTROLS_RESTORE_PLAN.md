# Phone/Pad 远端鼠标与浮动控制恢复实施计划

- 日期：2026-07-20
- 基线：`main` / `origin/main` = `1f16f361a`
- 状态：计划完成，产品代码尚未开始修改
- 目标分支：`codex/restore-official-cursor-controls`
- 适用范围：Phone/Pad 的虚拟触控板模式
- 不在范围：PC 物理键鼠行为、直触模式、协议以外的新输入设备能力

## 1. 目标

恢复“设置 → 个性化”中此前隐藏的三组入口，并把它们作为可发布功能完成闭环：

1. 虚拟鼠标样式：`圆环` / `官方远端鼠标`。
2. 浮动鼠标：左右键、滚轮和拖动手柄。
3. 浮动摇杆：连续移动远端指针。

恢复后必须满足：

- 默认仍为圆环，用户主动选择后才启用官方远端鼠标，避免升级后无提示改变既有操作习惯。
- 用户选择能持久化，重启后保持；非法或未知旧值归一化为圆环。
- 官方远端鼠标显示 RustDesk / FreeRDP 提供的真实形状、hotspot、位置和可见性。
- 圆环与官方远端鼠标互斥；浮动鼠标和浮动摇杆可分别启用，也可同时启用。
- 触控板慢速可精确停在小按钮，快速移动可覆盖大范围，不乱飞、不瞬移。
- 个性化卡片完整容纳所有恢复项，终端字体颜色和终端字体大小不得被裁剪或落入下一卡片。
- PC 物理键鼠模式、Phone/Pad 直触模式以及现有协议输入不回归。

## 2. 当前基线审计

### 2.1 已经具备，不重写

| 能力 | 当前实现 | 结论 |
| --- | --- | --- |
| 协议无关光标状态 | `RemoteCursorStore` 区分 shape、position、visibility revision | 保留 |
| RustDesk 光标事件 | `cursor_position`、`cursor_data`、`cursor_id` 已接入 FFI 和 native store | 保留并补顺序测试 |
| FreeRDP 位置回传 | 已设置 `FreeRDP_GrabMouse = TRUE`，`SetPosition` 更新远端位置 | 保留 |
| 光标比例 | `RemoteDesktop.ets` 已使用单一 scale 和 `ImageFit.Contain` | 保留并扩展形状测试 |
| 坐标变换 | `RemoteSurfaceTransformPolicy.ets` 已统一点、逆变换和 delta | 保留并补 resize/revision 边界 |
| 本地预测与远端权威位置 | 页面已有 prediction、ack tolerance 和 timeout | 保留并消除残余状态分散 |
| 触控映射曲线 | 已有低速 `0.75`、高速 `1.65`、平滑和长间隔重置 | 以真机数据校准，不先重写常量 |
| 浮动控件运行时 | `floatingVirtualMouseBuilder()`、`floatingVirtualJoystickBuilder()` 仍存在 | 恢复入口并做行为验收 |

### 2.2 当前明确关闭项

1. `HostListPage.ets` 用一个块注释隐藏了样式选择、浮动鼠标和浮动摇杆。
2. 启动时无条件把 `virtualMouseStyle` 写成 `circle`，覆盖旧偏好。
3. 云端恢复显式跳过 `virtualMouseStyle`，随后再次强制写入 `circle`。
4. `CloudSyncSettingsPolicy.ets` 暂时移除了 `virtualMouseStyle`。
5. `RemoteDesktop.ets` 和 `HostListPage.ets` 的 StorageLink 默认值为 `circle`；这个安全默认应继续保留。

### 2.3 恢复前必须解决的残余问题

1. `cbPointerSetDefault()` 目前只调用 `setVisible(true)`，会继续显示上一张等待、手套或调整大小光标；必须恢复明确的默认箭头。
2. `remoteCursorViewRevision * 0` 仍是响应式刷新技巧，后续应换成明确可观察的 render revision/state。
3. 个性化展开高度仍固定为 `620`；直接解除注释会再次裁剪终端字体设置。
4. 云端可能留有隐藏功能以前的旧 `arrow` 值；不能在升级后的第一次同步中静默覆盖本机圆环。
5. 浮动鼠标、浮动摇杆和触控板手势共用位置时，必须继续走同一个 prediction/transform/input helper，不能另建一套坐标公式。

## 3. 产品与兼容性决策

### 3.1 默认与文案

- 新安装、非法值、缺失值：默认 `circle`。
- 升级安装：读取本机已保存的合法值，不再每次启动强制覆盖；由于上一发布版已写入圆环，现有用户不会被自动切到官方光标。
- 设置文案：
  - 标题：`触控板鼠标样式`
  - 选项一：`圆环`
  - 选项二：`官方远端鼠标`
  - 说明：`仅用于手机和平板的触控板模式，显示 RustDesk / FreeRDP 回传的远端指针`
- 浮动鼠标和浮动摇杆保留现有默认关闭状态。

### 3.2 模式边界

| 场景 | 圆环 | 官方远端鼠标 | 浮动鼠标/摇杆 |
| --- | --- | --- | --- |
| Phone/Pad 触控板 | 二选一显示 | 二选一显示 | 按各自开关显示 |
| Phone/Pad 直触 | 不显示 | 不显示 | 不显示 |
| PC 物理键鼠 | 不显示 | 不叠加，使用系统 pointer | 不显示 |
| 未连接/断开中 | 不显示 | 不显示并释放旧 PixelMap | 不显示 |

### 3.3 云同步迁移

恢复 `virtualMouseStyle` 同步，但增加一次性本地迁移标记，避免历史云值突然覆盖：

1. 新增本地非云同步标记 `virtualMouseStyleRestoreVersion = 1`。
2. 第一次运行恢复版本时，以当前本机合法值为准；若无值则使用圆环。
3. 第一次云恢复跳过旧 `virtualMouseStyle`，将本机值上传为新的基准后写入迁移标记。
4. 标记存在后，样式与其他用户偏好一样参与正常云同步。
5. 浮动鼠标和浮动摇杆继续沿用现有云同步字段，不新增重复键。

若 CloudStore 当前生命周期无法安全完成“先本地、后上传”，第一阶段允许 `virtualMouseStyle` 保持本地同步关闭；不得为了赶进度接受旧云值无条件覆盖。该降级必须在提交说明和验收记录中明确。

## 4. 实施阶段

### 阶段 0：建立任务基线

1. 在 `main == origin/main`、没有活动任务且用户本地文件已妥善保留后，创建 `codex/restore-official-cursor-controls`。
2. 记录基线验证：native 102/102、Rust 89/89、ArkTS 测试编译、生产 HAP 和 Light 门禁。
3. 保存设备 `38451` 的圆环模式、个性化页面和小按钮定位基线视频/截图，不纳入 Git。

### 阶段 1：先补测试，再恢复设置入口

1. 为 `RemoteCursorStylePolicy` 增加测试：默认、非法值、circle/arrow 互斥、连接状态、控制模式边界。
2. 为偏好迁移增加纯策略测试：本机值优先、首次云恢复跳过、迁移后正常同步。
3. 解除 `HostListPage.ets` 中三组控件的注释。
4. 移除启动和云恢复路径中的强制 `circle` 写回，改为合法值归一化。
5. 保持 `RemoteDesktop.ets`、`HostListPage.ets` 的 StorageLink 默认值为 `circle`。
6. 恢复或分阶段恢复 `CloudSyncSettingsPolicy.ets` 中的 `virtualMouseStyle`。

阶段验收：三个入口可见、点击即时更新 AppStorage、重启保持、默认仍为圆环。

### 阶段 2：修复个性化卡片高度

不能再简单把 `620` 改成另一个容易失效的魔法数字。实施方案：

1. 为个性化内容容器记录自然高度，例如 `appearanceContentHeight`。
2. 展开首帧使用足够容纳全部内容的安全上限，内容布局完成后通过 `onAreaChange` 缓存实际高度。
3. 后续展开使用 `实际内容高度 + 外层底部间距`；折叠仍为 `0`，保留现有动画和 clip。
4. 当字体缩放、窗口宽度或断点变化时重新测量，不能复用旧尺寸。
5. 若 API 23 的布局测量无法稳定驱动同一层 constraint，则将测量放到内层自然布局 Column；禁止回退到未经测试的固定 `620/820`。

最低 UI 验收：Phone、Pad 竖屏、Pad 横屏，字体缩放 1.0/1.3/1.75；终端字体颜色和大小始终位于个性化卡片内，下一卡片顶部不重叠。

### 阶段 3：补齐 FreeRDP 默认光标语义

1. 为默认箭头提供稳定 RGBA 资源或可复用生成函数，定义宽高和 hotspot。
2. `cbPointerSetDefault()` 更新默认 shape、hotspot、shape revision 和 visible；不得复用上一张自定义 shape。
3. `cbPointerSetNull()` 只隐藏，不销毁最后一张合法自定义 shape。
4. `cbPointerSet()` 只更新 shape/hotspot/visible；`cbPointerSetPosition()` 只更新 position。
5. disconnect/reconnect 按 sessionId/generation 清理，旧回调不得污染新会话。
6. 为 custom → default、wait → default、null → default、position-before-shape 增加 native 测试。

阶段验收：箭头、白手套、等待、横向调整、纵向调整之间切换不残留、不拉伸、不跳回旧形状。

### 阶段 4：收敛 ArkTS 光标状态

1. 把页面中 shape、position、visible、authoritative、prediction 和 revision 的应用收敛到明确的 `RemoteCursorRenderState` 或等价状态对象。
2. 删除 `remoteCursorViewRevision * 0`，让位置或 revision 成为明确的响应式依赖。
3. 保留当前 ack tolerance/timeout 行为，但给 prediction 增加 session generation；断开、重连、resize、旋转时清除过期 prediction。
4. RDP 的逻辑桌面尺寸不得被 renderer source 覆盖；RustDesk 只有在 FFI 约定“frame size 即当前显示器逻辑尺寸”时才允许同步，并增加协议断言和日志。
5. 所有正向位置、逆向触控点和 delta 继续调用 `RemoteSurfaceTransformPolicy`；浮动鼠标和摇杆不得自行乘第二套比例。
6. 光标位图、显示尺寸和 hotspot 继续使用同一 scale 与 `ImageFit.Contain`。

阶段验收：被控端物理鼠标移动可更新控制端；控制端本地预测平滑，收到远端权威位置后不回跳到旧位置。

### 阶段 5：恢复并校验浮动鼠标、浮动摇杆

1. 浮动鼠标：验证左右键 down/up、滚轮方向、拖动手柄、按钮释放和断线释放。
2. 浮动摇杆：验证按压、连续移动、松手停止、Cancel、应用切后台、旋转和重连。
3. 两者的移动统一调用 `setRemoteCursorPrediction()` + `queueMouseMove()`；按钮和滚轮使用当前合并位置。
4. 两者同时启用时检查层级、拖动区域、触控冲突和安全区，不遮挡远控顶部栏、IME、文件传输状态和系统手势区。
5. 开关关闭时立即隐藏控件并停止 timer；禁止仅隐藏 UI 但后台继续发送移动。

阶段验收：任意开关组合都稳定，连续按压 60 秒无粘键、无持续移动、无 timer 泄漏。

### 阶段 6：触控曲线数据化校准

1. 保持当前曲线作为基线，先证明几何映射 round-trip 正确，再调 gain。
2. 日志采样记录本地 delta、dt、curve gain、用户倍率、远端 delta、prediction、authoritative 和 discontinuity；不得记录账号、地址或输入内容。
3. 在设备 `38451` 上执行三种轨迹：1–3 vp 微调、常速 100–300 vp、快速跨屏。
4. 只有数据证明当前参数不合格时才修改 `0.75/1.65/0.20`；每次只调整一组参数并保留对比结果。
5. 低速不设置吞掉微移动的 deadzone，浮点累计保留到协议发送前；单事件 discontinuity 继续重锚而不发送。
6. RustDesk 用户速度倍率与曲线 gain 只合并一次，最终有效 gain 保持上限。

阶段验收：至少 30 次小按钮靠近、停留、点击中无乱飞；快速跨屏不出现单帧瞬移或边界溢出。

## 5. 预计修改文件

### 必改

- `entry/src/main/ets/pages/HostListPage.ets`
  - 恢复 UI、偏好读取、首次迁移、内容高度测量。
- `entry/src/main/ets/pages/RemoteDesktop.ets`
  - 响应式 render state、session generation、浮动控件统一输入路径。
- `entry/src/main/ets/services/RemoteCursorStylePolicy.ets`
  - 样式归一化、显示边界及迁移策略 helper。
- `entry/src/main/ets/services/CloudSyncSettingsPolicy.ets`
  - 安全恢复 `virtualMouseStyle` 同步或记录阶段性本地-only 决策。
- `entry/src/main/cpp/rdp/freerdp_adapter.cpp`
  - `SetDefault` 和默认箭头生命周期。
- `entry/src/main/cpp/input/remote_cursor_snapshot.cpp/.h`
  - 如默认 shape 或 generation 需要协议无关存储，在这里实现。

### 按测试结果修改

- `entry/src/main/ets/services/RemoteSurfaceTransformPolicy.ets`
- `entry/src/main/ets/services/TouchpadPointerCurvePolicy.ets`
- `entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp/.h`
- `rustdesk_ffi/src/cursor_state.rs`
- `rustdesk_ffi/src/connector.rs`

RustDesk 当前光标链路已有实现，不因恢复 UI 而无条件重写 FFI。

### 测试

- 新增 `entry/src/ohosTest/ets/test/RemoteCursorStylePolicy.test.ets`
- 扩展 `RemoteSurfaceTransformPolicy.test.ets`
- 扩展 `TouchpadPointerCurvePolicy.test.ets`
- 扩展 `entry/src/main/cpp/test/remote_cursor_snapshot_test.cpp`
- 扩展 Rust `cursor_state` / connector 的事件顺序测试
- 如抽出设置迁移策略，新增对应 ArkTS policy test 并注册到 `List.test.ets`

## 6. 自动化测试矩阵

### ArkTS

1. 样式合法值、非法值、默认值和互斥显示。
2. Phone/Pad 触控板、直触、PC 物理鼠标模式边界。
3. 本地偏好首次迁移和云端旧值保护。
4. transform identity、contain、letterbox、横竖屏、非整数缩放、正逆 round-trip。
5. shape 宽高比与 hotspot 使用同一 scale。
6. 触控曲线连续、单调、有界、长间隔重置、NaN/Infinity 安全。
7. discontinuity 不发送，下一事件重新锚定。

### Native / Rust

1. shape、position、visibility revision 相互独立。
2. RDP custom/default/null/position 生命周期。
3. session reset/generation 隔离。
4. RustDesk position-before-shape、shape-before-position、cursor_id 缓存命中/未命中、重复事件。
5. RGBA 尺寸、hotspot、最大边界和无效数据拒绝。

### 工程门禁

1. 定向 ArkTS policy tests。
2. native 全套测试，基线不得低于 102/102。
3. RustDesk FFI host tests，基线不得低于 89/89。
4. `default@OhosTestCompileArkTS`。
5. 生产 `assembleHap`，arm64-v8a 与 x86_64 受影响 ABI 均存在。
6. `git diff --check`。
7. Light 开源合规门。

## 7. 设备验收矩阵

在设备 `38451` 上分别验证 RDP 与 RustDesk：

| 场景 | 验收标准 |
| --- | --- |
| 个性化布局 | 三组鼠标设置和两个终端设置均在同一卡片，无裁剪、重叠、跳卡 |
| 圆环 | 默认显示、位置平滑、与官方光标互斥 |
| 普通箭头 | 箭尖 hotspot 与实际点击点一致 |
| 白手套/等待 | 保持原比例，不横拉或竖拉 |
| 横向/纵向调整 | 方向正确，不在两种拉伸框之间跳变 |
| 默认恢复 | 离开特殊控件后恢复默认箭头，不残留旧 shape |
| 被控端移动 | 被控端物理鼠标移动后控制端在可接受延迟内跟随 |
| 小按钮 | 慢速可停留、微调和点击，30 次重复无乱飞 |
| 快速移动 | 可跨大范围，无单帧瞬移和边界溢出 |
| letterbox | 黑边不产生远端坐标，内容四角映射正确 |
| 横竖屏/resize | 位置按逻辑坐标重投影，不跳中心、不变形 |
| 浮动鼠标 | 左右键、滚轮、拖动和释放完整，无粘键 |
| 浮动摇杆 | 连续移动平滑，松手/Cancel/切后台立即停止 |
| 同时启用 | 控件不互抢触摸，不遮挡关键 UI |
| 重连 | 旧位置、旧 shape、旧 timer 不污染新会话 |
| PC 回归 | 物理键鼠仍使用系统 pointer，不显示虚拟覆盖层 |

## 8. 提交与回滚策略

按可独立回滚的检查点提交：

1. `test(cursor): cover restored cursor settings and migration`
2. `feat(settings): restore touchpad cursor controls`
3. `fix(ui): measure expanded appearance content`
4. `fix(rdp): restore default remote cursor shape`
5. `fix(input): unify remote cursor render state`
6. `test(input): expand cursor and touchpad regressions`

任何检查点失败都只回滚该检查点，不回滚已验证的统一 transform、触控曲线或 PR #25 的其他功能。发布前保留两个快速止损开关：

- UI 层重新隐藏官方远端鼠标选项，但不破坏存储兼容。
- 默认继续保持圆环；出现协议光标问题时用户可立即切回圆环。

禁止通过再次在启动时无条件写 `circle` 来止损，因为该做法会破坏用户偏好并制造后续迁移问题。

## 9. 完成定义

只有同时满足以下条件才可合并：

1. 三组设置入口恢复且个性化卡片在 Phone/Pad 与字体缩放矩阵中布局正确。
2. RDP、RustDesk 的所有目标形状等比显示，hotspot 与点击位置一致。
3. 被控端位置能回到控制端，控制端 prediction 不覆盖新的远端权威位置。
4. 浮动鼠标、浮动摇杆通过组合、取消、后台和重连测试。
5. 小按钮精确定位和快速跨屏测试通过，无随机乱飞。
6. ArkTS、native、Rust、双 ABI HAP、diff check 和 Light 门禁全部通过。
7. `38451` 真机矩阵有截图/视频和日志证据。
8. PR required check 通过并合并，随后回到同步的 `main`，删除已合并任务分支。

在以上条件完成前，不把“入口已解除注释”表述为功能完成。
