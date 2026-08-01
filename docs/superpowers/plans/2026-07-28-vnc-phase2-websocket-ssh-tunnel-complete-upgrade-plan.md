# VNC 二阶段升级计划：WebSocket Gateway 与 SSH 隧道完整实现

> 日期：2026-07-28（Asia/Shanghai）
> 代码基线：main，8528ce539
> 目标平台：HarmonyOS API 23，entry / default
> 文档状态：计划已落盘，尚未实施
> 本轮约束：只制定计划，不修改 entry、native、Rust、测试或配置代码

## 0. 结论先行

当前代码把 websocket_gateway 和 ssh_tunnel 正确地保持在 fail-closed 状态。这不是“少打开一个开关”，而是两条尚未完成的端到端传输链路：

1. WebSocket Gateway 需要一个已部署、带版本、认证、目标选择、TLS、限流、关闭和重连语义的服务端，同时需要客户端把 RFB 字节流正确承载在 WebSocket 消息中。
2. SSH 隧道需要独立的 SSH session、主机密钥验证、认证、direct-tcpip channel、非阻塞字节泵和生命周期管理；现有 SSH 终端的 PTY/Shell adapter 不能直接充当隧道。
3. 两条链路都要接入现有 VNC RFB 引擎的统一有序字节流接口，不能分别复制一套 RFB 连接逻辑，也不能通过失败后自动退回直连来伪装兼容。
4. VNC 的配置、网关令牌和 VNC TLS 信任仍归 VNC owner；SSH 隧道使用 SSH 凭据和主机密钥能力时，只允许通过窄接口引用 SSH owner，不能复制、修改或接管 SSH 终端/SFTP 数据。
5. 云端继续只有一张物理表 vncrecord。新增的是版本化 payload 和引用关系，不是 vncgateways、vncsecrets 或其他物理表。

本阶段的完成定义是：在真实网关、真实 SSH 服务端和真实 VNC 服务端上建立 RFB 连接，完成首帧、输入、剪贴板（按主机策略）、断开、取消、重连和异常诊断，并通过单设备、多设备、云同步、加密、API 23 真机和既有 RDP/RustDesk/SSH 回归验收。仅完成 UI、保存配置或 native 单元测试均不算完成。

## 1. 当前基线与已确认问题

### 1.1 代码现状

| 位置 | 当前行为 | 二阶段必须解决的问题 |
| --- | --- | --- |
| entry/src/main/ets/services/VncGatewayProtocolPolicy.ets | WebSocket 返回 E-VNC-GATEWAY-CONTRACT-DRAFT；SSH 隧道返回 E-VNC-SSH-TUNNEL-CONTRACT | 将草案 gate 改为“版本协商 + 服务端能力 + 凭据/信任/目标均满足”后的真实报告 |
| entry/src/main/cpp/vnc/vnc_transport_policy.h | native 只允许 direct_tcp 和 ultravnc_repeater | native allowlist 必须继续 fail-closed，直到对应 contract fixture 和互操作证据通过 |
| entry/src/main/cpp/vnc/vnc_transport.h/.cpp | 已有 TCP/TLS、部分 WebSocket Upgrade、frame 读写和 Repeater pairing；但 connect() 先被 allowlist 拒绝 | 补齐 RFC 6455 解析、认证 header、子协议、应用 envelope、分片、控制帧、背压和关闭；不能直接复用当前草案代码作为完成证明 |
| docs/VNC_GATEWAY_PROTOCOL.md | 已有服务端契约草案；当前 JSON/二进制消息 envelope 仍不够明确，状态明确为 draft | 在二阶段 A 固定为可测试的 v1 wire contract，并保留兼容/拒绝规则 |
| entry/src/main/ets/pages/RemoteDesktop.ets | 能读取 VNC gateway endpoint、TLS、Repeater target；没有把 gateway token 取出并传到 ConnectionConfig | 建立短生命周期 token 投影，确保 token 只进入当前连接，不进入日志、普通 payload 或 UI 摘要 |
| entry/src/main/cpp/extensions/protocol_adapter.h、extension_loader_napi.cpp | 有 vncTransport、gateway host/port/path、Repeater 字段；没有 gateway token、协议版本、SSH tunnel profile/ref | 增加显式、最小化、可擦除的连接参数；更新 ArkTS/N-API/native 三层契约和校验 |
| entry/src/main/ets/services/VncModelPolicy.ets | transport union 已包含 websocket_gateway、ssh_tunnel，但 gateway model 只有通用 endpoint、path、targetId、TLS | 以 schema v2 增加 WebSocket contract 和 SSH direct-tcpip 需要的非敏感引用/策略字段 |
| entry/src/main/ets/services/VncGatewayService.ets | 网关 token 已由 VNC secret owner 管理；不支持的 transport 会强制 enabled=false | 支持 token/信任/能力状态的完整投影；缺 token、缺引用或版本不匹配时仍必须不可连接 |
| entry/src/main/cpp/ssh/ssh_adapter.h/.cpp | 面向终端：PTY、Shell、exec、subsystem、SFTP、keepalive；没有 direct-tcpip、本地 forward channel 或 tunnel session | 新增独立 SshTunnelSession/transport；禁止复用终端 singleton、PTY channel 或其关闭状态 |
| entry/src/main/cpp/test/vnc_transport_policy_test.cpp | 明确断言 WebSocket、public relay、SSH tunnel 当前拒绝；mode2 也拒绝 | 先扩展协议/错误/边界测试，再在所有 enablement gate 通过后修改断言 |
| VNC cloud/model/service | 只有 vncrecord，逻辑类型为 settings、host、gateway、secret、trust；新设备 cloud-first barrier 已存在 | 保持表和 bootstrap barrier；处理 gateway metadata、令牌、TLS trust、SSH 引用的多行一致性和缺失依赖 |

### 1.2 当前可用与不可用边界

当前可用的 VNC transport 仍只有：

- direct_tcp
- UltraVNC Repeater viewer mode12

当前明确不可用且本阶段不自动放开的能力：

- WebSocket Gateway
- public relay
- SSH tunnel
- UltraVNC Repeater mode2
- reverse/listen 形式的 SSH forwarding

mode2 是 Repeater 的服务端监听角色，不是 HarmonyOS viewer 的另一种连接模式；本阶段不会把它混入 WebSocket 或 SSH tunnel 的实现范围。

## 2. 范围、非目标与隔离规则

### 2.1 本阶段范围

#### WebSocket Gateway

- 固定 remotedesk-vnc-v1 子协议。
- 支持 wss://host/path；ws:// 只能在用户明确选择可信局域网策略时使用。
- 支持带 token 的 gateway authentication、目标绑定、过期、并发限制和服务端 ACL。
- 支持把已协商的 RFB byte stream 作为 WebSocket binary application message 传输。
- 支持 TLS hostname verification、可选 SHA-256 pin、心跳、背压、取消、正常关闭和可诊断重连。
- 提供独立服务端实现或可审计的部署包；仅修改移动端不能使 WebSocket Gateway 具备可用服务端。

