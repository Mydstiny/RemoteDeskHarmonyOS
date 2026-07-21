# RDP 三种认证模式升级计划

> 状态：阶段 1-4 已实现并完成自动化验证；阶段 5 的 Windows/HarmonyOS 实机矩阵仍待验收
>
> 日期：2026-07-20
>
> 适用范围：RemoteDeskHarmonyOS 现有 RDP 添加、连接、云同步、本地备份链路

## 1. 结论先行

用户反馈对应两类不同能力，不能把它们都当作“密码为空”：

| 模式 | 目标端条件 | 客户端实际凭据 | 可行性 | 结论 |
| --- | --- | --- | --- | --- |
| 普通密码/Windows 凭据 | 现有 RDP/NLA 条件 | 用户名 + 密码，或现有 `RdpCredential` | 已支持 | 保持兼容，不改变现有语义 |
| 空密码本地账户 | 本地账户密码为空，并允许空密码远程登录 | 用户名 + 空字符串密码 | 可实现 | 增加独立模式；不能把历史漏填密码自动识别为空密码 |
| Restricted Admin | 目标端开启 `DisableRestrictedAdmin=0`，并满足管理员、NTLM、策略等条件 | NTLM Hash，或经过验证的空密码 NTLM Hash | 条件可实现 | 增加第三模式，但不能承诺“只输入用户名” |

核心判断：

1. 空密码本地账户可以沿用普通 NLA/NTLM 连接路径，只需要允许密码长度为 0，并在 UI、模型和校验层将其与“未填写密码”区分开。
2. `DisableRestrictedAdmin=0` 只是 Windows 目标端的开关。Windows `mstsc /restrictedadmin` 能够使用当前 Windows 会话中的凭据材料；HarmonyOS 客户端没有该 Windows 会话的 token、LSA 凭据或 NTLM Hash，不能泛化复制这种“输入用户名但不输入密码”的行为。
3. FreeRDP 已有 `/restricted-admin` 与 `/pth:<NTLM Hash>` 能力，因此 Restricted Admin 可以做成“显式输入 NTLM Hash”的第三种模式。Hash 等价于高敏感凭据，第一版默认只做本机加密存储，不进入云端。
4. Restricted Admin 失败时不得自动降级到普通密码或空密码模式，否则会造成错误的凭据尝试和不可解释的安全边界。

因此本计划的产品承诺是：

> 支持普通密码、空密码本地账户，以及基于用户提供 NTLM Hash 的 Restricted Admin；不承诺从 HarmonyOS 自动读取 Windows 当前用户凭据，也不承诺仅凭用户名登录普通有密码账户。

## 2. 目标与非目标

### 2.1 目标

- 在 FAB 添加 RDP 主机的现有流程中提供三个清晰的认证入口。
- 保留现有手动账号密码和 Windows 凭据管理器行为。
- 支持空密码本地账户的显式保存和连接。
- 支持 Restricted Admin 的显式模式、NTLM Hash 输入、空密码 Hash 来源和错误提示。
- 让认证模式元数据跨设备同步，但让 Restricted Admin Hash 只留在本机。
- 复用现有 `CloudStore`、`CloudTableAdapter`、`DataCrypto`、`localextensions`、`LocalBackupService` 和 RDP NAPI/FreeRDP 链路。
- 老主机默认仍按普通密码模式解释，老版本不会把 Hash 当成普通密码发送。
- 在真实 FreeRDP HAP 和 Windows 目标机上完成可重复验收。

### 2.2 非目标

- 不由客户端远程修改 Windows 注册表或组策略。
- 不从 HarmonyOS 获取 Windows 登录 token、LSA Secret、SAM、当前会话 NTLM Hash 或 Kerberos TGT。
- 不实现 Credential Guard、Remote Credential Guard、智能卡、证书登录或 Kerberos SSO。
- 不通过关闭 NLA、放宽所有 NTLM 策略或绕过 Windows 权限来“修复”认证失败。
- 不把 NTLM Hash 放入 `remotehosts.passward`、`rdpcredentials.password`、`displayconfig` 明文扩展、云端 `usersettings` 或日志。
- 不为本功能新增云表、云服务 API 或另一套密码存储系统。

## 3. 三种模式的精确定义

建议新增两个受限枚举，避免用空字符串推断认证方式：

```text
RdpAuthMode:
  password          普通密码/Windows 凭据
  blank_password    空密码本地账户
  restricted_admin  Restricted Admin

RdpRestrictedAdminSecretSource:
  empty_password_hash  使用经过验收的空密码 NTLM Hash
  ntlm_hash            使用用户输入的 NTLM Hash
```

### 3.1 `password`

- 手动输入用户名和密码，沿用当前 `RemoteHost.username/password`。
- 选择已有 `RdpCredential`，沿用当前 `rdpCredentialId` 解析逻辑。
- 继续使用当前的域名、Microsoft Account/AzureAD 用户名规范化逻辑。
- 该模式是所有旧记录和无效未知模式的兼容默认值。

