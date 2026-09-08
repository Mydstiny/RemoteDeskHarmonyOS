**文件传输与剪贴板完整优化、修复及验收计划**

状态：IMPLEMENTATION_IN_PROGRESS / 用户于 2026-09-08 授权完整执行，允许与其他任务并行。制定日期：2026-09-07。

2026-09-07 首次交付为纯计划，记录保留在第 12 节。2026-09-08 用户授权完整执行及并行处理；从 T0 开始逐项实施、当次验证、提交与独立复核。具体完成状态以执行记录为准，计划条目本身不表示功能或设备验收已通过；移动仍须满足目标验证和源文件删除条件。

**1. 目标与范围**

让用户能够明确、可靠地完成本地与远端之间的文件发送、接收、复制粘贴，并知道文件发往哪里、当前处于什么阶段、失败后如何恢复。重点协议为 RDP、RustDesk；共用任务能力参考既有 SSH/SFTP，保持现有 SSH/SFTP 行为稳定。

必须覆盖以下闭环：

| 操作 | 目标行为 | 完成依据 |
|---|---|---|
| 本地选择文件/目录上传 | 选择源及可解释的远端目标，处理重名、进度、取消和重试 | 协议发送证据与可用的目标验证分别显示 |
| 远端文件/目录下载 | 选远端条目，接收到本地受管 partial，再保存到用户选择的目录 | 本地写入/关闭/校验成功，最终导出结果可用 |
| 本地文本复制/剪切后粘贴到远端 | 用户明确粘贴时取到当前内容；自动同步只发往活动授权会话 | 格式发布成功后才注入对应粘贴操作 |
| 远端文本复制/剪切后粘贴到本地 | 远端新事件更新本地，重复内容也不丢事件 | 本地 Pasteboard 写入成功且来源记录一致 |
| 本地复制文件→远端粘贴 | RDP 和 RustDesk 均有明确本机文件粘贴入口，再逐步接入系统快捷键 | 文件 offer、按需读取与结果分离，目标由协议/用户选择解释 |
| 远端复制文件→本地粘贴 | 先支持“接收远端已复制文件”，再支持本地系统文件管理器粘贴 | 完整接收或经过平台验证的延迟文件提供机制，其他应用具有有效读取授权 |
| 图片/富文本复制粘贴 | 支持经协商的格式，并保留纯文本回退 | 格式、编码、尺寸、字节预算及目标可用性验证 |
| 跨端剪切/移动文件 | 仅在明确移动意图、目标验证、源身份与删除权限成立时实施 | copy → verify → 条件性 delete；条件不足则保留源并说明仅复制 |

文本 Ctrl+X 的源删除由源应用执行，不能承诺本客户端把文本剪切变成跨端原子事务。RDP 共享盘上的 Windows 文件操作、RDP 文件剪贴板、RustDesk 文件会话、RustDesk Cliprdr 必须分别建模，不把一种路径的证明复用于另一种。

现有基础文件/剪贴板功能及本轮可靠性修复保持免费，不新增 Pro 门槛。VNC 保留当前文本同步；Moonlight 不增加其原协议没有提供的通用文件能力。伴随 SFTP 通道若将来需要，另设显式连接和认证，不能静默复用其他协议凭据。

**2. 基线、事实与实施前复核**

计划编写基线：`ab3a60ac1`，活动分支 `codex/pro-purchase-foundation`，main 基线 `8edc18786`。启动时工作树干净，ahead 34 / behind 0；Pro M7 仍是活动任务，本计划不替换其任务、审查基线或分支。

诊断时重点文件在 `5109d5837`、`552604327` 至计划编写基线之间没有差量。以下 F01–F17 是 2026-09-07 当前源码诊断，实施前仍应确认是否被其他任务修复。

| 依赖/平台 | 本轮核验依据 | 实施约束 |
|---|---|---|
| FreeRDP | gitlink `dae8276ac7361b8d14f7b87d41163fe03dbb944e`、本地 client_cliprdr_file.c、OHOS patches/build | 区分 helper 实际能力和本项目接线；不依赖 Linux FUSE 在 OHOS 可用 |
| RustDesk | proto 来源 RustDesk `93d064a9b0eb58ab94db88ff727a877ef773c0d8`，hbb_common `387603f47cbb15c0d3dc3d67ae3396d3eb707daf` | 自有 FFI 不是完整官方客户端；消息方向、mtime、digest/Done 依固定版本核验 |
| HarmonyOS | 本机 API 26 SDK 声明与 2026-09-04 更新的官方 Pasteboard 页面 | API 26 开发基准；保留 API 23 时按具体接口检查 since、SysCap、权限、导入与回退 |
| 当前验证 | 5 项生产方法隔离探针复现缺陷；RDP offer 4 项原生测试通过；实际转换循环复现 emoji 编码错误 | 属于已有诊断证据；不替代后续改动的当次回归、构建与设备验收 |

隔离复现的 5 项是：剪贴板启动只记基线、相同远端文本再次复制丢失、两桥串传、RustDesk 成功遗漏 finalize、RustDesk await 后提交到替换会话。RDP emoji 的实际输出为 `eda0bdedb880`，期望 `f09f9880`。其余条目为源码确认或注明条件的集成风险，不能全部标成设备已复现。

**3. 问题与实施工作包映射**

| 编号 | 诊断和影响 | 优先级 | 工作包 | 必须验证的关闭条件 |
|---|---|---|---|---|
| F01 | 多桥缺少统一所有者，可能把 A 远端内容转发给 B | P1 | T1 | 双窗口、切焦点、克隆与账号切换无串传 |
| F02 | RustDesk 跨 await 使用当前 session，可能误投新会话 | P1 | T1 | picker、read、enqueue、progress 任一点代次变化都不误投 |
| F03 | RDP 同批同名文件写入相同 TRUNC 暂存路径 | P1 | T2 | 同名/大小写/清洗碰撞不静默覆盖、不重复发布同一文件 |
| F04 | 共享盘与历史暂存共用持久根，缺少主机/会话隔离和回收 | P1 | T2、T4 | 私有暂存不被共享；旧文件不自动暴露；回收只触及归属明确的缓存 |
| F05 | 关闭 RDP 剪贴板后，已锁流仍有读取路径 | P1 | T2 | 锁定后关闭立即拒绝新的内容读取，安全处理在途回调 |
| F06 | 过期本地文件 URI 抢占远端复制 B 后的 Ctrl+V | P1 | T1、T7 | 两端来源顺序正确，远端内部粘贴不被本地旧文件劫持 |
| F07 | 桥恢复时本机已有文本仅设基线，明确粘贴可能漏发 | P2 | T1 | 本地复制→切回→立即粘贴无需重复复制 |
| F08 | 内容 hash 代替事件序列，同内容新复制/清空/重试缺失 | P2 | T1 | A→B→A、同内容新事件、清空、失败重试均正确 |
| F09 | RDP UTF-16 代理对转换错误，文本限制单位不一致 | P2 | T1 | emoji/生僻字/非法输入/字节边界均有确定结果 |
| F10 | RDP 无远端文件描述符到本地落盘/URI 接收器 | P2 | T5 | 远端复制文件→显式接收→另存/本地粘贴完整闭环 |
| F11 | RDP 暂存/announce 被当成传输完成/共享盘就绪 | P2 | T3、T4 | 真实状态与完成证据匹配，服务端拒绝设备能更新 UI |
| F12 | RDP URI 未标准编码、文件名边界与空文件处理不完整 | P2 | T2、T5 | 字面%20/编码斜杠/保留名/0 B/路径边界不损坏、不越界 |
| F13 | RustDesk 固定 Windows 路径，无下载/真正 Cliprdr | P2 | T6、T7 | 可选远端目录、双向文件会话和文件剪贴板分别验收 |
| F14 | RustDesk 全内存上传、假进度、取消和 deadline 不完整 | P2 | T3、T6 | 缓冲有界，块级真实进度，逐任务取消可终结 |
| F15 | RustDesk 成功未清理实况任务，超时后孤儿任务/单槽覆盖 | P2 | T3 | 每个 transferId 都收敛到受管状态并幂等回收 |
| F16 | RustDesk sender-complete 冒充远端确认，冲突/mtime 不完整 | P2 | T3、T6 | sent 与 verified 分开；冲突生效；mtime 按协议秒保留 |
| F17 | connected/attached 代替方向、格式协商和远端权限 | P2 | T1、T4、T6 | 能力模型准确，动态撤销生效；拒绝不触发弱化权限重试 |

