# M7 沙盒部署与购买鉴权准备

2026-09-19，用户撤销此前联网暂缓限制，随后明确优先测试 Pro 购买与鉴权，暂不测试安全密钥；另行明确允许将既有八份私有配置上传到本项目两个指定沙盒函数，并开启 Chrome 所需的本地文件访问权限。

## 已执行

- `066b738f`：同一固定 OpenSSL 3.5.8 源码、Alpine 镜像及构建脚本重建静态 Linux x64 PKIX 程序。原临时产物已不存在，不对新旧字节差异归因。更新 manifest、SBOM、构建包清单及 provenance；独立复核 PASS。
- `db981019`：Debug 沙盒固定到 `remotedesk-pro-sandbox-api`，配置本项目应用 ID 和现有 RSA2048 验签公钥。未放入私钥；production/Release 返回 null。配置与主机测试独立复核 PASS。
- 完整 ZIP 4,635,042 字节，SHA-256 `d367573fbd45fa463ad6fc480ba28237cb15a9b46a63651a2c6ce246f005f5fb`。八份私有输入沿用现有身份和密钥，仓库不保存秘密及其单独哈希。
- AGC RemoteDesktop 项目创建 `remotedesk-pro-sandbox-api`：`handler.myHandler`，POST、API 客户端鉴权、decode 开启、60 秒超时、实例并发上限 10、500 MB。
- AGC 创建 `remotedesk-pro-sandbox-worker`：`handler.myWorker`，仅定时触发器、异步、600 秒超时、实例并发上限 1、500 MB。用户询问是否有必要后，确定首次验收手动运行即可，定时器保持关闭；无 HTTP 触发器。
- API 云端实际测试：格式合法但签名无效的会话请求得到 `{version:1,status:401,body:account_login_required}`，证明完整运行时冷启动及账号会话拒绝路径。不是原生 SDK 调用证据。
- worker 云端实际手动测试：`status:200`、`checked:0`、`successful:0`、`busy:false`。不代表订单发货已验收。
- API 数字版本发布两次返回 AGC“处理请求时发生未知错误，请稍后重试”；第二次发生于实际 API 测试通过后。本轮显式 Debug 沙盒保持既有 `$latest` 设计，记录精确部署包；数字版本固定仍待平台发布恢复。
- API26 Mate 80 Pro Max 保留数据覆盖安装 Debug HAP 成功；设备包查询确认 `debug:true`、版本 1.1.5.1。未卸载、未清应用数据。

## 验证

- 当前服务端 78 项通过；重建静态程序在实际 Linux Node22 中运行 19 项 PKIX/厂商协议测试通过。
- 配置/账号会话/可信客户端由 reviewer 独立执行 34 项通过；公钥与现有公开 DER 294 字节完全一致。
- 实际 Linux 完整包连接现有 CloudDB 控制记录，冷启动、无效会话业务 401、空 worker 通过。SDK 后台连接不自动退出，输出结果后仅停止该临时容器。
- `default@OhosTestCompileArkTS`：BUILD SUCCESSFUL in 5 s 745 ms；签名 `assembleHap`：BUILD SUCCESSFUL in 7 s 770 ms；Release：BUILD SUCCESSFUL in 27 s 222 ms，均 exit 0。
- Light、diff、两个 ABI 的 FIDO/CBOR 以及沙盒/模拟权益 Release 裁剪通过；冻结 Release ABC `f03657396d7f5b7397d9fff3709d4de59c62f052edfcee6b8a61b4ba420a3917`。客户端配置及公钥存在于 Debug，Release 后端配置恒为 null。

## 待执行

原生 Cloud Foundation 网关、Huawei 授权码交换、无权益恢复、沙盒购买、服务端验单与确认发货、重启恢复及退款查询仍需实际设备结果。设备重启后需重新打开沙盒开关，保持“跟随真实权益”，不能使用模拟 Pro 证明购买成功。

