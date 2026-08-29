# 全协议 IPv6 支持升级计划

> 日期：2026-08-29
>
> 审查基线：`codex/per-protocol-pinch-zoom-plan@1051588dd`
>
> 范围：RDP、RustDesk、SSH/SFTP、VNC、Moonlight；覆盖录入、持久化、解析、连接、代理/网关、证书或主机密钥、发现、重连、诊断与测试。
>
> 基线说明：本计划来自 `1051588dd` 的只读代码审查，不把该提交之后的并发修改倒推为审查证据。2026-08-30 经用户明确授权，开始在当前活动工作树按里程碑实施。

## 1. 结论

项目已经具备多处 IPv6 底座，但尚无协议达到可无条件宣称“端到端 IPv6 完成”的标准。Moonlight、SSH/SFTP、VNC、RDP 的底层传输已能处理部分 IPv6/AAAA 场景；RustDesk 也能连接部分人工配置的 TCP IPv6 端点。共同短板集中在：地址契约不统一、括号与 zone/scope 语义不完整、双栈候选串行、连接与预检/信任身份不一致、发现仍偏 IPv4、真实数据通道与真机矩阵不足。

因此建议采用“统一端点基础设施 + 分协议闭环 + 分能力声明”的方案，而不是逐页放宽输入校验。发布时必须区分：

1. `configured_endpoint_ipv6`：人工配置的 IPv6/AAAA 端点可完成真实会话；
2. `dual_stack_racing`：A/AAAA 可控竞速、失败回退与网络切换闭环；
3. `discovery_ipv6`：发现结果携带地址族和 scope，且不扫描 IPv6 `/64`；
4. `protocol_control_data_ipv6`：协议控制面和数据面选择同一可用地址族；
5. `nat_traversal_ipv6`：仅 RustDesk AUTO/NAT/打洞完成后声明。

能力按“协议 × 能力”独立验收和发布；不适用项记为 N/A。依赖关系为：`configured_endpoint_ipv6=M0+M1`、`dual_stack_racing=M2`、`discovery/control-data=M3`、`RustDesk nat_traversal_ipv6=M4`，后者不得阻塞其他协议的较低层级声明。

实施状态（2026-08-30）：M0 已完成，M1 进行中。Endpoint V2 已接入五协议录入/导入、规范化新写、SSH 代理与跳板链、RustDesk control-plane fingerprint、RDP/VNC 预检以及通用/Moonlight NAPI 边界；非法、歧义和未完成接口存在性验证的 scoped IPv6 均 fail-closed。五类“协议 × 能力”声明已独立定义且仍全部关闭；真实连接、重连和真机矩阵未完成前不发布 `configured_endpoint_ipv6`。

## 2. 当前能力矩阵

| 协议 | 已有基础 | 主要发布阻断 | 当前判定 |
|---|---|---|---|
| RDP | 预检与 RD Gateway 解析使用 `AF_UNSPEC`；真实 FreeRDP 支持 IPv6/AAAA；IP SAN 校验已有基础 | 输入/规范化、route/trust identity、transport/SNI/client hostname 混用、Gateway literal + DNS 证书名、Happy Eyeballs、IPv6 发现 | 部分支持 |
| RustDesk | ID/Relay/Direct TCP helper 可解析 hostname、raw/bracketed IPv6；屏幕与文件传输复用该路径 | 官方 `socket_addr_v6` 未接入；控制面 fingerprint 可截断 raw IPv6；健康检查固定 IPv4；无双栈竞速；UDP/NAT/打洞/AUTO 未实现 | 仅配置型 TCP 部分支持 |
| SSH/SFTP | Direct 使用 `AF_UNSPEC`；HTTP CONNECT、SOCKS5 ATYP=IPv6、ProxyJump 下游和 forwarding 已有 IPv6 能力；SFTP 复用 SSH session | bracketed direct/proxy、zone、runtime 与 probe/key-install 路由不一致、无 Happy Eyeballs、listener 未显式 `IPV6_V6ONLY`、remote-forward 候选回退缺陷 | 基础较强但未闭环 |
| VNC | transport 与证书 probe 使用 `AF_UNSPEC`/`sockaddr_storage`；已有 `::1` 证书 probe fixture | bracketed host、zone 被误当 DNS/SNI、trust key 未规范化、顺序地址尝试、缺真实 VNC IPv6 transport 测试 | 部分支持 |
| Moonlight | 已有 IPv4/IPv6/hostname 模型、bracket formatter、IPv6 mDNS 候选、控制面候选和 upstream IPv6/NAT64 支持 | zone/scope 缺失、模型语义校验不足、等价 IPv6 未去重、控制面实际选址未原样传到媒体面、hostname family preference 不可靠 | 最接近完成，仍需闭环 |