P1 先于新能力开放。T4/T5/T6/T7 新功能不能绕过 T1–T3 直接在大页面继续堆叠。F04、F05、F06 等即使当次设备不能复现，也须通过状态机和回调链证明边界，不得仅以“正常使用没遇到”关闭。

**4. 统一设计契约**

采用共用任务外壳和独立协议 adapter。以下名称为建议职责边界，实施时优先扩展合适的现有模块，避免为重命名而大规模改动 SSH/SFTP。

| 层 | 职责与必要约束 | 主要现有接入点 |
|---|---|---|
| ClipboardCoordinator | 唯一活动目标/接收方、全局来源和事件 epoch、方向/格式策略、权限与窗口租约 | ClipboardBridgeService、ClipboardSyncPolicy、RemoteDesktop 窗口生命周期 |
| LocalFileProvider / TransferArtifactStore | URI/Picker/拖拽读取授权、FD、私有暂存、文件身份、空间预留、清理归属、系统导出 | SshLocalFileProvider、SshSftpShareStager、RemoteDesktop 暂存方法 |
| TransferTaskService / Store | 独立 taskId、批次、稳定连接身份、队列、真实进度、冲突、取消、持久恢复、幂等 finalize | TransferSessionPolicy、SshSftpTaskEngine/Store、FileTransferLiveTaskService |
| RDP adapter | CLIPRDR 格式/锁/范围读写、rdpdr 注册/服务器接受/文件访问、native 回调 admission | freerdp_adapter、rdp_file_clipboard_bridge/offer |
| RustDesk adapter | 独立 file session、目录/上下行/取消/digest；Cliprdr 单独协商和消息处理 | rustdesk_bridge、rustdesk_ffi lib/connector/session/control_inbox |
| TransferCenter / 用户入口 | 目标与来源明确；进度、冲突、接收/导出、暂停/取消/重试；能力不可用原因 | 既有 SSH TransferCenter 的交互与任务模型、RemoteSessionTopBar |

**4.1 会话与剪贴板所有权**

所有操作持有不可变租约：`accountScopeId + windowId + hostId + protocol + routeIdentity + sessionId + attemptId + nativeGeneration`。routeIdentity 使用既有规范化身份，不包含口令/token。会话 id 相同但 generation 不同仍是新租约。

选择器打开、权限返回、URI 打开、分块提交、native 回调、本地剪贴板写入和任务 finalize 都检查租约。后台持续文件任务可拥有自己的受管租约，不依赖页面是否显示；自动剪贴板同步须遵循独立的前台/活动目标策略。恢复相同主机也不能把旧请求自动投给新连接。

剪贴板 envelope 至少包括 originSession、originKind、sequence、formats、payloadBytes、deliveryState。hash 只用于辅助内容比较，不能替代新复制事件序号。记录成功写入本地的确切 envelope，用于所有桥共享的防回环，不使用单实例 1.2 秒窗口作为唯一依据。

本地系统 changeCount、tag 等只能在核验 API 和权限后使用，并处理计数重置/溢出/同 app 自写；不把自定义 tag 当安全凭据。远端回传与本地发送分开存储。同步失败时不推进 delivered/acknowledged checkpoint。

**4.2 文件任务与完成证据**

任务基本字段：`schemaVersion、taskId、batchId、protocol、direction、sourceKind、sourceIdentity、targetIdentity、lease、totalBytes、readBytes、sentBytes、writtenBytes、verifiedBytes、stage、completionEvidence、conflictPolicy、ownedArtifacts、errorCode`。公开进度不要混用本地读取与网络发送字节。

| 状态 | 含义 | 可进入的后续结果 |
|---|---|---|
| preparing | 获取授权、解析清单、预留空间、创建独立目标 | ready、cancelling、failed、cancelled |
| ready / offered | 可以发送，或仅向远端发布了文件清单 | transferring、cancelling、expired、cancelled、failed |
| transferring | 有真实块读写/发送 | senderCompleted、verifying、waitingConnection、paused、cancelling、failed |
| senderCompleted | 协议发送结束，尚无目标验证 | verifying、cancelling、completed（保留 sender-only 证据）、commitUnknown |
| verifying / committing | 校验 partial、执行可用的 rename/export | cancelling、completed、commitUnknown、failed |
| waitingConnection / paused | 保留可重建的断点身份，当前不发送 | preparing、transferring、cancelled、failed |
| cancelling | 已关闭新的工作准入，正在收束在途操作 | cancelled、completed（已越过提交点）、commitUnknown |
| commitUnknown | 不确定目标是否已经提交，禁止盲目覆盖/自动删源 | reconcile 后 completed、failed 或等待用户处理 |
| completed / failed / cancelled / expired | 当前 attempt 的确定终态 | 重试创建新 attempt，不让旧回调修改它 |

取消不等于删除源，也不等于必然回滚已完成的远端 rename/export。临界点已跨越时必须记录实际结果，不能为了显示 cancelled 留下损坏目标。完成通知与后台运行资源进入统一、幂等 finalize；等待连接/未知结果由服务持续管理，不能因为页面 30 秒等待结束而失去所有者。

RDP 对端读取完文件范围，只能证明相应读取，不能保证对方编辑器保存。RustDesk 发出 Done 有 sender-complete 意义，不能死等不存在的对称确认，也不能冒充目标持久化验证。大小/mtime 相等属于元数据校验，不等同内容哈希。

**4.3 存储、路径和冲突**

