# Pro 服务端协议与运行时来源

本目录为项目独立实现，没有复制、分发或执行华为示例项目源码，没有引入 npm 依赖。阅读示例仅用于核对官方协议常量及格式。

已于 2026-09-07 核验：

- [IAP JWS 验签](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/iap-verifying-signature)：ES256，typ JWT，x5c 叶/中间/根三张证书，专用非 critical OID `1.3.6.1.4.1.2011.2.415.1.1`。
- [Huawei CBG Root CA G2](https://pki.consumer.huawei.com/ca/cer/RootCaG2Ecdsa.cer)：实际 DER SHA-256 `df21a3c09f7954579305f85c64f80cad86f79853ee3a887c1dec95d218df3a37`。仅保存信任指纹，未将证书文件加入仓库。
- [JWT 请求签名](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/iap-jwt-description)：ES256、aud iap-v1、aid、iss、kid 与请求原始 JSON SHA-256 digest。
- [IAP 公共说明](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/iap-rest-common-statement)、[订单状态](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/iap-query-order-status)、[发货确认](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/iap-confirm-purchase-for-order)、[订单模型](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/iap-server-data-model)。
- [Account Kit 解析凭证](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/account-api-get-token-info)：服务端 POST access_token；验证无 NSP_STATUS 错误、type=0、client_id、expire_in、union_id/open_id，不能相信 App 发送的 X-Union-ID。
- [官方服务端示例](https://gitcode.com/HarmonyOS_Samples/iapkit-sample-serverdemo)，只读参考 commit `c64d71bf7b0af8eff41a63e0f5f52c5a91736925`，上游 Apache-2.0。

本地实际测试运行时为 Node.js 26.4.0 和 OpenSSL 3.6.3。它们作为外部宿主运行时使用，不随 HAP 或本目录源码再分发；补充 SBOM 记录这一验证快照。未来部署的镜像必须固定实际版本、生成镜像完整 SBOM、记录摘要及保留相应通知，不能用此本地快照替代生产依赖锁定。

- Node.js：[来源与 MIT 及捆绑组件通知](https://github.com/nodejs/node/blob/v26.4.0/LICENSE)。
- OpenSSL：[来源与 Apache-2.0 许可证](https://github.com/openssl/openssl/blob/openssl-3.6.3/LICENSE.txt)。
