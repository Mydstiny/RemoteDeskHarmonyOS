# SSH 模块完备升级计划

> 文档版本：v1.0  
> 盘点日期：2026-07-24  
> 代码基线：main，commit bfae6ef30  
> 目标平台：HarmonyOS，API 23  
> 适用仓库：RemoteDeskHarmonyOS  
> 本文性质：实施计划与验收基线。本次只新增本文档，不修改业务代码。

## 1. 结论先行

当前项目已经具备“直连一台 SSH 服务器并打开一个基础 PTY Shell”的雏形，也有一套能工作的基础 SFTP、私钥工具和 ArkUI 终端界面。但它距离成熟 SSH 终端的能力边界仍有明显差距：当前实现把连接、认证、通道、输出队列、终端状态、渲染和文件传输耦合在少数全局对象中，许多关键路径只覆盖最短成功路径。

按本计划定义的产品范围和加权能力模型估算：

| 能力层 | 当前估算 | 说明 |
| --- | ---: | --- |
| 基础直连 Shell 的成功路径 | 约 60% | 可连接、认证并读写基础 PTY，但异常、代理、MFA、断线恢复能力不足 |
| 核心 SSH 客户端能力 | 约 35% | 认证、通道、终端、SFTP、安全和可靠性均存在关键缺口 |
| 成熟终端的整体 parity | 约 30%～40% | 这不是协议 RFC 覆盖率，而是面向用户功能簇的工程估算 |

如果只做 P0 和 P1，本项目可以达到“可用于日常 SSH 运维”的目标，估计覆盖 75%～85% 的成熟终端核心体验；要达到稳定发布、可迁移、可扩展的完整产品形态，还需要 P2 的转发、高级认证、算法策略、连接复用和发布硬化。

建议采用四个阶段推进：

1. P0 基础可靠性与安全底座：先消除会导致连接错误、数据丢失、凭据泄露或多会话互相影响的问题。
2. P1 核心终端体验与可用性：补齐 SSH 通道语义、VT 终端、渲染交互、SFTP 和断线恢复。
3. P2 高级 SSH 能力：补齐 forwarding、ProxyJump、agent、证书、FIDO2 等高级能力。
4. 发布硬化：做协议互操作、性能、模糊测试、安全审计、API 兼容和 API 23 真机验收。

## 2. “完全实现”的边界

“完全实现”不能简单等同于复制 OpenSSH 的全部服务器、客户端和平台集成能力。本计划将完成定义为以下产品范围：

### 2.1 必须达到的能力

- 一个 App 内可以安全地创建、并行管理和销毁多个独立 SSH Session。
- 支持域名、IPv4、IPv6、超时、连接取消、重连和前后台恢复。
- 支持直连、HTTP CONNECT、SOCKS5，随后支持 ProxyJump/Bastion。
- 支持密码、公钥、加密私钥、keyboard-interactive/MFA，并正确处理用户拒绝和服务端方法协商。
- 支持 host key 首次信任、变更告警、known_hosts 持久化、OpenSSH SHA256 指纹展示。
- 支持 PTY Shell、exec、subsystem、stdin/stdout/stderr、退出码、信号、窗口变化和多 channel。
- 终端核心正确处理常见 VT100/VT220/xterm 语义、UTF-8、宽字符、组合字符、颜色、样式、滚动、备用屏、鼠标跟踪、粘贴模式和选择复制。
- SFTP 支持目录浏览、上传下载、递归、进度、取消、断点续传、冲突处理、元数据和安全的符号链接策略。
- 输出事件具有二进制语义、有限队列、背压和序列号，不因 UI 暂时繁忙而无限占用内存或重复回放。
- 所有异常可诊断、可分类、可测试；密码、私钥口令和会话敏感数据不出现在日志中。

### 2.2 允许后置或明确不承诺的能力

以下能力可以在 P2 或产品路线另行评估，不应阻塞 P0/P1 的首发：

- OpenSSH 全量服务器端能力。
- X11 forwarding、GUI 图形协议、完整终端图形协议（例如 Kitty graphics、完整 sixel）。
- PKCS#11、GSSAPI/Kerberos、FIDO2 security key 在所有 HarmonyOS 设备上的兼容性。
- OpenSSH 的全部平台级配置文件、系统 agent、系统钥匙串兼容细节。
- 在移动端不适合的无限 scrollback、无限并发和无上限日志。

对于暂未实现的能力，UI 必须显示“不支持”或“需要后续版本”，不能静默降级为直连或错误的协议行为。

## 3. 代码审计基线

以下结论来自当前代码，而不是仅凭 UI 现象推断。实施前应把这些位置改造成单元测试和回归测试的起点。

| 代码位置 | 现状证据 | 直接影响 |
| --- | --- | --- |
| entry/src/main/cpp/ssh/ssh_adapter.cpp:132 | 使用 AF_INET 和 inet_pton | 只能处理 IPv4 字面量，域名和 IPv6 路径缺失 |
| entry/src/main/cpp/ssh/ssh_adapter.cpp:432 | 连接后固定走认证和 Shell 流程 | 没有清晰的 Session、Channel、认证方法状态机 |
| entry/src/main/cpp/ssh/ssh_adapter.cpp:559 | 鼠标处理为空实现 | 终端应用中的鼠标选择、鼠标跟踪和滚轮协议不可用 |
| entry/src/main/cpp/ssh/ssh_adapter.cpp:615 | SFTP 是同步基础实现 | 大文件、递归、取消、进度和错误恢复不足 |
| entry/src/main/cpp/ssh/ssh_adapter.cpp:1106 | reader loop 直接推动输出 | 输出生命周期、背压、关闭竞态和多 channel 语义不清晰 |
| entry/src/main/cpp/ssh/ssh_adapter.cpp:1206 | SSH adapter 以单例注册 | 多窗口或多连接可能共享状态、互相覆盖或互相关闭 |
| entry/src/main/cpp/ssh/ssh_algorithm_prefs.h:21 | 算法偏好硬编码 | 无法按服务器协商结果、策略和安全等级配置 |
| entry/src/main/cpp/ssh/ssh_key_tool.cpp:396 | 指纹从 DER 数据路径计算 | 可能与 OpenSSH 的 SSH public-key blob 指纹不一致 |
| entry/src/main/cpp/extensions/extension_loader_napi.cpp:1042 | 主要解析 gateway 字段 | proxy 配置模型没有落到实际代理握手 |
| entry/src/main/cpp/extensions/extension_loader_napi.cpp:2843 | ThreadSafeFunction 使用无限队列 | 高速输出时有内存增长和 UI 延迟风险 |
| entry/src/main/ets/pages/SshTerminal.ets:840 | proxy 信息写入 gateway 字段 | 用户配置的代理可能最终仍然直连 |
| entry/src/main/ets/pages/SshTerminal.ets:873 | 输出截断到 50 KB | 大输出被静默丢失，且截断策略不具备协议语义 |
| entry/src/main/ets/components/NativeTerminalRenderer.ets:207 | 截断后全量重放 | 重绘成本随历史输出增长，且可能重复显示 |
| entry/src/main/ets/components/NativeTerminalRenderer.ets:447 | 绘制属性不完整 | 颜色、样式、字体度量、选择和高 DPI 行为不完整 |
| rustdesk_ffi/src/terminal_core/parser.rs:67 | 多种终端模式被忽略 | bracketed paste、mouse tracking、OSC/DCS/APC、auto-wrap、keypad、tab stops 等行为缺失 |
| rustdesk_ffi/src/terminal_core/terminal.rs:231 | 具备基础滚动和 viewport 核心 | 可以增量演进，但需要补齐状态模型、Unicode 和渲染快照测试 |

