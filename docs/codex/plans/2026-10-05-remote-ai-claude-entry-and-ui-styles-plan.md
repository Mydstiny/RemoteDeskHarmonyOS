# 远程 AI：Claude Agent 入口与两种远控界面风格

状态：IMPLEMENTING（2026-10-05 用户确认）。R1 Claude Agent 入口、R2 两种界面风格已实现（见第 5 节），待独立复核与实机验收。
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
| R2 | `AiTimeline`（工具步骤摘要、统一差异解析、Claude Edit/Write/MultiEdit 与 Codex fileChange 差异、对话/日志划分）、`AiStylePalette`（Claude 经典色与 Codex 中性色，深浅各一套）、`aiCodexItem`（命令含输出、文件修改转差异、思考、MCP、网页搜索）、DSH 工具步骤带输入/输出；会话页重写为两种风格：Claude 风格（右侧气泡、Markdown 正文、可展开的工具行与差异、折叠思考、运行中提示、内联审批卡、圆角输入框带附件/模型/权限模式与发送/停止）与 Codex 风格（任务列表、对话/日志/差异三个标签、修改汇总）；新组件 `AiRemoteMarkdown`、`AiDiffView`；远程 AI 设置新增「界面风格」（旧设置缺字段时按 Claude）；Claude 发送后本地先显示提问直到引擎回显；会话列表改为可点选的行；新内容自动跟随到底部，上滑后停止跟随。测试：`test_ai_timeline.cjs`，`test_ai_ui_parity.cjs` 按新结构更新（三个弹层表头、两种页头的 Pro 标识、不同高度/风格/审批组合下列表高度） |
| R1 | 后端表 `AI_BACKENDS`（`codex`/`dsh`/`claudecode`）与名称、端口、校验；添加/编辑、安装说明、远程 AI 设置三处的 Claude Agent 卡片；目录 `pro.ai.claudecode`（available）；`aiClaudeItems`（Claude 事件 → 会话记录，含历史）；Claude 错误码中文提示；`test_ai_claude_transcript.cjs`、安装说明与入口测试补齐。电脑端 Claude 服务已重新初始化到 `192.168.31.142:9445`（旧状态备份于 `~/.remotedesk/claudecode.bak-20261005-lan`），验收项目 `acceptance` 指向 `~/Library/Application Support/RemoteDesk/workspaces/acceptance-claudecode` |

插件侧待办（需另开插件 PR）：实时 `assistant/message` 的思考块用 `textOf(block)` 取文本，思考内容为空（应取 `block.thinking`）；用户自己的提问在实时流中不回显，App 发送后需本地先显示；打开已有历史的会话后，实时事件的 `seq` 从 0 重新编号（`open()` 建 handle 时 `sequence: 0`，未接续 `read()` 读到的历史），与历史重号（App 已改为按到达顺序编号，不依赖 `seq`）；`read()` 按偏移分页，而 history 满 4000 条后会从头部裁剪，翻页期间有新事件时后续页会漏事件；`read()` 在 history 为空时用新数组替换 `this.history`，与 `open()` 绑定的 `handle.history` 脱钩（先 open 后 read 的新建/分叉会话，之后读到的是过期数组）。

## 6. 独立复核（2026-10-05，Opus）

第一轮 FAIL（1 个 P1、6 个 P2、4 个 P3），已全部修复：

