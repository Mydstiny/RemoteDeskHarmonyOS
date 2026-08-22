# SSH 工作台升级执行账本

> 状态：`ACTIVE_M8_M9` / `NOT_COMPLETE`
> 权威计划：`docs/codex/plans/2026-08-19-ssh-termius-harmonyos7-api26-workbench-plan.md`
> 建立日期：2026-08-19
> 当前工作树：`codex/moonlight-complete-upgrade` / `66db169f`（M0–M9 SSH 增量保留；workbench flag 已增加协议身份门禁，API23 PC 已补 SFTP 下载暂停/继续/取消/重试闭环和短窗口操作区修复，会话日志与广播输入均受默认关闭的独立高风险 flag 约束，日志追加采用重启安全的不可变 chunk 增量提交且不再深拷贝完整日志，页面日志投影不再携带持久记录正文，SSH/SFTP 诊断不再记录 host 标识、远端路径或原始异常消息，平台异常只记录有限数值错误码，后台常驻通知只展示连接/受限数量，日志导出补齐确认和异步身份 fence，大日志搜索改为可取消的分片调度，命令完成通知增加默认关闭的独立用户设置并保留并发会话通知，多窗格 xterm 安全模式按 host/session/generation 隔离且未知状态 fail closed，广播刷新不再静默替换显式目标或跨重连保留旧选择，WebMessagePort 双端序号严格连续；API26 工具链和最终实机矩阵仍待外部条件）
> 当前产品基线：HarmonyOS 6.1 / API 23
> API 26 状态：本机未安装；任何 API 26-only import 均禁止进入产品代码

## 1. 账本用途

本文件记录 SSH 工作台 S0–M9 的范围、复用点、非回归契约、设备证据、构建 receipt 和审查结论。它不替代产品计划，也不把全 App UI 升级并入 SSH 实施。

执行纪律：

1. SSH 连接、认证、Host Key、SFTP、转发和终端渲染已有实现必须复用；没有独立缺陷证据时不得重写。
2. 新工作区的持久快照不保存密码、私钥、MFA、终端输出、native handle 或 ArkWeb 对象。
3. API 26 SDK 未落地前，只实现纯策略、实体、Controller 和当前 API 可表达的 UI；新 API 名称不能靠猜测落入产品代码。
4. 每个阶段最多一次主审和一次针对修复的复核；不因上下文压缩重复派发审查。
5. 全计划最多创建两个审查智能体；只允许 `gpt-5.6-sol`、`medium`，后续阶段复用相同 reviewer。
6. HDC 只在沙箱外运行。模拟器用于日常 UI 回归，最终完成仍以用户实机验收为准。

## 2A. 最新执行指针（2026-08-22）

