# Pro 权益服务

当前实现服务端可信验证的底层链路；尚无启动服务、生产部署或 App 正式授权。继续 M7，不能把此模块作为购买闭环已交付。

- `iap-crypto.mjs`：固定华为 Root CA G2 指纹，OpenSSL 3 完整证书路径/CRL 检查，IAP 非 critical OID，ES256/P1363 签名，以及服务端请求 JWT。
- `huawei-api.mjs`：固定华为 HTTPS 站点、禁用重定向、超时/长度限制、Account Kit 用户凭证与 OAuth Client ID 校验、订单最新状态/通知验证和独立发货确认调用。
- 客户端订单只提供查询引用，不提供可信 owner、商品或权益。账号 owner 与现有 App 的 `ownerScopeIdForUnionId` 使用相同派生规则。
- 本版只接受白名单非消耗型商品。NORMAL 与 SANDBOX 独立配置，最新订单签名限定五分钟新鲜度，实际沙箱联调必须确认该窗口与官方返回兼容。
- 证书 CRL 必须在部署时提供且保持更新；过期/缺失即验证失败。模块不会根据外部证书 URL 自动下载资源，不把签名验证失败当成退款。

运行环境：Node.js 24+、OpenSSL 3（必须支持 `verify -no-CAstore`）。无需 npm 依赖。测试执行 `npm test`；每次用临时生成的测试 CA、叶证书、CRL 和私钥验证真实密码学与撤销路径，结束后清理，仓库不保存测试私钥。

后续接入原子订单台账、购买意图与账号绑定、幂等发货、通知/主动对账、带签名的离线权益以及 App 的购买/恢复协调。生产所需 merchant key、Issuer ID、Key ID、OAuth Client ID、商品 ID、域名和部署资源尚未配置，不写入客户端或代码仓库。

协议依据、运行时许可证与当前测试版本见 [PROVENANCE.md](PROVENANCE.md) 和 [SBOM.spdx.json](SBOM.spdx.json)。未复制华为服务端示例源码；项目自有实现适用仓库 AGPL-3.0-or-later。
