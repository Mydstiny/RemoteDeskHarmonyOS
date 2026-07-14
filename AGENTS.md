# AGENTS.md — RemoteDeskHarmonyOS Codex 开发规则

## 项目与唯一工作区

- 项目：HarmonyOS NEXT PC 四协议远程桌面客户端（RDP、RustDesk、SSH/SFTP、VNC）。
- 唯一开发、构建、提交和发布工作区：
  `C:\Users\14288\DevEcoStudioProjects\RemoteDesktop`。
- 禁止创建或使用持久 Git worktree。合规 hook 创建并立即销毁的临时校验目录不属于开发工作区。
- 不依赖第三方 skills、Superpowers 或 Claude 中转流程；使用 Codex 原生能力、Git、项目脚本和本地 API 23 文档。

## 每个 session 的启动流程

1. 读取 Codex-only 当前状态：
   `C:\Users\14288\.codex\projects\C--Users-14288\memory\CURRENT.md`。
2. 读取精简任务队列：
   `C:\Users\14288\.codex\projects\C--Users-14288\memory\QUEUE.md`。
3. 仅在涉及架构/历史约束时读取：
   `C:\Users\14288\.codex\projects\C--Users-14288\memory\DECISIONS.md`。
4. 运行 `powershell -File scripts/dev_workflow.ps1 status`，核对实际 Git 状态。
5. 向用户报告：当前阶段、活动任务、当前分支/commit、相对 `main` 状态、最近验证和下一步。

不要在每次启动时读取历史 HANDOFF/TASKS/CODEWALK 全文。旧 Claude/Codex 中转站仅为只读归档。

## 一个任务一个分支，而不是一个 session 一个分支

- 如果 `CURRENT.md` 或实际 Git 显示存在未完成活动分支，新 session 必须继续该分支；不得创建新分支。
- 只有在没有活动任务、工作树干净、`main == origin/main` 时，才能运行：
  `powershell -File scripts/dev_workflow.ps1 start -Task <task-name>`。
- 同一时间只允许一个日常活动 `codex/...` 分支。新任务必须等待当前任务已合并或明确归档。
- 标准闭环：
  `main` → `pull --ff-only` → `codex/...` → 修改/验证/commit → push → PR →
  required `open-source-compliance` → merge → `main` → `pull --ff-only` → 删除已合并分支。
- session 中断时允许在同一活动分支做清晰 checkpoint commit，并在 `CURRENT.md` 写明下一步；不另开分支。

## 修改与提交规则

- 开始前检查 `git status --short --branch` 和用户已有修改。只暂存本任务明确文件。
- 禁止 `git add -A`、`git push --all`、`git push --mirror`、直接 push `main`、force-push、恢复旧公开 tag，或推送 `refs/archive/*`。
- 不提交真实 `build-profile.json5`、`local.properties`、`agconnect-services.json`、签名材料、口令、token、本机路径、用户数据或 session 临时文件。
- 修改 HarmonyOS API 前先查本地 API 23 文档；依赖/proto/license/gitlink 变化必须同步更新 SBOM、NOTICE、provenance 和哈希。
- 仓库功能变更必须 commit；纯调查且没有文件修改时不制造空 commit。

## 按风险分级验证

| 变更范围 | 最低验证 |
|---|---|
| 文档、流程、纯元数据 | `git diff --check` + Light 合规门 |
| ArkTS/UI/策略 | 定向测试或测试编译 + `default@OhosTestCompileArkTS` + `assembleHap` + Light |
| C/C++/Rust/FFI | 定向 native/Rust 测试 + 受影响 ABI + `assembleHap` + Light |
| 发布/tag/依赖升级 | clean clone、全测试/设备矩阵、双 ABI、Release gate |

构建命令和当前阻塞记录在 `CURRENT.md`；不要用旧的 `default@OhosTestBuildArkTS` 作为验收门。

## 本地统一历史库

- 所有旧分支、旧 tag、回滚节点和私有历史通过 `refs/archive/*` 保留在同一 `.git` 对象库中。
- 离线完整 bundle 和 manifest 位于：
  `C:\Users\14288\DevEcoStudioProjects\RemoteDesktopHistory\`。
- 使用 `powershell -File scripts/history_tool.ps1 list|find|show|diff|restore|verify-bundle` 查询或恢复历史。
- `refs/archive/*` 可能包含已撤销凭据和旧私有历史，只允许本地读取，绝不上传 GitHub。
- 模组回退必须从最新公开 `main` 新建 `codex/rollback-...`，恢复目标路径后重新构建和测试；不得把整个旧历史 merge 回 `main`。

## session 结束流程

1. 运行与变更范围匹配的验证，并记录准确结果。
2. 更新 `CURRENT.md`：活动分支、commit、已完成、验证、下一步、blocker。
3. 更新 `QUEUE.md`：完成项移除或归档，只保留 Now / Next / Later。
4. 只有出现长期有效的架构规则或通用坑位时才更新 `DECISIONS.md`。
5. 任务完整完成时必须走 push/PR/required check/merge，并回到同步的 `main`；未完成则留在同一活动分支。

历史记录按月归档，不在 CURRENT/QUEUE 中无限追加。

## 本地参考

- API 23：`C:\Users\14288\harmonyos_support\openharmony-docs-api23\zh-cn\application-dev\reference\`
- Codex-only 中转站：`C:\Users\14288\.codex\projects\C--Users-14288\memory\`
- 历史 bundle：`C:\Users\14288\DevEcoStudioProjects\RemoteDesktopHistory\`
