# RDP 当前状态

更新时间：2026-08-29

## 运行架构

生产构建默认启用真实 FreeRDP 3.x：

```text
RemoteDesktop.ets
  → ExtensionLoader.ets
  → extension_loader_napi.cpp
  → FreeRdpAdapter
  → FreeRDP / WinPR 双 ABI静态依赖
  → GDI/GFX → 共享 EGL/XComponent 渲染器
```

`USE_REAL_FREERDP=OFF` 只保留为不含真实协议能力的编译骨架，不是发布路径。
arm64-v8a 与 x86_64 的发布预编译位于 `libs/freerdp-ohos/`，由
`scripts/build_freerdp_ohos.sh all` 可复现生成。

## 高 DPI 与窗口适配契约

- `自动匹配窗口` 使用 XComponent 实际内容区比例，不再把 PC 会话强制为横屏。
- 连接前尚未协商 Display Control 时，自动模式按 100/140/180 目标界面倍率等比降低
  远端逻辑分辨率，优先保证旧 Windows Server 和不支持动态布局的主机字体可读。
- 收到 `DisplayControlCaps` 后，客户端升级为物理像素分辨率，并通过 RDP monitor layout
  同时发送物理尺寸、方向、DesktopScaleFactor 和 DeviceScaleFactor。
- `远端界面大小` 分为自动、标准、大、特大；它与 Fit/100%/125%/手势缩放等本地查看
  变换相互独立，且作为 device-local 偏好保存。
- 自动模式保持完整画面和等比例，不用裁切、拉伸掩盖黑边；固定预设比例不匹配时仍可能
  留边，并明确属于用户选择的远端桌面尺寸。

## 动态分辨率

FreeRDP 预编译已启用 `drdynvc`、`disp`、`rdpdr` 和 `drive` 客户端。动态布局只在
桌面设备、前台 RDP、自动分辨率、非 PIP 且服务端 caps 就绪时开放：

- ArkTS 稳定窗口防抖 500 ms；native 再执行 500 ms 最小发送间隔。
- 单请求在途，拖窗期间保留最新请求；5 秒没有桌面 resize 回包才允许超时恢复。
- 后台、PIP、surface 转移、偏好变化、断线和重连都会取消尚未发送的旧请求。
- 发送失败只关闭本次会话的动态能力，不断开现有 RDP；用户可在重连后按新窗口适配。
- `cbDesktopResize` 仍复用既有 GDI/GFX、frame pump、renderer source 和输入 viewport
  事务，诊断区分 requested、effective、applied、server_adjusted 与 fallback。

## 共享盘与供应链

后连接共享盘使用 FreeRDP 公开的 `RdpdrClientContext::RdpdrRegisterDevice`，不再依赖
未落入源码基线的私有桥接符号。构建脚本会强制检查 `drive_DeviceServiceEntry`、
`disp_DVCPluginEntry` 和 `rdpdr_VirtualChannelEntryEx`，并在任一缺失时失败。

来源、构建选项和归档策略见 `docs/compliance/FREERDP_OHOS_PROVENANCE.md`；精确 SHA-256
见 `docs/compliance/THIRD_PARTY_ARTIFACTS.sha256`。

## 当前验证边界

策略、ArkTS/NAPI 契约、native 状态机、双 ABI真链接、预编译哈希和 Light 合规均有自动化
门禁。仍需在真实 HarmonyOS PC + Windows 10/11/Server 环境完成全屏、分屏、自由窗口、
100/140/180 字体、连续拖窗、PIP、后台恢复、重连及输入映射验收；没有该外部矩阵证据前，
不得把“用户现场问题已完全关闭”写成事实。