通知回调、正式商户激活及生产购买继续未完成；当前 API 不提供通知入口。安全密钥不在本轮验收范围。M7 和整个 Pro 计划均未宣称完成。

## 安装后的用户反馈

用户报告既有页面全部变方正、布局与动画变化。此次安装带入十批公共 UI 改造；源码对比确认结构变动；用户随后附上 DevEco 投屏截图，显示主机分组直角块和顶部搜索区域挤压。实时 CUA 仍返回空 AX/截图不可用，用户附图与实时可操控状态须分开。购买测试中断，优先恢复原界面，保留本次后端/鉴权接线及用户数据。不能以本节安装成功视为 UI 或购买验收通过。


## 真机购买与崩溃修复进展

- 原 UI 22 文件恢复 `db7665f8` 独立复核通过；保留数据安装后，HDC 截图核对主界面圆角、搜索区域、设置与添加主机 Sheet。未宣称完整动画/多设备视觉验收。
- 用户日志的模拟 Pro 崩溃定位到 `ProAppIconPanel.presets` 的 BuilderParam `this` 绑定。`ad3c1a20` 在图标/分享/接续三个调用者使用父级闭包，实际生成 ArkUI 回归与独立复核通过。真机真实/免费/Pro/真实切换无崩溃、进程未重启。
- 用户单独批准后，将既有 Debug 证书的公钥指纹加入 AGC，未变更私钥或正式收费。稍后真机 `isSandboxActivated` 和 `queryProducts` 成功；IAP 服务原已启用。
- 原生账号会话与服务器意图创建通过，华为支付页明确显示沙盒、不产生扣费；用户完成人脸验证并确认购买成功。
- App 返回未激活；恢复购买能查到订单，但尚无有效签名权益。只读 CloudDB 汇总为一个 unbound intent 与一个 control，无 order。正在定位服务端验单失败，未再次购买、未手动写权益、未开启定时器。
- `c625958e` 支付配置错误提示：22 项客户端回归、编译5s184、签名6s642（SignHap963ms）、Light/diff 和独立复核通过。`7f73d337` 服务端固定故障分类：79项服务端回归、编译5s059、签名6s340（SignHap972ms）、Light/diff通过；独立五文件与 ZIP 复核通过，八份私有材料与原授权部署逐字节一致。AGC 会话过期、已请用户重新登录；诊断包尚未完成提交。

## Actual verification diagnosis, 16:53

- Invocation logger1c02e089 uses the platform fourth argument and AsyncLocalStorage; protected API deployed. Console invalid-session probe returned401 and emitted a fixed failure category. Earlier stdout/console/global-only variants had no visible diagnostics.
- Existing purchased order restore returned cloud iap_verification_failed at16:44. Header/root pin/leaf policy checks passed before this bounded catch; path, signature or CRL checks still need separation.
- Client915b6c9b independently PASS (41tests+28boundary checks), preserve-data installed. Actual phone logs: session200, reconcile503, reconcile stage1. No repeated purchase, no activation claim.
- PKIX stage diagnosticfdc07e55 independently PASS:81server+19real PKIX and30reviewer HTTP/PKIX checks; compile4s683/signed5s922 SignHap913, Light/diff PASS. Package sha2566d825abdc7bf1305568fb0739bf7888c6d7be6eaf4add492ae9496386f3a8c29;851public files,8private bytes unchanged. Upload pending browser availability.
- Release22s434 SignHap851 and dual-ABI/ABC sandbox/simulation/USB pruning PASS; ABC562d71b605f49e9a23277d95d57cc347fb4ac759b60330cddec471c3cdbd0c07.

## Actual CRL failure, 17:01–17:12