### 3.2 `blank_password`

- 用户名必填，密码字段不显示或明确显示为“空密码”。
- `password` 必须是空字符串，`rdpCredentialId` 必须为空。
- 只允许目标为本地账户；域账户、Microsoft Account、AzureAD 账户不应在此模式下被误导使用。
- 连接仍走普通 NLA/NTLM 路径，不打开 Restricted Admin。
- “密码为空”是用户的明确选择，不等价于密码输入框未填写。

### 3.3 `restricted_admin`

- 用户名必填，密码输入框不提供普通密码登录语义。
- 客户端显式请求 Restricted Admin；目标端必须支持并允许该模式。
- `ntlm_hash` 来源要求 32 位十六进制 NTLM Hash，输入时允许大小写但保存前统一规范化，不接受长度不符或非十六进制字符。
- `empty_password_hash` 来源只适用于已确认目标账户密码为空的场景。常量 Hash 由 native 侧 fixture/实现确认，不依赖用户手工输入。
- 普通有密码账户如果只有用户名而没有 Hash，连接必须阻止并提示重新输入 Hash；不能把普通密码模式的密码字段偷偷复用为 Restricted Admin 凭据。

## 4. Windows 目标端前置条件

客户端只负责选择认证协议和传递凭据，不能替目标端完成下面的配置。产品帮助页和错误提示应明确这些条件。

### 4.1 三种模式共同条件

- 目标机开启 Remote Desktop，防火墙和网络路径允许目标端口，默认是 TCP 3389。
- 用户拥有“允许通过远程桌面服务登录”权限，或属于 Remote Desktop Users/Administrators 等允许组。
- 用户名格式与目标账户类型一致。对于本地账户，优先使用 `HOST\user` 或 `.\user` 的明确形式，并复用现有域名解析逻辑。
- 证书校验、NLA、网关和主机名策略仍沿用现有 RDP 设置。
- 不能因为认证失败就建议用户关闭 NLA；NLA 关闭应作为单独的实验变量验收。

### 4.2 空密码本地账户

Windows 本地安全策略“帐户：使用空密码的本地帐户只允许进行控制台登录”默认会阻止空密码网络/RDP 登录。目标机需要在组策略/本地安全策略中允许该账户进行远程登录，常见注册表表现为：

```text
HKLM\SYSTEM\CurrentControlSet\Control\Lsa\LimitBlankPasswordUse = 0 (DWORD)
```

该设置会降低目标机安全性，不能由客户端静默修改。还需要确认：

- 账户确实是本地账户且密码为空；
- 账户具备 RDP 登录权限；
- 目标版本的 NLA/NTLM 对空密码的实际行为与实验结果一致；
- 域策略或安全基线没有在下次刷新时恢复限制。

### 4.3 Restricted Admin

目标机通常需要允许 Restricted Admin：

```text
HKLM\SYSTEM\CurrentControlSet\Control\Lsa\DisableRestrictedAdmin = 0 (DWORD)
```

`DisableRestrictedAdmin=0` 不代表客户端可以只提供用户名。还需要确认：

- 目标 Windows 版本和 RDP 服务支持 Restricted Admin；
- 目标账户通常需要具备管理员权限；
- 目标端 NTLM 没有被组策略、Credential Guard 或安全基线禁止；
- RDP/NLA/防火墙/用户权利条件均满足；
- 如果使用 `ntlm_hash`，Hash 与用户名、域和目标账户完全匹配；
- 如果使用空密码 Hash，目标账户确实为空密码，且空密码策略也允许远程登录。

必须在 Windows 测试机上分别记录：普通 `mstsc`、`mstsc /restrictedadmin`、FreeRDP `/restricted-admin`、FreeRDP `/pth` 的结果。不能仅因 MSTSC 成功，就推断第三方客户端可凭用户名成功。

## 5. 当前代码审计结论

现有入口和链路可复用，但需要补齐认证模式字段：

