# 全新 FAB 资源添加子流程重构执行计划

更新日期：2026-07-17  
状态：待实施，需求已确认  
适用范围：SSH 密钥、2FA 验证器、中继服务器的 FAB 添加流程

## 1. 背景与问题

当前全新模式只替换了 FAB 第一层选择 Sheet。用户点击“从文件导入”“生成新密钥”“手动输入”或中继类型后，后续步骤仍复用经典模式的旧 Builder、旧状态变量和旧 Sheet，导致：

- 新版入口和旧版子弹窗混用，视觉和操作不一致。
- 修改新版子流程容易影响经典模式。
- 嵌套添加完成后的回填、实时刷新和错误恢复不稳定。
- RustDesk 中继流程存在不必要的 OSS、Pro、高级自定义类型选择。
- 2FA 缺少完整的文件批量导入能力和 `.atsf` 格式支持。

本计划替代 `RESOURCE_ADD_FAB_UI_UPGRADE_PLAN.md` 中尚未实施的现代子流程设计；旧计划保留为历史记录。

## 2. 最终目标

1. 全新模式拥有独立的 Sheet 容器、流程状态、表单组件和路由，不调用任何经典模式 UI Builder。
2. 经典模式完整保留现有布局和操作，不因新版重构发生视觉变化。
3. 两套 UI 只共用底层解析、生成、校验、保存和同步 Service。
4. SSH 密钥三个入口的所有子弹窗全部重做。
5. 2FA 四个入口的所有子弹窗全部重做，并支持 `.atsf` 文件导入。
6. RustDesk 新版流程取消 OSS/Pro/高级自定义选择，统一填写中继服务器内置选项。
7. RustDesk 服务器先独立保存，再由新弹窗选择“确定保存”或“下一步”登录 Pro。
8. VNC Repeater 使用独立新版流程，不复用 RustDesk 表单或云表。
9. 所有新增结果立即刷新列表、计数器、详情卡和嵌套选择器。

## 3. 不可变约束

### 3.1 新旧模式隔离

路由边界固定为：

```text
FAB / 嵌套添加入口
        ↓
FabAddStylePolicy
   ├─ classic → Legacy Resource UI
   └─ modern  → Modern Resource Flow
```

- Modern 组件不得调用 `legacy*Sheet()`、旧 `sheetContent` Builder 或经典表单回调。
- Classic 组件不得依赖 Modern 流程状态。
- 禁止用大量 `if (modern)` 在同一个 Builder 内拼接两套 UI。
- 编辑已有资源暂时保留现有编辑弹窗；添加流程先完成彻底隔离，编辑升级另行验收。

### 3.2 数据与安全

- 不修改任何现有云表、字段、主键或服务端同步协议。
- SSH 私钥、TOTP Secret、Pro Token 和密码不得写入日志或 Toast。
- Pro Token 继续只存本机安全存储。
- VNC Repeater 继续使用独立本地存储，不写入 RustDesk 云记录。
- 用户取消、返回或解析失败时必须清理临时私钥、Passphrase、TOTP Secret 和 Pro 密码。

## 4. 统一现代 Sheet 框架

新增独立公共组件，建议结构：

```text
components/resourceadd/modern/
├── ModernResourceSheet.ets
├── ModernFlowHeader.ets
├── ModernChoiceCard.ets
├── ModernFieldGroup.ets
├── ModernResultSummary.ets
├── ModernAsyncState.ets
├── ModernFlowFooter.ets
├── ModernSshKeyAddFlow.ets
├── ModernTotpAddFlow.ets
├── ModernRelayAddFlow.ets
└── ModernRustDeskProFlow.ets
```

统一容器布局：

```text
返回按钮 / 标题 / 关闭按钮
步骤说明或进度
可滚动内容区
字段级和页面级错误区
固定底部主次操作按钮
```

适配规则：

- 手机：竖屏 Bottom Sheet，内容区滚动，底部按钮固定。
- Pad：受控宽度的 Bottom Sheet 或居中 Sheet。
- PC：居中 Sheet/Dialog，不使用移动端全宽底部样式。
- 第一层与所有子步骤统一 22px 标题、13px 说明、68px 选择卡、16px 圆角、20px 外边距和 36px 关闭按钮。
- 子步骤必须支持返回上一步并保留已填写草稿。

## 5. 流程状态与结果协议

每个 Modern Flow 使用独立枚举或字符串状态，不再使用跨业务数字 `sheetContent`：

