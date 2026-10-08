# Pro 反馈群二维码

Pro 反馈入口使用两个独立的 HTTPS 清单，应用只有在当前账号的 `pro.lifetime` 权益有效时才显示：

- 畅联群：`https://lijiong.online/feedback/pro-chanlian.json`
- QQ 群：`https://lijiong.online/feedback/pro-qq.json`

两个清单都沿用反馈页的轮换格式，包含 `version`、`issuedAt`、`expiresAt`、`qrImageUrl`、`joinUrl`、`title`、`notice`、`imageSha256` 和 `imageBytes`。二维码和清单由服务器的 Hexo `source/feedback/` 生成到 `public/feedback/`；应用只接受 `lijiong.online/feedback/` 下的 HTTPS 资源，并在显示、刷新、保存前复核 Pro 权益和清单版本。

2026-10-01 发布的资源为 `pro-chanlian-20261001-01.jpg` 和 `pro-qq-20261001-01.jpg`，有效期至 2026-10-08。QQ 群号为 `1095800223`。二维码是公开入群凭证，轮换时应让旧二维码在对应平台失效；不要把 SSH 凭据或其他私密信息写入清单或图片。
