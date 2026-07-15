# RustDesk Domain Resolution Design

## Goal

让 RustDesk FFI 的 ID/Rendezvous、Relay、直连和文件传输连接路径可靠支持域名、IPv4 和 IPv6，同时把解析失败与 TCP 连接失败以阶段化错误返回给 ArkTS/UI。API 地址保持可选，不参与普通远程连接。

## Root cause

当前 `rustdesk_ffi` 在多个位置把 `host:port` 直接解析为 `SocketAddr`。Rust 的 `SocketAddr` 解析只接受字面量地址，不执行 DNS 解析，因此 `hbbs.example.com` 和 `hbbr.example.com` 会在 TCP 建立前失败。`RendezvousConnecting` 的状态来自 ID 服务器连接阶段；Relay 解析也存在相同缺陷。

## Design

新增一个小型网络连接模块，使用 `ToSocketAddrs` 将 host/port 解析为一个或多个候选 `SocketAddr`，在共享 deadline 内逐个调用 `TcpStream::connect_timeout`。模块负责：

- 接受独立的 host + port，以及 Relay 响应中可能携带端口的 endpoint 字符串；
- 拒绝 `http://`、`https://`、路径和空 endpoint，并返回 `InvalidInput`；
- 支持域名、IPv4、IPv6 和 IPv6 bracket 形式；
- 尝试所有 DNS 候选地址，返回包含阶段、host、port 和底层错误的诊断；
- 不记录密码、服务器 Key 或 API 凭据。

现有 RendezvousClient 的 ID 连接、Relay 连接和 Connector 直连全部调用该模块。协议握手、Key、密码、API 字段和状态机顺序不改变。

## Error handling

错误阶段至少区分 `rendezvous resolve/connect`、`relay resolve/connect` 和 `direct resolve/connect`。FFI 继续通过 `rustdesk_last_error` 暴露完整错误，UI 可以据此提示地址格式、端口不可达或网络路由问题。

## Tests

回归测试先验证现有实现对 `localhost` 的失败，再验证修复后：

- Rendezvous 使用域名连接本地 listener；
- Relay endpoint 使用域名和显式端口连接本地 listener；
- direct endpoint 使用域名连接本地 listener；
- 无效 URL 形式被拒绝；
- IPv4/IPv6 endpoint 解析保持可用；
- 多候选地址在首个候选失败后继续尝试。

## Acceptance

- `cargo test --manifest-path rustdesk_ffi/Cargo.toml --no-default-features` 通过（88/88）；
- 本机默认 `opus-audio` host 链接仍受缺少 `-lopus` 影响，OHOS HAP 构建已使用项目实际 native 链路通过；
- 受影响 HarmonyOS native 测试通过；
- `assembleHap`、`default@OhosTestCompileArkTS` 和 Light 合规门通过；
- 真机使用 `hbbs`/`hbbr` 域名完成首次连接、重连和 Relay 连接验证仍待设备环境执行。
