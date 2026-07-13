# Contributing

贡献默认以 AGPL-3.0-or-later 提交。提交者必须拥有所提交内容的权利，
保留第三方版权/许可证/NOTICE，并在依赖或构建输入变化时更新 SBOM、
来源修订和哈希。

所有提交使用 `git commit -s`，表示接受 Developer Certificate of
Origin 1.1。不得提交 AGConnect 配置、API key、token、签名材料、真实
主机/账号数据或本机路径。

PR 必须通过开源合规门、相关单元测试、双 ABI（涉及 Rust/native 时）
和生产 HAP 构建。协议、ABI、schema、Preferences、权限与 UI 行为变化
必须独立说明并提供回归证据。
