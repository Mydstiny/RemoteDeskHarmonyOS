# RustDesk 双 2FA、地址簿标签、2FA 品牌头像、流畅度、长连接、移动快捷栏与全协议组合键完整修复计划

> 计划日期：2026-08-01（Asia/Shanghai）
>
> 计划版本：v1.3
>
> 计划性质：可执行的产品、架构、数据、安全、测试与发布计划；本文件不修改产品代码
>
> 审计起始基线：`main@d1047eacf`，`origin/main@bfae6ef30`，本地 `main` ahead 212
>
> 计划落盘复核基线：并发的 VNC 任务已将 `main` 推进到 `4c22e1f4cf`，相对
> `origin/main` ahead 213；本计划没有修改或提交该任务代码
>
> 扩展审计落盘基线：共享工作区随后由并发 1.1.0 升级任务推进并切换到
> `codex/upgrade-1-1-0-cloud-sync@a71f3337d`；本次只继续修改本计划文件，没有执行切分支、
> 提交或修改该升级任务文件
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

本计划现在包含六条必须分别闭环、最终统一验收的工作流：

1. **Server Pro 账号 2FA**：发生在登录和地址簿同步之前，通过第二次 HTTP
   `/api/login` 完成；绑定属于 Pro API 账号。
2. **受控端 Peer 2FA**：发生在连接具体设备时，通过现有加密 Peer channel 的
   `Auth2FA` 完成；绑定属于具体受控端。
3. **RustDesk 低延迟与长连接连续性**：收帧、解码、送显、回压和输入不得互相形成长期阻塞，
   短时过载恢复后不得永久降到 15 FPS；网络切换或 socket 中止不能停在最后一帧伪装成仍在线。
4. **移动端会话工具与全协议组合键**：PC 保留顶部栏；Phone/Pad 默认贴左右边缘，避开系统
   安全区；RDP、RustDesk、VNC、SSH 都有直接可发现的 C/X/V 虚拟动作，并按协议语义发送。
5. **Server Pro 地址簿标签**：保持地址簿、共享权限、Peer 多标签和颜色的服务端 owner，提供
   未标记/并集/交集筛选、搜索、只读展示和权限受控写回，绝不覆盖本地单值工作组。
6. **2FA 品牌头像**：从运行时无保证 CDN 改为可审计的本地优先品牌资源，扩大真实覆盖，首屏立即
   回退首字母，消除每次进入重新等待和错误品牌匹配。

当前实现只完成了第 2 条的基础链路。第 1 条收到 `email_check` 后直接终止，既没有手动
验证码提交，也没有验证器绑定和自动填写，因此用户在“登录并同步设备”阶段遇到 2FA 时
必然失败。第 3、4 条还存在后文列出的确定性状态机与交互缺陷。第 5 条目前仅在 API 临时模型中
解析标签，进入持久化/UI 前被丢弃；第 6 条依赖无版本 CDN，存在确定的失效映射和重复加载问题。

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
- RustDesk 运行中发生 WLAN 漫游、地址替换或瞬时断网时，1 秒内从“已连接”转入可见的重连态，
  网络恢复后按有界退避创建新 generation；失败后明确断开，不再永久显示最后一帧；
- stream 进入终态后 500ms 内停止音频回调和输入发送，旧 FFI/decoder/audio callback 不得进入新会话，
  不得继续以 5ms 周期拉取静音并制造系统日志风暴；
- Phone/Pad 的 RustDesk 与 VNC 会话快捷栏默认靠左右边缘，菜单向屏幕内展开，并同时避开
  SYSTEM、CUTOUT、导航手势、软键盘和其他悬浮面板；
- 全协议虚拟组合键首屏包含 C/X/V：远程桌面按 Windows/macOS 解析为 Ctrl 或 Command，
  SSH 明确区分终端控制字符与“粘贴本机文本”，VNC 只读模式全部禁用发送。

### 0.4 P1 成功定义

- Server Pro 个人/共享/legacy 地址簿不再扁平丢失标签；同一 Peer 在多个地址簿中的 membership、别名、
  标签和权限可分别表达；
- Pro 地址簿可按单标签、多标签并集、多标签交集和“未标记”筛选，全文搜索可命中标签与地址簿名；
- 服务端标签与本地 `groupId` 同时存在、互不覆盖；只读共享地址簿绝不出现可写入口；
- 标签新增、重命名、删除、改色和 Peer 标签修改只在已验证 write/full-control 权限及版本契约下开放；
- 2FA 品牌头像现有意图覆盖中不再存在死 slug；本地资源冷启动立即可见，离线和未知 issuer 首帧显示
  首字母，不再等待 CDN 失败后才回退；
- 品牌匹配不使用任意短字符串包含关系；`Duo` 等安全产品不得显示为无关公司；资源来源、hash、许可和
  商标指引可审计，未经官方品牌资产证明的图标不再宣称“官方/真实 Logo”。

## 1. 范围与非目标

### 1.1 本计划包含

1. Server Pro 登录 challenge 的完整建模、第二步请求和状态机；
2. TOTP 与邮件验证码的严格区分；
3. Pro 账号级验证器绑定、系统身份认证和自动/手动提交；
4. Peer 2FA 换码边界、自动尝试记账、重试和悬空绑定修复；
5. 绑定元数据的 owner scope、迁移、云同步和备份边界；
6. 两种 2FA 的 UI 文案、无障碍、取消、错误和恢复路径；
7. HTTP、ArkTS、NAPI/C++/Rust、真实端点和真机验收；
8. 分阶段提交、独立复核、发布和回滚门禁；
9. RustDesk 收帧、解码、回压、送显和输入链路的可观测性、确定性修复与真机基准；
10. PC/Pad/Phone、横竖屏和系统安全区下的会话工具栏信息架构与边缘停靠；
11. RDP、RustDesk、VNC、SSH 的统一虚拟组合键目录、远端系统解析和协议能力门禁；
12. RustDesk 长连接的网络变更感知、transport error 分层、有界重连、快速静默与资源回收；
13. Server Pro 个人/共享/legacy 地址簿的 profile、membership、tag、permission、筛选、搜索与受控写回；
14. 2FA 品牌 manifest、本地资产、resolver、缓存、占位、隐私、许可与首屏性能。

### 1.2 本计划不包含

- 不在本计划中为 HarmonyOS 被控端新增“设置本机 2FA Secret”的产品功能；
- 不实现 RustDesk trusted device，也不向 Peer `Auth2FA.hwid` 写入持久信任身份；
- 不让第三方 API-only 面板冒充官方 Server Pro challenge 契约；
- 不为邮件验证码读取邮箱、自动抓取短信或调用外部 OTP 服务；
- 不新建 RustDesk 云表，不同步 TOTP secret；
- 不把 Moonlight 或尚未落地的 HarmonyOS 被控端线路纳入这次组合键和工具栏实现；
- 不把 SSH 的 `Ctrl+C/Ctrl+V/Ctrl+X` 误实现为图形桌面的复制、粘贴、剪切；
- 不在没有真机 trace 的情况下直接承诺“零拷贝”或盲目扩大/缩小解码队列；
- 不用模拟器、Mock 成功或旧构建记录替代真实 Server Pro/Peer/API 23 验收；
- 不把所有“停滞”都归因于本次 Wi-Fi 样本；每次故障仍须用 session/generation 证据区分网络、
  服务端、协议、decoder、renderer 与 lifecycle；
- 不通过无限重连、缓存旧 OTP、静默重复生物认证或延长 socket timeout 掩盖连接终态；
- 不把 Server Pro 多标签塞入本地单值 `groupId`，不跨账号/地址簿按标签文本合并，不把服务端 tag cache
  写入华为云或可移植备份；
- 不在未取得 shared profile 写权限时调用 tag mutation API；legacy 整体快照写回没有冲突契约时保持只读；
- 不运行时抓取任意网页/favicon，不自动加载 TOTP `iconUrl`，不把 issuer、账号、邮箱域名、secret 或
  用户品牌清单发送给 CDN；
- 不把社区维护的单色品牌图标称为“官方 Logo”；商标/许可不能确认的品牌使用可读首字母。

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
14. `test(rustdesk): specify network continuity and quiesce state machine`
15. `fix(rustdesk): recover bounded sessions across network changes`
16. `fix(audio): quiesce remote renderer on silence and stream end`
17. `feat(remote-ui): dock mobile session tools to safe screen edges`
18. `feat(remote-input): add protocol-aware copy cut paste shortcuts`
19. `test(remote-input): cover shortcut semantics and overlay collisions`
20. `test(rustdesk): pin address book profile tag and permission contracts`
21. `feat(rustdesk): preserve address book memberships and tag filters`
22. `feat(rustdesk): add permission-gated address book tag mutations`
23. `test(totp): audit brand manifest coverage and asset provenance`
24. `perf(totp): bundle brand assets and cache avatar rendering`
25. `docs(remote): record long-run address book logo and mobile ui acceptance`

每个提交只暂存明确文件，不使用 `git add -A`。同一文件存在用户修改时逐 hunk 复核。

## 10. 回滚与兼容策略

- Server Pro challenge 模型和 binding store 采用 additive versioned schema；
- 任一 auto 路径出现问题时可关闭 auto policy，手动 code 路径必须继续可用；
- 未识别服务端 challenge fail closed，不回退成“忽略 2FA 继续同步”；
- legacy host binding 迁移必须幂等；回滚旧版本不会删除 KeyVault TOTP 条目；
- 不自动信任设备、不保存 `hwid`，避免回滚后留下绕过 2FA 的远端信任；
- challenge secret 永不落盘，因此进程终止后的恢复策略始终是重新登录；
- 若 cloud/backup 白名单迁移发现兼容风险，先停止新写出 binding reference，保留旧读取，
  不批量清用户云数据；
- 长连接恢复可通过 feature flag 退回“明确断开 + 手动重试”，但 fast quiesce、旧 generation 隔离和
  终态 UI 不得回滚；不得退回最后一帧假在线或无限静音 callback。

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
- Wi-Fi 漫游/断网/网络类型切换后不会永久停在最后一帧；恢复成功使用新 session generation，
  恢复失败显示可操作的断线结果；
- RustDesk transport 终态后的 audio、video、input、clipboard 和旧 callback 全部完成快速静默与最终回收，
  2/4/8 小时 soak 不出现持续静音回调、日志风暴、CPU/内存单调增长或不可恢复停滞；
- Server Pro 地址簿 profile/membership/tag/permission 没有在分页、共享簿、同 Peer 多簿或离线缓存中丢失；
  tag 并集/交集/未标记/搜索与写权限矩阵全部通过，且本地工作组不回归；
- 2FA 品牌资产 manifest 的资源、hash、来源、许可/商标说明全部通过构建审计；冷/热/离线首屏、失败缓存、
  未知 issuer、误匹配和大列表性能矩阵通过；
