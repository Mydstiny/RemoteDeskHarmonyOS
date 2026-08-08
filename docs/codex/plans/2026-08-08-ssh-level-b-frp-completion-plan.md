# SSH Level B 与外部 FRP SSH 入口完成执行计划

- 状态：`PROPOSED`，仅计划，尚未按本文实施
- 日期：2026-08-08 Asia/Shanghai
- 活动任务：`ssh-terminal-complete-upgrade`
- 活动分支：`codex/ssh-terminal-complete-upgrade`
- 基线：`main@d2769ad4b`
- 编写时 HEAD：`4646fb910`
- 目标读者：可按明确步骤执行、但不应自行补充架构假设的实现模型或工程师
- 优先级：`Level B → 外部 FRP TCP/Visitor 入口验收`

## 1. 目的

本计划用于完成 SSH 剩余能力：

1. HTTP CONNECT、SOCKS5 和一至三跳 ProxyJump 的完整用户路径与真实端点验收。
2. local、remote、dynamic SSH forwarding 的配置、运行、停止、恢复、状态显示和真实数据链路验收。
3. 连接已经由外部 frps/frpc 暴露出来的 SSH TCP 映射或 Visitor TCP 入口。
4. App 不内嵌 frpc、不实现 FRP 控制面、不管理 FRP token/visitor secret，也不自建 FRP 协议或桥接服务。
5. 上述能力与多 SSH session、generation、后台恢复、PiP、认证和 host-key 流程的集成。
6. Phone、Pad、PC/2in1 上统一、自然、无竞态的 SSH 配置和运行时 UI。

本文不授权重构、清理或顺带修复 RDP、RustDesk、VNC、Native Drawing、已验收 SFTP，以及其他 session 正在修改的代码。

## 2. 当前事实基线

执行者必须先接受以下事实，不得从零重写已经存在的数据链路：

| 能力 | 当前实现 | 未完成部分 |
|---|---|---|
| SFTP | Pad/PC 双栏、Phone 1.0.8 单栏、双 SSH 任务和持久恢复已实机验收 | 冻结，不属于本计划改动范围 |
| HTTP CONNECT | Native 握手已有实现 | 新 profile、统一 UI、错误显示、真实端点矩阵 |
| SOCKS5 route | Native 握手已有实现 | 新 profile、统一 UI、真实端点矩阵 |
| ProxyJump | Native 已有 `direct-tcpip` 链路，最多三跳 | UI/持久化目前主要是单跳平面字段；缺逐跳认证、host-key、错误上下文和端点证据 |
| Local forwarding | Native listener/channel 数据链路已有 | 缺 ArkTS controller、profile、UI、状态和端点验收 |
| Remote forwarding | Native remote listener/accept 数据链路已有 | 同上 |
| Dynamic forwarding | Native SOCKS5 CONNECT 状态机已有 | 同上 |
| FRP TCP | 已按映射后的原始 TCP 地址连接 | 缺正式 UI 文案、字段校验和真实 frps/frpc 互操作 |
| 外部 STCP/XTCP Visitor | 外部官方 frpc visitor 可以对 App 提供普通 TCP bind 地址 | App 只需连接该 TCP 地址；缺 endpoint profile、UI 和真实互操作 |
| SUDP | FRP 提供 UDP 数据报 | SSH 不能直接使用；App 不实现 UDP 到 SSH 的自建桥接 |

主要现有入口：

- `entry/src/main/cpp/ssh/ssh_adapter.cpp`
- `entry/src/main/cpp/ssh/ssh_forwarding_manager.cpp`
- `entry/src/main/cpp/ssh/ssh_route_policy.h`
- `entry/src/main/cpp/extensions/extension_loader_napi.cpp`
- `entry/src/main/ets/services/ExtensionLoader.ets`
- `entry/src/main/ets/services/SshForwardingPolicy.ets`
- `entry/src/main/ets/services/SshTransportPolicy.ets`
- `entry/src/main/ets/pages/SshTerminal.ets`
- `entry/src/main/ets/components/hostadd/SshAddFlow.ets`

## 3. 完成定义

单项能力只有同时满足以下要求，才能在状态文档中标记为完成：

1. 用户可以在正式 UI 中创建、编辑、启动、停止并查看结果。
2. 配置有独立 `schemaVersion`，旧数据能 additive 迁移且不会被自动破坏。
3. 密码、OTP、私钥口令和代理秘密不进入普通配置、日志、SFTP task、云数据或诊断包；App 不接收 FRP token 或 visitor secret。
4. 所有 Native 操作显式携带并校验 `sessionId`、`channelId` 和 `generation`。
5. 页面 detach、Tab 切换、前后台、PiP、网络切换、session 重连和页面销毁不会产生 stale callback 或资源泄漏。
6. Feature flag 关闭后能安全停止本功能拥有的运行时资源，不能关闭无关 SSH session，更不能影响其他协议。
7. 有策略测试、Native 测试、ArkTS 测试、真实端点结果和设备矩阵结果。
8. Phone、Pad、PC/2in1 UI 没有遮挡、竞态、无法关闭、焦点丢失或突兀的页面跳转。
9. 强制 Hvigor 门禁、范围匹配的 Native/Rust 测试、Light 合规门和独立 reviewer 通过。
10. FRP 支持被准确描述为“连接外部 FRP 已暴露的 TCP 入口”，不能宣称 App 自身实现了 STCP/XTCP/SUDP 控制面。

任何仅有 enum、数据结构、空 UI、mock、未接线 Native 函数或未执行真实数据传输的能力，都只能标记为“骨架”或“未验收”。

