# Pro 权益服务

当前实现可信验证、HTTP 接口、持久台账与签名权益；App 接入和实际部署仍在推进。

- `iap-crypto.mjs`：固定华为 Root CA G2 指纹，OpenSSL 3 完整证书路径/CRL 检查，IAP 非 critical OID，ES256/P1363 签名，以及服务端请求 JWT。
- `huawei-api.mjs`：固定华为 HTTPS 站点、禁用重定向、超时/长度限制、Account Kit 用户凭证与 OAuth Client ID 校验、订单最新状态/通知验证和独立发货确认调用。
- 客户端订单只提供查询引用，不提供可信 owner、商品或权益。账号 owner 与现有 App 的 `ownerScopeIdForUnionId` 使用相同派生规则。
- 本版只接受白名单非消耗型商品。NORMAL 与 SANDBOX 独立配置，最新订单签名限定五分钟新鲜度，实际沙箱联调必须确认该窗口与官方返回兼容。
- 证书 CRL 必须在部署时提供且保持更新；过期/缺失即验证失败。模块不会根据外部证书 URL 自动下载资源，不把签名验证失败当成退款。

运行环境：Node.js 24+、OpenSSL 3（必须支持 `verify -no-CAstore`）。无需 npm 依赖。测试执行 `npm test`；每次用临时生成的测试 CA、叶证书、CRL 和私钥验证真实密码学与撤销路径，结束后清理，仓库不保存测试私钥。

- `ledger.mjs`：私有持久目录内的 SQLite WAL/FULL 事务；随机购买意图绑定服务端验证账号；order/token 不可跨账号重绑定；token 使用部署提供的 32 字节 AES-GCM 密钥加密。schema 2 原子迁移，未知版本/错误密钥/环境复用拒绝启动。
- `fulfillment.mjs`：最新订单核验后落盘，按账号签发 RS256 权益；独立 outbox 查询最新状态后确认发货，发货租约与失败退避持久化。终结退款保留墓碑；公平批次防止异常订单阻塞后续；权益状态与 revision 原子读取。
- 离线缓存默认每日重验、七天可用；永久购买记录与缓存新鲜度独立。失败不续签，退款只影响对应订单。所有未终结订单需要最新查询后才签发新权益。

部署必须使用真正的持久数据库。此 SQLite 实现不能直接放入 AGC 云函数临时文件系统；AGC 适配需要核对运行时和云数据库事务。用户已授权完善 AGC 沙盒，现有测试商品、IAP key 和指定沙盒测试帐号已核对；没有实际服务器部署或真实验单结果。私钥与其他凭据只由私有部署配置提供，不写入客户端或代码仓库。

`cloud-ledger.mjs` 提供独立 CloudDB 事务台账，保留与 SQLite 一致的订单绑定、退款墓碑、发货租约及公平扫描规则。数据库使用仅 Administrator 可读写的独立存储区，模型见 `agc/ProLedgerRecord.json`。每个事务通过已存在的控制记录保护新键与范围并发；状态和修订号同事务返回。控制记录需在服务关闭时向全新空存储区预置一次，运行时绝不覆盖或自动重建。

云函数部署使用 Node 22+ 并且不加载 `node:sqlite`。在 `agc` 目录执行 `npm ci --ignore-scripts` 后运行 `npm test` 验证真实 SDK 的查询、版本前置条件和序列化接口；远程传输由测试替代，不能当成已通过云端验收。该测试使用 Node 的 `--test-force-exit`，因为 SDK 的配置轮询没有公开停止 API；所有测试完成后才退出。根目录 `npm test` 另覆盖 53 项协议/台账/HTTP 检查。

协议依据、运行时许可证与当前测试版本见 [PROVENANCE.md](PROVENANCE.md) 和 [SBOM.spdx.json](SBOM.spdx.json)。未复制华为服务端示例源码；项目自有实现适用仓库 AGPL-3.0-or-later。