- 私有 clipboard staging、共享盘根、接收 partial、已保存的用户文件分别管理；路径由内部文件 ID 生成，显示名另存。
- 授权根 containment 使用规范化路径和适当的目录/FD 相对访问。禁止遍历、绝对远端路径注入、符号链接逃逸和多次 URI decode；仅 startsWith 不足以成立。
- 先解析整批文件名与目标规则，再做覆盖/跳过/重命名决策；考虑 Windows 大小写、保留名、尾部点/空格、Unicode 和清洗碰撞。跨文件系统合法性由目标 adapter 决定。
- 0 B 文件作为合法文件；目录与文件显式区分。目录递归有层级、数量、总大小上限；不自动跟随符号链接。超过能力边界返回明确原因。
- 配额同时计入现有暂存、在途预留与下载/导出需要的额外空间。未知大小来源使用运行时上限，不能只检查元数据。
- 清理仅针对 manifest 证明本任务拥有的临时文件；保留有效锁/在途 FD；未知历史目录、用户导出文件和其他账号文件不能自动清理。
- 旧 rdp_transfer 目录先停止默认重曝，提供用户可见的恢复/导出入口；迁移使用可恢复记录，失败保留旧数据，不直接删除或把旧内容自动共享给新主机。

**4.4 能力模型**

每个方向及格式独立计算 `configured / protocolSupported / negotiated / remoteAllowed / localAuthorized / operational / reason`。至少区分文本、图片、富文本、文件 clipboard、文件 upload/download、directory、resume、cancel、move、sharedDrive。

RustDesk 使用已有远端 clipboard/file permission 快照，不能 connected 即“已确认”。RDP 反映 file-streaming/锁/大文件协商与服务器设备回复，不能 attached 即完整文件能力。设置关闭时同步关闭业务与 native 新请求准入；关闭后不重试其他路由以绕过限制。

**5. 工作包、依赖及逐项实施步骤**

依赖顺序：`T0 → T1 → T2 → T3 → T4/T5/T6 → T7 → T8 → T9`。斜线表示可分别验收，实施是否并行取决于同一工作区的文件冲突；不创建持久 worktree，不同时改同一页面/native 文件。实施授权已取得；按以下依赖逐项验收，不能把独立开发中的模块直接视为可公开使用。

**T0：冻结复核证据与可执行回归基线**

前置：用户明确授权开始实施；按 CURRENT/实际 Git 继续已有活动分支，只有符合仓库 start 条件时才新建独立任务分支。

1. 复查 F01–F17 对应源码、当前依赖版本和 API 23/26 声明；已经被其他任务修复的仅验证其结果，不重复实现。
2. 将本轮隔离复现迁为调用生产逻辑的定向回归，加入真实 adapter callback fixture。mock 不模拟“必然成功”的假协议确认。
3. 建立协议消息轨迹 fixture：RDP FormatList/Lock/Range/Unlock/DEVICE_REPLY；RustDesk Receive/Digest/Confirm/Block/Done/Error/Cancel，绑定固定 peer 版本。
4. 列出设备、端点、共享盘、目标文件夹和测试文件授权需求，使用合成数据；设备不在场则记录设备阻塞，继续可做的代码/宿主验证。
5. 记录未修改构建基线、内存峰值、任务延迟、通知回收与文件内容校验方式。此处不得将历史构建替代后续改动门禁。

退出：每项问题有路径/触发条件/预期/验证方式；待验证问题明确标为 conditional；实施范围不含其他未完成 Pro/AI/视频工作。

**T1：剪贴板正确性、权限与会话隔离**

范围：ClipboardBridgeService/ClipboardSyncPolicy、RemoteDesktop 剪贴板与窗口入口、RemoteSessionCapabilityPolicy、ExtensionLoader/NAPI、RDP/RustDesk 剪贴板快照。

1. 增加统一协调器和稳定会话租约，集中选择活动目标；远端内容不得被其他会话桥作为本地更新再次转发。
2. 在本地、远端、系统写入之间传递事件 sequence 和来源；处理相同文本新事件、清空、失败后重试、permission revoke 与 native late callback。
3. 明确粘贴入口执行“读取当前内容→检查来源/权限/租约→发布格式→发送粘贴动作”。避免等待固定毫秒替代发布回执；仅入队时不能表示已发布。
4. 先不自动广播恢复时的历史剪贴板；恢复基线与明确粘贴分离。RDP 远端出现文件 FormatList 时，即使尚不能接收也更新来源，以免过期本地 A 抢占远端 B。
5. 统一纯文本 UTF-8 字节预算和超限提示。RDP 使用可靠的 UTF-16LE 转换，验证响应 flags、长度、代理项、NUL 及边界；所有方向不静默截断。
6. 将真实权限/协商状态接入 UI 和业务层；本地授权失败保留可用的接收/显式 Picker 路径。保留 RDP 原连接未协商 cliprdr 时必须重连的真实条件。

验收：F01/F02/F06/F07/F08/F09 生产路径定向回归；双桥与双窗口独立验收；连续账号/窗口/连接代次变化无误投；自动同步与明确粘贴互不制造重复动作。VNC 共享文本桥回归但不扩展文件能力。

**T2：RDP 文件发送、暂存隔离与撤销**

范围：RDP 文件 picker、拖拽、物理文件粘贴、延迟加载入口、rdp_file_clipboard_bridge/offer 及 helper 外围 callbacks。

1. 统一入口到受控文件清单；为每个文件生成独立 staging ID，标准 URI 编码后再交给 FreeRDP。独立保存显示名与逻辑树，不能重复同一路径伪装多个文件。
2. 分离私有 staging 和共享盘，绑定 host/account/session。旧目录保持可恢复，不改写用户已保存文件。
3. 按需读取或分块复制到 owned partial，完成本地校验后才发布 offer；发生取消/源变化/空间不足时标记原因并清理本 attempt 的 partial。
4. 为 FileContentsRequest/Lock/Unlock 外围补 native admission 和 lifetime fence。内容更新保留符合协议的旧锁；用户关闭授权则禁止新的数据请求并按同步边界撤销旧锁。
5. 使用有效 clipDataId 和 offer generation 处理请求，限制清单、文件范围和单请求资源，防止畸形 cbRequested 导致任意内存分配。上限及短读响应须符合固定版本协议，不拒绝合法请求来掩盖实现限制。
6. 支持 0 B 文件；目录支持与总量预算经 T5 的递归策略验收后再开放。所有 Phone/Pad/PC 入口用同一能力与错误模型，不以 xl 断点决定协议是否支持。
7. 用户可见区分“本机暂存”“已提供给远端”“远端读取中”；实际目标是远端焦点窗口时明确说明，不能称为拖拽落点目录。

验收：F03/F04/F05/F12；同批同名、字面%20、%2F、保留名、0 B、源变化、空间不足；锁中关闭、旧回调晚到；路径外读取拒绝；原有正常文件上传不回退。

**T3：统一任务生命周期、完成状态与后台通知**

范围：FileTransferLiveTaskService、FileTransferProgressModel、TransferSessionPolicy、RemoteDesktop 文件方法、RustDesk transfer status FFI；借鉴 SSH 引擎，不立即替换其稳定执行器。

