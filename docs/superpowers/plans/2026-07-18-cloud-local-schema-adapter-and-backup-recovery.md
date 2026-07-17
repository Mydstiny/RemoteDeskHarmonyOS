# 本地数据与既有云表适配、备份恢复重构计划

日期：2026-07-18  
项目：RemoteDeskHarmonyOS  
分支：`codex/rustdesk-pro-account-sync`

## 1. 目标与不可违反的约束

### 1.1 目标

在不修改华为云现有数据表结构、不删除云端已有数据的前提下，建立稳定的本地数据模型与云表适配层，并恢复以下能力：

1. 云端数据可安全拉取到本地；
2. 本地增删改可以按策略上传到既有云表；
3. 本地主机扩展字段不因云同步丢失；
4. Pro 账户继续复用 `rustdeskrelays.accountsjson`；
5. 本地备份可导出、校验、导入和失败回滚；
6. 旧版本备份、旧本地数据库和云端旧字段能够兼容；
7. 云端空数据、结构不匹配、账号错误或同步失败时，禁止清空或覆盖本地/云端数据。

### 1.2 约束

- 不新增、删除或重命名云控制台中的字段；
- 不把本地专用字段写入既有云表；
- 不将 Pro access token 写入云表或本地普通数据库；
- 不把云端空响应当成可信的“全量删除”；
- 不在未完成云端快照校验前执行本地清空；
- 不在本地数据为空且没有明确用户确认时执行全量上传；
- 所有迁移和恢复操作必须可失败回滚；
- 保留当前工作区其他功能改动，不回退无关 UI、RustDesk、SSH 或 RDP 修改。

## 2. 已确认的结构差异

### 2.1 云表字段作为唯一同步契约

云端现有表为：

| 表 | 现有云字段/问题 |
|---|---|
| `cryptoparams` | `id/key/value`，本地基本一致 |
| `rdpcredentials` | 无本地 `username` 字段 |
| `remotehosts` | 使用拼写错误的 `passward`，没有本地 SSH host key、RDP 证书、RustDesk 直连及凭据关联扩展字段 |
| `rustdeskrelays` | 已有 `accountsjson`，可承载 Pro 账户非敏感元数据 |
| `sshkeys` | 无 `formatversion/privatekeyencrypted` |
| `totpentries` | 基本一致 |
| `usersettings` | 使用 `payload/schemaversion`，本地使用 `key/value` |

### 2.2 本地扩展字段

以下字段不得再写入 `remotehosts` 云表：

```text
sshkeypassphrase
sshkeyid
sshhostkeyalgorithm
sshhostkeyfingerprintsha256
sshhostkeyrawbase64
sshhostkeytrustedat
sshhostkeytrustmode
rdpcertificatefingerprintsha256
rdpcertificatesubject
rdpcertificateissuer
rdpcertificatecommonname
rdpcertificatetrustedat
rdpcertificatetrustmode
rdpcertificateallowuntrustedroot
rdpcertificateallowhostmismatch
rustdeskrelayid
rustdeskaccountid
rustdeskpasswordmode
rustdeskauthmode
rustdeskdirectenabled
rustdeskdirecthost
rustdeskdirectport
rdpcredentialid
```

这些字段进入本地扩展存储，并通过稳定的主键与云端基础记录关联。

## 3. 目标架构

```text
RemoteHost / SshKey / TotpEntry / Relay / UserSetting
                    │
          Local model + LocalExtensionStore
                    │
          CloudTableAdapter（字段白名单）
                    │
          Existing Huawei cloud tables
```

### 3.1 分层职责

#### CloudTableAdapter

- 只负责云字段白名单映射；
- 负责本地字段名与云字段名转换；
- 负责类型转换、空值处理和版本兼容；
- 负责将云行解析为“基础模型”，不直接写 UI 或业务状态；
- 严禁透传未知字段。

#### LocalExtensionStore

- 保存云表没有的本地扩展字段；
- 使用 `hostId/key/value` 或固定扩展表结构；
- 保存证书信任、SSH host key、RustDesk 直连、凭据关联和本地运行态；
- 扩展字段的删除与主记录删除保持事务一致；
- 扩展字段不参与云表 schema 绑定。

