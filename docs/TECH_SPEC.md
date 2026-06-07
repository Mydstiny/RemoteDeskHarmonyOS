# 鸿蒙 PC 双协议远程桌面客户端
## RDP (FreeRDP) + RustDesk 双协议 · 华为云同步 · 主机安全锁 · 可扩展架构
### 技术方案文档 v4.0 — 2026年6月

> **v4.0 更新：新增第十四章沉浸光感 UI 设计 + 附录 F：Claude Code 项目落地指南**

---

# 第一章 项目概述

## 1.1 项目目标

构建一款面向 HarmonyOS NEXT PC 平台的原生远程桌面客户端，核心特性：

- **双协议支持**：RDP (FreeRDP) + RustDesk，用户连接时自由切换
- **华为账号登录**：集成 HMS Account Kit，云端同步远程主机配置
- **远程主机锁**：对敏感主机设置独立密码/生物识别锁，防误操作/防未授权访问
- **可扩展架构**：插件化设计，新功能通过 Extension Point 注册即可集成
- **沉浸光感 UI**：基于 HarmonyOS 6 UIDesignKit 的玻璃拟态 + 动态光效界面

## 1.2 为什么需要双协议

| 场景 | 推荐协议 | 原因 |
|------|---------|------|
| 连接 Windows 电脑 | RDP (FreeRDP) | Windows 内置 RDP 服务端，无需额外安装 |
| 跨平台远程（Linux/macOS） | RustDesk | RustDesk 开源且原生支持多平台服务端 |
| 低带宽 / 高延迟网络 | RustDesk | 自研编码器在弱网下表现更优 |
| 企业环境（域认证） | RDP | RDP 原生支持 NLA 网络级认证和域登录 |
| 个人设备互连（无公网 IP） | RustDesk | 支持自建中继服务器，打洞穿透 NAT |

## 1.3 核心技术栈

| 层级 | 技术 | 说明 |
|------|------|------|
| UI 框架 | ArkUI (声明式) + ArkTS + UIDesignKit | 鸿蒙原生 UI，沉浸光感 |
| 账号服务 | HMS Account Kit + Cloud DB | 华为账号登录与云同步 |
| 安全认证 | Biometric Authentication Kit + HUKS | 指纹/人脸识别 + 密钥管理 |
| RDP 后端 | FreeRDP 3.x (Apache 2.0) | 纯 C，最成熟的开源 RDP |
| RustDesk 后端 | RustDesk core FFI (AGPL) | Rust 编译为 C 兼容库 |
| 渲染引擎 | OpenGL ES 3.0 + EGL | GPU 加速，零拷贝 |
| 视频解码 | OH_AVCodec 硬件解码 | H.264/H.265 硬解 |
| 音频引擎 | OHAudio (AAudio 兼容) | 低延迟播放和录制 |
| 构建工具 | DevEco Studio 5.0+ / CMake | 鸿蒙官方 IDE |
| 插件系统 | Extension Registry (自研) | 服务注册/发现/生命周期 |

---

# 第二章 可扩展架构设计

## 2.1 设计目标

本项目的核心架构原则是"面向扩展开放，面向修改封闭"。未来添加新功能（如新协议适配器、新认证方式、新 UI 组件）时，不应修改核心框架代码。

- **协议可插拔**：添加新远程协议（如 VNC、SPICE）只需实现 ProtocolAdapter 接口
- **认证可替换**：支持华为账号、企业 SSO、本地密码等多种认证方式
- **UI 可组合**：工具栏、状态栏、设置面板通过 Extension Point 动态加载
- **存储可切换**：本地加密存储 ↔ 云端同步，通过 DataProvider 接口抽象

## 2.2 核心架构：Extension Point 模式

```
┌──────────────────────────────────────────────────────────────┐
│                    Extension Registry                          │
│  ┌─────────────┬──────────────┬──────────────┬──────────────┐ │
│  │ ProtocolRegistry│ AuthRegistry │ ToolbarRegistry│ DataProviderReg││
│  │  "protocol"      │ "auth"       │ "toolbar.action"│ "storage"     ││
│  └───────┬──────────┴──────┬───────┴──────┬───────┴──────┬───────┘ │
│          │                 │              │              │         │
│  ┌───────▼────┐   ┌───────▼────┐  ┌──────▼────┐  ┌────▼──────┐   │
│  │ FreeRDP    │   │ HuaweiAuth │  │ LockButton │  │ CloudDB   │   │
│  │ RustDesk   │   │ LocalAuth  │  │ Screenshot │  │ LocalEncrypt│  │
│  │ VNC (ext)  │   │ SSO (ext)  │  │ FileSend   │  │ (extensible)│  │
│  └────────────┘   └────────────┘  └────────────┘  └───────────┘   │
└──────────────────────────────────────────────────────────────┘
```

## 2.3 Extension Point 接口规范

```cpp
// extensions/extension_registry.h — 扩展注册中心
template<typename T>
class ExtensionRegistry {
    std::map<std::string, std::shared_ptr<T>> extensions_;
public:
    void register(const std::string& point, const std::string& name,
                  std::shared_ptr<T> ext) {
        extensions_[point + "." + name] = ext;
    }
    std::vector<std::shared_ptr<T>> get(const std::string& point) {
        std::vector<std::shared_ptr<T>> result;
        for (auto& [key, ext] : extensions_) {
            if (key.starts_with(point)) result.push_back(ext);
        }
        return result;
    }
};

class ExtensionSystem {
public:
    ExtensionRegistry<ProtocolAdapter>   protocols;
    ExtensionRegistry<AuthProvider>      auth;
    ExtensionRegistry<ToolbarExtension>  toolbar;
    ExtensionRegistry<DataProvider>      storage;
    static ExtensionSystem& instance() {
        static ExtensionSystem sys;
        return sys;
    }
};
```

---

# 第三章 双协议架构（基于扩展系统）

## 3.1 ProtocolAdapter 接口

