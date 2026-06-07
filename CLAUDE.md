# CLAUDE.md — 鸿蒙PC双协议远程桌面客户端

## 项目定位
HarmonyOS NEXT PC 原生远程桌面客户端，双协议（RDP + RustDesk）、华为云同步、主机安全锁、沉浸光感UI。

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

## 目录结构（严格遵循）
```
entry/src/main/
├── ets/
│   ├── entryability/EntryAbility.ets
│   ├── pages/          → LoginPage, HostListPage, ConnectionForm, RemoteDesktop, Settings
│   ├── components/     → ImmersiveBackground, GlassmorphicCard, FloatNavigation, HostCard, LockGate
│   ├── services/       → AuthService, HostSyncService, LightSensingService, LockService, ExtensionLoader
│   └── napi/           → ProtocolBridge, NativeAuth (type declarations)
├── cpp/
│   ├── extensions/     → extension_registry.h, protocol_adapter.h, auth_provider.h, data_provider.h
│   ├── rdp/            → freerdp_adapter.cpp
│   ├── rustdesk/       → rustdesk_bridge.cpp
│   ├── render/         → gl_renderer.cpp, hw_decoder.cpp
│   ├── audio/          → audio_player.cpp
│   └── security/       → host_locker.cpp, crypto_utils.cpp
└── resources/
freerdp/                  # git submodule
rustdesk_ffi/             # Rust project (Cargo.toml)
plugins/                  # .hsp external extensions
```

## 开发阶段（当前: Phase 1）
- [ ] Phase 1: 扩展框架 (ExtensionRegistry, ProtocolAdapter) — 5天
- [ ] Phase 2: FreeRDP + RustDesk 交叉编译 — 7天
- [ ] Phase 3: NAPI 桥接 + 共享渲染管线 — 10天
- [ ] Phase 4: 音频 + 输入 + 剪贴板 — 7天
- [ ] Phase 5: ArkTS UI (沉浸光感) — 10天
- [ ] Phase 6: 主机安全锁 — 5天
- [ ] Phase 7: 测试 + AppGallery 发布

## 编码规范
- ArkTS 组件：@Component + @State 声明式
- C++ 类：驼峰命名，接口用纯虚类
- 错误处理：try/catch，不忽略异常
- 注释语言：中文
- 禁止 any 类型（ArkTS strict mode）
- ArkUI API：优先使用 BlurStyle.REGULAR（非自定义值）

## 权威参考
- 完整技术方案：docs/TECH_SPEC.md（真理来源，以它为准）
- 鸿蒙沉浸式文档：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-develop-apply-immersive-effects
- 背景模糊 API：https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ts-universal-attributes-background
