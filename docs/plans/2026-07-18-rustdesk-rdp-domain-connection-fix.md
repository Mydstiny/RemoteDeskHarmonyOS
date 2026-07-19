# RustDesk / RDP 域名连接问题修复方案

日期：2026-07-18  
状态：待实施，已完成只读证据分析  
范围：RustDesk 域名中转、Pro/普通中继配置、RDP 域名预检查、连接弹窗生命周期  
约束：当前不修改业务代码，不构建，不提交

## 1. 结论摘要

本次问题不是一个统一的 DNS 故障，而是两条协议在新增连接前置流程中分别出现了回归：

- RustDesk 域名已经解析并到达 `RequestingRelay`，但普通主机没有绑定中继配置或 server key，应用发送 `key_len=0`，服务器返回 `LICENSE_MISMATCH`。
- RDP 的 IP 证书检查和连接正常；域名仅在新增证书预检查的 raw `getaddrinfo()` 阶段失败，失败码为 `gai=-2`。
- 快速点击会并发启动多个连接尝试，造成多个 sheet/FFI 生命周期重叠。

根本的产品设计问题是：连接入口、主机 endpoint、relayId、Pro account 和 server key 没有形成一个不可缺项的连接契约；新前置流程又扩大了适用范围，导致普通连接走了 Pro 流程，并将配置错误延迟到服务器报错。

## 2. 证据链

### 2.1 RustDesk 域名中转

实体机日志出现：

```text
Connecting to rustdesk...online:21116
Request peer=... keyId=default key=<empty>
state=RequestingRelay
error=punch hole refused: LICENSE_MISMATCH
key_len=0
```

含义：

1. 域名已经进入 FFI；
2. 已到达 rendezvous/relay 请求阶段；
3. 失败数据是空 key，而不是 DNS 失败；
4. server key 必须来自与目标 ID/Rendezvous server 同一套 relay 配置。

IP Pro 中转日志曾出现非默认 `serverKeyId` 和 `key=<secret:44>`，说明携带 key 的 IP 中转路径与空 key 域名路径不是同一配置状态。

### 2.2 RDP

域名日志：

```text
RDP-CERT resolve failed ... gai=-2
Unable to resolve RDP host
```

IP 日志：

```text
resolve ok
tcp connected
tls handshake ok
probe ok
```

所以 RDP 证书校验、TLS 和 IP 连接能力是正常的；当前失败点是实体机对域名的解析路径。

## 3. RustDesk 代码路径模拟

### 3.1 正确路径：独立 relay 页面/完整配置

填写：

```text
idServer = domain
idServerPort = 21116
relayServer = relay-domain
relayPort = 21117
key = server-key
```

保存后 relay 应包含完整五元组。主机选择该 relay 后：

```text
host = relay.idServer
port = relay.idServerPort
rustdeskRelayId = relay.id
```

进入连接时由 relayId 找回 key，最终应为：

```text
direct=off
Connecting to domain:21116
serverKeyId=<non-default>
key=<secret:N>
```

### 3.2 当前错误路径：旧普通主机/未绑定 relay

现有主机可能是：

```text
host = domain
port = 21116
rustdeskRelayId = ''
customHostname = peer-id
```

当前校验允许该对象保存。连接配置组装时没有 relayId，无法找回 key：

```text
relayId=未设置
serverKeyId=default
key=<empty>
```

这与实体机日志完全一致。

### 3.3 当前错误路径：内嵌新增 relay

`RustDeskAddFlow.saveRelay()` 没有把表单中的端口和 key 写入新对象。即使主机绑定了新 relay，也可能得到：

```text
idServer = domain
idServerPort = default
relayServer = relay-domain
relayPort = default
key = ''
```

该路径必须与独立 relay 页面统一到同一个保存服务。

### 3.4 当前入口回归

`d894f59a9` 将 RustDesk 连接入口从仅 Pro 托管主机扩大为全部 RustDesk 主机：

```diff
- host.protocol === 'rustdesk' && host.sourceType === 'rustdesk_pro' && host.rustdeskProManaged
+ host.protocol === 'rustdesk'
```

结果是普通账户也进入 Pro 预鉴权 sheet。该改动与快速弹窗冲突和普通账户错误直接相关，应恢复模式区分，或将预鉴权流程重构为真正协议无关且能正确处理三种模式。

## 4. 修复设计

### 4.1 建立统一连接配置解析器

新增一个唯一的连接配置解析层，输入 `RemoteHost`、relay 集合和 Pro account，输出不可变的连接配置：

```text
mode: direct | relay | pro-relay
endpointHost
endpointPort
peerId
relayId
accountId
serverKey
authMode
```

所有入口都必须使用该解析器：普通 RustDesk、Pro 地址簿、旧主机迁移、预鉴权和最终 RemoteDesktop 会话。禁止各页面重复拼装字段。

### 4.2 明确三种 RustDesk 契约

#### 直连

- 必须有 direct host/port；
- 不需要 ID server key；
- 只能使用设备密码；
- 不进入 Pro relay 预鉴权。

#### 普通中继

- 必须有明确 relayId；
- endpoint 来自 relay.idServer/idServerPort；
- 如果该服务器要求 key，则必须有非空 key；
- 不显示或调用 Pro 专属账户预鉴权 UI。

#### Pro 中继

- 必须有 relayId、accountId、peerId；
- relay endpoint、API server、account relayId 必须属于同一配置；
- 必须有对应 server key；
- 进入 Pro 设备密码/批准预鉴权。