```cpp
class ProtocolAdapter {
public:
    virtual std::string protocol_name() = 0;   // "RDP", "RustDesk"
    virtual int default_port() = 0;            // 3389 / 21116
    virtual int connect(const ConnectionConfig& cfg,
                        ConnectionCallbacks* cb) = 0;
    virtual void disconnect() = 0;
    virtual void send_key(uint32_t scancode, bool pressed) = 0;
    virtual void send_mouse(int x, int y, int button, bool pressed) = 0;
    virtual void send_text(const std::string& text) = 0;
    virtual bool supports_codec(CodecType codec) = 0;
    virtual void set_video_callback(VideoFrameCallback cb) = 0;
    virtual void set_audio_callback(AudioDataCallback cb) = 0;
};
```

## 3.2 协议对比

| 特性 | FreeRDP (RDP) | RustDesk | 未来可扩展 |
|------|--------------|----------|-----------|
| 默认端口 | 3389 | 21116 | 自定义 |
| 视频编码 | GFX H.264/H.265 | VP8/VP9/H.264/H.265 | 协议声明 |
| 认证 | NLA (CredSSP) | 密钥对+密码 | AuthProvider |
| NAT 穿透 | 不支持 | 内置 UDP 打洞 | 自行实现 |

---

# 第四章 开发环境搭建

## 4.1 系统要求

| 操作系统 | 最低版本 | 推荐配置 |
|---------|---------|---------|
| Windows | Windows 10 64位 | 16GB 内存, 500GB SSD |
| macOS | macOS 12 (Monterey) | 16GB 内存, Apple Silicon |

## 4.2 安装 DevEco Studio

1. 访问 https://developer.huawei.com/consumer/cn/download/
2. 下载 DevEco Studio 5.0.x 最新版
3. SDK Manager 中安装 HarmonyOS SDK (API 12+)
4. 确保 HMS Core 相关 SDK 也已安装（Account Kit, Cloud DB 等）

## 4.3 注册华为开发者账号

1. 访问 https://developer.huawei.com/consumer/cn/ 注册并实名认证
2. 在 AppGallery Connect 创建项目和应用
3. 开通 Account Kit、Cloud DB、Biometric Authentication Kit
4. 记录 App ID、Client ID、Client Secret

## 4.4 项目目录结构

```
RemoteDeskHarmonyOS/
├── AppScope/app.json5
├── entry/src/main/
│   ├── module.json5
│   ├── ets/
│   │   ├── entryability/
│   │   ├── pages/
│   │   │   ├── LoginPage.ets            # 华为账号登录（光感UI）
│   │   │   ├── HostListPage.ets         # 主机列表（沉浸式卡片）
│   │   │   ├── ConnectionForm.ets       # 连接表单
│   │   │   ├── RemoteDesktop.ets        # 远程桌面主视图
│   │   │   └── Settings.ets             # 设置页
│   │   ├── components/
│   │   │   ├── GlassmorphicCard.ets     # ✨ 玻璃拟态通用卡片
│   │   │   ├── FloatNavigation.ets     # ✨ 悬浮导航栏（光感）
│   │   │   ├── ImmersiveBackground.ets # ✨ 沉浸光感背景层
│   │   │   ├── HostCard.ets             # 主机卡片（含锁状态）
│   │   │   └── LockGate.ets             # 主机锁验证门
│   │   ├── services/
│   │   │   ├── AuthService.ts
│   │   │   ├── HostSyncService.ts
│   │   │   ├── LightSensingService.ts  # ✨ 光感传感器服务
│   │   │   └── ExtensionLoader.ts
│   │   └── napi/
│   ├── cpp/
│   │   ├── extensions/
│   │   ├── rdp/
│   │   ├── rustdesk/
│   │   ├── render/
│   │   ├── audio/
│   │   └── security/
│   └── resources/
├── plugins/                             # 外部扩展 (.hsp)
├── freerdp/                             # FreeRDP submodule
├── rustdesk_ffi/                        # RustDesk FFI
└── build-profile.json5
```

---

# 第五章 FreeRDP (RDP) 后端集成

## 5.1 交叉编译

```bash
cd freerdp && mkdir build_ohos && cd build_ohos
cmake .. \
  -DCMAKE_TOOLCHAIN_FILE=../cmake/toolchains/ohos-arm64.cmake \
  -DWITH_CLIENT=ON -DWITH_SERVER=OFF \
  -DWITH_FFMPEG=OFF -DWITH_SSE2=OFF -DWITH_NEON=ON \
  -DBUILD_SHARED_LIBS=OFF
make -j$(nproc) && make install
```

## 5.2 协议适配器注册

```cpp
class FreeRdpAdapter : public ProtocolAdapter {
    freerdp* instance_;
    std::string protocol_name() override { return "RDP"; }
    int default_port() override { return 3389; }
    int connect(const ConnectionConfig& cfg, ConnectionCallbacks* cb) override {
        instance_ = freerdp_new();
        return freerdp_connect(instance_);
    }
};

void register_free_rdp() {
    ExtensionSystem::instance().protocols.register(
        "protocol", "rdp", std::make_shared<FreeRdpAdapter>());
}
```

---

# 第六章 RustDesk 后端集成

## 6.1 FFI 接口

```rust
// rustdesk_ffi/src/lib.rs
#[no_mangle]
pub extern "C" fn rustdesk_connect(
    cfg: *const RustDeskConfig,
    on_frame: FrameCallback, on_audio: AudioCallback,
    on_disconnect: DisconnectCallback) -> *mut c_void { ... }

#[no_mangle]
pub extern "C" fn rustdesk_send_mouse(h: *mut c_void, x: i32, y: i32,
                                       btn: u32, down: bool) { ... }

#[no_mangle]
pub extern "C" fn rustdesk_send_key(h: *mut c_void, sc: u32, down: bool) { ... }
```

## 6.2 交叉编译

```bash
rustup target add aarch64-unknown-linux-ohos
cd rustdesk_ffi && cargo build --release --target aarch64-unknown-linux-ohos
```