注：SFTP 不建立独立网络连接栈，跟随 SSH transport 升级，但必须单独覆盖传输恢复与文件完整性验收。

## 3. 统一技术基线（P0）

### 3.1 Endpoint V2

建立 ArkTS 与 native 共用语义的版本化端点模型。模型分四层，禁止混用：原始文本只存在于 parse request；校验成功后才生成 canonical value；DNS 结果和 numeric scope 只存在于本次运行的 resolved sockaddr；证书 pin、host key 和 route 只消费 typed server identity 与 canonical endpoint。canonical value 至少包含：

```text
canonicalHost, family(hostname|ipv4|ipv6), port,
scope/interfaceName?, scopeKind, endpointVersion
```

规则：

- host 与 port 始终分字段；持久化的 IPv6 host 不带方括号。
- host-only 输入接受 hostname、IPv4、raw IPv6、`[IPv6]`；仅组合输入接受 `[IPv6]:port`，拒绝含 scheme、userinfo、path、CR/LF 或歧义端口的文本。
- IPv6 经二进制解析后输出稳定 canonical text；socket/UI authority formatter 使用 `%scope`，URI authority formatter 按 RFC 6874 使用 `%25scope`，两者均仅由 formatter 添加方括号，禁止混用。
- zone/scope 独立建模。link-local scope 是路由属性，不进入 IP SAN；接口名默认不得跨设备同步。
- ArkTS、NAPI 和 native 边界均 fail-closed，并设长度上限；不再由各协议手写冒号切割。
- 提供统一 `formatHostPort`、`formatUserAtHost` 和 IPv6-aware 脱敏函数，禁止完整地址或接口名进入日志。

M0 同时冻结以下规范性决策：

- ASCII DNS 校验后转小写并去除一个根尾点；第一期拒绝 Unicode host，待引入统一、可审计的 IDNA/Punycode 实现后再开放。
- 第一期开启手工配置时拒绝 IPv4-mapped IPv6、unspecified `::` 和 multicast；loopback 可用但不得绕过公网监听确认。
- link-local 必须提供语法有效且在当前网络可映射的 interface-name scope；numeric scope 仅允许本次运行使用，不持久化；global IPv6 携带 zone 直接拒绝。接口存在性/索引映射在接入网络边界时验证，接口失效时给出 scope 错误，不尝试无 scope 连接。
- bracketed host-only 输入统一去括号后存储；`canonicalHost` 仅保存 DNS/IP 文本，运行时 `resolvedAddress/sockaddr` 不持久化。

### 3.2 解析与双栈连接（P1/M2）

- API 23 下使用系统/原生 `getaddrinfo(AF_UNSPEC)` 或等价网络解析能力，保留 A/AAAA 全候选及 resolver owner；M1 先保证 IPv6 literal、AAAA-only 和同网络重连，M2 再开放双栈能力声明。
- M2 实现受控 Happy Eyeballs：地址族交错、短 stagger、共享总 deadline、首个成功者获胜、取消其余候选。客户端负责解析时，预检与连接复用同一候选策略；网关/代理/上游负责解析时，保持同一目标身份和 resolver owner，不虚构客户端可控制的 family 一致性。
- 网络 generation 变化时取消旧候选并在当前网络重新解析；不得让旧 DNS 结果跨网络复用。
- 诊断仅记录阶段、resolver owner、候选数、获胜 family、fallback 原因、scope 是否存在和脱敏错误，不记录完整 endpoint。

### 3.3 身份、信任与迁移

- route、证书 pin、Restricted Admin secret、RustDesk control-plane fingerprint、SSH hop trust、VNC TLS binding 改为版本化结构序列化或长度前缀/hash，禁止用未转义 `host:port|...` 拼接。
- 旧记录双读，新写 canonical V2。只有当 host/port/serverName/route/scope 的解析语义完全等价时才能继承信任；歧义、非法或 scope 改变时必须重新预检，不能静默迁移 pin/秘密。
- DNS 身份绑定逻辑 hostname 与端口，不绑定某次 A/AAAA；IP literal 使用 canonical IP。link-local 配置只保存在本设备，或同步时显式失效。

