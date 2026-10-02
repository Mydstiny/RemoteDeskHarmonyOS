# Pro「诊断与 AI 帮助」账户登录与 Coding Plan 升级计划

- 日期：2026-10-02（Asia/Shanghai）
- 计划版本：1.0
- 计划状态：P0 全应用 Agent 与 Siri-style UI 已实现；真实 Provider、真机和邮件客户端验收待执行
- 关联基线：[Pro 诊断与 AI 帮助完整升级计划](2026-10-01-pro-diagnostic-ai-help-upgrade.md)
- 当前分支：`codex/pro-purchase-foundation`
- 目标平台：HarmonyOS Phone / Pad / PC，API 26 开发基准，保留 API 23 安装兼容核对
- 首发范围：中国大陆 Provider 优先；国际 Provider 作为后续适配

## 1. 这次升级要解决的问题

当前“辅助 AI 配置”已经支持 Provider HTTPS 地址、API Key、模型 ID、模型列表和本机安全存储，但它仍然是 API Key 模式。它没有账户 OAuth、套餐识别、Coding Plan 资格判断、账户切换或撤销授权。

用户提出的“使用各家的账户登录并消耗 Coding Plan”不能做成一个统一的登录按钮。账户登录、开放平台 API、Token Plan 和 Coding Plan 是不同的授权与计费边界；每家供应商还可能限制 Coding Plan 只能用于指定的官方编程工具。升级后的产品必须先判断供应商声明的认证方式和允许用途，再决定是否呈现登录或 Coding Plan 入口。

本计划的产品决策是：

1. 普通开放平台 API/Token Plan 继续作为首发默认路径。
2. 只有供应商正式允许第三方应用使用的 Coding Plan，才进入可选适配；不能因为专用 Key 能够发出请求，就推断该用法获得授权。
3. 账户登录只支持供应商官方 OAuth 2.0、PKCE 或设备授权；不接收密码、Cookie、网页 Session、非公开 Token 或逆向接口。
4. “诊断与 AI 帮助”是应用支持助手，不是代码代理。Coding Plan 若声明仅限编码工具，界面必须显示“当前套餐不适用于诊断助手”，并阻止请求。
5. 每个 Provider 的认证、套餐和数据用途都必须由版本化 Manifest 声明，并经过官方文档、服务条款、隐私政策和真实端点四项核验。

## 2. 当前实现与缺口

| 已有构件 | 当前能力 | 本计划需要增加的能力 |
|---|---|---|
| `DiagnosticAiSettingsSheet` | Provider、Endpoint、API Key、模型和“拉取模型” | 认证方式选择、账户状态、套餐类型、授权/撤销、数据用途提示 |
| `DiagnosticAiModels` | `bearer`、`api_key_header`、`custom_header`、`none` | OAuth/PKCE、设备授权、专用 Coding Plan Key、认证状态和授权范围 |
| `DiagnosticAiProviderCatalog` | 国内 Provider Manifest 和 OpenAI-compatible 基础字段 | 认证/计费/允许用途/地区/条款版本的能力声明 |
| `DiagnosticAiProviderService` | 模型列表和诊断分析请求 | OAuth 刷新、套餐端点、配额、错误分类、Provider 专用协议 |
| `DiagnosticAiProfileStore` / Secret Store | 本机保存非秘密资料和 API Key | token 分离、撤销、轮换、过期清理、账号隔离 |
| `DiagnosticAiAssistantPanel` | 脱敏诊断请求、捕获和分析结果 | 数据发送前预览、套餐限制提示、设置建议预览与确认 |
| `ProEntries` / `ProFeatureCatalog` | Pro 可见性与运行时门控 | 每种认证和 Coding Plan 能力的独立运行时门控 |

本阶段不修改上述实现，只把后续可执行边界、UI 和验收标准固定下来。

## 3. 认证与套餐能力模型

### 3.1 认证方式枚举

Provider Manifest 使用以下认证能力，页面只能渲染 Manifest 声明过的选项：

| 认证模式 | 用户体验 | 安全要求 | 适用条件 |
|---|---|---|---|
| `api_key` | 粘贴 API Key，测试并保存 | Asset Store、不可回显、不进日志/同步 | 开放平台 API 或明确允许第三方应用的专用 Key |
| `oauth_pkce` | 系统浏览器授权，回到应用 | PKCE、state/nonce、最小 scope、刷新和撤销 | 供应商公开 OAuth 且允许移动/桌面第三方客户端 |
| `device_authorization` | 显示一次性代码，用户在浏览器确认 | 短时 device code、轮询上限、撤销 | 供应商公开设备授权流程 |
| `coding_plan_key` | 输入供应商专用 Coding Plan Key | 计划专用端点、模型白名单、用途检查 | 官方允许自定义应用或明确列出本应用类型 |
| `official_cli_bridge` | 连接供应商官方 CLI/SDK | 本地 IPC、权限隔离、版本钉住 | 计划只允许官方工具，且供应商允许 Bridge |
| `unsupported` | 显示不可用原因 | 禁止继续请求 | 只有网页登录、内部接口或用途不匹配 |

