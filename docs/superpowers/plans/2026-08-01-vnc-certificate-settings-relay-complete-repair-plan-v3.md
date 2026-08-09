# VNC 证书弹窗、设置一致性与中继可用性 V3 完备修复计划

- 计划日期：2026-08-01（Asia/Shanghai）
- 审计仓库：`RemoteDeskHarmonyOS`
- 计划落盘基线：`codex/upgrade-1-1-0-cloud-sync@a71f3337d`
- 本地 `main`：`a71f3337d`
- 远端参考：`origin/main@bfae6ef30`
- 文档状态：**仅完成只读审计与实施计划；未修改 ArkTS、native、测试、配置、设备数据或 Git 历史**
- 目标版本：后续独立 VNC 修复任务；本计划不授权在当前文档任务中实现
- 发布结论：VNC TCP 直连已有真机证据；VNC 中继整体仍是 NO-GO，直到真实 UltraVNC Repeater mode12、TLS 证书、断线重连和云矩阵完成

## 0. 结论先行

本轮不应只把当前 `promptAction.showDialog` 换成一个更大的弹窗。正确修复是把 VNC TLS
信任升级为与现有 RDP 证书预检相同等级的产品闭环，同时保持 VNC 的 transport、owner、云同步和
安全语义独立：

1. **交互对齐 RDP**：使用 `bindSheet`，具备探测中、首次信任、已信任匹配、证书变更、探测失败
   五态；提供证书详情、取消、重试、仅本次继续、信任/更新并信任。
2. **连接前确认**：TLS 证书必须在读取或发送 VNC 密码前完成探测与决策，不能先把凭据交给一个
   尚未确认身份的 endpoint。
3. **信任真实 TLS endpoint**：直连 TLS pin 归属 VNC host；Repeater TLS pin 归属 VNC gateway，
   不能继续按目标 host 重复保存同一 gateway 证书。
4. **保留 native 最终门禁**：ArkTS 弹窗只是决策 UI，真实连接仍必须把精确 SHA-256 pin 传给
   native；native pin 不匹配必须 fail-closed。
5. **不冒充 VeNCrypt**：当前实现是“TCP 建立后立即 TLS，再进入 RFB”，不是 RFB VeNCrypt
   security type。所有 UI、错误码和文档必须改成准确表述。
6. **一并修复设置和中继真实性缺口**：默认 transport/default gateway、重复滚轮方向、
   `jpegQuality` 空设置、host/gateway 交叉校验、Gateway target owner、TCP 测试误判等必须在同一
   独立任务内按阶段闭环。
7. **设备信任统一进入数据安全**：VNC 必须像 SSH 主机指纹和 RDP 证书一样，在主设置页“数据安全”
   中拥有独立的“VNC TLS 证书信任”记录管理；VNC 协议分组可保留快捷入口，但只能打开同一个
   管理 Sheet，不能形成第二套可变 owner。
8. **保持未实现能力 fail-closed**：WebSocket Gateway、SSH tunnel、public relay、reverse/listen、
   Repeater mode2 和 VeNCrypt 不因本计划出现而开放。

## 1. 实施边界

### 1.1 本计划覆盖

- VNC TLS 证书探测、详情展示、首次确认、证书变化、仅本次继续、持久信任、忘记信任；
- direct TCP 与 UltraVNC Repeater mode12 的 TLS endpoint 归属；
- VNC `secure_only`、`trusted_network`、`allow_plaintext` 的可判定语义；
- 现代/经典 VNC 新增和编辑流程的默认 transport/default gateway 一致性；
- VNC 显示、编码、帧率、滚轮、剪贴板和诊断设置的能力真实性；
- VNC Gateway 保存、绑定、深度健康检查、mode12 真实端点验收；
- `vncrecordv2` trust payload、设备本地确认、云恢复后重新确认和兼容迁移；
- 完整 host/native/API 23/真实 endpoint/云端/其他协议回归矩阵。

### 1.2 本计划不覆盖

- 实现 VeNCrypt、SASL、Apple Remote Desktop 账号认证或 VNC username 认证；
- 实现 Tight/JPEG、H.264/H.265/VP9/AV1 等视频 transport；
- 实现 WebSocket Gateway、SSH tunnel、public relay、SOCKS/HTTP proxy 或 reverse VNC；
- 把 UltraVNC mode2 伪装成 Viewer 连接模式；
- 修改 RDP 证书 owner、RDP host 字段、FreeRDP 信任策略或 RDP 现有 Sheet；
- 修改 RustDesk relay、SSH host key 或其他协议的数据 owner；
- 在 AGC 控制台创建/重建 `vncrecordv2` 表；该动作仍是外部发布前置；
- 以编译、TCP 端口可达或 fixture 通过替代真实 Repeater/TLS 验收。

## 2. 当前事实与根因矩阵