当前已有的私钥解析、基础密码/公钥认证、PTY 读写和基础文件操作应保留为兼容入口，但不能继续让它们承担所有连接状态。

## 4. 对标来源和学习边界

本计划参考的是成熟项目的公开实现、测试和协议边界，实施时必须遵守各项目许可证，不能直接复制不兼容代码。

| 项目 | 上游来源 | 重点参考 |
| --- | --- | --- |
| OpenSSH portable | https://github.com/openssh/openssh-portable | known_hosts、host key 指纹、认证方法、channel、转发、重连语义、算法和安全默认值 |
| libssh2 | https://github.com/libssh2/libssh2 | 嵌入式 SSH 客户端 API、session/channel/SFTP 状态机、非阻塞 I/O 和错误码 |
| xterm.js | https://github.com/xtermjs/xterm.js | VT parser、终端模式、输入编码、选择、搜索、鼠标和 bracketed paste |
| ConnectBot | https://github.com/connectbot/connectbot | 移动端多会话、键盘、前后台和 Android/Harmony 类设备交互设计 |
| Tabby | https://github.com/Eugeny/tabby | 多连接配置、ProxyJump、SFTP、搜索、转发和产品级会话管理 |
| Alacritty | https://github.com/alacritty/alacritty | 终端状态机、渲染、键盘/鼠标协议、性能和快照测试思路 |
| PuTTY | https://www.chiark.greenend.org.uk/~sgtatham/putty/ | 兼容性、主机密钥策略、代理和跨平台终端行为 |

对标原则：

- 以协议语义、错误处理、测试方式和用户可观察行为为准，不以某个项目的 UI 细节为准。
- 先实现 SSH client 的稳定子集，再按能力开关扩展；不通过“忽略服务端消息”伪装兼容。
- 每个新增能力都要有 OpenSSH server 或等价测试服务器的互操作用例。
- 在引入第三方库前做许可证、C ABI、交叉编译、线程模型、内存所有权和 HarmonyOS API 23 兼容性审查。

## 5. 鸿蒙官方约束与落地原则

以下资料以 HarmonyOS 官方文档和 OpenHarmony docs 源码为准。文档页面的版本化 URL 可能随 API 版本变动，实施时应在 API 23 版本页重新锁定链接和 SDK 头文件。

| 官方能力 | 规划用途 | 必须遵守的约束 |
| --- | --- | --- |
| Network Kit / Socket | TCP、连接超时、连接关闭和网络状态 | 不能假设退后台后 socket 永久可用；前台恢复必须检测并重建 |
| Network Kit / DNS | 域名和 IPv4/IPv6 地址解析 | API 23 支持获取全部地址以及按 IPv4/IPv6 指定解析；不要再只调用 inet_pton |
| N-API / Node-API async work | C++ 网络和文件操作异步化 | JS 线程只做参数、状态和事件派发；native worker 不触碰 ArkUI 对象 |
| N-API ThreadSafeFunction | worker 到 ArkTS 的事件通知 | 使用有限队列或自建有界队列；关闭时先停止生产、再释放 TSFN |
| TaskPool | UI 外部的可调度任务 | 适合可取消、可分段的工作；不要把不可序列化的 native session 直接当作任务参数 |
| ArkGraphics 2D / Canvas | 终端网格绘制 | 以 API 23 SDK 实际可用接口为准，缓存字体度量和绘制资源，使用脏行增量绘制 |
| 手势、触摸、鼠标、轴事件 | 选择、拖拽、滚轮、外接键鼠 | 统一转换为终端输入事件，再由终端模式决定是否发给远端 |
| Background Tasks Kit | 前后台生命周期协作 | 后台不承诺永久保持 SSH；恢复时提供重连/状态恢复，不在后台无边界耗电 |
| HUKS | 私钥、口令或密钥材料的安全存储 | 只存必要材料和引用；访问控制、删除、迁移和错误处理必须可测试 |
| Crypto Architecture Kit | 哈希、签名、密钥转换等 | 官方约束表明不支持多线程并发调用；加密操作必须串行化或集中到单一 crypto worker |
| Pasteboard | 复制和粘贴 | 读取剪贴板要有明确用户动作和隐私边界；多行粘贴需确认，并支持 bracketed paste |

官方资料入口：

- OpenHarmony docs：https://gitee.com/openharmony/docs
- Network Kit、Socket、DNS 参考：https://developer.huawei.com/consumer/cn/doc/harmonyos-references
- N-API / Node-API 参考：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides
- TaskPool 参考：https://developer.huawei.com/consumer/cn/doc/harmonyos-references
- ArkGraphics 2D、Canvas、CanvasRenderingContext2D 参考：https://developer.huawei.com/consumer/cn/doc/harmonyos-references
- 手势、触摸、鼠标、轴事件参考：https://developer.huawei.com/consumer/cn/doc/harmonyos-references
- Background Tasks Kit 参考：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides
- HUKS 和 Crypto Architecture Kit 参考：https://developer.huawei.com/consumer/cn/doc/harmonyos-references
- Pasteboard 参考：https://developer.huawei.com/consumer/cn/doc/harmonyos-references

页面入口是为了保证文档版本可追溯；实施任务中应记录具体 API 23 页面、SDK 版本和示例代码提交日期。不能因为某个新版本文档中存在接口，就默认 API 23 可用。

## 6. 目标架构

当前最重要的结构性改造是把“一个全局 adapter”改为“每个连接一个独立 session context”，并把远程字节、终端状态和 UI 绘制分层。

