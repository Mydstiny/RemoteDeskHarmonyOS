# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目

HarmonyOS NEXT PC 原生多协议远程桌面客户端 (RDP + RustDesk + SSH/SFTP + VNC)，
ArkTS/ArkUI 前端 + C++ NAPI 原生层 + Rust FFI 协议桥，附带华为云同步、本地加密和主机安全锁。
API 23 是兼容性上限 (`compileSdkVersion 6.1.0(23)`)。

## 沟通语言

**所有面向用户的回复一律使用中文。** 仓库的代码注释、`docs/codex/` 共享状态和本文件都是中文，
英文回复会脱离项目语境。代码标识符和日志字符串沿用仓库既有风格（英文标识符 + 中文注释）。

## 会话启动

在写代码前先读取仓库内的共享状态 (`AGENTS.md` 定义的流程)：

1. `docs/codex/CURRENT.md` — 当前阶段、活动分支、blocker
2. `docs/codex/QUEUE.md` — 任务队列
3. `docs/codex/DECISIONS.md` — **D-001..D-019 长期有效的架构决策与坑位，改代码前必读**
4. `docs/codex/HANDOFF.md` — 上一轮交接细节与标准命令（仅在需要时）

`AGENTS.md` 中写死的 `C:\Users\14288\...` 路径属于原维护者机器，本 checkout
(`D:\Codespace\matepad_vpn\RemoteDeskHarmonyOS`) 不适用；仓库内 `docs/codex/` 才是权威共享状态。

## 构建

本机 SDK 通过目录联结 `C:\ohos_sdk` → `C:\Program Files\Huawei\DevEco Studio\sdk`（规避路径空格）。

```powershell
# 完整 HAP 构建（等价于双击 build_hap.bat）
$env:DEVECO_SDK_HOME = 'C:\ohos_sdk'
$env:OHOS_SDK_HOME = 'C:\ohos_sdk'
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' `
  'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' `
  --mode module -p module=entry -p product=default assembleHap `
  --analyze=normal --parallel --incremental --daemon