| 范围 | 当前事实 | 风险/缺口 | V3 目标 |
| --- | --- | --- | --- |
| VNC TLS 首次确认 | `RemoteDesktop.ets` 从错误字符串解析 `VNC_TRUST_REQUIRED:<fp>` 后调用系统 `showDialog` | 只有完整指纹和“确认并重连”；无证书主体、颁发者、名称、有效期、变化态、一次性连接或异步生命周期保护 | RDP 风格五态 Sheet + 结构化 probe 结果 |
| 信任记录管理 | VNC 可变 trust 列表位于 VNC 协议分组；“数据安全”目前只有 SSH 指纹、RDP 证书和 RustDesk 认证信任 | 用户无法在统一设备信任中心查看/撤销 VNC host 与 Gateway 证书；与 RDP 产品结构不一致 | 数据安全新增独立 VNC TLS 证书管理；VNC 分组仅复用同一入口 |
| TLS 信任 owner | `VncTrustService.save()` 固定 `ownerType=host`，连接时按 `vncHost.id` 查 pin | 多个目标共用同一 TLS Gateway 时重复确认；无法准确表达实际证书 endpoint | direct→host，repeater→gateway |
| TLS 语义 | native 在 RFB 前直接 `TLS_client_method()`；`SSL_VERIFY_NONE` 后要求 SHA-256 pin | UI 出现“TLS/VeNCrypt”，容易误导为已支持 RFB VeNCrypt 或系统 CA 验证 | 明确“TLS 包装 + 指纹固定”；VeNCrypt 继续不可用 |
| 证书变化 | 已保存 pin 不匹配只返回失败文本 | 没有展示旧/新指纹差异和显式更新路径 | 进入 `CERTIFICATE_CHANGED`，默认拒绝，用户可仅本次或更新信任 |
| 默认连接 | `VncSettingsSheet` 可保存默认 Repeater，但现代 `VncAddFlow` 初始值硬编码 direct | 设置看似保存但现代流程不生效；`defaultGatewayId` 不可选 | 所有新增入口使用同一 resolver |
| Gateway target | 新 Gateway 表单仍要求 `targetId`，运行时却以 host target 为主，gateway 仅旧数据 fallback | 一个 Gateway 被错误建模为绑定一个 target，不利于多目标复用 | 新 Gateway 只拥有 endpoint；target 归 host |
| Repeater TLS | 当前 `vncTls = host.tls || gateway.tls` | repeater host 的 TLS 开关实际作用于 gateway socket，语义混乱 | direct 只看 host TLS；repeater 只看 gateway TLS |
| host/gateway 一致性 | 正常 UI 会过滤，但运行时主要按 host transport 做 availability 判断 | 异常导入/旧记录可能绑定错 transport 或 disabled gateway | service、preflight、native 三层交叉校验 |
| Gateway 测试 | 只创建 TCP socket并立即关闭 | “端口可达”不能证明 TLS、mode12 banner、target pairing、RFB 首帧或重连 | 分层健康状态，深度测试止于 RFB banner，不发送密码 |
| 画质/JPEG | `jpegQuality` 可保存但无 UI、无 native 投影；`custom` 归一化成 balanced；Tight 不开放 | 空设置和能力错觉 | 废弃无效字段的活动语义，不开放未实现编码 |
| 帧率 | 15/30/60/不限控制 framebuffer request pacing | 用户可能理解为服务端保证 FPS | UI 明确“请求上限”，诊断展示 requested/effective |
| 滚轮方向 | 运行时权威是共享 `rustdeskReverseWheel`；VNC payload 仍保存 `reverseWheel` | 云端只恢复 VNC settings 时可能与实际个性化方向不一致 | 共享个性化成为唯一权威，VNC 字段仅兼容读取 |
| 安全策略 | `trusted_network` 和 `allow_plaintext` 在 native 都允许明文 | 名称不同但协议结果相同 | 定义并实现可判定差异，或在实现前合并 UI 语义 |
| 云同步 | 本地 scope 和 `vncrecordv2` 校验存在 | AGC 远端字段为空，上传 Code 24/-1108 | App 侧不伪报成功；AGC 修复后做双设备矩阵 |

## 3. VNC TLS endpoint 与信任模型

### 3.1 引入唯一 endpoint resolver

新增纯策略 `VncTlsEndpointPolicy.ets`，所有证书探测、信任查找、真实连接和 Gateway 深度测试
必须调用同一个 resolver，不允许各页面自行拼接 host/port/TLS：

```text
resolveVncTlsEndpoint(host, gateway?) ->
  ok
  endpointOwnerType: host | gateway
  endpointOwnerId
  transport: direct_tcp | ultravnc_repeater
  connectHost
  connectPort
  serverName
  tlsRequired
  securityPolicy
  repeaterTarget
  stableEndpointBinding
  errorCode
```

规则：

1. `direct_tcp`：不得绑定 Gateway；endpoint 是 host 的 `host:port`；TLS 由 host 控制；trust owner
   是 host。
2. `ultravnc_repeater`：必须绑定存在、启用、同 transport、`mode12` 的 Gateway；endpoint 是
   gateway 的 `host:port`；TLS 只由 gateway 控制；trust owner 是 gateway；target ID 只来自 host，
   旧 gateway target 仅作有审计日志的兼容 fallback。
3. `secure_only` 且解析后 TLS 关闭：在打开密码 Sheet 前返回 `E-VNC-TLS-REQUIRED`。
4. host/gateway transport、mode、owner scope、userId/store/generation 任一不匹配都 fail-closed。
5. endpoint identity 必须稳定绑定 owner 和非敏感 endpoint fingerprint；不能只用可变 label。
6. 日志只记录 transport、owner 类型、端口是否存在和不可逆短 fingerprint，不记录真实地址、
   target ID、完整证书指纹或账号 scope。

### 3.2 trust owner 修正

`VncTrustService` 的接口从只接收 `ownerId` 改为接收结构化 endpoint identity：

```text
VncTrustOwner {
  ownerType: host | gateway
  ownerId
  userId
  storeIdentityFingerprint
  endpointBindingFingerprint
}
```

不变量：

- direct 证书只能被同一 host endpoint 使用；
- gateway 证书可被绑定到该 gateway 的多个 VNC target 复用；
- ownerType、ownerId、账号 scope、store/generation 和 endpoint binding 必须全部匹配；
- 修改 Gateway endpoint 后，旧 pin 只作为历史候选，不得自动用于新 endpoint；
- 云端恢复的 trust row 只有候选意义；没有设备本地交互确认 marker 时 `confirmed=false`；
- crypto reset、账号切换、store 切换、Gateway 删除或 endpoint 变化必须清理/失效本地确认；
- 忘记 trust 写普通用户删除 tombstone，但 scope 关闭不得反向删除云行。

### 3.3 trust payload v2

继续使用物理表 `vncrecordv2` 和 `recordtype=trust`，不新增物理列。将 payload 扩展为版本化 JSON：

```json
{
  "payloadVersion": 2,
  "fingerprintSha256": "64-char-lowercase-hex",
  "confirmed": true,
  "confirmedAt": 0,
  "endpointOwnerType": "host|gateway",
  "endpointBindingFingerprint": "sha256",
  "subject": "bounded string",
  "issuer": "bounded string",
  "commonName": "bounded string",
  "notBeforeMs": 0,
  "notAfterMs": 0,
  "rootTrustedAtProbe": false,
  "hostMismatchAtProbe": false
}
```

约束：