- `66db169f` 修复 SSH 持续后台任务通知把 host 标签、以及标签为空时的用户名/IP/端口地址直接显示在系统通知的问题。通知内容策略现在只接收运行数和受限数，展示连接/受限数量与通用状态；后台任务 Map、会话快照、WantAgent 恢复参数、持续任务申请/停止和多会话聚合均保持原逻辑。策略测试锁定运行/受限组合文案不含主机身份或远端路径。
- `6c5126dc` 收敛 SSH 页面、工作区 RDB、本机文件选择、PiP 和后台任务的异常诊断边界：hilog 不再拼接原始异常对象或 message，只从对象读取有限数值 `code`，无有效数值时写入固定 `unknown`。用户可见的连接/文件错误信息保持既有行为，不改变连接、窗口、通知、文件或恢复控制流；策略用例使用带私有 host、远端路径和 password 字段的异常对象，锁定这些字段不会进入诊断输出。
- `0989af9d` 修复 SSH 终端、标签、xterm、转发及双 SSH SFTP 诊断直接写入 host 标识和远端源/目标路径的问题：hilog 只保留本地 batch/task、session/generation、阶段、结果类别、偏移和字节数；端点诊断只输出 `local/ssh` 类型，远程复制异常不再拼接可能带路径的原始异常字符串。连接、身份 fence、任务状态和传输路径本身未改动。
- `1d50f847` 修复 M6 单行日志追加仍对整个持久文档做多轮 JSON 深拷贝和逐 chunk 正文序列化的问题：策略追加只复制顶层数组与逻辑尾 chunk，未变化 chunk/record 保持引用；Store 追加直接提交已归一化候选，并凭不可变 chunk ID 跳过缓存行的序列化。索引仍是先写候选数据、后切换可见性的提交边界，旧 ID 碰撞会 fail closed，原有索引失败后重启恢复用例继续覆盖一致性。
- `cd22f921` 修复 M6 日志 Sheet 打开时每次缓冲输出刷新都把完整持久日志复制进 ArkUI `@State` 的问题：Store 新增只含设置与 chunk 元数据的页面快照，记录正文继续留在加密 Store 内；设置开关使用独立浅快照。完整 snapshot、分片搜索、书签、导出和持久化路径不变，回归用例证明页面快照无记录正文但 Store 搜索与完整快照仍可读取记录。
- `7246f498` 修复 M6 日志 chunk 先覆盖旧行、后写索引导致失败提交在重启后复活的问题：逻辑尾 chunk 的每次更新都写入新 ID，旧索引继续指向旧密文；只有新索引提交成功才删除旧行及对应序列化/密文缓存。Store 测试增加索引写失败后的全新实例恢复，证明未提交记录不会被旧索引重新载入。
- `903eb5b1` 修复 M6 多会话命令完成通知复用固定 ID 的问题：每个满足 opt-in 和时长/失败门禁的完成事件从 1024 个有界 ID 环中取得下一个值，避免正常并发完成时后一条通知覆盖前一条，同时不引入无界 ID。纯策略用例覆盖连续分配、边界回绕和非有限输入。
- `490e11af` 修复 M6/M7 多窗格安全模式仍依赖当前页面全局状态的问题：每个 xterm 文档在完成 VT 写入后通过稀疏 JS proxy 上报 mouse/application cursor/application keypad/alternate-buffer 状态，ArkTS 侧同时校验 WebView 生命周期、surface identity、host、sessionId 与 generation；未知、过期或跨会话遥测一律不作为安全证据。广播目标增加 `safetyKnown` fail-closed 原因，会话日志和命令历史也只在精确身份的安全快照存在且非 raw/备用屏幕时采集。
- `81180347` 修复 M6 命令完成通知缺少独立 opt-in 的问题：加密的生产力设置增加默认 `false` 的 `completionNotificationEnabled`，旧 schema 中字段缺失时确定降级为关闭；生产力 Sheet 提供独立“命令完成提醒”开关，页面与 `SshNotificationService` 两层均检查该值。仅开启 Shell integration 不再隐式发布长命令或失败命令通知，本地补全设置保持独立语义。
- `a5c3dc9e` 修复 M6 大日志搜索在 ArkUI 线程同步线性扫描的问题：策略层新增有界游标，每次只扫描固定工作量；Store 通过零延迟调度在切片间让出事件循环；页面增加 120ms 输入防抖及 host/page/binding/flag/Sheet 可见性 fence，关闭 Sheet、切换 owner、页面退出或 rollout 关闭都会取消旧请求。同步搜索与分片搜索复用同一状态机，纯策略用例锁定预算为 1 时仍可推进、结果等价以及非法 identity 不会退化成无过滤搜索。
- `5fbdc1ec` 补齐 M6 日志导出的高风险确认与异步 fence：导出前明确提示文件将离开应用加密存储并要求用户确认，确认弹窗和系统文件选择器返回后都重新校验 host、页面 generation、SSH binding generation、日志双 flag、store ready 与 closing 状态；任一条件变化即取消，避免把切换前主机或 rollout 回退前捕获的快照写到用户文件。
- `282492e0` 为 M6 会话日志补齐独立 `sshSessionLogs` 发布门禁，默认关闭且不能被持久化的 `settings.enabled=true` 绕过；入口、启停/暂停、搜索、书签、导出与实际 input/output capture 均重新校验双 flag。运行中关闭 flag 会关闭 Sheet、取消 flush timer 并丢弃尚未落盘的输入/输出/命令缓冲，导出在系统 picker 返回后也再次校验，避免 rollout 回退期间继续写出先前捕获的内容。
- `5fd45827` 为 M7 广播输入增加独立发布门禁 `sshBroadcastInput`，默认关闭且不能继承更宽泛的 `sshWorkbenchV2`；生产力 Sheet 默认隐藏入口，页面打开、目标刷新、确认前后发送均重新校验双 flag，运行中关闭独立 flag 会立即关闭广播面板并清空目标、文本与安全状态。纯策略测试锁定只有工作台已就绪且独立 flag 明确开启时才可用；未新增面向普通用户的开关，等待安全审查和设备矩阵后再决定放量。
- `24377a51` 收紧 M8 WebMessagePort 双端序号完整性：ArkTS 状态机与 xterm 网页端现在都只接受正整数 generation/sequence、非负整数 ACK，并要求握手 `sequence=1/ack=0`、后续入站序号严格连续；向前跳号不再被当成合法新帧执行后续 input/resize。纯策略测试覆盖小数计数器和 forward gap，通道 flag 仍默认关闭。
- `0575bb18` 进一步把 M7 广播选择绑定到前后两次刷新中相同的 `sessionId + generation`：即使目标在确认弹窗期间断开并已重连为同一个 host，只要 native 会话或 generation 变化就立即移出选择，新 owner 必须由用户重新显式勾选；策略测试锁定该快速重连竞态。
- `514be272` 修复 M7 广播输入的目标漂移：广播面板首次打开时仍只预选当前 SSH 会话；用户显式选择的目标若在确认前断开、进入鉴权/raw/全屏等不安全状态，发送前刷新只移除该目标，不会把当前会话静默补入并接收原本未发给它的输入。纯策略测试锁定首次预选、显式空选择、失效目标不替换及有效目标去重；本轮只声明源码策略和构建证据，未在 HDC/真机上冒充完成广播 UI 矩阵。
- `4a9b0923` 修复 Pad/PC 短自由窗口 SFTP 双栏布局把底部传输操作挤出可视区的问题：宽裕窗口仍由现有 `layoutWeight` 自动扩展，只把工作区最小高度从空闲 300vp 收敛为统一 150vp。策略测试锁定空闲、传输中、待恢复三态均保留 footer；API23 PC 同一 SSH 窗口底边 y=1048 下，“传输方向”从修复前 y=957 移到 y=768，“选择文件并上传/下载到本机”完整位于 y=805–881。
- API23 PC 回环 SFTP 下载完成真实生命周期闭环：256MB 文件从“下载中 1%”进入“已暂停 12% · 33.3MB/256.0MB”，继续后推进到 14%，取消后显示 partial 已保留和“重试传输”；重新授权并确认目标替换后从保留偏移恢复到 16%，最终显示“已保存 268435456 字节”，刷新本机端点后目标条目为 256.0MB。该证据覆盖 PC/API23 下载侧；上传侧、Phone、物理设备和 API26 仍不冒充已完成矩阵。
- `2d23d9c7` 补齐 M0 非 SSH 隔离契约：`SshWorkspacePlatformFacts` 显式携带协议身份，只有规范化后的 `ssh` 才能消费 `sshWorkbenchV2`；即使 API26、DynamicLayout、ContainerReader、UI Design Kit、多窗口和键盘能力声明全部为真，RDP/VNC/RustDesk/Moonlight 仍强制返回 workbench 关闭、静态布局、纯色 chrome、无 detached window/SSH shortcut。既有 `SshWorkspacePolicy.test` 增加四协议 fail-closed 用例，无共享测试注册改动。
- `60602d651` 将手机 SSH 顶栏的语言、SFTP 和隧道操作收敛为官方 ArkUI `bindPopup` 二级工具菜单：手机/手机横屏使用 40vp 更多按钮，Pad/PC 保留直接操作；未连接时隐藏依赖会话的 SFTP/隧道项。Popup 动作沿用既有 locale Dialog、SFTP Sheet 和 forwarding Sheet，并在延迟关闭后重新校验页面 generation、当前 host 和连接状态。API23 Phone HDC 已重新采证：Host Key 确认、公钥鉴权成功后进入终端，更多菜单显示三项且语言入口可打开既有“SSH 会话地区语言”弹层；临时端点与 reverse port 在采证后清理。
- M8 WebMessagePort 已完成 API 23 兼容双栈的生产边界：版本/会话/generation/端口实例 fence、严格 JSON 类型、超前 ACK 拒绝、UTF-8 字节预算、控制帧优先且线上序号单调；生产 flag 仍默认关闭，ArrayBuffer 批量等待 API 26 SDK/真机证据。
- M9 SSH 认证后窗口 handoff 已补齐多标签语义：交接只移除已经转移的 host，源页保留其他 SSH 标签并切换到下一个会话；没有剩余标签才返回源页。目标窗口仍复用现有 `RemoteSessionWindowCoordinator`，不改变密码/Key/KBI/MFA/Host Key 流程。
- M9 PC 响应式复验已修复 SSH 主机添加流固定 900vp 导致的 Sheet 溢出：`2d1f06d6` 改为跟随父 Sheet 宽度，PC 模拟器布局树确认代理选项和“下一步”均在可视区域内。
- `9d0a29497` 补齐独立 SSH 窗口的系统前台恢复：目标 Ability `onForeground` 通过现有窗口协调器提升目标窗口，避免回到桌面/任务栏后焦点落回主窗口。精确 `default@OhosTestCompileArkTS` 与 `assembleHap` 均已通过；`ohosTest@OhosTestCompileArkTS` 仍受环境中未注册的 `00306054` 任务阻塞。
- `139a97d3` 将 native recovery 的 generation 变化即时传递到 page/tab/callback fence：旧 callback 只触发受保护的下一轮同步，不再把新 generation 的输出永久丢入旧 detached 路径；TabStore generation 替换的 startup fence 也有回归测试。双构建通过，API23 PC 模拟器重新安装后 EntryAbility 启动 smoke 通过。
- `e8bf366a` 将 SSH 工作区布局引擎接入 capability policy：运行时只读取稳定的 `deviceInfo.sdkApiVersion`，API26/新 UI 声明必须由显式 SDK/设备 adapter 提供；在 adapter 缺失时继续使用静态布局，并以策略测试锁定“版本号 alone 不升级”的 fail-closed 行为。
- `d00511e55` 修复 PC/API23 独立窗口内转发 Sheet 的输入焦点竞争：窗口出现后终端隐藏焦点锚点不再抢占监听地址/端口输入框；SSH-only 双构建与 HDC 安装 smoke 已通过。
- 2026-08-20 在 PC/API23 模拟器完成一次真实回环互操作：产品 ED25519 key + Host Key 指纹确认后才创建 `RemoteSessionAbility`；sshd 日志确认两次 `Accepted publickey`；终端输入/输出、SFTP 47 项列表、远程复制、本地授权后上传、本地下载到系统文件选择器、既有目标文件拒绝、关闭 SFTP 后终端继续输入均已采集。SSH 转发规则实际启动后，通过 HDC `rport` 将主机 payload 送入监听器，UI 流量从 `0 B` 增长到 `29/35 B`，停止后状态回到已停止；测试 sshd 与 HDC 映射已清理。
- 同一回归还验证了窗口生命周期：鉴权前仍停留在 HostList，鉴权成功后才出现独立窗口；终端 `echo SSH_WINDOW_OK` 回显正常；系统标题栏最大化、F11 进入/退出沉浸全屏均恢复稳定；标题栏拖到左边缘由 HarmonyOS WMS 进入左右分屏。此前 HDC 任务栏/WMS 证据已证明主窗口与两个独立 SSH 窗口可并存并可切换焦点。
- 2026-08-20 追加 API23 PC 回环复验：Host Key 已验证后继续原有 ED25519 公钥鉴权，sshd 日志再次确认 `Accepted publickey`；HDC 键盘输入 `echo SSH_API23_E2E_OK` 回显成功；启用标准 `internal-sftp` 后 SFTP 目录读取成功（47 项）；独立窗口最小化时主窗口仍在前台，系统最近任务同时展示 SSH 窗口与 HostList，恢复 SSH 窗口后 `RemoteSessionAbility` 回到前台且终端提示符和连接仍在。临时 sshd、密钥和 HDC 映射均已清理。
- 2026-08-20 追加 API23 PC 密码鉴权失败回归：故意使用错误密码，保留既有 Host Key 确认和原生认证顺序；sshd 记录 `Failed password`，应用日志记录 `sessionId=-31` 与 `independent SSH carrier released after authentication failure`。HDC 层级和截图确认主页面回到 `连接失败 (code=-31)`，提供“重试/返回”，没有创建 `RemoteSessionAbility`，系统任务仅保留主 `EntryAbility`；临时 sshd、密钥目录和 HDC 映射已清理。
- 2026-08-20 追加 API23 Phone SSH 入口回归：主机列表打开“添加远程主机”后，协议选择包含 SSH，进入 SSH 表单可见名称、地址、端口、用户名和路由入口；未提交临时数据，系统返回后回到主机列表。当前证据为 `/private/tmp/ssh-phone-current-api23.json`（`44a37cf179ac72d3fea1c7dc1ffc10ac60b39f6c2e3deab6cdca8b39bad5af2c`）、`/private/tmp/ssh-phone-current-api23.png`（`1c2fdcff59ec30c0da9c954fac3d987015d76ba123d608735e6b6cc527b82664`）以及返回后的 `/private/tmp/ssh-phone-after-back-api23.json`（`5c0eb16f4e0d1d62de1c683ea8d14619e73ce448257750aa5a1087c8e607e086`）、`/private/tmp/ssh-phone-after-back-api23.png`（`1ba42c8347068d9b2288f1f6df401791baf4c6bb1f194581cb4d2ddf25a78c37`）。
- 2026-08-20 追加 API24 Phone 密码鉴权成功回归：通过 HDC `rport` 将临时 Paramiko 密码服务映射到 `127.0.0.1:22222`，在“添加 SSH 主机”第二步选择“密码登录”并提交 `codex-test`，先显示原有“首次连接 SSH 主机”指纹确认，再由服务端记录 `AUTH username='codex-test' password='codex-window-e2e '`，随后进入已连接终端并显示 `RemoteDesktop authenticated-window E2E server`/`codex-test$`。终端布局证据为 `/private/tmp/ssh-password-terminal.json`（`dba1b1c9e0554b369bc8b3736691c0ba3374fd6d6964e05435c107689c256bef`），截图为 `/private/tmp/ssh-password-terminal.png`（`dc4ce048542b53a790bb8e5245b22ee6af28d4faf60bb2cd6fcb7a771f1637ff`）；临时服务与本轮新增 `rport` 已停止/移除。
- 仍未宣称完成：API 26 SDK/目标设备、物理设备验收、SFTP 上传侧及 Phone/物理设备/API26 的暂停/恢复/取消/重试余下矩阵、后台/PiP、API26 下的沉浸/分屏差异、密码/KBI/MFA 成功/取消/失败全矩阵以及多主机/全协议并行矩阵。
- 2026-08-20 曾尝试把 SSH 源策略套件接入 `entry/ohosTest` 设备 runner；该跨目录接线使 `onDeviceTest` 编译错误从基线 260 增至 337，已由 `3f3fd4da` 精确回退。当前 runner 基线仍受既有非 SSH 测试源错误阻塞，因此不宣称任何 SSH Hypium 设备通过。
- 同日 API23/24 本地 SDK 之外未发现可验证的 API26 SDK；两个 HDC 守护进程探测均无响应，设备 UI 复验保持 `DEVICE_PENDING`，不通过重启守护进程或未证实 API 名称绕过门禁。

