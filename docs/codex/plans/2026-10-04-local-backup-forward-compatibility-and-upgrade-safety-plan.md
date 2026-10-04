# 本地备份前向兼容与升级安全计划

日期：2026-10-04。状态：**计划已落盘，待实施；本轮只写计划、复审并提交，不构建、不修改应用实现。**

## 1. 背景与已确认问题

当前完整备份失败不是文件系统写入失败，而是备份生成后的二次校验失败。导出链路在
[LocalBackupService.ets](../../../entry/src/main/ets/services/LocalBackupService.ets) 中先取得
一致的本地快照，调用 `createLocalBackupDocument`，写入私有暂存文件，再对暂存文件和
Picker 目标文件分别执行完整字节读取、字节比较和 `validateLocalBackupDocument`。

当前实现存在一条确定的生产字段缺口：

1. [CloudStore.ets](../../../entry/src/main/ets/services/CloudStore.ets) 的
   `hostCloudExtensionValues` 会写入 `lanaddressmode`、`landiscoveryidentity`、
   `lanlastresolvedat`。
2. [BackupManifestV3.ets](../../../entry/src/main/ets/services/BackupManifestV3.ets) 的完整模式
   会原样复制主机扩展 payload。
3. [LocalBackupPolicy.ets](../../../entry/src/main/ets/services/LocalBackupPolicy.ets) 的
   `validateLocalExtensions` 仍按 `REMOTE_HOST_EXTENSION_PAYLOAD_COLUMNS` 拒绝白名单之外
   的 payload key。
4. 这三个 LAN 字段不在该白名单中，所以只要某个主机扩展已保存这些字段，完整模式在
   暂存文件校验阶段就返回 `invalid_backup`，界面最终显示“备份文件格式或完整性校验失败”。
5. 脱敏模式先经过 `redactExtensionRows`，未知字段会被过滤掉，因此同一份数据可以成功
   导出；这解释了“脱敏正常、完整失败”的差异。

最小受控样本已经复现该差异：包含三个 LAN 字段的 `remotehosts` 扩展，脱敏文档校验通过，
完整文档校验失败。这个样本证明校验器过严，但不授权直接放宽所有安全边界。

## 2. 目标与不变边界

目标是让安全策略只阻止真正的安全或完整性问题，让未知但结构正确的未来字段继续被保存、
导出和升级后的版本读取；应用更新不得因为新版本不认识旧字段而丢失旧数据，也不得因为
旧版本留下的字段而阻塞当前版本的健康功能。

以下边界保持不变：

1. 完整备份仍然是用户明确选择的敏感导出；源已配置加密时保留密文和必要加密参数，
   未配置加密时明文导出仍需用户明确选择。
2. 脱敏备份不携带密码、私钥、TOTP、登录令牌、本机确认 marker 或未分类的未来敏感字段。
3. owner、store identity、scope generation、lease、文件哈希、manifest section 哈希、
   RDB 事务和恢复前再次校验继续 fail-closed；本计划不通过删除这些门禁来“修复”导出。
4. 设备信任、VNC/Moonlight 的设备绑定语义继续按现有策略处理；未知字段不得被错误解释成
   已确认的 trust 或配对身份。
5. 未知字段不得自动进入云同步协议。未被当前版本理解的 opaque 数据只在本地备份/本地
   兼容存储中保留，等有明确 schema 的版本接管。

## 3. 兼容性分类契约

将扩展字段从单一“白名单/拒绝”改成带安全含义的分类。分类注册表必须同时被生产者、
导出器、校验器和恢复器使用，避免再出现“写入端已新增字段、校验端忘记更新”的分裂。

| 字段类别 | 完整备份 | 脱敏备份 | 恢复与升级 |
|---|---|---|---|
| 已知敏感字段 | 保留原始密文/明文形态，按用户选择和加密契约处理 | 删除 | 只有通过现有密钥、owner 和格式校验后才可进入敏感存储 |
| 已知可迁移配置 | 保留 | 保留 | 按当前 schema 解释 |
| 已知设备信任/公开元数据 | 按既有设备信任策略保留 | 按现有脱敏策略保留 | 不生成本机确认状态，不自动扩大信任范围 |
| 未知但值为字符串、记录身份和 owner 正确的字段 | 原样作为 opaque 字段保留，记录数量和 schema 来源 | 默认删除，除非注册表明确标为可脱敏 | 保存在本地兼容表；新版本认识后再提升为正式字段 |
| 未知对象/数组、非字符串敏感值或不符合类型约束的字段 | 记录为受影响字段并阻止“完整成功”声明；原始本地数据保持不变 | 删除并记录脱敏计数 | 不猜测、不强制转换、不写入业务字段 |
| 记录 id、tablename、recordid、owner、payload JSON 不一致 | 拒绝该记录/该 artifact | 拒绝或按现有安全规则隔离 | 不自动归属当前账号，不清空目标数据 |