- `CURRENT.md`、`QUEUE.md`、必要 ADR、发布说明和回滚说明已更新；
- PR required checks 通过并按项目闭环合并、清理分支。

## 12. 扩展审计：流畅度、长连接、移动快捷栏与全协议组合键

### 12.1 证据分级

后续实施和汇报必须把结论分成三类：

| 等级 | 含义 | 本计划中的处理 |
|---|---|---|
| 已确认缺陷 | 由当前代码和状态机可直接推出，不依赖特定设备复现 | 直接进入修复阶段，并先写失败测试 |
| 高风险链路 | 代码存在阻塞、排队或语义冲突，但实际占比取决于设备和网络 | 先加 session trace，再按数据选择实现 |
| 待真机确认 | 仅靠静态代码不能判断用户所见卡顿由哪一段主导 | 禁止提前宣称根因，进入对照矩阵 |

2026-08-01 已取得一份 API 23 实体 Pad 的长连接现场日志，因此第 12.4 节可以确认该样本的触发链和
客户端放大缺陷；仍没有同场景官方客户端、服务端双端 trace 和覆盖多网络环境的复现数据，不能把
其他设备的全部“不流畅”或“停滞”一律单归因于网络、解码器或 GPU。

### 12.2 RustDesk 流畅度：已确认缺陷

#### A. 回压会被历史累计丢帧永久锁高

当前链路：

1. `HardwareDecoder::DroppedFrameCount()` 返回本 decoder 生命周期内累计的
   `inputDropCount + waitKeyframeDropCount`；软件路径的 `softDropped` 也是累计值；
2. `DecoderNapi::ActiveVideoPressureLevel()` 在队列深度之外直接判断累计丢帧：
   `dropped >= 4 -> level 2`，`dropped >= 10 -> level 3`；
3. C++ 每 30 个视频回调向 Rust 连接上报一次压力；
4. Rust `pressure_target_fps()` 对非 VP9 会话按 `[60,45,30,15]` 限流；
5. 因为历史 dropped 不随健康窗口归零，队列即使恢复为空，level 3 仍可持续存在；当前 Flush 只清
   queue/backpressure，不清这些累计计数，只有换成新的计数 owner（例如重建硬件 decoder/context 或
   换会话）才可能消除该状态。

结论：一次短时过载累计丢掉 10 帧后，H264/H265/VP8/AV1 会话可能长期被压到 15 FPS。这与
“使用一段时间后不够流畅、恢复不了”直接一致，属于 P0 确定性缺陷。

#### B. 两套回压状态同时写同一个 FPS

Rust streaming loop 先在 `requested_pressure_level != applied_pressure_level` 时立即把请求压力应用到
当前 FPS，又维护一套“连续 5 个 overload window 降级、连续 30 个 clean window 恢复”的
`current_backpressure_level`。同一个状态既被 C++ level 直接覆盖，又被 Rust 的二次迟滞递增/递减，
所以没有唯一决策 owner。若上游累计压力不归零，30 秒恢复路径永远没有机会回到正常等级。

修复必须保留一套权威控制器：C++ 上报窗口样本，Rust 负责最终迟滞与发送；或者 C++ 产出最终
level、Rust 只透传。禁止继续两层都修改目标 FPS。

#### C. AUTO 会话的初始 decoder 与实际协商默认不一致

- ArkTS 在 RustDesk `rustdeskCodec == 0(AUTO)` 时先以内部 codec `3` 初始化 decoder，即 VP9；
- FFI 固定使用 Balanced profile，profile 的默认协议偏好是 H264、60 FPS；
- 第一张实际 H264 keyframe 到达后，native 发现 codec mismatch，销毁并重建 decoder。

这至少会制造首帧期间的 decoder churn；在 decoder 建立、Surface 绑定或关键帧到达较慢的设备上会
放大首连卡顿。它不是持续卡顿的充分解释，但属于可消除的确定性启动浪费。

### 12.3 RustDesk 流畅度：高风险链路

#### A. 收帧、解码入队和 ACK 在同一同步调用栈

Rust streaming loop 收到 `VideoFrame` 后同步执行 `on_video(vf)`，回调跨 FFI 进入 C++ bridge、
extension loader 和 `DecodeActiveNative()`；回调返回后才发送逐帧 `video_received` ACK。硬件路径每帧
执行一次 `new[] + memcpy` 后入队，软件路径也复制到 `std::vector`。`DecodeNative()` 还在整个
codec 检查、重建和入队期间持有 `pipelineMutex`。

因此 decoder 建立、锁竞争、内存分配或入队抖动会同时推迟：

- 下一条网络消息的读取；
- 本帧 ACK；
- 同一 streaming loop 中 mouse/key/control batch 的发送；
- audio、clipboard、cursor 等后续消息分发。

代码已经有 `video callback slow >= 50ms` 和 `video ack slow >= 50ms` 日志，但缺少一条可关联到
session/frame/input 的完整时间线。是否需要增加独立 ingress/admission worker、改变 FFI buffer 所有权
或只优化分配，必须由 Phase 8 trace 决定。

#### B. 队列上限偏向吞吐，不代表低延迟

- 硬件 encoded input queue 上限为 12；
- 软件 decode queue 上限为 30；
- 溢出时硬件路径会丢最旧 encoded frame，软件路径会整队清空并等待关键帧；
- 送显线程按 `frameAvailableCount - frameConsumeCount` 一次消费一个通知，但 NativeImage 更新可能已经
  指向较新 Surface 内容。

在 60 FPS 下，12 帧约等于 200ms，30 帧约等于 500ms。队列“没溢出”并不等于低延迟。计划的
目标不是随意改成固定更小数字，而是用 frame age 和依赖链证明 admission 策略：不能丢坏参考帧，
也不能为了完整播放历史画面而持续展示过期帧。

#### C. 诊断计数存在跨 session 污染

- extension loader 的 `frameCount`、decode return 计数和 inactive display 计数为 callback 内 static；
- bridge cadence 的 last frame、window 和 gap count 也为 static；
- `g_rustdeskVideoPerf` 是全局快照，且 decode 记录固定传入 queue/dropped 为 0；
- 回压又从另一套 active decoder telemetry 读取真实 queue/dropped。

结果是诊断 UI、日志 pressure 和实际控制器可能描述不同窗口；重连后的第一段统计也会继承上一会话
相位。所有性能判断必须先改成 session/generation scoped，再用于验收。

#### D. 输入前端已有 16ms 合并，但出口仍受 streaming loop 影响

ArkTS 鼠标移动用 16ms 窗口保留最新坐标，Rust `ControlInbox` 也会合并 mouse move，方向是正确的。
但 control batch 只在 streaming loop 每轮读消息前发送；如果同步 video callback 卡住，输入仍会排在其
后面。因此要分别测量“ArkTS enqueue -> Rust inbox -> socket send -> remote cursor echo”，不能只看
本地预测光标是否平滑。

### 12.4 长连接停滞现场审计（2026-08-01）

#### A. 脱敏时间线与确定结论

本次只读取真机既有 hilog 和进程状态，没有清日志、重启应用、重新安装或改变网络；原始日志仅保留在
工作区外的临时目录，计划文件不写入端点、Peer、账号、SSID/BSSID、IP、设备 ID 或一次性验证码。

| 相对事件 | 脱敏证据 | 结论 |
|---|---|---|
| 连接建立 | Peer 2FA 通过后进入 `CONNECTED`，首个视频关键帧在约 1 秒内到达 | 认证与首连成功，不是 2FA 阻断 |
| 连接初期 | VP9 hardware decoder 创建失败，回退 FFmpeg software decoder | 是既有流畅度/功耗风险，不是本次终止点 |
| 连接后约 8 秒 | remote audio 累计写入约 684 次/1.31MB 后不再到达；renderer 此后持续拉取并补静音 | 远端静音本身不等于故障，但本地 renderer 缺少 inactivity suspend |
| 约 30 分钟 | video/decoder/present 计数持续增长到断点前，累计收到约 5.1 万次 video callback | 没有证据支持 decoder 自发死锁或先冻结 |
| 终止瞬间 | Rust FFI 报 `streaming failed: Connection aborted (os error 103)` | transport 已进入错误终态 |
| 同一时间窗 | 系统将 WLAN supplier 标记 unavailable、停止对应 network monitor、移除 WLAN IPv4/IPv6、销毁本应用 socket，随后重新关联 AP；其他网络客户端也出现 103 | 本次样本的直接触发是 WLAN 接口下线/重关联，不是已观察到的 Server idle timeout 或主动 relay close |
| 终止之后 | 无新视频，但页面没有进入重连/断线结果；最后一帧继续保留 | 用户看到的“停滞”由客户端终态未闭环放大 |
| 终止之后 | Rust FFI 结束句柄被异步回收，但页面 session/native resource teardown 未被触发 | FFI handle 回收不等于 ArkTS/native 会话清理 |
| 终止之后 | OHAudio 仍约每 5ms 拉取静音，伴随 renderer/server 警告；日志持续快速轮转 | 存在独立的音频静默/日志风暴/资源生命周期缺陷 |

这份证据只能确认“本次样本由网络接口切换触发”。它同时确认了两个与触发源无关、任何 transport
终态都会命中的客户端 P0：**连接后没有 RustDesk 持续状态监控/恢复状态机**，以及 **stream 终止没有
立即静默所有数据面资源**。

#### B. 代码责任边界

1. `RemoteDesktop.ets` 的 `waitForNativeConnected()` 只覆盖建连阶段；连接成功后仅 RDP 启动
   `startRdpNativeStateMonitor()`，RustDesk 没有等价的长生命周期 monitor/event subscriber；
2. native 已公开 `0=DISCONNECTED / 1=CONNECTING / 2=CONNECTED / 3=RECONNECTING / 4=ERROR`，但当前
   RustDesk stream error 直接写 `ERROR`，没有任何 owner 驱动 `RECONNECTING`；
3. `RustDeskBridge::onFfiDisconnect()` 会 detach 并回收已结束的 Rust handle、更新 adapter state，
   但不会调用页面 `disconnectAndCleanup()`；`g_sessions`、renderer/decoder/audio 只有页面显式断开时才进入
   `BeginSessionTeardown()`；
4. Rust streaming loop 对非 timeout recv error 正确返回错误；本次 103 已被及时识别，因此单纯延长
   read timeout 不能修复问题；
5. RustDesk audio 本来是首个 PCM 到达后 lazy create，但 renderer 一旦启动就持续返回 VALID 并补静音；
   `AudioActivityState` 没有 last-PCM/inactivity 状态，transport error 也没有走 `TakeActiveNative()`；
6. 完整 teardown 受 PIP barrier 保护是合理的，但“立即停止输入、音频和旧 callback”不应等待 PIP surface
   最终释放，必须拆成 fast quiesce 与 deferred destroy 两阶段。

