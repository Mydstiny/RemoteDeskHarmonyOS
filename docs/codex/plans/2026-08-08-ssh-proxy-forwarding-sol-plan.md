# SSH 代理设置与隧道转发实施计划（Sol 简版）

- 状态：`PROPOSED`，只是一份执行计划
- 日期：2026-08-08
- 分支：`codex/ssh-terminal-complete-upgrade`
- 上位计划：`docs/codex/plans/2026-08-08-ssh-level-b-frp-completion-plan.md`
- 目标：让 SSH 连接支持代理设置，以及 local/remote/dynamic 隧道转发

## 1. 本计划只做什么

实现两组能力：

1. SSH 连接代理设置：
   - Direct。
   - HTTP CONNECT。
   - SOCKS5。
   - SSH ProxyJump，一至三跳。
   - 已由外部 FRP 暴露的 TCP SSH endpoint。
2. SSH 隧道转发：
   - Local forwarding。
   - Remote forwarding。
   - Dynamic forwarding，也就是本地 SOCKS5 listener。

不做：

- 不修改 SFTP。
- 不修改 RDP、RustDesk、VNC。
- 不内嵌 frpc，不实现 FRP 控制面。
- 不处理 FRP token、visitor secret、STCP/XTCP 建链。
- 不实现 SUDP。
- 不启用 Native GPU terminal renderer。
- 不重写现有 SSH adapter 和 forwarding manager。

## 2. 当前代码事实

不要重新实现已有 Native 数据链路：

- HTTP CONNECT 和 SOCKS5 握手已在 `entry/src/main/cpp/ssh/ssh_adapter.cpp` 中存在。
- ProxyJump 已使用 `libssh2_channel_direct_tcpip_ex`，Native 最多支持三跳。
- Local、remote、dynamic forwarding 的 Native listener/channel 基础已经存在。
- SOCKS5 CONNECT 状态机已经存在。
- ArkTS 已有 Native forwarding wrapper 和基础 policy。
- 当前主要缺口是 profile、controller、正式 UI、逐跳错误和真实端点验收。

原则：先复用和加固，再补 UI；禁止另写第二套 SSH adapter。

## 3. 绝对修改边界

### 允许修改

- `entry/src/main/cpp/ssh/**`
- `entry/src/main/ets/services/Ssh*.ets`
- 新增 `entry/src/main/ets/components/ssh/**`
- `entry/src/main/ets/pages/SshTerminal.ets` 的最小接线
- `entry/src/main/ets/components/hostadd/SshAddFlow.ets` 的最小接线
- SSH 专属 ArkTS/Native 测试
- `tests/ssh_endpoints/**`
- SSH 专属字符串和文档

### 仅允许 additive 修改

- `entry/src/main/cpp/extensions/extension_loader_napi.cpp`
- `entry/src/main/cpp/extensions/protocol_adapter.h`
- SSH NAPI `.d.ts`
- `entry/src/main/cpp/CMakeLists.txt`

### 禁止修改

- `entry/src/main/ets/pages/RemoteDesktop.ets`
- `entry/src/main/cpp/render/**`
- `entry/src/main/cpp/rdp/**`
- `rustdesk_ffi/**`
- VNC/RDP/RustDesk 页面和服务
- SFTP 页面、任务引擎和 store

发现其他 session 的改动时，保留原样，不 reset、不 stash、不覆盖、不一起提交。

## 4. 必须遵守的运行时规则

所有 Native 操作必须携带：

- `sessionId`
- `channelId`
- `generation`

禁止使用全局 active SSH adapter。

收到 callback 时依次校验：

1. session 仍存在。
2. channel 仍属于该 session。
3. generation 与当前 generation 相同。
4. runtime 仍处于允许接收该事件的状态。

任一条件失败：丢弃 callback，并释放它携带的 Native 资源。

## 5. 代理 Profile

新增 `SshProxyProfileV1`，只保存非秘密字段：

- `schemaVersion: 1`
- `hostId`
- `kind`
- `connectTimeoutMs`
- HTTP/SOCKS endpoint
- ProxyJump `hops[]`
- 外部 FRP endpoint
- `updatedAt`