```

产物：`entry/build/default/outputs/default/entry-default-{unsigned,signed}.hap`

原生依赖（clean clone 或 RustDesk/Opus 输入变化后才需要重建，产物已在 `libs/` 就位）：

```bash
bash scripts/build_opus_ohos.sh all            # arm64-v8a + x86_64
bash scripts/build_rustdesk_ffi_ohos.sh all
bash scripts/build_freerdp_ohos.sh all         # 仅 USE_REAL_FREERDP 需要
bash scripts/build_ffmpeg_softdec_ohos.sh <arch>
```

x86_64 单独构建见 `build_x64_deps.bat`（内含 Clang/sysroot/`OPUS_LIB_DIR` 环境变量样板）。
`libs/` 缺库时 CMake 会给出可执行的错误提示——照提示跑对应脚本，不要改 CMake 绕过。

## 测试

| 层 | 命令 / 入口 |
|---|---|
| ArkTS 编译门 | `default@OhosTestCompileArkTS`（测试模块用 `ohosTest@OhosTestCompileArkTS`）— **不要用已废弃的 `default@OhosTestBuildArkTS`** |
| ArkTS 本地单测 | `entry/src/test/*.test.ets`（hypium），全部在 `entry/src/test/List.test.ets` 手动注册 |
| ArkTS 设备测试 | `entry/src/ohosTest/ets/test/`，`onDeviceTest` 任务 |
| Native C++ | `cmake -S entry/src/main/cpp -B <build> -DRDP_BUILD_TESTS=ON -DRDP_TESTS_ONLY=ON` → `cmake --build <build> --target rdp_native_tests` → 运行 `rdp_native_tests[.exe]` |
| Rust | `cargo test --manifest-path rustdesk_ffi/Cargo.toml --lib --no-default-features` |
| 合规门 | `pwsh -File scripts/verify_open_source_release.ps1 -Mode Light`（PR required check；tag 走 `-Mode Release`） |

**新增测试必须两处注册**：`.test.ets` 要 import + 调用进 `List.test.ets`；native 测试要加进
`entry/src/main/cpp/CMakeLists.txt` 的 `rdp_native_tests` 源文件列表。
跑单个 ArkTS 测试没有 CLI filter——临时在 `List.test.ets` 里只保留目标调用。
`RDP_TESTS_ONLY=ON` 让 CMake 在配置完测试后 `return()`，跳过全部 OHOS/FreeRDP/Rust 链接，
是唯一能在宿主机上跑 native 测试的方式。

按变更范围选择验证强度（`AGENTS.md` 的风险分级表）：文档 → `git diff --check` + Light；
ArkTS/UI → 定向测试 + `OhosTestCompileArkTS` + `assembleHap` + Light；
C/C++/Rust/FFI → 定向 native/Rust 测试 + 受影响 ABI + `assembleHap` + Light。

## 架构

### 分层

```
entry/src/main/ets/pages/          ArkUI @Entry 页面（RemoteDesktop.ets 9k+ 行，是会话总控）
entry/src/main/ets/components/     可复用 UI（含 dialogs/ hostadd/ resourceadd/ 子目录）
entry/src/main/ets/services/       112 个文件：Service（有状态/有 IO）+ Policy（纯函数）
entry/src/main/ets/services/ExtensionLoader.ets   ← 唯一的 NAPI 门面（单例）
entry/src/main/ets/types/rdpnapi.d.ts             ← librdpnapi.so 的 TS 声明（ABI 契约）
        │
entry/src/main/cpp/                napi_init.cpp 注册各子系统 *Napi::Init(env, exports)
        ├── extensions/  会话生命周期、teardown 执行器
        ├── rdp/         FreeRDP 适配 + 帧调度/损伤累积/GL 上传门/认证策略
        ├── rustdesk/    rustdesk_bridge.cpp → Rust FFI
        ├── ssh/ vnc/ terminal/ render/ audio/ input/ security/
        │
rustdesk_ffi/src/                  Rust: 协议会话、加密通道、wire 编解码、terminal_core
freerdp/                           git 子模块（分支 freerdp-ohos）
```

ArkTS 只通过 `import rdpnapi from 'librdpnapi.so'` 触达原生层，且实际只有三处
（`ExtensionLoader.ets`、`RemoteDesktop.ets`、`napi/TerminalCoreBridge.ets`）。
新增原生能力时改动是成套的：C++ 实现 → `napi_init.cpp` 子系统 Init → `rdpnapi.d.ts` 声明 →
`ExtensionLoader` 方法（try/catch + `ExtensionResult` 包装，绝不让原生异常穿透到 UI）。

### Policy 模式（本仓库最重要的约定）

`services/*Policy.ets` 是**无依赖的纯函数模块**——不 import UI、不碰 NAPI、不做 IO，
把判定逻辑从 9000 行的页面里抽出来，从而能在 `entry/src/test/` 里离线单测。
`Service` 才持有状态、RDB、网络和 NAPI 句柄。
写新交互逻辑时默认先落成 Policy + 单测，页面只负责调用与渲染。
同一模式在 native 侧重复：`rdp_*_policy.cpp` / `audio_queue_policy.cpp` 等纯 C++ 策略进
`rdp_native_tests`，带 OHOS 依赖的部分留在适配器里。

### 会话边界

协议会话、渲染、音频、输入、剪贴板、文件传输各自独立。可选能力（音频、剪贴板、共享目录）
失败不得破坏已建立的桌面会话。云同步与加密写入必须先确认本地事务成功再更新缓存或推送。

## 关键约束

- **API 23 上限**（D-007）：改 HarmonyOS API 前查本地 API 23 文档；禁止 `@kit.uiMaterial` 等 API 26 专有能力。
  ArkTS 严格模式要求显式接口/类型，避免 `any`/`unknown`，动态键用方括号索引。
- **`freerdp/` 子模块常年显示 dirty** —— 这是交叉编译产物导致的，**不要 reset**，重置要重新编译数分钟。
- **`USE_REAL_FREERDP`**：CMake 默认 OFF，但 `entry/build-profile.json5` 用
  `-DUSE_REAL_FREERDP=ON` 覆盖，所以正常 HAP 构建走真实 FreeRDP，需要 `libs/freerdp-ohos/<abi>/` 预编译产物。
  `RUSTDESK_USE_REAL_CORE` 在 CMakeLists 中硬编码开启。
- **双 ABI**：`arm64-v8a` + `x86_64`。Rust 目标分别是 `aarch64-unknown-linux-ohos` /
  `x86_64-unknown-linux-ohos`，必须配套 Clang target 与 sysroot（D-008）。
- **OHOS NDK 不是完整 Linux**（D-016）：`std::random_device`、`std::filesystem` 有已知限制；
  用 OHOS Crypto API（`Crypto_DataBlob.len` 单位是字节，`OH_CryptoRand` 实例一次性）并链接 `libohcrypto.so`。
- **RustDesk 流正确性**（D-015）：ArkTS/NAPI 入队成功不算数，必须有日志/计数证明流循环真正消费了消息；
  加密 TCP 读取要跨超时重试保留半帧，`read_exact()` 重试不得丢弃已读字节。
- **UI 生命周期**（D-017）：`bindSheet` 失败通常是宿主节点挂载时机问题而非数量上限；
  PIP/渲染器把 `ABOUT_TO_*` 当过渡态，等 `STOPPED`/`ERROR`，重挂载前显式交还 surface/renderer/decoder 所有权。
- **私有输入不进 Git**：`build-profile.json5`、`local.properties`、`agconnect-services.json`
  已被 `.gitignore` 排除（各有 `.example` 模板）；签名材料、口令、token、真实主机地址同理。

## Git 与提交

- 一个任务一个分支：`main` → `pull --ff-only` → 功能分支 → PR → required `open-source-compliance` → merge。
  同一时间只保留一个活动任务分支（D-002）。
- 禁止 `git add -A`、`git push --all`、直接 push `main`、force-push、`--no-verify`。只暂存本任务明确文件。
- 所有提交用 `git commit -s`（DCO，见 `CONTRIBUTING.md`）。
- hook 路径是 `.githooks`（`pwsh -File scripts/install_git_hooks.ps1` 安装）；pre-push 会拦截私有历史。
- 依赖 / proto / license / gitlink 变化必须在同一 PR 内更新 `docs/compliance/SBOM.spdx.json`、
  `NOTICE`、provenance 和哈希，否则合规门会拒绝（D-012）。
- 本仓库主协议为 AGPL-3.0-or-later。
