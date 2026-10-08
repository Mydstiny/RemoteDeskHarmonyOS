# RustDesk EasyTier 直连流程与连接失败修复计划

> 已合并：执行以 [2026-10-03 合并计划](2026-10-03-rdp-rustdesk-observability-direct-quality-plan.md) 为准；本文件保留为来源记录。

状态：PLAN_ONLY（2026-10-03，暂不改代码）

本计划针对用户反馈的场景：官方 RustDesk 可以通过 EasyTier 连接，RemoteDesktop 的 RustDesk 直连失败。用户提供的诊断 JSONL 只有 `core.app` 的开始/停止事件，`connection.rustdesk` 为 0 条，因此本计划先修复流程语义和取证能力，再根据真实直连阶段结果修复 native/网络问题。

## 1. 目标与边界

### 1.1 目标

1. 让用户明确区分 RustDesk 中继、普通可达地址直连、局域网发现和 EasyTier 覆盖网络直连。
2. 保证 EasyTier 虚拟 IP、端口、设备密码和直连策略从添加、保存、恢复到 native 连接保持一致。
3. 把直连失败拆分为地址解析、路由/TCP、RustDesk 握手、设备认证、首帧和会话运行阶段。
4. 用可复现的设备矩阵判断问题属于添加流程、HarmonyOS 路由可见性、端口/服务配置还是 RustDesk 协议兼容性。

### 1.2 边界

- 本计划不把 EasyTier 当作 RustDesk 协议能力；EasyTier 只提供一个可达的虚拟网络地址。
- 本计划不通过关闭校验或强制切换策略来伪造 AUTO 能力。当前 AUTO 仍然是 release-gated，需要单独完成 NAT/候选竞争/relay fallback 验证。
- 不记录密码、服务器 Key、完整用户地址或用户原始日志；诊断只保留脱敏后的地址族、端口、路径、阶段和错误类别。
- 当前计划阶段不修改代码、不运行 Hvigor/HAP、不开启真实发布能力。实现阶段仍须按 `AGENTS.md` 执行应用构建和复核门禁。

## 2. 当前代码事实

### 2.1 添加流程

- [RustDeskAddFlow.ets](../../../entry/src/main/ets/components/hostadd/RustDeskAddFlow.ets:258) 当前展示“中继连接”和“局域网直连”。直连内部又分为“手动配置”和“局域网搜索”。
- 手动直连允许域名、IPv4、IPv6，保存 `rustdeskDirectEnabled`、`rustdeskDirectHost`、`rustdeskDirectPort` 和设备密码；远程 ID 可以为空。[RustDeskAddFlow.ets](../../../entry/src/main/ets/components/hostadd/RustDeskAddFlow.ets:129)
- 局域网搜索通过 UDP 21119 广播发现 RustDesk Peer，并要求发现身份、地址策略和设备 ID 保持一致。[RustDeskLanDiscoveryService.ets](../../../entry/src/main/ets/services/RustDeskLanDiscoveryService.ets:1)
- EasyTier 不使用局域网广播发现，应走手动直连地址路径。当前“局域网直连”名称会让用户误以为 EasyTier 也需要局域网搜索。

### 2.2 连接路径

- `directEnabled=true` 映射到 `direct_ip`，否则映射到 `force_relay`。[RustDeskConnectionStrategyPolicy.ets](../../../entry/src/main/ets/services/RustDeskConnectionStrategyPolicy.ets:28)
- 直连 endpoint 来自 `rustdeskDirectHost`/`rustdeskDirectPort`，默认 Peer TCP 端口为 21118。[RustDeskHostConfigPolicy.ets](../../../entry/src/main/ets/services/RustDeskHostConfigPolicy.ets:145)
- native/Rust 直连会跳过 rendezvous，使用 TCP 连接目标 Peer，然后执行 RustDesk 直连 Hash/Login。[connector.rs](../../../rustdesk_ffi/src/connector.rs:1231)
- 直连只允许设备密码；请求被控端批准属于 rendezvous/relay 路径。[RustDeskHostConfigPolicy.ets](../../../entry/src/main/ets/services/RustDeskHostConfigPolicy.ets:96)
- native 将规范化后的直连地址作为 direct peer login identity，不把远程 ID 强行放入直连登录。[lib.rs](../../../rustdesk_ffi/src/lib.rs:2064)

