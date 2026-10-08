# RemoteDesktop Pro 下一阶段产品与实施计划

- 日期：2026-10-02
- 计划版本：1.0
- 状态：PLANNING_ONLY（只定义范围和验收，不授权实现、收费或发布）
- 当前工作区：继续活动分支 codex/pro-purchase-foundation；禁止创建持久 worktree 或新分支
- 适用平台：HarmonyOS Phone / Pad / PC，开发基准 API 26，保留 API 23 安装兼容核对
- 相关代码：entry/src/main/ets/services/pro/ProFeatureCatalog.ets
- 相关现状：[共享队列](../QUEUE.md)、[RDP/RustDesk 显示计划](2026-10-01-rdp-rustdesk-pro-display-resolution-scale-plan.md)、[工作区与主机管理计划](2026-09-30-pro-workspaces-host-management-plan.md)

> 本计划是产品和工程设计文件。写入本文件不等于新增功能已实现、已通过审查、已通过真机/远端矩阵、已部署后端或已开放正式购买。当前工作区已有其他未提交改动，实施前必须先完成独立审查和 checkpoint；本计划不得覆盖或重置那些改动。

---

## 1. 目标与范围

### 1.1 产品目标

当前 Pro 目录已经覆盖：

- 工作区与布局；
- 高级主机管理；
- RDP / RustDesk 高级显示；
- 诊断与 AI 帮助；
- 电脑端远程 AI；
- 个性化方案和预设应用图标；
- 碰一碰传文件、连接分享、同账号接续；
- Pro 反馈；
- USB FIDO2 和手机通行密钥探索。

下一阶段不继续堆叠装饰性入口，而是补齐三类长期价值：

1. 可靠性：让用户知道主机为什么不可用，能够复现和提交证据。
2. 效率：让跨协议连接、文件任务和常用操作可重复执行。
3. 一致性：让显示方案、传输任务和工作区在主机与设备之间有稳定的恢复语义。

### 1.2 本计划包含的候选功能

| 代号 | 建议 feature ID | 功能 | 首发状态 | 首发范围 |
|---|---|---|---|---|
| H | pro.hostHealth | 主机健康中心 | experimental | 所有设备；RDP、RustDesk、SSH、VNC、Moonlight |
| T | pro.transfer.resumable | 增强传输中心 | experimental | SSH / RustDesk 优先，RDP 受通道限制 |
| E | pro.session.evidence | 会话证据包 | experimental | 所有设备；先截图和结构化时间线，再评估录屏 |
| D | 复用 pro.display.rdpAdvanced、pro.display.rustdeskAdvanced；必要时新增 pro.display.multiMonitor | 显示方案与多屏 | experimental | RDP / RustDesk；VNC 仅支持已证明的厂商协议 |
| A | pro.automation.recipe | 跨协议自动化方案 | planned | 工作区、SSH Snippet、端口转发和受控连接编排 |
| S | pro.connection.guestInvite | 短时访客邀请 | planned | 连接分享扩展；需要 App Linking、后端和跨设备验收 |

以下内容不纳入现有一次性 pro.lifetime 的首发承诺：

- 团队成员、RBAC、共享主机库和审计后台；
- 持续云端监控、云端录屏、托管中继和云存储；
- 需要长期服务器成本的通知、历史保留或跨网服务。

这些应单独评估 Team/Business 或服务型权益，不能悄悄扩大买断承诺。

### 1.3 明确不改变的免费能力

以下能力继续免费，新增 Pro 功能只能叠加增强层：

- RDP、RustDesk、SSH/SFTP、VNC、Moonlight 的核心连接；
- 正常画质、基础输入、现有本地画布缩放和现有文件通道；
- 已有的基础剪贴板、SFTP 文件管理、RustDesk 文件传输；
- 认证、加密、应用锁、主机锁和数据删除等基础安全能力；
- 现有诊断日志的手动抓取、预览、保存和脱敏导出；
- 免费用户已有的工作区、主机和会话数据不能因为新增 Pro 功能而丢失。