## 6.3 许可证合规

⚠️ RustDesk 采用 AGPL-3.0。推荐独立进程通信方案（Unix Domain Socket）避免许可证传染。

---

# 第七章 共享渲染管线

## 7.1 零拷贝架构

```
RDP GFX / RustDesk VP8/H.264
        │
        ▼  OH_AVCodec 硬解 (H.264/H.265)
        │
        ▼  NativeImage (零拷贝 GL 纹理)
        │
        ▼  OpenGL ES 3.0 渲染器 (NV12→RGB Shader)
        │
        ▼  XComponent Canvas (显示)
```

## 7.2 硬件解码器

```cpp
class HardwareDecoder {
    OH_AVCodec* decoder_;
    OH_NativeImage* nativeImage_;

    void Init(int w, int h, CodecType codec) {
        const char* mime = (codec == H265) ? OH_AVCODEC_MIMETYPE_VIDEO_HEVC
                                           : OH_AVCODEC_MIMETYPE_VIDEO_AVC;
        decoder_ = OH_VideoDecoder_CreateByMime(mime);
        OH_NativeImage_Create(&nativeImage_, 0);
        OH_VideoDecoder_SetSurface(decoder_, OH_NativeImage_GetSurface(nativeImage_));
        OH_VideoDecoder_Start(decoder_);
    }

    GLuint GetTextureId() { return OH_NativeImage_GetTextureId(nativeImage_); }
};
```

---

# 第八章 共享音频管线

```cpp
class AudioPlayer : public AudioDataProvider {
    OH_AudioRenderer* renderer_;

    void Init() {
        OH_AudioStreamBuilder* builder;
        OH_AudioStreamBuilder_Create(&builder, AUDIOSTREAM_TYPE_RENDERER);
        OH_AudioStreamBuilder_SetSamplingRate(builder, 48000);
        OH_AudioStreamBuilder_SetChannelCount(builder, 2);
        OH_AudioStreamBuilder_SetLatencyMode(builder, AUDIOSTREAM_LATENCY_MODE_FAST);
        OH_AudioStreamBuilder_GenerateRenderer(builder, &renderer_);
        OH_AudioRenderer_Start(renderer_);
    }

    void OnData(uint8_t* pcm, size_t len) override {
        OH_AudioRenderer_Write(renderer_, pcm, len);
    }
};
```

---

# 第九章 统一输入处理

鸿蒙 PC 支持键盘/鼠标/触控三种输入，统一映射到 ProtocolAdapter 接口。

| 鸿蒙事件 | RDP 映射 | RustDesk 映射 |
|---------|---------|-------------|
| KeyEvent | RDP ScanCode | RustDesk KeyEvent |
| Mouse Click | RDP Mouse Event | RustDesk Mouse Event |
| Touch 单指 | 左键 | 左键 |
| Touch 双指 | 右键 | 右键 |
| Touch 捏合 | Ctrl+滚轮 | 缩放事件 |

---

# 第十章 华为账号登录与云同步

## 10.1 HMS Account Kit 集成

```typescript
// pages/LoginPage.ets
import { authentication } from '@hms.core.hwid';

private async huaweiLogin() {
    const authParams = new authentication.HuaweiIdAuthParamsHelper()
        .setProfile().setIdToken().setAuthorizationCode().createParams();
    const service = await authentication.HuaweiIdAuthManager
        .getService(getContext(), authParams);
    const result = await service.signIn();
    this.userName = result.getDisplayName();
    await this.syncHostsFromCloud(result.getUnionId());
}
```

## 10.2 Cloud DB 数据模型

```typescript
class RemoteHost {
    id: string;
    userId: string;          // 华为账号 UnionID
    label: string;           // 主机显示名
    protocol: string;        // "rdp" | "rustdesk"
    host: string;            // IP 或域名
    port: number;
    username: string;
    locked: boolean;         // 是否已加锁
    lockType: string;        // "none" | "biometric" | "pin" | "password"
    syncVersion: number;     // 冲突检测
}
```

---

# 第十一章 远程主机安全锁

## 11.1 功能概述

对列表中的指定主机设置独立密码保护。连接加锁主机时需先通过身份验证。

| 锁类型 | 安全等级 | 技术方案 |
|--------|---------|---------|
| 生物识别锁 | ★★★★★ | IAM Biometric Auth Kit |
| PIN 码锁 | ★★★★ | AES-256 本地加密 |
| 密码锁 | ★★★★★ | AES-256 + Argon2id |

## 11.2 HUKS 加密存储

```cpp
class HostLocker {
    static std::vector<uint8_t> EncryptCredential(
        const std::string& hostId, const std::string& credential) {
        // HUKS AES-256-GCM 加密，密钥存储在 TEE
        OH_Huks_Blob alias = { (uint8_t*)hostId.c_str(), hostId.size() };
        OH_Huks_GenerateKeyItem(&alias, paramSet, nullptr, nullptr);
        OH_Huks_Encrypt(&alias, paramSet, &plainText, &cipherText);
        return {cipherText.data, cipherText.data + cipherText.size};
    }
};
```

---

# 第十二章 NAPI 桥接层

```cpp
#include <napi/native_api.h>
#include "extensions/extension_registry.h"

static napi_value Init(napi_env env, napi_value exports) {
    ExtensionSystem::instance();
    ProtocolBridgeNapi::Init(env, exports);
    RendererNapi::Init(env, exports);
    AudioNapi::Init(env, exports);
    SecurityNapi::Init(env, exports);
    ExtensionLoaderNapi::Init(env, exports);
    return exports;
}
NAPI_MODULE(rdpnapi, Init)
```

---

# 第十三章 性能优化

| 指标 | RDP 目标 | RustDesk 目标 | 实现方式 |
|------|---------|-------------|---------|
| 帧延迟 | < 30ms | < 50ms | 硬解 + 零拷贝 |
| 帧率 | 30-60fps | 30fps | AdaptiveFPSController |
| 首帧 | < 500ms | < 800ms | 预连接 + 缓存 |
| CPU | < 15% | < 20% | NEON + GPU 离线 |
| 内存 | < 150MB | < 200MB | 静态链接 + 帧池 |

