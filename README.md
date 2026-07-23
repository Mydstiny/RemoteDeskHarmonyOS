# RemoteDeskHarmonyOS

面向 HarmonyOS NEXT PC 的原生多协议远程桌面客户端。当前版本为
**1.0.8**（`versionCode 1000008`），在一个 ArkUI 工作台中提供 RDP、
RustDesk 和 SSH/SFTP 连接，并保留正在验证的 VNC 原生适配路径；同时集成
华为云数据同步、本地加密与备份、后台视频、画中画和多窗口响应式体验。

> 当前仓库仍处于测试与发布验证阶段。GitHub 中标记为 `unsigned` 的 HAP
> 未经应用签名，仅用于开发测试；它不是 AppGallery 或生产分发安装包。

## 功能概览

| 能力 | 当前实现 |
|---|---|
| RDP | 基于 FreeRDP/WinPR，支持证书预检、Microsoft/Azure AD 凭据、音视频、输入、纯文本剪贴板和共享目录 |
| RustDesk | 原生 Rust FFI 客户端链路，支持 rendezvous/relay/direct、视频、音频、输入、纯文本剪贴板和文件传输，并改进异步会话恢复 |
| SSH/SFTP | 终端、密钥与密码认证、主屏 scrollback、文件浏览、上传/下载、取消和安全续传 |
| VNC | 保留原生适配代码，当前版本尚未开放可用连接入口，仍需完成设备验证 |
| 主机工作台 | 主机添加与编辑、工作组、连接入口、协议筛选与真实能力状态 |
| 数据与安全 | RDB、本地 AES-256-GCM 数据保护、HUKS/生物认证集成、备份恢复与主机安全锁建设 |
| 华为云同步 | 七张固定业务表的显式同步、选择控制、重试、下载回滚与本地恢复隔离 |
| HarmonyOS 体验 | PC/Pad/Phone 响应式布局、沉浸式浮动导航、后台视频、画中画与前后台恢复 |
| 1.0.8 更新 | 远程视频后台播放、VP9 切后台崩溃修复、PIP 生命周期修复、启动握姿权限与响应式引导 |
| 反馈与社区 | 设置内支持邮箱反馈、获取远程更新的畅联群聊二维码以及保存到相册 |

部分能力依赖远端服务器配置、HarmonyOS 设备形态、系统权限和本地私有
AGConnect 配置。正式 Release 还需要通过完整四协议设备矩阵与凭据轮换
确认；仓库不会把未完成的外部验证描述为已经通过。

## 支持平台与技术栈

- HarmonyOS NEXT，项目以 API 23 SDK 为当前开发基线。
- ArkTS + ArkUI 声明式 UI，使用 HarmonyOS 原生 Kit。
- C/C++ NAPI 扩展承载 FreeRDP、VNC、音视频、渲染和输入桥接。
- Rust 承载 RustDesk 协议桥和 SSH 终端相关逻辑。
- 构建系统为 DevEco Studio Hvigor；当前产物覆盖 ARM64 与 x86_64 原生库。

## 架构

```text
ArkUI pages/components
        │
        ├── services / policies / RDB / cloud coordination
        │
        └── rdpnapi (NAPI boundary)
              ├── FreeRDP / WinPR ── RDP
              ├── rustdesk_ffi ───── RustDesk
              ├── libssh2 / terminal core ── SSH/SFTP
              ├── VNC adapter
              └── decoder / renderer / audio / input bridges
```

协议会话、渲染、音频、输入、剪贴板和文件传输保持明确边界。可选能力失败
不应破坏已经建立的桌面会话；云同步和加密写入必须先确认本地事务成功，
再更新缓存或请求推送。

## 仓库结构

| 路径 | 用途 |
|---|---|
| `AppScope/` | 应用级清单、版本与资源 |
| `entry/src/main/ets/` | ArkTS 页面、组件、模型、服务和策略 |
| `entry/src/main/cpp/` | NAPI、协议适配、渲染、音视频与原生测试 |
| `rustdesk_ffi/` | RustDesk Rust FFI、协议会话与 Rust 测试 |
| `freerdp/` | 指向本仓库公开 `freerdp-ohos` 分支的 FreeRDP 子模块 |
| `scripts/` | 依赖构建、SBOM、合规、clean-clone 和 Git hook 脚本 |
| `docs/compliance/` | SPDX SBOM、来源、发布门禁、回滚和开源合规记录 |
| `LICENSES/` | 项目与第三方许可证文本 |

