# M5：连接分享与官方接续

继续当前分支；M5 分增量实现，共用显式白名单连接模型。代码、系统能力和真实跨设备验收分别记录。

## 第一增量：直连 SSH 官方接续

- API23 兼容的官方 UIAbility.onContinue、onWindowStageRestore、setMissionContinueState 和 distributedDataObject；当前只登记 phone/tablet、EntryAbility、直连 SSH，保持 experimental。PC 独立 RemoteSessionAbility 使用本机会话记录，不能把该记录伪装成跨设备句柄。
- 原生菜单中明确准备两分钟；同账号、双方独立 Pro、平台协同权限及对应主机配置全部检查。当前业务服务不依赖按钮隐藏来鉴权。
- wire version=1，只传主机引用、协议、端点、用户名、展示名称和声明的页面/文件目录。最多 8192 字符，即使按四字节 UTF-8 也小于官方 100 KB 限制。密码、私钥、PIN、信任记录、原生句柄、转发与未完成任务不入模型；未知字段/版本拒绝。
- 模型预留受限的 RDP 视图字段，当前 RDP 业务接续尚未开放；代理 SSH 不降级为直连，接收端也不能用同 ID 的不同端点直接连接。
- 系统 launchReason 必须为 CONTINUATION；公开 Want/深链不进入同账号接续。禁止系统复制原生页面栈和自动退出源端。冷启动加载原主机页，热启动保留现有页面和连接。
- 官方配置默认为 ACTIVE：应用启动先置 INACTIVE，只有用户主动准备后启用。接收方要求 pageStack/sourceExit 均为 false；合法冷迁移同步调用 restoreWindowStage，再在 onWindowStageRestore 复用原有初始化。热目标只登记请求并提示，不替换已有 Router 页面。
- 接收端在主机列表展示端点、限制和确认入口，经既有锁定/SSH 指纹/密码/密钥/MFA 鉴权再进入终端。仅带短时本机事务 ID 到页面，不能携带 authenticated 标志绕开原鉴权。
- 目标观察到原生 SSH 已连接，读取并恢复声明目录之后才通过官方分布式数据对象发就绪回执；源端仅在正确账号/窗口/会话和事务仍有效时展示手动结束按钮。失败、拒绝、超时都保留源端。
- 回执对象只存短小回执；随机会话 ID 和事务 ID 独立生成，重复投递、过期、未知/错误回执拒绝。加入通道有 2.5 秒超时，旧对象迟到完成不操作新对象。
- 普通终端进程不会迁移；持续进程需由用户自己的 tmux 等远端机制保留。目录恢复是 SFTP API 操作，不发送任何 shell 命令。

## 后续 M5 增量与外部前提

- 用户决定（2026-09-29）：RustDesk 与 VNC 远程桌面接续列入后续升级计划。当前界面与目录描述明确"目前仅支持 RDP 和直连 SSH"。实现时沿用同一白名单连接模型与接收端重新鉴权：RustDesk 仅传 ID/中继引用、显示名称与可恢复的显示器/画质选择，不传密码、一次性口令或会话令牌；VNC 仅传端点、Repeater/TLS 配置引用与视图缩放。两者都需先实现各自可恢复视图的读取/校验与接收端协议能力检查，并补充 host 回归和真实跨设备验收。

- Share Kit 的 knockShare / HYPERLINK + 官方 App Linking 需要已配置的关联域名；本路径没有 KNOCK_COLLABORATION 权限要求。API26 ServiceInteraction 的 KNOCK 消息通道属于另一条能力路径，其签名准入和 phone 声明不能混用，也不能从 windowId 推断 PC 准入。
- 关联域名和真实 fragment 投递仍待确认。不得编造公网邀请服务或加入未授权凭据传输；分享内容本身不授予接收者 Pro。
- PC 官方同账号接续、RDP 视图及其他协议按各自可恢复状态补充适配，不能把直连 SSH 增量当作全部 M5。

## 第二增量：直连 SSH 碰一碰分享