| 层级 | 当前情况 | 需要的升级 |
| --- | --- | --- |
| FAB/添加页 | `HostListPage.ets` 进入 `HostProtocolPicker`，RDP 再进入 `RdpAddFlow.ets`；当前只有账号密码和 Windows 凭据 | 在 RDP 认证区域扩展为三个模式，现代和经典入口共用相同校验 |
| 主机模型 | `RemoteHost` 有 `username/password/rdpCredentialId`，验证要求用户名或凭据且密码不能空 | 增加非敏感 `rdpAuthMode` 和 `rdpRestrictedAdminSecretSource`；按模式验证 |
| 会话配置 | `SessionConfig` 目前没有 RDP 认证模式或 Hash | 增加可选的瞬时认证字段，旧调用默认普通模式 |
| NAPI | `extension_loader_napi.cpp` 负责 ArkTS 到 native 的配置解析 | 增加模式、Hash 来源、Hash 格式校验和兼容默认值 |
| native 配置 | `ConnectionConfig` 已有用户名、密码、域和 RDP 身份规范化字段，但没有独立 RDP 认证模式 | 增加专用字段，不复用 SSH 的 `authMethod` |
| FreeRDP | 当前普通路径显式关闭 Restricted Admin；源码已经有 `RestrictedAdminModeRequired`、`PasswordHash`、`/restricted-admin` 和 `/pth` 支持 | 仅在 Restricted Admin 模式启用相应设置，保留普通模式隔离 |
| 云同步 | `CloudTableAdapter` 已有 `remotehosts.displayconfig` 扩展和 `_remoteDeskExtensionV1`；`localextensions` 不参与云分布表 | 模式元数据投影到既有云扩展，Hash 使用现有本地扩展表 |
| 加密 | `DataCrypto` 已为主机密码、凭据和扩展提供加密/锁定状态 | 复用 `DataCrypto.encrypt/isReady/lock`，不新建密钥体系 |
| 备份 | `LocalBackupService`/`CloudStore` 已能导出、恢复整表和 `localextensions` | 让加密 Hash 行随既有 extensions 备份，不增加顶层备份结构 |

注意：当前的 `rdpAuthIdentityMode` 是用户名/域名规范化设置，不是本计划的认证模式，不能用它承载 `password/blank_password/restricted_admin`。

## 6. FAB 添加入口与交互设计

### 6.1 入口结构

保持现有入口：

```text
FAB → 添加主机 → RDP → RDP 连接信息 → 认证方式（三个入口）
```

在 `RdpAddFlow.ets` 的“认证方式”区域改为三个等宽卡片或分段按钮：

1. **普通密码/凭据**
2. **空密码本地账户**
3. **Restricted Admin**

不在 `HostProtocolPicker` 增加三个 RDP 协议，避免用户误以为是三种不同远程协议；三项属于 RDP 的认证方式。

### 6.2 普通密码/凭据页面

保持当前能力：

- 子选项“手动账号密码”和“Windows 凭据”；
- 复用当前 `RdpCredential` 列表、添加凭据按钮和凭据解析；
- 手动输入时用户名必填、密码按当前规则校验；
- 进入其他模式时清空 `credentialId`，避免把旧凭据绑定带到新模式。

### 6.3 空密码本地账户页面

- 显示用户名输入框，提示“本地用户名或 HOST\用户名”。
- 密码输入框隐藏；在表单中显示只读状态“密码：空”。
- 显示警告：“目标机必须允许空密码本地账户通过远程桌面登录；客户端不会修改目标机策略。”
- 保存前要求勾选确认：“我确认这是目标机上的本地空密码账户”。
- 用户名为空、勾选未确认、主机地址/端口不合法时阻止保存。
- 连接按钮使用普通 NLA/NTLM 连接，不携带 Restricted Admin 标志。

### 6.4 Restricted Admin 页面

- 显示用户名输入框和可选域/用户名提示。
- 显示“凭据来源”二选一：
  - “目标账户为空密码（使用空密码 Hash）”；
  - “输入 NTLM Hash”。
- Hash 输入使用密码控件，提供显示/隐藏切换；粘贴后立即做 32 位十六进制校验，不在日志或错误文本中回显。
- 显示明确说明：
  - “目标机还需要 `DisableRestrictedAdmin=0`。”
  - “普通密码不能代替 NTLM Hash。”
  - “Hash 只保存于本机加密存储，不同步到云端；换设备需要重新输入。”
- 默认勾选“保存到本机（加密）”。如果 `DataCrypto` 未解锁，保存 Hash 前先要求解锁；也可以允许“仅本次连接”，连接发起后清除内存副本。
- 保存/连接前要求确认用户理解 Restricted Admin 只适用于目标端支持的账户和策略。

### 6.5 编辑、列表和连接前行为

- 旧主机没有 `rdpAuthMode` 时显示为普通密码模式。
- 主机列表可显示非敏感徽标：`密码`、`空密码`、`Restricted Admin`。
- 空密码模式不显示密码缺失错误。
- Restricted Admin 主机如果本机没有 Hash，只显示“需要重新输入 NTLM Hash”，不得静默尝试空密码或普通密码。
- 编辑时切换模式立即清理互斥字段：

| 切换到 | 处理 |
| --- | --- |
| 普通密码/凭据 | 允许绑定 `rdpCredentialId` 或输入密码；删除 Restricted Admin 本地 Hash |
| 空密码本地账户 | 清空 `password` 和 `rdpCredentialId`；删除 Restricted Admin 本地 Hash |
| Restricted Admin | 清空 `password` 和 `rdpCredentialId`；保存 Hash 或要求连接前输入 |

