# SSH 工作台升级执行账本

> 状态：`ACTIVE_M8_M9` / `NOT_COMPLETE`
> 权威计划：`docs/codex/plans/2026-08-19-ssh-termius-harmonyos7-api26-workbench-plan.md`
> 建立日期：2026-08-19
> 当前工作树：`codex/moonlight-complete-upgrade` / `41483b417`（M8 通道边界与 M9 SSH 多窗口交接增量）
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

- M8 WebMessagePort 已完成 API 23 兼容双栈的生产边界：版本/会话/generation/端口实例 fence、严格 JSON 类型、超前 ACK 拒绝、UTF-8 字节预算、控制帧优先且线上序号单调；生产 flag 仍默认关闭，ArrayBuffer 批量等待 API 26 SDK/真机证据。
- M9 SSH 认证后窗口 handoff 已补齐多标签语义：交接只移除已经转移的 host，源页保留其他 SSH 标签并切换到下一个会话；没有剩余标签才返回源页。目标窗口仍复用现有 `RemoteSessionWindowCoordinator`，不改变密码/Key/KBI/MFA/Host Key 流程。
- 最近 SSH-only 提交：`493601b10`（有序端口投递）、`05fab8f48`（计划指针）、`41483b417`（多标签窗口交接）。精确 `default@OhosTestCompileArkTS` 与 `assembleHap` 均已通过；`ohosTest@OhosTestCompileArkTS` 仍受环境中未注册的 `00306054` 任务阻塞。
- 仍未宣称完成：API 26 SDK/目标设备、真实可达 SSH endpoint 的成功鉴权与 SFTP/转发/后台/多窗口 E2E、PC 窗口吸附/沉浸状态的实机验收。

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

这些文件位于临时目录，不作为仓库制品。账本保留命令、hash 和观察结果；阶段验收前重新采集最终 SSH 页面证据。

### 7.3 已证明与未证明

已证明：两个目标可通过 HDC 连接；当前 HAP 在 API 23 Phone/PC 环境可启动；PC 使用系统自由窗口，当前窗口初始区域为 2090×1394 px；PC 可以进入现有 SSH 主机列表。关闭残留的诊断日志 Sheet 后，点击 SSH 主机正确进入既有 Host Key 预检；TCP 不可达时保留在 HostList 的错误 Sheet，不会进入 Terminal，也不会创建独立会话窗口。

尚未证明：成功 Host Key 校验后的密码/Key/KBI/MFA 认证、终端焦点、软/硬键盘、SFTP、转发、后台/PiP、SSH 独立窗口和多主机并行。当前唯一测试 endpoint 离线，因此本轮只证明了预检错误路径；不得把主机卡片的延迟探测文案当成 SSH 端口可达证据。没有成功路径证据前，S0 不能标为完成。

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
| M9 | M8 前置 | SSH handoff 已落地；PC 多窗口/系统窗口状态待验收 | 策略覆盖 | PASS | PASS | PC 真机/多主机待验 | 待最终实机复核 | DEVICE_PENDING |

## 10. S0 下一步

1. 为成功认证、终端、SFTP、转发和独立窗口准备可达 SSH endpoint；当前离线 endpoint 只保留错误态证据。
2. 精确提交 M0 SSH-only 增量；不得暂存本账本列出的并行脏文件。
3. 进入 M1 搜索桥和 Profile/快捷能力前，继续复用既有 SearchAddon、`SshSessionStore` 与 `SshTerminalTabStore`。

本轮最终构建命令均于 2026-08-19 在 `0c6be42e5` 加 M0 未提交增量上执行，使用 `source scripts/macos_env.sh` 后的 DevEco Hvigor 环境：

```sh
hvigorw --mode module -p module=entry -p product=default default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon
hvigorw --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --no-daemon
```