## 4. 绝对隔离边界

### 4.1 默认允许修改

- `entry/src/main/cpp/ssh/**`
- `entry/src/main/ets/services/Ssh*.ets`
- 新增 `entry/src/main/ets/components/ssh/**`
- `entry/src/main/ets/pages/SshTerminal.ets` 中最小 SSH 接线
- `entry/src/main/ets/components/hostadd/SshAddFlow.ets` 中最小 SSH 接线
- SSH route/forwarding 专属 Native 与 ArkTS 测试
- `tests/ssh_endpoints/**`
- SSH 专属资源字符串和文档

### 4.2 受控共享文件

以下文件只有在没有 SSH 专属替代入口时才能做 additive 修改，而且一个提交中不得同时整理其他区域：

- `entry/src/main/cpp/extensions/extension_loader_napi.cpp`
- `entry/src/main/cpp/extensions/protocol_adapter.h`
- NAPI `.d.ts` 文件
- `entry/src/main/cpp/CMakeLists.txt`
- `entry/src/main/ets/pages/HostListPage.ets` 的 SSH 分支

修改这些文件时必须：

1. 保持现有导出和签名兼容。
2. 新函数使用 SSH 前缀；外部 FRP endpoint 不新增 FRP Native 控制面函数。
3. 不改变 RDP、RustDesk、VNC 分支的条件、默认值和生命周期。
4. 独立 reviewer 重点检查共享文件 diff。

### 4.3 禁止修改

除非用户另行明确授权，禁止修改：

- `entry/src/main/ets/pages/RemoteDesktop.ets`
- `entry/src/main/cpp/render/**`
- `entry/src/main/cpp/rdp/**`
- VNC 页面、服务和 Native 路径
- `rustdesk_ffi/**`
- RustDesk/RDP/VNC 数据模型
- 已验收 SFTP builder、传输引擎、任务 store 和弹窗布局
- Native SSH GPU surface 的可见渲染路径

如果编译错误来自禁止范围或其他 session，执行者只记录证据，不得借本任务授权修复。

### 4.4 Git 操作约束

每个提交必须执行：

```sh
git status --short --branch
git diff --name-only
git diff --check
git diff --cached --name-only
```

只允许使用：

```sh
git add -- <本阶段精确文件列表>
```

禁止：

- `git add -A`
- `git reset --hard`
- `git checkout --`
- `git clean`
- stash
- 覆盖、删除或格式化其他 session 的文件

暂存列表出现本阶段白名单外文件时，必须停止提交。

## 5. 目标架构

```text
SSH UI / BindSheet
  ├─ SshRouteProfileStore
  ├─ SshForwardingProfileStore
  ├─ SshModalCoordinator
  ├─ SshSessionManager
  │    ├─ SshRouteSecretBroker
  │    ├─ SshRouteCoordinator
  │    │    ├─ direct/http_connect/socks5 -> SshNativeFacade
  │    │    ├─ frp_tcp/external_frp_visitor_endpoint -> ordinary TCP connect
  │    │    └─ ssh_jump(hops[]) -> SshNativeFacade
  │    └─ SshEventEnvelope / generation fencing
  └─ SshForwardingController
       └─ SshNativeFacade -> SshForwardingManager
```

架构约束：

1. 如果 `SshSessionManager`、`SshSessionContext` 或 `SshNativeFacade` 已存在，扩展现有实现；禁止再创建平行 manager/facade。
2. `SshNativeFacade` 是 ArkTS 到 Native SSH 的统一入口。
3. `SshSessionManager` 负责连接、认证、恢复和 generation。
4. `SshForwardingController` 不持有全局 active adapter，只使用 session owner。
5. FRP 的控制面、版本协商、token、visitor secret 和 P2P 建链全部由用户部署的官方 frps/frpc 负责。
6. App 只接收一个可连接的 TCP host/port，并按普通 SSH transport 执行 KEX、host-key 和认证。
7. 现有 NAPI `SshRoute` schema 保持兼容；外部 FRP endpoint 通过 mapper 转换成普通 TCP 目标，不新增 FRP Native 协议栈。

## 6. 公共类型和持久化规则

### 6.1 `SshRouteProfileV2`

必须包含：

- `schemaVersion: 2`
- `hostId`
- `kind`
- `connectTimeoutMs`
- `handshakeTimeoutMs`
- `hops[]`
- HTTP/SOCKS endpoint 元数据
- `frpEndpointProfileId`
- host-key policy 元数据
- `updatedAt`

不得包含任何 secret。

### 6.2 `SshJumpHopProfileV1`

每跳必须包含：

- 稳定 `hopId`
- label
- host、port、username
- auth method preference
- private key 引用 ID，但不是私钥正文或口令
- host-key policy 和已知指纹元数据
- connect/auth timeout
- position

限制：

- 最多三跳。
- 第四跳必须在 UI 和 policy 层被拒绝，不能静默截断。
- 目标主机与每个 hop 的 host-key 状态完全独立。

### 6.3 `SshForwardingProfileV1`

必须包含：

- `schemaVersion: 1`
- `id`
- `ownerHostId`
- `type: local | remote | dynamic`
- `bindHost`
- `bindPort`
- `targetHost`
- `targetPort`
- `startPolicy: manual | onSessionReady`
- 最大并发连接数
- 最大总流量或单连接流量限制
- 允许端口范围
- loopback policy
- 更新时间

dynamic 类型不得要求 targetHost/targetPort。

### 6.4 `SshForwardingRuntimeV1`

仅保存在内存：

