# 最小手动诊断日志抓取实施计划（2026-08-19）

> **状态：已完成实现、独立复核与虚拟机验证；待用户实机验收。** 第一版只有一条产品路径：
> 设置 → 日志 → 开始抓取 → 用户复现 → 结束并保存。本文是当前实现和验收的唯一诊断日志计划。

## 1. 当前代码与实施边界

- 2026-08-19 提交前复核快照的活动任务仍是 `moonlight-complete-upgrade`，分支
  `codex/moonlight-complete-upgrade@cc0624d45`，基线为 `main@aeb0cdac5`，相对基线
  ahead 151、behind 0。
- 工作树已有大量 Moonlight、SSH、云同步和窗口相关的用户改动，必须全部保留；不切换分支、
  不 stash、不 reset，不把无关文件纳入日志功能 checkpoint。
- 用户已明确要求在当前分支开始推进日志功能。因此本功能只新增独立 leaf service/component，
  对已有混合文件只做最窄追加，并在每个阶段核对精确 diff。
- 当前连接包括 RDP、RustDesk、SSH/SFTP、VNC、Moonlight/Sunshine。Moonlight 本地数据是
  始终可用真源，当前代码还包含兼容优先的可选云表路径；诊断功能不得改变其云部署开关、
  表注册、选择状态或回退行为。
- 第一版不读取 HiLog。现有 ArkTS `hilog`、native `OH_LOG_*`、Rust `eprintln!` 和 helper
  输出含有错误原文、地址、路径或标识，不能作为安全导出源。

## 2. 最小产品合同

### 2.1 设置入口和交互

- 在全局设置中新增独立动作栏位“日志”，使用与其他设置动作一致的 Symbol icon、尺寸、
  卡片、颜色、圆角和跳转箭头；位置放在“反馈”前。
- 点击后打开独立 `DiagnosticCaptureSettingsSheet`，不改反馈邮件、畅联群聊、评价或各协议
  原有设置 Sheet。
- 用户可选择固定最长时长 `1 / 3 / 5 / 10 / 15 / 30` 分钟，默认 10 分钟。
- 用户可选择大模组；默认只勾选 `应用状态`，其余模块均由用户按复现目标手动勾选。
  `应用状态` 始终启用且不能取消。
- 点击“开始抓取”后固定时长和模块。关闭 Sheet、进入连接页、切换到独立远程窗口或让应用
  在已有后台连接模式下运行，都不会因为 UI 销毁而停止抓取。
- 用户复现完成后回到设置，点击“结束并保存”；运行时立即冻结事件并打开系统保存位置
  选择器。用户选定位置后自动写入并校验，不再出现第二个“导出”步骤。
- 达到最长时长后停止接收新事件，不在后台自动弹出选择器。用户回到设置时显示
  “已到时，待保存”。
- 选择器取消或写入失败时保留冻结事件，可重试保存或明确丢弃。

### 2.2 第一版明确不做

- 不做“最近 N 分钟”的常驻历史缓冲，不在用户点击开始前采集。
- 不做 baseline/final 快照聚合；不轮询既有诊断 HUD，也不为了日志初始化 provider。
- 不读取系统 HiLog、数据库行、Preferences 值、网络包、终端内容、截图、帧或音频。
- 不做 ZIP、自动上传、自动邮件附件、系统分享、崩溃后恢复或持续写盘。
- 不新增权限、后台任务、通知、云表、RDB schema、native/Rust/NAPI ABI。
- 不改现有日志行为，不机械迁移所有日志调用，不增加可调日志等级。

### 2.3 生命周期限制

- 同一进程同时只有一份抓取。
- recorder 是 ArkTS 模块级进程单例，不属于设置组件实例。
- `EntryAbility` 与 `RemoteSessionAbility` 当前同进程；第一版不为此修改 Ability。若应用
  进程被系统杀死，未保存的抓取丢失，UI 必须明确提示这一限制。

## 3. 大模组目录