## 7. 数据模型与兼容迁移

### 7.1 `RemoteHost` 非敏感字段

在 `entry/src/main/ets/model/RemoteHost.ets` 增加：

```text
rdpAuthMode: 'password' | 'blank_password' | 'restricted_admin'
rdpRestrictedAdminSecretSource: 'empty_password_hash' | 'ntlm_hash'
```

推荐默认值：

```text
rdpAuthMode = 'password'
rdpRestrictedAdminSecretSource = 'ntlm_hash'
```

这两个字段可以进入 `RemoteHostJSON`，但 Restricted Admin Hash 不进入 `RemoteHostJSON`、`toJSON()` 或任何通用主机对象。

### 7.2 本机敏感字段

不要在 `RemoteHost` 上持久化 `rdpRestrictedAdminHash`。使用现有 `localextensions` 表增加一个逻辑记录，例如：

```text
tablename = 'rdprestrictedadminsecrets'
recordid  = RemoteHost.id
payload   = {
  scheme: 'ntlm',
  secret: DataCrypto.encrypt(hash),
  binding: <host/user/domain 的本机绑定指纹>
}
```

要求：

- `secret` 始终是 `DataCrypto` 加密结果，不能保存明文 Hash。
- `binding` 用于目标地址、端口、用户名或域发生变化时使 Hash 失效，防止旧 Hash 被误用于新账户。
- `localextensions` 行与云表记录解耦，不能加入 `setDistributedTables` 或 `CloudTableAdapter` 的云字段投影。
- 删除主机、切换出 Restricted Admin、修改用户名/域/目标地址时删除或作废该行。
- 连接时只创建 `SessionConfig` 的瞬时 Hash 字段；连接启动后尽快清理 ArkTS/native 临时副本。

如果实现选择沿用现有 remotehosts 扩展行，而不是单独的逻辑 `tablename`，必须改为“读取后合并写入”，不能让普通主机保存动作覆盖 Hash；单独逻辑行更容易避免这一类丢失。

### 7.3 迁移规则

- 缺少 `rdpAuthMode` 的历史记录一律为 `password`。
- 历史记录“用户名存在但密码为空”不能自动改成 `blank_password`，因为可能是旧版本保存的不完整记录。
- 非法模式值回退为 `password`，记录脱敏迁移日志。
- `blank_password`/`restricted_admin` 记录如果仍有 `rdpCredentialId`，加载时标记为冲突并清理，不允许两种凭据同时生效。
- Restricted Admin 模式元数据可以从云端恢复；本地 Hash 不存在时，记录保持模式但连接必须阻止并要求重新设置。
- 迁移不改变既有普通密码、`RdpCredential`、证书信任、网关和显示配置。

## 8. ArkTS → NAPI → FreeRDP 连接链路

### 8.1 ArkTS 解析顺序

在 `RemoteDesktop.ets` 中按以下顺序构造会话：

1. 读取主机模式，缺失时设为 `password`。
2. 只有 `password` 模式才解析 `rdpCredentialId` 并覆盖用户名/密码。
3. `blank_password` 强制 `password=''`，拒绝凭据 ID，保留用户名和域规范化结果。
4. `restricted_admin` 从本机 `localextensions` 读取并解密 Hash；若来源为 `empty_password_hash`，生成受控的空密码 Hash；若 Hash 缺失、DataCrypto 锁定或绑定不匹配，返回本地错误，不调用 native。
5. 构造 `SessionConfig`，传递模式和瞬时 Hash；连接返回后清除 UI 状态和临时 Hash。

建议扩展 `SessionConfig`：

```text
rdpAuthMode?: 'password' | 'blank_password' | 'restricted_admin'
rdpRestrictedAdminSecretSource?: 'empty_password_hash' | 'ntlm_hash'
rdpRestrictedAdminHash?: string       // 仅连接期间存在，不序列化
```

这些字段全部可选，旧调用缺失时按普通密码处理。

### 8.2 NAPI 与 native 配置

修改：

- `entry/src/main/ets/types/rdpnapi.d.ts`
- `entry/src/main/cpp/extensions/extension_loader_napi.cpp`
- `entry/src/main/cpp/extensions/protocol_adapter.h`

在 `ConnectionConfig` 中使用 RDP 专用字段，不复用 SSH 的 `authMethod`：

```text
rdpAuthMode
rdpRestrictedAdminSecretSource
rdpRestrictedAdminHash   // 仅 native 连接上下文，不能写日志/持久化
```

NAPI 层需要：

- 对模式做白名单校验；
- 对 Restricted Admin Hash 做 32 位十六进制校验；
- 对普通/空密码模式拒绝不应出现的 Hash；
- 缺少新字段时保持旧版本兼容；
- 返回稳定的错误码，不把底层 Hash 或密码放进错误详情。

### 8.3 FreeRDP 设置映射

