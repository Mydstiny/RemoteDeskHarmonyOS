# 本地备份、RustDesk 配置粘贴与设备密码统一修复方案

**基线：** 2026-07-19，分支 `codex/rustdesk-pro-account-sync`，提交 `a019ea96f`。

**目标：** 修复本地备份“保存后无法导入”、RustDesk 中继配置依赖剪贴板权限、RustDesk 设备密码只有直连路径能保存的问题；同时保留当前已经验证可用的云表适配、脏表重试、手动下载回滚和云端字段结构。

## 一、硬约束

- 不修改、不新增、不删除任何华为云表字段。
- `remotehosts.passward` 继续作为主机设备密码的唯一云端字段。
- 删除 `localextensions.password` 的覆盖作用，不再让本地扩展副本覆盖 `passward`。
- RustDesk Server Pro 登录密码不保存；Pro access token/device identity 属于设备凭据，后续进入安全存储，不能混入云端 `accountsjson`。
- RustDesk 设备密码只有在远端鉴权成功且用户明确开启“记住密码”后才保存；失败、取消、超时都不能落盘。
- 中继配置导入不再读取系统剪贴板，不申请或依赖剪贴板权限；“粘贴”只表示用户手动把配置密钥填写进应用。
- 保留现有文件导入、旧备份 v1/v2、官方 RustDesk 反转 Base64/JSON 解析兼容性。
- 不触碰当前工作树中与本方案无关的虚拟鼠标、FAB、RustDesk 网络等未提交改动。

## 二、已确认根因

### 1. 本地备份被错误判定为无效

当前链路：

`LocalBackupService.saveBackup()` → `CloudStore.exportAllTableRows()` → `ResultSet.getColumnNames()` → JSON 文件 → `validateLocalBackupDocument()`。

问题有两层：

1. 分布式表结果集会返回系统删除标记列 `#_deleted_flag`。当前 `exportAllTableRows()` 将所有列原样写入备份，但 `LocalBackupPolicy.localBackupColumns()` 不允许该列，因此有实际数据的备份会被校验拒绝。API 23 文档明确该列是结果集辅助字段，不应作为业务列恢复。
2. `saveBackup()` 忽略 `writeSync()` 返回值，`selectAndValidate()` 只执行一次 `readSync()` 且不检查完整读取。文件提供方发生部分读写时，JSON 会被截断或补零，最终同样显示“未选择有效的本地备份文件”。

SHA-256 目前只能发现损坏，不能解决上述字段投影和 I/O 完整性问题；后续仍需按总云同步计划升级到加密备份 v3。

### 2. RustDesk 中继配置导入错误地依赖系统剪贴板

当前 `RustDeskRelayPage.importRelayClipboard()` 调用 `ClipboardBridgeService.getSystemText()`，内部再调用 `pasteboard.getSystemPasteboard().getData()`。无剪贴板权限时服务将错误吞掉并返回空字符串，页面只能提示剪贴板为空。

现有 `RustDeskRelayImportService.parse()` 已经具备官方配置解析能力：

- 直接 JSON；
- RustDesk 客户端导出的“整体反转 + Base64URL(JSON)”配置串；
- `host/relay/api/key` 与兼容字段名；
- ID/Relay 地址和端口解析。

因此缺口在输入 UI，不在官方配置解析核心。

### 3. RustDesk 设备密码保存路径不一致

当前存在三个问题叠加：

1. `HostListPage.confirmRustDeskProPreflight()` 在鉴权成功后调用 `HostSyncService.updateHost(saved)`，但忽略返回值，保存失败时仍继续进入连接页面。
2. `RemoteDesktop.persistRustDeskSessionAuth()` 使用 `isProRustDeskHost()` 作为前置条件，只有 Pro 主机走该保存路径；普通中继和其他会话入口不会统一保存。
3. `CloudStore.updateHost()` 先写 `remotehosts`，再单独写 `localextensions`，并且 `hostExtensionValues()` 把密码再次写入 `localextensions.password`。启动加载时 `mergeHostExtension()` 使用扩展中的 `password` 覆盖主记录的 `passward`。旧密码或一次失败/延迟的扩展写入就会在重启或云回调后把新密码覆盖掉。

