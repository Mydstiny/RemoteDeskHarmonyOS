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

- Share Kit + 官方 App Linking 需要已配置的关联域名。API26 ServiceInteraction KNOCK 消息通道需要 KNOCK_COLLABORATION 的签名准入，SDK 权限表声明 phone；不能从存在 windowId 推断 PC 准入。
- 仍待用户确认域名/准入。不得编造公网邀请服务或加入未授权凭据传输；邀请本身不授予接收者 Pro。
- PC 独立会话、RDP 视图及其他协议按各自可恢复状态补充适配，不能把第一增量当作全部 M5。

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