#### SSH 隧道

- 本阶段只实现本地 viewer 到 SSH server 的 direct-tcpip。
- SSH server 再连接 VNC target；target host/port 的语义明确为 SSH server 侧可达地址。
- 每个 VNC 连接使用独立 SSH session 和独立 direct-tcpip channel。
- 支持现有 SSH owner 已具备且通过 API 23 验证的认证/代理能力；不复制 SSH 私钥或口令到 VNC 记录。
- 支持 host-key trust、连接取消、channel close、读写背压、keepalive 和故障分类。

### 2.2 非目标

- 不把 VNC 记录写入 remotehosts、rustdeskrelays 或 usersettings。
- 不让 RustDesk service 管理 VNC Gateway，也不让 SSH terminal service 管理 VNC tunnel CRUD。
- 不实现 SSH tcpip-forward、远端 listener、reverse tunnel 或任意端口反向暴露。
- 不在手机 App 内运行公网 VNC relay server；Gateway server 是独立部署单元。
- 不实现 public relay 的另一个未定义协议；它继续单独 fail-closed。
- 不启用 WebSocket per-message compression、任意文本帧 RFB、URL query token 或无 ACL 的任意目标转发。
- 不通过“Gateway 不通则直连”“SSH 不通则 Repeater”等隐式 fallback 改变用户配置。
- 不把暂未实现的 mTLS、ProxyJump/Bastion、SSH agent、FIDO2、远端转发包装成已支持。

### 2.3 隔离与依赖边界

| 能力 | owner | 允许依赖 | 禁止行为 |
| --- | --- | --- | --- |
| VNC host/gateway/settings | VNC services + vncrecord | VNC crypto、VNC trust、统一 VNC transport broker | 复用 RDP/RustDesk 配置；将 VNC Gateway 写入 RustDesk relay 表 |
| WebSocket token | VNC recordtype=secret，secretkind=gateway_token | DataCrypto/HUKS 的现有安全路径 | 放入 gateway payload、URL、日志、备份明文或 ConnectionConfig 长期对象 |
| SSH tunnel endpoint | VNC gateway/host payload 中的非敏感引用和策略 | 窄的 SSH credential/trust provider | 直接调用 SSH terminal singleton、共享 PTY channel、修改 SSH 主机记录 |
| SSH authentication/private key | 现有 SSH owner/KeyVault | SSH 认证和 host-key API | 复制私钥/口令到 vncrecord；由 VNC UI 绕过 SSH trust |
| WebSocket TLS trust | VNC trust owner，绑定 VNC gateway/host endpoint | VNC trust confirmation | 云恢复 fingerprint 后自动信任新设备 |
| SSH host key trust | SSH owner / 数据安全入口 | 现有 SSH trust policy | 在 VNC secret 中复制 fingerprint，绕过 SSH 数据安全确认 |
| RFB engine | VNC native engine | VncByteStream | 为每个 transport 复制 RFB handshake/encoding/input 代码 |

## 3. 研究依据与采用结论

实施阶段必须继续以一手规范、官方文档和上游源码为准，不从二手博客复制协议代码。

### 3.1 WebSocket

