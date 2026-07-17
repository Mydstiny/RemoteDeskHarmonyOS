# 添加主机向导与 RustDesk 认证信任优化实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在手机和平板提供默认启用的分步添加主机向导，完整支持 RDP、RustDesk、SSH，预埋 VNC，并补齐 RustDesk LAN 发现、连接前鉴权、对象卡标签、认证信任集中管理及所有关联页面的实时刷新。

**Architecture:** 保留当前经典添加 Sheet 作为兼容路径，将新版流程从 `HostListPage.ets` 拆为独立向导容器、协议步骤组件、纯状态模型和复用型选择器。主机、Windows 凭据、RustDesk 中继、SSH 密钥与认证信任统一经现有 Service 写入并发出数据变更通知；向导只保存草稿，最终确认时原子化创建主机，可选择“保存”或“保存并连接”。

**Tech Stack:** HarmonyOS NEXT API 23、ArkTS、ArkUI `bindSheet`、Hypium、现有 `HostSyncService`、`KeyVaultService`、`RustDeskLanDiscoveryService` 和 RustDesk FFI。

## 实施状态（2026-07-17）

- 已完成并提交：新版/经典入口、四协议选择器、RDP 凭据流程、RustDesk 中继/直连/LAN 流程、SSH 密码/保险库密钥流程、RustDesk 卡片标签、普通/Pro 共用后台预鉴权及数据安全认证信任管理。
- 自动验证：各检查点均通过 `default@OhosTestCompileArkTS` 和生产 `assembleHap`；最终全量门禁结果记录在本任务交付说明。
- 最终实机验收保留：手机/Pad 的 Sheet 与键盘布局、真实 Windows 凭据登录、RustDesk LAN 广播与远端连接、远端批准、SSH 私钥文件选择和真实服务器登录。
- VNC 仍按原约束仅预埋入口，不实现连接。

## Global Constraints

- 仅手机和 Pad 的 FAB 默认进入新版向导；PC 不改变现有添加入口。
- “个性化 > 添加主机方式”默认选择“全新模式”，经典模式继续打开当前 Sheet。
- 编辑已有主机复用当前编辑 Sheet，只优化视觉，不改成新增向导。
- VNC 仅显示预埋/即将支持状态，本轮不实现连接。
- 直连 RustDesk 只允许密码认证，不允许请求远端批准。
- RustDesk 密码必须支持一次性密码和永久密码。
- 密码与私钥不得明文出现在日志、卡片或数据安全摘要中。
- 保存凭据、中继、密钥、主机或认证偏好后，所有外部缩略卡、内部详情、计数器和选择器必须实时刷新。
- 不提交 `.appanalyzer/`、`docs/VNC_UPGRADE_DESIGN.md` 或用户现有 VNC 计划文件。

---

## 目标文件结构

### 新建

- `entry/src/main/ets/components/hostadd/HostAddWizardSheet.ets`：新版向导容器、步骤导航、返回/取消/保存。
- `entry/src/main/ets/components/hostadd/HostProtocolPicker.ets`：RDP、RustDesk、SSH、VNC 四协议入口。
- `entry/src/main/ets/components/hostadd/RdpAddFlow.ets`：RDP 基础信息与认证方式步骤。
- `entry/src/main/ets/components/hostadd/RustDeskAddFlow.ets`：直连/中继分支、密码模式与最终确认。
- `entry/src/main/ets/components/hostadd/SshAddFlow.ets`：SSH 基础信息与密码/密钥分支。
- `entry/src/main/ets/components/hostadd/RustDeskLanDiscoverySheet.ets`：扫描状态、结果选择、端口确认。
- `entry/src/main/ets/components/hostadd/WindowsCredentialPickerSheet.ets`：选择、添加并自动回选凭据。
- `entry/src/main/ets/components/hostadd/RustDeskRelayPickerSheet.ets`：选择、添加并自动回选中继。
- `entry/src/main/ets/components/hostadd/SshKeyPickerSheet.ets`：选择、导入并自动回选密钥。
- `entry/src/main/ets/model/HostAddDraft.ets`：跨步骤草稿、验证和 `RemoteHost` 转换。
- `entry/src/main/ets/model/RustDeskAuthTrust.ets`：每主机默认认证方式、密码记忆与更新时间模型。
- `entry/src/main/ets/services/RustDeskAuthTrustService.ets`：认证信任 CRUD、迁移和通知。
- `entry/src/main/ets/components/RustDeskAuthTrustSheet.ets`：数据安全中的信任摘要、编辑和删除。
- 对应 `entry/src/test/` 与 `entry/src/ohosTest/ets/test/` 策略测试文件。

