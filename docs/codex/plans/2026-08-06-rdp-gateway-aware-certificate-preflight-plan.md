# RDP Gateway-aware 证书预检修复计划

状态：方案和代码检查点已落地于当前工作树；Restricted Admin + RD Gateway
明确 fail closed；真实 Microsoft RD Gateway 端点验收待完成。RDP 改动与活动
SSH/渲染改动混在同一工作树中，尚未独立提交。

计划创建时不修改代码；后续实施在现有活动分支继续，所有真实端点和设备验收
仍按本文完成定义执行。

日期：2026-08-06

适用项目：`RemoteDeskHarmonyOS`

## 1. 目标

修复 RDP 证书预检与实际连接路径不一致的问题，使直连 RDP、透明 TCP
转发和 Microsoft RD Gateway 场景分别按真实协议进行预检。重点保证：

1. 配置了 Gateway 时，预检先验证 Gateway，再通过 Gateway 隧道验证目标 RDP；
2. Gateway 证书和目标 RDP 证书分别展示、确认、保存和校验；
3. 任何网关协议、TLS、RDP negotiation 或证书阶段失败时都明确失败，不能
   通过关闭证书校验或无条件 fallback 继续连接；
4. HTTPS 厂商堡垒机、Azure Bastion 等非标准 RD Gateway 不被误判为普通 RDP
   或普通 RD Gateway；未实现对应协议时必须 fail closed。

完成后，用户看到的错误必须能回答“失败发生在 Gateway 还是目标 RDP”，而
不是把 Gateway 的 HTTP/RPC/WebSocket 响应泛化成“RDP TLS handshake failed”。

## 2. 当前基线和证据

现有 P0 计划
[`2026-08-03-rdp-tls-handshake-fix-plan.md`](./2026-08-03-rdp-tls-handshake-fix-plan.md)
已经覆盖直连 RDP 的 TPKT/X.224 读取、RDP security negotiation 分类和 TLS
握手错误收集。该 P0 不包含 RD Gateway 或厂商堡垒机支持，本计划不回退或
否定它。

当前风险点：

- [freerdp_adapter.cpp:335](../../../entry/src/main/cpp/rdp/freerdp_adapter.cpp:335)
  的预检直接连接 `host:port`，发送 RDP X.224，再升级 TLS；它没有
  `gatewayHost/gatewayPort` 输入。
- [HostListPage.ets:3498](../../../entry/src/main/ets/pages/HostListPage.ets:3498)
  只把 `host`、`port`、`customHostname` 传给预检。
- [freerdp_adapter.cpp:4584](../../../entry/src/main/cpp/rdp/freerdp_adapter.cpp:4584)
  的真实连接却可以先设置 `FreeRDP_GatewayHostname`、Gateway 端口和
  `FreeRDP_GatewayEnabled`。
- [protocol_adapter.h:121](../../../entry/src/main/cpp/extensions/protocol_adapter.h:121)
  目前只有一个通用的目标 RDP 证书指纹字段。
- [freerdp_adapter.cpp:2137](../../../entry/src/main/cpp/rdp/freerdp_adapter.cpp:2137)
  的证书判定只读取这一份指纹，没有按
  `VERIFY_CERT_FLAG_GATEWAY` 选择 Gateway pin。
- 当前预检失败后存在“已有指纹时交给 native 连接”的兼容路径。该路径最多
  适用于受限的直连本地解析错误；不能用于 Gateway TLS、Gateway 隧道、目标
  TLS、证书变化或协议不匹配。

因此，当前实现不能证明“预检看到的证书就是实际连接会验证的证书”。

## 3. FreeRDP 官方依据

实施时以当前项目实际锁定的 FreeRDP 版本 API 为准，并在升级版本时重新核对
字段和回调签名。以下官方代码和 issue 是本计划的协议边界依据：

