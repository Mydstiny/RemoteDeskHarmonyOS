# Dependency update policy

依赖更新必须锁定来源修订和 SHA-256，更新第三方 notice/SBOM，检查许可证
兼容性，并重跑相关 ABI、构建和设备矩阵。RustDesk proto、FreeRDP、
FFmpeg 配置与静态库更新属于高风险变更，禁止仅以“构建成功”批准。
