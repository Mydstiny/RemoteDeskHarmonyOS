# RDP / RustDesk 官方远端指针与悬浮鼠标设计

## 1. 目标

在 HarmonyOS 手机和 Pad 的 RDP、RustDesk 远程会话中实现两层相互独立的鼠标能力：

1. 画布上的远端命中指示：用户可在“个性化”中选择保留的圆环，或协议提供的真实鼠标指针；默认使用鼠标指针。
2. 可选的悬浮实体鼠标控制器：提供左右键、滚轮、中键、拖动把手和可选虚拟摇杆；默认关闭。

实现参考 Microsoft Windows App 的鼠标指针模式与 RustDesk 1.4.3 官方虚拟鼠标，但使用项目现有 ArkUI、FreeRDP 和隔离的 RustDesk FFI 架构独立实现。

## 2. 已确认的产品行为

### 2.1 个性化设置

复用现有“个性化 → 虚拟鼠标样式”选择，不新增重复入口：

- `圆环`：以远端实际命中坐标为圆心，保留左键、右键、拖拽的颜色反馈。
- `鼠标指针`：优先显示协议传回的真实光标形状和 hotspot；远端尚未提供有效形状时显示内置标准箭头。
- 新用户、无设置或非法设置默认使用 `鼠标指针`。
- 已明确保存为 `circle` 的用户继续使用圆环。
- 继续使用既有存储值 `arrow` 表示鼠标指针，但其渲染语义升级为真实远端指针；这样旧客户端和现有云数据仍可识别该值。

在同一张个性化卡片中增加：

- `悬浮实体鼠标默认开启`：默认关闭。
- `显示虚拟摇杆`：默认关闭，仅在悬浮实体鼠标开启时可用。

会话内也可从“手势/输入”面板即时开关悬浮鼠标和摇杆。会话开关不改变默认偏好，只有个性化设置修改默认值。

### 2.2 鼠标指针模式手势

- 单指移动：相对移动远端指针。
- 单指轻点：左键单击。
- 双击后保持并拖动：左键拖拽。
- 双指轻点或单指长按：右键单击。
- 双指上下移动：滚轮。
- 双指缩放：只缩放本地画布，不向远端发送缩放手势。
- `Cancel`、断连、后台、旋转、切换输入模式和组件销毁：释放全部按键并清空手势状态。

直接触控模式不显示本地虚拟指针；触控板模式显示用户选择的圆环或鼠标指针；实体鼠标/键鼠模式优先使用系统指针。

### 2.3 悬浮实体鼠标

- 控制器与远端命中指示分离。移动控制器本身不会改变真实指针样式。
- 包含左键、右键、滚轮上/下、中键和拖动把手。
- 按下时使用强调色；任何取消路径都必须发送对应 `mouseUp`，防止远端粘键。
- 可拖动并吸附安全区域边缘，避开工具栏、系统安全区和虚拟键盘。
- 横竖屏切换保存归一化位置，再在新安全区域内恢复和夹紧。
- 7 秒无操作自动折叠；按键按下、连续滚动、拖动控制器或摇杆活动时不折叠。
- 可选摇杆连续移动远端指针，离中心越远速度越高，松手立即归零。
- 控制器区域拦截本地触摸；控制器外部继续由远程画布处理手势。

## 3. 架构

```text
FreeRDP pointer callbacks ──────┐
                               ├─ Native RemoteCursorSnapshot
RustDesk cursor_data/id/pos ───┘  ├─ RGBA / width / height
                                  ├─ hotX / hotY
                                  ├─ remoteX / remoteY / visible
                                  ├─ shapeRevision / positionRevision
                                  └─ protocol / sessionId
                                              ↓
                                    NAPI 只读快照接口
                                              ↓
                    ArkUI RemoteCursorOverlay（圆环/真实指针/降级箭头）

ArkUI FloatingRemoteMouse ──标准化动作──> RemoteDesktop 输入分发
                                           ├─ RDP sendMouse / wheel
                                           └─ RustDesk sendMouse / wheel
```

### 3.1 统一光标快照

Native 层向 ArkUI 暴露统一快照，至少包含：

- `sessionId`、协议类型；
- 远端位置和可见性；
- RGBA 位图、宽高、hotspot；
- `shapeRevision` 和 `positionRevision`。

位图只在 `shapeRevision` 变化时跨 NAPI，位置轮询不得重复复制位图。ArkUI 必须拒绝 sessionId 不匹配的旧回调。

### 3.2 RustDesk

当前 FFI 已收到但丢弃 `cursor_data`、`cursor_id`、`cursor_position`：