#### C. 根因分层与排除项

- **直接触发（本样本已确认）**：WLAN network generation 失效，系统移除地址并销毁旧 socket；
- **用户可见根因（代码已确认）**：RustDesk 连接后没有终态订阅、有界重连和明确断线 UI；
- **资源放大缺陷（代码与日志已确认）**：stream error 后 audio renderer/诊断仍运行，造成静音回调、CPU 与
  日志压力；
- **性能伴随项**：VP9 硬解失败回退软件、累计回压和 skipped present 需要按第 12.2/12.3 节治理；
- **本样本不支持的结论**：不能宣称 hbbr 超时、Server Pro token 过期、Peer 2FA 失效、decoder deadlock、
  relay 主动关闭或系统内存回收是这次 30 分钟终止的原因。

### 12.5 移动快捷栏：结构性冲突

#### RustDesk 顶栏

- policy 已区分 `pc/pad/phone`，但 layout 只有 icon、gap、`topOffset`、button count 和 menu width；
- Pad 与 PC 都是 `topOffset=8`，Phone 是 `topOffset=6`，没有 dock side、orientation 或 safe inset；
- 展开态工具体固定高 520vp，外层固定高 540vp、宽 `100%`，始终定位在顶部；
- 子菜单也固定向下展开，宽度为 300/340/360vp；
- `RemoteDesktop` 根层同时 `expandSafeArea(SYSTEM, TOP/BOTTOM)`，却只监听 keyboard avoid area，
  没有把 SYSTEM/CUTOUT 顶部和侧边 inset 传入顶栏。

所以 Phone/Pad 顶部与状态栏、挖孔、横屏侧边系统区冲突不是小偏移误差，而是 layout contract 根本
没有表达移动端边缘停靠。

#### VNC 顶栏

`VncSessionToolbar` 的收起态和展开态同样固定在顶部中心 `y=8`，展开时 7 个 40x42 按钮横排；它只
测试显示条件、模式切换和 20 秒折叠，没有设备分类、安全区、方向或碰撞测试。VNC 的“组合键”按钮
实际打开修饰键主面板，不会直接打开包含 C/V 的快捷键面板，文案与到达路径不一致。

#### 可复用基础

现有 `RemoteModifierHandle` 已实现 58x42vp 左右吸边胶囊、24vp 可见 tab、拖动和 snap；
`RemoteFloatingPanelPlacementPolicy` 已能将面板锚定到侧边 handle 并选取低碰撞位置。这些可以成为
统一 overlay placement 的基础，但目前 viewport 顶边仍是固定 48/70vp、底边是 keyboard 或 24vp，
尚未消费真实 SYSTEM/CUTOUT/nav inset，也只局部处理 diagnostics 碰撞。

### 12.6 全协议 C/X/V 组合键审计

| 协议/入口 | 当前状态 | 缺口 |
|---|---|---|
| RDP | 共享侧边修饰键面板；长按胶囊后快捷面板有 Ctrl+C、Ctrl+V | 无 Ctrl+X；C/V 不可发现；没有语义目录 |
| RustDesk | 与 RDP 共用面板和 dispatcher | 无 Ctrl+X；虚拟组合键没有复用当前 macOS layout 选择 |
| VNC | 顶栏“组合键”只打开修饰键面板；长按另一个胶囊才到 C/V | 无 Ctrl+X；入口误导；只读必须统一禁用；远端 OS 未建模 |
| SSH | `VirtualKeyBar` 只有 Esc/Tab/Ctrl/Alt/Shift/导航键 | 没有 C/V/X 专用键；移动端没有可发现“粘贴本机文本”入口 |

额外语义事实：

- RDP 目标在本项目中固定为 Windows，可用 Ctrl+C/X/V；
- RustDesk 已有每 session 的 Windows/macOS 键盘布局选择，实体键在 macOS 下交换 Ctrl/Meta，但虚拟
  shortcut 数组仍硬编码 Ctrl；
- RustDesk Pro host 有 `rustdeskProPlatform` 提示，native PeerInfo 也知道 platform，但后者没有形成
  统一 ArkTS session metadata；
- VNC 协议本身不可靠提供远端 OS，必须增加 per-host/session layout 选择，不能静默假定所有 VNC 都是
  Windows；
- SSH 中 `Ctrl+C` 是中断、`Ctrl+V` 通常是 quoted-insert、`Ctrl+X` 是 shell/editor prefix，不是图形
  剪贴板；当前桌面 SSH 已有安全的 `handlePaste()`、256KB 限制、多行确认和 bracketed paste，但该
  方法明确拒绝移动设备，Phone/Pad 的 VirtualKeyBar 无对应入口。

结论：用户感知“全局没有 C/V/X”是合理的。虽然远程桌面隐藏面板已有 C/V，但到达路径依赖 500ms
长按且没有 X；SSH 则确实三者都没有专用入口。

## 13. RustDesk 低延迟目标架构

### 13.1 单 session 性能时间线

为每个 `sessionId + connectGeneration + displayGeneration` 记录单调时钟事件，不记录敏感端点：

```text
socket frame received
  -> protobuf parsed
  -> ffi callback enter/exit
  -> native admission enter/exit
  -> decoder queue depth/drops delta
  -> decode submitted/output available
  -> render begin/swap end
  -> frame presented

input collected
  -> ArkTS coalesced
  -> native/Rust inbox
  -> socket send
  -> remote cursor echo (when available)
```

最少派生指标：received/decode/present FPS、本地 ingress-to-present frame age p50/p95/max、callback
p50/p95/max、decode submit
p50/p95、queue p50/p95/max、drops delta、keyframe wait、render/swap p50/p95、input enqueue-to-send p95、
remote echo p95、pressure level 和实际发送的 target FPS。

远端采集时间戳与本机单调时钟未建立可信同步前，不把本地 frame age 冒充网络端到端延迟；只有协议
时间戳或双端 trace 可校准时才报告 capture-to-present。

所有计数在 session 开始归零，disconnect/supersede 后停止写入；diagnostics HUD 与回压读取同一份只读
snapshot，禁止各自重算不同 pressure。

### 13.2 窗口化回压与唯一 owner

引入时间窗口样本，而不是拿累计总数直接决策：

```text
PressureSample {
  intervalMs,
  queueDepthP95,
  queueDepthMax,
  droppedDelta,
  keyframeWaitDelta,
  callbackP95Us,
  presentFps,
  frameAgeP95Ms
}
```

规则：

1. dropped total 只用于诊断，不进入当前 level；level 只使用窗口 delta；
2. 连续健康窗口必须可恢复，队列为 0 且 droppedDelta=0 时历史事故不得阻止恢复；
3. 只有一个 owner 应用 degrade/recover 迟滞和发送 runtime option；
4. 变更 target FPS/quality 后设置最小驻留期，防止 15/30/45/60 抖动；
5. VP9 不再硬编码永久绕过全部压力，而是先通过真机能力矩阵确定独立阈值；
6. display switch、PIP、前后台、decoder recreate 会重置窗口但保留只读总计；
7. 发送 refresh/keyframe 必须限频，不能每个 level 采样都造成额外编码抖动。

### 13.3 ingress、解码与 ACK 的决策门

Phase 8 先对三种方案做 trace/A-B，禁止直接选最复杂方案：

| 方案 | 适用条件 | 风险 |
|---|---|---|
| 保持同步，优化分配/锁 | callback p95 很低，主要问题是压力锁死或送显 | 结构简单，但无法隔离偶发重建 |
| C++ bounded admission worker | callback 明显阻塞网络/输入，复制成本可接受 | 必须保证 FFI borrowed buffer 在 callback 内完成所有权复制 |
| FFI owned buffer + release callback | memcpy/分配已被 profile 证明为主瓶颈 | ABI、生命周期、双 ABI 和断连回收风险最高 |

无论选哪种，ACK 语义必须与官方协议兼容。不能为追求异步而在 frame 未被安全接管前 ACK，也不能
把 input/control 排在可无限增长的视频任务之后。

### 13.4 低延迟 admission 与送显

- 硬件和软件 queue 使用同一种 policy 接口，但阈值可按 backend/codec/capability 不同；
- 目标是限制 frame age，不是简单“每帧都解码”或“只保留最后一帧”；
- H264/H265/VPx/AV1 的参考依赖不同，丢帧后必须等待/请求可恢复关键帧，不能任意丢中间参考帧；
- software queue 达到危险水位前应提前降流，而不是堆到 30 后整队清空；
- NativeImage 多个 frame-available 通知要验证是否应合并为“下一次呈现最新可用 Surface”，避免对同一
  最新 buffer 重复 swap；
- transform/redraw 与新视频帧分开计数，旋转或缩放不得伪增 display FPS；
- decoder lifecycle 锁与热路径锁分离前必须证明不会产生 use-after-free、旧 generation render 或
  disconnect deadlock。

### 13.5 编码器和设备能力策略

1. AUTO 初始 decoder 必须与 FFI profile 的实际首选一致，或延迟到首张带 codec 的 keyframe 再创建；
2. 记录 requested codec、negotiated codec、actual decoder backend 和 fallback reason；
3. AUTO 优先选择设备能稳定硬解的 codec，软件 VP8/VP9/AV1 只在真机预算允许时进入高帧率档；
4. 显式选 codec 若只能软件解码，应在设置页提示预计功耗/帧率，不静默当作等价选项；
5. 分辨率、FPS、quality 与 codec 联合决策，不能仅降 FPS 而持续保留超出设备预算的 4K 软件解码；
6. 同一 endpoint/设备的 capability cache 只保存非敏感能力和失败原因，并按应用版本/系统升级失效。

### 13.6 长连接连续性状态机

建立唯一的 `RustDeskConnectionContinuityOwner`，同时消费 native transport 终态和系统 network generation
变化；系统网络回调只是提示，最终结果仍以新 socket/协议握手为准。优先使用 native -> ArkTS 的事件通知，
500ms 轮询只能作为丢事件兜底，不能复制一套互相竞争的重连 owner。

```text
Connected
  -> TransportLost(errorClass, oldGeneration)
       -> FastQuiescing
       -> WaitingForNetwork
       -> Reconnecting(attempt, newGeneration)
            -> Connected
            -> ReauthRequired(Peer2FA | ServerPro2FA | approval)
            -> WaitingForNetwork
            -> Failed(explicit reason, manual retry)
  -> Closed(user | auth reject | policy | protocol violation)
```

状态机规则：

1. `TransportLost` 到达后立即冻结最后一帧并覆盖“正在重新连接”状态，不再让静止画面冒充在线；同步关闭
   `inputForwardReady`，丢弃/释放 held keys、mouse coalescing、clipboard producer 和文件发送；