禁止增加“账号密码登录”“导入 Cookie”“粘贴网页 Token”“抓取官方客户端配置”四种隐式模式。

### 3.2 计费与允许用途

每个 profile 同时记录 `billingMode` 和 `allowedUseCases`，不能只记录一个 `providerId`：

```text
billingMode: payg_api | token_plan | coding_plan | subscription_chat | local
allowedUseCases: diagnostic_assistant | coding_agent | interactive_chat | batch
requiresInteractive: boolean
requiresOfficialTool: boolean
entitlementEndpoint: optional
termsVersion: string
dataRegion: mainland_cn | other | local | unknown
```

诊断请求只有在 `allowedUseCases` 包含 `diagnostic_assistant`、套餐仍有效、地区与数据策略匹配，并且 `requiresInteractive` 规则得到满足时才能发出。`coding_agent` 不自动等于 `diagnostic_assistant`。

### 3.3 国内首发 Provider 分层

下表是实现优先级，不是已完成能力；每一项必须在进入“可用”前补齐官方资料和实测证据。

| 层级 | Provider 类型 | 首发策略 | 默认认证状态 |
|---|---|---|---|
| D0 | DeepSeek、通义/Qwen、智谱 GLM、Kimi、硅基流动 | OpenAI-compatible API/模型列表先行 | `api_key`，Coding Plan 另行核验 |
| D0 | Ollama 等本机服务 | 明确开启局域网/本机端点，显示数据不出本机 | `none` 或本机令牌 |
| D1 | 百度文心/千帆、字节豆包/火山、讯飞星火、MiniMax | 独立 adapter，按官方协议和错误码实现 | 先 `api_key` |
| D1 | 已有 Coding Plan 的国内服务 | 只接专用 Key/官方 OAuth，必须通过用途审查 | `review_required` |
| D2 | 其他大陆 Provider | Manifest + adapter + 数据政策核验 | `hidden_until_verified` |
| D3 | OpenAI、Anthropic、Gemini、Azure、OpenRouter | 后续国际适配 | 不阻塞国内首发 |

以官方资料为例，阿里云百炼 Coding Plan 使用独立的计划 Key 和地址，并与普通 API Key 分离；其 FAQ 还限制计划用于指定的交互式编程工具。智谱 Coding Plan 的官方工具助手也以专用 API Key 配置为主。因此，不能把“能填写 Key”当成“RemoteDesktop 可以合法消耗该套餐”。实现时应把这类套餐初始标为 `review_required`，直到供应商确认诊断类第三方应用的允许用途。

## 4. 信息架构与 UI 目标

保留现有三个顶层部分，但把“辅助 AI 配置”内部重构为四步信息架构。Phone 使用 Sheet，Pad/PC 使用右侧面板，标题、关闭、滚动和现有设置组件保持一致。

```text
诊断与 AI 帮助
├─ 辅助 AI 配置
│  ├─ 连接方式
│  ├─ Provider 与认证
│  ├─ 模型与额度
│  └─ 隐私与数据
├─ 启动 AI 辅助
└─ 传统日志
```

### 4.1 顶部 Provider 状态卡

位置：配置页顶部，固定在滚动内容上方。

显示：

- Provider 名称和自有图标（不复制供应商品牌素材）；
- 当前模型；
- 认证类型：API Key、官方账户、Coding Plan、本机；
- 状态：未配置、待授权、已连接、即将过期、配额受限、用途不允许、已撤销；
- 最近测试时间和数据处理地区；
- 主按钮：`配置`、`重新授权`、`测试连接`或`退出账户`。

状态卡不显示完整账户邮箱、完整 Key、完整端点或精确配额秘密；账户只显示脱敏标识。

### 4.2 Provider 选择页

使用分组卡片：

- 中国大陆 Provider；
- 本机/局域网；
- 国际 Provider（后续适配，置灰并说明）；
- 自定义兼容端点（高级入口）。

每张卡显示能力标签：`模型列表`、`流式`、`视觉`、`官方登录`、`Coding Plan`、`仅官方工具`。标签来自 Manifest，不由模型自由生成。

点击 Provider 后进入认证方式选择；如果只有一种认证方式，自动选中但仍显示完整用途和数据说明。

### 4.3 认证方式选择

使用单选卡，而不是把所有字段堆在一个表单里：