---

# 第十四章 🆕 沉浸光感 UI 设计

> **基于 HarmonyOS 6 UIDesignKit，对标 Apple HIG 玻璃拟态**

## 14.1 设计理念

远程桌面客户端作为生产力工具，应采用 HarmonyOS 6 全新的**沉浸光感设计语言**，创造"轻量、通透、有层次"的视觉体验。核心设计原则：

- **玻璃拟态（Glassmorphism）**：半透明毛玻璃背景，内容层叠有深度感
- **动态光效（Immersive Light）**：随壁纸/环境光自适应调整光效强度和色调
- **悬浮层级（Float Hierarchy）**：导航栏悬浮于内容之上，不占用布局空间
- **安全区延展（Safe Area Expansion）**：背景色延展至状态栏和导航栏区域

## 14.2 三层视觉架构

```
┌──────────────────────────────────────────────┐
│              第一层：沉浸光感背景层            │
│  ┌────────────────────────────────────────┐  │
│  │  动态光晕 + 主色调模糊 + 安全区延展      │  │
│  │  · backgroundColor + expandSafeArea    │  │
│  │  · 大半径 blur 创建光晕氛围              │  │
│  │  · 光感传感器动态调节强度                 │  │
│  └────────────────────────────────────────┘  │
│              第二层：玻璃拟态内容区            │
│  ┌────────────────────────────────────────┐  │
│  │  backgroundBlurStyle(REGULAR)          │  │
│  │  · 毛玻璃半透明卡片                      │  │
│  │  · 白色边框 + 柔和阴影                   │  │
│  │  · 主机列表/表单/设置面板                │  │
│  └────────────────────────────────────────┘  │
│              第三层：悬浮导航栏               │
│  ┌────────────────────────────────────────┐  │
│  │  FloatNavigation (强/平衡/弱 三档)       │  │
│  │  · 底部悬浮，不占布局空间                 │  │
│  │  · 动态透明度随滑动变化                   │  │
│  │  · 触觉反馈 + 手势融合                   │  │
│  └────────────────────────────────────────┘  │
└──────────────────────────────────────────────┘
```

## 14.3 核心 API 速查表

| API | 说明 | 版本要求 |
|-----|------|---------|
| `backgroundBlurStyle(BlurStyle.REGULAR)` | 组件背景毛玻璃效果 | API 10+ |
| `foregroundBlurStyle(BlurStyle.REGULAR)` | 组件内容模糊效果 | API 10+ |
| `.blur(radius)` | 基础模糊半径（用于光晕） | API 10+ |
| `.backdropFilter($r('sys.blur.20'))` | 系统级背景滤镜 | API 12+ |
| `.expandSafeArea([SYSTEM], [TOP, BOTTOM])` | 扩展至状态栏/导航栏 | API 12+ |
| `setWindowLayoutFullScreen(true)` | 全屏布局窗口 | API 12+ |
| `setWindowSystemBarProperties(...)` | 系统栏颜色/图标样式 | API 10+ |
| `@kit.SensorServiceKit` (ambientLight) | 环境光传感器 | API 12+ |
| `UIDesignKit` (ImmersiveLightEffect) | 沉浸光感组件 | API 22+ (HMOS 6) |

**BlurStyle 枚举值：**

| 值 | 说明 | 适用场景 |
|----|------|---------|
| `REGULAR` | 标准模糊（推荐） | 卡片、面板 |
| `THIN` | 轻度模糊 | 工具栏、悬浮按钮 |
| `THICK` | 重度模糊 | 弹窗、遮罩 |
| `REGULAR_LIGHT` | 标准浅色 | 暗色背景卡片 |
| `THICK_LIGHT` | 重度浅色 | 大面积半透明区域 |
| `NONE` | 无模糊 | 性能敏感场景 |

## 14.4 沉浸光感背景层实现

```typescript
// components/ImmersiveBackground.ets
// 沉浸式光感背景层 — 所有页面的底层容器
import { window } from '@kit.ArkUI';
import { sensor } from '@kit.SensorServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';

@Component
export struct ImmersiveBackground {
  @State lightIntensity: number = 0.6;        // 光效强度 (0.0 ~ 1.0)
  @State dominantColor: string = '#1a1a2e';   // 主色调（默认深蓝）
  @StorageLink('currentTheme') theme: string = 'dark';

  aboutToAppear() {
    // 尝试获取环境光传感器数据，动态调节光效强度
    try {
      sensor.on(sensor.SensorId.AMBIENT_LIGHT, (data) => {
        const lux = data.light; // 环境光 lux 值
        // 映射 lux → 光效强度
        // 暗光环境 (<50 lux): 增强光效 → 0.7~0.9
        // 正常环境 (50~500 lux): 适中 → 0.4~0.7
        // 强光环境 (>500 lux): 减弱光效 → 0.2~0.4
        this.lightIntensity = this.mapLuxToIntensity(lux);
      }, { interval: 1000000000 }); // 1秒采样
    } catch (err) {
      console.warn('Ambient light sensor unavailable, using default intensity');
    }
  }

  private mapLuxToIntensity(lux: number): number {
    if (lux < 50) return 0.85;
    if (lux < 200) return 0.70;
    if (lux < 500) return 0.50;
    return 0.30;
  }

  build() {
    Stack() {
      // 第一层：主光晕效果
      Column()
        .width('100%').height('100%')
        .backgroundColor(this.dominantColor)
        // 大光晕模糊层
        .overlay(
          // 顶部光晕
          Column()
            .width(300).height(300)
            .backgroundColor('#6677ff')
            .blur(120) // 大半径模糊创造光晕
            .opacity(this.lightIntensity * 0.5)
            .position({ x: '50%', y: 100 })
        )
        .overlay(
          // 底部光晕
          Column()
            .width(250).height(250)
            .backgroundColor('#ff6688')
            .blur(100)
            .opacity(this.lightIntensity * 0.4)
            .position({ x: '30%', y: '70%' })
        )
        // 关键：扩展至安全区（状态栏/导航栏）
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      // 第二层：渐变遮罩（提升内容可读性）
      Column()
        .width('100%').height('100%')
        .linearGradient({
          direction: GradientDirection.Top,
          colors: [
            ['rgba(0,0,0,0.4)', 0.0],
            ['rgba(0,0,0,0.2)', 0.5],
            ['rgba(0,0,0,0.5)', 1.0]
          ]
        })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      // 第三层：实际页面内容（插槽）
      Column() {
        this.contentBuilder()
      }
      .width('100%').height('100%')
      .padding({ top: 44, bottom: 80 }) // 避让状态栏 + 悬浮导航栏
    }
    .width('100%').height('100%')
  }

  @BuilderParam contentBuilder: () => void;
}
```