`kind` 只允许：

- `direct`
- `http_connect`
- `socks5`
- `ssh_jump`
- `frp_tcp_endpoint`
- `external_frp_visitor_endpoint`

### HTTP CONNECT / SOCKS5

保存：

- proxy host
- proxy port
- username，可选
- 是否需要认证

不保存：

- 密码
- token
- 认证 header

连接前通过一次性 secret broker 请求密码。

### ProxyJump Hop

每个 hop 保存：

- `hopId`
- label
- host
- port
- username
- auth method
- private key ID，可选
- host-key policy
- known fingerprint，可选
- timeout
- position

最多三跳。第四跳必须直接拒绝，不能截断。

每个 hop 和最终目标分别完成：

1. TCP/上游 channel 建立。
2. SSH KEX。
3. host-key 校验。
4. 认证。

错误必须显示具体位置，例如“第 2 跳 host-key 不匹配”。

### 外部 FRP Endpoint

App 只连接外部 FRP 已经提供的 TCP 地址：

- FRP TCP：填写 frps 对外 SSH 映射 host 和 remote_port。
- 外部 Visitor：填写官方 frpc visitor 已监听的 TCP host 和 bindPort。

App 不显示、不保存：

- FRP 控制端口
- FRP token
- visitor secret
- proxy name
- FRP 协议版本

STCP/XTCP 只可作为来源说明，不能让 App 启动 FRP 协议。SUDP 不允许保存为 SSH route。

## 6. Forwarding Profile

新增 `SshForwardingProfileV1`：

- `schemaVersion: 1`
- `id`
- `ownerHostId`
- `type: local | remote | dynamic`
- `bindHost`
- `bindPort`
- `targetHost`
- `targetPort`
- `startPolicy: manual | onSessionReady`
- `maxConnections`
- `byteLimit`
- `updatedAt`

默认安全规则：

- Local 默认绑定 `127.0.0.1`。
- Dynamic 默认绑定 `127.0.0.1`。
- Remote 默认请求远端 loopback listener。
- 非 loopback 地址必须二次确认。
- 端口必须为 1–65535；允许使用 0 时必须明确表示动态分配并回显实际端口。
- Dynamic 不需要 targetHost/targetPort。

运行时 `SshForwardingRuntime` 只保存在内存：

- profileId
- sessionId
- channelId
- generation
- nativeRuntimeId
- actualBindHost/Port
- state
- activeConnections
- bytesIn/Out
- lastError

## 7. UI 设计

### 7.1 统一风格

新增并复用：

- `SshSheetScaffold.ets`
- `SshProxyEditor.ets`
- `SshJumpHopEditor.ets`
- `SshForwardingSheet.ets`
- `SshForwardingEditor.ets`
- `SshRuntimeStatusCard.ets`
- `SshModalCoordinator.ets`

视觉规则：

- 间距使用 8/12/16/24vp。
- 输入框圆角 10vp，卡片 12vp，sheet 16vp。
- 最小点击区域 44×44vp。
- 关闭按钮固定在 header 右侧，不能上移或覆盖标题。
- 使用现有主题颜色，禁止新增随意硬编码颜色。

### 7.2 代理设置入口

在 SSH 添加/编辑主机中增加“连接方式”：

- 直连
- HTTP 代理
- SOCKS5 代理
- SSH 跳板
- FRP TCP 入口
- 外部 FRP Visitor 入口

选择后只显示对应字段。

Phone：

- 保持现有添加主机 bindSheet。
- 代理配置在同一个 sheet 内切换步骤。
- 不再打开嵌套系统 bindSheet。

Pad/PC：

- 使用宽 bindSheet。
- 左侧连接方式/跳板列表，右侧详情。
- 窄窗口回退单栏。

### 7.3 隧道转发入口

SSH 终端工具栏增加“隧道”按钮：

- badge 显示运行中的 listener 数量。
- 错误时显示错误状态点。
- 点击打开 `SshForwardingSheet`。

Sheet 内容：

