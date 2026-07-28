# RemoteDeskHarmonyOS 云同步、备份恢复与升级全链路升级计划

> 计划日期：2026-07-28
> 适用仓库：RemoteDeskHarmonyOS
> 当前状态：待实施；本文件是升级路线图，不代表代码已经完成
> 目标基线：API 23 上限，兼容现有 main 及已发布旧版本数据
> 计划原则：账号隔离优先于同步便利；可恢复优先于静默继续；无法证明安全时 fail-closed

## 0. 结论先行

当前代码已经有一套相当完整的同步保护基础：启动 cloud-first barrier、自动上传延迟、空云快照保护、串行 CloudSyncCoordinator、dirty/retry/conflict 持久化、手动下载回滚、restored_not_uploaded 隔离，以及 VNC 的独立物理表、v2 AAD、reset epoch 和 trust 二次确认。

但当前版本仍不能把“新机、换机、升级、双设备云恢复、账号切换、系统备份、旧备份部分恢复”称为发布级闭环。必须按下面的依赖顺序实施：

1. 先建立 AccountScope 和所有业务表的 owner fence。
2. 再把启动、登录、切换、退出和服务缓存绑定到同一个账号生命周期。
3. 再做数据库版本迁移和云表契约迁移。
4. 再升级云同步状态机、超时、断网恢复和跨表恢复。
5. 再实现本地备份 v3 和系统 BackupExtensionAbility，或者在完成前关闭系统备份声明。
6. 再把加密启用、锁定、解锁、关闭和忘记密码 reset 做成可恢复的持久化状态机。
7. 最后通过两台 API 23 设备、华为云真实表、旧 APK、旧 RDB 和真实协议端点验收。

本计划明确禁止以下发布策略：

- 未完成账号过滤时继续扩大云同步范围。
- 通过“时间更新”或“本地非空”猜测云端与本地谁权威。
- 把空实现的系统备份能力继续配置成可备份。
- 用新版缺少的表清空当前本地表，冒充“部分恢复”。
- 把新设备登录等同于“启动时已经知道当前账号”。
- 把 VNC、RDP、RustDesk、SSH 的凭据放入共用的无 scope 缓存。
- 在没有官方服务端契约时开放 WebSocket、公网 relay、SSH reverse listen。

## 1. 证据基线

### 1.1 本地代码直接证明的事实

| 编号 | 事实 | 代码位置 | 计划结论 |
| --- | --- | --- | --- |
| C-01 | EntryBackupAbility 的 onBackup/onRestore 只有日志和空 Promise；backup_config 却允许备份恢复 | entry/src/main/ets/entrybackupability/EntryBackupAbility.ets:6-15；entry/src/main/resources/base/profile/backup_config.json:2 | P0。必须实现真实导出/恢复，或在完成前关闭声明 |
| C-02 | EntryAbility 先初始化 KeyVaultService、HostSyncService，再请求 startup pull；没有看到 AccountKitService.init 的启动调用 | entry/src/main/ets/entryability/EntryAbility.ets:159-170；entry/src/main/ets/services/AccountKitService.ets:66-74 | P0。云 pull 必须等 AccountScope 完成 |
| C-03 | 登录成功只更新 AuthService、保存凭据、保存 loginMode、跳主页面；没有统一 rebind、清旧缓存、cloud-first 等待协议 | entry/src/main/ets/pages/LoginPage.ets:200-228；entry/src/main/ets/pages/HostListPage.ets:3451-3487 | P0。登录成功必须成为一次完整的 scope transition |
| C-04 | AccountKitService 在 dataPreferences 尚未初始化时只更新内存 credential，持久化可能丢失 | entry/src/main/ets/services/AccountKitService.ets:90-120 | P1。启动初始化必须早于任何登录回调 |
| C-05 | remotehosts、RDP credentials、relay、SSH keys、TOTP 的普通读取路径直接查询整表；VNC 路径才统一携带 userId | entry/src/main/ets/services/CloudStore.ets:2928-2948、3293-3335、3641-3658、3800-3828、4125-4143、4450-4505 | P0。所有读取、写入、删除、合并和扩展表都必须绑定 scope |
| C-06 | rdpcredentials 本地表有 username，但云字段白名单只有 id/label/password/createdat/updatedat；username 被放入 local extension | entry/src/main/ets/services/CloudTableAdapter.ets:8-16、41-56；entry/src/main/ets/services/CloudStore.ets:2936-2942、2951-2968 | P1。新设备云恢复会丢失 RDP 用户名，必须扩展云契约或停止该表跨设备同步 |
| C-07 | local backup v2 要求顶层表数量严格等于 CLOUD_SYNC_TABLES；旧七表备份在新版增加 vncrecord 后不能作为部分备份恢复 | entry/src/main/ets/services/LocalBackupPolicy.ets:190-219、224-242；entry/src/main/ets/services/CloudSyncPolicy.ets:1-10 | P1。需要显式 version adapter 和 merge/replace 语义 |
| C-08 | 行内新增列可以缺失，但缺表、extensions/localTables 语义和 VNC 业务语义不能完整表达 | entry/src/main/ets/services/LocalBackupPolicy.ets:328-349、270-324 | P1。缺失字段、缺失表、空表和显式删除必须分开 |
| C-09 | CloudSyncCoordinator 已经串行化并持久化 dirty/retry/conflict/journal；CloudStore 有手动下载快照和回滚 | entry/src/main/ets/services/CloudSyncCoordinator.ets:152-239、entry/src/main/ets/services/CloudStore.ets:490-546 | 保留并扩展，不重写成多套同步入口 |
| C-10 | CloudStore 调用 relationalStore.cloudSync 的完成回调与 Progress.SYNC_FINISH 分离，但当前没有统一的应用级 watchdog/cancel ledger | entry/src/main/ets/services/CloudStore.ets:887-1082 | P1。超时、进程被杀和半完成必须可判定、可恢复 |
| C-11 | 旧 relay JSON 仍有从 cryptoparams 合并到 rustdeskrelays 的兼容路径；新链路已经有独立 rustdeskrelays 表 | entry/src/main/ets/services/CloudStore.ets:3053-3093、1241-1285 | P1。迁移必须有一次性 marker、重复执行幂等和账号绑定 |
| C-12 | 旧 vncrecords 会迁移到本地 VNC overlay，且故意不立即上传；新云物理表只有 vncrecord | entry/src/main/ets/services/CloudStore.ets:1425-1494；entry/src/main/ets/services/VncRecordPolicy.ets:5-23 | 保留这一安全边界，补齐旧表、旧备份和 scope 的验证 |
| C-13 | DataCrypto 的 resetEncryption 会先写 reset，再清业务表和 crypto 参数并推送；autoMigrate 明确不是事务性的 | entry/src/main/ets/services/DataCrypto.ets:464-530、656-701 | P1。改为可恢复的 durable operation state machine |
| C-14 | logout 清理认证态、loginMode、AccountKit 凭据和内存 DEK，但没有统一清业务行、HostSync/KeyVault/VNC cache、dirty/retry/journal | entry/src/main/ets/pages/HostListPage.ets:3422-3448 | P0。A/B 切换前必须完成旧 scope drain |