- profileId
- sessionId
- channelId
- generation
- native runtime ID
- 实际监听地址
- 状态
- 当前连接数
- 收发字节
- 最后错误
- 启动时间

### 6.5 `SshFrpEndpointProfileV1`

必须包含：

- `schemaVersion: 1`
- profile ID 和 label
- `mode: tcp_mapping | external_visitor_tcp_endpoint`
- `endpointHost`
- `endpointPort`
- 仅用于显示和帮助文案的 `sourceType: tcp | stcp | xtcp | other`
- 可选 label/description
- connect timeout
- 更新时间

不得包含 FRP serverAddr/controlPort、token、visitor secret、proxy name、wire protocol 配置或 P2P 参数，因为这些都属于外部 frps/frpc 配置。

映射规则：

1. `frp_tcp` 表示由 frps 暴露的 SSH TCP 映射地址，App 直接连接 `endpointHost:endpointPort`。
2. `frp_visitor`、`frp_stcp` 和 `frp_xtcp` 只有在用户明确提供“外部 frpc visitor 已监听的 TCP 地址”时才可用。
3. 上述 Visitor 类型仅作为来源标签；实际数据链路仍是 App 到该 endpoint 的普通 TCP SSH 连接。
4. `frp_sudp` 保持不可用，因为它不是 SSH 所需的 TCP 字节流。
5. 如果外部网关已经把任意 FRP 模式转换为 TCP，App 应将其保存为 `external_visitor_tcp_endpoint`，不能宣称 App 原生支持该 FRP 协议。

### 6.6 一次性 SSH secret handoff

新增或扩展 `SshRouteSecretBroker`：

- secret 只存在于内存。
- 每份 handoff 带随机 request ID、sessionId、hop、轮次、generation 和到期时间。
- 默认 60 秒超时。
- 成功消费一次后立即失效。
- 取消、超时、页面销毁、session close 和 generation 变化立即清理。
- 日志最多记录 `secretPresent=true/false`。
- 禁止记录 secret 长度、哈希、掩码后的部分内容或序列化对象。
- FRP token 和 visitor secret 不进入 broker，因为 App 不负责启动或配置 frpc。

### 6.7 存储选择

首版使用 SSH 专属 Preferences/RDB namespace，例如：

- `ssh_route_profiles_v2`
- `ssh_forwarding_profiles_v1`
- `ssh_frp_endpoint_profiles_v1`

避免修改共享 `RemoteHost` 表结构和其他协议的 CloudStore 行为。

迁移规则：

1. 优先读取新 profile。
2. 新 profile 不存在时，才 additive 映射旧平面 `sshProxy*` 字段。
3. 旧单跳字段映射为 `hops[0]`。
4. 不自动解释 `legacy_gateway`。
5. 新 profile 保存成功后不删除旧字段。
6. 未知高版本 schema 只读并提示升级，不得覆盖。
7. 新 profile 首版只做本地持久化；非秘密元数据的云同步不属于本计划，避免扩大共享模块改动。

## 7. Feature Flag

新增 SSH 专属 capability policy，至少包含：

| Flag | 初始值 | 打开条件 |
|---|---:|---|
| `sshProxyJumpSingleHop` | 保持现有行为 | 不得回归已有单跳 |
| `sshProxyJumpMultiHop` | false | 一至三跳真实端点矩阵通过 |
| `sshHttpConnectRoute` | 保持现有安全行为 | 真实 HTTP CONNECT 通过 |
| `sshSocks5Route` | 保持现有安全行为 | 真实 SOCKS5 通过 |
| `sshForwardingUi` | false | local/remote/dynamic 端点矩阵通过 |
| `sshFrpTcpEndpoint` | 保持现有行为 | 真实 frps/frpc TCP 映射通过 |
| `sshExternalFrpVisitorEndpoint` | false | 外部 STCP/XTCP visitor TCP bind 地址互操作通过 |

要求：

- UI 隐藏或禁用不是唯一保护；policy 和 Native 必须同时 fail closed。
- Flag 关闭时只停止该 flag 拥有的 SSH runtime。
- 不关闭 SSH shell、SFTP task 或其他协议 adapter。
- 不增加 FRP control-plane、XTCP 或 SUDP feature flag；这些不属于 App 能力。

## 8. UI/UX 统一规范

### 8.1 新增组件

- `entry/src/main/ets/components/ssh/SshSheetScaffold.ets`
- `entry/src/main/ets/components/ssh/SshRouteEditor.ets`
- `entry/src/main/ets/components/ssh/SshJumpHopEditor.ets`
- `entry/src/main/ets/components/ssh/SshForwardingSheet.ets`
- `entry/src/main/ets/components/ssh/SshForwardingEditor.ets`
- `entry/src/main/ets/components/ssh/SshFrpEndpointEditor.ets`
- `entry/src/main/ets/components/ssh/SshRuntimeStatusCard.ets`
- `entry/src/main/ets/services/SshLayoutPolicy.ets`
- `entry/src/main/ets/services/SshModalCoordinator.ets`

`SshTerminal.ets` 只负责薄接线，不继续堆积完整表单和状态机。

### 8.2 视觉 token

- 基础间距 8vp。
- 常用间距 8/12/16/24vp。
- 输入框圆角 10vp。
- 卡片圆角 12vp。
- 大 sheet 圆角 16vp。
- 最小点击区域 44×44vp。
- 关闭图标 20–22vp，但点击区域保持 44vp。
- 主按钮高度 44–48vp。
- 所有颜色使用现有主题 token 和语义色。
- 禁止为新页面任意增加硬编码蓝色、灰色、阴影和不一致字重。