---

## 2. 当前基线和前置门禁

### 2.1 已有实现基线

- ProFeatureCatalog 已区分 available、planned、experimental 和 disabled。
- ProEntries.visible() 和 ProRuntime.decision() 已分开控制入口显示与业务执行。
- 工作区、主机组织、连接接续、连接分享、诊断 AI 和 RDP/RustDesk 显示均已有不同程度的实现或计划。
- 诊断 AI 使用脱敏结构化事件、用户自有 Provider 和受控设置建议；Provider、真机、邮件客户端和生产权益验收仍需单独完成。
- RDP/RustDesk 显示计划已完成策略和 native 边界，但当前计划记录的主要 blocker 是 host × device 的显示 profile 运行时接通和真实 peer/设备矩阵。
- SSH 已有 Snippet、命令历史、广播、端口转发和传输中心；新 Pro 自动化只能提供跨协议编排和安全策略，不能把现有免费能力重新收费。
- RDP 文件传输依赖剪贴板/共享驱动通道；VNC 和 Moonlight 没有可以直接承诺的通用远程文件通道。

### 2.2 开始新阶段前的门禁

在 H/T/E/D/A/S 任一阶段开始代码实现前：

1. 读取最新 CURRENT.md、QUEUE.md 和实际 git status --short --branch。
2. 继续当前活动分支；不切换分支、不 stash、不 reset、不覆盖并行改动。
3. 对当前未提交改动做 checkpoint commit 或明确记录范围，避免新计划与旧增量混合。
4. 完成现有 Pro 工作区/主机管理、诊断 AI、M4/M5 和显示 profile 的独立审查路径。
5. 明确该阶段的文件范围、计划 hash、代码范围树和 review receipt。
6. 每个阶段独立提交、独立复核、独立运行构建门禁；不把旧阶段 PASS 复制为新阶段 PASS。

---

## 3. 统一 Pro 产品契约

### 3.1 功能目录

每个新功能必须登记：

| 字段 | 要求 |
|---|---|
| featureId | 稳定、不可复用、可追踪 |
| requiredEntitlementId | 默认 pro.lifetime；有持续成本时另立权益 |
| availability | planned / experimental / available / disabled |
| minAppVersionCode、minApiVersion | 明确升级和系统条件 |
| devices、protocols | 不能用“全平台”掩盖能力差异 |
| capabilities、permissions | 运行时逐项检查 |
| serverAuthorized | 没有后端证据时保持 false |

### 3.2 显示与执行

- 介绍页可以展示 planned 功能，但不能把 planned 写成已交付。
- 入口显示使用 ProEntries.visible() 或 ProFeatureGate。
- 业务 action、异步请求、native dispatch、任务恢复、深链和快捷键必须再次调用 ProRuntime.decision()。
- await 前后、Preferences/RDB 写入前后、Provider 请求前、远端发送前都复查：
  - 当前账号 owner 和 generation；
  - entitlement 状态；
  - feature availability；
  - 设备、协议、能力和权限；
  - 页面/窗口/任务 lease；
  - 当前请求 generation。
- 退款、撤权、账号切换、注销和冷启动失效时：
  - 新 Pro action 立即停止；
  - 免费连接和已经安全运行的免费任务不被强制中断；
  - 未完成的 Pro 任务安全收尾或回滚；
  - 配置保留，但下次 action 必须重新鉴权。

### 3.3 生命周期

所有新增任务都要有：

| 字段 | 用途 |
|---|---|
| accountScopeId、accountGeneration | 账号和代次隔离 |
| featureId、ownerId | 权益和窗口归属 |
| requestGeneration | 丢弃晚到回调 |
| createdAt、updatedAt | 过期和恢复判断 |
| cancel、timeout、revoke state | 可解释地收尾 |