```ts
type ModernSshKeyStep = 'method' | 'file-pick' | 'file-preview' | 'generate-options' |
  'generate-preview' | 'paste' | 'saving' | 'done';

type ModernTotpStep = 'method' | 'scan' | 'file-pick' | 'file-preview' |
  'uri' | 'manual' | 'saving' | 'done';

type ModernRelayStep = 'protocol' | 'rustdesk-form' | 'rustdesk-saved' |
  'pro-login' | 'vnc-form' | 'done';
```

统一返回结果：

```ts
interface ResourceAddResult {
  resourceType: string;
  resourceIds: string[];
  primaryResourceId: string;
}
```

- 独立页面调用者收到结果后关闭 Sheet 并刷新。
- 嵌套主机向导收到结果后恢复父步骤、保留主机草稿并自动选中新资源。
- 取消返回空结果，不重置父流程。

## 6. SSH 密钥现代流程

### 6.1 第一层

```text
从文件导入
生成新密钥
粘贴私钥
```

### 6.2 从文件导入

```text
新版说明页
→ 系统文档选择器
→ 读取与原生解析
→ 密钥信息预览
→ 名称和保护设置
→ 导入并保存
```

实施要求：

- 使用系统文档选择器，禁止图库选择器。
- 限制文件大小，处理空文件、编码错误、权限错误和用户取消。
- 支持现有 OpenSSH、PEM、PKCS#8 私钥能力。
- 预览文件名、密钥类型、指纹、加密状态和公钥状态。
- 加密私钥在当前 Modern Sheet 内请求 Passphrase 并重新校验。
- 只有用户点击“导入并保存”才写入 `KeyVaultService`。
- 从 SSH 主机流程进入时，保存后自动选择新密钥。

### 6.3 生成新密钥

```text
选择 ED25519 / RSA
→ 名称、注释、位数和可选 Passphrase
→ 生成
→ 指纹和公钥预览
→ 保存
```

- 默认推荐 ED25519。
- RSA 提供 3072 和 4096 位。
- 生成按钮防重复触发。
- 生成成功后可复制公钥，但保存仍需用户确认。
- 取消时销毁尚未保存的私钥材料。

### 6.4 粘贴私钥

- 使用 Modern 多行输入组件。
- 自动规范换行并调用原生解析。
- 区分私钥无效、只有公钥、加密私钥缺少 Passphrase。
- 私钥正文默认遮挡或折叠。
- 保存成功后清空输入缓存。

## 7. 2FA 现代流程

### 7.1 第一层四个入口

```text
扫描二维码
从文件导入
导入 otpauth 配置
手动输入
```

### 7.2 扫描二维码

- 仅在用户选择扫码后申请相机权限。
- 权限拒绝、永久拒绝、相机不可用和二维码无效均留在 Modern Flow 内处理。
- 扫描成功后进入账户确认页，不直接保存。
- 显示发行方、账户、算法、位数和周期。

### 7.3 从文件导入

```text
新版文件说明页
→ 系统文档选择器
→ 格式识别与解析
→ 批量账户预览
→ 用户勾选
→ 重复项处理
→ 批量保存
```

必须支持的格式：

1. `.atsf`。
2. 包含一条或多条 `otpauth://` URI 的 `.txt`。
3. 约定结构的 `.json`。
4. 约定字段的 `.csv`。

#### ATSF 专项要求

- `.atsf` 是首版验收必选格式，不得作为普通文本文件盲读。
- 实施前根据实际 ATSF 样本确认文件头、版本、编码、字段结构和完整性校验方式。
- 新增独立 `AtsfTotpImportParser`，不得把 ATSF 特例散落在页面代码中。
- 识别不支持的 ATSF 版本并给出明确错误。
- 如果 ATSF 支持加密或口令保护，在 Modern Sheet 内进入口令步骤；错误口令不得破坏原文件或生成部分记录。
- 支持一次解析多条账户，预览发行方、账户、算法、位数和周期。
- 单条损坏时展示逐条错误；只有文件整体不可解析时阻断整个导入。
- 测试夹具至少包含：有效单账户、有效多账户、重复账户、损坏文件、不支持版本，以及加密/错误口令样本（若格式支持）。

通用批量导入规则：

- 默认勾选所有有效条目，无效条目不可勾选。
- 重复检测同时考虑现有保险库和当前文件内重复项。
- 重复项提供跳过或替换，不静默覆盖。
- 批量保存要么使用事务，要么返回准确的成功/失败明细。
- 保存后 2FA 列表、外部摘要、计数器和动态验证码立即刷新。

### 7.4 导入 otpauth 配置

- 支持粘贴一条 `otpauth://` URI。
- 实时解析并展示发行方、账户、算法、位数和周期。
- 解析错误保留原输入供修正。
- 与文件导入共用标准 TOTP 校验模型，不共用 UI 状态。