```text
选择连接方式

[ API Key ]       开放平台按量或 Token Plan
[ 官方账户登录 ]  通过系统浏览器授权，不在应用内输入密码
[ Coding Plan ]   仅在供应商允许诊断类第三方应用时显示
                  [仅官方编码工具可用] 时显示阻断说明
```

页面底部显示：`查看供应商条款`、`查看隐私政策`、`发送哪些数据`。用户必须确认用途后才能保存受保护凭据。

### 4.4 API Key 配置页

字段顺序：

1. Provider 预设端点（可展开修改）；
2. API Key 密码输入框；
3. 模型 ID 或“拉取模型”；
4. 数据处理地区和训练使用声明；
5. `测试连接`、`保存配置`；
6. `轮换 Key`、`删除配置`。

Key 不回显，不写入文本错误，不允许放在 URL query。拉取模型成功后显示模型能力、更新时间和套餐可用标记。

### 4.5 官方账户登录页

```text
使用供应商账户

RemoteDesktop 将打开供应商官方授权页面。
我们不会接收你的密码。

授权范围：模型调用、模型列表、套餐状态（如供应商提供）
诊断数据发送：仅在每次分析前单独确认

[打开官方授权页]
```

授权回调只接受已登记的 HTTPS/App Link/自定义 scheme 组合，校验 `state`、PKCE verifier、issuer、client ID、redirect URI 和账户 owner。回调失败时保留页面，不留下半成品 token。

### 4.6 Coding Plan 页面

Coding Plan 页面必须明确标识“供应商专用套餐”，并显示：

- 专用 Key 与普通 API Key 是否互通；
- 专用 Base URL；
- 支持的模型白名单；
- 允许的工具/场景；
- 剩余配额（只有官方提供查询接口时显示）；
- 数据处理地区、留存和训练策略；
- 供应商条款版本与核验时间。

如果 `requiresOfficialTool=true` 或不包含 `diagnostic_assistant`，页面直接显示：

> 该套餐只允许在供应商指定的编程工具中使用，不能用于 RemoteDesktop 诊断助手。请改用开放平台 API 或供应商允许的连接方式。

不显示“尝试连接”按钮，避免以请求结果反推条款许可。

### 4.7 模型与额度页

采用“可用模型列表 + 当前选择 + 刷新时间”的结构。每个模型显示：

- 模型 ID 和显示名；
- 输入模态、上下文上限、流式/视觉能力；
- 当前套餐是否支持；
- 最近一次列表刷新时间。

模型拉取失败时允许手动输入，但显示“未验证模型”，且发送前再做一次 Provider 错误分类。配额未知时显示“供应商未提供额度查询”，不伪造剩余次数。

### 4.8 隐私与数据页

用可展开清单显示本次 AI 请求会包含的字段：

- 用户主动描述的问题；
- 经过二次脱敏的诊断事件；
- 协议、设备类型、应用版本和时间范围；
- 不包含的字段：密码、Key、Cookie、文件内容、屏幕、音频、剪贴板、终端正文和 raw hilog。

用户可设置：每次发送前确认、只允许本机 Provider、诊断结果保留天数、立即清理本地 AI 数据。设置变更本身不触发网络请求。

## 5. AI 浮窗和设置辅助 UI

### 5.1 入口与状态

右上角 AI 入口对有效 Pro 账号常驻显示，覆盖主机列表和远程会话；不再提供隐藏入口的用户开关。入口只存在于应用窗口内，不申请系统级悬浮窗权限。权益撤销时由统一生命周期门控立即隐藏。

使用 RemoteDesktop 自有的渐变圆环/波纹标识，只借鉴 Apple Intelligence 的状态驱动和轻量动效，不复制 Apple 图标或资源。

| 状态 | 视觉 | 可用动作 |
|---|---|---|
| 空闲 | 静态渐变环，低频呼吸 | 打开面板 |
| 打开中 | 光环扩散为胶囊 | 等待布局，不发送请求 |
| 就绪 | 显示问题快捷卡片和输入框 | 输入、选择范围、发送 |
| 思考中 | 内圈旋转，显示 Provider/模型 | 取消 |
| 准备抓取 | 显示模块、时长和数据范围 | 确认/取消 |
| 抓取中 | 收缩为悬浮球和环形进度 | 查看进度/停止 |
| 等待确认 | 琥珀色徽标 | 确认设置或邮件 |
| 错误/离线 | 灰色或红色短提示 | 查看原因、换 Provider、重试 |
| 权益撤销 | 立即消失 | 保留传统日志入口 |

抓取期间改为悬浮球，避免遮挡远程桌面；只有抓取结束后才恢复结果面板。

### 5.2 输入首屏