## 14.5 玻璃拟态卡片组件

```typescript
// components/GlassmorphicCard.ets
// 通用玻璃拟态卡片 — 主机列表项、设置卡片、连接表单等复用

@Component
export struct GlassmorphicCard {
  @Prop borderRadius: number = 20;
  @Prop paddingSize: number = 16;
  @BuilderParam contentBuilder: () => void;

  build() {
    Column() {
      this.contentBuilder()
    }
    .width('100%')
    .padding(this.paddingSize)
    .borderRadius(this.borderRadius)
    // 毛玻璃背景效果（核心API）
    .backgroundBlurStyle(BlurStyle.REGULAR)
    .backgroundColor('rgba(255, 255, 255, 0.15)') // 半透明底
    // 精致边框
    .border({
      width: 1,
      color: 'rgba(255, 255, 255, 0.2)',
      style: BorderStyle.Solid
    })
    // 柔和阴影
    .shadow({
      radius: 20,
      color: 'rgba(0, 0, 0, 0.15)',
      offsetY: 4
    })
  }
}
```

## 14.6 悬浮导航栏组件

```typescript
// components/FloatNavigation.ets
// HarmonyOS 6 悬浮导航 — 强/平衡/弱 三档透明度

export enum TransparencyLevel {
  STRONG = 0.85,   // 强效果：高透明度，玻璃感明显
  BALANCED = 0.70, // 平衡效果：适中（推荐默认）
  WEAK = 0.55      // 弱效果：低透明度，更清晰
}

@Component
export struct FloatNavigation {
  @State currentTab: number = 0;
  @State navTransparency: number = TransparencyLevel.BALANCED;
  @Prop bottomAvoidHeight: number = 0; // 内容区底部避让高度
  onTabChange?: (index: number) => void;

  private tabs: Array<{icon: Resource, label: string}> = [
    { icon: $r('app.media.ic_hosts'), label: '主机' },
    { icon: $r('app.media.ic_connection'), label: '连接' },
    { icon: $r('app.media.ic_settings'), label: '设置' }
  ];

  build() {
    // 悬浮导航栏容器
    Column() {
      // 玻璃拟态底色
      Row() {
        ForEach(this.tabs, (tab: {icon: Resource, label: string}, index: number) => {
          Column() {
            Image(tab.icon)
              .width(24).height(24)
              .fillColor(index === this.currentTab ? '#FFFFFF' : 'rgba(255,255,255,0.6)')
            Text(tab.label)
              .fontSize(10)
              .fontColor(index === this.currentTab ? '#FFFFFF' : 'rgba(255,255,255,0.6)')
              .margin({ top: 2 })
          }
          .layoutWeight(1)
          .onClick(() => {
            this.currentTab = index;
            this.onTabChange?.(index);
            this.triggerHaptic();
          })
        })
      }
      .width('90%').height(64)
      .justifyContent(FlexAlign.SpaceAround)
      .borderRadius(24)
      .backgroundBlurStyle(BlurStyle.REGULAR) // 毛玻璃
      .backgroundColor(`rgba(30, 30, 40, ${this.navTransparency})`)
      .border({
        width: 0.5,
        color: 'rgba(255, 255, 255, 0.1)',
        style: BorderStyle.Solid
      })
      .shadow({
        radius: 30,
        color: 'rgba(0, 0, 0, 0.3)',
        offsetY: 8
      })
    }
    .width('100%')
    .position({ x: '50%', y: '90%' })
    .translate({ x: '-50%', y: 0 }) // 水平居中
    .animation({ duration: 300, curve: Curve.EaseOut })
  }

  private triggerHaptic() {
    try {
      import('@kit.SensorServiceKit').then(sensor => {
        sensor.vibrator.startVibration({
          type: 'time',
          duration: 30
        }, { id: 0 });
      });
    } catch (err) {
      console.error('Haptic feedback failed:', err);
    }
  }
}
```

## 14.7 光感传感器服务

```typescript
// services/LightSensingService.ts
import { sensor } from '@kit.SensorServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';

export class LightSensingService {
  private static instance: LightSensingService;
  private currentLux: number = 200; // 默认正常环境
  private listeners: Array<(lux: number) => void> = [];

  static getInstance(): LightSensingService {
    if (!this.instance) {
      this.instance = new LightSensingService();
    }
    return this.instance;
  }

  startMonitoring() {
    try {
      sensor.on(
        sensor.SensorId.AMBIENT_LIGHT,
        (data: sensor.AmbientLightResponse) => {
          this.currentLux = data.light;
          this.notifyListeners(data.light);
        },
        { interval: 1000000000 } // 1秒
      );
    } catch (err) {
      console.warn('Ambient light sensor not available, theme will remain static');
    }
  }

  /** 获取建议的光效强度 (0~1) */
  getLightIntensity(): number {
    if (this.currentLux < 50) return 0.85;   // 暗光 → 强光效
    if (this.currentLux < 200) return 0.70;  // 室内 → 平衡
    if (this.currentLux < 500) return 0.50;  // 明亮 → 弱光效
    return 0.30;                              // 室外 → 最弱
  }

  /** 获取建议的 UI 主题 */
  getRecommendedTheme(): 'dark' | 'light' {
    return this.currentLux < 300 ? 'dark' : 'light';
  }

  onLightChange(callback: (lux: number) => void) {
    this.listeners.push(callback);
  }

  private notifyListeners(lux: number) {
    for (const cb of this.listeners) cb(lux);
  }
}
```