- 左侧 forwarding profile 列表。
- 右侧 profile 编辑和 runtime 状态。
- Phone 使用单栏列表 → 编辑。
- Pad/PC 使用双栏宽 sheet。

每张 runtime 卡显示：

- 类型
- bind 地址
- target 地址
- listening/stopped/error 状态
- 当前连接数
- 收发流量
- 启动/停止按钮

运行中的 profile 不允许直接修改，必须先停止或另存。

### 7.4 弹窗竞态

所有新增 SSH sheet 经过 `SshModalCoordinator`：

1. 打开时生成 mount token。
2. 旧 sheet 未 `onDisappear` 时只记录 pending 请求。
3. 旧 sheet 消失后校验 token/session/generation。
4. 校验通过才打开新 sheet。
5. 页面销毁时清空 pending 请求。
6. 连续点击同一入口不能创建两个 sheet。

不要用多个无归属布尔值竞争控制 bindSheet。

## 8. 实施阶段

### 阶段 0：基线

1. 读取 `AGENTS.md`、`CURRENT.md`、`QUEUE.md`。
2. 运行 `scripts/sync_workspace.sh status`。
3. 记录其他 session 的 dirty files。
4. 运行当前构建门禁。
5. 不改代码，不制造空提交。

### 阶段 1：Profile、policy、store

新增：

- `SshProxyProfilePolicy.ets`
- `SshProxyProfileStore.ets`
- `SshForwardingProfileStore.ets`
- 对应 ArkTS 测试

步骤：

1. 实现第 5、6 节 schema。
2. 使用 SSH 专属 Preferences/RDB namespace。
3. 旧单跳字段 additive 映射为 `hops[0]`。
4. 不删除或回写旧字段。
5. 未知 schema 只读，不能覆盖。
6. secret 字段出现时拒绝序列化。

提交：

`feat(ssh): add proxy and forwarding profiles`

### 阶段 2：代理 UI

新增代理编辑组件，最小修改 `SshAddFlow.ets`。

步骤：

1. 实现连接方式选择。
2. 实现 HTTP/SOCKS 表单。
3. 实现一至三跳列表和编辑。
4. 实现外部 FRP TCP endpoint 表单。
5. 手机保持单 sheet 内部步骤。
6. Pad/PC 使用宽双栏。
7. 保存前执行 policy。

提交：

`feat(ssh-ui): add unified proxy route editor`

### 阶段 3：代理连接接线与 Native 加固

步骤：

1. Profile 映射为现有 `SshRoute` handoff。
2. 连接前通过 secret broker 收集代理/逐跳凭据。
3. 复用 HTTP CONNECT、SOCKS5 和 direct-tcpip 实现。
4. 补逐跳错误上下文。
5. 补 generation 校验和反向资源释放。
6. 重连时重新建立完整 route。
7. 外部 FRP endpoint 只走普通 TCP SSH。

提交：

`fix(ssh-native): harden proxy routes and multi-hop lifecycle`

### 阶段 4：Forwarding Controller

新增：

- `SshForwardingController.ets`
- `SshForwardingRuntimeStore.ets`

步骤：

1. 封装 configure/start/stop/list/snapshot。
2. start 要求 owner session 为 Ready。
3. runtime 绑定 session/channel/generation。
4. stop 幂等。
5. SSH 断线立即清理 listener 和连接。
6. 仅 `onSessionReady` profile 在重连后恢复。
7. stale callback 丢弃并释放 Native runtime。
8. 关闭 feature flag 只停止 forwarding，不关闭 SSH session。

提交：

`feat(ssh): add generation-owned forwarding controller`

### 阶段 5：Forwarding UI

步骤：

1. 增加终端“隧道”入口。
2. 实现 local/remote/dynamic 表单。
3. 默认 loopback。
4. 实现启动、停止、复制、删除。
5. 显示实际监听地址、连接数、流量和错误。
6. 页面关闭只 detach UI。
7. session 关闭才停止 runtime。

提交：

`feat(ssh-ui): add forwarding workspace`

### 阶段 6：真实端点测试

新增 `tests/ssh_endpoints/**`，覆盖：