| 发现 | 修复 |
|---|---|
| P1 回合结束后仍有后台任务（`background`）时只剩「停止/补充指令」，无法发送新任务 | `working()` 不再含 `background`；输入框显示「上一轮启动的任务仍在电脑上运行」和「查看」（终端任务）；按钮判定提为 `composerMode()` 并加行为测试；`turn.start` 回执不再覆盖事件流已报告的状态（快速失败的回合不会卡在「请求已接受」） |
| P2 提问回显被历史中同文本的消息吞掉；回显 ID 重复、同回合顺序颠倒（P3） | 回显只由**之后到达**的引擎用户消息一对一抵消（先按同文本，再按同回合）；ID 用单调计数；同回合按发送顺序插入 |
| P2 Codex 风格自动跟随失效 | 列表数据统一由 `shownItems()` 提供，`listLength()` 按风格与标签页计算真实行数并加测试 |
| P2 DSH 工具步骤回归（一直转圈、参数二次编码、结果行错误、小写工具名不识别） | 新的纯函数 `aiDshItems`：按 `toolCallId` 把结果并入调用、参数先解析再格式化、`turn/end` 收尾、结果事件保留隐藏占位以便压缩区间定位；`bash/read/edit/write/grep/glob/web_*/todo_write/str_replace_editor` 按 Claude 工具显示摘要与差异；新测试 `test_ai_dsh_transcript.cjs`（按 `@deepseek-ai/dsh-session` 的 `SessionEventMap`） |
| P2 关闭「显示工具执行过程」后错误通知也被隐藏 | 只隐藏 `tool` 与 `thinking` |
| P2 远端内容无上限（日志单行 1 MB、替换型差异 6 万行、展开时一次创建全部行） | 折叠预览限 6 行且 ≤800 字符；`aiReplacementDiff`/`MultiEdit`/统一差异都限 4000 行并标记 `truncated`；差异视图每次多显示 400 行，超限提示「其余内容请在电脑端查看」 |
| P2 长会话 UI 线程开销呈平方增长 | 快照整页记录后只映射一次；实时事件只记录，页面最多每 80 ms 刷新一次；Claude 日志在整条消息到达后丢弃已被替换的分片；分片查找改为 Map；差异汇总按会话记录缓存；`AiDiffView` 不再深拷贝文件数组（内容变化时按键重建） |
| P2 测试只检查源码字符串 | 新增行为测试：首次打开即连接、发送/停止判定、通知过滤、两种风格各标签页行数、Claude 文件审批、日志预览上限、回显各情形、DSH 映射、差异上限与线性解析 |
| P3 流式回答每个分片整体重建 | 随 80 ms 刷新节流缓解（ForEach 键仍含长度，否则 V1 不会刷新该行） |
| P3 畸形输入下正则超线性 | 表格分隔行先 trim 并限长；`diff --git` 头不再用回溯正则，并去掉行尾 `\r` |
| P3 新建会话/切项目/重连后视图状态未重置 | `resetView()` 统一重置跟随、展开与标签页 |

待确认项核对结果（对照电脑上运行中的插件 `0.2.0-82f7608`）：`turn.start` 回执带 `turnId`（`steer` 不带，按文本抵消）；历史与实时 `seq` 不是同一序列（见上方插件待办）；Claude 文件审批 `kind` 为 `fileChange` 且不带 `nativeItemComplete`，App 原先只能拒绝——已改为 Claude 的文件审批可以允许，并在审批卡显示编辑内容（`-`/`+` 行，超长截断）；Codex 新增/删除文件的 `diff` 为文件原文，已改为整段按新增/删除计数。

范围外既有问题（c8b7b9ac0 引入，阻塞验收）已一并修复：首次打开会话页时 `allowed` 尚为 false，`reconnect()` 直接返回、页面停在「未连接」；现在按 Pro 权益（`accessible()`）判断能否连接，「更多 → 重新连接」与空状态的「重新连接」在未连接时也可用。

### 第二轮复核（2026-10-05，Opus）：FAIL → 第三轮修复

原 P1 与大部分 P2/P3 核实已修复；第二轮发现的处理：

