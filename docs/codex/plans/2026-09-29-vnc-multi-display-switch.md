# VNC 多显示器单屏切换与侧栏优化计划

Status: PLAN_ONLY
Created: 2026-09-29 Asia/Shanghai
Scope: VNC 连接多显示器电脑时，默认只显示一个远端屏幕，并在会话侧栏中切换屏幕。
Implementation status: 未开始；本文件只记录评估、设计、验证和验收计划，不代表协议已经支持。
Observed workspace: codex/pro-purchase-foundation @ 210bddb4f；当前工作树干净。现有 Pro 任务完成或归档前，不创建新的日常分支、不把实现混入当前分支。

## 1. 目标和决策结论

### 1.1 目标

- 多屏 VNC 会话连接后只呈现一个已选远端屏幕，默认使用服务端标记的主屏；没有主屏时使用稳定排序后的第一块屏幕。
- 在 VNC 会话侧栏提供“显示器”入口，列出可用屏幕并支持切换。
- 切换过程中释放旧屏幕坐标系中的输入，等待目标屏幕的首帧和几何确认后再恢复输入。
- 服务器不支持显示器目录或切换时，不显示伪造的屏幕列表，保留现有整桌面行为并给出清晰状态。
- 让“视觉上只显示一块屏幕”和“服务器只采集/发送一块屏幕”成为两个可验收的指标，避免把客户端裁剪误报为带宽优化。
- 单屏 VNC、TLS、Repeater、View-only、已有缩放和诊断行为保持兼容。

### 1.2 明确结论

