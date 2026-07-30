# RustDesk 中继保存、控制面认证与官方功能对齐完整计划 v3.2

> 计划日期：2026-07-29；v3.2 执行校准：2026-07-30（Asia/Shanghai）
>
> 计划类型：实体实施计划；v3.2 起进入正式实施，不再停留在只读评估
>
> 当前项目：HarmonyOS NEXT API 23 四协议远程桌面客户端
>
> v3.2 修订：在 v3.1 的保存链路和人因工程方案上，校准当前代码基线、显式 profile
> 迁移、1.0.9 版本事实、D-020 云生命周期边界和本地闭环流程
>
> 执行基线：本地 `main` 为 `d0e6ffee2`；唯一活动任务分支为
> `codex/rustdesk-control-plane-v3`，从该本地 `main` 直接建立；不合并远端 `main`
>
> 前置实现 checkpoint：`972a3c0d7 fix(rustdesk): repair relay control plane and peer 2fa`
>
> 用户问题版本：现场应用显示 `1.0.8`；当前执行基线已是
> `1.0.9`/`1000009`，但该编号对应前序 cloud/data lifecycle 交付，RustDesk 修复产物
> 仍必须提供独立 build identity，正式发布时使用新的可区分版本
>
> 许可证路线：采用独立协议实现（C 方案），不直接复制、链接或替换为 RustDesk
> 官方客户端核心；继续遵守本项目现有 AGPL、NOTICE、SBOM 和 provenance 约束

## 0. 结论、目标与执行原则

### 0.1 用户问题的结论

三类现场反馈应归入同一个 P0 问题族：

1. 中继配置保存：
   - 用户能进入中继添加 Sheet 并完成字段操作；
   - 点击保存会出现 Toast 或 Sheet 状态变化，但配置没有形成稳定、可回读的中继记录；
   - 页面没有显示数据库提供的具体失败码；
   - 当前日志没有 `validation -> commit -> read-back` 的业务阶段记录，无法从现场直接区分
     校验拒绝、加密锁定、账号切换、数据库事务失败或保存后回读丢失；
   - 添加路径同时暴露协议类型、服务类型、控制面策略、Key 模式、多个端口和 Pro 登录，
     用户无法判断哪些字段与自己的托管服务相关。
2. 官方或兼容 RustDesk Server Pro：
   - 中继/API 配置成功；
   - 账号登录成功；
   - 地址簿同步成功；
   - 普通用户账号能看到目标主机；
   - 从主页连接时，无论输入设备密码还是请求远端批准，都返回
     `you have not logged in or your login session has expired`。
3. OSS/托管 hbbs+hbbbr 配合“超享 RustDesk 远程管理后台”：
   - 普通用户账号登录和地址簿同步正常；
   - 同一自建服务器、同一公钥、同一 Peer 在其他 RustDesk 设备上可连接；
   - HarmonyOS 地址簿主机和手工主机均在 `RequestingRelay` 阶段返回
     `Connection failed, please login!`；
   - 服务器后台能看到 `harmonyos-rustdesk-ffi` 请求，证明没有回落到官方公共服务器。

后两类连接错误都发生在 Peer 设备密码、请求批准和 Peer 2FA 之前。中继保存失败则更早，
发生在任何连接上下文形成之前。正确的层次为：

```text
中继配置本地校验/保存/回读   当前新增 P0
HTTP 账号登录                成功
HTTP 地址簿同步              成功
hbbs rendezvous/control-plane 失败
hbbr relay                   可能尚未建立
Peer key exchange            尚未开始
Peer password/approval/2FA   尚未开始
```

因此它不是“用户没有登录”的充分证据，也不能通过反复修改 Peer 密码、公钥或请求批准
方式解决。

### 0.2 本计划的两个主目标

#### 目标 A：彻底修复 P0 控制面问题

- 让中继配置在离线、无云服务和普通本地账号场景下都能可靠保存；
- 让每次保存拥有可观察的校验、提交、回读和最终状态；
- 让数据库的结构化失败码完整到达 UI，不再退化为一个通用布尔值；
- 合并三套中继添加逻辑，建立唯一的校验、默认值和持久化 owner；
- 通过渐进披露把默认添加任务压缩为服务器地址和服务器 Key 两个核心输入；
- 让登录成功的普通用户和管理员都能按服务器真实契约连接；
- 让手工主机和地址簿主机使用同一套服务器/账号/Token 投影逻辑；
- 让官方 Server Pro、OSS key-only、第三方地址簿 API-only 和自定义控制面互不误判；
- 让 `please login`、权限不足、Token 过期、Relay Key 失败和 Peer 密码失败落入正确层级；
- 任何 relay/control-plane 原始英文都不能单独清除有效 HTTP 登录 Token；
- 通过真实 Server Pro、超享、官方 OSS、普通用户和管理员矩阵闭环。

#### 目标 B：大幅推进与 RustDesk 官方客户端的功能对齐

- 支持明确的 `AUTO`、`FORCE_RELAY`、`DIRECT_IP` 连接策略；
- 实现真实 NAT 探测、官方兼容的 TCP hole punching、IPv6 候选和 relay fallback；
- 对齐 rendezvous、secure TCP、relay、Peer 加密、认证、权限、媒体、输入、
  剪贴板、文件传输和生命周期；
- 建立固定官方版本、协议 fixture、黑盒互操作和真实网络矩阵；
- 未实现能力显式 fail-closed，不向 Peer 或用户宣称已经支持。

### 0.3 执行原则

1. **服务器能力决定连接认证，不由主机来源决定。**
   “来自地址簿”不等于“需要 Pro Token”，“手工添加”也不等于“不需要 Token”。
2. **HTTP Token 与 hbbs connect Token 分层。**
   只有服务器 profile 明确且验证过的情况下，HTTP 登录产物才能进入
   `PunchHoleRequest.token`/`RequestRelay.token`。
3. **普通用户不是降级账号。**
   管理员权限用于 Web 管理；能否连接由 Access Control 决定，连接后的功能由
   Control Role 决定。
4. **错误以阶段和结构化响应为准。**
   英文字符串只用于显示和诊断，不能直接驱动账号状态写入。
5. **先保持可回滚，再增加自动连接。**
   在 AUTO/P2P 完整通过前，不把一个布尔值改名成“自动”并默认发布。
6. **独立实现不等于凭记忆重写。**
   依据固定 protobuf、官方文档、服务端可控 fixture 和黑盒行为；不逐行复制官方客户端。
7. **API 23 是上限。**
   所有 HarmonyOS API 必须在本机 API 23 SDK 声明或华为官方 API 23 文档中可验证。

## 1. 当前仓库状态与用户修改保护

### 1.1 v3.2 正式实施基线

- 项目根目录：
  `/Users/mydestiny/Desktop/RemoteDesktop/RemoteDeskHarmonyOS`
- 分支：`codex/rustdesk-control-plane-v3`
- 分支创建点：`d0e6ffee2`
- 本地 `main`：`d0e6ffee2`
- 相对本地 `main`：计划提交前领先 0、落后 0
- 相对 `origin/main`：本地 `main` 领先 147 个提交
- 活动 `codex/<task>` 分支：`codex/rustdesk-control-plane-v3`
- 持久 worktree：1
- VNC V2 与 cloud lifecycle D-020 已在本地 `main` 闭环；本任务不得重新审查或改写；
- 工作树保留 SSH、Moonlight、RDP 和 RustDesk controlled-host 其他任务文档；
- 本任务只暂存 RustDesk control-plane v3 计划和后续明确归属的实现文件，不 fetch、
  pull、stash、reset，也不覆盖其他任务文件。

必须保留且不得暂存或修改：

- `docs/SSH_MODULE_UPGRADE_PLAN.md`
- `docs/SSH_MODULE_UPGRADE_PLAN_V2.md`
- `docs/superpowers/plans/2026-07-28-moonlight-harmonyos-complete-upgrade-plan.md`
- `docs/superpowers/plans/2026-07-30-rdp-freerdp-harmonyos-full-parity-lifecycle-ux-upgrade-plan.md`
- `docs/superpowers/plans/2026-07-30-rustdesk-harmonyos-2in1-controlled-host-complete-upgrade-plan.md`

任何新增脏文件必须先确认归属。RustDesk 实现继续继承 D-020 的
account/store/generation/owner/barrier/checkpoint 规则，不新增第二张 RustDesk 云表，
不削弱 cloud-first、恢复隔离、crypto 或 token revocation。

### 1.2 与既有 v2 计划的关系

本计划继承但不替代以下已落地边界：

- `oss_key_only`、`addressbook_only_custom`、
  `official_server_pro_token`、`custom_control_plane` profile；
- profile 作为当前设备 `localmetadata`，不进入云 relay 行和普通备份；
- Token fingerprint/generation；
- exact phrase 不再单独清 Token；
- `rdRelayPort` 从 ArkTS 贯通 NAPI/C++/Rust；
- hbbs 广告 relay 显式端口优先、配置端口只作 fallback；
- Peer 2FA `Auth2FA`、session/epoch 隔离和手动/自动提交；
- 屏幕连接与文件传输均有 relay/token 基础路径。

v3.2 继续实施并强化：

- 中继保存结构化结果、本地优先、原子事务和强一致回读；
- 三套添加逻辑合并与基于人因工程的渐进披露流程；
- 保存/连接 attempt 级脱敏诊断；
- 手工主机与地址簿主机统一连接上下文；
- 普通用户/管理员、Access Control/Control Role 的完整矩阵；
- Server Pro Token handoff 的 source-independent 规则；
- 超享/第三方控制面的能力探测与 adapter 边界；
- AUTO/FORCE_RELAY/DIRECT_IP 三态及真实 hole punching 路线；
- 全功能官方对齐、版本治理、发布和回滚路线。

v3.2 的实现结论必须区分：

- **本地代码完成**：安全实现的功能、测试、门禁和独立复核全部闭环；
- **发布完成**：真实官方 Server Pro、第三方控制面、OSS hbbs/hbbr、密码/批准/2FA、
  P2P/relay/direct、API 23 生命周期及多设备云矩阵均有证据。

真实端点和设备矩阵完成前发布状态保持 `NO-GO`。依赖未固定服务端契约或真实网络证据的
能力必须 `unsupported_fail_closed` 或 `blocked_by_server_contract`，不得伪造可用。

## 2. 官方依据与固定参照

### 2.1 RustDesk 官方客户端与协议参照

实施时固定以下参照，不跟随浮动 `master`：

