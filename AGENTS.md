# AGENTS.md — RemoteDeskHarmonyOS Codex 开发规则

## 项目与唯一工作区

- 项目：HarmonyOS NEXT PC 四协议远程桌面客户端（RDP、RustDesk、SSH/SFTP、VNC）。
- 每台设备使用自己的本地 checkout；Windows 的默认路径是
  `C:\Users\14288\DevEcoStudioProjects\RemoteDesktop`，macOS 使用当前本地工作区。
- 禁止创建或使用持久 Git worktree。合规 hook 创建并立即销毁的临时校验目录不属于开发工作区。
- 不依赖第三方 skills、Superpowers 或 Claude 中转流程；使用 Codex 原生能力、Git、项目脚本和本地 API 23 文档。

## 每个 session 的启动流程（强制门禁）

1. 无论 session 从哪个父目录启动，先定位并进入本项目根目录；读取本文件以及
   工作区根目录的 `AGENTS.md`（存在时）。
2. 读取脱敏共享状态短卡：`docs/codex/CURRENT.md`；机器字段以
   `docs/codex/STATE.json` 为准，不读取原始 Codex 记忆。
3. 读取精简任务队列：`docs/codex/QUEUE.md`。
4. 仅在状态或任务链接要求时读取：`docs/codex/DECISIONS.md`、
   `docs/codex/HANDOFF.md`、计划或 `docs/codex/archive/YYYY-MM/`。
5. 根据平台运行 `scripts/dev_workflow.ps1 status` 或
   `scripts/sync_workspace.sh status`，核对实际 Git 状态和 `review=...` 判定。
6. 向用户报告：当前阶段、活动任务、当前分支/commit、相对 `main` 状态、最近验证、下一步和 blocker。

若没有完成上述启动门禁，不得开始新的代码修改或声称已经完成任务。正常启动只消费短卡和队列；归档内容按需查询，不作为每 session 的固定输入。

### 状态与审查去重

- `scripts/codex_state.mjs` 是跨平台状态计算器，由 Bash/PowerShell 工作流入口调用。
- `STATE.json` 保存任务、基线、计划路径、审查范围和 blocker；`REVIEW_RECEIPTS.jsonl` 只保存结构化审查事实。
- 只有任务 `base`、计划 hash、声明的代码范围树 hash 同时匹配 `status=PASS` receipt，才输出 `SKIP_FULL_REVIEW`。
- 只有文档变化时沿用代码审查；代码、计划、基线或审查范围变化时输出 `REVIEW_REQUIRED`，并给出增量路径。
- `BLOCKED`/`RESUME_REVIEW` 必须复用原 reviewer task ID；没有报告不得写 PASS，也不得因为上下文压缩重复派发。
- 未提交代码位于声明范围内时，审查状态保持 `REVIEW_REQUIRED`，先做 checkpoint commit。

不要复制或读取 Windows/Mac 的 Codex 原始记忆目录；需要共享的内容只能整理进
`docs/codex/`。旧 Claude/Codex 中转站仅为各设备本地只读归档。

## 一个任务一个分支，而不是一个 session 一个分支

- 如果 `CURRENT.md` 或实际 Git 显示存在未完成活动分支，新 session 必须继续该分支；不得创建新分支。
- 只有在没有活动任务、工作树干净、`main == origin/main` 时，才能运行：
  `powershell -File scripts/dev_workflow.ps1 start -Task <task-name>`。
- 同一时间只允许一个日常活动 `codex/...` 分支。新任务必须等待当前任务已合并或明确归档。
- 标准闭环：
  `main` → `pull --ff-only` → `codex/...` → 按计划逐步修改/验证/commit →
  子 agent 独立复核 → 修复复核问题并重新验证/commit → push → PR →
  required `open-source-compliance` → merge → `main` → `pull --ff-only` → 删除已合并分支。
  只有子 agent 明确复核通过后才能合并；复核发现问题时必须留在任务分支修复，不能带着未解决的问题合并。
- session 中断时允许在同一活动分支做清晰 checkpoint commit，并在 `CURRENT.md` 写明下一步；不另开分支。

## 修改与提交规则