- fdc07e55 deployed. Actual restore reported cryptoStage3 / iap_crl_distribution_unsupported; pinned strict chain and ES256 signature passed before CRL preparation.
- Public Huawei root CRL candidate was independently fetched from https://h5hosting.dbankcdn.com/cch5/crl/pki_CRL_root_g2_crl/root_g2_crl.crl (HTTP200, no redirect,375-byte DER). It verifies against the existing pinned RootCaG2Ecdsa, valid2026-06-08–2027-07-18. Candidate is not yet proof of the actual IAP distribution point. Original cpki endpoint redirects; generic redirect following remains forbidden.
- 4a199ae5 scoped review PASS:12HTTP+19realPKIX;82server,compile4s867/signed6s203 SignHap1s020,Light/diff. Deployed ZIP exported and byte-identical;8private inputs unchanged. Its Huawei-only log filter still omitted actual distribution points.
- 1a902dfc logs bounded safe-ASCII public CA addresses from the already-verified certificate; download rules unchanged.82server,compile4s916/signed5s973 SignHap976,Light/diff PASS. ZIP sha2569e557b98f9cdc744cee1a9d3d2c095be603da2c1aeb1b74b7edd17c2ca19cfed;8private inputs unchanged. Uploaded and submitted, actual new log pending.

- Actual17:12 CDP: http://h5hosting-drcn.dbankcdn.cn/cch5/crl/haicag3/HuaweiCBGHAIG3crl.crl. Fixed HTTPS direct download independently returned200,326-byte DER; signature is still enforced against the verified IAP chain at runtime.
- ae46a178 exact two-file independent PASS;20PKIX+83server tests,compile4s905/signed5s995 SignHap905,Light/diff PASS. ZIP1c3dc84cfa6e1466b117b0cd5fb5cbed99b2703c3af1c2216593be9699dc82c4 deployed;8private unchanged.17:17 actual restore progressed from PKIX failure to unclassified error. No order/activation yet; read-only count3rows (2unbound intents+control).
- 16629880 adds bounded official CloudDB numeric code and known local source location diagnostics, no raw error or record.84server,compile4s754/signed5s773 SignHap878,Light/diff PASS. ZIP418497a65e4dcc1f16e52b843555aa1cb1741f10cdc7869ffb8908b9860a8a6f uploaded/submitted.

### CloudDB rate-limit diagnosis and repair

- 17:26 real restore failed at CRL download; the next completed request at 17:27 passed PKIX and returned `cloud_database_failed / 3007009`. The bundled official SDK declares this as `TOO_MANY_REQUESTS`.
- `1a29c711`: exact CloudDB throttle errors share a three-retry 1/2/3-second budget across transaction reads and rejected commits. Other errors are not retried. Every replay starts fresh reads and preserves the control-row fence, ownership and token binding.
- 86 server tests PASS, including read/commit throttling, one durable binding, cross-account rejection, exhaustion, non-throttle and ambiguous-network failures. Current compile4s635; signed assemble5s797 (SignHap942ms); Light/diff PASS.
- Package `pro-sandbox-throttle.zip`: SHA256 `f0074361089ba35149bb3750d376cf9c909244db99ae8ec4687409d4251b3df4`, 851 source files and 8 unchanged private inputs; API upload in progress. Worker schedule stays disabled. No additional purchase was made.

- Post-deployment restores at17:33/17:36 still returned3007009 after bounded backoff. Independent SDK review confirms one logical rejected query can issue primary+backup requests; 3 retries can total8 HTTP reads. SDK can fold commit errors into false; no blanket claim that all throttling is solved.
- Same-project local diagnostic (no order creation): live references(owner,true), terminalReference for a synthetic nonexistent order, and snapshot all PASS with2 transaction reads each; snapshot noEntitlement. This does not prove where the cloud request fails or exclude hot-query limits.
- `695c80de` adds fixed operation name and bounded read-step diagnostics only.87serverPASS; compile4s861/signed5s680 SignHap855/Light/diffPASS. ZIP3fd8c650968c389ac2583c9c42fc3fa94ec02b50f33156cda86c924de0581ef8,851public/8private. Uploaded for precise failure localization; no private payload/message logged.