以 vendored FreeRDP 当前版本为准，映射目标如下：

| 模式 | FreeRDP 关键设置 |
| --- | --- |
| `password` | `FreeRDP_Username`、`FreeRDP_Password`；`RestrictedAdminModeRequired=false`；保持现有 NLA/TLS/NTLM 配置 |
| `blank_password` | `FreeRDP_Username`、`FreeRDP_Password=""`；`RestrictedAdminModeRequired=false`；不因空密码改动全局安全策略 |
| `restricted_admin` | `FreeRDP_Username`、`FreeRDP_PasswordHash`；`RestrictedAdminModeRequired=true`；按 FreeRDP 版本要求设置 `ConsoleSession=true` 和 `RestrictedAdminModeSupported` |

实现注意：

- Restricted Admin 模式下不能同时把普通明文密码写入 `FreeRDP_Password`，避免误走普通 NLA。
- 当前普通路径的 `RestrictedAdminModeRequired=false`、`RestrictedAdminModeSupported=false` 不能无条件复制到第三模式；需要在真实 FreeRDP 版本上确认 `Supported` 的客户端语义后，仅按模式设置。
- `RemoteCredentialGuard`、`DisableCredentialsDelegation` 不在本次范围内，不得为了“看起来像 MSTSC”而全局打开。
- 保持现有 `AuthenticationPackageList="ntlm"` 的 HarmonyOS 限制，但 Restricted Admin 必须验收 NTLM 被目标策略允许的情况。
- FreeRDP 失败时记录模式、来源、Hash 长度和脱敏主机，不记录 Hash、密码或完整用户名。

## 9. 云同步策略：只同步模式，不同步 Restricted Admin Hash

### 9.1 不新增云结构

继续复用：

- `CloudTableAdapter.ets` 的 `remotehosts` 云表列；
- 现有 `displayconfig` JSON 扩展容器 `_remoteDeskExtensionV1`；
- `CloudStore` 的 `hostExtensionValues`、`hostExtensionFromResult`、`mergeHostExtension`、`absorbCloudHostExtension`；
- `CloudSyncCoordinator` 既有推送/接收流程；
- `localextensions` 作为不参与云分布表的本地数据。

### 9.2 云端只放非敏感元数据

将下面两个字段加入 `REMOTE_HOST_CLOUD_EXTENSION_COLUMNS`，使用小写稳定键名：

```text
rdpauthmode
rdprestrictedadminsecretsource
```

同步流程：

1. `CloudStore.hostExtensionValues()` 生成模式元数据。
2. `projectRemoteHostCloudExtension()` 只投影上述非敏感字段到已有 `displayconfig` 扩展。
3. `encodeRemoteHostDisplayPayload()` 保留现有显示配置和未知扩展兼容行为。
4. 云端接收后 `decodeRemoteHostDisplayPayload()` 和 `absorbCloudHostExtension()` 恢复模式。
5. Hash 只通过本地逻辑扩展行读写，不进入云行、不参与云冲突合并。

不要把 `rdprestrictedadminhash` 加入 `REMOTE_HOST_CLOUD_EXTENSION_COLUMNS`。现有云端加密不能替代“不上传”的边界；一旦旧版本把未知字段当普通密码，风险不可接受。

### 9.3 跨设备行为

| 场景 | 预期行为 |
| --- | --- |
| 普通模式同步 | 继续复用 `rdpcredentials`、现有密码加密和凭据 ID |
| 空密码模式同步 | 同步用户名和 `blank_password` 模式；新设备可直接尝试空密码，但仍受目标策略限制 |
| Restricted Admin 同步到新设备 | 同步模式和 Hash 来源，不同步 Hash；首次连接提示重新输入 Hash或选择空密码 Hash |
| 本机有 Hash，云端只更新显示配置 | 保留本机 Hash |
| 云端改变主机地址/端口/用户名/域 | 清除或作废绑定不匹配的本机 Hash |
| 旧客户端读取新模式记录 | 未知模式扩展被忽略，按旧逻辑视为普通模式；因密码为空通常会失败/阻止，不会收到 Hash |
| 旧客户端重新保存该主机 | 可能丢失未知模式元数据，这是既有 displayconfig 扩展的版本兼容风险；新版本应在 UI 标记“仅支持新版本编辑”并在发布说明中声明 |

旧版本兼容的安全底线是：新模式不能把 Hash 放入旧版本会读取的 `passward` 或 `password` 字段。功能兼容可以失败，秘密泄露不能发生。

## 10. 本地存储和 DataCrypto 策略

### 10.1 普通密码

- 继续使用当前 `RemoteHost.password` 和 `RdpCredential.password` 的既有加密/解密路径。
- 不改变现有凭据 ID、云同步协调和解锁行为。

### 10.2 空密码

