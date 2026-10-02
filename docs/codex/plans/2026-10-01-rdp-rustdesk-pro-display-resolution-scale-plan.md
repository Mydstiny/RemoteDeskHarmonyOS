# RDP 与 RustDesk 高级显示方案及 Pro 接入计划

状态：`IMPLEMENTING`；P0–P4 代码增量已落盘，本地门禁与设备安装已完成，P5 真实远端矩阵与独立复核待验收

日期：2026-10-01（Asia/Shanghai）

项目：RemoteDeskHarmonyOS（公开产品名 RemoteDesktop）

适用范围：RDP 远端桌面分辨率、RDP Windows 式界面缩放、RustDesk 远端显示分辨率、自定义显示方案、Pro 权益与真机验收。

本计划由 2026-10-01 的只读研判形成，随后获得实现授权。当前工作区继续使用既有 `codex/pro-purchase-foundation` 活动任务；工作树保留其他并行改动，不切换分支、不创建持久 worktree、不清理无关脏文件。实现增量按声明范围落盘，真实 Windows/RustDesk peer、HarmonyOS 设备和生产权益验收仍需单独完成。

## 1. 决策摘要

用户反馈中的“自定义分辨率”可能对应两种不同需求：

1. 让远端 Windows/RustDesk 主机实际输出一个指定的桌面尺寸，以匹配 16:10、3:2、21:9 等目标比例；
2. 让已经收到的远端画面更好地放入本地窗口，减少黑边或查看溢出内容。

第一种会改变远端桌面、视频帧尺寸、带宽和输入几何；第二种只改变本地渲染。产品文案、数据模型和权益门控必须始终将二者分开。

建议将新增能力归入 Pro 的“高级显示方案”：

- RDP 的 Auto 和标准分辨率预设继续免费；
- RustDesk 远端已经宣告的候选分辨率继续免费；
- Fit、Fill、100%–200%、本地 Custom 和双指画布缩放继续作为本地查看能力；
- RDP 任意宽高、自定义 Windows 界面缩放百分比、按主机和设备保存高级显示方案作为 Pro；
- RustDesk 的自定义远端分辨率请求作为 Pro，但只对明确支持的 peer、远端平台和显示器类型开放；
- RustDesk 远端应用内部 TouchScale、Android Accessibility 注入和通用远端应用缩放不在本计划内。