## 2. 当前工作树隔离

建立本账本时，活动分支仍是尚未闭环的 Moonlight 任务分支。工作区门禁禁止切分支、stash、reset 或覆盖现有改动。因此：

- SSH 增量只创建或修改下述 SSH allowlist 内文件。
- 现有 Moonlight、云同步、诊断、RDP、RustDesk、VNC 变更不查看 diff、不修改、不暂存、不纳入 SSH 提交。
- 在当前任务分支闭环前，不创建声称独立的 SSH 分支；提交必须使用精确 pathspec，避免带入并行改动。
- 如果共享注册文件不可避免，只做可机械核对的 SSH 测试注册，并记录修改前后的测试总数。

建立时明确排除的并行脏路径：

```text
docs/superpowers/plans/2026-08-04-diagnostic-log-export.md
entry/src/main/ets/components/DiagnosticCaptureSettingsSheet.ets
entry/src/main/ets/pages/HostListPage.ets
entry/src/main/ets/pages/VncSettingsPage.ets
entry/src/main/ets/services/DiagnosticCaptureRuntime.ets
entry/src/test/SshSessionStore.test.ets
```

其中 `SshSessionStore.test.ets` 虽属于 SSH，但在建立账本时已有非本任务改动；M0 不在该文件叠加修改，新契约使用独立测试文件。

## 3. SSH 文件 allowlist

### 3.1 默认可修改

```text
docs/codex/plans/2026-08-19-ssh-*.md
entry/src/main/ets/pages/SshTerminal.ets
entry/src/main/ets/pages/SshWorkspacePage.ets
entry/src/main/ets/components/Ssh*.ets
entry/src/main/ets/components/ssh/**
entry/src/main/ets/services/Ssh*.ets
entry/src/main/ets/services/ssh/**
entry/src/main/ets/napi/Ssh*.ets
entry/src/main/resources/rawfile/ssh-terminal/**
entry/src/main/cpp/ssh/**
entry/src/main/cpp/terminal/ssh_terminal_*
entry/src/main/cpp/test/ssh_*
entry/src/test/Ssh*.test.ets
entry/src/ohosTest/ets/test/Ssh*.test.ets
```

### 3.2 条件共享文件

| 文件 | 允许原因 | 额外门禁 |
|---|---|---|
| `entry/src/test/List.test.ets` | 注册新的 SSH 纯策略测试 | 静态核对 import、调用和实际 `it()` 数量 |
| `entry/src/ohosTest/ets/test/List.test.ets` | 注册必要的 SSH 设备测试 | focused count 与实际注册数一致 |
| `entry/src/main/resources/base/profile/main_pages.json` | 仅在引入独立 SSH Workspace Page 时注册页面 | 旧 `SshTerminal` 路由仍可用 |
| `entry/src/main/ets/entryability/EntryAbility.ets` | 仅通知、系统窗口或 API 26 能力确实要求 | 非 SSH 启动和窗口 smoke |
| `entry/src/main/module.json5` | 仅新增平台权限/Ability 时 | 权限最小化和全协议启动 smoke |
| build profile / SDK 配置 | 仅 SSH-U0 独立工具链提交 | 全仓双 Hvigor 门禁和兼容决策 |

### 3.3 禁止顺手修改

Moonlight、RDP、RustDesk、VNC 页面和协议服务、HostList 全局视觉、全 App Theme/Navigation、云同步 schema，以及任何与 SSH 工作台无直接依赖的诊断能力均不在本计划范围。

## 4. 已有实现复用矩阵

| 能力 | 当前单一实现 | 本计划处理方式 | 禁止事项 |
|---|---|---|---|
| native 连接与 PTY | `cpp/ssh/ssh_adapter.*`、`ssh_session_manager.*` | 原样复用，通过既有 facade 调用 | 新建第二套 transport/session manager |
| 密码/Key/KBI/MFA | native auth policy、prompt broker、`SshPreflightService` | 保留原鉴权顺序和错误语义 | 为新窗口绕过或提前完成鉴权 |
| Host Key 与逐跳预检 | `SshPreflightService`、native route/auth policy | 原样复用 | UI 自动接受变化或吞掉逐跳失败 |
| 代理与 ProxyJump | `SshProxy*` 服务、native route policy | 工作台只展示/调用 adapter | 复制 proxy store 或重写路由 |
| locale/LANG | `SshSettingsPolicy`、`SshSettingsService` | 继续 host-scoped 读取 | 新增全局 locale 单例 |
| session 身份 | `SshSessionStore`、`SshSessionHandle` | 作为运行态真值；Workspace 只持临时引用 | 新建重复 Runtime Session Store |
| 页面标签 | `SshTerminalTabStore` | M2 扩展/适配关闭、排序、固定语义 | 新 Store 与旧 Store 双写 |
| xterm 渲染 | `SshXtermSurface`、rawfile xterm | 保留 surface 生命周期并增量加桥 | 用 ArkUI `@State` 承载字节流 |
| native 渲染 | `SshTerminalSurface`、renderer registry、native renderer | 保留 fallback/可选路径 | 为工作台再写解析器 |
| 搜索引擎 | rawfile 已加载 `SearchAddon`，已有 `__sshXtermSearch` | M1 只补 ArkTS UI、选项和可靠桥 | 再引入第二个搜索库 |
| transcript | `SshTerminalTranscriptStore` | M5 前仅作内存回看 | 冒充持久加密日志 |
| SFTP | `SshSftpTaskEngine`、TaskStore、batch/integrity/owner policy | M3 增加 Pane/adapter，保持引擎唯一 | 复制上传下载队列 |
| 端口转发 | `SshForwardingController`、runtime/profile store | 工作台只消费低频状态 | 新建第二个 forwarding controller |
| 后台/PiP | `SshTerminalBackgroundTaskService`、`SshTerminalPipService` | 保留现有生命周期 | 工作区恢复时盲目联网 |
| 独立窗口 | `RemoteSessionWindow*` 现有协调器与鉴权证明 | SSH 只消费既有 handoff/owner | 鉴权前开窗或双 owner |
| 响应式断点 | 现有 `BreakpointUtil` | API 26 前继续作为唯一全局断点真值 | 建第二套冲突 breakpoint 系统 |

M0 对计划中“新建 `SshWorkspaceRuntimeStore`”的解释调整为：不创建第二套 session registry。若需要工作区映射，只能建立不拥有 native session 的轻量 adapter，并以 `SshSessionStore` 的 `SshSessionHandle` 和 generation 为唯一运行态身份。

## 5. S0 契约草案

以下是 M0 必须编码并通过纯策略测试的语义，不代表当前已经实现。

### 5.1 持久快照

`SshWorkspaceSnapshot` 只允许包含：

- `schemaVersion`、`revision`、`workspaceId`、脱敏或用户指定名称。
- tab 的稳定 UI ID、kind、hostId 引用、固定/排序/未连接状态。
- Pane 树的稳定 ID、方向、比例、tab 映射和焦点 ID。
- 用户明确选择的布局/视觉配置引用。

快照不得包含：

- `SshSessionHandle`、native pointer、channel 对象或 ArkWeb controller。
- 密码、私钥正文、MFA、prompt 响应或解引用 secret。
- 终端字节流、选择内容、剪贴板、命令历史或文件路径。
- “恢复后自动连接”的隐式布尔值；联网必须是显式 action。

### 5.2 运行态引用

`SshRuntimeSessionRef` 是内存态 adapter，字段固定为 `sessionId + channelId + generation + hostId`。其中前三项必须能无损映射到现有 `SshSessionHandle`。它不能被 JSON/RDB 持久化。

### 5.3 Action

M0 action 只修改纯快照：创建/重命名工作区、打开占位 tab、激活、关闭、排序、固定、分割/合并 Pane、移动 tab、聚焦和更新比例。连接、认证、发送输入、SFTP 和转发属于 Controller effect，不由 reducer 伪装完成。