旧账号的晚到回调不能写入新账号；旧窗口的晚到回调不能更新新会话；旧 hostRef 不能复活已删除主机。

---

## 4. 功能 H：主机健康中心（第一优先级）

### 4.1 用户价值

在主机卡片和 Pro 面板中看到：

- 最近一次检查时间；
- 在线、离线、检测中、认证失败、证书/信任失败、路由不可达、能力不支持、超时；
- 最近延迟和连续失败次数；
- RDP 直连/Gateway、RustDesk 直连/中继、SSH 代理、VNC repeater/TLS 等路径；
- IPv4/IPv6 实际获胜路径，而不是只显示配置候选；
- 最近一次可复现的稳定错误码和脱敏证据入口。

首发是用户主动刷新和批量检测，不做 24 小时后台监控，不承诺系统通知。

### 4.2 数据模型

建议新增本地只读观察表或受控文档：

| 字段 | 内容 |
|---|---|
| schemaVersion | 固定为 1 |
| ownerScopeId、hostRef、protocol | 账号、主机和协议 |
| observedAt、attemptGeneration | 观察时间和请求代次 |
| status | reachable / auth_required / trust_required / route_unavailable / capability_unsupported / timeout / remote_rejected / unknown |
| latencyMs、addressFamily、routeKind | 延迟、IPv4/IPv6、直连/Gateway/relay/proxy/repeater |
| capabilitySummary | 脱敏能力摘要 |
| diagnosticCode、evidenceRef | 固定错误码和证据引用 |

规则：

- 不保存密码、私钥、token、原始主机地址或终端正文；
- 诊断码使用固定白名单；
- 本机保留数量有上限，例如每个主机最近 50 条；
- 默认不云同步健康历史；如果以后加入云同步，必须单独加密、版本和容量策略；
- 主机删除、账号切换和 App 分身切换时清理或隔离观察记录；
- 观察结果必须标注时间，不能把旧的“在线”显示成当前在线。

### 4.3 实施阶段

| 阶段 | 内容 | 退出条件 |
|---|---|---|
| H0 | 定义状态、错误码、观察模型和保留策略 | 纯策略测试覆盖未知、超时、认证、信任、路由和撤权 |
| H1 | 将现有批量连通检测和诊断事件接入统一观察器 | RDP/RustDesk/SSH/VNC/Moonlight 各有明确能力降级 |
| H2 | HostList 卡片健康点、详情页和批量检测面板 | 过期结果、检测中和失败原因不会混淆 |
| H3 | 趋势、路径详情、脱敏导出和诊断 AI 入口 | AI 只能读取已脱敏观察，不可直接改安全设置 |
| H4 | Phone/Pad/PC 与账号/撤权/离线验收 | 免费用户、错误账号和失效 Pro 均无越权 action |

---

## 5. 功能 T：增强传输中心（第二优先级）

### 5.1 Pro 增量

基础传输继续免费，Pro 只增加：

- 统一任务队列；
- 暂停、继续、取消、重试；
- 断线后的受控续传；
- 分块校验和与最终完整性报告；
- 同名冲突策略和批次策略；
- SSH → SSH 双主机复制；
- 大文件任务的容量预检和后台收尾；
- 与工作区绑定的传输任务恢复。

不承诺：

- VNC/Moonlight 通用文件传输；
- RDP 任意远端目录枚举；
- 未经远端协议确认的“已保存”；
- 通过 Pro 共享密码、私钥或远端授权。

### 5.2 任务模型

| 字段 | 内容 |
|---|---|
| schemaVersion、jobId、ownerScopeId | 版本、任务和账号 |
| source、target | 协议、hostRef、受保护路径引用 |
| direction | upload / download / remote_copy |
| sizeBytes、chunkSize | 容量和分块 |
| hashAlgorithm、expectedHash | sha256 或无校验 |
| completedBytes | 续传进度 |
| conflictPolicy | ask / rename / overwrite / skip |
| state | queued / running / paused / retrying / completed / failed / cancelled / quarantined |
| sessionLease、requestGeneration | 会话和晚到回调隔离 |