- Latest17:42 cloud diagnostic:3007009 at terminalReference, ledgerRead2. This is before IAP refresh in this request; prior statements inferring that every CloudDB error followed PKIX were insufficient. Actual locked SDK commit3007009 is folded into false and ultimately ledger_transaction_conflict in offline reproduction, making the second order read the supported failure location.
- Updated worker(throttle package) manual execution PASS status200/checked0/successful0/busyfalse. Timer remains disabled; no order has been delivered yet.
- `7f39b715`: batch terminalReference control+order primary keys in one transactional in-query, explicitly reject unexpected/duplicate rows, retain control-row version check/write for absent-key safety.88serverPASS; local actual SDK references2reads/terminal1read/snapshot2reads PASS. Compile5s405/signed7s600 SignHap1s107/Light/diffPASS. ZIP368e21009b94aaad57d29d906f72c0b977c05e0ff3c1a0c7b08158ff330e6e25,851public/8private. Cloud effect still requires actual restoration.

-17:46/17:47 after batch lookup: restore advanced through the ledger precheck, then cryptoStage3/iap_crl_download_failed. No grant persisted. Local exact leaf and candidate root HTTPS endpoints both returned200(<0.2s); the actual second certificate URL still needs live identification.
-6975799b adds bounded CRL download index/category/status and strictly limited public PKI URL diagnostics. Fetch targets, redirect:error,5s/2MiB bounds, signature/chain/revocation checks and cache admission are unchanged.90serverPASS; compile4s970/signed5s863 Sign906/Light/diffPASS. ZIPc0185f421318af67d71858b93cd98c8d0d244884cffcb60cbe1b8c7af32118e8,851public/8private deployed to API. Independent review in progress.

### Confirmed root CRL redirect

-17:55 actual diagnostic identifies crlIndex1/redirect: `http://pki.consumer.huawei.com/ca/crl/root_g2_crl.crl`. A separate public request confirms302 to the existing h5hosting.dbankcdn.com root CRL path. Its clean HTTPS form returns the same375-byte DER; pinned RootCaG2Ecdsa signature verification again PASS.
-50cac0f2 maps only that exact source URL to the previously validated fixed HTTPS target. No generic redirect following, extra hosts, TLS exemptions or revocation bypass.90serverPASS; compile5s264/signed6s538 Sign965/Light/diffPASS. Independent review_pro_plan exact2-file and21PKIX PASS,8private unchanged.
-ZIP602368394502501bbc6ae82e7ad62280c1c44c5051ef9e1dd742b735dcbdf564,851public/8private; uploading API. Prior exported CRL-diagnostic ZIP exactly matchedc0185f42; initial requests used prior runtime until new fields appeared.

### Actual trusted activation and fulfillment acceptance

-Root-CDP fix50cac0f2 deployed to API. Phone in real entitlement mode reports “沙盒权益已验证并恢复”; ledger grows from3 to6 rows: control, one bound+one unbound intent, one token, one active order and one account. First grant revision1/total1/active1/pending1; no second payment.
-Worker update initially rejected by automatic review because API/worker package compatibility was not established. Verified ZIP public handler.js contains both myHandler/myWorker, is byte-identical to the existing worker entry, and cloud DOM entry remains handler.myWorker. Re-submission with this evidence was permitted and completed; no trigger change. This was a shared reviewed package, not an API-only entry replacement.
-Worker manual invocation with updated package returns status200,checked1,successful1,busyfalse. Independent read confirms order revokedfalse/pendingfalse/finishedtrue/attempts1 and account revision1,total1,active1,pending0.
-Actual force-stop/start preserves account data. Production remains isolated/free by default; explicit Debug sandbox selection loads persisted signed grant and shows “沙盒 · Pro 已激活” in real mode. Screenshot saved only locally as pro-active-after-restart.jpeg. No simulated Pro override.
-Post-delivery restore again reports verified/recovered. Ledger remains6 rows with exactly one order/token/account, revision1 and attempts1; no duplicate fulfillment.
-Current official sandbox guide distinguishes purchase-history deletion (irreversible for all sandbox purchases on the account) from refund. No purchase history was cleared, no refund was fabricated, and no production merchant agreement/charging was enabled. Actual refund/account/offline/multi-device and notifications remain unverified; worker scheduling remains disabled.