### 7.5 手动输入

字段：

- 发行方。
- 账户。
- Secret。
- 算法，默认 SHA-1。
- 位数，默认 6。
- 周期，默认 30 秒。

保存前规范化 Base32、检查非法字符和重复 Secret，并显示验证码预览。

## 8. RustDesk 中继现代流程

### 8.1 协议选择

```text
RustDesk 中继
VNC 中继
```

### 8.2 RustDesk 服务器配置

全新模式取消以下第二层选项：

- RustDesk OSS。
- RustDesk Server Pro。
- 高级自定义。

用户点击“RustDesk 中继”后直接进入统一的内置选项设置：

- 配置名称。
- ID/Rendezvous Server 地址。
- ID Server 端口，默认 21116。
- Relay Server 地址。
- Relay 端口，默认 21117。
- API 地址，可选。
- Key，可选。
- 高级选项折叠区。
- 可选连接测试。

点击“保存”后必须先完成服务器持久化和页面实时刷新，再进入新的保存结果 Sheet。

### 8.3 保存结果 Sheet

固定文案语义：

```text
中继服务器已保存

服务器配置已经保存。你可以直接完成，也可以继续登录
RustDesk Server Pro 账户，同步 Pro 地址簿和设备。

[确定保存] [下一步]
```

“确定保存”：

- 结束 Modern Flow。
- 已保存服务器立即出现在卡片和主机添加选择器中。
- 不创建 Pro 账户。

“下一步”：

- 打开 Modern Pro 登录 Sheet。
- 自动带入刚保存服务器 ID 和可用 API 地址。
- Pro 登录、取消或失败都不得回滚服务器。

### 8.4 Pro 登录

- API 地址。
- 用户名。
- 密码。
- 登录并同步设备。
- 错误显示在当前 Sheet。
- 登录成功后保存账户元数据和本地 Token，并实时刷新卡片。
- 未登录 Pro 的服务器后续仍可从卡片打开同一个 Modern Pro Flow。

## 9. VNC Repeater 现代流程

```text
VNC 中继
→ UltraVNC Repeater 配置
→ 保存
```

字段：

- 配置名称。
- Repeater 地址。
- Viewer 端口，默认 5901。
- Repeater 模式。
- 默认目标 ID，可选。

VNC 配置使用独立模型和本地存储。当前 VNC 连接引擎未启用时，界面必须明确显示能力状态，不得显示虚假的在线或可连接状态。

## 10. 底层 Service 拆分

Modern 和 Classic UI 共用以下无界面业务能力：

```text
SshKeyImportService
SshKeyGenerationService
TotpImportService
AtsfTotpImportParser
TotpDuplicatePolicy
KeyVaultService
HostSyncService
RustDeskProSyncService
VncRelayConfigService
```

页面只负责收集输入和展示结果；文件解析、密码校验、重复检测和批量事务不得直接写在 ArkUI Builder 中。

## 11. 文件级实施范围

重点修改：

- `entry/src/main/ets/pages/KeyVaultPage.ets`
- `entry/src/main/ets/pages/RustDeskRelayPage.ets`
- `entry/src/main/ets/pages/HostListPage.ets`
- `entry/src/main/ets/components/resourceadd/ResourceFabPicker.ets`
- `entry/src/main/ets/components/hostadd/SshAddFlow.ets`
- `entry/src/main/ets/services/KeyVaultService.ets`

新增候选：

- `entry/src/main/ets/components/resourceadd/modern/*`
- `entry/src/main/ets/services/TotpImportService.ets`
- `entry/src/main/ets/services/AtsfTotpImportParser.ets`
- `entry/src/main/ets/services/TotpDuplicatePolicy.ets`
- 对应测试文件和非敏感 ATSF 测试夹具。

最终以实际依赖为准，但不得继续把所有现代流程堆入 `HostListPage.ets`、`KeyVaultPage.ets` 或 `RustDeskRelayPage.ets`。

## 12. 分阶段实施与验收

### 阶段 0：基线和路由测试

- 记录所有 FAB、空状态按钮和嵌套添加入口。
- 为 `classic/modern` 路由补测试。
- 固化经典模式截图或关键布局参数。

完成标准：能证明新版修改不会进入经典 UI 路径。

### 阶段 1：Modern Sheet 公共框架

- 建立统一容器、Header、选择卡、字段组、错误区和 Footer。
- 建立各业务独立状态机和结果回传协议。
- 处理返回、关闭、草稿保留和敏感状态清理。