“完整备份成功”只在所有必需 section 和记录都通过完整性验证，或所有未知字段都已按
opaque 契约保留时成立。被隔离的记录不得被静默丢弃后仍显示完整成功；需要使用单独的
受影响计数和明确错误码。未知 key 本身不再作为安全错误，错误应落在类型、身份、owner、
认证或哈希边界上。

### 3.1 Opaque section 的落地格式

为避免把未认识字段偷偷塞回当前业务表，只有需要携带 opaque 字段时才生成备份格式
`version=4`；没有 opaque 字段的文档继续生成现有 v3，保持旧版本可读。v4 在现有文档外层
增加可选的 `opaque` 区段，结构固定为：

```text
opaque: {
  schemaVersion: 1,
  fields: [{
    table, recordId, owner, location: "row" | "payload",
    key, value, valueType: "string", sourceSchemaVersion
  }]
}
```

`fields` 按 `table + recordId + location + key` 排序后参加 canonical payload 和独立
`local:opaque` manifest section 的 SHA-256；外层 `sha256` 仍覆盖 manifest、已知字段、
扩展和 opaque 区段。manifest 增加可选的 `opaqueSchemaVersion`、`opaqueFieldCount` 和
`opaqueByteCount`，旧 v3 文档不增加这些字段。恢复只把 opaque 条目写入新的本地-only
`backupopaque` 兼容表（绑定 owner/store/generation、sourceSchemaVersion、sourceHash、
recordId、location、key、value），不写入分布式表、业务列、认证配置或 trust 状态。

每个 key 必须匹配 `^[a-z][a-z0-9_]{0,127}$`；table、recordId、owner 各不超过 256 字节；
单值不超过 64 KiB UTF-8；单记录 opaque 不超过 4 MiB；单个 artifact 的 opaque 不超过
8 MiB、4096 条，且仍受现有 32 MiB 总备份上限约束。超限返回独立的
`opaque_limit_exceeded`，不截断、不静默丢弃、不把结果标为完整成功。

旧版本遇到 v4 或 `opaque` 区段时，在任何写入前返回明确的“需要升级以读取未来字段”；
不得把已知部分导入后声称完整恢复。新版本继续完整读取 v1/v2/v3；v4 没有 opaque 时
也必须可以降级生成等价 v3 供旧版本使用。

## 4. 生产者与校验器的单一 schema 来源

新增一个只描述便携备份数据契约的 schema registry（名称和文件路径在实施时确定，建议
放在 `entry/src/main/ets/services/`），至少提供：

- 每张表及 `localextensions` 的已知列、整数列、owner 列和不可迁移列；
- 主机扩展字段的 `secret`、`safe`、`trust`、`device_local`、`opaque_forward` 分类；
- 当前应用写入字段的生产者清单；
- 当前版本能解释的字段版本和最早写入版本；
- 由 registry 生成或直接复用的导出、脱敏、校验和恢复规则。

实施时先把 `lanaddressmode`、`landiscoveryidentity`、`lanlastresolvedat` 纳入正确的
非敏感分类，并明确它们在脱敏备份中是否应保留。若产品决定它们属于可跨设备配置，加入
脱敏安全集合；若它们仍需设备本地语义，则完整备份保留、脱敏备份删除，但两种模式都
必须能通过合法性校验。

增加一项静态契约检查：扫描 `CloudStore` 等写入点的字段集合，与 registry 的生产者集合
比较；新增字段没有分类和兼容版本时，测试阶段失败，而不是等用户导出时失败。

## 5. 完整模式与脱敏模式的校验分层

校验顺序保持“外层结构 → section/行完整性 → 敏感策略 → 业务恢复适配”，但每层只判断
自己负责的风险：

1. **外层结构**：format、version、manifest、canonical hash、section hash、大小和读取
   完整性必须严格验证。
2. **行与身份**：id 唯一、tablename/recordid 绑定、owner 与当前 scope 一致、JSON 是
   对象、值类型符合字段类别；未知字符串字段可以进入 opaque 集合。
3. **敏感策略**：完整模式允许用户明确选择的敏感数据；脱敏模式对未分类字段默认按
   敏感处理，不因“当前版本不认识”而误把它当成安全配置。