## 获取源码

```powershell
git clone --recurse-submodules https://github.com/Mydstiny/RemoteDeskHarmonyOS.git
Set-Location RemoteDeskHarmonyOS
```

如果已普通 clone，执行 `git submodule update --init --recursive`。FreeRDP
OHOS 修改历史位于同一 GitHub 仓库的 `freerdp-ohos` 分支；主分支通过
gitlink 固定到可复现修订。

## Windows/macOS 双端协作

源码、Git 历史和子模块可以通过 GitHub 在 Windows 与 MacBook 间迁移；跨设备共享的脱敏任务状态位于
`docs/codex/`。本机 Codex 原始记忆、DevEco SDK、签名材料、AGConnect secret、构建缓存、日志和真实用户数据不进入仓库。
完整流程见 [`docs/CROSS_DEVICE_GITHUB_WORKFLOW.md`](docs/CROSS_DEVICE_GITHUB_WORKFLOW.md)。

Mac 首次 clone 后执行：

```sh
git config core.hooksPath .githooks
chmod +x scripts/sync_workspace.sh .githooks/pre-push
source scripts/macos_env.sh
./scripts/sync_workspace.sh status
```

`scripts/macos_env.sh` 会自动发现 DevEco Studio SDK、内置 Node/Hvigor/ohpm、
OHOS LLVM/CMake/Ninja 和 rustup 管理的 cargo/rustc。它只设置当前 shell，
不会写入私有配置；PowerShell 7 仍需单独安装，或通过 `POWERSHELL_COMMAND`
指定用户级 `pwsh` 路径。

每次开始任务必须从干净的 `main` 同步远端并创建任务分支。Windows 使用：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/dev_workflow.ps1 start -Task <lowercase-kebab-task>
```

macOS/Linux 使用：

```sh
./scripts/sync_workspace.sh start <lowercase-kebab-task>
```

两个入口都会执行 `fetch --prune`、`pull --ff-only origin main`、递归子模块同步、工作区脏检查和活动分支检查；不会自动覆盖或 stash 未提交修改。Mac 端需要 PowerShell 7，以便 pre-push hook 运行同一套开源合规门禁；hook 也会发现用户级 `pwsh` 安装。

没有网络时，可在已有副本运行 `scripts/create_migration_bundle.ps1` 生成包含公开 `main` Git bundle、源码归档、FreeRDP 子模块归档和迁移清单的脱敏包；它不包含私钥、SDK、日志、构建产物或私有 Codex 记忆。

## 本地私有配置

仓库不会跟踪签名证书、口令、AGConnect secret、API key、本机 SDK 路径
或真实用户数据。首次构建时按示例创建本地文件：

- `build-profile.example.json5` → 本地 `build-profile.json5`
- `local.properties.example` → 本地 `local.properties`
- `entry/src/main/resources/rawfile/agconnect-services.example.json` → 本地
  `agconnect-services.json`

真实值只能保存在本机安全路径或 CI secrets。不要把这些文件加入 Git，
也不要在 issue、日志或截图中公开它们。

## 构建依赖

1. 安装 DevEco Studio 和 HarmonyOS API 23 SDK。
2. 安装 Git、PowerShell 7、Rust/Cargo，以及项目脚本所需的 C/C++ 工具链。
3. 准备上述本地私有配置。
4. 首次 clean clone 或 RustDesk/Opus 输入变化后构建双 ABI 原生依赖：

```text
bash scripts/build_opus_ohos.sh all
bash scripts/build_rustdesk_ffi_ohos.sh all
```

macOS 可先执行 `source scripts/macos_env.sh`；原生依赖脚本会自动使用
`/Applications/DevEco-Studio.app/Contents/sdk`（或 `DEVECO_SDK_HOME`）
并兼容 macOS 的 `shasum` 和 CPU 并行数。

FreeRDP、FFmpeg 或其他原生依赖变化时，使用 `scripts/` 下对应的 OHOS 构建
脚本，并同步更新来源、许可证、SBOM 和产物哈希。

## 构建 HAP

在 Windows PowerShell 中：

```powershell
$env:DEVECO_SDK_HOME = 'C:\Program Files\Huawei\DevEco Studio\sdk'
$env:OHOS_SDK_HOME = $env:DEVECO_SDK_HOME
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' `
  'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' `
  --mode module -p module=entry -p product=default assembleHap `
  --analyze=normal --parallel --incremental --daemon