### 8.3 Header

统一 header 三段布局：

1. 左侧标题和可选副标题。
2. 中间状态区域，可为空但必须保留布局约束。
3. 右侧固定关闭按钮。

关闭按钮不能通过负 margin、绝对定位或过高 offset 躲避内容。标题变长时截断标题，不移动关闭按钮。

### 8.4 Phone

- 保持现有 1.0.8 SSH/SFTP 主交互。
- 已验收 SFTP 完全冻结。
- 新 route/forward/外部 FRP endpoint 编辑使用单栏步骤式内容。
- 在现有“添加主机”bindSheet 内推进步骤，不能再叠加第二个系统 bindSheet。
- 使用内部返回按钮回到 profile 列表。
- footer 必须计算 safe inset 和 IME inset。
- 键盘弹出时内容区滚动，操作按钮不得遮挡输入框。
- 不改变终端、虚拟键栏和原有返回行为。

### 8.5 Pad

- 使用居中宽 bindSheet。
- 宽度：`min(availableWidth - 32vp, 960vp)`。
- 推荐最低宽度 760vp。
- 高度：`min(availableHeight - 28vp, 720vp)`。
- 左栏 300–320vp，显示 profile、hop 或 forwarding 列表。
- 右栏使用剩余宽度显示详情。
- 窄分屏自动降级为 Phone 单栏，而不是压缩双栏。
- 不根据设备型号或 `isDesktopDevice` 单一判断。

### 8.6 PC/2in1

- 最大宽度可扩展到 1080vp。
- 支持 hover、鼠标、键盘焦点、Tab 顺序、Enter 提交和 Esc 关闭当前编辑层。
- 保持列表/详情双区。
- 不强制全屏路由。
- profile 切换前如果有未保存修改，显示轻量确认。
- 删除 profile、停止运行时 listener 等破坏性操作需要二次确认。

### 8.7 统一布局上下文

必须使用：

- `windowWidthClass`
- `touchAvailable`
- `pointerAvailable`
- `physicalKeyboardAvailable`
- `orientation`
- `safeInsets`
- `imeInsets`

禁止只判断 `isDesktopDevice`。

### 8.8 BindSheet 竞态治理

所有新增 SSH sheet 统一经过 `SshModalCoordinator`：

1. 每次打开生成 `mountToken`。
2. 当前 sheet 尚未 `onDisappear` 时不能立即挂载下一 sheet。
3. 目标请求保存为 `pendingSheetRequest`。
4. 旧 sheet `onDisappear` 后校验 token、sessionId 和 generation。
5. 校验通过才打开目标 sheet。
6. 页面销毁时清空 pending request。
7. 关闭按钮先更新业务状态，再请求关闭 sheet。
8. 禁止多个无归属布尔状态同时控制多个 bindSheet。
9. 连续点击相同入口只能复用或忽略，不能创建两个实例。
10. 新协调器不得反向重构已验收 SFTP，除非出现明确回归并取得用户授权。

### 8.9 ProxyJump UI

- 路由类型显示：直连、HTTP CONNECT、SOCKS5、FRP TCP、SSH 跳板。
- 跳板列表支持添加、删除和排序。
- 每个 hop 显示地址、用户、认证方式、host-key 状态和最近错误。
- 三跳后禁用添加，并显示“最多支持 3 跳”。
- 错误必须指明“第 1 跳”“第 2 跳”“目标主机”，不能只显示“连接失败”。
- 每跳凭据在连接预检中动态请求，不在编辑表单中持久化明文。

### 8.10 Forwarding UI

- SSH 工具栏新增“隧道”入口。
- badge 显示运行中的 listener 数量；错误时显示错误状态。
- profile 卡显示 mode、bind、target、状态、连接数和流量。
- local/remote 默认绑定 loopback。
- 用户选择 `0.0.0.0`、`::` 或其他非 loopback 地址时显示安全警告。
- dynamic 模式只显示 SOCKS5 bind，不显示固定 target。
- 运行中 profile 不允许原地修改；必须停止或另存。
- 页面关闭只 detach UI，不停止 runtime。
- owner session 关闭时停止 runtime。

### 8.11 外部 FRP SSH 入口 UI

- 只提供两个选择：“FRP TCP 映射”和“外部 FRP Visitor TCP 入口”。
- FRP TCP 字段为“SSH 映射主机”和“SSH 映射端口（remote_port）”。
- Visitor 字段为“运行 frpc visitor 的主机”和“visitor bindPort”。
- 页面明确说明：FRP 服务、token、secret、STCP/XTCP 建链由外部 frps/frpc 负责，App 只连接最终 TCP 入口。
- 禁止出现 FRP 控制端口、token、visitor secret、proxy name 和协议版本输入框。
- `sourceType` 可选择 TCP/STCP/XTCP/其他，但只改变说明文案，不改变 Native 数据链路。
- SUDP 显示为不适用于 SSH，不能保存成可连接 route。
- 点击帮助时使用当前 sheet 内的说明区域，不生硬跳转到另一个页面。

### 8.12 无障碍和自然交互

- 所有图标按钮设置 accessibility text。
- 焦点顺序按视觉顺序。
- sheet 关闭后焦点返回打开入口。
- loading 不允许造成主要布局反复跳动。
- 保存成功后保留当前位置并显示轻量反馈。
- 错误应靠近字段或 runtime 卡片，不使用无上下文 toast 替代关键错误。

## 9. 分阶段实施和提交

每个阶段只能生成一个职责清晰的提交。上一阶段未通过停止条件时，禁止进入下一阶段。