| moduleId | UI 名称 | 第一版结构化事件 |
| --- | --- | --- |
| `core.app` | 应用状态 | 抓取开始、到时、手动结束；始终启用。保存结果只显示在 UI，不改写 frozen 文件 |
| `connection.rdp` | RDP 连接 | 请求、预检结果、连接状态变化、断开 |
| `connection.rustdesk` | RustDesk 连接 | presence/预检、直连或中继类别、连接状态变化、断开 |
| `connection.ssh_sftp` | SSH / SFTP | 生命周期状态、认证阶段类别、SFTP 任务开始/完成/失败 |
| `connection.vnc` | VNC 连接 | TLS/RFB 预检、连接状态变化、断开 |
| `connection.moonlight` | Moonlight 串流 | 配对/catalog/launch 类别和 coordinator 已提交的状态变化 |
| `data.cloud_sync` | 云同步 | 请求方向、执行/跳过/重试/完成和聚合数量 |
| `data.local_store` | 本地数据库 | 初始化和 `CloudStore` 中央 mutation 结果；不 dump schema、行或备份内容 |
| `network.routing` | 中继与网关 | RustDesk relay/Pro、VNC/RDP Gateway、SSH proxy/forwarding 的阶段与结果 |
| `security.ssh_key` | SSH 密钥对 | 生成、导入、检查、改口令、保存、删除、安装、认证测试结果 |

TOTP 不属于 SSH 密钥日志，保持零接入。

## 4. 最小架构

只新增四个生产文件：

```text
业务中央边界 ── no-throw record(...) ──▶ DiagnosticCaptureRuntime
                                             │
设置 Sheet ── start/status/stop/discard ─────┤
                                             ▼
                                      frozen event array
                                             │
                                             ▼
                               DiagnosticCaptureExportService
                                             │
                                             ▼
                                  DocumentViewPicker + BoundedDocumentIo
```

- `DiagnosticCapturePolicy.ets`：模块、时长、事件目录、结果枚举、容量和序列化合同。
- `DiagnosticCaptureRuntime.ets`：进程单例、单调时钟、状态机、内存上限和事件缓冲。
- `DiagnosticCaptureExportService.ets`：JSONL、DocumentPicker、完整写入、`fsync`、回读校验。
- `DiagnosticCaptureSettingsSheet.ets`：模块/时长选择、开始、结束保存、重试、丢弃。

不再创建独立 snapshot service 或 format service；JSONL 格式函数和导出服务放在同一文件，
避免为第一版拆出没有第二个使用者的抽象。

## 5. 运行时合同

### 5.1 状态机

```text
idle ── start ──▶ capturing ── stop/deadline ──▶ readyToSave
 ▲                    │                              │
 │                    └──────── discard ────────────┤
 │                                                   │
 └──── saved/discard ◀── saving ◀── save/retry ─────┘
                              └── cancel/fail ─▶ readyToSave
```

- deadline 使用 `systemDateTime.getUptime(TimeType.STARTUP)`，不因 wall clock 改动延长。
- 每次 `record()` 和 `status()` 都检查 deadline；到期即冻结。
- `record()` 永不 throw、永不 await，返回值只表示诊断是否接受，业务代码不得使用它决策。
- 未抓取或模块未选时先返回，不读取时间、不分配事件对象。
- 活跃连接只额外保留 `sessionId → moduleId` 的进程内轻量身份，不保留地址或凭据；身份不与
  capture 生命周期绑定，确保已建立连接和第二次抓取仍能记录状态/断开。状态去重按
  `captureId` 隔离。
- 事件上限 10,000 条，总序列化估算上限 8 MiB，单事件上限 1 KiB。达到上限只丢新事件并
  计数，绝不影响业务返回值、异常、锁或 Promise。
- `discard(expectedCaptureId)` 原子校验确认框打开时看到的 capture，只清理对应诊断内存，
  不触碰连接、云任务、数据库、relay、Preferences 或密钥。

### 5.2 固定事件结构

