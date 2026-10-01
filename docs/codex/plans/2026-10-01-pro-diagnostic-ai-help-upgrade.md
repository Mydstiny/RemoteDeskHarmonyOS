# Pro「诊断与 AI 帮助」完整升级计划

- 日期：2026-10-01
- 计划版本：1.0
- 状态：D0–D5 客户端基础链路已实现，生命周期/端点/邮件预览修复已提交；真实 Provider、真机、邮件客户端和发布权益验收待执行
- 当前工作区：继续活动分支 `codex/pro-purchase-foundation`；实现沿用现有分支，不创建新分支或持久 worktree
- 产品名称：RemoteDesktop Pro「诊断与 AI 帮助」
- 适用平台：HarmonyOS Phone / Pad / PC，开发基准 API 26，保留 API 23 安装兼容核对
- 核心原则：传统手动日志保持可用；AI 配置、自动诊断编排、AI 分析和邮件打包属于 Pro 增量

## 1. 目标与决策

本功能把现有设置中的“日志”升级为一个 Pro 诊断工作台，包含三个部分：

1. **辅助 AI 配置**：配置用户自己的 AI Provider，保存安全凭据，拉取模型列表并选择默认模型。
2. **启动 AI 辅助**：用户描述问题，助手根据应用知识和结构化诊断事件给出有证据的只读建议，并在用户确认后发起有界日志抓取。
3. **传统日志抓取**：保留当前脱敏 JSONL 捕获、预览、保存和丢弃流程，不因 Pro 功能而破坏既有免费支持路径。

新助手不是现有的远程 Codex/DSH 工作台。现有 `services/ai` 负责连接用户电脑上的 Codex/DSH；本计划新增独立的诊断 AI 域，不能把第三方 API Key 塞入 `AiHost`、`AiLocalStore` 或普通主机字段。

首发采用“中国大陆 Provider 优先、OpenAI 等国际 Provider 后续加入”的顺序。首发只做只读诊断和受控设置建议，不开放通用 Agent、Shell、自动连接、自动发信或自动修改安全配置。

## 2. 当前实现基线与复用边界

### 2.1 可以直接复用的链路

| 当前构件 | 复用方式 |
|---|---|
| `DiagnosticCapturePolicy/Runtime/ExportService` | 作为第三部分和 AI 分析包的结构化事件来源；保留 schema、事件白名单、容量上限和脱敏契约 |
| `ProFeatureCatalog`、`ProEntries`、`ProFeatureGate`、`ProRuntime` | 注册新 feature ID；保持“可见”和“可执行”分离，所有受保护操作重新检查权益和账号 generation |
| `AccountSessionCoordinator`、`SensitiveDataBarrier` | 账号切换、注销、恢复和作用域转换时取消请求、清理内存秘密和关闭助手 |
| `RustDeskProCredentialStore` 的 Asset Store 模式 | 仅作为 Provider API Key/OAuth secret 的安全存储参考；Preferences 只保留非秘密元数据 |
| `AppSheetHeader`、`RightPanelDialog`、`RemoteOverlayRegistry`、`RemoteFloatingPanelPlacementPolicy` | 设置页、Pad/PC 侧栏和远程会话内浮窗的生命周期与定位 |
| `Theme`、`AppUiMetrics`、`AppSettingsActionRow`、`AppSettingsChoiceButton` | 保持现有 RemoteDesktop UI 语言、触点大小、主题和大字体规则 |
| `SettingsAccordionPolicy` 和现有反馈邮件启动策略 | 复用系统邮件编辑器入口；新增附件预览和明确发送确认，不能直接复用为自动发送 |

### 2.2 不应直接复用的构件

- `AiTransport`：当前是固定 mTLS 的 Codex/DSH LAN 协议，不是公网 Provider HTTPS 客户端。
- `AiModels.AiBackend`：当前只有 `codex` 和 `dsh`，不能扩展成任意 Provider 的 API 配置。
- `AiLocalStore` 的 identity 字段：其中保存的是远程 AI 配对身份，不应混入 API Key。
- `DiagnosticCaptureRuntime` 的全局单例状态：AI 自动抓取必须增加 owner/lease 或排队策略，不能停止用户正在进行的手动捕获。
- `FeedbackSettingsSheet` 的普通邮件正文：目前没有诊断附件、二次脱敏、发送状态或附件失败恢复。