### 阶段 0：冻结基线，不改代码

步骤：

1. 读取根目录和项目 `AGENTS.md`。
2. 读取 `CURRENT.md`、`QUEUE.md` 和当前计划。
3. 执行 `scripts/sync_workspace.sh status`。
4. 记录 branch、HEAD、main、dirty files、review 状态和 blocker。
5. 记录 SFTP 实机验收结论和 Phone 1.0.8 交互冻结规则。
6. 生成本次任务允许修改路径清单。
7. 运行当前强制门禁，区分基线问题与本任务问题。

停止条件：

- 当前工作树有无法归属的冲突。
- 活动分支与状态文件不一致。
- 需要修改禁止范围才能继续。

阶段 0 不制造空提交。

### 阶段 1：Capability 和纯 policy

新增：

- `entry/src/main/ets/services/SshFeatureFlags.ets`
- `entry/src/main/ets/services/SshRouteProfilePolicy.ets`
- `entry/src/main/ets/services/SshFrpEndpointPolicy.ets`
- 对应 ArkTS 测试

步骤：

1. 定义第 7 节所有 flag。
2. 单跳 ProxyJump 和现有 FRP TCP endpoint 不得被意外关闭。
3. 多跳、forwarding UI 和外部 Visitor endpoint 默认 false。
4. 校验每种 route 的必填字段、端口、host 和最大跳数。
5. 明确 `frp_sudp` 和缺少外部 TCP endpoint 的 Visitor route 的 fail-closed 错误码和用户文案键。
6. 测试关闭 flag 时已有 runtime 的 stop 决策，但不要在 policy 中直接执行 Native 操作。

测试：

- route kind 全覆盖。
- 未知 enum fail closed。
- 第四跳拒绝。
- 非 loopback forwarding 警告。
- disabled/无 endpoint 的 FRP route 不发生 fallback。

提交信息：

`feat(ssh): add isolated capability and route policies`

### 阶段 2：Profile、store 和迁移

新增：

- `SshRouteProfileStore.ets`
- `SshForwardingProfileStore.ets`
- `SshFrpEndpointProfileStore.ets`
- `SshProfileMigration.ets`
- 对应序列化和迁移测试

步骤：

1. 按第 6 节定义 schema。
2. 使用 SSH 专属 namespace。
3. 实现原子 save/load/delete/list。
4. 实现旧单跳字段到 `hops[0]` 的 additive mapper。
5. 不删除或回写旧字段。
6. 未知 schema 版本只读。
7. 序列化前执行 secret key denylist 检查。
8. 测试损坏 JSON、空数组、重复 profile ID 和迁移幂等。

提交信息：

`feat(ssh): add versioned route forwarding and frp stores`

### 阶段 3：统一 Sheet、布局和 modal coordinator

新增：

- `SshSheetScaffold.ets`
- `SshLayoutPolicy.ets`
- `SshModalCoordinator.ets`
- 布局和状态机测试

步骤：

1. 实现 Phone、compact、wide 三种结果。
2. 实现统一 header/content/footer。
3. 实现 safe/IME inset 计算。
4. 实现 mount token、pending request 和页面销毁清理。
5. 用 mock 内容验证，不接 route 或 forwarding 业务。
6. 连续打开、关闭、替换目标 30 次。

提交信息：

`feat(ssh-ui): add responsive sheet and modal coordinator`

### 阶段 4：多跳 Route UI

新增：

- `SshRouteEditor.ets`
- `SshJumpHopEditor.ets`

修改：

- `SshAddFlow.ets` 中最小接线

步骤：

1. 旧单跳展示为第一个 hop。
2. 实现添加、删除、排序和复制 hop。
3. 三跳后禁用添加。
4. 每跳独立展示 host-key 和认证方式。
5. Phone 在现有 host add sheet 内推进。
6. Pad/PC 使用左列表、右详情。
7. 切换 hop 时保留未保存草稿。
8. 保存时调用 policy，定位第一个错误字段。

验收：

- 旧主机数据不丢失。
- 未使用 ProxyJump 的 direct 主机连接表单不变化。
- 无新增嵌套 bindSheet 竞态。

提交信息：

`feat(ssh-ui): add responsive multi-hop route editor`

### 阶段 5：一次性认证和连接预检

新增或扩展：

- `SshRouteSecretBroker.ets`
- `SshAuthPromptBroker.ets`
- 现有 `SshSessionManager`
- 现有 `SshNativeFacade`

步骤：

1. 连接前计算目标和所有 hop 的认证需求。
2. 按 hop 顺序发起认证。
3. keyboard-interactive 请求包含 name、instruction、prompt、echo、轮次和 hop。
4. 支持多 prompt、多轮、partial success、取消和超时。
5. 凭据 handoff 到 Native 后立即销毁 ArkTS 副本。
6. 页面销毁和 generation 变化清理 pending request。
7. 日志增加 hop/request ID，但不记录 secret。

测试：

- 密码回退 keyboard-interactive。
- 多轮 MFA。
- private key passphrase。
- hop 2 取消。
- 页面销毁后的迟到 response。
- generation 变化后的迟到 response。

提交信息：

`feat(ssh): add per-hop ephemeral authentication handoff`

### 阶段 6：ProxyJump Native 加固

修改：

- `ssh_adapter.cpp/.h`
- `ssh_route_policy.h`
- SSH 专属 NAPI bridge
- Native 测试

步骤：