## 14.8 主机列表页 (沉浸式 UI 完整示例)

```typescript
// pages/HostListPage.ets — 沉浸光感主机列表
import { ImmersiveBackground } from '../components/ImmersiveBackground';
import { GlassmorphicCard } from '../components/GlassmorphicCard';
import { FloatNavigation, TransparencyLevel } from '../components/FloatNavigation';
import { LightSensingService } from '../services/LightSensingService';

@Entry
@Component
struct HostListPage {
  @State hosts: RemoteHost[] = [];
  @State lightIntensity: number = 0.6;
  @State searchText: string = '';
  private lightService = LightSensingService.getInstance();

  async aboutToAppear() {
    // 启动光感监测
    this.lightService.startMonitoring();
    this.lightService.onLightChange((lux: number) => {
      this.lightIntensity = this.lightService.getLightIntensity();
    });
    // 加载远程主机列表
    const userId = await this.getCurrentUserId();
    this.hosts = await this.syncService.loadFromCloud(userId);
  }

  build() {
    // 使用沉浸光感背景作为根容器
    ImmersiveBackground({
      lightIntensity: this.lightIntensity,
      contentBuilder: () => {
        this.MainContent()
      }
    })
  }

  @Builder
  MainContent() {
    Column() {
      // 搜索栏（玻璃拟态）
      GlassmorphicCard({ borderRadius: 16, paddingSize: 8 }) {
        Row() {
          Image($r('app.media.ic_search'))
            .width(20).height(20)
            .fillColor('rgba(255,255,255,0.7)')
            .margin({ left: 8 })
          TextInput({ placeholder: '搜索远程主机...', text: this.searchText })
            .backgroundColor(Color.Transparent)
            .fontColor('#FFFFFF')
            .placeholderColor('rgba(255,255,255,0.4)')
            .layoutWeight(1)
            .height(44)
            .onChange((value) => this.filterHosts(value))
        }
      }
      .margin({ top: 16, left: 16, right: 16 })

      // 主机列表（玻璃拟态卡片）
      List({ space: 12 }) {
        ForEach(this.hosts, (host: RemoteHost) => {
          ListItem() {
            GlassmorphicCard() {
              Row() {
                // 主机图标
                Image(host.icon || $r('app.media.default_host'))
                  .width(48).height(48).borderRadius(12)
                // 主机信息
                Column() {
                  Text(host.label)
                    .fontSize(17).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
                  Text(`${host.protocol.toUpperCase()} · ${host.host}:${host.port}`)
                    .fontSize(13).fontColor('rgba(255,255,255,0.6)')
                    .margin({ top: 2 })
                }
                .layoutWeight(1).alignItems(HorizontalAlign.Start)
                .margin({ left: 12 })
                // 锁状态图标
                Image(host.locked ? $r('app.media.icon_locked') : $r('app.media.icon_unlocked'))
                  .width(24).height(24)
                  .fillColor(host.locked ? '#FF6B6B' : '#51CF66')
              }
            }
            .onClick(() => this.connectToHost(host))
          }
        })
      }
      .layoutWeight(1)
      .padding({ left: 16, right: 16, top: 12 })

      // 悬浮导航栏
      FloatNavigation({
        bottomAvoidHeight: 80,
        onTabChange: (index: number) => this.onTabSwitch(index)
      })
    }
    .width('100%').height('100%')
  }
}
```

## 14.9 窗口级沉浸式初始化

```typescript
// entryability/EntryAbility.ets
import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';

export default class EntryAbility extends UIAbility {
  private windowStage: window.WindowStage | null = null;

  onWindowStageCreate(windowStage: window.WindowStage) {
    this.windowStage = windowStage;
    windowStage.loadContent('pages/HostListPage', (err) => {
      this.initImmersiveWindow();
    });
  }

  private async initImmersiveWindow() {
    const mainWindow = await this.windowStage?.getMainWindow();
    if (!mainWindow) return;

    // 1. 启用全屏布局
    await mainWindow.setWindowLayoutFullScreen(true);

    // 2. 设置透明系统栏（让光感背景延展到状态栏下）
    await mainWindow.setWindowSystemBarProperties({
      statusBarColor: '#00000000',               // 透明状态栏
      navigationBarColor: '#00000000',           // 透明导航栏
      statusBarContentColor: '#FFFFFF',          // 白色状态栏图标
      navigationBarContentColor: '#FFFFFF'       // 白色导航栏图标
    });

    // 3. 启用安全区避让（HarmonyOS 6 新特性）
    await mainWindow.setWindowAvoidAreaOption({
      type: window.AvoidAreaType.TYPE_SYSTEM,
      mode: window.AvoidAreaMode.MODE_AVOID
    });
  }
}
```

## 14.10 性能注意事项

| 场景 | 建议 | 原因 |
|------|------|------|
| 低端设备 | 降级到 `backgroundBlurStyle(THIN)` 或纯色 | 模糊计算有 GPU 开销 |
| 列表滚动中 | 暂停光感传感器采样 | 减少不必要的状态更新 |
| 页面不可见 | 暂停光效动画 | 通过 `onPageShow/Hide` 控制 |
| 高对比度模式 | 自动降级为纯色背景 | 无障碍合规要求 |
| 远程桌面主视图 | 不使用毛玻璃 | 优先保证渲染性能 |

---

# 第十五章 权限声明与发布