- subject/issuer/CN 仅用于用户回看，不作为信任判断；真实连接只认精确 SHA-256 pin；
- 每个字符串有严格长度和 UTF-8/控制字符边界，拒绝把任意证书文本写入日志或 UI；
- 不保存 raw PEM、证书链、私钥、session ticket 或完整 endpoint；
- v1 host trust 兼容读取。direct host 可在再次连接确认后升级；repeater host trust 不自动改成
  gateway trust，必须重新确认；
- record ID 和普通日志不得直接回显完整 fingerprint；管理页仅显示分组/截断值。

## 4. RDP 风格 VNC 证书 Sheet

### 4.1 状态机

新增纯策略 `VncCertificatePreflightPolicy.ets`：

```text
IDLE
  -> PROBING
  -> TRUST_FIRST_TIME
  -> TRUSTED_MATCH
  -> CERTIFICATE_CHANGED
  -> ERROR
  -> CLOSING
```

分类规则：

- probe 失败或无证书：`ERROR`；
- 无本地确认 pin：`TRUST_FIRST_TIME`；
- owner、endpoint binding 与 pin 全匹配：`TRUSTED_MATCH`，不显示 Sheet，直接进入密码/连接阶段；
- 当前证书与本地 pin 不同：`CERTIFICATE_CHANGED`；
- 云端有相同 pin 但本机无 confirmation marker：仍是 `TRUST_FIRST_TIME`；
- 云端候选与当前证书不同：`CERTIFICATE_CHANGED`，不能 last-write-wins 自动替换；
- 证书过期、尚未生效、根不受信或主机名不匹配作为显式 warning flags；不隐式转换成已信任。

### 4.2 视觉与信息层级

Sheet 视觉仿照 `HostListPage.rdpCertificatePanel()`：

- 手机/窄屏：`SheetType.BOTTOM`；PC/大屏：`SheetType.CENTER`；
- 固定标题和操作区，中间详情可滚动；适配大字体、键盘、安全区和横竖屏；
- `PROBING`：LoadingProgress + “正在检查 VNC TLS 证书”；
- `ERROR`：黄色警告图标、脱敏错误、取消/重试；
- 首次信任：锁/盾牌图标，明确“首次见到该 endpoint”；
- 证书变化：红色高风险提示，明确“保存的证书与当前证书不同”，同时显示旧/新指纹的短摘要；
- 可展开详情：连接类型、endpoint owner、CN、Issuer、Subject、有效期、根信任、名称匹配、
  SHA-256 指纹；
- direct 显示“VNC 主机证书”；repeater 显示“VNC Gateway 证书”，不得把 target ID 写成证书主机。

### 4.3 按钮语义

| 状态 | 按钮 | 结果 |
| --- | --- | --- |
| PROBING | 取消 | 失效当前 generation，清理一次性凭据，关闭连接尝试 |
| ERROR | 取消 / 重试 | 重试创建新 generation；旧结果不得回写 |
| TRUST_FIRST_TIME | 显示详情 / 取消 / 仅本次继续 / 信任 | “仅本次”只写内存 handoff；“信任”写 VNC trust + 本地 marker |
| CERTIFICATE_CHANGED | 显示详情 / 取消 / 仅本次继续（高风险） / 更新并信任 | 默认焦点不放在高风险动作；更新必须覆盖为新 pin 并失效旧 marker |
| TRUSTED_MATCH | 无弹窗 | 直接进入凭据或连接阶段 |

“仅本次继续”不是关闭 native 校验，而是把当前 probe 得到的 pin 放入当前连接 attempt 的
一次性 handoff；native 仍按该 pin 校验。手动断开、页面销毁、账号/store/generation 变化、后台安全屏障
和下一次新连接都必须清除它。

### 4.4 Sheet 生命周期

复用 RDP 已验证的生命周期原则，但实现 VNC 独立策略：

- `probeGeneration`：取消、重试、切换主机、endpoint 变化时递增；
- `connectionAttemptGeneration`：同一主机重复点击只能保留最新连接尝试；
- `closing` 和 `pendingRoute/pendingConnect`：原生 Sheet 退出动画完成前不复用同一宿主；
- `onDisappear` 后才进入密码 Sheet 或真实连接，避免两个 native Sheet 同时退场；
- probe 回调必须同时匹配 generation、host owner、gateway owner、account/store generation；
- 页面销毁和 `SensitiveDataBarrier` 清空一次性证书 decision 与一次性密码；
- probe/保存失败保留可重试状态，不自动降级明文，不自动连接。

### 4.5 连接顺序

所有 VNC 入口最终汇聚到 `RemoteDesktop`，因此证书预检放在 VNC 会话页的连接状态机中，避免
HostList、`VncSettingsPage`、现代 FAB“保存并连接”等入口各实现一套：

```text
读取 vncHostId
  -> 加载 account-scoped host/gateway/settings
  -> resolveVncTlsEndpoint
  -> 校验 transport/security
  -> TLS 关闭：进入凭据阶段
  -> TLS 开启：异步 certificate probe
       -> trusted match：进入凭据阶段
       -> first/change/error：显示 VNC certificate Sheet
       -> once/trust decision：Sheet 完整退出
  -> 读取一次性或持久 VNC password
  -> native connect（必须带 expected pin）
  -> RFB/repeater/auth/首帧
```

这样可以保证 password 不先于证书确认，同时覆盖所有路由入口。现有
`VNC_TRUST_REQUIRED:<fingerprint>` 保留为 native 防御兜底，但改为触发同一 Sheet/结构化重探测，
不能继续直接弹系统 `showDialog`。

### 4.6 “数据安全”中的 VNC TLS 证书信任管理

主设置页现有“数据安全”卡片已经按设备信任顺序提供：

```text
SSH 主机指纹
RDP 证书信任
RustDesk 认证信任
```

V3 在 RDP 证书信任之后新增独立行：

```text
VNC TLS 证书信任
N 条已信任 · M 条待本机确认
```

并将数据安全分组副标题更新为准确覆盖“端到端加密、2FA 与设备信任”。该入口打开统一
`VncCertificateTrustManagerSheet`，不是 `VncSettingsSheet` 内的第二份列表。

管理 Sheet 必须包含：