### 2.3 证据缺口

- 用户日志的实际采集窗口约 2.9 秒，`connection.rustdesk` 事件数为 0，无法证明是否进入 native connect。
- 现有策略测试覆盖密码、可选远程 ID、全局/链路本地 IPv6和中继绑定，但没有覆盖 EasyTier 地址的添加、保存/恢复、端口变化、真实 TCP 阶段和 native 直连协议阶段。[RustDeskProConnectionPreflightPolicy.test.ets](../../../entry/src/test/RustDeskProConnectionPreflightPolicy.test.ets:67)

## 3. 根因假设与优先级

### P0：流程语义导致错误使用

用户选择了“局域网直连”后，可能进入局域网搜索或填写了 RustDesk ID，而不是在手动配置中填写 EasyTier 虚拟 IP。该问题属于添加流程说明和分支引导缺失。

### P1：直连 endpoint 或端口不一致

EasyTier 虚拟 IP 可能保存为空、保存为旧地址、被旧全局端口覆盖，或目标 Peer 实际监听的端口不是 21118。需要同时核对添加页、RemoteDesktop 配置和 native 最终参数。

### P1：HarmonyOS 应用进程看不到 EasyTier 路由

官方 RustDesk 连接成功可能走的是 ID/rendezvous 或 relay，而不是 EasyTier 直连。只有在两端都使用相同 EasyTier IP 和端口进行 A/B 后，才能确认 TUN 路由对本应用是否可见。

### P1：直连认证/协议阶段不一致

直连只接受设备密码，不能使用请求批准；TCP 建立后仍可能在 Hash/Login 阶段失败。需要区分密码错误、peer identity、协议版本和首帧问题。

### P2：地址族限制或地址生命周期

链路本地 IPv6 当前明确拒绝；EasyTier 地址变化时，静态保存的 direct host 可能过期。动态 IP 策略当前绑定 RustDesk ID/LAN 语义，不能直接作为 EasyTier 地址更新机制。

## 4. 产品与添加流程修复

### 阶段 A：重命名并重新组织入口

推荐将一级入口从“局域网直连”改为：

> 直连（局域网 / EasyTier）

直连页面保留两个明确的二级选项：

1. **手动地址**：适用于局域网 IP、EasyTier、VPN、域名或其他可达地址。
2. **局域网搜索**：仅适用于同一二层网络的 UDP 21119 发现。

手动地址页面必须明确展示：

- EasyTier 填虚拟 IP，不填 RustDesk ID；
- Peer 端口默认 21118，可修改；
- 直连必须填写设备密码；
- 手动直连可不填控制 ID；
- 局域网搜索才要求发现身份和地址策略。

### 阶段 B：增加直连配置回读和防覆盖

1. 添加成功后立即回读 `rustdeskDirectEnabled`、`rustdeskDirectHost`、`rustdeskDirectPort`。
2. 编辑、保存、冷启动、云同步和主机卡片展示都使用同一个 canonical direct endpoint。
3. 旧主机迁移时，只在明确识别为 direct record 时迁移到 `direct_ip`；不把 EasyTier 地址绑定为 relay endpoint。
4. 对地址变化显示“直连地址已变化，请重新确认”，不静默使用旧地址。
5. 为 `manual_direct`、`lan_discovery`、`overlay_direct` 增加明确的来源标记或等价策略，避免用 `lanAddressMode` 表达 EasyTier 状态。

## 5. 连接和诊断修复

### 阶段 C：统一直连 preflight

添加一个有界的直连 preflight，并让正式连接复用同一个规范化 endpoint：