### 5.4 所有权与 generation

1. 一个 native session 同时只有一个 `SshSessionStore` owner。
2. tab、Pane 和窗口只引用 owner，不重复释放。
3. 所有异步回调都校验 `sessionId + channelId + generation`。
4. 旧 generation 输出、错误和关闭回调必须丢弃，不能更新新会话。
5. 关闭 UI 引用不等于结束 SFTP/转发任务；任务是否继续由已有引擎策略决定。
6. 独立窗口 handoff 仍遵守“鉴权成功后建窗”，失败回滚到原 owner。

## 6. 非回归矩阵

| 契约 | 自动化证据 | HDC/设备证据 | 阶段状态 |
|---|---|---|---|
| 密码、Key、KBI/MFA 鉴权顺序不变 | 现有 native auth/prompt tests | 成功/取消/失败各一条 | S0 待设备 |
| Host Key 首次、接受、变化、逐跳失败 | preflight/native tests | Sheet、拒绝和错误态 | S0 待设备 |
| Proxy/ProxyJump 与三跳路由 | proxy/route tests | 至少一条可用路径或明确环境 blocker | S0 待设备 |
| locale 为 host-scoped | `SshSettingsPolicy.test` | 两主机切换不串值 | S0 待设备 |
| tab 切换不重连、不串 surface | tab/xterm binding tests | 两标签切换、退出 | S0 待设备 |
| generation 丢弃旧回调 | session store/native tests | 断网重连日志 | S0 待设备 |
| xterm 输入、选择、复制、搜索 | input/surface tests；SearchAddon 已存在 | 软键盘和物理键盘 | S0 待设备 |
| native renderer fallback | renderer/native tests | 能力开关 smoke | S0 待设备 |
| SFTP 暂停/恢复/重试/完整性 | SFTP policy/native tests；`SheetTransitionPolicy.test` 锁定短窗口 footer | API23 PC 下载：1% → 暂停 12%/33.3MB → 继续 14% → 取消保留 partial → 重试 16% → 完成 268435456 字节；短窗按钮 y=805–881 | M7 PC/API23 DOWNLOAD PASS；上传/Phone/物理/API26 待设备 |
| 转发生命周期 | forwarding tests | 开启、关闭、断线 | S0 待设备 |
| 后台、前台、PiP | lifecycle policy tests | 切后台/返回/PiP | S0 待设备 |
| 独立窗口鉴权后创建、单 owner | RemoteSessionWindow tests | PC SSH 成功后开窗 | S0 待设备 |
| 非 SSH 协议不受 SSH flag 影响 | `SshWorkspacePolicy.test` 四协议 fail-closed 用例已注册并编译 | API23 PC 在 `sshWorkbenchV2=false` 下显示 RDP/RustDesk/SSH/VNC/Moonlight 全部添加入口 | M0 SOURCE/HDC PASS；device runner 仍受基线阻塞 |

## 7. HDC 基线索引

### 7.1 设备

| Target | 形态 | 屏幕 | 当前证据 |
|---|---|---:|---|
| `127.0.0.1:5555` | Phone | 1320×2848 | EntryAbility / HostListPage / window 70，全屏 1320×2848 |
| `127.0.0.1:5557` | PC/2-in-1 | 3120×2080 | EntryAbility / HostListPage / window 172，自由窗口 `[672,392][2762,1786]` |

采集命令均使用 `/Users/mydestiny/Library/OpenHarmony/Sdk/23/toolchains/hdc` 在沙箱外执行。PC 端只是启动既有安装包，没有重装或清理应用数据。

### 7.2 临时证据