- 官方 API23+ Share Kit `on('knockShare', {windowId, sendOnly: true}, callback)`；API26 才读取 getInfo 坐标，坐标缺失时明确确认当前窗口，外部碰点拒绝。只撤销本模块注册的对象和 callback，不全局 off。
- 源端先预览地址、用户名、名称、目录并准备两分钟，碰一碰后再确认发送；当前窗口/页面、native SSH generation、账号 transition、Pro 运行时、目录和重新读取的持久 direct route 均需有效。单次 callback 先占用，异步及迟到重复不能复用。
- 只复制既有白名单模型；share purpose 必须清空账号 owner 和本地主机引用。固定编译期 HTTPS App Link + canonical `#rd=` fragment，拒绝其他域名、路径、query、非规范编码、过大与过期数据。fragment 不进入网站 HTTP 请求，但系统分享及 App Linking 是否完整保留仍需真机验证。
- 普通 SSH 接收免费。EntryAbility 只处理 viewData Want；冷启动保留正常初始化，热启动提示主机页确认，CONTINUATION Want 不进入分享路径。收件卡片不自动连接；确认后仅向新 SSH 表单预填基础字段，密码/私钥由接收者在本机填写。
- 接收确认绑定本机账号 generation；过期/账号切换阻止旧表单写入。用户修改端点或代理后可以按普通流程保存，分享目录不再自动恢复。仅对新保存的稳定 host ID 绑定短时本机标识，依旧经过原锁定、指纹、密码/密钥/MFA 流程。
- 手机/平板原路由和 PC 已认证独立窗口交接携带该短时标识。只有实际 SSH attach 和 SFTP 目录成功后才消费；PC 窗口启动不等于目录完成，移除鉴权载体页也不取消目标标识。原生 generation、页面、文件窗格或账号变化使旧恢复失效。
- Share Kit 的 Promise 完成只表示信息交给系统，不是目标 SSH-ready 回执；发送端不提供据此关闭会话的路径。跨账号确认回执、PC 官方 continuation、RDP 适配及设备矩阵仍未完成。
- `ProConnectionShareConfiguration` 暂返回空字符串：真实域名/App Link 声明/AGC 应用关联/系统 fragment 交付核验完成前，发送与接收均拒绝执行，不虚构生产地址。目录条目保持 experimental，不进入正式权益销售。

本轮当前 host 验证：27 项分享检查执行生产 policy/sender/receiver 和实际 Want、保存、路由、PC 交接、SFTP 恢复方法；34 项接续与 14 项文件碰一碰回归 PASS。代码提交 eca8f8aa 已由原 reviewer 独立复核 PASS，另追加 3 项真实源页面/发送异步边界检查 PASS；没有真实跨设备分享成功结论。

官方依据：[手机与 PC 互碰分享](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/knock-share-pc-phones-mutually)、[通过 App Linking 拉起应用](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/app-linking-startupapp)、[分享链接](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/share-utd-link)。API 声明按当前 DevEco SDK 的 `@hms.collaboration.harmonyShare.d.ts` 与 `@hms.collaboration.systemShare.d.ts` 核对。

## 本轮验收

生产类的主机测试覆盖：白名单与畸形负载、账号/端点/权限变化、重复/过期、源端保留、就绪回执与显式退出、旧通道异步超时隔离。默认测试编译、签名 HAP、Release 实际字节码隔离、Light/diff 必须通过后再提交并独立复核。

真机未验收：API23/26 两台同账号 Phone/Pad 的系统接续发现、冷/热启动、原生鉴权、目录恢复、真实回执与断网/取消。当前没有真实跨设备成功证据，experimental 不进入正式权益销售。