## 4. 分阶段实施

### M0：契约与安全迁移门禁（P0）

1. 冻结 Endpoint V2、zone policy、formatter、identity V2 和错误码。
2. 建立共享 parser/formatter/resolver 测试向量，加入旧数据迁移与信任 fail-closed 用例。
3. 对每个协议定义独立能力开关；默认不开启新的 IPv6 产品声明。

退出条件：同一输入在 ArkTS/native 得到相同 canonical 结果；非法/歧义输入无法落库或进入传输；旧信任没有越权继承。

### M1：人工配置端点端到端 IPv6（P0）

| 协议 | 必做工作 |
|---|---|
| RDP | 拆分 `connectHost`、`targetServerName`、真实 `clientHostname`；旧 `customHostname` 迁移为 `targetServerName`，新的 `clientHostname` 默认空。Gateway 独立 connect host/server name；仅 DNS 名发 SNI；direct、Gateway、证书预检统一 Endpoint V2 与 IP SAN 规则。通过锁定补丁/升级 FreeRDP 或验证独立设置接口修正其 literal SNI 行为，并以 direct/Gateway 握手证据验收。产品构建强制 `USE_REAL_FREERDP=ON`，IPv4-only skeleton 明确不受支持。首期通用 HTTP/SOCKS proxy 为 N/A，仅承诺 direct + Microsoft RD Gateway。 |
| RustDesk | Import、ID、Relay、Direct、健康检查统一 Endpoint V2；修复 raw IPv6 fingerprint 截断；TCP helper 使用统一总 deadline 与可取消 attempt，M2 再启用 A/AAAA 竞速；连接与登录身份使用同一 canonical 表示；AUTO 继续 fail-closed，并修正误导性的 NAT 能力标记。 |
| SSH/SFTP | direct、FRP、HTTP/SOCKS proxy、ProxyJump 1–3 跳、probe/auth/key-install 共用 production transport；修复 bracket/zone；所有敏感认证前完成对应 hop/target host-key 校验。 |
| VNC | direct/repeater、TLS probe 与正式 transport 共用 parser/resolver；把 scoped connect address 与 TLS serverName 分开；IP SAN 去 bracket/zone，route identity 保留 scope；补真实 IPv6 VNC 会话 fixture。 |
| Moonlight | 强化 address/family 语义校验和 RFC 5952 去重；Host API 返回实际选中的 numeric address/family/scope，并原样传给 streaming/common-c，避免控制面与媒体面二次 DNS 后选到不同 family。 |

退出条件：每个希望开启 `configured_endpoint_ipv6` 的协议独立通过“新增/编辑 → 保存/重启 → 预检/信任 → 真实连接 → 同网络断线重连”的 IPv6 literal、AAAA-only 流程；不适用项为 N/A。SFTP 另通过上传、下载、列表和断线恢复。

### M2：双栈、代理/网关与监听完整性（P1）

- 全协议接入共享总预算的 Happy Eyeballs，并验证第一候选黑洞时可回退。
- RDP 覆盖 target/gateway 混合 family；SSH 覆盖 proxy、1–3 hop 与 remote-forward 本地 target；VNC 覆盖 repeater；Moonlight 保证控制/媒体 family 一致。
- SSH IPv6 listener 显式设置 `IPV6_V6ONLY`；默认 IPv6-only。若产品允许 dual-stack，显式创建双 listener 或显式关闭 V6ONLY，并通过 `getsockname` 回传实际 family/bind address。
- 所有协议在网络切换、IPv6 前缀变化、VPN 和 DNS64/NAT64 场景淘汰旧候选并重新连接。

退出条件：A-only、AAAA-only、dual-stack、IPv6 blackhole→IPv4 fallback、IPv4失败→IPv6、取消与网络切换均有可重复自动化和真机证据。

### M3：发现与协议控制面/数据面（P1）

- 禁止 IPv6 `/64` 暴力扫描。保留现有 IPv4 `/24` 行为；IPv6 采用 mDNS/DNS-SD、协议原生发现、系统可见邻居或已保存 endpoint 定点刷新。
- Moonlight mDNS 候选携带 interface/scope；双栈同机按稳定身份去重。
- RustDesk 接入固定 upstream schema 的 `socket_addr_v6`，将单一 peer address 改为带来源/family 的候选集合；屏幕、presence、文件传输共用 selector，并验证失败后 relay fallback。
- RDP 动态地址继续以证书 fingerprint 为身份线索，地址 family/scope 仅作为候选；相同 fingerprint 仍可能来自证书克隆，只有更多稳定关联证据充分时才能合并，无法确认时保持 fail-closed。不得把随机 IPv6 扫描结果当身份。

