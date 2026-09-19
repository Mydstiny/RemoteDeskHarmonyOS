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