- RustDesk 客户端固定提交：
  [`d412d198720aa56f6cfed2dfad262e8fb1322fb7`](https://github.com/rustdesk/rustdesk/tree/d412d198720aa56f6cfed2dfad262e8fb1322fb7)
- hbb_common 固定提交：
  [`559176122bdd5c8afa4e8fd5b706c3d901fb0c15`](https://github.com/rustdesk/hbb_common/tree/559176122bdd5c8afa4e8fd5b706c3d901fb0c15)
- RustDesk OSS server 固定提交：
  `6e7de5b1d648e64e5d7930eea2239f58721420b9`

需要固定 blob/hash 并建立本地记录的协议文件：

- `hbb_common/protos/rendezvous.proto`
- `hbb_common/protos/message.proto`
- 当前本地：
  `rustdesk_vendor/libs/hbb_common/protos/UPSTREAM.yml`

P0 不为了“看起来更新”而整体升级 protobuf。只有字段或 oneof 兼容性不足时才升级，
并同步：

- 生成代码；
- blob SHA；
- provenance；
- NOTICE；
- SBOM；
- 输入 hash；
- 双 ABI 构建。

### 2.2 官方自建配置边界

RustDesk 官方客户端配置文档明确区分：

- ID Server：hbbs；
- Relay Server：hbbr，通常可由 hbbs 推导；
- API Server：Server Pro 账号登录和 Web 控制面；
- Key：`id_ed25519.pub` 公钥，与 Pro 许可证 Key 不同。

参考：

- [RustDesk Client Configuration](https://rustdesk.com/docs/en/self-host/client-configuration/)
- [RustDesk Client](https://rustdesk.com/docs/en/client/)

本项目因此必须保持以下字段长期独立：

```text
idServerHost/idServerPort
relayServerHost/relayServerPort
apiServerUrl
serverPublicKey
sharedAccessKey
accountAccessToken
controlPlaneConnectToken
peerPassword
peer2faCode
```

### 2.3 官方网络/端口行为

RustDesk OSS 官方文档给出的基础端口语义：

- `21115/TCP`：NAT 类型测试；
- `21116/UDP`：ID 注册和 heartbeat；
- `21116/TCP`：TCP hole punching/连接服务；
- `21117/TCP`：hbbr relay；
- `21118/21119/TCP`：Web client 支持。

参考：

- [RustDesk Server OSS Docker](https://rustdesk.com/docs/en/self-host/rustdesk-server-oss/docker/)
- [RustDesk Server OSS Installation](https://rustdesk.com/docs/en/self-host/rustdesk-server-oss/install/)

官方文档明确以 TCP hole punching 作为直接连接路径，失败时才消耗 relay 流量。
本项目当前 `nat=SYMMETRIC` 和 `force_relay=true` 均为固定值，不能代表官方自动策略。

### 2.4 Server Pro 普通用户、Access Control 与 Control Role

RustDesk 官方 Server Pro 文档将三者分开：

- Access Control：决定账号能否连接某设备；
- Control Role：决定连接后键鼠、剪贴板、文件、音频、终端等权限；
- Admin Role：决定 Web Console 中的管理能力，不是远程连接的前置条件。

参考：

- [Access Control](https://rustdesk.com/docs/en/self-host/rustdesk-server-pro/permissions/)
- [Control Role](https://rustdesk.com/docs/en/self-host/rustdesk-server-pro/control-role/)
- [Admin Role](https://rustdesk.com/docs/en/self-host/rustdesk-server-pro/admin-role/)

官方还定义 `Not Logged` 和 `Default` Control Role。普通用户登录成功但无权访问目标设备时，
应返回访问控制结果，而不是被客户端改写为“登录过期”。

### 2.5 官方连接策略和扩展能力

官方文档还说明：

- `disable-udp=Y` 时不使用 UDP 21116，转为 TCP 21116；
- force relay 是诊断/策略选项；
- WebSocket 只支持 relay（Direct IP 例外）；
- Server Pro 可根据地理位置选择多个 relay；
- trusted devices、单向剪贴板、单向文件传输、初始剪贴板同步等均有版本边界。

参考：

- [Advanced Settings](https://rustdesk.com/docs/en/self-host/client-configuration/advanced-settings/)
- [Configure Relay Servers](https://rustdesk.com/docs/en/self-host/rustdesk-server-pro/relay/)
- [RustDesk FAQ](https://github.com/rustdesk/rustdesk/wiki/FAQ)

## 3. HarmonyOS API 23 官方能力边界

### 3.1 已由本机 API 23 SDK 确认的声明

本机官方 OpenHarmony SDK：

```text
/Users/mydestiny/Library/OpenHarmony/Sdk/23
```

实施时必须再次读取实际 `.d.ts`，不能只抄计划。

#### Network Kit

`ets/api/@ohos.net.connection.d.ts` 已确认：

- `createNetConnection()`；
- `getDefaultNet()`/`getDefaultNetSync()`；
- `NetConnection.on('netAvailable')`；
- `NetConnection.on('netCapabilitiesChange')`；
- `NetConnection.on('netLost')`。

用途：

- ArkTS 感知网络可用性；
- 把网络 generation 变化通知 native；
- 触发可取消重连；
- 不在 ArkTS 线程实现 RustDesk wire socket。

`ets/api/@ohos.net.socket.d.ts` 已确认：

- UDP bind/message/extra options；
- TCP bind/connect/message/extra options；
- TLS socket；
- IPv4/IPv6 地址结构。

用途：

- UI/设置页的连通性测试；
- 局域网发现；
- 必要时做受控 socket fixture。

正式 RustDesk 会话、CryptoChannel、hole punching 和 relay socket 继续由 Rust/C++ native
所有，避免双栈状态机和 ArkTS 生命周期竞争。

项目已经声明：

```text
ohos.permission.INTERNET
```

#### UIAbility 生命周期

`ets/api/@ohos.app.ability.UIAbility.d.ts` 已确认：

- `onForeground()`；
- `onBackground()`；
- `onDestroy()` 可返回 `void | Promise<void>`；
- `onDestroy()` 后应用可能退出，异步清理不可无限延迟。

计划约束：

- background 不默认断开已建立远程会话；
- pending login/2FA 的 Sheet 可隐藏，但 attempt 必须可判定；
- destroy 必须同步发起 native cancel/close，再做有界异步收尾；
- callback 必须校验 session/attempt/page generation。

#### TaskPool

`ets/api/@ohos.taskpool.d.ts` 已确认：

- Task/TaskGroup/execute；
- 参数需要可序列化；
- ArrayBuffer transfer 后原对象失效；
- `@Sendable` 和 clone/transfer 有严格限制；
- 序列化失败有明确错误。

计划约束：

- 不把 native handle、C++ 指针、CryptoChannel、socket 或 Secret 放入 TaskPool；
- TaskPool 只用于可序列化、无状态、可取消的轻量计算；
- Rust 连接线程继续拥有 socket 状态机。

#### User Authentication Kit

`ets/api/@ohos.userIAM.userAuth.d.ts` 已确认：

- `getAvailableStatus()`；
- `getUserAuthInstance()`；
- `UserAuthInstance.cancel()`；
- PIN/人脸/指纹；
- `MAX_ALLOWABLE_REUSE_DURATION = 300000`。

项目已经声明：

```text
ohos.permission.ACCESS_BIOMETRIC
```

用途仅限：

- 用户明确启用的主机锁；
- TOTP Secret 使用前的本地用户确认；
- 未来受控的 Token/Secret读取授权。

不得把本地生物认证当成 RustDesk Server Pro 登录或 Peer 2FA。

#### Asset Store Kit

`ets/api/@ohos.security.asset.d.ts` 已确认：

- `add/remove/update/query`；
- `AUTH_VALIDITY_PERIOD`；
- `IS_PERSISTENT`；
- 使用持久化属性需要额外权限；
- 官方文档将其定位为不超过 1KB 的短敏感数据安全存储。

参考：

- [Asset Store Kit](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V14/asset-store-kit-overview-V14)
- [HarmonyOS 文档中心](https://developer.huawei.com/consumer/cn/doc/)

本 P0 不迁移现有 KeyVault/DataCrypto 格式到 Asset Store。Token 当前保持现有短期内存
和账号 owner；Asset Store 迁移必须另立 ADR，评估卸载、持久化、备份、换机、锁屏和
认证有效期。

## 4. 当前代码审计与确定性缺口

### 4.1 已确认的 P0 高风险条件

`HostListPage.rustDeskProConfig()` 当前对 `rdAccessToken` 的最终赋值仍依赖：

```text
host.rustdeskProManaged && host.sourceType === 'rustdesk_pro'
```

这意味着服务器 profile 即使为 `official_server_pro_token`：

- 地址簿托管主机可能发送 Token；
- 同一 Server Pro 上手工添加的主机可能强制发送空 Token；
- 手工主机报 `please login` 与现场完全一致；
- 主页路径与 `RemoteDesktop.ets` 的 Token 解析可能不一致；
- 文件传输和重连也可能继续复制不同条件。

修复必须消除“host source 决定 token”的设计。

### 4.2 服务器 profile 与账号绑定仍未成为统一 owner

当前 profile 已存在，但连接上下文仍分散在：

- `HostListPage.ets`
- `RemoteDesktop.ets`
- `RustDeskProConnectionPreflightPolicy.ets`
- `RustDeskControlPlanePolicy.ets`
- NAPI config 映射
- C++ bridge
- Rust FFI

风险：

- 普通连接、preflight、文件传输、重连字段不同；
- accountId/relayId/sourceType 任一旧字段导致 Token 丢失；
- 手工主机没有明确账号绑定 UI；
- 第三方 API-only 可能误选 `official_server_pro_token`；
- 同名 relay 或旧 host 记录可能残留错误 profile。

### 4.3 当前 rendezvous 行为与官方自动策略不一致

`rustdesk_ffi/src/protocol/rendezvous.rs` 当前：

- `nat_type` 固定为 `SYMMETRIC`；
- `force_relay` 固定为 `true`；
- `punch_hole()` 明确返回 Unsupported；
- 未实现官方 TCP hole punching 全状态机；
- 未实现真实 NAT test；
- 未实现 AUTO 失败转 relay；
- 未实现 IPv6/UPnP/多候选竞争；
- 未处理完整 ConfigUpdate、health、online/discovery 等消息。

因此“其他设备能连、HarmonyOS 不能”可能同时由：

- Token/profile 错误；
- 官方客户端走 direct，而 HarmonyOS 必走 relay；
- 超享 control-plane 对自定义客户端登录契约不同；
- 当前 secure/token/key 字段组合不被目标版本接受；

共同造成。P0 必须先修 Token 投影，同时用 FORCE_RELAY A/B 独立验证；长期再补 AUTO。

### 4.4 错误分类已改善但真实契约仍未闭环

当前已经：

- 生成 `RDERR|stage=...|code=...|detail=...`；
- exact phrase 分类为 `control_plane_incompatible`；
- 只有特定结构化 Pro session error 才允许清 Token。

仍需补齐：

- hbbs `PunchHoleResponse.other_failure` 与 `RelayResponse.refuse_reason` 的来源；
- Access Control denied 与登录过期区分；
- ordinary user disabled、device disabled、group denied；
- Token absent、invalid、expired、wrong server、wrong generation；
- hbbr endpoint/key 与 hbbs control-plane；
- Peer offline/ID missing/password/approval/2FA；
- 第三方面板原始错误 adapter。

### 4.5 版本不可区分

现场问题 HAP 显示：

```text
versionName = 1.0.8
versionCode = 1000008
```

当前 `d0e6ffee2` 执行基线已经显示：

```text
versionName = 1.0.9
versionCode = 1000009
CURRENT_RELEASE_VERSION = 1.0.9
```

但该版本号已经用于前序 cloud/data lifecycle 交付，不能证明安装了本次 RustDesk 修复。
开发 checkpoint 必须增加可见 build identity；正式发布本修复时使用
`1.0.10`/`1000010` 或当时尚未占用的更高版本，并同步 release notes、SBOM、
provenance 和回滚说明。不得仅凭“关于页显示 1.0.9”判定现场修复存在。

### 4.6 2026-07-29 现场 1.0.8 真机保存日志证据

现场设备：

```text
bundle: com.example.remotedesktop
versionName/versionCode: 1.0.8/1000008
process: 21753
device: HarmonyOS API 23 真机
```

用户按约定重新执行了一次保存，并确认界面原文为“中继服务器保存失败”
（用户转述时写作“中级服务器保存失败”）。这与
`RustDeskRelayPage.doSaveRelay()` 的通用持久化失败分支完全对应，因而可以确定：

1. 保存按钮的点击已被 ArkUI 接收；
2. ID Server、端口、Pro API 和 Key 的页面前置校验已经通过；
3. `HostSyncService.addRelay()` 或 `updateRelay()` 返回了 `false`；
4. 失败发生在 HostSync/CloudStore 持久化边界，不是连接服务器、账号登录或 Peer 认证；
5. 当前 UI 没有取回 `CloudStore.getLastMutationResult()`，所以具体失败码被丢失。

真机时间窗 `2026-07-29 23:26:51.421–23:26:51.729` 只能看到按钮被接受和 Toast
挂载，没有看到 `RustDeskRelay`、保存 attempt、校验阶段、事务阶段或回读阶段业务日志。
同一约 308ms 窗口内出现三次 Button/Toast 序列，说明界面没有提交中禁用和幂等保护；
它应作为重复提交风险修复，不能据此假定三次都完成了数据库调用。

本次时间窗没有出现 `CloudStore.upsertRelay transaction failed`。这不能证明数据库事务成功，
但把排查优先级推向事务开始前的静默拒绝：

- 加密已配置但当前未解锁：`unlock_required`；
- 恢复、账号生命周期或 mutation gate 尚未开放：`restore_in_progress`；
- relay 记录 owner 与当前 owner 不一致：`invalid_data`；
- 编辑记录已从 `HostSyncService.relays` 中消失，`updateRelay()` 直接返回 `false`；
- 数据库/服务就绪状态在 UI 打开与点击保存之间发生变化。

此前观察到的 `StepResultSet/AbsResultSet` 系统告警发生在 Sheet 状态变化附近，但没有
attempt/stage 关联，既可能来自保存后列表回读，也可能来自无关查询。修复前不得把它写成
根因。

### 4.7 当前保存调用链与语义丢失点

```text
RustDeskRelayPage.doSaveRelay()
  ├─ 页面字段校验
  ├─ resolveRustDeskRelayKey()
  └─ HostSyncService.addRelay()/updateRelay()       返回 boolean
       └─ CloudStore.upsertRelay()                  返回 boolean
            ├─ store/mutation/owner/unlock gate
            ├─ rustdeskrelays 行写入
            ├─ localmetadata profile 写入
            ├─ 本地 mutation journal 写入
            └─ commit + 异步 cloud push
```

`CloudStore.upsertRelay()` 已经能区分：

```text
not_ready
restore_in_progress
invalid_data
unlock_required
local_write_failed
metadata_write_failed
journal_write_failed
```

并通过 `getLastMutationResult()` 暴露脱敏结果，但 `HostSyncService` 和页面没有传播它。
页面最终只显示一个通用 Toast。与此同时，控制面 profile 与 relay 行处于同一事务；
profile 的 `localmetadata` 写入失败会回滚整个 relay 保存。这个原子性可以保留，但必须
让用户知道失败阶段和可恢复动作。

### 4.8 当前保存实现的确定性缺口

1. `addRelay()`/`updateRelay()` 只返回 `boolean`，无法表达失败阶段和重试建议。
2. `updateRelay()` 在内存 Map 找不到记录时直接 `false`，没有错误码。
3. 页面没有 `idle/validating/committing/verifying` 状态，也没有防重复提交。
4. 成功后只调用全量 `load()`，没有按 relay ID 做强一致回读和字段 fingerprint 校验。
5. 本地保存与云同步成功被耦合在同一个“保存”心智模型里；用户无法知道是否已本地保存。
6. mutation gate 会受恢复/账号生命周期影响，但页面没有等待、保留草稿或一键重试。
7. `unlock_required` 已有明确中文信息，传到 UI 时却被覆盖。
8. 早期返回完全没有业务日志，远程现场只能看到 ArkUI Toast 外壳。
9. 日志没有 saveAttemptId，无法把点击、数据库事务、回读和最终页面状态串起来。
10. 保存失败后没有可复制的脱敏诊断摘要。

### 4.9 三套添加流程已经发生行为漂移

当前至少存在三套 RustDesk 中继表单/保存实现：

- `pages/RustDeskRelayPage.ets`：管理页实际入口；
- `components/hostadd/RustDeskAddFlow.ets`：添加主机内嵌入口；
- `components/resourceadd/modern/ModernRelayAddFlow.ets`：另一套现代入口，当前代码搜索
  未发现实际调用方，属于待确认的不可达/遗留实现。

管理页默认路径依次要求用户理解“网关协议 → OSS/Pro/高级 → 控制面 profile →
Key 模式 → ID/Relay/API 地址和端口 → 保存后确认 → 可选登录”。这把内部协议模型直接
暴露给普通用户，产生以下人因问题：

- 用户的真实目标是“添加一台自建 RustDesk 服务器”，却先被要求选择实现细节；
- `oss_key_only`、`addressbook_only_custom`、`official_server_pro_token`、
  `custom_control_plane` 是工程策略，不应成为普通用户决策；
- 数字输入清空时立即回填默认端口，编辑反馈不符合预期；
- “保存”和“确定保存”形成两个提交边界，用户不知道哪一步已经落盘；
- 空 Key 被描述成官方默认行为，容易误用于任意自建服务器；
- 三套表单的校验、默认值、导入和错误文案无法长期保持一致。

## 5. 根因树与证据要求

### 5.0 中继保存失败优先级

#### 第一优先级：事务前 mutation gate 拒绝

现场已经越过字段校验、进入通用持久化失败分支，且对应时间窗没有事务 catch 日志。
优先依次验证：

1. `DataCrypto.isSetupComplete() && !DataCrypto.isReady()` → `unlock_required`；
2. `mutationGateOpen === false` 或 restore/account transition → `restore_in_progress`；
3. `recordOwnerWriteAllowed()` 失败 → 当前实现的 `invalid_data`，目标模型映射
   `owner_mismatch`；
4. CloudStore/HostSync ready 状态在 Sheet 生命周期中发生切换。

证据：

- 保存开始时的非敏感 gate snapshot；
- 直接返回的 `DataMutationResult`；
- 解锁前/后、恢复前/后、账号切换前/后 A/B；
- 不依赖全局 last result 的 attempt 级断言。

#### 第二优先级：事务子步骤失败

依次注入：

- relay 行写入失败；
- profile metadata 写入失败；
- mutation journal 写入失败；
- commit/rollback 异常。

现场没有 catch 日志不能永久排除这类问题；release 日志级别、buffer flow control 和日志
标签都可能影响观测。必须用注入测试证明每个子步骤 rollback 和 code。

#### 第三优先级：编辑记录竞态或服务投影丢失

`HostSyncService.updateRelay()` 在内存 Map 不存在 `editingRelayId` 时直接返回 `false`，
不会进入 CloudStore。需要复现：

- 打开编辑 Sheet 后同步刷新；
- 账号切换；
- 云下载/本地恢复；
- 列表删除/合并；
- Sheet 保持期间服务重新初始化。

目标行为是保留草稿并显示 `record_missing`，允许“另存为新配置”。

#### 第四优先级：提交成功但回读/页面投影失败

当前没有 read-back stage，系统 `ResultSet` 告警也无法归属。需要把数据库 commit、
按 ID 查询、HostSync Map 更新、列表 load 和 Sheet 关闭拆成独立阶段，并为每个 ResultSet
确保 close。只有同一 attempt 明确出现 `readback_missing/mismatch`，才能把回读认定为根因。

### 5.1 第一优先级：Token 没有按服务器 profile 发送

可能原因：

- 手工主机 source gate 导致 Token 为空；
- addressbook host accountId/relayId 旧字段不一致；
- HostList 与 RemoteDesktop 使用不同 resolver；
- ordinary user Token generation 被旧连接覆盖；
- C string 生命周期或 NAPI 映射丢失；
- token 只进入 PunchHoleRequest，未进入 fallback RequestRelay；
- profile 从云/备份恢复后默认为 key-only。

证据：

- ArkTS resolved context：`profile`、`accountBound`、`tokenPresent`、
  `tokenFingerprintPrefix`、`tokenGeneration`；
- NAPI/C++/Rust 每层只记录 present/absent 和同一不可逆 fingerprint；
- fake hbbs 解码请求，断言两个 control-plane 消息字段；
- 真实 Server Pro ordinary/admin A/B。

### 5.2 第二优先级：Token 类型/登录契约不兼容

可能原因：

- `/api/login` access token 不是 hbbs connect token；
- 需要另一次 ticket exchange；
- 目标面板只兼容官方/定制客户端；
- secure rendezvous 的 KeyExchange/HWID/device registration 不完整；
- ordinary user 和 admin 的权限/claim 不同；
- Token 与 API/ID Server 实例不匹配。

证据：

- 官方 Server Pro 固定版本契约；
- 超享 vendor 明确说明或服务端可控测试；
- token absent/present A/B；
- ordinary/admin 同一 HAP A/B；
- 官方客户端同账号 FORCE_RELAY A/B；
- hbbs 结构化拒绝或服务日志。

未取得契约前：

- `THIRD_PARTY_API_ONLY` 默认 key-only；
- `THIRD_PARTY_CONTROL_PLANE` 仅显式启用；
- 不猜换票 endpoint；
- 不伪造官方客户端 version。

### 5.3 第三优先级：Access Control 被误报为登录失败

可能原因：

- ordinary user 可读地址簿，但无权访问目标设备；
- 设备归属、用户组、设备组或 cross-group 未授权；
- user/device disabled；
- Not Logged/Default role 配置；
- 服务端返回统一英文，被客户端误分类。

证据：

- ordinary own device/shared device/group device/denied device 矩阵；
- Access Control 后台截图或管理员确认；
- ControlPermissions 解码；
- deny 结果不得清 Token；
- admin 成功不作为普通用户 bug 已修复的替代证据。

### 5.4 第四优先级：Relay-only 暴露服务端路径问题

可能原因：

- 官方客户端成功使用 direct；
- HarmonyOS 固定 force relay；
- hbbs/hbbr Key 不一致；
- relay endpoint/port 广告错误；
- 多 relay 节点中部分节点未同步 key；
- hbbr 端口/防火墙/容器映射；
- UUID/secure/conn_type 不匹配。

证据：

- 官方客户端明确 FORCE_RELAY；
- hbbr 是否出现 pair；
- explicit port/fallback port；
- hbbs/hbbr 同 key fingerprint；
- 单 relay 与多 relay；
- HarmonyOS DIRECT/AUTO/FORCE_RELAY 结果。

## 6. 目标领域模型

### 6.1 RustDeskServerProfile

```text
oss_key_only
oss_shared_access_key
official_server_pro_token
third_party_api_only
third_party_control_plane
direct_ip
```

对应设计常量：

```text
OSS_KEY_ONLY
OSS_SHARED_ACCESS_KEY
OFFICIAL_SERVER_PRO_TOKEN
THIRD_PARTY_API_ONLY
THIRD_PARTY_CONTROL_PLANE
DIRECT_IP
```

不再使用模糊的 `pro`/`advanced` 或主机来源推断最终 Token 语义。`DIRECT_IP` 表示不经过
hbbs/hbbr 的传输上下文，本质上属于连接策略；为兼容现有持久化模型可作为 profile
读取，但 resolver 必须把它归一化为 `strategy=direct_ip`，且永远不投影 HTTP/control
plane Token。

职责必须固定：

- `oss_key_only`：只使用 Ed25519 服务器公钥验证服务器身份，不发送 control-plane Token；
- `oss_shared_access_key`：使用服务端 `-k` 共享访问 Key，不等于服务器公钥或账号 Token；
- `official_server_pro_token`：只有官方 Server Pro 登录、当前 owner/generation 和能力证明
  一致时，才把控制面 Token 投影到 `PunchHoleRequest`/`RequestRelay`；
- `third_party_api_only`：HTTP 地址簿可登录/同步，但连接 wire 永不发送该 HTTP Token；
- `third_party_control_plane`：必须有设备本地 adapter/capability 证明才允许投影 Token；
- `direct_ip`：无 hbbs/hbbr Token、无 relay fallback，端点必须由用户明确配置。

现有 localmetadata 的迁移规则：

- `oss_key_only` 保持不变；key mode 为共享 `-k` 时显式归一化为
  `oss_shared_access_key`；
- `addressbook_only_custom` 迁移为 `third_party_api_only`；
- `official_server_pro_token` 保持，但必须重新绑定当前 owner/token generation；
- `custom_control_plane` 不因旧枚举名称自动获得 Token 权限；无本机 capability 证明时
  安全降级为 `third_party_api_only`，只有显式验证后才迁移为
  `third_party_control_plane`；
- profile 继续只存当前设备 `localmetadata`，不得进入 cloud relay 行或普通备份；
- 迁移失败保留原 relay，并显示需要重新确认的结构化状态，不丢数据、不猜测权限。

### 6.2 RustDeskConnectionStrategy

```text
auto
force_relay
direct_ip
```

阶段性兼容：

- 旧 relay 记录在 AUTO 尚未完成时迁移为 `force_relay`；
- 旧 direct 记录迁移为 `direct_ip`；
- AUTO 只有在真实 NAT/hole punching/fallback 完成后才成为新主机默认。

### 6.3 RustDeskCredentialEnvelope

瞬态对象，不持久化：

```text
serverPublicKey
sharedAccessKey
httpAccessToken
controlPlaneToken
tokenFingerprint
tokenGeneration
peerPassword
requestApproval
peer2faCode
```

约束：

- public/shared key 二选一；
- HTTP token 与 control-plane token 可以同源，但必须由 profile adapter 明确授权；
- peer2faCode 只在收到 `2FA Required` 后存在；
- Secret 不跨日志、云、备份和 crash。

### 6.4 RustDeskResolvedConnectionContext

建议新增统一 resolver，所有入口复用：

```text
attemptId
hostRecordId
hostSource
peerId
relayId
accountId
serverProfile
connectionStrategy
idServerHost/idServerPort
relayFallbackHost/relayFallbackPort
apiServerUrl
keyMode
tokenPresent/tokenFingerprint/tokenGeneration
peerAuthMode
expectedCapabilities
```

输入来自 host/relay/account/settings；输出传给 SessionConfig。以下入口不得自行重组：

- HostList 主页；
- RemoteDesktop 普通路由；
- RustDesk preflight；
- 文件传输；
- reconnect/restore；
- quick action；
- 后台恢复。

### 6.5 RustDeskConnectionAttempt

每次连接独立：

```text
attemptId
sessionId
epoch
networkGeneration
pageGeneration
state
deadline
cancelToken
resolvedContextFingerprint
```

禁止使用全局 last error/全局 pending sender 作为唯一连接 owner。

### 6.6 RustDeskRelayDraft

三套 UI 不再直接构造 `RustDeskRelayConfig`，统一编辑一个无 Secret 日志投影的 draft：

```text
draftId
editingRelayId
entryPoint
setupMode                  import | simple | advanced
serverProfileHint
idServerHost/idServerPort
relayServerHost/relayServerPort
apiServerUrl
keyInput/keyMode
accountLoginRequested
dirtyFields
revision
```

约束：

- 端口在输入期保持字符串，失焦或提交时再解析，允许用户正常清空和修改；
- import/simple/advanced 最终进入同一个 normalizer 和 validator；
- Sheet 暂时关闭、账号切换、解锁跳转和前后台切换时保留内存草稿；
- 草稿不得写入云，不持久化明文共享 Key 或账号密码；
- 保存成功后才清理草稿；
- 对同一 `draftId + revision` 的重复提交必须幂等。

### 6.7 RustDeskRelaySaveResult

替换跨层 `boolean`：

```text
ok
saveAttemptId
stage                       validating | waiting_gate | committing | verifying
code
relayId
localCommitted
cloudSyncState              not_requested | pending | synced | failed
message
recoveryAction              unlock | retry | reopen | fix_field | switch_account | none
durationMs
```

保存失败码至少覆盖：

```text
invalid_id_server
invalid_id_port
invalid_relay_port
api_required
invalid_key
not_ready
restore_in_progress
owner_mismatch
unlock_required
record_missing
local_write_failed
metadata_write_failed
journal_write_failed
readback_missing
readback_mismatch
cancelled
```

CloudStore 是持久化失败码 owner；HostSync 只补充 `record_missing` 和内存投影阶段；
UI 只负责把稳定 code 映射为字段错误、动作按钮和脱敏详情，不重新猜根因。

### 6.8 RustDeskRelaySaveAttempt

保存状态机：

```text
idle
  → validating
  → waiting_gate
  → committing
  → verifying
  → saved

任一进行态 → failed/retryable
任一进行态 → cancelled
```

规则：

- `validating` 后按钮进入忙碌态，直到结果可判定；
- `waiting_gate` 仅用于有界等待数据库初始化/账号切换，不无限阻塞；
- `committing` 使用一个数据库事务；
- `verifying` 按 relay ID 重新查询，并校验非敏感字段和 Key fingerprint；
- `saved` 明确表示本地已保存；云同步另显示“等待同步/同步失败”，不能回滚本地成功；
- 旧 attempt 回调必须以 attemptId/draft revision 拒绝，不能覆盖新结果；
- 用户可在失败后保留全部输入并执行明确 recovery action。

## 7. P0 修复实施阶段

保存修复先于连接认证修复。只有配置能稳定本地保存、重启回读并生成可诊断结果后，
才允许进入 Server Pro Token 和 hbbs/hbbr 连接验收。

### Phase SAVE-0：先补可观察性并复现每个失败门

#### 目标

下一次真机失败无需猜测，日志能回答“在哪一阶段、以什么稳定错误码结束”，同时不泄露
地址、账号、Key 或 Token。

#### 任务

1. 每次点击生成 `saveAttemptId`，三个 UI 入口均使用同一格式。
2. 记录以下阶段事件：

```text
relay_save_started
relay_save_validation_finished
relay_save_gate_finished
relay_save_transaction_finished
relay_save_readback_finished
relay_save_finished
```

3. 每条日志只允许：
   - saveAttemptId；
   - entryPoint/setupMode；
   - new/edit；
   - stage/code；
   - durationMs；
   - relayId 的不可逆短 fingerprint；
   - owner generation/mutation gate/encryption ready 的布尔状态。
4. 禁止记录：
   - Key、Token、密码、用户名；
   - 完整 relay ID；
   - 完整 ID/Relay/API 地址；
   - 数据库 values bucket；
   - 服务端响应 body。
5. 把 `DataMutationResult` 在跨层返回前记录一次，在 UI 映射后记录一次；同一结果不得
   以多个互相矛盾的 code 结束。
6. 增加“复制诊断摘要”：

```text
App 1.0.9 (build/sha)
Save attempt: …
Entry: relay_management/simple
Stage: waiting_gate
Code: unlock_required
Local committed: no
Cloud sync: not_requested
```

#### 验收

- 人工触发每个保存失败码，真机日志能唯一定位；
- 日志扫描确认没有 Secret/完整 endpoint；
- 快速点击三次只有一个 committing attempt；
- 旧版现场“只有 Toast、无业务日志”的情况不再出现。

### Phase SAVE-1：结构化保存 API 贯通 UI、HostSync 与 CloudStore

#### 目标

消除 `boolean` 黑洞，建立唯一失败语义 owner。

#### 任务

1. `CloudStore.upsertRelay()` 提供结构化版本，原 boolean wrapper 仅在迁移期保留。
2. `HostSyncService.addRelay()`/`updateRelay()` 返回 `RustDeskRelaySaveResult`：
   - update Map 不存在时返回 `record_missing`；
   - CloudStore 失败原样传播 code/message；
   - 数据库成功后才更新内存 Map；
   - 内存投影失败不得伪装成本地数据库失败。
3. `RustDeskRelayPage` 不读取 `getLastMutationResult()` 全局槽作为常规路径；结果必须由
   当前函数直接返回，避免并发保存拿到别人的 last result。
4. `getLastMutationResult()` 只保留兼容/诊断用途，增加 attemptId 或移除全局歧义。
5. UI 映射稳定动作：

| Code | 主文案 | 主动作 |
|---|---|---|
| `unlock_required` | 数据已锁定，解锁后才能保存 | 去解锁 |
| `restore_in_progress` | 正在切换/恢复数据，请稍候 | 保留并重试 |
| `not_ready` | 本地数据尚未准备好 | 稍后重试 |
| `owner_mismatch` | 当前账号已变化，无法覆盖原记录 | 另存为当前账号 |
| `record_missing` | 这条配置已被删除或刷新 | 重新添加 |
| `*_write_failed` | 本地保存未完成 | 重试/复制诊断 |
| `readback_*` | 已写入但校验异常 | 重新载入/复制诊断 |

6. 字段校验失败定位到字段下方，不再只弹 Toast。

#### 验收

- 每个 CloudStore code 到页面一一对应；
- 两个并发 attempt 不串 last result；
- update 记录被删除时不再显示模糊保存失败；
- 所有失败保留 draft，成功才关闭或进入下一步。

### Phase SAVE-2：本地优先、原子事务与强一致回读

#### 目标

“保存”只承诺当前设备本地持久化；云同步异步、可失败、可重试，不阻断用户添加服务器。

#### 任务

1. 明确 mutation policy：
   - 云服务未配置、网络离线、云 bootstrap 失败时允许本地保存；
   - 只有本地恢复正在覆盖数据库、账号 owner 正在切换或加密锁定时暂时拒绝；
   - `startupSyncPending` 本身不得无限阻断普通本地新增；
   - 每个 gate 都有独立 code、开始时间和最大等待时间。
2. 保持以下操作为单个原子事务：
   - relay 行；
   - local control-plane profile metadata；
   - local mutation journal。
3. 明确 rollback 结果；commit 异常不得更新 HostSync 内存 Map。
4. commit 后立即按 relay ID 从数据库重新查询：
   - 记录存在；
   - owner 正确；
   - normalized endpoint/port/profile/key mode 正确；
   - Key 仅比较 fingerprint；
   - ResultSet 必须在所有分支关闭。
5. 再更新 HostSync 内存 Map，并按同一 ID 二次读取服务投影。
6. 云 push 排队失败时返回：

```text
ok=true
localCommitted=true
cloudSyncState=failed
```

页面显示“已保存到本机，云同步稍后重试”，不能显示保存失败。
7. 应用重启后再次读取，证明不是仅保存在内存。
8. 建立旧 profile metadata 缺失/损坏的迁移策略，不因 localmetadata 单点问题让旧 relay
   永久不可编辑。

#### 验收

- 无云、离线、云不可用均可保存和重启回读；
- 锁定时明确要求解锁，解锁后原草稿一键重试成功；
- 恢复/账号切换期间不写错 owner，完成后可重试；
- 任一事务子步骤失败都不留下半条记录；
- 快速重复保存不产生重复 relay；
- 不再出现“列表短暂出现、重进消失”。

### Phase SAVE-3：唯一 RustDeskServerSetup owner

#### 目标

三套表单共用一个 builder、validator、save coordinator 和 UI 状态机。

#### 任务

1. 新增纯策略层：

```text
RustDeskRelayDraftPolicy
RustDeskRelayImportPolicy
RustDeskRelayValidationPolicy
RustDeskRelaySaveCoordinator
```

2. `RustDeskRelayPage` 和 `RustDeskAddFlow` 只做入口壳与导航，不再各自实现保存。
3. 对 `ModernRelayAddFlow` 做 reachability 决策：
   - 若产品仍需它，改为复用 canonical flow；
   - 若不可达且无路线，单独提交删除；
   - 在确认前不让它继续成为第四种行为。
4. import/simple/advanced 使用同一 normalize：
   - scheme/host/IPv6；
   - 默认端口；
   - API URL；
   - Key 空白/格式；
   - server profile 推断；
   - 重复服务器检测。
5. 同一服务器从管理页、添加主机页和空状态入口添加，得到完全相同的模型与错误。
6. 保留入口意图：
   - 从“添加主机”进入，保存成功后返回主机表单并自动选中 relay；
   - 从“服务器管理”进入，保存成功后停留详情页；
   - 从地址簿登录进入，先保存服务器，再进入独立登录步骤。

#### 验收

- 搜索代码只能找到一个 save coordinator；
- 三入口 fixture 输出字节级等价的非时间字段；
- 后续新增 profile 只改策略和一个 UI；
- 无重复校验、重复默认值或重复错误文案。

### Phase SAVE-4：基于人因工程重做添加流程

#### 依据

遵循华为官方 [UX 设计指南](https://developer.huawei.com/consumer/cn/doc/design-guides/ux-guidelines-overview-0000001760867048)
与 [HarmonyOS 设计开发入门](https://developer.huawei.com/consumer/cn/design/devstart/) 中的
任务导向、清晰反馈、一致性、渐进披露和多设备体验原则；同时遵循 RustDesk 官方
[Client Configuration](https://rustdesk.com/docs/en/self-host/client-configuration/) 对
ID Server、Relay Server、API Server 和 Key 的字段边界。

#### 默认用户路径

首页动作只保留：

```text
添加 RustDesk 服务器
  ├─ 粘贴/扫描配置（推荐）
  └─ 手动填写
```

粘贴配置后先展示可理解的摘要：

```text
服务器          example.com
中继            自动使用 example.com:21117
服务器公钥      已识别 · 末 6 位 fingerprint
地址簿登录      可选，保存后设置
```

手动填写默认只显示：

| 字段 | 默认行为 | 必填 |
|---|---|---|
| 服务器地址 | 接受域名、IPv4、带括号 IPv6；默认 ID 端口 21116 | 是 |
| 服务器公钥 | 支持粘贴/扫码；只显示 fingerprint，不回显完整值 | 自建默认是 |

主按钮只有一个：`保存服务器`。

保存成功后的结果页：

```text
服务器已保存到本机
[连接测试]  [登录地址簿（可选）]  [完成]
```

“连接测试”不是保存前置条件；用户即使离线也能先保存。Pro/API 登录失败不得撤销已保存
服务器。

#### 自动推导

- Relay Host 默认等于 ID Server；
- ID 端口默认 21116；
- Relay 端口默认 21117；
- API 地址只有用户选择“登录地址簿”或导入配置包含 API 时才出现；
- server profile 由导入字段、能力探测和 adapter 选择，不让普通用户直接选择内部枚举；
- third-party API 默认 `third_party_api_only`，不得因“能登录地址簿”自动推断 connect Token；
- 官方公共服务器与任意自建服务器严格区分，空 Key 不静默套用官方服务器 Key；
- 发现同 endpoint/key fingerprint 的已有配置时提供“使用已有/更新”，不重复新建。

#### 高级设置

仅在用户展开“高级设置”后显示：

- ID Server 独立地址/端口；
- Relay Server 独立地址/端口；
- API Server；
- public key/shared key 模式；
- 连接策略（功能完成前只显示实际可用选项）；
- 自定义 control-plane compatibility（开发者开关二次确认）。

普通界面不显示：

```text
oss_key_only
oss_shared_access_key
official_server_pro_token
third_party_api_only
third_party_control_plane
direct_ip
```

这些值只出现在脱敏诊断摘要或开发者模式。

#### 交互细节

1. 保存只有一个提交边界，删除保存后的“确定保存”。
2. 端口输入允许为空；失焦时给建议，提交时才阻止非法值。
3. 错误贴近字段，首个错误自动聚焦并滚入可视区域。
4. 主按钮在 committing/verifying 时禁用并显示进度；触控目标至少 44vp。
5. 返回/关闭时只有 dirty draft 才询问是否放弃。
6. 解锁、账号切换或登录跳转回来后恢复滚动位置、焦点和 draft。
7. Key 输入支持粘贴和扫码，不做自动大小写/空白破坏；提供“这不是许可证 Key”的说明。
8. 屏幕阅读器朗读标签、必填、错误、保存状态；颜色不作为唯一状态提示。
9. 手机采用全屏/大 Sheet 单列；宽屏双栏只改变布局，不改变字段顺序和提交语义。
10. Toast 只用于短暂成功反馈；需要用户行动的失败使用可停留状态区和动作按钮。

#### 验收指标

- OSS 标准服务器从入口到本地保存：不超过 2 个用户输入、1 次提交；
- 导入有效配置：1 次粘贴/扫码、1 次提交；
- Pro 用户先保存再登录，登录失败不丢配置；
- 新用户不理解 control-plane/profile 也能完成；
- 专家仍可在高级设置独立配置全部 endpoint；
- 5 名内部走查者首次完成率 100%，无一人误把 API 登录成功当作 relay 保存成功；
- 重复点击、旋转/窗口变化、前后台、无网、解锁跳转均不丢 draft。

### Phase SAVE-5：保存专项测试、迁移与发布阻断

#### 自动化矩阵

| 维度 | 覆盖值 |
|---|---|
| 入口 | 管理页、添加主机、空状态/现代入口 |
| 操作 | 新增、编辑、重复点击、删除后编辑 |
| 数据状态 | ready、not_ready、restore、owner switch、locked/unlocked |
| 网络/云 | 无云、离线、云失败、云成功 |
| profile | OSS public/shared、official Pro、third-party API-only/custom |
| 输入 | import、simple、advanced、IPv4、IPv6、域名、自定义端口 |
| 生命周期 | 关闭 Sheet、后台/前台、进程重启、旧回调晚到 |
| 结果 | 每个 DataMutationCode、readback missing/mismatch |

#### 必须新增的测试

- `CloudStore.upsertRelay` 每个失败分支；
- `HostSyncService` 结构化结果传播；
- add/update 内存 Map 与数据库顺序；
- relay/profile/journal 原子 rollback；
- commit 后 read-back；
- 应用重启 read-back；
- duplicate tap/idempotency；
- draft 保留和 attempt generation；
- 三入口同 draft 同输出；
- 旧 relay/profile metadata 迁移；
- 日志 Secret 扫描；
- UI 可访问性与关键宽度快照/真机走查。

#### 发布阻断

以下任一出现，不得发布 RustDesk 修复版本：

- 仍能显示无动作的“中继服务器保存失败”；
- 本地保存依赖云登录或网络；
- 保存后重启消失；
- 一次操作生成重复 relay；
- 锁定/恢复/owner 错误仍被压成 boolean；
- 任一入口继续维护独立保存逻辑；
- 诊断日志包含 endpoint、Key、Token、密码或用户名。

### Phase P0-0：版本、诊断和现场可判定性

#### 目标

先让每个现场结果可确认使用的是哪份代码、哪个 profile、是否送出 Token、失败在哪一层。

#### 任务

1. 不复用已被前序交付占用的 `1.0.9` 作为唯一现场证据；开发 checkpoint 增加 build
   identity，正式修复版本使用 `1.0.10`/`1000010` 或当时尚未占用的更高版本。
2. 增加非敏感 build identity：
   - app version；
   - Git short SHA；
   - FFI ABI version；
   - protocol fixture version；
   - build time。
3. 每次连接生成 attemptId。
4. ArkTS/NAPI/C++/Rust 统一日志字段：
   - profile；
   - strategy；
   - key mode；
   - token present/absent；
   - token generation；
   - endpoint/port；
   - stage/code。
5. 日志不包含 Token、密码、完整 key、真实 API 响应 body。
6. 增加可复制的“脱敏诊断摘要”，不导出原始隐私日志。

#### 验收

- 两个都显示 1.0.8 的旧 HAP 不再参与新验收；
- 用户能提供准确 build ID；
- 同一 attempt 在四层有一致 ID；
- 能回答“请求是否携带 Token”而无需读取 Token。

### Phase P0-1：统一连接上下文 resolver

#### 目标

消除 host source gate 和多个页面重复投影。

#### 任务

1. 新建纯策略 resolver：
   - 不访问 UI；
   - 输入不可变快照；
   - 输出不可变 context；
   - 单元测试覆盖所有 profile/source/strategy。
2. 删除/停止使用以下判断作为 Token 决策：

```text
host.rustdeskProManaged && host.sourceType === 'rustdesk_pro'
```

3. Token 决策只依赖：
   - server profile；
   - account binding；
   - login status；
   - token generation；
   - strategy 非 direct；
   - adapter 能力。
4. HostList、RemoteDesktop、preflight、file transfer 统一调用 resolver。
5. 手工 Server Pro 主机必须绑定账号：
   - 可以保存为未绑定；
   - 连接时要求选择当前服务器账号；
   - 不允许静默空 Token。
6. 地址簿 API-only 主机即使 `sourceType=rustdesk_pro` 也不向 hbbs 发送 Token。

#### 建议文件

- 新增：
  `entry/src/main/ets/services/RustDeskConnectionContextPolicy.ets`
- 修改：
  `RustDeskControlPlanePolicy.ets`
  `HostListPage.ets`
  `RemoteDesktop.ets`
  `RustDeskProConnectionPreflightPolicy.ets`
  `RustDeskProModels.ets`
  对应 tests

#### 验收

- official Pro：手工/地址簿均 token present；
- API-only：手工/地址簿均 token absent；
- direct：任何 profile token absent；
- ordinary/admin 只改变 Token 内容/权限，不改变 wire 字段结构；
- 四个入口 resolved context 一致。

### Phase P0-2：Token 生命周期与失效边界

#### 目标

有效 HTTP 会话不因 relay 英文错误被清除，旧连接不影响新登录。

#### 任务

1. account session 增加/确认：
   - token fingerprint；
   - generation；
   - issuedAt/observedAt；
   - login status；
   - server/account/relay binding。
2. native 失败回传：
   - attemptId；
   - stage；
   - code；
   - detail；
   - token generation（不含 Token）。
3. `markConnectionSessionExpired()` 只接受：
   - 官方/已验证 profile；
   - 结构化 control-plane session-expired；
   - 或 HTTP API 401/明确语义 403；
   - fingerprint/generation 与失败 attempt 相同。
4. 以下永不清 Token：
   - exact phrase；
   - relay refusal；
   - access denied；
   - wrong key；
   - network timeout；
   - old generation；
   - third-party unknown response。
5. 重新登录递增 generation；所有旧 attempt 的过期回调被忽略。
6. logout 明确撤销当前 generation 并取消 pending attempt。

#### 验收

- `please login!` 后账号仍显示 logged_in；
- 地址簿仍可刷新；
- 重新登录后的新 Token 不被旧请求清除；
- HTTP 401 正确进入 expired；
- access denied 保持 logged_in。

### Phase P0-3：普通用户、管理员与 Access Control

#### 目标

证明普通用户不依赖管理员权限，权限错误得到正确诊断。

#### 真实账号矩阵

| 账号 | 目标 | 预期 |
|---|---|---|
| 管理员 | 可访问设备 | 成功 |
| 普通用户 | 自己设备 | 成功 |
| 普通用户 | 个人地址簿设备 | 成功 |
| 普通用户 | 共享地址簿设备 | 成功 |
| 普通用户 | user group 允许设备 | 成功 |
| 普通用户 | device group 允许设备 | 成功 |
| 普通用户 | 未授权设备 | access_denied |
| disabled user | 任意设备 | user_disabled |
| 任意用户 | disabled device | device_disabled |
| 未登录 | Not Logged 允许 | 按策略连接 |
| 未登录 | Not Logged 禁止 | login_required |

每格组合：

- password；
- request approval；
- Peer 2FA；
- FORCE_RELAY；
- 后续 AUTO；
- file transfer。

#### 规则

- Admin Role 不参与客户端连接资格判断；
- Access Control 拒绝不能归类 session expired；
- Control Role 只修改连接后的能力；
- `ControlPermissions` 必须投影到键鼠、剪贴板、文件、音频等 UI；
- 不允许以管理员成功替代 ordinary user 验收。

### Phase P0-4：rendezvous/control-plane wire 合同

#### 目标

让每种 profile 的 protobuf 字段可测试、可解释。

#### 纯函数 builder

建议拆分：

```text
build_punch_hole_request()
build_request_relay()
build_hbbr_relay_handshake()
build_direct_peer_login()
```

输入均显式，不读取全局账号或 host。

#### PunchHoleRequest 断言

- id；
- nat_type；
- licence_key；
- token；
- conn_type；
- version；
- udp_port；
- force_relay；
- upnp_port；
- socket_addr_v6。

#### RequestRelay 断言

- id；
- uuid；
- socket_addr；
- relay_server；
- secure；
- licence_key；
- conn_type；
- token；
- control_permissions。

#### fixture

使用假凭据保存序列化 fixture：

- OSS public key；
- OSS shared key；
- official Pro admin；
- official Pro ordinary；
- third-party API-only；
- custom control-plane；
- empty/expired token；
- direct。

#### 安全约束

- 不通过版本字符串伪装官方客户端；
- 不为通过测试关闭签名验证；
- 不把 Token 填入 licence_key；
- 不把公钥当 Pro license key；
- secure TCP 失败不静默回落 plain。

### Phase P0-5：Server Pro 与超享 adapter

#### OfficialServerProAdapter

负责：

- API URL 正规化；
- login request/response；
- ordinary/admin 同一 token handoff；
- HTTP 401/403；
- address book endpoints；
- control-plane token；
- 版本 capability；
- 后续账号 2FA/challenge。

必须以目标 Server Pro 固定版本验证，不以兼容面板成功替代。

#### ThirdPartyApiOnlyAdapter

负责：

- HTTP login；
- address book；
- token 仅用于 HTTP；
- relay 使用 OSS key-only；
- control-plane failure 不修改 HTTP login status。

#### ThirdPartyControlPlaneAdapter

仅在存在以下证据后启用：

- 版本化协议；
- connect token 来源；
- refresh/expiry；
- PunchHoleRequest/RequestRelay 字段；
- secure TCP 要求；
- ordinary/admin 行为；
- 真实 endpoint A/B。

超享当前先按未知能力处理：

1. API-only/key-only；
2. custom control-plane/token；
3. ordinary/admin；
4. official client FORCE_RELAY；
5. HarmonyOS FORCE_RELAY；
6. 服务端是否返回相同错误。

如果卖方/面板无日志和协议，不把猜测固化为默认产品逻辑。

### Phase P0-6：错误合同

#### 阶段

```text
account_http_login
address_book_http
resolving
nat_test
rendezvous_connect
rendezvous_secure
control_plane_punch
control_plane_relay_request
direct_candidate
relay_endpoint
peer_channel
peer_login
peer_2fa
session_stream
file_transfer
```

#### 稳定错误码

```text
account_not_logged_in
account_token_expired
account_token_rejected
control_plane_login_required
control_plane_incompatible
access_denied
user_disabled
device_disabled
server_key_mismatch
shared_key_mismatch
peer_not_found
peer_offline
direct_failed
relay_request_failed
relay_endpoint_failed
peer_channel_failed
wrong_password
approval_timeout
peer_2fa_required
peer_2fa_wrong
network_changed
cancelled
deadline_exceeded
```

#### 用户文案规则

- 首句给出真实层级；
- 第二句给出可操作建议；
- 诊断详情可展开；
- 不把原始敏感服务端响应直接弹出；
- password/approval 只有进入 peer_login 后才出现对应文案。

### Phase P0-7：真实端点闭环与 RustDesk 修复版本发布

#### 必测

- 官方 OSS public key；
- 官方 OSS shared `-k`；
- 官方 Server Pro 至少两个目标版本；
- ordinary/admin；
- personal/shared/group/denied；
- 超享 ordinary；
- 地址簿/手工；
- password/approval/Peer 2FA；
- token absent/present；
- relay default/custom port；
- screen/file transfer；
- API 23 真机。

#### 发布条件

- 版本与前序 1.0.9 可区分，目标为 1.0.10/1000010 或更高未占用版本；
- build fingerprint 可见；
- 用户问题两个 endpoint 均有结果；
- 失败也必须是准确的新错误，不允许仍显示虚假 expired；
- reviewer 通过；
- 所有强制门禁通过。

## 8. 官方连接行为对齐路线

### Phase A：连接策略三态

#### 数据模型

```text
auto
force_relay
direct_ip
```

#### FORCE_RELAY

保持 P0 可诊断路径：

```text
resolve → hbbs → secure/control-plane → relay approval → hbbr → peer
```

#### DIRECT_IP

直接连接 Peer endpoint，不经过：

- API account；
- hbbs；
- hbbr；
- address-book token。

当前默认直连端口和官方 controlled Peer listener 行为必须使用真实官方客户端/Peer验证，
不能只依据 hbbs Web 端口号推断。

#### AUTO

不能仅把 `force_relay` 设为 false。必须在 Phase B 完成后启用。

### Phase B：真实 NAT 与 TCP hole punching

#### 能力

- 21115 NAT test；
- 21116 UDP registration/heartbeat；
- 21116 TCP connection/hole punching；
- actual nat_type；
- local/public/IPv6 候选；
- UDP disabled/TCP-only profile；
- timeout/cancel；
- direct success；
- fallback relay。

#### native 所有权

- Rust socket 状态机拥有 socket；
- ArkTS Network Kit 只通知 network generation；
- 不把 socket/handle 放 TaskPool；
- 每个 attempt 使用独立取消令牌；
- 网络切换使旧 candidate 失效。

#### 候选状态机

```text
Resolving
→ DetectingNat
→ RequestingPeer
→ CollectingCandidates
→ RacingDirectCandidates
→ DirectConnected

RacingDirectCandidates
→ DirectDeadline
→ RequestingRelay
→ ConnectingRelay
→ RelayConnected
```

#### 候选策略

- 已验证 IPv6；
- 同网/LAN；
- public TCP；
- server-provided peer address；
- 受限并发；
- 首个完成者胜出；
- 关闭其余 socket；
- 不复用旧 network generation。

### Phase C：relay fallback 和多节点

- hbbs 广告 endpoint 优先；
- 配置 relay 仅 fallback；
- explicit port/IPv6；
- 多 relay；
- Geo relay；
- 节点 key fingerprint；
- node A 失败转 node B；
- UUID 重新申请；
- screen/file transfer 一致；
- WebSocket relay 单独 profile；
- WSS 失败不误称 P2P。

### Phase D：网络变化和重连

HarmonyOS `NetConnection` 事件：

- netAvailable；
- netLost；
- capabilities change。

重连规则：

- pending connect：取消旧 generation，重新 resolve；
- connected direct：尝试有界恢复，失败转 relay；
- connected relay：重新申请 UUID；
- background：保持已有会话，延迟非必要重试；
- foreground：校验 socket/stream generation；
- destroy：取消全部。

## 9. Peer 加密、认证与权限对齐

### 9.1 加密

- SignedId；
- PublicKey；
- Ed25519 verify；
- X25519 channel；
- nonce/sequence；
- partial frame timeout；
- replay/duplicate；
- key rotation；
- peer key change；
- public/shared key 降级边界；
- plain fallback 安全提示；
- 敏感内存清理。

### 9.2 Peer login

- Hash challenge；
- permanent/temporary password；
- request approval；
- Peer 2FA；
- Wrong 2FA Code；
- trusted device（后续独立、安全默认关闭）；
- OS Login；
- Windows Sessions；
- login screen；
- rate limit/lockout；
- exact peer errors。

### 9.3 权限

完整处理 `ControlPermissions`：

- keyboard/mouse；
- printer；
- clipboard；
- file；
- audio；
- camera；
- terminal；
- tunnel；
- restart；
- recording；
- block input；
- remote modify；
- privacy mode。

权限禁用只关闭对应能力，不把会话整体判为失败。

## 10. 视频、显示与性能对齐

### 10.1 codec

- RGB compressed/uncompressed；
- YUV/chroma；
- VP8；
- VP9；
- AV1；
- H.264；
- H.265；
- encoded frame batch；
- codec ability；
- supported encoding/decoding；
- hardware/software decode；
- failure downgrade；
- keyframe refresh。

### 10.2 显示

- PeerInfo display catalog；
- multi-monitor；
- switch/follow/capture displays；
- dynamic resolution；
- rotation；
- Android orientation；
- virtual display；
- privacy mode；
- cursor hotspot/cache；
- DPI/coordinate transform。

### 10.3 流控制

- fps/quality；
- latency；
- decode pressure；
- render pressure；
- keyframe starvation；
- background/foreground；
- Surface generation；
- dropped/replaced/presented；
- audio alive/video stalled；
- bounded queues。

## 11. 输入对齐

### 11.1 键盘

- Legacy/Map/Translate；
- Windows scancode；
- macOS virtual key；
- Linux/X11/Wayland差异；
- left/right modifiers；
- AltGr；
- lock keys；
- IME composition/commit；
- Unicode/emoji；
- dead key；
- Ctrl+Alt+Delete；
- Alt+Tab/Meta；
- focus loss release；
- reconnect cleanup。

### 11.2 鼠标/触控

- absolute/relative；
- left/middle/right/x buttons；
- vertical/horizontal/high-resolution wheel；
- touch pointer IDs；
- TouchScale/Pan lifecycle；
- pinch/pan/right-click；
- remote Android touch mode；
- local canvas zoom；
- orientation/surface recreation；
- virtual mouse/joystick；
- permission disabled。

## 12. 剪贴板、文件、音频与扩展

### 12.1 剪贴板

- UTF-8 text；
- MultiClipboards；
- image/HTML/RTF；
- cliprdr；
- file clipboard；
- size/chunk limits；
- loop suppression；
- one-way policy；
- initial sync；
- background permission。

### 12.2 文件传输

- upload/download；
- directory；
- empty dirs；
- rename/delete/create；
- overwrite/skip；
- digest；
- resume；
- cancel；
- concurrent jobs；
- large files；
- Unicode/path traversal；
- one-way policy；
- background live task；
- screen/file relay consistency。

### 12.3 音频

- AudioFormat；
- Opus；
- channels/rate/frame duration；
- jitter/loss；
- AV sync；
- output switch；
- mute/volume；
- background audio；
- mic upstream；
- voice call。

### 12.4 后续扩展

- chat；
- camera；
- terminal；
- TCP tunnel；
- screenshot；
- switch sides；
- elevation/UAC；
- remote restart；
- recording；
- plugins；
- remote printer。

未实现项在 capability 中返回 false，不创建空壳入口。

## 13. 测试架构

### 13.1 中继保存专项

- 每个 `DataMutationCode` 直接返回到 UI；
- add/update/delete-race；
- relay/profile/journal 原子事务和 rollback；
- commit 后数据库回读、HostSync 投影回读、进程重启回读；
- 无云/离线/cloud push failure；
- database not ready/restore/owner switch/encryption lock；
- duplicate tap/idempotency/late callback；
- draft retention/navigation/lifecycle；
- import/simple/advanced normalization；
- 管理页/添加主机页/现代入口等价；
- Secret 日志扫描；
- 字段级错误、焦点、读屏、窄屏和宽屏真机走查。

### 13.2 Rust 单元

- request builder；
- protobuf fixture；
- endpoint parser；
- NAT state；
- candidate race；
- relay fallback；
- token absent/present；
- error mapping；
- cancellation；
- partial frame；
- encryption；
- Peer auth；
- permission；
- file/control queues。

### 13.3 fake hbbs/hbbr/Peer

必须提供可控 fixture：

- require token；
- reject empty/invalid/expired；
- ordinary/admin；
- access denied；
- `please login`；
- relay uuid；
- explicit/fallback port；
- multi relay；
- direct success/fail；
- Peer password/approval/2FA；
- network stall/partial frame。

### 13.4 ArkTS

- relay draft/normalizer/validator；
- structured save result；
- save attempt state machine；
- CloudStore/HostSync result propagation；
- read-back/idempotency；
- resolver；
- migration；
- profile；
- account binding；
- generation；
- no cloud/backup profile；
- ordinary user UI；
- capability UI；
- lifecycle；
- error copy；
- version/build identity。

### 13.5 C/C++/NAPI/ABI

- repr(C) layout；
- ABI version；
- old caller；
- string lifetime；
- callback ownership；
- concurrent sessions；
- cancel/destroy；
- arm64-v8a；
- x86_64；
- symbol export。

### 13.6 真实端点

| 服务端 | 账号 | 主机来源 | 策略 | Peer Auth |
|---|---|---|---|---|
| OSS public key | 无 | 手工 | Auto/Relay/Direct | password/approval/2FA |
| OSS shared key | 无 | 手工 | Auto/Relay | password |
| Server Pro | admin | addressbook/manual | Auto/Relay | all |
| Server Pro | ordinary | addressbook/manual | Auto/Relay | all |
| Server Pro | denied ordinary | addressbook/manual | Relay | access denied |
| 超享 | ordinary | addressbook/manual | Relay | password/approval |
| Direct Peer | 无 | manual | Direct | password/2FA |

### 13.7 网络矩阵

- 同 LAN；
- 不同 LAN；
- cone NAT；
- symmetric NAT；
- CGNAT；
- IPv6；
- UDP blocked；
- TCP 21116 blocked；
- relay blocked；
- Wi-Fi→蜂窝；
- VPN；
- background/foreground；
- server restart；
- repeated connect/disconnect。

### 13.8 官方客户端黑盒对照

同一：

- server；
- account；
- Peer；
- network；
- strategy；
- auth；
- time window。

对比：

- direct/relay；
- request success；
- latency；
- permissions；
- user-visible error；
- server-visible sanitized fields。

不保存官方客户端私有流量中的真实 Token，不提交真实抓包。

## 14. 数据迁移

### 14.1 旧 relay

- 无 profile → `oss_key_only`/现有 key mode 推导，但 control-plane 默认 key-only；
- 共享 `-k` key mode → `oss_shared_access_key`，不得与 Ed25519 公钥合并；
- `addressbook_only_custom` → `third_party_api_only`；
- 原明确 Pro relay → `official_server_pro_token`，需要当前设备重新确认账号；
- `custom_control_plane`/advanced → 无本机 capability 证明时不自动升级为
  `third_party_control_plane`；
- profile 继续 localmetadata；
- 不写云字段；
- 首次读取执行 normalization，但不因 API 空或 profile metadata 缺失删除旧记录；
- endpoint/key fingerprint 重复项只提示合并，不自动覆盖；
- 迁移后必须完成数据库、HostSync 和重启三次回读；
- 迁移失败保留原记录，并给出结构化只读/修复状态。

### 14.2 旧 host

- 地址簿 host 保留 source/binding；
- 手工 host 保留 relayId；
- official Pro 手工 host 首次连接要求选择 account；
- direct host 迁移 strategy；
- 不改 Peer ID；
- 不复制 Token。

### 14.3 失败回滚

- resolver v2 可通过 feature flag 关闭；
- 原记录仍可读；
- Token 不落 host，因此无敏感回滚；
- AUTO 可回退 FORCE_RELAY；
- error classifier 不回滚到字符串清 Token。

## 15. 发布路线

### Release 1：1.0.10 P0（若该版本在发布时仍未占用）

- build identity；
- 中继本地保存结构化结果和强一致回读；
- 无云/离线保存、锁定/恢复/owner 明确恢复动作；
- 单一 RustDesk server setup owner；
- 默认“导入或地址+公钥”的渐进披露流程；
- 草稿保留、幂等提交和脱敏诊断摘要；
- unified resolver；
- source-independent token；
- ordinary user；
- exact expiry；
- profile adapter；
- structured errors；
- FORCE_RELAY/DIRECT 保持；
- 真实 Server Pro/超享验收。

### Release 2：1.1.x 连接对齐

- NAT test；
- TCP hole punching；
- AUTO；
- IPv6；
- relay fallback；
- network change；
- retry/cancel；
- 多 relay。

### Release 3：1.2.x 会话对齐

- encryption hardening；
- permissions；
- login variants；
- trusted device gated；
- file/clipboard；
- lifecycle。

### Release 4：1.3.x 媒体/输入对齐

- codec matrix；
- hardware decode；
- display；
- input；
- audio；
- performance。

### Release 5：后续扩展

- terminal/tunnel/camera/voice/recording/plugins。

## 16. 代码影响范围与提交边界

### 16.1 预计文件

ArkTS：

- `pages/RustDeskRelayPage.ets`
- `components/hostadd/RustDeskAddFlow.ets`
- `components/resourceadd/modern/ModernRelayAddFlow.ets`（复用或确认删除）
- `services/HostSyncService.ets`
- `services/CloudStore.ets`
- `services/CloudStoreMutationPolicy.ets`
- 新 `services/RustDeskRelayDraftPolicy.ets`
- 新 `services/RustDeskRelayValidationPolicy.ets`
- 新 `services/RustDeskRelaySaveCoordinator.ets`
- 新 `models/RustDeskRelaySaveResult.ets`（或并入现有 relay model）
- `RustDeskControlPlanePolicy.ets`
- 新 `RustDeskConnectionContextPolicy.ets`
- `RustDeskProApiPolicy.ets`
- `RustDeskProApiService.ets`
- `RustDeskProConnectionPreflightPolicy.ets`
- `RustDeskRelayConfig.ets`
- `HostListPage.ets`
- `RemoteDesktop.ets`
- NAPI type declarations
- `entry/src/test/HostSyncService.test.ets`
- `entry/src/test/CloudStore*.test.ets`
- 新 relay draft/validation/save/UI policy tests

Native：

- `extension_loader_napi.cpp`
- `protocol_adapter.h`
- `rustdesk_bridge.*`

Rust：

- `lib.rs`
- `connector.rs`
- `net.rs`
- `protocol/rendezvous.rs`
- `protocol/session.rs`
- 建议新增 `connection_strategy.rs`
- 建议新增 `nat.rs`
- 建议新增 `control_plane.rs`
- 建议新增 `error.rs`

文档/合规：

- release notes/version；
- CURRENT/QUEUE；
- protocol upstream/provenance；
- NOTICE/SBOM/hash（仅发生依赖/proto变化时）。

### 16.2 建议提交

1. `chore(release): identify rustdesk save and control-plane repair builds`
2. `test(rustdesk): reproduce relay persistence failure codes`
3. `fix(rustdesk): propagate structured relay save results`
4. `fix(rustdesk): verify local relay commits and readback`
5. `refactor(rustdesk): centralize server setup and validation`
6. `feat(rustdesk): simplify relay onboarding and preserve drafts`
7. `refactor(rustdesk): centralize resolved connection context`
8. `fix(rustdesk): bind tokens to control-plane profiles`
9. `fix(rustdesk): preserve valid sessions on relay rejection`
10. `test(rustdesk): cover ordinary server pro users`
11. `test(rustdesk): add rendezvous wire fixtures`
12. `feat(rustdesk): expose explicit connection strategies`
13. `feat(rustdesk): implement nat detection and direct fallback`
14. `feat(rustdesk): align relay failover and network recovery`
15. 后续按媒体/输入/文件独立提交。

每个提交只暂存任务文件，不使用 `git add -A`。实施开始时必须基于清晰交接后的独立任务
分支，不能混入当前 cloud lifecycle、SSH、Moonlight、VNC 或其他用户修改。

## 17. 安全、隐私和许可证

- HTTP password 只用于登录请求，不持久化明文；
- access token 不进入 host/cloud/portable backup/log；
- fingerprint 使用不可逆 hash；
- Peer password/TOTP/code 不进入诊断；
- real endpoint/log/screenshot 不提交；
- public/shared key 明确标注；
- Asset Store 迁移另立 ADR；
- 用户认证只授权本地读取，不替代服务器认证；
- 独立实现基于协议和行为，不复制官方核心；
- 更新 proto/依赖同步许可证、NOTICE、SBOM、provenance；
- RustDesk 官方名称/Logo 不用作“官方客户端”误导性品牌。

## 18. 强制工程门禁

任何后续代码、测试、配置、流程或文档改动完成前必须执行：

```sh
source scripts/macos_env.sh
hvigorw --mode module -p module=entry -p product=default \
  default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon
hvigorw --mode module -p module=entry -p product=default \
  assembleHap --analyze=normal --parallel --incremental --no-daemon
```

附加：

- `cargo check --tests`
- focused Rust tests
- `bash scripts/build_rustdesk_ffi_ohos.sh all`
- native tests
- ArkTS tests
- `git diff --check`
- Light compliance
- API 23 device
- real endpoints
- independent reviewer

`ohosTest@OhosTestCompileArkTS` 当前任务未注册（`00306054`）时必须记录 blocker，
不能宣称通过。

### 18.1 v3.1 计划文档更新验证记录

2026-07-29 在 `codex/cloud-data-lifecycle-root-fix@d2f365c32` 执行：

- Markdown/whitespace：`git diff --no-index --check /dev/null <本计划>` 通过；
- 工作树 tracked diff：`git diff --check` 通过；
- 开源合规 Light：通过；
- `default@OhosTestCompileArkTS`：最终通过；
- `assembleHap`：最终通过。

验证期间当前活动 cloud lifecycle 工作仍在变化。早期重复执行时曾观察到：

```text
CryptoLifecyclePolicy.ets:168,186,210,229
  arkts-no-spread

早期一次 OhosTestCompileArkTS：
HostListPage.ets:7749–7796
  CloudStore.setCryptoStatus()/clearCryptoParams() 尚不存在
```

这些错误均在当前活动任务继续更新后消失。本次 RustDesk 任务没有修改上述代码文件；
随后针对同一份最新工作树重新执行，两项 Hvigor 均成功。早期失败保留在记录中，用于说明
验证曾跨越变化中的工作树，不作为 RustDesk 文档缺陷或最终 blocker。正式实施 RustDesk
前仍需先完成 cloud lifecycle 分支交接，并在每个提交后重新执行全部门禁。

### 18.2 v3.2 正式实施校准

2026-07-30 已确认：

- `main@d0e6ffee2`，相对 `origin/main` 领先 147；
- VNC V2/D-020 已完成、快进合并并清理，活动任务分支在创建前为 `none`；
- 从本地 `main` 创建唯一分支 `codex/rustdesk-control-plane-v3`；
- 当前源码版本为 `1.0.9`/`1000009`，不能作为本次 RustDesk 修复的唯一 build 证据；
- `RustDeskRelayPage -> HostSyncService -> CloudStore` 仍把结构化
  `DataMutationResult` 压成 boolean，commit 后没有稳定 ID 强制回读；
- `HostListPage`/`RemoteDesktop` 仍以 `sourceType === 'rustdesk_pro'` 和
  `rustdeskProManaged` 作为 Token 投影门槛；
- rendezvous native 仍固定 `nat_type=SYMMETRIC`、`force_relay=true`，
  `punch_hole()` 仍 fail-closed 为 unsupported；
- 官方配置文档再次确认 ID Server + Ed25519 公钥是标准自建配置，API Server 用于 Pro
  登录，Relay 可由 ID Server 推导；高级设置明确区分 direct、UDP punch、relay 等选项；
- 本节对应的实际双 Hvigor、Light、diff 门禁结果在本次计划提交前补录到 Git 提交证据，
  不沿用 v3.1 旧 session 的成功记录。

## 19. Definition of Done

### 19.1 用户问题 P0 完成

以下全部满足：

1. 版本/build 可区分；
2. 管理页、添加主机页和保留的现代入口都能新增/编辑中继；
3. 标准 OSS 添加默认不超过“地址+公钥”两个输入和一次保存；
4. 每个 `DataMutationCode` 到达 UI，并提供正确 recovery action；
5. 无云、离线和 cloud push 失败时仍能本地保存；
6. `unlock_required`、恢复中和 owner 切换不会再显示通用保存失败；
7. relay/profile/journal 保持原子，任一失败无半条数据；
8. commit 后数据库、HostSync、应用重启三层回读一致；
9. 重复点击不重复写入，晚到回调不覆盖新 attempt；
10. 失败、解锁跳转和生命周期变化不丢 draft；
11. 保存成功与地址簿登录/连接测试完全解耦；
12. 现场能复制不含 Secret 的 save/connect 诊断摘要；
13. 代码中只有一个 relay save coordinator/validator；
14. ordinary user HTTP login 成功；
15. ordinary user address book 成功；
16. addressbook host password 成功；
17. addressbook host approval 成功；
18. manual Pro host 使用同账号成功；
19. admin 与 ordinary wire 字段结构一致；
20. denied ordinary 返回 access_denied；
21. `please login` 不清 Token；
22. HTTP 401/验证过的 expiry 才清 Token；
23. third-party API-only 不送 control-plane Token；
24. official Pro 正确送 Token；
25. screen/file transfer 一致；
26. Server Pro 和超享真实 endpoint 有结果；
27. API 23 真机通过；
28. 双 ABI、Hvigor、HAP、合规通过；
29. reviewer 无 P0/P1。

### 19.2 AUTO/P2P 完成

1. nat_type 不再固定；
2. direct 成功可证明；
3. direct 失败自动 relay；
4. symmetric/CGNAT 可 relay；
5. IPv6 可判定；
6. UDP blocked TCP-only 可用；
7. network change 不串旧 attempt；
8. 官方客户端黑盒结果在支持矩阵内一致；
9. FORCE_RELAY 和 DIRECT 始终可回滚。

### 19.3 官方功能对齐完成

每个功能必须标记为：

```text
aligned
partially_aligned
unsupported_fail_closed
blocked_by_platform
blocked_by_server_contract
```

只有：

- wire fixture；
- 单元/集成；
- 真实 Peer；
- API 23；
- 生命周期；
- 权限；
- 错误；

全部有证据，才能标记 aligned。

## 20. 首轮实施顺序

严格按以下顺序开始，不先做大规模 P2P：

1. 为当前保存路径补 saveAttemptId 和阶段日志，复现全部 gate；
2. 以自动化测试固定 `boolean` 丢失失败码和重复点击问题；
3. 贯通 `RustDeskRelaySaveResult`；
4. 修复 local-first、原子事务和 commit 后 read-back；
5. 三入口统一为一个 setup/save coordinator；
6. 上线导入优先、手工“地址+公钥”、高级折叠的新流程；
7. 完成无云/离线/锁定/恢复/账号切换/重启矩阵；
8. 增加 build identity；正式发布时升级为 1.0.10/1000010 或更高未占用版本，形成
   “中继能可靠保存”checkpoint；
9. 统一 connection context resolver；
10. 删除 host source Token gate；
11. ordinary/admin 测试；
12. expiry/access denied 分类；
13. fake hbbs wire fixture；
14. official Pro 真实端点；
15. 超享真实端点；
16. 形成 P0 reviewer checkpoint；
17. 再开始 connection strategy/AUTO/NAT。

这保证先修复“服务器配置根本无法可靠保存”，再修复“登录和地址簿成功但连接仍报登录
失效”，最后推进 AUTO/P2P；三个层级有独立证据，不再互相掩盖。
