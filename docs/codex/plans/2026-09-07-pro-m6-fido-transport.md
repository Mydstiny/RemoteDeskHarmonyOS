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

## 第二增量：真实库与 OHOS 授权 I/O 桥接

- 以同一临时授权、配置/描述符验证及非强制接口 claim 为前提，新增可选 libfido2 INIT/GetInfo 能力验证；原 INIT 模式保留。UI 明示未执行 PIN、注册和认证。
- 锁定 libfido2 1.17.0 与 libcbor 0.14.0。双 ABI 静态库由实际 OHOS SDK 构建；自定义 I/O 后端默认不枚举、不打开设备。库仅使用应用提供的 read/write，不采用未经证实的 getFileDescriptor/ioctl 或受限 DDK 旁路。
- 原生 worker 只允许 broadcast INIT 与已验证 CID 上至多两次 GetInfo。固定 64-byte USB 报告、最大 5 秒原生期限、单次最多 1500 ms、304 个请求/300 次读取；真实库解析 GetInfo 并要求明确的 FIDO2 版本。注册、签名、PIN、重置、凭据管理和厂商指令无入口。
- N-API 以 env 与递增操作 ID 隔离；每个传输请求只交付一次，只接受当前请求的完整响应。旧账号、页面退出、取消、USB 错误或超时都会取消确切 worker；环境销毁唤醒并 join，释放库状态之前不遗留依赖 JS 回调的线程。
- CMake 仅 Debug 链接两库与 worker；Release 的 N-API 五个接口均惰性拒绝。实际 HAP 同时验证两 ABI ELF 中无 Debug 库标记，以及 ArkTS libraryAvailable/debugAllowed 与模拟购买门的真实剪枝。Debug HAP 必须作为正对照。
- [锁与构建来源](../../compliance/FIDO2_OHOS_PROVENANCE.md)记录上游下载/补丁/工具链/OpenSSL/zlib/输出哈希，完整许可、SBOM 与 artifact hash 同步。Light 增加实际依赖校验；SBOM 刷新保留上游公共领域声明。

当前证据：19 项生产 ArkTS USB/FIDO 检查、20 项真实库 C++ 传输用例（ASan/UBSan）、实际 N-API 参数/代次/跨环境/销毁/Release stub 检查通过。来源门覆盖六类不安全归档、四类篡改，以及实际 PowerShell SBOM 再生。独立临时构建逐字节匹配两 ABI 的全部 78 个输出/manifest；随后仅收紧归档路径规范化，最终 76 个分发文件保持相同。

代码门：testCompile 4 s 730 ms；signed Debug 5 s 590 ms（SignHap 888 ms）；最终独占再生 Release 7 s 795 ms（SignHap 855 ms），全部 exit 0。Light/diff 通过，ABC `446f31b8b89a68bd0a63bbce6999e0304e0a98d9a278efc822e43ffac5b1ee5e` 的全部门和两 ABI ELF 裁剪通过。早期并行 Debug 构建覆盖了共享 HAP；独占重跑后又检出未刷新的生成 DEBUG=true，保存证据并仅移除未跟踪 BuildProfile 后再生成通过。未修改签名或应用配置。独立 checkpoint 审查待执行。

此增量仍不是 RDPEWA：现有 FreeRDP CANCEL_CUR_OP/阻塞等待/内部 FIDO worker 生命周期必须先修正，再加入会话绑定、远端 RP 信息的本地确认、PIN 安全交互与实际 Windows 注册/认证。USB 真机拔插/取消/系统授权和手机官方 RP/origin 证据仍缺失；生产安全功能继续 planned。

状态记录门：testCompile 4 s 940 ms；signed assembleHap 5 s 928 ms（SignHap 881 ms），均 exit 0。完整上游分发字节通过 `.gitattributes` 禁止 EOL 自动改写；工作区并行变更不计入本增量审查。
