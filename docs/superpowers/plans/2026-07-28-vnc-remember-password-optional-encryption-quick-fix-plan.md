# VNC 记住密码、可选应用加密与云同步解耦快速修复计划

> 计划日期：2026-07-28
> 计划状态：已实施本地代码；待真机 Mac VNC 与双设备云端验收
> 适用仓库：RemoteDeskHarmonyOS
> 目标：让 VNC 与 RustDesk 一样支持“一次性密码 / 记住密码”，并解除 VNC 功能、云同步和全局应用加密之间的错误强耦合。

## 0. 本次计划的明确边界

本计划已按以下边界实施到授权的本地 `main`：不修改云端表，不修改 vncrecord 的字段，不创建远端 PR，不推送远端，也不改变 RDP、RustDesk、SSH/SFTP 的既有行为。

本计划以当前用户需求为最终产品决策：

1. 用户不启用应用加密，不应因此失去 VNC 连接能力。
2. “记住密码”决定密码是否持久化；不记住时应支持一次性连接。
3. “云同步”决定是否上传相应数据；云同步不应因为应用加密未启用而被整体禁止。
4. “应用加密”只决定持久化凭据采用加密封装还是用户明确同意的未加密封装，不再作为所有 VNC 功能的总开关。
5. 未加密保存或未加密云同步必须明确告知用户风险并取得确认，不能静默把敏感数据上传云端。
6. VNC 继续使用独立 owner 和唯一云表 vncrecord，不进入 remotehosts、rustdeskrelays 或 usersettings。

本轮实际新增的关键实现包括：VNC 专用 `encrypted_v2/plain_explicit_v1` 凭据策略、记住密码开关、RemoteDesktop VNC 密码 Sheet、添加页到连接页的内存一次性凭据交接、锁定/未选 scope 下的 raw secret 删除，以及关闭全局加密时的事务化 VNC envelope 迁移。复核后又补上了同步范围失败回滚、VNC-only 请求中 `cryptoparams` 失败不阻断 `vncrecord`、混合协议请求继续 fail-closed、以及新建主机/网关失败时不制造用户 tombstone 的一致性修复。

## 1. 当前基线与问题证据

### 1.1 RustDesk 已有的可复用产品语义

RustDesk Pro 连接鉴权页面已经提供：

- 密码输入；
- 一次性密码 / 永久密码；
- “记住设备密码”复选框；
- 只有用户勾选记住时才调用持久化逻辑；
- 未勾选时密码只用于当前会话。

相关实现位于：

- entry/src/main/ets/pages/HostListPage.ets 的 RustDesk Pro 鉴权 Sheet；
- entry/src/main/ets/pages/RemoteDesktop.ets 的 rustDeskAuthRememberPassword、rustDeskSessionRememberPassword 和 persistRustDeskSessionAuth 逻辑。

普通 RustDesk 添加流程中的“一次性密码 / 永久密码”是密码语义选择，Pro 连接页另有显式“记住设备密码”控制。VNC 应同时采用这两个层次中真正有价值的部分：认证类型与持久化意愿分离，持久化必须显式可见。

### 1.2 VNC 当前保存链路

当前 VncAddFlow 始终把输入的 password 传给 VncHostService.save，没有“记住密码”状态。

当前链路为：

    VncAddFlow
      -> HostListPage.saveVncHostFromAddFlow
      -> VncHostService.save(values, id, password)
      -> VncSecretService.save(..., password)
      -> vncrecord(recordtype=secret)
      -> 保存成功后才进入 RemoteDesktop

因此“保存并连接”不是临时连接，而是“先持久化凭据，再使用主机 ID 连接”。没有保存成功就没有当前实现所需的连接路由。

### 1.3 当前错误的加密阻断

当前代码将“应用加密未启用”和“应用加密已启用但锁定”混成了同一状态：

- entry/src/main/ets/services/VncHostService.ets:91：只要密码非空且 DataCrypto.isReady() 为假，就拒绝保存。
- entry/src/main/ets/services/VncSecretService.ets:48：VNC secret 保存再次要求 crypto ready。
- entry/src/main/ets/pages/VncSettingsPage.ets:286：设置页再次阻止未解锁状态保存密码。
- entry/src/main/ets/pages/VncSettingsPage.ets:240：阻止未解锁时开启 VNC secret/trust 同步。
- entry/src/main/ets/services/VncCloudSyncSelectionPolicy.ets:49：令 secret scope 必须同时满足“选中 + crypto ready”。
- entry/src/main/ets/services/CloudStore.ets:4302：在 VNC secret 写入和投影时继续检查 crypto ready。
- entry/src/main/ets/services/CloudSyncCoordinator.ets:710：以 needsCrypto() 决定 VNC 同步是否加入 cryptoparams，使同步路径依赖应用加密状态。