快捷卡片：`连接失败`、`黑屏/花屏`、`输入无效`、`文件传输`、`账号/同步`、`帮我调整设置`。

发送区底部固定显示当前 Provider、模型、数据外发状态和“仅发送脱敏诊断包”。发送前打开数据预览，用户确认后才申请 capture lease 和发起 Provider 请求。

### 5.3 设置建议流程

助手不能直接执行任意设置。交互固定为：

```text
建议
→ 查看证据
→ 预览当前值/建议值差异
→ 用户确认
→ 类型化写入
→ 显示结果与撤销入口
```

建议卡必须显示 `settingId` 对应的用户可读名称、当前值、建议值、理由、证据事件和风险。密码、凭据、Key、OAuth、网络代理、VPN、TUN、证书、付款、远端服务和 Shell 只能跳转到设置页，不能由模型直接写入。

### 5.4 邮件确认

邮件发送与 AI Provider 外发分开确认。结果面板提供：

- `查看将发送的日志和诊断结论`；
- `打开邮件草稿`；
- `不发送`；
- 附件生成失败时单独重试或仅发送文字结论。

应用不自动调用发送接口，不把 API Key、OAuth token 或原始日志加入附件。

## 6. 技术落地分期

### P0：策略与 Manifest（先做）

交付：

- `DiagnosticAiAuthPolicy`、`DiagnosticAiBillingPolicy`、`DiagnosticAiUseCasePolicy`；
- Manifest 新字段和版本校验；
- `api_key`、`coding_plan_key`、`oauth_pkce`、`device_authorization` 能力枚举；
- 供应商资料、条款、隐私政策和数据地区登记表；
- 用途不匹配时 fail-closed；
- Provider 账户和 Pro owner 双重隔离。

退出条件：未知认证模式默认不可用；Coding Plan 未完成用途核验不能保存为可用 profile；现有 API Key 路径行为不回归。

### P1：API Key 与 Coding Plan 专用 Key

交付：

- 配置页认证方式 UI；
- 普通 API/Token Plan 和专用 Coding Plan Key 分开保存；
- 专用 Base URL、模型白名单、配额和错误分类；
- 供应商条款版本和用户同意记录；
- Provider adapter contract tests 和脱敏网络 fixture。

退出条件：每个 Provider 只有通过官方用途核验才显示 Coding Plan；Key、端点和响应不泄露到日志；账户切换、撤销、Pro 失效后请求立即阻止。

### P2：官方 OAuth/PKCE 与设备授权

交付：

- 系统浏览器授权页、回调校验和失败恢复；
- PKCE/state/nonce、issuer、client ID、redirect URI 绑定；
- refresh token 安全存储和最小 scope；
- 账户切换、退出、撤销、过期和重新授权；
- 没有授权查询接口时显示“套餐状态未知”，不猜测账户权益。

退出条件：不存在密码或 Cookie 输入；异常回调不产生残留 token；网络、时间、账户 owner 和 App generation 改变时请求可取消。

### P3：官方 CLI Bridge（仅必要时）

只有供应商正式允许 Bridge，且 HarmonyOS 有可维护的官方 SDK/CLI 才评估。Bridge 需要：

- 明确的本地 IPC 协议和版本锁定；
- 最小权限和每次请求的用户可见状态；
- 无任意 Shell、无静默后台进程、无自动执行远程命令；
- Bridge 不可用时回落到普通 API，不绕过条款限制。

如果没有官方支持，直接关闭该路线，不实现逆向兼容层。

### P4：设置建议与 UI 完整化

交付：

- `SettingProposal` schema 和白名单；
- 建议预览、差异、确认、写入结果和撤销；
- Phone/Pad/PC 响应式布局、键盘安全区、大字体、减少动态效果；
- 右上角入口、浮窗、捕获悬浮球状态机；
- Provider/套餐/隐私状态在所有页面一致显示。

退出条件：模型没有工具权限；没有确认不能写入；捕获期间悬浮球可取消且不会停止手动抓取；页面消失会取消请求并释放 owner。

### P5：真实 Provider、设备和发布验收

交付：

- 每个 D0 Provider 的真实模型列表和一次诊断分析；
- API Key、专用 Coding Plan Key、OAuth（如有）分别验收；
- Phone/Pad/PC 视觉、输入、旋转、键盘和浮窗验收；
- 账号切换、Pro 退款/撤销、离线、冷启动和恢复验收；
- 邮件草稿、附件预览和取消验收；
- 生产环境、服务条款、隐私政策和 AppGallery 文案复核。

在所有证据完成前，feature 状态保持 `experimental`，Coding Plan 不得显示为“已支持”。

## 7. 数据安全与实现约束

