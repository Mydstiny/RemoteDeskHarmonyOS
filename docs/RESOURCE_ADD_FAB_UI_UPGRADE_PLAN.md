# 统一资源添加 FAB 与 Server Pro 账户升级计划

更新日期：2026-07-17
状态：实施中
适用项目：RemoteDeskHarmonyOS

## 1. 目标

将 SSH 密钥、2FA 验证器和 RustDesk 中继服务器的添加体验升级为与新版添加主机一致的分步式 BindSheet，并由“个性化”中的统一偏好控制 FAB 添加风格。

同时完成 RustDesk 账户模型收敛：删除没有实际业务用途的旧 Admin 账户 UI，将既有账户云同步存储和同步协议复用于 Server Pro 账户；云表名称、字段、主键和服务端接口不得改变。

最终必须满足：

1. 手机和 Pad 点击相关 FAB 后使用统一 BindSheet 添加向导。
2. PC 沿用 PC 适配的对话框或侧边 Sheet，不强制使用移动端底部布局。
3. “添加主机方式”设置改名为“添加 FAB 风格”。
4. 全新模式控制主机、SSH 密钥、2FA 和 RustDesk 中继的添加入口。
5. 经典模式保留旧表单布局，但不恢复已经废弃的 Admin 账户业务。
6. RustDesk 服务器保存与 Pro 账户添加是两个独立事务。
7. 用户保存服务器后可暂不添加 Pro 账户，也可继续添加。
8. 未绑定 Pro 账户的服务器可以稍后从中继卡片拉起同一 Pro 账户 BindSheet。
9. 旧账户云表及同步接口保持完全兼容。
10. 所有新增、编辑和删除结果必须实时反映到列表、计数器、卡片详情和主机添加向导。

## 2. 不可变约束

### 2.1 云端兼容

禁止：

- 新建或重命名旧账户云表。
- 增删云表字段。
- 修改旧主键结构。
- 修改服务端同步 API 的请求与响应结构。
- 把登录 Token、Cookie、密码、临时验证码或设备密钥上传到云端。

允许：

- 在应用业务层引入 `RustDeskProAccount` 语义模型。
- 通过适配器将 Pro 模型映射到旧账户持久化结构。
- 在不改变云端字段类型和含义边界的前提下重新利用旧字段。
- 将敏感会话材料保存在设备本地安全存储中。

### 2.2 交互边界

- 服务器保存成功后，不因账户登录失败、取消或超时而回滚服务器。
- OSS 中继不要求账户。
- Server Pro 中继也允许不添加账户，仅失去地址簿同步能力。
- 没有 Pro 账户不能阻止手动添加 RustDesk ID 主机。
- 编辑已有资源默认使用优化后的单页编辑 Sheet，不强制重新走完整向导。

## 3. 现状与主要问题

### 3.1 添加体验不统一

- 新版主机添加已经使用类型选择与分步流程。
- SSH 密钥、2FA 和中继仍主要依赖信息密集的长表单。
- 从主机流程嵌套添加资源与从设置页面添加资源的 UI、保存路径和刷新行为容易分叉。

### 3.2 设置命名范围过窄

现有 `hostAddMode` 只表达“添加主机”，但产品目标是控制所有 FAB 触发的资源添加界面。

### 3.3 RustDesk 账户概念重复

- 旧 Admin 账户 UI 没有有效业务消费链路。
- Server Pro 登录、设备同步和地址簿才是实际功能。
- 旧账户同步能力已经存在，不能因改名而修改云表。
- 中继保存目前容易与账户配置耦合，导致用户无法先保存服务器。

## 4. 总体架构

### 4.1 统一 FAB 风格偏好

新增业务语义：

```ts
type FabAddStyle = 'modern' | 'classic';
```

推荐持久化键：

```text
fabAddStyle
```

兼容迁移：

```text
若 fabAddStyle 已存在：直接使用
否则读取 hostAddMode
hostAddMode == classic → fabAddStyle = classic
其他情况 → fabAddStyle = modern
```