这套逻辑对于“应用加密已启用但暂时锁定”是合理的安全保护，但对于“应用加密从未启用”的用户构成了不必要的功能阻碍。

### 1.4 当前数据模型限制

当前 vncrecord 的 secret 记录只接受绑定上下文的 AES-GCM v2 封装：

- entry/src/main/ets/services/VncRecordPolicy.ets
- entry/src/main/ets/services/VncSecretService.ets

当前非 secret 记录使用明文 payload，secret 的值位于 ciphertext 字段。现有校验不允许一个“用户明确选择的未加密 secret envelope”，所以即使允许 VNC 未启用加密，也需要先扩展 secret envelope 版本策略。

## 2. 产品与安全状态模型

必须把下面四个开关/状态分开处理。

### 2.1 持久化意愿

    rememberPassword = false
      当前连接使用；不创建 secret 记录；离开会话后清除。

    rememberPassword = true
      创建或更新 VNC secret 记录；具体使用 encrypted_v2 还是
      plain_explicit_v1 由应用加密状态和用户确认决定。

主机地址、端口、显示参数等非敏感 host metadata 可以照常保存，即使密码不记住。

### 2.2 应用加密状态

沿用 SensitiveDataStatePolicy 的三态模型：

    disabled  = 用户从未启用或已明确关闭全局应用加密
    locked    = 用户启用了全局加密，但当前 DEK 未解锁
    unlocked  = 用户启用了全局加密，当前 DEK 可用

状态语义：

| 状态 | 临时连接 | 记住密码 | 凭据同步 |
| --- | --- | --- | --- |
| disabled | 允许 | 允许，但需告知未加密 | 允许，需用户明确确认未加密同步 |
| locked | 允许 | 需要解锁；也可选择不记住 | 已有密文可同步但不可解密；新增加密凭据需解锁 |
| unlocked | 允许 | 允许，保存 AES-GCM v2 | 允许，按用户 scope 选择 |

重点：disabled 不能再被当成 locked；locked 也不能被静默降级为明文。

### 2.3 云同步意愿

云同步仍分两层：

1. 普通选择器决定物理表 vncrecord 是否参与云同步。
2. VNC 页面决定 settings、hosts、gateways、secrets、trust 五个逻辑 scope。

其中：

- metadata scope 不依赖 crypto；
- trust scope 不依赖 crypto，但新设备不得自动信任；
- secret scope 不依赖 crypto 才能被选择，但 secret 的存储封装必须根据实际 crypto 状态处理；
- secret scope 默认关闭；
- rememberPassword=false 时没有 secret 记录，因此没有密码可上传。

## 3. 修复后的用户流程

    添加或连接 VNC 主机
      -> 已有可用密码：直接进入连接
      -> 没有可用密码：显示 VNC 密码 Sheet
      -> 输入本次密码
      -> 选择是否记住
          否：仅当前会话使用
          是：根据 crypto 状态选择封装
              disabled：明文保存风险确认
              locked：提示解锁或改为一次性
              unlocked：AES-GCM v2 保存
      -> 启动 VNC native session

### 3.1 VNC 添加流程

在 VncAddFlow 第二步“认证与安全”增加：

- VNC 密码输入框；
- “记住密码”开关，默认关闭；
- 关闭时显示“只用于本次连接，不会保存到本机或云端”；
- 应用加密为 disabled 且用户打开“记住密码”时，显示“应用加密未启用，密码不会被加密保存”，并要求二次确认；
- 应用加密为 locked 且用户打开“记住密码”时，显示“先解锁应用加密，或改为仅本次连接”；
- 不显示应用主密码输入框；应用主密码只在主设置的数据安全入口处理。

行为：

- “保存”且不记住：保存 host metadata，丢弃输入密码；
- “保存并连接”且不记住：保存 host metadata，关闭添加 Sheet 后在 RemoteDesktop 进行一次性密码认证；
- “保存并连接”且记住：按三态 crypto 规则保存 secret，成功后再进入 RemoteDesktop；
- 保存失败时保留草稿，不清除用户输入。

### 3.2 RemoteDesktop VNC 认证 Sheet

当前 RemoteDesktop 已有 RustDesk 专属认证 Sheet，但没有等价的 VNC 密码 Sheet。新增 VNC 分支时必须保持协议隔离：