每条事件只允许以下字段，不提供任意 `message`、`payload` 或自由键值对象：

```text
sequence       capture 内单调序号
elapsedMs      相对抓取开始的单调毫秒
wallTimeMs     人工对时用 wall clock
moduleId       固定大模组 ID
eventCode      固定 catalog 机器码
level          info | warn | error
outcome        started | succeeded | failed | cancelled | timeout | skipped | retry | state
sessionRef     capture-local session-N；无会话为空
generation     数值 generation；无则 0
code           数值错误/状态码；无则 0
durationMs     数值耗时；无则 0
count          聚合计数；无则 0
bytes          聚合字节数；无则 0
```

`eventCode` 必须存在于 policy catalog 且属于传入模块，`outcome` 必须是固定枚举，所有数值
必须为有限安全整数并做范围收敛。原始 session/host/account/record/relay/store ID 只可作为
运行时内存相关键，文件中只出现本次抓取内分配的 `session-N`。

### 5.3 文件格式

- 文件名 `RemoteDesktop-log-YYYYMMDD-HHmmss.jsonl`，UTF-8 单文件。
- 第一行为 manifest：schema、app 名、开始/结束时间、选择模块、最长时长、停止原因、
  redaction policy 版本。
- 中间每行一个 event；最后一行为 summary：事件数、各模块数量、drop 数和字节数。
- 先在内存构造并逐行解析验证，再打开 `DocumentViewPicker.save()`。
- 复用 `BoundedDocumentIo.writeFully/readFully`，目标写入后 `fsync` 并回读逐字节比较；
  不调用 `LocalBackupService` 的备份或快照 API。
- 保存失败或取消不清空 frozen capture；保存成功才 reset 到 idle。

## 6. 隐私合同

以下内容不得进入 recorder 或文件：

- 密码、passphrase、PIN、Token、API/server key、私钥、公钥正文、证书或 fingerprint。
- TOTP secret/验证码、认证 prompt/response。
- host/IP/域名/端口组合、username/email/account/UnionID、host/record/relay/store/device ID。
- 终端命令与输入输出、SFTP 路径/文件名/内容、剪贴板、按键、鼠标/触摸轨迹。
- 屏幕帧、像素、音频、数据库行、SQL、Preferences value、云 payload、URL/header/query。
- `Error.message`、stack、`JSON.stringify(err)`、native last message、Rust/helper 原始输出。

生产 API 不接受任意文本字段，从类型层堵住原文进入路径。测试把上述每类 canary 注入
业务 fake/相关键和异常，序列化后对整个文件做字节搜索，命中即失败。

## 7. 最窄接入点

### 7.1 连接

- RDP/RustDesk/VNC：只在 `ExtensionLoader.ets` 已有 connect/preflight/state-change/
  disconnect 公共方法的结果确定后旁路记录；不改 callback、session registry 或 adapter。
- SSH：只在 `SshSessionStore.notify()` 把既有 typed `kind/state/generation` 映射为 catalog；
  明确丢弃 `hostId/address/error/payloadJson`。
- SFTP：只在 `SshSftpTaskStore` 的任务级 observer 边界记录 action/state/bytes；不在 chunk、
  picker、文件 I/O hot path记录。
- Moonlight：只在 `MoonlightSessionCoordinator.handleRuntimeEvent()` 成功提交状态后记录 typed
  event；host 操作只选一个现有中央服务边界，不触碰 native media/input path。

### 7.2 云同步与本地数据

- 云同步只接 `CloudSyncCoordinator` 的统一执行/完成边界，记录 direction、outcome、表数量、
  重试类别和耗时，不记录表行、owner scope 或 selection value。
- 本地数据库只接 `CloudStore` 已有 init 和中央 mutation 结果边界；不遍历 CRUD，不执行
  诊断 SQL，不读取或 dump 业务数据。
- 第一版不接 `LocalBackupService`；诊断导出也不能调用其业务方法。

### 7.3 中继、网关、代理与 SSH 密钥

