# VNC / RFB

核验快照：2026-09-07，`0000d4ca4`。

## 入口和协议边界

[VncSettingsPage.ets](../../../../../entry/src/main/ets/pages/VncSettingsPage.ets)、[RemoteDesktop.ets](../../../../../entry/src/main/ets/pages/RemoteDesktop.ets)、[vnc_adapter.cpp](../../../../../entry/src/main/cpp/vnc/vnc_adapter.cpp)。

VNC 的 repeater/gateway、TLS、密码和显示/输入契约独立于 RDP Gateway 与 RustDesk relay。网关协议以 [VNC_GATEWAY_PROTOCOL.md](../../../../../docs/VNC_GATEWAY_PROTOCOL.md)、[VncGatewayProtocolPolicy.ets](../../../../../entry/src/main/ets/services/VncGatewayProtocolPolicy.ets) 为依据，不能互相套用端口或握手。

## 认证与设置

- [VncTrustService.ets](../../../../../entry/src/main/ets/services/VncTrustService.ets)、[VncCertificatePreflightPolicy.ets](../../../../../entry/src/main/ets/services/VncCertificatePreflightPolicy.ets)、[VncCertificateDecisionHandoff.ets](../../../../../entry/src/main/ets/services/VncCertificateDecisionHandoff.ets)：证书决策绑定当前 endpoint、owner、generation 和连接，不能绕过变化提示。
- [VncSessionCredentialHandoff.ets](../../../../../entry/src/main/ets/services/VncSessionCredentialHandoff.ets) 与 [VncSecretStoragePolicy.ets](../../../../../entry/src/main/ets/services/VncSecretStoragePolicy.ets)：临时密码与记住密码的持久化分别处理。
- [VncSessionSettingsPolicy.ets](../../../../../entry/src/main/ets/services/VncSessionSettingsPolicy.ets)、[VncHostListProjectionPolicy.ets](../../../../../entry/src/main/ets/services/VncHostListProjectionPolicy.ets)：独立设置、旧记录投影、主机卡行为和云选择一起核对。

## 光标与滚轮案例

[VncPhysicalWheelPolicy.ets](../../../../../entry/src/main/ets/services/VncPhysicalWheelPolicy.ets) 用 scrollStep 等证据区分物理鼠标与连续触控板流，并维护余量/方向/空闲重置。平台报告 source=MOUSE 不足以将所有事件当离散鼠标；不以一个固定 raw divisor 适配所有设备。

复核 Axis begin/end/cancel、方向反转、稀疏样本和持续流。[RemoteWheelPolicy.ets](../../../../../entry/src/main/ets/services/RemoteWheelPolicy.ets) 的协议偏好不能修改原始设备分类。

光标形状、hotspot、远端尺寸、缩放/pan 与本地指针模式分别检查；显示正确不证明点击命中。历史：[2026-08-27-vnc-wheel-input-normalization.md](../../../../../docs/codex/plans/2026-08-27-vnc-wheel-input-normalization.md)、[2026-08-27-vnc-cursor-wheel-regression.md](../../../../../docs/codex/plans/2026-08-27-vnc-cursor-wheel-regression.md)。

## 验证

查 [VncCertificatePreflightPolicy.test.ets](../../../../../entry/src/test/VncCertificatePreflightPolicy.test.ets)、[VncTrustService.test.ets](../../../../../entry/src/test/VncTrustService.test.ets)、[VncSharedPreferencePolicy.test.ets](../../../../../entry/src/test/VncSharedPreferencePolicy.test.ets)、[vnc_adapter_network_recovery_test.cpp](../../../../../entry/src/main/cpp/test/vnc_adapter_network_recovery_test.cpp)。实际覆盖 RFB server 类型、认证方式、直连/repeater/TLS、Phone/Pad/PC、鼠标/触控板、前后台、网络切换。

来源补充：[2026-08-01-vnc-certificate-settings-relay-complete-repair-plan-v3.md](../../../../../docs/superpowers/plans/2026-08-01-vnc-certificate-settings-relay-complete-repair-plan-v3.md)。计划标题中的 complete 不等于全部服务端/设备矩阵通过。