- 标题“VNC TLS 证书信任”，说明“云同步记录不会自动取得本机信任”；
- 空态：“首次连接启用 TLS 的 VNC 主机或 Gateway 并选择信任后，会在这里显示”；
- 分组/标签：`VNC 主机` 或 `VNC Gateway`，不得把 Gateway 证书显示为 target host 证书；
- owner 的用户可识别名称、当前 endpoint 是否仍存在、direct/repeater transport；
- 本机状态：已确认、待本机确认、endpoint 已变化、owner 已删除/孤立记录；
- 信任时间、CN、Issuer、有效期、根/名称告警和脱敏 SHA-256 摘要；
- “查看详情”：显式展开完整 SHA-256、Subject 和 probe 元数据；普通列表和日志不展示完整值；
- “忘记”：二次确认后调用唯一 `VncTrustService.remove()`，清除本地 marker，并按用户删除语义
  写 tombstone；
- “重新检查”：重新 probe 当前真实 endpoint。证书相同只刷新非权威展示元数据；证书变化必须
  打开第 4 节同一 changed Sheet，不能像普通刷新一样静默替换并信任；
- host/gateway 被锁或安全中心要求验证时，删除、更新信任前走现有 lock gate；取消不改变记录；
- cloud candidate 可查看和删除，但“确认”只能在当前实时 probe 与 candidate pin 匹配后完成，
  不能在离线管理页点一下就变成本机信任。

唯一 owner 规则：

- `VncTrustService` 是数据源和 mutation owner；
- “数据安全”管理 Sheet 是唯一可变管理界面；
- VNC 协议分组原“Trust / 证书管理”改成“VNC TLS 证书信任”，显示同一计数并跳转到同一个
  manager；不得继续由 `VncSettingsSheet.trustContent()` 自己加载、删除和维护另一份状态；
- VNC“安全策略与 TLS”Sheet 只展示策略、当前信任摘要和“前往数据安全管理”的导航，不直接
  修改 trust rows；
- popup mode、刷新订阅、Sheet 关闭/返回统一由主设置页宿主管理，避免数据安全与 VNC 分组同时
  挂载两个 manager。

备份和云文案同步修正：凡当前只写“SSH 公钥/RDP 证书”的设备信任说明，必须明确是否包含
`VNC trust candidate`；设备本地 confirmation marker 永远不进入普通备份、完整备份或云端。

## 5. native 证书探测与最终校验

### 5.1 结构化 probe API

新增 `probeVncCertificateAsync`，调用链为：

```text
RemoteDesktop
  -> ExtensionLoader
  -> extension_loader_napi.cpp
  -> VNC TLS certificate probe
  -> VncCertificateInfo
```

返回字段至少包括：

```text
ok, errorCode, errorMessageCategory
fingerprintSha256
commonName, subject, issuer
notBeforeMs, notAfterMs
rootTrusted, hostMismatch
tlsVersion, cipherCategory
```

要求：

- probe 只做 TCP + immediate TLS 握手和证书读取，不发送 RFB、Repeater ID、密码或剪贴板；
- 支持 IPv4/IPv6、DNS、连接超时、取消和非阻塞 NAPI Promise；
- SNI 使用 resolver 产生的 serverName；IP literal 不伪造 DNS 名；
- 复用安全的 X.509 摘要/边界工具，不复用 RDP 的数据 owner；
- subject/issuer/CN 长度、编码、时间解析和证书链深度严格有界；
- error 使用稳定枚举，不依赖英文 OpenSSL 文本分类；
- 普通日志只记录错误类别、耗时、TLS 版本类别和短 endpoint fingerprint。

### 5.2 最终 pin 门禁

现有 `VncTransport::validatePeerCertificate` 保持最终权威，并补齐：

- expected pin 为空且 TLS 开启：返回结构化 `TRUST_REQUIRED`；
- pin 不匹配：返回结构化 `CERTIFICATE_CHANGED`，包含只供 UI handoff 的当前 fingerprint，普通日志不打印；
- constant-time 比较规范化后的 64 字符 SHA-256 hex；
- 证书缺失、摘要失败、TLS 版本过低、连接取消均独立错误码；
- probe 与 connect 的证书可能在两次握手之间变化；真实连接必须再次校验，不能信任 probe 结果本身；
- `secure_only` 继续要求 TLS + pin，不把 `SSL_VERIFY_NONE` 描述成系统 CA 已验证。

### 5.3 VeNCrypt 边界

本计划完成后，native RFB security types 仍只支持：

- `1`：None（受安全策略约束）；
- `2`：VNC Password；
- transport 外层 immediate TLS（可选/按策略强制）。

不得宣称支持 type `19` VeNCrypt、X509Vnc、TLSVnc、Apple 账号或 username。设置页和 Trust 空态中
所有“TLS / VeNCrypt”改为“VNC TLS 证书/指纹”。VeNCrypt 如要实现，必须另立协议计划、fixture、
真实服务器矩阵和安全复核。

## 6. 设置一致性修复

### 6.1 默认 transport/default gateway

新增 `VncHostDefaultsPolicy.ets`，现代 FAB、经典编辑和独立 VNC 主机目录统一使用：

- `defaultTransport=direct_tcp`：初始 direct，使用 defaultPort；
- `defaultTransport=ultravnc_repeater` 且 defaultGatewayId 指向同账号、启用、mode12 Gateway：
  初始 Repeater 并选中该 Gateway；
- default Gateway 缺失/停用/类型错误：安全回退 direct，并显示一次明确原因；不能静默选择列表中另一项；
- 设置 Sheet 增加“默认 Gateway”选择器，只列可用 mode12 Gateway；删除 Gateway 时清理失效默认引用；
- `repeaterMode` 对用户固定 mode12，不再作为可随意写入 mode2 的普通全局值；
- host 保存前再次解析并验证 defaults，防止 Sheet 打开后 Gateway 被删除或切换账号。

### 6.2 direct 与 repeater 字段互斥