| 发现 | 修复 |
|---|---|
| P2 Claude 快照分页与 SSE 重放重叠（cb4f1d0bb 引入，消息重复） | Claude 改用最后一页的 `cursor`（bridge 每页先取 `nextEvent-1` 再同步切片，最后一页覆盖已读全部事件）；DSH 仍用第一页（其页面止于第一页的 `through`） |
| P2 DSH 长会话映射开销（6.2 万事件快照 23 s） | 增量映射 `AiDshMapper`：按 seq 逐条追加，乱序或同 seq 不同内容才全量重建；消息来源按 seq 查表。3 万事件分页加载在桌面 Node 上约 60 ms；随机分批增量与整体映射逐项一致（20 轮）。顺带修复既有显示问题：每个分片一行 → 一步一行；推理混入正文 → 单独「思考」行；插件注入的上下文（AGENTS.md、技能、通知）显示成用户气泡 → 「上下文」步骤 |
| P2 Claude 风格「差异」详情直接渲染未截断的原生 diff | 解析后用 `AiDiffView`（4000 行上限、分页）；不是 diff 的内容截断到 2000 字 |
| P3 回执覆盖已结束回合的状态 | 按 `execution.*` 事件计数判断 |
| P3 补充指令的回显总在末尾 | 条目带到达序号 `order`，无回合的回显按发送位置插入 |
| P3 差异页键可能不变 | 键改为差异内容签名 `aiDiffSignature` |
| P3 新解析路径遇异常数据会抛 | `aiObject` 安全访问；DSH 缺字段跳过；Claude 审批缺 `input` 不抛 |
| P3 Codex 新增/删除文件行数边角错误 | 合成带计数的 hunk 头；`aiDiffFiles` 在 hunk 内按计数把 `--- `/`+++ ` 当内容 |
| P3 `job_output` 的 `job_id`、`pwsh` | 已映射 |
| P3 标题行正则二次方 | 从尾部线性扫描 |
| P3 分叉后未重置视图；忙时点重连只重置不连接 | 重置移入 `run()`；分叉后重置 |
| 待确认：同回合合成用户消息误删回显；插件将来回显提问时显示两次 | 同回合兜底要求引擎文本包含提问；发送前 `mark()`，回执前已到的引擎副本也能抵消（一对一） |

测试：`test_ai_dsh_transcript.cjs`（流式、注入上下文、异常字段、增量等价、3 万事件性能）、`test_ai_claude_transcript.cjs`（早到副本、补充指令位置、注入上下文、异常事件）、`test_ai_workspace.cjs`（两种后端的事件续接位置、回执不覆盖结束状态）、`test_ai_timeline.cjs`（hunk 计数、签名、工具名）、`test_ai_chat_mode.cjs`（Markdown 长行线性）。

### 第三轮复核（2026-10-05，Opus 5.5 high）：FAIL（1 个 P2）→ 第四轮修复

第二轮的 3 个 P2 核实已修复（DSH 增量与整体映射 500 轮随机对比 0 差异；6.2 万事件分页加载 265 ms，实时刷新约 0.15 ms）。新发现与处理：

| 发现 | 修复 |
|---|---|
| P2 DSH `user/message` 的 data 就是消息本身（`{id, role, content, source}`，dsh-session `deriveEventMessage` 直接返回 `event.data`），映射却读 `data.message.source`，插件注入的上下文仍显示成用户气泡；测试用了旧的包装格式 | 先读 `data` 本身，旧日志的 `message` 包装仍兼容；测试改用真实结构并覆盖插件来源 |
| P3 差异签名对超过 256 字符、只在后部不同的长行会碰撞 | 百万字符预算内逐字哈希，超出部分取两端和均匀采样 |
| P3 Codex 新增文件内容以 `--- ` 等开头时被当成 diff 透传 | 只有确定的 diff 形态（`diff --git`，或可选的 `---/+++` 头后紧跟带计数的 `@@`）才透传 |
| P3 `git diff --binary` 的二进制补丁被当成正文 | 显示为「（二进制文件）」并跳到下一个文件 |
| P3 AiDshMapper 移除流式行时重复全表扫描 | 移除时同步删除 `bySeq` 项，`lastIndexOf` 从尾部查找 |
| P3 工作区干净时显示「还没有读取到差异」 | 显示「工作区没有未提交的改动」 |
| P3 Codex 审批的 `kind: null`、非对象 `nativeItem` 会在渲染时抛错 | 改用安全访问 |