- routing 只选各自已有的 coordinator/service 最终结果边界，记录 route 类别、阶段和数值/
  枚举结果；不记录 endpoint、凭据、profile/record ID。
- SSH key 优先在 `ExtensionLoader` 已有 public key methods 和 `SshKeyImportService` 最终结果
  处记录。只保留 operation、key type 类别、bits、是否加密、outcome 和耗时；secret 参数
  不复制、不包装、不延长生命周期。
- `KeyVaultService` 只在确有统一 CRUD 边界且不会引入循环依赖时接入；否则由更外层已存在
  的成功/失败边界覆盖，禁止为日志重构密钥业务。

## 8. 零副作用硬约束

1. 所有 producer 调用都放在业务结果已经确定的位置，不能改变返回值、抛错或 Promise 链。
2. 不修改重连 generation、session/owner token、teardown、stale callback、后台 handoff、
   PIP、独立窗口或连接状态机。
3. 不在帧/解码/音频/输入/剪贴板/终端字节/SFTP chunk/packet hot path记录。
4. 不改变任何现有诊断 snapshot/HUD 的 ABI、字段或轮询。
5. 不改变云表、选择状态、lease、restore barrier、mutation journal、加密或账号切换顺序。
6. 选中模块和开始/停止抓取不能初始化 provider、建立/断开连接、触发同步、打开数据库、
   probe relay 或解锁密钥。
7. 任何诊断异常、OOM、满载、deadline 或保存失败都只能丢日志，业务功能继续原路径。

## 9. 实施 checkpoint

### Checkpoint 1：核心与文件保存

- [x] 新增 policy/runtime/export 三个 service。
- [x] 新增 policy/runtime/export 单元测试并注册到 `List.test.ets`。
- [x] 覆盖六个时长、模块冻结、deadline、容量、事件 catalog、sessionRef、JSONL、cancel/
  retry、短写/回读失败和全文件敏感 canary。
- [x] 先完成一次独立聚焦审查，再允许接业务 producer。

### Checkpoint 2：设置“日志”栏位

- [x] 新增独立设置 Sheet。
- [x] 在 route policy 分配独立 mode，在设置列表用现有 `settingsActionHeader` 加“日志”栏位。
- [x] 不创建新图标资源，使用已支持的系统 Symbol，保持其他设置项视觉合同。
- [x] Phone/2in1 虚拟机覆盖打开/关闭、开始、到时、手动结束、保存、取消重试和页面重建；
  `discard(expectedCaptureId)` 的原子校验与状态清理由 runtime 测试覆盖。

### Checkpoint 3：五类连接

- [x] 依次接 RDP、RustDesk、VNC、SSH/SFTP、Moonlight 的单一中央边界。
- [x] policy/runtime/export 和 SSH producer focused tests 已编写并注册；精确
  `default@OhosTestCompileArkTS` 已证明当前测试树可编译，producer 的 inactive/active/no-throw
  路径已完成独立静态复核。
- [ ] 本轮未把“测试编译”冒充设备侧 Hypium 执行；`ohosTest@OhosTestCompileArkTS` 当前返回
  `00306054 Task not found`，与仓库既有 blocker 一致。项目后续注册稳定入口后，由 CI 或用户
  实机验收补充运行记录。
- [x] 第一版保持 `entry/src/main/cpp`、Rust FFI/helper 和 NAPI typings 零修改。

### Checkpoint 4：云、本地数据、routing 与 SSH key

- [x] 接 CloudSyncCoordinator 和 CloudStore 的少数中央结果边界。
- [x] 接 relay/gateway/proxy/forwarding 与 SSH key 的最窄服务边界。
- [x] 对接点均位于已有业务结果确定之后；静态审查确认没有新增诊断分支参与云同步
  lease/journal/账号切换、DB commit/rollback、relay 保存回滚或 secret 生命周期决策，且
  recorder API 保持 no-throw、返回值不被业务消费。

### Checkpoint 5：交付验证