| 文件 | SHA-256 | 说明 |
|---|---|---|
| `/private/tmp/ssh-s0-phone.png` | `d18a56838a13f8a995c62e8fdf48aeee7a61585a3181fc60574c44ac4d4522c6` | Phone 当前 App UI；停留在设置/诊断弹层，不是 SSH 验收 |
| `/private/tmp/ssh-s0-phone-layout.json` | `9b3fce378d9982fa28698b9416710dcfc3eef6efca7c3a8477d499d3376d5290` | Phone UI hierarchy |
| `/private/tmp/ssh-s0-pc.png` | `71480dc674cb740aa7dd63a7174d23c91fed05e7d4f2b2b23b42f9ffa42a832e` | PC 当前 App 设置页和自由窗口基线 |
| `/private/tmp/ssh-s0-pc-layout.json` | `66df2adf98190776f49f8ee55b0571c5955304b0902583d7440b2e3f36368d53` | PC UI hierarchy |
| `/private/tmp/ssh-s0-pc-hosts-clear.png` | `806a4c76d79dcb6e5bab3c95c4468f80f4543b137a499ec4e3be0b0a77d8e277` | PC SSH 主机列表基线；不在账本记录私有地址或主机名 |
| `/private/tmp/ssh-s0-pc-hosts-clear-layout.json` | `0a814ec9a349bddbcbc52d2ed13beb0e078514c17bb21028bc48546d6e524ca2` | PC SSH 主机列表 UI hierarchy |
| `/private/tmp/ssh-s0-pc-connect.png` | `41ad1b9a765e5b5c99714d56002a233b036e540d8383349a2672797393a7aa51` | 点击现有 SSH 主机后的即时画面；采集过早，仍为主机列表，不能证明会话已建立 |
| `/private/tmp/ssh-s0-pc-session.png` | `973b0e96470eac04407cf2ea6b1f7a011c05284c00d4f7ac9dab3f042e417422` | 延后画面回到 HostListPage 设置 Sheet，并非 SSH Terminal；当前连接/鉴权结果仍未证明 |
| `/private/tmp/ssh-current-sheet.png` | `186d9344564b4596ba23bf3e0c6d77d60b55ae4ee1606f2c65a02631634256e7` | 复核确认此前拦截输入的是残留“日志”诊断 Sheet，不是 SSH 鉴权页 |
| `/private/tmp/ssh-clean-before-click.png` | `c2dc29957281553d124d27c3f576eed8065bbe62f21b5556caa3e63f19e95268` | 关闭残留 Sheet 后的 SSH 主机列表点击前基线 |
| `/private/tmp/ssh-preflight-visible.png` | `3a6ae29166196285c50f766e0113eba61b436e1046b30c534f0404df51eb4103` | 干净基线点击后的既有 Host Key 预检错误态；测试 endpoint TCP 不可达，未进入 Terminal、未创建会话窗口 |
| `/private/tmp/ssh-card-click.png` | `32059a94e1570508505d764cb595ce1e252fd1543e1bda2c7eeca0c574c00daf` | 当前签名 HAP 点击 SSH 主机后的预检失败 Sheet；鉴权未成功时仍停留在源页 |
| `/private/tmp/ssh-card-click-layout.json` | `193c04cb7bf49545729815d31009b67adc729958551423e65543b1d9f2539354` | 预检失败页面 hierarchy；`aa dump -l` 仅有 EntryAbility，无独立 SSH Ability |
| `/private/tmp/ssh-ui-fixed-form.png` | `9a9823ac5142d9002fc32c47201ef78fc732e0e6a518e4865335d8a12cdbb49e` | `2d1f06d6` 后 PC SSH 新主机表单：直连、HTTP CONNECT、SOCKS5、SSH 跳板、FRP TCP 和下一步均可见 |
| `/private/tmp/ssh-ui-fixed-form-layout.json` | `f89a1381ffe701b24882ba8079d7d39fdab3d0a926c16b6b7a532a095e48a81d` | 修复后布局树；表单右边界约 1980，未再越过系统 Sheet |
| `/private/tmp/ssh-new-window.jpeg` | `e7d843950014a6772d6fbe99d46a898b223311290071489741d795cb7b2e3bb6` | API23 PC 模拟器：Host Key/Key 鉴权完成后独立 SSH 窗口与 shell 提示符 |
| `/private/tmp/ssh-sftp-surface.jpeg` | `7df18ddf5f045680cbafa687b0c12fa0b63ee7a7f411a8e6289a3de7d2b32d12` | SFTP 面板打开，显示当前 SSH 会话已连接 |
| `/private/tmp/ssh-sftp-remote-right.jpeg` | `1f014347c902a657e6a7ed3b7709bb8bc378bed9fb1a9d03c152df786d24384f` | 双端点 SFTP 视图：两侧均加载 47 项远程目录 |
| `/private/tmp/ssh-sftp-close-terminal.jpeg` | `a45d9d07c0613600458bd14d3da7ffc89bdf41b1f8b48b576b53c510738457a1` | 关闭 SFTP 后独立窗口中的终端仍保持连接 |
| `/private/tmp/ssh-sftp-session.jpeg` | `15fe42298d977bf1012d161e54aa23adc1bf9cecb141936e0cd05910bf8b0a10` | 关闭 SFTP 后输入 `echo SSH_SFTP_SESSION_OK` 并收到回显，证明会话保活 |
| `/private/tmp/ssh-forward-surface.jpeg` | `97ed1fa4a86a454d4d98bdf4acebea4ec878b54a9ca4df5ddb44669404f84e4f` | SSH 转发面板可打开/关闭的早期基线；后续 `ssh-forward-data.XXXXXX.json` 已补实际规则数据流 |
| `/private/tmp/ssh-sftp-remote-right-layout.json` | `2ed54b8eda8b2fc20562921630901867ba3f486dbf5a0b530f73672dcf442e9a` | 双端点 SFTP 布局树，记录左右 pane、当前 host 和 47 项状态 |
| `/private/tmp/ssh-recovery-smoke.jpeg` | `5b8a0f6aa7e7466c3cb4c16d70193543c6ad7f0a72f2af1f165c843d90e7878a` | `139a97d3` 安装后 PC/API23 EntryAbility 启动 smoke，主机列表正常显示 |
| `/private/tmp/ssh-pc-auth-window.jpeg` | `d18b97e1cd896402fe89b9cc7124c02fbf455c7ac8a8d3e8f6542d193e56502d` | `rport` 回环后 Host Key 更新确认 + ED25519 公钥鉴权成功；独立窗口前台显示，源 HostList 仍在后方 |
| `/private/tmp/ssh-pc-window-command.jpeg` | `e7bdcb76f1c544f2602cd0ada8dbadf8ba9e3a561c68fe43eeaa89375eb68609` | 独立窗口终端输入 `echo SSH_WINDOW_OK` 并收到回显 |
| `/private/tmp/ssh-pc-window-max.jpeg` | `33a9f2c16f2a69811226b0b27db3ff9d0c770f05c9930466e8eb9fc61b33e5c5` | 标题栏最大化后的 PC/API23 窗口：终端铺满显示区，系统标题栏仍可见 |
| `/private/tmp/ssh-pc-window-f11.json` | `c37c09eddceff4b06c6d89207e1b80226c92608bb7c6d85aecb9c187edb2b7ff` | F11 进入沉浸全屏后 `ssh-terminal-pane=[0,17][3120,2080]`，标题栏/停靠区隐藏 |
| `/private/tmp/ssh-pc-window-f11-exit.json` | `a9b3664e5b923fe85dc3430cdf759fa93fcbb0bb4daeaac1429c66f9fdaf3383` | 第二次 F11 退出沉浸全屏并恢复原自由窗口 `[76,131][1368,1049]` |
| `/private/tmp/ssh-pc-window-drag-left.jpeg` | `a39e49f2bb9e05677752521e2484e69ef0912a416c8ca0ce115ae8b2676fccdb` | 标题栏拖至左边缘后由 HarmonyOS WMS 进入左右分屏，右侧为系统“没有可用窗口”占位 |
| `/private/tmp/ssh-forward-data.XXXXXX.json` | `a2bb3754ad1139f59314015a8e668264ea92a0179000e0888391631189c00d35` | 转发规则实际监听，UI 显示 `监听中`、`流量 29 B`；主机侧 payload 与监听器字节数一致 |
| `/private/tmp/ssh-forward-listening.XXXXXX.json` | `8d96927f55688a5293c36b4d74cbeb053f545c2523be71984cd229bcf6955202` | 转发启动后的零流量基线，UI 显示 `监听中`、`流量 0 B` |
| `/private/tmp/ssh-sftp-remote-copy-downloads.jpeg` | `bf37904ece7e3a2c0462b4696ee5954aa074e9a4ed9eac2f73e323f0a9f9f121` | 远程端点复制到 `Downloads` 后的 SFTP 面板 |
| `/private/tmp/ssh-sftp-upload-local-done.json` | `e244e2816d4bd70c29efd8dba3849ae8e71ad1157a33859ae3650d2ef8149a04` | 本机授权后选择 `Loopback-SSH-Key.pub` 上传，UI 显示 `SFTP 批次已完成` |
| `/private/tmp/ssh-sftp-download-local-saved.json` | `bd901edd13ba6b7dc8e33bdf1c22ad89f94d2dcf243fb2423d822a8483a72a75` | 远程文件下载到系统文件选择器并完成批次（文件存在性另由 picker verify JSON 检查） |
| `/private/tmp/ssh-sftp-download-verified-final2.json` | `bfea09c61acf09a28403bddb7137d43196e7723733c3b8c21a21084e4aa36386` | 重复下载到非空目标的拒绝态，UI 显示 `失败 · 26 B / 26 B`，用于覆盖冲突保护 |
| `/private/tmp/ssh-api23-e2e.png` | `654efebf2229c08ef1538ff28464319f51b9a3445f1a39063c5704bf308137e9` | API23 PC：ED25519 鉴权后的独立窗口终端，HDC 键盘输入 `echo SSH_API23_E2E_OK` 回显 |
| `/private/tmp/ssh-sftp-api23.png` | `72c534c23529216779dbbdf8eca628ea130c5c29afeeba87a871bc9b2c1a6e60` | API23 PC：标准 SFTP 子系统加载后的目录面板 |
| `/private/tmp/ssh-sftp-open2-api23.json` | `92d67794a8bf0ab5376bf7a1b06e5c705532a431d31084c806942fe7c1fecfa7` | API23 PC：SFTP hierarchy，显示 `SFTP 已就绪` 与远端目录项 |
| `/private/tmp/ssh-recents.png` | `3f337bc3c4da50ce3fc75debe3d3f5946f2d479af1b7e40b4a887d2f6c0aa69b` | API23 PC：系统最近任务同时展示独立 SSH 窗口与主 HostList 窗口 |
| `/private/tmp/ssh-minimized-api23.json` | `1c94ee23f065db9d4de13910fa612fd2c3dec261d7ba1d447dfe3cd01fea411a` | API23 PC：独立 `RemoteSessionAbility` 最小化后处于 BACKGROUND，EntryAbility 仍 FOREGROUND |
| `/private/tmp/ssh-restored-api23.png` | `b10b24f386b187b47d7908c8840234d959c2da61e10139a8484b568ea4fc5a2d` | API23 PC：从最近任务恢复后独立窗口回到前台，终端提示符仍在 |
| `/private/tmp/ssh-password-failure-fixed-final-api23.json` | `2ce475e668efc270369445ec648d8c57711d4689635e8a726b24c670051f42a9` | API23 PC：错误密码后回到 `连接失败 (code=-31)`，显示“重试/返回”，无独立 SSH Ability |
| `/private/tmp/ssh-password-failure-fixed-final-api23.png` | `f199a7fca838e583b4e2a8f98751e2734d60c00baefa202ea7c8339c95fafe4d` | API23 PC：鉴权失败最终页面截图，独立窗口鉴权 carrier 已卸载 |

这些文件位于临时目录，不作为仓库制品。账本保留命令、hash 和观察结果；阶段验收前重新采集最终 SSH 页面证据。

### 7.3 已证明与未证明

已证明：两个目标可通过 HDC 连接；当前 HAP 在 API 23 Phone/PC 环境可启动；PC 使用系统自由窗口。关闭残留的诊断日志 Sheet 后，点击 SSH 主机正确进入既有 Host Key 预检；TCP 不可达时保留在 HostList 的错误 Sheet，不会进入 Terminal，也不会创建独立会话窗口。`2d1f06d6` 后，PC SSH 新主机 Sheet 的布局树边界与截图均证明代理选项和下一步操作不再被固定宽度截断。2026-08-20 的两次回环 endpoint 复验进一步证明：产品 ED25519 key/指纹确认后才创建 SSH 独立窗口；sshd 日志确认公钥鉴权成功；HDC 键盘输入及终端命令可回显；SFTP 标准子系统可加载 47 项目录；已有远程复制、本地授权上传、本地下载及非空目标拒绝证据仍有效；关闭 SFTP 后终端继续执行命令；转发规则实际建立后可接收主机 payload 并更新流量；独立窗口最小化/最近任务恢复不丢会话，主窗口与 SSH 窗口可同时展示；标题栏最大化、F11 沉浸全屏进出、左边缘系统分屏均已采证。错误密码路径也已证明：Host Key/认证顺序不变，原生失败码 `-31` 会回到源页错误/重试界面，不会创建独立窗口或留下鉴权 carrier。2026-08-22 进一步完成 API23 PC 下载侧暂停/继续/取消/重试/最终导出的同任务闭环，并证明短自由窗口可完整访问传输 footer。

尚未证明：KBI/MFA 的成功/取消/失败全矩阵、密码鉴权的取消/失败在 Phone/PC 双端矩阵、真实软/硬键盘设备矩阵、SFTP 上传侧及 Phone/物理设备/API26 的暂停/恢复/取消/重试余下矩阵、通知/连续任务与 PiP、API26 设备和多主机/全协议并行。2026-08-22 回环 sshd 仅监听 127.0.0.1 且已在采证后关闭；但沙箱外 HDC/破坏性清理审批因会话额度限制被系统拒绝，PC `tcp:22220` 映射、模拟器下载目录中的 `codex-sftp-lifecycle.bin`，以及本机 `/private/tmp/000-codex-sftp-lifecycle`/临时 `sshd_config` 仍须在审批恢复后定点删除，不能写成已清理。没有物理/API26 与上述剩余矩阵证据前，M7–M9 仍保持 DEVICE_PENDING，整个 SSH 计划不能标为完成。

## 8. 工具链事实

