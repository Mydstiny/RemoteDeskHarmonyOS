# 生命周期、渲染与输入

核验快照：2026-09-07，`0000d4ca4`。本文件总结当前策略和历史修复；具体设备结果从共享队列/报告读取。

## 排查顺序

记录协议、设备类型、系统/应用版本、窗口模式、前后台步骤、编码/decoder、首次发生时机。先判断连接、解码、画面提交、输入映射哪一段失效。

沿 owner/session generation → surface generation → decoder binding → renderer → geometry → input gate 检查。重连可能清除现场；如果需要矩阵和代次证据，先完成用户授权的脱敏导出。

## 黑屏、恢复、PIP

- 先查 [RemoteForegroundRestorePolicy.ets](../../../../entry/src/main/ets/services/RemoteForegroundRestorePolicy.ets)、[RemoteSessionPipLifecyclePolicy.ets](../../../../entry/src/main/ets/services/RemoteSessionPipLifecyclePolicy.ets) 和 [decoder_pipeline_lifecycle_policy.h](../../../../entry/src/main/cpp/render/decoder_pipeline_lifecycle_policy.h)。
- 转场开始与终止是不同状态。确认 detach、callback admission、frame pump 退出、decoder/renderer 释放，再接管新 surface。
- 异步 disconnect 已提交不等于 native 已终止；使用 [RemoteSessionTerminationPolicy.ets](../../../../entry/src/main/ets/services/RemoteSessionTerminationPolicy.ets) 和 native 回执释放 registry。
- RDP 恢复还要看 frame ownership、damage、scheduler、upload gate；不能只要求服务端发关键帧解决所有黑屏。

证据：[pip-rustdesk-restore-rdp-startup-investigation-2026-07-23.md](../../../../docs/test-results/pip-rustdesk-restore-rdp-startup-investigation-2026-07-23.md) 是历史设备记录，不能替代本次验收。

## 翻转与坐标

[hw_decoder.cpp](../../../../entry/src/main/cpp/render/hw_decoder.cpp)、[gl_renderer.cpp](../../../../entry/src/main/cpp/render/gl_renderer.cpp)、[RustDeskDesktopFlipPolicy.ets](../../../../entry/src/main/ets/services/RustDeskDesktopFlipPolicy.ets)、[MoonlightDesktopFlipPolicy.ets](../../../../entry/src/main/ets/services/MoonlightDesktopFlipPolicy.ets) 是入口。

检查 producer 原始矩阵、decoder 已应用矩阵、renderer 手动变换、presentation mode，以及相关实例代次是否属于同一帧/会话。区分远端方向变化、native buffer 变换与用户手动翻转。不要全局添加 `flip_y` 修补某台设备。

视觉变换后，绝对坐标和相对 delta 必须匹配。验收包含正常/翻转画面与正常/翻转控制组合，窗口 resize/恢复和软硬解路径。JSONL schema/字段以 [DiagnosticCapturePolicy.ets](../../../../entry/src/main/ets/services/DiagnosticCapturePolicy.ets) 当前实现为准，历史 schema v4 不应永久硬编码到新工具。

## 全屏与鼠标偏移

RDP 案例 `58ac524ab`：pipeline bind 会初始化本地 renderer 尺寸，之后必须重新发布远端权威桌面 geometry。入口 [RdpPipelineGeometryReplayPolicy.ets](../../../../entry/src/main/ets/services/RdpPipelineGeometryReplayPolicy.ets)，测试 [RdpPipelineGeometryReplayPolicy.test.ets](../../../../entry/src/test/RdpPipelineGeometryReplayPolicy.test.ets)。

最终变换入口是 `RemoteDesktop.currentRemoteSurfaceTransform` / `mapInputPointWithTransform` 和 [RemoteSurfaceTransformPolicy.ets](../../../../entry/src/main/ets/services/RemoteSurfaceTransformPolicy.ets)。

检查 remote source size、content rect、letterbox/pan/zoom、density、rotation、最终 input transform。对比四角、中心、边界与全屏切换后的坐标。先证实失配层，不直接乘以固定 2 或 4。

## 焦点、键盘、IME、剪贴板

| 问题 | 入口与检查 |
|---|---|
| Dock 最小化触发远端输入 | [RemoteInputGuardPolicy.ets](../../../../entry/src/main/ets/services/RemoteInputGuardPolicy.ets)：焦点/可见性与事件代次 |
| 鼠标点击反复抢焦点 | [RemotePointerFocusPolicy.ets](../../../../entry/src/main/ets/services/RemotePointerFocusPolicy.ets)：只在需要恢复时申请 focus |
| 按键粘连、系统快捷键 | [HarmonyShortcutCaptureService.ets](../../../../entry/src/main/ets/services/HarmonyShortcutCaptureService.ets)、[HarmonyShortcutBlockingPolicy.ets](../../../../entry/src/main/ets/services/HarmonyShortcutBlockingPolicy.ets)：设备/协议设置、按下释放和切换清理 |
| IME 重复/丢字 | [RemoteImeSessionPolicy.ets](../../../../entry/src/main/ets/services/RemoteImeSessionPolicy.ets)：输入会话、composition 与物理键路由 |
| 剪贴板仅单向或循环 | [ClipboardBridgeService.ets](../../../../entry/src/main/ets/services/ClipboardBridgeService.ets)、[ClipboardSyncPolicy.ets](../../../../entry/src/main/ets/services/ClipboardSyncPolicy.ets)：权限、订阅、来源与回环抑制 |
| 缩放/滚轮差异 | [RemoteWheelPolicy.ets](../../../../entry/src/main/ets/services/RemoteWheelPolicy.ets)、[RemoteCanvasPinchInputPolicy.ets](../../../../entry/src/main/ets/services/RemoteCanvasPinchInputPolicy.ets)：协议/设备选择与 transform |

设置的首次默认、已保存值、损坏值和读取失败不是同一种状态。沿当前 policy 验证，避免读取失败覆盖运行中设置。

## 回归选择

查同名 `entry/src/test/*.test.ets` 与 `entry/src/main/cpp/test/*_test.cpp`。测试纯策略后执行强制 Hvigor 双门禁；最后由受影响设备完成前后台、PIP、窗口 resize、输入释放和视觉证明。自动化通过不替代这一步。