### 重点修改

- `entry/src/main/ets/pages/HostListPage.ets`：FAB 模式路由、向导接入、保存并连接、RustDesk 卡片标签。
- `entry/src/main/ets/pages/RustDeskRelayPage.ets`：中继新增后实时替换列表与详情快照。
- `entry/src/main/ets/pages/KeyVaultPage.ets`：SSH 密钥选择/导入后的实时刷新。
- `entry/src/main/ets/services/HostSyncService.ets`：统一保存入口及认证信任迁移协调。
- `entry/src/main/ets/services/KeyVaultService.ets`：密钥新增后通知选择器和保险库。
- `entry/src/main/ets/services/CloudStore.ets`：仅在现有 schema 能兼容时持久化新增偏好；敏感密码继续走既有加密链。
- `entry/src/main/ets/services/CloudSyncSettingsPolicy.ets`：同步新增的“添加主机方式”设置。
- 设置页相关组件：将“外观”改为“个性化”，增加模式配置；数据安全增加 RustDesk 认证信任入口。

---

### Task 1：冻结当前端口修复并建立回归基线

**Files:**
- Modify: `entry/src/main/ets/pages/HostListPage.ets`
- Modify: `entry/src/main/ets/services/RustDeskHostConfigPolicy.ets`
- Test: `entry/src/ohosTest/ets/test/RustDeskHostConfigPolicy.test.ets`

**Produces:** 已验证的直连端口实时迁移和卡片端点显示基线。

- [ ] 运行现有直连端口策略测试，确认 `21118 → 21117` 只迁移仍跟随旧默认的直连主机。
- [ ] 实机确认卡片立即显示 `rustdeskDirectHost:rustdeskDirectPort` 且 `192.168.31.11:21117` 可连接。
- [ ] 运行 `default@OhosTestCompileArkTS`、`assembleHap`、`git diff --check` 和 Light 合规门。
- [ ] 仅暂存三个端口修复文件并提交 `fix(rustdesk): refresh direct endpoints after port changes`。

### Task 2：建立新版/经典模式设置与 FAB 路由

**Files:**
- Create: `entry/src/main/ets/services/HostAddModePolicy.ets`
- Modify: `entry/src/main/ets/pages/HostListPage.ets`
- Modify: 设置页个性化组件
- Modify: `entry/src/main/ets/services/CloudSyncSettingsPolicy.ets`
- Test: `entry/src/ohosTest/ets/test/HostAddModePolicy.test.ets`

**Produces:** `HostAddMode = 'modern' | 'classic'`，默认 `modern`；手机/Pad 路由新版，PC 保持经典。

- [ ] 先写失败测试：无保存值默认 modern、classic 可持久化、PC 强制经典入口。
- [ ] 实现纯策略 `resolveHostAddMode(savedMode, isDesktopDevice)`。
- [ ] 将“外观”改名“个性化”，增加“添加主机方式”卡片和“全新模式/经典模式”选项。
- [ ] FAB 点击时依据策略打开 `showModernAddWizard` 或现有 `showAddSheet`。
- [ ] 验证模式切换立即生效，重启 App 后保持，云设置恢复后页面同步。
- [ ] 提交 `feat(hosts): add modern and classic add modes`。

### Task 3：拆出向导状态模型和四协议入口

**Files:**
- Create: `entry/src/main/ets/model/HostAddDraft.ets`
- Create: `entry/src/main/ets/components/hostadd/HostAddWizardSheet.ets`
- Create: `entry/src/main/ets/components/hostadd/HostProtocolPicker.ets`
- Test: `entry/src/ohosTest/ets/test/HostAddDraft.test.ets`

**Produces:** 可返回且不丢字段的步骤状态机；`toRemoteHost()` 仅在最终确认时生成对象。