#### MergeService

- 将云端基础数据、本地扩展数据和本地安全凭据合并为完整模型；
- 以稳定 `id` 为主键；
- 云端缺失扩展字段时保留本地扩展；
- 云端删除只有在“完整快照已确认且用户允许”时才删除对应本地基础数据；
- 任何部分失败都不提交最终合并结果。

## 4. 具体适配方案

### 4.1 `remotehosts`

建立明确的云字段白名单：

```text
id, userid, label, protocol, host, port, username,
passward, customhostname, sshusekey, sshkeypath, sshkeydata,
proxyhost, proxyport, proxyusername, gatewayhost, gatewayport,
displayconfig, locked, locktype, isfavorite, groupid, sortorder,
icon, lastconnected, lasthealth, lastlatency, syncversion,
createdat, updatedat
```

映射规则：

- `password ↔ passward`；
- 读取时优先 `passward`，兼容旧本地数据库中的 `password`；
- 写入云表时只写 `passward`；
- 云端不存在的本地字段写入 `LocalExtensionStore`；
- `customhostname` 继续作为 RustDesk peer ID 的兼容载体，但新代码不再由 ID 前缀猜测全部 Pro 状态；
- RustDesk relay/account 关联从扩展存储读取，Pro 账户元数据从 `accountsjson` 合并。

### 4.2 `usersettings`

云表保持：

```text
id, userid, payload, schemaversion, updatedat
```

适配规则：

- 本地多个 `key/value` 行聚合为一个或多个 payload 文档；
- payload 使用稳定 JSON 对象格式；
- `schemaversion` 由适配器维护，不由 UI 直接修改；
- 下载时校验 JSON、schema 版本和允许的设置键；
- 未知设置键保留在兼容区，不直接写入运行时 `AppStorage`；
- 上传时只上传允许同步的设置键；
- 设置解析失败时保留上一份本地有效设置。

### 4.3 `rustdeskrelays`

- 使用云表已有全部字段；
- Pro 账户非敏感元数据统一放入 `accountsjson`；
- access token、刷新 token、设备密钥等只放安全存储；
- `accountsjson` 读写采用版本化 JSON；
- 旧版无 `accountsjson` 时视为空账户列表；
- JSON 损坏时保留原始值并记录错误，不覆盖为 `[]`；
- 中继卡片、Pro 账户和地址簿均通过同一份合并快照刷新。

### 4.4 `rdpcredentials`

- 云端没有 `username`，本地用户名放入 `LocalExtensionStore`；
- 云端基础记录保存 `id/label/password/createdat/updatedat`；
- 读取时按 credential ID 合并本地用户名；
- 删除凭据时同步删除本地扩展和引用关系；
- 不因云端缺少用户名而删除本地完整凭据。

### 4.5 `sshkeys`

- 云端只同步现有字段；
- `formatversion` 和 `privatekeyencrypted` 保存到本地扩展或通过确定性默认值推导；
- 私钥仍按现有 DataCrypto 流程加密；
- 解密失败不得把私钥当作空字符串上传；
- 导入、生成、更新、删除都通过同一适配器写入基础数据和扩展数据。

### 4.6 `cryptoparams` 与 `totpentries`

- 保持现有字段映射；
- `cryptoparams` 必须先于敏感表参与 cloud-first 拉取；
- 只有云端 cryptoparams 已成功验证，才允许解密后合并 SSH 密钥、TOTP 和密码；
- 加密状态异常时进入保护态，不清空业务表。

## 5. 本地数据库迁移

### 5.1 迁移前保护

1. 打开数据库前读取表结构并记录版本；
2. 迁移前导出本地只读快照到应用私有临时目录；
3. 快照包含行数、列名、主键摘要和校验和；
4. 迁移失败时恢复快照；
5. 迁移日志不得包含密码、私钥、TOTP secret 或 token。

### 5.2 表拆分迁移