迁移期继续读取旧键，但只写新键。确认所有已发布版本完成迁移后，再单独评估是否停止读取旧键。

如果现有云端个性化表不能增加偏好键，则继续使用云端允许的旧 `hostAddMode` 键保存值，仅在本地代码中改称 `fabAddStyle`，不得为改名修改云表。

### 4.2 统一向导组件

建议新增：

```text
components/resourceadd/
├── ResourceAddWizardSheet.ets
├── WizardHeader.ets
├── WizardStepIndicator.ets
├── WizardChoiceCard.ets
├── WizardFieldGroup.ets
├── WizardSummaryCard.ets
├── WizardAsyncStatus.ets
└── WizardFooter.ets
```

业务向导：

```text
components/resourceadd/
├── SshKeyAddFlow.ets
├── TotpAddFlow.ets
├── RustDeskRelayAddFlow.ets
└── RustDeskProAccountSheet.ets
```

公共状态至少包括：

- 当前步骤。
- 是否正在执行异步操作。
- 字段级错误。
- 页面级错误。
- 是否存在未保存修改。
- 返回、取消、下一步和保存行为。
- 嵌套来源上下文，例如设置页、主机添加页或中继卡片。

## 5. 个性化设置升级

### 5.1 文案

原名称：

```text
添加主机方式
```

新名称：

```text
添加 FAB 风格
```

说明：

```text
控制添加主机、SSH 密钥、2FA 验证器和 RustDesk 中继时使用的界面风格。
```

### 5.2 选项

全新模式，默认：

- 卡片式类型选择。
- 分步填写。
- 独立校验与确认摘要。
- 支持在主机添加过程中嵌套创建资源并自动回填。

经典模式：

- 主机、SSH 密钥、2FA 和中继继续使用当前单页表单布局。
- 保存、实时刷新和安全策略仍使用新业务层。
- 不恢复旧 Admin 账户入口。
- Pro 账户始终使用有效的新 Pro 账户 Sheet。

## 6. SSH 密钥添加向导

### 6.1 第一步：添加方式

提供：

1. 从文件导入。
2. 生成新密钥。
3. 粘贴私钥。

### 6.2 文件导入

流程：

```text
系统文档选择器
→ 读取文本
→ 原生密钥检查
→ 元数据预览
→ 名称与保护设置
→ 确认保存
```

要求：

- 必须使用文档选择器，不能拉起图库。
- 复用 `SshKeyImportService`。
- 限制文件大小并处理编码、空文件和不可读文件。
- 显示文件名、密钥类型、指纹、加密状态和公钥状态。
- 导入后只有用户确认保存才写入保险库。
- 从 SSH 主机向导进入时，保存后自动选择新密钥。

### 6.3 生成密钥

默认提供：

- ED25519，推荐。
- RSA 4096。

字段：

- 名称。
- 注释。
- 可选 Passphrase。
- 对象保护方式。

生成后显示指纹、公钥预览、复制公钥和安装到主机入口。

### 6.4 粘贴私钥

- 多行输入。
- 自动规范换行。
- 调用原生检查，不依赖字符串外观判断。
- 禁止保存无效或只有公钥的内容。
- 保存或取消后清理内存中的临时文本。

### 6.5 保存与刷新

- 通过 `KeyVaultService` 单一写入口保存。
- 保存成功后更新服务内存快照。
- 密钥列表、计数器、添加 SSH 主机中的选择列表实时刷新。
- 从嵌套流程进入时返回新密钥 ID，不依赖页面重载。

## 7. 2FA 添加向导

### 7.1 第一步：添加方式

提供：

1. 扫描二维码。
2. 导入 `otpauth://` 配置。
3. 手动输入。

### 7.2 扫描二维码

- 仅在用户选择扫码后申请相机权限。
- 处理拒绝权限、永久拒绝、相机不可用和非 TOTP 二维码。
- 扫描成功后进入确认页，不直接保存。
- 显示服务名、账号、位数、周期和算法。

### 7.3 URI 或文件导入

