# AGENTS.md — 鸿蒙PC双协议远程桌面客户端 (Codex)

> **会话启动协议**：每次新会话的第一条消息，必须先执行：
> 1. 读取 `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md` — 上一个 agent 的接力信息
> 2. 读取 `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md` — 当前任务队列
> 3. 读取 `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\CODEWALK.md` — 永久项目知识 (首次或变更后)
> 4. 读取 `C:\Users\14288\.codex\projects\C--Users-14288\memory\MEMORY.md` 索引
> 5. 读取 `remote-desktop-project-state.md` 记忆
> 6. 向用户汇报：当前阶段、最新 commit、构建状态、活跃任务、关键规则
> 7. 从 TASKS.md 领取任务或等待用户指令
>
> **会话结束协议**：每次结束工作前，必须：
> 1. 更新 `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md` — 元信息、上次会话摘要、下一步
> 2. 更新 `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md` — 标记完成 + 新增任务
> 3. 更新 `remote-desktop-project-state.md` 记忆
> 4. 更新 `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\CODEWALK.md` — 仅当有新架构决策/通用坑位/编码规则时
> 5. git commit 并构建验证

## 项目定位
HarmonyOS NEXT PC 原生远程桌面客户端，四协议（RDP + RustDesk + SSH + VNC）、华为云同步、主机安全锁、沉浸光感UI。

## 当前阶段
Phase 5+ 完成 → Phase 6 (主机安全锁 40%) + Phase 7 (测试/发布)

## 权威知识源 (独立交换站)

| 文件 | 位置 |
|------|------|
| **CODEWALK.md** | `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\CODEWALK.md` |
| **HANDOFF.md** | `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md` |
| **TASKS.md** | `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md` |

> **编代码前先查 `CODEWALK.md`** — 里面有所有编码规则、架构约束和已知坑位。

## 唯一工作区与开源 Push 铁律

- 唯一允许进行开发、构建、提交和发布操作的工作区是
  `C:\Users\14288\DevEcoStudioProjects\RemoteDesktop`。
- 每个新任务必须先切到公开 `main`，执行 `git pull --ff-only`，再在同一
  工作区创建 `codex/...` 功能分支。除非用户明确重新授权，不得使用旧
  worktree，也不得从旧私有历史分支继续开发。
- 只暂存本任务文件。禁止 `git add -A` 混入用户文件，禁止
  `git push --all`、直接推送 `main`、force-push、推送与公开 `main`
  无祖先关系的历史，以及恢复已删除的旧 tag。
- 推送前必须确认 `core.hooksPath=.githooks`。`.githooks/pre-push` 会对实际
  推送 commit 运行开源合规门：普通分支为 Light，tag 为 Release。
- 标准流程固定为：公开 `main` → `git pull --ff-only` → `codex/...` →
  修改与验证 → push 功能分支 → PR → required `open-source-compliance`
  通过 → 合入受保护 `main` → 切回 `main` → `git pull --ff-only`。
- 依赖、proto、许可证或构建输入变化必须在同一 PR 更新 SBOM、NOTICE、
  provenance 和哈希。Release gate 未通过前禁止发布 tag 或正式二进制
  Release；未签名测试 HAP 只能按用户明确批准的 Draft/Pre-release 流程
  上传，且绝不能上传本地签名 HAP。

## 本地参考
- API 23 文档：`C:\Users\14288\harmonyos_support\openharmony-docs-api23\zh-cn\application-dev\reference\`
- Codex 记忆：`C:\Users\14288\.codex\projects\C--Users-14288\memory\`
- 构建命令：见 `CODEWALK.md` §8
- Git/Push 规则记忆：`open-source-git-workflow.md`

---

> **此文件只包含 Codex 特有的协议和行为规则。共享知识在 Mission_transformation。**
