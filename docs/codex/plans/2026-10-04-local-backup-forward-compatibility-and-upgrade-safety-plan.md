# 云同步与数据管理安全审计、本地备份前向兼容与升级安全计划（v2）

日期：2026-10-04（Asia/Shanghai）。状态：**PLAN-ONLY；用户已于 2026-10-04 确认 D1–D6（见第 7 节），计划可执行，等待开工指令。本文件更新不改应用代码、不构建、不装机。**

本版取代同文件的 v1（Codex 于 `f12e07241` 提交的“本地备份前向兼容与升级安全计划”）。v1 的目标与不变边界保留；v1 认定的根因经代码核对与复现后**更正**；范围扩大为整个云同步与数据管理子系统的安全审计（用户 2026-10-04 要求：排查安全策略过严、过松或逻辑不正确）。

## 0. 结论摘要

| 编号 | 级别 | 一句话 | 证据 |
|---|---|---|---|
| F1 | 高 | **完整备份必然失败**：删过任一 VNC 记录后，VNC 软删除行被完整导出原样带上，而完整模式校验拒绝 `deletedat>0` | 代码 + 宿主机复现 |
| F2 | 高 | **完整备份恢复会覆盖目标设备的加密参数**；目标若已用别的盐配置过主密码，其原有密文永久不可解，若再选“以本机为准上传”会波及云端 | 代码 |
| F3 | 中（D1 已决策：保留现行为） | 未设主密码时，勾选敏感表会把**未做端到端加密**的密码/SSH 私钥/TOTP/中继密码存入华为云空间；界面文案暗示“已加密保护”；函数注释与代码相反 → 只修文案与注释 | 代码 + 提交记录 |
| F4 | 中高（D2 已决策） | 脱敏备份携带并在恢复时**直接生效** SSH 主机公钥/RDP 证书信任，可被构造的备份预置信任；恢复预览却写“不含设备信任” | 代码 + 复现 |
| F5 | 中（D5 已决策：保留） | 脱敏备份**静默丢弃** LAN 三字段与 `rdprestrictedadminsecretsource`（两份白名单漂移），还计为“删除的敏感字段” | 复现 |
| F6 | 中 | 云扩展块和 `displayconfig` 按“当前已知键”重建：**新版本在其他设备写入的新键会被旧版本抹掉并回传** | 代码 |
| F7 | 中（D3 已决策：不设限制） | 主密码规则两套：设置页要求 12 位+大写开头+特殊字符；设置面板与 `DataCrypto` 要求 8 位；“32 位上限”从未执行 | 代码 |
| F8 | 中（需真机） | 冲突策略不一致：启动时先“本地优先”推送脏表再下载；回前台/云事件直接“云端优先”，并发修改时本地待上传改动可能被覆盖 | 代码 |
| F9 | 中 | 手动下载、重新启用同步表、恢复后“下载云端”等云端优先路径不做本地快照；校验失败时坏数据已落库，却提示“已回滚本次下载” | 代码 |
| F10 | 中 | v1 认定的根因（LAN 字段进入本地扩展 payload）**当前没有生产写入路径**；LAN 字段只写在 `displayconfig` 云扩展块，完整模式校验对其放行 | 代码 + 复现 + git 历史 |
| F11 | 中（D4 已决策） | “忘记主密码→重置”整行删除全部主机/凭据/密钥/2FA/中继/VNC，并整表清空 `localextensions`（含设备信任、个性化、凭据/中继/密钥关联），确认文案只写“所有加密数据” | 代码 |
| F19 | 高（实施中新发现） | **v1/v2 旧格式备份自 2026-07-31 起全部无法恢复**：校验末尾的三元表达式优先级错误，让旧格式也走 v3 脱敏规则并因缺少 manifest 抛错 | 代码 + 宿主机复现 + git 历史 |
| F12–F18 | 低/待验证 | 账号绑定的平台假设、规范云库被占用后的无交接、分身剪贴板全关、S1 未加密主库、云空间清空导致全设备清空、导出自检错误文案、`cryptoparams` 云端冲突 | 见第 2 节 |

已核实做得对的部分见 2.4，避免把健康机制当成问题改掉。

## 1. 审计范围、方法与限制

- 范围：`CloudStore`（1.6 万行，重点看导出/恢复/下载/加密/作用域路径）、`CloudSyncCoordinator`、`CloudSensitiveTransferPolicy`、`CloudSyncSelectionPolicy/Store`、`CloudLifecycleSafetyPolicy`、`AccountScopePolicy`、`AccountSessionCoordinator`、`PlatformCloudIdentity*`、`DataCrypto`、`CryptoLifecyclePolicy`、`LocalBackupPolicy/Service`、`BackupManifestV3`、`CloudTableAdapter`、`MoonlightBackupPolicy`、`VncRecordPolicy`、`AppCloneContext`、`RustDeskProCredentialStore`、`AccountCredentialStoragePolicy`、AI 数据工具入口，以及 `HostListPage`/`MasterPasswordSetupPage` 中的同步/备份/加密界面。
- 方法：
  1. 读决策点代码并与界面文案、注释、测试对照；
  2. 用 DevEco 自带 TypeScript 把真实 `LocalBackupPolicy`/`BackupManifestV3`/`CloudTableAdapter` 转译后在宿主机运行，构造快照复现导出→校验结果（脚本位于本次会话 scratchpad，S0 会转为仓库测试）；
  3. 查 git 历史确认字段/策略引入时的意图；
  4. 只读检查 3 台已连接设备（emulator、MLR-AL10、SGT-AL10）的 hilog 缓冲区：无备份失败记录（已滚动或失败发生在用户自己操作的手机）。
- 限制：平台云同步冲突语义、`cryptoparams` 云端冲突、云空间清空行为需要真机与真实华为云账号验证，本文标为“待验证”。启动恢复状态机未逐条审完，列为专项任务 S7。

### 1.1 宿主机复现结果（真实策略代码）

| 场景 | 脱敏 | 完整 |
|---|---|---|
| 基线（一台 SSH 主机） | 通过 | 通过 |
| LAN 键在本地扩展 payload（v1 假设的位置） | 通过 | **失败** `stage=extensions key=lanaddressmode` |
| LAN 键在 `displayconfig` 云扩展块（生产实际位置） | 通过 | 通过 |
| `vncrecordv2` 软删除行（删过 VNC 主机/网关/密钥） | 通过 | **失败** `stage=v3rows mode=full` |
| `vnclocalrecords` 软删除行 | 通过 | **失败** `stage=v3rows mode=full` |
| 云扩展块 LAN 键 + `rdprestrictedadminsecretsource` 在脱敏备份中 | 文档有效，但 4 个键被丢弃 | — |
| 本地扩展中的 SSH/RDP 信任字段在脱敏备份中 | 保留，manifest `deviceTrustIncluded:true` | — |

