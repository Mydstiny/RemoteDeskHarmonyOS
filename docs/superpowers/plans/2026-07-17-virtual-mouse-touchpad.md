# 手机/Pad 虚拟触控板鼠标方案实施计划

> 状态：待实施
>
> 目标版本：HarmonyOS NEXT / API 23
>
> 本计划只覆盖手机和 Pad 的虚拟触控板体验。当前仓库存在其他活动任务，本轮只新增本计划文档，不修改实现代码、不创建持久 worktree、不暂存、不提交。

## 1. 目标

在手机和 Pad 的远程桌面“触控板”模式下，提供一个更接近 RustDesk/RDP 鼠标的虚拟指针体验：

1. 在“设置 → 个性化”增加“虚拟鼠标样式”选择。
2. 保留当前圆环指示器作为兼容选项，新增标准鼠标箭头样式，并让箭头的尖端就是远端命中点。
3. 通过速度相关的触控映射曲线，让慢速移动更容易停在小按钮上，快速移动仍能高效跨屏。
4. 通过浮点坐标累加避免 `Math.round()` 丢失细小位移。
5. 保留现有单指移动、单击、双指右键、双指滚轮、长按拖拽等手势语义。
6. RDP 和 RustDesk 共用这套虚拟鼠标样式及基础曲线；协议层继续复用现有 `sendMouse()`、`sendMouseWheel()`。

## 2. 明确非目标

- 不实现手机/Pad 上的实体鼠标驱动、系统级 `CursorController` 鼠标注入或外接鼠标适配。
- 不改变当前“直接触控”模式：该模式仍按触点直接映射远端，并保留现有触摸反馈。
- 不改变当前“键鼠”模式和已经存在的系统鼠标指针处理；本计划不把触控板模式改成 `controlMode = 2`。
- 不修改 RDP、RustDesk native/FFI、视频渲染、认证、滚轮协议或远端鼠标事件格式。
- 不新增第一版的用户可调速度滑杆；先用经过测试的速度曲线和现有 RustDesk 速度偏好，避免设置项过多。

## 3. 当前实现与问题定位

### 3.1 输入链路

当前 `RemoteDesktop.ets` 的触控板链路为：

```text
TouchEvent
  -> stepDx/stepDy
  -> remoteDeltaFromLocal()
  -> remoteCursorX/remoteCursorY
  -> queueMouseMove()/sendMouse()
  -> 远端鼠标移动
```

远端坐标随后通过已有的 letterbox/视频内容坐标转换，绘制在本地触控板表面上。后端已经有足够的鼠标移动、按键和滚轮发送能力，不需要另造协议通道。

### 3.2 当前指针显示

- `remoteCursorX/Y` 跟踪远端逻辑桌面坐标。
- 现有圆环在 `RemoteDesktop.ets` 的覆盖层中绘制，并使用 `hitTestBehavior(HitTestMode.None)`，因此不会抢走触摸事件。
- 当前指示器按触摸动作短暂显示，随后自动隐藏；这适合触摸反馈，不适合需要持续瞄准小按钮的虚拟鼠标箭头。
- 系统 `CursorController` 不能让手指触控产生可见系统箭头，因此箭头必须作为 ArkUI 自定义覆盖层绘制。

### 3.3 当前映射问题

- `TOUCHPAD_POINTER_GAIN` 是固定线性增益，慢速和快速移动使用同一倍率。
- `remoteDeltaFromLocal()` 只做本地表面尺寸到远端桌面尺寸的线性换算。
- `rememberRemoteCursor()` 当前会对坐标取整；当一次触摸移动换算后小于一个远端像素时，位移会被吞掉，连续微调尤其明显。
- RustDesk 已有 `rustdeskTouchpadSpeed`，RDP 没有同类的用户速度倍率；曲线需要在两种协议上统一，同时避免与 RustDesk 现有倍率叠加到失控。

## 4. 用户体验与设置设计

### 4.1 设置项

新增全局偏好键：

```text
virtualMouseStyle: 'circle' | 'arrow'
```

语义如下：

| 值 | 显示名称 | 行为 |
|---|---|---|
| `circle` | 圆环 | 当前圆环指示器，保留现有短暂显示和动作颜色反馈 |
| `arrow` | 标准箭头 | 持续显示带尖端命中的虚拟鼠标箭头，点击/拖拽时提供轻微按下反馈 |

迁移和默认策略：