这解释了“直连看起来能保存，而 Pro/普通中继保存后又恢复旧值”的差异：不是直连协议本身有不同的密码存储，而是不同连接入口和旧扩展副本触发了不同的覆盖顺序。

## 三、目标数据流

```text
用户输入/认证成功
        ↓
统一 RustDeskAuthPersistenceService
        ↓
RemoteHost.password
        ↓
CloudStore 事务：remotehosts.passward + 非敏感扩展
        ↓
HostSyncService 单次快照
        ↓
CloudSyncCoordinator 脏记录/表级兼容队列
        ↓
云端回调只接受不旧于本地修订的快照
```

密码不再进入 `localextensions` 或 `displayconfig._remoteDeskExtensionV1`。中继地址、认证模式、Pro 绑定等非敏感配置仍按当前 CloudTableAdapter 规则同步。

## 四、实施任务

### Task 0：建立回归基线和隔离工作树改动

**文件：** 只读检查现有代码和测试；不修改用户未提交的无关文件。

- 保存当前 `git status --short --branch` 和相关文件 diff 清单。
- 创建脱敏备份夹具：空库、含一条主机/中继/密钥/2FA 的 v2 备份、带分布式删除标记的结果集快照、旧密码扩展副本。
- 记录当前云同步基线：编辑 RustDesk 直连/普通中继/Pro 主机端口和密码，手动推送，杀后台冷启动，确认端口和密码不回退。
- 若 `HostListPage.ets`、`RemoteDesktop.ets` 或 RustDesk FFI 的未提交改动与本任务冲突，先做精确 checkpoint，不得覆盖。

### Task 1：修复本地备份导出、导入和完整 I/O

**修改：**

- `entry/src/main/ets/services/CloudStore.ets`
- `entry/src/main/ets/services/LocalBackupPolicy.ets`
- `entry/src/main/ets/services/LocalBackupService.ets`
- `entry/src/main/ets/pages/HostListPage.ets`
- `entry/src/test/LocalBackupPolicy.test.ets`
- 新增 `entry/src/main/ets/services/BoundedDocumentIo.ets`
- 新增 `entry/src/test/BoundedDocumentIo.test.ets`

**实现：**

1. 在 `exportAllTableRows()` 和 `exportLocalExtensionRows()` 统一通过白名单投影列，只导出业务列；至少明确过滤 `relationalStore.Field.DELETED_FLAG_FIELD` / `#_deleted_flag`，不能把系统列写入可恢复备份。
2. 恢复入口对旧文件做兼容归一化：允许并剥离历史文件中的 `#_deleted_flag`，但绝不把它插入 RDB。
3. `BoundedDocumentIo.readDocumentFully(uri, maxBytes)`：先检查文件大小，再按固定块循环读取，累计返回值必须等于文件大小；超限、空文件、部分读取分别返回明确错误码。
4. `writeDocumentFully(uri, bytes)`：循环写入并验证写入字节数；保存失败不能提示“本地备份已保存”。
5. JSON 校验失败时保留内部诊断码（格式、系统列、缺表、未知列、哈希不匹配、截断），UI 显示可操作提示，不再统一吞成“未选择有效文件”。
6. 保持 v1/v2 可读和现有 SHA-256 校验；加密、认证和密码保护按总云同步计划的备份 v3 任务继续实施，不在这个热修复中破坏旧文件。

**必须覆盖：**

- 含真实业务行的当前 v2 备份可保存后重新选择；
- 含 `#_deleted_flag` 的历史备份可读但恢复时不写入系统列；
- 分块读写、短读、短写、空文件、超大文件、截断 JSON；
- 篡改一个字符仍被拒绝；
- 恢复失败保持原本地数据，且不自动上传云端。

### Task 2：将中继“剪贴板导入”改为手动粘贴配置密钥

**修改：**

- `entry/src/main/ets/pages/RustDeskRelayPage.ets`
- 新增 `entry/src/main/ets/components/resourceadd/modern/RustDeskRelayConfigPasteSheet.ets`
- `entry/src/main/ets/services/RustDeskRelayImportService.ets`（只补解析结果/错误码，不改协议兼容逻辑）
- `entry/src/test/RustDeskRelayImportService.test.ets`

