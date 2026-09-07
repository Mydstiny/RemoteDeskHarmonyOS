# RDP / FreeRDP

核验快照：2026-09-07，`0000d4ca4`。先结合 [共享渲染输入](../lifecycle-rendering-input.md)、[网络](../networking.md)。

## 入口

- ArkTS：[RemoteDesktop.ets](../../../../../entry/src/main/ets/pages/RemoteDesktop.ets) → [ExtensionLoader.ets](../../../../../entry/src/main/ets/services/ExtensionLoader.ets) → [extension_loader_napi.cpp](../../../../../entry/src/main/cpp/extensions/extension_loader_napi.cpp)。
- 原生：[rdp](../../../../../entry/src/main/cpp/rdp)；先 `rg -n '目标符号' entry/src/main/cpp/rdp`，再读具体调用者。
- 上游：[freerdp](../../../../../freerdp) gitlink、[freerdp-ohos](../../../../../patches/freerdp-ohos)、[build_freerdp_ohos.sh](../../../../../scripts/build_freerdp_ohos.sh)。
- 测试：[RdpSessionErrorPolicy.test.ets](../../../../../entry/src/test/RdpSessionErrorPolicy.test.ets)、[RdpPipelineGeometryReplayPolicy.test.ets](../../../../../entry/src/test/RdpPipelineGeometryReplayPolicy.test.ets)、[rdp_display_layout_policy_test.cpp](../../../../../entry/src/main/cpp/test/rdp_display_layout_policy_test.cpp)。

## 易回归契约

| 场景 | 处理要点与证据 |
|---|---|
| 连接时临时账号密码 | [RdpSessionCredentialHandoff.ets](../../../../../entry/src/main/ets/services/RdpSessionCredentialHandoff.ets) 和 [RdpSessionCredentialPolicy.ets](../../../../../entry/src/main/ets/services/RdpSessionCredentialPolicy.ets)：临时凭据与持久 host 分离，重连时核对授权寿命 |
| Gateway/证书预检 | [RdpCertificatePreflightPolicy.ets](../../../../../entry/src/main/ets/services/RdpCertificatePreflightPolicy.ets)、[rdp_gateway_policy.h](../../../../../entry/src/main/cpp/rdp/rdp_gateway_policy.h)：route/身份、取消、证书决策交接必须与正式连接一致 |
| 全屏、动态分辨率 | [RdpAdaptiveDisplayPolicy.ets](../../../../../entry/src/main/ets/services/RdpAdaptiveDisplayPolicy.ets)、[RdpPipelineGeometryReplayPolicy.ets](../../../../../entry/src/main/ets/services/RdpPipelineGeometryReplayPolicy.ets)、[rdp_display_layout_policy.h](../../../../../entry/src/main/cpp/rdp/rdp_display_layout_policy.h)：协商结果、source geometry 和 renderer bind 之后重放 |
| 黑屏/帧卡住 | [rdp_frame_pump.cpp](../../../../../entry/src/main/cpp/rdp/rdp_frame_pump.cpp)、[rdp_frame_scheduler.cpp](../../../../../entry/src/main/cpp/rdp/rdp_frame_scheduler.cpp)、[rdp_gl_upload_gate.cpp](../../../../../entry/src/main/cpp/rdp/rdp_gl_upload_gate.cpp)：帧所有权、dirty damage、队列消费、GL 提交各自检查 |
| 退出/重连 | [rdp_teardown_retirement_fence.h](../../../../../entry/src/main/cpp/rdp/rdp_teardown_retirement_fence.h)、[rdp_network_action_gate.h](../../../../../entry/src/main/cpp/rdp/rdp_network_action_gate.h)：终止回执、旧代次拒绝、网络变化 admission |

## 断线错误不能借用其他来源

`0a7559aa7` 的 [RdpSessionErrorPolicy.ets](../../../../../entry/src/main/ets/services/RdpSessionErrorPolicy.ets) 严格区分 native `[E-RDP-ERRINFO-0x...]`、FreeRDP `[E-CONN-0x...]` 和符号诊断。

只有完整合法 ErrorInfo envelope 可归为 server error；不能抓任意十六进制，也不能用服务器 `0x10` 为未知断线兜底。历史现场若缺少 RDP 事件，原始根因保持未确认。引用某个服务器码含义前查当前上游定义/对应官方协议资料。

排障保留 source、code、transport end、network generation、重连时间线；不要把本地 watchdog 包装成 Windows 服务器故障。

## 验证和依赖

检查 `USE_REAL_FREERDP`：[CMakeLists.txt](../../../../../entry/src/main/cpp/CMakeLists.txt) 默认 OFF 的 skeleton 构建不证明真实 FreeRDP 连接。需要实际协议验收时核对真实链接产物、ABI、服务端配置与证书。

上游/patch/gitlink 变化同步 [FREERDP_OHOS_PROVENANCE.md](../../../../../docs/compliance/FREERDP_OHOS_PROVENANCE.md)、NOTICE、SBOM 和 hashes；不要直接修改子模块并漏提 public patch。发布检查见 [验证](../validation.md)。

历史起点：[RDP_STATUS.md](../../../../../docs/RDP_STATUS.md)、[2026-07-30-rdp-freerdp-harmonyos-full-parity-lifecycle-ux-upgrade-plan.md](../../../../../docs/superpowers/plans/2026-07-30-rdp-freerdp-harmonyos-full-parity-lifecycle-ux-upgrade-plan.md)。旧计划的“完成”必须与具体 commit、测试及设备范围对应。