- 无值、非法值或云端旧数据统一回退到 `circle`，保证已有用户升级后视觉和操作不突变。
- `arrow` 在设置界面标注为推荐选项；验证稳定后如需改默认值，应另行做版本迁移，不在本次隐式改变。
- 样式是全局偏好，RDP 和 RustDesk 都读取同一个键；每个协议的触控板/直接触控/键鼠操控模式仍由各自的 `rdpControlMode`、`rustdeskControlMode` 决定。

### 4.2 个性化界面

在 `HostListPage.ets` 的现有“个性化”卡片中增加一行“虚拟鼠标样式”：

- 说明文字：`触控板模式下远端指针的显示方式`。
- 提供两个互斥选项：`圆环`、`标准箭头`；沿用当前个性化卡片和响应式 breakpoint 的视觉规范。
- 点击后立即更新 `AppStorage`、`Preferences` 和云同步表；已经打开的远程桌面会通过 `@StorageLink` 在下一帧切换样式，不要求断开重连。
- 仅在触控板模式使用该样式。直接触控仍使用原有反馈，键鼠模式仍使用已有系统指针决策。

### 4.3 持久化与云同步

沿用当前 `HostListPage` 的设置流程：

1. 添加 `@StorageLink('virtualMouseStyle')` 字段及合法值归一化函数。
2. 初始化时从 `RemoteDesktopAppPrefs` 读取，并用 `AppStorage.setOrCreate()` 注入运行时。
3. 新增保存方法，复用现有 `persistPref()`，使本地 Preferences 与 `CloudStore.upsertUserSetting()` 同步。
4. 将 `virtualMouseStyle` 加入 `CloudSyncSettingsPolicy.ets` 的白名单；现有 `CloudStore` 按白名单读写 `usersettings`，不需要改变表结构。
5. 在云端恢复后对该值再次做合法性校验，非法或类型不符时回退 `circle`，避免旧版本或手工污染数据让 ArkTS 状态出现异常。
6. 更新 `CloudSyncSettingsPolicy.test.ets`，断言新键可同步且其他临时会话状态仍不可同步。

## 5. 虚拟鼠标箭头实现方案

### 5.1 覆盖层职责

在 `RemoteDesktop.ets` 的现有远端表面 `Stack` 中增加样式分发：

```text
connected && touchpadMode
  -> circle: 现有圆环覆盖层
  -> arrow: 标准箭头覆盖层
```

要求：

- 不在 XComponent 内部依赖系统光标；箭头由 ArkUI `Stack` + 矢量资源或 `Canvas/Path` 绘制。
- 覆盖层必须继续使用 `HitTestMode.None`，不拦截任何触摸、拖拽和三指控制面板手势。
- 箭头尺寸以逻辑像素定义，在手机和 Pad 的不同密度下保持可识别；初始尺寸建议 24–28 vp，真机再微调。
- 箭头使用黑色主体加浅色描边或反差描边，保证在深浅远端桌面背景上可见。
- 箭头的 hotspot 固定在尖端，不能把图形中心当作命中点。绘制资源的尖端坐标、宽高和本地偏移要集中定义，避免后续换资源时出现偏移。
- 圆环样式继续复用现有环大小、颜色、按钮状态和自动隐藏逻辑。
- 箭头样式在触控板会话中持续可见，只在断开、离开触控板模式或远端坐标尚未初始化时隐藏；不能沿用圆环的 900 ms 自动隐藏。
- 箭头按下/拖拽时仅做轻微视觉反馈，例如缩放、颜色或小型按下环；不改变按键事件顺序。

### 5.2 坐标与状态

保持 `remoteCursorX/Y` 为远端逻辑坐标的唯一输入语义，并增加可响应的覆盖层状态：

- 远端逻辑坐标继续经过现有 `remoteToLocalPoint()`/letterbox 变换后得到本地显示坐标。
- 将本地覆盖层位置放入 `@State`（或等价的可观察状态），在光标移动、远端尺寸变化、表面布局变化、横竖屏切换时刷新。
- 远端桌面尺寸、视频帧尺寸和本地表面尺寸不一致时，箭头仍以远端桌面坐标转换，不直接以视频帧像素定位。
- 当远端尺寸变化时只重新夹紧和转换当前逻辑坐标，不把光标吸到触点或屏幕中心；只有首次初始化才使用远端桌面中心。
- 统一整理 `touchIndicatorX/Y` 与 `remoteCursorX/Y` 的更新入口，确保圆环和箭头不会各自维护一套漂移坐标。

### 5.3 样式策略模块

新增纯 ArkTS 策略模块 `entry/src/main/ets/services/RemoteCursorStylePolicy.ets`，避免在页面构建函数中散落字符串判断。建议提供：