```

在 macOS shell 中：

```sh
source scripts/macos_env.sh
hvigorw --mode module -p module=entry -p product=default assembleHap \
  --analyze=normal --parallel --incremental --daemon
```

常见输出目录：

```text
entry/build/default/outputs/default/entry-default-unsigned.hap
entry/build/default/outputs/default/entry-default-signed.hap
```

签名产物仅属于本地私有发布流程，不得上传到本仓库的 unsigned 测试
Release。

## 测试与验证

```powershell
# 开源合规轻量门禁
pwsh -File scripts/verify_open_source_release.ps1 -Mode Light

# 安装并确认本地 pre-push hook
pwsh -File scripts/install_git_hooks.ps1
git config --get core.hooksPath
```

其他主要验证入口：

- ArkTS：`default@OhosTestCompileArkTS` 与 `onDeviceTest` 任务图。
- Native：项目生成的 `rdp_native_tests` 测试程序。
- Rust：在 `rustdesk_ffi/` 执行 `cargo test --lib --no-default-features`。
- Clean clone：`scripts/verify_clean_clone_build.ps1`。
- 正式发布：`scripts/verify_open_source_release.ps1 -Mode Release`。

Release 模式还要求凭据轮换、完整设备矩阵和私有构建配置，不能用一次
Light 通过或一次本地 HAP 构建代替。

## 开发与 Push 流程

项目唯一标准工作区为：

```text
C:\Users\14288\DevEcoStudioProjects\RemoteDesktop
```

维护者和自动化 session 必须从公开、干净的 `main` 开始，并在同一工作区
创建 `codex/...` 功能分支：

```powershell
git switch main
git pull --ff-only
git switch -c codex/<task-name>
# 修改、测试、构建、运行 Light gate
git push -u origin codex/<task-name>
```

之后创建 PR，等待 required `open-source-compliance` 通过，再合入受保护的
`main`。合并后执行 `git switch main` 和 `git pull --ff-only`。

禁止从旧 worktree 或旧私有历史继续开发，禁止 `git push --all`、直接
推送 `main`、force-push 或恢复旧 tag。依赖、proto、许可证和构建输入
变化必须在同一 PR 更新 SBOM、NOTICE、provenance 与哈希。

## 开源许可证与对应源码

项目自有组合发行版采用 **AGPL-3.0-or-later**。FreeRDP、OpenSSL、
FFmpeg、libssh2、Mbed TLS、Opus、Rust crates 与 Huawei/OpenHarmony 包
保留各自许可证和分发条件。

请阅读：

- `LICENSE` 与 `LICENSES/`
- `NOTICE` 与 `THIRD_PARTY_NOTICES.md`
- `docs/compliance/SBOM.spdx.json`
- `docs/compliance/SOURCE_OFFER.md`
- `docs/compliance/AGPL_NETWORK_SOURCE_OFFER_POLICY.md`

公开二进制版本必须能够对应到完整源码、构建脚本、SBOM、第三方来源和
明确的源码修订。未发布的 unsigned draft 不代表正式 Release 验收完成。

## 参与贡献与安全报告

贡献要求见 `CONTRIBUTING.md`。提交默认采用 AGPL-3.0-or-later，并使用
Developer Certificate of Origin sign-off；PR 必须说明协议、ABI、schema、
权限和用户行为变化及相应验证证据。

安全问题请优先通过 GitHub Security Advisory 私密报告；备用联系方式与
敏感信息处理规则见 `SECURITY.md`。请勿在公开 issue 中提交凭据、主机
地址、证书、数据库备份或原始远程日志。