- 只在 VNC owner 路由中触发；
- 不读取 RustDesk/RDP/SSH 的密码状态；
- 输入密码通过内存中的一次性 session intent 传递，不放入 router 参数、Preferences、日志或共享普通 host model；
- 提供“记住密码”开关；
- 记住失败时可继续本次连接，不应阻止用户测试连接；
- 连接取消、断开、切后台和 session generation 变化时清理临时密码。

如果已有加密 secret 但当前应用加密锁定：

- 显示“已保存的 VNC 密码需要解锁应用加密”；
- 同时允许用户输入本次密码直接连接；
- 不把用户本次输入自动覆盖原有密文，除非用户明确选择记住并完成解锁或降级确认。

## 4. vncrecord secret envelope 方案

### 4.1 不增加云表和字段

继续只使用用户部署的 vncrecord。

继续使用现有 19 个字段：

    id, userid, recordtype, ownerid, ownertype, secretkind, payload,
    ciphertext, envelopeversion, cryptoversion, keyversion, aadversion,
    payloadhashsha256, syncversion, schemaversion, resetepoch,
    createdat, updatedat, deletedat

不新增：

    vncsecrets
    vncpasswords
    vncsettings
    vncgateways

### 4.2 加密 envelope

现有数据保持不变：

    payload.storageMode = encrypted_v2
    envelopeversion = 2
    cryptoversion = 2
    keyversion = 1
    aadversion = 1
    ciphertext = 2:<header>:<iv>:<ciphertext+tag>

AAD 继续绑定：

    remotedesktop|vnc
    vncrecord
    recordId
    ciphertext
    schemaVersion
    keyVersion
    aadVersion

### 4.3 用户明确选择的未加密 envelope

新增一个明确、可校验的未加密封装，例如：

    payload.storageMode = plain_explicit_v1
    envelopeversion = 1
    cryptoversion = 0
    keyversion = 0
    aadversion = 0
    ciphertext = plain-v1:<bounded-encoded-secret>

要求：

- ciphertext 是现有云表字段名，内部语义应统一称为 secretEnvelope；
- plain-v1 不是加密，只是版本化编码和格式标记；
- 不能把密码放进 payload、label、普通日志或卡片；
- 校验必须拒绝缺少前缀、空值、超长值和未知明文 envelope；
- 读取时只有 storageMode=plain_explicit_v1 且用户此前明确确认过未加密保存/同步，才允许作为凭据使用；
- 旧的 encrypted_v2 secret 仍必须通过 DataCrypto 解锁后才能读取；
- 未知 envelope 必须 fail-closed，不得猜测为明文。

### 4.4 Secret metadata

secret payload 继续只保存非敏感元数据，建议从：

    {"kind":"vnc_password","label":"Mac"}

扩展为：

    {"kind":"vnc_password","label":"Mac","storageMode":"plain_explicit_v1"}

旧的 encrypted_v2 记录没有 storageMode 时按旧版本规则解释为 encrypted_v2，保证向后兼容。

## 5. 云同步解耦方案

### 5.1 VNC selection policy

调整 VncCloudSyncSelectionPolicy：

- vncSecretSyncAllowed 不再接收 cryptoReady 作为许可条件；
- 许可条件只包含“secret scope 已选中”和“物理表 vncrecord 已选中”；
- 可以保留另一个只读能力函数，用于 UI 展示“当前新 secret 将使用 encrypted_v2 / plain_explicit_v1”；
- vncSyncNeedsCrypto 不再决定是否能同步，只用于计算 encrypted secret 的传输依赖。

### 5.2 CloudStore VNC 分支

调整 CloudStore:4290 附近逻辑：

- 非 secret 记录继续按 scope 写入本地和云端；
- secret 记录只检查物理表和 secret scope，不再检查 DataCrypto.isReady()；
- loadVncRecordsFromTable 不因 crypto locked 而隐藏整个 secret row；
- VncSecretService.load 再根据 envelope 类型决定：解密、读取明文 envelope，或返回 locked/invalid 状态；
- 加密 secret 在锁定设备上必须保持 opaque，禁止转换为空 secret、删除或覆盖；
- 未加密 secret 在未启用 crypto 的设备上可以正常读取；
- 删除 secret 是结构性操作，不需要解密，应允许在 crypto locked 状态执行并产生正常 tombstone。

### 5.3 CloudSyncCoordinator

调整 vncSyncTables：

