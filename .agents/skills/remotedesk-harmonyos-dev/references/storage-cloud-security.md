# 账号、云同步、备份与安全

核验快照：2026-09-07，`0000d4ca4`。本专题必须结合当前实现，不直接执行历史迁移步骤。

## 定位入口

| 操作 | 代码 |
|---|---|
| 账号切换与作用域 | [AccountSessionCoordinator.ets](../../../../entry/src/main/ets/services/AccountSessionCoordinator.ets)、[AccountScopePolicy.ets](../../../../entry/src/main/ets/services/AccountScopePolicy.ets) |
| 平台云身份 | [PlatformCloudIdentityPolicy.ets](../../../../entry/src/main/ets/services/PlatformCloudIdentityPolicy.ets)、[PlatformCloudIdentityService.ets](../../../../entry/src/main/ets/services/PlatformCloudIdentityService.ets) |
| RDB/云初始化和兼容恢复 | [CloudStore.ets](../../../../entry/src/main/ets/services/CloudStore.ets)、[CloudBindingRecoveryPolicy.ets](../../../../entry/src/main/ets/services/CloudBindingRecoveryPolicy.ets) |
| 旧库迁移 | [LegacySharedStoreMigrator.ets](../../../../entry/src/main/ets/services/LegacySharedStoreMigrator.ets)、[LegacySharedStoreMigrationPolicy.ets](../../../../entry/src/main/ets/services/LegacySharedStoreMigrationPolicy.ets) |
| 云首轮与生命周期 | [CloudBootstrapReconcilePolicy.ets](../../../../entry/src/main/ets/services/CloudBootstrapReconcilePolicy.ets)、[CloudLifecycleSafetyPolicy.ets](../../../../entry/src/main/ets/services/CloudLifecycleSafetyPolicy.ets) |
| 本地备份 | [LocalBackupService.ets](../../../../entry/src/main/ets/services/LocalBackupService.ets)、[LocalBackupPolicy.ets](../../../../entry/src/main/ets/services/LocalBackupPolicy.ets)、[BackupManifestV3.ets](../../../../entry/src/main/ets/services/BackupManifestV3.ets) |
| 加密与敏感传输 | [DataCrypto.ets](../../../../entry/src/main/ets/services/DataCrypto.ets)、[CloudSensitiveTransferPolicy.ets](../../../../entry/src/main/ets/services/CloudSensitiveTransferPolicy.ets)、[CryptoLifecyclePolicy.ets](../../../../entry/src/main/ets/services/CryptoLifecyclePolicy.ets) |
| 密码显示与编辑 | [SecretPresentationPolicy.ets](../../../../entry/src/main/ets/services/SecretPresentationPolicy.ets)、[SecretEditMutationPolicy.ets](../../../../entry/src/main/ets/services/SecretEditMutationPolicy.ets) |

## 物理库规则有历史冲突

[DECISIONS.md](../../../../docs/codex/DECISIONS.md) 中 D-008/D-022 以及重复编号不是可直接执行的完整现状。不能简单宣称“所有 owner 各一库都可以云同步”，也不能因为存在 canonical store 就允许任意账号打开它。

当前 `AccountScopePolicy.accountScopeToken` 为通过平台云身份证明的账号选择 canonical `remotedesktop.db`，其余选择当前 owner 的本地 hashed 库；`CloudStore.openScopeStore` 在 canonical 属于其他 owner 或兼容迁移失败时保留源数据并回退，`verifyStoreIdentity` 核对 owner/store/平台指纹。这是本项目当前部署契约，不是鸿蒙所有应用只能使用一个云库名称的通则。

沿当前初始化及 `verifyAccountScopeCloudBinding` 核对：平台身份绑定、候选 store、canonical owner 确认、旧 owner 规范化、分布式表注册、失败后的隔离回退、作用域 generation。云数据库名称契约和本地隔离要求需同时满足。

遇到 14800000/数据消失/登录回退时先检查哪个阶段失败、哪些表失败、目标 AGC schema 和 store identity，保留原库。修复前核对 [2026-08-28-cloud-sync-compatibility-first-recovery.md](../../../../docs/codex/plans/2026-08-28-cloud-sync-compatibility-first-recovery.md) 和 [2026-08-28-cloud-sync-permission-race-recovery.md](../../../../docs/codex/plans/2026-08-28-cloud-sync-permission-race-recovery.md)。

## 持续适用的检查点

- 每个异步回调、CRUD、迁移、备份都携带当前 owner/scope generation；旧账号结果不能写入新账号状态。
- cloud bootstrap 未获得权威结果时，不因本地非空、回调接受或一个成功表就宣称可全量上传。
- Moonlight/VNC 可选表兼容失败要与旧表恢复区分，不把一个可选 schema 错误扩大成整个登录/旧数据不可用。
- 删除、恢复、加密重置必须检查 durable receipt、事务/回滚、读取验证和终止状态。备份缺少某 section 不代表要求清空它。
- 迁移失败后保存权威隔离数据，避免再反向导入旧 canonical 快照覆盖较新恢复数据。
- 敏感字段是否允许导出取决于当前备份模式、用户选择和有效加密契约；不能从“密码显示受保护”推导“备份已加密”。不要从历史文档擅自删除或放开可导出字段。

## 协议和附属数据也在生命周期内

Moonlight 可选云表、selection、tombstone、配对身份删除、backup 兼容分别有 policy；查 [MoonlightCloudDeletionPolicy.ets](../../../../entry/src/main/ets/services/MoonlightCloudDeletionPolicy.ets)、[MoonlightBackupPolicy.ets](../../../../entry/src/main/ets/services/MoonlightBackupPolicy.ets)。VNC 独立 settings/secret/trust 与旧 host projection 必须一并检查。

TOTP/key vault/host lock/证书信任问题按本专题和对应协议继续查，不把 SSH host 公钥和 SSH 私钥混为一类。TOTP 品牌素材改动使用现有 `scripts/validate_totp_brand_manifest.py` 与 provenance 流程，不能随意替换上游素材。

## 验证

定向查 `CloudStore.test.ets`、`CloudBindingRecoveryPolicy.test.ets`、`LegacySharedStoreMigrationPolicy.test.ets`、`CloudSensitiveTransferPolicy.test.ets` 和 `LocalBackupPolicy.test.ets`。仿真 policy 通过不证明真实 RDB、AGC、app clone 或账号切换验收完成。先用副本/受控样本验证恢复，不对用户唯一数据试验破坏性操作。