- direct：显示地址、端口、host TLS；清空 gatewayId；不保存/使用 target ID；
- repeater：显示 target ID、Gateway 选择和 Gateway TLS 摘要；隐藏 host TLS 与 direct port；
- 新 Gateway 不要求 target ID；`VncGatewayValues.targetId` 仅保留旧记录兼容读取；
- host target ID 必填、有界、不得记录到普通日志；Gateway 可供多个 target 复用；
- service 保存、云解析、连接 preflight 和 native config 四层使用同一交叉校验策略。

### 6.3 画质、编码和帧率真实性

- 活动选项只保留 `speed/balanced/quality`，旧 `custom` 兼容读取后归一化且 UI 不声称存在；
- 活动编码只保留 `auto/zrle/raw`；`tight` 继续 fail-closed；
- `jpegQuality` 标记 deprecated：旧 payload 可读，新 UI 不展示，native 不消费前不得称为可调设置；
- UI 明确：画质预设当前主要影响自动色深；RFB 3.3/macOS 会为兼容把 8 位回退到 16 位；
- 帧率文案改为“增量画面请求上限”；HUD 同时显示 requested limit、实际 receive/present FPS、
  encoding 和 effective depth；
- 不恢复实测更慢的 Retina RAW 自动回退；RAW 仅用于手动诊断。

### 6.4 滚轮方向单一权威

- `usersettings`/共享个性化键 `rustdeskReverseWheel` 成为唯一运行时与云同步权威；
- VNC 设置页可保留同一开关入口，但直接读写共享 key，不再独立保存一个可冲突的 VNC 值；
- `vncrecordv2.reverseWheel` 仅用于旧版本兼容读取，不可覆盖已存在的共享个性化值；
- 迁移必须是幂等且设备本地可解释：只有共享 key 尚未存在时才允许采用旧本地值；云端 VNC 值不自动改变设备输入习惯；
- 双指、实体滚轮、触控板 Axis 最终都只在协议发送边界应用一次方向，测试防止双重反转。

### 6.5 安全策略可判定语义

目标语义：

| 策略 | 行为 |
| --- | --- |
| `secure_only` | 必须 immediate TLS，并经过一次性或持久 pin 校验；否则连接前失败 |
| `trusted_network` | TLS 优先；明文只允许用户明确选择且 native 实际连接地址全部属于可接受的私网/链路本地范围；解析到公网、混合地址或重绑定时阻断 |
| `allow_plaintext` | 用户二次确认后允许任意 endpoint 明文；连接页持续显示风险标识 |

实施 `trusted_network` 时必须在 native 对实际 `sockaddr` 做最终分类，不能只在 ArkTS 根据输入字符串
判断“192.168”。DNS 多地址、IPv6、VPN/TUN、NAT64 和地址变化必须有测试。若无法在同一阶段安全实现，
则不得保留一个与 `allow_plaintext` 结果完全相同却名称更安全的选项；应先合并/重命名语义。

## 7. UltraVNC Repeater mode12 完整可用性

### 7.1 协议边界保持不变

- 只开放 Viewer mode12；
- 严格读取 12 字节 `RFB 000.000\n`；
- 严格发送固定 250 字节、NUL 填充的 `ID:<target>`；
- target 超长、空值、控制字符、短 banner、错误 banner、短写和取消都 fail-closed；
- mode2 继续返回服务端监听角色错误；
- mode12 不使用 Gateway token，UI 不展示无效 token 输入。

### 7.2 Gateway 健康状态分层

将当前“测试 TCP”拆成不误导的分层结果：

```text
UNTESTED
TCP_REACHABLE
TLS_CERT_CONFIRMATION_REQUIRED
TLS_PIN_MATCHED
REPEATER_BANNER_OK
TARGET_PAIRED
RFB_BANNER_READY
FAILED(stage, stableCode)
```

- “测试端口”只更新 `TCP_REACHABLE`，界面明确“不代表 VNC 可用”；
- “深度测试”必须由用户选择/填写 target，并明确会发起一次短暂 Viewer pairing；
- TLS Gateway 先走同一证书 Sheet；
- 深度测试最多读取到真实 RFB banner 后主动关闭，不发送 VNC 密码、不进入 framebuffer；
- 健康结果是设备本地短期诊断，不作为云端 capability 或自动连接授权；
- enabled 只表示用户启用配置，不表示健康验证通过；卡片分别显示“已启用”和“最近验证阶段”。

### 7.3 真实 endpoint 验收

发布前至少需要一个真实 UltraVNC Repeater 和一个真实 VNC server，覆盖：

1. 无 TLS mode12：server 与 viewer 使用相同 ID，完成 pairing、RFB banner、密码、首帧、键鼠、
   滚轮、剪贴板策略、断开、立即重连；
2. TLS mode12：首次 Gateway 证书 Sheet、信任后连接、同 Gateway 第二个 target 不重复确认；
3. Gateway 证书轮换：必须进入 changed 状态，取消不连接，仅本次不落盘，更新信任后才替换 pin；
4. 错 target、server 未上线、错误 banner、半包、短写、慢速、网络切换、Gateway 停用/删除；
5. view-only、clipboard off/on、密码错误重试、后台恢复和 Surface 重建；
6. 真实 UltraVNC/TigerVNC/LibVNCServer 互操作，不以自写 fixture 代替全部外部证据。

## 8. 云同步、迁移和数据安全

### 8.1 云恢复规则

- `syncTrust=false`：trust 只在本地 owner 可见，不上传；
- `syncTrust=true`：可同步证书候选和元数据，但本地 confirmation marker 永不上传；
- 新设备拉取 trust 后第一次连接必须重新探测并弹窗；
- 同一 owner 出现多个 fingerprint 时保留冲突，不按更新时间自动选一个；
- 云端 trust 不能使 `trustedFingerprint()` 返回可连接 pin，除非本机 marker 与当前 endpoint binding 匹配；
- scope deselect 不写 tombstone；用户“忘记”才是删除；
- reset epoch、账号/store/generation 变化继续 fail-closed。

### 8.2 兼容迁移

- v1 direct host trust：保留为候选，首次连接重新确认后写 v2；
- v1 repeater host trust：不自动迁移到 Gateway，因为旧记录不能单靠 ownerId 证明证书属于哪个 endpoint；
- endpoint 修改：旧 trust 保留为历史/待确认，但不再参与连接；
- 旧 gateway target：只在 host target 为空时兼容读取，并在用户下一次显式保存 host 后完成 owner 归一化；
- 旧 `jpegQuality/custom/tight/reverseWheel` 仅兼容解析，不能重新暴露为已实现能力；
- 所有迁移必须具备 before-image、幂等 ID、失败回滚和 read-back；不能因解析失败删除旧数据。