- FreeRDP RD Gateway 建立 TLS、HTTP/RPC 隧道和后续 RDP 通道的路径：
  [rdg.c](https://github.com/FreeRDP/FreeRDP/blob/master/libfreerdp/core/gateway/rdg.c#L1318-L1381)。
- Gateway TLS 与目标 RDP TLS 的证书处理分离：
  [tls.c](https://github.com/FreeRDP/FreeRDP/blob/master/libfreerdp/crypto/tls.c#L1379-L1511)。
- Gateway 证书回调使用 `VERIFY_CERT_FLAG_GATEWAY` 区分阶段：
  [tls.c](https://github.com/FreeRDP/FreeRDP/blob/master/libfreerdp/crypto/tls.c#L1695-L1725)。
- RDP negotiation response、failure 和 selected protocol 的分类：
  [nego.c](https://github.com/FreeRDP/FreeRDP/blob/master/libfreerdp/core/nego.c#L785-L855)。
- Azure Bastion 不能直接按普通 RD Gateway 处理的现有讨论：
  [FreeRDP issue #11562](https://github.com/FreeRDP/FreeRDP/issues/11562)。
- Gateway 类型会影响 `http`、`rpc`、WebSocket 和 `no-websockets` 选择：
  [FreeRDP issue #12343 comment](https://github.com/FreeRDP/FreeRDP/issues/12343#issuecomment-3936239670)。
- RD Gateway/RDS Broker 协商失败的实际兼容性边界：
  [FreeRDP issue #12926](https://github.com/FreeRDP/FreeRDP/issues/12926)。

官方依据支持的结论是：Gateway TLS、Gateway 隧道和目标 RDP negotiation/TLS
是连续但不同的阶段；不能向 Gateway 443 端口直接发送普通 RDP X.224，也不能
把一份目标证书 pin 同时当作 Gateway pin。

## 4. 范围和明确边界

### 4.1 本计划包含

- 统一实际连接和证书预检使用的 endpoint/route 描述；
- 直连 RDP 的现有 P0 保持可用并继续回归；
- Microsoft RD Gateway 的 Gateway TLS、隧道和目标 RDP 双阶段预检；
- Gateway/目标证书的独立 trust record、pin、changed-certificate 处理；
- 按阶段和端点分类的 native/API/UI 错误；
- 真实 RD Gateway、目标主机和证书轮换验收；
- 开关、回滚、日志脱敏和发布门禁。

### 4.2 本计划不包含

- 不把 Azure Bastion 当成 Microsoft RD Gateway 修复；
- 不凭“端口为 443”“返回了 TLS”或“响应看起来像 HTTP”猜测厂商协议；
- 不实现任意厂商 HTTPS/网页堡垒机的通用适配器；
- 不通过 `cert:ignore`、`FreeRDP_IgnoreCertificate`、无条件接受回调或
  预检失败后强行连接解决问题；
- 不启用 Standard RDP Security、legacy TLS 或未知 security protocol 作为
  隐式 fallback；如确需兼容，必须另立计划并经过独立安全评审。

## 5. Endpoint 分类契约

### 5.1 分类表

| 类型 | 连接入口 | 预检首个协议 | 证书阶段 | 本计划处理 |
| --- | --- | --- | --- | --- |
| `direct_rdp` | 目标 `host:port` | RDP TPKT/X.224 | 目标 RDP TLS | 支持，沿用 P0 |
| `transparent_tcp_rdp` | TCP 转发后的 RDP 入口 | RDP TPKT/X.224 | 目标 RDP TLS | 支持，必须确认转发透明 |
| `microsoft_rd_gateway` | `gatewayHost:gatewayPort` | Gateway TLS，再 HTTP/RPC/WebSocket 隧道 | Gateway TLS + 隧道内目标 RDP TLS | 本计划新增 |
| `vendor_https_bastion` | 厂商 HTTPS/网页入口 | 厂商协议 | 可能只有 Gateway 证书，目标证书取决于厂商协议 | 本计划不通用支持，fail closed |
| `azure_bastion` | Azure Bastion 服务 | Azure Bastion Web/API/网页流程 | 不等同于 RD Gateway 双 TLS | 本计划不支持，单独立项 |
| `unknown_gateway` | 仅有模糊的代理/Gateway 字段 | 未知 | 未知 | 禁止预检后继续连接 |

### 5.2 配置规则

1. `endpointMode` 必须是显式枚举，默认值为 `direct_rdp`；不能以端口号、
   hostname 后缀或首包猜测网关类型。
2. `microsoft_rd_gateway` 必须同时有目标 endpoint 和 Gateway endpoint。
   Gateway 端口缺省为 443，但目标端口仍按目标 RDP 配置保存。
3. 现有 `gatewayHost` 非空的旧配置只能迁移为明确的
   `microsoft_rd_gateway`，或者标记为 `unknown_gateway` 让用户重新确认；
   不能静默当成厂商协议，也不能静默继续当前直连预检。
4. `customHostname` 只描述目标 RDP 的 server name/SNI、证书名和
   CredSSP 目标名；不能被复用成 Gateway SNI。
5. Gateway TLS SNI 必须使用 `gatewayHost`（或明确配置的 Gateway server
   name），目标 RDP TLS/证书名必须使用实际目标 server name。IP 连接和证书
   名不一致时，结果必须保留 host mismatch 标志并按独立 trust policy 处理。
6. endpoint 身份至少由以下字段组成：模式、目标 host/port/name、Gateway
   host/port/name、Gateway transport method 和协议版本。预检结果、pin 和
   异步 generation 都必须绑定该身份，防止切换主机或网关后复用旧结果。

## 6. 目标实现方案

### 阶段 A：冻结现状并完成端点判定

目标：在写 native/ArkTS 实现前，确认报告中的“堡垒机”属于哪一类。

工作项：

- 为问题样本收集脱敏的连接配置：目标 host/port、Gateway host/port、
  endpointMode、Gateway transport、customHostname，不记录口令和 token；
- 记录从客户端到入口的 DNS、TCP、TLS SNI、首个应用层协议和 Gateway 类型；
- 对直连入口、RD Gateway 入口、厂商 HTTPS 入口分别保存失败阶段和服务端
  错误，不把三者合并为同一个 TLS 错误；
- 确认项目构建中实际使用的 FreeRDP 版本、是否包含 Gateway HTTP/RPC/
  WebSocket 代码以及对应设置字段；
- 若拿不到真实 Gateway，先使用本地可控的 mock/recording endpoint，随后再
  做真实环境验收。没有真实 endpoint 时不能宣称 Gateway 已修复。

出口条件：

- 每个问题 endpoint 都有唯一分类；
- 能证明真实连接和预检使用同一 endpoint 描述；
- 未知或厂商协议样本被明确标为 unsupported，而非 RDP TLS failure。

### 阶段 B：统一 native/ArkTS 预检请求和结果模型

目标：把“预检哪个入口、预检到哪一阶段、信任哪张证书”变成显式契约。

建议的请求模型（名称可按现有 NAPI 风格调整）：

```text
RdpPreflightRequest
  route
    endpointMode
    targetHost
    targetPort
    targetServerName
    gatewayHost
    gatewayPort
    gatewayServerName
    gatewayTransport      # auto | http | rpc | websocket | no-websockets
  expectedTrust
    targetFingerprintSha256
    gatewayFingerprintSha256
  generation / requestId
```

建议的结果模型：

```text
RdpPreflightResult
  ok
  endpointMode
  routeIdentity
  stage                    # target | gateway | tunnel | negotiation
  errorCode / errorMessage
  gatewayCertificate       # optional, with stage=gateway
  targetCertificate        # optional, with stage=target
  targetNegotiation
  gatewayTransportRequested
  gatewayTransportNegotiated # nullable; unknown until observable
  requiresGatewayAuth
  requiresUserDecision
```

当前兼容结果模型中的 `gatewayTransportSelected` 仍然保留，但在锁定的
FreeRDP 3.26.1 适配层中它由请求配置直接填充，只能解释为
`gatewayTransportRequested`，不能解释为最终实际选择。后续若保留该字段，UI、
日志和持久化都必须使用“请求策略”语义；更推荐新增独立的 nullable
`gatewayTransportNegotiated`，只有抓包、FreeRDP instrumentation 或可观测
mock 明确证明最终分支后才填写，否则必须为 `unknown`。

每个证书记录至少包含 endpoint、SNI/name、CN、subject、issuer、SHA-256
fingerprint、rootTrusted、hostMismatch、notBefore/notAfter（若可获得）和
trust decision。结果不应只返回一份 `fingerprintSha256`，否则 UI 和存储层
仍可能把 Gateway 证书覆盖成目标证书。

实现要求：

- API 增加 Gateway 参数和双证书结果，但保持 direct 调用的兼容包装只在
  `direct_rdp` 下可用；
- 请求和结果带 generation/requestId，旧的预检结果不能覆盖新 host、网关
  或 transport 的状态；
- `gatewayHost`、目标 host、SNI 和证书 subject 在日志中全部脱敏；指纹只记
  hash 摘要或受控的完整值，不记录认证材料；
- native 与 ArkTS 使用同一份 route resolver，不能一侧认为有 Gateway、另一
  侧仍按直连调用。

出口条件：

- 任何 Gateway 配置都不会落到三参数直连 probe；
- 结果可以同时表达 Gateway cert 和 target cert；
- routeIdentity 变化时旧的 trust decision 不可复用。

### 阶段 C：实现直连和透明 TCP 预检保持路径一致

目标：不回归已经完成的 P0。

工作项：

- `direct_rdp`/`transparent_tcp_rdp` 继续按 TPKT 头、X.224 Confirm、RDP
  negotiation response/failure、TLS selection 的顺序执行；
- 仅对 `SSL`、`HYBRID`、`RDSTLS` 等当前 FreeRDP/P0 明确支持的选择进入 TLS；
- SNI、hostname check、CA trust、目标 pin 和用户确认沿用同一目标证书
  policy；
- Standard RDP Security、`RDP_NEG_FAILURE`、未知协议、非 RDP 首包和 TLS
  handshake 失败维持显式错误；
- 现有 `-22` 可作为 direct TLS handshake 的兼容错误码，但新 API 必须同时
  返回 `stage=target`、endpoint 类型和底层诊断，避免 UI 把 Gateway 错误
  显示为 RDP 错误；
- 直连的已保存指纹兼容 fallback 若保留，只能限于明确的本地 DNS/连接解析
  暂时错误，且 routeIdentity、目标 host/name、目标指纹完全匹配；不能对
  证书、TLS、RDP negotiation、Gateway 或未知协议启用。

出口条件：现有六类 RDP negotiation 测试继续通过，且 direct 连接的预检
endpoint、SNI、证书 pin 与真实连接完全相同。

### 阶段 D：实现 Microsoft RD Gateway-aware 双阶段预检

目标：使预检复用 FreeRDP 的 Gateway-aware 流程，而不是把 Gateway 443
当作普通 RDP 端口。

首选实现路径：

1. 创建一次带完整 route 配置的受限 FreeRDP preflight session；
2. 连接 `gatewayHost:gatewayPort`，建立 Gateway TLS，SNI 使用 Gateway
   hostname，触发并记录 Gateway certificate callback；
3. 按实际 Gateway 类型协商 HTTP/RPC/WebSocket；需要时支持
   `no-websockets`，但不能用猜测替代服务端能力探测；
4. 通过 FreeRDP Gateway 隧道访问目标 RDP，隧道内执行目标 RDP
   TPKT/X.224/security negotiation 和目标 TLS；
5. 触发并记录目标 certificate callback，确认目标证书后在进入桌面、频道和
   业务会话前结束 preflight session；
6. 返回一份包含两个证书阶段的 composite result。只有 Gateway TLS 和目标
   RDP TLS 都成功，Gateway 场景才可进入证书确认/连接路由。

实现约束：

- 优先调用项目锁定版本 FreeRDP 已有 Gateway/rdg/tls 路径；不要另写一套
  未覆盖的 HTTP/RPC/WebSocket 隧道解析器；
- 如果当前 FreeRDP API 无法在目标证书回调后安全停止，则抽取一个受控的
  preflight 生命周期适配层，确保停止发生在认证/桌面建立前，不能用“只验证
  Gateway 证书”冒充完整预检；
- Gateway 连接失败、Gateway TLS 失败、Gateway certificate reject、隧道
  协商失败、Gateway authentication required 和目标 RDP/TLS/certificate
  失败必须分阶段返回；
- 目标 host 不应被客户端绕过 Gateway 直接连接来获取目标证书。目标证书
  必须来自实际 Gateway tunnel；否则结果标记为不完整并阻断连接；
- 隧道复用、重试、连接取消、超时和资源释放必须与实际 FreeRDP session
  生命周期隔离，不能把 preflight socket 留给正式连接或反向复用。

出口条件：抓包或可观测 mock 能证明 Gateway 首包为 TLS/网关协议，未向
Gateway 入口发送 RDP X.224；目标证书来自隧道内目标阶段；两阶段均成功才
能放行连接。

### 阶段 E：分离证书信任和 FreeRDP 回调

目标：严格实现 Gateway pin 与 target pin 的一一对应。

建议的数据兼容策略：

- 现有 `rdpCertificateFingerprintSha256` 继续解释为目标 RDP certificate
  pin，或迁移为显式 `rdpTargetCertificateFingerprintSha256`；不得把旧值
  复制到 Gateway pin；
- 新增独立的 Gateway fingerprint、trust mode、trustedAt、subject/issuer
  和允许 host mismatch/untrusted root 的字段，或者使用带 stage 的结构化
  trust record；
- 已保存目标 pin 的直连主机保持兼容；已有 Gateway 配置如果没有 Gateway
  pin，必须重新完成 Gateway 证书确认；已有一份旧 pin 不能让双阶段直接通过；
- pin 绑定 routeIdentity。更换 Gateway host、port、server name、目标
  host/name 或 transport 后，至少重新验证受影响阶段；
- 证书轮换只替换对应阶段的 trust record。Gateway 轮换不能清除目标 pin，
  目标轮换也不能清除 Gateway pin，但任一阶段变化都阻断当前连接。

FreeRDP 连接设置和回调：

- 使用 FreeRDP 版本中对应的 Gateway accepted certificate 字段保存/传递
  Gateway trust；目标使用 accepted certificate 字段；字段名以锁定版本头文件
  为准并写入版本核对记录；
- `VERIFY_CERT_FLAG_GATEWAY` 时只读取和比较 Gateway pin；没有该 flag 时
  只读取和比较目标 pin；任何未知 flag 组合按拒绝处理并记录；
- changed-certificate、hostname mismatch、untrusted root 和普通 certificate
  callback 使用同一阶段映射；不能只修 `VerifyCertificateEx` 而遗漏 changed
  回调；
- 用户点击“信任 Gateway”只写 Gateway record；点击“信任目标”只写 target
  record。可提供“同时信任”按钮，但必须在 UI 和审计事件中明确列出两张证书；
- native 正式连接必须带上与预检相同的两个 trust decision，不能只设置
  `FreeRDP_CertificateAcceptedFingerprints` 这一份通用字段。

出口条件：使用两张不同证书的测试 Gateway 和目标主机时，四种组合结果
（两张都匹配、仅 Gateway 匹配、仅目标匹配、两张都不匹配）符合预期；任何
跨阶段 pin 都拒绝。

### 阶段 F：ArkTS 预检 UI、错误和持久化

目标：用户能准确理解并确认实际链路中的证书，不被误导继续连接。

工作项：

- 直连 UI 继续显示目标 RDP 证书；Gateway UI 分成 Gateway certificate
  和 target RDP certificate 两个阶段/区块；
- 每个阶段显示入口 host/port、SNI/server name、CN、issuer、SHA-256、根
  信任、主机名匹配、有效期和当前 trust state；敏感凭据不显示；
- Gateway 证书通过但目标证书尚未取得时，状态显示“等待 Gateway 认证/隧道
  建立”，不能显示“已验证”或自动连接；
- 错误标题按阶段显示：例如“堡垒机 TLS 失败”“堡垒机隧道协商失败”“目标
  RDP TLS 失败”“目标证书不匹配”；保留底层 code/detail 供诊断；
- 预检失败时默认停留在错误状态；只有显式取消、重新探测或修改 endpoint
  配置才能继续；
- 彻底审查现有 `shouldFallbackToNativeRdpConnectionAfterResolverFailure`。
  Gateway route 禁止任何 resolver/TLS/cert fallback；direct route 也只能
  按阶段 D 所列的窄范围策略工作；
- 预检状态与持久化使用 host/gateway/route generation，防止用户切换主机、
  关闭 Sheet 或重复打开时旧结果覆盖新结果；
- 旧数据迁移必须可逆：保留原目标 pin 的语义，新增字段为空时 Gateway
  进入重新确认，不自动删除用户记录。

出口条件：从主机列表发起直连和 Gateway 连接时，调用参数、native route、
UI 展示和最终连接参数一致；错误消息不再把 Gateway HTTP/RPC 响应归类为
RDP TLS handshake failure。

## 7. 错误分类和安全策略

新结果建议采用“稳定 code + endpoint + stage + 可读 detail”，而不是只依赖
一个整数。可保留现有 direct numeric code 作为兼容字段。

建议的阶段码：

| Code 前缀 | 阶段 | 示例 |
| --- | --- | --- |
| `E-RDP-ENDPOINT` | endpoint 配置/分类 | 缺少 Gateway host、未知 route |
| `E-RDP-GATEWAY-DNS` | Gateway 解析 | Gateway DNS 失败 |
| `E-RDP-GATEWAY-TCP` | Gateway TCP | 443 不可达、超时 |
| `E-RDP-GATEWAY-TLS` | Gateway TLS | TLS handshake、SNI 或协议版本失败 |
| `E-RDP-GATEWAY-CERT` | Gateway 证书 | pin 不匹配、hostname mismatch、过期 |
| `E-RDP-GATEWAY-TUNNEL` | Gateway 隧道 | HTTP/RPC/WebSocket 状态或协商失败 |
| `E-RDP-GATEWAY-AUTH` | Gateway 认证 | 需要凭据或认证失败 |
| `E-RDP-NEGOTIATION` | 目标 RDP negotiation | Standard Security、NEG_FAILURE、未知协议 |
| `E-RDP-TARGET-TLS` | 隧道内目标 TLS | 目标 TLS handshake 失败 |
| `E-RDP-TARGET-CERT` | 目标证书 | 目标 pin/hostname/root 不符合策略 |
| `E-RDP-BASTION-UNSUPPORTED` | 非标准堡垒机 | 厂商 HTTPS/Azure Bastion 未实现 |

安全不变量：

- Gateway route 没有完整双阶段结果时，连接路由必须返回错误；
- 任何证书 callback 拒绝、证书变化、hostname mismatch 或 trust record 缺失
  都不能被 `cert:ignore` 或“继续连接”绕过；
- 只验证 Gateway 证书不等于验证目标 RDP；只验证目标证书也不等于验证
  Gateway；
- 预检的 TLS 证书采集可以为展示而读取 peer certificate，但正式放行前必须
  经过 CA/name/pin 和用户 trust policy。不得以 `SSL_VERIFY_NONE` 作为最终
  信任结论；
- 隧道内目标证书的真实来源必须可审计。若只能从直连目标获取，结果必须标记
  `incomplete` 并阻断 Gateway 连接；
- 日志禁止记录密码、NTLM hash、Cookie、Authorization header、完整 token
  和未经脱敏的 host/user；
- 取消、超时、进程异常和重复连接都要释放 Gateway TLS、隧道、目标 TLS 和
  preflight session 资源。

## 8. 测试计划

### 8.1 纯逻辑和 native 单元测试

- route classifier：直连、透明 TCP、Microsoft RD Gateway、vendor HTTPS、
  Azure Bastion、unknown 的分类和默认值；
- endpoint identity：目标或 Gateway 任一字段变化都会使旧结果失效；
- direct negotiation：保留现有 TLS selection、碎片、Standard Security、
  negotiation failure、malformed frame、unknown protocol 六类回归；
- Gateway 首包：TLS ClientHello/SNI 正确，Gateway 入口绝不收到 RDP X.224；
- Gateway certificate：不同 Gateway host、端口、SNI 和证书的展示/校验；
- tunneled target certificate：目标证书只从隧道阶段产生；客户端无目标直连
  权限时仍可验证通过隧道得到的目标证书；
- callback flag mapping：带 `VERIFY_CERT_FLAG_GATEWAY` 只匹配 Gateway pin，
  不带 flag 只匹配 target pin；未知 flag 组合拒绝；
- pin matrix：两张都匹配、仅 Gateway 匹配、仅目标匹配、都不匹配，以及
  Gateway rotation/target rotation；
- CA/root/hostname：两个阶段分别覆盖受信任、未受信、名称不匹配、过期和
  无证书；
- tunnel methods：`http`、`rpc`、WebSocket、`no-websockets` 的成功、服务端
  不支持、错误状态码、截断响应和超时；`auto` 可能尝试 WebSocket、HTTP、RPC，
  HTTP 还可能发生 WebSocket upgrade 或回退，测试不得把请求策略猜成最终分支；
  没有可观测证据时结果必须是 `requested=<mode>, negotiated=unknown`；
- auth boundary：Gateway 证书成功但认证缺失时返回 `GATEWAY-AUTH`，不返回
  `ok=true`；
- fallback negative tests：TLS、cert、negotiation、tunnel、unknown/vendor/
  Azure 失败均不得调用正式连接路由；
- cleanup/retry/cancel：每个失败点释放 fd/TLS/session，重试不复用旧证书或
 旧 generation。

### 8.2 ArkTS/API 测试

- 预检请求包含 Gateway route 时，NAPI 收到完整 Gateway 参数；
- direct 调用仍只走 direct compatibility wrapper；Gateway 不得落到旧三参
  probe；
- 双证书结果在 Sheet 中同时可见，两个 trust decision 独立持久化；
- Gateway 仅部分完成、认证等待、失败、取消、超时和 stale result 的状态
  转换；
- host/gateway/transport 切换后，旧结果、旧 pin 和旧 UI 不可继续放行；
- 旧 host 数据迁移：直连目标 pin 保持，Gateway pin 为空并要求重新预检；
- 失败路径不调用 `doRdpCertificateRoute`，除非满足受限的 direct-only
  fallback 条件；
- 错误码和阶段文案映射稳定，禁止显示不准确的“RDP TLS handshake failed”。

### 8.3 真实 endpoint 验收矩阵

至少准备以下环境；缺少任一环境时记录为 evidence gap，不得用 mock 结果替代：

| 环境 | 必验内容 |
| --- | --- |
| 直连 Windows RDP | P0 regression、目标 SNI、目标 pin、证书轮换 |
| Microsoft RD Gateway + Windows RDP | Gateway TLS/SNI、Gateway pin、HTTP/RPC/WebSocket 方法、隧道内目标 pin |
| 自签名 Gateway + 受信目标 | 两张证书独立确认；只接受对应阶段的明确 trust |
| 受信 Gateway + 自签名目标 | Gateway 自动通过/已 pin，目标单独提示和 pin |
| Gateway 证书轮换 | 只阻断 Gateway，不清除目标 pin |
| 目标证书轮换 | 只阻断目标，不清除 Gateway pin |
| Gateway 可达但目标不可达 | 返回 target/tunnel 阶段错误，不显示 Gateway TLS 失败 |
| 443 上的普通 HTTPS/厂商堡垒机 | 返回 unsupported/vendor 错误，不发送 RDP X.224 |
| Azure Bastion | 明确 unsupported 或进入独立适配计划，不宣称 RD Gateway 通过 |

真实验收需要保存脱敏的：endpoint 配置摘要、FreeRDP 版本、Gateway method、
两个阶段的 SNI、阶段 code、握手耗时、证书指纹审计值和最终连接结果。禁止
保存认证凭据及隧道会话 token。

## 9. 交付顺序和分支闭环

按项目分支门禁执行，计划本身不改变当前活动 SSH 任务分支的代码范围：

1. 先完成阶段 A 的 endpoint 样本和 FreeRDP 版本/API 核对；
2. 在同一 RDP 任务分支先提交 endpoint/result contract 和纯逻辑测试；
3. 接入 FreeRDP Gateway-aware preflight，并先通过 mock/recording tests；
4. 接入双证书 trust storage、回调和 ArkTS Sheet；
5. 运行 native 定向测试、ArkTS 测试和真实 endpoint 矩阵；
6. 通过独立复核，确认没有绕过证书校验、跨阶段 pin 或错误 fallback；
7. 执行强制 Hvigor gates、assembleHap、`git diff --check` 和发布合规检查；
8. 先以受控 feature flag 灰度，Gateway route 默认要求新预检能力；
9. 完成真实 endpoint 验收后才扩大 Gateway 支持范围。

建议的 feature flag 行为：

- `direct_rdp` 默认继续可用；
- `microsoft_rd_gateway` 在 Gateway-aware preflight 未启用或不完整时直接
  返回“需要 Gateway-aware 证书预检”，不能落回旧直连 probe；
- `vendor_https_bastion`、`azure_bastion` 在没有专用适配器时直接返回
  `E-RDP-BASTION-UNSUPPORTED`；
- flag 关闭时允许保留诊断日志和 mock tests，但不允许真实 Gateway 连接绕过
  新的双阶段信任门禁。

## 10. 回滚方案

回滚以“保留安全拒绝”为原则：

- 如果 Gateway-aware 实现出现回归，回滚到仅支持 direct/transparent TCP 的
  稳定版本；所有 Gateway 配置继续 fail closed，不恢复旧的错误直连预检；
- 旧目标 pin 数据保留，新增 Gateway trust record 可被忽略但不能覆盖目标
  record；重新启用功能时要求按 route identity 重新核验；
- 如果只有 UI 或存储迁移出问题，关闭 Gateway 功能旗标并保留证书数据，禁止
  通过 UI 自动确认或清空 pin；
- 回滚验证必须至少覆盖 direct P0、Gateway 入口“不发送 RDP X.224”、未知
  vendor/Azure 拒绝、以及 `cert:ignore` 静态检查；
- 发布说明明确列出“直连可用、Gateway 暂停、厂商/Azure 不支持”，不能把
  回滚版本描述成支持所有堡垒机。

## 11. 发布门禁和完成定义

代码实现阶段的最低门禁：

- native 定向 RDP/Gateway tests 全部通过；
- ArkTS/NAPI 双证书请求、结果、迁移和 stale generation tests 通过；
- 现有 RDP P0 regression 通过；
- 实际 Microsoft RD Gateway endpoint 至少通过一组双证书环境和一组证书
  轮换环境；
- vendor HTTPS 和 Azure Bastion 未实现时均能清晰 fail closed；
- 日志审查通过，未出现密码、hash、Cookie、token 和未脱敏 endpoint；
- `git diff --check` 通过；
- 按项目门禁执行并记录以下两项，任何一项失败都不能宣称完成：

```sh
source scripts/macos_env.sh
hvigorw --mode module -p module=entry -p product=default default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon
hvigorw --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --no-daemon
```

完成定义（Definition of Done）：

1. 直连预检和真实直连共用目标 endpoint/name/trust policy；
2. Gateway 预检和真实连接共用 Gateway endpoint/transport/target route；
3. Gateway 和目标证书分别取得、显示、确认、持久化和回调校验；
4. 四种双 pin 组合以及两种证书轮换场景均符合预期；
5. Gateway 失败不会被转成直连 RDP TLS 失败，也不会自动 fallback；
6. 没有真实 Microsoft RD Gateway 证据前，只能交付为“代码/测试完成，真实
   endpoint 待验收”，不能写成堡垒机问题已解决。

## 12. 待补信息和明确 blocker

- 用户反馈的“堡垒机”具体是 Microsoft RD Gateway、RDS Broker、厂商 HTTPS
  堡垒机还是 Azure Bastion；
- Gateway hostname、端口、transport method（HTTP/RPC/WebSocket）和是否
  需要 Gateway 认证；
- 目标 RDP hostname 与证书名称是否一致，是否存在自签名、内部 CA 或证书
  轮换策略；
- 项目当前 FreeRDP 版本是否导出计划使用的 Gateway accepted-cert 字段、
  `VERIFY_CERT_FLAG_GATEWAY` 和 Gateway preflight 生命周期控制点；
- 可用于验收的真实 Gateway/目标主机、测试账号和可撤销证书；
- HarmonyOS 设备/HDC 是否在线，以完成端到端日志和 UI 验收；
- Azure Bastion 和厂商堡垒机若被列为必须支持对象，需要另立协议适配计划，
  不能由本计划的 RD Gateway 实现覆盖。

本计划只解决“先把 endpoint 和证书阶段做对”的修复路线；在上述真实 endpoint
和 FreeRDP 版本核对完成前，不允许把任何 Gateway TLS handshake workaround
写成最终修复。

## 13. 当前执行记录（2026-08-06）

本轮已完成的代码检查点：

- CloudStore/RDB schema、云表本地字段白名单、备份和设备信任清理已覆盖目标
  与 Gateway 双证书及 route identity 字段；
- 预检入口按 endpoint mode 选择 direct 或 Gateway-aware 路径，Microsoft RD
  Gateway 继续要求 Gateway/目标双证书；vendor HTTPS、Azure Bastion 和未知
  Gateway 保持 fail closed；
- 证书 trust、正式连接参数、one-time handoff 和 resolver fallback 均要求
  route identity 与当前完整路由一致；旧的空 route identity 不再放行正式连接；
- Restricted Admin 的 NTLM hash 只允许进入目标 RDP 的认证配置；预检请求携带
  `targetRestrictedAdmin`，route resolver 对 `Restricted Admin + Microsoft RD
  Gateway` 返回 `E-RDP-GATEWAY-AUTH`，不会把 hash 当作 Gateway 密码；
- 新增 stale route 的 ArkTS policy 测试，并将 Gateway route policy 纳入 native
  测试目标。

当前验证：

- `git diff --check`：通过；
- `default@OhosTestCompileArkTS`：通过；
- `assembleHap`：`BUILD SUCCESSFUL`；
- 重建后的 `rdp_native_tests`：Gateway 6 个策略用例通过；最新全量为
  `294 passed, 16 failed, 310 total`，16 个失败为既有 VNC TLS fixture 启动失败；
- `ohosTest@OhosTestCompileArkTS`：当前工程任务未注册，错误 `00306054`；
- 未获得真实 Microsoft RD Gateway、证书轮换或 HarmonyOS 设备端到端证据，不能
  宣称堡垒机互操作验收完成。

## 14. 继续执行记录（2026-08-07）

- RDP-only 的 ArkTS compile checkpoint 仍有效；此前对保留 SSH 混合改动的完整
  工作树复跑曾在 `entry/src/main/ets/pages/SshTerminal.ets:780` 报
  `10905209 Only UI component syntax can be written here`，该诊断不属于 RDP
  变更且本轮没有修改 SSH 文件。
- 2026-08-07 对当前工作树重新执行的 `default@OhosTestCompileArkTS` 返回 0，
  仅有已有警告；同轮 `assembleHap` 为 `BUILD SUCCESSFUL`。两项门禁当前通过，
  但这不等同于真实 RD Gateway 互操作已验收。
- 同一轮重建后的 `rdp_native_tests` 最新结果为 `294 passed, 16 failed,
  310 total`；16 个失败仍全部是既有 VNC TLS fixture 启动失败，RDP Gateway
  policy、RDP negotiation 和 RDP certificate 相关用例通过。
- RDP Gateway UI 已将 Gateway 证书卡片的入口显示绑定到真实
  `gatewayHost:gatewayPort`；本轮不再扩大代码范围或提交混合文件。

## 15. Restricted Admin 与 RD Gateway 边界（2026-08-06）

当前明确决策：

- `direct_rdp`/`transparent_tcp_rdp + Restricted Admin` 继续使用本机加密存储的
  NTLM hash，现有目标 RDP 认证路径不受本次 Gateway 规则影响；
- `microsoft_rd_gateway + Restricted Admin` 当前不宣称支持，并在预检和正式
  route resolver 两侧返回 `E-RDP-GATEWAY-AUTH`。原因是 FreeRDP 的
  `FreeRDP_PasswordHash` 是目标 RDP/CredSSP 的 target secret，而 Gateway
  认证使用 `FreeRDP_GatewayPassword`；NTLM hash 不能安全地填入 Gateway
  password。当前模型也没有独立的 Gateway 明文密码来源；
- 不通过把 hash 传进 Gateway、不把 hash 当普通密码重试、也不通过关闭证书校验
  或 fallback 绕过该拒绝。

若产品必须支持该组合，后续应另立凭据扩展：

1. 增加独立且本机加密的 Gateway username/domain/password 绑定，禁止进入
   RemoteHost、云同步和日志；目标 NTLM hash 仍单独保存并只在目标阶段使用；
2. 将 Gateway credential binding、target auth mode 和 request generation 纳入
   预检/正式连接契约，认证上下文变化时不得复用旧结果；
3. 分别向 `FreeRDP_Gateway*` 和目标 `FreeRDP_*` 设置真实凭据，补充 Gateway
   认证成功、认证失败、hash 清理和取消路径测试；
4. 在真实 Gateway + Restricted Admin 端点上完成双阶段证书、认证和证书轮换
   验收后，才移除该 fail-closed 限制。

## 16. 继续执行记录（2026-08-07：一次性信任与 transport 证据边界）

### 16.1 `CONTINUE_ONCE` 的安全语义

当前代码检查点已收紧一次性继续路径：

- `HostListPage.ets` 对原主机记录创建深拷贝后继续路由；不会把本次探测得到的
  目标/Gateway 指纹、trust mode、trustedAt、route identity 或证书 metadata
  写回主机持久化记录；
- 本次连接仍可通过 `oneTimeResult` 携带临时的目标和 Gateway 双证书 pin，且
  正式连接前再次校验 live route identity；一次性决定只对当前连接有效；
- 纯逻辑测试已将语义明确为
  `continue_once_should_leave_persisted_certificate_record_unchanged`，并继续
  要求 `shouldPersistRdpCertificateTrust(CONTINUE_ONCE) == false`；
- Gateway 场景如果缺少任一阶段证书、route identity 不一致或结果过期，不能以
  `CONTINUE_ONCE` 绕过，必须停留在失败/重新探测状态。

后续实现和复核必须补充对象级断言：一次性继续前后的目标与 Gateway trust
record 完全相同；正式连接收到的两个 one-time fingerprint 只存在于本次请求，
取消、超时、失败和连接结束后不可写入持久化、备份、云同步或日志。

### 16.2 Gateway transport 的当前证据边界

已核对项目 vendored FreeRDP 3.26.1：

- `freerdp/libfreerdp/core/transport.c:608-672` 表明 `auto` 可能按实现路径
  尝试 WebSocket、HTTP 或 RPC；
- `freerdp/libfreerdp/core/gateway/rdg.c:1508-1550` 表明 HTTP 路径还可能经历
  WebSocket upgrade 或回退；
- 当前公开适配 API 没有可靠的“最终 transport 分支”结果，因此现有
  `gatewayTransportSelected` 不能作为协商事实。

计划中的验收记录必须拆成：

1. `requested`：用户/配置传给 FreeRDP 的 transport policy；
2. `negotiated`：只有通过 wire trace、FreeRDP instrumentation 或明确的
   recording/mock 观察到的最终分支；
3. `unknown`：没有上述证据时的诚实值，不能用 `auto`、`http` 或代码分支推断
   代替。

因此当前只能宣称 Gateway-aware route policy 和双阶段证书回调的代码/测试
检查点通过；不能宣称 HTTP、RPC、WebSocket 或 `no-websockets` 的真实互操作，
也不能宣称 `auto` 的最终选择已被客户端可靠观测。

### 16.3 当前交付状态

- 本节没有新增代码修改；记录的是当前工作树既有代码检查点和后续执行边界。
- 较早的代码 checkpoint 曾记录 host native suite 为 `294 passed, 16 failed,
  310 total`；该记录中的 16 个失败是既有 VNC TLS fixture 启动失败，不能覆盖
  当前后续验证结果。
- 当前 HEAD 为 `7892f0332`，RDP 相关文件仍与活动 SSH/渲染改动混合未提交，不能
  把该 HEAD 视为 RDP 独立提交。
- 之前一次完整工作树验证中 `default@OhosTestCompileArkTS` 和 `assembleHap` 均通过；
  本次继续执行后 `default@OhosTestCompileArkTS` 仍通过，但最新
  `assembleHap` 被混合 SSH 改动的 native 编译错误阻断，不能用上一轮成功结果
  替代当前门禁；`git diff --check` 仍通过。
- 真实 Microsoft RD Gateway、证书轮换、HTTP/RPC/WebSocket/no-websockets、
  Restricted Admin Gateway 凭据和 HarmonyOS 设备端到端验收仍是 blocker；
  `E-RDP-GATEWAY-AUTH` 的 fail-closed 边界保持不变。

## 17. 最终执行记录（2026-08-07：当前代码检查点和收尾边界）

### 17.1 已落地的修复面

- 当前项目锁定的 vendored FreeRDP 版本为 `3.26.1-dev0`。Microsoft RD Gateway
  route 不再调用旧的三参数直连 probe，而是把目标、Gateway、SNI、transport
  policy、凭据和双 pin 作为完整请求送入 Gateway-aware FreeRDP preflight；直连
  和透明 TCP 仍走 direct probe。
- Gateway 与目标证书分别由 `VERIFY_CERT_FLAG_GATEWAY` 映射到独立记录和独立
  pin。正式连接再次按同一阶段规则校验；Gateway、vendor HTTPS、Azure Bastion
  和未知 route 不允许通过关闭证书校验或旧 resolver fallback 放行。
- `CONTINUE_ONCE` 只把当前结果的双证书 pin 作为一次性路由参数传递，不写回主机
  的目标/Gateway trust record、备份、云同步或日志；`TRUST` 才分别更新对应的
  trust record。
- 新增 Gateway/目标双 pin 组合测试：双 pin 匹配、仅 Gateway 匹配、仅目标匹配、
  两者都不匹配、Gateway 证书轮换、目标证书轮换。新增 transport observation
  contract 测试要求 Gateway TLS、目标 TLS、目标来自隧道，且 Gateway 入口不能
  收到 RDP X.224。
- 预检 FreeRDP session 现在显式复用正式连接的 TLS/NLA-only 安全组合：关闭
  Standard RDP Security、RDSTLS、Ext/AAD 和 Restricted Admin fallback，固定
  `RequestedProtocols=SSL|HYBRID`；预检不会因为 FreeRDP 默认值而接受正式连接
  会拒绝的安全降级。
- 证书 callback 收到无法解析的 PEM 时不再发布 `present=true` 的空指纹记录；对应
  Gateway 或目标阶段标记 metadata invalid 并 fail closed，刷新路径也不能持久化
  空 pin。

### 17.2 transport 事实边界

- `gatewayTransportRequested` 是配置/调用方请求的 policy；保留的
  `gatewayTransportSelected` 只是兼容别名，同样表示 requested policy。
- `gatewayTransportNegotiated` 只有在 wire trace、FreeRDP instrumentation 或
  可观测 recording/mock 明确记录最终分支时才允许填写 `http`、`rpc` 或
  `websocket`；当前生产适配层没有可靠的最终分支回调，因此无真实观测时固定为
  `unknown`。不能因为请求了 `auto`、代码设置了某个 flag，或 FreeRDP 具备某个
  分支，就把它写成实际协商结果。
- 本轮不向 vendored FreeRDP 增加 instrumentation。若产品或诊断要求展示真实
  transport，下一轮应单独增加最小、脱敏、可关闭的 observer，并用互操作端点和
  wire evidence 验证；observer 不得改变证书校验或 fallback 行为。

### 17.3 取消、超时和资源释放事实

- ArkTS Sheet 关闭、重试、切换主机和路由变化会递增 preflight generation；迟到
  的 Promise 结果在 native 调用前后都会被丢弃，不得更新 UI、trust record 或
  路由。
- 当前 NAPI 暴露的是不可取消的 async worker，没有对 FreeRDP worker 的物理
  cancel API。Gateway preflight 设置 `FreeRDP_TcpConnectTimeout=15000`，所以
  UI 取消后的 native 连接可能继续到返回或超时，但最长连接阶段受该上限约束。
- FreeRDP preflight 返回后会移除实例到 callback-state 的映射、清空证书回调指针；
  若防御性地返回 connected，则先 disconnect，再释放 context 和 instance。预检
  不把 live session 或 socket 交给正式连接复用。
- 真实设备仍需验证取消、超时、重复重试、网络切换和进程退出期间没有遗留 fd、
  TLS、Gateway tunnel、敏感凭据或一次性 pin。若该验证发现 15 秒收敛不可接受，
  另立 cooperative cancellation 变更，不通过 UI generation 把“忽略结果”冒充
  “已中断网络操作”。

### 17.4 最新自动化验证和未完成项

- Host `rdp_native_tests` 编译：通过；生产 HAP native 编译的最新完整门禁被
  非 RDP 的 SSH `extension_loader_napi.cpp` 错误阻断。
- Host native suite：`301 passed, 16 failed, 317 total`；16 个失败均为既有
  VNC TLS fixture 启动失败，RDP Gateway/证书/negotiation 相关用例（含新增
  malformed-stage-record 断言）通过。
- `default@OhosTestCompileArkTS`：通过。
- `assembleHap`：当前工作树最新复跑返回 `BUILD SUCCESSFUL`。此前一次尝试曾因
  混合 SSH 改动的 native 编译错误失败，随后基于当前文件状态重试通过；另一次
  首次打包遇到 BundleTool 的瞬时资源条目大小错误，立即重试通过，未改动产品资源。
- `git diff --check`：通过。
- `ohosTest@OhosTestCompileArkTS`：当前工程未注册，错误 `00306054`；不能写成
  测试通过。
- 仍未完成：真实 Microsoft RD Gateway 的 Gateway/目标双证书、证书轮换、
  HTTP/RPC/WebSocket/no-websockets 互操作、不同 Gateway 凭据绑定、取消/超时
  设备证据，以及 Azure Bastion/厂商 HTTPS 的专用协议支持。

### 17.5 推荐交付顺序

1. 先用真实 Microsoft RD Gateway + Windows RDP 端点验收 `requested`、两阶段
   SNI、Gateway/target 双 pin 和错误阶段；保存脱敏日志和 wire evidence。
2. 分别验收 Gateway 证书轮换、目标证书轮换、自签名/内部 CA、Gateway 可达但
   目标不可达、认证缺失和网络切换；每个失败都保持 fail closed。
3. 验收 `http`、`rpc`、`websocket`、`no-websockets` 和 `auto`。`auto` 必须用
   抓包或 instrumentation 记录最终分支，否则结果继续显示 `negotiated=unknown`。
4. 在 HarmonyOS 真机验证 Sheet 取消、重试、主机/Gateway 切换、后台/进程退出和
   一次性信任清理；确认没有跨阶段 pin 或敏感凭据落盘。
5. 通过独立复核后，先将 Gateway route 以 feature flag 灰度；在 RDP 相关改动
   从混合工作树中独立 checkpoint、完成强制 Hvigor gates 和合规审查后，再合并
   到 `main`。在此之前对外表述应为“直连修复可用，Gateway 代码检查点通过，
   真实堡垒机互操作待验收”。

### 17.6 2026-08-07 继续执行记录

- 本次修复前工作树为活动分支 `codex/ssh-terminal-complete-upgrade`，HEAD
  `7892f0332`，相对 `main@d2769ad4b` 为 ahead 114、behind 0；RDP 文件与
  既有 SSH/渲染修改仍混合未提交，未进行 reset、stash、切换分支或覆盖其他改动。
- 在 `freerdp_adapter.cpp` 中补齐 Gateway preflight 的显式 TLS/NLA-only 设置，
  并让 malformed PEM 在证书记录发布前失败；新增的 Gateway policy 回归断言已
  随 host native binary 编译并通过。
- 本次 host native 全量结果为 `301 passed, 16 failed, 317 total`。失败仍全部是
  `vnc_certificate_probe_test.cpp` 的既有 TLS fixture 启动失败，不属于本次 RDP
  改动；RDP Gateway policy、证书 pin、证书阶段、negotiation 相关用例通过。
- 本次重新执行的门禁结果为：`default@OhosTestCompileArkTS` 通过，
  `assembleHap` 在失败尝试后的立即重试返回 `BUILD SUCCESSFUL`，
  `git diff --check` 通过。构建输出仍有既有 ArkTS/deprecation/resource warning，
  未将 warning 写成错误或忽略。整包编译门禁当前通过，但这不等同于真实
  Microsoft RD Gateway 互操作已验收。
- `ohosTest@OhosTestCompileArkTS` 仍未注册（`00306054`）；没有真实 Microsoft
  RD Gateway、证书轮换、transport wire/recording、Restricted Admin Gateway
  凭据或 HarmonyOS 真机端到端证据。因此当前交付等级仍是“直连代码/测试修复和
  Gateway-aware 代码检查点完成，真实堡垒机互操作待验收”，不是“堡垒机问题已
  在生产环境解决”。

### 17.7 2026-08-08 提交前证书复核

- 提交前复核发现并修复两处会造成证书预检误判的问题：FreeRDP X.509 回调给出的
  叶子证书和中间证书链现在会一起交给 `X509_STORE_CTX`；直连 TLS probe 也使用
  `SSL_get_peer_cert_chain`，不再只验证叶子证书。
- 目标或 Gateway server name 为 IPv4/IPv6 字面量时改用
  `X509_check_ip_asc`；DNS 名继续使用 `X509_check_host`，避免合法 IP SAN 被误报
  为 hostname mismatch。
- `RdpCertificateRecord.flags` 只保留应用层证书风险位，不再与 FreeRDP callback
  flags 直接 OR；这避免 `VERIFY_CERT_FLAG_LEGACY=0x02` 与应用层
  `hostMismatch=0x02` 发生命名空间冲突。
- 新增原生回归覆盖 IP SAN/DNS SAN 分流，以及“缺少 intermediate 验证失败、完整
  intermediate PEM chain 验证成功”。重建后 host native suite 为
  `314 passed, 16 failed, 330 total`；新增用例和全部 RDP 用例通过，16 个失败仍是
  既有 VNC TLS fixture 启动失败。
- 提交前重新执行 `default@OhosTestCompileArkTS` 返回 0；`assembleHap` 首次在
  BundleTool 打包阶段遇到既有的 SVG zip entry 瞬时大小错误，生产 native 编译已
  成功，随后原样重跑返回 `BUILD SUCCESSFUL`。`git diff --check` 和 staged scope
  检查仍须在 checkpoint commit 前完成。
- 真实 Microsoft RD Gateway、证书轮换、transport wire evidence 和 HarmonyOS
  设备端到端证据仍未完成，因此提交只能标记为代码/测试 checkpoint。

### 17.8 2026-08-08 最终提交门禁

- 最终复核发现 Gateway route 新字段若直接加入固定云表列集合，会要求线上云表
  同步升级 schema。现已改为复用既有 `displayconfig` 扩展载荷持久化
  `rdpendpointmode`、`rdpgatewaytransport` 和 `rdpgatewayservername`，固定云表
  schema 不变；同时保留旧直读兼容并新增云扩展 round-trip 测试。
- `RemoteHostDeviceTrustPolicy` 已补齐目标与 Gateway 证书的 `notBefore/notAfter`
  字段，避免设备信任复制、备份或恢复时遗漏证书有效期元数据；本地备份安全扩展
  allowlist 和对应测试同步补齐。
- 最新 host native suite 为 `316 passed, 16 failed, 332 total`。全部 RDP
  Gateway、证书链、IP SAN、pin 和 negotiation 用例通过；16 个失败仍全部来自
  `vnc_certificate_probe_test.cpp` 的既有 TLS fixture `fixture.start()` 失败。
- 最新完整工作树门禁：`default@OhosTestCompileArkTS` 返回 0，`assembleHap`
  返回 `BUILD SUCCESSFUL`，`git diff --check` 与 `git diff --cached --check` 均
  通过。输出中的 ArkTS、deprecated API 和第三方依赖 warning 未被当作错误隐藏。
- 对“仅暂存 RDP 补丁”的隔离快照也完成原生编译与测试：`302 passed, 16 failed,
  318 total`，RDP 用例通过。该快照的 ArkTS 编译会被当前 HEAD 上已经存在但尚未
  成套提交的 SSH 类型依赖阻断；完整当前工作树的两项强制 Hvigor 门禁均已通过，
  本次不会为绕过该基线问题夹带 SSH 改动。
- 暂存范围仅包含 RDP Gateway/证书预检、持久化兼容、相关测试和本计划。共享文件
  中的 SSH、RustDesk、渲染、光标、焦点和输入改动保持未暂存，不进入本次提交。
- 交付结论保持为“RDP 代码复核和自动化门禁完成，真实 Microsoft RD Gateway
  互操作待外部环境验收”；不能将本次代码 checkpoint 表述为生产堡垒机问题已经
  完全解决。

### 17.9 2026-08-08 独立复核后的安全收敛

- 独立复核发现首次遇到自签名、名称不匹配或已轮换的 Gateway 证书时，原先的
  Gateway-aware preflight 会为了取得目标证书而临时接受 Gateway 证书，随后可能
  在用户确认前进入带凭据的 HTTP/RPC 认证。现改为两阶段：先建立不发送
  HTTP/RPC/WebSocket/RDP X.224 且不携带凭据的纯 TLS 连接，只取得 Gateway
  证书；只有系统 CA+SAN 校验通过，或当前路由已有匹配 Gateway pin，才允许进入
  FreeRDP Gateway 隧道。
- 用户首次确认私有 CA/自签名 Gateway 时，`CONTINUE_ONCE` 只在当前 Sheet 生命周期
  保存临时 Gateway pin，`TRUST` 只先保存 Gateway trust record；随后重新预检并
  取得目标证书。第二条 FreeRDP Gateway TLS 连接还会被临时绑定到第一次无凭据
  检查到的指纹，若两次连接间证书变化，会在发送 Gateway 凭据前 fail closed。
- 正式连接不再只依赖 `VERIFY_CERT_FLAG_MISMATCH`。启用
  `ExternalCertificateManagement` 后，PEM 回调路径会直接从叶子证书重新执行
  DNS/IP SAN 校验；PEM 缺失或无法解析时按 Gateway/target 阶段拒绝。
- `gatewayProtocolEvidenceIsComplete` 现在要求 negotiated transport 明确为
  `http`、`rpc` 或 `websocket`；`unknown` 不再被误认为完整 wire evidence。
- 已信任且 route identity 未变化的主机现在把 route-bound 结果传给 Sheet 策略，
  不再每次打开证书 Sheet 并产生额外 160ms 可见等待。该变化只影响连接前预检，
  没有修改帧回调、解码、Surface、渲染、光标、输入或连接后事件循环。
- Gateway-only 与最终双证书 `TRUST` 都检查 `updateHost()` 的持久化结果；保存失败
  时保留 Sheet、显示 `E-RDP-CERT-PERSIST` 并停止第二阶段或正式连接，不能把未落盘
  的 pin 当作已信任状态继续使用。
- 最新 host native suite 为 `317 passed, 16 failed, 333 total`；新增 Gateway
  credential gate、transport unknown 反例、PEM SAN 重算测试及全部 RDP 用例通过，
  16 个失败仍为既有 VNC TLS fixture `fixture.start()` 失败。
- 最新 `default@OhosTestCompileArkTS` 返回 0。`assembleHap` 首次完整 native 编译
  后在 `SignHap` 遇到一次工具侧 `00308018`，保持文件不变立即重跑返回
  `BUILD SUCCESSFUL`；native 编译、ArkTS 编译、打包和签名最终门禁均通过。
- 当前产品配置只表达一组 RDP/Gateway 共用凭据，尚未实现“Gateway 账号与目标
  Windows 账号不同”的独立凭据契约。该部署类型仍需单独设计安全存储、UI、NAPI
  与 FreeRDP 字段映射；本提交不把它写成已支持，也不将其失败误报为证书成功。