1. 先修现有 RustDesk 成功/失败/取消路径的幂等 finalize，移除孤儿任务；任务与通知不以页面轮询寿命为准。
2. 每个 transferId/attempt 独立持有状态；批次结果为逐文件聚合。旧 worker 不得覆盖新 worker，不把 skipped 算成 transmitted，不把已暂存算成远端已完成。
3. 拆开连接、无进展、整体期限；UI 等待结束后显示受管 pending/commitUnknown，可查看/取消/对账。重试不得并发覆盖同一目标。
4. 以真实字节和阶段更新进度，移除 90%/95% 固定假进度；未知总量显示不定进度。通知节流，不能每一块都跨 ArkTS/native/系统通知边界。
5. 上传只拥有读权限；下载 partial 与导出使用显式授权。后台任务支持的平台能力不足时，明确暂停/前台要求，不能以通知存在保证后台存活。
6. native/NAPI/Rust 增量接口采用版本、结构大小、64 位字节/ID 和返回码；避免 uint32 长度截断或 int32 transferId 回绕串任务。旧调用者保留明确兼容 adapter，双 ABI 一起核验。
7. 引入任务 manifest 与 checkpoint；只保存必要的账户隔离引用，不在 manifest 中保存凭据、剪贴板正文或临时 URI 授权。受管文件副本按独立 artifact 清单、权限和保留期限管理。重启重新授权/复核 source/partial identity 后才能恢复。

验收：F11/F14/F15/F16；完成、取消、断线、页面销毁、进程重启均有明确所有者/终态；通知和 continuousTask 数量恢复到基线；100 次合成多任务回放无结果覆盖/重复 finalize。

**T4：RDP 共享盘接收管理**

前置：T1–T3。共享盘是独立能力，不把它等同于文件剪贴板下载。

1. 区分 localRegistered、announceSent、serverAccepted、unavailable；接上 DEVICE_REPLY 的接受/拒绝事实以及设备卸载/重连代次。
2. 共享目录使用明确且有限的授权范围，私有 clipboard staging 不在其中；按账号/主机隔离，用户可选择启用、查看和关闭。
3. 接收文件区提供浏览、保存到系统目录、复制到本机剪贴板、删除自己接收文件的入口。用户选择目标，导出失败保持原接收文件；已有导出文件不被自动回收。
4. 不仅靠 watcher 的 create 或一次 size 稳定判断远端写完。核对 native 文件句柄关闭/rename、写入代次和后续变化；无法证明时显示“可能仍在写入”，导出时再冻结快照与验证。
5. 区分文件系统 copy/move 与 clipboard operation；不因为用户写入共享盘就宣称“剪切已安全回传”。

验收：服务器拒绝盘、盘被卸载、远端持续写/重命名、断线留下 partial、多个主机默认盘名、0 B/目录、导出权限与源内容变化；不暴露历史其他主机内容。

**T5：RDP 远端文件剪贴板接收器**

前置：T1–T3；与 T4 各自可验收。

1. 识别并保存远端 FileGroupDescriptorW 格式 ID、epoch 与服务端协商能力；请求/响应绑定代次，不把迟到描述符当当前剪贴板。
2. 校验清单长度、文件数、64 位大小、文件/目录类型、路径层级和名称；受控递归表示，零字节和空目录不被丢弃。
3. 使用 clipDataId/锁及 offset range 请求，维护 streamId→task/file/offset 映射，正确处理并发、乱序、短读、错误、超时、EOF 与格式更换。短读不能直接当整个文件成功。
4. 不启用未经证明的 OHOS FUSE。实现直接 native 文件接收，写受管 partial、fsync/关闭、校验本地完整性，再提交到已授权本地目标。
5. 首个交付入口为“接收远端已复制文件”，显示内容清单与保存位置；完成后可发布真实已接收文件 URI，交给 T7 的系统粘贴路径。
6. 处理没有锁支持的对端：格式更新时停止或重新确认，不能混合两次复制的数据。断线后先失效旧句柄，不自动对新 clipboard 续读旧任务。

验收：F10；Windows 复制→鸿蒙接收/另存；文件列表与内容 epoch 相同；乱序/短读/恶意路径/锁超时/剪贴板更换不会混合内容；服务端禁回传时准确不可用。

**T6：RustDesk 双向文件会话与流式引擎**

前置：T1–T3。保持既有认证、server-key/peer-key 信任和直连/relay 策略，不把文件失败降级成弱认证重试。

1. 对齐官方 file session 生命周期：目录/home/platform、read_dir、receive/send、digest/send_confirm、block/done/error/cancel，明确每种消息由谁读/写。
2. 替换固定 `C:\Users\Public\Documents`：读取有效 home/目录，由用户选择远端目标；按 Windows/Linux/macOS 路径模型校验，Android 能力单独探测。不要从用户名猜测目录必然存在。
3. 流式读取源 FD/受管文件，按协议块发送；不再把整个文件复制穿过 ArkTS→C++→Rust。块级取消、背压、带宽与全局预算贯穿读/序列化/发送。
4. 先完成上传冲突策略与正确时间元数据，再开放断点。digest 不直接视作完整内容哈希；offset/skip/overwrite 与对端确认一致，mtime 使用源值和正确秒单位。
5. 加入下载任务和本地 partial/导出，处理压缩块的解压预算、文件总量、路径验证与目录枚举；目录批次能够逐文件失败/重试。
6. 使用 taskId→protocol transferId 映射和独立状态事件。由受管文件会话处理第二次授权/MFA/远端批准，不能将控制会话成功视为文件会话天然批准；取消时销毁本任务资源。
7. sender-complete 后按对端能力选择 read_dir/stat 或读回哈希，保留证据级别；无法获得目标验证时显示“已发送，目标未验证”。远端返回错误及时消费，不靠一发 Done 立即丢弃在途结果。
8. 下载续传需要源/partial 证据且协议允许；上传续传按合法确认点恢复。没有稳定标识或源变化时重新开始/询问冲突，不按文件名或本地计数盲续。

验收：F13/F14/F15/F16/F17；双向单文件、目录、空文件、重名、权限、跨平台目标、慢链路、relay/直连、第二会话认证、取消和断线；目标内容验证与时间戳正确。

**T7：系统文件剪贴板与图片/富文本**

前置：T5 和 T6 提供的接收/发送 adapter 就绪；若单一协议先完成，可仅对该协议开放。

1. RustDesk 接入真正的 Cliprdr ready/format_list/format_data/file_contents/失效处理，不以按钮上传代替；复用共用文件对象、任务、路径安全与租约。
2. 本地 Picker、拖拽、文件管理器 clipboard 使用统一 LocalFileProvider；Phone/Pad/PC 能力取决于 API/协议，布局只决定入口形态。
3. 鸿蒙 API 26 文档和实际 API 23/26 SDK 逐项核对：READ_PASTEBOARD、getUnifiedData/setUnifiedData、getDataWithProgress/ProgressSignal、URI 共享授权、生命周期与系统控件。getDataWithProgress 不支持目录拷贝，目录单独处理；系统文件获取进度与网络进度分开。
4. 先采用完整接收到受管目录后发布可读 URI；发布之后保持有效租约，验证外部文件管理器读权限。绝不能把“还没下载的本地路径”作为已可用 URI。
5. 延迟 getter/虚拟文件按需读取单列实验验收：只用受支持平台 API，不在系统回调里执行无界网络等待，处理超时、来源退出、重复读取和取消。若外部应用无法正确等待，则继续使用先下载后粘贴方案，不降低完整性。
6. 图片先支持规范 PNG/PixelMap 与双方已协商格式；按尺寸和解码后字节限制，避免解压炸弹。HTML/RTF 后续分别验证跨应用效果，保留纯文本；未知格式不作为文本误解码，也不自动执行内容/加载外链。
7. 保留远端内部 Ctrl+C/Ctrl+X/Ctrl+V 的自然行为。只有来源和用户意图明确属于本机粘贴时拦截；可使用显式“粘贴本机文件/文本”消除来源歧义。