敏感路径只在本地加密存储；导出和诊断使用路径摘要，不导出完整路径。

### 5.3 实施阶段

| 阶段 | 内容 | 退出条件 |
|---|---|---|
| T0 | 统一协议能力矩阵和任务状态 | 每种协议明确支持、降级和禁止项 |
| T1 | 复用现有 ManagedTransferTask、SFTP task engine 和 RustDesk transfer client | 任务归属、取消、重连和 owner fence 通过 |
| T2 | 分块、续传、校验和、冲突策略 | 中断后不重复写坏文件，哈希不匹配进入 quarantine |
| T3 | 传输中心 UI 与工作区关联 | Phone/Pad/PC 触控、键鼠、大字体通过 |
| T4 | SSH 双主机、RustDesk peer 和 RDP 文件通道验收 | 只对实际确认的远端落盘写成功；VNC/Moonlight 清晰显示不支持 |

---

## 6. 功能 E：会话证据包（第三优先级）

### 6.1 分阶段范围

首发不直接承诺全程录屏，先做低风险的证据包：

1. 用户明确触发的单张截图；
2. 会话诊断时间线；
3. 远端分辨率、缩放、编解码、帧率、网络路径和错误分类；
4. 用户选择的时间窗口；
5. 脱敏预览、大小上限和系统邮件草稿。

录屏作为后续增量，只有在 HarmonyOS 屏幕捕获、编码、后台、锁屏、权限和磁盘策略全部证明后才登记为可用。

### 6.2 数据与隐私

- 证据包默认本机保存，默认不上传、不自动发邮件；
- 屏幕捕获必须显示系统/应用捕获状态；
- 后台、锁屏、窗口销毁、账号切换和 Pro 撤权时停止或安全收尾；
- 诊断脱敏不等于屏幕脱敏；屏幕内容必须单独预览和确认；
- 用户可以逐项去掉截图、网络摘要或诊断事件；
- 临时文件位于应用沙箱，使用容量上限、fsync、清理和失败可见状态；
- 邮件草稿只在用户确认后交给系统邮件编辑器，不能自动发送。

### 6.3 与诊断 AI 的边界

AI 只能读取用户主动选择并经过脱敏的结构化事件和证据摘要。不能：

- 读取屏幕原图后自行上传；
- 从截图推断或保存密码、私钥、TOTP；
- 自动发送邮件；
- 把证据包当作远端成功保存的证明。

### 6.4 实施阶段

| 阶段 | 内容 | 退出条件 |
|---|---|---|
| E0 | 权限、捕获 lease、红线字段和容量策略 | 账号/窗口/撤权/取消测试通过 |
| E1 | 单张截图和预览 | 各设备能保存、取消和删除；无权限时明确失败 |
| E2 | 诊断时间线与显示/网络摘要 | 事件 generation、renderer generation、decoder generation 可关联 |
| E3 | 邮件 bundle 和外部分享预览 | 附件失败不被写成发送成功 |
| E4 | 独立评估短录屏 | 仅在原生捕获和编码证据完整时进入新 feature ID |

---

## 7. 功能 D：显示方案与多屏增强

### 7.1 先完成现有显示计划

不新建重复的“自定义分辨率”功能。首先完成：

- host × device × orientation 的 profile store/runtime；
- 旧全局 Preferences 到 profile 的无损迁移；
- 账号、主机、设备和方向隔离；
- 页面、会话、重连、接续和工作区使用同一 profile；
- 过期、撤权和远端拒绝时回退免费 Auto/标准档。

### 7.2 多屏范围