- 保留现有业务表作为本地完整表；
- 新增本地扩展表，表名使用明确的本地前缀，例如 `localhostextensions`、`localcredentialextensions`；
- 旧版 `remotehosts` 中的 Pro 字段先复制到扩展表，再从云同步写入路径移除；
- 不使用 API 23 不支持的 `DROP COLUMN`；
- 如必须重建本地表，使用事务创建 canonical 临时表、复制数据、校验行数、替换表；
- 迁移完成后再次执行 `PRAGMA table_info` 并与本地预期 schema 比对。

### 5.3 迁移验收

- 每张表迁移前后行数一致；
- 每个主键集合一致；
- 密文值逐行校验一致；
- 扩展字段可通过主键完全恢复；
- 重复启动不会重复迁移；
- 迁移失败不会把表置为空。

## 6. 云端拉取流程

```text
绑定云表
  → 获取云端完整快照/变更游标
  → 校验账号、表名、schema 和记录数量
  → 先拉 cryptoparams
  → 拉基础表
  → 拉本地扩展合并所需的关联记录
  → 原子提交本地基础数据与扩展数据
  → 刷新服务和 UI
```

保护条件：

- 任一关键表返回结构错误：停止本次拉取；
- 所有业务表均返回 0，但云端快照未明确声明为空：停止，不清空本地；
- 拉取过程中部分表成功、部分失败：整体回滚；
- 仅收到“变更为空”不能当成全量为空；
- 记录 `accountId/appId/schemaVersion/cursor`，便于定位错账号或错环境；
- 成功后才更新本地游标。

## 7. 云端上传流程

完整能力恢复后仍保留安全门：

- 普通单行增删改只上传经过 adapter 过滤的云字段；
- 本地扩展变更不触发云表未知字段写入；
- 空本地数据库禁止自动全量上传；
- 全量上传前显示本地/云端行数对比；
- 上传前保存本地快照；
- 只在每张表收到成功回执后推进游标；
- 任何失败保留本地数据和待重试状态；
- `cryptoparams` 变更必须经过显式确认；
- 云端删除操作必须要求完整快照证据或用户明确确认。

## 8. 本地备份与恢复重构

### 8.1 备份格式

使用版本化文档：

```json
{
  "format": "remotedesk-local-backup",
  "formatVersion": 2,
  "createdAt": 0,
  "appVersion": "1.0.7",
  "schemaFingerprint": "...",
  "tables": {},
  "extensions": {},
  "checksum": "..."
}
```

要求：

- `tables` 保存云兼容字段和本地可恢复字段；
- `extensions` 保存云表没有的本地字段；
- 密钥、密码、TOTP 和中继敏感值沿用现有加密策略；
- 不把 access token 写入普通备份；
- 文件解析采用严格 JSON/格式校验；
- 文件选择器取消、空文件、损坏文件和版本过高都给出明确错误。

### 8.2 备份导出

1. 暂停自动上传队列；
2. 开启只读事务快照；
3. 导出所有基础表、扩展表和必要的 schema 元数据；
4. 计算稳定排序后的 checksum；
5. 加密并写入用户选择的文件；
6. 成功后恢复同步队列；
7. 导出失败不改变数据库和云同步状态。

### 8.3 备份恢复

1. 读取文件并校验格式、版本、checksum；
2. 将旧字段名转换为当前 canonical 字段；
3. 将 `password` 转为 `passward` 兼容映射；
4. 将缺失的新字段补默认值，将未知字段放入兼容区或忽略；
5. 先写入临时表/临时快照；
6. 校验所有主键、引用关系和扩展关联；
7. 用户确认后在单一事务中替换本地数据；
8. 恢复后禁止自动上传，等待用户明确选择“上传到云端”；
9. 恢复失败自动回滚到恢复前快照。

### 8.4 兼容历史备份

- 支持旧版完整字段备份；
- 支持旧版缺少 `formatversion/privatekeyencrypted` 的 SSH 密钥备份；
- 支持旧版 `usersettings key/value` 行格式转换为 payload；
- 支持旧版 `remotehosts.password` 和云端 `passward` 两种拼写；
- 支持旧版 Pro 字段迁移到本地扩展；
- 对字段缺失采用向前兼容，对未知字段禁止静默覆盖当前数据；
- 恢复报告列出跳过字段、默认字段和冲突字段。

