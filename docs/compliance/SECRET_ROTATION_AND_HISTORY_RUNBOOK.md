# Secret rotation and history runbook

2026-07-13 审计确认旧历史中跟踪过非占位 AGConnect `client_secret` 与
`api_key`。公开迁移按以下顺序执行：

1. 在 AGConnect 控制台撤销并重新生成相关凭据；检查 OAuth/API 配额。
2. 用新凭据完成私有构建与云功能验证，但不把值写入 Git。
3. 从新公开根提交移除真实配置，并强制替换公开分支/旧 tags。
4. 保存旧历史的本地受控 bundle 仅用于审计；不创建公开备份 ref。
5. 记录轮换时间、负责人和验证结果（不得记录值）。

GitHub 缓存、fork 或既有克隆无法通过 force-push 撤回，因此第 1 步是
硬性要求。删除文件或重写历史不能视为凭据已安全。