| 协议 | 首发策略 |
|---|---|
| RDP | 先完成单远端显示器 profile；随后评估真实 Display Control 多显示器 |
| RustDesk | 只对已返回能力、版本和权限证据的 peer 开放目标显示器 |
| VNC | 只支持已经证明的 UltraVNC/TigerVNC monitor-info / SetMonitor 路径 |
| SSH / Moonlight | 不提供远端桌面多屏能力；只保存本地工作区和窗口布局 |

每次切换必须能区分 requested、queued、accepted、applied、server_adjusted、rejected、unsupported 和 timeout。

“消息进入队列”或“候选分辨率出现”不能作为成功证据。成功至少需要远端确认、实际新帧尺寸和输入几何更新中的可核对证据。

---

## 8. 功能 A：跨协议自动化方案

### 8.1 产品定义

自动化不是任意远程 Shell，而是受控的本地编排：

1. 打开工作区；
2. 连接指定 SSH 主机；
3. 应用已保存的端口转发；
4. 插入用户选择的 SSH Snippet；
5. 打开 RDP/RustDesk/VNC/Moonlight 主机；
6. 显示每步结果。

### 8.2 安全规则

- 复用现有工作区、SSH Snippet 和端口转发；不重新收费基础能力；
- Recipe 不保存密码、私钥、API Key 或临时授权；
- 每步声明协议、hostRef、可接受状态和是否需要确认；
- 首次运行必须显示完整预览；
- 连接、命令广播、文件写入和远端设置变更必须单独确认；
- 支持 dry-run、暂停、取消、失败后继续和逐步重试；
- 任何 hostRef 被删除、账号切换、Pro 撤权或配置 revision 变化都会使旧计划失效；
- 远端命令只允许调用已存在的 Snippet，第一版不开放任意输入命令的自动执行。

### 8.3 退出条件

- recipe schema 可迁移、可校验、可回滚；
- 旧账号和旧窗口的晚到回调不能继续执行；
- 每个步骤都有可审计的开始、结果和取消状态；
- 设备、主机锁、凭据锁和协议能力检查全部在每一步重新执行。

---

## 9. 功能 S：短时访客邀请

### 9.1 产品定义

这是现有连接分享的扩展，不是把 Pro 权益转给接收方：

- 一次性、短时有效、版本化邀请；
- 分享协议、主机引用、显示/输入偏好和可恢复状态；
- 默认不分享密码、私钥、购买凭据和 Pro grant；
- 接收端必须自行登录、确认、认证和检查远端可达性；
- 发起端可以设置只读、有效期、允许操作和是否允许回收；
- 失败时保持源端连接和本地配置。

### 9.2 技术依赖

- App Linking/域名和 fragment 解析；
- Share Kit 或其他已确认的跨设备传输通道；
- 防重放 nonce、过期时间、接收确认和撤销；
- 跨账号边界和审计；
- RDP Gateway/NLA、RustDesk peer、VNC/TLS、SSH 认证分别验收。

第一版优先支持 SSH；RDP/RustDesk/VNC 只有在邀请字段、接收流程和重新认证均已证明后再开放。需要持续中继、云端保存邀请或团队管理时另行设计服务型权益。

---

## 10. 统一存储、加密和同步方案

### 10.1 存储分层

| 数据 | 首选存储 | 是否默认云同步 |
|---|---|---|
| 功能显示偏好 | Preferences | 继续沿用现有策略 |
| 健康观察 | 本地受限 RDB/文档 | 否 |
| 传输任务元数据 | 本地加密存储 | 否，首发 |
| 证据包和截图 | 应用沙箱、加密暂存 | 否 |
| 显示 profile | 设备本地、账号/主机隔离 | 按现有显示计划，首发不强行云同步 |
| 自动化 recipe | 加密本地配置 | 只有显式选择才同步 |
| 访客邀请 | 内存/短时安全暂存 | 否 |
| 密码、私钥、TOTP、API Key | 现有 KeyVault / Asset Store | 按既有安全策略 |

