# RemoteDeskHarmonyOS 云同步、备份恢复与升级全链路升级计划

> 初版日期：2026-07-28
> 重审日期：2026-07-29
> 适用仓库：RemoteDeskHarmonyOS
> 审计基线：`main@23940521a414fcb55605b37fe6e65fd18412c7a3`
> 当前状态：重审修订、待实施；本文件是升级路线图，不代表代码已经完成
> 目标基线：API 23 上限，兼容现有 main 及已发布旧版本数据
> 计划原则：账号隔离优先于同步便利；可恢复优先于静默继续；无法证明安全时 fail-closed

## 0. 结论先行

当前代码已有可保留的设备级基础：首次 cloud-first、自动上传延迟、空云整表保护、串行 CloudSyncCoordinator、dirty/retry/conflict/journal 持久化、进程内手动下载快照、`restored_not_uploaded` 隔离，以及 VNC 单云表、本地 overlay、行级 validator、`encrypted_v2`、reset epoch 和 trust 本机二次确认。本地备份也已有 32 MiB 上限、短读短写循环、写后重读和单 RDB 恢复事务；`password -> passward` 与旧 VNC 表迁移已有局部 marker/事务/回滚。

这些能力目前都是设备级、全局单例级或局部事务级，不能证明账号级安全和跨进程恢复。`cloudSync(mode, [table])` 以物理表为同步入口；只给共享库补 `WHERE userid` 仍可能让当前账号的同步操作携带其他账号物理行。因此根治边界必须升级为：

1. 无已验证账号绑定时，禁止注册分布式表和发起任何账号云操作。
2. 由唯一 `AccountSessionCoordinator` 管理 typed `ScopeToken`、generation、账号与系统云绑定状态、物理 store 和所有 transition。
3. anonymous/offline 使用独立 device-local store；每个 Huawei owner scope 使用独立 distributed RDB/store，同一已注册云库不得长期混存多个 app owner。
4. schema migration、cloud sync、backup restore、crypto reset 共用 durable operation/receipt/quarantine 基础，不再各自维护不可恢复的页面级步骤。
5. 所有服务、缓存、Preferences、临时凭据、native session 和迟到回调都绑定 scope generation。

“一次修复根治”指同一套不变量、统一数据入口和完整迁移路线，不指一个不可回滚的超大补丁。实施必须先止血、再建立底座、再逐域迁移，并始终保留旧数据只读兼容和 feature flag。

当前版本对本专题的发布判定仍是 **NO-GO**。在根治完成前，至少要先关闭系统备份声明、未绑定账号的云同步、无 owner/敏感表的默认上传以及未持久化的远端 crypto disable/reset。

本计划明确禁止：

- 只补 SQL owner filter 后继续共用一个多账号 distributed store。
- 通过“时间更新”或“本地非空”猜测云端与本地谁权威。
- 把空实现的系统备份能力继续配置成可备份。
- 把备份中的 absent 当 empty、剥离 tombstone 后重新插入、或用缺表清空新版表。
- 把新设备登录等同于“启动时已经知道当前账号”。
- 把 VNC、RDP、RustDesk、SSH、TOTP 的凭据、selection、journal 或临时明文放入共用无 scope 缓存。
- 由 UI/importer 自行填 owner；owner 必须由 scope-bound service 注入和校验。
- 把本地 `plain-v1`、Pro token、设备信任确认或登录 token 上传云端/写入便携备份。
- 在没有官方服务端契约时开放 WebSocket、公网 relay、SSH reverse listen。

## 1. 证据基线

### 1.1 2026-07-29 重审差异

仍成立的关键风险：

- AccountKit 未在生产启动链路初始化，startup pull 早于账号绑定；两条登录成功路径都没有 awaitable rebind/cloud-first transition。
- 普通业务表、缓存、dirty/retry/conflict/journal、cloud selection 和 crypto params 仍是全局或整表路径；登出不清 unionID、活动会话和明文缓存。
- `rdpcredentials` 仍无 owner，RDP username 仍不会进入云字段；`cryptoparams` 仍使用全局固定 key。
- 系统 BackupExtension 仍为空实现但配置为可恢复；旧七表备份仍整包拒绝，本地恢复仍是无 scope 的全库 replace。
- crypto enable/disable/reset 仍无 durable operation；生产页面另有一套与 `DataCrypto` 重复且漂移的编排。

本次新增或强化的结论：

- 平台入口是物理表级 `cloudSync`，共享多账号 distributed store 无法只靠行过滤证明云隔离，目标改为 per-account physical store。
- `UserAccount.setLoggedOut()` 不清 unionID，VNC owner 读取又不检查登录态；A 登出后离线模式仍可能使用 A scope。
- bootstrap marker、selection、dirty/retry/conflict/journal 全部无 scope；首次 pull 失败后产生的真实用户 mutation 可能在后续 bootstrap 成功时被当作 pre-bootstrap 状态丢弃。
- accepted 后无 `SYNC_FINISH` 没有 watchdog，可永久卡死唯一队列；普通表重新启用也没有 VNC 等价的 cloud-first barrier。
- 本地备份查询异常可退化为空数组并继续生成“成功”文件；导入又可能剥离删除标记并复活 tombstone。
- reset 先提交状态/epoch、后清理；崩溃后启动会把相同 reset 视为已处理，存在永久半完成窗口；`clearAllTables()` 还是跨全库删除。
- RustDesk Pro token 明文存入全局 Preferences；Huawei owner、RustDesk 服务端 userId、Pro accountId、relayId、device authorization 尚未分域。
- 新增 RustDesk TOTP 绑定只存在模型/UI 内存：未进入物理列、云扩展白名单、本地 extension 或备份，重启即丢。
- VNC 逻辑身份是 `(userid,id)`，物理主键却只有 `id`；全局 selection reconcile 还会扫描所有 owner。
- 旧 relay JSON 迁移函数存在但无生产调用点，是 dead migration path。

旧计划已被纠正的过时判断：

- `password -> passward` 不是完全未实现：已有局部 marker、事务、回滚和 canonical 优先级；缺口是正式 schema receipt、旧备份再次导入以及最终移除 shadow。
- 旧 `vncrecords` 已只迁入 `vnclocalrecords`，且有事务/marker；缺口是 skipped row quarantine、receipt、版本 adapter 和物理复合 identity。
- VNC 单表/overlay、validator、reset epoch、trust 本机确认可以保留；`encrypted_v2` 的 AAD 仍未绑定真实账号和 epoch，不能描述成账号级闭环。
- 当前本地备份 I/O 和单 RDB 恢复事务可以增量增强，不另建平行实现。

### 1.2 本地代码直接证明的事实

| 编号 | 事实 | 代码位置 | 计划结论 |
| --- | --- | --- | --- |
| C-01 | EntryBackupAbility 的 onBackup/onRestore 只有日志和空 Promise；backup_config 却允许备份恢复 | entry/src/main/ets/entrybackupability/EntryBackupAbility.ets:6-15；entry/src/main/resources/base/profile/backup_config.json:2 | P0。必须实现真实导出/恢复，或在完成前关闭声明 |
| C-02 | EntryAbility 先初始化 KeyVaultService、HostSyncService，再请求 startup pull；没有看到 AccountKitService.init 的启动调用 | entry/src/main/ets/entryability/EntryAbility.ets:159-170；entry/src/main/ets/services/AccountKitService.ets:66-74 | P0。云 pull 必须等 AccountScope 完成 |
| C-03 | 登录成功只更新 AuthService、凭据和 loginMode；空 unionID 也可 logged-in；登出不清 unionID | entry/src/main/ets/pages/LoginPage.ets:200-228；entry/src/main/ets/pages/HostListPage.ets:3942-4007；entry/src/main/ets/model/UserAccount.ets:25-37 | P0。登录/登出必须进入唯一 transition，账号 ID fail-closed |
| C-04 | AccountKitService 在 dataPreferences 尚未初始化时只更新内存 credential，持久化可能丢失 | entry/src/main/ets/services/AccountKitService.ets:90-120 | P1。启动初始化必须早于任何登录回调 |
| C-05 | remotehosts、RDP credential、relay、SSH key、TOTP、settings 普通读取直接查整表；新增/import 通常写空 userId；服务更新删除按裸 id | entry/src/main/ets/services/CloudStore.ets:3085-3105、3452-3504、3806-3900、3955-3994、4290-4387；entry/src/main/ets/components/hostadd | P0。所有 API 必须绑定 ScopeToken；UI/importer 不得决定 owner |
| C-06 | rdpcredentials 模型/RDB 均无 userid；云字段无 username，username 仅在 local extension | entry/src/main/ets/model/RdpCredential.ets:9-22；entry/src/main/ets/services/CloudStore.ets:1218-1227、3085-3105；entry/src/main/ets/services/CloudTableAdapter.ets:8-16、55 | P0。云 schema 未就绪前整表 sync-disabled |
| C-07 | local backup v2 要求顶层表数量严格等于 CLOUD_SYNC_TABLES；旧七表备份在新版增加 vncrecord 后不能作为部分备份恢复 | entry/src/main/ets/services/LocalBackupPolicy.ets:190-219、224-242；entry/src/main/ets/services/CloudSyncPolicy.ets:1-10 | P1。需要显式 version adapter 和 merge/replace 语义 |
| C-08 | 备份导出整表且异常退化为空；恢复全库 replace；absent 被当 empty；删除标记会被剥离 | entry/src/main/ets/services/CloudStore.ets:603-635、821-904；entry/src/main/ets/services/LocalBackupPolicy.ets:92、191-245 | P0。禁止伪成功空备份、跨账号覆盖和 tombstone 复活 |
| C-09 | Coordinator 已串行并持久化 dirty/retry/conflict/journal，但全部无 scope；手动下载普通表与 VNC 是两个独立进程内快照 | entry/src/main/ets/services/CloudSyncCoordinator.ets:183-206、397-476、807-977；entry/src/main/ets/services/CloudStore.ets:490-546 | 保留单队列，升级为 scoped durable ledger/checkpoint |
| C-10 | CloudStore 调用 relationalStore.cloudSync 的完成回调与 Progress.SYNC_FINISH 分离，但当前没有统一的应用级 watchdog/cancel ledger | entry/src/main/ets/services/CloudStore.ets:887-1082 | P1。超时、进程被杀和半完成必须可判定、可恢复 |
| C-11 | 旧 relay JSON migration 函数存在但无调用点；正常路径只读独立 relay 表 | entry/src/main/ets/services/CloudStore.ets:3212-3245、3404 | P1。接入 versioned migration runner 或删除死入口 |
| C-12 | 旧 vncrecords 已只迁到本地 overlay，但无效/旧 epoch 行静默跳过后仍写完成 marker；VNC 物理 PK 只有 id | entry/src/main/ets/services/CloudStore.ets:1433-1510、4799-4804；entry/src/main/ets/services/VncRecordPolicy.ets:60 | P1。保留安全边界，补 quarantine/receipt/scoped physical ID |
| C-13 | 生产 enable/disable/reset 由 HostListPage 分步编排；状态/epoch、清表和 push 非同一 operation，clearAllTables 无 scope | entry/src/main/ets/pages/HostListPage.ets:7650-7775；entry/src/main/ets/services/CloudStore.ets:2360-2483、2843-2877 | P0。统一 durable scoped crypto operation |
| C-14 | lock/logout/reset 未清 HostSync、KeyVault、VNC handoff、SSH preflight、RustDesk token 和活动 session | entry/src/main/ets/services/DataCrypto.ets:443-454；entry/src/main/ets/services/VncSessionCredentialHandoff.ets；entry/src/main/ets/services/SshPreflightService.ets；entry/src/main/ets/services/RustDeskProCredentialStore.ets | P0。实现 SensitiveDataBarrier |
| C-15 | cloudSync 以物理表执行，请求无 scope/generation/operationId；bootstrap marker 也是全局布尔 | entry/src/main/ets/services/CloudStore.ets:984-1105；entry/src/main/ets/services/CloudSyncCoordinatorPolicy.ets:9-21；entry/src/main/ets/services/CloudStore.ets:271-294 | P0。每账号独立 distributed store + generation fence |
| C-16 | RustDesk TOTP binding 未进入物理列、云扩展白名单、本地 extension 或 backup | entry/src/main/ets/model/RemoteHost.ets:298-300；entry/src/main/ets/services/CloudStore.ets:2091-2094；entry/src/main/ets/services/CloudTableAdapter.ets:62-74 | P1。补 canonical persistence 与 same-scope reference |
| C-17 | RustDesk Pro access token 明文写入全局 Preferences，调用按 Pro account/relay id，不含 Huawei owner | entry/src/main/ets/services/RustDeskProCredentialStore.ets:10-18、70-105、140-160 | P0。HUKS/安全存储、owner/device 绑定、logout drain |
| C-18 | RDP/SSH trust 虽声明 local-only，却经 displayconfig 云扩展恢复并影响连接 | entry/src/main/ets/services/CloudTableAdapter.ets:41-74；entry/src/main/ets/services/CloudStore.ets:2007-2045 | P1。信任确认永远 device-local |
| C-19 | Legacy CloudSyncService 仍保留无 scope 可写 REST 实现，当前无生产调用者 | entry/src/main/ets/services/CloudSyncService.ets | P3。编译期弃用并移除写能力，防止绕过 coordinator |

