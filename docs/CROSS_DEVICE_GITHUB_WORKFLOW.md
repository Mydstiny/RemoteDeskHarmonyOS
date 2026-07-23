# Windows/macOS 协作与迁移

本项目的 GitHub 仓库保存公开源码、测试、脚本、子模块指针和脱敏后的共享任务状态。Windows 与 MacBook 都可以修改代码、提交分支和创建 PR，但两台设备不能同时修改同一个任务分支。

## 哪些内容会迁移

- Git 历史、源码、测试、文档、脚本和 `freerdp` 子模块指针：通过 GitHub 或迁移包迁移。
- 跨设备共享记忆：`docs/codex/CURRENT.md`、`QUEUE.md`、`DECISIONS.md` 和 `HANDOFF.md`。
- 本机 SDK、DevEco Studio、Rust/C++ 工具链、签名文件、`local.properties`、`build-profile.json5`、AGConnect 配置、构建缓存和真实设备数据：每台设备独立配置，不进入 Git。
- Codex 的 Windows 本地原始记忆：不会直接上传；需要共享的内容必须整理进 `docs/codex/`，避免泄露本机路径、凭据、日志和设备信息。

## MacBook 首次迁移

有网络时，在 Mac 终端执行：

```sh
git clone --recurse-submodules https://github.com/Mydstiny/RemoteDeskHarmonyOS.git
cd RemoteDeskHarmonyOS
git config core.hooksPath .githooks
chmod +x scripts/sync_workspace.sh .githooks/pre-push
source scripts/macos_env.sh
./scripts/sync_workspace.sh status
```

`scripts/macos_env.sh` 只初始化当前 shell，会自动发现 Mac 上的 DevEco
Studio SDK、内置 Node/Hvigor/ohpm、OHOS LLVM/CMake/Ninja 和 rustup 的
cargo/rustc。它不会生成或复制签名、AGConnect、local.properties 或其他
私有配置。

如果普通 clone 没有拉取子模块：

```sh
git submodule update --init --recursive
```

Mac 端随后安装与项目兼容的 DevEco Studio、HarmonyOS API 23 SDK、Git、PowerShell 7、Rust/Cargo 和 native 工具链。私有配置通过安全渠道单独放入本机，不能从聊天记录或公开仓库复制密钥。

## 每次开始任务

Windows：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/dev_workflow.ps1 start -Task <lowercase-kebab-task>
```

macOS/Linux：

```sh
./scripts/sync_workspace.sh start <lowercase-kebab-task>
```

两个入口都会执行以下保护动作：

1. 只允许从 `main` 开始。
2. 工作区有未提交修改时立即停止，不自动覆盖、stash 或删除。
3. `git fetch --prune origin` 后执行 `git pull --ff-only origin main`。
4. 执行 `git submodule update --init --recursive`。
5. 拒绝已有未完成 `codex/...` 任务分支时开始第二个任务。
6. 创建新的 `codex/<task>` 分支，并提示先更新共享状态。

如果只是同步而不开始任务，可执行 `sync`：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/dev_workflow.ps1 sync
```

```sh
./scripts/sync_workspace.sh sync
```

## 修改、交接和合并

任务开始后，先更新 `docs/codex/CURRENT.md` 和 `docs/codex/QUEUE.md`，再修改代码。完成一个可交接阶段就提交一次 checkpoint；提交只包含本任务文件，使用 DCO sign-off：

```sh
git add <task-files>
git commit -s -m "fix(scope): describe the change"
git push -u origin codex/<task>
```

通过 GitHub PR 交接，PR 描述至少写明完成项、未完成项、验证结果、下一步和设备验收状态。另一台设备只在 PR 合并后重新从 `main` 开始；不要在两台设备上同时 checkout 并推进同一个活动分支。

任务完成闭环：

```text
main -> sync -> codex/<task> -> test -> commit -s -> push -> PR
     -> open-source-compliance -> merge -> main -> sync
```

禁止直接 push `main`、`git push --force`、`git push --all`、`git push --mirror`，也不要上传 `refs/archive/*`、签名文件、token、真实日志或用户数据。

## 推送前检查

仓库 hook 已由 `git config core.hooksPath .githooks` 启用。Mac 端 pre-push hook 会优先寻找 `pwsh`，因此需要安装 PowerShell 7；找不到时会明确拒绝推送，不会跳过开源合规检查。

```sh
./scripts/sync_workspace.sh doctor
./scripts/sync_workspace.sh finish-check
```

Windows 等价命令：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/dev_workflow.ps1 doctor
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/dev_workflow.ps1 finish-check
```

## 离线迁移包

可在 Windows 或已有项目副本中生成脱敏迁移包：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/create_migration_bundle.ps1 -OutputDirectory C:\tmp\RemoteDeskHarmonyOS-migration
```

迁移包包含公开 `main` 的 Git bundle、源码归档、`freerdp` 子模块归档和迁移清单，不包含未跟踪日志、构建产物、密钥或本机 Codex 原始记忆。Mac 端可以先解压并从 `RemoteDeskHarmonyOS-main.bundle` 克隆，再按清单添加 GitHub `origin`，最后执行 `./scripts/sync_workspace.sh status`。