- [ ] 写失败测试覆盖协议切换、前进/后退、取消不持久化、字段保留和最终验证。
- [ ] 定义 `HostAddStep`、`HostAddDraft`、`validateCurrentStep()` 和 `toRemoteHost()`。
- [ ] 实现四协议卡片；VNC 显示“即将支持”且不进入空流程。
- [ ] 实现统一标题、步骤指示、返回、取消、下一步和底部安全区。
- [ ] 验证手机竖屏、Pad 竖屏/横屏布局和键盘避让。
- [ ] 提交 `refactor(hosts): introduce host add wizard shell`。

### Task 4：RDP 分步添加与 Windows 凭据复用

**Files:**
- Create: `entry/src/main/ets/components/hostadd/RdpAddFlow.ets`
- Create: `entry/src/main/ets/components/hostadd/WindowsCredentialPickerSheet.ets`
- Modify: Windows 凭据现有编辑 Sheet，使其可由设置页和向导共同调用
- Modify: `entry/src/main/ets/pages/HostListPage.ets`
- Test: `entry/src/ohosTest/ets/test/RdpAddFlowPolicy.test.ets`

**Produces:** 基础信息 → 账号密码/Windows 凭据 → 保存或保存并连接。

- [ ] 写失败测试覆盖端口默认值、账号密码验证、凭据 ID 绑定及新凭据自动回选。
- [ ] 第一步实现名称、地址、端口和用户名基础字段。
- [ ] 第二步实现“账号密码”和“Windows 凭据”二选一。
- [ ] 抽取可复用凭据编辑 Sheet；空列表显示“添加凭据”，保存后自动选择。
- [ ] 监听 `HostSyncService.onDataChange()`，实时刷新设置页凭据缩略卡、展开卡、数量和绑定主机数。
- [ ] 实现保存与保存并连接，连接失败保留主机并返回错误信息。
- [ ] 提交 `feat(rdp): add credential-aware host wizard`。

### Task 5：RustDesk 中继添加流程和中继选择器

**Files:**
- Create: `entry/src/main/ets/components/hostadd/RustDeskAddFlow.ets`
- Create: `entry/src/main/ets/components/hostadd/RustDeskRelayPickerSheet.ets`
- Modify: `entry/src/main/ets/pages/RustDeskRelayPage.ets`
- Modify: 中继现有编辑 Sheet，使其可复用
- Test: `entry/src/ohosTest/ets/test/RustDeskAddFlowPolicy.test.ets`

**Produces:** 中继选择/新增 → 名称、控制 ID、可选密码、一次性/永久模式 → 保存。

- [ ] 写失败测试覆盖无中继阻断、新中继自动回选、空密码允许保存和密码模式映射。
- [ ] 实现直连/中继第一步选择，本任务先完成中继分支。
- [ ] 复用中继编辑 Sheet；保存后更新选择器并自动选中新 ID。
- [ ] 修复中继页列表、PC 详情和移动展开卡快照替换，确保 API 地址等立即显示。
- [ ] 实现名称、控制 ID、可选密码及一次性/永久密码选择。
- [ ] 保存后主机卡、计数器和中继绑定信息实时刷新。
- [ ] 提交 `feat(rustdesk): add relay host wizard flow`。

### Task 6：RustDesk 直连手动配置与 LAN 发现

**Files:**
- Create: `entry/src/main/ets/components/hostadd/RustDeskLanDiscoverySheet.ets`
- Modify: `entry/src/main/ets/components/hostadd/RustDeskAddFlow.ets`
- Modify: `entry/src/main/ets/services/RustDeskLanDiscoveryService.ets`
- Test: `entry/src/ohosTest/ets/test/RustDeskLanDiscoveryService.test.ets`

**Produces:** 手动配置或 LAN 搜索；选择结果后确认 IP、端口和密码。

- [ ] 写失败测试覆盖扫描去重、超时、取消、结果映射和自定义端口保留。
- [ ] 手动分支填写名称、控制 ID、IP、端口、密码及密码模式。
- [ ] 明确展示“直连不支持请求批准，只能使用设备密码”。
- [ ] LAN Sheet 展示扫描中、空结果、错误、重试和发现结果列表。
- [ ] 选择结果后回填名称、控制 ID、IP；端口默认采用用户当前直连默认值并允许修改。
- [ ] 提供“保存”和“保存并连接”；连接前验证端口范围和密码非空。
- [ ] 实机验证 UDP 21119 广播、响应解析和自定义 21117 连接。
- [ ] 提交 `feat(rustdesk): add LAN discovery host flow`。