- HTTP CONNECT。
- SOCKS5。
- 一、二、三跳 ProxyJump。
- 密码、公钥、keyboard-interactive。
- 每个 hop host-key mismatch。
- 外部 FRP TCP 映射 endpoint。
- 外部 frpc visitor 提供的 TCP endpoint。
- Local forwarding。
- Remote forwarding。
- Dynamic SOCKS5 CONNECT。
- IPv4、IPv6、域名。
- 端口占用、连接上限和 listener 失败。
- SSH 断线、重连和 stale callback。
- 八 session 并发。

提交：

`test(ssh): add proxy and forwarding endpoint matrix`

### 阶段 7：设备与回归验收

Phone、Pad、PC/2in1 必测：

- 代理设置保存和再次编辑。
- 三跳增删、排序和错误显示。
- 隧道 sheet 打开、关闭和重复打开。
- 软键盘、IME、实体键盘、鼠标。
- 横竖屏、分屏和窗口缩放。
- 前后台、锁屏和网络切换。
- Phone 原有 SSH/SFTP 交互不变。

只验证、不修改 RDP/RustDesk/VNC。

提交：

`fix(ssh-ui): finalize proxy and forwarding experience`

### 阶段 8：独立复核与交付

1. 检查全部 changed paths。
2. 检查 secret 泄漏。
3. 执行强制构建和测试。
4. 执行独立 reviewer。
5. 修复 reviewer 问题后重新验证。
6. 更新状态文档和 review receipt。
7. 缺少真实端点的能力保持 feature flag 关闭。

## 9. 验收标准

### 代理设置

- [ ] Direct 不回归。
- [ ] HTTP CONNECT 真实连接通过。
- [ ] SOCKS5 真实连接通过。
- [ ] 一至三跳 ProxyJump 通过。
- [ ] 每跳独立认证和 host-key 错误正确。
- [ ] 外部 FRP TCP endpoint 通过。
- [ ] App 不包含 FRP 控制面和 secret。
- [ ] 重连不会复用旧 route channel。

### 隧道转发

- [ ] Local forwarding 有真实数据流。
- [ ] Remote forwarding 有真实数据流。
- [ ] Dynamic forwarding 完成 SOCKS5 CONNECT。
- [ ] 监听失败能显示并清理。
- [ ] SSH 断线后 listener 和连接清理。
- [ ] stale callback 不污染新 generation。
- [ ] 页面关闭不误停后台 runtime。
- [ ] session 关闭会停止其全部 runtime。

### UI 和隔离

- [ ] Phone 保持原始交互。
- [ ] Pad/PC 使用统一宽 sheet。
- [ ] 关闭按钮、标题和内容不重叠。
- [ ] 连续开关 sheet 无竞态。
- [ ] SFTP 没有代码改动。
- [ ] RDP/RustDesk/VNC 没有代码改动。

## 10. 每个提交前的强制门禁

```sh
source scripts/macos_env.sh
hvigorw --mode module -p module=entry -p product=default default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon
hvigorw --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --no-daemon
```

同时执行：

- `git diff --check`
- SSH ArkTS 定向测试
- SSH Native 定向测试
- Light 合规门
- `git diff --cached --name-only`

任何失败都不能写成完成。

当前已知 blocker：

- `ohosTest@OhosTestCompileArkTS` 注册错误 `00306054`。
- Light 合规基线存在 `NOASSERTION`。
- 真实 ProxyJump、forwarding 和外部 FRP endpoint 环境尚未完整提供。

## 11. Sol 模型执行纪律

每次只做一个阶段：

1. 先读该阶段指定文件。
2. 先检查工作树和其他 session 修改。
3. 只改允许范围。
4. 先写测试，再做接线。
5. 不重写已有 Native 数据链路。
6. 不修改 SFTP 和其他协议。
7. 不创建第二套 session manager/native facade。
8. 不保存密码或代理 secret。
9. 不把外部 FRP endpoint 描述成 App 内置 FRP。
10. 测试、构建或端点缺失时停止并报告 blocker。
11. 只精确暂存本阶段文件。
12. 一个阶段一个提交，验收后再进入下一阶段。