## 2. 审计发现

### 2.1 已确认缺陷（高）

**F1 完整备份必然失败（VNC 软删除）**
- 删除 VNC 主机/网关/密钥时写软删除行：`deletedAt=now`（[CloudStore.ets:14156](../../../entry/src/main/ets/services/CloudStore.ets)）；除“清空全部数据”外从不清理。
- 导出只排除平台云删除标记 `#_deleted_flag`，不排除应用层 `deletedat>0`（[CloudStore.ets:4356](../../../entry/src/main/ets/services/CloudStore.ets)）。
- 脱敏模式用 `vncRowIsPortable` 过滤软删除（[BackupManifestV3.ets:319](../../../entry/src/main/ets/services/BackupManifestV3.ets)）；完整模式 `fullPortableBackupData` 原样复制（[BackupManifestV3.ets:505](../../../entry/src/main/ets/services/BackupManifestV3.ets)）。
- 完整模式校验明确要求 `deletedat==0`（[LocalBackupPolicy.ets:921](../../../entry/src/main/ets/services/LocalBackupPolicy.ets)）。
- 现有测试只覆盖脱敏模式的软删除（[LocalBackupPolicy.test.ets:674](../../../entry/src/test/LocalBackupPolicy.test.ets)），所以缺陷未被发现。
- 结论：这是“导出端与校验端契约分裂”，与 v1 想解决的问题同类，但发生在**行级**，而且对真实用户必然触发。界面最终显示“备份文件格式或完整性校验失败”。

**F2 完整恢复覆盖目标设备加密参数**
- 完整备份在源已配置加密时携带 `cryptoparams`（盐、校验值、状态）。
- 恢复走 `mergePortableRows` 的字段级合并（[CloudStore.ets:4708](../../../entry/src/main/ets/services/CloudStore.ets)），对 `cryptoparams` 没有任何特殊处理；其行 ID 由账号+键名确定性派生，同账号恢复必然命中并覆盖目标行。`cryptoparams` 不属于带 `userid` 的表，也不走 owner 校验。
- 恢复计划、预览、确认界面、`mergePortableBackup`（[CloudStore.ets:5022](../../../entry/src/main/ets/services/CloudStore.ets)）提交前后都不比较“目标已配置的加密契约”。
- 每次 `setMasterPassword` 都生成新随机盐，所以“新手机单独设主密码后恢复旧手机完整备份”就会触发：目标原有密文在新盐派生的密钥下 GCM 认证失败，永久不可解；恢复后表处于“恢复未上传”隔离，若用户选“以本机为准覆盖云端”，错误参数会进入云端并影响所有设备。

### 2.2 安全策略问题（2026-10-04 已决策）

**F3 无主密码时敏感数据明文上云，且告知不足**
- `cloudTableRowsAreUploadSafe` 在未配置加密时直接放行敏感表（[CloudSensitiveTransferPolicy.ets:268](../../../entry/src/main/ets/services/CloudSensitiveTransferPolicy.ets)），由 `97859c82a`（2026-07-31）刻意引入：“是否加密由用户明确选择”。
- 但同函数上方注释仍写“即使空的敏感表在加密关闭时也保持阻断”（[CloudSensitiveTransferPolicy.ets:242](../../../entry/src/main/ets/services/CloudSensitiveTransferPolicy.ets)），与代码相反。
- 同步管理界面对敏感表的说明是“包含敏感数据，启用时自动同步加密参数”“加密参数会随敏感数据自动保护”（[HostListPage.ets:19874](../../../entry/src/main/ets/pages/HostListPage.ets)、[19923](../../../entry/src/main/ets/pages/HostListPage.ets)），会让未设主密码的用户误以为已端到端加密。
- 默认只自动同步 Moonlight（[CloudSyncSelectionPolicy.ets](../../../entry/src/main/ets/services/CloudSyncSelectionPolicy.ets)），敏感表需用户手动勾选；设置主密码后各行会记入变更日志，下次同步用密文替换云端旧明文（已核实）。
- **D1 决策**：允许无主密码同步敏感表（依赖华为云空间自身的存储加密与账号保护），不加拦截、不加同意弹窗。落地只做“如实告知”：
  - 注释改为与代码一致（未配置加密时放行，由用户选择是否端到端加密）；
  - 同步管理里敏感表的说明按加密状态区分：未设主密码时写“由华为云空间存储加密与华为账号保护，未做端到端加密；设置主密码后改为端到端加密”，已设主密码时才写“已端到端加密，自动同步加密参数”；
  - 敏感表行内加一个小状态标签“端到端加密 / 云空间加密”。
  - 说明：云空间存储加密的密钥由服务方管理，不等于端到端加密；这是用户已知并接受的取舍，文案不得暗示端到端。

**F4 设备信任从脱敏备份导入并立即生效**
- 脱敏模式保留 `REMOTE_HOST_EXTENSION_TRUST`（SSH 主机公钥、RDP/网关证书指纹与信任模式），manifest 标 `deviceTrustIncluded:true`；恢复时合并进本地扩展，直接成为“已信任”。
- 恢复预览却写“该备份为脱敏配置，不含……设备信任（SSH 公钥/RDP 证书）”（[HostListPage.ets:5377](../../../entry/src/main/ets/pages/HostListPage.ets)）。
- 外层 SHA-256 不是带密钥的签名，任何人都能构造一个合法备份预置攻击者的证书指纹/主机公钥，实现首连免告警的中间人。
- 补充：`BackupManifestV3.ets:130` 的注释把“所有模式都保留信任”写成了有意设计（理由是公钥/证书不是秘密），但它忽略了恢复时信任会**直接生效**这一点。
- **D2 决策**：脱敏备份不带设备信任；完整备份恢复的 SSH/RDP 信任降级为“待确认”，首次连接时重新确认（与 VNC 现有候选语义一致）。落地要点见 S3-D2。