1. 复用现有 `libssh2_channel_direct_tcpip_ex` 链路。
2. 每跳生成独立错误上下文。
3. 每跳独立执行 KEX、host-key 和认证。
4. 目标 host-key 不继承任何跳板信任。
5. cancellation 和 close 按目标到第一跳反向传播。
6. 关闭 channel、relay、session 和 socket 的顺序固定并测试。
7. generation 失效后丢弃 callback 并释放对应资源。
8. 重连重新建立完整链路。

Native 测试：

- 0/1/2/3 跳 route policy。
- 第四跳拒绝。
- 每跳错误映射。
- 中途 cancel。
- 迟到 callback。
- 反复连接关闭资源计数。

提交信息：

`fix(ssh-native): harden generation-safe multi-hop proxyjump`

### 阶段 7：Proxy/ProxyJump 真实端点矩阵

新增：

- `tests/ssh_endpoints/compose.yaml`
- OpenSSH target、jump1、jump2、jump3 fixture
- HTTP CONNECT fixture
- SOCKS5 fixture
- 固定 host keys
- 运行脚本和脱敏结果模板

矩阵：

- HTTP CONNECT。
- SOCKS5。
- 单跳、双跳、三跳。
- 密码、公钥、PAM keyboard-interactive。
- 每个 hop 的 host-key mismatch。
- 每个 hop 的认证失败。
- 目标 host-key mismatch。
- 连接中取消。
- Wi-Fi/网络切换。
- 八 session 并发。

打开条件：

- 所有必测项通过后，`sshProxyJumpMultiHop=true`。
- 任何一项缺失时保持 flag 关闭。

提交信息：

`test(ssh): add real proxy and proxyjump endpoint matrix`

### 阶段 8：Forwarding Controller

新增：

- `SshForwardingController.ets`
- `SshForwardingRuntimeStore.ets`
- 事件映射测试

步骤：

1. 封装 configure/start/stop/list/snapshot。
2. start 前要求 owner session 为 Ready。
3. runtime 记录 sessionId、channelId 和 generation。
4. 断线立即停止 listener 和活动 connection。
5. 重连后仅 `onSessionReady` profile 自动恢复。
6. stale callback 丢弃并释放 Native runtime。
7. stop 幂等。
8. flag 关闭时只停止 forwarding runtime。
9. 页面 detach 不停止 runtime；session close 必须停止。

提交信息：

`feat(ssh): add generation-owned forwarding controller`

### 阶段 9：Forwarding UI

新增：

- `SshForwardingSheet.ets`
- `SshForwardingEditor.ets`
- `SshRuntimeStatusCard.ets`

修改：

- `SshTerminal.ets` 中增加工具栏入口和 sheet 挂载

步骤：

1. profile 和 runtime 状态分离展示。
2. 实现 local、remote、dynamic 三种表单。
3. 默认 loopback。
4. 非 loopback 显示安全提示。
5. 支持 start、stop、duplicate、delete。
6. 显示实际监听地址、连接数、流量和错误。
7. 运行中 profile 不允许直接修改。
8. PiP 只显示摘要，不提供编辑。

提交信息：

`feat(ssh-ui): add unified forwarding workspace`

### 阶段 10：Forwarding 数据链路和端点验收

必须覆盖：

- Local：本机 listener → SSH → 远端 TCP 服务。
- Remote：远端 listener → SSH → 本机 TCP 服务。
- Dynamic：完整 SOCKS5 CONNECT。
- IPv4、IPv6 和域名。
- 端口占用。
- 最大连接数。
- 流量限制。
- listener 启动失败。
- SSH 断线和重连。
- stale callback。
- 同一 session 多 listener。
- 八个并发 session。

只有三种模式的真实数据传输均通过，才能打开 `sshForwardingUi`。

提交信息：

`test(ssh): validate local remote and dynamic forwarding`

### 阶段 11：外部 FRP Endpoint 配置和 UI 收口

本阶段不增加 FRP Native 协议、Go/Rust 依赖、frpc 子进程或 FRP secret 管理。

新增：

- `SshFrpEndpointPolicy.ets`
- `SshFrpEndpointEditor.ets`
- endpoint profile 测试

步骤：

1. 提供“FRP TCP 映射”和“外部 FRP Visitor TCP 入口”两种 endpoint profile。
2. FRP TCP 保存 frps 对外可访问的 SSH 映射 host/remote_port。
3. Visitor 保存外部 frpc visitor 已监听的 TCP host/bindPort。
4. 不显示和不保存 FRP 控制端口、token、visitor secret、proxy name 或 wire protocol。
5. STCP/XTCP 只作为来源说明，不能触发 App 内部 FRP 建链。
6. `frp_sudp` 显示“不适用于 SSH TCP”，禁止保存成可连接 route。
7. endpoint profile 通过 mapper 生成普通 TCP SSH 目标。
8. 保留 `frp_tcp` 等旧 route 枚举兼容，但只有存在明确 endpoint 时才允许连接。
9. 错误显示 endpoint host、port 和 SSH 阶段，不显示不存在的 FRP 控制面阶段。
10. UI 与 ProxyJump/forwarding 共用 SSH sheet scaffold 和字段样式。

测试：

- endpoint host/port 校验。
- 控制端口字段不存在。
- FRP secret 字段无法序列化。
- STCP/XTCP source label 不改变 Native route。
- SUDP fail closed。
- 旧 `frp_tcp` profile additive 迁移。

提交信息：

`feat(ssh): add external frp endpoint profiles`

### 阶段 12：外部 FRP 真实互操作

测试环境可以锁定官方 frps/frpc 版本以保证结果可复现，但 FRP 二进制只存在于测试端点，不打包进 HAP。官方配置行为参考：

