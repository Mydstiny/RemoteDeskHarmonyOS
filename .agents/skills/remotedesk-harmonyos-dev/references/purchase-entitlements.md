# 本应用 Pro 与购买权益

历史基线：2026-09-07 整理的 `0000d4ca4`。本页的基线说明不能代替当前能力判断，尤其同一分支可能正在实现 M1/M2。先检查 `git diff 0000d4ca4 -- entry/src/main/ets/services/pro entry/src/main/ets/components/ProPurchaseSheet.ets`，再用 `git status --short`/`rg --files` 找新增且尚未跟踪的 runtime 文件。后续状态读 CURRENT/QUEUE。本应用内购和 RustDesk Server Pro API 是两个独立领域。

## 入口与基线边界

- [ProAccessPolicy.ets](../../../../entry/src/main/ets/services/pro/ProAccessPolicy.ets)：feature catalog、available/planned 和 access 判定。当前 core connection 为免费 available，付费候选仍是 planned。
- [ProBillingService.ets](../../../../entry/src/main/ets/services/pro/ProBillingService.ets)：非消耗型商品查询、沙盒购买、订单分页查询、全局 single-flight admission。展示价格以商店查询值为准；不要把本地营销数字当成交金额。
- [ProEntitlementService.ets](../../../../entry/src/main/ets/services/pro/ProEntitlementService.ets)：可信 verifier 的接入边界；进一步搜索当前 `ProRuntime`、`ProAppRuntime`、`EntryAbility` 与调用者，分别确认运行时接线和后端实现。
- [ProPurchaseSheet.ets](../../../../entry/src/main/ets/components/ProPurchaseSheet.ets)：设置入口弹层、UI 状态、关闭/重开与异步操作。
- [2026-09-06-pro-purchase-foundation.md](../../../../docs/codex/plans/2026-09-06-pro-purchase-foundation.md)：沙盒基础方案。未来路线从当前队列的 plan 链接查找，不假定未来 M1/M2 或生产履约已实现。

基线 `0000d4ca4` 只证明沙盒底座；后续权益类型及过期/复验语义以当前 `ProAccessPolicy` 为准，不固定使用旧字段名。终身权益、typed verification、运行时、离线 grants、退款和 Debug/Release 隔离分别核对实现、调用者及测试。运行时已接入也不能推导可信后端或生产履约已完成。

## 购买成功和权益可信是两件事

IAP 返回、订单数量、UI 状态、Debug 模式或一段本地 JSON 不足以授予正式权益。现有沙盒 provider 不在没有可信验证的情况下确认交付或授予 Pro。

实现 verifier 时追踪 owner、environment、product、请求代次、验证结果、履约幂等性与持久化，再处理账号变化、离线与退款；不能让 sandbox grant 进入 production。

## 关闭后继续购买的历史案例

修复 `ac83ccec7`：异步 sandbox preflight 结束后，必须在 checkout 副作用之前再次检查请求仍有效。

证据：[ProPurchaseLifecycle.ets](../../../../entry/src/main/ets/services/pro/ProPurchaseLifecycle.ets) 的 `runCurrentProPurchase`、`ProPurchaseLifecycle`；[ProAccessPolicy.test.ets](../../../../entry/src/test/ProAccessPolicy.test.ets)。`ProPurchaseCoordinator` 的进程级 single flight 跨弹层关闭/重开仍生效。

购买启动的账号代次和权益验证的账号代次是两条检查链；不能用权益服务拒绝旧结果的能力推定 checkout 同样受保护。调查时分别查 `isCurrent`、账号切换调用者和验证回调。

这个屏障只阻止尚未调用 `createPurchase` 的 checkout；系统支付已经发起后，关闭应用弹层不等于撤销支付，需要按 IAP 返回和订单/验证流程处理结果。

验证包括关闭期间 preflight 返回、快速重开、取消、错误、切换账号后旧结果、恢复购买分页。不要通过自动发起真实付款来验证 skill。

## 与 RustDesk Pro 区分

`services/RustDeskProApiService.ets`、`RustDeskProSyncService.ets` 等处理服务器 API/地址簿/凭据，不是本应用付费权益入口。服务器付费版可用不意味着当前应用账号获得 Pro。
