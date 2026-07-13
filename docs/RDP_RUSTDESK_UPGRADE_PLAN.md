# RDP / RustDesk 模块升级计划

更新时间: 2026-06-16  
接手对象: Claude  
范围: `RemoteDesktop` 的 RDP、RustDesk、共享渲染、输入、音频、剪贴板、构建链路。

## 结论先行

当前 RDP/RustDesk 已有 UI 入口、`ProtocolAdapter` 接口、NAPI 连接入口、GL/Decoder/Audio/Input/Clipboard 子系统骨架，但还没有形成可用的远程桌面闭环。

关键断点:

1. RDP 当前不是 FreeRDP 客户端，而是手写 TCP/X.224/RDP Negotiation/MCS 简化 PDU。它不能完成真实 NLA、证书、GCC/MCS Channel Join、Share Control、GFX、输入、剪贴板和音频链路。
2. RustDesk 当前有两个未闭合方向: `rustdesk_ffi` 是 mock 静态库，`rustdesk_bridge.cpp` 又没有调用它，而是手写一个疑似协议握手；其中密码会明文发出，不能继续作为正式方向。
3. 渲染管线还停在 Pbuffer 离屏 + Mock Decoder。即使协议产生帧，也不会可靠上屏。
4. ArkTS `RemoteDesktop.ets` 创建 `XComponent`，但没有将键盘、鼠标、触控事件转给 native，也没有将协议帧回调接到解码器和渲染器。
5. CMake 未链接 FreeRDP/WinPR；RustDesk 静态库存在，但内容仍是 mock/terminal_core，不是 RustDesk core。

## 当前代码证据

### RDP

- `docs/TECH_SPEC.md` 目标方案明确要求 FreeRDP 3.x，`FreeRdpAdapter` 应持有 `freerdp*` 并调用 `freerdp_connect()`。
- `entry/src/main/cpp/rdp/freerdp_adapter.cpp` 当前只包含 socket、X.224、RDP negotiation、MCS 简化函数，没有 include/link FreeRDP/WinPR。
- `sendKey/sendMouse/sendText` 只打日志，不向 RDP 会话发事件。
- `setVideoCallback/setAudioCallback` 只保存回调，连接流程不会触发它们。
- CMake 只链接 SSH 所需的 OpenSSL/libssh2 和 Rust mock 静态库，没有 FreeRDP/WinPR imported library。

### RustDesk

- `docs/TECH_SPEC.md` 要求 RustDesk 通过 `rustdesk_ffi/src/lib.rs` 暴露 `rustdesk_connect`、frame/audio/disconnect callback。
- `rustdesk_ffi/src/lib.rs` 当前 `rustdesk_connect()` 只返回一个 boxed host 字符串，输入函数都是 TODO。
- `entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp` 当前不调用 `rustdesk_ffi`，而是手写 TCP 连接、版本交换、ID 注册、密码认证。
- `rdAuthPassword()` 注释明确写着密码以明文 TCP 发送。这条路径必须停止推进，除非只是实验用并从正式连接入口移除。

### 共享链路

- `RemoteDesktop.ets` 只做 `initRenderer()`、`initDecoder()`、`connect()`，连接成功后显示 `XComponent`。
- `ExtensionLoader.ets` 未包装 `decodeFrame/renderFrame/resizeRenderer/getTextureId/handleKeyEvent/handleMouseEvent`，`rdpnapi.d.ts` 也未声明这些 NAPI。
- `gl_renderer.cpp` 当前 EGL surface 是 Pbuffer，注释已说明不会上屏。
- `hw_decoder.cpp` 当前是 Mock，固定返回 textureId=42。
- `input_handler.cpp` 有 NAPI 和 active adapter 概念，但 `ExtensionLoaderNapi::NapiConnect()` 没把新 session adapter 设置为 active；ArkTS 也未调用输入 NAPI。
- `clipboard_bridge.cpp` 是 Mock，未用系统 pasteboard API。

## 升级原则

1. RDP 不再手写协议，改为真实 FreeRDP/WinPR 客户端 API。
2. RustDesk 不再手写私有协议。先确定合规边界，再接真实 RustDesk core 或独立进程 IPC。
3. 先打通 `协议帧 -> decoder -> GL/XComponent` 共享链路，再做高级功能。
4. 所有协议只通过 `ProtocolAdapter` 暴露统一能力，不让 ArkTS 直接感知 FreeRDP/RustDesk 内部细节。
5. 每个阶段都要有可验证输出: 日志、首帧、输入回显、断线重连、资源释放。

## 推荐阶段路线

### R0: 基线保护与 API 补齐

目标: 让 Claude 先把现有骨架变成可测试的通路，不改协议细节。

任务:

1. 补齐 `rdpnapi.d.ts`:
   - `decodeFrame(handle, data, size, timestamp)`
   - `getTextureId(handle)`
   - `renderFrame(handle, textureId)`
   - `resizeRenderer(handle, width, height)`
   - `handleKeyEvent(...)`
   - `handleMouseEvent(...)`
   - `handleTouchEvent(...)`
2. 补齐 `ExtensionLoader.ets` 对上述 NAPI 的包装。
3. `RemoteDesktop.ets`:
   - 保存 `sessionId/rendererHandle/decoderHandle`
   - 绑定 `XComponent` surface lifecycle
   - 绑定 touch/mouse/key 事件到 ExtensionLoader
   - 连接失败时显示 native 返回错误码与协议名
4. `ExtensionLoaderNapi::NapiConnect()`:
   - 新增 session-level state callback 导出或至少保留 session error message
   - 调用 `InputHandler::instance().setActiveAdapter(adapter)`
   - 为 `ProtocolAdapter::setVideoCallback` 和 `setAudioCallback` 预留 decoder/audio 派发位置

验收:

- `listProtocols()` 返回 rdp/rustdesk/ssh/vnc。
- RemoteDesktop 页面可创建 renderer/decoder/session 并释放。
- 输入事件能从 ArkTS 到达当前 adapter 日志。
- 构建通过。

### R1: XComponent 真实上屏

目标: 先让 native renderer 能画到屏幕，而不是 Pbuffer。

任务:

1. 在 C++ NAPI 注册 `OH_NativeXComponent` 回调:
   - `OnSurfaceCreated`
   - `OnSurfaceChanged`
   - `OnSurfaceDestroyed`
2. `GLRenderer::InitEGL()`:
   - 用 `OH_NativeXComponent_GetNativeWindow` 获取 native window
   - 用 `eglCreateWindowSurface()` 替换 `eglCreatePbufferSurface()`
   - surface changed 时 `Resize()`
3. 加一个临时测试渲染:
   - 不依赖 RDP/RustDesk，直接渲染彩色测试纹理或清屏颜色
   - 用于证明 XComponent 真正上屏

验收:

- 连接页显示可见测试画面，不再只是黑屏。
- rotate/resize 后 viewport 正确。
- 离开页面不泄漏 EGL surface/context。

### R2: Decoder 真实现

目标: 让编码帧可以进 OH_AVCodec，输出 NativeImage/纹理给 GL。

任务:

1. `HardwareDecoder`:
   - `OH_VideoDecoder_CreateByMime`
   - `OH_AVFormat` 配置 width/height/mime
   - input buffer queue / callback
   - output surface 绑定 NativeImage 或 NativeWindow
2. 先支持 H.264:
   - RDP 和 RustDesk 都可优先落到 H.264
   - VP8/VP9 暂时标记 unsupported 或软件解码另立任务
3. `DecoderFrameCallback` 接到 `RendererNapi::renderFrame()` 或 native 内部 renderer 句柄。
4. 编写一个本地 H.264 小帧/测试流验证解码器，不依赖网络协议。

验收:

- H.264 测试流能解码并上屏。
- `destroyDecoder()` 无崩溃，无残留 callback。
- H.265 先保持 capability gate，不虚报。

### R3: RDP 真实 FreeRDP 接入

目标: 用 FreeRDP 替换手写 RDP。

任务:

1. 初始化/拉取 FreeRDP 源码:
   - 当前仓库未发现 `freerdp/` 子模块和 `.gitmodules`
   - 需要先添加 submodule 或 vendor 源码，并记录具体 commit
2. 交叉编译 FreeRDP/WinPR:
   - arm64-v8a + x86_64
   - `WITH_CLIENT=ON`
   - `WITH_SERVER=OFF`
   - 优先静态库
   - 禁用当前不需要的 X11/Wayland/FFmpeg/Server 依赖
3. CMake 接入:
   - `libfreerdp3.a`
   - `libwinpr3.a`
   - 必要的 crypto/ssl/zlib/uwac 依赖
4. 重写 `FreeRdpAdapter`:
   - `freerdp_new/free/freerdp_connect/freerdp_disconnect`
   - settings: ServerHostname, ServerPort, Username, Password, Domain, DesktopWidth, DesktopHeight, ColorDepth
   - NLA/CredSSP/证书策略
   - BeginPaint/EndPaint 或 GFX callback 转 `VideoFrame`
   - 输入: keyboard scancode, pointer event, wheel
   - 剪贴板: cliprdr channel
   - 音频: rdpsnd/audin 分阶段
5. 建立 reader/event loop 线程:
   - `freerdp_get_event_handles`
   - WaitForMultipleObjects 等价实现
   - 断线/重连状态上报

验收:

- Windows 远程桌面服务能完成 NLA 登录。
- 首帧上屏。
- 鼠标移动/点击、键盘输入可用。
- 断开连接后线程退出，页面可二次连接。

### R4: RustDesk 合规与真实连接

目标: 明确许可证/进程模型，然后接真实 RustDesk core。

必须先决策:

1. 如果主应用闭源或计划 AppGallery 商业发布，避免直接静态链接 AGPL RustDesk core。
2. 推荐方案: 独立 RustDesk helper 进程 + Unix Domain Socket IPC。
3. 备选方案: 全项目按 AGPL 合规开源并静态链接 core。

推荐实现:

1. 新建 `rustdesk_helper/` 或改造 `rustdesk_ffi/` 为独立 executable/service。
2. IPC 协议:
   - connect/disconnect
   - input events
   - clipboard
   - frame/audio stream
   - state/error events
3. C++ `RustDeskBridge` 不再手写 RustDesk 私有协议:
   - 只负责启动 helper、连接 socket、转发 IPC
   - 将 frame/audio IPC 转为 `VideoFrameCallback/AudioDataCallback`
4. 安全:
   - 删除或隔离当前明文密码 TCP path
   - 密码只进入 RustDesk 官方认证链
   - 日志禁止输出密码、密钥、token
5. NAT/中继:
   - 自建 ID server/relay 参数进入 `ConnectionConfig`
   - UI 需要增加 RustDesk ID/中继服务器字段，不能复用普通 host:port 语义

验收:

- 能连接 RustDesk 测试服务端/客户端。
- NAT/relay 状态能在日志和 UI 展示。
- 密码不出现在网络明文自定义 PDU 或 hilog。
- helper 崩溃时主进程能回收并显示错误。

### R5: 音频、剪贴板、文件传输

目标: 从“画面可用”升级为完整远程桌面体验。

任务:

1. 音频:
   - RDP rdpsnd -> `AudioDataCallback` -> `AudioPlayer`
   - RustDesk audio -> IPC/FFI -> `AudioPlayer`
2. 剪贴板:
   - ArkTS pasteboard permission + native bridge
   - RDP cliprdr / RustDesk clipboard event
   - 文本先行，文件列表后置
3. 文件传输:
   - RustDesk 官方文件传输优先
   - RDP drive redirection 后置

验收:

- 文本剪贴板双向同步。
- 远端音频播放。
- 异常断开后音频 renderer 正常释放。

### R6: 性能与质量

目标: 逼近 TECH_SPEC 目标。

指标:

- RDP 帧延迟 < 30ms。
- RustDesk 帧延迟 < 50ms。
- 首帧 RDP < 500ms, RustDesk < 800ms。
- CPU RDP < 15%, RustDesk < 20%。

任务:

1. 帧池与零拷贝:
   - 避免 ArrayBuffer 大拷贝跨 NAPI 频繁传输
   - native 内部直接 `adapter -> decoder -> renderer`
2. 帧率自适应:
   - foreground/background
   - 网络抖动
   - resize 降采样
3. 日志分级:
   - 默认只打状态/错误
   - 帧级日志必须关闭
4. 自动化测试:
   - native unit: adapter state machine
   - ArkTS UI smoke: connect page lifecycle
   - 真机集成: Windows RDP, RustDesk relay/direct

## Claude 接手建议顺序

1. 不要先改 FreeRDP 或 RustDesk 协议细节。先做 R0/R1，把 UI/NAPI/renderer 生命周期串通。
2. 第二步做 R2，用本地测试流验证 decoder + renderer。
3. 第三步才做 RDP FreeRDP 交叉编译和 adapter 替换。
4. RustDesk 必须先完成许可证/独立进程决策；当前 `rustdesk_bridge.cpp` 明文密码路径应标记为不可用于正式连接。
5. 每完成一个小阶段都更新 `HANDOFF.md` 和 Claude project-state，并提交。

## 高风险清单

| 风险 | 影响 | 处理 |
|------|------|------|
| 继续手写 RDP | 永远无法稳定支持 NLA/GFX/剪贴板/音频 | 直接替换为 FreeRDP API |
| RustDesk AGPL 静态链接 | 发布合规风险 | 优先 helper 进程 + IPC |
| Pbuffer 离屏 | 协议成功也黑屏 | R1 先做 XComponent window surface |
| Mock decoder | 无真实帧上屏 | R2 先用测试 H.264 流验证 |
| NAPI 缺少帧回调链 | 协议/渲染并排不相连 | R0 补 wrapper 和 native frame dispatcher |
| 输入未绑定 XComponent | 看得见但不可控 | R0/R1 绑定 key/mouse/touch |
| 线程释放不严 | 返回页面/二次连接崩溃 | 每个阶段加 destroy/reconnect 验收 |