## 3. Pro 权益与发布契约

不新增 IAP SKU，统一使用 `pro.lifetime`。建议登记以下独立 feature ID：

| feature ID | 作用 | 首发状态 |
|---|---|---|
| `pro.diagnostics` | 诊断与 AI 帮助入口、浮窗入口 | `experimental` → 验收后 `available` |
| `pro.diagnostics.providerConfig` | Provider 配置、凭据保存、模型拉取 | `experimental` |
| `pro.diagnostics.assistant` | AI 会话、问题分类、诊断分析、设置建议 | `experimental` |
| `pro.diagnostics.emailBundle` | 诊断结果和日志的邮件草稿打包 | `experimental` → 单独验收 |

已有 `pro.ai.workspace`、`pro.ai.codex`、`pro.ai.dsh` 继续表示远程电脑 AI 工作台，不与本功能合并。

每个入口、按钮、浮窗事件、模型请求、捕获请求、设置应用和邮件编排都必须经过共享 Pro decision。每次 `await` 前后、持久化前后以及真正发出网络请求前都重新验证：

- 当前账号 owner 和 generation；
- Pro entitlement 状态；
- Provider profile revision；
- 当前页面/浮窗 owner；
- 当前 capture lease；
- 当前助手会话是否仍有效。

Pro 撤权、退款待确认、账号切换或注销时：关闭助手、取消 Provider 请求、取消未开始的捕获、清理内存 Key、清理临时附件和草稿；保留传统手动日志入口。加密的非秘密 Provider 元数据是否保留由数据策略决定，任何受保护操作都必须重新取得有效权益。

## 4. 国内 Provider 优先路线

Provider 目录使用版本化、签名或内置哈希校验的 Manifest。页面只读取 Manifest，不在 UI 中硬编码 URL、认证头或厂商字段。每个条目必须声明：

```text
providerId
displayName
region
endpointPolicy
protocolFamily
authModes
modelListCapability
streamCapability
visionCapability
contextWindowRange
dataRetentionStatement
trainingUseStatement
privacyPolicyUrl
manifestVersion
manifestHash
```

具体 URL、模型名和厂商协议在实现阶段按官方资料逐项核对，不能把旧文档中的地址当作当前可用事实。

### 4.1 适配优先级

| 优先级 | Provider/服务类型 | 适配策略 | 说明 |
|---|---|---|---|
| D0 | OpenAI-compatible 国内服务 | 一个通用 JSON/SSE adapter + Manifest 参数 | 先覆盖 DeepSeek、通义/Qwen、智谱、月之暗面、硅基流动等兼容服务；每个服务仍需独立核对认证、模型目录和地区说明 |
| D0 | 自建局域网模型服务 | OpenAI-compatible LAN adapter | 适配 Ollama 等用户自行部署的服务；局域网端点必须显式启用、显示风险并校验证书/主机身份 |
| D1 | 百度文心、字节豆包、讯飞星火、MiniMax 等自有协议 | 独立 adapter | 不为了“兼容”强行拼接请求；按各自模型列表、流式事件、错误码和视觉能力建映射 |
| D2 | 其他大陆 Provider | Manifest + adapter 插件化扩展 | 先满足数据处理信息和测试合同，再进入可选目录 |
| D3 | OpenAI、Anthropic、Gemini、Azure、OpenRouter 等国际服务 | 后续阶段 | 需要单独处理跨境、地区、留存、训练和 AppGallery 文案，不阻塞国内首发 |

### 4.2 Provider 配置 UI

“辅助 AI 配置”页面采用三层结构：

1. **当前 Provider 卡片**：Provider、模型、连通状态、最近测试时间、数据处理地区。
2. **预设 Provider 列表**：按国内、局域网、自定义分组；显示能力标签，例如“流式”“视觉”“模型列表”。
3. **自定义 Provider 编辑器**：仅高级入口，要求额外风险确认，不允许任意 HTTP、`data:`、`file:`、用户名密码 URL、任意重定向或任意 Header。

配置字段：Provider、Endpoint、认证方式、API Key/OAuth、模型、超时、流式开关、数据发送前确认策略。API Key 输入框支持粘贴、显示/隐藏、轮换、测试、删除；不回显完整值，不进入日志或错误文本。