2. fast quiesce 必须在 PIP/surface 最终回收之前停止 audio renderer、decoder admission 和旧 generation
   callback；deferred destroy 继续复用现有 serialized teardown/PIP barrier；
3. 网络不可用时只等待，不空转连接；网络可用后立即一次，然后按 `1s / 2s / 5s / 10s`、`±20%`
   jitter 重试，总计最多 5 次且不超过 60 秒。每次都创建新的 Rust FFI handle、socket、session generation，
   old generation 永久失效；
4. Wi-Fi -> Wi-Fi 漫游、Wi-Fi -> 蜂窝/以太网、地址替换都视为旧 socket 不可迁移，统一重连；重复 network
   callback 按 generation 合并，不重置重试预算，不制造连接风暴；
5. `ConnectionAborted/Reset/TimedOut/BrokenPipe/NetworkDown/NetworkUnreachable` 可进入有界恢复；用户断开、
   密码/2FA/approval 拒绝、账号失效、server key/license 不匹配、协议解析/加密错误不得无限自动重试；
6. 每次重连重新执行 rendezvous/direct/relay 选择和 Peer login；不得复用旧 TOTP code。若 Peer 再发 2FA
   challenge，按当前 host binding 和新 counter 生成新码；KeyVault/系统认证不可静默完成时进入
   `ReauthRequired`，不在后台反复弹生物认证；
7. Server Pro access token 与 Peer 2FA 继续是不同 owner：transport 重连不主动重登 Pro；只有 control plane
   明确返回 session/token 失效才进入 Server Pro challenge，并在完成后恢复原重连意图；
8. 重连成功后重建 decoder/audio/display generation、重置窗口化 pressure、请求/等待可恢复关键帧，再开放
   输入；旧最后一帧只在遮罩下保留，首个新 generation frame 呈现后移除遮罩；
9. 重连预算耗尽时进入显式断开页，展示脱敏 error class、重试按钮和返回，不保留假 `connected=true`；
10. watchdog 同时使用 native state、network availability、last socket receive、last video/audio 和 renderer
    activity。静态远端桌面不是故障：只有 control channel/keepalive 也失活或 transport 已终态时才自动重连；
    network 正常但仅视频长期无数据时先限频请求 refresh/keyframe 一次，再按独立 video-stall 策略处理。

连接凭据只允许存在于当前连接/有界重连上下文；离开页面、锁屏策略拒绝、预算耗尽、账号 scope 切换或
用户取消时立即擦除。不得为了自动恢复新增明文密码、TOTP secret、code 或 challenge 持久化。

### 13.7 音频静默、日志与两阶段回收

1. RustDesk 保持“首个有效 PCM 后创建 renderer”，并新增单调时钟 `lastPcmAt`；连续 1500ms 没有 PCM
   时在非 callback 控制线程 Pause/Stop renderer、清队列并回到 prebuffer，后续 PCM 到达时按 60-120ms
   预缓冲恢复。阈值集中为可测 policy，不散落 magic number；
2. transport `DISCONNECTED/ERROR`、session supersede、后台策略关闭和显式退出都调用同一个幂等
   `QuiesceActiveSession(generation, reason)`；目标是 500ms 内不再收到 OHAudio write callback；
3. fast quiesce 只做 stop producer、deactivate callback、stop audio、release held input；可能阻塞的 Rust
   thread join、decoder/renderer release 和 PIP surface 销毁进入 deferred destroy，二者都有 request ID 和
   完成状态；
4. `AudioPlayer::Stop()` 必须覆盖 RUNNING/PAUSED/ERROR 等可释放状态，Destroy 可重复调用；callback 与
   teardown 通过 generation/atomic gate，不能访问已释放 renderer/player；
5. 删除每 100 次静音/underrun 的热循环日志。仅记录状态迁移、首次异常和最多每 60 秒一条聚合摘要；
   transport 终态后不得继续产生 `AudioDiag`、renderer attr 或 position model 周期日志；
6. 诊断只记录 `sessionHash/generation`、network type/generation、error class、lastRx/video/audio age、重连
   次数、quiesce/destroy 耗时和聚合计数，不记录 endpoint、IP、SSID/BSSID、Peer、账号、token、code 或
   剪贴板内容；导出前再次脱敏并设大小/保留期上限。

### 13.8 性能与连续性实施主要文件及测试

主要文件：

- `rustdesk_ffi/src/connector.rs`、`control_inbox.rs`、`protocol/session.rs`；
- `entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp/.h`；
- `entry/src/main/cpp/extensions/extension_loader_napi.cpp`；
- `entry/src/main/cpp/audio/audio_player.cpp/.h`、`audio_activity_state.*`；
- `entry/src/main/cpp/render/hw_decoder.cpp/.h`、`software_decoder.cpp/.h`；
- `video_backpressure_controller.*`、`video_perf_counters.*`、`gl_renderer.*`；
- `RemoteDesktop.ets`、新增 `RustDeskConnectionContinuityPolicy.ets`/network observer、
  `RustDeskDiagnosticsPolicy.ets`、`RustDeskDiagnosticsHud.ets`；
- FFI ABI/static assert、Rust unit tests、native test runner 和 ArkTS diagnostics tests。

新增/强化测试：

- 累计丢 10 帧后，后续健康窗口 level 必须恢复到 0；
- droppedDelta=0、queue=0 时不受 droppedTotal 影响；
- 单 owner 迟滞、最小驻留、降级/恢复和 refresh 限频；
- session A 的 dropped/cadence/frameCount 不进入 session B；
- AUTO 首帧 codec 不发生无必要 VP9 -> H264 重建；
- software/hardware queue 的关键帧恢复、断开清空、display generation 隔离；
- callback worker/owned buffer 若实施，覆盖 shutdown、late callback、内存回收和双 ABI；
- 输入在持续 60 FPS 视频、decoder 重建和 relay 抖动下仍按优先级发送；
- 以 fake clock 测试网络 unavailable/available、重复 generation、退避/jitter/预算和 cancel；
- 以 fault injection 在 streaming recv 注入 103/reset/timeout，验证 fast quiesce、旧 generation 拒绝、
  新 handle 重建及预算耗尽 UI；
- Peer 2FA 重连覆盖新 challenge、新 counter、换码边界、系统认证取消和绝不重放旧 code；Server Pro token
  失效必须进入独立账号状态机；
- audio 覆盖首 PCM lazy start、1500ms 静默暂停、恢复 prebuffer、RUNNING/PAUSED/ERROR teardown、晚到
  callback 和日志限频；
- 真机覆盖 Wi-Fi AP 漫游、开关 Wi-Fi、地址更新、Wi-Fi/有线切换、前后台/PIP/锁屏叠加，并保留脱敏证据。

## 14. Phone/Pad 边缘快捷栏 UI 方案

### 14.1 设备级布局决策

| 设备形态 | 默认位置 | 收起态 | 展开态 | 深层功能 |
|---|---|---|---|---|
| PC/2in1 桌面 | 顶部居中 | 顶部短柄 | 水平工具栏 | 向下 popover |
| Pad | 右侧中部，可拖到左侧 | 24-28vp 侧边 tab | 44-48vp 触控目标的竖向 rail | 向屏幕内侧 popover |
| Phone | 右侧中部，可拖到左侧 | 24-28vp 侧边 tab | 只放 3-5 个高频动作 | 底部 sheet/内侧小面板 |

Phone/Pad 的默认必须是靠边，而不是顶部。用户拖动后按 `deviceClass + orientation` 分别保存 side 和
归一化 y；横竖屏切换先按 ratio 恢复，再经过 safe/collision clamp。默认右侧只是初始值，左手用户可
拖到左侧。

### 14.2 信息架构

边缘 rail 首屏只保留高频且立即可执行的动作：

1. 展开/收起与拖动 affordance；
2. 键盘开关；
3. C/X/V 快捷入口或“组合键”入口；
4. 控制模式/画面适配；
5. 断开连接（危险色并二次防误触策略按现有产品规则）；
6. 其余聊天、录制、虚拟显示、性能 HUD、文件等进入 overflow，不把未接线能力占满首屏。

Pad 可在 rail 内显示更多动作；Phone 深层设置优先用 bottom sheet，避免窄屏 popover 覆盖远程内容。
菜单必须向屏幕内部展开：右侧 rail 向左开，左侧 rail 向右开。

### 14.3 统一 overlay placement contract

新增只读布局输入：

```text
OverlayViewport {
  width, height,
  systemTop, systemBottom, systemLeft, systemRight,
  cutoutRects,
  keyboardRect,
  orientation,
  deviceClass,
  occupiedRects[]
}
```

`occupiedRects` 至少包含 modifier handle/panel、shortcut panel、diagnostics HUD、文件传输状态、PIP 保留区
和当前打开的 session menu。统一 resolver 输出 dock side、handle rect、expanded rect、menu direction 和
fallback（collapse/bottom sheet）。

要求：

- 从 API 23 的 SYSTEM、CUTOUT、KEYBOARD avoid area 获取真实 inset，不再使用 6/8/48/70vp 猜值；
- 状态栏可见、导航栏隐藏、手势条、挖孔、瀑布屏、横屏侧边 inset 都要参与；
- overlay 只能在自身可见控件 rect 命中，删除 RustDesk 展开态全屏宽 x 540vp 的透明命中层；
- 两个 rail 不得占同一边同一 y；无法避让时按优先级合并入口或折叠低优先级面板；
- keyboard 弹出时先避让，空间不足自动收起，不把 rail 推到系统顶区；
- split screen、窗口缩放和方向变化使用 generation，旧测量回调不得覆盖新位置；
- 断开/换协议后清理本 session overlay owner，不遗留不可见 hit target。

### 14.4 视觉与可用性交付物

编码前必须形成并评审以下实体设计材料：

- PC、Pad 竖/横、Phone 竖/横共 5 套收起/展开线框；
- 左/右 dock、菜单内开、键盘弹出、挖孔和碰撞共至少 8 个状态图；
- 颜色、模糊、阴影、危险动作、激活态、禁用态和按下态 token；
- 最小触控目标 44x44vp，视觉 tab 可以小于 44vp，但命中区不得越过 safe area；
- 图标配可读 label/accessibilityText，不能只靠颜色表达锁定、只读或危险；
- 首次提示只解释“可拖到左右边、点击展开”，不依赖用户发现长按隐藏功能；
- 深浅主题、放大字体、屏幕朗读、外接鼠标 hover/右键和 RTL 评审。

### 14.5 UI 实施文件与测试

主要文件：

- `RemoteSessionTopBarPolicy.ets`、`RemoteSessionTopBar.ets`；
- `VncSessionUiPolicy.ets`、`VncSessionToolbar.ets`；
- `RemoteModifierHandle.ets`、`RemoteModifierPanel.ets`；
- `RemoteFloatingPanelPlacementPolicy.ets` 和新增统一 overlay policy；
- `RemoteDesktop.ets` 的 avoid-area listener、overlay registry 和生命周期；
- 对应 `entry/src/test` 与 `entry/src/ohosTest` policy/UI 测试。

