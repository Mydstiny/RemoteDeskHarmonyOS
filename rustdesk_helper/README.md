# rustdesk_helper — RustDesk IPC Helper 进程

## 用途

独立进程, 通过 Unix Domain Socket IPC 与主应用通信。
主应用不链接 RustDesk core → AGPL 许可证隔离。

## 架构

```
RemoteDesktop 主应用 (Apache-2.0 / 闭源)
  │
  ├── RustDeskBridge (IPC client)
  │     └── Unix Domain Socket (/data/local/tmp/rustdesk_helper.sock)
  │
  └── [进程边界]
  
rustdesk_helper (AGPL-3.0)
  ├── IPC server → 帧解析
  └── RustDesk core → 网络/协议/编解码
```

## 编译 (OHOS)

```bash
# 安装 OHOS Rust target
rustup target add aarch64-unknown-linux-ohos

# 编译
cargo build --release --target aarch64-unknown-linux-ohos

# 部署
hdc file send target/aarch64-unknown-linux-ohos/release/rustdesk_helper /data/local/tmp/
hdc shell "chmod +x /data/local/tmp/rustdesk_helper"
```

## 部署

1. 在设备上启动 helper: `hdc shell "/data/local/tmp/rustdesk_helper &"`
2. 启动主应用, RustDeskBridge 自动连接 IPC socket

## AGPL 合规

- rustdesk_helper 以 AGPL-3.0 开源
- 主应用通过 IPC 通信, 不链接 RustDesk core
- 符合 "aggregate" 条款 — 独立进程不触发 copyleft 传染

## TODO

- [ ] 集成真实 RustDesk core (crate/git dependency)
- [ ] TLS/加密 IPC channel
- [ ] Frame streaming (视频帧 IPC 转发)
- [ ] NAT traversal / relay 配置