**F7 主密码规则不一致**
- `DataCrypto.setMasterPassword` 实际只要求 ≥8 位（[DataCrypto.ets:211](../../../entry/src/main/ets/services/DataCrypto.ets)）；设置面板只要 8 位即可提交（[HostListPage.ets:20361](../../../entry/src/main/ets/pages/HostListPage.ets)）；独立设置页要求 ≥12、首字母大写、含特殊字符（[MasterPasswordSetupPage.ets:220](../../../entry/src/main/ets/pages/MasterPasswordSetupPage.ets)）；两处占位提示“12-32 位”，上限从未执行。
- 主密码的校验值随 `cryptoparams` 上云，可被离线暴力尝试（每次尝试需 PBKDF2 60 万次，但很短的密码仍可被穷举）。
- **D3 决策**：主密码不设长度与复杂度限制。落地：一个共享的 `masterPasswordAcceptable()`，只要求非空、两次输入一致；去掉 `DataCrypto` 的 8 位检查、设置页的 12 位/大写开头/特殊字符检查、设置面板的 8 位按钮门槛、“12-32 位”占位提示；不截断、不 trim。设置界面保留一行非阻断说明“主密码忘记后无法找回”（现有文案若已有则不新增）。已有密码的解锁路径不变。

**F11 重置加密的破坏范围**
- 重置（`resetCryptoV3Exclusive`，[CloudStore.ets:11404](../../../entry/src/main/ets/services/CloudStore.ets)）调用 `clearAllTablesInActiveTransaction`（[CloudStore.ets:10751](../../../entry/src/main/ets/services/CloudStore.ets)）：整行删除当前账号的主机、RDP 凭据、SSH 密钥、TOTP、中继、VNC，包括地址、端口、用户名等非敏感配置；**整表**删除 `localextensions`（设备信任、本机个性化、凭据/中继/密钥关联都在里面）和本地变更日志；清空中继控制面配置；为每张表记一条 `clear` 变更。确认文案只写“所有加密数据将被永久删除”（[HostListPage.ets:20323](../../../entry/src/main/ets/pages/HostListPage.ets)）。
- 代码注释说明它“刻意不是远程擦除协议”，并在重置时暂停敏感表同步；但之后重新启用敏感同步时，这些删除/`clear` 意图如何与云端交互，需要在实施时核实（见 S3-D4 第 4 条）。
- **D4 决策**：只清空加密字段，保留主机地址等普通配置。落地要点见 S3-D4。

### 2.3 中低风险与待验证

**F5 脱敏备份丢弃可跨设备配置**：`displayconfig` 云扩展块的键由 `REMOTE_HOST_CLOUD_EXTENSION_COLUMNS` 决定（[CloudTableAdapter.ets:88](../../../entry/src/main/ets/services/CloudTableAdapter.ets)），脱敏保留清单是 `BackupManifestV3` 里另一份 `REMOTE_HOST_EXTENSION_SAFE`（[BackupManifestV3.ets:157](../../../entry/src/main/ets/services/BackupManifestV3.ets)）。两份已漂移：`lanaddressmode`、`landiscoveryidentity`、`lanlastresolvedat`、`rdprestrictedadminsecretsource` 在云同步里是跨设备配置，在脱敏备份里却被删掉并计入 `removedSecretFields`。后果：脱敏恢复后静态 LAN 主机失去绑定与发现身份，受限管理员 RDP 主机丢失密钥来源设置。**D5 决策：保留**。四者都按非敏感配置保留；NTLM hash 本身仍是设备本地密钥，不进任何备份。
- 实施细化（2026-10-04）：每台主机保存时都会写入这四个键（多为默认值），而已发布版本的脱敏校验会把它们删掉再比较，所以只要新版备份里出现这些键，旧版就会拒绝导入。因此只保留**非默认值**（`lanaddressmode=static`、非空发现身份、非 0 解析时间）；默认值不写入，没有 LAN 绑定的主机生成的脱敏备份与旧版完全一致。`rdprestrictedadminsecretsource` 当前唯一取值就是默认的 `ntlm_hash`（只是选择器，不是 hash），按同一规则不写入、不再计为“删除的敏感字段”。代价：含 LAN 绑定主机的新版脱敏备份，旧版应用会在写入前安全拒绝。

**F6 跨版本抹除未知键**：`decodeRemoteHostDisplayPayload` 只保留当前已知键（[CloudTableAdapter.ets:225](../../../entry/src/main/ets/services/CloudTableAdapter.ets)），保存主机时按已知键重建云扩展块（[CloudStore.ets:9236](../../../entry/src/main/ets/services/CloudStore.ets)）与 `displayconfig` 顶层；本地扩展 `saveHostExtension`（[CloudStore.ets:9273](../../../entry/src/main/ets/services/CloudStore.ets)）也用 `ON_CONFLICT_REPLACE` 重写。多设备混用新旧版本时，新版本写入的新键会被旧版本保存一次就抹掉，并经云同步传回。修复：保存时保留现有行中未知的字符串键（有数量/大小上限，不解释、不参与业务）。这是 v1 第 6.2 条在**云路径**上的真实落点。

**F8 冲突策略不一致（待真机）**：已有本地修改的设备启动时先对脏表做“本地优先”推送再“云端优先”下载（[CloudSyncCoordinator.ets:870](../../../entry/src/main/ets/services/CloudSyncCoordinator.ets)）；回前台与云事件直接“云端优先”（[CloudSyncCoordinator.ets:1110](../../../entry/src/main/ets/services/CloudSyncCoordinator.ets)）。按平台语义，云端优先在双方都修改同一行时以云端为准，自动推送失败后仍待上传的本地修改可能被覆盖。需真机确认平台语义后统一：回前台前先推送脏表，或冲突时保留双方并提示。

**F9 下载校验失败后的“回滚”不一致**：只有启动/回前台/云事件三种自动下载在开始前给本地做快照（[CloudStore.ets:5861](../../../entry/src/main/ets/services/CloudStore.ets)）；其他云端优先路径在校验失败时直接返回（[CloudStore.ets:6167](../../../entry/src/main/ets/services/CloudStore.ets)），平台已写入本地的数据不会恢复，但失败文案统一写“已回滚本次下载”。修复：所有云端优先路径统一快照+恢复，或改为如实提示。另：整表校验（`whole_snapshot`）下，一条旧版明文行会让所有设备整表下载失败，建议参考 Moonlight 的逐行隔离。

**F10 v1 根因更正**：LAN 三字段自 `2c1132385`（2026-08-22）起只写在 `hostCloudExtensionValues`→`displayconfig` 云扩展块；`saveHostExtension`、迁移、设备信任迁移、恢复合并都不会把它们写进 `localextensions` 的主机 payload；完整模式校验对 `displayconfig` 内部不做白名单检查。v1 的“最小受控样本”是人为构造的位置。该位置仍是潜在风险（未来字段、旧备份恢复），保留为前向兼容加固项，但**不是**当前完整备份失败的原因（F1 才是）。

