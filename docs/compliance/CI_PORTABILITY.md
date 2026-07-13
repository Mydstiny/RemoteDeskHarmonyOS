# CI portability

GitHub Actions、本地 release 机与其他 CI 都必须调用
`scripts/verify_open_source_release.ps1`，不得复制更宽松的判断。
普通 push/PR 使用 `Light`；公开二进制和 tag 使用 `Release`，并提供
私有 build profile、双 ABI/HAP/ABI 证据和已验证设备矩阵。
