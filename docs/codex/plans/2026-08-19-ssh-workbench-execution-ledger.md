# SSH 工作台升级执行账本

> 状态：`ACTIVE_M8_M9` / `NOT_COMPLETE`
> 权威计划：`docs/codex/plans/2026-08-19-ssh-termius-harmonyos7-api26-workbench-plan.md`
> 建立日期：2026-08-19
> 当前工作树：`codex/moonlight-complete-upgrade` / `60602d651`（M9 SSH 多窗口交接、独立窗口前台恢复、recovery generation fence、独立窗口后台所有权保护与鉴权失败回退；手机会话工具官方 Popup 已接入；并记录设备 runner/API26 工具链阻塞）
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

## 2A. 最新执行指针（2026-08-20）

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
- 仍未宣称完成：API 26 SDK/目标设备、物理设备验收、SFTP 暂停/恢复/取消/重试全矩阵、后台/PiP、API26 下的沉浸/分屏差异、密码/KBI/MFA 成功/取消/失败全矩阵以及多主机/全协议并行矩阵。
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
| SFTP 暂停/恢复/重试/完整性 | SFTP policy/native tests | 上传、下载、取消、错误 | S0 待设备 |
| 转发生命周期 | forwarding tests | 开启、关闭、断线 | S0 待设备 |
| 后台、前台、PiP | lifecycle policy tests | 切后台/返回/PiP | S0 待设备 |
| 独立窗口鉴权后创建、单 owner | RemoteSessionWindow tests | PC SSH 成功后开窗 | S0 待设备 |
| 非 SSH 协议不受 SSH flag 影响 | flag-off policy test | RDP/VNC/RustDesk/Moonlight 入口 smoke | M0 待实现 |

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

已证明：两个目标可通过 HDC 连接；当前 HAP 在 API 23 Phone/PC 环境可启动；PC 使用系统自由窗口。关闭残留的诊断日志 Sheet 后，点击 SSH 主机正确进入既有 Host Key 预检；TCP 不可达时保留在 HostList 的错误 Sheet，不会进入 Terminal，也不会创建独立会话窗口。`2d1f06d6` 后，PC SSH 新主机 Sheet 的布局树边界与截图均证明代理选项和下一步操作不再被固定宽度截断。2026-08-20 的两次回环 endpoint 复验进一步证明：产品 ED25519 key/指纹确认后才创建 SSH 独立窗口；sshd 日志确认公钥鉴权成功；HDC 键盘输入及终端命令可回显；SFTP 标准子系统可加载 47 项目录；已有远程复制、本地授权上传、本地下载及非空目标拒绝证据仍有效；关闭 SFTP 后终端继续执行命令；转发规则实际建立后可接收主机 payload 并更新流量；独立窗口最小化/最近任务恢复不丢会话，主窗口与 SSH 窗口可同时展示；标题栏最大化、F11 沉浸全屏进出、左边缘系统分屏均已采证。错误密码路径也已证明：Host Key/认证顺序不变，原生失败码 `-31` 会回到源页错误/重试界面，不会创建独立窗口或留下鉴权 carrier。

尚未证明：KBI/MFA 的成功/取消/失败全矩阵、密码鉴权的取消/失败在 Phone/PC 双端矩阵、真实软/硬键盘设备矩阵、SFTP 暂停/恢复/取消/重试全矩阵、通知/连续任务与 PiP、API26 设备和多主机/全协议并行。回环 sshd 仅监听 127.0.0.1 且已在采证后关闭；HDC `rport` 已移除。没有物理/API26 与上述剩余矩阵证据前，M7–M9 仍保持 DEVICE_PENDING，整个 SSH 计划不能标为完成。

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
| M1–M6 | M0 契约 | 已落地 | 已注册 | PASS | PASS | API23 smoke | 已复核 | CHECKPOINT |
| M7 | M6 工作台 | 已落地 | 已注册 | PASS | PASS | 真实主机待接入 | 已复核 | DEVICE_PENDING |
| M8 | M7 工作台 | 已落地 | 已注册 | PASS | PASS | API26/高负载设备待验 | 已复核 | DEVICE_PENDING |
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
