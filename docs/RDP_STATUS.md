# RDP Status — FreeRDP 真实链路核验

> 建立时间: 2026-06-25 by Claude (T-235)
> 基于 commit `40a7ef8`

## 当前 RDP 架构

```
ArkTS UI (RemoteDesktop.ets ~3345行)
  │
  ├── ExtensionLoader.ets (单例门面)
  │     └── librdpnapi.so → extension_loader_napi.cpp
  │           ├── USE_REAL_FREERDP=ON  → freerdp_adapter.cpp (真实 FreeRDP 3.x)
  │           └── USE_REAL_FREERDP=OFF → freerdp_adapter.cpp (手写 TCP/X.224/MCS skeleton)
  │
  └── 共享渲染管线
        ├── gl_renderer.cpp     (EGL/GLES3 → XComponent Surface)
        ├── hw_decoder.cpp      (OH_AVCodec 硬解)
        └── audio_player.cpp    (OHAudio 播放)
```

## 核心文件

| 文件 | 行数 | 状态 |
|------|------|------|
| `entry/src/main/cpp/rdp/freerdp_adapter.cpp` | ~1500 | ✅ 双路径 (USE_REAL_FREERDP) |
| `entry/src/main/cpp/rdp/freerdp_adapter.h` | ~150 | ✅ |
| `entry/src/main/cpp/rdp/rdp_keymap.h` | ~200 | ✅ 80+ Harmony→RDP scancode 映射 |
| `entry/src/main/cpp/extensions/extension_loader_napi.cpp` | ~1650 | ✅ 协议调度 |
| `entry/src/main/ets/services/ExtensionLoader.ets` | ~200 | ✅ NAPI 门面 |
| `entry/src/main/ets/pages/RemoteDesktop.ets` | ~3345 | ✅ (待拆分) |

## 当前默认构建

- **`USE_REAL_FREERDP=OFF`** (默认)
- 默认 HAP 使用手写 RDP skeleton (TCP/X.224/MCS 握手层面)
- 手写 skeleton 不支持完整 RDP 会话 (NLA / GFX / 剪贴板 / 音频 / 驱动重定向)
- 这是为了保持双 ABI 默认包稳定，不增大 HAP 体积 (~8MB FreeRDP 静态库)

## 开启真实 FreeRDP

```powershell
# 1. 编译 FreeRDP (如果产物不存在)
bash scripts/build_freerdp_ohos.sh arm64

# 2. 构建时启用
# 方法 A: 修改 entry/build-profile.json5 → USE_REAL_FREERDP=ON
# 方法 B: hvigor 参数 (如果支持 CMake option 传递)
```

**前置条件**:
- `build/freerdp-ohos/libs/arm64-v8a/libfreerdp3.a` (~5.5MB)
- `build/freerdp-ohos/libs/arm64-v8a/libwinpr3.a` (~2.7MB)
- 当前本机: **build 产物不存在** (需要重建)

## 稳定规则 (来自 CODEWALK.md)

1. **RDP session size ≠ local surface size** — 远端桌面分辨率与 XComponent surface 尺寸分开设置
2. **No ArkTS TCP preflight** — 保持 FreeRDP native 作为唯一连接判定路径
3. **Cleanup must call `markXComponentSurfaceDestroyed()` before renderer destroy** — 防止 GPU vendor double free
4. **Drive/Clipboard must not block readiness** — 可选能力失败不阻断连接完成
5. **RDP connect thread is async** — `freerdp_connect()` 在独立 pthread 执行；取消时只能 `freerdp_abort_connect_context()` + join

## 当前已闭环功能 (真机验证)

| 功能 | 状态 | 备注 |
|------|------|------|
| RDP 连接 | ✅ | FreeRDP 3.x 完整 NLA/TLS 握手 |
| GDI 上屏 | ✅ | BGRA32 → EGL texture → XComponent |
| 鼠标输入 | ✅ | 绝对/相对坐标 + 滚轮 |
| 键盘输入 | ✅ | Harmony keyCode → RDP scancode (80+ 映射) |
| 文本输入 | ✅ | Unicode 输入 (含中文) |
| 音频播放 | ✅ | OHAudio renderer → PCM |
| 文件传输 | ✅ | rdpdr → `\\tsclient\<drive>` + 实况窗进度 |
| 剪贴板 | ✅ | ClipboardBridgeService (arkTS pasteboard → native sendClipboard) |
| 自适应渲染节流 | ✅ | 根据 GPU render cost 自动 60/30/20fps (video_backpressure_controller) |

## 后台连续性影响分析 (T-251~T-255)

**当前阻塞点**:
1. `RemoteDesktop.aboutToDisappear()` → `cleanup()` → `loader.disconnect()` → 无条件断连协议
2. `EntryAbility.onBackground()` → `disconnectRemoteSessions('background')` → `disconnectAll()` → 销毁所有会话+音频
3. `extension_loader_napi.cpp` `NapiDisconnect()` 同时调用 `adapter->disconnect()` + `AudioPlayerNapi::DestroyActiveNative()`

**需要的变更** (由后续任务实施):
- 拆分 `cleanup()` 为 `detachForBackground()` (仅释放 UI/Surface) 和 `disconnectAndCleanup()` (完全释放)
- `onBackground()` 区分 preserved session vs final destroy
- Native 层支持: renderer detach 不销毁协议连接和音频
- 新增 `multiDeviceConnection` 后台长时任务

**注意**: 当前架构在协议连接存活期间释放 renderer 是安全的 — `gl_renderer.cpp` 已有 `g_surfaceDetached` 守卫和 `MarkXComponentSurfaceDestroyed()` 。