**实现：**

1. 删除中继添加二级页面中“读取系统剪贴板”的动作和 `ClipboardBridgeService` 依赖；保留远程会话真实剪贴板功能，不删除全局剪贴板服务。
2. 按当前 Modern/BindSheet 风格新增子弹窗，标题为“粘贴 RustDesk 配置密钥”，主体使用多行输入区域，说明“请在 RustDesk 客户端复制配置后，在此处手动粘贴；应用不会读取系统剪贴板”。
3. 点击“解析”时调用现有 `RustDeskRelayImportService.parse('手动配置', input.trim())`。
4. 解析成功：关闭子弹窗，将 ID Server、ID 端口、Relay、Relay 端口、API、Key 回填到二级中继表单；不直接保存，用户仍可修改后保存。
5. 解析失败：保留输入和子弹窗，显示具体错误；空串、非法 Base64、非 RustDesk JSON、端口越界都不关闭弹窗。
6. “从文件导入配置（兼容）”继续保留，和手动粘贴走同一个回填函数，避免两套字段映射。

**必须覆盖：**

- 官方反转 Base64URL 配置串；
- 直接 JSON 配置；
- Relay 为空时按现有规则回填；
- IPv4、IPv6、显式端口；
- 空输入和损坏输入不触发剪贴板权限、不改变表单旧值。

### Task 3：统一三种 RustDesk 主机的鉴权后密码保存

**新增/修改：**

- 新增 `entry/src/main/ets/services/RustDeskAuthPersistenceService.ets`
- 新增 `entry/src/main/ets/services/RustDeskAuthPersistencePolicy.ets`
- 新增 `entry/src/test/RustDeskAuthPersistencePolicy.test.ets`
- `entry/src/main/ets/pages/HostListPage.ets`
- `entry/src/main/ets/pages/RemoteDesktop.ets`
- `entry/src/main/ets/services/HostSyncService.ets`
- `entry/src/main/ets/services/CloudStore.ets`
- `entry/src/main/ets/services/HostSyncMergePolicy.ets`
- `entry/src/main/ets/services/RustDeskProSyncPolicy.ets`
- `entry/src/test/HostSyncMergePolicy.test.ets`
- `entry/src/test/RustDeskProSyncPolicy.test.ets`

**实现：**

1. 定义统一请求：`hostId`、`authenticated`、`authMode`、`passwordMode`、`rememberPassword`、`password`，返回 `ok / unchanged / not_found / local_write_failed / unlock_required / sync_deferred`。
2. 只有 native 连接状态确认鉴权成功后才调用；连接失败、取消、超时和远端批准未完成都不保存。
3. 移除 `RemoteDesktop.persistRustDeskSessionAuth()` 的 Pro-only guard；HostList 前置鉴权、RemoteDesktop 直接连接/恢复路径全部调用同一 service。
4. `confirmRustDeskProPreflight()` 必须检查持久化结果：连接可以继续，但保存失败时明确提示“本次连接成功，但设备密码保存失败，请重试”，不能静默进入已记住状态。
5. 普通 RustDesk 中继、Pro 地址簿主机、RustDesk 直连主机采用完全相同的保存规则；直连只影响连接端点和是否允许请求批准，不影响数据保存。
6. `CloudStore.updateHost()` 改为一个 RDB 事务完成：写主机行、写非敏感扩展、记录本地修订/脏意图后再提交；扩展失败必须回滚主行，不能返回成功。
7. `hostExtensionValues()` 删除 `password`；`mergeHostExtension()` 不再读取扩展密码。迁移规则为：有效非空 `passward` 优先；只有 `passward` 为空时才从旧扩展复制一次，然后删除旧键并写回 `passward`。
8. `projectRemoteHostCloudExtension()` 继续排除密码，`hostToBucket()` 只把密码写入 `remotehosts.passward`；不修改云表结构。
9. Pro reconcile 在 API 没有返回设备密码时保留本地已保存密码；有新密码时按明确版本/时间规则接受，不能因一次地址簿刷新把本地密码清空。
10. 保留当前 `CloudSyncCoordinator` 的表级脏队列和重试；在总计划的记录级 journal 任务中补上 host revision，使云回调不会用旧快照覆盖刚保存的密码。