- 本地只保存明确的 `rdpAuthMode=blank_password` 和空密码状态。
- 不把空密码转换为特殊占位字符串；空字符串是连接配置的合法值，但只有在该模式下合法。
- 不把空密码误写入 `RdpCredential` 作为普通凭据。

### 10.3 Restricted Admin Hash

- 使用 `DataCrypto.encrypt()` 后写入 `localextensions` 的 Restricted Admin 逻辑记录。
- 保存前检查 `DataCrypto.isReady()`；锁定时不写明文、不降级为普通密码。
- 连接前解密到最小作用域的临时变量；连接启动后清理 UI 输入和可清理的 native 副本。
- 主机删除、模式切换、目标身份变化、用户明确删除凭据时删除该本地记录。
- DataCrypto lock/reset 之后，旧密文不可解密时显示“需要重新输入 Hash”，不尝试用密文连接。
- 诊断、日志、崩溃上下文、截图和云同步 payload 均不得包含 Hash。

## 11. 本地备份与恢复

继续复用 `LocalBackupService.ets` 和 `CloudStore` 的整表快照/`extensions` 机制，不新增顶层备份对象。

- `RemoteHost` 的认证模式和 Hash 来源随主机 JSON/既有扩展备份。
- Restricted Admin Hash 以 `DataCrypto` 加密后的 `localextensions` 行进入备份；备份文件中不出现明文 Hash。
- 现有备份若有 `extensions` 数组，恢复时自动恢复该行；现有恢复流程会锁定 DataCrypto，恢复后必须重新解锁才可使用。
- v1/历史备份没有模式字段时默认普通密码，没有 Hash 时不能假设 Restricted Admin 可用。
- 恢复时进行完整性校验、整批回滚和“不自动推云”，沿用现有行为。
- 测试必须断言：备份 JSON/压缩包的结构中没有新增明文 `rdpRestrictedAdminHash` 或 32 位 Hash 字段；只允许出现既有加密 payload。
- 只有在实现不得不增加顶层字段时才提高备份版本；优先保持现有版本和兼容逻辑不变。

## 12. 错误码、提示和日志

建议增加稳定的 RDP 认证诊断码，底层错误详情只作为本地脱敏信息：

| 诊断码 | 用户提示 |
| --- | --- |
| `RDP_AUTH_SECRET_REQUIRED` | 此 Restricted Admin 主机需要在本机重新输入 NTLM Hash |
| `RDP_AUTH_HASH_INVALID` | NTLM Hash 必须是 32 位十六进制字符 |
| `RDP_AUTH_CRYPTO_LOCKED` | 请先解锁本地凭据存储 |
| `RDP_BLANK_PASSWORD_POLICY` | 目标机拒绝空密码远程登录，请检查 LimitBlankPasswordUse 和 RDP 登录权限 |
| `RDP_RESTRICTED_ADMIN_DISABLED` | 目标机未开启 Restricted Admin，或被组策略禁止 |
| `RDP_RESTRICTED_ADMIN_NOT_SUPPORTED` | 目标 RDP 服务不支持 Restricted Admin |
| `RDP_RESTRICTED_ADMIN_NTLM_BLOCKED` | 目标安全策略阻止 NTLM/Hash 登录 |
| `RDP_AUTH_IDENTITY_MISMATCH` | 当前 Hash 与主机、用户名或域不匹配，请重新设置 |
| `RDP_AUTH_MODE_CONFLICT` | 主机认证模式与保存的凭据冲突，请重新选择认证方式 |

日志允许记录：

- 模式名称；
- secret source 名称；
- Hash 长度是否为 32；
- 主机脱敏值、用户名脱敏值、域脱敏值；
- `passwordLen` 等现有非秘密统计值。

日志禁止记录：

- 明文密码；
- NTLM Hash；
- 完整连接配置 JSON；
- 可逆的 Hash 派生值或用户复制的原始凭据。

## 13. 分阶段实施计划

### 阶段 0：FreeRDP 可行性 POC（先于 UI）

交付：

- 用当前 vendored FreeRDP 验证普通密码、空密码、Restricted Admin Hash 三条 native 配置路径。
- 确认 `FreeRDP_PasswordHash`、`RestrictedAdminModeRequired`、`RestrictedAdminModeSupported`、`ConsoleSession` 的确切语义和版本条件。
- 在真实 Windows 目标机上完成 `mstsc /restrictedadmin` 对照和 FreeRDP `/pth` 对照。
- 确认空密码 Hash 在真实目标机上的行为；如果失败，不把 `empty_password_hash` 宣称为已支持，只保留普通空密码模式。

门禁：必须使用真实 RDP HAP 配置（当前 `entry/build-profile.json5` 的 `USE_REAL_FREERDP=ON`），不能用 native skeleton 测试结果替代。

### 阶段 1：数据契约与迁移

修改范围：

