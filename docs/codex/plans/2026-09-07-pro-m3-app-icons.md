# M3 内置应用图标接入

- 分支：codex/pro-purchase-foundation；沿用当前任务，不创建工作区。
- 范围：默认图标、用户提供的白底版与透明底版。2026-09-07 用户明确不做自定义上传。
- 状态：62baa018 与修正 fea42b9b 已通过独立代码/最终 Release 产物复核；设备验收待完成。正式购买仍禁用。

## 行为与边界

设置 → RemoteDesk Pro 中以统一 ProFeatureGate 显示付费预设；免费用户不显示专属网格。API23 不显示图标面板且不解析/调用 API26 成员。恢复默认不依赖 Pro、账号或验单服务。模仿用户修改调试模式不会自动更换实际系统图标。

ProAppIconController 在业务入口复查权益，异步查询之后再次核对权限和页面存活。账号或调试状态变化会使待执行的选择失效；多个窗口共享忙状态，防止互相覆盖。已经交给系统的切换不能取消，不因后续撤权自动反向切换；UI 按系统回读结果更新，退出账号后仍可恢复默认。

当前版本将预设功能登记为 available，以便 Debug 真正运行注册→隐藏→模拟激活→执行流程。生产仍使用 UnavailableProVerifier，没有伪造真实权益或打开购买。该目录状态不代表全设备发布验收。

## 本地 SDK 与官方依据

- API26 SDK：`@ohos.bundle.bundleManager.d.ts` 的 getAlternateIcons/setAlternateIcon since26.0.0；`bundleManager/BundleInfo.d.ts` 提供 iconName/iconId/enabled。
- AppIconAdapter 导入 API23 已有的 bundleManager 模块，先判断 API版本和 Core syscap，再访问新成员。没有新增 API26-only 模块的冷启动导入。
- [应用配置](https://developer.huawei.com/consumer/cn/doc/doccenter-getting-started/app-configuration-file)：alternateIcons 的 name 与资源索引预先随包声明，支持单层图标。
- [AppGallery 图标管理](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/appgallery-appinfo-manage)：开发者提交与审核图标后客户端才能选择；不作为用户任意图片上传的替代。用户已取消该范围。

## 资源来源与完整性

两张 PNG 由用户于本任务提供并指示直接纳入应用。无新增第三方依赖，保留原始 1024×1024 资源，无缩放或重绘。

| 资源 | SHA256 |
|---|---|
| AppScope/resources/base/media/rd_logo_white.png | 2c3c0c7dada0ab7440d27cf71a6c924b06e5d3c1dcf81cf8db29d59616fe33d5 |
| AppScope/resources/base/media/rd_logo_transparent.png | 0074b8954f937c0965f0a48ff5372528c0c274e7c4b1e0cb51600042dd746bce |

默认资源保持为 layered_image；两个新名称固定为 rd_white/rd_transparent，不接受文件路径或任意外部名称。

实际打包证据：Debug 与 Release module.json 包含两个正确名称/资源索引，compileSdkVersion 为 26.0.0.105，min/targetAPIVersion 均为 60100023。工具将 PNG 优化为 512×512 RGBA，白底 Alpha 全 255，透明底 Alpha 0–255；两款包内图已目视核对。源文件保持上述 1024×1024 哈希，不将包内优化误写为逐字节/逐像素相同。

## 验证清单

- Host：免费直调拒绝、恢复默认免费、真权益与 Release 模拟拒绝、账号/模式/关闭后的预检失效、过期复查、多窗口互斥、API23 成员零访问、未知/缺失资源、查询错误和回读不一致。
- 构建：当次 default@OhosTestCompileArkTS 与 signed assembleHap；实际 HAP 确认 alternateIcons、PNG 与 Release 权益模拟裁剪；Light、git diff --check。
- 独立审查：提交后复用 /root/review_pro_plan，只审 M3 增量。
- 设备：API26 三态 UI、三个预设切换/恢复、重启、白底/透明显示；API23 安装冷启动；Phone/Pad/PC、分身、多窗口、桌面/Dock/最近任务/Ability 图标同步。

未取得设备证据时保留未验收状态，不声称系统外壳所有位置同步。

复核修正：图标选择现在捕获 ProPurchaseLifecycle epoch，并检查父面板的即时 isOpen；关闭动画尚未结束或快速关闭/重开时，旧预检无法触发系统调用。系统回读不匹配时标记暂未确认，显示重读按钮。25 项 host 检查 PASS；修正后 default@OhosTestCompileArkTS `BUILD SUCCESSFUL in 12 s 476 ms`、signed assembleHap `BUILD SUCCESSFUL in 23 s 672 ms`，Light/diff PASS。

本轮结果：24 项 host 检查 PASS；default@OhosTestCompileArkTS `BUILD SUCCESSFUL in 16 s 823 ms`；signed Debug assembleHap `BUILD SUCCESSFUL in 29 s 338 ms`；Release assembleHap `BUILD SUCCESSFUL in 1 min 7 s 693 ms`；实际 Release setter/snapshot/decision 模拟分支裁剪检查 PASS，modules.abc SHA256 为 `54c2d339df12f7ce02373c83414dc02aa113113d919bd9d9b6df316b11156df9`。Light 与 git diff --check PASS。曾出现的 ArkTS 不允许任意类型异常重抛已改为固定 Error 并重跑成功。设备操作确认尚未收到，未安装本轮图标包或操作当前 SSH 页面。

最终复核：/root/review_pro_plan 对 62baa018+fea42b9b 给出代码与产物 PASS，无剩余 finding，独立重跑 25 项 host 检查。最终 Release `BUILD SUCCESSFUL in 50 s 755 ms`；实际 HAP 裁剪通过，ABC SHA256 `475414b946df74a29e421ad637e60c3dde54714297765aecd70208679cab4b53`。此结论不包含任何未执行的设备或正式购买验收。