### 10.2 账号隔离

每条新数据必须包含 owner scope 或通过账号作用域键隔离。账号切换、分身、注销、恢复和加密重置必须：

- 停止旧任务；
- 清理内存秘密；
- 隔离或清理旧账号的健康、传输、证据和邀请；
- 保留可解释的失败/待恢复状态；
- 禁止旧回调写入新账号。

---

## 11. UI 入口和用户体验

### 11.1 入口原则

- 复用现有 RemoteDesk Pro 面板，不再创建孤立的第二套 Pro 设置页；
- 目录介绍、权益状态、设备不支持、权限未授予和远端不支持分开显示；
- 免费用户只看到统一 Pro 介绍入口，不在普通连接操作中遍布锁图标；
- 入口隐藏时不能残留空白占位、键盘焦点或无障碍节点；
- 所有 Phone/Pad/PC 页面保留原有圆角布局、主题、大字体和键鼠路径。

### 11.2 关键页面

- HostList：健康点、最近检查、批量检测和进入诊断；
- RemoteSessionTopBar：证据包、当前显示 profile 和能力状态；
- Transfer Center：任务队列、暂停/继续、冲突和完整性；
- Pro Workspace：自动化 recipe 入口和工作区关联；
- Pro Connection Share：访客邀请和接收确认；
- ProFeatureManagerPanel：每项功能的状态、设备限制、验收进度和隐私说明。

---

## 12. 验证和验收矩阵

### 12.1 代码级门禁

每一阶段必须运行：

    source scripts/macos_env.sh
    hvigorw --mode module -p module=entry -p product=default default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon
    hvigorw --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --no-daemon

并运行：

- 对应纯策略、ArkTS、Node、native/Rust 测试；
- git diff --check；
- Light 合规门；
- 改动测试模块时执行适用的 ohosTest@OhosTestCompileArkTS；
- 改动依赖、native 或协议时更新 ABI、SBOM、NOTICE、provenance 和哈希；
- 发布前运行 Release pruning 和 check_pro_release.py。

共享的 .hvigor、entry/build、entry/.cxx 必须停止竞争 builder，并使用项目本地隔离缓存；旧日志不能代替本次门禁。

### 12.2 通用设备矩阵

每个已实现功能至少覆盖：

- Phone / Pad / PC；
- API 23 安装兼容与 API 26 目标运行；
- 深色/浅色、普通字体/大字体、触屏/键鼠；
- 免费、真实 Pro、模拟免费、模拟 Pro、退款待确认、已撤权；
- 冷启动、后台恢复、窗口关闭、账号切换、应用分身；
- 网络断开、IPv4、IPv6、网络代际变化、超时、取消和重复点击。

### 12.3 协议矩阵

| 协议 | H 健康 | T 传输 | E 证据 | D 显示 | A 自动化 | S 分享 |
|---|---|---|---|---|---|---|
| RDP | 直连/Gateway、NLA/证书、实际获胜地址族 | 剪贴板/文件通道，不能承诺任意目录 | 截图/诊断优先，录屏另验 | Windows 10/11/Server、Display Control、多屏 | 只编排连接和本地策略 | 接收端重新认证 |
| RustDesk | ID/直连/中继、peer presence | 文件通道、断线、hash、peer 兼容 | 编解码/帧/网络摘要 | 新旧 peer、Windows 虚拟显示器、X11/Wayland 降级 | 只编排已确认能力 | 不共享密码/Pro |
| SSH/SFTP | 直连/代理/跳板、主机指纹 | 双主机、续传、权限、完整性 | 终端/传输诊断，敏感输入暂停 | 不提供远端桌面多屏 | Snippet/转发/工作区首发 | 先支持 SSH |
| VNC | direct/repeater/TLS、厂商错误码 | 不承诺通用文件 | framebuffer/LastRect/连接摘要 | 仅 UltraVNC/TigerVNC 已证实路径 | 不执行远端命令 | 仅完成协议字段后开放 |
| Moonlight | discovery/control/media/重连 | 不承诺通用文件 | 性能 HUD/码率/帧率摘要 | 保存本地查看和工作区布局 | 只编排启动和退出 | 需要单独协议设计 |