~~~mermaid
flowchart LR
    A["ArkTS SSH 页面"] --> B["N-API SSH Session Manager"]
    B --> C["每个连接独立的 SessionContext"]
    C --> D["Transport"]
    D --> D1["DNS / IPv4 / IPv6"]
    D --> D2["Direct / HTTP CONNECT / SOCKS5"]
    D --> E["SSH Protocol Session"]
    E --> E1["Auth State Machine"]
    E --> E2["Channel Manager"]
    E2 --> E3["Shell / Exec / Subsystem"]
    E2 --> E4["SFTP Channel"]
    C --> F["有界二进制 Event Queue"]
    F --> G["ThreadSafeFunction / ArkTS Event Bridge"]
    G --> H["Rust Terminal Core"]
    H --> I["Canvas Terminal Renderer"]
    I --> A
    J["Host Trust + HUKS"] --> E1
    K["Reconnect / Lifecycle Manager"] --> C
    L["SFTP Worker"] --> E4
    L --> G
~~~

### 6.1 线程和所有权规则

- ArkTS/UI 线程：只负责配置、用户输入、状态展示、渲染请求和事件消费。
- SSH I/O worker：每个 SessionContext 一个串行事件循环，或者由统一调度器串行轮询多个 session；不得让多个线程同时驱动同一个 libssh2/libssh session。
- SFTP worker：可以分段异步，但同一 SSH session 的协议操作必须通过 channel/session 所属的串行执行上下文。
- Rust terminal core：接收字节和输入事件，拥有终端状态；不直接访问 ArkUI。
- Renderer：只读终端快照或增量 diff，不持有 socket、私钥和 native session。
- Crypto worker：所有 Crypto Architecture Kit 调用集中串行，避免官方不支持的并发调用。
- 关闭顺序固定为：标记 Closing → 停止接受新任务 → 停止 I/O 生产 → 关闭 channel/socket → 发送最终状态事件 → 释放 TSFN → 清理密钥材料。

### 6.2 统一状态机

建议状态为：

Created → Resolving → Connecting → ProxyHandshake → SshHandshake → HostVerification → Authenticating → Ready

Ready → Reconnecting → Resolving 或 Closed  
任意状态 → Cancelling → Closed  
任意状态 → Failed（携带可恢复性和用户动作）

状态迁移必须由 native owner 串行执行，ArkTS 只能请求迁移，不能直接改写 native 状态。

## 7. 完整差距矩阵

状态含义：已具备表示有基础路径但仍需验证；部分实现表示只覆盖了最短成功路径；未实现表示当前代码没有实际能力；错误实现表示字段或接口存在但行为不符合协议。

| 功能簇 | 当前状态 | 与成熟项目差距 | 优先级 | 完成标准 |
| --- | --- | --- | --- | --- |
| 多 Session | 单例注册，状态可能共享 | 无独立生命周期和隔离 | P0 | 8 个并发 session 互不覆盖、互不关闭 |
| 域名解析 | 仅 IPv4 字面量 | 无 DNS、无地址轮换 | P0 | 域名解析所有地址，超时和错误可见 |
| IPv6 | 未实现 | 无 AF_INET6、无地址选择策略 | P0 | IPv6 literal 和 DNS AAAA 可用 |
| 代理 | 配置有 gateway，但实际直连 | HTTP CONNECT/SOCKS5 未握手 | P0 | 代理认证、超时、失败原因和 DNS 策略正确 |
| 密码/公钥 | 基础路径存在 | 方法协商、取消、加密私钥细节不足 | P0 | 与 OpenSSH 常见配置互操作 |
| keyboard-interactive | 未实现 | MFA/OTP/二次提示无法完成 | P0 | 可显示多轮 prompt，支持取消和敏感输入 |
| Host key 信任 | 有基础 trust 逻辑 | 不是完整 known_hosts，变更处理不足 | P0/P1 | 首次信任、匹配、变更阻断和删除重信任 |
| 指纹 | DER 路径可能不兼容 | 与 OpenSSH wire-format SHA256 不一致 | P0 | 给定公钥与 ssh-keygen -lf -E sha256 一致 |
| SSH Shell | 基础 PTY 存在 | 固定流程、EOF/exit/signal 不完整 | P1 | Shell 退出码、stderr、窗口变化正确 |
| exec | 未实现 | 无一次性命令通道 | P1 | stdout/stderr/exit status/timeout 可用 |
| subsystem | 未实现 | SFTP 等通道无法统一管理 | P1 | subsystem 生命周期和错误可见 |
| 多 channel | 未实现 | 一个 session 只能承载一个简化流 | P1 | shell、exec、SFTP 可按策略共存 |
| stderr | 未建模 | 可能与 stdout 混合或丢失 | P1 | 有独立流和 UI 合并策略 |
| signal | 未建模 | Ctrl-C 等不一定发到远端 | P1 | PTY 和非 PTY 语义各自正确 |
| 算法偏好 | 硬编码 | 无安全策略、无协商诊断 | P2 | 可配置、可审计、弱算法默认关闭 |
| compression/rekey | 未完整实现 | 长连接和高延迟场景不足 | P2 | 开关、阈值、重协商和回归用例 |
| 输出通道 | TSFN 无限队列 | 内存无上限、延迟不可控 | P0 | 有界、可测量、可恢复、无静默丢字节 |
| 输出格式 | 字符串和 50KB 截断 | 二进制/控制序列可能损坏 | P0/P1 | 原始 bytes 按序到 terminal core |
| 终端解析 | 基础 VT | 多种模式和 Unicode 缺失 | P1 | 通过终端 fixture 和 fuzz 回归 |
| alternate screen | 不完整 | vim、top、tmux 等体验不可靠 | P1 | 主/备用屏切换和恢复正确 |
| 鼠标跟踪 | 空实现 | TUI 鼠标、滚轮模式不可用 | P1 | SGR/UTF-8/普通鼠标模式正确 |
| bracketed paste | 未实现 | 粘贴可能误执行命令 | P1 | 多行确认和协议模式双重保护 |
| 选择/搜索 | 不完整 | 不能按单元格和屏幕语义操作 | P1 | 字符、词、行选择，增量搜索和复制 |
| 渲染 | 基础 Canvas 绘制 | 样式、字体、DPR、脏区不足 | P1 | 目标设备帧率和快照通过 |
| SFTP | 同步基础操作 | 无递归、进度、断点、元数据策略 | P1 | 大文件可取消、可恢复、错误可重试 |
| 断线恢复 | 未实现 | 网络变化和退后台导致会话丢失 | P1 | 可配置重连、去重、状态提示 |
| ProxyJump | 未实现 | 无 Bastion 链路 | P1/P2 | 跳板认证和目标 host key 语义正确 |
| port forwarding | 未实现 | 无本地/远端/动态转发 | P2 | 权限、绑定、生命周期和资源上限完整 |
| agent/证书 | 未实现 | 企业认证覆盖不足 | P2 | 能力探测、明确降级、审计 |
| HUKS | 未形成密钥生命周期 | 凭据持久化和迁移风险 | P0/P1 | 不落明文，删除和升级迁移可验证 |
| 可观测性 | 错误分散 | 无统一诊断和 telemetry | P0 | 结构化错误、阶段、耗时、队列指标 |