- 支持粘贴 `otpauth://`。
- 支持从文本文件读取。
- 第一阶段只保证单条 TOTP；批量迁移二维码作为后续能力。
- 解析失败必须保留输入供用户修正。

### 7.4 手动添加

字段：

- 服务名称。
- 账号。
- Secret。
- 算法，默认 SHA-1。
- 位数，默认 6。
- 周期，默认 30 秒。

输入时：

- 规范化 Base32。
- 检查非法字符。
- 生成验证码预览与倒计时。
- 检查重复 Secret，并提示覆盖、另存或取消。

### 7.5 隐私保护

- 展示当前 TOTP 全局隐私保护状态。
- 如果现有模型不支持逐条保护，首版不伪造逐对象开关。
- 提供前往数据安全设置的入口。
- Secret 不在普通日志、Toast 或错误文本中输出。

### 7.6 保存与刷新

- 通过 `KeyVaultService` 保存。
- 卡片验证码和倒计时立即开始。
- 2FA 列表、设置计数器和数据安全摘要实时刷新。

## 8. RustDesk 中继添加向导

### 8.1 第一步：服务器类型

提供：

1. RustDesk OSS。
2. RustDesk Server Pro。
3. 高级自定义。

### 8.2 服务器字段

OSS：

- 配置名称。
- ID/Rendezvous Server。
- Relay Server。
- Key。
- 高级端口设置。

Server Pro：

- 配置名称。
- API 地址。
- ID Server。
- Relay Server。
- Key。
- 高级端口设置。

高级自定义：

- 展开全部现有服务器字段。
- 保持字段分组，不回退成无层级长表单。

### 8.3 分项测试

连接测试分别展示：

- 地址格式。
- DNS 解析。
- ID Server 可达性。
- Relay 可达性。
- API 可达性，仅 Pro。
- Key 是否已配置。
- 延迟。

服务器允许在测试失败后保存，但必须明确提示风险；地址格式等阻断性错误除外。

## 9. Server Pro 账户模型与旧云表适配

### 9.1 业务模型

业务层使用：

```ts
class RustDeskProAccount {
  id: string;
  relayId: string;
  apiUrl: string;
  username: string;
  displayName: string;
  syncEnabled: boolean;
  lastSyncAt: number;
  updatedAt: number;
  syncVersion: number;
  requiresLogin: boolean;
}
```

实际字段应以旧云账户结构能够承载的字段为准；不能为补齐模型修改云表。

### 9.2 适配器

新增明确边界：

```text
RustDeskProAccount
  ↕ LegacyRustDeskAccountCloudAdapter
旧 Admin 账户云记录
```

适配器负责：

- 旧记录转 Pro 模型。
- Pro 模型写回旧记录字段。
- 缺失字段默认值。
- 版本与更新时间兼容。
- 旧数据识别和待重新登录标记。

业务 UI 和连接逻辑不得直接操作旧 Admin 语义。

### 9.3 敏感信息

云端只保存账户元数据。以下信息只存在设备本地安全存储：

- Access Token。
- Refresh Token。
- Cookie 或会话材料。
- 明文密码。
- 2FA 临时验证码。
- 设备绑定密钥。

多设备同步后，新设备看到 Pro 账户元数据，但必须独立重新登录。

### 9.4 旧记录迁移

可迁移：

- 具备 relayId、API 地址和 username。
- 转为 `requiresLogin=true` 的 Pro 账户。
- 用户重新登录后激活。

不完整：

- 显示为“配置待完善”。
- 不自动同步地址簿。
- 允许补充 API 地址、重新登录或删除。

禁止：

- 把旧 Admin 记录当成已登录 Pro 会话。
- 自动上传旧密码或 Token。
- 因迁移失败删除用户记录。

## 10. 服务器保存后的可选账户流程

### 10.1 两阶段事务

```text
事务 A：保存 RustDesk 服务器
成功后服务器立即持久化并刷新列表
              ↓
事务 B：可选添加 Server Pro 账户
取消或失败不影响事务 A
```

