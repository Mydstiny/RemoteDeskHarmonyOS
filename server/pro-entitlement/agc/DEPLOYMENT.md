# Pro 沙盒云函数部署

本包仅用于已授权的 ProSandbox 沙盒；正式购买配置继续关闭。请求函数入口为 `handler.myHandler`，独立发货函数入口为 `handler.myWorker`。二者共享同一私有数据库、订单密钥与会话密钥，但分别配置触发器。

## 私有输入与打包

本机私有目录保留 `sandbox.json`、`agc-server-credential.json`、`oauth-client.json`、`grant-private.pem`、`grant-public.der`、`iap-private.p8`、`ledger-key.bin` 和 `session-key.bin`。目录 0700，文件 0600；任何材料、生成 ZIP 或展开目录都不能进入 Git。AGC 凭据只授权本项目的开发角色，其权限已单独取得用户同意；不能改用其他项目或账号级凭据。

`sandbox.json` 有且仅有九个字符串字段：applicationId、productId、environment、packageName、zoneName、issuer、grantKeyId、iapIssuerId、iapKeyId。固定沙盒商品 `RemoteDesktop_Pro_Test`、环境 `SANDBOX`、独立区 `ProSandbox`。OAuth clientId 必须等于 applicationId，私钥分别为 RSA2048（权益）与 P-256（IAP），两枚随机 32 字节对称密钥必须独立。`grant-public.der` 为 RSA SPKI，客户端只取得这份公钥。

在 macOS/Linux 的 Node22+ 部署主机执行（路径替换为已准备的绝对路径）：

```sh
node server/pro-entitlement/agc/build-package.mjs \
  --private-dir /private/path/pro-sandbox \
  --pkix-dir /private/path/pro-pkix \
  --output /private/path/pro-sandbox.zip
```

PKIX 输入目录只需 `bin/openssl` 与 `RootCaG2Ecdsa.cer`；程序字节和证书的 DER 指纹必须匹配 `pkix/manifest.json`。华为 `.cer` 下载为 PEM，打包器解析并转成固定 DER 字节。打包器安装锁定的 npm 包，禁用安装脚本，包含每个依赖的通知、独立 SBOM、完整 PKIX 许可证以及源码逐文件哈希；不包含 SQLite 或原生 npm 插件。ZIP 与校验文件为 0600，中间目录始终清理。`DEPLOYMENT-MANIFEST.json` 不记录单个凭据的值或哈希。部署前核对 ZIP 哈希与 manifest，保持文件内密钥只交付到已授权的沙盒函数。

## AGC 配置

- 数据库：ProSandbox / ProLedgerRecord，仅 Administrator 读写。全新空区的 `control-v1` 已由一次性初始化建立；运行时只校验，不补建或覆盖。每次冷启动以控制记录事务验证应用、环境及加密密钥。
- 请求函数：Node22 或兼容的受管 Linux x64 运行时，事件调用，入口 `handler.myHandler`，同步超时至少 30 秒。HTTP 触发器使用「API客户端鉴权（Client适用）」。App 原生 Cloud Foundation SDK 固定函数名与版本；短会话在业务信封内验证，网关身份不能提供账号归属。
- 发货函数：同一部署包，入口 `handler.myWorker`，仅定时触发器，建议一分钟一次、异步超时 600 秒。不得配置公开 HTTP 触发器。每批最多检查 20 单，单进程防重入，数据库发货租约跨实例保护确认操作。
- 运行结果通过 `callback` 返回，不能仅返回 Promise。SDK 可能输出未经脱敏的错误对象，故该专用函数在加载 SDK 前关闭 console 原始日志；业务只返回固定错误、已验证响应和计数。验单失败使用 AGC 入口第四参数 logger.info（兼容 context.logger/global.logger）写入固定白名单分类（直接 stdout、原 console 与当前运行时 global.logger 未产生日志）；IAP 厂商错误仅保留最多 12 位数字错误码，不记录请求、响应、账号、订单、令牌、原始异常或堆栈。
- 通知回调继续关闭。华为通知需要独立、已验证签名和持久化后空 HTTP200 的入口；本包的四种客户端操作（含仅沙盒的订单退款路由查询）不提供通知或 worker 分发。

## PKIX 来源与验证

私有包带 OpenSSL 3.5.8 Linux x64 静态可执行文件；不放入 HAP 或 Git。源码 SHA-256、实际二进制 SHA-256、Alpine 构建镜像摘要、musl/GCC 版本与构建命令在 `pkix/manifest.json`，完整构建工具清单在 `pkix/build-packages.txt`。`pkix/build-openssl.sh` 使用固定源码归档；重新构建必须核验新字节并更新 manifest、SBOM 后重新审查，不假定滚动 APK 仓库仍给出同一产物。

随包保留 OpenSSL Apache-2.0、musl MIT 完整版权文件、GCC GPL 与 Runtime Library Exception 3.1，以及构建期 fortify-headers 的 0BSD 通知。对应来源见 manifest。受管 Node22/系统由 AGC 提供，未复制到部署包；不能把此包的 SBOM 宣称为华为整个运行镜像的 SBOM。

实际 Linux Node22 使用该静态程序已通过既有 19 项 PKIX/JWS/厂商协议检查。正式启用前仍须在 AGC 验证冷启动、控制记录、业务 401、空 worker、原生授权码交换，以及沙盒真实购买/恢复/确认发货/退款。主机或部署探针成功不等于 IAP 支付验收。

日志入口依据：[AGC Node.js 日志记录](https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/develop-func-nodejs-0000001713076049)，2026-09-19 核对官方 global.logger 声明。