模型列表必须用户主动点击“拉取模型”。响应统一为：模型 ID、显示名、输入模态、上下文上限、流式能力、视觉能力、工具能力、状态和抓取时间。列表失败时保留手动填写模型 ID 的回退，但不能静默使用过期模型。

## 5. “AI 可帮助设置应用”能力

助手可以帮助用户理解和配置应用，但采用“建议 → 预览 → 用户确认 → 类型化写入”的流程，不允许模型直接执行任意设置操作。

### 5.1 首发允许的设置类别

- RDP/RustDesk/VNC/Moonlight 的显示、缩放、画质和诊断开关；
- 远程会话顶栏、侧栏、快捷键、键盘和触控行为；
- SSH 终端字体、行距、皮肤和非秘密工作区偏好；
- 诊断捕获模块、时长、是否在问题发生时自动提示；
- 浮窗显示、入口位置、助手默认 Provider/模型；
- 已有设置页的导航和恢复默认操作。

### 5.2 首发禁止直接修改的类别

- 密码、SSH 私钥、TOTP、RDP 凭据、RustDesk 密钥；
- API Key、OAuth token、证书和私钥；
- 网络代理、VPN、TUN、IPv6 全局策略；
- 防火墙、中继、远端服务端配置；
- 付款、账号、退款、云同步破坏性操作；
- 任意 Shell、文件写入、远程连接和安全确认。

助手输出 `SettingProposal`，例如：

```text
settingId
currentValue
proposedValue
reason
evidenceRefs
risk
requiresUserConfirmation
rollbackValue
```

应用侧建立白名单 `DiagnosticAiSettingsActionPolicy`，每个 settingId 映射到已有服务的类型化方法。用户确认后再次校验账号、权益、页面 generation 和旧值；写入后显示变更、可撤销期限和实际结果。敏感设置只提供“打开对应设置页”和说明，不提供直接写入。

## 6. 右上角常驻 AI 入口与交互设计

### 6.1 入口位置

用户在“诊断与 AI 帮助 → 显示入口”中选择：

- 不显示；
- 主机列表页右上角显示；
- 远程会话页右上角显示；
- 两处都显示。

默认关闭，避免用户没有完成 Provider 配置时出现无效入口。入口只在应用前台和当前窗口内显示，不申请系统全局悬浮窗权限。

接入点：

- `HostListPage` 标题栏右侧；
- `RemoteSessionTopBar` 最右侧，保留系统返回、关闭和现有会话操作优先级；
- 会话内浮层接入 `RemoteOverlayRegistry`，携带 owner/generation，不能遮挡远程输入命中区域；
- Phone 使用现有 Sheet；Pad/PC 使用 `RightPanelDialog` 或右侧浮层。

### 6.2 自有视觉语言

可以借鉴 Apple Intelligence 的“流动光环、状态驱动、轻量动画”交互逻辑，但不复制 Apple 图标、资源或品牌标识。RemoteDesktop 使用自己的 AI 标识：

- 四色或双色渐变的圆环/波纹；
- 与现有主题强调色联动；
- 深色模式降低亮度和光晕半径；
- 所有动画支持减少动态效果；
- 44vp 最小触点，图标本体约 28–32vp；
- 大字体下不改变触控区域，只调整旁边状态文字。

### 6.3 状态动画

| 状态 | 视觉 | 用户动作 |
|---|---|---|
| `hidden` | 不显示 | 在设置中开启 |
| `idle` | 静态渐变环，低频呼吸 | 点击唤起助手 |
| `opening` | 光环扩散为胶囊 | 等待面板完成布局，不发送请求 |
| `ready` | 光环稳定，显示输入提示 | 输入问题、选择协议或会话 |
| `listening` | 光环沿边缘流动 | 输入文本；首发不做语音常驻 |
| `thinking` | 内圈旋转，显示 Provider/模型 | 可取消请求 |
| `capturePreparing` | 胶囊收缩，显示模块和时长 | 用户确认或取消 |
| `capturing` | 变为右上角悬浮球，环形进度 | 查看进度、停止、返回助手 |
| `analysisReady` | 悬浮球脉冲一次后恢复胶囊 | 查看证据、建议和设置操作 |
| `waitingConfirmation` | 琥珀色小徽标 | 用户确认设置或邮件，不自动执行 |
| `offline/error` | 灰色或红色短提示 | 查看错误、换 Provider 或重试 |
| `revoked` | 立即消失 | 保留传统日志入口 |