### 10.2 保存完成页

Server Pro 服务器保存成功后显示：

```text
服务器已保存

可以继续添加 Server Pro 账户，以登录并同步地址簿设备。

[暂不添加]  [添加 Pro 账户]
```

“暂不添加”：

- 关闭添加流程。
- 中继卡立即出现。
- 卡片标记“未添加 Pro 账户”。
- 服务器仍可供手动 RustDesk 主机绑定和连接。

“添加 Pro 账户”：

- 打开 `RustDeskProAccountSheet`。
- 自动带入服务器和 API 地址。
- 登录成功后保存账户元数据和本地 Token。
- 可选立即同步地址簿。

登录失败、取消或超时：

- 不删除服务器。
- 不回到服务器表单。
- 保留“服务器已保存，账户尚未添加”状态。

## 11. Pro 账户 BindSheet

### 11.1 添加模式

字段：

- 所属服务器，只读。
- API 地址，默认继承服务器。
- 用户名。
- 密码。
- 记住本机登录。
- 登录后立即同步地址簿。

行为：

- 调用现有 Server Pro `/api/login`。
- 登录成功后保存账户元数据。
- Token 写入本机安全存储。
- 地址簿同步失败不撤销已成功的账户登录，但要显示独立错误。

### 11.2 编辑模式

允许修改：

- 显示名称。
- API 地址。
- 自动同步开关。
- 默认账户状态。

修改 API 地址或用户名时：

- 清除旧本地会话。
- 标记 `requiresLogin=true`。
- 要求重新登录后再同步。

### 11.3 重新登录模式

- 复用稳定账户 ID，不能创建重复记录。
- 用户名默认只读或允许显式切换账户。
- 成功后替换本地 Token。
- 预留 Server Pro 2FA 挑战步骤。

## 12. 中继卡片升级

### 12.1 无账户

展开卡显示：

```text
Server Pro 账户
尚未添加 Pro 账户
添加账户后可登录并同步地址簿设备。
[添加 Pro 账户]
```

按钮打开与服务器创建完成页相同的 `RustDeskProAccountSheet`。

### 12.2 有账户

显示：

- 显示名称和用户名。
- 本机登录状态。
- API 地址。
- 地址簿设备数量。
- 最近同步时间。
- 是否为默认账户。

操作：

- 同步地址簿。
- 重新登录。
- 编辑。
- 退出本机登录。
- 删除账户。

删除账户只删除账户记录和对应本地 Token，不删除服务器；删除前显示受影响的主机或同步来源。

## 13. 添加主机流程复用

### 13.1 SSH

- 密钥列表为空时可打开统一 SSH 密钥向导。
- 保存后返回 SSH 主机步骤并自动选中新密钥。
- 主机草稿不得丢失。

### 13.2 RustDesk

选择中继服务器后：

- 没有 Pro 账户仍允许手动填写控制 ID。
- 显示非阻断提示：无法从 Server Pro 地址簿选择设备。
- 提供“添加 Pro 账户”按钮。
- 添加成功后返回原步骤，刷新账户和地址簿并自动选择新账户。

### 13.3 嵌套 Sheet 管理

- 不允许多个 BindSheet 状态互相覆盖。
- 子向导关闭后恢复父向导原步骤与草稿。
- 保存成功通过结果对象回传 ID，不依赖全局页面重载。
- 用户取消子向导时父向导保持原状态。

## 14. 实时刷新与同步触发

建议使用服务级修订号或统一事件：

```text
sshKeyRevision
totpRevision
rustDeskRelayRevision
rustDeskProAccountRevision
```

成功写入顺序：

```text
本地数据库事务成功
→ 更新服务内存快照
→ revision 增加
→ UI 订阅者刷新
→ 按现有策略触发一次云上传
→ 正常响应后同步任务静默
```

覆盖页面：

- 设置计数器。
- 密钥保险库外部摘要和内部详情。
- 2FA 卡片。
- 中继卡片和账户展开区。
- 添加主机向导中的资源列表。
- 主机编辑页中的绑定资源。
- 数据安全中的 RustDesk 信任状态。