- 当前 HAP `apiTargetVersion` / `apiCompatibleVersion` 均为 `60100023`。
- DevEco 内置 SDK 的 `sdk-pkg.json` 为 HarmonyOS 6.1.1 / API 24 / Release。
- 当前可直接调用的独立 HDC 位于 OpenHarmony SDK 23。
- 本机没有已验证的 API 26 SDK 声明，SSH-U0 保持 `PENDING_EXTERNAL_SDK`。

## 9. 阶段 receipt

| 阶段 | 输入 | 实现/文档 | 自动化 | Hvigor compile | assembleHap | HDC/实机 | Review | 状态 |
|---|---|---|---|---|---|---|---|---|
| S0 | 当前 API 23 产品 / `c07795fc5` | 本账本、复用/契约矩阵 | 未单独运行 suite；两项构建门禁覆盖编译 | PASS，exit 0，26.188s | PASS，exit 0，3m 6.999s | 壳与主机列表基线已有；认证后流程待补 | 待一次主审 | ACTIVE |
| SSH-U0 | API 26 SDK | capability allowlist | 待 SDK | 待 SDK | 待 SDK | 待 API 26 设备 | 待 | BLOCKED_BY_SDK |
| M0 | S0 契约 | 纯 snapshot/reducer、非 owning runtime adapter、capability/layout/style policy、flag-off Shell | 16 个纯策略用例已注册；设备执行未声明 | PASS，exit 0（最终复跑） | PASS，exit 0，7.122s | flag 默认关闭；旧页面未接线，既有 HDC 错误路径不变 | 一次主审 + 一次定向复核完成；5 个生产问题与 2 个测试问题均已修复 | READY_FOR_CHECKPOINT |
| M1–M6 | M0 契约 | 已落地；M6 会话日志独立 flag 默认关闭并约束 capture/export，chunk 更新以不可变行保证索引失败后的重启一致性；搜索使用可取消分片调度；完成通知独立 opt-in 且并发 ID 有界不互相覆盖；日志/历史仅接受精确会话的 xterm 安全快照 | 已注册；包含日志双 flag 合取、失败索引写后的新实例恢复、分片/同步等价、最小预算推进、通知默认关闭及 ID 回绕 | PASS | PASS | API23 smoke；真实断电/10MiB+ 设备压力、后台/通知权限矩阵待验 | 已复核；日志/通知/多窗格模式修复待最终实机复核 | CHECKPOINT |
| M7 | M6 工作台 | 已落地；广播刷新只保留显式且仍安全的目标；安全模式按 host/session/generation 隔离，未知状态 fail closed；独立高风险 flag 默认关闭 | 已注册；包含独立 flag、未知安全状态及失效目标不替换策略用例 | PASS | PASS | 真实主机及广播 UI 矩阵待接入 | 已复核；本次安全修复待最终实机复核 | DEVICE_PENDING |
| M8 | M7 工作台 | 已落地；双端 generation/sequence/ACK 整数且严格连续 | 已注册；包含小数计数器与向前跳号拒绝 | PASS | PASS | API26/高负载设备待验 | 已复核；本次序号修复待最终实机复核 | DEVICE_PENDING |
| M9 | M8 前置 | SSH handoff、独立窗口前台恢复、沉浸/分屏回归已落地 | 策略覆盖 | PASS | PASS | PC/API23 模拟器已证明鉴权后开窗、SFTP/终端保活、转发 payload、最小化/最近任务恢复、F11 沉浸进出、左边缘 WMS 分屏、任务栏/WMS 多窗口；物理/API26/剩余协议矩阵待验 | 待最终实机复核 | DEVICE_PENDING |

## 10. S0 下一步

1. 在 API26 SDK/目标设备可用后，复跑同一回环账本并补密码/KBI/MFA、SFTP 暂停/恢复/取消/重试、后台/PiP 和多主机/全协议并行矩阵。
2. 精确提交 M0 SSH-only 增量；不得暂存本账本列出的并行脏文件。
3. 进入 M1 搜索桥和 Profile/快捷能力前，继续复用既有 SearchAddon、`SshSessionStore` 与 `SshTerminalTabStore`。

最近一次 recovery fence 修复后的精确构建命令于 2026-08-20 在 `139a97d3` 上执行，使用 `source scripts/macos_env.sh` 后的 DevEco Hvigor 环境；两项均退出 0（assembleHap：`BUILD SUCCESSFUL in 11 s 740 ms`）：

```sh
hvigorw --mode module -p module=entry -p product=default default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon
hvigorw --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --no-daemon
```

手机入口证据补录后的同一双门禁于 2026-08-20 重新执行：`default@OhosTestCompileArkTS` exit 0（`BUILD SUCCESSFUL in 6 s 49 ms`），`assembleHap` exit 0（`BUILD SUCCESSFUL in 7 s 504 ms`）；仅有既有 ArkTS 弃用/依赖资源告警，无编译错误。

2026-08-20 native 轻量测试 receipt（主机环境）：使用 OpenHarmony SDK 23 的 CMake，以 `-DRDP_BUILD_TESTS=ON -DRDP_TESTS_ONLY=ON -DCMAKE_BUILD_TYPE=RelWithDebInfo` 配置并构建 `rdp_native_tests`，配置、编译均 exit 0。运行 `/private/tmp/remotedesktop-ssh-native-tests/rdp_native_tests` 后共 `769 passed, 16 failed, 785 total`；45 个 SSH 用例（终端诊断、鉴权/Prompt、PTY recovery、重连、generation/session、路由、转发、SFTP）全部显示 `OK`，无 SSH failure。16 个失败全部是共享 runner 中既有 VNC TLS fixture 的 `fixture.start()`，未涉及 SSH，未修改 VNC/Moonlight；完整输出 SHA-256 为 `da54ead34c2507116e687111ec654299c3e6069164a4d46229e555b50517f722`。该结果作为 SSH native host smoke 记录，不冒充全协议 suite 通过。

2026-08-22 KBI broker 取消后重连 receipt：新增 `ssh_auth_prompt_broker_accepts_new_session_after_cancellation`，证明同一 broker 在旧请求取消后拒绝 stale response、并可为新 sessionId/generation 建立独立等待与响应。OpenHarmony SDK 23 CMake 轻量 host suite 配置、构建均 exit 0；`rdp_native_tests` 完整运行 `786 passed, 0 failed, 786 total`。同工作树精确执行 `default@OhosTestCompileArkTS` exit 0，随后 `assembleHap` exit 0（`BUILD SUCCESSFUL in 2 min 5 s 957 ms`）。本 receipt 只覆盖 SSH 测试增量；用户并行编辑的 `VncSettingsPage.ets` 保持未暂存、不纳入本次验证声明。

2026-08-22 M0 协议隔离 receipt：`2d23d9c7` 将协议身份加入现有 SSH capability policy，并新增 RDP/VNC/RustDesk/Moonlight 四种非 SSH 输入的 fail-closed 契约。精确 `default@OhosTestCompileArkTS` exit 0，`assembleHap` exit 0（`BUILD SUCCESSFUL in 13 s 673 ms`）；签名 HAP SHA-256 为 `07465028a9cdc1c8211becbe74a53b51fd4dd3d41a92a67eca306bd48eb6ba2e`。最新包安装到 API23 PC `127.0.0.1:5557` 并启动成功；模块偏好文件确认 `sshWorkbenchV2=false`，协议选择 Sheet 层级同时包含 RDP、RustDesk、SSH、VNC、Moonlight。证据为 `/private/tmp/ssh-flag-isolation-start.json`（`178ef6f900217aaac95ba1e95d6656ac2397ca9dc56bfeb0813bc6fa757dc6bc`）、`/private/tmp/ssh-flag-isolation-start.jpeg`（`7b7e7657f92af8cbe0e25bfa78a22b73de44d3dfe040fc07e7d04a5a3255b91a`）和 `/private/tmp/ssh-flag-isolation-picker.json`（`0ce6b0de1e955cde979d67eb55d6d612bdd4866ee7d45877b518efb6edc4fcdf`）。本次未执行受既有 runner 基线阻塞的设备 Hypium，未把源码用例编译冒充运行通过；用户并行的 `VncSettingsPage.ets` 仍未暂存。

2026-08-22 SFTP 下载生命周期与短窗口 receipt：`4a9b0923` 只修改 `SheetTransitionPolicy.ets` 及既有策略测试，使双栏内容区在短窗口最低可压缩至 150vp；大窗口 `layoutWeight` 扩展、SSH/SFTP 引擎、任务 store、完整性 checkpoint 与其他协议均未改动。精确 `default@OhosTestCompileArkTS` 与 `assembleHap` 连续执行均 exit 0（assembleHap：`BUILD SUCCESSFUL in 14 s 175 ms`）；签名 HAP SHA-256 为 `c9ba42fdd0500b13f9867bd6083d8358126f2e8e24a9d3376d140c35a172d2f1`，安装到 API23 PC `127.0.0.1:5557` 成功。下载证据依次为 `/private/tmp/ssh-sftp-downloading.json`（`12294f433d13226308309e2a877d4c6dd52fc28ccddec4b22224922ed2d69017`）、`ssh-sftp-paused.json`（`1f781bc85f6238eb0b296ef65f37ce026ec2a3560500beede00a0b0ea7b444f4`）、`ssh-sftp-resumed.json`（`552b414432c1157d3ca5176e336a82a36b0e75c9a0ba61b645ff1c993eef4613`）、`ssh-sftp-cancelled.json`（`760930d88a6a98844264a9a06ce76297687ff4b3be348a7656eb8c85f2283853`）、`ssh-sftp-retry-active.json`（`978c3752d10e47fa14c0a4e2a20028d109a4b76dbe24f4d6800bf2617c882565`）、`ssh-sftp-completed.json`（`3acb59246abfc31310a3ba9a905382dcf18b858af6761c17b5b29897570f5a89`）和本机列表刷新 `ssh-sftp-local-refreshed.json`（`70aa895549d8923b265d26485f26dbb4dc9886966d85dd08c97455a933084e5a`）。短窗口布局证据为 `ssh-sftp-short-fixed.json`（`3ba89c61c6ed73d044a1bf602dbea75aa41e6b77ce4c26d2ae20be8005bb0257`）与选择本机端点后的 `ssh-sftp-short-local.json`（`24dc50c9089fb4b7ce6c9e822ea362370664f81312439de6894529e383ed8a48`）。本轮只宣称 API23 PC 下载侧闭环；清理 blocker 如 7.3 所列。