## Refund and fault-path acceptance increment

- Code `0a4f9c216ac973c1ea56f72703e5ef6b5fb95b72`, base `069fbd57a90c4221b9738ace3f2f5ffc9a51325c`: five-file scoped independent PASS. Original three failures (post-signature cache read, negative write, receipt-delete rollback) reproduce on old code and pass on repaired code. New persistent verification fence blocks old positive cache after interrupted acceptance; negative state commits before receipt cleanup. v1 migration preserves cache and pending receipts; migration rollback/retry independently checked.
- Client/runtime/configuration checks56/56; trusted-client subset33/33; independent7/7; server90/90. Simulated native purchase cancellation makes no receipt/grant/reconcile. Host tests do not replace device refunds, offline or second-account testing.
- Debug-only refund entry uses current native IAP query and unique matching app/product/type/SANDBOX order. API26 SDK declares createRefundRequest sinceAPI15; API23 baseline supported. Vendor UI return means application submitted/returned, not approved refund. User performs final vendor confirmation; only signed server reconciliation changes entitlement. Official current sandbox refund behavior: https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/iap-server-refund-receive-notify . Purchase-history clearing is not used as a refund.
- DevEco compile6s765; signedDebug15s313 (Sign838ms); signedRelease22s631 (Sign859ms), exit0. Light/diff PASS. Initial sandbox cache EPERM resolved via approved escalation; one missing explicit ArkTS query-result type repaired before passing. Release config/sandbox guards PASS; actual refund async method always takes constant-false DEBUG branch and throws before IAP, with unreachable async body retained by compiler. ABC `ad064a941727fb0079eb79eea2ca70aff350d90b7408304a4d53ed17b5fd6de8`.
- Frozen Debug HAP84269092bytes SHA256 `7ba2a7709eabf6f8817fcc0af84721bd256243f69d8258deaaa2819a563b750e`, bundle/version unchanged, debugtrue. HDC preserve-data install succeeded. Launch blocked by device lock10106102; new-client native schema migration/refund not yet accepted. USB and second sandbox account requested for remaining matrix.
- Actual deployed API negative tests: forged well-shaped session returnsbusiness401/account_login_required; worker and notifications operation attempts returnbusiness400/invalid_request. Read-only CloudDB remains sixrows, one active/finished order, attempts1, accountrevision1, pending0. No new purchase, refund or grant mutation.
- Numeric version publication of the accepted deployment still returns AGC unknown error; no numeric version created. Existing deployed $latest service remains operational. Worker timer and notification configuration remain disabled; formal checkout still disabled.

- Refund record final gates: testCompile4s843; signed assembleHap5s615 Sign838ms, exit0; Light/diff/state PASS. Phone still locked at final probe; USB not present.


## Delivered sandbox order refund lookup