4. **业务适配**：只有 registry 已知字段才能进入当前业务模型；opaque 字段留在兼容区，
   不参与连接、认证、云上传或设备信任判断。

`validateLocalExtensions` 不得再把“未知 key”与“伪造 owner/坏 JSON/错误类型/重复绑定”
混为同一个失败原因。诊断只记录脱敏后的表、阶段、字段名和计数，不记录 payload 值、
密码、token、地址或私钥。

## 6. 更新应用与老数据承接

升级路径必须区分“读取旧数据”“写入新字段”“降级到旧版本”三个问题：

1. **读旧数据**：v1/v2/v3 备份、旧 `passward`/扩展字段、旧 VNC/Moonlight section、
   旧 owner/空 owner 和旧加密参数按其原格式读取；缺少可选 section 是 no-op，不清空
   当前表。
2. **写新字段**：更新已知字段时采用 read-modify-write，保留同一 payload 中未认识的
   opaque 字段；不能用“当前版本已知字段全集”重建 payload 后把未来字段抹掉。
3. **迁移事务**：迁移携带 owner、store identity、generation、operation id、源修订和
   迁移 marker；主 RDB 内使用真实事务，Preferences/扩展使用现有持久回执和恢复门闩。
   迁移失败保留原始数据和旧 marker，不能写空值冒充迁移完成。
4. **新备份给旧版本**：若旧版本无法安全保留 opaque 字段，导入前必须明确报“不支持的
   扩展字段/需要升级”，不得静默导入已知部分后宣称完整恢复。
5. **旧备份给新版本**：新版本接受缺失字段并使用默认/NULL 语义；旧字段只有在 owner、
   认证和格式验证通过后才迁移，不因一条坏记录阻塞其他健康记录。
6. **旧 owner/空 owner**：v1/v2 只能先解析和展示来源，不能自动认领当前账号；只有用户
   明确确认 legacy owner adoption、当前 scope lease 有效且来源记录通过格式/哈希校验时，
   才能执行目标 owner 重绑。v3 的 foreign owner、空 owner 或 opaque owner 不匹配继续
   拒绝或隔离，不能通过默认值归属当前账号。
7. **账号与 app clone**：继续以 active scope lease 为准；更新或恢复过程中重新核对
   owner、store identity、storeInstanceId 和 generation，旧账号结果不能写入新账号。
8. **云边界**：未知 opaque 字段不自动进入现有云表或云 payload。若未来需要跨设备同步，
   先增加明确的云 schema、版本和兼容策略，再单独验收。

## 7. 原始数据、失败与恢复语义

- 导出是只读快照，不为了满足新白名单改写用户 RDB。
- 未知但结构合法的字段在完整模式中原样保存；校验失败不能通过“删字段再重算 hash”
  伪造完整备份。
- 顶层表行新增列和 `localextensions.payload` 新增 key 分开处理：v3 的既有已知列契约继续
  严格校验；v4 对 owner/身份正确、值为字符串的未来行列抽取到 `opaque.fields`，而不是
  直接放回当前表。未知表名、未知 owner 列或非字符串行列值不能自动抽取，必须隔离并给出
  不支持的 schema 错误。
- 单条数据损坏时保留源数据，返回包含表/阶段/字段类别的可诊断错误；不清空目标库，
  不把局部结果标成完整成功。
- 恢复时只合并文件中实际存在且通过 owner/lease/哈希验证的字段；缺表、空表和缺字段
  不删除本机数据。
- 任何从 opaque 升级为正式字段的迁移必须可重复、可回滚到原始 opaque 表示，并记录
  迁移版本和源 hash。

内部校验报告统一使用 `valid`、`valid_with_opaque`、`unsupported_version`、`invalid`、
`quarantined` 五类状态，并携带 `reasonCode`、`stage`、`table`、脱敏后的 `recordId`、
`unknownFieldCount`、`opaqueFieldCount`、`opaqueByteCount` 和 `quarantinedCount`。现有
布尔/nullable API 可以由该报告兼容包装，但 UI、诊断和恢复日志不得再把所有失败压成同一
个“格式或完整性错误”。

## 8. 实施分期

### P0：冻结契约与样本

- 固定当前 v1/v2/v3 备份 JSON、`localextensions`、加密开启/关闭/锁定、device-local
  与 Huawei-account scope 的去敏样本。
- 建立生产者字段清单，确认 LAN 三字段和其他历史/未来字段的来源、敏感级别与 owner 规则。
- 定义完整、脱敏、opaque、quarantine 四种验证结果，以及 UI/诊断错误码映射。