验收：F06/F10/F13；两端文件管理器复制粘贴、同内容新事件、文件复制与文本/图片交替、URI 授权过期、剪贴板源更换、多窗口；目录与不支持格式有明确结果。

**T8：复制与剪切/移动事务**

前置：T4/T5/T6/T7 的相应方向能提供足够完成证据。移动按 adapter 与方向分别开放，不作为所有协议统一默认能力。

1. 区分 copy 与 move 意图；识别实际支持的 OS drop effect/剪切标记，并校验不是陈旧/伪造事件。仅看到 Ctrl+X 按键或文件列表不足以授权删除。
2. 目标完整接收、校验和提交后才考虑删除源。要删除的是原始 source identity，不是同名后来新建的文件；多文件逐项记录，不一次性删除整个目录树。
3. 重新验证源身份只是必要条件，不足以消除校验与删除之间的竞态。只有平台/协议提供可靠的句柄或条件删除语义、或等价可证明的互斥，才自动删除；无法实现则保留源，提供明确的仅复制结果。
4. 本地 Picker/clipboard 通常只有读取授权，不能据此推断具有删除授权。远端 cliprdr 也不保证存在可信最终落盘/删除回执；不得通过注入 Delete 键冒充协议移动。
5. 对账 copyComplete、targetVerified、sourceDeleteRequested、sourceDeleted 与 commitUnknown；重启/重试不得重复删除，也不得在目标未知时重新覆盖后删源。
6. 源文本剪切不改变其 OS 行为；文件系统共享盘 move 单独验收 Windows 语义，不与 app 自管移动互相计为成功。

验收：任意阶段取消/断线/目标磁盘满/源被替换/账号变化都不误删源；删除失败保留目标副本并准确呈现部分结果。能力不足时明确“已复制，源文件保留”，该结果不能计为完整移动通过。

**T9：性能、设备矩阵、独立复核与发布收口**

1. 使用统一诊断字段 task/attempt ID、脱敏 host scope、protocol、direction、source kind、lease generation、phase、字节与错误码，不记录文件内容、完整路径、剪贴板正文、账号凭据。
2. 建议初始目标：单传输热路径文件缓冲 ≤8 MiB、总传输缓冲 ≤32 MiB；Phone 默认一个活动大文件任务，PC 并发上限先为两个；块大小在 64–256 KiB 范围按协议核验。此为验收预算提案，T0 实测后冻结，不是已达到的性能声明，也不包含媒体解码内存。
3. 通知/进度建议每秒 4 次以内且终态立即更新；取消正常路径目标 2 秒内停止新块，故障 I/O 在已记录的 deadline 内收束。任何超出必须有清晰原因和可见受管状态。
4. 用目标文件 SHA-256 对比作为合成文件设备验收依据；平台只提供 metadata 的产品验证必须如实标注其证据级别。
5. 对每个实现/修复增量执行当次门禁、定向测试与独立子 agent 审查；P1 不带入发布。按状态 receipt 复用匹配审查，不重复重审无差量代码，不沿用旧构建。
6. 每个协议、方向、格式按已验证能力开放。完整任务完成后才走 push/PR/required open-source-compliance/merge；当前 Pro 分支未完成时保留同一分支，不为本计划合并未完成业务。

**6. 必须落地的测试矩阵**

| 用例组 | 最低场景 | 判定结果 |
|---|---|---|
| C01 文本编码 | ASCII、中文、emoji/非 BMP、多行、CRLF、非法代理项、NUL、字节边界 | 数据一致或明确拒绝，无静默截断 |
| C02 文本事件 | A→本地B→远端A、相同内容重复制、clear、发送/系统写入失败后重试 | 新事件生效，旧事件不重放，checkpoint 仅成功推进 |
| C03 粘贴时机 | 连接前复制、后台复制、切回后立即 Ctrl+V、权限刚获批 | 明确粘贴有当前内容；不自动广播历史内容 |
| C04 所有权 | 两个可见窗口、切焦点、最小化、前后台、克隆、账号切换 | 无串传和晚回调覆盖 |
| C05 来源抢占 | 本地文件A仍在，远端复制/剪切B后粘贴；文本/文件/图片交替 | 粘贴来源正确，无重复注入 |
| F01 文件边界 | 0 B、1 B、64 KiB±1、100 MiB±1、2 GiB±1、未知大小来源 | 能力边界准确，字节数与内容一致，内存/磁盘受控 |
| F02 名称/路径 | 同名、大小写、清洗碰撞、%20/%2F、中文/emoji、保留名、长名、..、符号链接 | 不覆盖错误对象，不访问授权根外 |
| F03 目录/批次 | 空目录、多层树、混合文件、超数量/层级/总大小、部分失败 | 逐项结果，重试不重复已提交结果，批次可取消 |
| F04 目标冲突 | overwrite/skip/rename、只读、目标被替换、磁盘满 | 策略生效；未知提交不盲重试 |
| R01 RDP 文件协议 | 真实 FormatList/descriptor/size/range、乱序/短读/超时、远端格式切换 | stream/task/epoch 匹配，文件不混合 |
| R02 RDP 锁撤销 | 锁中换内容、关开关、断线、旧请求、超大请求 | 合法旧锁可读条件明确；关闭授权后无新增读取 |
| R03 RDP 共享盘 | accepted/rejected/removed、持续写入/rename、多个主机默认名、导出 | 状态真实、可见性明确、历史内容不跨主机暴露 |
| D01 RustDesk 会话 | direct/ID/relay、固定版本 hbbs/hbbr、文件二次认证/MFA/批准/拒绝 | 认证与路由不弱化；取消清理本任务会话 |
| D02 RustDesk 文件协议 | upload/download、digest/confirm/skip、compressed block、sender Done、error/cancel、mtime | 方向正确、冲突正确、sent/verified 分开 |
| L01 任务生命周期 | picker/read/enqueue/write/verify/rename/export 各阶段断线/取消/杀进程 | 不误投新代次，无孤儿状态，partial 可恢复或安全回收 |
| L02 多任务 | 同名并发、旧 worker 晚结束、批量超时再上传、100 次回放 | taskId 独立，无单状态槽覆盖，无通知泄漏 |
| H01 鸿蒙系统集成 | URI 授权、拒绝/撤销读取、延迟加载、外部文件管理器粘贴、第三方应用打开 | 返回真实可读文件；平台不支持时明确回退 |
| H02 多格式 | PNG/PixelMap、HTML、RTF、无纯文本/多格式、过大解码 | 协商准确、资源有界、回退可解释 |
| M01 移动 | 目标成功/失败/未知，源替换，删除失败，进程恢复，重复请求 | 未验证不删源；不删后来替换的同名文件 |
| P01 性能 | 低内存、大文件、500 ms RTT、受限带宽、丢包/重连、后台 | 缓冲/取消/通知符合冻结预算，无 UI 长时间同步 I/O |