- https://github.com/fatedier/frp/releases
- https://gofrp.org/en/docs/reference/visitor/

矩阵：

1. 外部 frpc 将目标 SSH 通过 TCP proxy 暴露到 frps remote_port，App 连接该 host/port。
2. 外部 frpc 运行 STCP visitor 并监听一个 App 可访问的 TCP bind 地址，App 连接该地址。
3. 外部 frpc 运行 XTCP visitor 并监听一个 App 可访问的 TCP bind 地址，App 连接该地址。
4. FRP token/secret 全部保存在外部测试配置，验证 App 日志、profile 和诊断包中不存在这些值。
5. 验证 SSH 密码、公钥、keyboard-interactive 和 host-key 流程在映射后保持一致。
6. 验证网络切换、FRP endpoint 短暂不可达和恢复。
7. 验证填写 frps 控制端口时明确失败，App 不自动改写。
8. 验证外部 visitor 未启动时显示 TCP endpoint 不可达，而不是假报 SSH 认证错误。
9. 验证不存在 direct/HTTP/SOCKS fallback。
10. SUDP 不进入 SSH 互操作矩阵，因为 App 不自建 UDP-to-TCP 桥接。

验收边界：

- 通过 TCP 映射、STCP visitor 和 XTCP visitor 的最终 TCP endpoint 完成真实 SSH 会话，即满足 App 的 FRP 支持目标。
- 报告必须写明“FRP 控制面由外部官方 frps/frpc 提供”。
- 不把外部 frpc 的 STCP/XTCP 成功宣称为 App 内置 FRP 协议实现。

提交信息：

`test(ssh): validate external frp ssh endpoints`

### 阶段 13：后台恢复、PiP 和并发

步骤：

1. forwarding runtime 和通过外部 FRP endpoint 建立的普通 SSH session 纳入 session collection。
2. 前台恢复逐 session 执行 health check。
3. generation 通过后才重新绑定 UI。
4. 需要 MFA/host-key 时进入 `NeedsAuthentication`。
5. App 只重试 SSH/TCP endpoint；外部 FRP 的恢复由外部 frpc/frps 负责。
6. 系统拒绝后台时设置 `backgroundLimited`。
7. PiP 只显示 active session 状态和输出摘要。
8. active tab 关闭后切换到下一个 session。
9. 无可用 session 时停止 PiP。
10. 八个 SSH session 并发执行连接、forwarding 和网络恢复。

提交信息：

`feat(ssh): integrate routes and tunnels with background recovery`

### 阶段 14：最终 UI 和设备门禁

设备矩阵：

| 场景 | Phone | Pad | PC/2in1 |
|---|---:|---:|---:|
| 添加/编辑多跳 | 必测 | 必测 | 必测 |
| Forwarding sheet | 必测 | 必测 | 必测 |
| 外部 FRP endpoint profile | 必测 | 必测 | 必测 |
| 软键盘和 IME | 必测 | 必测 | 必测 |
| 实体键盘 | 必测 | 必测 | 必测 |
| 鼠标和焦点 | 可选 | 必测 | 必测 |
| 横竖屏 | 必测 | 必测 | 视设备 |
| 分屏/窗口缩放 | 必测 | 必测 | 必测 |
| 前后台和锁屏 | 必测 | 必测 | 必测 |
| 网络切换 | 必测 | 必测 | 必测 |

逐项检查：

- 标题、关闭按钮和内容不重叠。
- 所有 sheet 都能关闭和再次打开。
- 连续 profile 切换不失效。
- IME 不覆盖 footer。
- loading/empty/error 状态不造成异常高度跳动。
- Phone SFTP 保持实机验收结果。
- Pad/PC 新 UI 与现有 SSH/SFTP 风格统一。
- 键盘焦点、鼠标 hover 和无障碍文案正确。

提交信息：

`fix(ssh-ui): finalize responsive route and tunnel experience`

### 阶段 15：最终复核和交付

1. 运行全部强制门禁和端点矩阵。
2. 运行真实设备矩阵。
3. 执行 secret 泄漏扫描。
4. 执行 RDP/RustDesk/VNC 最小回归验证，但不修改其代码。
5. 执行独立 reviewer。
6. reviewer 发现问题时在当前分支修复并重新执行对应门禁。
7. 更新 `CURRENT.md`、`QUEUE.md`、`STATE.json` 和 review receipt。
8. 未解除 blocker 的能力保持 flag 关闭，并在交付说明中逐项列出。

## 10. 测试矩阵

### 10.1 ArkTS/policy

- profile schema 和迁移幂等。
- secret 字段拒绝序列化。
- route/forward/外部 FRP endpoint flag 组合。
- 1–3 hop 校验和第四跳拒绝。
- forwarding loopback 和端口范围。
- modal coordinator 连续开关、替换和页面销毁。
- runtime generation 和 stale event。

### 10.2 Native

- ProxyJump channel/socket/relay 生命周期。
- HTTP CONNECT 和 SOCKS5 握手边界。
- local/remote/dynamic listener 和连接 acquire/release。
- stop 幂等。
- generation 变化后的资源清理。
- 外部 FRP endpoint 与普通 TCP route 使用相同的 socket ownership。
- 反复 start/stop 资源计数。

### 10.3 真实端点

- OpenSSH 密码、公钥、PAM keyboard-interactive。
- HTTP CONNECT、SOCKS5。
- 一至三跳 ProxyJump。
- local、remote、dynamic forwarding。
- 外部 FRP TCP 映射后的 SSH endpoint。
- 外部 STCP visitor 暴露的 TCP endpoint。
- 外部 XTCP visitor 暴露的 TCP endpoint。
- visitor 未运行、endpoint 不可达和恢复。
- SUDP 明确不适用于本 App 的 SSH TCP 入口。