- API Key、access token、refresh token 进入专用 Asset Store；RDB/Preferences 只保留非秘密元数据、指纹、revision 和 consent ID。
- 密钥不进入云同步、备份、导出、崩溃日志、hilog、诊断包、邮件正文或附件。
- Provider 只允许 HTTPS 和审核过的认证 Header；禁止把密钥放进 URL query，禁止关闭证书校验，禁止携带认证头跨 origin 重定向。
- Provider 响应、远程文档和模型输出均视为不可信文本；AI 请求为 tool-less，不能调用设置、连接、文件、邮件、Shell 或支付操作。
- 每次 await 前后重新核验 owner、账号 generation、Pro entitlement、profile revision、页面 generation、capture lease 和 consent。
- 诊断请求默认只发送二次脱敏结构化事件；不读取 raw hilog、数据库原文、屏幕、音频、剪贴板、终端正文、文件内容或凭据。
- 本地审计只保存 providerId、模型、认证模式、数据地区、consent、schema/redaction 版本、bundle hash、大小和结果状态。
- 远程端点、解析地址、响应体、模型数量、并发、超时、流式帧和重定向均有限制；失败时 fail-closed。

## 8. 测试与验收矩阵

### 8.1 代码与策略

- Manifest schema：未知字段、过期版本、未知认证和用途不匹配均拒绝。
- API Key：保存、轮换、删除、账号隔离、Pro 撤销和冷启动。
- OAuth：state/PKCE/nonce、错误回调、重复回调、过期、撤销、账户切换和并发取消。
- Coding Plan：专用 Key/URL 分离、模型白名单、官方工具限制、配额未知、条款版本变化。
- 设置建议：白名单、旧值 fencing、二次确认、撤销和页面消失取消。
- 捕获：手动/AI owner 互斥、停止释放、bundle discard、generation 失效和迟到响应。

### 8.2 UI 与设备

Phone / Pad / PC 每个平台都要验证：

- 设置入口、四步配置、错误状态和大字体；
- 系统浏览器授权回调与取消恢复；
- Coding Plan 阻断卡和普通 API 回落；
- 右上角入口默认关闭、开启、页面切换和会话顶部栏；
- 思考、抓取悬浮球、分析结果、设置确认和邮件预览；
- 键盘、旋转、Pad 右栏、PC 宽窗口、减少动态效果；
- 账号切换、Pro 失效、离线和冷启动清理。

### 8.3 真实外部验收

必须分别记录以下证据，不能用 HAP 构建代替：

- 供应商官方认证/套餐用途允许性；
- 真实模型列表与分析请求；
- 真实 Provider 错误、限流和配额响应；
- 设备上的视觉、触控、键盘和浮窗行为；
- 系统邮件草稿和附件预览；
- AppGallery/生产账户、退款、撤销和隐私政策状态。

## 9. 风险与回退

| 风险 | 处理 |
|---|---|
| Coding Plan 允许官方 CLI，不允许自定义应用 | 页面阻断，回退普通 API，不做逆向 Bridge |
| Provider 没有 OAuth 或套餐查询 | 继续 API Key；状态显示未知，不假设订阅权益 |
| OAuth 回调在设备/地区受限 | 保留 API Key 路径，提示使用系统浏览器重试 |
| 专用 Key 能请求但条款不明确 | 标记 `review_required`，不进入可用目录 |
| Provider 响应格式变化 | Manifest/adapter 版本化，错误可见，禁止静默换模型 |
| 用户误把诊断助手当代码代理 | 首屏和配置页明确“只读诊断/受控设置”，不开放通用 Agent |
| Provider 数据处理地区不符合选择 | 发送前阻断并显示替代 Provider |
| Pro 撤销或账号切换期间有异步请求 | generation/revision fencing，取消请求并清除内存秘密 |

## 10. 计划交付物

1. 本计划文件，作为账户登录、Coding Plan 和 UI 的实施基线。
2. Provider 能力登记表和每家供应商的官方资料/条款核验记录。
3. Manifest、认证、套餐、用途和数据策略的 schema 与策略测试。
4. Phone/Pad/PC UI 线框和状态转场清单；实现时沿用现有 RemoteDesktop 组件和主题。
5. OAuth/PKCE、专用 Coding Plan Key、API Key 三套独立验收报告。
6. 真实 Provider、设备、邮件和 Pro 生命周期证据包。

## 11. 不在本次升级范围内

- 读取供应商网页 Cookie、内部 Session 或逆向私有接口；
- 把用户的 Chat/订阅额度当成通用 API；
- 在应用中运行任意 Shell、远程编码 Agent 或自动改安全配置；
- 系统级全局悬浮窗和后台语音监听；
- 通过模型自动发送邮件、自动连接远程主机或自动修改付款/账户设置；
- 为了显示“支持 Coding Plan”而绕过供应商用途限制。