测试至少覆盖：

- PC 不回归，Phone/Pad 默认 side dock；
- Phone/Pad 横竖屏、左右 dock、split screen、窗口 resize；
- SYSTEM/CUTOUT/nav gesture/keyboard 的每种组合；
- modifier、shortcut、diagnostics、session rail 两两及三者碰撞；
- menu 始终向内、完全可见，空间不足走 bottom sheet；
- 全屏远程画布除实际按钮外可正常点击/拖动；
- 旋转时旧 area callback 不覆盖新 generation；
- 44vp 命中、无障碍、放大字体和危险按钮防误触。

## 15. 全协议虚拟组合键目标架构

### 15.1 不以原始 keycode 数组作为产品模型

建立 `RemoteShortcutCatalog/Policy`，条目至少包含：

```text
ShortcutAction {
  id,
  semanticKind,
  label,
  icon,
  protocolSet,
  remoteOsSet,
  capability,
  danger,
  discoverability,
  dispatchKind,
  keySequence | textProvider
}
```

UI 只发 semantic action ID；policy 根据协议、远端 OS/layout、view-only、browse mode、连接状态和剪贴板
能力解析最终动作。页面不得继续散落 `[2072, 2019]` 这类产品语义。

### 15.2 C/X/V 必须拆成三类语义

| 语义 | 远程桌面 | SSH |
|---|---|---|
| Copy | 远端应用 Copy key chord | 本地复制终端选区，不发送 Ctrl+C |
| Cut | 远端应用 Cut key chord | 不映射为“剪切”；可单列发送 Ctrl+X prefix |
| Paste shortcut | 向远端应用发送 Ctrl/Command+V | 不标作粘贴；Ctrl+V 是 quoted-insert 控制字符 |
| Paste local text | 按现有 clipboard policy 同步/注入文本 | 读取本机剪贴板，执行 256KB、多行确认、bracketed paste |
| Terminal Ctrl+C/V/X | 不显示为终端控制 | 分别发送 `0x03`、`0x16`、`0x18` |

这样既满足用户需要的“Ctrl C/V/X 按键”，又避免在 SSH 上把中断命令标成复制。

### 15.3 协议与远端系统解析

#### RDP

- 远端系统固定 Windows；Copy/Cut/Paste shortcut 分别解析为 Ctrl+C/X/V；
- key chord 是远端键盘输入，不因本地 clipboard sync 关闭而禁用；
- `Paste local text` 才受 RDP clipboard capability 和权限控制。

#### RustDesk

- native PeerInfo platform 是连接后的权威值，Pro `rustdeskProPlatform` 只作为连接前提示；
- 未取得 platform 时使用现有每 session Windows/macOS 选择，不猜测；
- Windows/Linux 使用 Ctrl+C/X/V，macOS 使用 Command+C/X/V；
- 虚拟、实体、IME 和 shortcut 共用同一 `RemoteKeyboardLayout`，不能各自映射；
- browse mode/输入阻断/display switch pending 时动作显示原因并禁止发送。

#### VNC

- 新增 per-host/session `remoteKeyboardLayout`（至少 Windows/Linux Ctrl、macOS Command）；
- legacy/unknown 默认显示明确的“Ctrl C/X/V”，允许用户在会话控制台切换，不静默声称已识别 OS；
- view-only 时全部 outbound shortcut disabled；本地复制诊断文本等本地动作不受影响；
- 顶栏“组合键”必须直接到 shortcut surface，不能先到另一个面板再要求长按。

#### SSH

- VirtualKeyBar 增加直接可见的 `Ctrl+C`、`Ctrl+V`、`Ctrl+X` 终端控制键；
- 增加独立“粘贴文本”动作，Phone/Pad 复用现有 256KB 限制、多行确认和 bracketed paste；
- 增加“复制选区”入口，复用 TerminalEmulator/native terminal selection，不发送控制字符；
- 发送专用 Ctrl action 后不污染 sticky Ctrl/Alt/Shift，原锁定状态按明确策略恢复；
- shell/editor application mode 不改变 C/V/X 控制字节，但 UI 帮助文案说明常见含义。

### 15.4 可发现性与布局

- 远程桌面 shortcut surface 第一行固定为 `复制 / 剪切 / 粘贴快捷键`，显示实际 chord 副标题；
- `粘贴本机文本` 与 `发送远端粘贴快捷键` 必须是两个动作，避免 clipboard sync 误解；
- Phone/Pad 点击侧边 rail 的 C/X/V 入口即可到达，不要求 500ms 长按；
- PC 可以保留快捷面板，但 C/X/V 同样在第一屏；
- SSH 第一屏直接显示 `Ctrl+C / Ctrl+V / Ctrl+X / 粘贴文本`，空间不足横向滚动或进入第二行，
  不能藏在无提示长按里；
- 最近使用排序不得移动危险动作，Ctrl+Alt+Del 始终独立分组。

### 15.5 原子发送与生命周期

- shortcut dispatcher 按全部 down、逆序 up 原子发送；中途失败也执行 best-effort release；
- semantic shortcut 与 sticky modifier 隔离，执行前快照、执行后恢复，不产生重复 Ctrl down；
- session/generation、input capability 和 view-only 在 resolve 与 dispatch 两次检查；
- disconnect、focus lost、应用后台、layout 切换、browse mode 和 display switch 都 release held modifiers；
- 长按/双击防抖不得重复发送完整 chord；
- 组合键日志只记录 action ID、protocol、layout、result，不记录剪贴板内容或按键文本序列；
- `Paste local text` 沿用敏感数据边界，不进入普通诊断和 crash breadcrumb。

### 15.6 组合键实施文件与测试

主要文件：

- 新增 `RemoteShortcutCatalog.ets` / `RemoteShortcutPolicy.ets`；
- `RemoteKeyDispatcher.ets`、`RemotePhysicalKeyboardPolicy.ets`；
- `RemoteModifierPanel.ets`、`RemoteModifierHandle.ets`；
- `VncSessionToolbar.ets`、`RemoteSessionTopBar.ets`、`RemoteDesktop.ets`；
- `VirtualKeyBar.ets`、`SshTerminal.ets`、`SshTerminalInputPolicy.ets`；
- RemoteHost/VNC host 的远端 layout 元数据与迁移；
- ArkTS unit/ohosTest、native input adapter tests。

测试矩阵：

- RDP Ctrl+C/X/V 的 down/up 和 reverse release；
- RustDesk Windows Ctrl 与 macOS Command 的同一 semantic action；
- RustDesk 未知 platform 使用 session 选择且重连不误继承另一 host；
- VNC Windows/macOS layout、unknown fallback 和 view-only 禁止；
- SSH Ctrl+C=`0x03`、Ctrl+V=`0x16`、Ctrl+X=`0x18`；
- SSH Paste Text 的单行、多行取消/确认、bracketed paste、256KB 拒绝和移动端路径；
- sticky modifier 开/关、发送失败、断开、前后台、方向切换无卡键；
- clipboard sync off 时远端 Copy/Cut/Paste chord 仍可发送，但 Paste Local Text 正确禁用；
- UI 第一屏存在 C/X/V，accessibilityText 与实际解析 chord 一致。

## 16. 扩展实施阶段

### Phase 8：性能、连续性与 UI/快捷键契约冻结

目标：在动热路径前建立可复现基线，并把 UI/semantic 决策变成测试契约。

任务：

1. 在同一 HarmonyOS 设备、同一受控端、同一网络上记录本客户端与固定官方客户端基线；
2. 为 session 性能时间线增加测试先行的数据模型，不先改变调度；
3. 捕获 direct/P2P/relay、H264/H265/VP9、1080p/2K 的 5 分钟动态画面；
4. 输出 callback、queue、drop delta、frame age、present 和 input latency 基线；
5. 完成第 14.4 节线框和状态图，冻结 PC/Pad/Phone layout contract；
6. 冻结 ShortcutAction 语义、协议矩阵、远端 layout owner 和迁移边界；
7. 固化本次约 30 分钟/103/WLAN 重关联的脱敏时间线与 fault fixture，并定义 error class、network
   generation、fast quiesce 和 reconnect snapshot；
8. 为累计丢帧锁死、AUTO codec mismatch、post-connect RustDesk ERROR 无 owner、audio 静音回调、
   移动 top dock、C/X/V 缺失写失败测试。

退出门：能用 session ID 把一次卡顿定位到网络、callback、decoder queue、present 或 input；UI 和快捷键
评审无未决 P0/P1。没有基线不得进入 pipeline 重构。

### Phase 9：回压 P0 修复

目标：先消除“过载后永久 15 FPS”，不夹带线程/ABI 大改。

任务：

1. 压力判断改为 interval delta；累计 dropped 只显示；
2. 选择并实现唯一压力 owner；
3. 合并 degrade/recover 迟滞、最小驻留和 refresh 限频；
4. session/display/decoder lifecycle 重置窗口；
5. HUD、日志和控制器读取同一 snapshot；
6. 覆盖 VP9、software、hardware 和切换 codec；
7. 真机制造短时过载，证明恢复而非重连恢复。

退出门：累计 dropped 任意大但连续健康窗口后 level=0、target FPS 回到配置值；无频繁 runtime option
抖动；Rust/native 定向测试和双 ABI 通过。

### Phase 10：pipeline、codec 与送显优化

目标：根据 Phase 8 数据只修实际主瓶颈。

任务：

1. 决定同步优化、bounded worker 或 owned-buffer ABI；记录 ADR 和未选方案原因；
2. 消除 AUTO 初始 VP9 与 Balanced H264 的无必要重建；
3. hardware/software admission 以 frame age 和关键帧恢复为核心；
4. 验证/实现 frame-available 合并与呈现 pacing；
5. video 热路径不得饿死 control/input/ACK；
6. 处理 display switch、PIP、前后台、旋转、重连和断连回收；
7. 逐 checkpoint 做 CPU、内存、温升、电量和官方客户端对照。

退出门：第 17.1 节性能矩阵达到门槛；没有 use-after-free、旧帧、卡键、decoder deadlock 或 ABI 泄漏。

### Phase 10A：长连接网络恢复与资源静默

目标：把本次 103 现场样本固化为可注入测试，并让所有可恢复 transport loss 走同一有界状态机。

任务：