禁止：

- 通过杀后台或重新进入页面才能看到更新。
- 用轮询代替本地变更通知。
- 打开 Sheet 就触发无条件云上传。
- 登录失败后反复自动重试上传。

## 15. 文件级实施建议

重点修改：

- `entry/src/main/ets/pages/HostListPage.ets`
- `entry/src/main/ets/pages/KeyVaultPage.ets`
- `entry/src/main/ets/pages/RustDeskRelayPage.ets`
- `entry/src/main/ets/components/hostadd/HostAddWizardSheet.ets`
- `entry/src/main/ets/components/hostadd/SshAddFlow.ets`
- `entry/src/main/ets/components/hostadd/RustDeskAddFlow.ets`
- `entry/src/main/ets/model/RustDeskRelayConfig.ets`
- `entry/src/main/ets/model/RustDeskAccount.ets`
- `entry/src/main/ets/services/KeyVaultService.ets`
- `entry/src/main/ets/services/HostSyncService.ets`
- `entry/src/main/ets/services/CloudStore.ets`
- `entry/src/main/ets/services/CloudSyncSettingsPolicy.ets`

新增候选：

- `entry/src/main/ets/model/RustDeskProAccount.ets`
- `entry/src/main/ets/services/LegacyRustDeskAccountCloudAdapter.ets`
- `entry/src/main/ets/components/resourceadd/*`

最终文件名以实际代码依赖为准；优先拆分组件，避免继续扩大 `HostListPage.ets`、`KeyVaultPage.ets` 和 `RustDeskRelayPage.ets`。

## 16. 实施阶段

### 阶段 0：基线与回归保护

- 记录旧云账户结构和所有读写路径。
- 为旧账户序列化、反序列化和冲突合并补测试。
- 记录主机、密钥、TOTP、中继和 Pro 账户当前实时刷新路径。
- 不修改云端 schema。

完成标准：现有数据可完整往返，测试能捕获字段丢失。

### 阶段 1：FAB 风格设置与公共框架

- 设置项改名为“添加 FAB 风格”。
- 完成旧偏好迁移。
- 引入公共向导容器和选择卡。
- 建立 modern/classic 路由。

完成标准：切换风格后四类 FAB 使用正确入口，重启后保持设置。

### 阶段 2：SSH 密钥向导

- 实现文件导入、生成和粘贴。
- 接入保险库保存和实时刷新。
- 接入 SSH 主机向导自动回填。

完成标准：文件选择器不拉起图库，保存后无需离开页面即可使用。

### 阶段 3：2FA 向导

- 实现扫码、URI 导入和手动添加。
- 实现预览、重复检测和隐私状态。
- 接入实时刷新。

完成标准：有效 TOTP 与标准实现一致，权限拒绝和错误输入可恢复。

### 阶段 4：Pro 账户云适配

- 建立 Pro 业务模型。
- 复用旧账户云表和同步协议。
- 删除旧 Admin UI 和业务文案。
- 实现旧记录待登录迁移。
- Token 继续设备本地保存。

完成标准：云表无变更，旧记录不丢失，新设备同步后要求重新登录。

### 阶段 5：中继向导与可选账户

- 实现 OSS、Server Pro 和高级自定义流程。
- 服务器先保存。
- 保存完成页允许暂不添加或继续添加 Pro 账户。
- 登录失败不回滚服务器。

完成标准：无账户服务器可独立存在、绑定主机并正常手动连接。

### 阶段 6：卡片与嵌套入口

- 无账户中继卡增加“添加 Pro 账户”。
- 有账户卡展示状态和操作。
- 主机添加流程复用同一 Pro Sheet。
- 子 Sheet 返回后保留父草稿并自动选择资源。

完成标准：所有入口使用同一业务组件且结果一致。

### 阶段 7：实时刷新与清理

- 收敛 revision/事件机制。
- 删除旧 Admin 入口、死代码和无用文案。
- 保留必要旧数据读取适配。
- 确认云同步只在增删改或用户主动同步时启动。