### 8.3 AGC 外部 blocker

当前 AGC 下发的 `vncrecordv2` 表字段为空，真实上传仍会出现 `fields is null`、Code 24/-1108。
本计划的 App 代码不得把本地成功写成云端成功。发布前由用户在 AGC 补齐 19 字段并发布新 schema，
然后执行：

- 单设备 settings/host/gateway/secret/trust 上传下载；
- 新设备 cloud-first，不发布本地默认覆盖云端；
- 两设备 trust 候选同步但分别本地确认；
- 证书冲突、Gateway endpoint 修改、scope deselect、用户删除、crypto reset、账号切换；
- Code 24/-1108、离线、超时、进程终止后的重试与不误报。

## 9. 错误码与诊断

新增稳定错误类别，UI 不解析 OpenSSL/英文字符串决定流程：

```text
E-VNC-CERT-PROBE-CONNECT
E-VNC-CERT-PROBE-TLS
E-VNC-CERT-MISSING
E-VNC-CERT-INVALID
E-VNC-CERT-TRUST-REQUIRED
E-VNC-CERT-CHANGED
E-VNC-CERT-PIN-MISMATCH
E-VNC-CERT-SAVE
E-VNC-CERT-STALE
E-VNC-ENDPOINT-OWNER
E-VNC-ENDPOINT-BINDING
E-VNC-GATEWAY-TRANSPORT
E-VNC-GATEWAY-DISABLED
E-VNC-REPEATER-BANNER
E-VNC-REPEATER-TARGET
E-VNC-PLAINTEXT-NETWORK
```

诊断必须区分：TCP、TLS、证书、Repeater pairing、RFB version、RFB security、密码、首帧、空闲超时、
解码和送显。不得输出密码、token、target ID、完整 endpoint、完整指纹、subject/issuer 原文或云 owner。

## 10. 分阶段实施任务

### 阶段 A：冻结基线与先写失败测试

目标：在任何业务实现前把本计划的安全与 owner 不变量写成纯策略测试。

任务：

1. 保存当前 direct 真机脱敏基线和 `182/182` native 基线；
2. 新增 endpoint resolver、certificate state、decision、trust owner、default host、gateway binding、
   shared wheel authority 的失败测试；
3. 测试首次、匹配、变化、云候选、endpoint 修改、账号/store/generation 变化；
4. 测试 direct/repeater TLS 归属和 host/gateway transport 不一致；
5. 测试未实现 transport 全部继续 fail-closed。

退出条件：新测试在旧实现上按预期失败，且没有修改 RDP/RustDesk/SSH 行为。

### 阶段 B：native 结构化 VNC 证书 probe

目标：提供不发送 RFB/凭据的异步 TLS 证书信息源。

任务：

1. 提取/新增有界 X.509 元数据工具；
2. 实现 direct immediate-TLS probe、取消、超时、IPv4/IPv6/SNI；
3. 增加 NAPI Promise 和 `ExtensionLoader` 类型；
4. 将真实连接的 trust-required/changed/pin-mismatch 改为稳定 code；
5. 保留 constant-time pin 校验和 TLS 1.2+ 下限。

退出条件：scripted TLS server 覆盖自签、受信根、名称不匹配、过期、轮换、无证书、pin 匹配/不匹配；
普通日志无敏感数据。

### 阶段 C：VNC 证书 Sheet 与连接状态机

目标：所有 VNC 路由入口在凭据前完成统一证书决策。

任务：

1. 新增 VNC certificate Sheet 状态和 builder；
2. 接入 `RemoteDesktop` 现有 bindSheet 生命周期，避免与 VNC password、控制台和其他 Sheet 重叠；
3. 实现 generation、取消、重试、Sheet onDisappear 后继续；
4. 实现一次性 pin handoff 和持久 trust；
5. native 防御错误触发结构化重探测，不再调用简易 `showDialog`；
6. 取消/页面销毁/安全屏障清除一次性 pin 和未使用密码。

退出条件：首次、匹配、变化、取消、重试、快速重复点击、旋转、后台前台和页面销毁均无双弹窗、
旧回调覆盖或未确认连接。

### 阶段 D：trust v2 与 endpoint owner 迁移

目标：direct trust 归 host，Repeater trust 归 gateway，云恢复不自动信任。

任务：

1. 扩展 trust payload 校验和 view；
2. 更新 `VncTrustService` 的结构化 owner API、本地 marker key 和 endpoint binding；
3. 实现 v1 兼容与 fail-closed 迁移；
4. 在“数据安全”新增独立 `VNC TLS 证书信任` 行和统一管理 Sheet；
5. 将 VNC 分组原 trust 列表收敛为同一 manager 的快捷入口，删除第二套可变 UI owner；
6. 管理 Sheet 显示 host/gateway、状态、时间、证书元数据和脱敏指纹，支持忘记与安全重探测；
7. endpoint 修改/删除/账号切换/crypto reset 失效确认；
8. 校正备份、云同步和安全中心文案，不导出本地 confirmation marker。

退出条件：同 Gateway 多 target 只需一次确认；云恢复、endpoint 改动和证书轮换均必须重新确认。

### 阶段 E：设置一致性

目标：消除保存但不生效、重复权威和空能力设置。

任务：

1. 现代/经典新增统一读取 default transport/default gateway；
2. 设置页增加默认 Gateway，删除/停用时清理引用；
3. direct/repeater 字段互斥，Gateway 不再要求新 target；
4. 废弃活动 `jpegQuality/custom/tight` 语义；
5. 帧率与画质文案对齐真实 native；
6. shared reverse wheel 成为唯一权威；
7. 落实或收敛 trusted-network/plaintext 的真实差异。

退出条件：每个可见设置都有“UI→持久化→会话→native/运行时→测试”证据；无死字段被描述为可用。

### 阶段 F：Gateway 深度检查与 mode12 交叉门禁

