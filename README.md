<div align="center">

<img src="docs/assets/readme-hero.svg" alt="RemoteDesktop：面向 HarmonyOS NEXT 的原生远程连接工作台，支持 RDP、RustDesk、SSH/SFTP、VNC 和 Moonlight。" width="100%" />

# RemoteDesktop · 鸿蒙远程桌面

**远程桌面、终端、文件与串流，一个工作台就够。**

面向 HarmonyOS NEXT 的原生多协议客户端，为手机、平板与 PC 打造。

[![HarmonyOS NEXT](https://img.shields.io/badge/HarmonyOS-NEXT-147DFF?style=flat-square)](#连接你的工作空间) [![ArkTS + Rust + C++](https://img.shields.io/badge/ArkTS%20%2B%20Rust%20%2B%20C%2B%2B-Native-334155?style=flat-square)](docs/DEVELOPMENT.md) [![License: AGPL v3+](https://img.shields.io/badge/License-AGPL--3.0--or--later-2563EB?style=flat-square)](LICENSE) [![Open source compliance](https://github.com/Mydstiny/RemoteDeskHarmonyOS/actions/workflows/open-source-compliance.yml/badge.svg?branch=main)](https://github.com/Mydstiny/RemoteDeskHarmonyOS/actions/workflows/open-source-compliance.yml)

[详细功能](#详细功能) · [使用指南](docs/app-store/USER_GUIDE.md) · [从源码构建](docs/DEVELOPMENT.md) · [版本与发布](https://github.com/Mydstiny/RemoteDeskHarmonyOS/releases) · [反馈问题](https://github.com/Mydstiny/RemoteDeskHarmonyOS/issues)

</div>

---

## 连接你的工作空间

在 Windows 桌面上继续工作，在服务器终端中处理任务，或通过 Sunshine 串流应用。
RemoteDesktop 将不同连接方式放进统一的主机工作台，按工作组整理、按协议筛选，让常用设备更容易找到。

| 连接方式 | 适用场景 | 主要能力 |
| :--- | :--- | :--- |
| **RDP** | Windows 远程办公 | FreeRDP / WinPR、证书预检、Microsoft / Azure AD 凭据、音视频、文本剪贴板与共享目录 |
| **RustDesk** | 跨平台远程控制 | ID / 中继 / 直连、远程画面与音频、键鼠输入、文本剪贴板与文件传输 |
| **SSH / SFTP** | 服务器维护与文件管理 | 多标签与多窗格终端、密钥认证、跳板机、端口转发、双栏文件工作区与传输中心 |
| **VNC** | 连接已有 VNC 服务 | TLS / 明文预检、证书与凭据确认、远程画面、输入、文本剪贴板与网关配置 |
| **Moonlight** | 通过 Sunshine 串流 | 主机发现、PIN 配对、应用目录、画面与音频、键鼠 / 触控 / 控制器输入 |

## 为鸿蒙日常使用而设计

<table>
<tr>
<td width="50%" valign="top">

### 多设备，自然适配

ArkTS + ArkUI 原生界面，适配 Phone、Pad 与 PC。结合窗口尺寸调整布局，提供远程键盘、浮动控制栏、画中画与前后台恢复。

</td>
<td width="50%" valign="top">

### 终端与文件，一起处理

SSH 多标签、多窗格、搜索和常用命令，搭配 SFTP 双栏浏览与传输中心，让终端操作和文件管理衔接起来。

</td>
</tr>
<tr>
<td width="50%" valign="top">

### 数据保护，掌握在自己手中

支持本地 AES-256-GCM 数据保护、HUKS / 生物认证集成、密钥库、TOTP 验证器与备份恢复。连接时核对远端身份，按需管理凭据。

</td>
<td width="50%" valign="top">

### 离线使用，按需同步

可离线管理本机数据；登录华为账号并完成云服务配置后，按需选择同步内容，提供显式同步、重试与本地恢复隔离。

</td>
</tr>
</table>

> 各项能力受远端服务、设备形态、系统权限和配置影响；剪贴板、文件传输等以当前协议与会话的实际可用状态为准。

## 开始使用

**了解产品** → 阅读[使用指南](docs/app-store/USER_GUIDE.md)，了解首次使用、添加主机与各协议的操作方式。

**准备连接** → 在远端启用对应服务，在 RemoteDesktop 添加主机，核对证书或主机指纹；Moonlight 需先完成 Sunshine 配对。

**参与开发** → 克隆源码，按[开发与构建指南](docs/DEVELOPMENT.md)配置 DevEco Studio、本地依赖和私有构建文件。

```sh
git clone --recurse-submodules https://github.com/Mydstiny/RemoteDeskHarmonyOS.git
cd RemoteDeskHarmonyOS
```

> [!NOTE]
> 仓库当前版本为 **1.1.5.1**，仍处于测试与发布验证阶段。安装包可用性以 [Releases](https://github.com/Mydstiny/RemoteDeskHarmonyOS/releases) 为准；标记为 `unsigned` 的 HAP 未经应用签名，仅用于开发测试，不是 AppGallery 或生产分发安装包。

<details>
<summary><strong>1.1.5.1 更新摘要</strong></summary>

- PC 画面：改进画面翻转处理及诊断。
- RDP：改进凭据、输入、缩放和断线原因展示。
- RustDesk：改进工具栏、监控与文本剪贴板。
- SSH：改进常用命令和会话操作体验。
- 通用体验：改进退出保护、列表避让和鸿蒙快捷键设置。

详细变更及历史版本说明见[使用指南](docs/app-store/USER_GUIDE.md)。设备与协议矩阵验证仍在持续推进。

</details>

---

## 详细功能

从远程办公到服务器维护，各种连接方式共享主机管理入口，并保留适合各自场景的操作工具。

[RDP](#rdp) · [RustDesk](#rustdesk) · [SSH / SFTP](#ssh--sftp) · [VNC](#vnc) · [Moonlight](#moonlight) · [操控与多设备](#操控与多设备) · [数据与安全](#数据与安全)

### RDP

**在鸿蒙设备上使用 Windows 远程桌面。** 适合连接已开启远程桌面服务的 Windows 专业版、企业版或 Windows Server 主机。

- **账号与连接**：基于 FreeRDP / WinPR，支持本地、域、Microsoft / Azure AD 凭据；连接前进行证书预检，也可选择不保存账户和密码、每次连接时输入。
- **画面与缩放**：提供远端分辨率与本地查看缩放设置。PC 自动模式结合窗口、屏幕密度与方向适配；服务端支持动态显示控制且会话条件满足时，可随窗口调整远端桌面，能力不可用时保留兼容回退。
- **日常操作**：根据设备和会话能力使用键鼠、触控板或直接触控，配合远程键盘、功能键和自定义组合键操作远端应用。
- **文本与文件**：支持双向纯文本剪贴板，通过共享目录访问文件；显示、音频、输入和共享目录的可用性以当前会话为准。
- **问题定位**：区分连接失败、客户端或网络中断与服务端返回的断线原因，便于反馈时说明问题发生在哪个阶段。

画面大小、远端界面缩放与本地查看比例是不同设置。更详细的适配说明见 [RDP 状态文档](docs/RDP_STATUS.md)。

### RustDesk

**连接其他平台上的远程设备。** 可通过设备 ID 建立连接，也支持按配置使用自建 ID / Relay 服务或直接连接。

- **主机配置**：管理远程设备 ID、认证信息与连接配置；使用自建服务时，按服务端要求配置 ID / Relay 和密钥信息。
- **质量选择**：提供低延迟、均衡和最佳质量选项；编解码与后端监控按当前会话实际生效情况展示。
- **远程操作**：接入视频、音频、键鼠输入与文本剪贴板；手机控制场景包含横竖屏、触控坐标和缩放适配。
- **显示控制**：HarmonyOS PC 可按主机选择画面翻转方式。实验多画布模式可同时查看最多两块远端显示器，异常时回退到单画布。
- **文件能力**：按已确认的远端会话能力提供文件传输，具体入口与可用状态在连接后展示。

地址簿登录、远程设备在线与中继授权是不同环节；地址簿登录成功并不等于远程会话已经可用。

### SSH / SFTP

**把服务器终端和文件工作区放在一起。** SSH 支持密码、私钥和跳板机配置；首次连接时核对服务器主机指纹。

| 终端工作台 | 文件工作区 |
| :--- | :--- |
| 多标签与多窗格，宽屏下并行处理多个终端 | SFTP 双栏浏览，在本机与远端之间管理文件 |
| 终端搜索、常用命令与配置档案 | 上传、下载、新建目录、重命名与删除 |
| 广播输入、快捷键与独立焦点控制 | 传输中心集中查看进度，进行中的任务可取消 |
| 端口转发与跳板连接配置 | 对保留的部分上传文件，按已确认位置安全续传 |

在手机上，终端保持单任务操作路径；在平板和 PC 上，可利用宽屏布局同时查看多个终端。进入 SSH 会话后，通过顶部文件入口打开 SFTP，终端维护与文件管理可以在同一工作流程中完成。

常用命令可编辑、删除并随时调用；广播输入面向需要向多个终端发送相同内容的场景，执行前应确认目标会话。

### VNC

**连接已有的 VNC 桌面环境。** 添加主机时配置目标地址、端口、安全策略和可选网关。

- **连接预检**：识别 TLS / 明文连接条件，在进入会话前确认服务器身份、证书和凭据。
- **远程桌面**：提供画面、指针与键盘输入，按当前协议能力使用文本剪贴板。
- **操控设置**：接入远程键盘及按协议保存的缩放、滚轮方向等偏好。
- **信任管理**：首次连接或跨设备恢复后，重新核对服务器身份与本机信任提示。

实际加密方式取决于远端 VNC 服务与所选安全策略，配置网关本身不代表连接已经启用 TLS。

### Moonlight

**通过 Sunshine 串流远端应用。** 适合希望从鸿蒙设备访问主机应用、使用音视频串流与控制器输入的场景。

1. 在远端准备 Sunshine，发现或手动添加主机。
2. 核对主机身份并完成 PIN 配对。
3. 从应用目录中选择项目，启动串流会话。

会话支持画面、声音，以及按设备能力提供的键鼠、触控和控制器输入；同时管理重连、前后台恢复和画中画。退出时区分“仅断开连接”与“结束主机应用”，便于按需要保留远端运行状态。

Moonlight 的定位是音视频与输入串流，文件操作请使用 SSH / SFTP、RDP 共享目录或其他协议明确支持的入口。

## 操控与多设备

RemoteDesktop 使用原生 ArkTS / ArkUI 界面，按窗口与设备形态组织内容。

| 设备 | 使用体验 |
| :--- | :--- |
| **Phone** | 面向触控的主机与会话入口、远程键盘和手势；SSH 保持单任务操作路径 |
| **Pad** | 利用更宽的空间展示主机、终端和文件内容，并结合触控与外接键鼠使用 |
| **PC** | 物理键鼠、响应式窗口、宽屏多窗格终端，以及远程桌面的分辨率和缩放控制 |

**键盘与输入**：图形协议提供远程键盘入口，可切换 Windows / macOS 键位，发送功能键、导航键与自定义组合键。系统输入法支持中文、Emoji 和大段文字，实际输入效果受目标系统、应用与协议能力影响；SSH 使用独立的终端输入体系。

**画面与偏好**：RDP、RustDesk、VNC 与 Moonlight 可分别保存双指缩放偏好；五种协议可分别设置滚轮方向。会话控制区提供恢复画面状态的入口，SFTP 文件列表保持系统滚动方向。

**后台与画中画**：远程会话接入后台连接、系统媒体播控和返回应用后的画面恢复。有真实视频且设备支持时可使用画中画；后台持续运行仍受系统电量策略、窗口状态、用户开关与权限影响。

**引导与退出**：首次使用教程按设备形态介绍操作方式，之后可从“设置 → 教程”重新查看。会话提供退出保护设置，可关闭快捷退出并保留明确的退出按钮。

## 文件与剪贴板

不同协议提供的文件入口各有侧重，连接成功后还需等待对应会话能力就绪。

| 协议 | 文件操作 | 文本协作 |
| :--- | :--- | :--- |
| **RDP** | 通过共享目录提供文件访问 | 双向纯文本剪贴板 |
| **RustDesk** | 按远端会话能力提供文件传输 | 双向纯文本剪贴板 |
| **SSH / SFTP** | 双栏浏览、上传下载、目录管理与传输取消 | 使用独立的终端输入、复制与粘贴路径 |

RDP 与 RustDesk 的文本同步包含长度限制和回环保护；这些入口描述的是纯文本同步。VNC 的文本剪贴板按会话能力开放，Moonlight 不提供远端文件传输。

SFTP 上传或下载开始后，可在传输状态区域取消任务；保留在远端的部分上传文件支持按已确认位置安全续传。更完整的操作步骤见[文件传输与剪贴板说明](docs/app-store/USER_GUIDE.md#五文件传输与剪贴板)。

## 数据与安全

### 密钥库与验证器

密钥库用于管理 SSH 私钥，TOTP 验证器用于管理一次性验证码；添加验证器记录时，可扫描二维码或手动输入标准 `otpauth` 信息。设置页提供验证器隐私保护、主机安全锁与凭据显示控制。

应用支持以本地主密码派生密钥，使用 AES-256-GCM 保护敏感数据，并集成 HUKS / 生物认证能力。主密码需要妥善保管；遗失后无法找回，也无法据此恢复已加密数据。

### 离线与账号隔离

离线模式与每个已验证的华为账号使用独立的本地数据库。离线模式不上传业务数据；切换账号时会停止旧同步任务并清理敏感缓存，避免将不同账号的数据混在一起。

### 按需云同步

登录华为账号并完成云服务前置配置后，可选择需要同步的数据类型，执行上传或下载；同步流程提供失败重试、下载回滚和异常恢复。

启用并解锁应用加密后，受保护的敏感字段会在本机加密后上传。未启用加密时，明确选择保存和同步的部分凭据可能以未加密形式保存或同步，请根据设置提示选择。导入本地备份后，需要明确选择一次“上传本机”或“下载云端”；只传输勾选的数据类型。

### 本地备份与恢复

备份提供导出、导入前预检、完整性检查与事务恢复，无效备份不会覆盖现有数据，恢复失败时会回滚。当前备份默认不导出登录令牌、密码、私钥、TOTP 密钥与设备信任，因此恢复主机记录后，部分认证信息仍需重新配置。

备份仍可能包含敏感信息，请存放在可信位置。数据处理说明见[隐私政策](docs/app-store/PRIVACY_POLICY.md)，安全问题报告方式见[安全政策](SECURITY.md)。

## 连接准备与常见问题

<details>
<summary><strong>第一次使用，需要在远端准备什么？</strong></summary>

| 连接方式 | 远端准备 |
| :--- | :--- |
| RDP | 支持作为远程桌面服务端的 Windows 系统、已开启的远程桌面服务及相应账号 |
| RustDesk | 可用的远程客户端及设备 ID / 认证信息；自建服务另需核对 ID / Relay 与密钥配置 |
| SSH / SFTP | 已启用的 SSH 服务与账号、密码或私钥；需要跳板时配置对应连接路径 |
| VNC | 已启用的 VNC 服务，明确端口、认证方式与安全策略 |
| Moonlight | 已准备的 Sunshine 主机，以及首次连接所需的 PIN 配对 |

添加主机后按界面核对远端身份。协议端口与网络可达性以实际服务配置为准。

</details>

<details>
<summary><strong>连接成功了，为什么剪贴板或文件入口还不可用？</strong></summary>

桌面连接、文本剪贴板与文件传输是不同能力。先确认已启用对应协议设置，再等待会话能力显示为就绪；远端服务不支持的功能不会因连接成功而自动具备。Moonlight 会话中的文件操作需要改用 SFTP 等入口。

</details>

<details>
<summary><strong>画面大小不合适，或触控方式不习惯？</strong></summary>

先确认当前协议的远端分辨率、本地查看缩放与输入模式。RDP 的远端界面大小和本地缩放相互独立；图形协议可根据设备能力选择触控板、直接触控或键鼠。缩放和滚轮方向按协议保存，调整一个协议不会代替其他协议的设置。

</details>

<details>
<summary><strong>如何反馈连接失败或画面问题？</strong></summary>

在 [Issues](https://github.com/Mydstiny/RemoteDeskHarmonyOS/issues) 或应用“设置 → 反馈”中说明应用版本、协议、设备类型、远端软件、操作步骤与错误阶段。应用支持脱敏诊断导出；分享前仍应检查并移除凭据、主机地址、证书、令牌和用户数据。

应用反馈页也提供畅联群聊二维码入口，可获取当前二维码并保存到相册。安全漏洞请使用[私密报告渠道](SECURITY.md)。

</details>

## 原生界面，多协议内核

```text
                     ArkTS · ArkUI
                页面 / 组件 / 响应式交互
                           │
               服务 · 策略 · 本地数据 · 云同步
                           │
                      NAPI / FFI
                           │
       ┌─────────┬─────────┼─────────┬──────────┐
     FreeRDP   RustDesk   libssh2    VNC     Moonlight
       RDP     Rust FFI   SSH/SFTP           Sunshine
       └─────────┴─────────┼─────────┴──────────┘
                  渲染 · 音频 · 输入桥接
```

原生库覆盖 **ARM64 / x86_64**。开发基准为 **API 26**，应用兼容目标与 native ABI 工具链分别核对；具体环境与构建步骤见[开发指南](docs/DEVELOPMENT.md)。

## 文档与参与

| 我想… | 入口 |
| :--- | :--- |
| 了解使用方法与版本变化 | [用户指南](docs/app-store/USER_GUIDE.md) |
| 搭建环境、查看架构与构建命令 | [开发与构建](docs/DEVELOPMENT.md) |
| 在 Windows / macOS 间协作 | [跨设备工作流](docs/CROSS_DEVICE_GITHUB_WORKFLOW.md) |
| 贡献代码或改进文档 | [贡献指南](CONTRIBUTING.md) |
| 提交问题或功能建议 | [GitHub Issues](https://github.com/Mydstiny/RemoteDeskHarmonyOS/issues) |
| 私密报告安全问题 | [安全政策](SECURITY.md) |
| 了解隐私与数据处理 | [隐私政策](docs/app-store/PRIVACY_POLICY.md) |

欢迎贡献文档、问题复现和改进建议。反馈时请说明协议、设备类型、版本与复现步骤，并移除凭据、主机地址、证书和用户数据。

## 开源与致谢

项目自有组合发行版采用 **[AGPL-3.0-or-later](LICENSE)**。感谢 FreeRDP / WinPR、RustDesk、libssh2、Moonlight、FFmpeg、OpenSSL、Mbed TLS、Opus 及其他上游项目；各依赖保留自己的许可证与分发条件。

[第三方声明](THIRD_PARTY_NOTICES.md) · [NOTICE](NOTICE) · [许可证文本](LICENSES/) · [SPDX SBOM](docs/compliance/SBOM.spdx.json) · [对应源码](docs/compliance/SOURCE_OFFER.md) · [网络源码提供政策](docs/compliance/AGPL_NETWORK_SOURCE_OFFER_POLICY.md)

---

<div align="center">
<sub>RemoteDesktop · 让远程工作，融入鸿蒙日常。</sub>
</div>