2026-08-22 M7 广播目标失效保护 receipt：`514be272` 在既有 `SshBroadcastPolicy` 中增加纯选择协调函数，并让 `SshTerminal` 仅在广播面板首次打开时预选当前 host；切换目标、确认前刷新和实际发送前刷新均只保留用户显式选择且仍满足连接、鉴权、raw、全屏安全约束的 host。由此，唯一显式目标失效后结果为空并拒绝发送，不再把当前会话静默替换为接收方。新增策略用例覆盖首次预选、显式空选择、目标失效不替换及有效目标去重。精确 `default@OhosTestCompileArkTS` exit 0，`assembleHap` exit 0（`BUILD SUCCESSFUL in 12 s 976 ms`）；签名 HAP SHA-256 为 `2ebb812bdac9fdb3bcd93d83798939ac438b20ee4d7ef7279010786c5ba2b462`。本 receipt 不声明 HDC/真机广播交互通过；相关设备矩阵和 7.3 所列定点清理仍待外部审批/设备条件。

2026-08-22 M7 广播快速重连 fence receipt：`0575bb18` 让选择协调同时接收上一刷新目标快照；只有 `hostId + sessionId + generation` 前后完全一致且仍满足安全门禁的目标才能保留。目标在两次刷新之间完成断开/重连时，即使 host 相同且当前已重新 connected，也不会继承旧选择。新增 `should_drop_a_reconnected_target_with_a_new_generation` 精确锁定此竞态。精确 `default@OhosTestCompileArkTS` exit 0，`assembleHap` exit 0（`BUILD SUCCESSFUL in 11 s 757 ms`）；签名 HAP SHA-256 为 `b67af4362f5935df209f2a0abf3668819c004730b5a14784afc3ea10eda131c0`。本 receipt 仍仅为源策略/构建证据，HDC/真机广播、API26 和物理设备矩阵保持 `DEVICE_PENDING`。

2026-08-22 M8 WebMessagePort 序号完整性 receipt：`24377a51` 修复双端只拒绝倒退/重复、却接受向前跳号的问题。ArkTS `validIdentity`/`validSequence`/`validAckSequence` 现在拒绝小数，入站状态机对 `lastReceivedSequence + 1` 之外的 forward gap 返回 `out_of_order_sequence` 且不推进状态；xterm rawfile 同步要求首个 hello 为 `sequence=1/ack=0`，后续严格连续。新增纯策略用例证明小数 generation/sequence/ACK 与 gap frame 均 fail-closed。精确 `default@OhosTestCompileArkTS` exit 0，`assembleHap` exit 0（`BUILD SUCCESSFUL in 12 s 888 ms`）；签名 HAP SHA-256 为 `fb2b47f9bbfe5e080083b7f35d4bdd4a76b69ff0d650143f0d646a97b67f114d`。通道 flag 仍默认关闭，API26/高负载/前后台 WebView 设备矩阵仍为 `DEVICE_PENDING`。

2026-08-22 M7 广播独立发布门禁 receipt：`5fd45827` 增加 `sshBroadcastInput` AppStorage flag 并明确默认 `false`；只有 `sshWorkbenchV2` 已启用、工作区已就绪且该独立 flag 明确为真时，生产力 Sheet 才展示广播入口，页面才允许打开、刷新目标或在确认前后发送。flag 在运行中关闭时立即 fail-closed：关闭 Sheet、停止 active 状态并清空目标、选择、文本、模式与 reconnect 安全记忆。新增纯策略用例锁定默认关闭和双 flag 合取；未增加普通用户设置入口，因 M7 仍需独立安全审查与实机矩阵。精确 `default@OhosTestCompileArkTS` exit 0，`assembleHap` exit 0（`BUILD SUCCESSFUL in 13 s 268 ms`）；签名 HAP SHA-256 为 `9dca7271635b4ba2841e65c237c0d0e1a3fa55eff59c6ecb269f78c2b69c00b7`。本 receipt 不声明 HDC/真机广播交互、API26 或物理设备验收通过。

2026-08-22 M6 会话日志独立发布门禁 receipt：`282492e0` 增加默认 `false` 的 `sshSessionLogs` AppStorage flag；持久化日志设置保持不迁移、不降级，但入口、设置更新、搜索、书签、导出及捕获路径都要求工作台与独立 flag 同时开启，因此旧的 `settings.enabled=true` 不能在 rollout 关闭时继续记录。运行中关闭 flag 会关闭日志 Sheet、取消 flush timer，清空尚未落盘的输入/输出/命令缓冲并移除页面内日志投影；异步导出在 picker 返回后再次校验 flag。新增纯策略用例锁定默认关闭和双 flag 合取。精确 `default@OhosTestCompileArkTS` exit 0，`assembleHap` exit 0（`BUILD SUCCESSFUL in 18 s 335 ms`）；签名 HAP SHA-256 为 `91d16bad405e6474277ae66b81baed5226885ef04c78a527a34993306b4bc679`。本 receipt 不声明 10MiB 压力、后台/锁屏/通知权限、API26 或物理设备矩阵通过。

2026-08-22 M6 会话日志导出确认与异步 fence receipt：`5fbdc1ec` 在生成导出快照前增加明确二次确认，告知只导出当前主机的二次脱敏内容且保存文件会离开应用加密存储；确认弹窗与系统 `DocumentViewPicker` 两个 await 之后均通过纯 `matchesSshSessionLogExportFence` 校验原始 host、page generation、binding generation、日志 rollout 可用性、store ready 和页面 closing 状态。任一 host/owner/页面/flag 变化即拒绝继续写出。策略测试覆盖合法 fence 以及 host、page、binding、flag 变化的 fail-closed 行为。精确 `default@OhosTestCompileArkTS` exit 0，`assembleHap` exit 0（`BUILD SUCCESSFUL in 12 s 274 ms`）；签名 HAP SHA-256 为 `42c87ed604e30d90024436050e31f898df72b4b816bf953f68968537e2daaaa1`。本 receipt 仅为源码/构建证据，未冒充系统 picker 真机、后台或物理设备验收。

2026-08-22 M6 大日志分片搜索 receipt：`a5c3dc9e` 将原先由 `TextInput.onChange` 触发、在 ArkUI 上同步遍历完整日志的搜索改为有界游标和 256 工作单元的异步切片，并增加 120ms 防抖与 request sequence、host、page generation、SSH binding generation、双 flag、store ready、closing、Sheet 可见性联合 fence；关闭/隐藏日志 Sheet、页面退出、owner 变化或 rollout 回退都会取消旧结果。纯策略用例证明预算为 1 时游标仍推进、分片结果与同步搜索一致，并保留非法 identity 的 fail-closed 语义。共享工作树第一次 `default@OhosTestCompileArkTS` 仅因并行的 `CloudStore.ets`/`HostSyncService.ets` 类型错误退出 255，本次 4 个 SSH 文件没有报错；只复制本次 4 文件的 `/private/tmp/remotedesk-ssh-log-search.6YD51t/repo` 隔离镜像随后 compile/assemble 均 exit 0（assemble：`BUILD SUCCESSFUL in 53 s 245 ms`）。并行修改稳定后，共享工作树正式 compile exit 0；第一次正式 assemble 在并发产物写入期间于 SignHap 报 `zip END header not found`，稳定后精确重跑 exit 0（`BUILD SUCCESSFUL in 8 s 909 ms`）。最终 `entry-default-signed.hap` SHA-256 为 `30e42f94b3d31e29950a645379123dd857a0ffacbd1b12a7a1dac868a4663c9f`。本 receipt 证明策略、编译和打包门禁，不冒充 API23/API26/物理设备上的 10MiB+ 交互压力验收。