- 选中任意 VNC metadata scope 时，可以同步 vncrecord，不要求 cryptoparams；
- 选中 secret scope 时仍同步 vncrecord；
- 只有当前传输集合中存在 encrypted_v2 secret 时，cryptoparams 才作为解密依赖参与排序；
- plain_explicit_v1 secret 不要求 cryptoparams；
- 即使设备无法解密 encrypted_v2，仍应完成云行拉取并保留 opaque row，不得用空本地快照覆盖云端；
- 继续沿用现有 cloud-first barrier、启动空数据保护、scope 关闭不反向 tombstone 和单队列串行同步。

### 5.4 VNC 设置页文案与交互

替换当前“未解锁，密码/令牌不可保存”的绝对阻断文案：

| crypto 状态 | 建议文案 |
| --- | --- |
| disabled | 应用加密未启用；记住的密码可按明文策略保存，开启云同步前会再次确认风险 |
| locked | 应用加密已锁定；已保存的加密凭据需要解锁，仍可临时输入密码连接 |
| unlocked | 应用加密已解锁；记住的密码将使用 AES-GCM 保存 |

开启 secrets scope 时：

- unlocked：确认对话框说明密码使用 AES-GCM v2；
- disabled：确认对话框明确说明将以未加密形式进入 vncrecord，用户确认后开启；
- locked：允许选择 scope，但提示新 encrypted secret 需要解锁；不把 scope 开关本身阻断。

开启 trust scope 不再要求 crypto ready；仍保留新设备人工确认 trust 的规则。

## 6. 关闭应用加密与旧数据迁移

当前关闭全局加密流程会因为存在 VNC encrypted secret 而直接失败：

- entry/src/main/ets/pages/HostListPage.ets:7302
- entry/src/main/ets/services/CloudStore.ets:2416

快速修复必须把这个阻断改为可解释迁移：

1. 用户输入主密码确认关闭；
2. 在 DEK 仍然可用时扫描本地 overlay、当前 vncrecord 和兼容旧表；
3. 将 active encrypted_v2 VNC secret 解密并转换为 plain_explicit_v1；
4. 保留 owner、secret kind、record ID、sync version、reset epoch 和 tombstone 关系；
5. 先提交并推送 vncrecord 明文 envelope；
6. 再按现有流程处理其他协议的明文迁移；
7. 最后发布 disabled 状态、清除 crypto 参数和内存 DEK；
8. 迁移失败时回滚事务，保持应用加密 active，不发布半成品 disabled 信号。

现有 encrypted_v2 secret 在应用加密仍处于 locked 状态时不允许静默降级；用户必须解锁并明确确认关闭加密，或先删除对应 secret。

多设备关闭加密必须继续遵守 cloud-first 顺序：先完成 VNC secret envelope 迁移，再发布 cryptoparams=disabled，防止接收设备先清除解密参数而收到仍为 v2 的旧 secret。

## 7. 文件级实施顺序

本计划实施时必须在新的 codex/<task> 任务分支或用户明确授权的本地 main 上，按小提交推进；不得一次性修改无关协议文件。

### Commit 1：VNC 凭据策略和模型测试

预计文件：

- entry/src/main/ets/services/VncSecretStoragePolicy.ets（新增，纯策略）；
- entry/src/main/ets/services/VncRecordPolicy.ets；
- entry/src/main/ets/model/VncRecord.ets（如需补充 storage mode 类型）；
- entry/src/test/VncSecretStoragePolicy.test.ets；
- entry/src/test/VncRecordPolicy.test.ets；
- 测试注册文件。

内容：

- 定义 disabled / locked / unlocked 与 remember 的组合策略；
- 定义 encrypted_v2 / plain_explicit_v1；
- 验证 secret payload 不出现密码/token/ciphertext 字段；
- 验证 malformed plain envelope、unknown envelope 和越界值 fail-closed。

### Commit 2：VNC Secret Service 解耦

预计文件：

- entry/src/main/ets/services/VncSecretService.ets；
- entry/src/main/ets/services/VncHostService.ets；
- entry/src/main/ets/services/VncGatewayService.ets；
- entry/src/main/ets/services/VncSecretStoragePolicy.ets。

内容：

- disabled + remember=true 写入 plain_explicit_v1；
- unlocked + remember=true 写入 encrypted_v2；
- locked + remember=true 返回可区分的 unlock_required；
- remember=false 不创建 secret row；
- load 返回 available / missing / locked / invalid 等状态，不能把 locked 当成空密码；
- 删除 secret 在 locked 状态下按 ID 安全执行，不需要先解密；
- Gateway token 使用同一套规则，但不进入主机密码路径。

