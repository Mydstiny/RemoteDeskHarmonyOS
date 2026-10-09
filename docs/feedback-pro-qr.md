# Pro 反馈群二维码

Pro 反馈入口只使用 QQ 群 HTTPS 清单，应用只有在当前账号的 `pro.lifetime` 权益有效时才显示：

- QQ 群：`https://lijiong.online/feedback/pro-qq.json`

清单沿用反馈页格式，包含 `version`、`issuedAt`、`expiresAt`、`permanent`、`qrImageUrl`、`joinUrl`、`title`、`notice`、`imageSha256` 和 `imageBytes`。QQ 清单用 `permanent: true` 和 `expiresAt: 0` 表示长期有效；二维码和清单由服务器的 Hexo `source/feedback/` 生成到 `public/feedback/`。

2026-10-09 更新的 QQ 清单继续使用 `pro-qq-20261001-01.jpg`，标记为长期有效；需要更换二维码时上传新图片并生成新版本清单。QQ 群号为 `1095800223`。二维码是公开入群凭证；不要把 SSH 凭据或其他私密信息写入清单或图片。
