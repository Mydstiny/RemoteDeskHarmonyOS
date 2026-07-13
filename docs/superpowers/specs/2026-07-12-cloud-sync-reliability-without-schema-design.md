# 无云表迁移的云同步可靠性修复设计

**状态：** 用户已确认方案，等待书面规格审阅后制定实施计划。

## 目标

在不新增、不删除、不修改七张华为云表及其字段的前提下，保证用户选择的数据范围是云同步的唯一边界，同时保留“本地 CRUD 后立即自动上传、每次启动自动拉取”的产品行为，并消除恢复、加密和并发操作的主要数据风险。

## 固定约束

- 云表固定为 `cryptoparams`、`usersettings`、`remotehosts`、`rdpcredentials`、`rustdeskrelays`、`sshkeys`、`totpentries`；禁止任何 schema 变更。
- 用户的同步选择仍仅存本机，默认全选；未选表绝不主动上传或下载，原有本地/云端数据不删除。
- `cryptoparams` 仍是敏感业务表的前置依赖；拉取时优先于业务表。
- 启动和手动下载使用 `CLOUD_FIRST`；手动上传和 CRUD 自动推送使用 `NATIVE_FIRST`。
- 保留明文 JSON 本地备份；恢复时绝不自动上传到云端。
- 不改 RDP、RustDesk、SSH、VNC、渲染、音频、输入或既有加密格式。

## 核心架构

所有七张表继续通过 `setDistributedTables(..., DISTRIBUTED_CLOUD, { autoSync: false })` 注册为华为云表。关闭的是系统对表变更的自主同步，不是 `cloudSync()` API；应用仍可显式调用 `cloudSync()` 完成自动或手动同步。

新增单一 `CloudSyncCoordinator`，成为唯一允许请求云同步的入口。它维护一个内存串行队列和本机持久化的待推送表状态，所有请求在入队时冻结“选择快照、方向、来源、表集合和操作 id”。`CloudStore` 只保留 RDB、序列化、数据读取和单表实际执行；各业务服务不再直接触发 `cloudSync()`。

```text
CRUD / 启动 / 前台恢复 / 手动操作 / 云端变更
                  ↓
         CloudSyncCoordinator
   选择快照 · 全局串行 · 重试 · 事件去重
                  ↓
              CloudStore
       cloudSync(CLOUD_FIRST/NATIVE_FIRST)
                  ↓
              华为云七表
```

## 同步触发规则

| 来源 | 表集合 | 方向 | 失败后的行为 |
| --- | --- | --- | --- |
| 本地 CRUD | 当前选中的所属表；敏感表自动加 cryptoparams 依赖 | Native-first | 合并同表最新状态，持久化等待重试 |
| 应用启动 | 当前选择快照 | Cloud-first | 逐表结果刷新；失败表保留本地缓存并标记待重试 |
| 应用回前台 | 当前选择快照，仅在上次同步失败、网络/服务恢复或显式云变更时 | Cloud-first | 同启动恢复 |
| 手动上传 | 用户确认时冻结的当前选择快照 | Native-first | 报告成功、失败、跳过表；不把部分成功称为整体覆盖 |
| 手动下载 | 用户确认时冻结的当前选择快照 | Cloud-first | 任一表失败则恢复本地快照；不刷新为半恢复状态 |
| 云端变更通知 | 当前选择快照 | Cloud-first | 自身操作产生的通知只更新状态，不反向拉取 |
| 本地 JSON 恢复 | 全七表，仅本地 | 不调用云 | 恢复锁期间所有云请求排队，完成后不自动上传 |

零表选择不会调用任何云 API；UI 的上传和下载按钮明确禁用并说明原因。选择发生变更时不会影响正在执行的操作；新选择只对之后入队的操作生效。

## 队列、重试与可观测性

协调器按操作而非按表建立全局队列，避免 `cryptoparams`、业务表、下载和恢复相互穿插。自动 CRUD 请求可在同一表上合并，但删除必须保留为最终状态。每次失败记录表名、方向、操作 id、失败次数、错误码和下一次重试时间到本机 Preferences；不记录任何业务内容或敏感值。