### Commit 3：VNC 添加和连接临时密码

预计文件：

- entry/src/main/ets/components/hostadd/VncAddFlow.ets；
- entry/src/main/ets/pages/HostListPage.ets 的 VNC 分支；
- entry/src/main/ets/pages/RemoteDesktop.ets 的 VNC 分支；
- 新增 VNC 专用 transient credential/session intent policy 和测试。

内容：

- 添加“记住密码”开关；
- 不记住时保存 metadata 但不写 secret；
- 新增 VNC 认证 Sheet；
- 不通过 router 参数传密码；
- 连接取消、后台、断开和 generation 变化时清除临时凭据；
- RustDesk/RDP/SSH 的认证 Sheet、字段和生命周期不复用、不改动。

### Commit 4：VNC 云同步解耦

预计文件：

- entry/src/main/ets/services/VncCloudSyncSelectionPolicy.ets；
- entry/src/main/ets/services/VncCloudSyncSelectionStore.ets；
- entry/src/main/ets/services/VncCloudSyncService.ets；
- entry/src/main/ets/services/CloudStore.ets 的 VNC 分支；
- entry/src/main/ets/services/CloudSyncCoordinator.ets 的 VNC 分支；
- entry/src/main/ets/pages/VncSettingsPage.ets；
- VNC cloud policy tests。

内容：

- secret/trust scope 可独立选择；
- metadata sync 不依赖 crypto；
- plain secret 不依赖 cryptoparams；
- encrypted secret 只把 cryptoparams 作为依赖，不把它作为整个 VNC table 的开关；
- 云端 encrypted row 在 locked 设备上保持 opaque，不被空数据覆盖；
- scope 取消继续不写反向 cloud tombstone。

### Commit 5：关闭加密迁移与回归门禁

预计文件：

- entry/src/main/ets/services/CloudStore.ets 的 VNC decrypt/migration 分支；
- entry/src/main/ets/pages/HostListPage.ets 的关闭加密分支；
- entry/src/test/CloudStoreMutationPolicy.test.ets；
- entry/src/test/CloudSyncCoordinatorPolicy.test.ets；
- entry/src/test/VncRecordPolicy.test.ets。

内容：

- encrypted_v2 -> plain_explicit_v1 事务迁移；
- 删除 secret 不再被 crypto lock 阻断；
- 迁移失败不发布 disabled；
- 多设备 disabled 状态按 cloud-first 顺序传播。

## 8. 测试矩阵

### 8.1 单设备测试

| 场景 | 预期 |
| --- | --- |
| crypto disabled + remember off + TCP 直连 | 可以保存 host metadata，连接时输入密码成功 |
| crypto disabled + remember on + cloud secrets off | 本地可重连，云端没有 secret row |
| crypto disabled + remember on + cloud secrets on | 风险确认后保存 plain_explicit_v1，可重启使用 |
| crypto unlocked + remember on | 保存 encrypted_v2，连接和重启恢复正常 |
| crypto locked + remember off | 可以一次性输入密码连接，不写入 secret |
| crypto locked + remember on | 提示解锁或改为本次连接，不覆盖原有密文 |
| 无密码 VNC server | 仅在服务端确实提供 None auth 时允许；不能把空密码当作 Mac VNC 密码 |
| 切后台/锁屏 | 临时密码清除；回前台不自动恢复明文 |
| 删除已保存 secret | 即使 crypto locked，也能删除并产生正确 tombstone |

### 8.2 多设备测试

1. A 设备未启用 crypto，只同步 host metadata；B 设备拿到主机但每次输入密码。
2. A 设备未启用 crypto，明确确认同步 secret；B 设备未启用 crypto，可以读取 plain_explicit_v1。
3. A 设备启用 crypto 并同步 encrypted_v2；B 设备未解锁时保留 opaque row，不显示、不覆盖。
4. B 设备解锁后读取 A 的 encrypted_v2 secret。
5. 新设备本地为空时，cloud-first 拉取 VNC 数据，不能把空集合推回云端。
6. 关闭 VNC secret scope 后，不产生反向 cloud tombstone。
7. trust scope 在未启用 crypto 时也能同步，但新设备必须人工确认。
8. A 设备关闭全局 crypto 后，VNC encrypted_v2 先迁移为 plain_explicit_v1，再同步 disabled 状态。
9. 云端存在 encrypted secret，而 B 设备 crypto locked 时，B 的本地编辑、空默认值和 scope 变化不能覆盖 A 的云行。