## 8. 分阶段实施计划

### Phase 0：基线冻结和契约设计（1～2 周）

目标是先让后续修改有可验证的边界。

任务：

1. 固定 API 23 SDK、NDK、Rust toolchain、libssh2/libssh 版本和构建命令。
2. 建立 OpenSSH 测试矩阵：密码、公钥、加密私钥、keyboard-interactive、IPv4、IPv6、不同 host key、exec、SFTP、断线。
3. 定义 N-API 接口版本和事件协议，给每条事件增加 sessionId、channelId、sequence、timestamp、kind。
4. 将现有 gateway 配置迁移为明确的 transport/proxy 配置，并保留旧字段兼容读取和迁移提示。
5. 加入 native/Rust/ArkTS 的最小测试骨架；验收命令使用 default@OhosTestCompileArkTS，不再使用旧的 default@OhosTestBuildArkTS。
6. 记录当前行为快照，尤其是现有用户配置、host trust、SFTP 路径和终端颜色，作为回滚基线。

交付物：

- SSH 事件和错误协议文档。
- OpenSSH 测试容器或可复现测试脚本。
- API 23 构建和测试说明。
- 基线测试报告和已知兼容性清单。

### P0：连接、安全、生命周期和背压（4～6 周）

#### P0-1：Session 工厂和多连接隔离

改造 entry/src/main/cpp/ssh/ssh_adapter.cpp 和 entry/src/main/cpp/extensions/extension_loader_napi.cpp：

- 移除 SSH adapter 的全局 session 状态和单例注册依赖。
- 新增 SessionManager、SessionContext、ChannelManager、SessionStateMachine。
- 每次 create 返回不可猜测的 sessionId；native 保存唯一所有权，ArkTS 只保存句柄。
- 所有回调携带 sessionId/channelId；关闭后拒绝迟到事件。
- 为 connect、authenticate、resize、write、close、reconnect、sftp 建立明确的 command queue。
- 做重复 close、超时 close、JS 页面销毁、native 异常和 TSFN 释放的竞态测试。

验收：同时打开 8 个连接，分别输出不同标记并交错关闭；无串流、死锁、崩溃和资源泄露。

#### P0-2：DNS、IPv4/IPv6 和连接策略

- 用 API 23 支持的 DNS 能力或等价的 AF_UNSPEC 地址解析替换固定 inet_pton 路径。
- 地址结果保留 family、sockaddr、主机名和解析时间，不把域名直接当 IP 使用。
- 支持 IPv4/IPv6 literal、DNS A/AAAA、IPv6 zone 场景的合法性校验。
- 建立顺序尝试或受控 Happy Eyeballs 策略；每个地址共享总超时，取消时立即关闭候选 socket。
- 区分 DNS 失败、连接拒绝、超时、TLS/SSH 握手失败和 host key 失败。
- 记录脱敏的地址族和耗时，不记录凭据。

验收：域名、IPv4、IPv6、不可达地址、解析超时和网络切换均有可重复测试。

#### P0-3：真实代理传输

新增 Transport abstraction、HttpConnectProxy、Socks5Proxy：

- direct：直接连接目标。
- HTTP CONNECT：建立 TCP 连接，发送规范 CONNECT，支持代理用户名/密码，验证响应状态和 header 结束。
- SOCKS5：支持无认证和用户名密码认证，明确 remote DNS 与 local DNS 模式。
- proxy 的连接、握手、读写、取消和超时都必须纳入 Session 状态机。
- 不再把 proxy 写入 gateway 后仍调用直连 socket。
- 对代理密码使用一次性内存和安全擦除；日志只保留 proxy 类型和失败阶段。

验收：直连、HTTP CONNECT、SOCKS5、代理认证错误、代理超时、目标 DNS 错误各自通过；抓包确认没有绕过代理。

#### P0-4：认证方法状态机和 MFA

- 首先读取服务端提供的 authentication methods，再按用户策略尝试，不能固定只走一种路径。
- 完成 password、publickey、encrypted private key 的非阻塞流程。
- 增加 keyboard-interactive 回调：事件包含 prompt 文本、echo 标志、prompt 序号和超时；ArkTS 返回答案或 cancel。
- 默认对 echo=false 的回答遮罩，禁止写入普通日志和错误对象。
- 支持多轮 prompt、OTP、跳板认证和认证失败后的最终原因。
- 统一认证取消、页面返回、应用退后台、服务端断开和重试次数。
- 限制密码和 OTP 重试，避免自动重试导致账户锁定。

验收：OpenSSH 配置 ChallengeResponseAuthentication/PAM 的密码、OTP、拒绝和超时场景；用户取消后 native 不再读写已释放的 JS callback。

#### P0-5：OpenSSH 兼容的 host key 指纹和信任

- 指纹输入必须是 SSH public-key blob：key type string 加算法参数，而不是任意 DER 编码。
- SHA256 指纹按 OpenSSH 规则编码为 base64，无错误的换行、前缀或 padding。
- 支持常见 ssh-ed25519、ecdsa-sha2-nistp256/384/521、rsa-sha2-256/512 的类型和参数解析；对不支持算法给出明确结果。
- 首次连接产生 PendingTrust 事件，用户选择一次信任、保存信任、取消。
- 已保存 key 匹配时直接通过；key 变化时阻断并展示旧/新指纹。
- 后续扩展完整 known_hosts：多 host、端口、通配符、hashed host、算法迁移和删除。
- HUKS 只用于保护需要持久化的私钥或敏感引用；host trust 数据要有版本、来源和迁移格式。

验收：本地 ssh-keygen 输出与 App 指纹逐项一致；首次信任、重复连接、host key 变化和撤销均可测试。

#### P0-6：二进制事件队列、背压和输出完整性

- 把 stdout/stderr/终端 bytes 从字符串改为 ArrayBuffer 或等价的 byte payload，禁止以 UTF-8 转换作为传输边界。
- 每个 session 使用有界队列，限制总 bytes、事件数和单批最大 bytes。
- 用 sequence 检测丢失、重复和乱序；消费者一次批量 drain，避免每个字节一个 JS 回调。
- 不采用“截断后从头全量重放”。终端核心只接收未消费区间或从明确 checkpoint 恢复。
- 队列满时优先应用协议级暂停/减小读取批次；不能静默丢掉交互输出。无法背压时进入 Overrun 状态并让用户知道。
- TSFN 使用有限 maxQueueSize 或由 native 有界队列承担背压；关闭顺序必须阻止新生产者。
- 对 SFTP 进度、状态和终端字节分别设定队列策略，不能让进度淹没终端输入。