```json5
{
  "module": {
    "requestPermissions": [
      { "name": "ohos.permission.INTERNET" },
      { "name": "ohos.permission.GET_NETWORK_INFO" },
      { "name": "ohos.permission.MICROPHONE", "reason": "$string:mic_reason" },
      { "name": "ohos.permission.KEEP_BACKGROUND_RUNNING" },
      { "name": "ohos.permission.ACCESS_BIOMETRIC" },
      { "name": "ohos.permission.DISTRIBUTED_DATASYNC" },
      { "name": "ohos.permission.GET_ACCOUNT_INFO" }
    ]
  }
}
```

---

# 第十六章 测试策略

| 测试类型 | 工具 | 覆盖目标 |
|---------|------|---------|
| 单元测试 | ArkTS hypium | GlassmorphicCard、FloatNavigation、LockService |
| Native 测试 | CppUnitTest | HUKS、HostLocker、ExtensionRegistry |
| 集成测试 | 真机+Windows/Linux | RDP/RustDesk 端到端、云同步一致性 |
| UI 测试 | hdc + 截图对比 | 光感效果、沉浸式渲染正确性 |
| 性能测试 | hypeprof+SmartPerf | 帧率、GPU、模糊性能回归 |
| 无障碍测试 | 系统高对比度模式 | 自动降级验证 |

---

# 第十七章 开发路线图

| 阶段 | 内容 | 周期 | 里程碑 |
|------|------|------|--------|
| Phase 1 | 扩展框架 + ProtocolAdapter 接口 | 5天 | ExtensionRegistry 可运行 |
| Phase 2 | FreeRDP + RustDesk 交叉编译 | 7天 | 双协议后端编译通过 |
| Phase 3 | NAPI 桥接 + 共享渲染管线 | 10天 | 首帧渲染成功 |
| Phase 4 | 音频 + 输入 + 剪贴板 | 7天 | 完整交互闭环 |
| Phase 5 | ArkTS UI (沉浸光感 + 登录/列表/桌面) | 10天 | 完整 UI 可操作 |
| Phase 6 | 主机安全锁（生物识别/PIN/密码） | 5天 | 锁机制通过安全审核 |
| Phase 7 | 测试 + 发布 | — | AppGallery 上架 |

---

# 附录 A：关键 API 版本要求

| API | 最低版本 | 推荐版本 |
|-----|---------|---------|
| backgroundBlurStyle | API 10 | API 12+ |
| expandSafeArea | API 12 | API 13+ |
| setWindowLayoutFullScreen | API 12 | API 13+ |
| UIDesignKit (ImmersiveLight) | API 22 | API 23 (HMOS 6.1) |
| SensorServiceKit (ambientLight) | API 12 | API 13+ |
| HUKS | API 9 | API 12+ |
| Biometric Authentication Kit | API 10 | API 12+ |
| HMS Account Kit | API 9 | API 12+ |
| Cloud DB | API 9 | API 12+ |

---

# 附录 B：协议元信息扩展点

```cpp
class VncAdapter : public ProtocolAdapter {
    // ... 实现 VNC 协议细节
    int default_port(): number { return 5900; }
};
```

---

# 附录 C：调试命令速查

```bash
hdc list targets                     # 列出设备
hdc shell hilog | grep RDP           # RDP 日志
hdc shell hilog | grep HMS           # HMS 登录日志
hdc shell hilog | grep Lock          # 主机锁日志
hdc shell hilog | grep Extension     # 扩展系统日志
hdc shell hilog | grep LightSensor   # 光感日志
hdc shell hypeprof -p <pid> -o /tmp/perfetto  # 性能分析
hdc install -r entry-default-signed.hap       # 安装应用
```

---

# 附录 D：关键参考链接

- 鸿蒙开发者官网：https://developer.huawei.com/consumer/cn/
- HMS Account Kit：https://developer.huawei.com/consumer/cn/hms/huawei-account/
- Cloud DB 开发指南：https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/agc-clouddb-introduction
- Biometric Auth Kit：https://developer.huawei.com/consumer/cn/hms/huawei-bioauth/
- HUKS 通用密钥库：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/huks-overview
- ArkUI 沉浸式效果：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-develop-apply-immersive-effects
- 背景模糊 API：https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ts-universal-attributes-background
- FreeRDP 官方文档：https://github.com/FreeRDP/FreeRDP/wiki
- RustDesk 源码：https://github.com/rustdesk/rustdesk
- MS-RDPBCGR 协议规范：https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/

---

# 🆕 附录 F：Claude Code 项目落地指南

## F.1 准备工作

让 Claude 按本文档构建项目，你需要：

**1. 创建 CLAUDE.md 文件（放在项目根目录）**

```markdown
# CLAUDE.md — 鸿蒙PC双协议远程桌面客户端

## 项目定位
HarmonyOS NEXT PC 原生远程桌面客户端，双协议（RDP + RustDesk）、华为云同步、主机安全锁。

## 技术栈
- UI: ArkTS + ArkUI (声明式) + UIDesignKit (沉浸光感)
- 后端: FreeRDP 3.x (C) + RustDesk core FFI (Rust) 
- 渲染: OpenGL ES 3.0 + OH_AVCodec 硬解
- 安全: HUKS + Biometric Authentication Kit
- 平台: HarmonyOS NEXT API 12+ (目标 HMOS 6)

## 架构原则
- 扩展优先：所有功能通过 ExtensionRegistry 注册，不修改核心框架
- 零拷贝渲染：硬解 → NativeImage → GL 纹理，全程无 CPU memcpy
- 协议可插拔：实现 ProtocolAdapter 接口即可添加新协议
- 光感 UI：基于 BlurStyle + 光感传感器动态调节

## 文件管理规范
- 所有 ArkTS 代码放在 entry/src/main/ets/
  - pages/      → 页面级组件
  - components/ → 可复用通用组件 
  - services/   → 业务逻辑层
  - napi/       → NAPI 类型声明
- 所有 Native 代码放在 entry/src/main/cpp/
  - extensions/ → 扩展框架
  - rdp/        → FreeRDP 适配器
  - rustdesk/   → RustDesk FFI 桥接
  - render/     → OpenGL ES 渲染
  - audio/      → OHAudio 音频
  - security/   → HUKS + 主机锁
- 交叉编译产物放在 freerdp/build_ohos/ 和 rustdesk_ffi/target/
- 外部插件 (.hsp) 放在 plugins/

## 开发阶段
当前阶段: Phase 1 — 扩展框架 + ProtocolAdapter 接口
- [ ] Phase 1: 扩展框架 (ExtensionRegistry, ProtocolAdapter)
- [ ] Phase 2: FreeRDP + RustDesk 交叉编译
- [ ] Phase 3: NAPI 桥接 + 共享渲染管线
- [ ] Phase 4: 音频 + 输入 + 剪贴板
- [ ] Phase 5: ArkTS UI (沉浸光感)
- [ ] Phase 6: 主机安全锁
- [ ] Phase 7: 测试 + 发布

## 编码规范
- ArkTS 组件：使用 @Component + @State 声明式
- C++ 类：驼峰命名，接口用纯虚类
- 错误处理：用 try/catch，不忽略异常
- 注释语言：中文
- 禁止使用 any 类型（ArkTS strict mode）

## 参考文档
完整技术方案：鸿蒙PC双协议远程桌面_技术方案_v4.md
```