1. 先为 post-connect `ERROR/DISCONNECTED`、network generation 和错误分类写失败测试；
2. 增加 native 状态事件与 ArkTS 唯一 continuity owner，轮询只作兜底；
3. 把 teardown 拆成 500ms fast quiesce 与 deferred destroy，先关闭输入、音频和旧 callback；
4. 实现 network-aware `0/1/2/5/10s`（首次可用立即尝试）有界退避、jitter、5 次/60 秒预算和取消；
5. 每次恢复创建新 FFI/session/display generation，重建 decoder/audio 并以关键帧开放输入；
6. 接入 Peer 2FA 新 challenge/新 counter 与 Server Pro 独立 reauth 分支，禁止旧 OTP/code replay；
7. 实现 1500ms audio inactivity suspend、恢复 prebuffer、终态立即 stop 和热日志限频；
8. fault injection 覆盖 103/reset/timeout/auth reject/用户断开，真机覆盖 Wi-Fi 漫游、开关、地址替换、
   网络类型切换和前后台/PIP 组合；
9. 完成第 17.2 节 2/4/8 小时 soak 与脱敏诊断审核。

退出门：transport 终态 1 秒内有可见状态、500ms 内完成 fast quiesce；受控网络恢复后 10 秒内重连或给出
明确的 `ReauthRequired/Failed`，旧 generation 零回调、零输入、零 OTP 重放，日志与资源无持续增长。

### Phase 11：统一移动边缘会话栏

目标：PC 顶部行为不回归，Pad/Phone 默认侧边且不再侵入系统区域。

任务：

1. 新增统一 overlay viewport/placement policy 与纯测试；
2. RemoteDesktop 获取 SYSTEM/CUTOUT/KEYBOARD/nav avoid area；
3. RustDesk top bar 重构为 PC top / mobile side 两种 renderer；
4. VNC toolbar 接入同一 policy；
5. 合并 modifier、shortcut、diagnostics 的 occupied rect/collision；
6. 保存 device class + orientation + side + y ratio；
7. 删除全宽透明 hit surface；
8. 完成视觉、无障碍、旋转和真机手势验收。

退出门：第 17.3 节全部通过；Phone/Pad 任何支持方向都没有系统区重叠和不可点击远程画布。

### Phase 12：全协议 C/X/V 与 shortcut catalog

目标：让所有当前支持连接都能从可发现入口完成正确语义的 C/X/V。

任务：

1. 建立 semantic catalog 和 capability resolver；
2. RemoteKeyDispatcher 支持 semantic、layout 映射、sticky snapshot/release；
3. RDP/RustDesk/VNC 第一行加入 Copy/Cut/Paste shortcut 与 Paste Local Text 分离；
4. RustDesk 统一 PeerInfo/Pro hint/session selection；
5. VNC 增加远端 layout 配置、legacy migration 和 view-only 门；
6. SSH 增加 Ctrl+C/V/X、Copy Selection、Paste Text 移动端安全路径；
7. 顶栏、侧栏、胶囊和控制 sheet 的“组合键”入口指向同一 catalog；
8. 完成协议、OS、设备、lifecycle 和无障碍矩阵。

退出门：第 17.4 节全部通过；任何 UI label 与最终发送序列不一致都算 P1。

### Phase 12A：Server Pro 地址簿标签闭环

目标：保留个人簿、共享簿与 legacy 地址簿的归属、membership、标签、颜色和权限，让标签从 API 数据
成为可搜索、可筛选、按权限受控写回的完整产品能力，同时与本地单值 `groupId` 严格分离。

任务：按第 18.5 节完成 fixture、模型、原子同步、owner-scoped cache、只读 UI、权限门禁与后置 mutation。

退出门：第 18.6 节全部通过；跨簿 destructive de-dup、部分分页覆盖 last-known-good、只读簿发出写请求或
把 Server Pro 多标签投影到本地单工作组，任一项存在均算 P1。

### Phase 12B：2FA 品牌头像覆盖与加载治理

目标：用版本化、本地优先且逐项审计的品牌资产替代逐卡运行时 CDN，把“进入页面后等待头像”改为首帧
稳定占位、本地资源快速替换，并消除错误品牌、失效 slug、N 个 ticker 和隐私/商标歧义。

任务：按第 19.4 节完成 manifest、资产/provenance validator、精确 resolver、共享 cache/ticker、首帧策略和
默认关闭的显式远程回退。

退出门：第 19.5 节全部通过；默认路径发生品牌网络请求、出现空白头像、已知误匹配或资产来源/权利字段
不完整，任一项存在均算 P1。

### Phase 13：整体验收、独立复核与发布

目标：双 2FA、地址簿标签、2FA 品牌头像、流畅度、长连接、移动 UI 和全协议输入作为一个产品版本收敛，
而不是分别“局部完成”。

任务：

1. 重跑双 2FA、地址簿标签、品牌头像、性能、长连接、UI、shortcut 全矩阵；
2. 使用真实 Server Pro、真实 Peer、direct/P2P/relay、RDP、VNC、SSH 和 API 23 真机；
3. 独立 reviewer 分别检查认证安全、地址簿 owner/权限/缓存、品牌资产许可与隐私、
   network/reconnect/native 生命周期、性能统计、移动交互和输入语义；
4. reviewer 修复后完整重跑，不接受只跑失败用例；
5. 双 ABI release、Hvigor 两门、Light/Release 合规、secret 扫描全部通过；
6. 更新 CURRENT/QUEUE/ADR、升级说明、设置迁移和回滚说明；
7. 任务分支提交、push、draft PR、required checks、合并回 main、清理分支。

退出门：无未解决 P0/P1/P2，所有真实矩阵有脱敏证据；否则发布 `NO-GO`。

## 17. 扩展验收矩阵与量化门槛

### 17.1 RustDesk 性能矩阵

场景至少覆盖：

- 网络：LAN direct、LAN rendezvous/P2P、真实 hbbr relay、100ms RTT/1% loss 受控网络；
- 画面：静态桌面、文本滚动、窗口拖动、网页滚动、30/60 FPS 视频、多显示器切换；
- 分辨率：1080p、2K，支持设备再加 4K；
- codec：AUTO、H264、H265、VP9；VP8/AV1 在服务端和设备支持时加入；
- quality：速度、平衡、画质；
- lifecycle：首次连接、重连、PIP、前后台、旋转、锁屏恢复、display switch；
- 输入：触控板、直接触控、外接鼠标 60/120Hz、实体键盘与虚拟组合键。

动态画面稳态门槛：

1. 临时过载结束后 10 秒内压力至少开始恢复，连续健康窗口后回到 level 0，不要求重连；
2. queue=0 且 droppedDelta=0 时 target FPS 不得因 droppedTotal 保持 15/30；
3. 在 ingress >= 20 FPS 的动态窗口，present FPS 不低于 ingress 的 85%，且不得通过重复 redraw 虚增；
4. LAN 同场景相对固定官方客户端：present FPS 不低于其 90%，frame-age p95 不高超过
   `max(20ms, 20%)`；若未达到必须记录平台能力 blocker，不得调低验收线掩盖；
5. ArkTS input enqueue 到 socket send p95 <= 32ms；decoder 重建窗口允许单次例外，但不能连续饿死输入；
6. 5 分钟持续动态画面无无法解释的连续 2 秒 queue>=8，无内存持续增长；
7. 性能 HUD 与脱敏 trace 的 received/decode/present/queue/drop/pressure 数值一致；
8. 30 分钟运行无持续 thermal severe 导致的隐性 15 FPS；若系统热控触发，UI 明确归因并保守降档。

### 17.2 RustDesk 长连接与恢复矩阵

| 场景 | 注入/操作 | 必须结果 |
|---|---|---|
| 本次样本回放 | streaming recv 注入 `ConnectionAborted(103)` + network unavailable/available | 1 秒内重连遮罩，500ms 内停 audio/input；网络可用后新 generation 恢复 |
| Wi-Fi AP 漫游 | 保持应用前台，切换同网段 AP | 旧 socket 不复用；去重 network callback；无永久最后一帧 |
| 地址替换/DHCP 更新 | 移除并重新分配 WLAN 地址 | waiting-network 不空转；恢复后重新 rendezvous/direct/relay |
| Wi-Fi 开关 | 关闭 5/15/45 秒后开启 | 重试预算不被重复 callback 重置；恢复或明确 Failed |
| 网络类型切换 | Wi-Fi <-> 有线/可用蜂窝 | 使用新 network generation；旧 callback/按键不得跨代 |
| relay 抖动 | 100ms RTT、1% loss、短时 reset/timeout | 可恢复错误有界退避；不形成连接风暴 |
| 认证失败 | 密码错、Peer 2FA 错、approval reject、Pro token 失效 | 不把 auth failure 当网络无限重试；进入正确 reauth/失败状态 |
| Peer 2FA 重连 | 新 challenge 穿过 TOTP 换码边界 | 仅提交新 counter code；取消系统认证后等待用户，不重放旧 code |
| 静态桌面/无音频 | 画面静止、远端长期静音但 control channel 正常 | 不误判断线；audio 1500ms 后暂停且可被新 PCM 唤醒 |
| 前后台/PIP/锁屏 | 在等待网络、重连握手和首帧阶段分别切换 | 单 owner、可取消；PIP barrier 不拖住 fast quiesce |
| 用户主动断开 | 任一 backoff/reauth 阶段点击断开 | 立即取消 timer/connect；不再自动恢复或弹认证 |

量化门槛：

1. native transport 终态到 UI 状态变化 `p95 <= 1s`，到 audio/input fast quiesce `p95 <= 500ms`；
2. 受控网络恢复且服务可用时，direct/P2P/relay 的成功重连 `p95 <= 10s`；需要 2FA/approval 时 1 秒内进入
   `ReauthRequired`，不计用户输入时间；
3. 每次重连至多 5 次/60 秒，退避符合 policy；用户取消后 100ms 内不再启动新 attempt；
4. 新 generation 首帧前不发送用户输入；首帧后旧 generation 的 video/audio/input/clipboard callback 为 0；
5. transport 终态 1 秒后 OHAudio write callback 增量为 0，且不再出现周期性 `AudioDiag`/renderer 警告；
6. 2 小时自动故障注入、4 小时真实 relay、8 小时 LAN/静态+动态混合 soak 均无永久停滞、无限重连、
   日志风暴、线程泄漏或 CPU/内存单调增长；每 30 分钟记录 bounded snapshot；
7. 同一故障用固定官方客户端做对照；若官方同样断开，可记录网络/服务端事实，但本客户端仍必须满足
   状态可见、资源静默和手动/自动恢复边界。

### 17.3 移动 UI 矩阵