### 12.4 验收记录格式

每个场景必须记录：

    操作
    预期结果
    实际证据
    状态
    构建/HAP/设备/peer/服务来源
    限制和未验证项

编译成功、HAP 安装、listener、候选列表、消息入队或本地模拟都不能单独证明远端功能成功。

---

## 13. 发布、回滚和收费条件

### 13.1 发布状态

- 新功能默认 planned 或 experimental；
- 实现、纯策略测试和 HAP 通过后仍保持 experimental；
- 只有代码复核、真机、协议 peer、隐私、账号/撤权和实际 Provider/后端条件都通过，才提升为 available；
- Release checker 必须证明没有 Debug 模拟授权、空 endpoint、测试商品或开发者绕过路径；
- 生产购买描述只能包含真正交付的功能。

### 13.2 回滚

- 回滚优先把 feature availability 改为 disabled 或 experimental，不删除用户配置；
- 未完成的传输任务和证据包进入可解释的暂停/待恢复状态；
- 显示 profile 失败时回退免费 Auto/标准档；
- 自动化 recipe 无法验证时只读展示，不执行；
- 访客邀请过期或撤销后不可重放；
- 任何回滚不得删除免费主机、凭据、云同步或工作区数据。

### 13.3 正式收费前置条件

必须同时满足：

1. 至少一个真实可用且有明确设备/协议范围的 Pro 功能已交付；
2. AGC 商品、可信验单、恢复购买、退款撤权、离线策略和跨账号矩阵通过；
3. 所有产品文案与实际能力一致；
4. 真实用户设备和远端矩阵完成；
5. 生产包无法启用 Debug 模拟；
6. 后端、域名、通知或邮件等外部依赖有独立证据；
7. 独立审查无未解决的 P0/P1。

---

## 14. 推荐实施顺序

### Now：先收口现有路线

1. 完成并复核当前 host × device 显示 profile runtime。
2. 完成工作区/高级主机管理设备验收。
3. 完成诊断 AI 的 Provider、邮件和真实设备验收。
4. 完成 M4/M5 的 PC、App Linking、跨设备和文件完整性验收。
5. 保持安全密钥、手机通行密钥和 RustDesk AI 跨网能力为 planned/experimental。

### Next：新增本计划功能

1. H：主机健康中心；
2. T：增强传输中心；
3. E：截图 + 诊断证据包；
4. D：显示 profile 完整接通后再做多屏；
5. A：跨协议自动化；
6. S：短时访客邀请。

### Later：单独商业评估

- 自适应画质和网络策略；
- 团队/RBAC/审计；
- 持续监控、通知、云存储和托管中继；
- 录屏云分享和跨网 AI 传输。

---

## 15. 待确认的产品决策

实现前只需要确认以下产品决策，其他工程细节按本计划执行：

1. 主机健康历史是否坚持“本地按需检测”，首发不做后台监控（推荐：是）。
2. 会话证据是否先交付截图/诊断时间线，再评估录屏（推荐：是）。
3. 增强传输是否先限定 SSH + RustDesk，RDP 只做现有通道增强（推荐：是）。
4. 显示 profile 是否保持设备本地，不立即加入云同步（推荐：是）。
5. 自动化第一版是否只允许已保存 Snippet，不允许任意 Shell（推荐：是）。
6. 访客邀请是否先完成 SSH，再扩展其他协议（推荐：是）。
7. 团队协作是否独立为新的服务型产品，而不是并入一次性 Pro（推荐：是）。

计划只有在这些边界明确、当前活动分支完成 checkpoint、独立审查范围可计算后，才进入代码实施。