官方复核：[应用接续](https://developer.huawei.com/consumer/en/doc/best-practices/bpta-continue-cast)（2026-09-04 更新）确认默认 ACTIVE、冷/热回调、同步 restoreWindowStage、按需关闭页面栈和源端退出。DataObject 回执仍按本机 SDK 要求校验 DISTRIBUTED_DATASYNC；接续本身自 API12 免该权限，不把两者混同。

本次代码门禁：default 测试编译 BUILD SUCCESSFUL in 11 s 898 ms ；signed Debug BUILD SUCCESSFUL in 14 s 927 ms ；Release BUILD SUCCESSFUL in 53 s 363 ms 。25 项 connection、26 项 runtime、14 项 knock 和 49 项 SSH host 检查通过；Light/diff PASS。Release ABC SHA-256 9c782c92bbd29d11e0a839da5bc58959782686f73c786f3d694d9ba075dfbeba，实包模拟与实验授权路径审计 PASS。代码独立复核待进行；不代表跨设备验收。


## 首轮独立复核修正

首轮复核发现四项 P2，修正后重新执行门禁并复核：

1. 每次业务检查重新读取可读、有效的持久代理 profile 并复用 canonical runtime plan，只接受真实 direct；不以旧平面字段推断连接路由。目标 restore/complete 重读当前 HostSync 主机，旧对象不能证明新配置。
2. 源端与目标恢复同时绑定 native session generation 和实际 CONNECTED 状态。相同 sessionId 的恢复换代不能继承旧接续事务的关闭授权。
3. SFTP 读取之后重新核对声明的页面、目录及关闭状态；文件页关闭再打开也使原恢复失效。
4. 直接监听账号 transition activity，在 currentScope 更换之前就拒绝业务执行并清理活跃事务。Debug 模拟 Pro 不能越过该边界。冷启动、尚未确认且未绑定账号的官方数据可以等待账号初始化；此时没有通道或执行租约，必须在转换结束后由用户确认最终账号，旧接受请求失效。

新增回归执行实际 profile store/runtime policy 和生产 SshTerminal 的准备/恢复方法，当前共 33 项 connection checks PASS。独立复核与最终构建结果另记；真机矩阵仍未执行。

修正后当次门禁：default 测试编译 BUILD SUCCESSFUL in 11 s 201 ms；signed Debug BUILD SUCCESSFUL in 30 s 278 ms；Release BUILD SUCCESSFUL in 55 s 966 ms，全部 exit 0。33 项 connection（含真实页面方法）、49 项 SSH、Light/diff 与 Release 审计 PASS；ABC SHA-256 e617e8f253a95b570e0a892f6fc6207d08d7533dd355cec8963c8597a4e9d328。修正独立复核待进行。

最终独立复核 PASS：精确 ed537821 + 27716d2d + c64efc8e；最后补充按事务 ID 条件取消，旧页面迟到不能取消新目标。34 项 connection（含真实页面方法）独立通过；最终 compile24s782、signedDebug36s942、Release49s746，Light/diff/Runtime 实包剪枝 PASS。ABC 1211b5ab54a2090731ee37b3836aa89a14d7a2221e054ed11a1c6e1267d6a9db。共享构建当时包含正在开发的 M6 Debug USB 探针，不把该代码计入 M5 审查；全 M5 与真机跨设备仍未完成。

本增量最终门禁：testCompile BUILD SUCCESSFUL in 21 s 270 ms；signed Debug BUILD SUCCESSFUL in 1 min 13 s 939 ms；Release BUILD SUCCESSFUL in 1 min 18 s 655 ms，全部 exit 0。Light/diff PASS。独立 Release 模拟/USB/sandbox 剪枝与空 App Link getter 审计 PASS，ABC 87648ef2ddb21f6ecd3d515c8ae96cba673d090c38b083b36798edb05488b519。产物包含并行 AI/文件传输开发代码，审查只覆盖上述增量与 Pro 剪枝。


## 第三增量：PC 独立 SSH 窗口官方接续

- `RemoteSessionAbility` 增加 continuable；保持原 multiton、exported=false 和普通会话授权入口。每个新 mission 先置 INACTIVE，仅当前实际窗口、native SSH generation、账号和 Pro 租约有效且用户明确准备后置 ACTIVE。进程同时只准备一个源窗口，关闭其他窗口不会取消它。
- 接收只处理系统 CONTINUATION launchReason，同时要求 pageStack/sourceExit 均为 false。合法报文同步 restoreWindowStage；不激活跨设备传来的本机会话记录，不复制 native handle。重放、过期和无效报文拒绝并结束新建临时窗口，不取消原有有效收件。
- onWindowStageRestore 使用既有独立窗口引导页，只向本机 EntryAbility 传已有短时事务 ID。冷主窗口执行原账号/数据库初始化；热主窗口仅提示已有收件，不改当前页面。回到主机页仍需明确确认，再执行原锁定、指纹、密码/密钥/MFA 流程。临时窗口启动和转交成功均不发送就绪回执。
- 临时窗口使用本机 LocalStorage 标记转交成功；启动失败、页面关闭、账号变化、过期与迟到回调都按事务 ID 隔离。尚未转交时销毁会清理本事务；成功转交后销毁不清理主窗口收件。收件卡片迟到完成也只能取消自身事务。
- 删除 SSH 页中两处 PC 排除条件，目录恢复和真实 native generation 检查复用已审查路径。功能仍为 API23+ Debug Pro 实验项，协议仍仅 SSH；Free/Release、缺协同能力或权限、未发布 RDP 路径均拒绝。
- 45 项接续检查覆盖实际 ability、引导页及收件卡片的方法，包括普通 Want、冷/热 multiton restore、重复/过期、主窗口启动失败、旧页面迟到、按窗口取消和主窗口既有收件提示。另 27 项 runtime、27 项 share 和 49 项 SSH 检查 PASS。此处平台 API mock 不能证明实际设备系统回调顺序或跨设备成功。

官方核对：[应用接续](https://developer.huawei.com/consumer/cn/doc/best-practices/bpta-continue-cast) 明确默认同 UIAbility 接续、multiton 接收走 onCreate、onWindowStageRestore 和同步 restoreWindowStage，且不支持模拟器。实际不同设备、同账号协同条件及 exported=false 的系统接续准入需要真机验收。

本次代码门禁：testCompile `BUILD SUCCESSFUL in 19 s 518 ms`；signed Debug `BUILD SUCCESSFUL in 24 s 154 ms`；Release `BUILD SUCCESSFUL in 36 s 906 ms`，全部 exit 0；Light/diff 和实际 ABC 模拟/USB/sandbox 剪枝 PASS。ABC SHA256 `05f4687700cf203ae6e212e1cf8bebadfd2d1cee7a816af279930ceb885c3449`。初始 ArkTS 显式类型问题已修正；共享 native/ArkTS 构建遇到并行手机控制模块尚未落盘/未完成，待对应任务完成后成功重跑。十份本增量源码 hash 保持，其他任务代码不计入本范围。提交和独立复核待进行；全 M5、RDP 与真实跨设备验收仍未完成。


第三增量独立复核 PASS：精确 `4719e6dc` → `3fc4a578` 的十份源码/测试及六份文档；148 项原检查和 13 组新增生产方法生命周期、授权与旧请求边界通过。冻结代码、五个并行状态子树、第七批 UI receipt 和实际 Release 剪枝已独立核对；无待修问题。元数据门禁 testCompile 19 s 836 ms、signed assembleHap 38 s 286 ms（SignHap 984 ms）均 exit 0，Light/diff PASS。真实 PC/跨设备矩阵仍未执行。

## 第四增量：RDP 身份与视图接续

- API23+ Phone/Pad/PC 复用已审查的系统接续入口、同账号及双方独立 Pro 授权，只在 Debug 实验模式执行。新增 RDP 源控制栏入口和收件说明；Release/Free 不获得实验授权，普通连接仍走原流程。
- SSH V1 白名单保持兼容；RDP 使用 V2、continuation-only，新增严格四字段非秘密 identity（canonical route、authMode、username、domain）。只允许当前实现的单显示器 monitor=0、缩放/平移、三种输入模式和严格边界标志；未知字段、非有限数、保留旋转/显示器及 V1 RDP 拒绝。
- 路线按既有 `rdpRouteIdentity` 绑定直连/透明 TCP/Microsoft Gateway，包括目标/网关端口、TLS server name 和 Gateway transport；不支持的堡垒机路线拒绝。每次业务检查重读当前配置和已保存用户名，不读取密码/hash/证书信任。连接时询问的凭据必须在原生 connect 前与目标声明的实际 username/domain 匹配。
- 只在真实 native CONNECTED 和账号 generation 仍一致后，按 native sessionId/generation/ownerToken 保存内存身份回执。回执随既有 PC 已认证窗口交接复用，不进入 Want；账号 transition 和准确 teardown 删除。源端描述绑定这次原生连接的身份，页面字段或凭据引用不能冒充认证回执。
- 目标沿用原锁定、证书、凭据与原生连接流程；进入真实会话后按目标窗口像素尺寸调用现有 RDP canvas clamp 恢复视图。输入模式使用当前会话 override，不改其他窗口偏好。不同尺寸下平移可能被现有边界规则收敛；不宣称像素布局跨屏完全相同。
- 原 renderer 的 transformVersion 只是布局发布，不能证明显示。新增同一 seqlock 下的 presentedTransformVersion，仅 RAW/OES/retained 三条 `eglSwapBuffers` 成功分支发布；失败、几何或变换改变清零。两个读取器补充 acquire fence，主机并发测试覆盖一致性。
- 目标只有本次提交产生新版本、该版本已成功呈现、RDP desktop/source 尺寸一致且无 Display Control/resize pending，再结合当前原生/账号/窗口/页面/输入视图后才发送就绪回执。原生提交失败不得复用旧成功版本。视图等待有界；页面/Surface 重建、后台、用户调整、过期、替换与迟到请求均隔离，失败保留两端普通会话。
- 来源正常后台保活可等待回执；断开/换代使旧来源失效。仍需匹配回执后由用户手动结束来源；Windows 桌面是否复用及普通进程保留取决于服务器策略，不迁移密码、Windows 进程或未完成传输。
- 23 组新增检查执行生产 identity/envelope/view/store 和实际 RemoteDesktop 准备/恢复方法，50 组共享接续检查包含 RDP 服务重新认证、fresh route、错误身份及 ACTIVE 等待取消。另 27 share、27 runtime、18 RDP direct-touch PASS；实际 renderer 方法编译并发观察 222127 次、两条 OHOS ABI 编译参数下 syntax PASS。平台/native 模拟不等于真实 EGL、Windows 或跨设备验收。

第四增量当前代码门禁：testCompile `BUILD SUCCESSFUL in 7 s 699 ms`；signed Debug `BUILD SUCCESSFUL in 9 s 464 ms`（SignHap 907 ms）；Release `BUILD SUCCESSFUL in 32 s 568 ms`，全部 exit 0。Light/diff 与实际 Release 模拟/USB/sandbox 剪枝 PASS；ABC `e3dbffa03ce3faddefe4b3ccebc99f07b9612eeaa1b96e9886e037403c1f1c8b`。初始 CanvasViewport 显式类型问题已修正，缓存访问及并行剪贴板未完成导入在成功重跑前处理；没有把并行文件纳入本增量。独立复核和真实 Phone/Pad/PC RDP 接续仍待完成。

第四增量独立复核 PASS：精确 `35e38224` 与修复 `13413239`。唯一 P2 是 pending transform / viewport snapshot 两条 seqlock 缺少成对屏障；两个 publisher 在 odd 标记后增加 release fence，ApplyPending 在 payload 读取后增加 acquire fence。真实 OHOS ARM64 编译的两个 writer 出现 `dmb ish`，三个 reader 出现 `dmb ishld`；该证据与 C++ 内存模型共同支撑修复，不以宿主压力通过代替弱内存或真机证明。[标准依据](https://eel.is/c++draft/atomics.fences)。

同一独立 reviewer 确认无剩余 finding：原始 145 项检查、十组真实路由/窗口交接、100 组 SSH V1 与父版本对照通过；扩展的实际 SetCanvas→ApplyPending→Publish/GetViewport/GetCanvas 三线程测试 2,084,838 次观察及快照 9,632 次观察、三条 swap 成功边界、双 ABI syntax 通过。17 份初始身份/页面/服务/声明/测试与最终两份 renderer/harness 用两个有限范围 receipt 分别记录，明确排除中间 phone/clipboard 提交。

修复当次门禁：testCompile `BUILD SUCCESSFUL in 4 s 909 ms`；signed Debug `BUILD SUCCESSFUL in 1 min 3 s 383 ms`（SignHap 877 ms）；Release `BUILD SUCCESSFUL in 32 s 723 ms`（SignHap 949 ms），均 exit 0；Light/diff 与独立 Release 实包授权剪枝 PASS；ABC `54043c4f4eb725ea4a0f38c3de5e9af7cb1eaf005482c2b0cb6830cb87f3df31`。初始缓存 EPERM 获准重试；首次签名构建遇到并行 Rust 声明编辑，由其 owner 修正后成功重跑。真实 EGL/Windows/Phone/Pad/PC 系统流转、DDO 与全部 M5 验收仍未完成。

复核记录门禁：testCompile 5 s 349 ms、signed assembleHap 6 s 198 ms（SignHap 942 ms），exit 0；Light/diff/state PASS。初始资源打包在四个 locale 的生成目录遇到内容完全相同的 `string 2.json`；保留证据后仅清理这些生成副本，应用源资源没有修改。