**2. 将本技术文档 v4.md 放入项目**

```bash
# 在项目根目录
cp ~/鸿蒙PC双协议远程桌面_技术方案_v4.md ./docs/TECH_SPEC.md
```

## F.2 文件管理策略

**目录树规范（Claude 按此创建文件）：**

```
RemoteDeskHarmonyOS/
├── CLAUDE.md                        # ← Claude 上下文文件
├── docs/
│   └── TECH_SPEC.md                 # ← 本技术方案 v4
├── AppScope/
│   └── app.json5
├── entry/
│   └── src/main/
│       ├── module.json5
│       ├── ets/
│       │   ├── entryability/
│       │   │   └── EntryAbility.ets
│       │   ├── pages/
│       │   │   ├── LoginPage.ets
│       │   │   ├── HostListPage.ets
│       │   │   ├── ConnectionForm.ets
│       │   │   ├── RemoteDesktop.ets
│       │   │   └── Settings.ets
│       │   ├── components/
│       │   │   ├── ImmersiveBackground.ets
│       │   │   ├── GlassmorphicCard.ets
│       │   │   ├── FloatNavigation.ets
│       │   │   ├── HostCard.ets
│       │   │   ├── LockGate.ets
│       │   │   ├── ProtocolSelector.ets
│       │   │   └── RdpCanvas.ets
│       │   ├── services/
│       │   │   ├── AuthService.ts
│       │   │   ├── HostSyncService.ts
│       │   │   ├── LightSensingService.ts
│       │   │   ├── LockService.ts
│       │   │   └── ExtensionLoader.ts
│       │   └── napi/
│       │       ├── ProtocolBridge.ts
│       │       └── NativeAuth.ts
│       ├── cpp/
│       │   ├── extensions/
│       │   │   ├── extension_registry.h
│       │   │   ├── protocol_adapter.h
│       │   │   ├── auth_provider.h
│       │   │   └── data_provider.h
│       │   ├── rdp/
│       │   │   └── freerdp_adapter.cpp
│       │   ├── rustdesk/
│       │   │   └── rustdesk_bridge.cpp
│       │   ├── render/
│       │   │   ├── gl_renderer.cpp
│       │   │   └── hw_decoder.cpp
│       │   ├── audio/
│       │   │   └── audio_player.cpp
│       │   └── security/
│       │       ├── host_locker.cpp
│       │       └── crypto_utils.cpp
│       └── resources/
├── plugins/
├── freerdp/              # git submodule
├── rustdesk_ffi/         # Rust 项目
└── build-profile.json5
```

## F.3 给 Claude 的任务指令模板

**按阶段推进（推荐）：**

```
请阅读 docs/TECH_SPEC.md，现在开始 Phase 1。
创建以下文件，严格按照技术文档中的接口定义：

1. entry/src/main/cpp/extensions/extension_registry.h
2. entry/src/main/cpp/extensions/protocol_adapter.h
3. entry/src/main/cpp/extensions/auth_provider.h
4. entry/src/main/cpp/extensions/data_provider.h
5. 更新 entry/src/main/cpp/napi_init.cpp（注册扩展系统）
6. 验证编译通过

每完成一个文件，列出创建的文件名和行数。
```

**按模块开发：**

```
请基于 TECH_SPEC.md 实现沉浸光感 UI 模块（Phase 5 ArkTS UI 子任务）。
按顺序创建：

1. components/ImmersiveBackground.ets — 三层光感背景
2. components/GlassmorphicCard.ets — 通用玻璃拟态卡片
3. components/FloatNavigation.ets — 悬浮导航栏
4. services/LightSensingService.ts — 光感传感器服务
5. pages/HostListPage.ets — 集成所有组件的完整页面
6. entryability/EntryAbility.ets — 窗口沉浸式初始化

确保所有 API 调用与官方文档一致，使用 BlurStyle.REGULAR 而非自定义值。
```

## F.4 关键提醒

1. **CLAUDE.md 是 Claude 的"记忆"** —— 它每次启动都会读这个文件。保持它准确、精简（< 200 行）
2. **TECH_SPEC.md 是"真理来源"** —— Claude 应该以它为准，不要凭空编造 API
3. **按阶段推进** —— 不要一次让 Claude 写全部代码。每完成一个 Phase，验证编译通过再继续
4. **文件路径严格一致** —— Claude 创建文件时必须使用确切的目录结构，不要自由发挥
5. **禁止 any 类型** —— 在对话中明确要求 ArkTS strict mode，避免松散类型

---

**文档版本：v4.0 | 更新日期：2026年6月 | 作者：Li Jiong + Hermes Agent**
