# RDP 模块修复与升级计划

更新时间: 2026-06-17  
接手对象: Claude / Codex  
范围: RDP 用户输入、ArkTS -> NAPI 配置、`FreeRdpAdapter`、FreeRDP/WinPR 构建链接、渲染/输入/音频/剪贴板闭环。

## 结论

当前 RDP 模块还不能视为真实可用的 Windows RDP 客户端。仓库已经包含 FreeRDP 子模块，且 `freerdp_adapter.cpp` 中有 `USE_REAL_FREERDP` 条件编译路径，但默认构建仍走手写 RDP skeleton。这个 skeleton 只能尝试 TCP、X.224、RDP Negotiation、简化 MCS PDU，不能完成真实 NLA/CredSSP、证书校验、GCC/MCS channel join、Share Control、GFX、输入、剪贴板和音频。

本轮已做最小输入链路修正:

1. `RemoteDesktop.ets` 使用 `RemoteHost.displayConfig` 传递 RDP 宽高、色深、多屏配置，不再固定 1920x1080/32bpp。
2. `RemoteDesktop.ets` 支持用户在用户名输入 `DOMAIN\user`，连接前拆成 `domain=DOMAIN`、`username=user` 传给 NAPI/FreeRDP。
3. `HostListPage.ets` 端口输入为空或非法时按当前协议默认端口回退，RDP 不再误回退到 SSH 的 22。
4. `HostListPage.ets` RDP 用户名占位提示改为 `user 或 DOMAIN\user`。

## 当前链路审计

### 用户输入

当前表单可输入:

- 名称
- 协议
- 地址
- 端口
- 用户名
- 密码
- RDP 客户端主机名 `customHostname`

当前模型已有但表单未完整暴露:

- `displayConfig`: width/height/multiMonitor/monitorCount/dynamicResolution/colorDepth
- `gatewayHost/gatewayPort`

当前模型缺少:

- 独立 RDP `domain` 字段
- RDP gateway 用户名/密码/域
- 证书信任策略和证书指纹缓存
- NLA/CredSSP 开关、TLS/RDP security fallback 策略
- 驱动器/打印机/音频/剪贴板重定向开关

结论: 直连普通 Windows RDP 的最低输入足够；域账号可临时通过 `DOMAIN\user` 输入。企业网关、证书固定、独立域字段、多显示器 UI 和重定向设置仍不足，需要后续补齐。

### ArkTS -> NAPI

`SessionConfig` 已包含:

- `host/port/username/password/domain`
- `width/height/customHostname/gatewayHost/gatewayPort`
- `multiMonitor/monitorCount/colorDepth`
- `codec`

`extension_loader_napi.cpp` 已解析以上字段并填入 `ConnectionConfig`。

本轮修正后 `RemoteDesktop.ets` 已真正传递 `domain/displayConfig/multiMonitor/colorDepth`。剩余问题是 UI 没有提供独立 domain/gateway/display 高级配置入口。

### native RDP 适配器

`freerdp_adapter.cpp` 有两条路径:

- `USE_REAL_FREERDP`: 调用 `freerdp_new()`、设置 settings、`freerdp_connect()`、事件循环、基础输入。
- 默认路径: 手写 skeleton。

默认构建问题:

- `entry/src/main/cpp/CMakeLists.txt` 没有导入 `libfreerdp3.a/libwinpr3.a`。
- 没有定义 `USE_REAL_FREERDP`。
- `scripts/build_freerdp_ohos.sh` 已存在，但产物未接入主工程。
- skeleton 只支持 IP 直连，`inet_pton()` 不支持域名。
- skeleton 不会使用 username/password/domain/display/gateway 等关键字段。
- skeleton 的 `sendKey/sendMouse/sendText` 只打日志，不会发真实 RDP 输入。

### FreeRDP 子模块

`git submodule status`:

```text
0f2b091c960a2bb5aaa8aec01cd6726ea37d9d9f freerdp (3.26.0-257-g0f2b091c9)
```

FreeRDP 源码已在仓库内，下一步重点不是“添加源码”，而是让交叉编译产物进入 `rdpnapi` 构建。

## 修复升级路线

### RDP-0: 输入和配置基线

目标: 保证用户填的数据可以完整进入 `ConnectionConfig`。

已完成:

- `DOMAIN\user` 拆分到 `domain/username`。
- `displayConfig` 进入连接宽高、色深、多屏配置。
- RDP 端口非法回退到 3389。

待完成:

1. `RemoteHost` 新增独立 `rdpDomain` 字段，并做 CloudStore 迁移。
2. RDP 表单增加“域/工作组”输入，优先级高于 `DOMAIN\user` 自动拆分。
3. RDP 表单增加“显示”折叠区:
   - 自动/1920x1080/2560x1440/3840x2160/自定义
   - 色深 16/24/32
   - 动态分辨率
   - 多显示器和显示器数量
4. RDP 表单增加“高级”折叠区:
   - 客户端主机名
   - Gateway host/port
   - Gateway credentials
   - 证书策略: 首次询问/始终信任/拒绝不匹配

验收:

- hilog 中 `ExtLoader` 打印的 host/port/width/height/domain/gateway 与 UI 输入一致。
- 保存、编辑、云同步后字段不丢失。

### RDP-1: FreeRDP/WinPR 交叉编译产物接入

目标: 让主工程可以选择真实 FreeRDP 路径构建。

任务:

1. 修正并验证 `scripts/build_freerdp_ohos.sh`:
   - arm64-v8a
   - x86_64
   - `WITH_CLIENT=ON`
   - `WITH_SERVER=OFF`
   - `WITH_X11/WAYLAND/FFMPEG/GSTREAMER/CUPS/PCSC/PULSE/ALSA=OFF`
2. 明确产物目录:
   - `build/freerdp-ohos/libs/arm64-v8a/libfreerdp3.a`
   - `build/freerdp-ohos/libs/arm64-v8a/libwinpr3.a`
   - `build/freerdp-ohos/libs/x86_64/libfreerdp3.a`
   - `build/freerdp-ohos/libs/x86_64/libwinpr3.a`
3. `CMakeLists.txt` 新增开关:
   - `-DUSE_REAL_FREERDP=ON`
   - imported `freerdp3/winpr3`
   - include `freerdp/include`、生成的 config include
4. 处理 FreeRDP 额外静态依赖:
   - OpenSSL/crypto
   - zlib 或 FreeRDP 构建实际要求的压缩/crypto 依赖
   - pthread/系统库按 OHOS toolchain 结果补齐

验收:

- `assembleHap` 在 `USE_REAL_FREERDP=ON` 下编译通过。
- `listProtocols()` 的 RDP version 返回 FreeRDP 真实版本，而不是 `3.7.0-skeleton`。

### RDP-2: 替换真实连接路径

目标: 用 FreeRDP 完成 Windows RDP 认证和会话建立。

任务:

1. `FreeRdpAdapter::connect()` 初始化:
   - `freerdp_new()`
   - `freerdp_context_new()`
   - settings 写入 host/port/username/password/domain
   - desktop width/height/colorDepth
   - customHostname
   - Gateway 配置
2. 安全设置:
   - NLA/CredSSP 默认开启
   - TLS 开启
   - RDP security fallback 仅调试可选
3. 证书策略:
   - 首次连接返回 certificate fingerprint 到 ArkTS
   - 用户确认后缓存 fingerprint
   - host mismatch 明确展示
4. 错误码映射:
   - DNS/Socket
   - TLS
   - CredSSP/NLA
   - 用户名/密码错误
   - 证书拒绝
   - 授权/并发限制
5. 事件循环:
   - `freerdp_get_event_handles()`
   - `freerdp_check_event_handles()`
   - 线程退出和 disconnect 清理

验收:

- 能连接 Windows 10/11 开启远程桌面的主机。
- 错误密码能给出明确错误，不崩溃。
- 返回上一页后可再次连接。

### RDP-3: 画面链路

目标: RDP 首帧上屏，并形成稳定刷新。

任务:

1. 先用 FreeRDP GDI path:
   - BeginPaint/EndPaint 获取 invalid region
   - 从 primary buffer 生成 BGRA/RGBA frame
   - 先允许一次 CPU copy，验证闭环
2. 接入 renderer:
   - 新增 raw BGRA 上传路径，避免强行走 H.264 decoder
   - 或新增 `VideoFrame.codec = RAW_BGRA`
3. 第二阶段接 RDPEGFX/H.264:
   - 开启 GFX pipeline
   - 识别 H.264/AVC444
   - 接 OH_AVCodec/NativeImage 零拷贝路线