设备/对端组合：API 23/26 的 Phone、Pad、PC；RDP 主测固定 Windows 客户端/服务器版本与组策略；RustDesk 主测 Windows/Linux/macOS，Android 能力单独列。网络包含 LAN、跨网直连、用户自建 relay、慢链路；UDP/KCP/AUTO 仍遵守现有未完成的拓扑开放门，不借本计划自动开启。

SDK 编译可覆盖不在场设备，但设备验收记录必须注明设备/系统/对端版本/构建/网络/结果/内容哈希。缺设备只阻塞对应设备结论，不能用宿主 mock 替代。

**7. 代码范围、提交与回滚控制**

| 工作包 | 预计文件范围 | 提交与回滚边界 |
|---|---|---|
| T1 | Clipboard*、RemoteDesktop 剪贴板入口、RemoteSessionCapabilityPolicy、ExtensionLoader/NAPI、native clipboard | 按会话隔离、事件序列、Unicode 分提交；保留真实能力关闭路径 |
| T2 | RemoteDesktop RDP 文件入口、rdp_file_clipboard_*、FreeRDP callback wrapper、暂存 provider | 安全修复不回退到共享历史根/无租约旧路径；新入口可单独关闭 |
| T3 | FileTransfer*、TransferSessionPolicy、任务服务/store、RustDesk status FFI | 状态 schema 可读旧记录；未识别记录保留待处理，不自动执行 |
| T4/T5 | RDP adapter、共享盘接收 UI、RDP native 接收器、LocalFileProvider | 盘接收与 clipboard 接收单独开关；关闭不删除用户文件 |
| T6 | RustDesk bridge/FFI/session/connector、远端文件面板 | 上传/下载/目录/续传逐项开放，不退回固定路径或弱信任 |
| T7 | 公共 ClipboardCoordinator、RDP/RustDesk file clipboard adapter、平台 URI/格式处理 | 每方向/格式独立开关，先下载后粘贴作为受支持回退 |
| T8/T9 | 条件移动、对账、诊断与性能 | 移动关闭时保留复制；先撤销新请求再 drain，保留未知提交记录 |

每阶段修改前刷新 Git 状态，保留其他任务变更；只暂存明确本任务文件/差量。新增依赖、gitlink/proto 或 vendor patch 才更新对应 SBOM/NOTICE/provenance/hash，不为计划伪造依赖变更。后续功能变更必须 commit，独立审查发现问题就在同一任务分支修复并重验。

不得以“统一架构”为由立即重写整个 SSH/SFTP。首次接入只复用纯策略/文件 provider/任务视图；只有证明任务语义一致且既有取消/rename/export 回归通过后，才考虑引擎合并。

**8. 强制验证命令与证据记录**

macOS 在项目根执行；Windows 使用 DevEco 自带 launcher 和相同任务名/参数。每次实际代码或文档变更的要求以当前 AGENTS 为准。

```sh
source scripts/macos_env.sh
hvigorw --mode module -p module=entry -p product=default default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon
hvigorw --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --no-daemon
pwsh -NoProfile -File scripts/verify_open_source_release.ps1 -Mode Light
git diff --check
```

ArkTS 测试模块受影响时另加 `ohosTest@OhosTestCompileArkTS`；若任务未注册，按真实失败记录，不能用旧的 OhosTestBuildArkTS 替代。native/Rust/FFI 变更执行定向原生/Rust 回归与受影响双 ABI；宿主 cargo 测试与 OHOS ABI 构建分开记录。仅文件存在不证明真实 FreeRDP/RustDesk 链接、生效或设备接受。

每个工作包必须记录：base/head、plan hash、声明代码范围、测试命令/退出值、精确成功/失败摘要、独立 reviewer task ID、receipt、设备矩阵和 blocker。只有实际检查通过才能写 PASS；独立审查状态仅覆盖其声明范围。文档计划通过不等于 T0–T9 代码审查通过。

**9. 风险、待验证决策与降级路径**

| 决策/风险 | 必须取得的事实 | 未成立时的行为 |
|---|---|---|
| 多窗口系统焦点/剪贴板调度 | API 23/26 PC 可见窗口、focus/active/background 真实事件 | 唯一显式活动会话收发，禁止多桥广播 |
| OHOS 延迟文件提供 | 外部文件管理器可等待、回调可取消、URI 授权有效、来源退出可控 | 先完整接收再发布真实 URI |
| RDP helper 集成范围 | 本地到远端/远端到本地 flags、锁、错误、callback lifetime 的固定版行为 | 新接收独立关闭，发送保留安全修复 |
| RustDesk 目标验证 | 对端目录/stat/读回能力、二次认证和文件权限 | 仅声称 sender-complete，不开放自动源删除 |
| 原子本地导出 | Picker 目标是否可安全 rename/替换，取消跨越 TRUNC 的边界 | 使用受管副本和明确覆盖确认；不制造“原子”假承诺 |
| 恢复/续传可信度 | 源、partial、偏移与连接身份可复核 | 保留 partial，重新授权/确认；不自动续传 |
| 移动源删除 | 可靠条件删除/稳定身份、真实删除权限与目标验证 | 保留源，明确仅复制或删除未完成 |
| 旧共享目录恢复 | 历史文件归属未知，可能是用户唯一副本 | 提供恢复/导出，不自动清理或重新暴露 |
| 大文件性能 | 实测缓冲、空间、取消期限、跨 ABI 计数 | 保留合理大小/并发上限，不硬改产品承诺 |

这些事项是实施时的验证任务，不阻塞本计划落盘。确实需要设备、账户/目录选择或外部配置时再请求所需输入；不为已授权的普通修复重复确认。

**10. 执行状态与完成定义**

| 工作包 | 当前状态 | 已关闭诊断项 | 剩余条件 |
|---|---|---|---|
| 计划实体文件 | 已交付并复核，实施已授权 | 无实现项关闭 | 保留设备与性能验收边界 |
| T0 | code_regression_baseline_ready | F01–F17 均有生产实现/回归路径 | 未获取设备性能基线；见第 13 节 |
| T1 | code_implemented_reviewed | F01/F02/F06/F07/F08/F09 的代码边界 | API23/26 多窗口/前后台/真实系统剪贴板 |
| T2 | code_implemented_reviewed | F03/F04/F05/F12 的代码边界 | 真实对端锁/撤销、存储/授权故障设备验收 |
| T3 | code_implemented_reviewed | F11/F14/F15/F16 的任务证据边界 | 真实后台存活、通知回收、故障 I/O 时延 |
| T4 | code_implemented_reviewed | F04/F11/F17 共享盘隔离及设备回复事实 | Windows 服务器拒绝/卸载/持续写入/导出矩阵 |
| T5 | code_implemented_reviewed | F10 直接 native partial 接收器 | Windows 文件管理器到 API23/26 接收/另存矩阵 |
| T6 | code_implemented_reviewed | F13/F14/F15/F16/F17 文件会话路径 | 固定 peer、二次认证、跨平台目录/冲突/网络；未开放盲续传 |
| T7 | code_implemented_reviewed | 真正 RustDesk Cliprdr、RDP PNG/HTML/RTF、有界系统文件读取 | 跨应用格式/URI 授权和延迟能力设备验收 |
| T8 | copy_only_fallback | 没有基于发送完成、剪切标记或 Ctrl+X 自动删除源文件 | 完整移动未实现/不可用，条件删除/权限/目标提交证据不足 |
| T9 | host_checks_ready_device_pending | 独立增量复核、1/2 受管并发、64 KiB 块、250 ms 进度节流 | 真机性能/内容 SHA-256/网络/后台矩阵和分支发布收口 |