- `RemoteCursorStyle = 'circle' | 'arrow'` 类型。
- `normalizeRemoteCursorStyle(value: string | undefined): RemoteCursorStyle`。
- `shouldRenderVirtualTouchpadCursor(connected, touchpadMode, cursorReady): boolean`。
- `shouldRenderArrowCursor(style, connected, touchpadMode, cursorReady): boolean`。
- `shouldRenderCircleCursor(style, indicatorVisible, connected, touchpadMode): boolean`。

保留并复用已有 `RemotePointerModePolicy` 对键鼠模式的系统指针判定，不把本次虚拟箭头逻辑混入外接鼠标模式。

## 6. 触控映射曲线设计

### 6.1 设计目标

映射以“慢速精确、快速跨屏、连续可预测”为目标：

- 手指慢慢移动时降低倍率，方便停在 16–32 px 的小按钮或文字控件上。
- 手指快速移动时逐步提高倍率，减少跨屏所需的滑动次数。
- 速度变化必须平滑，不能在阈值处突然跳动。
- 横向、纵向、斜向保持同一倍率，不改变方向。
- 不给小位移设置硬性死区；触控板事件产生的有效微小位移必须能通过累加最终体现。

### 6.2 初始曲线

新增纯策略模块 `entry/src/main/ets/services/TouchpadPointerCurvePolicy.ets`。曲线的输入使用触控事件的本地表面位移和事件间隔，远端分辨率换算仍沿用现有 `remoteDeltaFromLocal()`：

```text
distance = hypot(stepDx, stepDy)
dt = clamp(elapsedMs, 8 ms, 100 ms)
instantSpeed = distance / dt
smoothedSpeed = lerp(previousSpeed, instantSpeed, smoothing)
t = clamp((smoothedSpeed - precisionSpeed) /
           (fastSpeed - precisionSpeed), 0, 1)
eased = t * t * (3 - 2 * t)       // smoothstep
curveGain = minGain + (maxGain - minGain) * eased
```

第一版调参起点：

- `minGain`: 0.45–0.60，建议先用 0.55。
- `maxGain`: 1.80–2.00，建议先用 1.90。
- `smoothing`: 0.20–0.35，先用 0.25，减少单帧尖峰。
- `precisionSpeed`、`fastSpeed` 根据实际 TouchEvent 位移单位设定；先通过调试日志/真机采样确认范围，再固定到策略常量。
- `dt` 异常、首帧或长时间停顿时使用安全默认值并重置速度状态，不能因除零或后台恢复产生大跳步。

策略函数应返回有效倍率、平滑速度和下一状态，便于 Hypium 在不启动页面的情况下验证单调性、边界和稳定性。

### 6.3 现有 RustDesk 速度设置的兼容方式

- 曲线作为 RDP 和 RustDesk 共用的基础倍率。
- RustDesk 现有 `rustdeskTouchpadSpeed` 继续作为用户倍率；有效倍率应经过统一上限保护，避免用户已选 2.2x 时再叠加高速曲线造成跨越过大。
- RDP 暂不新增独立速度设置，使用曲线默认倍率。
- 具体合成顺序固定为：本地表面到远端桌面比例 → 曲线倍率 → RustDesk 用户倍率 → 远端边界夹紧；若实现中采用不同顺序，必须用同一组基准案例证明结果等价且不会重复缩放。
- 第一轮真机调参重点检查 RustDesk 的最慢/默认/最快三档，必要时为最终有效倍率增加上限，而不是破坏现有设置值的持久化语义。

### 6.4 浮点累加器

在 `RemoteDesktop.ets` 中新增与显示/发送坐标分离的精确累加值：

```text
remoteCursorPreciseX/Y  // 保留小数，用于下一次相对位移
remoteCursorX/Y         // 夹紧后取整，用于既有发送和点击接口
```

实现要求：

- 每次单指移动从 `remoteCursorPreciseX/Y` 加上换算后的浮点 delta，而不是从已取整的 `remoteCursorX/Y` 重新计算。
- 只有发送、显示或边界判断需要整数时才取整；坐标夹紧应先作用于精确值，再生成整数镜像。
- 首次初始化、远端尺寸变化、重连、切换操控模式和取消手势时同步两个坐标值，避免残留小数造成下一次会话跳动。
- 远端边界 `[0, width - 1]`、`[0, height - 1]` 必须同时作用于精确坐标和发送坐标。
- 点击、右键、拖拽释放继续使用当前显示/发送坐标，保证命中点和视觉箭头一致。

### 6.5 手势状态重置

在以下时机清空曲线速度状态和上一帧时间：

- 单指 `Down`、`Up`、`Cancel`。
- 从单指转双指、从双指回单指。
- 长按拖拽开始/结束。
- 连接建立、断开、重连、远端分辨率改变。
- 进入直接触控或键鼠模式。