### P1：registry 与校验器

- 引入单一 registry，替换 `LocalBackupPolicy` 和备份 manifest 中重复的字段白名单。
- 让完整模式保留合法 opaque 字段；让脱敏模式默认删除未分类字段。
- 保留现有 hash、manifest、section、scope lease、owner 和加密门禁。
- 为写入生产者增加“字段必须已注册”的静态/主机测试。

### P2：升级和恢复适配

- 对 `CloudStore` 的扩展写入统一使用 registry，更新已知字段时保留未知 payload。
- 为旧备份、旧扩展、缺 section、旧加密参数、旧 owner 和 app clone 增加兼容适配与持久 marker。
- 将 opaque 字段写入 `backupopaque` 本地兼容表，禁止未经注册的云上传、连接认证和 trust 激活；
  同时加入 v4 解析、canonical hash、manifest section 和旧版本拒绝路径。

### P3：回归与故障注入

- 覆盖字段新增、字段未知、字段删除、key 顺序变化、重复 id、错误 owner、坏 JSON、非字符串
  值、旧 schema、未来 schema 和 hash/manifest 篡改。
- 覆盖导出中断、Picker 取消、短读/短写、重启、账号切换、scope generation 变化、迁移中断
  和恢复重试。
- 证明完整备份不会因合法未来字段失败，也证明不安全/损坏记录不会被静默放行。

### P4：设备和升级验收

- 在受控副本上用旧版安装数据执行旧版 → 当前版保留数据更新，不卸载、不重置、不重新 setup。
- 在 Phone/Pad/PC 与 app clone 组合中验证完整/脱敏导出、导入、重启、账号切换和恢复隔离。
- 用旧备份恢复到新版本，再用新版本读取和再次导出；验证未知字段仍在且没有进入云同步。
- 另行验证同账号云数据、加密锁定状态、VNC/Moonlight 可选表和协议连接数据，不把主机数量
  或导出成功当成秘密可用性证明。

## 9. 必须新增的验证用例

1. `remotehosts` 扩展包含三个 LAN 字段时，完整和脱敏文档都能按各自策略校验。
2. 完整模式包含一个未来字符串字段时，导出 → 校验 → 恢复 → 再导出保持 key/value 和 hash。
3. 脱敏模式遇到未知字段时不携带该值，且 manifest/section hash 仍正确。
4. 顶层表行未知列与 payload 未知 key 都能进入 v4 opaque section；未知表名、对象/数组、
   非字符串秘密、非法 JSON 或错误 owner 时，不静默放行、不清空源数据。
5. opaque section 的 key/值/记录/总量上限、manifest section hash、外层 canonical hash
   和 `backupopaque` 恢复回读均通过；超限返回 `opaque_limit_exceeded`。
6. 旧版本读取 v4 时在写入前明确返回需要升级；新版本读取 v1/v2/v3 文件缺失可选 section
   时恢复只合并实际存在字段。
7. 新版本更新已知字段时，旧/未来 opaque 字段不会被重建逻辑抹掉。
8. legacy owner/空 owner 只有显式 adoption 才能重绑；foreign owner 始终隔离或拒绝。
9. 加密 active/locked/disabled、明文明确同意、错误主密码和缺少 cryptoparams 各自进入
   正确的边界，不用一个通用“格式错误”掩盖。
10. 账号切换、app clone、store reopen 和 generation 变化不会让旧导出/恢复结果写入新 scope。
11. 生产者字段集合与 registry 闭包检查通过；不存在“生产者已写、校验器未识别”的差集。
12. 完整模式的合法扩展不再因为字段白名单过严失败；真正的完整性/身份/认证错误仍失败。

## 10. 完成条件与交付边界

计划实施完成前，不得声称完整备份已恢复或老版本升级已验收。实施交付至少需要：

- registry、导出/脱敏/校验/恢复四条路径使用同一分类来源；
- LAN 三字段的回归失败被关闭，且新增未来字段样本通过；
- 旧 v1/v2/v3、加密生命周期、scope lease、app clone 和更新保留数据样本通过；
- 真实 RDB/Picker 的字节完整性、恢复事务和失败后原始数据保留证据通过；
- 独立复审无 P0/P1/P2；
- 按变更范围执行当前 AGENTS 要求的测试编译、`assembleHap`、Light 合规和设备/升级验收。

本次只提交本计划文件。按用户要求，本轮不执行构建、签名、设备安装、数据迁移或代码修复。