捕获期间使用悬浮球而不是持续展开的面板，减少对远程桌面的遮挡。悬浮球点击后只展开进度和取消操作；捕获完成后才恢复分析结果面板。

### 6.4 输入交互

- 点击入口打开面板，不直接开始网络请求；
- 首屏显示问题快捷卡片：“连接失败”“黑屏/花屏”“输入无效”“文件传输”“账号/同步”“我想调整设置”；
- 用户可以补充协议、主机和会话范围，主机展示脱敏名称；
- 输入框底部显示当前 Provider、模型、数据外发状态和“仅发送脱敏诊断包”；
- 发送前显示数据范围预览；
- 键盘打开时面板跟随安全区滚动，不固定遮挡输入框；
- 关闭面板清理未提交草稿，已完成的本地诊断摘要按保留策略处理；
- 首发不做后台常驻聊天、不做自动语音监听、不做无边界附件上传。

## 7. 诊断助手的数据流和安全边界

### 7.1 诊断编排

```text
问题文本/快捷卡片
→ 本地规则分类
→ 推荐协议、会话、模块和时长
→ 隐私与大小预览
→ capture owner/lease
→ DiagnosticCaptureRuntime
→ JSONL strict validation
→ 第二次白名单/正则/canary 脱敏
→ analysis bundle
→ 用户确认 Provider 外发
→ 单次 tool-less AI 请求
→ typed diagnosis result
```

默认 `core.app`；协议、网络、云同步、本地数据库和 SSH 密钥模块逐项确认。不得读取 raw hilog、数据库原文、屏幕、音频、剪贴板、终端正文或文件内容来补足模型上下文。

### 7.2 密钥和 Provider 请求

- Provider API Key/OAuth secret 进专用 Asset Store；RDB 只存非秘密元数据和指纹；
- 不进入云同步、备份、导出、崩溃日志、hilog、诊断包和邮件；
- 只允许审核过的认证 Header；禁止把 Key 放入 URL query；
- HTTPS、证书和主机校验必须 fail-closed；禁止关闭证书验证；
- 禁止跨 origin 重定向；重定向不得携带认证头；
- Endpoint、解析地址、响应体、模型数量、并发、超时和流式帧均有上限；
- Provider 响应和文档内容均视为不可信文本，必须防 Prompt Injection；
- AI 请求没有工具权限，不能直接调用设置、连接、文件、邮件或 Shell。

### 7.3 本地保留和审计

本地仅保留必要审计元数据：

- providerId、模型 ID；
- consent ID 和时间；
- capture schema/redaction 版本；
- bundle hash、大小和结果状态；
- 目标主机 hash；
- 取消、失败和过期状态。

默认不持久化完整 prompt、完整 response 或原始日志。诊断结果缓存采用短 TTL，提供“立即清理全部 AI 诊断数据”。

## 8. 邮件与分享

邮件是独立用户同意，不与“发送给 AI Provider”合并。

生成邮件前展示：收件人、主题、正文、附件名称、附件大小、脱敏版本、包含的模块和设备字段。调用系统邮件编辑器或系统分享面板，由用户最终点击发送。无邮件应用时提供保存到文件或系统分享回退。

不内置 SMTP，不后台发送，不宣称附件可安全擦除。取消、失败或用户修改收件人后，本地 bundle 仍受 TTL 和清理策略管理。

## 9. 文档与内容系统

新增随版本发布、带 hash 的本地知识文档：

- 五协议使用指南；
- RDP/RustDesk/SSH/VNC/Moonlight 错误码和限制；
- 网络、网关、中继和证书说明；
- 隐私政策和数据安全；
- 诊断字段、脱敏和发送说明；
- 设置项说明和恢复默认指南；
- Provider 地区、训练、保留和费用说明。

内容可复用 `GuideContentRegistry`、`AboutSettingsSheet` 的文案来源，但 AI 只获取必要章节的本地片段和引用，不把整份隐私政策或用户数据无条件发送给 Provider。