| 设备 | 方向/窗口 | 系统状态 | 必须结果 |
|---|---|---|---|
| Phone | 竖屏 | 状态栏+手势条 | 右侧默认 dock，无遮挡，画布可点 |
| Phone | 横屏 | 挖孔/侧 inset | rail 避开挖孔，菜单向内或 bottom sheet |
| Phone | 任意 | 软键盘弹出 | rail 避让或收起，不进入顶部系统区 |
| Pad | 竖/横 | 全屏 | 侧边 rail，拖到左右并分别保存 |
| Pad | 分屏/浮窗 | resize | clamp 到新 viewport，旧 callback 不回写 |
| PC/2in1 | 小窗/全屏 | hover/鼠标 | 顶部栏保持，popover 完全可见 |
| 全部 | diagnostics+modifier+shortcut | 多 overlay | 无重叠死区，低优先级可折叠 |
| 全部 | 放大字体/读屏 | accessibility | label 可读、44vp 命中、顺序稳定 |

RustDesk 与 VNC 都执行这张表；不能只修 RustDesk 后让 VNC 保留相同顶部冲突。

### 17.4 组合键矩阵

| 协议 | 远端/layout | C | X | V | 本机文本粘贴 |
|---|---|---|---|---|---|
| RDP | Windows | Ctrl+C | Ctrl+X | Ctrl+V | 受 RDP clipboard capability 控制 |
| RustDesk | Windows/Linux | Ctrl+C | Ctrl+X | Ctrl+V | 受 RustDesk clipboard policy 控制 |
| RustDesk | macOS | Command+C | Command+X | Command+V | 受 RustDesk clipboard policy 控制 |
| VNC | Ctrl layout | Ctrl+C | Ctrl+X | Ctrl+V | 受 VNC clipboard capability 控制 |
| VNC | macOS layout | Command+C | Command+X | Command+V | 受 VNC clipboard capability 控制 |
| VNC | view-only | 禁用 | 禁用 | 禁用 | 禁用 |
| SSH | terminal | 0x03 | 0x18 | 0x16 | 文本发送+多行确认+bracketed paste |

每格都要验证 Phone、Pad、PC 入口；RustDesk/VNC 还要验证 modifier latch、断开、浏览/只读、方向切换
和连续快速点击。SSH 要分别验证 shell、vim/emacs/tmux 常见环境，但不把特定程序行为当成协议保证。

### 17.5 回滚顺序

1. 性能回压可通过 feature flag 回到保守单 owner 固定档，但绝不能回到累计 dropped 锁死；
2. pipeline worker/owned ABI 若回滚，先停 producer、drain/release buffer，再切回同步 callback；
3. 自动重连可回滚为明确断开+手动重试，但 fast quiesce、generation 隔离和终态 UI 必须保留；
4. 移动 rail 可回滚视觉 renderer，但必须保留 safe inset 和无全宽透明 hit layer；
5. shortcut catalog 可隐藏新增入口，但旧 dispatcher 的 release 安全和 Ctrl+X 数据迁移不得回滚；
6. VNC/RustDesk layout metadata 为 additive，旧版本忽略时不能破坏 host；
7. SSH Paste Text 回滚时保留已有桌面安全限制，不得退回无确认多行粘贴；
8. 任一回滚不触碰 TOTP secret、账号 token、host password 或用户云数据。

## 18. Server Pro 地址簿标签审计与完整修复方案

### 18.1 官方能力基线

官方 Server Pro 文档把 Address Book 列为 Pro 能力，并明确支持通过
`--address_book_tag` 分配设备标签；官方高级设置同时定义标签排序、按标签交集筛选和与最近会话同步，
入口覆盖桌面和移动端：

