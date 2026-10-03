/**
 * What the numbers in a capture mean. Events carry codes and counts, never text, so the model needs this key to read
 * them; it is sent only with a capture to analyse. Extend it with every new event code.
 */
const GLOSSARY: string[] = [
  '通用：outcome 为 started/succeeded/failed/cancelled/timeout/skipped/retry/state；elapsedMs 为距抓取开始的毫秒数。',
  '*_state_changed：code 为连接状态，1 连接中、2 已连接、4 失败、0 已断开、5 等待二次验证（RustDesk）。',
  '*_connection_request：succeeded 只表示本地已创建会话（还未连上），failed 的 code 为本地错误：-1 协议不可用、-2 连接被拒绝、-50 RDP 认证参数无效。',
  'rdp_failure：一次 RDP 失败。count 为类别：1 TCP/传输失败（端口不通、被防火墙拦截或远端未开启远程桌面）、2 DNS 解析失败、' +
    '3 TLS 握手失败、4 凭据或 NLA 认证失败（用户名、密码、域）、5 账号被禁用/锁定/过期/受限、6 证书问题、7 网关失败、' +
    '8 服务器主动断开（code 为服务器 ErrorInfo）、9 超时、10 已取消、11 安全协商失败（NLA/TLS/RDP 安全层不匹配）、' +
    '12 账号没有远程登录权限、13 密码过期需修改、0 未分类。code 为 FreeRDP 连接错误码（十进制，如 131085=0x2000D 传输失败、' +
    '131092=0x20014 登录失败）或服务器 ErrorInfo；generation 为 1 连接过程中、2 会话进行中；durationMs 为从开始连接到失败的毫秒数。',
  'rdp_certificate：用户对证书提示的选择，code 1 本次继续、2 信任并保存、3 取消连接、4 跳过预检。',
  'rdp_preflight：证书/路由预检；failed 表示预检阶段就无法连上（多为网络或端口问题）。',
  'rdp_clipboard / rustdesk_clipboard：剪贴板同步通道，code 0 已启动、1 被另一个连接占用、2 缺少本机剪贴板读取权限（只能远端到本机）、' +
    '3 本次连接没有协商剪贴板通道（需开启剪贴板后重连）、4 启动异常、5 原生层拒绝；count 1 表示本机读取可用。',
  'rdp_drive：驱动器映射，succeeded 已挂载、failed 服务器端不可用（组策略或远端禁止驱动器重定向）、timeout 15 秒内未挂载。',
  'rdp_audio：远程音频，skipped 用户关闭了远程音频、failed 本机音频播放器初始化失败（code 为句柄，≤0 失败）。',
  'rustdesk_failure：一次 RustDesk 失败。count 为类别：1 ID/中继服务器不可达或网络超时、2 对端 ID 不存在或离线、3 设备密码错误、' +
    '4 对端要求点击批准（密码不够）、5 等待批准超时、6 中继鉴权失败（服务器 Key 不匹配等）、7 Server Pro 登录或控制面不兼容、' +
    '8 二次验证失败、9 首帧失败（连上但没有画面）、10 握手失败或连接中断、11 本机 RustDesk 核心未运行、12 已取消、13 握手或验证超时、' +
    '14 连接方式不支持（如直连不能请求批准）、15 连接配置无效、0 未分类。code 为出错阶段：1 ID 服务器、2 中继、3 控制面、4 对端、5 其它、0 未知；' +
    'generation 1 连接过程中、2 会话中；durationMs 为从开始连接到失败的毫秒数。',
  'rustdesk_first_frame：连上后到第一帧画面显示，durationMs 为耗时，count 为期间请求解码恢复/关键帧的次数；timeout 即黑屏（连上但一直没画面），' +
    'failed 表示等待首帧时连接断了。',
  'ssh_session_event：SSH 会话状态，code 1 已创建、2 连接中、3 认证中、4 就绪、5 网络中断、6 计划重连、7 重连中、8 需要重新认证、9 失败、10 关闭中、11 已关闭。',
  'ssh_preflight：主机指纹预检，failed 的 code 为原生错误码（-99 为本地调用异常），多为网络不通或端口不对。',
  'ssh_failure：一次 SSH 连接失败。count 为类别：1 连接失败（网络、端口、服务未开）、2 认证失败或取消（用户名/密码/键盘交互）、3 主机指纹问题、' +
    '4 私钥缺失或私钥口令错误、5 跳板机失败、6 代理失败、7 路由或预检已过期、8 会话绑定失败、0 未分类；code 为原生连接返回码；' +
    'durationMs 为从开始连接到失败的毫秒数。',
  'sftp_task_started / sftp_task_completed：code 1 上传、2 下载；bytes 为文件大小或已校验的字节数。',
  'sftp_failure：SFTP 任务失败。count 为类别：1 本机文件读写失败（文件不存在、无法读取或写入）、2 写入后校验不一致、3 文件在传输中被改动、' +
    '4 路径、冲突或续传位置无效、5 传输异常、6 目录准备失败、7 连接中断（任务等待重连，outcome 为 retry）；generation 1 上传、2 下载；code 为具体原因编号。',
  'vnc_failure：一次 VNC 失败。count 为类别：1 连接失败（地址、端口、服务未开）、2 VNC 密码错误、3 缺少密码、4 TLS 配置不匹配（目标是明文 RFB 却开了 TLS 等）、' +
    '5 证书问题、6 网关或 WebSocket 配置问题、7 地址、配对或主机配置无效、8 恢复画面失败、9 超时、0 未分类；durationMs 为从开始连接到失败的毫秒数。',
  'vnc_update_rejected / vnc_update_progress：画面更新被拒绝（编码不支持等）与更新进度。',
  'moonlight_pair / moonlight_catalog / moonlight_launch：配对、读取应用列表、启动串流的结果。code：0 成功、1 参数无效、2 本机忙、' +
    '3 需要运行时证明、4 主机不可用、5 未配对、6 应用不存在、7 应用列表无效、8 需要先恢复上次会话、9 主机正忙（已有串流）、10 需要确认、' +
    '11 操作被主机拒绝、12 结果未知、13 已取消、14 请求已过期、15 超时、16 网络传输失败、17 协议失败、18 需要重新配对、19 正在关闭、' +
    '20 原生异常、21 缓存失败、22 已释放、23 生命周期已关闭；count 为部分返回的应用数。',
  'moonlight_state_changed：串流会话阶段，code 1 发现主机、2 校验、3 需要配对、4 已配对、5 应用列表就绪、6 请求启动、7 主机接受启动、' +
    '8 视频就绪、9 音频就绪、10 输入就绪、11 首帧已显示、12 串流稳定、13 传输中断、14 重连协商中、15 请求停止、16 已停止、17 失败、18 已取消、' +
    '19 能力降级（如解码器能力不足）。',
  'app_fault_history：抓取开始时的最近 7 天故障统计（只有类型与时间，没有堆栈）：count 为闪退次数、generation 为卡死次数、' +
    'code 为最近一次的类型（1 JS 崩溃、2 原生崩溃、3 卡死）、durationMs 为距最近一次的毫秒数、bytes 为本次运行的未捕获异常数。',
  'app_exception：本次运行中出现未捕获的 JS 异常，count 为累计次数。',
  'app_lifecycle：应用前后台变化；window_orientation_*：屏幕方向请求与结果。',
  'account_login：华为账号登录。count 为方式：1 手动登录、2 启动时静默恢复、3 无网络时离线恢复；code 为华为账号接口错误码' +
    '（1001502002 用户取消、1001502014 企业账号受限，其余见华为账号 Kit 错误码）；timeout 表示静默恢复超时。',
  'cloud_sync_requested / started / retry：code = 来源×10 + 方向。来源 1 启动、2 回到前台、3 云端有变化、4 自动推送、5 手动上传、6 手动下载、' +
    '7 重新开启同步、8 本地恢复；方向 1 本机优先、2 云端优先。count 为同步的表数；retry 的 durationMs 为下次重试的延迟。',
  'cloud_sync_completed / skipped：code 为失败类型：0 无、1 版本冲突、2 空快照、3 删除记录清理、4 数据不安全被拒绝、5 云服务错误、6 网络、' +
    '7 结果不确定、8 等待恢复、9 没有选择同步内容、10 未知、11 本地收尾失败；count 为失败的表数。',
  'ai_request：一次 AI 请求。count 为用途：1 问答、2 设置、3 诊断、4 反馈、5 读取模型列表（连通性）、6 聊天模式；code 为失败类别：0 成功、1 网络、2 超时、' +
    '3 Key 或权限（401/403）、4 限流（429）、5 服务端错误（5xx）、6 请求格式不被接受（400/422）、7 空结果、8 请求过大（413）、9 端侧模型不可用、' +
    '10 服务地址无效、11 当前套餐或用途不允许、12 其它；generation 为 HTTP 状态码；durationMs 为耗时；bytes 为请求内容大小。',
  'ai_config：AI 配置问题，code 1 API Key 无法从本机安全存储读出、2 没有选择可用的 AI 服务和模型。',
  'ai_setting：AI 一键修改设置，code 为设置在目录中的序号，outcome succeeded 已修改、failed 未修改（已是该值或无法修改）。',
  '*_runtime_snapshot：runtime.protocol 中 receivedFps/displayFps 为接收与显示帧率，decodeErrors 解码错误数，droppedFrames 丢帧，' +
    'lastFrameAgeMs 距最后一帧的毫秒数（很大说明画面停了），inputEventsDropped 丢弃的输入，bitrateKbps 码率。'
];

export function diagnosticAiEventGlossary(): string {
  return GLOSSARY.join('\n');
}