完成标准：手机、Pad、PC 容器与新版添加主机风格一致。

### 阶段 2：SSH 密钥完整子流程

- 文件导入。
- ED25519/RSA 生成。
- 粘贴私钥。
- 保险库保存、实时刷新和 SSH 主机自动回填。

完成标准：三个入口从头到尾不出现经典弹窗，文件导入不打开图库。

### 阶段 3：2FA 完整子流程

- 扫码。
- 文件导入，包括 ATSF/TXT/JSON/CSV。
- otpauth URI。
- 手动输入。
- 批量预览、重复处理、保存和实时刷新。

完成标准：有效 `.atsf` 可导入，多账户可选择，损坏和不支持版本可恢复且不产生半条数据。

### 阶段 4：RustDesk 中继与 Pro

- 删除 Modern 的 OSS/Pro/高级自定义二级选择。
- 实现统一服务器内置选项表单。
- 服务器先保存。
- 实现“确定保存 / 下一步”的结果 Sheet。
- 实现 Modern Pro 登录和卡片补登录入口。

完成标准：服务器保存与 Pro 登录是独立事务，Pro 失败不回滚服务器。

### 阶段 5：VNC Repeater

- 实现独立 Modern VNC 表单和保存结果。
- 接入现有本地存储、实时刷新、编辑和删除。
- 保持连接能力状态诚实展示。

完成标准：VNC 配置不进入 RustDesk 表单、不污染 RustDesk 云数据。

### 阶段 6：全入口回归和清理

- 页面 FAB。
- 空状态入口。
- 添加 SSH 主机时嵌套添加密钥。
- 中继卡片补充 Pro 账户。
- classic/modern 切换和重启持久化。
- 删除 Modern 对旧 Builder 的所有引用。

## 13. 自动验证

最低门禁：

- Modern/Classic 路由测试。
- SSH 文件、生成、粘贴解析测试。
- TOTP URI、TXT、JSON、CSV 和 ATSF 解析测试。
- ATSF 有效、批量、重复、损坏、不支持版本和口令场景测试。
- RustDesk 服务器保存成功、Pro 失败不回滚测试。
- 嵌套添加成功回填和取消保留草稿测试。
- 定向 ArkTS 测试。
- `default@OhosTestCompileArkTS`。
- `assembleHap`。
- `git diff --check`。
- Light 开源合规门。

## 14. 实机验收矩阵

设备：

- 手机竖屏。
- 手机横屏。
- Pad。
- PC/2in1。

重点场景：

1. Classic 模式所有入口仍显示原弹窗。
2. Modern 模式所有子步骤均为新版弹窗。
3. SSH 文件选择器只显示文档文件，不进入图库。
4. 加密私钥口令正确、错误、取消和重试。
5. 生成 ED25519/RSA 后保存与自动选中。
6. 2FA 扫码权限拒绝与恢复。
7. `.atsf` 单账户、多账户、重复、损坏和不支持版本导入。
8. TXT/JSON/CSV 文件批量预览和部分条目错误。
9. RustDesk 保存后选择“确定保存”。
10. RustDesk 保存后选择“下一步”并成功登录 Pro。
11. Pro 登录失败或取消后服务器仍存在。
12. 从未登录 Pro 的中继卡片再次打开 Modern Pro Sheet。
13. VNC Repeater 保存、重启恢复、编辑和删除。
14. 所有列表、计数器、详情和嵌套选择器实时刷新。

## 15. 完成标准

只有全部满足才关闭任务：

1. Modern 添加流程不再调用经典子弹窗。
2. Classic 模式视觉和流程没有被新版改造改变。
3. SSH 三种添加方式全部使用新版子流程。
4. 2FA 四种添加方式全部使用新版子流程。
5. `.atsf` 文件导入通过自动测试和实机验收。
6. RustDesk Modern 流程不再显示 OSS/Pro/高级自定义类型选择。
7. RustDesk 服务器保存后显示“确定保存 / 下一步”及 Pro 登录说明。
8. Pro 登录失败、取消或超时不影响已保存服务器。
9. VNC Repeater 使用独立新版流程和独立数据模型。
10. 新增资源在所有消费者中实时可见。
11. 手机、Pad、PC 的新版 Sheet 与新版添加主机保持一致。
12. 构建、测试、合规门和实机矩阵通过。

## 16. 明确不在本轮范围

- 修改云数据库 schema。
- 同步 Pro 密码或 Token。
- 实现新的 VNC native 连接引擎。
- 支持尚未取得规范或测试样本的其他验证器私有加密备份格式。
- 全面重做已有资源的编辑界面；本轮优先完成添加流程彻底隔离。