### 4.3 修复 relay 保存

统一所有新增、编辑、导入路径，完整保存：

```text
idServer
idServerPort
relayServer
relayPort
apiServer
key
```

不要在内嵌组件中重新实现保存逻辑。对于 Pro relay，key 不能再被模型无条件标为“可选”；如果确实支持非 Pro 无 key server，应由 server kind/能力探测区分，而不是让所有配置都静默通过。

### 4.4 修复旧主机绑定

添加 relay 后执行一次受控迁移：

1. `rustdeskRelayId` 已存在：校验引用是否仍有效；
2. `rustdeskRelayId` 为空且 endpoint+port 唯一匹配 relay：自动绑定；
3. 匹配多个 relay：要求用户选择；
4. 无匹配：保留主机但连接前提示“请选择中继配置”；
5. 直连主机：绝不迁移到 relay。

不能只迁移 Pro managed host，普通旧主机也要有明确迁移策略。

### 4.5 修复连接入口

恢复普通 RustDesk 与 Pro RustDesk 的入口分支：

- 普通 relay：直接进入通用 RemoteDesktop 会话，或进入专门的普通认证 sheet；
- Pro managed relay：进入 Pro preflight；
- direct：进入直连流程；
- 任何配置不完整：在 FFI 前失败并给出明确提示。

错误信息至少区分：中继配置未绑定、server key 缺失、server key 与服务器不匹配、域名解析失败、TCP 连接失败、设备密码/远端批准失败。

### 4.6 修复 RDP 域名预检查

RDP 预检查应与实际 FreeRDP 连接使用同一套 endpoint/resolver 语义：

- 保留原始域名用于 TLS SNI 和证书主机名校验；
- 解析应使用设备实际可用的 DNS/VPN/TUN 路径；
- 不要让独立 raw `getaddrinfo()` 在目标域名只存在 Windows 私有隧道映射时成为不可解释的硬闸门；
- 如果设备确实不具备该私有 DNS/VPN 能力，应明确提示“设备无法解析该域名”，不能显示为证书错误；
- IP 路径保持当前成功行为。

如果域名只在 Windows 的 Meta Tunnel 中存在合成记录，而实体机没有同一隧道，App 代码无法凭空解析它；此时必须提供真实可达 DNS 记录或设备侧网络能力。

### 4.7 修复弹窗并发

建立统一连接尝试仲裁：

- 每个 host 同时只有一个 attempt；
- sheet 打开、连接启动、FFI teardown、sheet 关闭各有明确状态；
- 新点击取消/替换旧 attempt，不允许两个 FFI session 并发；
- generation/token 同时保护 probe 结果、pending route 和 sheet `onDisappear`；
- 连接中按钮禁用；
- 旧 route 不得消费新 host 的 pending 参数。

## 5. 测试方案

### 5.1 单元/策略测试

覆盖 direct / relay / pro-relay 三模式解析、relayId 缺失、relayId 失效、key 为空、endpoint 唯一/多重/无匹配迁移、API server 与 ID server 分离、RDP IP/域名错误分类、重复点击和迟到结果。

### 5.2 实体机矩阵

| 场景 | 预期 |
|---|---|
| RDP IP | 证书预检查与实际连接成功 |
| RDP 域名且设备可解析 | 预检查与实际连接成功 |
| RDP 域名且设备不可解析 | 明确解析错误，不伪装为证书错误 |
| RustDesk 普通 IP relay + 合法配置 | 中转成功 |
| RustDesk 普通域名 relay + 合法 key | 中转成功 |
| RustDesk Pro 域名 + 地址簿 | key 非空，预鉴权成功 |
| RustDesk 无 relayId | FFI 前阻断并提示绑定配置 |
| RustDesk 空 key 对 Pro server | FFI 前阻断并提示 key 缺失 |
| RustDesk direct IP | 直连成功，不经过 relay/pro preflight |
| 快速重复点击 | 只产生一个有效 attempt |

### 5.3 日志验收

成功域名中转必须满足：

```text
direct=off
Connecting to <domain>:<port>
relayId=<masked non-empty>
serverKeyId=<non-default>
key=<secret:N>
```

失败时必须能看到准确阶段，不允许只显示通用“连接失败”。

## 6. 风险与实施顺序

- 不自动把域名替换成 IP，避免证书主机名、SNI、多租户路由被破坏。
- 不按域名盲目选择 key，避免把一个服务器的 key 发给另一个服务器。
- 旧主机迁移必须可撤销，并保留原 host/port。
- 当前工作树有邻近任务未提交修改；实施前必须重新确认差异，只暂存本修复涉及文件。

实施顺序：

1. 修复 RustDesk 入口条件，停止普通主机误入 Pro preflight；
2. 统一 relay 保存并补齐内嵌路径的 key/端口；
3. 增加 relayId/key 完整性校验和旧主机迁移；
4. 统一 RustDesk 连接配置解析；
5. 修复 RDP 域名预检查 resolver/错误分类；
6. 实现连接尝试与 sheet 生命周期串行化；
7. 执行策略测试和实体机矩阵；
8. 通过验证后再提交代码。

## 7. 当前状态

方案已落盘，业务代码尚未修改，未构建，未提交。持久化记录位于：

- `.planning/rustdesk-rdp-domain-fix/task_plan.md`
- `.planning/rustdesk-rdp-domain-fix/findings.md`
- `.planning/rustdesk-rdp-domain-fix/progress.md`
