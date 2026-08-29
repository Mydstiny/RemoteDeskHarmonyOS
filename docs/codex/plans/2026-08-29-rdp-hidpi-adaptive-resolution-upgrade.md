# RDP 高 DPI 自适应分辨率升级计划

状态：阶段 1–4 已实现并进入最终自动化门禁；真实 Windows 兼容矩阵待外部环境验收。

## 执行结果

- 已落地密度感知的连接时回退：未协商动态能力前，以同比例逻辑分辨率保证字体可读；
  `disp` caps 就绪后再升级为物理像素 + DPI scale。
- 已贯通 ArkTS、NAPI、FreeRDP 的分辨率、物理尺寸、方向和 100/140/180 scale 契约，
  并增加 device-local “远端界面大小”设置、控制中心状态和诊断字段。
- 已启用 `disp`/dynamic resolution，完成 500 ms 防抖、native 限流、单请求在途、
  latest-wins、超时、caps 校验、生命周期取消和不掉线降级。
- 已重建 arm64-v8a/x86_64 FreeRDP 预编译，修复可复现路径与共享盘公开接口，更新
  provenance、归档哈希和构建时必需符号检查。
- 已增加 ArkTS 策略与 native 策略/队列测试。自动化结论与 HAP 哈希在最终门禁后回写
  `docs/codex/CURRENT.md`；HarmonyOS PC × Windows 10/11/Server 真机矩阵保留为发布验收项。

## 目标

让 HarmonyOS PC 的 RDP 会话同时满足：自适应模式字体可读、画面比例匹配窗口、窗口变化后不长期留黑边，并在远端不支持动态分辨率或 DPI 缩放时可预测地降级。

## 已确认缺口

1. 当前自适应把 XComponent 的物理像素直接作为 Windows 桌面尺寸，最长边仅封顶 3840；高密屏会得到较大的远端工作区，但 FreeRDP 仍使用默认 100% 桌面/设备缩放，字体偏小。
2. 固定预设与任意 PC 窗口比例不一致时，renderer 的 `contain` 策略必然留边；改成默认裁切或拉伸会隐藏内容或破坏比例，不能作为修复。
3. 自适应尺寸只在连接前计算一次。窗口变化目前只 resize 本地 renderer，分辨率设置仍需重连。
4. 当前 arm64/x86_64 FreeRDP 预编译包未启用 `CHANNEL_DISP_CLIENT`，因此不能通过 RDP Display Control 主动发送 monitor layout。
5. RDP 自适应沿用“计算机画面强制横屏”逻辑，窄窗口或竖向分屏时不能真实匹配窗口。
6. 原生侧已具备服务端桌面 resize 的事务化 GDI、frame pump 和 renderer source 重建，可作为动态分辨率回包基础。

## 产品契约

- `窗口适配`：默认“自动匹配窗口”；固定分辨率保留在高级选项，并提示比例不同可能留边。
- `远端界面大小`：提供“自动、标准、大、特大”，首选映射到兼容的 100%、140%、180% RDP scale。
- `本地查看缩放`：继续表示 Fit/100%/125%/手势画布缩放，不与 Windows DPI 缩放混为同一设置。
- 自动模式完整显示远端桌面，不默认裁切、不拉伸；可选“填满并裁切”如以后增加，必须明确标为查看模式。
- 界面大小偏好属于查看设备能力，应 device-local；不得修改远端 Windows 的持久系统显示设置。

## 目标策略

新增纯策略 `RdpAdaptiveDisplayPolicy`，输入窗口物理/逻辑尺寸、`densityPixels`、有效 DPI、用户界面大小、设备形态和协议能力，输出请求分辨率、scale factors、方向、降级原因与是否需要重连。