双指滚轮不走鼠标移动曲线；其现有滚轮增益、节流和反向设置保持不变。

## 7. 预计修改文件与任务拆分

### Task 1：定义样式和曲线纯策略

**文件：**

- 新增 `entry/src/main/ets/services/RemoteCursorStylePolicy.ets`
- 新增 `entry/src/main/ets/services/TouchpadPointerCurvePolicy.ets`
- 新增 `entry/src/test/RemoteCursorStylePolicy.test.ets`
- 新增 `entry/src/test/TouchpadPointerCurvePolicy.test.ets`
- 修改 `entry/src/test/List.test.ets`

**步骤：**

- [ ] 先写样式归一化、模式判断和曲线边界的失败测试。
- [ ] 实现 `circle/arrow` 合法值回退和虚拟光标显示条件。
- [ ] 实现速度计算、平滑、smoothstep 曲线和有效倍率上限。
- [ ] 测试零位移、极短/极长 `dt`、慢速/快速、斜向、连续性、单调性和 NaN/负数防护。
- [ ] 在 `List.test.ets` 注册两个纯策略测试。

### Task 2：设置、持久化和云同步

**文件：**

- 修改 `entry/src/main/ets/pages/HostListPage.ets`
- 修改 `entry/src/main/ets/services/CloudSyncSettingsPolicy.ets`
- 修改 `entry/src/test/CloudSyncSettingsPolicy.test.ets`

**步骤：**

- [ ] 增加 `virtualMouseStyle` 的 `@StorageLink`、默认值和归一化读取。
- [ ] 在启动恢复流程中读取 Preferences，并同步到 AppStorage。
- [ ] 在现有“个性化”卡片添加样式选择行和两个选项。
- [ ] 新增保存函数，复用 `persistPref()`，确认本地写入与 CloudStore 推送均发生。
- [ ] 把键加入 `CloudSyncSettingsPolicy`，验证云恢复能覆盖运行时值且非法值回退圆环。
- [ ] 不把 `rustdeskControlMode`、`rdpControlMode` 或会话临时状态误归入新的样式字段。

### Task 3：RemoteDesktop 虚拟箭头覆盖层

**文件：**

- 修改 `entry/src/main/ets/pages/RemoteDesktop.ets`
- 可能新增 `entry/src/main/resources/base/media/virtual_mouse_arrow.svg`（或 API 23 兼容的等效矢量资源）
- 需要时修改 `entry/obfuscation-rules.txt`

**步骤：**

- [ ] 读取 `@StorageLink('virtualMouseStyle')`，把样式判断限定在触控板模式。
- [ ] 抽取现有圆环渲染为独立分支，保持现有自动隐藏和颜色反馈。
- [ ] 添加箭头覆盖层，使用尖端 hotspot、letterbox 坐标转换和 `HitTestMode.None`。
- [ ] 增加持续可见的箭头状态；连接后初始化到远端中心，断开或离开触控板模式时隐藏。
- [ ] 在左键按下、右键、长按拖拽期间提供轻微视觉状态，不改现有 `sendMouse()` 顺序。
- [ ] 在移动、布局、分辨率和横竖屏变化时刷新覆盖层位置，确认箭头不会被视频缩放中心化偏移。
- [ ] 确认键鼠模式继续由 `RemotePointerModePolicy` 控制系统指针，直接触控不使用新箭头。

### Task 4：接入速度曲线和精确坐标

**文件：**

- 修改 `entry/src/main/ets/pages/RemoteDesktop.ets`

**步骤：**

- [ ] 增加触控移动时间、平滑速度和精确坐标累加状态。
- [ ] 在单指移动分支计算 `stepDx/stepDy` 的速度曲线倍率，再复用已有远端尺寸比例换算。
- [ ] 保留 RustDesk 用户倍率，并增加有效倍率边界保护；RDP 使用统一基础曲线。
- [ ] 让 `rememberRemoteCursor()` 同步精确坐标与整数镜像，移除从整数坐标继续累加造成的微移丢失。
- [ ] 在所有手势和会话生命周期入口重置曲线状态及累加器。
- [ ] 检查点击、右键、拖拽、滚轮、键盘避让、断连清理等路径仍读取同一远端命中坐标。

### Task 5：定向验证与真机调参

**步骤：**

