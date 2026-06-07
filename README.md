<p align="center">
  <img src="https://img.shields.io/badge/HarmonyOS-NEXT-blue?style=flat-square" alt="HarmonyOS NEXT">
  <img src="https://img.shields.io/badge/license-Apache%202.0-green?style=flat-square" alt="Apache 2.0">
  <img src="https://img.shields.io/badge/API-12%2B-orange?style=flat-square" alt="API 12+">
  <img src="https://img.shields.io/badge/C%2B%2B-17-blueviolet?style=flat-square" alt="C++17">
  <img src="https://img.shields.io/badge/Rust-FFI-red?style=flat-square" alt="Rust FFI">
</p>

# 🖥️ RemoteDeskHarmonyOS

**鸿蒙 PC 双协议远程桌面客户端** — 原生 HarmonyOS NEXT 远程桌面应用，支持 RDP 与 RustDesk 双协议，集成 HMS 云同步、硬件级主机安全锁、HarmonyOS 6 沉浸光感 UI。

<p align="center">
  <img src="https://raw.githubusercontent.com/Mydstiny/RemoteDeskHarmonyOS/main/docs/architecture.svg" width="80%" alt="Architecture">
</p>

---

## ✨ 特性

| 特性 | 说明 |
|------|------|
| 🔄 **双协议引擎** | RDP (FreeRDP 3.x) + RustDesk，一键切换 |
| ☁️ **华为云同步** | HMS Account Kit 登录，Cloud DB 多设备同步远程主机 |
| 🔐 **主机安全锁** | HUKS 硬件级加密，指纹/面部/PIN/密码四种解锁方式 |
| 🎨 **沉浸光感 UI** | HarmonyOS 6 玻璃拟态 + 环境光传感器自适应 |
| 🧩 **可扩展插件** | ExtensionRegistry 架构 + HSP 动态模块加载 |
| 🖥️ **鸿蒙 PC 适配** | 2in1 设备优先，支持手机/平板多端 |

## 🚀 快速开始

### 环境要求

| 工具 | 版本要求 |
|------|---------|
| DevEco Studio | 5.0.0+ |
| HarmonyOS SDK | API 12+ |
| CMake | 3.16+ |
| Rust | 1.70+ (RustDesk FFI) |
| Node.js | 18+ (HMS SDK) |

### 构建步骤

```bash
# 1. 克隆项目
git clone https://github.com/Mydstiny/RemoteDeskHarmonyOS.git

# 2. 初始化 FreeRDP 子模块
cd RemoteDeskHarmonyOS
git submodule add https://github.com/FreeRDP/FreeRDP.git freerdp
cd freerdp && git checkout stable-3.0 && cd ..

# 3. 交叉编译 RustDesk FFI
cd rustdesk_ffi
rustup target add aarch64-unknown-linux-ohos
cargo build --release --target aarch64-unknown-linux-ohos
cd ..

# 4. DevEco Studio 打开项目 → Build → Build Hap
```

> ℹ️ 完整构建指南见 [docs/TECH_SPEC.md](docs/TECH_SPEC.md)

## 📂 项目结构

```
RemoteDeskHarmonyOS/
├── entry/src/main/
│   ├── ets/                    # ArkTS 前端
│   │   ├── pages/              # 登录/主机列表/远程桌面/设置
│   │   ├── components/         # 玻璃拟态卡片/悬浮导航/光感背景
│   │   ├── services/           # 认证/云同步/光感/锁服务
│   │   └── napi/               # Native 桥接类型声明
│   ├── cpp/                    # C++ Native
│   │   ├── extensions/         # ExtensionRegistry 扩展框架
│   │   ├── rdp/                # FreeRDP 适配器
│   │   ├── rustdesk/           # RustDesk FFI 桥接
│   │   ├── render/             # OH_AVCodec + OpenGL ES 渲染
│   │   ├── audio/              # OHAudio 低延迟音频
│   │   └── security/           # HUKS 加密 + 主机锁
│   └── resources/
├── docs/TECH_SPEC.md           # 完整技术方案 (v4)
├── freerdp/                    # FreeRDP git submodule
├── rustdesk_ffi/               # RustDesk Rust FFI 项目
└── plugins/                    # HSP 动态扩展 (.hsp)
```

## 🧩 架构概览

```
 ┌──────────────────────────────────────┐
 │       ArkTS UI (沉浸光感)              │
 │  LoginPage · HostList · RemoteDesktop │
 ├──────────────────────────────────────┤
 │  ExtensionRegistry (插件框架)          │
 │  ProtocolRegistry · AuthRegistry      │
 ├──────────┬───────────────────────────┤
 │  NAPI    │  C++ Native                │
 │  Bridge  │  FreeRDP · RustDesk · GL   │
 ├──────────┴───────────────────────────┤
 │  HarmonyOS SDK · HMS Core · HUKS      │
 └──────────────────────────────────────┘
```

## 🛡️ 开源协议

本项目使用 **Apache License 2.0**。依赖库授权：

| 依赖 | 协议 | 说明 |
|------|------|------|
| FreeRDP | Apache 2.0 | 静态链接 |
| RustDesk | AGPL-3.0 | ⚠️ 独立进程 + Unix Socket 隔离，避免 copyleft 传染 |

详见 [LICENSE](LICENSE) 和 [NOTICE](NOTICE)。

## 📦 Release

| 版本 | 日期 | 说明 |
|------|------|------|
| v0.1.0 | 2026-06 | 首个源码发布：完整项目结构与核心模块 |

## 🤝 贡献

欢迎 Issue / PR。大改动请先开 Issue 讨论。

---

**作者:** Li Jiong (Mydstiny)  
**平台:** HarmonyOS NEXT · 2in1 / Phone / Tablet  
**语言:** ArkTS · C++ · Rust
