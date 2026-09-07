# Pro 远程 AI：AI0 首批实现与接口证据

- 日期：2026-09-07；对应[完整计划](2026-09-07-pro-remote-ai-workspace.md)。
- 阶段：AI0 进行中。本批为插件源码、兼容性诊断与本地上游探针，不能当作 AI0 全部完成或局域网功能交付。
- 用户已授权开始实施，并要求 Codex/DSH 插件分别在 GitHub 管理；鸿蒙 App 才保留本地工作区。插件仅用临时本地副本执行验证，没有放入鸿蒙源码或创建长期本地插件 checkout。
- 鸿蒙当前活动分支沿用 `codex/pro-purchase-foundation`；同期 Pro、SSH、视频诊断等其他任务的修改不纳入本批。

## 1. 实际仓库与本批交付

| 仓库 | 内容 | 当前版本 |
| --- | --- | --- |
| [remotedesk-codex-plugin](https://github.com/Mydstiny/remotedesk-codex-plugin) | 标准插件 manifest/部署 Skill、独立 doctor、App Server stdio 传输与探针、后续公共协议目录、双语首页、用户/Agent 操作说明、CI、许可证/来源 | 0.1.0-alpha.1 |
| [remotedesk-dsh-plugin](https://github.com/Mydstiny/remotedesk-dsh-plugin) | 原生 Cordis 诊断插件、bundle patch、实际组件版本 doctor、原生运行时验证、双语首页、用户/Agent 操作说明、CI、许可证/来源 | 0.1.0-alpha.1 |

两个仓库初始为 private，通过 GitHub Git 数据 API 创建任务分支、提交和 PR。各自 PR #1 已在独立复核、精确提交 CI 和源码树一致性核对后 squash merge，任务分支已删除。未公开发布、未上架插件目录、未安装至本机用户 profile、未设置监听或自启动。用户操作文档只提供当前可执行命令，不虚构 install/start/pair 入口。

本批不向插件复制 App、RustDesk 核心、原始 Git 历史或账号数据；原创代码采用 MIT，外部运行时不随包分发。来源与已观察的接口/元数据哈希保存在各仓 `docs/provenance.json`。公共网络协议尚未冻结，DSH 尚未引入重复公共库。

## 2. Codex 证据

- 实际环境：Codex CLI 0.153.4，Node 26.4.0，macOS arm64。CLI 版本、官方生成 schema 与真实握手相互核对。
- 真实 App Server stdio：initialize → initialized → thread/start 通过；临时会话返回 `readOnly` / `untrusted` / `user`。无 turn/start，无模型调用，不读取用户历史。引擎自身可能写操作缓存/日志。
- 16 项源码测试通过：未知版本阻断、错误脱敏、提前取消、UTF-8 分帧、乱序请求关联、默认拒绝服务端审批、帧限额、未知响应、退出/超时、并发限额、缺失可执行文件，以及继承管道/忽略 TERM 的后代清理。
- 探针仅控制自己启动的 POSIX 进程组，关闭有界；SIGINT/SIGTERM 进入同一清理路径。Windows 进程树收尾未验收，stdio 探针明确拒绝该平台；不使用全局 pkill，不影响现有 Codex App。
- 上游 schema 的 thread/read、turn/start、turn/steer、turn/interrupt 和审批类型已核对。schema 存在不证明实现已接通。

仍待：实际模型回合、消息与回合关联、真实允许/拒绝/取消审批、恢复、差异、执行隔离、认证网络桥接。只读参数被接受不等于 shell/MCP/子进程/子 Agent 已按首发需求隔离。

## 3. DSH 证据与已确认缺口

实际 CLI 为 0.1.0-rc.6，但该安装解析的 dsh-base、dsh-agent、dsh-session、dsh-user-approval、dsh-user-questions 均为 0.1.0-rc.8；Cordis 为 4.0.1。doctor 检查整个实际组件组合，未知版本阻断，不只检查 CLI 标签。

- 6 项源码测试通过：组件漂移阻断、错误脱敏、仅观察选中会话、拒绝伪造/复用 ID 的实例、插件卸载后旧引用失效、准确处理 Agent 注销及替代实例。
- 真实 Cordis / SessionStore / AgentRegistry / ApprovalService / UserQuestions 运行时测试通过，Agent 为确定性内存 fixture，没有模型循环或用户 profile。
- 原生测试证明：插件加载/卸载、真实 session/event、默认 unavailable、显式 rejected、取消后 cancelled、晚到 allowed-once 不覆盖已取消审计、保留已有问答 provider，以及 Agent 注销时释放引用。
- 锁定 rc.8 的 `agent/disposed` 参数是 `{ agent }`，不是原始 Agent；独立复核发现并修复，真实运行时回归覆盖了此边界。
- 锁定 rc.8 的 `userQuestions.registerProvider` 只允许单个 provider。在线主分支的作用域化问答描述不能套用；当前插件不抢占本机问答入口。

仍待：真实模型 send/followup/steer/cancel、输入领取与 turn 终态关联、权限审批的多 UI 作用域分流、远程问答方案、受限执行 profile、DSH CLI 隔离 profile 安装/卸载/升级。`whenIdle()` 不能作为某条消息的完成依据。

## 4. 鸿蒙 API 23 安全传输核对

已查本地 API 23 SDK `ets/api/@ohos.net.webSocket.d.ts` 与 `@ohos.net.socket.d.ts`，没有修改 API 声明或关闭证书校验。

| SDK 能力 | 核对结果 | 实施含义 |
| --- | --- | --- |
| WebSocket 自定义 CA | `caPath` | 可以指定信任来源；实际证书链/主机名行为仍要上机测试 |
| WebSocket 客户端证书 | `clientCert` 中 certPath/keyPath/keyPassword | 当前接口要求 PEM 文件路径，不能声称直接绑定不可导出的 HUKS TLS 私钥 |
| WebSocket 校验开关 | `skipServerCertVerification` | 必须保持 false；不得用关闭校验解决隧道地址变化 |
| TLSSocket mTLS | ca/cert/key/password、isBidirectionalAuthentication | 存在低层 TLS 选项，但需要自己处理上层流协议与生命周期 |
| TLSSocket 服务端校验 | `skipRemoteValidation` | 必须保持 false；当前声明未找到独立 serverName/hostname 校验回调 |
| 隧道中的原身份 | 不能从 localhost 地址自动推导 | 必须验证证书身份与配对的实例身份一致，不只证明端口连通 |

下一步验证两个重点：客户端私钥在沙箱内的生成/保护/使用/清理；通过 RustDesk 本地转发访问时保留服务身份并保持标准主机名校验。候选方案（如实例专用 CA、显式 SAN 或受支持 native 传输）只有通过实际证书负例后才固定，当前不选取明文回退。

本次只读检查发现一台在线 phone，报告 API 26；未安装测试包、未执行 TLS/mTLS 或 AI UI 验收，也不能据此声称完成 API 23 设备矩阵。

## 5. Pro 与连接边界

已对照当前 `ProFeatureCatalog.ets` / `ProAccessPolicy.ets`：复用 `PRO_LIFETIME = pro.lifetime`，不新增第二份权益服务；功能声明包含 availability、版本/设备/协议/capability/permission 等条件。

专项计划的 `pro.ai.workspace`、`pro.ai.codex`、`pro.ai.dsh`、`pro.ai.rustdeskTransport` 仍是待注册的功能 ID，未加入当前生产可执行目录。两种后端和后续中继共用同一买断权益。本批插件没有购买授权能力。

首发仍为认证加密的 LAN。后续只复用用户拥有或获许可使用的 hbbs/hbbr 与标准 RustDesk TCP PORT_FORWARD；不运营新公网中继，不把 hbbr 当任意 SOCKS/WSS 代理。需要单独验证 RustDesk 设备认证、隧道许可、peer 端口转发和 TLS 身份。

## 6. 验证与审查记录

- Codex 插件 manifest 验证通过；两仓 npm 包内容预览通过，无账号/签名/机器配置或第三方运行时打包。
- 两仓 GitHub `source-checks` 在 Node 22、24、26 的源码测试和 pack 检查通过。真实上游集成仅覆盖上面记录的 macOS 组合。
- 独立 reviewer `/root/review_remote_ai_plan` 首轮发现两个 P2（Codex 后代持管道导致无限 close、DSH 注销事件形状错误），均已修复并加入回归；同一 reviewer 最终 PASS，无剩余 P1/P2；仅覆盖本批探针。
- 鸿蒙当次 `default@OhosTestCompileArkTS`：BUILD SUCCESSFUL in 47 s 616 ms；生产 `assembleHap`：重试 BUILD SUCCESSFUL in 8 s 88 ms。首次 assemble 在 2 min 18 s 972 ms 因 SignHap 11110001 / Input stream read error 失败，未签名包 ZIP 检查通过；同命令重试成功，未改签名配置。Light 与 git diff --check 通过。共享工作区仍有并发任务改动，本结果不代替它们各自最终验收。

## 7. 后续顺序

1. 补全 AI0 的执行隔离和真实回合/审批/恢复探针，并固定 DSH 本机/远程问答共存方案。
2. 完成鸿蒙证书/私钥与错误证书拒绝的实际设备原型，明确 API 23 与 API 26 证据范围。
3. 进入 AI1：统一 schema/测试向量、设备配对、项目与执行权限、请求幂等、事件恢复和撤销状态机。
4. Codex 打通一条 LAN 纵向链路后，按完整计划推进 DSH 与鸿蒙界面；AI5 验收前不开放正式付费能力。

## 8. 本批 GitHub 合并快照

| 仓库 | 合并提交 | 已复核源码树 | PR |
| --- | --- | --- | --- |
| remotedesk-codex-plugin | `ad3590d9629c41094b7752e35b30142b6dbe88a7` | `6b5cd214d2fba50b96cdb2129334732c9856e868` | [#1](https://github.com/Mydstiny/remotedesk-codex-plugin/pull/1) |
| remotedesk-dsh-plugin | `9b2a541c68a540c598ae902a9f5a0993dff1bcb8` | `528433eade8a8cbae975d70c59493eed1accae28` | [#1](https://github.com/Mydstiny/remotedesk-dsh-plugin/pull/1) |