1. 先以 XComponent 实际内容区确定宽高比；PC 窗口不再强制横屏。宽高使用同一倍率，最后按协议要求偶数化并限制在服务端能力范围内。
2. “自动界面大小”根据 HarmonyOS 显示密度选择最近的已验证档位 100/140/180；用户显式选择优先。
3. 服务端可接受 DPI scale 时，远端分辨率保持接近窗口物理像素以保证清晰度，同时发送 `DesktopScaleFactor`、`DeviceScaleFactor`，物理尺寸和方向仅在本地数据有效时附带。
4. DPI scale 不可用或被兼容策略禁用时，按目标界面倍率等比降低远端分辨率：`remote = surfacePx / uiScale`。两个轴除以同一倍率，因此仍与窗口同比例。
5. 保留当前 3840 最长边作为第一版清晰度/带宽上限；最小尺寸、偶数约束和 Display Control caps 在纯策略中统一处理，不散落到页面和 native。
6. 自动策略生成可诊断的 `requested/effective resolution`、scale、capability、fallback reason；不记录主机地址、用户名或凭据。

## 分阶段实施

### 阶段 1：密度感知的连接时自适应

- 新增纯策略及 ArkTS 单元测试，覆盖密度 1.0/1.25/1.5/2.0、16:9/16:10/3:2、窄窗口、偶数化和 3840 封顶。
- RDP `auto` 改由该策略生成精确窗口比例；FreeRDP 暂不支持 DPI 时，默认使用等比降低分辨率的可读性回退。
- 固定预设、迁移 ID 和现有本地查看缩放保持兼容；文案明确“本次连接尺寸”，仍提示重连生效。
- 先在 HarmonyOS PC 默认启用新自动策略；Phone/Pad 保持现有观察行为，待矩阵通过后再统一。

交付价值：不改 FreeRDP 依赖即可解决主要字体问题，并让连接时自动模式没有比例黑边。

### 阶段 2：RDP DPI 缩放协商

- 在 ArkTS → NAPI → `ConnectionConfig` 增加 scale、方向和可选物理尺寸字段，进行范围校验和兼容默认。
- FreeRDP 连接前设置 `DesktopScaleFactor`、`DeviceScaleFactor`、有效的 physical width/height 与 orientation；首轮只开放已验证的 100/140/180。
- 对不支持、忽略或显示异常的远端保留阶段 1 的逻辑分辨率回退，不把失败升级为连接失败。
- 增加 native 配置映射测试、日志脱敏和 Windows 版本兼容验收。

交付价值：高密屏保持较高清晰度，同时由 Windows 放大字体和控件。

### 阶段 3：真正的动态分辨率

- 重建 arm64/x86_64 FreeRDP 预编译包，启用 `disp` client；同步更新预编译哈希、来源/provenance、SBOM、NOTICE 和许可证核对结果。
- 显式启用 `SupportDisplayControl` 与 `DynamicResolutionUpdate`，在 `ChannelConnected/Disconnected` 中按 session generation 管理 `DispClientContext`，等待 `DisplayControlCaps` 后才允许发送。
- 增加受生命周期保护的 native/NAPI `requestRdpDisplayLayout`，校验 server caps、尺寸、scale、方向和当前 owner；发送失败只关闭本次会话的动态能力，保留现有桌面。
- 复用现有 surface resize coordinator 做本地快速重绘；协议 resize 另设至少 500 ms 防抖、latest-wins 和单请求在途限制，避免拖窗风暴。
- PIP、后台保活、surface 转移、重连、断线和 renderer generation 变化时取消旧请求；服务端 resize 回包继续走现有事务化 `cbDesktopResize`。
- 服务端无 `disp`、caps 未就绪或请求被拒绝时，保留当前桌面并提示“重连后按新窗口适配”。

交付价值：全屏、分屏和自由窗口调整后，Windows 桌面尺寸跟随稳定窗口，不再依赖手动重连。

### 阶段 4：设置、诊断与灰度