RDP 的 Windows 式百分比必须拆成两个协议字段。微软 RDPEDISP 规定 `DesktopScaleFactor` 可为 100–500%，`DeviceScaleFactor` 只能为 100%、140% 或 180%。[MS-RDPEDISP DISPLAYCONTROL_MONITOR_LAYOUT](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpedisp/ea2de591-9203-42cd-9908-be7a55237d1c)；FreeRDP 也分别提供 `/scale-desktop` 与 `/scale-device`。[FreeRDP command line](https://github.com/FreeRDP/FreeRDP/blob/master/client/common/cmdline.c)

## 2. 当前实现基线

### 2.1 RDP

- [RemoteResolutionPresetPolicy.ets](../../../entry/src/main/ets/services/RemoteResolutionPresetPolicy.ets) 已有 Auto 和 18 个稳定尺寸，覆盖 4:3、5:4、16:9、16:10、21:9、4K 等常见比例；当前模型仍是稳定 ID + 宽高预设，没有用户自定义宽高对象。
- [RdpAdaptiveDisplayPolicy.ets](../../../entry/src/main/ets/services/RdpAdaptiveDisplayPolicy.ets) 当前公开 `auto`、`100`、`140`、`180` 四种远端界面大小，并按本地密度在这三档之间选择自动值。
- [rdp_display_layout_policy.h](../../../entry/src/main/cpp/rdp/rdp_display_layout_policy.h) 已统一校验 200–8192 尺寸、偶数宽度、物理尺寸、方向、Display Control server caps、限频、单请求在途和超时 fail-closed。
- [freerdp_adapter.cpp](../../../entry/src/main/cpp/rdp/freerdp_adapter.cpp) 已在初始连接配置 `FreeRDP_DesktopWidth`、`FreeRDP_DesktopHeight`、`FreeRDP_DesktopScaleFactor`、`FreeRDP_DeviceScaleFactor`、物理尺寸、方向和 Display Control；动态请求通过 `requestDisplayLayout` 进入同一 native 事务。
- PC 会话具备 Display Control 能力等待、caps 校验、500 ms 防抖、latest-wins、超时禁用、输入几何 fence 和 renderer/source geometry 回放。真实 Windows 主机、不同 server 版本和实际 DPI 显示效果仍需设备验收。
- 当前 PC 运行时动态调整受 `Display Control` 和会话生命周期约束；Phone/Pad 的自适应尺寸主要在连接前计算，不能把 PC 动态切换语义直接推广到移动设备。

### 2.2 RustDesk

- [RemoteDesktop.ets](../../../entry/src/main/ets/pages/RemoteDesktop.ets) 已有远端显示器目录、显示器切换、候选分辨率菜单、pending/timeout 状态和 geometry epoch 处理。
- [rustdesk_ffi/src/lib.rs](../../../rustdesk_ffi/src/lib.rs) 已导出 `rustdesk_change_display_resolution(handle, display, width, height)`；[connector.rs](../../../rustdesk_ffi/src/connector.rs) 已构造 `Misc.change_display_resolution` 消息。
- [message.proto](../../../rustdesk_vendor/libs/hbb_common/protos/message.proto) 同时保留新 `DisplayResolution` 和旧 `change_resolution` oneof；协议注释说明新字段用于 1.2.4 及以上 peer，旧 peer 仍需兼容旧消息。
- 当前 FFI 请求成功只代表本地消息进入控制队列，不代表远端显示器已经应用；最终事实必须来自远端确认消息、实际新视频帧尺寸和输入几何更新。
- RustDesk 物理显示器、虚拟显示器/IDD、多显示器、Windows 权限、Linux X11/Wayland 和远端移动平台的能力不同。官方显示服务明确指出 Wayland 当前不支持改变显示分辨率，并保留远端原始分辨率恢复流程。[RustDesk display_service.rs](https://github.com/rustdesk/rustdesk/blob/master/src/server/display_service.rs)

### 2.3 本地查看缩放

- [RemoteCanvasTransformPolicy.ets](../../../entry/src/main/ets/services/RemoteCanvasTransformPolicy.ets) 已建模 Fit、Fill、100%、125%、150%、175%、200%、Custom、焦点缩放、pan、边界钳制、旋转和窗口/远端几何 rebase。
- 本地画布缩放只影响 renderer viewport、letterbox/crop 和输入反变换，不改变远端桌面分辨率；它不应因为新增 Pro 远端能力而被门控或改名成“远端分辨率”。

### 2.4 Pro 基础设施

- [ProFeatureCatalog.ets](../../../entry/src/main/ets/services/pro/ProFeatureCatalog.ets) 已区分 `available`、`planned`、`experimental` 和 `disabled`，并支持按设备、协议、能力、权限和 entitlement 描述功能。
- [ProAccessPolicy.ets](../../../entry/src/main/ets/services/pro/ProAccessPolicy.ets) 已分开 `visible` 与 `executable`，并对账号、环境、权益、设备、协议、能力、权限和 server authorization 做纯策略判断。
- 新显示能力必须先进入共享 Pro 可见性目录，再在页面、会话菜单、异步 action 和 native dispatch 前重新执行权益检查。购买、恢复、退款、账号切换、冷启动和过期后的旧状态不能继续驱动受保护操作。

## 3. 产品契约

### 3.1 用户可见的三个概念

| 名称 | 作用 | 是否改变远端主机 | 建议权益 |
|---|---|---:|---|
| 远端桌面大小 | 要求远端输出指定桌面尺寸，影响远端帧和输入空间 | 是 | Auto/标准预设免费，自定义 Pro |
| Windows 界面缩放 | RDP `DesktopScaleFactor`/`DeviceScaleFactor`，影响远端字体与控件 | 只改变本次会话 DPI 协商 | 标准档免费，自定义百分比 Pro |
| 本地查看缩放 | Fit、Fill、画布 zoom/pan、输入反变换 | 否 | 免费 |

RDP 会话中建议使用“远端桌面大小”“Windows 界面缩放”“本地查看缩放”三个明确标题。RustDesk 中使用“远端显示器”“远端候选分辨率”“本地查看缩放”；RustDesk 不复用 RDP 的 Windows DPI 文案。

### 3.2 免费与 Pro 边界

免费能力：

- RDP Auto 和现有稳定预设；
- RustDesk peer 已返回的候选分辨率和显示器切换；
- RDP 100%、140%、180% 兼容档以及自动档；
- 本地 Fit/Fill/固定查看缩放/双指画布缩放；
- 远端不支持显示控制时的正常连接、查看和输入。

Pro 能力：

- RDP 任意宽高的单显示器会话方案；
- RDP 100–500% 的 `DesktopScaleFactor` 自定义值；推荐预设为 100%、125%、150%、175%、200%；
- 按“主机 × 本地设备/显示器 × 方向”保存多个显示方案；
- RustDesk 在兼容 peer 上提交任意受控尺寸请求、保存远端显示方案和查看实际应用结果。

RDP v1 仍以单远端显示器为范围；RustDesk 多显示器按 `display index` 操作，不在本计划内合并成跨屏虚拟桌面。改变 RustDesk 物理显示器可能影响远端用户，确认页必须显示目标显示器、原始尺寸、目标尺寸、权限和恢复策略。

## 4. 数据模型与持久化方案

建议新增版本化的 device-local 显示方案模型，具体命名在实现阶段根据现有 host-local personalization API 决定：

```text
RemoteDisplayProfile {
  schemaVersion: number
  profileId: string
  hostId: string
  protocol: 'rdp' | 'rustdesk'
  targetDisplay: number | null
  deviceScope: 'phone' | 'tablet' | 'pc' | 'unknown'
  displayScope: string
  orientationScope: 'landscape' | 'portrait' | 'any'
  resolution: {
    mode: 'auto' | 'preset' | 'custom'
    presetId: string
    width: number
    height: number
  }
  rdpScale: {
    desktopMode: 'auto' | 'preset' | 'custom'
    desktopPercent: number
    deviceMode: 'auto' | 'fixed'
    devicePercent: 100 | 140 | 180
  }
  localViewMode: 'fit' | 'fill' | '100' | '125' | '150' | '175' | '200' | 'custom'
  localViewCustomPercent: number
  createdAt: number
  updatedAt: number
}
```

约束：

- RDP 宽度、 高度范围为 200–8192；宽度必须为偶数；服务端 caps 和本地设备资源上限继续生效；默认自动策略仍保留 3840 长边预算。
- RDP `desktopPercent` 为整数 100–500；`devicePercent` 只能为 100、140、180；普通用户默认只看到 desktop percent，device percent 由自动策略选择。
- RustDesk 自定义请求使用相同的安全尺寸范围，但最终以 peer 的候选列表、版本、平台和实际帧为准；远端返回的取整值必须保留为 effective value。
- 本地查看缩放仍使用现有 50–300% Custom 范围和独立字段，不能复用远端分辨率 ID 或 RDP scale 字段。
- 方案默认保存在当前设备的 host-local personalization，不写入密码、token、远端凭据或未授权的共享云字段。
- `rdpDesktopResolutionId`、旧四档 `rdpDesktopPreset`、`rdpRemoteUiScale` 和本地查看缩放旧字段需要可逆迁移；未知或损坏的远端 Pro 值回退 Auto/免费预设，不能阻塞启动。

建议将“草稿”“当前有效方案”“最近一次远端 effective result”分开保存。权益撤销时清理受保护的当前请求和内存态，允许保留不可执行的草稿供用户重新购买后恢复，但不得让草稿绕过 Pro action gate。

## 5. 分阶段实施计划

### P0：契约冻结与实现前审查

任务：

1. 刷新当前分支、脏范围、FreeRDP 真实链接状态、RustDesk vendor/proto 来源和本地 API/SDK 证据。
2. 固定上述三种缩放语义、免费/Pro 边界和单显示器范围。
3. 记录 RDP 的当前 Auto/预设/动态 Display Control 行为，记录 RustDesk 当前候选菜单和实际未验收边界。
4. 明确实现文件范围，禁止把本计划与当前 Pro 反馈、工作区、SSH、UI 的未提交改动混入同一实现增量。

退出条件：评审可以用一条具体示例判断结果，例如 `1920×1200 + RDP 125% + 本地 Fit` 的三层状态互不混淆。

### P1：策略、模型与 Pro 门控

任务：

1. 建立显示方案 schema、范围校验、迁移、profile scope 和 effective result 模型。
2. 新增 Pro feature ID，默认进入 Pro 升级目录；共享可见性先于页面渲染，业务 action 仍必须使用当前 entitlement。
3. 对购买、恢复、退款、账号切换、冷启动、离线过期和异步存储写入建立 generation/lease fence。
4. 为页面、session toolbar、native dispatch 定义统一 `visible / locked / unsupported / pending / applied / rejected` 状态。

退出条件：旧设置迁移无损，免费值仍可执行，Pro 值在无权益、错误账号、过期或能力不足时不能进入 native 请求。

### P2：RDP 自定义分辨率与 Windows 式缩放

任务：

1. 将 `DesktopScaleFactor` 和 `DeviceScaleFactor` 拆成独立策略和 native 校验；保留自动密度选择。
2. 为 RDP 增加自定义宽高输入、比例锁定可选项、协议范围提示、设备资源提示和恢复默认。
3. 初始连接将 profile 转为 `SessionConfig`；PC 动态请求复用 Display Control 的 caps、限频、latest-wins、单请求在途、超时和输入 fence。
4. 动态请求结果必须区分 `accepted`、`queued`、`applied`、`server_adjusted`、`rejected`、`not_ready`、`unsupported` 和 `timeout`。
5. Display Control 不可用时保留当前会话，提示“重连后生效”，不能把失败转成断线或黑屏。
6. 诊断同时记录 requested/effective resolution、requested/effective scale、capability、fallback reason 和 geometry epoch，不记录主机地址或凭据。

退出条件：Windows 10、Windows 11 和至少一个 Windows Server 上，RDP 100/125/150/175/200% 及代表性自定义宽高可以区分请求值与实际值；动态切换后首帧、viewport、输入和远端光标保持一致。

### P3：RustDesk 能力感知的远端分辨率

任务：

1. 解析 `PeerInfo` 的版本、平台、显示器、current display、候选分辨率、虚拟显示器信息和权限状态。
2. 按 peer 版本发送 `change_display_resolution` 或兼容的旧 `change_resolution`；旧版本和缺失版本不能盲发带 display index 的新消息。
3. 第一版只对 Windows/虚拟显示器/X11 等已验证目标开放 Pro 自定义请求；Wayland、移动 peer、无权限、无驱动和能力未知时只显示本地缩放或候选列表。
4. 自定义请求进入 pending 状态后，等待 `SwitchDisplay`/PeerInfo/实际新帧；快速连续选择使用 request generation，旧回执不得覆盖新方案。
5. 切换期间暂停输入，保留旧帧或显示明确进度；成功后更新 remote geometry、renderer、viewport、光标和输入矩阵；失败保留旧画面。
6. 连接建立时保存远端原始显示快照；断开后核对恢复状态，恢复失败必须提示用户。

退出条件：新版 Windows RustDesk peer 可以完成能力读取、显示器选择、自定义请求、实际帧确认和交互；旧 peer、Wayland、无权限和无驱动场景有明确可行动提示，且不会影响正常连接。

### P4：共享渲染、输入和会话 UX

任务：

1. 在设置中心建立“显示与交互”共享区，在 RDP/RustDesk 协议区放置各自远端能力；会话菜单提供临时覆盖和“恢复设置默认值”。
2. RDP 显示项显示“远端桌面大小”“Windows 界面缩放”“本地查看缩放”；RustDesk 显示“远端显示器”“远端候选/自定义请求”“本地查看缩放”。
3. PC、Pad、Phone 分别适配分栏、分组卡片和底部 Sheet；非法值、能力加载中、权益锁定、远端拒绝和超时必须有不同文案。
4. 所有远端几何变化通过同一 geometry epoch 进入 renderer、canvas transform、远端光标和输入坐标；窗口 resize、旋转、PIP、后台恢复和重连不能保留旧尺寸。
5. 本地 pinch/pan 只提交 `CanvasTransform`；不得因为本地画布手势开启而发送 RDP Display Control 或 RustDesk `TouchScale`。

退出条件：同一远端帧在 Fit、固定本地缩放、远端重设分辨率后都能通过四角/中心/边界 round-trip；输入误差不超过 1 个物理像素或定义的取整误差。

### 5.1 当前执行记录（2026-10-01）

- P0 契约已冻结：远端桌面大小、RDP Windows 界面缩放、本地查看缩放使用独立字段；RDP v1 只处理单远端显示器，RustDesk 自定义请求按 `display index` 处理。
- P1 已落盘：新增版本化 `RemoteDisplayProfilePolicy`，覆盖几何范围、旧 RDP 字段迁移、RDP desktop/device scale 分离、RustDesk peer 能力判断和请求状态文案；RDP/RustDesk 两个 Pro feature ID 已进入共享目录，当前保持 `experimental`，Release 不开放。
- P2 已落盘：RDP 设置页、会话控制中心和 `SessionConfig` 已接通自定义宽高；native 接受 desktop 100–500%、device 100/140/180% 的分离校验；Display Control 动态请求继续使用原有 caps、latest-wins、超时和输入几何 fence。
- P3 已落盘：RustDesk FFI display snapshot 升级到 v2，携带 peer 版本/平台；ArkTS 只接受精确的 Windows/Linux X11 平台标识、版本至少 1.2.4、显示器索引和显式权限证据，Wayland/mobile/能力未知保持候选列表降级。当前 RustDesk `PermissionInfo` 没有显示设置权限位，native 对 `hasPermission` 保持 false，故自定义请求继续封闭到后续补齐明确权限信号。
- P4 已落盘：设置与会话菜单已区分远端分辨率和本地画布缩放，custom 草稿不写入凭据；RDP 在冷启动、重连、窗口变化和动态请求前重新检查 entitlement，失效时回退 Auto/免费标准档。
- 本地验证（2026-10-02）：新增 RDP split-scale、Pro catalog 和 device-local settings 测试后，`default@OhosTestCompileArkTS` 通过（1 min 28.996 s）；修正显示页类型导入后再次通过（2 min 35.306 s），强制并行 `assembleHap` 再次通过（6.327 s）。RDP display policy 原生策略测试 15/15 通过；Rust host `--no-default-features` 320/320 通过；Pro entry gating 与 Pro runtime 全部通过；arm64 Rust 交叉编译、双 ABI native 编译、`git diff --check` 和 state validation 通过。`ohosTest@OhosTestCompileArkTS` 在当前工程未注册，准确错误为 `00306054`，不能作为通过项。修正后的 HAP SHA-256 为 `e410d003cb42bfda09c00a3eb4329126bb49d0a1a7a44b06a1c4cf3b083d6688`。
- 设备证据（2026-10-02）：此前 HAP `d3e0a15e…875e40e` 已成功覆盖安装到 `127.0.0.1:5557`、`192.168.31.118:40123`（MLR-AL10）和 `192.168.31.156:38451`（SGT-AL10）。模拟器与 MLR 可启动并导出页面树；MLR 页面树确认 RDP 与 RustDesk 主机入口及 Pro 标记可见。修正后的 HAP `e410d003…d6688` 已重新安装到当前仍在线的 `127.0.0.1:5557`；MLR/SGT 在复测时已断开，不能把修正后 HAP 写成已安装到真机。SGT 屏幕处于锁定状态，系统此前拒绝自动解锁并返回 `10106102`，因此没有把它写成 UI 交互通过。安装/页面树不等于真实远端分辨率或输入生效证据。
- 独立复审（2026-10-02，`/root/review_display_final`）：未发现 P0；RDP `DesktopScaleFactor`/`DeviceScaleFactor` 拆分、native 校验和 Pro action gate 未发现阻断问题。P1 为 host × device profile 尚未接入运行时：`RemoteDisplayProfilePolicy` 目前只提供纯模型/迁移函数，`RemoteDesktop.ets` 与 `HostListPage.ets` 仍直接读写全局 `AppStorage`/`RemoteDesktopAppPrefs`，无法按主机保存和恢复多个方案。`CloudSyncSettingsPolicy` 已确认这些字段不进入云同步。RustDesk `hasPermission=false` 的 fail-closed 结论符合当前 `PermissionInfo` 没有显示设置权限位的证据，但因此自定义远端请求仍是后续 P3 开放项。
- 未关闭项：先补齐 host × device profile 的运行时存储/恢复与回归测试，再完成 Windows 10/11/Server 实机 DPI 与 Display Control、RustDesk 新旧 peer/Windows 虚拟显示器/X11/Wayland/mobile 矩阵、Phone/Pad/PC 完整交互/恢复与输入、真实 Pro 购买/退款/账号切换回归、PR/required check/merge。生产能力继续由 `experimental` 和 capability/entitlement 双重门控；本次复审因 P1 发现保持 `REVIEW_REQUIRED`。

### P5：自动化、真机和远端矩阵

纯策略与 ArkTS：

- 尺寸范围、偶数化、面积 caps、比例分类、旧值迁移、profile scope、有效值回读；
- RDP desktop/device scale 分离、100–500% 边界、自动密度选择和降级；
- RustDesk 版本分支、空候选列表、多显示器、旧回执、超时、取消和 geometry epoch；
- entitlement 过期、账号切换、购买异步返回、冷启动和恢复购买后的 protected action；
- PC/Pad/Phone 的布局、取消、恢复默认、locked/unsupported/pending/applied 状态。

Native/Rust：

- RDP real FreeRDP 初始 settings、Display Control caps、server area caps、限频、timeout fail-closed、输入 fence 和 renderer replay；
- RustDesk protobuf 新旧 oneof、版本分支、FFI 参数边界、控制队列、旧 session 丢弃、display state 和实际帧几何；
- arm64-v8a 与 x86_64 ABI、真实 `USE_REAL_FREERDP=ON` 产物、来源/provenance/SBOM/NOTICE。

远端与设备：

| 维度 | 最低覆盖 |
|---|---|
| RDP 主机 | Windows 10、Windows 11、Windows Server；支持/不支持 Display Control；直连与 Gateway |
| RDP 比例 | 4:3、5:4、16:9、16:10、3:2、21:9、4K、窄窗口、竖向窗口 |
| RDP 缩放 | 自动、100%、125%、140%、150%、175%、180%、200%、自定义边界值 |
| RustDesk 主机 | 新旧 peer、OSS/Pro、Windows 物理显示器、Windows 虚拟显示器、Linux X11、Linux Wayland、移动 peer |
| HarmonyOS 设备 | Phone、Pad、PC；窗口化、全屏、分屏、旋转、PIP、后台恢复、重连 |
| 稳定性 | 连续切换、快速连点、远端拒绝、网络抖动、首帧、30 分钟高分辨率/高缩放压力 |

所有验收按“操作 → 预期结果 → 实际证据 → 状态”记录。编译、HAP、listener、候选列表或本地消息入队不能替代真实 Windows、peer、设备、远端实际帧和输入证据。

### P6：灰度、发布与回滚

1. 先灰度 RDP PC 的 Pro 自定义宽高和 desktop scale；真实 Windows 矩阵通过后，再扩大 Phone/Pad 的初始连接能力。
2. RustDesk 先开放能力目录和候选列表，再开放 Windows/虚拟显示器 Pro 自定义请求；其他平台保持清晰降级。
3. 新增功能以 Pro entitlement 和 capability 双重门控，生产配置默认关闭，Debug/实验能力不能写成已交付购买权益。
4. 出现黑屏、输入偏移、恢复失败、远端副作用或资源峰值时，可单独关闭远端自定义请求，保留免费 Auto/预设、候选列表和本地 canvas。
5. 任何代码实现增量都必须独立 checkpoint、独立 review，并执行项目规定的 `default@OhosTestCompileArkTS`、`assembleHap`、定向 native/Rust 测试、`git diff --check`、Light 合规和对应真机矩阵。

## 6. 关键风险与处理

| 风险 | 处理 |
|---|---|
| 用户其实只需要无黑边查看 | 首屏先提供 Fit/Fill/本地画布说明，Pro 远端分辨率说明其会改变远端桌面和带宽 |
| RDP 百分比只对部分应用生效 | 分开 desktop/device scale，覆盖现代与旧版 DPI 应用，显示 requested/effective/fallback |
| RDP 服务端忽略或调整尺寸 | 使用实际 GDI/frame geometry 为准，保留旧画面并显示服务器调整结果 |
| RustDesk 物理显示器被改变 | 显示目标和影响，记录原始尺寸，连接结束恢复并报告失败 |
| RustDesk peer 版本/平台差异 | 版本分支、能力 allowlist、候选列表优先、旧消息兼容、Wayland/mobile 降级 |
| 旧回执覆盖新请求 | session/attempt/request/geometry generation fence，latest-wins 与输入暂停 |
| Pro 撤销后旧状态继续执行 | entitlement/account lease 在 await、存储写入和 protected dispatch 前重新检查；清理 pending/native route |
| 4K/200% 资源峰值 | 按设备设长边/面积预算，记录首帧、帧率、CPU/GPU、内存、resize 耗时和黑屏次数 |
| 当前分支有并行脏改动 | 只新增计划文件；实现时按声明范围修改、checkpoint、独立复核，不使用 `git add -A`、reset、stash 或 worktree |

## 7. Definition of Done

计划本身的落盘和本地构建通过不代表功能完成。实现任务只有同时满足以下条件才可从 `IMPLEMENTING` 转为交付状态：

1. 三层显示语义、免费/Pro 边界和 profile schema 已评审；
2. RDP 初始连接、动态 Display Control、DPI scale、fallback 和输入几何通过自动化与真实 Windows 矩阵；
3. RustDesk 新旧 peer、显示器/候选/自定义请求、平台降级、恢复和实际帧矩阵通过；
4. Pro 可见性、entitlement、账号 lease、退款/恢复/冷启动/离线过期和 protected action 通过；
5. arm64-v8a/x86_64、真实 FreeRDP、RustDesk FFI、HAP、合规和独立 review 通过；
6. CURRENT/STATE/QUEUE、计划哈希、审查范围、验证证据和 blocker 已更新；
7. push/PR/required check/merge 后回到同步 `main`，并清理已合并分支。

## 8. 参考资料

仓库内：

- [RDP/RustDesk 分辨率、Windows 缩放和双指交互总计划](../../REMOTE_RESOLUTION_SCALE_PLAN.md)
- [RDP 高 DPI 自适应分辨率升级计划](2026-08-29-rdp-hidpi-adaptive-resolution-upgrade.md)
- [RDP 协议专题](../../../.agents/skills/remotedesk-harmonyos-dev/references/protocols/rdp.md)
- [RustDesk 协议专题](../../../.agents/skills/remotedesk-harmonyos-dev/references/protocols/rustdesk.md)
- [本应用 Pro 权益专题](../../../.agents/skills/remotedesk-harmonyos-dev/references/purchase-entitlements.md)

外部协议资料：

- [Microsoft MS-RDPEDISP DISPLAYCONTROL_MONITOR_LAYOUT](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpedisp/ea2de591-9203-42cd-9908-be7a55237d1c)
- [FreeRDP command line scale options](https://github.com/FreeRDP/FreeRDP/blob/master/client/common/cmdline.c)
- [RustDesk display service](https://github.com/rustdesk/rustdesk/blob/master/src/server/display_service.rs)
