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
  'rdp_preflight：证书/路由预检；failed 表示预检阶段就无法连上（多为网络或端口问题）；count 1 表示这台电脑只接受旧版 TLS' +
    '（1.0/1.1 或弱加密，常见于未更新的 Windows 7 / Server 2008 R2），用户在证书提示里同意降低安全要求后才会连接。',
  'rdp_name_resolution：RDP 主机名解析（预检时名称解析失败或解析出的地址连不上才会进行；只有数量和步骤，没有名称和地址）。' +
    'succeeded 找到地址、failed 都没找到；count 为最终方式：1 DNS、2 DNS 加网络的域名后缀（office-pc → office-pc.corp.local）、' +
    '3 局域网（xxx.local 用 mDNS，计算机名用 LLMNR 和 NetBIOS，与 mstsc 在局域网里的做法相同）、0 未找到；' +
    'generation 为尝试过的步骤位：1 DNS、2 域名后缀、4 局域网（名称含点且不以 .local 结尾时不查局域网）；code 为找到的地址数；' +
    'durationMs 为解析耗时。failed 且 generation 含 4：局域网里没有设备应答这个名称（电脑关机、不在同一网段、' +
    '防火墙拦截 UDP 5353/5355/137，或名称写错），建议改填 IP 地址。',
  'rdp_security_choice：用户对单台电脑降低或恢复 RDP 安全要求（只保存在本机，按账号、主机和地址区分）。code：1 同意这台电脑用旧版 TLS、' +
    '2 这台电脑改用 TLS 登录（不做 NLA）、3 恢复这台电脑的 NLA 登录、4 撤销旧版 TLS、5 删除主机时一并清除、' +
    '6 在「设置 → Windows RDP → 恢复各电脑的默认安全设置」里全部恢复；failed 表示没能保存（选择没有生效）；' +
    'count 为之后仍有降级选择的电脑数。',
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
    'lastFrameAgeMs 距最后一帧的毫秒数（很大说明画面停了），inputEventsDropped 丢弃的输入，bitrateKbps 码率。' +
    'RDP 例外：receivedBytes 为 GFX 线上负载字节，bitrateKbps 不导出（为 0），callbackBytes 为本机渲染回调拷贝字节（不是网络流量）。',
  'runtime.rdpGraphics（RDP）：requestedMode 只是连接前客户端愿意通告的模式（gdi/gfx/gfx-h264），不是线上事实；' +
    'capsConfirmed/capsConfirmedVersion 为服务端确认的 GFX 能力版本；wireCodec 为实际 GFX 帧编码（none 表示没有收到 GFX 帧，' +
    'remotefx/progressive/planar/clearcodec/avc420/avc444 等）；h264Status：gated_off 客户端门禁未通告 H.264、advertised_unconfirmed 已通告待确认、' +
    'server_disabled 服务端确认不用 AVC、allowed_not_used 允许但未出现 AVC 帧、in_use 已收到 AVC 帧；wireBytes 为 GFX 线上负载字节，' +
    'copiedBytes 为本机呈现拷贝字节（不是网络流量）；fallbackReason 为本次连接因同一主机上次 GFX 失败而回退 GDI 的原因。' +
    'evidenceLevel 为 missing 或 configured 时不得断言线上编码。',
  'rdp_graphics_negotiation：RDP 图形协商发生变化（能力确认、首次看到某种线上编码、回退），runtime.rdpGraphics 为变化后的值；' +
    'code 0 无原生证据、1 只有客户端配置、2 服务端已确认能力、3 已观测到线上编码、4 已收到 H.264 帧；count 为 GFX 帧命令数，bytes 为线上负载字节。',
  'rustdesk_quality_request：会话中切换画质。generation 为请求档位（0 速度、1 平衡、2 画质），code 1 已交给原生发送、0 被拒绝只保存为下次连接；' +
    'count 为切换前远端报告的目标码率（kbps，0 表示未报告）。画质档位只改变远端编码码率，不改变分辨率与色度采样。',
  'rustdesk_quality_result：画质切换的证据结论。code 1 发送失败、2 远端码率升高、3 远端码率降低、4 码率未变化（受网络自适应或远端编码器限制）、' +
    '5 远端未报告码率（无法确认）、6 尚未得出结论就被更新的档位、断开或离开页面取代；count 为切换后的远端目标码率（kbps，6 时为 0）；' +
    'durationMs 为等待时长。只有 2/3 能说明“已生效”，判断最新档位看最后一条结果。',
  'rustdesk_direct_stage：RustDesk 连接阶段与路由证据（无地址）。generation 为地址来源：0 中继、1 手动直连地址（局域网 IP、EasyTier 等虚拟网 IP、VPN、域名）、' +
    '2 局域网搜索；code 为阶段：0 未知/开始、1 本地校验未通过、2 地址无效、3 TCP 超时、4 TCP 被拒绝（对端未开启 IP 直接访问或端口不对）、' +
    '5 无路由（虚拟网未运行或本应用看不到虚拟网卡）、6 TCP 被中断、7 TCP 其它失败、8 设备密码错误、9 对端不接受密码登录、10 登录握手失败、' +
    '11 已登录但无画面、12 已取消、13 已连接；count 为地址类别：1 域名、2 私有 IPv4（含 EasyTier 默认网段）、3 100.64/10 共享地址、' +
    '4 回环、5 链路本地、6 公网 IPv4、7 IPv6 ULA（fc00::/7）、8 IPv6 链路本地、9 IPv6 回环、10 全局 IPv6、0 无效、' +
    '11 不适用（中继路由没有直连地址）。' +
    '地址类别不能证明使用了哪种虚拟网。',
  'runtime.video（RustDesk、Moonlight 的视频证据；值为 0 的字段不发送）：codec 编号 0 H.264、1 H.265、2 VP8、3 VP9、4 AV1。' +
    'decoderAttempts 为每次创建解码器的记录：capabilityHardware 1 为硬件解码；bufferTransform 为 NativeImage 缓冲区变换，' +
    'producerV1Class 为旧版 V1 矩阵的方向类；orientationCorrection 为方向自检纠正掉的方向类（-1 未纠正；在纹理空间纠正时再加 256，' +
    '如 259 为在纹理空间纠正上下颠倒，否则在画面空间纠正）；' +
    'streamDisplayOrientation 为码流里的显示方向 SEI（0 没有）。orientationSelfTests 为方向自检：把已知的四色画面' +
    '（左上红、右上绿、左下蓝、右下白）用本机真实的解码器 → NativeImage → GPU 路径解码，再读回四角颜色；' +
    'mode 0 为直接采样（手机、平板、RDP），4 为生产者矩阵模式（鸿蒙 PC 的 RustDesk）；referenceOrientation 为同一张图当作普通' +
    '纹理（RDP 和软解走的路径，各设备都显示正常）用同样方式读回的方向：1 表示读回正常，其它值表示这块缓冲区的读回本身转了，' +
    'identityOrientation 和 appliedOrientation 已按它换算成屏幕上的方向；stage 15 为完成，其它为停下的步骤' +
    '（1 EGL、2 纹理、3 NativeImage、4 NativeWindow、5 创建解码器、6 配置、7 绑定 Surface、8 启动、9 送入码流、10 等待输出、' +
    '11 等待帧、12 更新纹理、13 渲染、14 读回），platformCode 为该步骤的返回值；identityOrientation 为不加变换采样时的方向，' +
    'appliedOrientation 为会话实际所用变换下的方向；方向类：1 正常、2 左右镜像、3 上下颠倒、4 旋转 180°、5 旋转 90°、' +
    '6 旋转 270°、7 转置、8 反转置、9 其它、10 读回失败。mode 4 的 appliedOrientation 为 2–8 时，PC 从下一帧起自动纠正，' +
    '并在 decoderAttempts.orientationCorrection 记下；glRenderer、decoderName 为 GPU 和解码器名称。' +
    'observedOrientation 和 rustdesk_orientation_observation 的 code 为用户的日志标记：1 画面正常、2 上下倒置、3 左右镜像；' +
    'controlFlipX/Y、requestedVisualFlipX/Y 为用户在「画面翻转」里手动打开的翻转（1 开）。判断：自检 appliedOrientation 为 1 ' +
    '而用户仍标记倒置，问题在自检覆盖的路径之外（码流方向或手动翻转）；已自动纠正而用户又手动翻转时两者叠加，' +
    '先在「画面翻转」里点「复位」。',
  'rustdesk_preflight 的本地校验失败 code：-20 中继绑定无效、-21 认证绑定已变化、-22 密码仍在加密仓库、-23 未填写设备密码、' +
    '-24 直连选择了请求批准、-25 密码锁定时切换请求批准、-26 连接入口配置校验失败（直连地址/端口无效、链路本地 IPv6、中继缺失等，' +
    '面板尚未打开）、-27 鉴权流程不可用；这些失败的 generation 为 0，表示没有发起原生连接。'
];

export function diagnosticAiEventGlossary(): string {
  return GLOSSARY.join('\n');
}