- 缓存 `cursor_data.id → RGBA/尺寸/hotspot`；
- `cursor_id` 切换当前形状；
- `cursor_position` 更新服务端确认位置；
- 缓存容量有上限，连接结束时整体清理；
- 损坏数据不进入 UI。

### 3.3 RDP

接入 FreeRDP pointer shape、position、null/default pointer 回调，转换成统一快照：

- 彩色、单色和缓存指针转换为 RGBA；
- null pointer 更新可见性；
- default pointer 使用系统标准形状或内置标准箭头；
- 所有回调受当前 session 生命周期保护。

### 3.4 ArkUI 绘制

新增独立 `RemoteCursorOverlay`，只负责坐标转换和绘制：

- 圆环和真实指针共享同一个远端命中坐标；
- 真实指针位置为 `localHitPoint - scaledHotspot`；
- 覆盖层使用 `HitTestMode.None`；
- 形状切换更新像素数据，位置变化只更新位置状态；
- 本地输入立即预测位置，协议位置到达后只在必要时校正，避免网络延迟导致手感迟滞；
- 旋转、letterbox、缩放和远端分辨率改变后重新执行同一坐标变换。

### 3.5 悬浮控制器边界

新增独立 `FloatingRemoteMouse` 组件。组件只输出标准化动作：

- 相对移动；
- 左/右/中键 down/up；
- 滚轮 delta；
- 控制器位置和折叠状态变化。

组件不引用 RDP 或 RustDesk adapter。`RemoteDesktop` 负责把动作分发给当前协议，并统一执行输入清理。

## 4. 状态与持久化

- 保留现有 `virtualMouseStyle` 键和 `circle | arrow` 存储值：`circle` 表示圆环，`arrow` 表示真实远端鼠标指针。
- 默认值从 `circle` 改为 `arrow`，但不得覆盖已有 `circle` 用户。
- 悬浮鼠标与摇杆默认值使用新的用户设置键，进入现有 `usersettings` 适配和白名单，不改变云表结构。
- 悬浮鼠标会话临时开关、位置、当前按键和折叠状态不得上传云端。
- 位置只保存在本地 Preferences，并按设备方向/尺寸使用归一化坐标。

## 5. 容错与安全

- 对光标宽高、像素长度、hotspot 和缓存数量设置硬上限。
- 位图长度必须与格式和尺寸一致；异常数据降级为内置标准箭头。
- 不在每个位置更新中分配大块像素内存。
- 重连、后台、旋转、异常退出和协议切换均调用统一输入释放逻辑。
- 旧 session 的形状、位置和按键回调不得影响当前 session。
- 悬浮控制器所有定时器在组件销毁时停止。

## 6. 测试与验收

### 6.1 自动化测试

- RustDesk cursor data 缓存、ID 切换、位置更新、损坏数据和容量上限；
- RDP pointer shape/position/null/default 回调转换；
- hotspot 定位和缩放；
- sessionId 隔离与重连清理；
- `circle` 保留、`arrow` 升级为真实指针、新用户默认 `arrow`；
- 悬浮鼠标按键 down/up 成对、Cancel 强制释放；
- 摇杆速度边界、松手归零；
- 横竖屏归一化位置恢复和安全区域夹紧。

### 6.2 实机验收

在手机和 Pad 上分别验证 RDP Windows、RustDesk Windows 与 RustDesk macOS：

1. 普通箭头、文本、调整大小、忙碌、链接和拖拽等远端形状能正确切换；
2. hotspot 与实际点击位置一致，缩放、黑边、横竖屏后不漂移；
3. 圆环和鼠标指针可即时切换，重启和云恢复后选择正确；
4. 单击、双击保持拖动、双指右键、长按右键、滚轮和本地缩放语义正确；
5. 悬浮鼠标左右键、中键、连续滚动、拖动、折叠和摇杆正常；
6. 断连、旋转、切后台和取消手势后远端无粘键；
7. 光标位置更新不引起视频帧卡顿或明显额外内存增长。

最低工程验证包括 Rust 定向测试、native 定向测试、ArkTS 测试编译、`assembleHap`、`git diff --check` 和 Light 合规门。

## 7. 非目标

- 不把悬浮鼠标默认强制开启。
- 不修改远端协议的鼠标事件格式。
- 不把指针合成进 native 视频帧或 OpenGL 纹理。
- 不复制 RustDesk Flutter 组件代码；仅复用公开交互语义并以 ArkUI 独立实现。
- 不改变 PC 端实体鼠标和系统指针行为。