### 10.4 恢复和压力

- 八个并发 SSH session。
- Wi-Fi 切换。
- 前后台。
- 锁屏。
- 进程重启。
- 迟到 callback。
- session generation 快速变化。
- 长输出、vim、tmux 和 REPL。
- listener 端口冲突和连接上限。

### 10.5 安全

断言以下位置不存在 secret：

- Hilog。
- ArkTS 日志。
- Native 日志。
- profile store。
- SFTP task store。
- CloudStore 行。
- backup manifest。
- diagnostics zip。
- crash annotation。

### 10.6 其他协议回归边界

只做验证，不借机改动：

- RDP 启动和关闭。
- RustDesk 启动、视频和输入。
- VNC 启动和关闭。
- SFTP Phone/Pad/PC 已验收路径。
- Native Drawing 继续不作为可见 SSH 验收路径。

## 11. 强制构建与合规门禁

每个阶段改动完成、提交或宣称完成前执行：

```sh
source scripts/macos_env.sh
hvigorw --mode module -p module=entry -p product=default default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon
hvigorw --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --no-daemon
```

同时执行：

- `git diff --check`
- 范围匹配的 ArkTS 测试
- 范围匹配的 Native 测试
- 涉及 Rust/FFI 时对应语言测试；本计划不新增 Go/FRP FFI
- Light 合规门
- 依赖变化时 SBOM、NOTICE、provenance 和 hash 校验

`default@OhosTestBuildArkTS` 不能代替规定门禁。

对测试模块有影响时，应额外执行 `ohosTest@OhosTestCompileArkTS`。当前已知任务注册错误 `00306054` 若仍存在，必须记录 blocker，不能写成通过。

## 12. 执行模型固定循环

每个阶段必须严格执行以下循环：

1. 读取本阶段列出的现有文件完整上下文。
2. 执行 workspace status。
3. 记录其他 session 的 dirty files。
4. 为本阶段建立精确文件白名单。
5. 只实现本阶段目标，不顺带重构。
6. 先补纯 policy 测试，再接 controller/UI/Native。
7. 执行 targeted tests。
8. 执行两项 Hvigor 门禁。
9. 执行 Light 合规门。
10. 执行 `git diff --check`。
11. 检查所有修改路径。
12. 只精确暂存本阶段文件。
13. 阅读完整 staged diff。
14. 检查是否出现 secret、日志泄漏或跨协议改动。
15. 创建一个职责单一的 commit。
16. 更新状态和证据。
17. 上一阶段有失败、缺失端点或缺失设备证据时停止，不进入下一阶段。

执行者禁止做以下推断：

- “Native 有函数，所以功能完成”。
- “UI 可以点击，所以数据链路完成”。
- “单跳通过，所以三跳也通过”。
- “App 能连接 FRP TCP 映射，所以 App 自己实现了 STCP/XTCP/SUDP”。
- “没有日志错误，所以成功”。
- “旧 session 构建通过，所以当前改动通过”。
- “其他模块只是格式变化，可以一起提交”。

## 13. 已知 blocker

编写本计划时存在：

1. 尚无真实 OpenSSH bastion、forwarding 和外部 FRP endpoint 完整矩阵。
2. `ohosTest@OhosTestCompileArkTS` 任务注册失败 `00306054`。
3. Light 合规基线中 `totp-reviewed-brand-assets` 为 `licenseDeclared=NOASSERTION`。
4. Native SSH GPU surface 在 API 23 上不是验收路径，必须继续使用 xterm.js。
5. 外接键盘和第三方 IME 覆盖仍不完整。
6. 标准 SUDP 不能直接提供 SSH 所需的 TCP 字节流，本计划明确不在 App 内实现 bridge。

这些 blocker 不妨碍先完成隔离的 policy、profile、UI 骨架和已有 Native 链路加固，但会阻止对应 feature flag 和最终完成状态。

## 14. 最终交付清单

- [ ] 文件变更全部位于允许范围。
- [ ] SFTP 未被修改且实机回归通过。
- [ ] RDP/RustDesk/VNC 无代码改动和生命周期回归。
- [ ] Profile schema 和迁移通过。
- [ ] Secret broker 泄漏测试通过。
- [ ] HTTP CONNECT/SOCKS5 真实端点通过。
- [ ] 一至三跳 ProxyJump 通过。
- [ ] Local forwarding 通过。
- [ ] Remote forwarding 通过。
- [ ] Dynamic forwarding 通过。
- [ ] 外部 FRP TCP 映射 endpoint 通过。
- [ ] 外部 STCP visitor TCP endpoint 通过。
- [ ] 外部 XTCP visitor TCP endpoint 通过。
- [ ] App 不包含 frpc、FRP 控制面、token/secret 管理或 SUDP bridge。
- [ ] SUDP 在 SSH UI 中明确不可用。
- [ ] 八 session 并发和恢复通过。
- [ ] Phone/Pad/PC UI 矩阵通过。
- [ ] `default@OhosTestCompileArkTS` 通过。
- [ ] `assembleHap` 通过。
- [ ] Native/Rust/FFI 对应测试通过；没有新增 Go/FRP 依赖。
- [ ] Light 合规门通过。
- [ ] 独立 reviewer 通过。
- [ ] 状态文档和 review receipt 已更新。

只有上述适用项全部关闭，才能将 SSH Level B 或“连接外部 FRP SSH endpoint”标记为完成。