目标：端口可达不再被误判为中继可用。

任务：

1. 区分端口测试和深度测试；
2. 深度测试复用 endpoint resolver 和证书 Sheet；
3. socket fixture 覆盖 banner、250 字节 ID、短读写、取消、RFB handoff；
4. service/preflight/native 校验 transport、enabled、mode12、target；
5. 健康状态只落设备本地，不进入云 capability。

退出条件：UI 只有到 `RFB_BANNER_READY` 才能显示“协议链路已验证”；TCP 成功只显示端口可达。

### 阶段 G：真实设备和端点验收

目标：把代码证据升级为产品可用证据。

执行第 12 节完整矩阵；真实 Repeater、TLS、证书变化、同 Gateway 多 target、输入、剪贴板、断线重连
和其他协议 smoke 任一未通过，发布保持 NO-GO。

### 阶段 H：独立复核、闭环和发布记录

1. 按 D-020 由独立子 agent 对照用户问题、计划、diff、测试和真机证据；
2. 所有发现均在任务分支修复、重新测试并提交；
3. 两项 Hvigor、native、Light、diff、设备矩阵全部记录准确结果；
4. 更新 CURRENT/QUEUE/HANDOFF；
5. 未获用户授权不 push、不建 PR、不合并远端 main；
6. 只有用户授权且 required check/复核通过后，才合并并清理任务分支。

## 11. 目标文件清单

### 11.1 新增策略/类型候选

- `entry/src/main/ets/services/VncTlsEndpointPolicy.ets`
- `entry/src/main/ets/services/VncCertificatePreflightPolicy.ets`
- `entry/src/main/ets/services/VncCertificateProbeLifecyclePolicy.ets`
- `entry/src/main/ets/services/VncHostDefaultsPolicy.ets`
- `entry/src/main/ets/services/VncCertificateDecisionHandoff.ets`
- 对应 `entry/src/test/*.test.ets` 与 `entry/src/ohosTest/ets/test/*.test.ets`

### 11.2 现有 ArkTS 候选

- `entry/src/main/ets/pages/RemoteDesktop.ets`
- `entry/src/main/ets/pages/HostListPage.ets`
- `entry/src/main/ets/pages/RustDeskRelayPage.ets`
- `entry/src/main/ets/components/VncSettingsSheet.ets`
- `entry/src/main/ets/components/hostadd/VncAddFlow.ets`
- `entry/src/main/ets/components/resourceadd/VncGatewayAddFlow.ets`
- `entry/src/main/ets/services/VncTrustService.ets`
- `entry/src/main/ets/services/VncGatewayService.ets`
- `entry/src/main/ets/services/VncHostService.ets`
- `entry/src/main/ets/services/VncSettingsService.ets`
- `entry/src/main/ets/services/VncRecordPolicy.ets`
- `entry/src/main/ets/services/VncGatewayProtocolPolicy.ets`
- `entry/src/main/ets/services/VncSessionSettingsPolicy.ets`
- `entry/src/main/ets/services/ExtensionLoader.ets`
- `entry/src/main/ets/services/SensitiveDataBarrier.ets`
- 如为控制 HostList 体积新增组件：`entry/src/main/ets/components/VncCertificateTrustManagerSheet.ets`

### 11.3 native 候选

- `entry/src/main/cpp/extensions/extension_loader_napi.cpp`
- `entry/src/main/cpp/extensions/protocol_adapter.h`
- `entry/src/main/cpp/vnc/vnc_transport.h`
- `entry/src/main/cpp/vnc/vnc_transport.cpp`
- `entry/src/main/cpp/vnc/vnc_rfb_engine.cpp`
- `entry/src/main/cpp/vnc/vnc_transport_policy.h`
- `entry/src/main/cpp/test/vnc_rfb_protocol_test.cpp`
- 必要时新增独立 VNC TLS probe/证书工具和 socket fixture 文件；不得把 VNC owner 逻辑塞入 RDP adapter

### 11.4 文档候选

- `docs/VNC_GATEWAY_PROTOCOL.md`
- `docs/codex/CURRENT.md`
- `docs/codex/QUEUE.md`
- `docs/codex/DECISIONS.md`（仅新增长期有效安全边界时）
- `docs/codex/HANDOFF.md`

## 12. 验证矩阵

### 12.1 ArkTS/策略

- endpoint direct/repeater/gateway owner；
- host/gateway transport、mode、enabled、scope/generation 不一致；
- certificate state first/match/change/error/cloud-candidate；
- continue-once 不持久化，trust 持久化且本地 marker 必需；
- stale probe/result/sheet disappear/快速重复连接；
- default transport/default gateway 的有效、缺失、停用、删除；
- reverse wheel 单一权威与旧字段迁移；
- settings enum/normalization/不可见字段；
- secure/trusted/plaintext 决策；
- trust v1/v2、endpoint 修改、账号切换、reset epoch、scope deselect/delete。

### 12.2 native/host

- TLS 1.2/1.3、SNI、IPv4/IPv6、超时和取消；
- X.509 subject/issuer/CN/validity 有界解析；
- SHA-256 格式、constant-time match、missing/changed；
- self-signed、受信 CA、host mismatch、expired/not-yet-valid、证书轮换；
- Repeater banner、250 字节 ID、短读/短写、错误 banner、RFB handoff；
- RFB 3.3/3.7/3.8、None/VNC Password、安全策略；
- Raw/CopyRect/ZRLE/Cursor/DesktopSize/LastRect 不回归；
- wheel/viewOnly/clipboard/first-frame/idle timeout 不回归。

### 12.3 API 23 UI

- 手机/平板/PC，窄屏/宽屏，横竖屏，大字体，深浅主题；
- 首次证书、显示/隐藏详情、继续一次、信任、变化、取消、重试；
- Sheet 与密码、虚拟键盘、控制台、错误 Sheet 不重叠；
- 退出动画、旋转、后台前台、重复点击、断开立即重连；
- Trust 管理页忘记/重新确认和 host/gateway 标识；
- “数据安全”显示独立 VNC TLS 证书信任计数；从数据安全和 VNC 分组进入的是同一 manager、
  同一列表和同一 mutation owner；