**F12 账号绑定的平台假设（低）**：平台身份证明只证明“系统分布式账号已登录”，`proveCurrentCloudAccount` 收到的 App UnionID 未使用（[PlatformCloudIdentityService.ets:38](../../../entry/src/main/ets/services/PlatformCloudIdentityService.ets)），代码注释承认 API23 无法证明两者是同一人（[PlatformCloudIdentityPolicy.ets:113](../../../entry/src/main/ets/services/PlatformCloudIdentityPolicy.ets)）。现有的存储平台指纹校验在系统账号切换后会阻断，加上 Account Kit 通常就用系统账号登录，实际风险较低。建议：在计划/文档中显式记录该平台假设；首次云绑定时提示“云数据存入当前系统华为账号的云空间”。

**F13 规范云库被占用后无交接（低，过严）**：同一系统用户下若规范云库 `remotedesktop.db` 已归另一账号，新账号永久退到本地哈希库、不能云同步（[CloudStore.ets:1390](../../../entry/src/main/ets/services/CloudStore.ets)）。当旧 owner 记录的平台指纹已与当前系统账号不符时，可提供显式的“把旧数据迁到其本地库并接管云库”流程。

**F14 分身剪贴板全关**：分身同时关闭两个方向的剪贴板桥接（[AppCloneContext.ets:69](../../../entry/src/main/ets/services/AppCloneContext.ets)，唯一调用点 [RemoteDesktop.ets:4832](../../../entry/src/main/ets/pages/RemoteDesktop.ets)），理由是系统剪贴板全机共享，但主应用同样使用全机剪贴板，分身里远程会话复制粘贴完全不可用。**D6 决策：默认关闭，允许用户在分身中手动开启**，落地见 S3-D6。

**F15 主库存储取舍（低）**：主 RDB 为 S1、未开 RDB 加密；未设主密码时凭据仅受系统文件级加密保护。记录为已知取舍；提高等级需评估对云同步与已安装数据的兼容影响。

**F16 云空间清空的连锁影响（待真机）**：账号绑定正常时“确为空快照”的证明恒成立（[CloudStore.ets:6117](../../../entry/src/main/ets/services/CloudStore.ets)），自动云端优先会接受空表。若用户在华为云空间里清空本应用数据，下一次同步可能把所有设备的本地主机清空。需真机验证；建议区分“云端被重置”（本地行此前已同步、云端整体消失）与“用户在其他设备删除”，前者先询问。

**F17 导出自检的错误归因（低）**：导出后的自检失败与“用户选的文件损坏”共用 `invalid_backup` 和“备份文件格式或完整性校验失败”（[LocalBackupService.ets:58](../../../entry/src/main/ets/services/LocalBackupService.ets)），把应用自身缺陷说成文件问题，也不带阶段信息。修复：区分 `export_self_check_failed(stage)` 与 `invalid_backup(reason)`，并记录脱敏诊断事件。

**F19 v1/v2 旧格式备份无法恢复（实施中新发现，已在 S1 修复）**：`validateLocalBackupDocument` 末尾写成 `version >= 3 && mode === 'full' ? !full : !redacted`，v1/v2 文件条件为假，进入 `validateRedactedV3Rows`，随后读取不存在的 `manifest.accountScope` 抛错（或因密钥字段被脱敏比较拒绝），统一返回“格式或完整性校验失败”。由 `651683042`（2026-07-31，引入完整模式）带入；`LocalBackupPolicy.test.ets` 中 4 个旧格式用例一直失败但未被执行（ohosTest 编译本身另有历史错误）。修复为只对 v3 执行按模式的行校验；宿主机脚本现在实际运行这些用例。

**F18 `cryptoparams` 云端冲突（待真机）**：同一账号下两台各自设过主密码的设备，在开启敏感同步时会共用同一组 `cryptoparams` 行 ID；未找到内容冲突检测。若云端优先下载覆盖本机参数，后果与 F2 相同。需真机验证；与 F2 共用“加密契约比较”机制修复。

### 2.4 已核实做得对的部分（不要改坏）

- PBKDF2-SHA256 60 万次 + AES-256-GCM；新格式把账号/表/记录/字段绑进 AAD；旧格式仅兼容读取。
- 主密码已配置但本次未解锁时，敏感写入一律 `unlock_required`，不会落明文；读取时锁定的密文显示为空，不会把密文当明文。
- 启用加密时每条被加密的行都记入变更日志，下次同步用密文替换云端旧明文。
- RustDesk Pro 令牌、账号凭据存系统 Asset Store，`THIS_DEVICE` + `DEVICE_FIRST_UNLOCKED`。
- 分身只保存本机、不登录账号、不云同步；实例状态读不到时 fail-closed。
- AI 数据工具的编辑/删除都经界面确认，给 AI 的主机摘要不含地址、用户名、密钥。
- 备份导出/恢复都校验 owner、store identity、generation、lease；恢复是字段级合并、缺表/缺列不删除本机数据，本地扩展 payload 合并保留已有未知键。
- 恢复确认文案对 v1/v2 旧备份会写明“确认后绑定当前本地数据作用域”。
- Moonlight 导出与校验复用同一过滤函数，两端天然一致（F1 的修复应采用同样模式）。
- 敏感表默认不同步，需用户勾选；关闭/重置加密会自动暂停敏感同步，防止明文覆盖或远程清空。

## 3. 对 v1 计划的修订

1. **根因**：从“LAN 字段被扩展白名单拒绝”改为“VNC 软删除行级契约分裂（F1）”；LAN 场景降为前向兼容加固。
2. **v4 + opaque 区段 + `backupopaque` 新表：降级为条件性远期项**。理由：
   - 扩展字段本来就以 `payload` JSON 字符串原样进出备份，恢复合并会保留已有未知键，前向兼容只需让完整模式校验接受“未知但为字符串”的 payload 键、脱敏模式继续按白名单删除；
   - 当前版本导出只选已知列（`exportTableRows` 用 `localBackupColumnsForTable`），不会产生未知行列；
   - 新增本地表意味着 RDB 迁移、恢复路径和云边界的新风险，与收益不相称。
   - 只有将来某版本确实需要跨版本保留“行级新列”时，才重新启用 v1 第 3.1 节设计。