验收：以持续输出、二进制控制序列、窗口最小化和快速切换页面压测；无无限内存增长、无重复显示、无静默丢包。

#### P0-7：统一错误、取消和敏感数据清理

- 定义 errorCode、phase、retryable、userAction、nativeCause、sessionId、channelId 的结构化错误。
- 区分 DNS、transport、proxy、ssh handshake、host trust、auth、channel、sftp、terminal、lifecycle。
- 所有超时和取消使用统一 token；取消必须可传播到 socket、worker、SFTP 和 UI。
- 密码、私钥口令、OTP、代理口令在使用后 secure zero；不在异常、trace、持久化配置和 crash 字符串中出现。
- 关闭时清理 reader、writer、channel、TSFN、临时文件和 HUKS 会话。

验收：错误 UI 可指导用户行动；内存检查、日志扫描和异常路径测试均无敏感信息。

P0 完成门槛：没有多 session 隔离、域名/IPv6、真实代理、MFA、正确指纹、有限队列和安全错误处理之前，不进入大规模终端功能开发。

### P1：协议通道、终端核心、渲染、SFTP 和恢复（8～12 周）

#### P1-1：SSH Session/Channel 语义

- 把 shell、exec、subsystem 建模为同一 Channel API 的不同类型。
- Shell：可选 PTY、term 类型、rows/columns、环境变量、shell 请求、窗口变化、EOF、close。
- Exec：命令、超时、stdout、stderr、exit status、signal、取消和远端关闭。
- Subsystem：按名称打开，SFTP 通过此路径接入，不在 adapter 中写死。
- 为 channel 设置独立 ID、状态和流量统计；支持一个 session 上按策略创建多个 channel。
- 处理 SSH_MSG_CHANNEL_WINDOW_ADJUST、EOF、CLOSE、exit-status、exit-signal 和异常序列。
- Ctrl-C、Ctrl-D、Ctrl-Z 等输入要根据 PTY/非 PTY 和终端模式决定发送字节还是 SSH signal。

验收：运行 shell、exec、SFTP 并发场景；命令返回非零码时 UI 显示正确；stderr 既不丢失也不错误地当作 stdout。

#### P1-2：bytes-to-terminal-core 管线

改造 entry/src/main/ets/pages/SshTerminal.ets、entry/src/main/ets/components/NativeTerminalRenderer.ets 和 rustdesk_ffi/src/terminal_core：

- native 只把远端原始 bytes 投递给 Rust terminal core；ArkTS 不做 50 KB 截断、字符串重编码或控制序列清洗。
- terminal core 负责解析、屏幕状态、scrollback、alternate screen、光标、选择快照和输入模式。
- 将 parser 和 terminal 的输入/输出拆成可单测的纯数据接口。
- 保留增量 diff：输出字节 → 状态变更 → 脏行/脏区 → renderer。
- 终端 core 的快照必须包含字符、宽度、组合字符、前景/背景、粗体/下划线/反显、光标和行属性。

#### P1-3：补齐 VT/xterm 常用语义

按优先级逐步实现：

1. UTF-8 解码、替换字符、宽字符、组合字符、emoji 的宽度和光标移动。
2. C0/C1、CSI、OSC、DCS、APC 的安全解析和长度上限；未支持序列要安全忽略而不破坏后续输入。
3. auto-wrap、insert mode、origin mode、cursor save/restore、tab stops、keypad/application cursor。
4. 主屏/备用屏、清屏、滚动区域、SGR 颜色和样式、默认颜色、反显。
5. bracketed paste、focus reporting、application mouse、SGR mouse、wheel 和 modifier。
6. OSC title、OSC 8 hyperlink 等非危险能力；对 OSC 52 剪贴板等高风险功能默认关闭并按用户设置启用。
7. 远端尺寸变化、DEC 私有模式恢复和异常序列 fuzz。

不能为了支持某个序列而允许远端控制本地文件、剪贴板、应用权限或导航；所有本地副作用必须有策略开关和用户授权。

#### P1-4：Canvas 渲染和交互

- 以 API 23 ArkGraphics 2D/Canvas 可用接口为基准，建立固定字体和回退字体测量。
- 采用网格单元缓存、脏行绘制和可见 viewport，不在每次输出时全量重放历史。
- 处理 DPR、旋转、窗口尺寸、字体大小、行高、列宽、光标闪烁和主题颜色。
- 对粗体、下划线、反显、256 色和 truecolor 建立颜色转换规则。
- 用 terminal core 的 cell snapshot 渲染，不让 Canvas 自己猜测控制序列含义。
- 实现鼠标/触摸选择、拖拽、滚动、惯性边界、复制、粘贴、清除选择和搜索。
- 兼容外接键盘、IME 组合输入、硬件键、功能键和 ArkUI key event。
- 选择时按 grapheme、宽字符和换行语义工作；复制到 Pasteboard 时保留合理的行和空格。

验收：shell、vim、top、htop、tmux、less、nano、git diff 等典型程序在 API 23 设备或模拟器上可操作；帧率、输入延迟和内存有指标。

#### P1-5：粘贴安全和输入编码

- 默认对多行粘贴弹出确认，展示行数和首尾摘要，不在确认前发送。
- 远端启用 bracketed paste 时使用 200/201 包裹；未启用时仍执行本地多行保护。
- 对控制字符、超长粘贴和不可见 Unicode 设定明确策略。
- 复制只取 terminal core 选择结果；不从已截断的 UI 字符串复制。
- 输入事件先经过终端模式编码器，再进入 channel，避免把 ArkUI keyCode 直接当作远端字节。

#### P1-6：SFTP 异步和可靠传输

重构 entry/src/main/cpp/ssh/ssh_adapter.cpp 中的同步 SFTP 路径，增加 SFTP service/worker：

- 目录列出、stat、mkdir、rename、remove、read、write、chmod/chown/times 等能力按权限和平台限制分组。
- 上传下载使用分块、进度、取消、限速可选项和统一超时。
- 递归操作要有遍历深度、文件数、总大小和单文件上限；拒绝路径穿越和不安全的符号链接跟随。
- 冲突策略：询问、覆盖、跳过、重命名；先写临时文件、fsync/关闭、再原子 rename（以 HarmonyOS 文件语义验证）。
- 断点续传需要远端尺寸、mtime/哈希或用户确认；不能只按相同文件名续传。
- 显示失败项并支持重试，已成功项不重复传输。
- 对远端权限、软链接、特殊文件、时间戳和大小差异进行显式提示。
- 大文件使用流式 buffer；不要把整个文件放在 ArkTS 字符串或 JS 堆。