- [x] `git diff --check` 与 `git diff --cached --check`。
- [x] 精确 `default@OhosTestCompileArkTS`，exit 0。
- [x] 精确 `assembleHap`，exit 0，`BUILD SUCCESSFUL`。
- [x] Light 开源合规门，exit 0。
- [x] 只复用一个 `gpt-5.6-sol`、reasoning `medium` reviewer；修复后结论为
  `PASS（原 4 项均关闭，无新增 P0-P3）`。
- [x] HDC 从沙箱外启动；Phone 覆盖 1 分钟到时、Sheet 重建、picker 取消/重试/保存；2in1
  冷安装最新 HAP 后覆盖默认仅基础日志、勾选 SSH/SFTP、离开设置复现、自动到时、手动结束、
  Download 保存及 JSONL 解析。
- [ ] 实机仍由用户最终验收；虚拟机结果不能冒充真实协议端点、真机后台或长时验收。

## 10. 当前验证证据

- 2in1 虚拟机目标实际设备类型为 `2in1`。重新安装后执行强制停止与冷启动，确认“日志”入口
  和新代码生效；旧进程未被安装动作自动替换的情况没有被误判为产品缺陷。
- 默认选择只包含不可取消的 `core.app`；RDP、RustDesk、SSH/SFTP、VNC、Moonlight、云同步、
  本地数据库、中继与网关、SSH 密钥对均默认未选。本次 SSH Demo 抓取只额外选择
  `connection.ssh_sftp`。
- 手动流程文件 `RemoteDesktop-log-20260819-230203.jsonl` 保存在 2in1 的 Download：6 行、
  1525 bytes；manifest 的时长为 10 分钟、停止原因是 `manual`、选择模块严格为
  `core.app + connection.ssh_sftp`。文件含 4 条事件、0 条丢弃，其中基础事件 2 条、SSH
  预检事件 2 条；事件与 summary 计数一致。SHA-256 为
  `edd4f760aa4bb1326dc54e08ab0afcbbcaa1d42e1ab421c206edd60f4fb180f4`。
- SSH Demo 的预检本身失败，因此本轮验证的是“真实失败能够被采集和导出”，不是 SSH 终端
  成功连接。自动到时流程另生成 `RemoteDesktop-log-20260819-225057.jsonl`，停止原因为
  `deadline`；两个原始文件都保留在虚拟机 Download。
- 对手动流程完整文件执行隐私搜索，未命中测试端点、端口、连接名称、密码/passphrase、
  Token、私钥、终端/命令/剪贴板内容、URL 或文件 URL；`sessionRef` 为空，没有原始业务 ID。
- 当前诊断增量没有修改 native、Rust、NAPI、权限、云表或数据库 schema。两项强制 Hvigor
  门、Light 合规、diff 检查和独立 reviewer 均通过。

## 11. 完成标准

- 设置中存在统一风格的“日志”栏位，用户可选择大模组和 1–30 分钟固定时长。
- 开始后只在所选模块的中央边界收集结构化事件；离开设置不停止，到时不再接收。
- 点击“结束并保存”后选择一次本地位置即可得到可逐行解析的 JSONL。
- 文件覆盖五类连接、云同步、本地数据、中继/网关/代理和 SSH 密钥的代表性操作结果。
- 全文件敏感 canary 通过，且不存在原始 HiLog、错误文本、地址、凭据、终端/文件/数据库
  内容。
- recorder 关闭、开启、到时、满载、内部失败、picker 取消和保存失败时，其他模组的返回值、
  状态、时序、清理和持久化语义不变。
- 无新增权限、后台任务、native/Rust/NAPI ABI、云表和数据库 schema。
- 定向测试、两项强制 Hvigor 门、Light 合规、聚焦审查和虚拟机 UI/保存流程均有当前树证据。

实现、独立复核和虚拟机交付验证已经完成；剩余唯一外部验收项是用户使用实机和可达的真实
协议端点确认真机后台行为与成功连接路径。