发布前必须更新：

- `docs/app-store/PRIVACY_POLICY.md`；
- 应用内隐私摘要；
- AppGallery 权限用途和第三方处理说明；
- 用户指南；
- 安全威胁模型；
- Provider Manifest 来源和变更记录；
- 版本发布说明和删除/撤回路径。

## 10. 实施阶段和交付物

### D0：产品、安全、文档契约

交付：feature ID、数据流图、同意矩阵、Provider Manifest schema、AI 结果 schema、设置动作白名单、威胁模型、隐私文案和回滚开关。

退出条件：未知的处理地点、保留、训练用途、发送对象和删除路径不能被默认隐藏；没有明确答案的 Provider 不进入默认可选列表。

### D1：Provider 和秘密存储基础

实际新增/落地范围：

```text
services/diagnosticAi/DiagnosticAiModels.ets
services/diagnosticAi/DiagnosticAiProviderCatalog.ets
services/diagnosticAi/DiagnosticAiEndpointPolicy.ets
services/diagnosticAi/DiagnosticAiSecretStore.ets
services/diagnosticAi/DiagnosticAiProviderService.ets
services/diagnosticAi/DiagnosticAiProfileStore.ets
```

交付 Provider Manifest、国内 D0 adapter、Asset Store、账号/设备隔离、Key 轮换删除、HTTPS/SSE、错误脱敏和本地测试服务器。

### D2：诊断编排和 AI 结果

新增：

```text
services/diagnosticAi/DiagnosticCaptureOrchestrator.ets
services/diagnosticAi/DiagnosticAiBundlePolicy.ets
services/diagnosticAi/DiagnosticAiPromptPolicy.ets
services/diagnosticAi/DiagnosticAiResultPolicy.ets
services/diagnosticAi/DiagnosticAiSettingsActionPolicy.ets
```

交付问题分类、capture owner/lease、范围预览、二次脱敏、typed result、证据引用、置信度、不确定性和只读设置建议。

### D3：设置页和 Provider 配置 UI

实际新增或扩展：

```text
components/diagnosticAi/DiagnosticAiSettingsSheet.ets
components/diagnosticAi/DiagnosticAiAssistantPanel.ets
pages/HostListPage.ets 的设置叶子页
```

将 HostListPage 的“日志”入口改为“诊断与 AI 帮助”，保留传统日志子页。免费用户看得到 Pro 说明，但不能执行受保护操作。

### D4：右上角入口、浮窗和悬浮球

实际新增或扩展：

```text
components/diagnosticAi/DiagnosticAiOrb.ets
components/diagnosticAi/DiagnosticAiAssistantPanel.ets
services/diagnosticAi/DiagnosticAiOrbPolicy.ets
```

接入 `HostListPage`、`RemoteSessionTopBar`、`RemoteOverlayRegistry`、`RightPanelDialog`，完成 owner/generation、窗口销毁、前后台和输入命中隔离。

### D5：邮件 bundle 和提醒

实际新增：

```text
services/diagnosticAi/DiagnosticAiMailPolicy.ets
并复用现有系统邮件编辑器启动策略；附件文件导出保留为后续扩展
```

完成二次脱敏、附件预览、大小限制、系统邮件编辑器和无邮件应用回退。提醒默认只在应用内出现；系统通知必须有用户开关和权限回退。

### D6：国内 Provider 扩展和后续国际 Provider

先扩展自有协议的百度、豆包、讯飞、MiniMax 等，再考虑 OpenAI、Anthropic、Gemini、Azure、OpenRouter。每个新 Provider 必须有独立 Manifest、adapter、数据处理说明、模型目录测试、错误/限流测试和隐私审核。

## 11. 测试与验收门禁

### 11.1 单元和策略测试

- Manifest schema、签名/hash、URL、认证头和重定向策略；
- API Key 不出现在 JSON、日志、备份、云表、导出和邮件；
- 模型列表分页、重复、错误 JSON、超大响应和过期模型；
- capture owner/lease、取消、截止、页面销毁和手动捕获冲突；
- redaction canary 覆盖密码、token、API Key、私钥、地址、路径和终端文本；
- AI typed result、证据引用、置信度和未知结论；
- 设置建议白名单、确认、回滚和敏感设置拒绝；
- Pro 撤权、退款、账号切换和迟到网络回调。