1. 输入解析：地址、端口、地址族、链路本地 IPv6。
2. 路由/TCP：DNS、无路由、超时、连接拒绝。
3. RustDesk Hash/Login：协议首包、peer identity、设备密码。
4. 会话首帧：认证成功但无视频数据。

每一层返回稳定的脱敏错误类别，不能继续使用通用 `-2` 作为唯一用户提示。

### 阶段 D：补齐 EasyTier 取证

诊断记录以下字段：

- `route=direct_ip`、`source=manual_direct/overlay_direct`；
- endpoint family、端口、是否 scoped IPv6；
- TCP 阶段和 RustDesk 阶段；
- 错误类别、native 连接代次、总耗时；
- 是否发生过 direct-to-relay fallback。

不记录完整 IP、密码、Key、RustDesk ID 或文件/屏幕内容。

## 6. native/网络修复边界

### 阶段 E：先修确定性 direct 问题

只有 preflight 证明问题进入对应阶段后，才修改 native/Rust：

- TCP 前失败：修 endpoint canonicalization、端口、路由可见性或网络观测逻辑。
- TCP 成功、Hash/Login 失败：核对官方 Peer 版本、直连登录 identity、密码和首包协议。
- 登录成功、无首帧：检查 decoder/stream，不把它归因于 EasyTier。

### 阶段 F：可选直连到中继回退

仅对明确的网络错误允许回退到已配置 relay。密码错误、权限错误、peer key 或协议错误不能自动改走 relay，以免掩盖真正原因。

AUTO/NAT/TCP hole punching 作为独立后续计划，不能通过简单把当前 `auto_unavailable` 删除来开启。[RustDeskConnectionStrategyPolicy.ets](../../../entry/src/main/ets/services/RustDeskConnectionStrategyPolicy.ets:51)

## 7. 测试与验收计划

### 7.1 策略和数据测试

- 手动 EasyTier IPv4：控制 ID 为空、地址和 21118 保存正确。
- 手动 EasyTier 自定义端口：保存、编辑、冷启动和云同步后端口不变。
- 局域网搜索：仍要求发现 ID，不能被手动 EasyTier 地址绕过。
- 直连密码为空、请求批准、scoped IPv6、非法端口和非法地址均给出明确错误。
- direct/relay 字段互斥，旧 relay host 不得污染 direct endpoint。

### 7.2 native/fixture 测试

- TCP timeout、connection refused、成功建立 TCP 但 Hash 错误、密码错误、登录成功无首帧。
- direct endpoint 的 IPv4、全局 IPv6、hostname；链路本地 IPv6保持明确拒绝或在单独支持后验收。
- 直连成功后断网、EasyTier 路由变化和取消连接；旧连接不能污染新连接。

### 7.3 真实设备矩阵

1. 同一局域网 IPv4 直连。
2. EasyTier IPv4 直连。
3. EasyTier 地址变化后的重新连接。
4. EasyTier IPv6（若产品决定支持）。
5. 官方 RustDesk 与 RemoteDesktop 使用同一个 EasyTier IP、端口和设备密码进行 A/B。
6. 直连失败、relay 可达时的明确回退行为。

验收必须记录：设备型号/API、EasyTier 地址族、Peer 版本、Peer 监听端口、应用实际 route、失败阶段和完整结构化诊断。编译/HAP 证据不能替代这些网络和设备结果。

## 8. 实施顺序与完成标准

1. A：入口重命名和手动/EasyTier 引导。
2. B：direct endpoint 保存/回读/迁移边界。
3. C-D：统一 preflight 和脱敏诊断。
4. E：按真实失败阶段修复 native/网络问题。
5. F：单独评估 direct-to-relay fallback 和 AUTO。
6. 完成策略测试、native fixture、真实 EasyTier A/B、回归和独立复核后，才把计划状态改为实现完成。

本计划提交时不修改应用代码、不运行构建门禁，不把当前空 RustDesk 日志写成根因结论。