验收：小文件、空目录、深层递归、大文件、低空间、权限拒绝、中断恢复、软链接和同名冲突全部有测试。

#### P1-7：重连、keepalive 和前后台恢复

- 定义可配置 keepalive 与 server alive 机制；对无响应区分网络断开和远端主动关闭。
- 监听网络/应用生命周期，退后台时保存 session metadata，前台时检测 socket 和连接状态。
- 使用指数退避加抖动，限制次数和总时间；不能在应用退后台持续无限重连。
- 重连前重新解析 DNS、重建代理、校验 host key、重新认证；不要复用已经失效的 channel 指针。
- 标记 session epoch；旧连接事件不得污染新连接。
- PTY 恢复策略要明确：默认重建 channel 并提示用户，不能假装远端 shell 仍保持原状态。
- SFTP 任务记录 checkpoint，重连后只恢复允许恢复的传输。

验收：飞行模式、切换 Wi-Fi/蜂窝、退后台再前台、代理断开、服务器重启等场景均能给出可理解状态并按策略恢复。

#### P1-8：ProxyJump/Bastion

- 将跳板链路抽象成 transport over established channel，而非把目标连接硬编码到 adapter。
- 每一跳独立 host key 验证、认证、超时和错误上下文。
- 支持跳板与目标使用不同凭据和 proxy 组合的配置校验。
- 为链路设置最大跳数、总超时、最大并发和取消传播。

如 P1 时间不足，先交付单跳 HTTP CONNECT/SOCKS5，ProxyJump 按 P2 feature flag 保持明确不支持。

P1 完成门槛：Shell/exec/SFTP 的核心路径和常见终端程序稳定；输出不丢不重；设备前后台与网络切换有可解释行为。

### P2：高级 SSH 能力和发布硬化（8～14 周）

#### P2-1：端口转发

- local forwarding：App 监听受控本地端口，将连接通过 SSH channel 转发。
- remote forwarding：请求服务端监听，限制绑定地址、端口范围和用户授权。
- dynamic SOCKS forwarding：把 App 作为 SOCKS5 client/server 的边界定义清楚。
- 每个 forwarding 有独立 ID、状态、连接数、流量上限、超时和关闭操作。
- 默认只绑定 loopback，移动端 UI 明确展示暴露面；禁止无意间监听所有接口。
- 所有转发在 session close、网络变化和页面销毁时可靠释放。

#### P2-2：高级身份认证

- SSH agent：优先使用应用内受控 agent channel；不直接暴露任意本地 socket。
- OpenSSH user certificate：解析 certificate key type、principals、有效期和 CA trust。
- FIDO2/security key：先做设备能力探测和交互设计，无法使用时清晰降级。
- PKCS#11、GSSAPI/Kerberos：以企业需求为依据评估，不在没有设备/服务端矩阵时承诺兼容。
- 私钥格式扩展：OpenSSH new format、PKCS#8、加密算法和错误迁移；所有格式测试对照官方工具。

#### P2-3：算法、压缩、rekey 和安全策略

- 算法列表改为策略对象：KEX、host key、cipher、MAC、compression；默认优先现代算法，弱算法显式开启。
- 把协商结果和拒绝原因显示为脱敏诊断，方便处理老旧服务器。
- 支持压缩开关、阈值和 CPU/流量权衡；不能在 UI 卡顿时同步压缩。
- 支持 rekey 计数/时间阈值和长连接回归。
- 以 libssh2/OpenSSH 的 CVE 和安全公告为输入，建立依赖升级流程。

#### P2-4：完整 known_hosts 和终端高级协议

- known_hosts 解析：多 key、host pattern、端口格式、hashed host、@cert-authority、@revoked 等按支持范围实现。
- 信任数据版本化、导入导出、删除单项、备份恢复和迁移。
- OSC 8 hyperlinks 等可安全呈现；OSC 52 剪贴板和本地通知必须有用户权限。
- 终端图形协议只在有明确需求和资源预算时实现；不把未支持数据当作可执行本地操作。

#### P2-5：性能、连接复用和发布质量

- 评估 ControlMaster/连接复用的移动端价值；如果实现，必须隔离凭据和 channel，并明确后台生命周期。
- 建立 bytes/s、输入到显示延迟、P50/P95 connect、P95 SFTP、首帧时间、内存峰值和 CPU 指标。
- 按低端设备、横竖屏、外接键盘、长时间输出、超长 scrollback、后台恢复压测。
- 完成 crash、ANR、内存泄露、线程泄露、非法输入、资源耗尽和依赖许可证审查。
- 增加灰度开关和遥测字段，但不得上传命令内容、文件内容、私钥、密码、host key 原文。

## 9. N-API 和数据模型建议

### 9.1 对外操作

建议保留旧调用的兼容包装，同时逐步迁移到以下语义清晰的接口：

- createSession(config) → sessionId
- connect(sessionId)
- authenticate(sessionId, credentialRef)
- respondAuthPrompt(sessionId, requestId, answer)
- openShell(sessionId, options) → channelId
- exec(sessionId, command, options) → channelId
- openSubsystem(sessionId, name, options) → channelId
- write(channelId, Uint8Array)
- resize(channelId, columns, rows)
- sendSignal(channelId, signal)
- closeChannel(channelId)
- closeSession(sessionId)
- reconnect(sessionId)
- sftpStart(sessionId, operation)
- sftpCancel(taskId)
- getHostTrust(sessionId)
- updateHostTrust(hostKeyId, decision)

接口名称可按现有 N-API 风格调整，但不得继续把 gateway、SSH session、terminal buffer 和 proxy 当作同一个对象。

### 9.2 事件类型

至少包括：

- session.state
- session.error
- auth.prompt
- auth.result
- hostKey.pending
- hostKey.changed
- channel.opened
- channel.stdout
- channel.stderr
- channel.exit
- channel.closed
- terminal.inputMode
- sftp.progress
- sftp.result
- reconnect.scheduled
- reconnect.result
- diagnostics.metrics

每个事件都有：

- schemaVersion
- sessionId
- channelId 或 taskId
- sequence
- monotonic timestamp
- kind
- payload

二进制 payload 不转字符串；ArkTS 只在需要展示时做编码。输出和进度事件可以批量，但必须保留序列边界。

### 9.3 配置迁移

旧配置到新配置的迁移规则：