退出条件：发现结果可实际连接且 scope 正确；RustDesk 官方 hbbs/hbbr 的 IPv6-only 和双栈候选完成屏幕、presence、文件传输闭环。

### M4：RustDesk AUTO/NAT/打洞（P2，独立里程碑）

- 实现官方兼容的 NAT test、UDP registration/heartbeat、TCP coordination/hole punching，正确填充 IPv6 wire 字段。
- 覆盖对称 NAT、CGNAT、UDP blocked、TCP-only、global IPv6、IPv6-only、NAT64 和 relay fallback。
- 由 Rust native 独占可取消 socket 状态机；只有真实固定版本 hbbs/hbbr 与官方受控端矩阵通过后才开放 AUTO，并声明 `nat_traversal_ipv6`。

## 5. 验证矩阵与完成定义

最低自动化向量：

- 语法：hostname、IPv4、`::1`、global IPv6、压缩/展开等价形式、IPv4-mapped IPv6、`[v6]`、`[v6]:port`、非法 `:::1`、尾随垃圾、URL/path/userinfo、超长/控制字符。
- scope：有效 interface/numeric scope、缺 scope、接口消失/切换、跨设备同步失效、scope 不参与 IP SAN 但参与路由身份。
- DNS/连接：A-only、AAAA-only、多 A/AAAA、两种 family 黑洞与回退、NXDOMAIN、空结果、慢解析、取消、IPv6-only、DNS64/NAT64。
- 安全：DNS SAN + AAAA、IPv6 IP SAN、literal 不发 SNI、显式 serverName、等价 IPv6 不误丢 pin、不同 scope/port/route 不串信任、两个设备复用同一证书时不被误合并。
- 协议：RDP direct/Gateway；RustDesk ID/Relay/Direct/official candidate/file transfer；SSH direct/proxy/jump/forwarding/SFTP；VNC direct/repeater/TLS；Moonlight HTTP/pair/control/RTSP/UDP media。
- 真机：HarmonyOS Phone/Pad/PC，至少双栈 Wi-Fi、IPv6-only/NAT64、VPN、link-local；模拟器只作补充。

某协议的某项 IPv6 能力“完成”必须同时满足适用项：

1. 新增、编辑、保存、重启、备份/云同步按策略正确往返；
2. 预检与真实连接使用相同 endpoint/identity 契约；客户端解析时复用 family 候选策略，上游解析时保留同一 resolver owner 和目标身份；
3. 控制面与数据面均通过，且网络切换后可恢复；
4. 错误可区分 DNS、scope、no-route、timeout、refused、TLS/host-key、family fallback；
5. 自动化、API 23 Hvigor 双门禁、native/Rust 测试和真机报告均通过；
6. 独立 reviewer 复核后，才开启对应协议能力声明。

## 6. 主要改造面与风险控制

主要改造面集中在：

- 共享模型/持久化/UI：`RemoteHost.ets`、各 HostAddFlow、`CloudStore.ets`、`CloudTableAdapter.ets`、备份/同步、`HostListPage.ets`、`SafeLogger`；
- RDP：`freerdp_adapter.cpp`、证书与 gateway policy、ExtensionLoader/NAPI、LAN discovery；
- RustDesk：`rustdesk_ffi/src/net.rs`、`protocol/rendezvous.rs`、`connector.rs`、control-plane/relay/direct policy 与健康检查；
- SSH/SFTP：`ssh_adapter.cpp`、`ssh_key_tool.cpp`、route/forwarding/NAPI、preflight/key-install、SFTP recovery；
- VNC：`vnc_transport.cpp`、`vnc_certificate_probe.cpp`、TLS/trust endpoint policy、direct/repeater flows；
- Moonlight：HostAdd/Models/Discovery/RuntimeContext、ProductRuntime/HostApi、HTTP formatter 和 common-c 交接边界。

实施时应坚持小步提交和逐协议 feature gate。任何阶段都不得用“parser 单测通过”“底层出现 `AF_INET6`”或“某次 `::1` probe 成功”替代端到端验收；迁移与信任问题一律 fail-closed，性能优化不得放宽证书/host-key 边界。
