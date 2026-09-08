# Pro 服务端协议与运行时来源

本目录业务代码为项目独立实现，没有复制、分发或执行华为示例项目源码。SQLite/HTTP 核心不依赖 npm 包；AGC 部署子目录单独锁定华为官方云数据库 SDK 及传递依赖。阅读示例仅用于核对官方协议常量及格式。

已于 2026-09-07 核验：

- [IAP JWS 验签](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/iap-verifying-signature)：ES256，typ JWT，x5c 叶/中间/根三张证书，专用非 critical OID `1.3.6.1.4.1.2011.2.415.1.1`。
- [Huawei CBG Root CA G2](https://pki.consumer.huawei.com/ca/cer/RootCaG2Ecdsa.cer)：实际 DER SHA-256 `df21a3c09f7954579305f85c64f80cad86f79853ee3a887c1dec95d218df3a37`。仅保存信任指纹，未将证书文件加入仓库。
- 动态 CRL 使用 X.509 `2.5.29.31` 分发点，固定允许上述华为 PKI 主机。只有完整证书路径和 ES256 验证通过后才下载；缓存不能跳过 OpenSSL `-crl_check_all`。其他主机或分发点格式需要实际官方证据与独立复核后才可支持，不能临时关闭吊销检查。
- [JWT 请求签名](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/iap-jwt-description)：ES256、aud iap-v1、aid、iss、kid 与请求原始 JSON SHA-256 digest。
- [IAP 公共说明](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/iap-rest-common-statement)、[订单状态](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/iap-query-order-status)、[发货确认](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/iap-confirm-purchase-for-order)、[订单模型](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/iap-server-data-model)。
- [Account Kit 解析凭证](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/account-api-get-token-info)：服务端 POST access_token；验证无 NSP_STATUS 错误、type=0、client_id、expire_in、union_id/open_id，不能相信 App 发送的 X-Union-ID。
- [Account Kit 获取用户级凭证](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/account-api-obtain-user-token)：当前 HarmonyOS 接口 POST `grant_type=authorization_code`、`code`、`client_id`、`client_secret` 至官方 `/oauth2/v3/token`，授权码五分钟内一次使用。SDK 26 的实际 `@hms.core.authentication.d.ts` 同时核对授权请求/响应 state、`serviceauthcode`、`forceAuthorization=false`；所用声明自 API10/12 提供，保留 API23 兼容。客户端不执行带密钥的交换。
- [官方服务端示例](https://gitcode.com/HarmonyOS_Samples/iapkit-sample-serverdemo)，只读参考 commit `c64d71bf7b0af8eff41a63e0f5f52c5a91736925`，上游 Apache-2.0。

本地实际测试运行时为 Node.js 26.4.0 和 OpenSSL 3.6.3。它们作为外部宿主运行时使用，不随 HAP 或本目录源码再分发；补充 SBOM 记录这一验证快照。未来部署的镜像必须固定实际版本、生成镜像完整 SBOM、记录摘要及保留相应通知，不能用此本地快照替代生产依赖锁定。

- Node.js：[来源与 MIT 及捆绑组件通知](https://github.com/nodejs/node/blob/v26.4.0/LICENSE)。
- OpenSSL：[来源与 Apache-2.0 许可证](https://github.com/openssl/openssl/blob/openssl-3.6.3/LICENSE.txt)。

## AGC 云数据库适配

- 官方 [Node.js Server SDK 集成](https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/agc-clouddb-sdk-integrationsdk-0000001982503202) 和 [云函数访问数据库](https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/agc-clouddb-sdk-use-clouddb-0000001982662914)。
- 2026-09-07 从官方 npm 发布读取 `@hw-agconnect/cloud-server@1.0.5`，并校验包 SHA-512。声明和实际实现均核对：`CloudDBCollection.runTransaction`、`Transaction.executeQuery/executeUpsert`、`naturalbase_version`、最多五次事务尝试，以及先读后写约束。
- SDK 仅校验查询返回的对象；空查询和范围不自动防止并发插入。每笔业务事务必须读写已存在的 `control-v1`，包含只读权益快照；控制记录缺失时不自动初始化、不签发权益。独立存储区首次配置期间预置控制记录，随后不得覆盖。
- SDK 对未设置凭据的环境不自动初始化：它读取 `AGC_CONFIG` 或 `PROJECT_CREDENTIAL`，或由部署显式配置。AGC 实际运行验证为 Node 22.23.2 / Linux x64，当前探针未收到这两项托管凭据。不能把文档中的推荐路径当成实际已就绪。
- `agc/package-lock.json` 固定全部 31 个 npm 包；Axios 显式固定 1.20.0。使用 `npm ci --ignore-scripts`。本次 `npm audit` 返回 0 项漏洞，这是当前检查结果而非永久安全保证。
- `agc/SBOM.spdx.json` 保存每个发布归档 SHA-512，完整许可说明见同目录 `THIRD_PARTY_NOTICES.md`，可用 `npm run inventory` 重建。SDK 未附独立 LICENSE 文件，其 README 和 package.json 声明 ISC；通知保留该声明、源码版权以及 ISC 许可文本。所有依赖均只用于独立服务端部署。

2026-09-08 核对原生 Cloud Foundation 入口：

- 官方 [调用函数](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/cloudfoundation-call-function)、[公共模块](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/cloudfoundation-cloudcommon) 和 [Node.js 入口](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/cloudfoundation-develop-function-nodejs)：函数调用不需要用户级 AuthProvider；用户账号归属仍由独立 Pro 短会话验证。HTTP 触发器需要应用侧网关鉴权，函数通过 callback 返回 JSON 兼容对象。
- 当前 API26 `@hms.core.deviceCloudGateway.cloudFunction.d.ts`、`cloudCommon.d.ts` 证实 `call`、`init` 自 API12 提供；官方设备约束说明 PC/2in1 从 API23 支持。保留的最低 API23 覆盖所有目标设备；不使用本地 `localUrl`、安装预加载或不存在的取消接口。