- 旧 host/port/user/password/key 映射到 connection 和 credential。
- 旧 gateway 只作为兼容字段解析；根据其旧语义迁移为 proxy.host/port 或明确标记需要用户确认，绝不默认推断为“已代理”。
- 旧 trust/fingerprint 数据先只读迁移，验证旧格式是否为 wire-format；无法证明时标记为重新确认。
- 新字段增加 schemaVersion、transport、proxy、authMethods、hostKeyPolicy、reconnectPolicy、terminalPolicy。
- 迁移失败只影响该连接配置，不阻塞其他配置加载。

## 10. 文件级改造地图

### 10.1 Native C++

现有文件：

- entry/src/main/cpp/ssh/ssh_adapter.cpp：拆分连接、认证、channel、SFTP、reader loop；保留薄兼容层。
- entry/src/main/cpp/ssh/ssh_algorithm_prefs.h：改为可配置策略和协商结果。
- entry/src/main/cpp/ssh/ssh_key_tool.cpp：统一 key parser、wire-format fingerprint、secure cleanup。
- entry/src/main/cpp/extensions/extension_loader_napi.cpp：只做 N-API 参数转换和 manager 注册，不持有业务状态。

建议新增：

- entry/src/main/cpp/ssh/ssh_session_manager.h/.cpp
- entry/src/main/cpp/ssh/ssh_session_context.h/.cpp
- entry/src/main/cpp/ssh/ssh_state_machine.h/.cpp
- entry/src/main/cpp/ssh/ssh_transport.h/.cpp
- entry/src/main/cpp/ssh/ssh_dns_resolver.h/.cpp
- entry/src/main/cpp/ssh/ssh_proxy.h/.cpp
- entry/src/main/cpp/ssh/ssh_auth.h/.cpp
- entry/src/main/cpp/ssh/ssh_host_verifier.h/.cpp
- entry/src/main/cpp/ssh/ssh_channel_manager.h/.cpp
- entry/src/main/cpp/ssh/ssh_event_queue.h/.cpp
- entry/src/main/cpp/ssh/ssh_error.h/.cpp
- entry/src/main/cpp/ssh/sftp_worker.h/.cpp
- entry/src/main/cpp/ssh/ssh_secure_memory.h/.cpp

每个新增模块都应有相同名字的 unit test 或 mock test，避免再次把所有状态集中到 adapter。

### 10.2 Rust 终端核心

- rustdesk_ffi/src/terminal_core/parser.rs：从 byte parser、状态转换和 action 输出三层拆分。
- rustdesk_ffi/src/terminal_core/terminal.rs：补齐 cell、行属性、主/备用屏、scrollback、selection snapshot。
- 建议新增 terminal_modes.rs、unicode_width.rs、input_encoder.rs、selection.rs、snapshot.rs、parser_fuzz.rs。
- 所有状态变更使用确定性测试；同一输入 bytes 在不同批次切分下必须得到同一快照。

### 10.3 ArkTS/UI

- entry/src/main/ets/pages/SshTerminal.ets：移除 50 KB 字符串缓冲和 proxy/gateway 混用，改为 session/channel store。
- entry/src/main/ets/components/NativeTerminalRenderer.ets：改为消费 terminal snapshot/diff，加入字体、颜色、选择和输入事件层。
- 新增 SshSessionStore、SshEventBridge、TerminalInputController、TerminalSelectionController、SftpTransferStore、HostTrustDialog。
- 网络状态、前后台和重连 UI 统一由 session state 驱动，而不是由页面局部变量推断。

## 11. 测试和验收矩阵

### 11.1 Native/协议互操作

- OpenSSH 最新稳定版 server：密码、公钥、加密私钥、keyboard-interactive、OTP。
- 至少一个老版本 OpenSSH 和一个不同实现 server，验证算法和窗口行为。
- IPv4 literal、IPv6 literal、A/AAAA 域名、双栈失败回退。
- direct、HTTP CONNECT、SOCKS5 无认证和认证、remote/local DNS。
- host key 首次信任、相同 key、变化 key、不同端口、删除后重新信任。
- Shell、exec、subsystem、stderr、exit code、exit signal、window change、EOF。
- 长输出、二进制控制序列、远端快速关闭、重复关闭、连接取消。
- SFTP 小文件、大文件、递归、权限、断点、覆盖、软链接、磁盘满和中断恢复。

### 11.2 Rust terminal core

- parser 输入按 1 字节、随机 chunk、整块三种方式喂入，快照必须一致。
- VT fixture 对照 xterm.js/Alacritty 行为：颜色、光标、滚动、备用屏、tab、wrap、鼠标、粘贴。
- Unicode：ASCII、CJK、组合字符、emoji、无效 UTF-8、零宽字符。
- 资源限制：超长 CSI/OSC、超长粘贴、超长行、最大 scrollback、恶意字节流。
- cargo test、property test、fuzz、快照差异和性能基准。

### 11.3 ArkTS/UI 和 HarmonyOS API 23

- API 23 模拟器和至少一台真实设备：冷启动、旋转、横竖屏、窗口尺寸变化。
- 外接键盘、触摸、鼠标、滚轮、轴事件、IME 组合输入和功能键。
- 多行粘贴、复制、系统 Pasteboard、隐私提示和取消。
- 页面销毁、应用退后台、恢复前台、网络切换和系统回收。
- Canvas 首帧、持续输出、选择、滚动、搜索、主题和字体变化。
- default@OhosTestCompileArkTS、native unit、Rust test、集成测试全部纳入 CI。

### 11.4 安全

- 静态扫描日志和错误文本，确认无密码、OTP、私钥口令、私钥原文。
- 内存和临时文件检查，确认 secret 生命周期结束后清理。
- host key 改变必须阻断，代理必须不能绕过配置。
- 命令、远端路径、OSC 序列、SFTP 文件名和控制字符的注入测试。
- 连接数、channel 数、输出速率、SFTP 文件大小、递归深度、重连次数上限。
- 第三方依赖 CVE、许可证、编译选项、符号导出和 ABI 兼容审查。

### 11.5 性能指标建议

首发前至少建立以下目标，实际阈值在目标设备测量后冻结：

| 指标 | 建议目标 |
| --- | --- |
| 输入到终端状态更新 P95 | 不超过 50 ms |
| 普通输出到首屏刷新 P95 | 不超过 100 ms |
| 高频输出时 UI 线程阻塞 | 不超过 16 ms 单次连续阻塞 |
| 终端输出队列 | 有明确 bytes/event 上限，压测不随时间无界增长 |
| 连接成功 P50/P95 | 在本地网络和代理网络分别记录基线 |
| SFTP | 记录吞吐、CPU、峰值内存、取消响应时间 |
| 长连接 | 24 小时 keepalive/rekey/断线恢复无资源增长 |

## 12. 里程碑和工作量

以下为两名熟悉 C++/Rust/ArkTS 的工程师的粗略估算，实际以 Phase 0 的依赖审查为准：