- 已确认/待本机确认/endpoint 变化/orphan 四种记录显示正确；离线 cloud candidate 不能直接信任；
- 忘记、重新检查、证书变化转入同一 preflight Sheet，取消不改记录；
- SSH 指纹、RDP 证书、VNC TLS 证书、RustDesk 认证信任的顺序和各自 owner 不交叉；
- 默认 Gateway、新增 direct/repeater 字段互斥；
- Gateway 端口测试与深度测试的文案和状态不误导。

### 12.4 真实 VNC endpoint

- 标准 macOS Screen Sharing 明文 trusted-network direct；
- immediate-TLS wrapper/self-signed direct；
- 受信 CA direct；
- TigerVNC/UltraVNC/LibVNCServer；
- UltraVNC Repeater mode12 无 TLS/TLS；
- 同 Gateway 两 target；
- 证书轮换、错误 target、server 缺席、网络切换、立即重连；
- 首帧、持续帧、键鼠、双指/实体滚轮、方向、虚拟键盘、剪贴板、view-only；
- Retina ZRLE 保留现有性能边界，不声称稳定 30fps。

### 12.5 云和其他协议

- AGC 修复后的单设备/新设备/双设备/账号切换矩阵；
- Secret/Trust opt-in、云候选本地再确认、冲突、删除、reset；
- RDP 证书 Sheet、RDP 连接和证书管理零回归；
- RustDesk password/approval/2FA/relay/direct 零回归；
- SSH host key/passphrase/SFTP 零回归；
- 本地备份不新增证书链、私钥或本地 confirmation marker。

## 13. 建议提交序列

后续实施必须在独立 `codex/vnc-certificate-relay-settings-v3` 分支按小步提交，建议：

1. `test(vnc): pin certificate endpoint and settings invariants`
2. `feat(vnc): add structured TLS certificate probe`
3. `feat(vnc): add RDP-style certificate preflight sheet`
4. `fix(vnc): bind trust to direct host or gateway endpoint`
5. `fix(vnc): apply transport defaults and remove duplicate setting authority`
6. `fix(vnc): harden gateway binding and mode12 diagnostics`
7. `test(vnc): add TLS, repeater and lifecycle coverage`
8. `docs(vnc): record real endpoint acceptance and release gates`

每个提交只暂存任务文件；不得 `git add -A`，不得夹带当前或未来的 cloud-sync、RDP、RustDesk、SSH、
Moonlight 等不相关修改。

## 14. 强制门禁

每个实现 checkpoint 至少执行：

```sh
source scripts/macos_env.sh
hvigorw --mode module -p module=entry -p product=default default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon
hvigorw --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --no-daemon
```

并执行：

- VNC/native 定向测试和完整 native host suite；
- `git diff --check`、`git diff --cached --check`；
- Light 开源合规门；
- 影响 `ohosTest` 时尝试当前注册任务；若仍为 `00306054`，如实记录未运行；
- C/C++/OpenSSL 变化检查许可证、NOTICE、SBOM、provenance；
- 最终 API 23 真机和真实 endpoint 矩阵；
- D-020 独立复核。

编译成功不能替代真实 TLS/Repeater 证据；TCP 可达不能替代 RFB 首帧；自写 fixture 不能替代真实
UltraVNC/TigerVNC/LibVNCServer；用户手测一个 direct Mac 不能证明中继全部可用。

## 15. 停止条件与回滚

出现以下任一情况立即停止扩大实现：

- VNC trust 需要写入 RDP host、RustDesk relay 或 SSH owner；
- 云端候选可以绕过设备本地确认；
- continue-once 需要关闭 native pin 校验；
- probe 会发送 VNC 密码、Repeater token 或进入 framebuffer；
- Gateway 证书仍按 target host 保存；
- 为了“看起来可用”开放 WebSocket/SSH/public/mode2/VeNCrypt；
- 需要修改 `vncrecordv2` 物理 19 字段而没有迁移、AGC 和双设备计划；
- RDP 证书 Sheet 或其他协议出现回归；
- 两项 Hvigor、native、Light 或独立复核未通过。

回滚按阶段进行：

- Sheet 可独立回退到旧系统 Dialog，但 native pin 门禁不得回退；
- trust v2 可回退到 v1 兼容读取，但不得自动信任 cloud row；
- 设置修复可独立回退，不影响证书 owner；
- Gateway 深度测试可关闭，TCP 测试必须继续准确标注“仅端口”；
- 未验证 transport 继续由双层 allowlist fail-closed。

## 16. 完成定义

只有同时满足以下条件，才能报告“VNC 证书与 mode12 中继可用”：

1. 所有 VNC 连接入口在 TLS 模式下都先完成统一证书预检，再读取/发送密码；
2. RDP 风格 Sheet 五态、详情、一次性、持久信任、变化、取消、重试和生命周期全部通过；
3. direct trust 归 host、repeater trust 归 gateway，同 Gateway 多 target 不重复确认；
4. “数据安全”拥有独立 VNC TLS 证书信任记录管理；VNC 分组只复用同一 manager，没有第二套
   列表或 mutation owner；
5. cloud trust 新设备不会自动信任，endpoint/证书/账号变化 fail-closed；
6. host/gateway/default/target/TLS/security 设置与运行时一致，无保存但不生效的活动设置；
7. `jpegQuality/custom/tight`、VeNCrypt 和未实现 transport 不再被描述为可用；
8. Gateway UI 明确区分 TCP 可达、TLS、pairing、RFB banner；
9. 真实 direct TLS 和真实 UltraVNC Repeater mode12 完成首帧、输入、断线重连和证书轮换；
10. AGC 修复后完成单/双设备 trust 矩阵；
11. native、ArkTS 编译、signed HAP、Light、diff、API 23、其他协议 smoke 和 D-020 全部通过；
12. 所有 blocker 和未覆盖能力在 CURRENT/QUEUE/HANDOFF 中准确记录；
13. 未获用户授权不 push、不建 PR、不合并远端 main。

在上述条件全部达成前，产品文案只能写：

> VNC TCP 直连可用；UltraVNC Repeater Viewer mode12 已实现，真实端点验证进行中；其他 VNC
> Gateway 类型未开放。
