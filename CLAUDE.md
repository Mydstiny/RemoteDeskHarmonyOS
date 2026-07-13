# CLAUDE.md — 鸿蒙PC双协议远程桌面客户端

> **会话启动协议**：每次新会话的第一条消息，必须先执行：
> 1. 读取 `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md` — 上一个 agent 的接力信息
> 2. 读取 `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md` — 当前任务队列
> 3. 读取 `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\CODEWALK.md` — 永久项目知识 (首次或变更后)
> 4. 读取 `C:\Users\14288\.claude\projects\C--Users-14288\memory\MEMORY.md` 索引
> 5. 读取 `remote-desktop-project-state.md` 记忆
> 6. 向用户汇报：当前阶段、最新 commit、构建状态、活跃任务、关键规则
> 7. 从 TASKS.md 领取任务或等待用户指令
>
> **会话结束协议**：每次结束工作前，必须：
> 1. 更新 `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md` — 元信息、上次会话摘要、下一步
> 2. 更新 `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md` — 标记完成 + 新增任务
> 3. 更新 `remote-desktop-project-state.md` 记忆
> 4. 更新 `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\CODEWALK.md` — 仅当有新架构决策/通用坑位/编码规则时
> 5. git commit (按 [[always-git-commit]] 规则)
> 6. 构建验证 (按 [[build-before-git]] 规则)

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

## 本地参考
- API 23 文档：`C:\Users\14288\harmonyos_support\openharmony-docs-api23\zh-cn\application-dev\reference\`
- Claude 记忆：`C:\Users\14288\.claude\projects\C--Users-14288\memory\`
- 构建命令：见 `CODEWALK.md` §8

---

> **此文件只包含 Claude 特有的协议和行为规则。共享知识在 Mission_transformation。**
