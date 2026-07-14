# 反馈页畅联群聊二维码维护

反馈页从公开 HTTPS 清单读取二维码，不把二维码图片或邀请链接打包进应用。默认地址为：

`https://mydstiny.github.io/RemoteDeskHarmonyOS/feedback/chanlian.json`

每次更新群二维码时，上传新的图片并替换清单。时间戳使用 Unix 毫秒，`expiresAt - issuedAt` 不得超过 7 天：

```json
{
  "issuedAt": 1783987200000,
  "expiresAt": 1784592000000,
  "qrImageUrl": "https://mydstiny.github.io/RemoteDeskHarmonyOS/feedback/chanlian-20260714.png",
  "joinUrl": "https://example.com/your-huawei-app-linking-url",
  "title": "加入 RemoteDesktop 畅联群聊",
  "notice": "二维码每 7 天更新一次，请保存后使用另一台设备扫描。"
}
```

`joinUrl` 是可选项。建议使用华为 App Linking 或你维护的 HTTPS 落地页；畅连没有在公开开发者文档中承诺一个可跨版本使用的群聊 URI，因此应用只在清单提供该链接时尝试直接跳转，失败后仍可保存二维码扫描。