- 重构 RDP 控制中心，把“窗口适配”“远端界面大小”“本地查看缩放”分层展示；动态能力就绪时标记立即生效，否则标记重连后生效。
- 迁移旧 `rdpDesktopResolutionId=auto` 为新自动窗口策略；固定 ID 不改语义。新增偏好走既有 device-local 持久化和备份兼容规则。
- 诊断面板增加请求/生效分辨率、DPI scale、`disp` capability、最近 resize 结果与降级原因。
- 先灰度到 HarmonyOS PC；真机矩阵通过后再评估 Phone/Pad 默认值，不跨协议复用 RDP DPI 语义。

## 主要代码范围

| 范围 | 预期文件 |
|---|---|
| 纯策略与偏好 | `services/RdpAdaptiveDisplayPolicy.ets`（新增）、RDP 偏好初始化/本地化策略 |
| 页面与设置 | `pages/RemoteDesktop.ets`、`components/rdp/RdpControlCenter.ets`、相关引导文案 |
| ArkTS/NAPI 契约 | `services/ExtensionLoader.ets`、两份 `rdpnapi.d.ts`、NAPI connection config 解析 |
| FreeRDP runtime | `rdp/freerdp_adapter.*`、display channel 生命周期与请求门控 |
| 预编译与合规 | `libs/freerdp-ohos/*`、SBOM/NOTICE/provenance/哈希登记 |
| 测试 | ArkTS policy tests、native lifecycle/config tests、既有 RDP resize/GFX 回归测试 |

## 验收标准

### 自动化

- 自动模式目标比例与稳定后的 XComponent 比例一致；偶数化造成的边缘误差不超过 2 个物理像素。
- 同一窗口在各 density 档位下得到确定的分辨率和 100/140/180 scale；无效 DPI、零尺寸和超限输入均安全回退。
- 动态请求最多约 2 次/秒、同 session latest-wins；旧 generation、PIP/后台/断线请求全部被拒绝或取消。
- `disp` 缺失、caps 未就绪、发送失败及服务端拒绝不会断开现有 RDP 会话。
- GDI/GFX resize、输入 viewport、远端光标和画布 transform 始终使用同一生效几何代际。

### 真机

- HarmonyOS PC：1.0/高密度显示，全屏、左右分屏、自由窗口、最大化/恢复、横竖向窄窗口。
- Windows：Windows 10、Windows 11、至少一个 Windows Server；覆盖支持与不支持 Display Control 的主机。
- 100/140/180 三档字体和控件大小可辨识，自动档默认不再出现用户反馈的高 DPI 小字体。
- 自动模式稳定后无可见比例黑边；固定预设继续完整显示并允许预期留边，不发生隐式裁切。
- 连续拖窗、快速最大化/恢复、PIP、后台恢复和重连无闪退、死帧、输入偏移或 resize 循环。
- 码率、FPS、首帧时间和 resize 恢复时间与当前基线对比记录；3840 上限下不出现不可接受的资源回退。

## 回退与风险控制

- 每阶段独立提交和验收；阶段 1 可在不依赖阶段 2/3 的情况下单独发布。
- 动态能力按会话协商并可本地关闭；关闭后回到连接时精确比例策略，不回退到任意固定预设。
- DPI 缩放出现远端兼容问题时，只对该策略/设备形态降级为逻辑分辨率，不修改远端系统设置。
- `disp` 预编译升级属于 native/依赖高风险变更，必须补双 ABI、ABI/导出、供应链和独立 reviewer 门禁；未通过前不得默认开启。
- 不以“铺满裁切”、非等比拉伸或修改 Windows 持久显示设置作为故障回退。

## 交付门禁

每个实现阶段均执行仓库规定的定向测试、两项 Hvigor、`git diff --check` 和 Light 合规；阶段 2/3 额外执行 native 单测、双 ABI/导出检查、预编译来源与哈希核验。只有自动化、独立复核和对应真机矩阵通过后，才将该阶段标记完成。