- 开始前检查 `git status --short --branch` 和用户已有修改。只暂存本任务明确文件。
- 禁止 `git add -A`、`git push --all`、`git push --mirror`、直接 push `main`、force-push、恢复旧公开 tag，或推送 `refs/archive/*`。
- 不提交真实 `build-profile.json5`、`local.properties`、`agconnect-services.json`、签名材料、口令、token、本机路径、用户数据或 session 临时文件。
- 修改 HarmonyOS API 前先查本地 API 23 文档；依赖/proto/license/gitlink 变化必须同步更新 SBOM、NOTICE、provenance 和哈希。
- 仓库功能变更必须 commit；纯调查且没有文件修改时不制造空 commit。

## 每次改动完成后的强制 DevEco 验证

任何代码、ArkTS、native、Rust、测试、配置或流程文件改动，在提交、复核、合并或交付前都必须执行以下两项 Hvigor 门禁；它们是所有风险级别的共同最低要求，不能用旧日志或上一 session 的结果代替：

```sh
source scripts/macos_env.sh
hvigorw --mode module -p module=entry -p product=default default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon
hvigorw --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --no-daemon
```

Windows 使用 DevEco 自带的 `hvigorw.js`/`hvigorw.bat` 执行相同的 `module=entry`、`product=default` 和任务名，并使用非 daemon 方式完成可判定的退出。两项都必须返回成功；否则任务保持未完成，失败原因必须记录在 `docs/codex/CURRENT.md` 的 blocker 中。`default@OhosTestBuildArkTS` 是旧门，不得作为替代验收项。对 ArkTS 测试模块有影响时，另加 `ohosTest@OhosTestCompileArkTS`。

## 按风险分级验证

| 变更范围 | 最低验证 |
|---|---|
| 文档、流程、纯元数据 | 强制 Hvigor 两项 + `git diff --check` + Light 合规门 |
| ArkTS/UI/策略 | 定向测试或测试编译 + `default@OhosTestCompileArkTS` + `assembleHap` + Light |
| C/C++/Rust/FFI | 定向 native/Rust 测试 + 受影响 ABI + `assembleHap` + Light |
| 发布/tag/依赖升级 | clean clone、全测试/设备矩阵、双 ABI、Release gate |

构建命令、准确的成功/失败输出和当前阻塞记录在 `CURRENT.md`；不要用旧的 `default@OhosTestBuildArkTS` 作为验收门。

## 本地统一历史库

- 所有旧分支、旧 tag、回滚节点和私有历史通过 `refs/archive/*` 保留在同一 `.git` 对象库中。
- 离线完整 bundle 和 manifest 位于：
  `C:\Users\14288\DevEcoStudioProjects\RemoteDesktopHistory\`。
- 使用 `powershell -File scripts/history_tool.ps1 list|find|show|diff|restore|verify-bundle` 查询或恢复历史。
- `refs/archive/*` 可能包含已撤销凭据和旧私有历史，只允许本地读取，绝不上传 GitHub。
- 模组回退必须从最新公开 `main` 新建 `codex/rollback-...`，恢复目标路径后重新构建和测试；不得把整个旧历史 merge 回 `main`。

## session 结束流程

1. 运行强制的 Hvigor `default@OhosTestCompileArkTS` 和生产 `assembleHap`，再运行与变更范围匹配的附加验证，并记录准确结果。
2. 更新 `STATE.json` 和 `CURRENT.md`：活动分支、commit、阶段、已完成、验证、下一步、blocker、review 状态。
3. 更新 `QUEUE.md`：完成项移除，只保留 Now / Next / Later；旧事实进入月度 archive。
4. 只有出现长期有效的架构规则或通用坑位时才更新 `DECISIONS.md`；独立审查写入 `REVIEW_RECEIPTS.jsonl`，不写 raw session transcript。
5. 任务完整完成时必须走 push/PR/required check/merge，并回到同步的 `main`；未完成则留在同一活动分支。

`CURRENT.md` 不超过 120 行，`QUEUE.md` 只保留短队列。历史记录按月归档，不在 CURRENT/QUEUE 中无限追加。

## 本地参考

- API 23：`C:\Users\14288\harmonyos_support\openharmony-docs-api23\zh-cn\application-dev\reference\`
- 跨设备共享状态：`docs/codex/`
- 历史 bundle：`C:\Users\14288\DevEcoStudioProjects\RemoteDesktopHistory\`
