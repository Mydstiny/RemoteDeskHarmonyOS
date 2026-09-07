# M6：安全密钥与手机通行密钥

继续当前活动分支，先验证实际可用的 USB 传输，再接 FreeRDP RDPEWA。完整远端注册/认证成功之前，两项安全能力保持 planned，不进入正式售卖范围。

## USB 首个增量

- 本机 API26 SDK 的 usbManager 提供普通应用临时 requestRight、控制传输及 API18 中断传输/取消；不能将 DDK 的 system_basic ACL 要求泛化为所有 USB 路径的前提。
- Debug 模拟 Pro 中提供显式设备选择与初始化探测。只支持 PC/2in1、API23+、USB syscap。Release 服务入口编译为不可执行，生产安全密钥功能仍 planned。
- 仅枚举非 Boot HID 候选，选择后调用系统临时授权。先确认当前配置，读取并解析报告描述符，只接受 FIDO Usage Page 0xF1D0 / CTAPHID 0x01 的独立、未编号 64-byte 输入/输出报告。不能因为 USB class=HID 就发送 FIDO 数据。
- 不切换设备配置、重置设备、强制抢占接口、读取序列号或访问键盘/鼠标接口。只在描述符匹配后以 force=false 申请该接口。
- 只发送带随机 nonce 的 CTAPHID_INIT，验证完整包序、返回 nonce、CID、协议版本与 CBOR 能力。未发送注册、签名、PIN 或触摸请求，不把探测成功写成 RDP 认证成功。
- 每次操作独占，账号/模拟状态、面板关闭、后台、取消及超时使操作失效；异步授权后的旧操作不能连接设备。取消挂起传输，释放实际占用的接口及 pipe，迟到回调不更新新操作。
- 设备返回、枚举标签和错误均不进入原始诊断日志；结果只显示通道支持与下一步限制。

## 仍需闭合的实现

当前 FreeRDP 两个 ABI 的配置均未启用 CHANNEL_RDPEWA_CLIENT；RDPEWA 客户端依赖 libcbor/libfido2，现有 adapter 没有 AUTH_FIDO_PIN 的安全本地交互。后续须接 OHOS USB I/O、取消/拔出、会话隔离及 PIN UI，更新实际新增依赖的 SBOM、NOTICE、provenance 与哈希，再完成双 ABI 和真实 Windows RP 验收。

华为 OnlineAuthentication ArkTS 接入要求 RP 域名与应用关联。此证据不能证明可代理任意远端网站；手机通行密钥保持可行性验证，不能伪造 origin 或使用自建不安全中转替代官方路径。

## 证据与验收

- 本机 SDK：openharmony/ets/api/@ohos.usbManager.d.ts，requestRight/claimInterface/usbControlTransfer/usbSubmitTransfer/usbCancelTransfer。
- [FIDO CTAP 2.3 USB HID 定义与初始化](https://fidoalliance.org/specs/fido-v2.3-ps-20260226/fido-client-to-authenticator-protocol-v2.3-ps-20260226.html#usb-hid-init)。本实现按规范独立编写，不引入第三方 HID 库。
- 主机测试覆盖实际解析器与 USB 控制器，包括复合键盘拒绝、畸形报告、分片/顺序/nonce、授权拒绝和迟到、取消、断连、超时与释放。不以平台 mock 代替硬件证据。
- 本增量完成后执行当次 Hvigor 两门、Release 实包授权剪枝、Light/diff、独立复核并单独 commit。USB 硬件、PC 以及 RDP 端到端验证仍待实际执行。

首个实现提交 `3ea2859e`：13 项主机检查、本次 testCompile 15 s 695 ms、签名构建 18 s 891 ms、Release 38 s 395 ms、Light/diff 与实际 ABC 探测门剪枝均通过。独立复核发现 HID Local Usage 列表被覆盖的问题，已改为拒绝同一 Main item 前混合或重复 Usage，并拒绝尾部悬空 Usage；14 项检查覆盖 Collection/Input/Output 三处注入及实际控制器零 claim/零 INIT。修复后重新执行构建和复核，不沿用修复前产物。

修复 `ff31ef7d` 独立复核 PASS，无剩余 finding。14 项主机检查、本次 testCompile 7 s 876 ms、签名构建 10 s 927 ms、Release 35 s 455 ms、Light/diff 及 Release USB/模拟剪枝均通过；ABC `3511f23fca3443df1e075435846a6cd24bb9e93221cc34746cdf685b272597b5`。此 PASS 仅覆盖 Debug 初始化探测，USB/PC/RDP/手机认证验收仍待执行。