## 12. 参考资料与证据边界

- [阿里云百炼 Coding Plan](https://help.aliyun.com/zh/model-studio/coding-plan)：专用 Coding Plan Key、专用 Base URL 和支持模型。
- [阿里云 Coding Plan FAQ](https://help.aliyun.com/zh/model-studio/coding-plan-faq)：Coding Plan 与普通 API 的区别及工具/场景限制。
- [阿里云 Qwen Code 接入说明](https://help.aliyun.com/en/model-studio/qwen-code)：官方工具中的套餐配置方式。
- [智谱 Coding Tool Helper](https://docs.bigmodel.cn/cn/coding-plan/extension/coding-tool-helper)：Coding Plan 在官方支持工具中的 API Key 配置方式。
- [关联计划：Pro 诊断与 AI 帮助](2026-10-01-pro-diagnostic-ai-help-upgrade.md)：现有捕获、脱敏、Pro 门控和邮件边界。

外部 Provider 的当前价格、模型目录、OAuth 范围、套餐用途和服务条款都是易变事实；实现和发布前必须重新读取供应商官方资料，并把核验日期、版本和链接写入 Manifest/验收记录。HAP 编译成功只能证明代码可构建，不能证明 Provider 许可、账户登录、配额、设备 UI、邮件或生产支付已经验收。

## 13. 2026-10-02 实现记录

本轮实现提交：`7f5425ba feat(diagnostics): complete full-app AI assistant flow`；逐帧岛屿状态与光核组件在 `f7e07378`，卡片展开后的输入聚焦时序修正在 `241092bb`。

已经落地的 P0 行为：

- 普通应用使用问题直接请求 AI，不再强制启动日志抓取；意图分为询问用法、协助设置、诊断问题和反馈开发者。
- 诊断意图先在 Siri-style 卡片中说明抓取范围，只有用户点“开始抓取诊断”后才取得 capture lease；结束后再分析脱敏包。
- 设置意图携带全应用使用知识和对话摘要，只能返回白名单、可回滚的设置建议，卡片确认后才写入。
- 反馈意图可从结果卡生成开发者邮件草稿；系统邮件打开前仍保留预览，不自动发送。
- Provider 请求对拒绝 `response_format` 的兼容端点自动重试无该字段，并兼容自由文本、代码围栏 JSON、数组内容和 OpenAI-compatible `choices` 响应。
- 主机列表和远程会话顶部统一使用同一个 AI island；思考时收缩为浮动胶囊，抓取时显示进度与结束动作，完成后展开结果卡。
- 新增应用使用、五协议、设置、隐私、安全、诊断和邮件知识基线，版本为 `RemoteDesktop-help-2026-10-02-v1`。

验证记录：`default@OhosTestCompileArkTS` BUILD SUCCESSFUL（10.138 秒），签名 `assembleHap` BUILD SUCCESSFUL（1 分 3.717 秒）；`ohosTest@OhosTestCompileArkTS` 因项目未注册任务 `00306054` 不可执行。真实国内 Provider 请求、真机视觉/输入、系统邮件和账户/Pro 生命周期仍需单独验收。

## 14. Siri 逐帧参考的交互落地（2026-10-02）

本轮将用户提供的《Siri 交互逐帧详细提示词》和逐帧总览图作为视觉参考与状态验收表，未把附件中的示例联系人、第三方品牌或文案当作产品指令。实现按 RemoteDesktop 的权限和应用语义映射为以下状态：

- F000：顶部黑色紧凑胶囊只显示六点光核，作为唤起和处理中状态；
- F010：胶囊扩展为短任务状态，说明正在准备助手或处理诊断请求；
- F020：展开为顶部对齐的深色玻璃卡片；诊断意图先展示读取范围、脱敏说明和“开始抓取诊断/取消”，没有确认不会读取日志；
- F049/F057：抓取和思考时回到悬浮胶囊，完成后回到短答案卡片，保留底部彩色沉浸光而不覆盖整页；
- F091/F101：结果卡提供展开/收起、建议设置的逐项确认、邮件草稿预览，以及“继续询问 RemoteDesktop”的输入框，输入后沿用对话摘要再次请求 Provider。

动画时序采用可观察的三段式弹簧转场（紧凑光核 → 任务胶囊 → 会话卡片），用 ArkUI 动画和现有 HDS 沉浸材质实现；具体帧率和曲线仍以 Phone/Pad/PC 真机视觉验收为准。附件中“发送成功”的画面只作为卡片层级参考，邮件仍必须由用户预览并通过系统邮件显式发送，代码构建不等于邮件或 Provider 成功证据。

## 15. 持久化修复与三端质感升级（2026-10-02）

本轮修复提交：`3bd6fc23 fix(diagnostics): persist AI credentials and refine Siri surfaces`。

- 修复根因：旧版 `DiagnosticAiProfileStore.persist()` 把非秘密的 `secretRef` 清空，导致设置页本次运行可以拉取模型，重建助手后却无法读回 API Key；现在持久化 opaque alias，并对旧记录用 SecretStore metadata 自动回填。
- AssetStore 写入改为先替换旧 alias、写入后立即回读校验；Preferences/Profile 与 selected provider/model 做保存后回读校验；拉取模型或点击模型卡片会自动保存最终模型选择。
- Provider 解析兼容 OpenAI choices、Ollama `message.content`、`response` 和自由文本；助手在密钥读回失败时显示明确的重新保存提示，不再泛化为“未配置”。
- Phone/Pad/PC 通过 `deviceClass` 分配卡片宽度、高度、圆角和安全区；唤起时序调整为参考 GIF 的约 0/1/2 秒三阶段；思考环改为每个独立椭圆光片自旋、伸缩、漂移并叠加外环公转。
- 卡片底缘加入 HDS `HdsVisualComponent` 双边流光适配器，手写渐变作为兼容回退；入口按钮使用 SDK 可见的 `Celia_fill` 助手 glyph 包装为沉浸玻璃按钮。SDK 没有公开可嵌入的专有“小艺 Agent”按钮 API，因此不宣称调用了系统私有浮窗。

最新验证：`default@OhosTestCompileArkTS` BUILD SUCCESSFUL（15.734 秒），签名 `assembleHap` BUILD SUCCESSFUL（19.059 秒）；HAP SHA-256 为 `05e1bcade50852069cf62e13340514f7032c9179ed839b2dce39ee310cfaa18d`。该 HAP 已通过 `hdc install -r` 部署到 MatePad Mini `192.168.31.118:40123` 与 Mate 80 Pro Max `192.168.31.156:38451`，两台均回读 `com.example.remotedesktop` 1.1.6 / 1001007。`ohosTest@OhosTestCompileArkTS` 仍因任务 `00306054` 不存在而不可执行；真实 Provider 发送、密钥跨重启回读和三端视觉仍需设备操作验收。

## 16. 全应用 Agent、会话与用量闭环（2026-10-02）

- `DiagnosticAiConversationStore` 按账号作用域保存最近 50 个本机会话、助手名称/语气/本地记忆和用量估算；不会写入主机同步、诊断包或 Provider 配置。
- 问答、设置引导、诊断和开发者反馈共用一个 Agent 请求入口。模型只能返回结构化建议，应用通过 `DiagnosticAiAppActionPolicy` 白名单打开页面；模型不能输出路由、命令或直接写入 `AppStorage`。
- 诊断包在 Provider 成功返回后才释放；网络失败、页面重建、密钥回读失败或请求过大都会保留并提供重试/丢弃动作。发送前对 Provider 请求做 48 KiB 有界摘要，完整脱敏包留在本机。
- 新增功能必须同步更新 `GuideContentRegistry`、`DiagnosticAiKnowledgeBase`、Agent 模式/动作白名单、隐私说明、用量统计和三端浮窗验收用例；构建通过不代表真实 Provider、设备或邮件成功。

## 17. 独立用量监控、个性化与多订阅（2026-10-02）

### 17.1 信息架构

“诊断与 AI 帮助”设置区现在固定为六个入口：

1. 辅助 AI 配置：添加、验证、删除 Provider 和模型；多个配置可以同时保留。
2. 启动 AI 辅助：Siri 风格对话、应用操作卡、诊断抓取和开发者反馈。
3. AI 用量监控：订阅切换、Provider+模型分项统计和总览。
4. AI 个性化设置：名称、语气、本地记忆开关、用户画像摘要和清除操作。
5. AI 会话管理：本地会话列表、原 Provider/模型归属和继续对话弹窗。
6. 传统日志抓取：与 AI Provider 完全分离的原有脱敏日志工具。

用量监控和个性化不再作为 Provider 配置页底部的附属卡片。这样用户可以分别理解“我用了哪个订阅、花了多少”和“助手应该怎样与我交流”。

### 17.2 多订阅模型

- `DiagnosticAiProfileStore` 保存多个 owner-scoped Provider profile；`DiagnosticAiSettings.selectedProviderId/selectedModelId` 是“下一次新请求”的当前订阅。
- `DiagnosticAiConversationStore` 以 `providerId + modelId` 记录请求次数、输入/输出 Token、缓存 Token 和估算费用；历史会话保存原始 Provider/模型归属，不随当前订阅切换而迁移，继续对话时先恢复该订阅。
- 费用只有在 Provider 返回真实账单时才可标记为账单值；当前客户端使用估算值并明确显示估算口径，不能把估算当作供应商账单。
- API Key 永远不进入用量记录、会话正文、诊断包、邮件或云同步；删除 Provider 时同时删除对应 Asset Store 密钥。

### 17.3 个性化与记忆边界

- 名称、语气、回答长度、助手角色、语言、主动建议、敏感操作确认和本地画像摘要是独立字段；关闭本地记忆只停止把摘要附加到新请求，不删除历史会话。
- “清除本地记忆”只清除画像摘要；“删除 AI 数据”才同时删除会话、用量和偏好。账号切换通过 owner scope 隔离，不能读取上一账号的会话或画像。
- 交互参考主流助手的分层方式：记忆/个性化独立于聊天历史，Provider/订阅独立于个性化；应用额外保留本地优先和可见删除入口。

### 17.4 动作注册表与执行模式

`DiagnosticAiAppActionPolicy` 现在登记设置页、五协议设置、远程会话工具栏和诊断/反馈入口。每个动作有 `execute`、`floating` 或 `inline` 模式及敏感操作确认标记：

- 页面导航、协议设置和普通开关：思考胶囊 → 打开现有设置模块 → 完成胶囊/悬浮球；
- 日志抓取、会话诊断和长任务：悬浮球模式，保持远程桌面可操作；
- 断开、凭据、文件传输、隐私、Ctrl+Alt+Delete 和密钥相关操作：二次确认后才调用已有回调；
- 模型只能返回动作 ID 或解释文本，不能返回路由、AppStorage key、命令或任意代码。

Provider 的结构化响应包含 `appActions`，解析器只接受动作注册表中的 ID，未知值直接丢弃；`recommendedReadOnlySteps` 仅作为旧 Provider 的文本回退映射。新增设置 Sheet、开关或协议工具栏能力时，必须同时登记动作 ID、展示名、执行模式、确认策略和 HostList/RemoteSessionTopBar 的现有回调，否则 Agent 只能解释该功能而不能生成可点击的模块卡片。页面重建后的待分析诊断包先重新绑定当前账号的 Profile/Asset Store 密钥，再决定显示配置引导；因此失败重试入口不会被“AI 未就绪”状态遮住。

`settingProposals` 另有独立的可回滚布尔设置目录。应用在写入前读取实时 `AppStorage`，若 Provider 携带的 `currentValue` 已过期则拒绝应用并要求重新询问；凭据、密钥、主机地址、代理、TLS、付款和任意命令永远不进入该目录。

新设置/协议/会话功能的 Definition of Done 必须包括：动作 ID、展示标签、能力门控、确认策略、知识库步骤、GuideContentRegistry 教程、隐私说明、用量归属和 Phone/Pad/PC 浮窗验收用例。个性化和用量弹窗必须按可用视口高度计算原生 Sheet 高度，内部只使用一个滚动容器，禁止固定高度截断设置项或让内容溢出遮罩层。

## 18. 2026-10-02 P0 实现记录

在当前活动分支上，P0 已从计划落到代码 checkpoint `56895bc2`（前一 UI/catalog checkpoint 为 `4884e28e`）：

- `DiagnosticAiProviderManifest` 增加认证能力、计费模式、允许用途、官方工具/交互式要求、条款版本、数据地区和 Coding Plan 模型白名单；既有普通 API Key Provider 保持 `diagnostic_assistant` 允许用途。
- 新增 `DiagnosticAiAuthPolicy`、`DiagnosticAiBillingPolicy` 和 `DiagnosticAiUseCasePolicy`。Agent 发起诊断请求前统一检查认证方式、套餐用途、授权状态、条款版本、数据地区和 consent；未知认证、用途不匹配、官方工具专用或 Coding Plan 未核验时 fail-closed。
- 旧 API Key profile 在 owner-scoped ProfileStore 读取时迁移为显式 `api_key`/`payg_api`/`connected` 元数据，并生成 legacy consent 标记；不会读取密码、Cookie 或网页 Session。

本阶段验证：`default@OhosTestCompileArkTS` BUILD SUCCESSFUL（38.347 s），签名 `assembleHap` BUILD SUCCESSFUL（51.381 s），会话/价格/路由与 P0 auth/billing/use-case 策略测试 PASS；`ohosTest@OhosTestCompileArkTS` 任务 `00306054` 仍未注册。P0 HAP 需要重新安装后再做设备回读；真实 Provider 官方条款/用途、账户授权、设备视觉/输入、邮件和生产权益仍未验收。下一步是 P1 认证方式选择 UI、普通 API/Token Plan 与专用 Coding Plan Key 分离及条款同意记录。