2026-08-22 M6 命令完成通知 opt-in receipt：`81180347` 为加密的 `SshProductivitySettingsV1` 增加默认关闭的 `completionNotificationEnabled`；旧版本文档缺少该字段时经白名单编码确定归一化为 `false`。生产力 Sheet 增加独立开关，页面把设置显式传入通知请求，`SshNotificationService` 在构造系统通知前再次 fail-closed 校验；由此单独启用 Shell integration 或本地补全都不会隐式发布通知。策略测试覆盖旧文档默认关闭以及失败命令在 `enabled=false` 时仍不允许通知。精确 `default@OhosTestCompileArkTS` exit 0，`assembleHap` exit 0（`BUILD SUCCESSFUL in 15 s 365 ms`）；签名 HAP SHA-256 为 `7ce73e0e2cd2afd5edbfa3588070b9d569672fb6d0bac15b827620b30c9cb7f2`。本 receipt 不声明通知权限拒绝、后台、锁屏或物理设备交互已验收。

2026-08-22 M6/M7 多窗格终端模式身份 fence receipt：`490e11af` 让 xterm 5.3 在 boot/reset 及每个已完成 VT 写批次后读取公开 `terminal.modes` 与 active buffer 类型，并通过现有生命周期隔离的 JavaScript proxy 稀疏上报；bulk output 即使切到 WebMessagePort，模式控制面仍不扩展 M8 数据信封。`SshXtermSurface` 和页面同时校验 lifecycle token、surface identity、host、sessionId 与 generation，旧文档、重连前会话及缺失 API 都不会产生“安全”结论。M7 广播策略增加 `safety_unknown` 并在连接后优先 fail closed；M6 会话日志和命令历史也要求同一精确会话的安全快照，mouse/application cursor/application keypad 或 alternate buffer 任一激活即停止采集。纯策略用例锁定未知状态不可广播。共享工作树精确 `default@OhosTestCompileArkTS` exit 0，`assembleHap` exit 0（`BUILD SUCCESSFUL in 23 s 448 ms`）；签名 HAP SHA-256 为 `e5df31edb409a01ac964fef18f34548e7418994439278cea114d26735ded4dd0`。构建时工作树同时存在未纳入本提交的局域网发现并行修改；本 receipt 只声明本次 SSH 代码通过同一完整产品门禁，不声明 HDC、真实多主机广播、API26 或物理设备矩阵已验收。

2026-08-22 M6 并发完成通知 ID receipt：`903eb5b1` 将 SSH 完成通知的单一固定 ID 改为服务实例内的 1024 项有界 ID 环；只有实际满足用户 opt-in 及失败/长命令策略的事件才分配 ID，正常多会话并发不再因 `notificationManager.publish` 使用同一个 ID 而互相替换，达到边界后才确定回绕且不产生无界编号。纯策略用例覆盖首次分配、连续分配、上界回绕和 `NaN`。精确 `default@OhosTestCompileArkTS` exit 0（`BUILD SUCCESSFUL in 8 s 843 ms`），`assembleHap` exit 0（`BUILD SUCCESSFUL in 10 s 212 ms`）；签名 HAP SHA-256 为 `39f6a0e8293d43449f5a3f6f2c36580e70017c27bf37d4e5257cbd4a91880313`。本 receipt 不声明通知权限、后台/锁屏、API26 或物理设备多会话通知矩阵已验收。

2026-08-22 M6 日志 chunk 重启一致性 receipt：`7246f498` 将逻辑尾 chunk 的更新从“覆盖同一 RDB 行”改为不可变候选行：新密文使用由记录身份、session/generation、时间、chunk 序号和记录数构成的新 ID，先写新行，再原子地以索引作为可见性边界；索引失败时旧索引仍只引用旧密文，成功后才删除旧行及其内存序列化/密文缓存。Store 回归用例不仅检查当前实例未前移，还在模拟索引写失败后创建全新 Store 并重新初始化，证明失败追加不会在进程重启后复活。第一次正式 `assembleHap` 因并行 `CloudStore.ets` 正在增加但尚未定义 `rdpRestrictedAdminSecretOwnedByCurrentScope` 而 exit 255，本次 3 个 SSH 文件无报错；并行修改稳定后，精确 `default@OhosTestCompileArkTS` 与 `assembleHap` 均重跑 exit 0，最终 assemble 为 `BUILD SUCCESSFUL in 1 s 509 ms`，签名 HAP SHA-256 为 `71c3d26627c2c9a74bddeab7ca27817d812d331f1911f6af636a3bcea1932123`。本 receipt 证明模拟失败恢复及产品构建，不冒充真实断电、API26 或物理设备恢复矩阵。

2026-08-22 M6 日志页面轻量投影 receipt：`cd22f921` 保留 `SshSessionLogStore.snapshot()` 的完整深拷贝语义供既有非热路径使用，新增 `pageSnapshot()` 只复制设置及 chunk 身份、时间、大小等元数据，并让 `SshTerminal` 的可观察页面状态和设置开关不再读取记录正文。日志 Sheet 当前只消费设置和 chunk 数量，搜索结果继续由可取消分片搜索单独返回；测试锁定轻量投影的 `records` 为空，同时完整 snapshot 与搜索仍能读取原记录。精确 `default@OhosTestCompileArkTS` exit 0，`assembleHap` exit 0（`BUILD SUCCESSFUL in 12 s 234 ms`）；标准签名 HAP SHA-256 为 `fb4bacf3c0ae22fd01aa1fc351015326a9a21ede8130837d0b1c7f416c0f0d58`。本 receipt 证明源码、测试编译和打包门禁，不冒充 10MiB 真机压力、API26 或物理设备验收。

2026-08-22 M6 日志增量追加 receipt：`1d50f847` 将 `appendSshSessionLogRecord` 从“完整文档 JSON encode/decode、修改、再次完整 prune clone”改为只复制设置、顶层数组和被更新的逻辑尾 chunk；保留的旧 chunk 与 record 引用不变。Store 不再用两次完整文档编码判断追加变化，也不再让通用 commit 重新归一化完整正文；追加专用提交先拒绝旧不可变 ID 对应新对象的碰撞，再只序列化/加密缓存中不存在的新 chunk，并以加密索引作为可见性提交点。回归用例锁定跨主机追加时旧 chunk 引用和旧文档内容均保持不变，原有索引写失败后的新实例恢复用例继续覆盖失败提交不可见。精确 `default@OhosTestCompileArkTS` exit 0，`assembleHap` exit 0（`BUILD SUCCESSFUL in 12 s 891 ms`）；标准签名 HAP SHA-256 为 `7469537b6ea56aedd99bfa80a80b610c1a8d00d55038eefd41edd2c79fec9094`。本 receipt 证明源码、测试编译与打包门禁，不冒充 10MiB 真机压力、断电、API26 或物理设备验收。

2026-08-22 SSH/SFTP 诊断字段脱敏 receipt：`0989af9d` 移除终端 ready/recovery、标签切换、native renderer fallback、转发绑定、xterm input/focus/mode、双 SSH SFTP 建链/事件/复制等 hilog 中的 host 标识、active host、端点 host、远端 `sourcePath/targetPath/targetRoot` 和 surface identity。诊断仍保留本地 batch/task ID、session/generation、阶段、状态、错误类别、偏移和字节数，业务所需 host/path 变量仍在原控制流中使用，未改变连接、传输或身份校验。静态扫描确认相关敏感键不再进入两处诊断调用。精确 `default@OhosTestCompileArkTS` 与 `assembleHap` 均 exit 0（assemble：`BUILD SUCCESSFUL in 12 s 295 ms`）；标准签名 HAP SHA-256 为 `9a2daed54b67c2a8ba416c80e19034cb2c87bca0e84f6d25c7a450e783cf5e85`。本 receipt 不冒充 HDC、API26 或物理设备隐私验收。

2026-08-22 SSH 平台异常诊断边界 receipt：`6c5126dc` 新增 `sshDiagnosticErrorCode`，只允许有限数值平台错误码进入 hilog；SSH 页面、工作区 RDB、本机文件选择器、PiP 与后台任务不再记录任意异常 message/对象字段。用户可见错误提示仍沿用原始业务路径，未改变连接、文件、窗口、后台任务或通知语义。纯策略用例证明异常对象中构造的私有 host、远端路径和 password 不会出现在诊断结果，`NaN` 与字符串 code 均降级为 `unknown`。精确 `default@OhosTestCompileArkTS` exit 0，`assembleHap` exit 0（`BUILD SUCCESSFUL in 12 s 614 ms`）；标准签名 HAP SHA-256 为 `7ce2c492162c80d90a5a293eb97c8188df04bee5e483121e390320142eee805f`。本 receipt 不冒充 HDC、API26 或物理设备隐私验收。

2026-08-22 SSH 后台常驻通知隐私 receipt：`66db169f` 删除聚合通知中的 `hostLabel`/`hostAddress` 拼接，并把展示策略收敛为只接收运行连接数与后台受限数；通知现在只显示通用标题及“保持 N 个 SSH 连接，M 个后台受限”等数量状态。后台任务的会话集合、系统持续任务 ID、WantAgent、快照和停止条件未改动。既有通知策略测试增加运行/受限组合，锁定可见文案不含构造的用户名/IP/端口或远端路径。精确 `default@OhosTestCompileArkTS` exit 0，`assembleHap` exit 0（`BUILD SUCCESSFUL in 11 s 872 ms`）；标准签名 HAP SHA-256 为 `fe3dd2897c523d3c36b5bb4a88e831deb726467744ef7aad5c99cbcd67e354d3`。本 receipt 不冒充通知权限、锁屏、HDC、API26 或物理设备验收。