### 1.2 官方文档与官方源码依据

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
| [应用安装卸载与更新](https://developer.huawei.com/consumer/cn/doc/doccenter-getting-started/application-package-install-uninstall) | 应用升级必须递增 app.json5 的 versionCode，可通过应用市场或应用内检测升级 | 发布门禁必须同时验证包升级、RDB migration 和 versionCode；不得把“安装新包”当作迁移完成 |
| [RustDesk 官方仓库](https://github.com/rustdesk/rustdesk/tree/d412d198720aa56f6cfed2dfad262e8fb1322fb7) | 2026-07-28 核对的 master 头为 d412d198；remote_page 文件为 a9185d6a；client io loop 为 c0eb7fb5；server connection 为 4dc07d36 | 本项目当前 FFI 不是直接依赖上游 crate；升级时必须以固定上游 commit 做能力/协议对照，并更新许可、SBOM 和 ABI 记录 |
| [RustDesk remote page](https://github.com/rustdesk/rustdesk/blob/a9185d6a309a3a3dad76a30c832e7f18bc0eaa53/flutter/lib/desktop/pages/remote_page.dart) | 上游远程连接 UI、会话和输入/显示语义参考 | 只借鉴协议/行为契约，不把 Flutter UI 状态直接移植到 ArkTS |
| [FreeRDP 官方仓库](https://github.com/FreeRDP/FreeRDP/tree/973171425bb707deacbb907671e219cff2de478a) | 2026-07-28 核对的 master 头为 973171425；update.c 文件版本为 e32c57dd | 需要将本地 OHOS fork 维护为可追踪 patch queue，升级前后比较 core/settings/transport/update 行为 |
| [FreeRDP update.c](https://github.com/FreeRDP/FreeRDP/blob/e32c57ddca84e382a0e48279b560668b20183b31/libfreerdp/core/update.c) | 上游更新处理和会话数据流参考 | RDP 凭据/云同步升级不能改变 native ABI；协议变化须有 FreeRDP 版本、OHOS patch 和回归矩阵 |
| [本项目 FreeRDP fork 分支](https://github.com/Mydstiny/RemoteDeskHarmonyOS/tree/freerdp-ohos) | 当前子模块指向公开仓库 freerdp-ohos 分支 commit dae8276a | 不直接切到 FreeRDP upstream；先生成 upstream-to-ohos 差异、冲突清单和可回滚 bundle |
| [RFB protocol specification](https://github.com/rfbproto/rfbproto/blob/master/rfbproto.rst) | RFB 版本协商、security type、ServerInit、更新编码和输入事件 | VNC 生命周期必须把 transport pairing 与 RFB handshake 分层，拒绝未知 security type |
| [LibVNC/libvncserver](https://github.com/LibVNC/libvncserver) | VNC client/server 行为与编码参考 | 如引入第三方实现，必须固定 commit、封装在 native engine、补 license/SBOM 和 fuzz gate |
| [UltraVNC mode12](https://github.com/UltraVNC/UltraVNC/blob/main/repeater/mode12_listener.cpp) / [mode2](https://github.com/UltraVNC/UltraVNC/blob/main/repeater/mode2_listener_server.cpp) | Repeater viewer/server 角色和配对字节契约 | viewer 不得把 mode2 server listener 冒充成客户端连接；没有真实 Repeater 不能宣称 relay 可用 |

本计划使用了公开官方网页和 GitHub CLI 核对的 commit 证据。华为官方文档页部分由动态文档中心渲染，执行阶段仍要把 API 23 对应的本地文档快照和 SDK 版本写入验证记录。

### 1.3 证据等级

- A：当前代码/测试直接证明的行为。
- B：官方文档或官方源码明确约束的行为。
- C：需要华为云、双设备、旧 APK 或真实协议端点才能证明的行为。
- D：基于代码路径的风险推断，必须在实施中转为 A 或 C。

报告、提交说明和发布说明必须标注证据等级，不能把 D 级风险写成“已经在真实云端复现”。

## 2. 目标架构与不变量

### 2.1 统一账号生命周期

新增 AccountScopeService，所有业务服务只接受 typed scope，不接受空字符串或从 UI 临时读取的 userId。

状态机：

~~~text
anonymous
  -> account_loading
  -> authenticated(scopeId)
  -> cloud_bootstrap(scopeId)
  -> ready(scopeId)
  -> switching(oldScope -> newScope)
  -> locked(scopeId)
  -> restore_pending(scopeId)
  -> blocked(reason)
~~~

固定规则：

1. scopeId 由稳定的 Huawei unionID 规范化得到；openID、authorizationCode、access token 不能作为跨设备 owner。
2. 未登录时只能使用明确标记为 device-local 的数据；不得启动账号云 pull/push。
3. 登录成功不是 UI 状态更新，而是一次可等待的 transition：停旧任务、清旧缓存、加载新 scope、执行新 scope cloud-first、成功后才发布 ready。
4. 账号切换期间拒绝业务 CRUD、云上传和新连接；正在运行的 RDP/RustDesk/SSH/VNC session 必须先 cancel/drain。
5. logout 必须清除所有带 scope 的内存对象、selection、dirty/retry/conflict/journal cursor、VNC overlay view、DEK 使用态和协议缓存；磁盘上的其他账号数据不能被删除。
6. scope 解析失败、unionID 为空、账号变更但 transition 未完成时，界面显示 blocked/needs-login，而不是显示上一次账号的内容。

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
| vncrecord | userid + recordtype | 保持唯一物理云表，逻辑行均带 userid | 保留 vncrecords -> vnclocalrecords 迁移和 secret opt-in |
| vnclocalrecords | 设备本地 overlay | userid + device-local | 账号切换只重载当前 scope，不能删除别的账号 |
| localextensions/journal/metadata | 设备本地 | owner scope + operation scope | 切换时清理视图，不删除其他账号的备份数据 |

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

- operationId、scopeId、deviceId、appVersion、schemaVersion。
- source、direction、selected tables、precondition snapshot hash。
- 每张表的 started/accepted/finished/failed/rolled_back 状态。
- 请求开始和最后进度时间、watchdog deadline、重试次数、错误码。
- 迁移/恢复前后的 row count、owner count、tombstone count 和 hash。
- 是否允许自动重试，是否需要用户确认，是否被 crypto/restore/account switch 阻塞。

平台 cloudSync 的回调只代表平台阶段；应用只有在 Progress.SYNC_FINISH、表快照校验和本地 apply 全部通过后，才把该表标记为成功。

### 2.4 数据合并原则

1. 首次云 bootstrap 采用 cloud-first；没有有效账号 scope 时不执行。
2. 已完成 bootstrap 的设备才允许 native-first；dirty journal 必须与当前 scope、operation generation 匹配。
3. 空云快照只有在云 service、表权限、账号和 schema 都已确认可用时才可被解释为“真实空”；否则是 unavailable。
4. 手动下载必须在磁盘上保留可恢复 snapshot，不能只放内存；进程被杀后要么恢复前快照，要么进入 restore_pending。
5. 跨物理表不能声称云端原子；本地 apply 采用 transaction + journal + receipt，失败时恢复到上一致性版本，并显式列出已完成表。
6. deleted tombstone、reset epoch 和 schema version 参与冲突比较；旧 epoch 或其他 scope 的记录永远不能复活。

## 3. 分阶段实施路线图

每个阶段只允许一个主责任人/直接 agent，子 agent 不得继续派发任务。阶段完成必须提交代码、测试、证据和回滚说明，不能只提交“已检查”。

### Phase 0：契约冻结、旧数据样本和云端前置

依赖：无。建议作为第一条独立分支 codex/cloud-lifecycle-contract。

工作项：

- [ ] 建立 schema inventory：本地 RDB、云表、local extension、local table、Preferences、KeyVault、AccountKit、VNC overlay 的字段和 owner。
- [ ] 记录当前 main commit、FreeRDP fork commit dae8276a、RustDesk 对照 commit d412d198，以及构建 SDK/API 23 版本。
- [ ] 收集并脱敏保存旧版本 APK、旧 RDB fixture、旧 local backup v1/v2、旧 relay cryptoparams JSON、旧 vncrecords 表 fixture。
- [ ] 定义 rdpcredentials.userid/username 和 cryptoparams.userid 的云端 schema 变更申请；在 AGC/华为云创建测试环境，不直接使用生产表。
- [ ] 为每个旧数据来源生成 migration manifest：来源版本、可恢复字段、丢失字段、需要用户选择的字段、禁止自动导入的字段。
- [ ] 增加 feature flags：accountScopeFence、cloudLifecycleV2、backupV3、cryptoLifecycleV2、vncSecretSync；默认在开发环境关闭新路径，直到下一阶段通过。

涉及文件：

- entry/src/main/ets/services/CloudSyncPolicy.ets
- entry/src/main/ets/services/CloudTableAdapter.ets
- entry/src/main/ets/services/LocalBackupPolicy.ets
- entry/src/main/ets/services/VncRecordPolicy.ets
- docs/codex/CURRENT.md、docs/codex/QUEUE.md、docs/codex/DECISIONS.md
- 新增 docs/migrations/manifest-v1-to-v3.json（只放字段元数据，不放用户数据）

退出条件：

- [ ] 云端测试表字段、类型、权限、主键和 distributed table 注册方式已由真实环境确认。
- [ ] 每个旧 fixture 都能被分类为可自动迁移、需用户确认、不可迁移。
- [ ] 没有任何用户密钥、token、云端地址密码进入仓库。

回滚：

- 只回滚 feature flag 和测试云 schema；不删除旧表、不覆盖旧备份。

### Phase 1：AccountScope、登录绑定与账号隔离

依赖：Phase 0。

工作项：

- [ ] 新增 AccountScopeService/AccountScopeState，统一保存当前 scopeId、generation、状态、切换原因和最后 bootstrap receipt。
- [ ] 在 EntryAbility 中先初始化 AccountKitService，再解析持久化登录态；无有效账号时跳过账号云 pull。
- [ ] 让 LoginPage.onLoginSuccess 和 HostListPage.triggerSystemLogin 都调用同一个 awaitable login transition。
- [ ] 在 transition 开始时停止 CloudSyncCoordinator、HostSyncService、KeyVaultService、VNC services 和 RustDesk Pro refresh；清旧 scope cache 和 session registry。
- [ ] 给所有读取 API 增加 scope 参数或 typed owner wrapper；禁止无参数 loadAllHosts/loadAllRdpCredentials/loadAllRelaysLocal/loadAllSshKeys/loadAllTotpEntries。
- [ ] 所有 insert/update/delete/merge/extension/journal/dirty/retry/conflict 记录都写 scopeId。
- [ ] 为 remotehosts、rdpcredentials、rustdeskrelays、sshkeys、totpentries、usersettings、cryptoparams、vncrecord 建立 owner invariant 检查；发现空 owner 或 owner 不匹配时 quarantine。
- [ ] A 登出后登录 B：B 只能看到 B 数据；A 的 session 不能上传；B 不能修改 A 的 dirty journal。
- [ ] 服务缓存按 scope generation 失效；旧 native callback 发现 generation 不一致时丢弃。

涉及文件：

- 新增 entry/src/main/ets/services/AccountScopeService.ets
- entry/src/main/ets/entryability/EntryAbility.ets
- entry/src/main/ets/services/AccountKitService.ets
- entry/src/main/ets/services/AuthService.ets
- entry/src/main/ets/pages/LoginPage.ets
- entry/src/main/ets/pages/HostListPage.ets
- entry/src/main/ets/services/CloudStore.ets
- entry/src/main/ets/services/HostSyncService.ets
- entry/src/main/ets/services/KeyVaultService.ets
- 所有 HostAddDraft、RdpAddFlow、RustDeskAddFlow、SshAddFlow、key/TOTP/relay/VNC 新增入口

测试：

- 单元：空 unionID、重复登录同账号、A -> B -> A、登录回调重入、退出时回调晚到。
- RDB：每类表混入 A/B/空 owner 行，所有读取和写入均不得越界。
- UI/集成：登录按钮、设置页系统登录、冷启动自动恢复、登出、切换账号、断网后切换。
- Native：old session generation 的帧、错误、断开事件不得触发新账号页面。

退出条件：

- [ ] 代码审查能证明所有业务表读取都带 scope。
- [ ] A/B 隔离测试通过，包含云上传前的 mutation journal。
- [ ] 未登录状态不产生账号云请求。
- [ ] 未完成 transition 时 UI 不显示旧账号数据。

发布阻断：

- 任意一个普通业务读取仍允许无 scope。
- rdpcredentials 或 cryptoparams 仍无法确定 owner。

### Phase 2：RDB 版本迁移和旧数据适配

依赖：Phase 1。

工作项：

- [ ] 新增 SchemaMigrationService 和 schema_version/migration_receipt 表；所有迁移按整数版本执行，记录开始、成功、失败和重试。
- [ ] 不再用“所有 ALTER TABLE 异常都忽略”作为唯一判断；迁移前通过表/列 introspection 判断已完成、部分完成和异常状态。
- [ ] 为 rdpcredentials 增加 userid，并补云端 username 字段；旧行只有在能通过现有账号上下文确定 owner 时迁移，否则进入 quarantine。
- [ ] 为 cryptoparams 增加 userid 或规范化 account:key 主键；旧全局 crypto 参数不能自动复制给新账号。
- [ ] 迁移 usersettings 的旧 key/value 和新 payload/schemaversion，明确哪些是账户设置、设备设置、登录状态、临时状态。
- [ ] 迁移 remotehosts 的 password -> passward，保留 legacy shadow 只读窗口；迁移完成后禁止再次生成 password。
- [ ] 迁移 relay：旧 cryptoparams key=rustdesk_relays JSON -> rustdeskrelays 行；按 id 去重，保留未知字段到 quarantine，不重复推送。
- [ ] 迁移旧 vncrecords -> vnclocalrecords/vncrecord，沿用 reset_epoch、recordtype、payload/ciphertext 语义；旧 epoch/无效 payload 不导入。
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

### Phase 3：CloudSyncCoordinator 生命周期升级

依赖：Phase 1、Phase 2、Phase 0 的测试云环境。

工作项：

- [ ] 将 coordinator 初始化拆成 account wait、RDB ready、distributed table ready、cloud service ready、bootstrap ready。
- [ ] requestStartupPull 必须带 scopeId、scope generation 和 operationId；scope 未 ready 时返回 account_required，而不是空成功。
- [ ] 给每个表 cloudSync 增加 watchdog：accept deadline、progress deadline、overall deadline；超时后调用取消/关闭路径并写 retryable receipt。
- [ ] 通过网络状态/foreground onActive/登录完成/手动刷新触发重试和 pull；重试不创建并行队列。
- [ ] 把当前内存 manualDownloadSnapshot 改为磁盘可恢复 snapshot；恢复完成才删除。
- [ ] 引入 per-table receipt 和跨表 apply journal；云端一张表成功不等于全量成功。
- [ ] 为 cloud-first 增加云服务可用性证明：账号、权限、schema、同步进度都确认后，才把空快照视为真实空。
- [ ] 对选中的表做 owner count、schema version、deleted/tombstone 和 payload hash 校验。
- [ ] 恢复失败时回滚本地业务表、extensions、localTables、metadata、mutation journal 和 selection；回滚失败进入 restore_pending，禁止自动上传。
- [ ] 本地新建/修改在 bootstrap 前继续延迟；bootstrap 后才释放自动上传。
- [ ] 统一 CloudStore、HostSyncService、VncCloudSyncService 的入口，禁止旧 CloudSyncService REST 路径双写业务表。

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
- 进程在每个阶段被杀，重启后读取 operation ledger。
- 空云、部分空云、只返回一张表、旧 schema 云行、云端冲突、重复回调。
- 同时触发 startup pull、手动 download、automatic push、crypto migration，必须串行且可判定。

退出条件：

- [ ] 任何操作都有终态：success、retryable、blocked、cancelled、rolled_back。
- [ ] 不再存在永久 pending 而无用户可见原因的路径。
- [ ] 失败期间没有自动上传覆盖云端。
- [ ] 双设备数据最终一致性、冲突和删除 tombstone 行为有设备日志证据。

### Phase 4：本地备份 v3、部分恢复和系统迁移

依赖：Phase 1、Phase 2、Phase 3。

工作项：

- [ ] 将 local backup 从 v2 升为 v3；manifest 必须包含 format、formatVersion、schemaVersion、sourceAppVersion、accountScope、createdAt、table inventory、column inventory、extensions、localTables、crypto descriptor、sha256/HMAC。
- [ ] 导出采用临时文件 + fsync/close + 原子 rename；任意一张表导出失败都返回错误，不生成“空行但看似成功”的备份。
- [ ] 默认不导出明文密码、私钥、TOTP secret、VNC secret；提供用户明确输入备份密码后的加密备份，或只导出脱敏配置。
- [ ] v1/v2/v3 adapter：缺少新版表时标记 absent，不当成 empty；缺少新版行字段用默认值；未知字段拒绝或隔离；未知表保留到 ignored inventory。
- [ ] 恢复分成 merge 和 replace 两种显式模式。merge 对 absent table no-op；replace 只清理用户明确勾选的表，绝不因旧备份缺表而清全库。
- [ ] 恢复前做 preview：账号、表、行数、字段损失、密钥/secret 状态、VNC trust 状态、冲突策略。
- [ ] 恢复期间进入 restore_pending，停止自动上传；导入完成、hash/owner/invariant 校验通过后再生成 restored_not_uploaded。
- [ ] 恢复后密码/私钥/TOTP/VNC secret 若无法解密，保留结构和 locked 状态，不填空字符串覆盖原值。
- [ ] 实现 EntryBackupAbility.onBackup/onRestore 的真实协议，或在实现完成前将 backup_config 的 allowToBackupRestore 设为 false 并在 UI 明确提示“请使用本地备份”。
- [ ] 对系统换机测试应用数据目录、RDB、Preferences、KeyVault 引用、登录态、云 selection 是否恢复；不能把系统自动复制 app 文件误报为业务数据恢复。

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
- [ ] sha256/HMAC、密码错误、文件截断、未知字段、owner mismatch 都被拒绝。
- [ ] 系统 BackupExtensionAbility 有真实双设备/换机证据；否则配置已安全关闭。

### Phase 5：加密生命周期 V2

依赖：Phase 1、Phase 2、Phase 3、Phase 4。

工作项：

- [ ] 将 crypto 状态改为 durable state：active、locked、enable_pending、migrating、disable_pending、reset_pending、blocked。
- [ ] setMasterPassword 必须防重入；先生成新 salt/verifier/key version，按记录迁移并写 receipt，最后提交 active。
- [ ] autoMigrate 按 table/record 记录 envelope version；进程中断后从 receipt 继续，不能依靠“是否加密”猜测整次操作是否完成。
- [ ] lock/后台/账号切换时清除 DEK、HostSync/KeyVault/RustDesk/VNC/TOTP 的明文缓存和待处理 secret buffer；已有连接按策略关闭或进入不可操作。
- [ ] disableEncryption：验证密码 -> durable disable_pending -> 每类敏感行解密/校验 -> 清除 salt/verifier/DEK -> 提交 disabled；中途失败停在 pending，不宣称已关闭。
- [ ] resetEncryption：按账号 scope 写 reset_pending，停止所有 session，生成本地恢复 checkpoint，清理该账号表和 tombstone，递增 VNC reset epoch，写 cloud receipt；其他账号不受影响。
- [ ] 远程 reset 到达时验证 account scope、reset epoch、operation id；旧设备收到后只清自己的对应 scope。
- [ ] 解锁失败/超次锁定不能永久阻塞 coordinator；UI 显示需要解锁、重试时间和恢复路径。
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
- [ ] 日志、Toast、backup preview、错误上报不含 secret、token、私钥或明文密码。

### Phase 6：协议数据域和官方源码对齐

依赖：Phase 1-5。各协议可以并行实现，但必须共用 AccountScope/CloudSync/Backup/Crypto 契约。

#### 6.1 RDP

- [ ] rdpcredentials 增加 userid 和云端 username；远端主机与 credential 引用必须同 scope。
- [ ] 保持 passward 为历史 canonical cloud contract，迁移 password shadow 后不再重新生成。
- [ ] RDP certificate fingerprint/trust 默认设备本地；云端可恢复提示信息但不能自动信任。
- [ ] RDP restricted-admin secret 必须绑定 host/credential/account，备份默认脱敏。
- [ ] 对照 FreeRDP upstream connection/settings/transport/update 行为，记录本地 OHOS patch queue，不把云数据模型耦合到 native settings。
- [ ] 升级 FreeRDP 前先跑现有 native 144 tests，再跑证书、AAD、网关、音视频、clipboard、输入和断开回归。

#### 6.2 RustDesk 和 Relay

- [ ] rustdeskrelays 所有行/账户/peer 都按 userid + relayId + accountId 绑定。
- [ ] 旧 cryptoparams relay JSON 迁移只执行一次；旧值有损或无法解析时进入 quarantine，不覆盖新行。
- [ ] API password、shared key、账户 password、Pro token 只存加密 envelope；云端/备份按用户 opt-in。
- [ ] 以 RustDesk d412d198 对照 remote page、client io_loop、server connection 的连接/断开/重连/输入/文件传输语义；当前仓内 FFI ABI 变更必须单独版本化。
- [ ] RustDesk 上游更新同步许可、NOTICE、SBOM、源码 commit 和 release manifest；禁止把 AGPL 依赖变成未记录的闭源产物。

#### 6.3 SSH/SFTP

- [ ] SSH key、passphrase、host key trust、proxy 和 terminal 状态全部 scope 化。
- [ ] 私钥云同步必须是加密密文；host-key trust 默认 device-local，新设备首次连接仍询问。
- [ ] SSH session 在账号切换、后台和 restore_pending 时可取消，旧 session generation 不得回调新页面。
- [ ] SSH tunnel 作为独立 transport capability，不复用 VNC password 或 RustDesk relay。

#### 6.4 TOTP

- [ ] TOTP entry 读取/写入/删除按 userid；secret 永不进入普通日志和明文备份。
- [ ] 跨设备恢复先恢复 metadata 和 locked state；只有 master password/用户明确确认后才解密使用。
- [ ] 切换账号必须清除 TOTP 明文 cache 和 timer。

#### 6.5 VNC

- [ ] 保持唯一云物理表 vncrecord，recordtype 分为 settings、host、gateway、secret、trust；本地完整 overlay 为 vnclocalrecords。
- [ ] secret 继续使用 context-bound v2 AES-GCM AAD；secret 默认不上传，只有 scope、选择器、crypto ready、用户确认同时满足时镜像。
- [ ] reset_epoch、deletedAt、payload hash、owner relationship 在迁移、备份、下载、冲突和恢复中都校验。
- [ ] 旧 vncrecords 只迁移到本地 overlay，不能在新机 bootstrap 时 native-first 发布。
- [ ] trust 记录恢复后仍需本机确认；gateway target、token、证书引用不得进入其他协议表。
- [ ] RFB 3.3/3.7/3.8、VNC password、Raw/CopyRect/DesktopSize、BGRA、键鼠/clipboard、UltraVNC mode12 继续走独立 native engine；mode2 只保持 server-side contract fixture。
- [ ] WebSocket、公网 relay、SSH tunnel/reverse listen 无服务端协议和实机证据时保持 gate disabled。

### Phase 7：可观测性、安全和运维

依赖：Phase 3-6。

工作项：

- [ ] 增加 redacted sync diagnostic：scope hash、operation id、table、phase、rows、latency、error code；禁止账号原值、地址密码、token、secret。
- [ ] 增加用户可读状态：尚未登录、等待云服务、同步中、部分成功、需要重试、需要解锁、恢复挂起、账号切换中、功能被云 schema 阻塞。
- [ ] 增加自检页：RDB schema、owner invariant、cloud table availability、last operation receipt、backup version、crypto state、VNC epoch。
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
| clean install、云服务不可用 | 本地可用但标记 cloud unavailable；不清空、不上传 | 把 unavailable 当空云或永久 pending |
| 云表不存在/字段不匹配 | 对应表 blocked，显示迁移指引 | 静默丢字段或写入未注册字段 |
| 首次启动时用户立刻新增主机 | 写入待 bootstrap journal，云 pull 后按规则处理 | 新机本地新增被云空快照覆盖或反向覆盖云 |

### 4.2 老用户升级

| 场景 | 预期 |
| --- | --- |
| 旧 app -> 新 app 正常更新 | versionCode 递增；RDB migration 在 UI 使用前完成 |
| 迁移中途杀进程 | 下次启动从 receipt 继续，原始行仍可恢复 |
| 旧 password/passward | canonical passward 保留，password shadow 不重新出现 |
| 旧 relay cryptoparams JSON | 迁移到独立 rustdeskrelays，幂等，不重复上传 |
| 旧 vncrecords | 本地 overlay 保留，epoch/owner/payload 校验通过后才可按用户选择上传 |
| 旧数据库缺 username/userid | 可识别为待确认，不把空字段覆盖到云端 |
| 新字段/新表 | 未知旧数据不丢；新表有明确 absent/empty 语义 |

### 4.3 老用户在新设备登录并拉云

1. 新设备启动时不得以旧设备缓存推断账号。
2. 用户登录 A，创建 A scope，清空 anonymous 视图。
3. 云 first pull 只导入 A；每表 owner count 与 payload hash 校验。
4. RDP username、relay accounts、SSH key metadata、TOTP locked state、VNC host/gateway/secret opt-in 均按契约出现。
5. 新设备不自动信任 RDP certificate、SSH host key、VNC trust。
6. pull 失败不显示半恢复数据；重试后成功或进入 restore_pending。

### 4.4 A/B 账号切换

- A 有主机、RDP credential、relay、SSH key、TOTP、VNC secret 和 active session。
- 登出 A 时所有服务停止/清 cache/journal。
- 登录 B 后只显示 B；B 的 mutation 不能写入 A 的 row 或 A 的 cloud dirty table。
- 切回 A 后 A 的数据仍完整；B 的数据不被清除。
- 在切换每一个阶段杀进程，重启后继续 switching 或回到安全的 blocked 状态。

### 4.5 云同步异常

- 云端空、部分空、只有旧表、只有新版表。
- 权限拒绝、网络超时、Progress 回调重复、accepted 但没有 finish。
- 下载中本地写入、上传中账号切换、上传中加密 reset、手动 download 与 automatic push 并发。
- 冲突、删除 tombstone、旧 reset epoch、同 ID 不同 owner。
- 预期：每次都有可查询 operation receipt；没有自动静默覆盖。

### 4.6 本地备份与恢复

- v1 七表 -> v3：导入所选表；缺少 vncrecord 不清空。
- v2 八表 -> v3：保留 extensions/localTables；缺字段默认，未知字段隔离。
- 缺 extensions/localTables、空表、截断文件、错误 hash、错误密码、未知 scope、重复 ID。
- merge 与 replace 都必须二次确认；replace 只影响显式选择的 scope/table。
- 导出任何一张表失败，不生成成功文件。
- 恢复中杀进程，重启后回滚或继续；恢复成功后 restored_not_uploaded，用户确认后才上传。

### 4.7 系统备份/换机

- 开启系统 backup 时验证 RDB、Preferences、BackupExtension data、KeyVault 引用、crypto state、cloud selection 的实际覆盖范围。
- 新设备 restore 后先进入 restore_pending，必须完成 schema/owner/crypto/cloud 校验。
- 系统只恢复了文件但没有业务表时，UI 必须明确报告“系统备份不包含业务数据”，不能显示成功。
- 如果 API 23 BackupExtension 无法安全导出所需数据，发布前关闭 allowToBackupRestore 并引导本地 v3 backup。

### 4.8 加密生命周期

- 首次启用、自动迁移、后台锁定、正确解锁、错误解锁、关闭加密、忘记密码 reset。
- 每个阶段杀进程、断网、另一个设备在线、另一个账号有数据、VNC secret sync 开关不同。
- 预期：操作可恢复、DEK/明文 cache 清理、reset epoch 单调、其他账号不受影响。

### 4.9 VNC 和协议数据域

- VNC 直连 RFB、Repeater mode12、旧 mode2 fixture、secret 默认不同步、用户 opt-in、VNC trust 二次确认、旧 vncrecords 恢复、offline overlay。
- RDP credential username/密码/证书 trust。
- RustDesk relay legacy JSON、Pro account/peer、密码/共享 key。
- SSH private key/passphrase/host trust。
- TOTP secret locked/unlocked。
- 任意协议 session 在后台、账号切换、restore、crypto reset 时均可取消，旧回调不能穿透 scope。

## 5. 测试分层与证据要求

### 5.1 纯策略/单元测试

新增或扩展：

- AccountScopePolicy.test.ets
- AccountTransitionPolicy.test.ets
- CloudOwnerFencePolicy.test.ets
- SchemaMigrationPolicy.test.ets
- CloudSyncOperationPolicy.test.ets
- BackupManifestV3.test.ets
- BackupRestoreMergePolicy.test.ets
- CryptoOperationPolicy.test.ets
- RdpCredentialCloudAdapter.test.ets
- RustDeskLegacyRelayMigration.test.ets
- VncRecordPolicy.test.ets

覆盖空值、重复、非法 owner、旧 schema、新 schema、未知列、epoch、hash、操作状态和重试退避。

### 5.2 RDB/集成测试

- 为每个旧版本建立 fixture；不使用只有当前 schema 的假数据。
- 检查 migration receipt、事务回滚、quarantine、row count、owner count、tombstone。
- 模拟进程被杀的每个 operation phase；模拟 callback duplicate/late.
- 检查本地 backup restore 后 extension、localTables、journal、metadata 和业务表的一致性。

### 5.3 设备测试

- API 23 两台设备、同一华为账号、同一网络/分布式权限。
- API 23 单设备 A/B 账号切换。
- 冷启动、后台、前台、锁屏、网络切换、设备重启。
- 记录真实设备型号、HarmonyOS 版本、应用 versionCode、cloud schema revision；不要记录账号、密码、地址和原始 secret。

### 5.4 真实云测试

- 测试表创建、字段权限、自动同步、离线保留、网络恢复、云端空值和 partial failure。
- 对每张表验证 owner filter 不能只依赖 UI；下载后在 RDB 层再次检查。
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
| P0 | A/B 账号数据泄漏、旧账号 dirty upload、登录前云 pull | 关闭新云同步入口；仅允许本地受限模式 |
| P0 | 系统备份开关为 true 但实现为空 | 实现前关闭 allowToBackupRestore，UI 引导本地备份 |
| P0 | rdpcredentials/cryptoparams 无可靠 owner | 禁止跨设备同步这两类表，或先完成云 schema |
| P1 | 旧备份整包拒绝、缺表被误解为清空 | backup v3 adapter 完成前只提供预览/导出，不自动 replace |
| P1 | cloudSync accepted 但未 finish，进程杀死后永久 pending | 使用 operation ledger/watchdog；超时进入 retryable/blocked |
| P1 | crypto disable/reset/autoMigrate 半完成 | 进入 durable pending，禁止宣称完成；保留 checkpoint |
| P1 | RDP username、relay JSON、旧 VNC 表迁移丢字段 | quarantine + 用户确认；不得写空值覆盖 |
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

- [ ] 所有业务读取/写入/同步/缓存/备份/恢复都绑定 AccountScope。
- [ ] 新机首次启动、老用户升级、新设备拉云、A/B 切换、云异常、备份恢复、系统换机、旧备份部分恢复均有通过记录。
- [ ] rdpcredentials username/userid、cryptoparams owner、relay legacy、VNC legacy 的迁移和云 schema 已真实验证。
- [ ] CloudSyncCoordinator 的每次操作都有 durable receipt、watchdog、明确失败语义和恢复路径。
- [ ] BackupExtensionAbility 要么真实恢复业务数据并通过换机验收，要么配置关闭且 UI 不再暗示系统备份可用。
- [ ] crypto 的 enable/lock/unlock/disable/reset 在断点、断网和账号切换下不泄露、不串号、不半完成。
- [ ] RDP/RustDesk/SSH/TOTP/VNC 各自的数据域没有跨协议污染；VNC 仍只有 vncrecord 一个云物理表。
- [ ] FreeRDP fork、RustDesk 对照 commit、RFB/UltraVNC 契约、许可证和 SBOM 已记录。
- [ ] API 23 ArkTS compile、assembleHap、native tests、git diff check、Light gate 和实际设备/云测试全部有证据。
- [ ] 最终报告区分 A/B/C/D 证据等级，并列出尚未验证的外部依赖；不存在“代码看起来支持所以算完成”的项目。

## 9. 建议的第一批实施顺序

下一轮不要直接改 UI 或新增云字段，建议按下列小闭环提交：

1. Phase 0：冻结 schema/fixture/云端测试表。
2. Phase 1-A：AccountScopeService + EntryAbility/登录/退出 transition。
3. Phase 1-B：CloudStore/HostSync/KeyVault/VNC 全量 owner fence。
4. Phase 2-A：rdpcredentials userid/username 和 cryptoparams owner migration。
5. Phase 2-B：旧 relay、password/passward、vncrecords、backup fixture migration。
6. Phase 3：operation ledger + watchdog + account-gated startup pull。
7. Phase 4：backup v3 和系统 BackupExtension。
8. Phase 5：crypto durable state。
9. Phase 6：协议域逐个打开 feature flag。
10. Phase 8：真实双设备和 staged release。

每一步都必须在主分支合并前通过项目规定的构建门禁；任何外部云/设备 blocker 都写进本文件对应阶段和最终发布报告，不能用“待后续”掩盖未完成的生命周期。