- [ ] 运行 `default@OhosTestCompileArkTS`，确认新增策略和页面编译通过。
- [ ] 运行生产 `assembleHap`，不得用旧的 `default@OhosTestBuildArkTS` 作为唯一验收门。
- [ ] 运行 `git diff --check`。
- [ ] 运行项目规定的 Light 合规门：`powershell -File scripts/verify_open_source_release.ps1 -Mode Light`。
- [ ] 在 Phone 真机验证 RDP/RustDesk 的圆环和箭头两种样式。
- [ ] 在 Pad 真机验证横屏、竖屏、letterbox、不同远端分辨率和窗口尺寸。
- [ ] 对小按钮进行慢速靠近、微调、停留和点击；确认箭头尖端命中按钮而不是图形中心。
- [ ] 对快速跨屏、斜向移动、边界移动进行验证；确认无明显跳跃、反向、越界或卡死。
- [ ] 验证单击、双击（若现有手势支持）、双指右键、双指滚轮、长按拖拽和拖拽释放。
- [ ] 修改设置后在已连接会话中确认立即生效，重启应用后确认本地持久化，启用云同步后确认跨设备恢复。
- [ ] 验证直接触控、键鼠模式、外接设备和现有系统指针行为没有回归。

## 8. 测试设计与验收标准

### 8.1 自动化测试

纯策略测试至少覆盖：

- 非法样式、空值和旧数据均规范化为 `circle`。
- 只有触控板模式且坐标已准备好时才绘制虚拟光标。
- `arrow` 不受圆环短暂显示标志影响；`circle` 仍受该标志控制。
- 同一 `dt` 下快速移动倍率大于慢速移动倍率，且倍率落在配置范围内。
- 速度经过阈值时连续变化，边界输入不产生 NaN、Infinity 或负倍率。
- X/Y 同比例处理，斜向移动方向不改变。
- 浮点增量连续累积后能跨过一个远端像素，不能被每帧取整吞掉。

### 8.2 人工验收

功能完成的必要条件：

1. 用户可以在“设置 → 个性化”选择“圆环/标准箭头”，选择结果能保存。
2. 标准箭头尖端与远端实际命中位置重合，视频缩放、留黑边和旋转后仍然重合。
3. 慢速微调能稳定停在小按钮上；快速移动能明显减少跨屏滑动次数，且速度变化没有突跳。
4. 现有触控板点击、右键、滚轮、长按拖拽的远端事件结果不变。
5. 直接触控和键鼠模式没有被新样式覆盖；外接鼠标仍走已有系统指针路径。
6. RDP 和 RustDesk 均可用，RustDesk 既有触控板速度设置仍有效且不会让高速档失控。
7. 通过生产 HAP、ArkTS 测试编译、`git diff --check` 和 Light 合规门。

## 9. 风险与处理

| 风险 | 处理 |
|---|---|
| API 23 对自定义光标资源或 Canvas API 的限制 | 优先使用现有 ArkUI `Stack`/`Image`/矢量资源能力；若资源编译或渲染不稳定，退回 API 23 已验证的 `Canvas/Path` 绘制，不引入系统光标依赖 |
| 箭头覆盖层遮挡触摸 | 固定 `HitTestMode.None`，并在真机执行点击、拖拽、三指手势回归 |
| 曲线在不同密度和事件频率下过快/过慢 | 速度使用本地表面坐标和受保护 `dt`，先用日志采样，再在 Phone/Pad 各选一台真机校准阈值；不把未验证阈值暴露成永久用户设置 |
| RustDesk 既有速度倍率与新曲线叠加过大 | 统一计算有效倍率并设置安全上限，测试 0.4x、1.0x、2.2x 三档 |
| 远端分辨率改变后箭头偏移 | 精确坐标与显示坐标分离，所有位置都经过同一 `remoteToLocalPoint()`，在横竖屏和 letterbox 用固定坐标案例验证 |
| 云端旧数据类型异常 | 读取时做字符串枚举校验，非法值回退 `circle`；CloudStore 只增加白名单键，不改表结构 |
| 现有工作区有未跟踪文件或活动分支 | 实施时只选中新功能文件；按 `AGENTS.md` 先归档当前任务，再创建对应任务分支，不触碰 `.appanalyzer/`、VNC 设计文档等用户文件 |

## 10. 完成后的交付闭环

实际实施时遵循仓库 `AGENTS.md`：

1. 在有活动任务时继续/等待同一任务分支，不另建持久 worktree。
2. 只修改本计划列出的文件，先完成定向测试和 HAP 构建。
3. 更新 `CURRENT.md`、`QUEUE.md` 记录实现状态、验证结果和未解决的调参问题。
4. 只暂存本任务文件并创建清晰 commit；不提交本地签名、配置、用户数据或未跟踪的既有文件。
5. 完成后按项目流程 push、PR、合规检查并回到同步的 `main`。