### Task 7：普通 RustDesk 主机连接前鉴权

**Files:**
- Create/Extract: `entry/src/main/ets/components/RustDeskConnectionAuthSheet.ets`
- Modify: `entry/src/main/ets/pages/HostListPage.ets`
- Modify: 现有 Pro 鉴权逻辑以复用组件
- Test: `entry/src/ohosTest/ets/test/RustDeskConnectionAuthPolicy.test.ets`

**Produces:** 普通中继和 Pro 共用的密码/请求批准 Sheet；直连强制密码。

- [ ] 写失败测试覆盖已有密码直接连接、空密码提示、请求批准、记住选择、取消和直连限制。
- [ ] 抽取 UI 组件但保留现有后台预鉴权状态机，避免先路由后鉴权。
- [ ] 中继允许“密码/请求批准”；直连仅显示密码并解释限制。
- [ ] 用户选择记住时保存默认方式；密码记忆单独控制。
- [ ] 远端拒绝、密码错误和超时均留在主机页显示可重试错误。
- [ ] 实机验证一次性密码、永久密码、远端批准和取消四条路径。
- [ ] 提交 `refactor(rustdesk): unify connection authorization sheets`。

### Task 8：SSH 分步添加与密钥保险库复用

**Files:**
- Create: `entry/src/main/ets/components/hostadd/SshAddFlow.ets`
- Create: `entry/src/main/ets/components/hostadd/SshKeyPickerSheet.ets`
- Modify: SSH 密钥现有编辑/导入 Sheet
- Modify: `entry/src/main/ets/services/KeyVaultService.ets`
- Test: `entry/src/ohosTest/ets/test/SshAddFlowPolicy.test.ets`

**Produces:** 基础信息 → 密码/密钥 → 选择或导入密钥 → 保存或保存并连接。

- [ ] 写失败测试覆盖端口默认值、密码/密钥互斥、密钥 ID 绑定和导入后自动回选。
- [ ] 第一步实现名称、地址、端口和用户名。
- [ ] 第二步实现密码登录或密钥登录。
- [ ] 密钥选择器复用保险库服务；空列表可新增，从文件导入必须使用文档选择器而不是图库。
- [ ] 导入成功后写入保险库、自动选择，并实时刷新保险库缩略卡、详情和数量。
- [ ] 保留私钥口令和代理配置能力，敏感内容不写日志。
- [ ] 提交 `feat(ssh): add key-aware host wizard`。

### Task 9：RustDesk 对象卡“直连/中继/Pro”标签

**Files:**
- Create: `entry/src/main/ets/services/RustDeskCardBadgePolicy.ets`
- Modify: `entry/src/main/ets/pages/HostListPage.ets`
- Test: `entry/src/ohosTest/ets/test/RustDeskCardBadgePolicy.test.ets`

**Produces:** `resolveRustDeskBadges(host): string[]`，支持 `直连`、`中继`、`Pro + 中继`。

- [ ] 写失败测试覆盖普通直连、普通中继、Pro 中继及旧数据回退。
- [ ] 在 RustDesk 对象卡右上角复用 Pro 胶囊视觉渲染标签。
- [ ] 标签只读取主机实际保存字段，不读取全局直连开关。
- [ ] 编辑连接模式、Pro 同步或云恢复后立即刷新标签和端点。
- [ ] 提交 `feat(rustdesk): label host connection modes`。

### Task 10：数据安全中的 RustDesk 认证信任管理

**Files:**
- Create: `entry/src/main/ets/model/RustDeskAuthTrust.ets`
- Create: `entry/src/main/ets/services/RustDeskAuthTrustService.ets`
- Create: `entry/src/main/ets/components/RustDeskAuthTrustSheet.ets`
- Modify: 数据安全设置页
- Modify: `entry/src/main/ets/model/RemoteHost.ets` 或现有兼容持久化字段
- Test: `entry/src/ohosTest/ets/test/RustDeskAuthTrustService.test.ets`