{
  "commit": "1c466f3956fe133da9fd0b8b6879564736b1b2d5",
  "status": "reviewed-installed-awaiting-agc-login",
  "reviewTaskId": "/root/review_pro_plan",
  "reviewStatus": "PASS",
  "cause": "API26 queryPurchases documentation at lines1435-1436 excludes delivered sandbox non-consumables; ALL query did not recover the real delivered order.",
  "scope": "Authenticated sandbox-only refund-order lookup; session owner, empty request body, fresh vendor verification, one active ledger order, five non-token route fields; client Debug/scope/generation guards. No grant/refund/delivery authority.",
  "verification": {
    "server": "93 PASS",
    "client": "54 PASS (35 trusted,11 session,8 signed)",
    "independent": "92 related tests plus3 extra CloudDB concurrency boundaries PASS",
    "testCompile": "PASS exit0 BUILD SUCCESSFUL in700ms",
    "assembleHap": "PASS exit0 signed BUILD SUCCESSFUL in12s407; SignHap863ms",
    "release": "PASS exit0 signed BUILD SUCCESSFUL in22s815; SignHap846ms",
    "compliance": "Light and diff PASS",
    "package": "851 public source files;8 same authorized private inputs; Linux Node22 cold-start PASS; forged refund-order session401"
  },
  "packageSha256": "88b910e2b6976e6f23685bda0f56db67093c0782b7ca28ac086c6f387de9cb6a",
  "debugHapSha256": "b0fb8d9dfca51e136fd202e9bbbc857032b5aef950550450b0108352511ee7ba",
  "device": "0a4f updated client started with preserved original UI/data and restored signed real sandbox grant;46bb native history still no unique order;1c466 Debug preserve-data installed. Refund route not yet deployed.",
  "boundary": "Worker timer and formal checkout OFF; no full-plan or refund acceptance claim."
}

## Refund-route deployment and real UI entry

- API updated at20:30:10 Asia/Shanghai with package88b910e2b6976e6f23685bda0f56db67093c0782b7ca28ac086c6f387de9cb6a; actual refund-order forged-session console probe401 account_login_required. Worker previous package retained; timerOFF.
- A stale UI after first submission led to repeated submissions; later requests returned HTTP400/code121080 StorageInfo param error. Reloaded console timestamp plus actual new-route execution confirmed the initial update, so retries stopped. One browser call stalled about19minutes; no security/network configuration changed.
- New1c466f39 Debug launched preserving original rounded UI/data. At20:57, native empty-history fallback successfully opened Huawei refund reason/Submit screen for the existing delivered sandbox order. Final submission handed to user; no agent refund submission or local entitlement change.
- Pre-submission ledger: six rows, one order active/nonrevoked/finished/pendingfalse/attempts1; account revision1 total1 active1 pending0. Refund/revocation/restart acceptance pending.
- Record gates: PASS compile 5 s 25 ms; signed assembleHap5s898 Sign930ms; Light/diff PASS. Initial duplicate generated-resource failure resolved by quarantining four byte-identical copies.

## Refund timeout with successful vendor completion

- User final submission at21:00:27: vendor IAP6.26.10.302 returned HTTP500/N00002/[BiS]Read timed out from refunds (2095ms), immediately followed by S00002 frequent operations. UI showed service unavailable. No further refund submitted by agent.
- Exited error/refund UI and restored purchases. Server fresh Huawei verification persisted revokedtrue, account revision2 total1 active0 pending0; order finishedtrue pendingfalse attempts1. Six ledger rows unchanged in count. App top label clearly sandbox Pro revoked in real mode.
- Force-stop/start, explicit sandbox selection and repeated restore did not revive old Pro. Ledger remained revision2/one revoked order/attempts1. This is online restart acceptance, not offline proof.
- Wording fix3e099221 removes misleading cancellation claim on vendor-UI exit and displays signed real-state revocation explicitly.35trusted PASS; testCompile7s207, signedDebug8s577 Sign893ms, Light/diff PASS.
- Exact wording3e099221 independent review PASS (three files, three extra targeted checks). Frozen HAP SHA2565d25fb5dc40a9a64b1f52561cb356b5972538bec513a94b13b43f010eaf1bda7 installed preserving data; real-mode Pro sheet displays both sandbox revoked status and explicit server-confirmed revocation result. Final record gates compile5s192/signed5s675 Sign879ms, Light/diff PASS. Offline and cross-account device acceptance remain open.