## 9. UI 与状态刷新

- 云同步状态区分：未绑定、绑定中、拉取成功、拉取部分失败、上传待确认、保护态；
- 展示每张表的最后成功时间、行数和错误原因；
- 数据恢复完成后统一触发 HostSyncService、KeyVaultService、Relay 服务刷新；
- 设置、密钥、TOTP、中继和主机卡片全部从合并后的本地快照刷新；
- 云端空响应不会让 UI 直接变成空状态，除非完整快照已确认且用户接受删除。

## 10. 实施顺序

### 阶段一：冻结与观测

- 保留当前工作区快照；
- 增加脱敏的 schema、行数、游标和同步方向日志；
- 确认当前设备、账号、appId 和云服务实例；
- 禁止测试期间自动全量上传。

### 阶段二：适配层

- 新增 `CloudTableAdapter`；
- 新增本地扩展存储；
- 实现七张云表的字段白名单；
- 实现 `passward`、`usersettings payload` 和 `accountsjson` 适配；
- 将所有 CRUD 改为经过适配层。

### 阶段三：本地迁移

- 实现迁移前快照；
- 迁移旧 Pro 字段到扩展表；
- 校验行数、主键、密文和扩展字段；
- 完成幂等和失败回滚。

### 阶段四：云端拉取

- 实现 cloud-first 全量快照保护；
- cryptoparams 优先拉取和校验；
- 基础表与扩展数据原子合并；
- 处理空响应、部分失败和错账号。

### 阶段五：备份恢复

- 升级本地备份格式；
- 实现旧格式转换器；
- 实现恢复前快照和事务回滚；
- 恢复后默认禁止自动上传。

### 阶段六：恢复完整同步

- 逐表恢复自动上传；
- 保留空库上传保护；
- 加入显式全量上传确认；
- 验证多设备增删改查和冲突处理。

## 11. 验证矩阵

### 单元/策略测试

- 七张表字段白名单测试；
- `password/passward` 双向转换测试；
- `usersettings key/value ↔ payload` 测试；
- `accountsjson` 版本化解析和损坏保护测试；
- 扩展字段合并、删除和孤儿清理测试；
- 旧备份、新备份、缺字段、未知字段和损坏 checksum 测试；
- 空云响应不会清空本地测试；
- cloud-first 失败不会触发上传测试。

### 设备测试

1. 空白设备首次 cloud-first 拉取；
2. 云端有数据、本地为空；
3. 本地有数据、云端有数据；
4. 云端返回空表；
5. 云端只返回部分表；
6. 断网、切 Wi-Fi、云服务不可用；
7. 旧版本数据库迁移；
8. 旧备份导入和恢复；
9. 恢复后不自动上传；
10. 用户确认后全量上传；
11. 主机、SSH 密钥、2FA、RDP 凭据、中继和 Pro 账户实时刷新；
12. 多设备新增、编辑、删除和冲突处理。

### 发布前门禁

- `default@OhosTestCompileArkTS`；
- 受影响 ArkTS 单元测试；
- 生产 `assembleHap`；
- `git diff --check`；
- Light 合规检查；
- 真机 38451 至少完成 cloud-first、备份恢复和上传确认三条链路；
- 日志确认无敏感数据泄漏、无未授权清库、无云表 schema 变更。

## 12. 完成标准

只有同时满足以下条件才算完成：

- 云端既有表结构未发生变化；
- 云端基础数据能按字段白名单完整拉回；
- 本地扩展字段在同步和恢复后保持；
- Pro 账户仍通过 `accountsjson` 工作；
- 本地备份可导出并在新设备恢复；
- 旧备份可兼容导入；
- 空云响应、结构错误和部分失败不会清空本地；
- 恢复后不会未经确认自动上传；
- 用户明确确认后，完整增删改查同步可正常工作；
- 真机日志和测试结果均可追溯。