- `entry/src/main/ets/model/RemoteHost.ets`
- `entry/src/main/ets/services/CloudTableAdapter.ets`
- `entry/src/main/ets/services/CloudStore.ets`
- `entry/src/main/ets/services/DataCrypto.ets`（仅在需要暴露现有能力时，优先不改算法）
- `entry/src/main/ets/services/LocalBackupService.ets`（优先只补测试/调用）

交付：模式枚举、JSON 默认值、互斥字段清理、云扩展投影、本地密文行、绑定失效和备份兼容。

### 阶段 2：现代/经典 UI

修改范围：

- `entry/src/main/ets/components/hostadd/RdpAddFlow.ets`
- `entry/src/main/ets/pages/HostListPage.ets`
- 现有主机编辑/校验共用路径

交付：FAB RDP 添加页三入口、三种动态表单、确认提示、编辑迁移、Hash 脱敏输入、缺失 Hash 连接前提示。现代和经典添加/编辑入口必须使用同一模式和校验函数，不能出现一边允许空密码、另一边仍拒绝的分叉。

### 阶段 3：ArkTS/NAPI/native 连接链路

修改范围：

- `entry/src/main/ets/pages/RemoteDesktop.ets`
- `entry/src/main/ets/types/rdpnapi.d.ts`
- `entry/src/main/cpp/extensions/extension_loader_napi.cpp`
- `entry/src/main/cpp/extensions/protocol_adapter.h`
- `entry/src/main/cpp/rdp/freerdp_adapter.cpp`

交付：模式解析、临时 Hash 注入、FreeRDP 三路径映射、稳定诊断码、无自动降级、日志脱敏和临时数据清理。

### 阶段 4：同步/备份与兼容回归

交付：

- 同步只投影两个非敏感模式字段；通过代码审查和测试确认 Hash 不在云 payload。
- 新设备同步 Restricted Admin 主机时正确进入重新设置流程。
- 本地备份/恢复保留加密 Hash，并在 DataCrypto 未解锁时阻止连接。
- 旧版本读取新记录时不把 Hash 当成普通密码。

### 阶段 5：真实设备验收与发布门禁

交付：Windows 版本/策略矩阵、真实 HarmonyOS HAP 连接矩阵、日志脱敏审计、用户帮助文案、回滚演练。未完成真实 HAP 首帧/重连验收前，不将 Restricted Admin 标为正式支持。

### 13.1 本次实施记录（2026-07-21）

- 阶段 1 已落地：`RemoteHost` 的模式/来源兼容默认值、互斥字段清理、现有云扩展中的非敏感投影，以及 `localextensions` 内本机加密的 Hash 与目标身份绑定。
- 阶段 2 已落地：现代 FAB 的 RDP 添加流程和经典添加/编辑 Sheet 均提供普通密码/凭据、空密码本地账户、Restricted Admin 三个入口；既有 Hash 永不回显，修改目标身份时要求重新输入。
- 阶段 3 已落地：ArkTS 会话只在 Restricted Admin 模式按需读取本机 Hash，NAPI 使用白名单策略解析，FreeRDP 设置 `PasswordHash`、`ConsoleSession` 和 Restricted Admin 标志；普通/空密码模式不携带 Hash，连接调用后清除 ArkTS 临时副本。
- 阶段 4 已落地：云端只同步 `rdpauthmode` 和 `rdprestrictedadminsecretsource`，Hash 不进入云 payload；本地扩展沿用既有备份/恢复路径。
- 自动验证：ArkTS 测试编译、主机 native 测试 `114/114`、双 ABI 生产 HAP 和 Light 合规门均通过。增量并行 daemon HAP 曾在 Hvigor `DoNativeStrip` 遇到工具链内部 `00308018`；同一源码以非 daemon 构建成功。
- 未完成项：在真实 Windows 目标机完成三种模式的登录、首帧、断线重连、目标策略错误与同步/备份恢复矩阵前，Restricted Admin 仍只能标记为待实机验收能力。

## 14. 测试与验收矩阵

### 14.1 ArkTS/模型/同步单元测试

- 缺少模式字段的旧 JSON 默认为 `password`。
- 非法模式、空用户名、空密码模式缺少确认、Restricted Admin Hash 非 32 位/非十六进制均被拒绝。
- 普通模式仍支持手动密码和现有 `RdpCredential`。
- 模式切换正确清理 `password`、`rdpCredentialId` 和本地 Restricted Admin secret。
- `displayconfig` 仅包含 `rdpauthmode`、`rdprestrictedadminsecretsource` 等非敏感扩展。
- 云端接收更新不会覆盖本机 Restricted Admin secret；身份绑定变化会失效。
- 云扩展缺失/未知时不崩溃，老记录仍可读取。
- DataCrypto 锁定、解密失败、重置后不会把密文送进连接配置。
- LocalBackup v1/v2 恢复、整批回滚、不自动推云和 Hash 密文检查。

### 14.2 Native/NAPI 测试

