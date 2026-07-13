# RemoteDeskHarmonyOS

HarmonyOS NEXT 原生远程桌面客户端，支持 RDP、RustDesk、SSH/SFTP 与
VNC，并包含云同步、主机安全锁、后台实况与多端响应式界面。

## License and source

项目自有组合发行版采用 **AGPL-3.0-or-later**。FreeRDP、OpenSSL、
FFmpeg、libssh2、Mbed TLS、Opus、Rust crates 与 Huawei/OpenHarmony
包保留各自许可证。请阅读 `LICENSE`、`NOTICE`、
`THIRD_PARTY_NOTICES.md` 和 `docs/compliance/SBOM.spdx.json`。

每个公开二进制 release 必须对应同名 source tag、发布清单、SBOM 和
完整对应源码。网络交互版本的源码提供策略见
`docs/compliance/AGPL_NETWORK_SOURCE_OFFER_POLICY.md`。

## Secure local configuration

仓库不包含 AGConnect secret、API key、签名口令、证书或本机 SDK 路径。
从 `build-profile.example.json5`、`local.properties.example` 和
`agconnect-services.example.json` 创建本地私有配置；真实值只可来自
本机安全路径或 CI secrets。

## Build

1. 安装 DevEco Studio 与 API 23 SDK。
2. 准备私有根 `build-profile.json5` 和真实（但不跟踪的）
   `entry/src/main/resources/rawfile/agconnect-services.json`。
3. 首次 clean clone 或修改 RustDesk FFI 后，运行
   `scripts/build_rustdesk_ffi_ohos.sh all`。
4. 使用 DevEco 的 Node/Hvigor 执行：

```text
hvigorw.js --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --daemon
```

在提交或自动推送前运行：

```powershell
pwsh -File scripts/verify_open_source_release.ps1 -Mode Light
```

本地钩子安装：`pwsh -File scripts/install_git_hooks.ps1`。GitHub Actions
会再次运行相同门禁；release 还必须通过 clean-clone、双 ABI、HAP、
ABI 与设备矩阵检查。
