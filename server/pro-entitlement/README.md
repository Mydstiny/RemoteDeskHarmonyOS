# Pro 权益服务

当前实现可信验证、HTTP 接口、持久台账与签名权益，以及 App 验签、加密本地队列和购买恢复接入。固定沙盒 URL/公钥尚未填入，完整云端部署与实机验收仍在推进，正式购买关闭。

当前 App 登录获得的是 Account Kit 授权码；旧 `AuthService` 的 token 字段实际是 OpenID，不能用作 Bearer。`ProAccountSession` 单独请求新的一次性授权码并校验 state/UnionID，`/v1/pro/session` 在华为官方端点交换后核验用户令牌与客户端 ID，再返回 10 分钟的请求会话。授权码和华为令牌不持久化，客户端不持有服务器密钥；完整部署和实机支付仍待验收。

- `iap-crypto.mjs`：固定华为 Root CA G2 指纹，OpenSSL 3 完整证书路径/CRL 检查，IAP 非 critical OID，ES256/P1363 签名，以及服务端请求 JWT。
- `huawei-api.mjs`：固定华为 HTTPS 站点、禁用重定向、超时/长度限制、Account Kit 用户凭证与 OAuth Client ID 校验、订单最新状态/通知验证和独立发货确认调用。
- `session.mjs`：独立 32 字节密钥签发 HS256 请求会话，固定令牌类型、签发者、应用和环境。部署将 `ProSessionService` 作为 `ProHttpApi` 的账号验证器；该模式不再接受原始华为 Access Token。此会话只认证请求，权益仍必须使用独立 RS256 签名。
- 客户端订单只提供查询引用，不提供可信 owner、商品或权益。账号 owner 与现有 App 的 `ownerScopeIdForUnionId` 使用相同派生规则。
- 本版只接受白名单非消耗型商品。NORMAL 与 SANDBOX 独立配置，最新订单签名限定五分钟新鲜度，实际沙箱联调必须确认该窗口与官方返回兼容。
- `iap-crl.mjs`：先验证固定根证书的完整路径与 JWS 签名，再读取已验证证书的 CRL 分发点。下载仅允许华为 `pki.consumer.huawei.com` 的无凭据 HTTP/HTTPS CRL 地址，无重定向、五秒超时、每份最大 2 MiB。每次使用均由 OpenSSL 验证 CRL 签名、时效及完整链撤销状态，成功后最多缓存五分钟；缺失、过期或验证失败不发放权益，也不当成订单退款。离线配置仍可提供静态 CRL 包，不能与动态来源混用。

SQLite/本机 HTTP 运行环境：Node.js 24+、OpenSSL 3（必须支持 `verify -no-CAstore`）。此核心无需 npm 依赖；AGC 子目录依赖单独锁定。测试执行 `npm test`；每次用临时生成的测试 CA、叶证书、CRL 和私钥验证真实密码学与撤销路径，结束后清理，仓库不保存测试私钥。

- `ledger.mjs`：私有持久目录内的 SQLite WAL/FULL 事务；随机购买意图绑定服务端验证账号；order/token 不可跨账号重绑定；token 使用部署提供的 32 字节 AES-GCM 密钥加密。schema 2 原子迁移，未知版本/错误密钥/环境复用拒绝启动。
- `fulfillment.mjs`：最新订单核验后落盘，按账号签发 RS256 权益；独立 outbox 查询最新状态后确认发货，发货租约与失败退避持久化。终结退款保留墓碑；公平批次防止异常订单阻塞后续；权益状态与 revision 原子读取。
- 离线缓存默认每日重验、七天可用；永久购买记录与缓存新鲜度独立。失败不续签，退款只影响对应订单。所有未终结订单需要最新查询后才签发新权益。
- `/v1/pro/reconcile` 接收 `purchaseDataList` 和 32 字节随机挑战的无填充 base64url `challenge`。RS256 签名包含原挑战，App 必须匹配本次请求才承认在线重验成功；旧响应不能刷新缓存或清除时钟阻断。

部署必须使用真正的持久数据库。此 SQLite 实现不能直接放入 AGC 云函数临时文件系统；AGC 适配需要核对运行时和云数据库事务。用户已授权完善 AGC 沙盒，现有测试商品、IAP key 和指定沙盒测试帐号已核对；AGC 已部署运行环境探针、创建沙盒存储区。2026-09-08 已通过真实 SDK 检查控制记录、空权益快照和四个并发事务，库内只有控制记录，没有业务订单。尚无完整后端部署或真实验单结果。私钥与其他凭据只由私有部署配置提供，不写入客户端或代码仓库。

`cloud-ledger.mjs` 提供独立 CloudDB 事务台账，保留与 SQLite 一致的订单绑定、退款墓碑、发货租约及公平扫描规则。数据库使用仅 Administrator 可读写的独立存储区，模型见 `agc/ProLedgerRecord.json`。每个事务通过已存在的控制记录保护新键与范围并发；状态和修订号同事务返回。控制记录需在服务关闭时向全新空存储区预置一次，运行时绝不覆盖或自动重建。

云函数部署使用 Node 22+ 并且不加载 `node:sqlite`。在 `agc` 目录执行 `npm ci --ignore-scripts` 后运行 `npm test` 验证真实 SDK 的查询、版本前置条件和序列化接口；远程传输由测试替代，不能当成已通过云端验收。该测试使用 Node 的 `--test-force-exit`，因为 SDK 的配置轮询没有公开停止 API；所有测试完成后才退出。根目录 `npm test` 另覆盖 60 项协议/台账/HTTP/会话检查。

协议依据、运行时许可证与当前测试版本见 [PROVENANCE.md](PROVENANCE.md) 和 [SBOM.spdx.json](SBOM.spdx.json)。未复制华为服务端示例源码；项目自有实现适用仓库 AGPL-3.0-or-later。

App 的 `services/pro/ProTrustedEntitlementClient.ets` 验证固定 RS256 公钥、账号/应用/环境/商品、revision 和时效。`ProEntitlementStore.ets` 使用独立 S3 加密 RDB，同一事务写缓存并移除已验证的精确订单；未完成订单和 CloudStore/E2EE 相互独立。启动/账号转换/前台重验受代际约束，关闭购买页后的回调只保留到捕获的原账号，客户端不调用 `finishPurchase`。

本地最高观察时间、签名 revision 和退款墓碑阻断普通重启/回拨/旧记录替换；进程内另记录已观察退款，持久化失败立即撤销当前权益。系统备份禁用且可携带备份不含本数据库；此设计不声称具备可信硬件计数器或对整机特权快照回滚的防护。设备系统时钟异常需要成功在线重验，服务不可用不会给旧签名续期。

设置 `PRO_TYPESCRIPT_PATH` 指向已安装 DevEco 的 TypeScript 模块，再用 Node 24+ 执行 `node --test scripts/tests/test_pro_signed_client.cjs scripts/tests/test_pro_trusted_client.cjs scripts/tests/test_pro_account_session.cjs`（仓库根）可复现 38 项 App 协议、真实 RSA、SQLite 事务和短期会话适配测试；`scripts/tests/test_pro_runtime.cjs` 覆盖现有权益/账号/图标策略。主机适配不等于原生 Account Kit、CryptoFramework、加密 RDB 或 IAP 实机验收。

请求会话只保留在进程内；按墙上时钟与包含休眠的运行时间双重到期，提前 30 秒更新，时钟回拨也触发重建。账号/环境转换清空会话并取消请求；401 最多重新授权一次。每日权益边界由真实运行时定时器触发在线重验，暂时失败后最多五分钟重试，原签名离线期限保持不变。