- [RFC 6455 — The WebSocket Protocol](https://www.rfc-editor.org/rfc/rfc6455)：定义 HTTP Upgrade、Sec-WebSocket-Accept、子协议、binary/text frame、client masking、fragmentation、Ping/Pong、Close 和安全限制。
- [noVNC](https://github.com/novnc/noVNC)：证明标准 VNC 客户端可以通过 WebSocket 接收 RFB，并展示 VNC 端的协议边界、编码和浏览器/移动端交互；不直接把其前端代码移入 HarmonyOS native。
- [websockify](https://github.com/novnc/websockify)：是 WebSocket-to-TCP bridge 的直接参考，适合验证“WebSocket binary payload 与原始 RFB TCP 字节流互通”；它本身不提供本项目所需的 account binding、target ACL、VNC Gateway v1 hello 或云端租约，因此不能当作生产 Gateway contract 的全部。

采用结论：客户端和服务端都必须先完成 RFC 6455 conformance，再完成项目自有的 versioned application envelope；不能把一次 HTTP 101 成功当作 RFB Gateway 已实现。

### 3.2 SSH forwarding

- [RFC 4254 — The Secure Shell (SSH) Connection Protocol](https://datatracker.ietf.org/doc/rfc4254/) 第 7 节定义 tcpip-forward 和 direct-tcpip；本阶段只采用 direct-tcpip。
- [libssh2 direct_tcpip example](https://libssh2.org/examples/direct_tcpip.html)：提供 libssh2_channel_direct_tcpip_ex 的官方示例路径。
- [libssh2 channel open API](https://libssh2.org/libssh2_channel_open_ex.html)：作为 channel type、非阻塞状态和错误处理的 API 依据。
- [libssh2 upstream](https://github.com/libssh2/libssh2)：当前项目 native SSH 依赖的上游实现和许可证来源；其公开许可证、版本、补丁和 ABI 必须进入项目 provenance/SBOM/NOTICE 审查。
- [OpenSSH portable](https://github.com/openssh/openssh-portable)：用于对照 AllowTcpForwarding、PermitOpen、host key、认证拒绝和 forwarding 错误语义；不直接复制实现。

采用结论：VNC tunnel 不是打开 SSH Shell 后把 VNC 字节写进终端，而是一个无 PTY 的 SSH connection channel。服务端拒绝 forwarding、目标不可达或 host key 不匹配都必须被准确显示，不能降级成普通 SSH 终端。

### 3.3 HarmonyOS API 23

- [HarmonyOS Socket connection 官方指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/socket-connection)：用于 socket 生命周期、网络异常、连接/关闭和平台能力核对。
- [HarmonyOS native WebSocket guidelines](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/native-websocket-guidelines)：用于 native WebSocket 生命周期、线程与网络边界核对；如果最终继续使用 native C++ framing，也必须按该指南验证平台生命周期，而不是假设 Linux socket 语义永远成立。
- [HarmonyOS Node-API thread safety](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/use-napi-thread-safety)：用于 worker 到 ArkTS 的线程安全事件通知和销毁顺序。
- 本地 API 23 declarations 已核对；任何新的 ArkTS/Kit API 必须先在本机 API 23 declaration 和 default@OhosTestCompileArkTS 中确认，不能照搬更高 API 示例。

采用结论：VNC RFB 和 WebSocket/SSH 字节泵继续以 native stream owner 为主，ArkTS 只管理配置、状态和事件；不新增一条绕过现有 native RFB engine 的 ArkTS WebSocket 实现。若 API 23 的官方 WebSocket API 不能提供所需 binary backpressure，则保留 native C++ stream，并补齐 RFC 6455 测试和平台 lifecycle 适配。

## 4. 目标架构

~~~mermaid
flowchart LR
  UI["VNC Host / Gateway UI"] --> VNC["VNC owner projection"]
  VNC --> CAP["Capability + trust + secret gate"]
  CAP --> BROKER["VNC transport broker"]
  BROKER --> TCP["Direct TCP / Repeater"]
  BROKER --> WS["WebSocket byte stream"]
  BROKER --> SSH["SSH direct-tcpip byte stream"]
  TCP --> RFB["One RFB engine"]
  WS --> RFB
  SSH --> RFB
  RFB --> UI
  WS --> GW["Separate VNC Gateway service"]
  GW --> TARGET1["RFB target / ACL"]
  SSH --> SSHCORE["Dedicated libssh2 tunnel session"]
  SSHCORE --> SSHOWNER["SSH credential + host-key provider"]
  SSHCORE --> TARGET2["SSH-server-side VNC target"]
  CLOUD["vncrecord + AES-GCM v2"] --> VNC
  CLOUD --> CAP
~~~

### 4.1 统一字节流接口

二阶段首先要抽象出 transport 不可见的 VncByteStream 语义（名称可按现有 C++ 风格调整）：

- connect(parameters, cancellation, deadline)：返回 transport、协议版本、TLS/trust、peer/session 摘要。
- readExact(buffer, size, deadline)：维护 partial read，不因 timeout retry 丢失已读字节。
- writeAll(buffer, size, deadline)：有界写队列和可观察 backpressure。
- close(reason)：幂等、可取消，确保 worker、channel、socket、TLS 和 TSFN 的顺序释放。
- capabilities()：返回协议版本、最大 payload、heartbeat、是否支持 clipboard 等，不返回 secret。

RFB engine 只依赖上述有序字节流；它不读取 Gateway token、SSH key、WebSocket frame 或 SSH packet。每个 VNC connection 必须有一个串行 transport owner，不能让 UI、RFB worker、WebSocket reader 和 SSH reader 同时驱动同一个 session。

### 4.2 统一状态机

~~~text
Created
  -> Resolving
  -> Connecting
  -> TransportHandshake
  -> TrustVerification
  -> Authenticating
  -> TargetBinding
  -> Ready
  -> RfbHandshake
  -> Streaming

任意状态 -> Cancelling -> Closed
任意状态 -> Failed(code, retryable, userAction)
Streaming -> Reconnecting -> Resolving（仅在用户策略允许时）
~~~

状态只能由 native session owner 串行推进；ArkTS 只能发送 connect/cancel/retry 请求。回调必须携带 connectionId + generation，旧页面、surface recreation 或失败重连产生的事件不能污染新连接。

## 5. WebSocket Gateway v1 完整契约

当前 docs/VNC_GATEWAY_PROTOCOL.md 是 draft；二阶段 A 必须把它冻结为可测试的 v1。下面的 wire contract 是计划中的目标，不代表本轮已部署。

### 5.1 endpoint、TLS 与 HTTP Upgrade

生产 endpoint：

~~~text
wss://<gateway-host>:<port>/<path>
~~~

客户端 Upgrade 必须包含：

~~~http
GET /<path> HTTP/1.1
Host: <gateway-host>:<port>
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Version: 13
Sec-WebSocket-Key: <random-16-byte-base64>
Sec-WebSocket-Protocol: remotedesk-vnc-v1
Authorization: Bearer <gateway-token>
~~~

规则：

- token 绝不放在 URL query、path、Sec-WebSocket-Protocol、close reason、普通日志或诊断文本中。
- 若部署配置为匿名 LAN Gateway，必须在 gateway policy 中明确标记 authMode=none；客户端仍不能把缺 token 的远端 WSS 当成匿名成功。
- 默认只接受 wss。ws 仅在 VNC trusted_network 策略、用户明确确认、endpoint 归类为可信局域网并通过 API 23 网络上下文验证时可用。
- TLS 必须完成 hostname verification；可选 pin 绑定到 VNC trust record。云恢复的 fingerprint 只是候选值，新设备第一次使用必须本地确认。
- 不协商 permessage-deflate；v1 不接受未知 extension/reserved bits。
- 服务端若不接受 v1 子协议，应返回 426 或稳定的 HTTP error；客户端不改用无子协议的 raw WebSocket。

服务端 101 响应至少包含：

~~~http
HTTP/1.1 101 Switching Protocols
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Protocol: remotedesk-vnc-v1
~~~

### 5.2 application envelope

RFC 6455 的 WebSocket message 边界不等于 RFB 消息边界，因此 v1 使用明确的二进制 application envelope。每个 binary WebSocket message 必须是一个完整 envelope；RFC 6455 层允许 fragmented frames，客户端必须先重组为完整 WebSocket message 再解析。

~~~text
offset  size  meaning
0       1     kind
1       4     payloadLength，unsigned big-endian
5       N     payload
~~~

payloadLength 必须等于 message 剩余长度，最大值由双方在 hello ack 中协商且不能超过客户端硬上限。kind 固定为：

| kind | 名称 | 允许时机 | payload |
| ---: | --- | --- | --- |
| 0x01 | gateway_hello | Upgrade 后的第一条 application message | UTF-8 JSON |
| 0x02 | gateway_hello_ack | 服务端响应第一条 hello | UTF-8 JSON |
| 0x10 | rfb_data | status=ready 后 | 不透明 RFB bytes，不得改写 |
| 0x7f | gateway_close | 任意阶段的可选最终诊断 | UTF-8 JSON，不含 secret/RFB |

不要再使用“二进制消息里有时是 JSON、有时是 raw RFB、但没有 envelope”的草案行为。文本 WebSocket frame 在 v1 一律拒绝；未知 kind、长度溢出、未定义顺序、reserved bit 或控制帧超长都属于 protocol error。

### 5.3 hello 与 target binding

第一条 0x01 payload：

~~~json
{
  "type": "gateway_hello",
  "version": 1,
  "client": "remotedesk-harmonyos",
  "requestId": "opaque-client-request-id",
  "targetId": "opaque-target-reference",
  "capabilities": ["rfb-byte-stream", "ws-ping-pong"]
}
~~~

约束：

- requestId 只用于诊断，不包含账号、token、密码、地址或 RFB 内容。
- targetId 来自主机 owner 的目标引用；它不是密码，不代替 server-side ACL。
- server 必须把 bearer token 的 account/scope 与 targetId 绑定，并校验目标是否允许被该账号访问。
- 目标选择失败、目标忙、租约过期、token 无效必须返回稳定状态，不能静默接入另一个目标。
- 客户端在收到 ready 以前绝不发送 rfb_data。

第一条 0x02 payload：

~~~json
{
  "type": "gateway_hello_ack",
  "version": 1,
  "requestId": "same-opaque-client-request-id",
  "status": "ready",
  "sessionId": "opaque-server-session-id",
  "idleTimeoutMs": 60000,
  "heartbeatIntervalMs": 20000,
  "maxPayloadBytes": 1048576
}
~~~

status 允许值：ready、auth_required、unauthorized、expired、target_not_found、target_busy、unsupported_version、rejected。非 ready 状态必须立即进入可诊断失败路径，不得尝试 RFB。

### 5.4 RFB 数据、控制帧与关闭

- 0x10 的 payload 是 RFB byte stream；客户端按收到顺序串联，不把一个 WebSocket message 当作一个 RFB message。
- 客户端到服务端的 WebSocket data frame 必须按 RFC 6455 masking 规则 mask；服务端到客户端不 mask。
- Ping/Pong 使用 RFC 6455 control frame 完成 heartbeat；控制帧可以穿插在 fragmented data message 中，不能被 RFB parser 当作数据。
- Ping payload 最大 125 bytes；超限控制帧直接 protocol error。
- v1 不使用 application-level ping/pong JSON，避免与 RFB 字节和 WebSocket control frame 形成三套心跳语义。
- Close 使用 RFC 6455 close handshake；gateway_close 只用于需要携带稳定业务 code 的场景，随后仍必须关闭 WebSocket。
- 客户端、服务端都要设置 logical message 上限、累计接收上限、发送队列上限和 idle deadline。达到上限时关闭 backpressure_limit，不能无限申请内存。

建议稳定的业务 close code：

~~~text
normal
unauthorized
expired
target_not_found
target_busy
protocol_version
tls_required
backpressure_limit
idle_timeout
server_shutdown
internal_error
~~~

这些 code 进入 VNC diagnostics，但不带 token、RFB payload、私钥、SSH endpoint secret 或完整 server trace。

### 5.5 Gateway server 必须提供的能力

移动端之外，必须交付一个独立 Gateway service 或等价可审计部署：

1. TLS termination 和证书轮换。
2. bearer token 校验、过期、撤销、scope 和并发 session 限制。
3. account/target ACL；target registry 不能允许任意公网地址作为 SSRF 目标。
4. 与后端 RFB target 建立 TCP/TLS 连接并做纯字节桥接，不解析或记录 framebuffer、密码和 clipboard。
5. bounded receive/send queue、连接空闲超时、单连接带宽/累计字节限制和取消。
6. target offline、busy、auth failure、server shutdown 的稳定错误映射。
7. 无 token/target/RFB 内容的审计指标：连接数、握手结果、错误 code、延迟、字节计数和版本。
8. 能够在不升级客户端的前提下拒绝未知版本，并在 v1 期间保持 backward-compatible contract。

websockify 可以用作互操作 bridge 原型或测试 fixture，但它的“WebSocket 到 TCP”能力不能替代本项目的认证、目标 ACL、租约、版本和审计层。若部署或改造它，必须完成 LGPL-3.0 合规；noVNC 的 MPL 2.0 代码同样不能未经 license review 直接拷贝进 HarmonyOS native。

## 6. SSH 隧道完整实现方案

### 6.1 传输拓扑

~~~text
VNC RFB engine
  -> VncSshTunnelStream (client device)
  -> libssh2 SSH session
  -> SSH_MSG_CHANNEL_OPEN("direct-tcpip")
  -> SSH server connects to targetHost:targetPort
  -> VNC RFB server
~~~

targetHost 和 targetPort 是 SSH server 侧可达的目标。依据 RFC 4254，direct-tcpip channel carries the host/port requested by the client；本阶段不申请 tcpip-forward，不在设备上打开监听端口，也不在 SSH server 上创建远端 listener。

### 6.2 独立 session/channel

- 每个 VNC connection 创建一个独立 SSH session；不能把终端页面已有 session 借给 VNC。
- 不请求 PTY，不启动 Shell，不发送终端 escape，不混入 stdout/stderr/exit code。
- SSH handshake、host-key verify、authentication、direct-tcpip open、byte pump 和 close 由该 tunnel session 的单一 I/O worker 驱动。
- 使用 libssh2 非阻塞模式；处理 LIBSSH2_ERROR_EAGAIN 时等待正确的 socket direction，保留 partial read/write，不忙等。
- SSH channel window、VNC RFB read/write queue 和 native callback queue 都必须有上限；上游变慢时暂停读取或关闭并报告 backpressure。
- VNC close、用户 cancel、页面销毁、网络变化、SSH server close 都必须沿同一个 close state machine 释放 channel、session、TLS/socket、线程和临时密钥。

### 6.3 认证与主机密钥

- UI 选择一个既有 SSH host/credential profile 的稳定 ID；VNC 只保存 opaque reference 和 tunnel policy。
- SSH 密码、私钥、私钥口令和 agent 材料仍由 SSH owner/KeyVault 提供，不能复制到 vncrecord 的 payload 或 VNC secret。
- SSH host key fingerprint 继续由 SSH 的数据安全/known-host trust 入口管理；VNC tunnel 只能调用“检查/请求确认”的窄接口。
- 新设备从云端恢复 SSH profile 或 fingerprint 时，若本机没有对应 trust confirmation，必须再次确认；绝不自动信任。
- 认证方法、代理方式和密钥是否可用必须在 connect gate 中一次性报告；缺少本地 key、SSH profile 或解锁状态时显示不可用，不 fallback 到 VNC password/direct TCP。
- 首期允许 password/public-key 以及当前 SSH 模块已经通过回归的 proxy path；keyboard-interactive、ProxyJump/Bastion、agent/FIDO2 等没有真实交互和测试前仍显示为后续能力。

### 6.4 forwarding 权限和错误

SSH server 必须允许对应用户使用 TCP forwarding，并可通过 OpenSSH 的 AllowTcpForwarding、PermitOpen 或等价策略限制目标。客户端必须把以下结果区分开：

| 失败 | 用户可见诊断 |
| --- | --- |
| SSH host key 不匹配 | 阻止连接，显示指纹变化并提供数据安全入口 |
| SSH 认证失败/取消 | 认证失败或用户取消，不重试无效凭据 |
| server 禁止 forwarding | E-VNC-SSH-FORWARD-DENIED，提示服务端 forwarding policy |
| target DNS/连接拒绝 | E-VNC-SSH-TARGET-UNREACHABLE，说明解析/连接发生在 SSH server 侧 |
| channel 打开超时 | E-VNC-SSH-DIRECT-TCPIP-TIMEOUT |
| channel 被关闭/EOF | E-VNC-SSH-CHANNEL-CLOSED，可按用户策略重连 |
| backpressure/本地取消 | E-VNC-SSH-CANCELLED 或 E-VNC-SSH-BACKPRESSURE |

任何上述失败都不能悄悄开 Shell、把 VNC 字节写入 PTY，或改为直连。

## 7. 云同步、schema 和加密设计

### 7.1 物理云表不变

用户只部署一张 Huawei 云表：vncrecord。二阶段不增加物理表。字段保持：

~~~text
id
userid
recordtype
ownerid
ownertype
secretkind
payload
ciphertext
envelopeversion
cryptoversion
keyversion
aadversion
payloadhashsha256
syncversion
schemaversion
resetepoch
createdat
updatedat
deletedat
~~~

逻辑 recordtype 仍为：

~~~text
settings | host | gateway | secret | trust
~~~

禁止新增 vnchosts、vncgateways、vncsecrets、vncsettings、vnctrusts 等物理表。普通云同步选择器显示物理表名 vncrecord；VNC 设置页继续按逻辑 scope 管理偏好、主机、Gateway、secret、trust。

### 7.2 schema v2 payload

二阶段采用 VNC payload schema v2；现有 v1 direct TCP/Repeater 行必须可读，迁移不能删除或重置。新增字段仅进入同一行的 JSON payload，且未知 transport/version 继续 fail-closed。

#### gateway payload 的公共字段

~~~json
{
  "label": "...",
  "transport": "websocket_gateway | ssh_tunnel | ultravnc_repeater",
  "host": "gateway-or-ssh-host",
  "port": 443,
  "path": "/vnc",
  "protocolVersion": "remotedesk-vnc-v1",
  "repeaterMode": "mode12",
  "targetId": "legacy-repeater-target-or-empty",
  "tls": true,
  "enabled": false,
  "connectTimeoutMs": 10000,
  "handshakeTimeoutMs": 10000,
  "idleTimeoutMs": 60000,
  "heartbeatIntervalMs": 20000,
  "maxPayloadBytes": 1048576
}
~~~

#### SSH tunnel 的附加非敏感字段

~~~json
{
  "sshProfileId": "opaque-existing-ssh-owner-id",
  "forwardMode": "direct_tcpip",
  "knownHostPolicy": "ssh-owner-trust",
  "targetResolution": "ssh-server-side"
}
~~~

VNC host row 的 host/port 在 WebSocket transport 中表示 Gateway hello 的 target reference/target metadata；在 SSH tunnel 中表示 SSH server 侧要连接的 VNC target。UI 必须按 transport 解释并明确标注，不能把 Gateway endpoint 和 VNC target 互换。

#### secret row

- WebSocket bearer token：ownerType=gateway、secretKind=gateway_token。
- Repeater token（如果某部署需要）：继续使用现有 VNC secret kind，但不能与 WebSocket token 混用。
- SSH private key、password、passphrase：不复制到 vncrecord；保存为 SSH owner/KeyVault 的引用和现有 SSH sync policy。
- VNC secret 默认不同步；只有用户勾选 VNC secrets、DataCrypto ready、密钥 envelope 正确且明确确认时才允许云同步。

#### trust row

- WebSocket TLS trust 可由 VNC host/gateway 关联的 trust row 保存 fingerprint、endpoint digest、trust domain 和确认时间。
- SSH host key trust 继续由 SSH owner 管理，VNC row 只保存 opaque sshProfileId，不复制 fingerprint。
- 云恢复的任何 trust 记录都只是候选状态；新设备必须重新确认，不能以 confirmed=true 直接跳过本地确认。

### 7.3 AES-GCM 和 AAD

继续使用现有 VNC AES-GCM v2 envelope，不为了新增 transport 另造一套加密格式。每一条 secret 的 AAD 必须绑定至少：

~~~text
physicalTable=vncrecord
recordId
recordType=secret
ownerId
secretKind
field=gateway-token-or-vnc-secret
schemaVersion
cryptoVersion
keyVersion
aadVersion
resetEpoch
~~~

要求：

- token 只在 connect attempt 的短生命周期内解密；连接成功后也不得存进长期 ConnectionConfig 或日志。
- token、私钥、口令、RFB password 不进入普通备份、诊断、Relay 卡片、cloud payload、URL 或错误 message。
- resetepoch、DEK/KEK 版本、ciphertext、payload hash 和 schema 必须按现有 VNC validator 检查；任何不匹配都 fail-closed。
- trust fingerprint 是校验材料，不是 secret；仍不能自动信任新设备。

### 7.4 多行一致性和新设备保护

一个可连接的 WebSocket Gateway 可能依赖 gateway、secret、host、trust 四类行；SSH tunnel 还依赖 SSH owner/profile 和 SSH trust。云同步必须把它们当作有依赖关系的投影，而不是看到一行就立即启用：

1. cloud-first barrier 完成前，不允许本地默认设置、空 token、空 SSH ref 或空 trust 覆盖云端。
2. gateway metadata 先恢复也只能显示“等待依赖/不可连接”；不得上传一条本地空 secret 把云端 token 删除。
3. secret row 到达后必须重新验证 owner、secretKind、AAD、reset epoch 和 ciphertext；无法解密就保持 unavailable。
4. SSH profile/credential 不在本设备时，VNC tunnel 显示缺失依赖；不能自动创建一个空 SSH profile。
5. scope 取消不产生反向 cloud tombstone；用户明确删除才写普通 tombstone。
6. gateway 配置、secret 行和 trust 行的 save/delete 使用本地 mutation journal 或等价的可恢复顺序；中途失败后要恢复旧 payload 或保持 disabled，而不是留下“enabled=true 但没 token”的假连接。
7. 冲突按稳定 id + syncVersion + updatedAt 合并，不能按本地空数组覆盖云端集合；删除 tombstone 保留到服务端确认并遵守现有 reset epoch 规则。

## 8. UI 与用户操作流程

### 8.1 中继第三页

- 继续将 RustDesk relay 与 VNC Gateway 共列在第三页。
- 不增加“VNC/RustDesk 切换”或目录过滤；卡片使用类似首页 Pro 对象卡的协议标签明确显示 RustDesk 中继或 VNC Gateway。
- RustDesk 卡片的添加、编辑、删除、测试路径保持原有 service/表/表单，不能因为 VNC 二阶段改动。
- VNC Gateway 卡片显示 endpoint、transport、TLS、协议版本、enabled/availability、token configured（仅状态，不显示 token）和不可用原因。
- Relay FAB 仍是添加动作选择器：选择 RustDesk 进入原 RustDesk 流程，选择 VNC 进入 VNC Gateway owner-isolated 流程；不是目录筛选器。
- 编辑/删除/测试按 kind 分派到各自 owner；聚合目录只读展示，不拥有云数据。

### 8.2 VNC Gateway 添加/编辑

采用现有 bindSheet 和其他协议的自适应弹窗规律：文字步骤标题（例如 1/3），不使用圆圈套圆圈的进度条；内容不足时 FIT_CONTENT，内容超出窗口时由父 sheet 自适应拉伸，避免固定高度和嵌套滚动造成空白或看不见字段。

#### 第一步：传输与 endpoint

- 传输类型：WebSocket Gateway / SSH 隧道 / 已有 Repeater mode12。
- WebSocket：Gateway host、port、path、协议版本只读显示为 remotedesk-vnc-v1。
- SSH：选择 SSH profile；显示 SSH server host/port 和“VNC target 在 SSH server 侧可达”的说明。
- 只显示当前 transport 需要的字段；不把 token、私钥、PTY/Shell 选项放在基础表单。
- 未找到 SSH profile 时提供去 SSH 设置/数据安全的入口，不能允许保存为可连接状态。

#### 第二步：认证、TLS 与 trust

- WebSocket token 输入为密码控件；说明 token 只存入 VNC secret owner，保存前必须 crypto ready。
- WebSocket TLS、secure_only/trusted_network 说明、TLS fingerprint trust 管理入口。
- SSH 显示 SSH host-key trust 状态，跳转现有 SSH 数据安全入口；不复制 SSH fingerprint。
- 认证/forwarding/target 依赖未满足时显示明确 unavailable 原因，而不是只显示“保存成功”。

#### 第三步：确认

显示连接类型、非敏感 endpoint、target 角色、协议版本、TLS/trust、依赖状态和 enabled 状态；绝不显示 token、密码、私钥、完整指纹或 RFB 内容。提供“保存”和“保存并连接”，后者在 sheet onDisappear 后再路由到 RemoteDesktop，避免生命周期竞态。

### 8.3 VNC Host 添加

保留其他协议的分步人因模式，四步建议为：

1. 连接目标：名称、VNC target host/port、transport 和已保存 Gateway。
2. 认证与连接安全：VNC password、WebSocket token 只显示“已配置”状态、TLS/trust；SSH profile 依赖只读展示。
3. 显示与交互：只读默认开启、缩放、clipboard 默认关闭；高级 timeout 由 VNC 设置叶子管理。
4. 确认：展示 transport-specific endpoint 解释、不可用依赖和最终操作。

WebSocket 的 host targetId 和 SSH 的 server-side target host 需要分别用用户能理解的标签表达；不能沿用一个“服务器地址”字段让用户误以为两者都在本地直连。

### 8.4 设置页

VNC 仍是协议设置组中 SSH 之后的独立栏。二阶段只在 VNC 自己的 bindSheet leaf 中新增：

- WebSocket Gateway 协议、heartbeat、frame limit 和重连策略。
- SSH tunnel 默认 profile、target resolution 说明和转发安全策略。
- Gateway token/trust/cloud scope 状态入口。

不把 token、SSH key、host fingerprint 放进普通设置 payload 或其他协议设置；不改变 RDP/RustDesk/SSH 原有设置卡片布局。
## 9. 分阶段实施路径

### Phase 2A：契约冻结与数据/能力底座

目标：不连接真实 WebSocket/SSH tunnel，但把所有边界写成可执行契约。

任务：

1. 将 docs/VNC_GATEWAY_PROTOCOL.md 从 draft 修订为 v1 contract：固定 subprotocol、application envelope、hello/ack、auth、target、heartbeat、limits、close codes 和错误映射。
2. 为 SSH direct-tcpip 写独立 contract：profile reference、target host/port 语义、host-key owner、forwarding policy、channel lifecycle 和 no-listener boundary。
3. 定义 schema v2 JSON 字段、v1 migration、unknown field/value、secret/trust owner 和云依赖状态。
4. 定义 ArkTS capability report：unsupported、configured_unavailable、ready、connecting、degraded、failed；把 server contract version 与本地 native capability 分开报告。
5. 定义错误 code 表、redaction 规则、connection generation、metrics 和诊断字段。
6. 定义 server reference implementation 的独立 repository/deployment owner、license、TLS 证书、token issuer、target registry 和测试 VNC endpoint。

门禁：contract review 通过、schema review 通过、云表仍只有 vncrecord、现有 gates 仍拒绝两种 transport；没有服务端和 fixture 不得进入 2B 的 enablement。

### Phase 2B：统一 native stream 与 WebSocket client

任务：

1. 把 VncTransport 的共同 read/write/close 语义提炼为有序 byte stream，保持现有 direct TCP/Repeater 行为不变。
2. 修订 WebSocket handshake：校验 101、Upgrade、Connection、version、subprotocol、accept；添加 Authorization 的短生命周期注入；拒绝 query token、错误 host/path 和未知 extension。
3. 实现 application envelope 编解码、fragment reassembly、binary kind 顺序、最大 payload、masked/unmasked 规则、Ping/Pong、Close 和 backpressure。
4. 所有 parser 使用 bounded buffer；所有 timeout retry 保留 partial bytes；所有错误带稳定 code，不把服务端 header/token 打入日志。
5. 通过 N-API 传递 token 和 gateway contract 参数时使用显式类型、一次性拥有权和清零路径；不把 secret 放入持久 session/config。
6. 将 ConnectionConfig/N-API 类型扩展为版本化字段，native 和 ArkTS 双重拒绝未知/不完整的 WebSocket 配置。
7. 在仍关闭 native allowlist 的情况下先完成 unit/fuzz/fixture 测试，避免测试通过后 UI 提前可用。

门禁：RFC 6455 frame fixture、协议错误 fixture、TLS pin mismatch、token redaction、RFB byte preservation、内存上限、cancel/close、direct/repeater 回归全部通过。

### Phase 2C：独立 WebSocket Gateway 服务端

任务：

1. 交付最小生产服务：WSS listener、v1 subprotocol、hello/ack、bearer auth、account/target ACL、target connector、纯字节桥、heartbeat、limits、close codes、metrics。
2. 目标注册必须使用显式 ID/ACL；禁止客户端给任意公网 host/port，防止 SSRF 和未经授权的内网扫描。
3. 以真实 LibVNCServer/TigerVNC/UltraVNC 兼容 endpoint 做互操作；用 websockify/noVNC 做 bridge 参照，不把不兼容 license 的代码复制进 app。
4. 提供本地 fixture server、TLS test certificate、expired token、busy target、slow target、fragmented message、server shutdown 和 backpressure 场景。
5. 提供可审计 deployment artifact、配置样例、secret rotation、日志 redaction、健康检查和 rollback 说明；生产 endpoint 不在移动端仓库写死。

门禁：独立 server 通过安全 review、license/provenance review、fixture suite 和至少一个真实 VNC server 互操作；没有这一步客户端继续显示“服务端契约未部署”。

### Phase 2D：ArkTS VNC owner、云同步和 WebSocket UI 接通

任务：

1. 将 gateway schema v2 解析/保存/迁移接入 VncModelPolicy、VncGatewayService、VncHostService 和 VncRecordPolicy。
2. 增加短生命周期 tokenFor 投影、缺 token/crypto locked/expired 的 capability 状态；不改变 secret 默认不同步策略。
3. 为 VNC TLS trust 增加 endpoint/domain 绑定和新设备重新确认；不改变 SSH host-key trust owner。
4. RemoteDesktop 只投影已授权的 VNC transport 参数到 native；建立 connection generation 和 stale callback 防护。
5. 更新 Gateway/Host add flow 和第三页卡片状态，使 WebSocket 只有在“本地能力、contract version、endpoint、TLS/trust、token、target、cloud/crypto”全部 ready 时可保存为 enabled/可连接。
6. 开关采用 feature flag + server contract version 双门；开关关闭时已有配置保留但不可连接，不删除云记录。

门禁：ArkTS compile、assembleHap、VNC cloud row validator、secret/trust tests、真实 WSS + VNC 首帧/输入/clipboard/断开/reconnect 通过；RDP/RustDesk/SSH 回归无变化。

### Phase 2E：独立 SSH direct-tcpip tunnel

任务：

1. 新增独立 VncSshTunnelStream 或等价 native adapter，明确不复用 SshAdapter 的 PTY/Shell channel。
2. 在已完成 SSH handshake/auth/host-key verify 的 session 上调用 libssh2 direct-tcpip API；支持 nonblocking/EAGAIN、deadline、channel window 和 cancellation。
3. 实现双向 bounded byte pump：VNC -> SSH channel、SSH channel -> VNC，处理 partial read/write、half-close、EOF、socket error、remote refusal 和 close reason。
4. 通过窄接口读取 SSH profile credential/trust；没有 profile/key/host-key confirmation 时在 connect gate 阶段失败，不能落入普通 SSH terminal。
5. 支持当前已验证的 direct SSH endpoint 和必要的既有 proxy path；ProxyJump/Bastion 只有在独立 session chaining、host-key 链和真实 fixture 完成后才开放。
6. 将 SSH tunnel status/errors 投影到 VNC UI，但不让 VNC 页面编辑 SSH host fingerprint；失败动作跳转到 SSH 设置/数据安全 owner。
7. 仅实现 direct_tcpip；显式拒绝 tcpip-forward、reverse/listen 和任意本地监听。

门禁：OpenSSH server/Dropbear 或等价 fixture 允许/拒绝 forwarding 的双向测试、host-key mismatch、key/password auth、EAGAIN、slow target、target refusal、cancel、断线重连和真实 RFB 互操作全部通过。

### Phase 2F：综合验收与发布

任务：

1. API 23 手机、平板、PC 做 endpoint/Sheet/后台前台/网络切换/屏幕旋转/重复 connect-disconnect smoke。
2. 两台设备同一账号验证 vncrecord cloud-first、空本地不覆盖云端、metadata/secret/trust 到达顺序、scope deselect、删除 tombstone、crypto reset epoch 和缺 SSH dependency。
3. 对 direct TCP、Repeater mode12、WebSocket Gateway、SSH tunnel 各做真实 VNC 首帧、输入、clipboard 策略、只读、缩放、取消、重连。
4. 运行 RDP、RustDesk、SSH terminal/SFTP 的已有关键回归；任何 VNC capability/云同步错误不能中断其他 owner。
5. 完成安全、license、SBOM/NOTICE/provenance、性能/内存/backpressure、release build 和回滚演练。
## 10. 文件级实施清单

以下是后续实现时的建议改动边界；本轮不创建或修改这些代码文件。

### 10.1 ArkTS / model / cloud

- entry/src/main/ets/services/VncGatewayProtocolPolicy.ets：版本协商、capability report、错误 code、feature gate。
- entry/src/main/ets/services/VncModelPolicy.ets：schema v2 transport-specific model、严格校验、非敏感引用。
- entry/src/main/ets/services/VncRecordPolicy.ets：schema v1 -> v2 migration、trust domain、secret kind 和跨 owner dependency validation。
- entry/src/main/ets/services/VncGatewayService.ets：Gateway v2 保存、enabled gate、token/依赖投影、mutation rollback。
- entry/src/main/ets/services/VncHostService.ets：target role、gateway binding、host/tunnel projection。
- entry/src/main/ets/services/VncSecretService.ets、VncCloudSyncService.ets、CloudStore.ets：secret scope、cloud-first、row dependency、AAD/epoch 和冲突行为。
- entry/src/main/ets/pages/RemoteDesktop.ets：短生命周期连接参数和 generation；不得在页面 state 留存 secret。
- entry/src/main/ets/types/rdpnapi.d.ts：显式 N-API config/result 类型。

### 10.2 Native VNC / N-API

- entry/src/main/cpp/vnc/vnc_transport_policy.h：在所有 gate 通过后才放行对应 transport。
- entry/src/main/cpp/vnc/vnc_transport.h/.cpp：统一 byte stream、WebSocket contract、TLS/trust、queue、close。
- 建议新增 entry/src/main/cpp/vnc/vnc_websocket_contract.h/.cpp：envelope/handshake/frame parser，便于独立测试。
- 建议新增 entry/src/main/cpp/vnc/vnc_ssh_tunnel.h/.cpp：libssh2 direct-tcpip session/channel 和 byte pump。
- entry/src/main/cpp/vnc/vnc_rfb_engine.cpp：只接入 stream/capability，不复制 WebSocket/SSH 语义。
- entry/src/main/cpp/extensions/protocol_adapter.h、extension_loader_napi.cpp：增加版本化、最小参数和 secret 清零边界。
- entry/src/main/cpp/ssh/ssh_adapter.*：仅在能抽出安全、无行为变化的 credential/trust provider 时调整；禁止把 VNC tunnel 逻辑写入终端 Shell 路径。

### 10.3 UI

- entry/src/main/ets/components/resourceadd/VncGatewayAddFlow.ets：conditional WebSocket/SSH 字段、token/trust 状态和依赖提示。
- entry/src/main/ets/components/hostadd/VncAddFlow.ets：按 target role 显示 WebSocket targetId 与 SSH server-side target。
- entry/src/main/ets/pages/RustDeskRelayPage.ets：只接入聚合状态/标签/动作分派，不改变 RustDesk owner。
- entry/src/main/ets/pages/HostListPage.ets、VncSettingsSheet.ets：VNC 专属设置 leaf，复用既有 bindSheet lifecycle。

### 10.4 测试与服务端

- entry/src/main/cpp/test/vnc_transport_policy_test.cpp：gate、错误、direct/repeater 回归。
- 新增 native WebSocket frame/envelope/stream tests：RFC masking、fragmentation、control、length、close、queue。
- 新增 native SSH tunnel tests：direct-tcpip、EAGAIN、channel close、target refusal、forward denied、host-key failure。
- 新增 ArkTS model/cloud/secret/trust tests：schema migration、dependency projection、empty local protection、scope deselect。
- 独立 Gateway repository/deployment：server、fixture、TLS、token issuer/mock、target registry、interop VNC server、license/provenance。
- 更新 THIRD_PARTY_NOTICES.md、SBOM、NOTICE、REUSE/provenance：仅在真正新增/升级依赖或部署组件时修改，并记录来源和许可证。

## 11. 安全威胁与控制项

| 威胁 | 控制 |
| --- | --- |
| WebSocket token 泄露 | 只用 Authorization header；禁止 URL/query/log/UI；短生命周期解密和内存清零 |
| TLS 降级/中间人 | 默认 WSS、hostname verification、可选 pin、首次/新设备本地确认、secure_only gate |
| 目标 ID 越权 | server-side account/scope/ACL/租约；targetId 不作为授权本身 |
| Gateway SSRF | server 目标 registry/allowlist；客户端不能提交任意公网地址作为 server target |
| WebSocket frame bomb | max logical frame、累计配额、控制帧规则、bounded queues、backpressure close |
| fragmentation/control 解析错误 | RFC 6455 conformance fixture；控制帧可交错但不进入 RFB bytes |
| SSH host-key MITM | SSH owner trust、变更阻断、新设备再确认、禁止 VNC 绕过 |
| SSH 任意端口转发 | 只允许 profile 绑定 target；server PermitOpen/等价 ACL；不实现 reverse/listen |
| SSH tunnel 复用终端状态 | 每连接独立 session/channel；不使用 PTY/Shell singleton |
| 重连重复发送/旧回调 | generation id、单 owner state machine、取消先于释放 |
| 云端空数据覆盖 | cloud-first barrier、依赖投影、mutation journal、scope deselect 不写 tombstone |
| secret/trust 混淆 | secretkind、AAD、owner、schema、reset epoch 全校验；缺依赖只显示 unavailable |
| 开源 license 污染 | noVNC/websockify/libssh2 逐项 license/provenance/SBOM/NOTICE 审核，禁止未经确认复制 |

## 12. 测试矩阵与通过标准

### 12.1 WebSocket unit/fixture

- HTTP Upgrade：成功 101、错误 accept、缺少/错误 subprotocol、错误 version、TLS required。
- RFC frame：client masking、server unmasking rejection、binary/text、fragmentation、continuation、interleaved ping/pong、close code、reserved bits。
- application envelope：kind、big-endian length、超长、截断、错误顺序、hello/ack、RFB payload 逐字节保持。
- security：token 不进日志/错误/URL；expired/unauthorized/target ACL；pin mismatch；无 token 的 secure server。
- reliability：慢 server、慢 RFB target、bounded queue、idle timeout、server shutdown、cancel、retry generation。

### 12.2 SSH tunnel unit/integration

- libssh2 direct-tcpip channel open 成功；server 禁止 forwarding；target refuse/timeout。
- password/public-key/现有代理路径；错误认证和用户取消；host-key match/mismatch/new-device confirmation。
- EAGAIN 读写、partial packet、SSH window、VNC backpressure、half-close、remote EOF、local cancel。
- 同一 SSH profile 并行打开多个 VNC tunnel，互不关闭；SSH terminal/SFTP 同时运行不互相污染。
- 明确断言没有 PTY、Shell、tcpip-forward、本地 listener 和 fallback。

### 12.3 真实互操作

- Direct TCP 与现有真实 VNC server。
- UltraVNC Repeater viewer mode12，验证 pairing、首帧、键鼠、clipboard、断开和重连。
- WebSocket Gateway service + 真实 VNC server，验证 hello/ack、WSS、target ACL、首帧、输入、close/reconnect。
- SSH server + SSH server 侧可达 VNC server，验证 direct-tcpip 与 forwarding policy。
- VNC password、只读、缩放、clipboard、超时和证书信任策略。

### 12.4 HarmonyOS 与回归

- API 23 手机/平板/PC：bindSheet 自适应、配置保存、连接、页面销毁、surface recreation、横竖屏、后台/前台、网络切换、重复连接。
- 单设备：创建、编辑、删除、离线使用、token/SSH key 缺失、crypto lock/reset。
- 双设备同账号：新设备 cloud-first、共享配置、secret opt-in、trust re-confirm、scope deselect、删除 tombstone、offline recovery。
- RDP、RustDesk、SSH terminal/SFTP、RustDesk relay：连接、设置、云同步、卡片、FAB、页面生命周期全部回归。

### 12.5 构建与发布门禁

每个实现 checkpoint 都必须在当前 commit 执行：

~~~sh
source scripts/macos_env.sh
hvigorw --mode module -p module=entry -p product=default default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon
hvigorw --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --no-daemon
git diff --check
~~~

涉及 native/C++ 时还要运行受影响 native tests；涉及开源依赖、服务端部署或发布元数据时还要运行：

~~~sh
. scripts/resolve_powershell.sh
pwsh_cmd="$(resolve_powershell_command)"
"$pwsh_cmd" -NoProfile -File scripts/verify_open_source_release.ps1 -Mode Light -RepositoryRoot .
~~~

ohosTest@OhosTestCompileArkTS 仍需单独尝试；如果环境继续报 00306054 task not registered，只能记录为测试任务/环境 blocker，不能写成测试通过。真实设备和云端服务端验收也必须与本地编译分开报告。

## 13. Enablement、回滚与交付条件

### 13.1 放开条件

WebSocket 或 SSH tunnel 各自独立放开，必须分别满足：

1. contract/version 已冻结并有 owner。
2. native/ArkTS capability gate、secret/trust gate 和 cloud dependency gate 全部 ready。
3. 本地 unit、fixture、native、ArkTS compile 和 package 通过。
4. 有真实 server/target 的端到端 RFB 证据。
5. API 23 真机生命周期、网络切换、取消/重连通过。
6. 双设备 cloud sync/encryption matrix 通过。
7. RDP/RustDesk/SSH terminal/SFTP regression 通过。
8. security、license、SBOM、NOTICE、provenance 和 rollback review 通过。

任何一项未通过时：配置可以作为未来迁移数据保存，但必须 enabled=false 或 capability unavailable，并显示可理解原因。

### 13.2 回滚策略

- 客户端 feature flag 可以分别关闭 WebSocket 和 SSH tunnel，不删除 v2 gateway/host 行。
- server 只接受已发布版本；版本不匹配显示 unavailable，不尝试猜测协议。
- schema v2 回滚时保留未知字段和原始 payload hash；旧客户端读取不支持的 transport 时必须拒绝而不是覆盖成 direct TCP。
- 迁移失败、secret 解密失败、SSH dependency 缺失时保持 disabled 并保留用户数据，等待修复或用户重新确认。
- 回滚不能影响 direct TCP、Repeater mode12、RDP、RustDesk 或 SSH terminal/SFTP。

## 14. 交付物清单

二阶段最终交付必须同时包含：

- 移动端 VNC WebSocket client 和独立 SSH direct-tcpip transport。
- 冻结版 docs/VNC_GATEWAY_PROTOCOL.md 和 SSH tunnel contract。
- 独立 Gateway server/deployment、配置、TLS/token/target ACL 说明和互操作 fixture。
- vncrecord schema v2 迁移说明；不新增物理云表。
- 加密、secret、trust、cloud-first、多设备冲突和 reset epoch 测试证据。
- native/ArkTS/unit/integration/real-device test report。
- license、SBOM、NOTICE、provenance、release/rollback evidence。
- 更新后的 docs/codex/CURRENT.md、QUEUE.md 和最终 HANDOFF；不得记录 token、私钥、真实 endpoint 或设备日志。

## 15. 本轮执行记录

- 已复核代码基线：main / 8528ce539；当前工作树另有未提交的用户/其他任务修改，本计划未触碰这些文件。
- 已复核现有 VNC UX、vncrecord、cloud-first、AES-GCM v2、native VNC 和 SSH terminal owner 边界。
- 已核对 RFC 6455、RFC 4254、libssh2 direct-tcpip、noVNC/websockify、OpenSSH 和 HarmonyOS 官方文档入口。
- 本轮只落盘本计划文件；没有修改 entry、native、Rust、测试、配置或现有协议逻辑。
- 在二阶段实际代码任务开始前，必须先完成 2A 契约冻结，并继续保持两种 transport fail-closed。
