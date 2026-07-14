# 反馈页畅联群聊二维码维护

反馈页从公开 HTTPS 清单读取二维码，不把二维码图片或邀请链接打包进应用。默认地址为：

`https://lijiong.online/feedback/chanlian.json`

当前线上文件位于 Hexo 站点的 `source/feedback/chanlian-current.jpg` 和 `source/feedback/chanlian.json`，由 `https://lijiong.online/feedback/` 提供。仓库中的 `docs/feedback` 保留为版本化源文件和 GitHub Pages 备用镜像，不发布仓库其他文档。

每次更新群二维码时，替换 `chanlian-current.jpg` 和 `chanlian.json` 中的时间、提示文案。时间戳使用 Unix 毫秒，`expiresAt - issuedAt` 不得超过 7 天：

```json
{
  "issuedAt": 1783987200000,
  "expiresAt": 1784592000000,
  "qrImageUrl": "https://lijiong.online/feedback/chanlian-current.jpg",
  "joinUrl": "",
  "title": "加入 RemoteDesktop 畅联群聊",
  "notice": "二维码每 7 天更新一次，请保存后使用另一台设备扫描。"
}
```

`joinUrl` 是可选项。建议使用华为 App Linking 或你维护的 HTTPS 落地页；畅连没有在公开开发者文档中承诺一个可跨版本使用的群聊 URI，因此应用只在清单提供该链接时尝试直接跳转，失败后仍可保存二维码扫描。

服务器更新流程：将 `chanlian-current.jpg` 和 `chanlian.json` 上传到 Hexo 的 `source/feedback/`，在 `/www/wwwroot/hexo` 执行 `npm run build`。更新后验证 `https://lijiong.online/feedback/chanlian.json` 和图片地址均返回 200。GitHub Pages 工作流仍可作为海外备用镜像，但不再是客户端主地址。

二维码是公开入群凭证，不要把管理员口令、私有 API token 或其他敏感信息写入图片、JSON 或仓库。旧图片虽然不再由当前路径引用，但仍可能存在 Git 历史中；因此每次轮换后应让畅连侧的旧二维码立即失效，并保持 7 天上限。