3. **“旧版本遇到 v4 返回需要升级”**：已发布版本无法修改。它们遇到未知版本或未知键，会在写入前统一报“格式或完整性校验失败”（安全但文案泛化）。只有本计划之后的版本才能给出明确的“需要升级”提示。
4. **单一 registry 范围扩大**：不只覆盖本地扩展 payload，还要覆盖：行级契约（软删除、owner）、`CloudTableAdapter` 云扩展列、`BackupManifestV3` 的 `SECRET_COLUMNS/SAFE/TRUST`、`LocalBackupPolicy` 列/payload 白名单、`CloudSensitiveTransferPolicy.SENSITIVE_COLUMNS`、`RemoteHostDeviceTrustPolicy.DEVICE_LOCAL_TRUST_KEYS`。F1、F5 都是这些清单之间漂移造成的；另一处已发现的漂移：`remotehosts` 的密钥列在 `SECRET_COLUMNS` 中是 `password/passward/sshkeydata/sshkeypassphrase`，在 `SENSITIVE_COLUMNS` 中只有 `passward/sshkeydata`（实施时确认 `password`、`sshkeypassphrase` 是否仍有写入，再统一）。D4 的“只清空加密字段”也必须以 registry 的 secret 分类为唯一来源。
5. **v1 第 6.2 条（读改写保留未知字段）**：落点从“本地扩展”扩展到“云扩展块与 `displayconfig`”（F6），后者才是多设备混用版本时真实发生数据丢失的路径。
6. 新增加密契约保护（F2/F18）、敏感数据告知（F3）、信任导入降级（F4）、同步一致性（F8/F9/F16）、fail-closed 可退出性审计（S7）。

## 4. Registry 契约（保留 v1 第 3–5 节的分类思想，修订如下）

- 位置：`entry/src/main/ets/services/PortableDataSchemaRegistry.ets`（实施时可调整名称）。
- 每个字段分类：`secret`、`safe`（可跨设备配置）、`trust`（设备信任，恢复时为候选）、`device_local`（不导出）、`opaque_forward`（未知，完整模式原样保留、脱敏删除）。
- 每张表的行级规则：owner 列、软删除列与“导出是否包含软删除”、整数列、不可迁移列。
- 消费方：导出（完整/脱敏）、导出自检、导入校验、恢复合并、云扩展投影、敏感上传检查。各模块旧清单改为从 registry 派生，**不得**再各自维护。
- 闭包测试：扫描生产者（`hostExtensionValues`、`hostCloudExtensionValues`、`remoteHostLocalPersonalizationValues`、各 `saveLocalExtension` 调用、行写入桶）的键集合，与 registry 求差集；新增字段未分类时测试失败。
- 校验分层（沿用 v1 第 5 节）：外层结构/哈希 → 行与身份 → 敏感策略 → 业务适配；未知 key 本身不再是安全错误，错误落在类型、身份、owner、认证、哈希上。
- 结果报告：`valid`、`valid_with_opaque`、`unsupported_version`、`invalid`、`quarantined`，携带 `reasonCode`、`stage`、`table`、计数；界面和诊断按原因给出不同文案（F17）。

## 5. 执行分期（准备执行）

实施遵守 AGENTS.md：当前活动分支 `codex/pro-purchase-foundation`（Codex 正在其上进行 AI 相关的并发未提交改动，实施时只暂存本任务文件）；每期独立 checkpoint、双 Hvigor 门禁、Light/diff、独立复核后提交。

### S0 取证与先写失败用例（不改行为）
1. 请用户在出问题的手机上点一次“完整备份”，同时抓 hilog（`LocalBackupPolicy validate stage=…`、`extension invalid payload key=…`），确认 F1 是不是用户遇到的那次失败；没有设备就以本计划的复现结果为准。
2. 把本次宿主机复现转为仓库测试（`entry/src/test/LocalBackupPolicy.test.ets` 新增完整模式用例 + `scripts/tests/` 宿主机脚本），覆盖 1.1 节全部场景；F1、F5 的用例先以失败状态提交到用例清单。
3. 冻结 v1/v2/v3 备份、加密开启/关闭/锁定、device-local 与华为账号作用域的去敏样本。

### S1 立即修复（低风险，可单独交付）
1. F1：完整导出与脱敏一致地排除 VNC 软删除行（`vncrecordv2`、`vnclocalrecords`），或让完整模式校验复用导出投影；补完整模式软删除用例。
1a. F19：修复旧格式校验的优先级错误；新增宿主机脚本 `scripts/tests/test_data_management_safety.cjs`，直接运行 `LocalBackupPolicy`、`CloudSyncSheetPolicy`、`MasterPasswordPolicy`、`AppCloneContext` 的 hypium 用例。
2. F17：区分导出自检失败与导入文件无效，错误码带阶段；记录脱敏诊断事件。
3. F3（D1）：注释与同步管理文案改为如实描述，敏感表加“端到端加密 / 云空间加密”状态标签；上传行为不变。
4. F5（D5）：四个键按“非默认值才保留”加入脱敏保留集合（见 F5 实施细化），并加跨清单一致性测试（云扩展每个键都必须被脱敏保留或按默认值省略）。

### S2 加密契约保护（高优先级）
1. F2：恢复前比较备份与目标的加密契约（KDF 版本/迭代、盐、校验值、`crypto_status`）。
   - 目标未配置加密：可导入（与现状一致），恢复后要求输入备份主密码解锁；
   - 目标已配置且契约一致：正常合并；
   - 目标已配置且不一致：拒绝合并 `cryptoparams` 与密文字段，只导入非敏感配置并明确提示；后续可选“输入备份主密码→用目标密钥重新加密导入”。
2. F18：真机验证两台独立配置主密码设备开启敏感同步的行为；若会覆盖，下载前比较契约，不一致时暂停敏感同步并提示二选一。

### S3 产品决策项落地（D1 已并入 S1；D5 已并入 S1）
四项互相独立，各自一个 checkpoint，顺序为 D3 → D6 → D2 → D4（由易到难；D4 依赖 S2 的加密契约比较）。

