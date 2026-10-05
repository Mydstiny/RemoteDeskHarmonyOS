# 远程 AI：Claude Agent 入口与两种远控界面风格

状态：IMPLEMENTING（2026-10-05 用户确认）。R1 Claude Agent 入口已实现（见第 5 节）；R2 两种界面风格进行中。
范围：手机/平板/PC 上的「远程 AI」（Codex、DSH、新增 Claude Agent）。手机通行密钥另见 [通行密钥计划](2026-10-05-pro-phone-passkey-prototype-plan.md)。

## 0. 用户决定（2026-10-05）

1. Claude Agent 作为第三个后端，**直接对所有 Pro 开放**（与 Codex、DSH 相同，正式版可见）。
2. 电脑端 Claude 插件从 `127.0.0.1:9445` 重新初始化到局域网地址，只动 Claude 插件，Codex/DSH 不变。
3. 远控界面**同时做 Claude Code 风格和 Codex 风格**，在「远程 AI 设置」里新增「界面风格」切换。

## 1. 现状（代码事实）

- 后端写死为 `'codex' | 'dsh'`：`AiModels`（类型、默认端口、校验）、`AiHostEditor`/`AiHostInstallPanel`/`AiSettingsPage`（选择卡片）、`AiHostService`、`AiHostInstallPolicy`（固定版本安装说明）、`AiWorkspaceController`（快照与事件分支）。
- 权益按 `'pro.ai.' + backend` 判定；握手要求 `engine === host.backend`，所以 Claude 的后端 ID 必须是插件引擎名 `claudecode`，权益 `pro.ai.claudecode`。
- 邀请码/配对链接不含引擎字段（引擎在握手时核对），Claude 插件用同一 bridge-core，配对格式不变。
- Claude 插件事件与 DSH 同名（`user/message`、`assistant/chunk`、`assistant/message`、`tool/call`、`tool/result`、`turn/start`、`turn/end`、`error`），但语义不同：流式分片之后还会给完整消息（无 `sourceEventSeqs`），工具结果以 `user/message` 中的 `tool_result` 块出现，`assistant/message` 带 `kind: text|thinking`。直接走 DSH 逻辑会重复显示正文、把工具结果显示成“你”的消息。
- 现有远控页（`RemoteAiWorkspace.ets`）是按钮行 + 下拉框 + 纯文本卡片，执行项直接显示 JSON。

## 2. R1：Claude Agent 入口

- `AiBackend` 增加 `claudecode`；默认端口 9445；名称「Claude Agent」。所有选择卡片、标签、校验、默认后端设置改用统一的后端表。
- 目录新增 `pro.ai.claudecode`「Claude Agent 远程控制」（available，与 Codex/DSH 同级）。
- 安装说明：Claude 插件尚无发行包，按固定提交从源码安装（不虚构发行资产与 SHA256）：仓库 `Mydstiny/remotedesk-claudecode-plugin`，版本 0.2.0，提交 `82f76082082a17d71f73cf1075651fc21c89771f`（`claude/probe-foundation`，含 API Key 认证；与本机已部署的 `0.2.0-82f7608` 一致）。
- 会话内容：新增 Claude 事件映射（分片合并为一条流式正文、完整消息替换分片、`tool_result` 归入对应工具调用、思考单独成项、回合结束状态与错误）。
- 电脑端：Claude 服务重新初始化为局域网监听（重新生成证书，需要在面板 9545 填 API Key 后重新配对）。

## 3. R2：远控界面两种风格

### 3.1 统一时间线模型（纯函数，可宿主机测试）

Codex 条目与 DSH/Claude 事件都映射为同一组时间线项：用户消息、助手正文（Markdown）、思考、工具（命令/读/写/搜索/MCP/网页，含标题、摘要、状态、输入、输出、差异）、回合状态、错误。审批来自 `approval.list`，作为待处理卡片插在时间线末尾。

### 3.2 Claude Code 风格

对齐 Claude App 的 Code 页：项目与会话列表；会话页顶部为标题、状态与菜单；用户消息为右侧圆角气泡，助手正文无气泡直接排版（Markdown：标题、列表、行内代码、代码块、表格）；工具调用为一行可展开的紧凑行（图标 + 动作 + 对象 + 结果），文件修改显示 +/− 行数，展开看差异；思考折叠为「已思考」；审批以内联卡片出现在输入框上方（拒绝 / 允许此次，问题类逐项作答）；底部输入框带附件、模型与模式选择，运行中发送键变为停止键。配色为 Claude 经典色（浅色米白 `#f5f4ee` + 陶土橙 `#c96442`，深色 `#262624` + `#d97757`）。

### 3.3 Codex 风格

对齐 ChatGPT App 中的 Codex：会话以「任务」列表呈现（状态徽标、时间）；任务页分「对话」「日志」「差异」三个标签：对话只显示用户与助手正文，日志按时间列出命令与工具输出（等宽字体），差异按文件分组着色显示；审批与输入框同样位于底部。配色为黑白灰中性色，深浅色各一套。

### 3.4 设置与功能保持

「远程 AI 设置」新增「界面风格：Claude / Codex」（按账号本机保存，默认 Claude）。两种风格保留现有全部能力：取得控制权、发送、补充指令、停止、附件、模型/推理强度/权限模式/协作模式、重命名/分叉/压缩/归档、差异、终端任务、待确认操作核对、加载更早记录、重连与前后台恢复。

## 4. 验证

- 宿主机：时间线映射（Codex 条目、DSH 替换区间、Claude 分片/工具结果/思考/错误）、后端表与校验、设置读写、现有 `test_ai_*` 全部通过。
- 四项 Hvigor 门禁与测试登记、Light 合规门；阶段性独立复核。
- 实机（用户）：三种后端分别配对、发送、审批、停止、附件；两种风格在手机竖屏、平板、PC 窗口下的显示与深浅色。

## 5. 实现记录

| 阶段 | 内容 |
|---|---|
| R1 | 后端表 `AI_BACKENDS`（`codex`/`dsh`/`claudecode`）与名称、端口、校验；添加/编辑、安装说明、远程 AI 设置三处的 Claude Agent 卡片；目录 `pro.ai.claudecode`（available）；`aiClaudeItems`（Claude 事件 → 会话记录，含历史）；Claude 错误码中文提示；`test_ai_claude_transcript.cjs`、安装说明与入口测试补齐。电脑端 Claude 服务已重新初始化到 `192.168.31.142:9445`（旧状态备份于 `~/.remotedesk/claudecode.bak-20261005-lan`），验收项目 `acceptance` 指向 `~/Library/Application Support/RemoteDesk/workspaces/acceptance-claudecode` |

插件侧待办（需另开插件 PR）：实时 `assistant/message` 的思考块用 `textOf(block)` 取文本，思考内容为空（应取 `block.thinking`）；用户自己的提问在实时流中不回显，App 发送后需本地先显示。