重试仅在 Wi‑Fi 可用、云服务可用且应用处于可执行生命周期时运行，采用有限指数退避。手动操作优先于后台重试。云端事件订阅保留，但仅提交协调器请求；在本机操作尚未完成或事件携带同一操作 id 时不触发反向下载。

## 手动操作与本地恢复安全

手动上传不具备华为云跨表原子提交能力，因此 UI 必须显示逐表进度和最终逐表结果。任何失败都显示“部分完成”，提供“仅重试失败表”，不显示“云端已整体覆盖”。

手动下载开始前，导出七表的内存快照；若任意表失败，使用单个本地 RDB 事务恢复该快照。只有完整成功后才通过刷新总线更新主机、凭据、中继、SSH 密钥、TOTP 与个性化设置。

本地 JSON 恢复改为固定七表 schema 的字段/类型校验，恢复锁覆盖整个预检、替换和内存刷新窗口。恢复完成后不提交任何云请求，后续只有新的用户 CRUD 或用户手动上传才允许写云。

## 加密生命周期

启用、关闭、重置加密必须作为协调器独占操作。启用时的顺序是：保存 cryptoparams → 完成本地可恢复迁移 → 推送 cryptoparams → 推送已选敏感业务表。关闭和重置也必须在同步选择允许传播时才执行跨设备信令；若用户没有选择任何敏感表，UI 必须明确提示“此操作只能影响本机”，不能静默假定其他设备会同步状态。

`autoMigrate()` 保留幂等性，但要补充本机操作记录，确保异常退出后可在解锁时继续完成；在迁移完成前不得把操作标为成功。

## 运行态刷新与已知边界

新增按表刷新总线：主机与 RDP 凭据刷新 `HostSyncService`，SSH/TOTP 刷新 `KeyVaultService`，中继刷新中继状态，`usersettings` 使用既有白名单同步更新 Preferences、AppStorage 与当前 UI。启动流程只保留一次 cloud-first 恢复。

在不增加 `deviceId`、墓碑或修订元数据的限制下，不能完整解决两台设备离线同时修改或“删除与修改”同一记录的冲突。修复后的策略是避免应用侧并发、保留本地下载回滚快照、如检测到本机存在未完成推送则不自动 cloud-first 覆盖，并将最终同记录冲突继续交由华为云现有规则处理。这是本约束下明确保留的边界，不会假称已具备跨设备冲突合并能力。

## 验收标准

- 取消任一表后，该表在 CRUD、启动、前台、手动上传下载、云端事件中均不产生 `cloudSync()` 调用。
- 任一 CRUD 后，对应已选表立即入队并在 Wi‑Fi/云服务可用时完成 native-first 推送；失败可自动重试。
- 每次冷启动只执行一次 cloud-first 恢复；成功表立即刷新到 UI 和运行态。
- 下载任一表失败后，七表本地数据与下载前一致。
- 本地恢复期间没有 cloudSync 调用，恢复完成后不自动上传。
- 加密启停不会与业务表同步交叉；未选择敏感表时跨设备影响有明确拦截提示。
- 生产 `assembleHap` 通过；云同步 Hypium 测试在修复既有测试目标阻塞后全部通过；两台真机完成离线、Wi‑Fi 切换、云服务关闭和部分失败矩阵。

## Implementation Verification — 2026-07-13

The design was implemented without changing any of the seven cloud-table schemas. Explicit coordinator execution remains the only production `cloudSync()` path, with system `autoSync` disabled. Automatic retries are selection-aware at execution time; manual-download rollback is visible to UI; RDB mutations are success-gated; crypto raw writes respect restore/download locks; and disable/reset encryption stop before cloud publication when a local transaction fails.

Signed `assembleHap` passed. The ArkTS test target did not execute the policy suites because it is still blocked by the existing `HostListPage.ets:2794:11` parser error followed by the DevEco SourceMap `reading 'share'` crash. This blocker is outside the cloud-sync change set.