### 11.2 UI 验收

- Phone/Pad/PC、深色/浅色、横竖屏、大字体、实体键盘；
- orb 的 idle/opening/thinking/capturing/result/error 状态；
- 浮窗不遮挡远程输入和顶部系统动作；
- 悬浮球可取消捕获并能恢复助手；
- 设置动作预览、确认和撤销；
- Pro 不可用时入口和传统日志回退；
- 减少动态效果设置下不依赖动画表达状态。

### 11.3 网络、设备和邮件验收

- 国内 D0 Provider 真实模型列表和流式分析；
- 无网、DNS 失败、坏证书、429、5xx、超时、慢流和服务恢复；
- API Key 轮换、删除、账号切换和冷启动；
- 真机 Phone/Pad/PC 的入口与浮窗；
- 真实邮件应用、无邮件应用、附件超限和取消；
- 传统 JSONL golden 和五协议业务零副作用。

代码变更每个 checkpoint 都必须重跑仓库规定的 `default@OhosTestCompileArkTS` 和 `assembleHap`，再执行定向测试、`git diff --check`、Light 合规、独立审查和对应设备/Provider/邮件证据。构建通过不能替代真实 Provider、真机或生产权益验收。

## 12. 回滚与发布条件

发布开关分为：

```text
diagnosticAiEntry
diagnosticAiDomesticProviders
diagnosticAiSettingsActions
diagnosticAiRemoteSessionOrb
diagnosticAiEmailBundle
```

任何 Provider、浮窗或邮件问题都可以单独关闭对应开关，保留传统日志和已保存的非秘密配置。回滚不删除用户 API Key，除非用户明确执行删除或安全事件要求清理。

只有 D0–D6 的代码审查、隐私文档、国内 Provider、真实设备、撤权矩阵、邮件矩阵和回滚演练全部通过，才把 `pro.diagnostics` 从 `experimental` 提升为 `available`。OpenAI 等国际 Provider 不影响国内首发，但必须在后续单独通过跨境和数据处理审查。

## 13. 首个实施 checkpoint（已完成）

第一批已完成并扩展为可运行客户端链路：

1. feature ID、Pro 可见/可执行门禁和设置叶子页；
2. 国内优先 Provider Manifest、端点校验、模型列表和 OpenAI-compatible 非流式请求；
3. API Key Asset Store、作用域 metadata、账号切换清理和常驻入口关闭；
4. capture owner/lease、问题到模组映射、二次脱敏 bundle 和 AI 结果 schema；
5. `SettingProposal` 白名单、JSON 结果解析、逐项确认和安全布尔设置写入；
6. HostListPage/RemoteSessionTopBar orb、助手面板、抓取悬浮状态和减少动态效果兼容；
7. 邮件主题/正文/脱敏包草稿生成并接入现有系统邮件编辑器；
8. 隐私政策、用户指南、独立诊断说明和策略测试。

完成该 checkpoint 后进入真实 Provider、设备、邮件和发布验收阶段。仓库不包含真实 API Key、真实用户数据或生产权益配置。

## 14. 本次计划落盘验证记录

- 计划文件：已新增并随实现同步更新；应用实现已落盘，未修改真实密钥、用户数据或生产权益配置。
- `git diff --check`：通过。
- Light 开源合规门：通过。
- `default@OhosTestCompileArkTS`：通过，修复后 `BUILD SUCCESSFUL in 16 s 897 ms`，使用项目本地 `.remotedesk-build-cache`；输出仅包含既有依赖/API 警告。
- `assembleHap`：通过，修复后 `BUILD SUCCESSFUL in 21 s 885 ms`，签名阶段约 1.9 s；使用项目本地 `.remotedesk-build-cache`，输出发布到 `entry/build/default/outputs`。
- Light 开源合规门：通过；`git diff --check`：通过。
- 现有 Node Pro 策略回归：`test_pro_entry_gating.cjs` 通过；`test_pro_runtime.cjs`、`test_pro_feature_visibility.cjs` 因环境缺少 `typescript` 模块未能启动，需在完整开发环境补跑。
- Provider、真机、邮件客户端和生产权益验收：代码链路已具备，真实环境证据仍待执行；国际 Provider 不在首发范围。
