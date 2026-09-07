# RustDesk 控制端与服务器控制面

核验快照：2026-09-07，`0000d4ca4`。本项目包含 OHOS 适配和 Rust FFI，不因使用官方协议就自动具备官方全部功能或鸿蒙被控端权限。

## 链路与证据

[RustDeskHostConfigPolicy.ets](../../../../../entry/src/main/ets/services/RustDeskHostConfigPolicy.ets) → [ExtensionLoader.ets](../../../../../entry/src/main/ets/services/ExtensionLoader.ets) → [rustdesk_bridge.cpp](../../../../../entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp) → [lib.rs](../../../../../rustdesk_ffi/src/lib.rs) / [connector.rs](../../../../../rustdesk_ffi/src/connector.rs) / [peer_stream.rs](../../../../../rustdesk_ffi/src/peer_stream.rs)。

查 host-list 预认证与直接连接的全部入口；显示设置正确不代表所有入口传递一致。`rg -n 'SupportedDecoding|H265|codec' rustdesk_ffi/src` 定位协商与帧类型，不比较不同结构中的裸 codec 数字。

## 编码与画质案例

修复 `15632691b` 将已保存显式 H.265 从预认证路径传至 native 配置；AUTO 仍保留原兼容策略。

当前 FFI request 的 `codec=5` 表示 H.265，而 frame snapshot 的 `codec=1` 表示 H.265。这是两套枚举，来源为 `rustdesk_ffi/src/lib.rs` 的配置与帧结构。修改前重新核对 ABI，不能推广到别的协议。

协商细节看 [session.rs](../../../../../rustdesk_ffi/src/protocol/session.rs) 的 `supported_decoding`；实际 HUD 对齐看 [RustDeskDiagnosticsPolicy.ets](../../../../../entry/src/main/ets/services/RustDeskDiagnosticsPolicy.ets) 和 [RustDeskDiagnosticsHud.ets](../../../../../entry/src/main/ets/components/RustDeskDiagnosticsHud.ets)。

诊断分别记录 preferred/requested、negotiated/actual frame、hardware decoder active。HUD 若只是显示偏好，不能宣称正在 H.265 硬解。

## 数据面生命周期

- [control_inbox.rs](../../../../../rustdesk_ffi/src/control_inbox.rs)：队列接收成功之后，还要证明 live loop 消费并发送。
- [peer_stream.rs](../../../../../rustdesk_ffi/src/peer_stream.rs)：TCP/UDP/KCP 各自 framing、取消、partial read 和背压。不要用每次超时重新 `read_exact` 的简化方式丢掉已读取帧段。
- [rustdesk_ffi_lifetime_policy.h](../../../../../entry/src/main/cpp/rustdesk/rustdesk_ffi_lifetime_policy.h)、[rustdesk_ffi_handle_gate.h](../../../../../entry/src/main/cpp/rustdesk/rustdesk_ffi_handle_gate.h)：FFI handle 的调用与释放边界。
- [rustdesk_display_switch_gate.h](../../../../../entry/src/main/cpp/rustdesk/rustdesk_display_switch_gate.h)：显示器切换后的旧帧、尺寸、input target 与 generation。
- 手机/Android 方向、桌面手动翻转和多画布预览分开；读 [RustDeskMultiCanvasPreviewPolicy.ets](../../../../../entry/src/main/ets/services/RustDeskMultiCanvasPreviewPolicy.ets) 与 [渲染输入](../lifecycle-rendering-input.md)。

## 认证与服务器 Pro

RustDesk peer 密码/2FA、relay 信任与 RustDesk Server Pro 登录 token 不可互换。[RustDeskProApiService.ets](../../../../../entry/src/main/ets/services/RustDeskProApiService.ets)、[RustDeskProSyncService.ets](../../../../../entry/src/main/ets/services/RustDeskProSyncService.ets)、[RustDeskProCredentialStore.ets](../../../../../entry/src/main/ets/services/RustDeskProCredentialStore.ets) 负责服务器登录和地址簿控制面。

同步地址簿时核对 scope/route identity 和本地标签、分组、密码、显示偏好的保留；同步时间不证明 host 在线。用户说“本应用买断/商品/订单”则去 [购买权益](../purchase-entitlements.md)。

## 网络与验收

ID、relay、direct、presence、file transfer 各自测试。RustDesk M4 UDP/KCP 代码存在不代表 AUTO/NAT capability 可开放；固定服务端拓扑验收要求见 [网络](../networking.md)。剪贴板正反向、权限恢复、来源回环和监听释放见共享专题。

测试：[RustDeskHostConfigPolicy.test.ets](../../../../../entry/src/test/RustDeskHostConfigPolicy.test.ets)、[RustDeskMultiCanvasPreviewPolicy.test.ets](../../../../../entry/src/test/RustDeskMultiCanvasPreviewPolicy.test.ets)、Rust `cargo test --lib --no-default-features`。OHOS ABI 构建用 [build_rustdesk_ffi_ohos.sh](../../../../../scripts/build_rustdesk_ffi_ohos.sh)，依赖来源看 [UPSTREAM.yml](../../../../../rustdesk_vendor/libs/hbb_common/protos/UPSTREAM.yml) 与 [RUSTDESK_KCP_PROVENANCE.md](../../../../../docs/compliance/RUSTDESK_KCP_PROVENANCE.md)。

历史：[2026-07-29-rustdesk-control-plane-official-parity-complete-plan-v3.md](../../../../../docs/superpowers/plans/2026-07-29-rustdesk-control-plane-official-parity-complete-plan-v3.md)、[2026-08-29-rustdesk-quality-and-multimonitor-completion.md](../../../../../docs/codex/plans/2026-08-29-rustdesk-quality-and-multimonitor-completion.md)。