计划交付完成指：实体文件可读、F01–F17 全部映射、范围/依赖/源码入口/验收/回滚明确、共享队列可找到、文档适用门禁与审查如实记录。不得把这一状态改写为“文件传输修复完成”。

后续全部功能交付完成指：已授权实施范围内的代码与设备矩阵通过；所有 P1 关闭；公开能力与实际已验收的协议/方向/格式一致；没有孤儿任务、误投、静默覆盖或未验证删源；按项目完整分支流程收口。若移动只能提供复制降级，则明确标为移动未实现/不可用，而不是完成移动。

**11. 可追溯源码与官方资料**

以下相对路径从本计划目录解析，跨设备不依赖本机绝对路径。打开具体实现并按符号定位，不把计划快照视为最新行为。

- [RemoteDesktop 页面](../../../entry/src/main/ets/pages/RemoteDesktop.ets)：startClipboardBridgeBestEffort、currentSessionCapabilities、stageFileForRdpClipboard、submitFileToRustDesk、handleRdpSystemFilePaste、handleFileDrop、ensureRdpTransferDir、物理 Ctrl+V 拦截。
- [ClipboardBridgeService](../../../entry/src/main/ets/services/ClipboardBridgeService.ets)、[ClipboardSyncPolicy](../../../entry/src/main/ets/services/ClipboardSyncPolicy.ets)、[RemoteSessionCapabilityPolicy](../../../entry/src/main/ets/services/RemoteSessionCapabilityPolicy.ets)。
- [FileTransferLiveTaskService](../../../entry/src/main/ets/services/FileTransferLiveTaskService.ets)、[TransferSessionPolicy](../../../entry/src/main/ets/services/TransferSessionPolicy.ets)、[ExtensionLoader](../../../entry/src/main/ets/services/ExtensionLoader.ets)、[NAPI](../../../entry/src/main/cpp/extensions/extension_loader_napi.cpp)。
- [FreeRDP adapter](../../../entry/src/main/cpp/rdp/freerdp_adapter.cpp)、[文件 bridge](../../../entry/src/main/cpp/rdp/rdp_file_clipboard_bridge.cpp)、[文件 offer](../../../entry/src/main/cpp/rdp/rdp_file_clipboard_offer.cpp)、[现有 offer 测试](../../../entry/src/main/cpp/test/rdp_file_clipboard_offer_test.cpp)。
- [FreeRDP file helper](../../../freerdp/client/common/client_cliprdr_file.c)、[rdpdr 设备回复](../../../freerdp/channels/rdpdr/client/rdpdr_main.c)、[URI 解码](../../../freerdp/winpr/libwinpr/clipboard/clipboard.c)、[OHOS 构建选项](../../../scripts/build_freerdp_ohos.sh)。
- [RustDesk bridge](../../../entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp)、[FFI](../../../rustdesk_ffi/src/lib.rs)、[connector](../../../rustdesk_ffi/src/connector.rs)、[proto](../../../rustdesk_vendor/libs/hbb_common/protos/message.proto)、[来源记录](../../../rustdesk_vendor/libs/hbb_common/protos/UPSTREAM.yml)。
- [SFTP 引擎](../../../entry/src/main/ets/services/SshSftpTaskEngine.ets)、[SFTP 完整性策略](../../../entry/src/main/ets/services/SshSftpIntegrityPolicy.ets)、[本地文件 provider](../../../entry/src/main/ets/services/SshLocalFileProvider.ets)。
- [鸿蒙 Pasteboard API](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-pasteboard)、[getDataWithProgress](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-pasteboard#getdatawithprogress15)：已在线及 SDK 核对类型、权限、文件进度/取消和不支持目录的边界。
- [Microsoft 文件内容请求](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpeclip/cbc851d3-4e68-45f4-9292-26872a9209f2)、[锁定内容处理](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpeclip/d19de33e-4027-43de-b150-668ee21bced8)。
- [RustDesk clipboard 官方说明](https://github.com/rustdesk/rustdesk/blob/master/libs/clipboard/README.md)、[官方权限与方向配置](https://rustdesk.com/docs/en/self-host/client-configuration/advanced-settings/)、[固定版本服务器 Done 处理](https://github.com/rustdesk/rustdesk/blob/93d064a9b0eb58ab94db88ff727a877ef773c0d8/src/server/connection.rs#L3274)、[固定版本 mtime 处理](https://github.com/rustdesk/hbb_common/blob/387603f47cbb15c0d3dc3d67ae3396d3eb707daf/src/fs.rs#L718)。

**12. 本次文档交付记录**

- 2026-09-07 计划交付阶段：应用实现、测试、构建配置、依赖和运行时开关未修改；不适用于后续已授权的实现增量。
- 文档结构与链接检查：F01–F17、T0–T9 完整映射，24 个本地源码链接均有效；无本机用户目录路径。
- 当次 `default@OhosTestCompileArkTS`：exit 0，`BUILD SUCCESSFUL in 933 ms`。首次沙箱启动因构建缓存写入 EPERM 未进入编译；授权访问现有缓存后成功，未改变构建路径或设置。
- 当次签名 `assembleHap`：exit 0，`Finished :entry:default@SignHap... after 1 s 942 ms`，`BUILD SUCCESSFUL in 14 s 290 ms`。
- 当次 Light：exit 0，`Open-source compliance gate passed (Light).`；`git diff --check` 和共享状态检查在提交前复核。
- 独立计划 reviewer：`/root/review_transfer_plan`；结论及最终文件 hash 记录在 `REVIEW_RECEIPTS.jsonl` 的 `file-transfer-clipboard/plan` 范围。该审查不覆盖并发 Pro 实现。
- 验证时共享工作区 HEAD 为 `bbc7fb535`；原诊断重点源码相对计划编写基线无变化。构建结果仅说明当次共享源码可编译/签名，不表示本计划的功能已经实现。
- 2026-09-07 计划交付时设备、协议网络传输、功能修复验收 NOT RUN；该时点 T0–T9 为 pending，后续状态见第 10/13 节。

### 2026-09-08 首批实现验证记录（未关闭工作包）

已接通会话/账号/窗口/route/native 所有者、远端事件来源与 RDP 实际 FormatList ACK 后粘贴；私有文件副本/清单、受管任务；RDP DEVICE_REPLY/写入句柄事实与远端文件接收；RustDesk 有界 FD 上传、显式远端目录与下载；接收后完整性校验、另存和已接收文件 URI 发布。源文件不自动删除。

定向验证：RDP native 50 项及双 ABI 10 项语法检查；Rust 289 项与 arm64-v8a/x86_64 源码构建；剪贴板 18、任务 16、真实文件系统 19、生产页面所有者/ACK/取消 12 项通过。首轮 testCompile 18 s 833 ms、签名 assembleHap 21 s 137 ms，均 exit 0；最后取消/释放修复后的 testCompile 7 s 112 ms、签名 assembleHap 8 s 578 ms（SignHap 909 ms）均 exit 0；Light/diff PASS。

本记录不是整体完成或独立代码审查通过。缓存恢复/发布租约回收、目录批次与冲突策略、RustDesk Cliprdr、图片/富文本、复制意图策略及真机/性能验收继续实施。没有安装/操作在用设备或对用户文件进行网络传输。


**13. 2026-09-08 实施增量与待验收边界**

代码提交：首批 `4039c311` 与 `a307a8af/31b1051e/fabdb8db/c8bf7c30` 修复；第二批 `e85a4e63`；RustDesk 文件剪贴板公开接线与四项复核修复 `e94e5fea`。系统文件读取/双协议目录别名/统一诊断最后增量 `42718408`。均留在同一活动分支，不包含其他 Pro/AI/UI 工作的审查结论。

- 首批三位非作者 reviewer 分工 PASS，关闭七项复核问题；对应收据保存在 REVIEW_RECEIPTS。第二批 RDP/rich/原生导出非作者复核 PASS；页面发现的两项 P2、Store 的 P2、Rust 文件剪贴板的 P1 已在 e94e5fea 修复。第三批 Store/Rust/FFI 非作者复核 PASS；页面/client 复核发现的大小写/NFC 父路径别名 P2 已在 42718408 修复并由原 reviewer 复核 PASS；邻接检查同步补 RDP native/整清单父路径一致性，避免选目录接收时漏掉别名子目录；两 native 文件由非作者独立 9 项回归 PASS。
- 第二批新增 manifest 恢复与受管发布租约、历史目录显式恢复、文件/空目录逻辑树、目录另存、RustDesk 目录/二次认证与明确冲突策略、RDP 图片/HTML/RTF、原生授权 FD 导出。RustDesk Cliprdr 在第三批接入公开 FFI/业务/UI；已发布 FD 保持到真实撤销 drain，晚请求不接到新 offer。
- 第二批门禁：testCompile `BUILD SUCCESSFUL in 9 s 374 ms`；签名 assembleHap `BUILD SUCCESSFUL in 1 min 216 ms`；Light/diff PASS，均 exit 0。第三批门禁：testCompile `BUILD SUCCESSFUL in 4 s 923 ms`；签名 assembleHap `BUILD SUCCESSFUL in 7 s 499 ms`；Light/diff PASS，均 exit 0。最后增量 `42718408` 的当次 testCompile `BUILD SUCCESSFUL in 7 s 471 ms`；签名 assembleHap `BUILD SUCCESSFUL in 8 s 665 ms`（SignHap 894 ms）；Light/diff PASS，均 exit 0，11 个源码/测试文件的 SHA-256 在门禁后及提交前匹配。
- 最近覆盖证据：RDP rich/lane/FD export 40 项、原生 FD sanitizer 14 项；RichContent 21、ClipboardBridge 30、ManagedTask 18（含 100 次回放）、ArtifactStore 51、DirectoryProvider 17、LegacyRecovery 10；Rust 318 项及 arm64-v8a/x86_64 源码构建、7 个新增 Cliprdr FFI 导出验证 PASS。非作者另以无默认特性独立运行 Rust 308 项 PASS；两条命令配置不同，不将其相加。最后增量页面 34、RustDeskClipboardClient 13、SystemClipboardFileProvider 15、诊断投影/服务接线 7、RDP descriptor 9 项 PASS；诊断接线后的原 ManagedTask 18 项 PASS，RDP 修改执行了真实 compile_commands 双 ABI 语法检查。

移动保持关闭：产品明确“跨端剪切按复制处理，源文件保留”。Picker/剪贴板 FD 为只读授权；源删除事务与逐项对账未实现，没有注入 Delete 替代协议移动。共享盘内由 Windows 执行的 move 是对端文件系统行为，不能作为应用移动验收。

性能边界：受管任务默认 Phone/Pad 1 个、2in1 2 个；本地复制及 RDP 接收块为 64 KiB。Rust 下载解压块限制 128 KiB，Cliprdr 请求 4 MiB，待写队列 8 MiB/64 条。它们不覆盖所有序列化副本或系统缓存，不能推导单任务 ≤8 MiB/总量 ≤32 MiB。普通进度按每任务 250 ms 节流，终态即时发布，不代表整机全局通知 ≤4 次/秒。默认无进展 300 秒、取消 drain 5 秒、RDP 请求 15 秒/总体 30 分钟、Rust 写入 10 秒；正常取消 ≤2 秒尚无设备实测。没有证据的 native drain 保留 paused/commitUnknown 及 partial。

持久记录包含 task/attempt、hostId、protocol、direction、sourceKind、leaseId、阶段/字节/证据与受限错误码，不存凭据、临时 URI 授权或正文。最后增量补入统一 15 字段诊断投影：task 与 account+host 仅输出有界诊断关联散列，所有枚举/错误码白名单，13 处入口填 native generation；按已有 250 ms 发布点输出，不序列化原记录，异常不影响任务。FNV 仅用于诊断关联，不是密码学匿名化或授权身份。跨通道热缓冲峰值与设备端诊断关联仍待实测。

设备/对端 blocker：尚未取得本次 Debug 安装/操作及合成文件对端目标的明确授权；不干扰用户在用设备。API23/26 Phone/Pad/PC、固定 Windows RDP、RustDesk Windows/Linux/macOS/Android、LAN/直连/relay、500 ms RTT/限速/丢包、后台与低内存、目标端独立 SHA-256、外部文件管理器 URI 读取/富文本粘贴均 NOT RUN。无锁对端/未可靠标识来源保持暂停重收，未开放自动盲续传。OHOS 虚拟远端文件的延迟系统 getter 保持实验未开放；使用先完整接收再发布真实 URI 的回退。

分支 blocker：同一 Pro/AI/UI 分支仍有并发未完成工作。完整任务尚未满足设备矩阵与发布条件，不 push/PR/merge 整个未完成分支，不宣称 T0–T9 全部完成。

最后收据覆盖：首批三份 PASS 保留；后续四份分别覆盖 RDP/rich/原生导出、Store/Rust/FFI、页面/服务/系统读取/诊断、RDP 父路径。后三个代码增量的 59 个不同路径均有对应非作者范围，混合文件内的 Pro/AI/UI 变化明确排除。当前未遗留代码复核 finding；整体状态仍为设备/性能/发布待验收。

文档收口当次门禁：testCompile `BUILD SUCCESSFUL in 4 s 93 ms`；签名 assembleHap `BUILD SUCCESSFUL in 5 s 390 ms`（SignHap 875 ms），均 exit 0；Light/diff/state PASS。五个状态/计划/收据文件在门禁前后 SHA-256 一致，随后仅记录本段真实结果。
