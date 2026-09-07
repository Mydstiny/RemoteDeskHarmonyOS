# Skill 维护与核验

本 skill 随 RemoteDeskHarmonyOS checkout 版本管理，默认允许自动发现；可显式用 `$remotedesk-harmonyos-dev` 调用。不依赖插件服务或第三方 skills。搬走单独目录会丢失仓库证据，需要连同对应公开 checkout 使用；未来导出独立通用 skill 时重新整理来源和适用范围。

## 单一来源

- `AGENTS.md` 保存强制规则；CURRENT/STATE/QUEUE 保存易变任务状态。
- 专题保存经过归纳的执行经验和代码/测试入口；源码、现有脚本和原计划不复制。
- [历史入口](history-index.md) 记录公开历史覆盖边界。[source-catalog.json](source-catalog.json) 是明确版本的已跟踪文档发现清单，不声称清单里的每份文档都已逐段审计。
- 本机原始记忆、日志、聊天、账号、证书、真实订单、设备地址和私有 archive 对象不打包。

## 条目格式

新经验只有能改变定位、实现或验证决定时才加入。采用：

```text
主题/症状：
适用范围：协议、API、设备、版本条件
已确认事实：
处理/排查顺序：
不适用/已知限制：
验证：对应测试与设备检查
证据：代码路径+符号、commit、计划/报告
最后核验：日期与实现快照
状态：当前实现 / 历史观察 / 规划 / 待验证 / 已替代
```

已有结论变化时更新原条目，并链接替代结论；不无限追加互相矛盾的“禁止”。不要因为一次局部设备问题形成全局规则。DECISIONS 重复编号需用标题或代码来源消歧。

## 本地检查

从仓库根目录执行，需 Python 3.9+ 与 Git，脚本只读：

```sh
python3 .agents/skills/remotedesk-harmonyos-dev/scripts/audit_skill.py --repo .
```

检查 markdown 本地引用、文件存在、public milestone 可由记录快照到达、catalog 来源文件仍存在，并输出新增/删除文档供维护判断。它不验证自然语言技术结论、网页可用性或产品行为。

有 skill-creator 校验器时再运行其 `quick_validate.py`；这不是使用本 skill 的依赖。新增 helper 必须有具体复用价值，并验证成功和失败路径。

## 使用验证

有实质路由/决策变化时，给独立评估者真实问题与本 skill/checkout，只读执行；不要提供预设答案。可选案例：

- “RDP 切全屏后点击偏移，只分析，不改代码。”
- “RustDesk 选 H.265 后 HUD 有疑问，怎么确认？”
- “关闭 Pro 弹窗后购买仍继续，如何调查？”
- “API 26 是否已经可以直接用，云同步能否按账号改库名？”
- “追溯 VNC 滚轮修复和它的验证范围。”

评估是否找到当前入口、保留用户范围、辨别规划/实现、引用可核验来源、选择必要验证。针对失败修正，不凭格式通过宣称行为已验证。

## 更新边界

维护 skill 不自动迁移应用 API、不打开 capability、不升级依赖，也不授权生产购买。需要更新公开时间线或 catalog 时只从明确公开 main/已授权 task ref 取数据；不要用 `git log --all`、全部 refs 或 raw transcripts 做历史导出。