### 1.3 官方文档与官方源码依据

以下链接是计划制定时核对的官方入口。执行每个 API 变更前仍必须以仓库所用 DevEco/API 23 SDK 的本地文档为准，不直接把较新 API 示例复制到本项目。

| 来源 | 已核对内容 | 对本项目的约束 |
| --- | --- | --- |
| [HarmonyOS Distributed Database Codelab](https://developer.huawei.com/consumer/en/codelab/HarmonyOS-Distributed-Database/) | DDS 按账号、应用、数据库三元组隔离；同一 HUAWEI ID；分布式同步需要相应权限和至少两台设备/分布式网络 | 不能把本地 unionID、华为账号、数据库 owner 混成一个随意字符串；双设备验收必须使用同一账号和真实权限 |
| [HarmonyOS 文档中心](https://developer.huawei.com/consumer/cn/doc/) | ArkData 包含关系型数据库、跨设备同步、同应用端云同步、数据库备份恢复、数据库加密和文件能力 | 计划按“RDB schema + cloud sync + backup + crypto”分别验收，不把云同步当作系统备份 |
| [HarmonyOS 知识地图](https://developer.huawei.com/consumer/cn/app/knowledge-map/) | 官方目录明确列出关系型数据库存储、跨设备同步、应用数据备份恢复、Socket、WebSocket、Node-API、异步开发、应用测试和分阶段发布 | 每个生命周期都必须有对应的本地单元测试、设备测试和发布阶段门禁 |
| [同应用端云数据同步](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/distributed-data-sync) | 端云同步环境和关系型数据同步属于独立能力，需检查云侧环境、权限和数据模型 | 先在 AGC/华为云创建并校验表和权限，再打开代码 feature flag |
| [应用文件备份恢复](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/app-file-backup-restore) | 应用文件/数据备份恢复是独立的系统能力 | BackupExtensionAbility 必须有真实数据协议、版本和失败处理，不能只依赖 allowToBackupRestore |
| [关系型数据库存储](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/data-persistence-by-rdb-store) | RDB 建表、迁移、事务和 ResultSet 是本地数据基础 | 所有 schema migration 要可重入、有版本和失败 marker，不能只靠吞掉 ALTER TABLE 异常 |
| [Socket 连接](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/socket-connection) | Socket 的连接、读写、关闭、错误和生命周期是独立的网络能力 | RFB、Repeater 和 SSH transport 不得在 ArkUI 线程阻塞；每次 close 必须能取消 worker |
| [WebSocket 连接](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/websocket-connection) | WebSocket 是与 Raw TCP 不同的连接模型 | 只有具备版本化服务端 binary gateway 契约时才打开 WebSocket VNC relay |
| [Node-API 进程/线程相关指导](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/use-napi-process) | NDK/Node-API 有独立的异步、线程和跨语言生命周期约束 | native 回调必须带 session generation，不能让旧会话事件进入新页面或新账号 |
| [云数据库](https://developer.huawei.com/consumer/cn/agconnect/cloud-base/) | 支持端云数据协同、多设备协同、离线端侧保留和网络恢复后同步，并提供身份/数据模型安全控制 | 这些是平台能力描述，不等同于本项目已经实现；真实云表、权限和失败语义必须实测 |
| API 23 本地 `@ohos.application.BackupExtensionAbility.d.ts` | `onBackup()`、`onRestore(bundleVersion)` 及 Ex 回调是应用自定义备份/恢复入口，restore 可获得来源 BundleVersion | 系统回调不能保持空实现；restore 只记录 durable intent，待正常启动完成账号/schema/crypto 初始化后导入 |
| API 23 本地 `@ohos.data.relationalStore.d.ts` | cloudSync 有 accepted callback 与 Progress 进度，`SYNC_FINISH`/ProgressCode 是独立阶段 | accepted 不得算成功；必须有 finish 校验、deadline 和迟到回调 fence |
| [应用安装卸载与更新](https://developer.huawei.com/consumer/cn/doc/doccenter-getting-started/application-package-install-uninstall) | 应用升级必须递增 app.json5 的 versionCode，可通过应用市场或应用内检测升级 | 发布门禁必须同时验证包升级、RDB migration 和 versionCode；不得把“安装新包”当作迁移完成 |
| [RustDesk 官方仓库](https://github.com/rustdesk/rustdesk/tree/12f2de5959fa1fcd36d5a5b0c2fa91657411cc7a) | 2026-07-29 重新核对的 master 头为 `12f2de5959fa1fcd36d5a5b0c2fa91657411cc7a` | 本项目当前 FFI 不是直接依赖上游 crate；升级时必须以固定上游 commit 做能力/协议对照，并更新许可、SBOM 和 ABI 记录 |
| [RustDesk remote page](https://github.com/rustdesk/rustdesk/blob/a9185d6a309a3a3dad76a30c832e7f18bc0eaa53/flutter/lib/desktop/pages/remote_page.dart) | 上游远程连接 UI、会话和输入/显示语义参考 | 只借鉴协议/行为契约，不把 Flutter UI 状态直接移植到 ArkTS |
| [FreeRDP 官方仓库](https://github.com/FreeRDP/FreeRDP/tree/0b4f031f3575a42ddec441ffdb99cd8a4ef77047) | 2026-07-29 重新核对的 master 头为 `0b4f031f3575a42ddec441ffdb99cd8a4ef77047` | 需要将本地 OHOS fork维护为可追踪 patch queue；本次数据生命周期修复不顺带升级 native dependency |
| [FreeRDP update.c](https://github.com/FreeRDP/FreeRDP/blob/e32c57ddca84e382a0e48279b560668b20183b31/libfreerdp/core/update.c) | 上游更新处理和会话数据流参考 | RDP 凭据/云同步升级不能改变 native ABI；协议变化须有 FreeRDP 版本、OHOS patch 和回归矩阵 |
| [本项目 FreeRDP fork 分支](https://github.com/Mydstiny/RemoteDeskHarmonyOS/tree/freerdp-ohos) | 当前子模块指向公开仓库 freerdp-ohos 分支 commit dae8276a | 不直接切到 FreeRDP upstream；先生成 upstream-to-ohos 差异、冲突清单和可回滚 bundle |
| [RFB protocol specification](https://github.com/rfbproto/rfbproto/tree/152107db63cd34b3536ad8ddf54a0cfc9017a9f9) | 2026-07-29 固定源码头；规范覆盖版本协商、security type、ServerInit、更新编码和输入事件 | VNC 生命周期必须把 transport pairing 与 RFB handshake 分层，拒绝未知 security type |
| [LibVNCServer](https://github.com/LibVNC/libvncserver/tree/42494999e6492aaab9c1db785ecd293ef10b3aed) | 2026-07-29 固定源码头；作为 VNC client/server 行为与编码参考 | 如引入第三方实现，必须固定 commit、封装在 native engine、补 license/SBOM 和 fuzz gate |
| [UltraVNC mode12](https://github.com/UltraVNC/UltraVNC/blob/main/repeater/mode12_listener.cpp) / [mode2](https://github.com/UltraVNC/UltraVNC/blob/main/repeater/mode2_listener_server.cpp) | Repeater viewer/server 角色和配对字节契约 | viewer 不得把 mode2 server listener 冒充成客户端连接；没有真实 Repeater 不能宣称 relay 可用 |

本计划使用了官方网页、API 23 本地 SDK 声明和 GitHub CLI 核对的 commit 证据。本轮 SDK 证据来自：

- `/Users/mydestiny/Library/OpenHarmony/Sdk/23/ets/api/@ohos.application.BackupExtensionAbility.d.ts`
- `/Users/mydestiny/Library/OpenHarmony/Sdk/23/ets/api/@ohos.data.relationalStore.d.ts`

华为官方网页部分由动态文档中心渲染；实施时必须把 DevEco、SDK/API 23 和本地 d.ts 快照摘要写入验证记录。GitHub 上游 commit 只是行为对照快照，不自动授权升级依赖。

### 1.4 证据等级

- A：当前代码/测试直接证明的行为。
- B：官方文档或官方源码明确约束的行为。
- C：需要华为云、双设备、旧 APK 或真实协议端点才能证明的行为。
- D：基于代码路径的风险推断，必须在实施中转为 A 或 C。

报告、提交说明和发布说明必须标注证据等级，不能把 D 级风险写成“已经在真实云端复现”。

## 2. 目标架构与不变量

### 2.1 统一账号生命周期

新增唯一 `AccountSessionCoordinator`，内部拥有 `AccountScopeState`、`AccountTransitionCoordinator` 和 store registry；不得再由 EntryAbility、LoginPage、HostListPage、VNC service 分别推断账号。所有业务服务只接受不可伪造的 typed `ScopeToken`，不接受空字符串、裸 unionID 或从 UI 临时读取的 userId。

`ScopeToken` 至少包含：

~~~text
ownerScopeId
generation
sessionState
cloudBindingState
storeIdentity
schemaRevision
selectionRevision
~~~

状态机：

~~~text
anonymous
  -> account_loading
  -> authenticating
  -> draining(old generation)
  -> bound(scopeId, storeIdentity)
  -> schema_migrating(scopeId)
  -> cloud_bootstrap(scopeId)
  -> ready(scopeId)
  -> switching(oldScope -> newScope)
  -> locked(scopeId)
  -> restore_pending(scopeId)
  -> blocked(reason)
~~~

固定规则：

1. `ownerScopeId` 由已验证的稳定 Huawei unionID 派生 opaque/hash ID；openID、authorizationCode、access token 不能作为 owner。
2. 必须显式验证 AccountKit 身份与平台 distributed/cloud identity 的绑定；无法证明一致时 cloudBindingState=blocked，禁止猜测。
3. 区分 `AccountOwnerId`、`ProtocolPrincipalId`、`DeviceId`、`StoreIdentity` 和 `SessionId`。RustDesk Pro 的 server userId 不是 Huawei owner。
4. anonymous/offline 数据进入独立 device-local store，不得用字符串 `"local"` 冒充账号 scope。
5. 每个 Huawei owner 使用独立 distributed RDB/store；同一时刻只有已验证当前账号的物理 store 可以注册 distributed tables。
6. 任何旧 generation 的 cloud/native/timer callback 都只能写诊断，不得改变新 generation 的数据或 UI。
7. 服务不得在调用时动态读取 `AuthService.getUnionId()`；只使用构造/绑定时取得的 ScopeToken。
8. logout 必须清空 `UserAccount` 的 unionID/openID/display/avatar/loginTime 等旧身份状态，而不只是 token。
9. 登录成功是一次可等待 transition：冻结旧 CRUD/连接/同步，generation++，取消 timer/retry/subscription，终止活动 session，清明文和旧快照，关闭旧 store，绑定新 store，完成迁移和逐表 cloud-first 后才发布 ready。
10. lock、logout、switch、reset、restore 共用 `SensitiveDataBarrier`：清 HostSync/KeyVault/VNC/RustDesk Pro、VNC handoff、SSH preflight、页面输入、活动 session registry，最后清 DEK。
11. transition 失败时 UI 只显示 switching/bootstrap/blocked 骨架和恢复动作，不显示旧单例缓存。

### 2.2 物理数据 owner 规则

| 数据 | 当前 owner | 目标 owner | 迁移策略 |
| --- | --- | --- | --- |
| remotehosts | 有 userid，但读取未统一过滤 | userid 必须非空，所有 SQL 和 extension 都按 scope | 旧空 userid 行 quarantine，登录后由用户确认归属 |
| rdpcredentials | 没有 userid，username 只在 local extension | 增加 userid；云字段包含 userid、username | 无法扩展云表时停止该表跨设备同步，不做无 owner fallback |
| rustdeskrelays | 有 userid，旧 cryptoparams 还有 relay JSON | userid 绑定；旧 JSON 只做一次迁移 | 迁移后写独立表，旧 key 只读并打 marker |
| sshkeys | 有 userid | userid 必须非空；私钥密文 | host-key trust 默认 device-local |
| totpentries | 有 userid | userid 必须非空；secret 密文 | 恢复后仍需本机解锁/确认 |
| usersettings | 有 userid | userid + typed setting key | 不同步设备级、登录态、session 和临时 UI 状态 |
| cryptoparams | 当前只有 id/key/value | 增加 userid 或采用 account:key 规范化主键，禁止全局混用 | 旧无 owner 参数只进入 quarantine，不能自动套给新账号 |
| vncrecord | userid + recordtype，但 PK 只有 id | 保持唯一云表；物理主键使用 scoped physicalId，逻辑 id 单独保存 | 保留 vncrecords -> vnclocalrecords 只迁本地和 secret opt-in |
| vnclocalrecords | 设备本地 overlay，PK 只有 id | scoped physicalId + device-local | 账号切换只重载当前 scope，不删除别的账号 |
| localextensions/journal/metadata | 设备本地但无 scope | owner scope + store + operation scope | 迁入 per-account store；旧值先 quarantine |
| cloud bootstrap/selection/retry/conflict | 全局 Preferences/key | scope + table + schemaRevision + selectionRevision | 禁止把旧全局状态归给首个登录账号 |
| RustDesk Pro credential | 全局 Preferences；server userId 与 owner 混用 | Huawei owner + device + Pro accountId；token HUKS/安全存储 | token 不进入云、便携备份或系统迁移 |
| active sessions / VNC handoff / SSH preflight | 进程内 Map，清理不完整 | owner scope + generation + sessionId + TTL | lock/logout/switch/reset 必须 drain/clearAll |
| trust/consent | RDP/SSH 部分经 displayconfig 移植；VNC 本机确认 | 观察值可同步，信任决定/明文 consent 永远 device-local | 新设备必须重新确认 |

新增或改变云字段前必须先完成云端 schema/权限部署。华为云端不能接受新字段时，代码必须让对应表进入 sync-disabled 状态并提示用户，不得静默上传未过滤数据。

### 2.3 目标同步状态机

~~~text
APP_START
  -> ACCOUNT_SCOPE_READY
  -> RDB_SCHEMA_READY
  -> CLOUD_SERVICE_READY
  -> CLOUD_SNAPSHOT_RECEIVED
  -> LOCAL_APPLY_TRANSACTION
  -> BOOTSTRAP_MARKER_COMMITTED
  -> READY

任何阶段失败：
  -> operation ledger = failed/retryable/blocked
  -> local mutation gate 按 scope 决定
  -> 不得把部分表成功报告成全量成功
~~~

每个 cloud operation 必须持久化：

- operationId、scopeId、generation、storeIdentity、deviceId、appVersion、schemaVersion、selectionRevision。
- source、direction、selected tables、precondition snapshot hash。
- 每张表的 `queued -> accepted -> progressing -> sync_finished -> validated -> committed` 状态。
- 失败终态：retryable、blocked、cancelled、rolled_back、restore_pending；允许显式 `degraded_success`，禁止用 ok=false 隐藏已提交表。
- 请求开始和最后进度时间、watchdog deadline、重试次数、错误码。
- 迁移/恢复前后的 row count、owner count、tombstone count 和 hash。
- 是否允许自动重试，是否需要用户确认，是否被 crypto/restore/account switch 阻塞。

bootstrap receipt 按 `scope + store + table + schemaRevision + selectionRevision` 保存。普通表或 VNC 在 selection 重新启用时都必须重新走对应 cloud-first barrier。平台 cloudSync 的 accepted callback 只代表接单；应用只有在 `Progress.SYNC_FINISH`、owner/schema/hash 校验和本地 apply 全部通过后，才把该表标记为成功。accept/progress/overall deadline 到期必须释放队列；迟到或重复 callback 只有匹配 operationId、scope、store 和 generation 才能生效。

### 2.4 数据合并原则

1. 首次云 bootstrap 采用 cloud-first；没有有效账号 scope 时不执行。
2. 已完成 bootstrap 的设备才允许 native-first；dirty journal 必须与当前 scope、operation generation 匹配。
3. 空云快照只有在云 service、表权限、账号和 schema 都已确认可用时才可被解释为“真实空”；否则是 unavailable。
4. pre-bootstrap 用户 mutation 必须以 record-level journal 保留，pull 后确定性 reconcile；不得整表丢弃为“启动默认值”。
5. 手动下载必须在磁盘上保留可恢复 checkpoint，不能只放内存；普通表与 VNC 属于同一用户操作，必须共享总 receipt 和发布屏障。
6. 跨物理表不能声称云端原子；本地 apply 采用 transaction + journal + receipt，失败时恢复到上一致性版本，并显式列出已完成表。
7. deleted tombstone、reset epoch 和 schema version 参与冲突比较；旧 epoch 或其他 scope 的记录永远不能复活。
8. 登录完成、foreground、网络恢复、selection re-enable、云事件和手动刷新只向同一 coordinator 队列提交 trigger。

### 2.5 统一导入与破坏性操作边界

portable backup、系统 restore、旧 RDB migration、云手动下载都必须进入同一条：

~~~text
source inventory
  -> format/schema adapter
  -> owner/store decision
  -> semantic validation
  -> quarantine/preview
  -> durable operation + checkpoint
  -> scoped transaction apply
  -> read-back/hash/reference validation
  -> committed or blocked
~~~

固定规则：

1. 表必须表达 `absent / present-empty / present-rows / explicit-delete`；absent 永远不能隐式触发 DELETE。
2. owner、record type、reset epoch、secret envelope、trust 等安全字段缺失时 quarantine 或拒绝，不能补默认值。
3. 导出任一 section 失败即整体失败，禁止异常降级为空数组后继续签名。
4. 所有 delete/reset/replace API 必须强制 ScopeToken；全库 clear 只允许带显式 migration/admin capability 的内部操作。
5. tombstone 要么以受支持的显式语义迁移，要么保留为 deleted；禁止剥离标记后复活。
6. rollback 不可判定时进入 blocked 并保留 before-image/checkpoint，UI 不得声称“原数据未修改”。

## 3. 分阶段实施路线图

每个阶段只允许一个主责任人/直接 agent，子 agent 不得继续派发任务。阶段完成必须提交代码、测试、证据和回滚说明，不能只提交“已检查”。

### Phase 0：发布止血、契约冻结和真实旧数据样本

依赖：无。建议作为第一条独立分支 codex/cloud-lifecycle-contract。

工作项：

- [ ] 先落安全默认值：`allowToBackupRestore=false`；未 validated/bound scope 时禁止 `setDistributedTables`、startup/manual pull、automatic/manual push。
- [ ] 在 owner/schema 完成前将 rdpcredentials、cryptoparams 及所有允许明文/无 envelope secret 的表设为 sync-disabled；远端 disable/reset 使用独立 kill switch。
- [ ] 暂停当前无 scope 的便携敏感全量导出；保留只读检查/预览能力，不继续生成可能伪成功的备份。
- [ ] 将旧 `CloudSyncService` REST 写入口标记为 compile-time deprecated 并禁止生产调用。
- [ ] 建立 schema inventory：本地 RDB、云表、local extension、local table、Preferences、KeyVault、AccountKit、VNC overlay 的字段和 owner。
- [ ] 记录审计基线 `23940521a`、FreeRDP fork `dae8276ac...`、RustDesk `12f2de595...`、FreeRDP upstream `0b4f031f...`、rfbproto `152107db...`、LibVNCServer `42494999...`，以及 DevEco/SDK API 23 版本。
- [ ] 收集并脱敏保存旧版本 APK、旧 RDB fixture、旧 local backup v1/v2、旧 relay cryptoparams JSON、旧 vncrecords 表 fixture。
- [ ] 冻结真实历史 table/column inventory；backup v1/v2 adapter 不得再引用动态 `CLOUD_SYNC_TABLES`。
- [ ] 生成 A/B/anonymous 同 id、distributed tombstone、部分 ALTER、旧全局 Preferences、未完成 journal/reset 的 fixture。
- [ ] 定义 rdpcredentials.userid/username 和 cryptoparams.userid 的云端 schema 变更申请；在 AGC/华为云创建测试环境，不直接使用生产表。
- [ ] 为每个旧数据来源生成 migration manifest：来源版本、可恢复字段、丢失字段、需要用户选择的字段、禁止自动导入的字段。
- [ ] 增加 feature flags：accountScopeFence、perAccountStore、cloudLifecycleV2、backupV3、cryptoLifecycleV2、vncSecretSync；新路径未通过前默认关闭，旧不安全写路径默认禁用。

涉及文件：

- entry/src/main/ets/services/CloudSyncPolicy.ets
- entry/src/main/ets/services/CloudTableAdapter.ets
- entry/src/main/ets/services/LocalBackupPolicy.ets
- entry/src/main/ets/services/VncRecordPolicy.ets
- docs/codex/CURRENT.md、docs/codex/QUEUE.md、docs/codex/DECISIONS.md
- 新增 docs/migrations/manifest-v1-to-v3.json（只放字段元数据，不放用户数据）

退出条件：

- [ ] 安全默认值在 clean install、老用户升级和无账号启动中均生效；无账号时云 executor 调用数为 0。
- [ ] 云端测试表字段、类型、权限、主键和 distributed table 注册方式已由真实环境确认。
- [ ] 每个旧 fixture 都能被分类为可自动迁移、需用户确认、不可迁移。
- [ ] 没有任何用户密钥、token、云端地址密码进入仓库。

回滚：

- 只回滚 feature flag 和测试云 schema；不删除旧表、不覆盖旧备份。

### Phase 1：AccountSessionCoordinator 与物理账号隔离

依赖：Phase 0。

工作项：

- [ ] 新增 `AccountSessionCoordinator`/`AccountScopeState`/`AccountTransitionCoordinator`，统一保存 ScopeToken、generation、storeIdentity、cloudBindingState、切换原因和 receipt。
- [ ] 在 EntryAbility 中先初始化 AccountKitService，再解析持久化登录态；无有效账号时跳过账号云 pull。
- [ ] 让 LoginPage.onLoginSuccess 和 HostListPage.triggerSystemLogin 都调用同一个 awaitable login transition。
- [ ] 空 unionID 登录直接失败；AccountKit identity 与系统 cloud identity 无法验证一致时进入 blocked。
- [ ] 建立 anonymous device-local store 和 per-account distributed store；物理 DB 名使用不可逆 scoped identifier，关闭旧 store 后才注册新 store 的 distributed tables。
- [ ] 在 transition 开始时 generation++ 并停止 coordinator、HostSync、KeyVault、全部 VNC service、RustDesk Pro refresh；drain ActiveRemoteSessionRegistry、VNC handoff、SSH preflight 和 native session。
- [ ] `UserAccount.setLoggedOut()` 清除完整身份对象；所有 VNC 服务移除 `"local"` fallback 和动态 AuthService owner lookup。
- [ ] 给所有读取 API 增加 scope 参数或 typed owner wrapper；禁止无参数 loadAllHosts/loadAllRdpCredentials/loadAllRelaysLocal/loadAllSshKeys/loadAllTotpEntries。
- [ ] 所有 insert/update/delete/merge/extension/journal/dirty/retry/conflict 记录都写 scopeId。
- [ ] owner 由 scope-bound service 在持久化边界注入；UI/importer 只生成 draft，edit 必须保留并校验不可变 owner。
- [ ] 为 remotehosts、rdpcredentials、rustdeskrelays、sshkeys、totpentries、usersettings、cryptoparams、vncrecord 建立 owner/reference invariant；发现空 owner、跨协议或 owner 不匹配时 quarantine。
- [ ] Preferences 拆分为 device/account/credential/session 四类；AccountKit 和 RustDesk token 迁入 HUKS/安全存储。
- [ ] A 登出后登录 B：B 只能看到 B 数据；A 的 session 不能上传；B 不能修改 A 的 dirty journal。
- [ ] 服务缓存按 scope generation 失效；旧 native callback 发现 generation 不一致时丢弃。

涉及文件：

- 新增 entry/src/main/ets/services/AccountSessionCoordinator.ets
- 新增 entry/src/main/ets/services/AccountTransitionCoordinator.ets
- entry/src/main/ets/entryability/EntryAbility.ets
- entry/src/main/ets/services/AccountKitService.ets
- entry/src/main/ets/services/AuthService.ets
- entry/src/main/ets/pages/LoginPage.ets
- entry/src/main/ets/pages/HostListPage.ets
- entry/src/main/ets/services/CloudStore.ets
- entry/src/main/ets/services/HostSyncService.ets
- entry/src/main/ets/services/KeyVaultService.ets
- entry/src/main/ets/services/ActiveRemoteSessionRegistry.ets
- entry/src/main/ets/services/VncSessionCredentialHandoff.ets
- entry/src/main/ets/services/SshPreflightService.ets
- entry/src/main/ets/services/RustDeskProCredentialStore.ets
- 所有 HostAddDraft、RdpAddFlow、RustDeskAddFlow、SshAddFlow、key/TOTP/relay/VNC 新增入口

测试：

- 单元：空 unionID、重复登录同账号、A -> B -> A、登录回调重入、退出时回调晚到。
- RDB：每类表混入 A/B/空 owner 行，所有读取和写入均不得越界。
- UI/集成：登录按钮、设置页系统登录、冷启动自动恢复、登出、切换账号、断网后切换。
- Native：old session generation 的帧、错误、断开事件不得触发新账号页面。

退出条件：

- [ ] 代码审查能证明所有业务表读取都带 scope。
- [ ] 代码审查能证明任一已注册 distributed physical store 只包含当前 validated owner。
- [ ] A/B 隔离测试通过，包含云上传前的 mutation journal。
- [ ] 未登录状态不产生账号云请求。
- [ ] 未完成 transition 时 UI 不显示旧账号数据。

发布阻断：

- 任意一个普通业务读取仍允许无 scope。
- rdpcredentials 或 cryptoparams 仍无法确定 owner。

### Phase 2：版本化 schema runner、owner backfill 和 quarantine

依赖：Phase 1。

工作项：

- [ ] 新增 SchemaMigrationService 和 schema_version/migration_receipt 表；所有迁移按整数版本执行，记录开始、成功、失败和重试。
- [ ] receipt 至少记录 source/target version、pending/running/succeeded/failed/needs_confirmation、attempt、当前步骤、前后 row/owner/hash 和 quarantine count。
- [ ] schema 达标前不注册云表、不开放业务写入、不启动自动上传。
- [ ] 不再吞掉所有 ALTER 异常；迁移前通过表/列 introspection 区分已完成、部分完成、损坏和真实失败。
- [ ] 为 rdpcredentials 增加 userid，并补云端 username 字段；旧行只有在能通过现有账号上下文确定 owner 时迁移，否则进入 quarantine。
- [ ] 为 cryptoparams 增加 scoped key/物理隔离；salt/verifier/status/reset control/legacy relay marker 均属于明确 owner。
- [ ] usersettings 保留现有 dual-read 作为输入，正式迁移为 typed account/device setting；旧 key/value 完成后只读。
- [ ] 保留现有 `password -> passward` 局部事务作为基础；import adapter 必须先 canonicalize，旧 backup 不能在 marker 完成后重新引入 password shadow；兼容窗口后重建表移除 password。
- [ ] 把 dead `syncRelaysFromCloud()` 接入 versioned runner：按 `scope + sourceHash` 迁一次，按 id 去重，未知/损坏字段 quarantine，不自动上传。
- [ ] 保留旧 `vncrecords -> vnclocalrecords` 只迁本地；旧 epoch、无效 payload、未知 schema 行进入 quarantine，不得静默跳过后写完成 marker。
- [ ] 把 vncrecord/vnclocalrecords 的物理身份迁为 scoped physicalId，避免 `ON_CONFLICT_REPLACE` 跨 scope 覆盖。
- [ ] 所有迁移完成后重新计算 owner count、字段 hash 和 row count，并写入 migration receipt。
- [ ] 支持进程在任意 SQL 步骤被杀后重新启动并继续；不产生双重加密或重复迁移。

涉及文件：

- 新增 entry/src/main/ets/services/SchemaMigrationService.ets
- entry/src/main/ets/services/CloudStore.ets
- entry/src/main/ets/services/CloudTableAdapter.ets
- entry/src/main/ets/services/LocalBackupPolicy.ets
- entry/src/main/ets/services/RustDeskRelayImportService.ets
- entry/src/main/ets/services/LegacyRustDeskAccountCloudAdapter.ets
- entry/src/main/ets/model/RdpCredential.ets、RustDeskRelayConfig.ets、VncRecord.ets

退出条件：

- [ ] clean install、每个旧 schema fixture、部分迁移 fixture 都能启动。
- [ ] 迁移失败不会删除原始行；重试是幂等的。
- [ ] 所有旧字段的去向有清单：保留、转换、隔离、明确丢弃。
- [ ] 任一 scope 不会读取另一 scope 的旧 unscoped 行。
- [ ] portable/system/cloud import 必须先过 adapter，再进入当前表；restore 后会重新执行必要 migration。

### Phase 3：CloudSyncCoordinator 生命周期升级

依赖：Phase 1、Phase 2、Phase 0 的测试云环境。

工作项：

- [ ] 将 coordinator 初始化拆成 account wait、RDB ready、distributed table ready、cloud service ready、bootstrap ready。
- [ ] 所有请求携带 ScopeToken、storeIdentity、generation 和 operationId；scope 未 ready 时返回 account_required/blocked，不把 skipped/no-table 报成 ok=true。
- [ ] bootstrap receipt 按 scope/store/table/schemaRevision/selectionRevision 保存；一张表或空选择不能完成其他表 bootstrap。
- [ ] 普通表与 VNC 在 selection re-enable 时都必须先 cloud-first，再开放该表 native-first。
- [ ] 给每个表 cloudSync 增加 watchdog：accept deadline、progress deadline、overall deadline；超时后调用取消/关闭路径并写 retryable receipt。
- [ ] timeout 后释放唯一队列；迟到/重复/乱序 callback 必须匹配 operationId/scope/store/generation，否则丢弃。
- [ ] 通过网络恢复、foreground、登录完成、selection re-enable、云事件和手动刷新触发同一队列；耗尽重试后进入明确 blocked/retryable。
- [ ] 把内存 manualDownloadSnapshot 改为磁盘 checkpoint；普通表和 VNC 共用一个总 operation/发布屏障，进程恢复后继续或完整回滚。
- [ ] 引入 per-table receipt 和跨表 apply journal；`degraded_success` 必须列出已提交/未完成表。
- [ ] 为 cloud-first 增加云服务可用性证明：账号、权限、schema、同步进度都确认后，才把空快照视为真实空。
- [ ] 对选中的表做 owner count、schema version、deleted/tombstone 和 payload hash 校验。
- [ ] 恢复失败时回滚本地业务表、extensions、localTables、metadata、mutation journal 和 selection；回滚失败进入 restore_pending，禁止自动上传。
- [ ] bootstrap 前允许的真实用户 mutation 进入 record-level journal；pull 后 reconcile，不得由 `finishStartupPull` blanket discard。
- [ ] 恢复隔离按 scope/table 保存；普通表和 VNC 全部成功且 journal 确认后，才清对应 `restored_not_uploaded`。
- [ ] 统一 CloudStore、HostSyncService、VncCloudSyncService 的入口；删除/封禁旧 CloudSyncService REST 写能力。

涉及文件：

- entry/src/main/ets/services/CloudSyncCoordinator.ets
- entry/src/main/ets/services/CloudSyncCoordinatorPolicy.ets
- entry/src/main/ets/services/CloudStore.ets
- entry/src/main/ets/services/HostSyncService.ets
- entry/src/main/ets/services/VncCloudSyncService.ets
- 新增 entry/src/main/ets/services/CloudSyncOperationStore.ets
- 新增 entry/src/main/ets/services/CloudSyncWatchdog.ets

测试：

- 云服务不可用、权限错误、表不存在、网络在 accept/progress/final 三个时点断开。
- accepted 无 finish、finish 无 accepted、重复/乱序/timeout 后晚到 callback；后续请求必须继续。
- 进程在每个阶段被杀，重启后读取 operation ledger。
- 空云、部分空云、只返回一张表、旧 schema 云行、云端冲突、重复回调。
- 首次 pull 失败后新增/修改/删除，再恢复网络，mutation 不丢、不反向覆盖。
- 普通表/VNC 任一子操作失败，检查总状态和恢复隔离不会提前解除。
- 同时触发 startup pull、手动 download、automatic push、crypto migration，必须串行且可判定。

退出条件：

- [ ] 任何操作都有终态：success、retryable、blocked、cancelled、rolled_back。
- [ ] 不再存在永久 pending 而无用户可见原因的路径。
- [ ] 失败期间没有自动上传覆盖云端。
- [ ] 双设备数据最终一致性、冲突和删除 tombstone 行为有设备日志证据。

### Phase 4：本地备份 v3、部分恢复和系统迁移

依赖：Phase 1、Phase 2、Phase 3；敏感备份格式定稿还依赖 Phase 5 的 envelope/KDF 边界。非敏感 inventory/adapter 可与 Phase 5 并行。

工作项：

- [ ] 复用现有 bounded I/O、写后重读和 RDB transaction，将 local backup 升为 v3；不另建平行备份服务。
- [ ] manifest 分离 formatVersion 与 RDB schemaVersion，包含 sourceAppVersion、accountScope、createdAt、每 section 的 absent/empty/rows/delete、table/column inventory、row/owner/tombstone count、section hash、crypto/trust descriptor 和 restore mode。
- [ ] 取得 backup lock 与一致性 RDB 读事务；每个表/extension/local table 显式成功或失败，禁止查询异常退化为空。
- [ ] 保留/适配 tombstone 语义，禁止校验器剥离 deleted flag 后把旧删除行重新插为活动行。
- [ ] 默认只导出脱敏配置。敏感备份必须由独立备份密码通过经过评审的 KDF 派生 AEAD key，并整体加密；不导出 AccountKit/RustDesk token、应用 verifier、设备 trust/consent 或设备绑定密钥引用。
- [ ] 先在应用私有目录生成 staging artifact：完整写入、fsync/close、重读验证、同目录原子 rename；再复制到 picker URI 并精确读回。不得假设任意 Document Provider 支持原子 rename。
- [ ] v1/v2/v3 adapter 使用冻结的历史 inventory；缺表标记 absent/no-op。普通可选字段可默认，owner/resetEpoch/recordType/envelope/trust 缺失必须 quarantine 或拒绝。
- [ ] 恢复分成 merge 和 replace 两种显式模式。merge 对 absent table no-op；replace 只清理用户明确勾选的表，绝不因旧备份缺表而清全库。
- [ ] 恢复前做 preview：来源 app/schema、账号、表/行/owner/tombstone、absent/empty/delete、字段损失、secret/locked、trust/consent、VNC epoch、冲突和 merge/replace。
- [ ] 导入前复用 VNC validator，检查 host/gateway/secret/trust 依赖；旧 epoch、孤儿、错误 hash/envelope 进入 quarantine。
- [ ] 写 durable restore_pending、before-image hash/checkpoint，停止 cloud/CRUD/session/敏感缓存；apply 后执行 owner/hash/reference/VNC/read-back 校验。
- [ ] rollback 失败或结果未知保持 blocked；禁止固定显示“原本地数据未被修改”。
- [ ] 成功后写 per-scope/per-table `restored_not_uploaded`；普通表/VNC 全部显式上传成功后才逐表解除。
- [ ] 恢复后密码/私钥/TOTP/VNC secret 若无法解密，保留结构和 locked 状态，不填空字符串覆盖原值。
- [ ] `onBackup` 只产生已验证的安全迁移 artifact；`onRestore(bundleVersion)` 只记录 durable restore intent，由正常启动在 account/store/schema/crypto ready 后走统一 import pipeline。
- [ ] 系统迁移明确排除登录 token、设备 trust、plain consent、活动 session 和 HUKS device-bound key；真实双设备验收通过后才重新开启 `allowToBackupRestore`。

涉及文件：

- entry/src/main/ets/services/LocalBackupPolicy.ets
- entry/src/main/ets/services/LocalBackupService.ets
- entry/src/main/ets/entrybackupability/EntryBackupAbility.ets
- entry/src/main/resources/base/profile/backup_config.json
- entry/src/main/ets/services/CloudStore.ets
- 新增 entry/src/main/ets/services/BackupManifestV3.ets
- 新增 entry/src/main/ets/services/BackupRestoreOperationStore.ets

退出条件：

- [ ] 旧七表备份可以恢复其中用户选择的表，新版未出现的表不会清空本地。
- [ ] 旧备份缺 VNC、extensions 或 localTables 时，行为可预览、可解释、可回滚。
- [ ] digest/AEAD、错误密码、文件截断、未知字段、owner mismatch 都被拒绝或进入可预览 quarantine。
- [ ] 系统 BackupExtensionAbility 有真实双设备/换机证据；否则配置已安全关闭。

### Phase 5：加密生命周期 V2

依赖：Phase 1、Phase 2、Phase 3。其 envelope/key/reset 契约是 Phase 4 敏感备份定稿的前置。

工作项：

- [ ] 将 crypto 状态改为 durable state：active、locked、enable_pending、migrating、disable_pending、reset_pending、blocked。
- [ ] 删除 HostListPage 与 DataCrypto 的双套编排；生产 UI 只能提交 operation intent、观察 receipt，不直接串联 set status/clear/push。
- [ ] setMasterPassword 必须防重入；先生成新 salt/verifier/key version，按记录迁移并写 receipt，最后提交 active。
- [ ] autoMigrate 按 table/record 记录 envelope version；进程中断后从 receipt 继续，不能依靠“是否加密”猜测整次操作是否完成。
- [ ] 引入 envelope v3；AAD 固定包含 app domain、ownerScopeId、table、recordId、field、schemaVersion、resetEpoch、keyVersion。每账号独立 DEK/keyVersion。
- [ ] 迁移通用 v1 空 AAD 和 VNC v2 常量 scope；`plain-v1` 只能在经本机确认的 local overlay 存在，云 bucket 和敏感备份 adapter 必须拒绝。
- [ ] lock/后台/账号切换通过 SensitiveDataBarrier 清 DEK、HostSync/KeyVault/RustDesk/VNC/TOTP 明文缓存、VNC handoff、SSH preflight 和页面 secret；已有连接按策略关闭或只读冻结。
- [ ] disableEncryption：验证密码 -> durable disable_pending -> 校验逐表迁移 -> 云端仍保持密文或 tombstone，绝不上传 plain-v1 -> 所有 receipt 完成后提交 disabled。
- [ ] resetEncryption：写 scoped reset control `{ownerScopeId, resetEpoch, operationId}`，停止 session，生成 checkpoint，只清目标 store/scope，按表写 receipt；禁止调用无 scope 的全库 clear。
- [ ] 远程 reset 按 scope 和最大 epoch 合并，重复/乱序/离线重连均幂等；每设备保留处理 receipt，失败维持 pending。
- [ ] 解锁失败/超次锁定不能永久阻塞 coordinator；UI 显示需要解锁、重试时间和恢复路径。
- [ ] 解锁失败计数/退避需要抗进程重启；日志、diagnostic、backup preview 和 toast 全部 redacted。
- [ ] 禁止 crypto 状态和 AccountKit token/登录态互相作为“解锁完成”的替代条件。

涉及文件：

- entry/src/main/ets/services/DataCrypto.ets
- entry/src/main/ets/services/KeyVaultService.ets
- entry/src/main/ets/services/CloudStore.ets
- entry/src/main/ets/services/CloudSyncCoordinator.ets
- 新增 entry/src/main/ets/services/CryptoOperationStore.ets
- VNC secret/trust service 和各协议敏感字段服务

退出条件：

- [ ] enable、lock、unlock、disable、forgot-password reset 每个阶段都能在进程被杀后恢复。
- [ ] 任意 crypto failure 不会产生部分明文覆盖、DEK 泄露或跨账号清理。
- [ ] reset epoch 不能倒退；旧 VNC secret/trust 不能复活。
- [ ] A/B 使用不同主密码、相同 recordId 和交错 reset 时互不影响。
- [ ] plain-v1、Pro token、AccountKit token 和设备 trust 均不能出现在云行或 portable/system backup。
- [ ] 日志、Toast、backup preview、错误上报不含 secret、token、私钥或明文密码。

### Phase 6：协议数据域和官方源码对齐

依赖：Phase 1-5。各协议可以并行实现，但必须共用 AccountScope/CloudSync/Backup/Crypto 契约。

#### 6.1 RDP

- [ ] rdpcredentials 增加 userid 和云端 username；远端主机与 credential 引用必须同 scope。
- [ ] 保持 passward 为历史 canonical cloud contract，迁移 password shadow 后不再重新生成。
- [ ] RDP certificate 观察到的 fingerprint 可作为提示，trustMode/allow-untrusted-root/host-mismatch 许可必须 device-local；新设备永不继承信任决定。
- [ ] RDP restricted-admin secret 必须绑定 host/credential/account，备份默认脱敏。
- [ ] add/edit/delete/get 全部使用 `(scope, credentialId)`；删除 credential 只能解绑同 scope host。
- [ ] 对照 FreeRDP upstream connection/settings/transport/update 行为，记录本地 OHOS patch queue，不把云数据模型耦合到 native settings。
- [ ] 本阶段不顺带升级 FreeRDP；如后续升级，先固定本地 fork patch queue，再跑现有 native 157/157 基线及证书、AAD、网关、音视频、clipboard、输入和断开回归。

#### 6.2 RustDesk 和 Relay

- [ ] 显式区分 Huawei ownerScopeId、RustDesk ProtocolPrincipalId、Pro accountId、relayId 和 device-local authorization。
- [ ] rustdeskrelays 所有行/账户/peer 都按 ownerScopeId + relayId + accountId 绑定；编辑必须保留不可变 owner。
- [ ] 旧 cryptoparams relay JSON 迁移只执行一次；旧值有损或无法解析时进入 quarantine，不覆盖新行。
- [ ] API password、shared key、账户 password 只有通过 envelope validator 才可进入云字段；Pro token 只存 owner+device 绑定的 HUKS/安全存储，不进入云或备份。
- [ ] 修复 RustDesk TOTP host binding：canonical RDB/cloud/backup roundtrip、同 scope TOTP 引用、删除解绑、重启保持；secret 仍独立加密和 opt-in。
- [ ] Pro 地址簿/relay metadata import 只生成 draft，由 scope-bound service 写入；控制面授权 key 也包含 ownerScopeId 和 deviceId。
- [ ] 以 RustDesk `12f2de595...` 对照连接/断开/重连/输入/文件传输语义；当前仓内 FFI ABI 变更必须单独版本化。
- [ ] RustDesk 上游更新同步许可、NOTICE、SBOM、源码 commit 和 release manifest；禁止把 AGPL 依赖变成未记录的闭源产物。

#### 6.3 SSH/SFTP

- [ ] SSH key、passphrase、host key trust、proxy 和 terminal 状态全部 scope 化。
- [ ] 私钥只有通过 envelope validator 才可进入云；host-key trust decision 永远 device-local，新设备首次连接仍询问。
- [ ] `sshKeyId` 只允许 SSH protocol host 引用，并验证 `(scope, protocol, type, id)`；RDP/RustDesk 畸形引用拒绝/quarantine。
- [ ] SSH session 在账号切换、后台和 restore_pending 时可取消，旧 session generation 不得回调新页面。
- [ ] SSH tunnel 作为独立 transport capability，不复用 VNC password 或 RustDesk relay。

#### 6.4 TOTP

- [ ] TOTP entry 读取/写入/删除按 userid；secret 永不进入普通日志和明文备份。
- [ ] 跨设备恢复先恢复 metadata 和 locked state；只有 master password/用户明确确认后才解密使用。
- [ ] 切换账号必须清除 TOTP 明文 cache 和 timer。
- [ ] 所有 host-to-TOTP 引用验证同 scope；同 id 不同账号不能互相自动提交。

#### 6.5 VNC

- [ ] 保持唯一云物理表 vncrecord，recordtype 分为 settings、host、gateway、secret、trust；本地完整 overlay 为 vnclocalrecords。
- [ ] 物理 identity 改为 scoped physicalId；logical record id 单独保存，vncrecord/vnclocalrecords 不再用裸 id 冲突替换。
- [ ] selection 按 scope/version 存储；reconcile 必须显式接收 ScopeToken，禁止无参数 `mergeVncRecords(true)` 扫描所有 owner。
- [ ] secret 从 v2 迁到账号/reset-epoch 绑定的 envelope v3；默认不上传，只有 scope、选择器、crypto ready、用户确认同时满足时镜像。
- [ ] reset_epoch、deletedAt、payload hash、owner relationship 在迁移、备份、下载、冲突和恢复中都校验。
- [ ] 旧 vncrecords 只迁移到本地 overlay，不能在新机 bootstrap 时 native-first 发布。
- [ ] trust 记录恢复后只成为 candidate，本机确认后才生效；plain-v1 consent、gateway target、token、证书引用不得跨设备/协议继承。
- [ ] RFB 3.3/3.7/3.8、VNC password、Raw/CopyRect/DesktopSize、BGRA、键鼠/clipboard、UltraVNC mode12 继续走独立 native engine；mode2 只保持 server-side contract fixture。
- [ ] WebSocket、公网 relay、SSH tunnel/reverse listen 无服务端协议和实机证据时保持 gate disabled。

### Phase 7：可观测性、安全和运维

依赖：Phase 3-6。

工作项：

- [ ] 增加 redacted sync diagnostic：scope hash、operation id、table、phase、rows、latency、error code；禁止账号原值、地址密码、token、secret。
- [ ] 删除 LoginPage 对 unionID/openID 的原值日志；authorizationCode/idToken/access/refresh token 和 RustDesk token 禁止进入普通 Preferences、日志和 crash context。
- [ ] 增加用户可读状态：尚未登录、等待云服务、同步中、部分成功、需要重试、需要解锁、恢复挂起、账号切换中、功能被云 schema 阻塞。
- [ ] 增加自检页：RDB schema、owner invariant、cloud table availability、last operation receipt、backup version、crypto state、VNC epoch。
- [ ] 自检区分 success、degraded_success、no-op、retryable、blocked 和 rollback-unknown，不把 skipped/tables=[] 计为成功。
- [ ] 为所有外部依赖保留 feature gate 和最小回滚开关；开关状态本身按设备，不进入账号云同步。
- [ ] 生成发布 manifest：app versionCode/versionName、Git commit、FreeRDP fork commit、RustDesk 对照 commit、native ABI、第三方许可证、数据库 schema version、backup format version。
- [ ] 规定故障处理：不自动删除数据；失败优先保留原始备份、checkpoint、quarantine 和 operation ledger。

### Phase 8：真实设备、云端和发布验收

依赖：所有前置阶段。

外部准备：

- [ ] 两台 API 23 HarmonyOS 设备，登录同一 HUAWEI ID，配置真实 distributed data sync permission。
- [ ] 一台第二账号设备或在同一设备完成 A/B 切换。
- [ ] 华为云测试项目、所有物理表和字段、权限、schema version、云端空表/部分表/拒绝访问场景。
- [ ] 旧版本 APK 至少覆盖添加 rdp username、relay JSON、SSH key、TOTP、VNC 旧表的版本。
- [ ] 真实 RDP server、RustDesk server/relay、SSH server、TOTP fixture、VNC server、UltraVNC Repeater。
- [ ] 网络注入工具：断网、延时、丢包、进程杀死、后台/前台、设备重启。

发布流程：

1. internal build：新 flags 全部关闭，验证旧用户启动和数据可读。
2. migration build：只打开本地 schema/migration，云写入仍需显式测试账号。
3. cloud pilot：打开 account fence 和 cloudLifecycleV2，限制测试账号，收集 operation receipts。
4. backup pilot：打开 BackupExtension/backup v3，验证旧备份、系统换机和失败恢复。
5. staged release：递增 app.json5 versionCode，先小比例发布，监控 migration failure、scope mismatch、restore pending、cloud timeout。
6. full release：所有 P0/P1 门禁通过，旧路径和回滚开关仍保留一个版本周期。

## 4. 全链路验收矩阵

### 4.1 新机器与首次启动

| 场景 | 预期 | 失败判定 |
| --- | --- | --- |
| clean install、无账号、无网 | 建立本地 schema，停在 anonymous，不能 cloud pull/push | 出现旧账号数据、云请求或空账号上传 |
| clean install、登录后有云数据 | 先取得 unionID/scope，再 cloud-first，完整校验后显示业务数据 | 登录前 pull、空云覆盖、部分表成功却显示全成功 |
| AccountKit A、系统 cloud identity B | cloudBinding blocked；不注册 distributed tables | 猜测绑定、把 A UI 数据写入 B 云 |
| clean install、云服务不可用 | 本地可用但标记 cloud unavailable；不清空、不上传 | 把 unavailable 当空云或永久 pending |
| 云表不存在/字段不匹配 | 对应表 blocked，显示迁移指引 | 静默丢字段或写入未注册字段 |
| 首次启动时用户立刻新增主机 | 写入待 bootstrap journal，云 pull 后按规则处理 | 新机本地新增被云空快照覆盖或反向覆盖云 |
| selection 关闭后在另一设备变更，再重新开启 | 对该表重新 cloud-first 后才允许上传 | 直接 native-first 覆盖另一设备数据 |

### 4.2 老用户升级

| 场景 | 预期 |
| --- | --- |
| 旧 app -> 新 app 正常更新 | versionCode 递增；RDB migration 在 UI 使用前完成 |
| 迁移中途杀进程 | 下次启动从 receipt 继续，原始行仍可恢复 |
| 旧 password/passward | canonical passward 保留，password shadow 不重新出现 |
| 旧 relay cryptoparams JSON | versioned runner 可达；按 source hash 幂等迁移，不重复上传 |
| 旧 vncrecords | 只迁本地 overlay；epoch/owner/payload 无效行 quarantine，不静默计为完成 |
| 旧数据库缺 username/userid | 进入 quarantine/待确认，不自动归属首次登录账号、不把空字段覆盖云 |
| 新库恢复旧 backup 后再次出现 password/legacy relay | import adapter 重新 canonicalize，不受旧 marker 跳过 |
| 相同 id 的 A/B VNC 行 | scoped physical identity 保留两者，不发生 REPLACE |
| 新字段/新表 | 未知旧数据不丢；新表有明确 absent/empty 语义 |

### 4.3 老用户在新设备登录并拉云

1. 新设备启动时不得以旧设备缓存推断账号。
2. 用户登录 A，创建 A scope，清空 anonymous 视图。
3. 打开 A 专属 physical store 并注册表；云 first pull 只导入 A；每表 owner count 与 payload hash 校验。
4. RDP username、relay accounts、SSH key metadata、TOTP locked state、VNC host/gateway/secret opt-in 均按契约出现。
5. 新设备不自动信任 RDP certificate、SSH host key、VNC trust。
6. pull 失败不显示半恢复数据；重试后成功或进入 restore_pending。

### 4.4 A/B 账号切换

- A 有主机、RDP credential、relay、SSH key、TOTP、VNC secret 和 active session。
- 登出 A 时所有服务停止/清 cache/journal。
- 登出清 unionID/openID、ScopeToken、Pro/VNC/SSH 临时明文，终止活动 native session；磁盘 A store 保留。
- 登录 B 后只显示 B；B 的 mutation 不能写入 A 的 row 或 A 的 cloud dirty table。
- 切回 A 后 A 的数据仍完整；B 的数据不被清除。
- 在切换每一个阶段杀进程，重启后继续 switching 或回到安全的 blocked 状态。

### 4.5 云同步异常

- 云端空、部分空、只有旧表、只有新版表。
- 权限拒绝、网络超时、Progress 回调重复、accepted 但没有 finish。
- accepted 后永久无 finish、timeout 后迟到 finish、A operation 在 B generation 回调。
- 下载中本地写入、上传中账号切换、上传中加密 reset、手动 download 与 automatic push 并发。
- 首次 pull 失败后产生真实用户 mutation；网络恢复后必须 record-level reconcile。
- 冲突、删除 tombstone、旧 reset epoch、同 ID 不同 owner。
- 预期：每次都有可查询 operation receipt；没有自动静默覆盖。

### 4.6 本地备份与恢复

- v1 七表 -> v3：导入所选表；缺少 vncrecord 不清空。
- v2 八表 -> v3：保留 extensions/localTables；普通可选字段可默认，安全字段缺失 quarantine，未知字段隔离。
- 缺 extensions/localTables、空表、截断文件、错误 hash、错误密码、未知 scope、重复 ID。
- 表状态覆盖 absent/present-empty/present-rows/explicit-delete；distributed tombstone 不得复活。
- 注入任意表查询失败时不得生成成功文件；并发写入时三个 section 必须来自一致性快照。
- merge 与 replace 都必须二次确认；replace 只影响显式选择的 scope/table。
- 导出任何一张表失败，不生成成功文件。
- 恢复中杀进程，重启后回滚或继续；恢复成功后 restored_not_uploaded，用户确认后才上传。

### 4.7 系统备份/换机

- 开启系统 backup 时验证 RDB、Preferences、BackupExtension data、KeyVault 引用、crypto state、cloud selection 的实际覆盖范围。
- 新设备 restore 后先进入 restore_pending，必须完成 schema/owner/crypto/cloud 校验。
- onRestore 的 bundleVersion、重复回调、中断重入均进入同一 durable intent；系统回调不直接打开业务 store 写库。
- AccountKit/RustDesk token、设备 trust/consent、HUKS device-bound key 和旧 bootstrap marker不得直接继承为可用状态。
- 系统只恢复了文件但没有业务表时，UI 必须明确报告“系统备份不包含业务数据”，不能显示成功。
- 如果 API 23 BackupExtension 无法安全导出所需数据，发布前关闭 allowToBackupRestore 并引导本地 v3 backup。

### 4.8 加密生命周期

- 首次启用、自动迁移、后台锁定、正确解锁、错误解锁、关闭加密、忘记密码 reset。
- 每个阶段杀进程、断网、另一个设备在线、另一个账号有数据、VNC secret sync 开关不同。
- A reset 时 B 设备离线并产生 stale write；B 上线后旧 epoch 数据不得复活。
- 预期：操作可恢复、DEK/明文 cache 清理、reset epoch 单调、其他账号不受影响、plain-v1 不上云。

### 4.9 VNC 和协议数据域

- VNC 直连 RFB、Repeater mode12、旧 mode2 fixture、secret 默认不同步、用户 opt-in、VNC trust 二次确认、旧 vncrecords 恢复、offline overlay。
- RDP credential username/密码/证书 trust。
- RustDesk relay legacy JSON、Pro account/peer、密码/共享 key、Pro token at-rest、TOTP binding 重启/云/备份 roundtrip。
- SSH private key/passphrase/host trust。
- TOTP secret locked/unlocked。
- RDP/SSH/VNC trust 在新设备均重新确认；跨协议畸形引用被拒绝。
- 任意协议 session 在后台、账号切换、restore、crypto reset 时均可取消，旧回调不能穿透 scope。

## 5. 测试分层与证据要求

### 5.1 纯策略/单元测试

新增或扩展：

- AccountScopePolicy.test.ets
- AccountTransitionPolicy.test.ets
- AccountStoreBindingPolicy.test.ets
- SensitiveDataBarrierPolicy.test.ets
- CloudOwnerFencePolicy.test.ets
- SchemaMigrationPolicy.test.ets
- CloudSyncOperationPolicy.test.ets
- CloudSyncBootstrapReceiptPolicy.test.ets
- BackupManifestV3.test.ets
- BackupRestoreMergePolicy.test.ets
- CryptoOperationPolicy.test.ets
- CryptoEnvelopeV3Policy.test.ets
- RdpCredentialCloudAdapter.test.ets
- RustDeskLegacyRelayMigration.test.ets
- RustDeskPeerTotpBindingPersistence.test.ets
- RustDeskProCredentialIsolation.test.ets
- VncRecordPolicy.test.ets
- VncScopedIdentityPolicy.test.ets

覆盖空值、重复、非法 owner、同 id 不同 scope、跨协议引用、旧/部分/损坏 schema、未知列、epoch、hash、operation 状态、重试退避、callback 乱序和进程恢复。

### 5.2 RDB/集成测试

- 为每个旧版本建立 fixture；不使用只有当前 schema 的假数据。
- 检查 migration receipt、事务回滚、quarantine、row count、owner count、tombstone。
- 检查 anonymous/per-account store 物理隔离，B 的上传物理快照不得包含 A 行。
- 模拟进程被杀的每个 operation phase；模拟 callback duplicate/late.
- 检查 setMaster/enable/disable/reset/restore 每个步骤的故障注入和冷启动重入。
- 检查本地 backup restore 后 extension、localTables、journal、metadata、tombstone、VNC validator 和业务表的一致性。
- 检查任一 export section 失败不会产生成功 artifact，rollback 不确定会进入 blocked。

### 5.3 设备测试

- API 23 两台设备、同一华为账号、同一网络/分布式权限。
- API 23 单设备 A/B 账号切换。
- 冷启动、后台、前台、锁屏、网络切换、设备重启。
- 活动 RDP/RustDesk/SSH/VNC session 中执行 logout/A->B/restore/reset，旧 callback 必须失效。
- 记录真实设备型号、HarmonyOS 版本、应用 versionCode、cloud schema revision；不要记录账号、密码、地址和原始 secret。

### 5.4 真实云测试

- 测试表创建、字段权限、自动同步、离线保留、网络恢复、云端空值和 partial failure。
- 对每张表验证当前 registered physical store 只含当前 owner，不能只依赖 UI/SQL filter。
- 逐表验证空、部分空、字段不匹配、权限拒绝、selection re-enable 和 accepted-without-finish。
- 云端 reset/删除/冲突必须留 operation receipt 和可导出的脱敏诊断。

### 5.5 构建与发布门禁

任何代码、ArkTS、native、Rust、测试、配置或本计划关联的实现改动，都必须执行：

~~~sh
cd RemoteDeskHarmonyOS
source scripts/macos_env.sh
hvigorw --mode module -p module=entry -p product=default default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon
hvigorw --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --no-daemon
~~~

另外必须执行并记录：

- git diff --check
- 项目要求的 Light compliance gate 和开源发布清单检查
- RustDesk/FreeRDP native tests
- 可运行的 ArkTS unit/ohosTest；如果 ohosTest task 未注册，必须记为 blocker，不得用旧任务名代替
- 真实设备/云端测试结果或明确的外部 blocker

## 6. 直接 agent/责任人拆分

这是执行时的并行拆分；每个 agent 只处理自己的生命周期，不允许再派发子 agent，不创建重复 Codex task，不改动其他 agent 的分支。

本次 2026-07-29 重审已按账号生命周期、云同步、schema migration、备份、crypto、协议数据域六个专题使用直接 agent 独立复核；六个 agent 均确认只读、零文件修改、零嵌套派发，随后已全部关闭。实施阶段继续沿用相同边界，但 agent 交付物必须是可审查的小闭环，不能让多个 agent 同时改同一核心文件。

| Owner | 责任域 | 交付物 |
| --- | --- | --- |
| Agent A | AccountScope、登录、退出、A/B 隔离 | 代码、owner invariant、A/B 测试、泄漏清单 |
| Agent B | RDB schema migration、旧版本 fixture | migration runner、receipt、v1/v2 fixture 报告 |
| Agent C | CloudSyncCoordinator、网络恢复、timeout、rollback | operation ledger、双设备模拟/设备证据 |
| Agent D | local backup v3、system BackupExtension、部分恢复 | manifest、restore preview、旧备份矩阵 |
| Agent E | crypto enable/lock/disable/reset | durable state machine、断点恢复、secret redaction |
| Agent F | RDP/RustDesk/SSH/TOTP/VNC 数据域 | 各协议 adapter、官方源码对照、native/real endpoint 矩阵 |
| Integration owner | 合并、构建门禁、发布和风险签字 | 统一报告、feature flag、release manifest、最终 go/no-go |

执行规则：

- agent 只接收当前阶段明确的文件范围和验收项。
- agent 返回必须包含：改动文件、事实证据、测试命令、失败/阻塞、未验证假设、回滚方法。
- 禁止 agent 派发新 agent；禁止用 create_thread 代替子任务 agent；禁止为了“等待”创建重复 task。
- 任何 agent 发现跨域问题，提交 blocker 给 Integration owner，不自行扩大范围。

## 7. 风险、优先级与回滚

| 优先级 | 风险 | 修复前的策略 |
| --- | --- | --- |
| P0 | 共享 distributed store、A/B 数据泄漏、旧账号 dirty upload、登录前云 pull | 无 validated binding 不注册云表；迁到 per-account store 前关闭账号云写 |
| P0 | 系统备份开关为 true 但实现为空 | 实现前关闭 allowToBackupRestore，UI 引导本地备份 |
| P0 | rdpcredentials/cryptoparams 无可靠 owner | 禁止跨设备同步这两类表，或先完成云 schema |
| P0 | 备份伪成功空表、跨账号整库导出/覆盖、tombstone 复活、敏感明文导出 | 暂停敏感导出和自动 replace；只保留只读检查 |
| P0 | reset 永久半完成、全库 clear、lock/logout 明文缓存残留 | 关闭远端 disable/reset；先上 scoped ledger 与 SensitiveDataBarrier |
| P0 | RustDesk Pro token 明文全局持久化且登出不清 | 禁止系统/portable 迁移；迁入 owner+device 安全存储 |
| P1 | 旧备份整包拒绝、absent 被误解为 empty | backup v3 adapter 完成前只提供预览，不自动 replace |
| P1 | cloudSync accepted 但未 finish，进程杀死后永久 pending | 使用 operation ledger/watchdog；超时进入 retryable/blocked |
| P1 | pre-bootstrap mutation 丢失、selection re-enable 直接上传、普通/VNC partial apply | per-table receipt、record reconcile、统一 checkpoint/发布屏障 |
| P1 | RDP username、dead relay migration、VNC skipped row/PK、RustDesk TOTP binding 丢失 | quarantine + canonical adapter；不得写空值覆盖 |
| P1 | RDP/SSH trust 跨设备继承、secret adapter 不校验 envelope | trust device-local；云 bucket fail-closed validator |
| P2 | VNC/WebSocket/公网 relay 缺后端或实机契约 | feature gate disabled，不宣称支持 |
| P2 | FreeRDP fork 与 upstream 漂移、RustDesk ABI/许可证未记录 | 固定 commit、patch queue、SBOM 和 native regression |

回滚原则：

1. 数据迁移失败优先保留原表、原备份、quarantine 和 receipt。
2. feature flag 可以关闭新同步/备份/crypto/VNC secret 路径，但不能删除用户数据。
3. 云 schema 不做破坏性删除；新增字段保留兼容读窗口。
4. 发布回滚只能回到仍能读取当前 schema 和 backup manifest 的版本；如果旧版本不能理解新数据，先停写并使用导出恢复。
5. 任何需要清表、删除云 tombstone 或重置 crypto 的操作都必须有明确用户确认和可验证的 account scope。

## 8. 完成定义（Definition of Done）

只有同时满足以下条件，才可以把该升级称为完成：

- [ ] 所有业务读取/写入/同步/缓存/Preferences/备份/恢复都绑定 ScopeToken；owner 由 service 注入。
- [ ] anonymous 与每个 Huawei owner 使用隔离 physical store；任何 registered distributed store 只含当前 validated owner。
- [ ] 登录/登出/A-B transition 可等待、可恢复；旧 generation 的同步、native callback、timer、session 和明文缓存全部失效。
- [ ] 新机首次启动、老用户升级、新设备拉云、A/B 切换、云异常、备份恢复、系统换机、旧备份部分恢复均有通过记录。
- [ ] rdpcredentials username/userid、cryptoparams owner、relay legacy、VNC legacy/scoped PK、RustDesk TOTP binding 的迁移和云 schema 已真实验证。
- [ ] CloudSyncCoordinator 每次操作都有 scoped durable receipt、逐表 bootstrap、watchdog、pre-bootstrap reconcile、明确 partial/degraded 语义和恢复路径。
- [ ] BackupExtensionAbility 要么真实恢复业务数据并通过换机验收，要么配置关闭且 UI 不再暗示系统备份可用。
- [ ] backup v3 默认脱敏；敏感模式使用独立 KDF+AEAD；absent/empty/delete/tombstone、scope、merge/replace 和 rollback-unknown 均有测试。
- [ ] crypto envelope v3 与 enable/lock/unlock/disable/reset 在断点、断网、离线设备和账号切换下不泄露、不串号、不半完成；plain-v1 不上云。
- [ ] RDP/RustDesk/SSH/TOTP/VNC 各自引用验证 `(scope, protocol, type, id)`；trust device-local；VNC 仍只有 vncrecord 一个云物理表。
- [ ] AccountKit/RustDesk token 位于安全存储，不进入日志、云、便携备份或系统迁移。
- [ ] FreeRDP fork、RustDesk 对照 commit、RFB/UltraVNC 契约、许可证和 SBOM 已记录。
- [ ] API 23 ArkTS compile、assembleHap、native tests、git diff check、Light gate 和实际设备/云测试全部有证据。
- [ ] 最终报告区分 A/B/C/D 证据等级，并列出尚未验证的外部依赖；不存在“代码看起来支持所以算完成”的项目。

## 9. 建议的第一批实施顺序

下一轮不要先改 UI，也不要把所有修复塞入一个提交。建议按以下不可交换的依赖顺序形成小闭环：

1. **Safety-0**：关闭系统 backup 声明、无账号云注册/同步、无 owner/敏感表默认上传和远端 disable/reset；封禁 legacy REST 写入口。
2. **Fixture-0**：冻结旧 APK/RDB/backup、A/B 同 id、tombstone、旧 Preferences/journal/reset fixture；建立测试 AGC additive schema。
3. **Foundation-1A**：`AccountSessionCoordinator`、ScopeToken/generation、AccountKit-first 启动和完整 logout/SensitiveDataBarrier。
4. **Foundation-1B**：anonymous/per-account physical store、账号与 cloud identity fail-closed 绑定、Preferences 分类。
5. **Migration-2A**：schema runner/receipt/quarantine/introspection 与 scoped metadata/journal/selection。
6. **Migration-2B**：按 cryptoparams -> RDP credential -> usersettings -> password/passward -> relay JSON -> VNC legacy/scoped PK 顺序迁移。
7. **API-2C**：CloudStore/HostSync/KeyVault/VNC/RustDesk Pro 全部 scope-bound；删除裸 id mutation/loadAll；补跨协议引用约束。
8. **Sync-3A**：scoped operation ledger、逐表 bootstrap receipt、selection re-enable barrier、三层 watchdog 和 late callback fence。
9. **Sync-3B**：record-level pre-bootstrap reconcile、磁盘 checkpoint、普通表/VNC 统一发布屏障、foreground/network recovery。
10. **Crypto-5**：envelope v3、唯一 durable crypto orchestrator、scoped reset control 和 SensitiveDataBarrier 完整接入。
11. **Backup-4**：在 owner/envelope/ledger 冻结后实现 v3 adapter、预览、AEAD、durable restore；最后接系统 BackupExtension。
12. **Protocol-6**：RDP username/trust、RustDesk Pro/TOTP binding、SSH/TOTP/VNC identity/selection 逐域打开 feature flag。
13. **Release-8**：A/B、双设备真实云、系统换机、旧版本原位升级、真实协议端点和 staged release。

依赖说明：Backup v3 必须在 AccountScope、schema adapter 和 envelope v3 契约确定后定稿，避免固化错误 owner/密钥边界；但 Phase 0 的备份止血必须最先执行。云端 additive schema 可以和本地基础设施并行准备，生产 feature flag 只能在对应 receipt 与真机验收后打开。

每一步都必须在主分支合并前通过项目规定的构建门禁；任何外部云/设备 blocker 都写进本文件对应阶段和最终发布报告，不能用“待后续”掩盖未完成的生命周期。