4. resize:
   - ArkTS 窗口尺寸变化 -> NAPI resize -> FreeRDP display update
   - renderer viewport 同步

验收:

- 首帧可见。
- 鼠标移动/窗口拖动有增量刷新。
- resize 后比例正确。

### RDP-4: 输入链路

目标: 键盘、鼠标、滚轮可用。

任务:

1. ArkTS 事件:
   - XComponent touch/mouse/key 已进入 ExtensionLoader，继续校准坐标。
2. native 映射:
   - ArkUI keyCode -> Windows scancode
   - modifiers: Ctrl/Alt/Shift/Meta
   - IME 文本输入走 Unicode event
3. Mouse:
   - move/click/double click
   - wheel/trackpad
   - 坐标按 remote desktop resolution 缩放
4. 特殊快捷键:
   - Ctrl+Alt+Del 使用 toolbar command，不直接拦截系统组合键。

验收:

- 远端记事本可输入英文、数字、符号。
- 鼠标点击、拖拽、滚轮可用。
- 坐标不偏移。

### RDP-5: 剪贴板、音频、网关

目标: 完整 RDP 客户端体验。

任务:

1. cliprdr:
   - 文本双向同步
   - 本地 pasteboard 权限处理
   - 防循环同步
2. rdpsnd:
   - PCM 输出到 `AudioPlayer`
   - 采样率/声道转换
3. audin:
   - 后置，麦克风权限确认后再启用
4. Gateway:
   - RD Gateway host/port
   - Gateway credentials
   - HTTP/TLS 代理错误展示
5. 重定向:
   - Drive redirection 后置
   - Printer/smartcard 默认关闭

验收:

- 文本剪贴板双向可用。
- 远端音频播放。
- RD Gateway 测试环境可连接。

### RDP-6: 稳定性与性能

目标: 达到 Phase 7 测试和发布前稳定度。

任务:

1. 状态机:
   - DISCONNECTED/CONNECTING/CONNECTED/RECONNECTING/ERROR
   - connect timeout
   - network drop
2. 资源清理:
   - FreeRDP context/settings/input/channels
   - event thread
   - renderer/decoder/audio
3. 性能:
   - 帧率统计
   - 首帧时间
   - copy 次数
   - CPU 占用
4. 自动化:
   - native adapter unit test
   - ArkTS UI smoke
   - 真机 Windows RDP checklist

验收:

- 连续连接/断开 20 次无崩溃。
- 弱网断开能回到错误状态。
- RDP 首帧目标 < 500ms。
- CPU 目标 < 15%。

## 立即交给 Claude 的注意事项

1. 上一轮 XComponent SurfaceId 修复尚未经过用户真机复测。请先向用户索要新的 hilog:

```powershell
hdc -t 192.168.31.222:38451 shell "hilog -T GL_RENDERER,RUSTDESK_BRIDGE,EXT_LOADER,RDP_ADAPTER"
```

2. 预期日志:
   - `跳过 Native 回调注册`
   - `setXComponentSurfaceId: surfaceId=... win=...`
   - `InitEGL: g_surfaceReady=1`
   - 不再有 `OnSurfaceCreated signal 7`
3. 在确认渲染 surface 稳定前，不要直接推进大量 FreeRDP 画面链路改造。
4. RDP 真实连接的第一阶段应先追求可登录和可断开，首帧可以先走 GDI raw frame，再优化到 GFX/H.264 零拷贝。

## 风险清单

| 风险 | 影响 | 处理 |
| --- | --- | --- |
| 默认仍走 skeleton | 用户以为是 FreeRDP, 实际无法真实登录 | CMake 开关接入真实库并在日志/version 明确 |
| FreeRDP 静态依赖不完整 | 链接失败或运行时崩溃 | 先固定最小功能集, 逐项打开 channel |
| 证书直接信任 | 安全风险 | 引入用户确认和 fingerprint 缓存 |
| display resize 与 renderer 不同步 | 花屏/拉伸/输入偏移 | 建立统一 desktop size source |
| 输入坐标未缩放 | 鼠标不可用 | native 统一做 local->remote 坐标映射 |
| 直接上 GFX/H.264 难度过高 | 首帧迟迟不可见 | 先 GDI raw frame 闭环, 再优化 |