**必须覆盖：**

- 直连、普通中继、Pro 地址簿主机分别保存一次性密码和永久密码；
- 记住关闭时认证成功后密码不改变；
- 杀后台冷启动后密码仍来自 `passward`；
- 云回调返回旧扩展/旧主机行时，新密码不回退；
- 本地扩展写失败时主行回滚、UI 收到失败；
- Pro 地址簿同步不返回密码时，本地记忆密码不丢失；
- Pro 账号登录密码仍不保存，不能把它和远端设备密码混淆。

### Task 4：与现有云同步安全评估计划合并验收

本任务完成后继续执行现有计划中的相关阶段，不重复实现已经存在的基础：

- 保留 `CloudTableAdapter` 的 `passward` 适配和字段白名单；
- 保留 `CloudSyncCoordinator` 的启动拉取、表级脏表、重试、会话期间延迟和手动下载回滚；
- 将 Task 3 的 host revision journal 接入总计划的记录级同步任务；
- 将备份 Task 1 的完整 I/O 和系统列归一化作为备份 v3 的输入层；
- 将 Pro token 安全存储、加密锁定 fail-closed、RDP 用户名跨设备 envelope、设置作用域和全 App 单次刷新继续按总计划执行。

## 五、验证顺序

### 自动化验证

1. 定向 ArkTS 单元测试：备份策略、完整 I/O、RustDesk 配置解析、密码保存策略、HostSyncMergePolicy、RustDeskProSyncPolicy。
2. `default@OhosTestCompileArkTS`。
3. `assembleHap`。
4. `git diff --check`。
5. Light 开源合规检查。
6. 若触碰 FFI，仅在 Task 3 不需要 FFI 的前提下避免 native 变更；如后续传输任务触碰 FFI，再执行 Rust/native 全套测试。

### 38451 实机验收矩阵

**本地备份：**

- 创建含主机、中继、SSH 密钥、2FA 的备份；保存后立即重新选择；
- 恢复成功、恢复取消、损坏文件、旧 v1/v2 文件、含云分布式删除标记的文件；
- 恢复后确认本地数据出现一次刷新且没有自动上传。

**RustDesk 中继配置：**

- 打开添加 RustDesk 中继二级界面；点击“粘贴配置密钥”；不授予剪贴板权限；手动填入官方导出串；点击解析；确认所有字段回填；保存并测试连接；
- 解析失败时输入弹窗不闪退、不清空、不改写原表单；
- 文件导入和手动粘贴结果一致。

**设备密码：**

- 直连、普通中继、Pro 地址簿各测试一次性密码/永久密码；
- 鉴权成功后杀后台冷启动，重新连接验证密码仍在；
- 鉴权失败、取消、超时、请求批准拒绝后确认密码没有被保存；
- 云端旧回调、手动推送、启动拉取后确认新密码不回退；
- 保存失败注入时确认页面明确提示，且数据库不存在半条更新记录。

## 六、停止条件

- 发现任何云表 schema 变化或未知列错误，立即停止并回到白名单适配。
- 备份恢复失败但原数据无法完整回滚，停止后续迁移。
- 新密码在 `passward` 已成功写入后又被扩展/云回调覆盖，停止并先修复所有权边界。
- 任何无剪贴板权限设备仍被要求读取系统剪贴板，停止 UI 合并。
- Pro 账号登录密码、access token、设备密码出现在日志、普通 Preferences、未加密备份或云端 metadata，立即停止并清理泄漏路径。

## 七、提交边界

建议拆成三个可回滚 checkpoint：

1. `fix(backup): normalize distributed rows and complete local backup io`
2. `fix(rustdesk): replace clipboard import with manual config paste`
3. `fix(rustdesk): persist device passwords through one auth path`

每次只暂存本任务明确文件；不提交 `.appanalyzer/`、签名产物、用户备份文件或其他未提交功能改动。