**S3-D3 主密码不设限制（F7）**
1. 新增共享 `masterPasswordAcceptable(password, confirm)`：非空且两次一致即通过。
2. 替换三处检查：`DataCrypto.setMasterPassword` 的 8 位检查（[DataCrypto.ets:212](../../../entry/src/main/ets/services/DataCrypto.ets)）、`MasterPasswordSetupPage.canSubmit/doSetup` 的 12 位/大写开头/特殊字符（[MasterPasswordSetupPage.ets:190](../../../entry/src/main/ets/pages/MasterPasswordSetupPage.ets)、[220](../../../entry/src/main/ets/pages/MasterPasswordSetupPage.ets)）、设置面板按钮的 8 位门槛（[HostListPage.ets:20361](../../../entry/src/main/ets/pages/HostListPage.ets)）。
3. 两处占位提示“12-32 位, 大写开头, 含特殊字符”改为“输入主密码”。
4. 验收：1 位密码可设置并可解锁；空密码、两次不一致被拒；已有 8–12 位密码解锁不受影响。

**S3-D6 分身剪贴板手动开启（F14）**
1. `appCloneClipboardBridgeAllowed(policy, cloneOptIn)`：主应用恒为允许；分身只在 `cloneOptIn` 为真时允许。开关是分身自己沙箱内的本机偏好，默认关闭，不进备份、不云同步。
2. 开关只在分身中显示（放在分身的本机数据/设置区），说明文案：“系统剪贴板在主应用和分身之间共享。开启后，分身中的远程会话会读写这个共享剪贴板。”
3. 开启后仍服从各协议自己的剪贴板开关（RDP/RustDesk 全局开关、VNC 主机开关）；`RemoteDesktop.clipboardBridgeEnabledForSession` 的唯一入口改为读取新函数。
4. 验收：分身默认无剪贴板桥接；开启后双向可用；关闭后立即停止；主应用行为不变。

**S3-D2 设备信任：脱敏不带、完整恢复降级（F4）**
1. 脱敏导出：删除 `REMOTE_HOST_EXTENSION_TRUST` 全部键，计入 `removedDeviceTrustFields`，manifest `deviceTrustIncluded=false`；更新 `BackupManifestV3.ets:130` 注释。
2. 脱敏导入：已发布版本生成的脱敏备份**确实含有**信任字段，所以不能拒收；校验通过后剥离信任键并在预览中显示“备份中的设备信任已忽略”。这同时防御构造的备份。
3. 完整恢复降级（纯函数，便于测试），作用于 SSH 主机、SSH 跳板主机、RDP 证书、RDP 网关证书四组字段：
   - `*trustmode` → 0（SSH 未信任 / `RDP_CERTIFICATE_UNKNOWN_TRUST_MODE`）；
   - `*trustedat` → 0；
   - `rdp*allowuntrustedroot`、`rdp*allowhostmismatch` → false（例外放行也是信任决定）；
   - 指纹、公钥、证书主题、路由身份保留作参考。
   VNC 已有候选语义，保持不变。v1/v2 旧备份同样经过降级。
4. 不降级本机已有的信任：目标主机在本机已有非 0 信任模式时，保留本机信任字段，忽略备份中的信任。
5. 首次连接：信任模式为 0 时走现有首次确认流程。实施时逐一核实四组流程不会把“已有指纹 + 模式 0”误报成“主机密钥已变更”告警（SSH 依据 [SshHostKeyTrustPolicy.ets:119](../../../entry/src/main/ets/services/SshHostKeyTrustPolicy.ets) 只认模式 1，跳板主机变更检测见 [HostListPage.ets:10397](../../../entry/src/main/ets/pages/HostListPage.ets)）。可选增强：确认框提示“与备份记录的指纹一致/不一致”。
6. 恢复预览文案：完整备份“包含设备信任记录，恢复后首次连接需重新确认”；脱敏备份“不含设备信任”。
7. 设备信任本来就不走云同步（`RemoteHostDeviceTrustPolicy` 只投影本机信任），本项不涉及云端。

**S3-D4 重置只清空加密字段（F11）**
1. 以 registry 的 secret 分类为准逐表处理（registry 未落地前以 `SECRET_COLUMNS` ∪ `SENSITIVE_COLUMNS` 为准）：
   - `remotehosts`：清空 `password/passward/sshkeydata/sshkeypassphrase`，`passwordConfigured=false`，地址、端口、用户名、协议设置保留；
   - `rdpcredentials`：清空 `password`，名称/用户名/域保留；
   - `rustdeskrelays`：清空 `apipassword/key` 以及 `accountsjson` 内的密钥字段（只保留账号名等非密钥项；做不到逐项则整列清空）；中继控制面令牌继续清除（它们是密钥）；
   - `sshkeys`：清空 `privatekey`，名称、公钥、指纹保留，界面标记“需重新导入私钥”，主机对密钥的引用保持有效；
   - `totpentries`：清空 `secret`，发行方/账号名保留，界面标记“需重新绑定”；
   - VNC：只对 `recordType==='secret'` 的记录写软删除（现有格式：密文为空），主机/网关/设置/信任记录保留；
   - `localextensions`：不再整表删除（其中的关联、个性化、设备信任都不是密文）；
   - 本地变更日志：不再整表删除，改为对被修改的行记 `update`。
2. 事务、生命周期状态（`reset_pending → reset_committed`）、`crypto_status=disabled`、VNC reset epoch 的写法保持不变，只替换“删什么”。
3. 界面适配：密码为空的主机连接时按“未保存密码”提示输入；空私钥的 SSH 密钥、空 secret 的 TOTP 显示需重新导入/绑定，不能崩溃或当作有效密钥使用。
4. 云端语义（保持“不是远程擦除”）：重置仍暂停敏感表同步。实施前先核实现有重新启用路径对 `clear`/删除意图的处理；新行为下，重新启用敏感同步时**不得**用本机的空字段静默覆盖云端仍可被其他设备解密的密文，必须让用户选择“以云端为准（输入原主密码后可用）”或“以本机为准（云端旧密文一并清空）”。这一步复用 S2 的加密契约比较（重置后若设了新主密码，本机与云端的契约必然不一致）。
5. 确认文案列出会清空的内容（各类密码、SSH 私钥、2FA 密钥、中继密钥、VNC 密码/令牌）和会保留的内容（主机地址、端口、用户名、分组与显示设置、设备信任）。
6. 验收：重置后主机列表与设置完整保留、所有密钥字段为空、无任何密文残留；未重新启用同步前云端不变；重新启用时出现二选一且两种选择结果正确。

### S4 Registry 与前向兼容
1. 引入 registry，替换五处清单（见第 3 节第 4 条），加生产者闭包测试。
2. 完整模式校验接受未知字符串 payload 键并计数；脱敏模式默认删除未分类键。
3. F6：`saveHostExtension`、云扩展块投影与 `displayconfig` 写回改为读改写，保留未知字符串键（数量/大小上限；不参与连接、认证、信任或上传判断，只是不抹除）。
4. 版本策略：继续生成 v3；不新增 `backupopaque` 表（见第 3 节第 2 条）。