**Produces:** 可查看、编辑、删除和批量清除的每主机默认认证策略。

- [ ] 写失败测试覆盖旧主机字段迁移、编辑方式、清除密码、删除信任但保留主机、批量清除和直连约束。
- [ ] 列表展示主机名、控制 ID、连接类型、默认认证方式、密码类型、是否记住密码和更新时间。
- [ ] 密码仅显示“已保存/未保存”，严禁显示明文。
- [ ] 编辑中继/Pro 的密码或请求批准；直连禁用请求批准。
- [ ] 将“清除认证偏好”和“清除已保存密码”拆为独立操作。
- [ ] 删除信任记录后恢复“每次询问”，不删除主机、中继或 Pro 地址簿对象。
- [ ] 服务发出统一通知，连接 Sheet、数据安全摘要和主机详情同时刷新。
- [ ] 提交 `feat(security): manage RustDesk authentication trust`。

### Task 11：经典编辑 Sheet 视觉优化与组件复用收口

**Files:**
- Modify: `entry/src/main/ets/pages/HostListPage.ets`
- Create/Modify: 通用字段组、选择器和说明组件

**Produces:** 编辑已有主机仍使用经典逻辑，但视觉分组与新版向导一致。

- [ ] 为 RDP、RustDesk、SSH 按“基础信息/认证/高级设置”分组。
- [ ] 统一标题、间距、错误提示、必填标识、密码可见按钮和底部操作区。
- [ ] 删除向导和经典 Sheet 重复的凭据、中继、密钥编辑实现，只保留共享组件。
- [ ] 验证编辑后卡片、详情、选择器和计数器立即刷新。
- [ ] 提交 `refactor(hosts): polish and reuse host editor sheets`。

### Task 12：端到端实时刷新审计和发布验证

**Files:**
- Test: 所有新增策略测试
- Update: `docs/SSH_KEY_IMPORT_FIX_PLAN.md` 或当前综合修复计划的完成状态
- Update: Codex `CURRENT.md`、`QUEUE.md`

**Produces:** 可提交的完整功能与实机验收记录。

- [ ] 自动验证：新增定向测试、`default@OhosTestCompileArkTS`、`assembleHap`、RustDesk FFI 测试、`git diff --check`、Light 合规门。
- [ ] 手机验证：新版/经典模式、键盘避让、每一步返回、取消无脏数据、保存与保存并连接。
- [ ] Pad 验证：竖屏/横屏 Sheet 尺寸、步骤布局、扫描结果和选择器嵌套 Sheet 生命周期。
- [ ] RDP 验证：账号密码、已有凭据、新增凭据自动回选、设置页实时刷新。
- [ ] RustDesk 验证：中继新增实时刷新、普通/Pro 鉴权、直连 21117、LAN 发现、一次性/永久密码、卡片标签。
- [ ] SSH 验证：密码、保险库密钥、文件导入、密钥口令、保存并连接及保险库实时刷新。
- [ ] 数据安全验证：认证信任编辑、删除、清密码、批量清除及连接弹窗同步。
- [ ] 检查升级兼容：旧主机、旧凭据、旧中继和旧认证字段无需用户重新创建。
- [ ] 仅暂存本计划范围文件，完成最终提交；随后 push、PR、required check 和 merge 流程另行执行。

---

## 实施顺序与检查点

1. Task 1 独立提交当前已验证端口修复。
2. Task 2–3 建立架构检查点，确认经典模式无回归后再继续协议流程。
3. Task 4、5、6、8 每个协议单独提交并实机验收，避免多协议同时失效。
4. Task 7 在普通中继流程稳定后再复用 Pro 鉴权，避免破坏已通过的 Pro 连接。
5. Task 9–10 最后接入展示和安全管理，依赖前面稳定的数据模型。
6. Task 11 只做复用和视觉收口，不新增业务行为。
7. Task 12 完成全量验收后才宣称功能完成。

## 非目标

- 本轮不实现 VNC 协议连接。
- 不重写 RustDesk FFI 传输协议或服务端。
- 不将已有主机编辑全面改造成分步向导。
- 不自动覆盖用户已自定义的 RustDesk 直连端口。
- 不在 LAN 发现结果中伪造远端未返回的自定义端口。