| 里程碑 | 内容 | 估算 |
| --- | --- | ---: |
| M0 | 基线、接口、测试矩阵、API 23 构建锁定 | 1～2 周 |
| M1 | 多 session、DNS/IPv6、代理、认证、host trust、队列 | 4～6 周 |
| M2 | channel/exec/stderr/exit、terminal core 管线、Canvas 基础体验 | 5～7 周 |
| M3 | VT 兼容、输入/选择/粘贴、SFTP worker、重连恢复 | 5～7 周 |
| M4 | ProxyJump、转发、高级认证、算法策略 | 5～9 周 |
| M5 | 性能、安全、互操作、API 23 真机、灰度发布 | 3～5 周 |

并行开发时，M1 的协议底座可以和终端 core fixture 准备并行，但 M2 以前不应把旧的字符串截断管线继续扩展。整体首发 P0/P1 约 15～22 个工程师周；包含 P2 和发布硬化约 23～36 个工程师周。

## 13. 风险、取舍和缓解

| 风险 | 后果 | 缓解 |
| --- | --- | --- |
| 继续沿用单例 adapter | 多连接串流、崩溃、难以重连 | P0 先完成 session factory 和所有权测试 |
| 直接把 libssh2 调用散落到多个 worker | session/channel 数据竞态 | 一个 session 一个串行 owner，跨线程只发 command |
| 只把字符串换成更大 buffer | 仍然丢控制序列和占满内存 | byte payload、有限队列、sequence、terminal checkpoint |
| 盲目全量重写 parser | 回归面大，短期不可交付 | 用 fixture 驱动的增量实现，先保证常见 VT |
| 引入 API 26-only UI 包 | API 23 编译或运行失败 | 只使用 API 23 SDK 能力，编译期验证 |
| 并发调用 Crypto Architecture Kit | 不稳定或违反官方约束 | 单一 crypto worker/锁，独立做性能测量 |
| 后台假设 socket 永久有效 | 连接状态虚假、耗电和资源泄露 | 生命周期状态机，前台恢复重建 |
| 代理字段兼容推断错误 | 凭据泄露或绕过企业网络 | 旧字段只迁移并提示，新模型必须明确 proxy type |
| 使用非 wire-format 指纹继续存量迁移 | 用户被错误地信任或阻断 | 不能证明格式时要求重新确认 |
| 无限 scrollback 和无限并发 | 移动端 OOM/ANR | 配置上限、可视窗口、历史淘汰和资源指标 |
| 直接复制 GPL/不兼容代码 | 发布和合规风险 | 只参考行为；许可证清单和法务审查作为合并门槛 |

## 14. 发布、兼容和回滚策略

- 每个 P0/P1/P2 能力使用独立 feature flag，默认值以安全和兼容为优先。
- 新 N-API 事件保留 schemaVersion；旧页面可消费兼容事件，不能依赖新字段不存在这一事实。
- 旧连接配置只读迁移，迁移前后保留备份和版本号；迁移失败不删除原数据。
- 新 renderer 与旧 renderer 可以在测试版本中切换；terminal core 快照不依赖 renderer。
- 代理、MFA、重连和高级终端模式逐步灰度，出现崩溃/ANR/资源异常时只关闭对应开关。
- 发布前保留旧版本可读取的配置格式；删除旧 adapter 前至少经过一个版本的兼容窗口。
- 回滚不是恢复错误状态：关闭新能力后仍必须保证已建立连接能安全关闭，不遗留 socket、worker、TSFN 或敏感数据。

## 15. 最终完成定义

只有同时满足以下条件，才可以把 SSH 模块标记为“完成”：

1. P0/P1/P2 范围内的每个能力都有实现状态、feature flag、测试和文档。
2. OpenSSH server 互操作矩阵全部通过，失败项有明确的兼容声明。
3. 多 session、代理、MFA、host key、exec/SFTP、断线恢复和长输出没有已知 P0/P1 缺陷。
4. terminal core 的 chunk-invariance、Unicode、VT fixture、fuzz 和 snapshot 测试通过。
5. API 23 真机在冷启动、前后台、网络切换、外接键鼠、旋转和长时间输出下通过。
6. 性能、内存、线程、ANR、资源上限和安全日志审查通过。
7. HUKS、Pasteboard、Network Kit、TaskPool、Canvas 等鸿蒙能力只使用目标 API 支持的接口，并有对应降级策略。
8. 第三方依赖许可证、C/C++/Rust ABI、符号导出和升级记录完成审查。
9. 用户可以从错误信息知道是 DNS、代理、host key、认证、channel、SFTP 还是网络生命周期问题，并能采取下一步动作。
10. 关闭、取消、重连和页面销毁全部通过资源泄露和迟到事件测试。

在达到上述门槛前，产品文案应称为“基础 SSH 终端”或“SSH/SFTP 基础版”，不应宣称与 OpenSSH、Tabby、ConnectBot 或 xterm.js 完全等价。

## 附录 A：实施顺序清单

执行时建议严格按以下顺序推进：

1. 冻结 API 23 构建、依赖版本和现有行为快照。
2. 先写 event/error/config schema 和多 session mock 测试。
3. 完成 SessionContext、关闭顺序和 N-API 生命周期。
4. 完成 DNS/IPv6 和 direct transport，再接入 HTTP CONNECT/SOCKS5。
5. 完成认证状态机、MFA、wire-format fingerprint 和 host trust。
6. 完成 binary bounded queue，并把旧的 50 KB 截断和全量重放移除。
7. 完成 Channel Manager，加入 exec、stderr、exit、signal、resize、subsystem。
8. 把原始 bytes 接入 Rust terminal core，先建立 fixture，再扩展 VT 模式。
9. 完成 Canvas 脏区渲染、选择、搜索、输入、滚轮和多行粘贴保护。
10. 完成 SFTP worker、递归、进度、取消、冲突和断点续传。
11. 完成 keepalive、前后台恢复、重连和 ProxyJump。
12. 按需求实现转发、高级认证、算法策略和连接复用。
13. 做互操作、fuzz、性能、安全、真机和灰度回归，满足最终完成定义。

## 附录 B：每个 PR 的合并门槛

- 说明影响的状态、线程、所有权和资源上限。
- 添加至少一个失败路径测试，而不只添加成功路径测试。
- 不把密码、私钥、OTP、命令内容和远端文件内容写入普通日志。
- 不在 ArkTS 线程执行阻塞网络、SFTP 或大块解析。
- 不引入 API 23 不支持的接口或依赖。
- 更新事件 schema、配置迁移、兼容说明和回滚方式。
- 通过 native/Rust/ArkTS 对应测试，并在需要时附 OpenSSH 互操作结果。