### S5 同步一致性（先真机验证再改）
F8（回前台前先推送脏表，或统一冲突策略并提示）、F9（所有云端优先路径统一快照+恢复；整表校验改为逐行隔离）、F16（区分云端重置与用户删除）。

### S6 账号与云库
F12（记录平台假设、首次绑定提示）、F13（显式云库交接流程）。

### S7 fail-closed 状态可退出性审计
逐个列出持久化阻断标记（恢复隔离、同步范围重新启用屏障、系统回调超时隔离、加密生命周期事务、持久化降级本地模式、前向兼容 schema 本地模式、恢复必需标记等），逐个确认：有用户可见说明、有退出路径、有测试覆盖；不满足的补齐。

### S8 设备与升级验收
沿用 v1 第 8 节 P4：旧版 → 当前版保留数据升级；Phone/Pad/PC 与分身组合的完整/脱敏导出导入、重启、账号切换；两台设备的云同步冲突、加密契约冲突与云空间清空场景。

## 6. 验证用例（在 v1 第 9 节基础上增补）

1. 删过 VNC 主机/网关/密钥后，完整备份导出→自检→选择文件校验全部通过；软删除不进入完整备份。
2. 目标已用不同盐配置加密时，完整恢复不覆盖 `cryptoparams`、不导入密文字段，原有密文仍可用旧主密码解开；契约一致时正常合并。
3. 脱敏备份保留 LAN 三字段与 `rdprestrictedadminsecretsource`，`removedSecretFields` 不再计入它们；脱敏恢复后静态 LAN 主机绑定不变。
4. D2：新导出的脱敏备份不含设备信任、manifest `deviceTrustIncluded=false`；旧版脱敏备份（含信任字段）仍能导入，但信任被剥离且预览提示；构造的“脱敏备份 + 攻击者指纹”恢复后不产生任何已信任记录；完整恢复的四组信任模式均为 0、例外放行为 false、指纹保留；本机已有信任不被降级；四组首次连接都弹首次确认而不是“密钥已变更”告警。
5. 云扩展块/`displayconfig`/本地扩展中的未知字符串键在旧版本保存主机后仍保留，不进入业务判断。
6. 生产者键集合与 registry 闭包检查通过；六处旧清单不再独立存在。
7. D3：三处入口共用 `masterPasswordAcceptable`；1 位密码可设置并解锁；空密码与两次不一致被拒；已有密码解锁不受影响；界面不再出现“12-32 位/大写开头/特殊字符”。
8. D1：同步管理中敏感表的文案按加密状态区分，未设主密码时不出现“自动保护/加密”字样，状态标签正确；上传行为与现状一致。
9. 每条云端优先路径在校验失败时都恢复下载前数据，或如实提示未回滚。
10. 导出自检失败的文案与导入文件损坏的文案不同，并带阶段。
11. D4：重置后各表行与非密钥列保留、所有 secret 列为空、无密文残留；VNC 只有 secret 记录被软删除；`localextensions` 中的关联、个性化与设备信任保留；空密码主机/空私钥/空 TOTP 的界面行为正确；重新启用敏感同步出现二选一，“以云端为准”后输入原主密码可恢复，“以本机为准”后云端密文被清空。
12. D6：分身默认无剪贴板桥接；开启后双向可用并服从各协议开关；关闭立即生效；主应用不受影响；开关不进备份、不云同步。
13. v1 第 9 节第 2、3、6–10、12 条继续有效（第 4、5 条中与 `backupopaque`/v4 相关部分随第 3 节第 2 条降级）。

## 7. 用户决策（2026-10-04 已确认）

| 编号 | 问题 | 决策 |
|---|---|---|
| D1 | 无主密码时敏感表能否上云（F3） | **允许**，依赖华为云空间自身加密；只修正文案与注释，如实区分“云空间加密”与“端到端加密” |
| D2 | 设备信任能否随备份导入（F4） | **脱敏不带；完整恢复后降级为待确认，首次连接重新确认** |
| D3 | 主密码规则（F7） | **不设长度与复杂度限制**（仅非空、两次一致） |
| D4 | 忘记密码重置的范围（F11） | **只清空加密字段，保留主机地址等普通配置** |
| D5 | LAN 三字段与受限管理员密钥来源在脱敏备份中保留（F5） | **保留** |
| D6 | 分身剪贴板（F14） | **默认关闭，允许用户手动开启** |
| D7 | 实施顺序 | 未单独答复，按默认：S0+S1 → S2 → S3（D3 → D6 → D2 → D4）→ S4 → S5 → S6 → S7 → S8 |

## 8. 完成条件

- F1、F2 关闭并有回归用例；F3–F7、F11、F14 按第 7 节决策落地；F8、F9、F16、F18 完成真机验证并按结论修复或记录为可接受风险；
- registry 成为导出/脱敏/校验/恢复/云扩展/敏感上传的唯一字段来源，闭包测试通过；
- S7 列出的每个阻断标记都有说明、退出路径与测试；
- 每期双 Hvigor 门禁、Light/diff、独立复核无 P0/P1/P2；设备与升级验收（S8）完成前不宣称“备份与升级已验收”。

本轮只更新本计划文件，不改应用实现、不构建、不装机。

## 9. 执行记录（2026-10-04）

