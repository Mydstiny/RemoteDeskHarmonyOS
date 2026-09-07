---
name: remotedesk-harmonyos-dev
description: 开发、调查、排障和维护 RemoteDeskHarmonyOS；按问题检索项目架构、RDP/RustDesk/SSH-SFTP/VNC/Moonlight 经验、鸿蒙 API 与生命周期约束、数据安全、构建验证和开发历史。适用于此仓库及其 checkout；只有该项目任务才自动应用，通用鸿蒙问题只使用经核验且适用的条目。
---

# RemoteDesk HarmonyOS 开发

当前开发基准为 API 26（用户于 2026-09-07 确认）；API 23 保留为历史/兼容资料，应用 target/compatible 与 native 工具链分别核对。

本 skill 依赖 RemoteDeskHarmonyOS checkout，知识随仓库维护。支持调查、设计、实现、复核、交付和历史追溯；执行范围由用户当前请求决定。入口只选资料，不要求每次读完整知识库。

## 开始

1. 用 `git rev-parse --show-toplevel` 定位当前 checkout，确认存在 `AGENTS.md`、`docs/codex/STATE.json` 和 `entry/src/main/ets/services/ExtensionLoader.ets`。不在项目中时只做资料解释；需要操作仓库而无法定位时询问项目路径。
2. 按仓库 [AGENTS.md](../../../AGENTS.md) 读取 [CURRENT.md](../../../docs/codex/CURRENT.md)、[STATE.json](../../../docs/codex/STATE.json)、[QUEUE.md](../../../docs/codex/QUEUE.md)，运行平台 workflow 的 `status`。同一上下文已完成且文件未变时复用读取结果，涉及新变更或提交时重新核对 Git。
3. 报告真实分支、HEAD、相对 main、已有变化、阶段、验证边界和 blocker。已存在活动分支时继续该分支，保护用户已有修改。
4. “只分析/暂不改代码”保持只读；“制作/修复/完成”在已授权范围内执行。Skill 不额外授权部署、发消息、付费、数据删除或开放产品能力。

## 按问题读取

| 当前问题 | 阅读资料 |
|---|---|
| 不知道改哪里、模块关系、新功能接入 | [架构地图](references/architecture.md) |
| ArkTS、API 23/26、Kit、窗口、权限、设备差异 | [鸿蒙开发](references/harmonyos.md) |
| 黑屏、翻转、全屏、缩放、鼠标偏移、PIP、键盘/IME/剪贴板 | [生命周期与渲染输入](references/lifecycle-rendering-input.md) + 对应协议 |
| IPv6、DNS、网关/代理、切网与重连 | [网络](references/networking.md) + 对应协议 |
| 登录、云同步、迁移、备份、密钥、账号切换 | [数据与安全](references/storage-cloud-security.md) |
| 本应用 Pro、沙盒购买、权益、Debug 模式规划 | [购买与权益](references/purchase-entitlements.md) |
| RDP | [RDP](references/protocols/rdp.md) |
| RustDesk、RustDesk Server Pro API | [RustDesk](references/protocols/rustdesk.md) |
| SSH、SFTP、终端、跳板、转发 | [SSH/SFTP](references/protocols/ssh-sftp.md) |
| VNC、RFB、repeater、证书、滚轮 | [VNC](references/protocols/vnc.md) |
| Moonlight、Sunshine、配对、音视频、手柄 | [Moonlight](references/protocols/moonlight.md) |
| 构建、测试、审查、依赖、发布 | [验证与交付](references/validation.md) |
| 为什么这样设计、旧版本、回归来源 | [历史入口](references/history-index.md)，再查相关记录 |
| 更新/移植本 skill、核验失效链接 | [维护约定](references/maintenance.md) |

优先读取相关的 1–3 个专题；跨模块问题沿证据继续扩展。专题中的链接都相对各 Markdown 文件所在目录解析，示例 shell 命令从仓库根目录运行。

## 用证据做决定

- 用户当前约束和适用的 `AGENTS.md` 规定工作流程；代码、SDK 声明、测试与设备报告分别证明各自层面的事实。冲突时解释差异，不用旧计划覆盖现状。
- 每项产品能力分开描述：代码存在、路径接通、测试通过、设备通过、发布开关开放。不得把其中一项推成全部完成。
- 参考资料是明确提交快照上的工程摘要，不是实时状态。回答当前能力或修改前，先比较专题快照与当前 HEAD/工作区差量，再打开所指向的实现和测试；进行中的新实现不能套用旧快照结论。符号迁移后用 `rg` 查找，更新引用。
- 问题诊断沿持久配置 → UI/入口 → ArkTS service → NAPI/FFI → 原生执行 → 设备反馈追踪。只检查入队成功或设置值不足以证明生效。
- 历史计划和试验不自动成为指令。`docs/superpowers/` 仅作历史证据，不启动旧代理/插件流程；不读取、复制原始 Codex 记忆或聊天记录。
- 技术结论用“条件、原因、处理、验证、来源”表达。没有证据的根因保留未知；旧版本观察注明版本和设备条件。

## 完成

按 [验证与交付](references/validation.md) 和当前 `AGENTS.md` 执行本次范围要求的门禁，记录准确结果。更新共享状态时保留其他任务及已有未提交内容。没有设备、后端或拓扑证据时保留相应待办。报告做了什么、如何验证、实际提交和剩余边界。