- [RustDesk Server Pro Web Console](https://rustdesk.com/docs/en/self-host/rustdesk-server-pro/console/)
- [RustDesk Advanced Settings：Address Book Tags](https://rustdesk.com/docs/en/self-host/client-configuration/advanced-settings/)
- [固定上游 `ab_model.dart`](https://github.com/rustdesk/rustdesk/blob/807e05ea9a7e298ed2deb438195faaafce19cdd2/flutter/lib/models/ab_model.dart)
- [固定上游 `address_book.dart`](https://github.com/rustdesk/rustdesk/blob/807e05ea9a7e298ed2deb438195faaafce19cdd2/flutter/lib/common/widgets/address_book.dart)

固定上游实现的最低产品语义不是一个字符串字段，而是：多个个人/共享/legacy 地址簿、每簿独立 tag
集合与颜色、Peer 多标签、虚拟 `Untagged`、默认并集筛选、可选交集筛选、排序、选择清空，以及在
`readWrite/fullControl` 权限下新增/重命名/删除/改色和修改 Peer 标签。

### 18.2 本地确定性根因

| 链路 | 当前实现 | 实际缺口 |
|---|---|---|
| API 模型 | `RustDeskProPeer.tags`、`RustDeskProAddressBook.tags` 已能解析 | 数据只在临时对象中存在 |
| modern tag 拉取 | 只拉 `/api/ab/peers` | 没有调用官方 `/api/ab/tags/{guid}`，因此 tag color 和完整 tag 集缺失 |
| shared profile | parser 只返回 GUID 字符串 | 地址簿名、owner、share rule、write/full-control 权限全部丢失 |
| 多地址簿 | personal/shared GUID 全部循环拉取后合成一个结果 | 地址簿 owner 被扁平化；同一 Peer 按 ID 去重，第二个 membership 的标签/别名/note 可被吞掉 |
| reconcile | 只投影 routing、platform、password 和时间 | `peer.tags`、address-book tags、颜色、note 和 membership 完全不进入持久化或 UI |
| RemoteHost | 只有单值本地 `groupId` | 无服务端多标签字段；`groupId` 是用户工作区，不是 Pro tag |
| 搜索/筛选 | 搜索 label/host/username/protocol/groupId；工作组只支持单值精确筛选 | 标签和地址簿名不可搜索；无并集/交集/未标记筛选 |
| 卡片 | 只显示本地工作组 chip、连接健康和 Pro badge | 不显示服务端 tag、颜色、地址簿来源或只读状态 |
| 测试 | 覆盖 legacy 顶层 `tags` 解析 | 没有 modern tag endpoint、per-peer tag、multi-book、权限、颜色、筛选和 mutation 契约 |

因此用户反馈“地址簿不支持标签”准确：当前只是**部分读取字段**，没有形成可用的标签功能。把
`peer.tags[0]` 写进 `groupId` 只能隐藏问题，并会破坏多标签、同名标签隔离和本地工作组所有权，禁止采用。

### 18.3 目标数据模型与缓存边界

新增 account-scoped、server-owned 的只读投影，不直接扩展成云同步字段：

```text
RustDeskProAddressBookProfile {
  accountId, guidHash/runtimeGuid, name, kind(personal|shared|legacy),
  ownerDisplay, shareRule(read|readWrite|fullControl), canWrite, fullControl,
  revision/updatedAt, syncState
}

RustDeskProAddressBookTag {
  accountId, bookGuid, exactName, color, serverOrder
}

RustDeskProPeerMembership {
  accountId, bookGuid, peerId, alias, note, tags[], platform,
  credentialReference/transientPasswordState, lastSeenAt
}
```

规则：

1. connection `RemoteHost` 与 address-book membership 分离；连接身份继续由 account + Peer 决定，列表 view
   key 使用 `accountId + bookGuid + peerId`，允许同一 Peer 在不同簿中以不同 alias/tag/note 出现；
2. tag identity 是 `accountId + bookGuid + exact server name`；显示保留 Unicode 和大小写，搜索可另建
   locale-folded key，但不得用 slug/lowercase 覆盖服务端原值；
3. 本地 `groupId` 继续归用户；Pro tag、设备组、用户组和工作区组在模型、UI、日志中使用不同名称；
4. profile/tag/membership 离线快照进入 app-private、owner-scoped 加密 cache，绑定 token generation/revision；
   不进入华为云、portable backup、普通 host JSON 或日志，账号删除/登出清除，token generation 变化强制重验；
5. cache 采用 last-known-good 原子替换：分页、任一 shared book 或 tag endpoint 失败时不提交半截快照；
   UI 显示“离线缓存/同步失败”，不能把空页误当服务端删除；
6. 日志只记录 account/book/peer 的脱敏 hash、页码、数量、权限和结果，不记录 GUID、标签文本、alias、note、
   Peer ID、密码或 token。

### 18.4 同步、筛选与写回状态机

读取顺序固定为：

```text
personal profile
  -> shared profiles(all fields + permission, paginated)
  -> for each book: peers pages + tags/colors
  -> validate references and totals
  -> build immutable snapshot
  -> atomic cache commit
  -> UI projection
```

UI 方案：

- RustDesk Pro 列表增加 account 和 address-book selector；普通手动主机列表不出现空标签栏；
- 当前簿显示彩色 tag chips、`未标记`、清除选择、排序开关和“任一/全部”筛选语义；
- 默认多标签为并集，开启“全部标签”后为交集；`未标记` 与普通 tag 组合遵循固定上游语义并有纯测试；
- 全文搜索在当前 account/book/tag scope 内匹配本地显示名、服务端 alias、Peer ID、hostname、tag 和簿名；
  筛选顺序固定为 account -> book -> tags -> text，结果计数可见；
- 卡片显示最多 3 个 tag，超出显示 `+N`；颜色不是唯一信息，读屏读出地址簿名和完整标签；
- Phone 使用可横向滚动/折叠的 tag chips，Pad/PC 可用侧栏；不能让大量标签挤压主机卡片或连接按钮；
- read-only shared book 可完整查看/筛选，但隐藏 mutation；write/full-control 的区别和 Web Console owner 明确展示。

写回必须后置于只读闭环，并按目标 Server Pro 版本 pin fixture：

- modern：`/api/ab/tag/add/{guid}`、`tag/rename`、`tag/update`、`DELETE tag/{guid}` 和
  `/api/ab/peer/update/{guid}`；每个 endpoint 固定 method/body/status/error fixture；
- UI resolve 与 API submit 两次检查 account、book、token generation、permission 和 operation generation；
- mutation 显示 pending，不永久乐观提交；成功后重拉受影响簿，失败/409/权限变化回滚到 last-known-good；
- rename/delete 明确受影响 Peer 数量，delete 二次确认；批量改标签有 bounded batch、部分失败清单和重拉；
- legacy `/api/ab` 整体快照写回只有在目标版本、updatedAt/冲突和最大设备限制全部验证后开放；否则保持
  只读并提供 Web Console 入口，不能覆盖其他客户端的并发修改。

### 18.5 实施任务（对应 Phase 12A）

1. 保存 modern/legacy personal/shared profile、tag/color、membership、permission 和错误 fixture；
2. 先写 multi-book 同 Peer、同名 tag 隔离、分页失败不提交、groupId 不污染的失败测试；
3. 建立 profile/tag/membership 模型、加密 cache、owner cleanup 和 atomic snapshot；
4. API service 拉取完整 shared profile 与 `/api/ab/tags/{guid}`，取消跨簿 destructive de-dup；
5. 先交付只读 selector、chip、并集/交集/未标记、搜索、卡片和无障碍；
6. 真机/真实 Server Pro 验证后按 permission 接入 modern mutation，legacy 写回单独 gate；
7. 覆盖账号切换、token 失效、离线 cache、增量同步、标签删除/重命名冲突和 1000 Peer 大簿；
8. 独立 reviewer 检查 owner、权限、隐私、并发写和本地工作组回归。

退出门：第 18.6 节全部通过；API 能解析但 UI 不可达、只显示第一个 tag、跨簿合并或 read-only 可写均算 P1。

### 18.6 标签验收矩阵

| 维度 | 必测场景 | 必须结果 |
|---|---|---|
| server | legacy、modern personal、shared read/readWrite/fullControl | profile、标签、颜色、权限完整 |
| membership | 同 Peer 在 2 个簿、不同 alias/tag/note | 两个 view membership 不互相覆盖 |
| tags | 0/1/多标签、Unicode、同名跨簿、删除/重命名 | identity 稳定、显示原文、引用一致 |
| filter | 未标记、单标签、OR、AND、清空 | 与固定上游 fixture 一致 |
| search | alias/Peer/hostname/tag/book + tag filter | 组合顺序稳定、无跨账号泄漏 |
| permission | read、readWrite、fullControl、运行中降权 | 双检查；只读零 mutation 请求 |
| sync | 分页失败、tag endpoint 失败、token 过期、离线 | last-known-good 保留，状态明确 |
| local group | 相同/不同 `groupId` 与 Pro tags 并存 | 两套筛选互不改写、迁移无损 |
| scale | 10 簿、100 tags/簿、1000 peers、重复 membership | 筛选 p95 <= 50ms，滚动无明显掉帧 |
| privacy | 日志、云、backup、crash snapshot | 无 GUID/tag/alias/note/Peer/token 明文 |

## 19. 2FA 品牌头像审计与完整修复方案

### 19.1 现场与代码审计结果

当前实现不是“内置真实公司 Logo 库”：`TotpBrandService.ets` 将 issuer 映射到
`https://cdn.simpleicons.org/<slug>`，资源目录中没有任何 TOTP 品牌资产。

2026-08-01 对当前 manifest 做脱敏、无用户数据的 CDN 探测：

- 143 个 issuer/别名映射到 132 个 unique slug；
- 24 个 slug 当前返回 404，只有 108 个返回 SVG 200；
- 失效项包括 `amazon/amazonwebservices/adobe/authy/canva/dingtalk/duosecurity/feishu/heroku/
  huaweicloud/jd/kraken/linkedin/microsoft/microsoft365/microsoftazure/microsoftentra/microsoftteams/
  salesforce/sendgrid/slack/tencentqq/twilio/wechatwork`；
- 当前网络对单个冷请求约 0.7-1.0 秒；这只是审计点，不是产品 SLA；
- CDN 响应虽声明浏览器缓存，但应用没有自有 version/hash、内存 LRU、磁盘 cache、prefetch 或 negative
  cache，不能把平台内部缓存当产品保证。

确定性缺陷：

1. `TotpCodeCard.aboutToAppear()` 每次把 `logoFailed=false`，失效 slug 在页面重进和列表复用后再次请求；
2. 加载中只显示空的 42x42 surface，只有 `onError` 后才切首字母，用户必然看到延迟/跳变；
3. `lookupSlug()` 使用双向 substring，`x`、`jd`、`qq` 等短别名会误命中无关 issuer；
4. `duo -> duolingo` 是确定的品牌错误；`duo security -> duosecurity` 当前又是 404；
5. `TotpEntry.iconUrl` 被模型/备份保存但卡片完全不读取，既不能补自定义头像，也没有远程 URL 安全策略；
6. `totpLogoMode` 默认就是 `logo`，与注释所称“用户启用后才联网”不一致；
7. 每张可见卡片各自创建 1 秒 timer，条目多时造成 N 个 ticker 和重复刷新，放大首屏/滚动负担；
8. “真实 Logo”文案过度承诺。Simple Icons 是社区维护的品牌 glyph 集；其 CC0 不授予品牌商标权，
   单个图标还必须分别检查许可和品牌指南。

Simple Icons 官方说明提供 3400+ 图标、建议在 CDN URL 固定版本，并明确提醒 icon removal 会导致未固定
URL 404，且要求逐项审查许可/商标：

- [Simple Icons README/CDN Usage](https://github.com/simple-icons/simple-icons)
- [Simple Icons Legal Disclaimer](https://github.com/simple-icons/simple-icons/blob/develop/DISCLAIMER.md)
- [Simple Icons License](https://github.com/simple-icons/simple-icons/blob/develop/LICENSE.md)

### 19.2 本地优先品牌 manifest

建立构建时版本化 manifest，禁止继续把映射、颜色和网络策略硬编码在一个 service：

```text
TotpBrandManifestEntry {
  brandId, displayName, aliases[], exactDomains[],
  localAsset, monochrome/fullColor, lightAsset?, darkAsset?,
  sourceUrl, sourceType(simple-icons|official-brand-kit), upstreamVersion,
  sha256, copyrightLicense, trademarkGuidelines, lastAuditedAt,
  officialAssetVerified, remoteFallbackSlug?
}
```

资产分层：

1. 先覆盖当前 132 个意图 slug：可合法使用的全部打包；24 个失效项改用允许的官方 brand kit/替代来源，
   无法确认权利时明确回退 initials，不伪造；
2. 第一版门禁至少 250 个 unique 本地品牌资产、500 个 exact alias/domain，覆盖开发/云、办公、社交、
   金融、密码与安全、中国常见服务；privacy-preserving fixture corpus 命中率 >=95%；
3. 压缩后品牌资源预算 <=2MB；超预算用实际 HAP diff 审批，不能以运行时 CDN 换包体数字；
4. Simple Icons 资产在 manifest 里标为“品牌图标”；只有来源为官方 brand kit、用途符合 guideline 且
   `officialAssetVerified=true` 才允许 UI/文档称“官方 Logo”；
5. 构建脚本校验资源存在、SVG 安全子集、viewBox、hash、重复 alias、许可/商标字段和 source URL；升级
   manifest 时输出新增/删除/许可变化 diff，任何死资源或缺 provenance 阻断构建。

### 19.3 Resolver、缓存与首屏渲染

- resolver 优先级固定为用户明确的本地自定义图 -> exact issuer alias -> exact verified domain -> tokenized
  alias -> initials；删除任意 substring 双向包含，短 alias 必须 exact；
- Unicode NFKC、大小写、空白和常见分隔符只用于 lookup key，不修改用户 issuer；建立误匹配 fixture，
  `Duo/Duo Security` 只能解析安全品牌，未知含 `x/jd/qq` 文本不得误命中；
- 卡片第一帧始终画稳定 initials/background；本地 SVG/PixelMap ready 后无布局变化地替换，失败继续 initials；
  不允许空白等待；
- 列表加载时一次性解析所有 entry 的 `brandId`，仅预解码首屏和前后各一屏；共享 page-level 1Hz ticker，
  删除每卡 timer；
- decoded PixelMap 内存 LRU 上限 64 项/8MB，页面退出可保留小型共享 cache；本地 bundle 不走磁盘网络 cache；
- 可选 remote fallback 默认关闭且 device-local，不进入云。开启前明确说明 CDN 可观察客户端 IP、请求时间和
  public brand slug；用户明确同意后只请求 pinned Simple Icons version 的公开 slug。10 秒超时、
  SVG/content-type/64KB 上限，成功按 version+hash 存 app-private cache <=10MB，404 negative cache 7 天、
  网络失败 10 分钟；请求、URL 和 cache key 不得包含原始 issuer/account；
- `iconUrl` 不自动联网。旧远程 URL 迁移为“待确认自定义头像”；用户确认后只允许 HTTPS、256KB、固定
  像素上限，下载一次、去元数据/重编码、保存本地 hash。新建优先选择品牌库或本地图片；
- 继续复用 `totpLogoMode=logo|initials` 存储值，UI 文案改为“品牌图标/首字母”；`initials` 保证零网络，
  `logo` 表示本地优先，不等于允许 CDN。

### 19.4 实施任务（对应 Phase 12B）

1. 固化现有 143 alias/132 slug/24 dead baseline、常见 issuer fixture 与错误匹配测试；
2. 建立 manifest schema、asset/provenance/license validator 和 HAP size report；
3. 修复 Duo/短 alias/Unicode/domain resolver，接入 250+ 审计后本地资产；
4. TotpCodeCard 改为 initials 首帧 + 本地 asset 渐进替换，增加共享 resolver/cache；
5. 合并每卡 timer 为页面 ticker，验证列表复用、搜索、锁定、主题切换和账号切换；
6. 设计 `iconUrl` 安全迁移和显式 remote fallback，默认首屏零网络；
7. 完成冷/热/离线、弱网、404、资源升级、内存、包体、对比度与 API 23 截图验收；
8. 法务/合规 reviewer 核对商标文案、许可、来源和 third-party notices。

退出门：第 19.5 节全部通过；只增加映射但仍运行时逐卡 CDN、把 404 缓存在组件状态或继续标“真实 Logo”
都不算完成。

### 19.5 品牌头像验收矩阵

| 维度 | 门槛 |
|---|---|
| 覆盖 | >=250 unique 本地资产、>=500 alias/domain、fixture corpus >=95%，manifest 死资源=0 |
| 正确性 | exact/Unicode/domain/unknown/恶意长 issuer 全通过；已知错误品牌=0 |
| 冷启动 | 首屏 initials 无空白；首屏本地 Logo ready p95 <=50ms；默认网络请求=0 |
| 热进入 | 重进页面/滚动复用不闪空白、不重新请求；可见 Logo ready p95 <=16ms |
| 离线/弱网 | 本地品牌 100% 可见；未知立即 initials；remote fallback 不阻塞卡片 |
| 大列表 | 100 条目只有一个 1Hz ticker；滚动无明显掉帧；decoded cache <=8MB |
| CDN 可选路径 | pinned version、成功/404/timeout/非法 MIME/超限全部有 cache/fallback；无请求风暴 |
| 自定义头像 | 未确认 URL 零请求；下载校验、重编码、清理、账号 owner 和删除均通过 |
| 视觉 | Phone/Pad/PC、深浅主题、动态字体、锁定态；initials 对比度 >=4.5:1 |
| 合规 | 每项 source/hash/license/guideline 完整；只有 verified official asset 使用“官方 Logo”文案 |
| 隐私 | 默认路径零网络；日志/crash/cache key 不含 secret、code、原始 issuer、account 或邮箱域名；可选 CDN 仅在披露 IP/public brand slug 暴露并取得用户同意后启用 |

在上述任一项缺失时，只能描述为“本地实现完成”或“特定环境验证通过”，发布状态保持
`NO-GO`。