| 批次 | 内容 | 提交 | 复核 |
|---|---|---|---|
| 1 | S0 宿主机测试脚本与真实旧版固件；S1：F1（完整备份排除 VNC 软删除）、F17（校验阶段与分层错误、诊断事件）、F19（v1/v2 恢复，含 2026-07-26..30 内测版 `vncrecords`/`vncrecord` 表与旧本地表规范化）、D1 文案、D5（非默认 LAN 值）；S3：D3、D6 | `9dab7e2ac` | 首轮 FAIL（P2：VNC 未设主密码时被写成“云空间加密”），修复后增量 PASS；追加 P3-1（旧格式不得携带未覆盖的 manifest/Moonlight 本地表）PASS |
| 2 | S2：F2（恢复不覆盖本机主密码参数，主密码不同则不导入加密数据）；S3：D2（脱敏不带设备信任、完整恢复降级为待确认、不削弱本机已建立的信任） | `59a03e1c3` | 首轮 PASS 附 7 项 P3（RDP 路由绑定可能沿用恢复的候选指纹、无契约文件带密文被当明文合并、文案、规划逻辑未测、非字符串 trim、形似密文的明文导致全部扣留、预览与恢复评估的数据不同），均已修复；两轮增量 PASS |
| 3 | S3：D4（重置只清空加密字段，VNC 仅删除机密记录并迁移到新代际，2FA 卡片/SSH 密钥显示“不可用”） | `8c2fe3ce1` | 首轮 FAIL（P1：重新勾选后整表日志把本机清空状态恢复并上传）→ 只清日志 FAIL（P1：平台自身的本地修改记录仍可能上传）→ 同步层拒绝上传 FAIL（P2：被拒的推送阻断下载并波及其他表）→ 协调器级“上传暂停” PASS |
| 4 | S4：字段登记表 `RemoteHostFieldRegistry`、F6（保存主机时，同步的 displayconfig 保留新版本写入的未知字段，绝不保留本版本已知且排除的字段）、更新版本备份的升级提示、解除重置暂停改为单事务 | `62cd22c68` | 首轮 PASS 附 P3（本机扩展前推会让降级后的完整备份自检失败、显示字段未登记），均已修复；F6 剩余路径与“可能”文案记为已知限制；增量 PASS |

验证（每批提交前的最终代码树）：`default@OhosTestCompileArkTS` 依次 49.523 s / 58.343 s / 35.704 s / 16.281 s，`assembleHap` 依次 54.424 s / 51.624 s / 36.678 s / 19.048 s，均 BUILD SUCCESSFUL；宿主机 `scripts/tests/test_data_management_safety.cjs` 最终 74/74；每批 Light 门禁与 `git diff --cached --check` PASS。未装机。

实施中的修订：
- D5 改为“只保留非默认值”，没有 LAN 绑定的主机生成的脱敏备份与 1.2.0 完全一致；含 LAN 绑定的新版脱敏备份会被旧版安全拒绝。
- S4 未把六处清单全部改为从登记表派生：登记表拥有 F6 所需的完整字段分类，并用闭包测试约束云扩展列、设备信任、备份白名单、`hostExtensionValues` 与本机个性化字段；`BackupManifestV3` 的 SECRET/SAFE 与 `CloudSensitiveTransferPolicy.SENSITIVE_COLUMNS` 仍各自维护，由跨清单测试防止漂移。
- 完整模式校验仍拒收未知字段（不做 opaque 导入）：导入一个无法解释的字段可能被将来的版本当作信任或密钥使用；改为对 v3 文件给出“可能由更新版本生成，请升级”的提示。
- F6 只作用于跨设备同步的 displayconfig：本机扩展从不同步，而完整备份会拒收未知字段，保留它们只会让降级后的完整备份失败，所以不保留。已知限制：设备信任迁移/拉取后信任清理、连接时 RDP 凭据净化会按投影重建扩展块，便携恢复会整体替换 displayconfig，这些路径不保留未知字段。
- D4 的云端语义（复核两轮后定稿）：重置不再写入任何待上传日志，并在同一事务中清除这些表原有的日志；同时写入持久的“重置上传阻断”（五张敏感表、`vncrecordv2`、`cryptoparams`），所有本机优先上传都在唯一的 `syncTableAsync` 入口被拒绝（失败类型 `crypto_reset_pending`，停止自动重试），下载不受影响。只有用户在“管理同步数据”中点击“以本机为准覆盖云端”并确认后才解除，之后仍由原有“覆盖云端存档”确认页执行上传。原因：平台自己记录分布式表的本地修改，云端优先拉取未必覆盖云端未变化的行，单靠清日志不能证明重置永不上传。
- F20（实施中新发现，已修复）：旧版重置写入整表日志，重新勾选敏感表时会把本机清空后的状态恢复并推送到云端，实际构成远程清空，与“不是远程擦除”的设计相反。
- VNC 证书的本机确认标记在重置时仍被清除（防止同指纹的新记录被隐式信任），所以重置后 VNC 证书需重新确认；SSH/RDP 设备信任保留。

仍开放：
- S5（F8/F9/F16）、F18：需要两台真机与真实华为账号验证后再改；F9 的“已回滚”文案在验证前保持不动。
- S6（F12/F13）：平台假设记录与云库交接流程未做。
- S7：持久化阻断标记的可退出性审计未做。
- S8：Phone/Pad/PC、旧版→新版保留数据升级、两台设备冲突与重置验收未做；本轮未装机。
- 验证口径更正：`default@OhosTestCompileArkTS` 只编译主代码（694 个文件），从不编译 `entry/src/test`；测试文件的严格 ArkTS 编译只发生在 `ohosTest@OhosTestCompileArkTS`，且只覆盖其列表导入的 73 个文件，而该编译本身有 300 个历史错误（299 个 ArkTS 错误：孤儿的 RustDesk Pro 通讯录测试 101 个、过期测试约 40 个、严格写法约 160 个；另有 1 个找不到模块），导致设备上的 hypium 测试无法运行。本计划新增的测试已通过“临时加入 ohosTest 列表”的严格编译（0 错误）并在宿主机脚本中实际执行；修复 ohosTest 编译另行处理。
- 已知行为：导出时快照阶段先记录 `local_backup_export succeeded`，随后自检失败再记录 `failed`（码 -3）；分身关闭剪贴板若保存失败，下次启动会恢复为开启（当场有提示）。
- 第 8 节完成条件对照：F1、F2 已关闭并有回归用例；F3–F7、F11、F14 已按第 7 节落地（F3→D1、F4→D2、F5→D5、F6→S4、F7→D3、F11→D4、F14→D6）；F17、F19、F20 已修复，F10 为根因更正、无需改代码；“registry 成为唯一字段来源”按上文修订为“登记表 + 跨清单闭包测试”；F8、F9、F16、F18 的真机验证、S7 阻断标记审计和 S8 设备与升级验收均未完成，因此不宣称“备份与升级已验收”。
- 复核遗留（P3）：重置后 SSH 生产力数据与会话日志仍由旧密钥加密而不可用；Moonlight 机密记录保留为不可解密文；早期代际的 VNC 行可能让 VNC 上传安全检查持续失败（安全方向）；VNC“记住密码”在机密删除后需确认连接时会提示输入；重置事务本身缺少 RDB 级自动化测试；RDP 路由探测对与实时证书不同的候选指纹显示“证书已变更”（仍需确认）；设置主密码后，形如 `3:a:b:c` 的明文密码会被全应用视为密文。