- NAPI 缺少新字段时生成普通密码配置。
- 三种模式的 `ConnectionConfig` 映射准确，SSH `authMethod` 不受影响。
- Restricted Admin 模式设置 `PasswordHash`，不设置明文 `Password`；普通/空密码模式不携带 Hash。
- Hash 校验、空密码 Hash fixture、模式冲突和诊断码映射。
- 普通模式 `RestrictedAdminModeRequired=false`；Restricted Admin 模式按 POC 结果设置 required/supported/console 字段。
- 连接日志不出现 Hash/密码。
- 保留现有 native 测试、双 ABI 和实际 FreeRDP 链接验收。

### 14.3 Windows + HarmonyOS 实机矩阵

至少覆盖：

1. 普通密码正确、错误；已有 `RdpCredential`；域/本地用户名格式。
2. 空密码本地账户 + `LimitBlankPasswordUse=0` 成功。
3. 空密码本地账户 + 默认限制失败，提示清晰。
4. Restricted Admin 目标 `DisableRestrictedAdmin=0`，Windows `mstsc /restrictedadmin` 对照成功。
5. Restricted Admin + 用户提供正确 NTLM Hash 成功；错误 Hash 失败且不降级。
6. Restricted Admin + 空密码 Hash 成功或被明确标记为当前版本不支持。
7. 非管理员账户、RDP 权限缺失、NLA 关闭、NTLM 被禁用、Credential Guard/域策略限制。
8. 云同步后模式保留、Hash 不泄露；新设备无 Hash 时阻止误连接。
9. 本地备份/恢复、DataCrypto 锁定/解锁/重置。
10. 修改主机地址、端口、域、用户名后旧 Hash 不再使用。
11. 旧版本读取新记录不会发送 Hash；旧版本写回造成的扩展丢失行为有发布说明和回归记录。
12. 真实生产 HAP 的首帧、重连、断开、错误恢复和日志采集。

## 15. 安全边界与发布要求

- NTLM Hash 按“等价于密码”管理，即使它本身不能直接反推出明文密码。
- Restricted Admin UI 必须显式说明“Hash 只保存在本机”；云同步设置页也要说明换设备需重新录入。
- 不能在诊断文件、截图、崩溃日志、开发者导出和云同步包中留下 Hash。
- 不能把 `DisableRestrictedAdmin=0` 包装成“客户端免密开关”；它是目标机安全策略改变，用户必须承担风险。
- 第一版不允许自动 fallback，不允许把空密码失败改用普通密码尝试。
- 目标机注册表/组策略变更必须由管理员按组织安全规范执行，帮助文案要提示风险和恢复方法。
- 只有在普通模式回归、空密码实机验收、Restricted Admin Hash 实机验收、同步/备份安全审计全部通过后，才可把三个入口从实验/灰度状态提升为正式能力。

## 16. Definition of Done

本功能完成必须同时满足：

- FAB RDP 添加页出现三个认证入口，现代和经典流程一致。
- 三种模式可以被保存、编辑、连接，旧主机默认普通密码。
- 普通密码和现有 Windows 凭据无回归。
- 空密码模式只在用户明确选择后允许空密码，并能给出目标策略失败提示。
- Restricted Admin 至少完成“用户输入 NTLM Hash”真实 HAP 连接验收；空密码 Hash 若未通过 POC，必须在 UI/文档中标记不支持，不得虚假宣称。
- `rdpAuthMode`/secret source 跨设备同步，Restricted Admin Hash 不进入云端。
- 加密 Hash 能随现有本地备份恢复，锁定/重置时 fail closed。
- NAPI/native/FreeRDP 日志和错误链路完成脱敏。
- ArkTS、native、双 ABI、真实 HAP、同步、备份和旧数据回归全部通过。
- 变更范围不新增云表、不新增密钥体系、不修改与本功能无关的用户已有文件。

## 17. 回滚方案

本设计采用“可选字段 + 默认普通密码 + 本地独立 secret 行”，因此可以安全回滚：

1. 关闭三个入口和新连接分支，旧代码读取主机时仍按普通密码默认值运行。
2. 保留云端未知扩展，不删除既有 `password`、`rdpCredentialId`、凭据和显示配置。
3. 回滚时不把 Restricted Admin Hash 搬回普通密码字段；必要时仅删除本机 `rdprestrictedadminsecrets` 逻辑行。
4. 若新版本已同步模式元数据，旧客户端最多表现为普通模式/密码缺失，不应拿到 Hash。
5. 发布前准备一次本地备份恢复演练，确认回滚不会破坏普通 RDP 主机。
6. 若 FreeRDP POC 证明 Restricted Admin 不适用于当前 HarmonyOS 构建，只发布普通密码 + 空密码本地账户，保留模式数据契约但隐藏 Restricted Admin 入口，待 native 依赖升级后再开启。