### 8.3 Mac 真机验收

最短回归路径：

    应用加密未启用
      -> VNC FAB
      -> TCP 直连
      -> rememberPassword=false
      -> 保存并连接
      -> RemoteDesktop VNC 密码 Sheet
      -> 输入 Mac VNC 密码
      -> 成功进入 Mac 桌面

第二条路径：

    应用加密未启用
      -> rememberPassword=true
      -> 明文保存风险确认
      -> 保存并连接
      -> 退出应用重新进入
      -> 直接连接或按云同步策略恢复

## 9. 不影响其他模组的约束

必须保持以下边界：

- 不给 RemoteHost 增加 VNC 密码字段；
- 不把 VNC secret 写入 remotehosts；
- 不把 VNC Gateway token 写入 rustdeskrelays；
- 不改变 RustDesk 的 rustDeskAuthRememberPassword 和 Pro session persistence；
- 不改变 RDP credential、SSH key、TOTP 的现有 DataCrypto 策略；
- 不改变通用 usersettings 的业务语义；
- 不把 VNC transient password 放入普通备份、日志、路由参数或卡片；
- 不改变 VNC WebSocket Gateway、SSH tunnel、PUBLIC relay、Repeater mode2 的 fail-closed 状态；
- 不新增云表，不修改用户需要部署的 vncrecord 字段；
- 继续使用现有 CloudStore + CloudSyncCoordinator 正式云链路，不接入旧 REST CloudSyncService。

## 10. 实施顺序与验收门禁

实施时按照项目既定开发闭环：

    确认 main 基线
      -> 任务分支或已授权本地 main
      -> Commit 1 策略/测试
      -> Commit 2 secret owner
      -> Commit 3 临时连接/UI
      -> Commit 4 云同步
      -> Commit 5 加密迁移
      -> 子 agent 复核
      -> 修复并重新验证
      -> 合并回 main
      -> 清理已合并分支

每个影响代码的提交都必须执行：

    source scripts/macos_env.sh
    hvigorw --mode module -p module=entry -p product=default default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon
    hvigorw --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --no-daemon
    git diff --check

VNC 相关策略、云同步和 native 连接测试还必须执行定向测试。ohosTest 的 00306054 task not registered 只能记录为当前环境 blocker，不能写成测试通过。

## 11. 风险、回滚和发布策略

### 11.1 主要风险

- 明文 secret 云同步会增加账号云端泄露风险；必须默认关闭 secret scope，并在开启时二次确认。
- 已有 encrypted_v2 secret 在 crypto locked 设备上不能被误判为空；必须保持 opaque。
- disabled 状态与 locked 状态迁移不完整，会导致密文丢失；迁移必须事务化并在清除 crypto 参数前完成。
- CloudStore 是共享基础设施，VNC 分支修改必须有 RDP/RustDesk/SSH 回归测试。
- transient password 如果通过 router params 传递，会被日志、恢复或调试信息暴露，必须使用内存 session intent。

### 11.2 回滚原则

- encrypted_v2 记录格式保持向后兼容，旧版本仍能识别并拒绝错误使用；
- plain_explicit_v1 只由新版本创建，旧版本遇到未知 secret envelope 必须 fail-closed，不得把它当作 host metadata；
- 若真机验收发现云同步或迁移问题，回滚 UI/connection commits 不应删除已有 vncrecord；
- 任何失败迁移不得清除 cryptoparams、不得写入反向 tombstone、不得用空本地快照覆盖云端。

## 12. 完成定义

只有满足以下条件才可称为本计划完成：

- 未启用应用加密时，Mac VNC 可以通过一次性密码直接连接；
- VNC 添加流程有明确“记住密码”开关；
- 记住密码、云同步和应用加密三者行为独立且有清晰风险文案；
- vncrecord 仍是唯一 VNC 云表，不增加新表或新字段；
- encrypted_v2、plain_explicit_v1、locked、disabled 四类凭据状态均有测试；
- 多设备 cloud-first 和空本地防覆盖回归通过；
- 关闭应用加密不再因 VNC 密文直接阻断，而是完成可回滚迁移；
- RDP、RustDesk、SSH/SFTP 的功能和云同步回归通过；
- API 23 ArkTS 编译、assembleHap、定向测试、Light 合规门禁均通过；
- 真机 Mac VNC 直连通过；
- 本计划实施完成后才允许提交远端 PR；本计划本身不触发远端操作。
