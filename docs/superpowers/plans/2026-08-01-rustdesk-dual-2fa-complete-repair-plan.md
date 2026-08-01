# RustDesk 双 2FA、流畅度、移动快捷栏与全协议组合键完整修复计划

> 计划日期：2026-08-01（Asia/Shanghai）
>
> 计划版本：v1.1
>
> 计划性质：可执行的产品、架构、数据、安全、测试与发布计划；本文件不修改产品代码
>
> 审计起始基线：`main@d1047eacf`，`origin/main@bfae6ef30`，本地 `main` ahead 212
>
> 计划落盘复核基线：并发的 VNC 任务已将 `main` 推进到 `4c22e1f4cf`，相对
> `origin/main` ahead 213；本计划没有修改或提交该任务代码
>
> 既有实现 checkpoint：`5b2277ad4`、`972a3c0d7` 的 Peer 2FA 与 relay 修复
>
> 官方客户端固定参照：
> [`rustdesk/rustdesk@807e05ea9a7e298ed2deb438195faaafce19cdd2`](https://github.com/rustdesk/rustdesk/tree/807e05ea9a7e298ed2deb438195faaafce19cdd2)
>
> 保护声明：计划开始落盘前工作树已有 9 项用户修改/新增文件；复核与扩展审计期间并发任务
> 持续修改 VNC、输入和其他计划文件。本计划只新增并继续更新本文件，不修改 ArkTS、Rust、
> C++、配置、测试或其他既有文档，
> 不 stash、不 reset、不覆盖用户修改

## 0. 执行结论

### 0.1 一句话结论

本计划现在包含四条必须分别闭环、最终统一验收的工作流：

1. **Server Pro 账号 2FA**：发生在登录和地址簿同步之前，通过第二次 HTTP
   `/api/login` 完成；绑定属于 Pro API 账号。
2. **受控端 Peer 2FA**：发生在连接具体设备时，通过现有加密 Peer channel 的
   `Auth2FA` 完成；绑定属于具体受控端。
3. **RustDesk 低延迟视频与输入**：收帧、解码、送显、回压和输入不得互相形成长期阻塞，
   短时过载恢复后不得永久降到 15 FPS。
4. **移动端会话工具与全协议组合键**：PC 保留顶部栏；Phone/Pad 默认贴左右边缘，避开系统
   安全区；RDP、RustDesk、VNC、SSH 都有直接可发现的 C/X/V 虚拟动作，并按协议语义发送。

当前实现只完成了第 2 条的基础链路。第 1 条收到 `email_check` 后直接终止，既没有手动
验证码提交，也没有验证器绑定和自动填写，因此用户在“登录并同步设备”阶段遇到 2FA 时
必然失败。第 3、4 条还存在后文列出的确定性状态机与交互缺陷。

### 0.2 术语边界

| 用户场景 | 本计划名称 | 协议 owner | 验证码提交位置 |
|---|---|---|---|
| 登录官方 RustDesk Server Pro 管理/普通账号 | Server Pro 账号 2FA | HTTP API adapter | 第二次 `/api/login` |
| Pro 返回邮件验证码挑战 | Server Pro 邮件验证 | HTTP API adapter | 第二次 `/api/login`，仅手动邮件码 |
| 连接启用了 2FA 的远程受控端 | Peer 2FA | 加密 Peer login channel | protobuf `Auth2FA` |
| hbbs/hbbr 发现、中继与转发 | Relay transport | rendezvous/relay | 不接收 TOTP |
| 未来本机作为 HarmonyOS 被控端设置 2FA | Controlled-host inbound 2FA | 被控端服务 | 验证远端 `Auth2FA`，不属于本计划实现范围 |

UI、错误码、数据模型和日志中不得再用“中继 2FA”统称上述认证。OSS `hbbr` 本身不执行
TOTP；用户所称的“中继服务器 2FA”在本项目中应显示为“Server Pro 账号二次验证”。

### 0.3 P0 成功定义

- Server Pro 返回账号 TOTP 挑战时，用户可以手动输入，也可以从本机 2FA 验证器选择条目；
- 已明确启用自动填写的既有 Pro 账号，重新登录时可在系统身份认证后自动生成并提交；
- Server Pro 返回邮件挑战时，只显示邮件验证码流程，不读取或生成 TOTP；
- 首次 Pro 登录可在挑战页选择条目，只有第二步认证成功后才持久化绑定；
- 登录成功前不写 access token、不创建半成品账号、不启动地址簿同步；
- Peer 2FA 继续使用同一 native session，不重新创建 rendezvous/relay 连接；
- Peer 自动填写不会因临近换码边界直接永久退回手动，而是在有效期限内等待下一安全周期；
- Pro 账号 2FA 与 Peer 2FA 可以连续发生，且允许绑定两个不同的验证器条目；
- 任何 secret、密码、一次性验证码和服务端 challenge secret 都不进入日志、云同步或备份；
- 真实 Server Pro、真实 Peer、真实 hbbs/hbbr 和 API 23 设备矩阵全部通过前保持发布
  `NO-GO`。
- RustDesk 短时丢帧后，回压能按时间窗口恢复，队列为空时不会因历史累计丢帧继续锁在
  severe/15 FPS；收帧、解码、呈现和输入延迟能在同一 session 时间线上定位；
- Phone/Pad 的 RustDesk 与 VNC 会话快捷栏默认靠左右边缘，菜单向屏幕内展开，并同时避开
  SYSTEM、CUTOUT、导航手势、软键盘和其他悬浮面板；
- 全协议虚拟组合键首屏包含 C/X/V：远程桌面按 Windows/macOS 解析为 Ctrl 或 Command，
  SSH 明确区分终端控制字符与“粘贴本机文本”，VNC 只读模式全部禁用发送。

## 1. 范围与非目标

### 1.1 本计划包含

1. Server Pro 登录 challenge 的完整建模、第二步请求和状态机；
2. TOTP 与邮件验证码的严格区分；
3. Pro 账号级验证器绑定、系统身份认证和自动/手动提交；
4. Peer 2FA 换码边界、自动尝试记账、重试和悬空绑定修复；
5. 绑定元数据的 owner scope、迁移、云同步和备份边界；
6. 两种 2FA 的 UI 文案、无障碍、取消、错误和恢复路径；
7. HTTP、ArkTS、NAPI/C++/Rust、真实端点和真机验收；
8. 分阶段提交、独立复核、发布和回滚门禁。
9. RustDesk 收帧、解码、回压、送显和输入链路的可观测性、确定性修复与真机基准；
10. PC/Pad/Phone、横竖屏和系统安全区下的会话工具栏信息架构与边缘停靠；
11. RDP、RustDesk、VNC、SSH 的统一虚拟组合键目录、远端系统解析和协议能力门禁。

### 1.2 本计划不包含

- 不在本计划中为 HarmonyOS 被控端新增“设置本机 2FA Secret”的产品功能；
- 不实现 RustDesk trusted device，也不向 Peer `Auth2FA.hwid` 写入持久信任身份；
- 不让第三方 API-only 面板冒充官方 Server Pro challenge 契约；
- 不为邮件验证码读取邮箱、自动抓取短信或调用外部 OTP 服务；
- 不新建 RustDesk 云表，不同步 TOTP secret；
- 不把 Moonlight 或尚未落地的 HarmonyOS 被控端线路纳入这次组合键和工具栏实现；
- 不把 SSH 的 `Ctrl+C/Ctrl+V/Ctrl+X` 误实现为图形桌面的复制、粘贴、剪切；
- 不在没有真机 trace 的情况下直接承诺“零拷贝”或盲目扩大/缩小解码队列；
- 不用模拟器、Mock 成功或旧构建记录替代真实 Server Pro/Peer/API 23 验收。

## 2. 当前实现审计与确定根因

### 2.1 Server Pro 账号链：P0 缺失

当前事实：

- `RustDeskProApiPolicy.ets` 对 HTTP 200 的 `type == "email_check"` 直接抛出
  `two_factor_required`；
- 响应中的 `tfa_type`、`secret`、`user` 和 challenge 上下文没有进入模型；
- `RustDeskProLoginResult.requiresTwoFactor` 存在，但所有成功响应都固定为 `false`；
- `RustDeskProApiService.login()` 只有第一次用户名/密码请求；
- `RustDeskProSyncService.authenticate()` 假设第一次请求立即返回 access token；
- `RustDeskRelayPage.ets` 只有 API URL、用户名、密码和“登录并同步设备”；
- `RustDeskProAccountState` 没有 TOTP entry ID 或自动填写策略；
- 现有测试把 `email_check` 断言为错误，没有 continuation 测试。

结论：Server Pro 账号 2FA 目前不是偶发失败，而是功能未实现。手动输入和自动填写都没有
可达路径。

### 2.2 Peer 链：基础可用，自动填写存在确定性缺陷

当前已完成：

- native 识别 `2FA Required` / `Wrong 2FA Code`；
- 在同一 CryptoChannel 等待并发送 `Auth2FA`；
- pending registry 按 session/epoch 隔离；
- 普通连接和 Pro managed host preflight 都有手动输入与自动提交入口；
- native 只接收一次性 code，不接收 TOTP secret。

当前缺陷：

1. 绑定新条目后 `rustdeskTotpAutoSubmit` 被重置为 `false`，用户容易认为“已绑定”即会自动填；
2. 自动填写仅允许 SHA1、30 秒、6 位，这是合理兼容门，但错误提示和绑定前校验不够前置；
3. 剩余不足 5 秒时直接退回手动，不等待下一周期，随机挑战约有 `4/30` 的窗口命中；
4. “本 session 已自动尝试”在系统认证、保险库查询和实际提交前就写入；取消、条目暂时不可用、
   临近换码都会消耗本 session 唯一机会；
5. 错码后没有按 TOTP counter 防止重复提交同一旧码的明确策略；
6. UI 称绑定 ID “仅保存本机”，但字段实际进入 cloud extension、portable backup 和 local backup；
7. 云端恢复主机引用而本机 owner scope 没有对应 TOTP 条目时会形成悬空绑定；
8. 自动化测试没有覆盖 UI -> 系统认证 -> KeyVault -> TOTP -> native submit 的完整路径；
9. 真实 Peer/hbbr/API 23 验收仍未执行。

### 2.3 当前验证 blocker

定向运行 Rust 2FA 测试会在测试编译阶段被
`rustdesk_ffi/src/protocol/rendezvous.rs` 的 `PunchHoleResponse` 未导入阻断。实施开始前必须
先把该 blocker 作为独立、最小测试修复闭环；在它解决前不得声称 Rust 2FA 测试通过。

## 3. 目标架构

### 3.1 两个状态机

#### A. Server Pro 登录状态机

```text
Idle
  -> PrimarySubmitting
  -> ChallengePending(email | totp)
       -> ManualSubmitting | AutoAuthorizing | AutoWaitingSafeWindow
       -> ChallengeSubmitting
       -> ChallengePending(wrong/expired/retryable)
  -> Authenticated
  -> AddressBookSyncing
  -> Completed

任意非终态 -> Cancelled | TimedOut | Superseded | Failed
```

规则：

- operation generation 和 account-session lease 同时有效才允许推进；
- challenge 到达后不创建新 account operation，不丢失第一次请求上下文；
- token 只在第二步成功后写入 Asset Store；
- challenge 成功但地址簿失败时继续遵守当前 login-and-sync 原子边界；
- 页面关闭、账号切换、应用后台超时、网络切换和新登录操作必须使旧 challenge 失效；
- challenge 不能跨应用重启恢复，重启后重新执行首步登录；
- wrong code 不能清除既有有效账号 token，也不能误标 relay/Peer 失败。

#### B. Peer 连接状态机

```text
Connecting
  -> WaitingPeer2FA
       -> ManualSubmitting | AutoAuthorizing | AutoWaitingSafeWindow
       -> RetryingPeer2FA
       -> WaitingPeer2FA(wrong code)
  -> Connected

任意 pending -> Cancelled | TimedOut | Superseded | Failed
```

规则：

- 始终复用原 CryptoChannel 和 native session ID；
- 自动尝试只在 code 真正送入 native 后记账；
- 以 TOTP counter 记录已提交周期，不重复自动发送同一 counter；
- 临近换码时等待下一安全窗口，等待时间必须小于 Peer pending deadline；
- wrong code 后停止无人值守重复发送，显示手动输入和用户主动“再次从验证器填写”；
- 用户取消系统认证只关闭本次自动动作，不取消整个 Peer challenge；
- native session 被取消或替换后，所有等待 timer 和 UI 回调必须失效。

### 3.2 Server Pro challenge 模型

新增显式模型，不再用异常字符串承载 challenge：

```text
RustDeskProLoginOutcome = Authenticated | Challenge

RustDeskProLoginChallenge:
  operationId / generation
  accountDraftId
  normalizedApiOrigin
  normalizedUsername
  kind: email | totp
  responseType
  tfaType
  transientSecret
  maskedDestination(optional)
  receivedAt / localDeadline
  sanitizedUserIdentity(optional)
```

约束：

- `transientSecret` 只存在于内存；禁止序列化、Preferences、Asset Store、日志和崩溃诊断；
- challenge 对象不得包含可由 UI 通用 JSON dump 输出的 secret；
- adapter 负责按固定官方版本生成第二步请求；业务/UI 不直接拼 JSON；
- 官方 `email_check` 外层响应必须继续读取 `tfa_type`：
  `tfa_check` 才是 TOTP，邮件挑战保持 email；
- 未识别的 challenge fail closed，显示“当前服务端二次验证类型暂不支持”，不猜字段；
- 第三方面板 adapter 必须用真实契约 fixture 单独声明能力，不能自动继承官方 Pro 逻辑。

### 3.3 两类绑定存储

新增统一但分域的本机绑定服务，例如：

```text
RustDeskTwoFactorBindingStore
  getProAccountBinding(identity, ownerScope)
  saveProAccountBinding(identity, entryId, autoPolicy, ownerScope)
  getPeerBinding(identity, ownerScope)
  savePeerBinding(identity, entryId, autoPolicy, ownerScope)
  validateEntryAvailability(binding, keyVault)
  migrateLegacyHostBinding(...)
```

#### Pro 账号绑定键

稳定身份至少包含：

- 当前 Huawei/local owner scope ID；
- 规范化 API origin（scheme + host + effective port）；
- Pro account 本地 ID；
- 规范化用户名；
- 登录成功后的 server user ID（存在时用于确认或提升 provisional binding）。

首次登录没有 server user ID 时使用 provisional identity；只有 challenge 成功后才把候选绑定提升为
正式绑定。失败、取消或超时不持久化。

#### Peer 绑定键

稳定身份至少包含：

- 当前 owner scope ID；
- host 本地 ID；
- RustDesk peer ID；
- relay/account identity；
- managed peer 时的 Pro account ID + server peer ID。

地址簿 reconcile 可以更新 alias、平台和路由，但不得把另一个 Peer 的绑定移过来。

#### 持久化边界

- 只保存 `entryId`、显式 auto policy、绑定版本和非敏感 identity hash；
- TOTP secret 继续只由 `KeyVaultService` 持有；
- 两类绑定都定义为本机、owner-scoped 元数据，不进入华为云和 portable backup；
- 其他设备恢复主机或 Pro 账号后必须显示“本机尚未绑定验证器”，由用户重新选择；
- 不新增云表；优先复用现有 owner-scoped `localmetadata`/Preferences 基础设施；
- 当前 `RemoteHost.rustdeskTotpEntryId/AutoSubmit` 作为 legacy 输入保留一个迁移窗口，但不再作为
  跨设备权威状态；
- 同 owner、同设备且条目存在时执行一次性迁移；条目不存在时保留主机但标记 unbound；
- 后续 cloud/backup 写出不再包含 legacy 绑定字段；旧备份读取仍须兼容但不得自动启用 auto submit。

### 3.4 安全数据分类

| 数据 | 存储 | 云/备份 | 日志 | native |
|---|---|---|---|---|
| TOTP secret | KeyVault/安全资产 | 仅遵守验证器自身既有加密策略 | 禁止 | 禁止 |
| Pro challenge secret | 内存、operation scoped | 禁止 | 禁止 | 禁止 |
| 一次性 code | 短生命周期内存 | 禁止 | 禁止 | Peer 场景只传 code |
| Pro access token | Asset Store | 禁止 | 仅 fingerprint/generation | 仅既有 control-plane 路径 |
| TOTP entry ID | owner-scoped 本机元数据 | 禁止 | 只允许脱敏 hash | 禁止 |
| auto policy | owner-scoped 本机元数据 | 禁止 | 可记录布尔状态 | 禁止 |
| challenge 类型/HTTP status | 不持久化 | 禁止 | 允许脱敏记录 | 禁止 |

系统身份认证必须沿用 `showLockGate` 的生物识别/PIN 能力；UI 文案不得只写“生物认证”而忽略
PIN fallback。系统认证成功只授权本次读取/生成 code，不代表 Server Pro 或 Peer 已认证成功。

## 4. 产品与交互设计

### 4.1 Server Pro 账号登录 Sheet

现有 API 地址、用户名、密码下方新增明确区域：

- 已有账号：显示“账号二次验证：未绑定 / 已绑定条目名称 / 本机条目不可用”；
- 新账号：不要求登录前必须绑定；challenge 到达后可选择条目；
- 自动填写默认关闭，由用户明确开启；
- 重新绑定时保留或改变 auto policy 必须由用户明确操作，不能静默重置；
- 删除 Pro 账号时只删除该账号的绑定引用，不删除验证器条目。

### 4.2 Challenge Sheet

#### TOTP challenge

显示：

- “Server Pro 账号二次验证”，而不是“中继 2FA”；
- 脱敏账号、API origin、当前绑定状态；
- 手动 6/8 位输入（最终长度以固定服务端契约为准）；
- “从 2FA 验证器填写”；
- 可选择验证器条目；
- “认证成功后记住此绑定”和“以后自动填写”显式选项；
- 当前验证码倒计时、等待下一安全周期状态；
- 错码、过期、challenge 失效、网络失败和取消的分层提示。

首次选择的候选绑定只在服务端认证成功后提交到 binding store。

#### Email challenge

显示：

- “Server Pro 邮件验证码”；
- 服务端提供时显示脱敏邮箱；
- 手动验证码输入；
- 不读取 KeyVault，不显示 TOTP 条目，不提供自动填写开关；
- 只有服务端契约明确支持 resend 时才显示重发，不猜 endpoint。

### 4.3 Peer 主机编辑与连接 Sheet

- 把“RustDesk 2FA 验证器”改为“受控端连接 2FA”，与 Pro 账号 2FA 区分；
- 绑定前直接提示兼容条件：SHA1、30 秒、6 位自动填写；其他条目仍允许作为手动参考，
  不允许误显示为可自动；
- 首次绑定默认 auto off，但按钮必须明确为“绑定”与“绑定并启用自动填写”，避免隐含状态；
- 重绑时不得无提示地把已有 auto policy 重置；
- 悬空绑定显示“此设备找不到已绑定条目”，提供重新绑定，不显示“已绑定”；
- 即使 auto off，Peer challenge Sheet 也提供用户主动“从验证器填写”；
- 临近换码显示“等待下一组安全验证码”，用户仍可改为手动或取消；
- wrong code 后不自动循环重试，允许用户主动生成新周期 code。

### 4.4 连续双 2FA 场景

必须支持如下真实流程：

```text
登录 Server Pro 账号
  -> 账号 TOTP（条目 A）
  -> 地址簿同步
  -> 连接某个 Peer
  -> 受控端 TOTP（条目 B）
  -> 远程桌面
```

条目 A 与 B 可相同也可不同，但状态、binding key、错误提示、attempt ID、自动策略和验证码提交
通道必须完全独立。任何一步取消只收敛当前状态机，不误删另一套绑定或有效 token。

## 5. 分阶段实施计划

### Phase 0：固定契约并解除测试前置 blocker

目标：在写业务实现前固定证据，恢复可判定的测试基线。

任务：

1. 固定官方 RustDesk commit、相关 blob SHA 和 Server Pro 目标版本；
2. 保存脱敏 JSON fixture：无 2FA、TOTP challenge、email challenge、wrong code、expired、
   unsupported challenge、success token；
3. 核对官方第二步 `/api/login` 的 request type、`verificationCode`、`tfaCode`、`secret`、
   device identity 和 password/identity 字段要求；
4. 为每个第三方面板建立独立 fixture/capability，不复用官方 adapter 假设；
5. 最小修复当前 `PunchHoleResponse` 测试导入 blocker，并先跑现有 Rust/ArkTS 基线；
6. 记录真实 Server Pro 是否对 challenge 设置 TTL、是否允许重试、错误响应形状和限次策略。

涉及文件：

- `rustdesk_ffi/src/protocol/rendezvous.rs`（只处理现有测试编译 blocker）；
- `entry/src/test/fixtures/rustdesk_pro/*` 或现有 fixture 目录；
- `rustdesk_vendor/libs/hbb_common/protos/UPSTREAM.yml`（仅协议版本确有变化时）；
- 对应 provenance/SBOM/NOTICE（仅依赖或 vendored schema 变化时）。

退出门：现有定向 Rust 测试可编译运行；fixture 不含真实地址、账号、token、secret 或 code。

### Phase 1：Challenge contract 与纯策略测试

目标：先让 API 层正确表达 challenge，不接 UI。

任务：

1. 把 `RustDeskProLoginResult` 改为显式 `Authenticated | Challenge` outcome；
2. 新增 challenge model 和类型守卫；
3. 解析 `email_check + tfa_type`，严格区分 email/TOTP/unsupported；
4. 新增第二步请求 builder，所有字段由 adapter 生成；
5. 统一错误分类：wrong code、expired、rate limited、transport、unsupported；
6. 添加 JSON 序列化/日志脱敏测试，确保 challenge secret 不可被通用诊断输出；
7. 保留 HTTP 400 minimal primary-login fallback，但 challenge continuation 不得错误触发 primary retry。

主要文件：

- `entry/src/main/ets/services/RustDeskProApiPolicy.ets`；
- `entry/src/main/ets/services/RustDeskProApiService.ets`；
- `entry/src/main/ets/model/RustDeskProModels.ets`；
- 新增 `RustDeskProTwoFactorPolicy.ets` 或等价纯策略文件；
- `entry/src/test/RustDeskProApiPolicy.test.ets`；
- 新增 challenge/request builder 测试。

退出门：fixture 驱动测试覆盖所有 challenge 类型；不存在用异常字符串携带正常 challenge 的路径。

### Phase 2：本机双域绑定存储与迁移

目标：建立 Pro account/Peer 两套 owner-scoped 绑定，不同步 secret 或悬空权威引用。

任务：

1. 实现 `RustDeskTwoFactorBindingStore`；
2. 接入 AccountSessionLease、ownerScopeId、generation 和账号切换 barrier；
3. 实现 provisional Pro binding 成功后 promotion；
4. 实现 Peer legacy host-field 一次性迁移；
5. 从 cloud/portable backup 新写出白名单移除 legacy binding 字段；
6. 保留旧记录读取兼容，但旧记录不得自动恢复 auto submit；
7. 验证账号登出、账号切换、删除 host、删除 Pro account、删除 TOTP entry 的级联行为；
8. 删除绑定引用绝不删除 KeyVault 中的验证器条目。

主要文件：

- 新增 `entry/src/main/ets/services/RustDeskTwoFactorBindingStore.ets`；
- `entry/src/main/ets/model/RemoteHost.ets`（兼容/迁移边界）；
- `entry/src/main/ets/services/CloudStore.ets`；
- `entry/src/main/ets/services/CloudTableAdapter.ets`；
- `entry/src/main/ets/services/BackupManifestV3.ets`；
- `entry/src/main/ets/services/LocalBackupPolicy.ets`；
- `entry/src/main/ets/services/HostSyncService.ets` 或 reconcile policy；
- 对应 owner-scope、迁移、云/备份白名单测试。

退出门：跨设备恢复不会显示伪“已绑定”；账号切换无法读取另一 owner 的绑定；云/备份中没有新增
binding reference，更没有 secret。

### Phase 3：Server Pro 二次登录状态机

目标：完成手动可用、可取消、可重试且原子安全的 HTTP 2FA 闭环。

任务：

1. 在 `RustDeskProSyncService` 增加 operation-scoped challenge controller；
2. 第一步返回 challenge 时暂停，不写 token、不拉地址簿；
3. 暴露显式 `submitChallengeCode`、`cancelChallenge`、`challengeSnapshot`；
4. 第二步成功后才进入现有 authenticate -> save -> sync 原子流程；
5. 页面销毁、账户切换、新登录、超时和后台过期使旧 challenge superseded；
6. wrong code 保持同一合法 challenge 或按服务端响应刷新 challenge；
7. 任何 HTTP/Peer/relay 错误不得误清另一个 account generation；
8. 终态清零 password、code、challenge secret 和 timer。

主要文件：

- `entry/src/main/ets/services/RustDeskProSyncService.ets`；
- `entry/src/main/ets/services/RustDeskProApiService.ets`；
- `entry/src/main/ets/services/RustDeskProCredentialStore.ets`；
- `entry/src/main/ets/services/AccountSessionCoordinator.ets`/相关 policy（只复用既有 owner）；
- 新增状态机测试和 late-result/generation 测试。

退出门：手动 TOTP、手动 email code、wrong code 重试、取消、超时和成功同步都可自动化判定；
所有晚到回调被 operation fence 拒绝。

### Phase 4：Server Pro Challenge UI 与验证器自动填写

目标：把状态机接入用户可理解的 Sheet，并安全接入 KeyVault。

任务：

1. 在 Pro 登录页显示账号级绑定状态；
2. 根据 challenge kind 展示 TOTP 或 email 专用 Sheet；
3. TOTP 支持手动输入、选择条目、一次性填充、成功后记住、显式自动策略；
4. auto 路径：system auth -> KeyVault -> compatibility -> safe window -> submit；
5. auto 失败保持手动可用；用户取消 system auth 不取消 HTTP challenge；
6. 首次登录候选绑定只在第二步成功后保存；
7. email challenge 完全不访问 KeyVault；
8. 加入焦点、键盘提交、窗口尺寸、Sheet 替换、无障碍 label 和深浅色测试。

主要文件：

- `entry/src/main/ets/pages/RustDeskRelayPage.ets`；
- 可新增独立 `RustDeskProTwoFactorSheet.ets`，避免继续膨胀页面；
- `entry/src/main/ets/services/KeyVaultService.ets`（只复用安全读取接口，避免扩散 secret）；
- `entry/src/main/ets/components/security/LockGate.ets` 或现有调用点；
- 纯 UI controller/policy 测试。

退出门：首次 TOTP、已绑定自动填、email 手动、无可用条目、系统认证取消、wrong code 都有明确 UI；
不会出现“Pro 账号需要二次验证”后无输入入口的死路。

### Phase 5：Peer 自动填写可靠性修复

目标：保留现有 native 正确链路，修复自动提交时序和绑定体验。

任务：

1. 将 auto-attempt 标记移动到 native submit 成功之后；
2. 用 `{sessionId, totpCounter}` 记录已提交周期；
3. 剩余不足安全阈值时等待下一周期，不直接要求手动；
4. timer 绑定 connectAttemptId/sessionId/generation，取消后不得提交；
5. wrong code 后禁止自动重复同一 counter，提供用户主动新码；
6. 普通连接与 Pro managed-host preflight 复用同一纯策略/controller，消除双份逻辑漂移；
7. 绑定前校验条目兼容性，悬空引用按 unbound 处理；
8. 手动仍接受经固定 Peer 版本验证的 6/8 位格式；
9. 保持 `Auth2FA.hwid` 为空，trusted device 继续不实现；
10. native 增加完整假 channel 测试：Required -> Auth2FA -> PeerInfo、Wrong -> retry、timeout、cancel、
    session isolation。

主要文件：

- `entry/src/main/ets/services/RustDeskPeerTwoFactorPolicy.ets`；
- 新增共享 `RustDeskPeerTwoFactorController.ets` 或等价 owner；
- `entry/src/main/ets/pages/HostListPage.ets`；
- `entry/src/main/ets/pages/RemoteDesktop.ets`；
- `rustdesk_ffi/src/protocol/session.rs`（测试/必要的可测试边界）；
- `rustdesk_ffi/src/lib.rs`；
- 对应 ArkTS/Rust 测试。

退出门：随机换码边界不再产生约 13.3% 的确定性手动回退；同一 session 不重复自动发送旧码；
两条 ArkTS 页面路径行为一致。

### Phase 6：诊断、错误分层与隐私审计

目标：现场可以一眼判断失败属于账号、邮件、Peer、relay 或 KeyVault，同时不泄密。

结构化错误至少包含：

- `pro_primary_login_failed`；
- `pro_totp_required` / `pro_email_code_required`；
- `pro_totp_wrong_code` / `pro_challenge_expired` / `pro_challenge_unsupported`；
- `peer_2fa_required` / `peer_2fa_wrong_code` / `peer_2fa_timeout`；
- `totp_binding_missing` / `totp_entry_unavailable` / `totp_incompatible`；
- `relay_connect_failed` / `rendezvous_rejected`。

诊断只允许记录：layer、route ID、HTTP status、challenge kind、operation/session generation、
是否存在绑定、是否进入 safe-window wait。禁止记录 username 原文、secret、code、token、密码、
完整 API URL query 和 TOTP entry ID。

主要文件：

- `RustDeskProApiError`/相关错误模型；
- `RustDeskConnectionErrorPolicy.ets`；
- `RustDeskProConnectionPreflightPolicy.ets`；
- Rust structured error 和 ArkTS 映射测试；
- 诊断导出/脱敏测试。

退出门：同一用户动作可以从脱敏诊断准确定位到五层之一；安全扫描找不到秘密字段。

### Phase 7：双 2FA 真实验收与独立复核 checkpoint

目标：用真实端点和设备证明两套 2FA 能连续、稳定、安全工作。

任务：

1. 完成第 7 节全部矩阵；
2. 真实设备时间正确与有意偏移场景都要有证据；
3. reviewer 独立检查 HTTP contract、owner/generation、secret 生命周期、native session 隔离；
4. 修复 reviewer 发现后重新跑全部门禁；
5. 更新 `CURRENT.md`、`QUEUE.md` 和必要 ADR；
6. 形成可独立回归的 2FA checkpoint；它不是整份计划的最终发布点；
7. 任一真实矩阵缺证据则整份计划保持 `NO-GO`。

## 6. 自动化测试矩阵

### 6.1 Server Pro API/策略

- primary login 无 challenge -> token；
- `email_check + tfa_type=tfa_check` -> TOTP challenge；
- `email_check + tfa_type=email_check/empty` -> email challenge；
- 未知 `tfa_type` -> unsupported fail closed；
- 第二步 TOTP request 字段逐项 fixture 对比；
- 第二步 email request 不含 TOTP-only 字段；
- wrong code、expired、rate limit、401/403、500、invalid JSON；
- challenge continuation 不触发 HTTP 400 minimal primary fallback；
- challenge secret/code 不出现在 error、JSON dump、hilog 和 diagnostics。

### 6.2 Operation/owner/binding

- 新登录 supersede 旧 challenge；
- 页面关闭、账号切换、owner scope 切换使旧回调失效；
- access token 仅在 challenge 成功后持久化；
- 首次候选 binding 仅成功后 promotion；
- 失败/取消/超时不保存 binding；
- 删除账号只删引用，不删 TOTP entry；
- Pro 绑定不能被 Peer 查询，Peer 绑定不能被 Pro 查询；
- 同 server 两个账号、同账号两个 server origin 不串绑定；
- managed host reconcile 不改 Peer binding identity；
- legacy host binding 本机迁移、跨设备悬空、条目已删除；
- cloud/backup outbound 不再写 legacy binding，old backup 仍安全读取。

### 6.3 TOTP 自动填写

- SHA1/30s/6 位兼容；
- SHA256/SHA512、自定义 period、8 位自动路径被前置拒绝并保留手动；
- safe boundary、剩余 4/1 秒、等待下一 counter；
- system auth 成功、取消、锁定、PIN fallback；
- KeyVault not-ready、entry missing、secret unavailable；
- submit 之前不消耗 attempt；
- submit 后同 counter 不重复；
- wrong code 后只允许用户主动新码；
- timer 在 session/operation 取消后不触发；
- 设备时钟偏差给出可诊断提示，不无限自动重试。

### 6.4 Peer native/FFI

- `2FA Required -> Auth2FA -> PeerInfo` 同一 CryptoChannel；
- `Wrong 2FA Code -> 新 code -> accepted`；
- 6/8 位格式、非数字拒绝；
- 两个并发 session 的 code 不串；
- cancel、epoch supersede、sender closed、90 秒 timeout；
- wrong code 不被归类为 relay error；
- bridge/NAPI 使用 session-scoped submit；
- `Auth2FA.hwid` 为空；
- screen connection 与 file-transfer/auth 入口边界按产品能力分别验证。

### 6.5 UI/生命周期

- Pro login TOTP、email 两种 Sheet；
- 首次选择、重新绑定、取消、系统认证失败；
- 键盘 Enter、焦点、窗口旋转/缩放、后台/前台、Sheet 替换；
- Peer 普通连接与 Pro preflight 一致；
- 悬空绑定、无验证器条目、auto off 的主动填写；
- 深浅色、放大字体、无障碍朗读不暴露 code；
- 连接成功后 code 输入状态立即清空。

## 7. 真实端点与 API 23 验收矩阵

### 7.1 Server Pro 账号

至少覆盖目标官方 Server Pro 的两个受支持版本：

| 场景 | 必须结果 |
|---|---|
| 未启用账号 2FA | 首步直接登录并同步 |
| TOTP 已启用，首次登录 | 手动/选择条目均成功，成功后才保存绑定 |
| TOTP 已启用，重新登录 | 系统认证后自动填写成功 |
| 邮件验证 | 只出现邮件码，不读取验证器 |
| 错码 | 保持可重试，不创建半账号，不清旧有效 token |
| challenge 过期 | 明确要求重新登录，不提交旧 secret |
| 取消/返回/应用后台 | operation 收敛，无晚到 token |
| 账号切换 | A 账号 challenge/code 不进入 B 账号 |
| 同 API 两个账号 | 分别绑定，互不覆盖 |
| API URL 端口/尾 `/api` 变化 | 规范化 identity 稳定且不误合并不同 origin |
| 第三方 API-only 面板 | 未声明 challenge 能力时 fail closed |

### 7.2 Peer 2FA

| 场景 | 必须结果 |
|---|---|
| Peer 未启用 2FA | 不出现 2FA UI |
| Peer 启用 2FA，manual | 正确码连接，错码可重试 |
| Peer 启用 2FA，auto | 系统认证后自动连接 |
| 换码边界 | 等待下一安全 code，不直接永久降级 |
| auto off | 可在 challenge Sheet 主动从验证器填充 |
| 条目不兼容/已删除 | 明确提示并保留手动 |
| password + 2FA | 两步顺序正确 |
| request approval + 2FA | 批准和 2FA 顺序按真实 Peer 行为正确收敛 |
| direct/P2P/relay | 三种路径均在 Peer 加密层处理 2FA |
| 取消/重连/并发 session | 无串码、旧 timer 和旧回调 |

### 7.3 连续双 2FA

必须至少完成：

1. Pro 账号条目 A -> Peer 条目 B；
2. Pro 与 Peer 共用同一个验证器条目；
3. Pro 自动、Peer 手动；
4. Pro 手动、Peer 自动；
5. Pro 成功后 Peer 错码；
6. Pro challenge 取消后不得进入 Peer；
7. 账号 token 过期重新 TOTP 后再连接 Peer；
8. 应用前后台和网络切换穿过两个状态机。

### 7.4 设备与环境

- HarmonyOS API 23 真机，至少 PC/2in1 目标形态；
- 生物识别可用、仅 PIN fallback、系统认证取消/锁定；
- Wi-Fi/有线切换、断网恢复、高延迟；
- 系统时间正确、偏差约一个 TOTP 周期；
- 同一 Huawei 账号两台设备验证本机重新绑定语义；
- 应用冷启动、热启动、后台恢复和升级安装。

每个真实用例记录：版本、设备、服务端 profile、脱敏 attempt ID、challenge kind、连接层、结果、
截图或脱敏日志。不得记录账号、secret、code、token、真实地址或个人设备 ID。

## 8. 强制构建与质量门禁

每个实现 checkpoint 都执行：

```sh
source scripts/macos_env.sh
hvigorw --mode module -p module=entry -p product=default default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon
hvigorw --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --no-daemon
git diff --check
```

附加门禁：

- ArkTS 受影响时执行定向测试；`ohosTest@OhosTestCompileArkTS` 只有真实注册可用时才可写通过；
- Rust 执行 `cargo check --tests`、定向 2FA/session 测试和受影响全量 lib 测试；
- NAPI/C++ 执行受影响 native tests、ABI/导出检查；
- `arm64-v8a`、`x86_64` RustDesk FFI release 构建；
- Light open-source compliance；
- secret/log/cloud/backup 静态扫描；
- 独立 reviewer 无 P0/P1/P2；
- 真实端点/API 23 矩阵。

命令失败、环境缺失或测试未执行必须记录为 blocker，不得用旧日志或其他 session 成功替代。

## 9. 建议提交拆分

1. `test(rustdesk): pin pro 2fa fixtures and restore test baseline`
2. `feat(rustdesk): model server pro login challenges`
3. `feat(rustdesk): add owner-scoped dual 2fa bindings`
4. `feat(rustdesk): complete server pro second-factor login`
5. `feat(rustdesk): add pro account 2fa challenge ui`
6. `fix(rustdesk): harden peer totp auto submission`
7. `fix(rustdesk): migrate legacy peer 2fa binding metadata`
8. `test(rustdesk): cover dual 2fa lifecycle and redaction`
9. `docs(rustdesk): record real endpoint acceptance evidence`
10. `test(rustdesk): add session-scoped video latency baseline`
11. `fix(rustdesk): make decoder pressure windowed and recoverable`
12. `perf(rustdesk): decouple ingress admission from decode scheduling`
13. `perf(rustdesk): align codec negotiation and presentation pacing`
14. `feat(remote-ui): dock mobile session tools to safe screen edges`
15. `feat(remote-input): add protocol-aware copy cut paste shortcuts`
16. `test(remote-input): cover shortcut semantics and overlay collisions`
17. `docs(remote): record device performance and mobile ui acceptance`

每个提交只暂存明确文件，不使用 `git add -A`。同一文件存在用户修改时逐 hunk 复核。

## 10. 回滚与兼容策略

- Server Pro challenge 模型和 binding store 采用 additive versioned schema；
- 任一 auto 路径出现问题时可关闭 auto policy，手动 code 路径必须继续可用；
- 未识别服务端 challenge fail closed，不回退成“忽略 2FA 继续同步”；
- legacy host binding 迁移必须幂等；回滚旧版本不会删除 KeyVault TOTP 条目；
- 不自动信任设备、不保存 `hwid`，避免回滚后留下绕过 2FA 的远端信任；
- challenge secret 永不落盘，因此进程终止后的恢复策略始终是重新登录；
- 若 cloud/backup 白名单迁移发现兼容风险，先停止新写出 binding reference，保留旧读取，
  不批量清用户云数据。

## 11. Definition of Done

只有以下全部满足，任务才能写“完成”：

- Server Pro TOTP 与 email challenge 均有完整手动路径；
- Server Pro TOTP 已实现安全的验证器选择、绑定和自动填写；
- Peer 2FA 自动填写换码、attempt 和悬空绑定缺陷修复；
- 两类 binding owner/identity 完全隔离；
- 连续 Pro 2FA -> Peer 2FA 矩阵通过；
- secret/code/password/token/challenge secret 未进入日志、云或备份；
- Rust/ArkTS/native 定向与受影响全量测试通过；
- 两项强制 Hvigor 门禁通过；
- 双 ABI release 构建通过；
- 独立 reviewer 无未解决 P0/P1/P2；
- 真实官方 Server Pro、真实 Peer/hbbs/hbbr 和 API 23 真机验收有脱敏证据；
- 临时解码过载恢复后不会被累计丢帧永久锁在 severe/15 FPS；
- 收帧、解码、呈现、帧龄、输入发送与远端回显均为 session-scoped，并有可关联的真机证据；
- RustDesk AUTO/显式编码器与实际解码 backend 不再产生未经证明的启动重建或软件解码负担；
- PC 顶部栏与 Phone/Pad 边缘栏的横竖屏、安全区、键盘和悬浮面板碰撞矩阵全部通过；
- RDP、RustDesk、VNC、SSH 都有可发现的 C/X/V 虚拟动作，且通过协议/远端系统语义测试；
- VNC 只读、RustDesk 浏览模式、会话断开和生命周期切换不会发送或残留组合键；
- `CURRENT.md`、`QUEUE.md`、必要 ADR、发布说明和回滚说明已更新；
- PR required checks 通过并按项目闭环合并、清理分支。

在上述任一项缺失时，只能描述为“本地实现完成”或“特定环境验证通过”，发布状态保持
`NO-GO`。