完成标准：所有卡片、计数器和详情即时一致，无后台轮询。

## 17. 测试计划

### 17.1 自动测试

- `fabAddStyle` 迁移与 classic/modern 路由。
- SSH 文件导入、粘贴、生成和错误格式。
- TOTP URI、Base32、算法、周期、重复检测。
- 旧 Admin 云记录到 Pro 模型的映射。
- Pro 模型写回旧云结构不丢字段。
- Token 不进入云序列化结果。
- 服务器保存成功、账户添加失败时服务器仍存在。
- 从卡片添加账户后实时刷新。
- 嵌套向导取消和成功回填。
- 删除被引用资源时的影响检查。

### 17.2 构建门禁

- 定向 ArkTS 测试。
- `default@OhosTestCompileArkTS`。
- 生产 `assembleHap`。
- `git diff --check`。
- Light 开源合规门。
- 如果修改 native 密钥解析或 RustDesk FFI，增加对应 native/Rust 测试和双 ABI 构建。

### 17.3 实机矩阵

设备：

- 手机竖屏。
- 手机横屏。
- Pad。
- PC/2in1。

场景：

- 全新与经典 FAB 风格切换。
- 独立页面添加和主机流程嵌套添加。
- SSH 文件选择器、加密私钥和自动回填。
- 2FA 扫码权限拒绝、恢复和验证码准确性。
- OSS 服务器保存。
- Pro 服务器保存后暂不添加账户。
- Pro 服务器保存后立即添加账户。
- 从无账户卡片补充账户。
- 登录失败、取消、API 不可达和重新登录。
- 多设备同步账户元数据，新设备重新认证。
- 地址簿同步和设备卡实时刷新。
- 应用重启与旧版本数据迁移。

## 18. 验收标准

全部满足才可关闭任务：

1. 个性化设置显示“添加 FAB 风格”。
2. 默认全新模式，经典模式可恢复旧表单布局。
3. SSH 密钥、2FA 和中继使用统一新向导。
4. SSH 文件导入不会打开图库。
5. 三类资源保存后列表、计数器和嵌套选择器实时刷新。
6. 旧 Admin UI 完全移除。
7. Pro 账户使用旧云表同步，云 schema 无任何变化。
8. 云端不包含密码和会话 Token。
9. Server Pro 服务器可不添加账户直接保存。
10. 无账户卡片可随时打开 Pro 账户 BindSheet。
11. Pro 登录失败不会删除或回滚服务器。
12. 无 Pro 账户仍可手动添加和连接 RustDesk 主机。
13. 多设备同步后账户元数据存在，但每台设备独立登录。
14. 手机、Pad、PC 布局和交互均通过实机验收。

## 19. 明确不在本轮范围

- 修改云数据库 schema 或部署新云表。
- 把 Pro 密码或 Token 跨设备同步。
- Server Pro 2FA 的完整实现；本轮只预留挑战步骤。
- 批量导入其他验证器的迁移二维码。
- RustDesk 服务端部署和账号创建。
- VNC 凭据向导；仅保留公共框架扩展能力。

## 20. 实施进度

### 2026-07-17：阶段 0 与阶段 1 首个切片

- 已确认旧账户云数据继续复用 `rustdeskrelays.accountsjson`，不修改云表结构。
- 已确认 Pro Token 继续使用设备本地 `RustDeskProCredentialStore`，不进入云同步 JSON。
- 个性化设置已改名为“添加 FAB 风格”，本地与云端继续使用兼容键 `hostAddMode`。
- 已引入统一 `FabAddStylePolicy`，PC 固定桌面表单，手机与 Pad 响应 modern/classic 偏好。
- SSH 密钥和 2FA FAB 已接入首层 modern/classic 路由；2FA 全新模式提供扫码、otpauth 与手动输入入口。
- `default@OhosTestCompileArkTS` 已通过；后续继续完善公共向导、嵌套回填和中继流程。