标准 RFB 以一个 framebuffer 传输远端画面。ServerInit 提供 framebuffer 宽高，DesktopSize 只能改变 framebuffer 尺寸；标准协议没有统一的显示器目录和显示器切换命令。参考：[RFC 6143](https://www.rfc-editor.org/info/rfc6143/)。

因此，真实的“只让服务端发送选中屏幕”必须依赖具体 VNC Server 的扩展能力。RealVNC、UltraVNC 等产品确实提供过多屏选择，但要求特定产品、版本或服务端条件，不能抽象成任意 VNC Server 都支持的 RFB 命令。参考：[RealVNC 多显示器说明](https://help.realvnc.com/hc/en-us/articles/360006483577-Working-with-multiple-monitors-in-RealVNC-Connect)、[RealVNC Displays API](https://www.realvnc.com/en/developer/docs/latest/api/c/Displays.h.html)、[UltraVNC Virtual Displays](https://uvnc.com/docs/documentation/134-ultravnc-virtual-displays.html)。

推荐路线是：

1. 先识别用户实际使用的 VNC Server 产品和版本。
2. 只为已经确认 wire contract 的服务端实现真实切换。
3. 对未知服务端保持整桌面并隐藏显示器入口。
4. 如果产品仍需要“只隐藏其他屏幕”，另行实现明确标注的客户端视口裁剪，不把它命名为服务端屏幕切换，也不宣称减少网络流量。

## 2. 当前代码和影响范围

| 层级 | 当前实现 | 影响 |
|---|---|---|
| RFB Native | VncRfbEngine 维护一组 framebufferWidth/framebufferHeight；DesktopSize 调整同一 framebuffer；emitFrame 固定 display=0 | 没有屏幕目录、屏幕 ID、当前屏幕或切换状态 |
| Native Adapter | VncAdapter 暴露连接、输入、刷新和帧回调，没有 VNC display API | 需要新增 VNC 专用接口，不应复用 RustDesk display API |
| 通用配置 | ConnectionConfig 的 multiMonitor/monitorCount 主要服务 RDP；VideoFrame.display 的语义是 RustDesk 显示器编号，其他协议使用 0 | 不能把 RDP 字段或 VideoFrame.display 直接当作 VNC 多屏能力 |
| NAPI | rdpnapi.d.ts 的 display 查询/切换函数是 RustDesk 专用 | 需要新增 VNC 专用 capability/switch API 和数据类型 |
| ArkTS 几何 | RemoteDesktop 根据 VNC frame 宽高同步逻辑尺寸，并设置 multiMonitor=false、monitorCount=1 | 切换确认必须接入现有几何、变换、光标和输入重置流程 |
| VNC 侧栏 | VncSessionUiPolicy 当前定义六个固定动作；VncSessionToolbar 已有 Phone/Pad 右侧 rail 和 PC 工具栏 | 需要条件显示 display 动作、动态高度、面板和测试 |
| VNC 设置模型 | VncModelPolicy/VncSessionSettingsPolicy 只有缩放、操控模式、诊断等会话或主机设置 | 首版显示器选择只保存到当前会话，不写入主机配置 |
| RustDesk 参考 | RemoteDesktop 已有“远端显示器与分辨率”面板和 generation/inputBlocked/timeout 状态机 | 可借鉴 UI 和生命周期状态设计，不能复用其协议或 native 入口 |
| VNC LastRect | e67724ac/21da46aa 修复了 FBU LastRect 解析和诊断 | 与显示器切换正交；必须单独验收，不能把 LastRect PASS 当成多屏 PASS |

主要代码入口：

- entry/src/main/cpp/vnc/vnc_rfb_engine.cpp
- entry/src/main/cpp/vnc/vnc_rfb_engine.h
- entry/src/main/cpp/vnc/vnc_adapter.cpp
- entry/src/main/cpp/vnc/vnc_adapter.h
- entry/src/main/cpp/extensions/extension_loader_napi.cpp
- entry/src/main/ets/types/rdpnapi.d.ts
- entry/src/main/ets/pages/RemoteDesktop.ets
- entry/src/main/ets/components/VncSessionToolbar.ets
- entry/src/main/ets/services/VncSessionUiPolicy.ets
- entry/src/main/ets/services/VncModelPolicy.ets
- entry/src/main/ets/services/VncSessionSettingsPolicy.ets

## 3. 方案分流和停止条件

### 3.1 M0 能力探测

在任何代码修改前，记录：

- VNC Server 产品、版本、操作系统和捕获模式；
- 直连、TLS、Repeater 或 Gateway 链路；
- 当前 ServerInit 的 framebuffer 宽高；
- 远端屏幕数量、名称、主屏、位置、分辨率和是否支持热插拔；
- 官方 Viewer 是否能在不重连的情况下切换；
- 切换后是服务端重新提供一个 framebuffer，还是客户端只改变视口；
- 同分辨率屏幕如何确认切换成功；
- 预期是降低视觉复杂度，还是必须降低网络流量和服务端采集开销。

M0 输出一份服务器能力矩阵和允许的 wire contract。若找不到公开、稳定且可验证的切换命令，则停止真实切换实现，不向通用 VNC 发送猜测字节。

### 3.2 方案 A：服务端原生切换，首选

适用于已确认的厂商扩展。

- 建立 VNC vendor capability adapter，按 serverKind/serverVersion 选择。
- 能力返回 display ID、名称、主屏、在线状态、位置、尺寸、目录 generation。
- 切换请求携带稳定 ID，不依赖当前列表索引。
- 以服务端确认、目标首帧和目标几何共同确认完成。
- 服务端热插拔时重新获取目录，移除当前屏幕时按策略回退主屏或第一块在线屏幕。

退出条件：没有明确 wire contract、无法区分拒绝和成功、或服务端扩展要求未授权 SDK/协议时，不进入实现。

### 3.3 方案 B：客户端视口裁剪，有限 fallback

适用于服务端只发送拼接 framebuffer、但能提供屏幕几何的情况。

- 保留一个完整 framebuffer 和一个独立的 VncViewportState。
- 渲染只使用 selectedRect，输入坐标加上 selectedRect 的远端偏移。
- 切换只改变视口和变换，不能声称降低网络或解码成本。
- 目录或几何未知时不自动猜测屏幕边界；手工矩形只能作为明确的实验能力。
- 诊断中区分 serverSelection 和 clientViewport，避免产品和日志误导。

### 3.4 方案 C：按独立会话重连，谨慎使用

只有服务器文档明确把每个屏幕映射到独立连接入口时才考虑。

- 不把 VNC display number 或 5900+n 默认解释成物理屏幕。
- 重新认证、TLS、证书信任、Repeater 参数和会话状态必须完整复用。
- 切换期间明确显示正在重连，输入全部阻断。
- 断开、认证失败或目标入口失效时恢复原连接状态。

## 4. 目标数据和状态契约

### 4.1 VncDisplayInfo

字段建议：

- stableId：服务端稳定 ID；没有稳定 ID 时由 serverKind + 原始 ID 组成；
- label：显示名称，缺失时使用“显示器 1”等本地化回退；
- x、y、width、height：远端桌面坐标和尺寸；
- primary：是否主屏；
- online：是否当前在线；
- index：仅用于展示排序，不作为切换身份；
- source：server、vendor-extension 或 viewport。

### 4.2 VncDisplayCapabilities

字段建议：

- supported：服务端是否支持真实切换；
- mode：serverSelection、clientViewport 或 unsupported；
- displays：当前目录；
- currentDisplayId：已确认屏幕；
- pendingDisplayId：正在切换的目标；
- generation：目录代际；
- serverKind/serverVersion：脱敏的能力来源；
- lastError：分类后的错误，不输出密码、地址或原始服务端文本；
- refreshedAt：用于诊断，不作为 UI 身份。

### 4.3 VncDisplaySwitchState

状态：

- idle；
- requesting；
- waitingAck；
- waitingFirstFrame；
- confirmed；
- rejected；
- timedOut；
- disconnected；
- unsupported。

不变量：

- session generation、display catalog generation、switch generation 都必须匹配才可提交 UI；
- 旧 generation 的帧、诊断、输入和异步回调不能覆盖新状态；
- pending 期间只允许最后一次目标生效；
- 没有首帧/几何确认时不能把“请求成功”显示成“切换成功”。

## 5. 分阶段实施计划

### M0：服务端和需求确认，PLAN_ONLY

任务：

- 采集实际 VNC Server 产品、版本、OS 和连接方式；
- 用官方 Viewer 做多屏行为 A/B；
- 固定 1/2/3 屏、不同分辨率、负坐标和热插拔样本；
- 保存脱敏的 ServerInit、能力结果、切换前后几何和截图；
- 确定用户优先级：视觉隐藏、降低流量，或两者都要。

完成标准：

- 能力矩阵中至少有一个可复现服务器；
- 明确支持的 wire contract 或明确判定为不支持；
- 形成 M1 的请求/响应/失败语义；
- 没有把标准 RFB 的 SetDesktopSize 当成屏幕选择命令。

### M1：Native VNC 协议层

任务：

- 在 vnc_rfb_engine 中添加 capability catalog 和切换状态；
- 在 vnc_adapter 中增加查询、切换、状态和目录变化回调；
- 将厂商命令放在独立 adapter 中，默认 VNC 路径不发送未知扩展；
- 添加目标 ID、session generation、switch generation 和超时；
- 切换前释放所有按键、鼠标按钮、触摸序列和旧坐标变换；
- 切换确认后发布目标帧、目标几何和新光标；
- 断线、重连、停止、销毁时清除 pending、catalog 和回调；
- 限制目录长度、名称长度、坐标范围和尺寸，防止服务端异常数据造成资源问题。

完成标准：

- 单屏和不支持服务器行为不变；
- 支持服务器能查询目录并完成一次真实切换；
- 同尺寸屏幕也能被明确确认；
- 失败不会泄漏旧输入或旧帧；
- arm64-v8a 和 x86_64 native 编译检查通过。

### M2：NAPI 和诊断接口

任务：

- 在 rdpnapi.d.ts 及其 native 注册处新增 VNC 专用类型和函数；
- 建议接口：
  - getVncDisplayCapabilities(sessionId)
  - requestVncDisplaySwitch(sessionId, stableId)
  - getVncDisplaySwitchState(sessionId)
  - observeVncDisplayCatalog(sessionId)
- 诊断快照增加 capability mode、catalog generation、current/pending ID、switch result 分类；
- 保持 RustDeskDisplayCapabilities 与 VncDisplayCapabilities 分离；
- 不把服务端原文、认证材料、地址或本地路径写入诊断。

完成标准：

- ArkTS 能读到一致的目录和状态；
- native 异步失败能被分类为 unsupported、rejected、timeout、disconnected 或 invalid；
- sessionId、generation 和账号/连接切换不会串数据。

### M3：ArkTS 会话和输入/几何生命周期

任务：

- RemoteDesktop 增加 VNC display catalog、current/pending state 和面板开关；
- 初次目录确认后选择主屏或稳定排序的第一块屏幕；
- 切换开始时调用现有 VNC 输入重置流程；
- 切换期间冻结旧坐标输入，保留取消、断开和诊断操作；
- 首帧和几何确认后重置画布变换、缩放、PIP、光标和输入映射；
- 将 syncVncLogicalSizeFromFrame 与 display switch generation 对齐；
- 目录刷新时处理屏幕移除、主屏变化、重复 ID、同名屏幕和空目录；
- 会话结束、返回、窗口销毁、网络重连时关闭面板并清理所有定时器。

完成标准：

- 快速点击屏幕 1/2/3 只落地最后一次有效请求；
- 切换期间没有旧屏幕点击、拖动、键盘按键穿透；
- 旧帧不能覆盖目标屏幕；
- 同分辨率切换仍能确认或超时回滚；
- View-only 模式不会因为显示器切换恢复输入。

### M4：VNC 侧栏和交互

任务：

- 在 VncSessionUiPolicy 中加入条件式 display action；
- VncSessionToolbarActions 增加打开显示器面板的回调；
- Phone/Pad 复用右侧 rail；PC 复用顶部工具栏或侧滑面板；
- 面板列表显示名称、尺寸、主屏、当前、切换中和错误状态；
- 屏幕超过三块时滚动，面板不遮挡关键断开和键盘操作；
- 单屏、不支持或目录未确认时隐藏入口；
- 切换中显示 loading 和目标名称，禁止重复提交同一目标；
- 添加读屏文本和键盘焦点顺序；
- 首版不保存“上次屏幕”到 VNC 主机配置；重连默认重新采用服务端主屏。

完成标准：

- VNC 侧栏在窄屏、横屏、大字体和键盘展开时不裁切；
- 面板关闭、切换、断开和页面销毁后无残留状态；
- 单屏用户看不到无意义的显示器入口；
- 不支持的服务端不会出现可点击但无效的屏幕卡片。

### M5：测试和构建

纯策略测试：

- 目录去重、排序、主屏回退、空目录；
- stableId 变化、目录 generation 变化；
- latest-wins、超时、拒绝、取消、重连；
- 当前/待切换/已确认状态转换；
- 不支持服务端隐藏入口。

Native 测试：

- 能力响应正常、截断、未知字段、超长名称、非法坐标和尺寸；
- 未知服务端不发送扩展命令；
- 切换确认、首帧等待、同尺寸屏幕、热插拔；
- input release、generation fence、停止和重连；
- TLS/Repeater/Gateway 下命令路径保持一致；
- ASan/UBSan、arm64-v8a、x86_64。

ArkTS/渲染测试：

- 侧栏动作集合和动态高度；
- 面板打开/关闭、窄屏、大字体、横竖屏；
- 画布变换、PIP、光标、缩放和输入坐标；
- 切换期间的键盘、鼠标、触摸和 View-only；
- RemoteDesktop 与 RemoteSessionAbility 销毁/恢复；
- 不支持服务器、单屏服务器和目录为空。

项目强制门禁：

- source scripts/macos_env.sh
- hvigorw --mode module -p module=entry -p product=default default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon
- hvigorw --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --no-daemon
- git diff --check
- scripts/verify_open_source_release.ps1 -Mode Light

所有结果都必须记录准确命令、退出码、时间、HAP/commit 证据。旧日志不能代替本次门禁。

### M6：服务端、设备和性能验收

服务器矩阵：

- 实际用户 VNC Server；
- 已明确支持的厂商/版本；
- 未支持的普通 RFB Server；
- 直连、TLS、Repeater/Gateway；
- 不同认证方式。

显示器矩阵：

- 单屏、双屏、三屏；
- 混合分辨率和 DPI；
- 左/右/上/下排列和负坐标；
- 横屏/竖屏；
- 主屏变化；
- 热插拔、屏幕移除和重连；
- 同尺寸不同屏幕。

每项按以下格式记录：

| 操作 | 预期 | 证据 |
|---|---|---|
| 连接双屏服务器 | 只显示默认屏幕 | 能力快照、截图、首帧几何 |
| 打开侧栏 | 显示真实目录和主屏标记 | 目录 JSONL、UI 截图 |
| 切换到第二屏 | pending 后只呈现第二屏 | 切换结果、目标首帧、几何和截图 |
| 切换期间点击/拖动 | 输入被释放或阻断，不落到旧屏幕 | native 输入日志和操作录像 |
| 服务端不支持 | 不显示虚假屏幕卡片 | unsupported 能力结果和 UI 截图 |
| 屏幕被移除 | 回退到主屏或第一块在线屏幕 | 目录变化、状态和截图 |
| 重连 | 清理旧目录，重新确认默认屏幕 | 断线/重连日志和截图 |
| 视觉裁剪 fallback | 只改变视口，不声称降低流量 | viewport 状态和流量对比 |

性能验收必须单独记录 framebuffer 解码量、网络接收量、内存峰值、切换耗时和输入恢复耗时。没有测量结果时，不得发布“降低带宽”结论。

## 6. 发布、兼容和安全边界

- VNC 显示器选择首版为会话级状态，不落入云同步、主机配置或分享 payload。
- 显示器名称、坐标和分辨率属于服务端输入，必须做长度、数值和数量限制。
- 所有 display ID、serverKind 和错误码进入诊断前都必须脱敏和限界。
- 不改变 VNC 密码、TLS、证书信任、Repeater 或 Gateway 逻辑。
- 不把服务端显示器 ID 当作账号身份、连接身份或安全凭据。
- 不允许旧会话 generation 的异步回调写入新会话。
- API 26 为开发基准；如果引入新的系统窗口、Surface 或输入 API，必须查本机 API 26 声明并补 API 23 回退评估。
- 双 ABI、HAP 产物、NOTICE、SBOM 和 provenance 只有在依赖或协议库实际变化时更新；新增自有 ArkTS/C++ 代码不应无故修改依赖清单。
- 当前 Pro 活动分支仍未完成，计划落盘不等于实现授权。开始实现时，应在当前任务合并或明确归档后，从同步 main 创建独立的 codex/vnc-display-switch 分支，并进行独立复核、PR、required open-source-compliance 和合并闭环。

## 7. 完成定义

计划对应的实现只有同时满足以下条件才可标记完成：

- 至少一个实际 VNC Server 的真实多屏切换通过；
- 未支持服务器保持安全降级；
- 侧栏和单屏回归通过；
- 切换前后输入、光标、缩放和几何正确；
- 热插拔、断线、重连、View-only 和 TLS/Repeater 场景有证据；
- Native、NAPI、ArkTS、双 ABI、Hvigor、Light 和 diff 检查全部通过；
- 设备/服务端验收与代码/build 证据分别记录；
- 独立复核通过后才允许合并；
- 没有把客户端裁剪、编译成功或 LastRect 修复结果误报成服务端多屏能力。

## 8. 当前待补信息

进入 M0 前，需要补齐：

1. 电脑端 VNC Server 产品、版本和操作系统；
2. 当前多屏排列、每块屏幕分辨率和主屏；
3. 用户希望的是隐藏其他屏幕，还是同时减少服务器采集和网络流量；
4. 是否允许首版只支持一个明确的 VNC Server 产品；
5. 是否存在可重复的测试电脑或服务端账号。

在这些信息缺失时，保持 PLAN_ONLY，不修改 VNC 协议实现。

## 9. 参考资料

- [RFC 6143: The Remote Framebuffer Protocol](https://www.rfc-editor.org/info/rfc6143/)
- [RealVNC: Working with multiple monitors](https://help.realvnc.com/hc/en-us/articles/360006483577-Working-with-multiple-monitors-in-RealVNC-Connect)
- [RealVNC SDK: Displays API](https://www.realvnc.com/en/developer/docs/latest/api/c/Displays.h.html)
- [UltraVNC: Virtual displays](https://uvnc.com/docs/documentation/134-ultravnc-virtual-displays.html)
- 项目现有 VNC 修复计划：docs/codex/plans/2026-09-08-vnc-lastrect-update-repair.md
