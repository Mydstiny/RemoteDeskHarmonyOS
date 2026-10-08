# Pro M1/M2 实施准备与验收计划

- 日期：2026-09-07。
- 来源：[Pro 总体路线图](2026-09-06-pro-product-roadmap.md)。
- 状态：M1/M2 代码已实现并通过本轮构建/host/Release 产物检查；独立代码复核与完整设备矩阵分别记录。每个阶段单独 commit，保留纠错边界。
- 基线：活动分支 `codex/pro-purchase-foundation`，准备时 HEAD `0000d4ca4666d2717c06fd38d00eb05fe977fee5`，相对 main 领先 5 个提交。
- 独立计划复核：`/root/review_pro_plan`；六项约束已纳入，实施准备文档复核通过，未发现阻止 M1/M2 开工的遗漏或冲突。该结论不是代码审查 PASS。

## 1. 重新审视后的结论

总体产品方向保留。先完成统一权益与调试底座，再用真实功能完成 B3，最后按已交付内容和可信购买闭环决定销售时间。API 26 图标、文件协同、接续、USB FIDO2、手机通行密钥各自独立验收；高不确定性的认证链路不阻塞可独立交付功能。

首批不能只增加一个 isPro 按钮：当前模型与计划存在权益清单、验证结果、缓存时间、订阅接线和 Debug 发行隔离五类差距，必须一起约束，避免产生模拟授权或旧账号错误授权。

补充工作线：[API 26 基础 UI 升级](2026-09-07-api26-base-ui-upgrade.md)面向全部用户免费，独立 U0–U4 推进；不依赖 Pro M1/M2 或后端完成。与本计划共享的页面和适配代码需协调修改顺序。

## 2. 首批范围

| 纳入 M1/M2 | 后续阶段 |
|---|---|
| 稳定功能目录、买断权益模型、显示/执行策略与原因 | Pro 图标等真实功能；基础 UI 另按独立 U 线推进 |
| 明确验证成功、无权益、撤销、暂不可用的结果语义 | 真实服务器验单、发货和持久离线缓存 |
| 应用账号生命周期接线与多窗口订阅 | 碰一碰、分享、接续和认证协议实现 |
| 运行期 Debug 三态及正式包隔离验证 | 工作区/主机管理/个性化等候选功能交付 |
| 现有 Pro 面板显示真实/模拟状态、Debug 工具区 | 修改现有免费连接、画质、输入、文件或安全能力 |
| 定向策略/运行时测试与构建/产物验证 | 生产 SKU 启用和正式收费 |

M1/M2 结束后所有现有 Pro 预告仍可保持 planned。模拟 Pro 不会凭空产生已交付功能；真实完整接入样例属于 B3/M3，不能以测试夹具替代。

## 3. 当前代码映射与修改落点

| 当前文件 | 当前事实 | 实施动作 |
|---|---|---|
| `entry/src/main/ets/services/pro/ProAccessPolicy.ets` | 功能目录在此文件内，仅 available/planned；授权匹配 featureIds | 拆出稳定目录，新增发布/版本/设备/协议/权限上下文；按 entitlementIds 匹配买断权益 |
| `entry/src/main/ets/services/pro/ProEntitlementService.ets` | verifier 返回 grant 或 null；null 清空权益；尚无业务实例 | 类型化验证结果；保留可信当前权益的暂不可用语义；接入统一运行时和刷新边界 |
| `entry/src/main/ets/components/ProPurchaseSheet.ets` | 静态权益预告和沙盒测试按钮，没有全局权益订阅 | 订阅运行时、显示真实/模拟状态；沙盒及模拟工具限制为 Debug |
| `entry/src/main/ets/pages/HostListPage.ets` | 已有底部 Pro 入口和设置叶弹层 | 保留永久入口；按快照更新摘要/状态；不给现有免费设置加锁 |
| `entry/src/main/ets/services/AccountSessionCoordinator.ets` | 已有 currentScope、账号转换和发布机制 | 复用其账号事实/订阅，必要时增加最小接线；不另建登录流程 |
| `entry/src/main/ets/services/pro/ProPurchaseLifecycle.ets`、`ProBillingService.ets` | 沙盒预检、全局单次购买、关闭弹层隔离已有实现 | 保留购买生命周期，模拟模式不得授予真实订单或提前完成发货 |
| `entry/src/test/ProAccessPolicy.test.ets` | 已有免费、计划中、账号/环境、时间和取消下单测试 | 更新权益模型并新增真实边界用例；运行时测试与其分离 |
| `hvigorfile.ts` / `entry/hvigorfile.ts`（仅在必要时） | 当前使用默认插件，无 Debug 模拟构建隔离规则 | 经本机工具链小验证后选择构建模式隔离/裁剪；不把机器签名配置提交仓库 |

拟新增角色：ProFeatureCatalog、ProRuntime、ProDebugController、统一 UI 绑定组件；命名随代码风格细化，不制造重复服务。现有目录 ID `pro.workspaces`、`pro.hostManagement`、`pro.personalization` 先保留；新子能力使用总体计划中的稳定 ID，避免无意义重命名。

## 4. 六项必须落实的设计修正

### 4.1 买断权益与功能列表分离

可信结果使用 `entitlementIds`，功能声明使用 `requiredEntitlementId`，同一买断范围统一为 `pro.lifetime`。两个不同版本发布的功能均可由同一买断权益访问。

不将旧 featureIds 自动升级为 lifetime。当前没有已上线授予或持久化旧授权的证据，实施前再确认引用与存储；若发现真实旧记录，单独设计可信迁移，不作宽松兼容。未明确标注的新功能默认免费；未注册的受保护入口默认拒绝，两者含义不同，不影响原有免费路径。

### 4.2 明确缓存时间与验证结果

买断不使用订阅到期语义。可信缓存元数据区分 `verifiedAt`、`revalidateAfter`、`usableUntil`（最终字段名可调整），各值与时钟须验证有限值和顺序。到达重验时间可触发刷新，到达可用边界则返回 `verificationRequired`，不显示成“许可证到期/必须再买”。

验证结果至少区分：verified（明确权益）、noEntitlement、revoked、unavailable。后三者不能共同压成 null。unavailable 或异常不能伪造撤权：仍在可用期的可信快照按既定规则保留；无可用快照时不授权。只有当前账号/环境、可信且新鲜的明确结果可以清空或撤销权益。

本阶段实现类型和内存生命周期，不伪装已实现签名离线存储；持久缓存与离线宽限期数值留给可信后端阶段确定。grant 复制保护、验证请求 generation 隔离、订阅异常隔离一并测试。

UI 在缓存生效边界改变时刷新，不能只靠 bindAccount/reconcile 通知；前台恢复与时间边界重新判断，业务执行始终按当下时间复查。

### 4.3 显示、执行与权限可申请性

目录使用数字 minAppVersionCode/minApiVersion；设备类型集中归一化。缺失/未知设备对受限 Pro 功能不授权；协议、会话、窗口和远端目标条件由每次调用传入，不设全局“当前协议”导致不同窗口串状态。

正式操作入口只允许 released/已验收能力；planned、experimental、disabled 及版本/API/设备不支持都隐藏，即使模拟 Pro 也不绕过。显示与执行共享同一决策对象并返回原因。

可申请系统权限尚未授予时，具备权益与静态能力的用户可以看见触发授权的入口，执行结果为 permissionRequired，授权成功后再次鉴权。被系统永久拒绝、硬件不支持与“尚未申请”分别解释，不能隐藏所有入口导致永远无法申请权限。本批主要固定接口和测试，实际权限申请由后续对应功能负责。

### 4.4 Debug 三态与发行隔离

三态为真实、模拟免费、模拟 Pro，默认真实，仅当前运行期有效，重启恢复。模拟层覆盖本地权益视角，不制造 ProVerifiedGrant，不改 owner/environment、订单、可信缓存或服务端权限。正式服务端不接受模拟身份。

Debug 工具入口位于 Pro 面板开发者区域，与现有沙盒工具合并；在所有相关已打开界面显示明确模拟标记。正式构建入口只解析到真实实现；模拟实现或其全部可执行分支必须从正式产物排除，不靠按钮隐藏证明安全。

本机 Hvigor 已有 BuildProfile.DEBUG 常量和 branchElimination 配置支持；官方说明 release 可裁剪静态不可达分支。这是候选方案，尚未在项目产物验证。先做最小构建验证再选择模式隔离/裁剪实现，不能用代码含 if(DEBUG) 就宣称通过。

M2 必须追加 Debug 与 Release 构建，检查实际 HAP 的模块/字节码，证明模拟授权计算、模拟 setter 生效路径及调用链均不可执行。不能仅搜索 UI 文案或只验证 DEBUG=false；结合产物结构和负向入口测试留存证据。若裁剪失败，M2 不通过，改用构建模式分离实现。

### 4.5 一个权威运行时与生命周期接线

真实权益、调试视角和监听由应用统一运行时持有；页面和弹层订阅快照/revision。AppStorage 可发布显示数据/刷新信号，不能作为授权输入。复用现有窗口运行时组织方式，验证多个 UIAbility/窗口是否共享同一状态；不把模块静态变量自然等同于跨进程共享。

绑定应用可信账号转换，立即隔离旧账号/旧请求；不得混用 RustDesk Server Pro 凭据，也不得仅凭云数据库 ready 判定购买身份。账号转换开始、失败/回退、完成和退出都要覆盖；同账号普通页面重建不无谓清空权益。

订阅时立即给当前状态；弹层打开后切换也能刷新；销毁退订；重验/时间失效同步刷新；隐藏入口处理焦点回退且不留占位。业务执行不读取 UI 中缓存的 allowed。

### 4.6 交付状态与免费能力不误报

M1/M2 是基础设施与开发调试交付，不是正式 Pro 商品或真实付费功能交付。目录预告不改为 released 以展示按钮；测试夹具放测试范围。关闭模拟或明确撤权不删除配置，不突然中断免费远程连接。

## 5. 实施顺序与检查点

1. 固定当前计划检查点，确认本分支已有文档与演示代码归属。
2. M1a：重构权益/验证结果类型和目录声明，更新原有测试并验证免费行为、老用户跨版本权益。
3. M1b：统一显示/执行决策、能力原因、运行时订阅和账号接线；验证并发与生命周期。
4. M2a：先证明 Debug/Release 构建隔离，再接入三态控制器与 Pro 面板，不反向依赖可写 UI 状态。
5. M2b：完成多订阅者/打开弹层刷新、重启恢复、生产产物负向检查。
6. 运行当次强制构建、定向测试、Light 和差异检查，checkpoint commit；新代码单独独立复核，修复后复验。
7. 更新状态，标明 M1/M2 与真机验证各自结果。B3/M3 的真实功能再开始；生产后端和正式收费继续关闭。

当前活动购买任务尚有外部集成项；首批完成不能冒充全部 Pro 完成。按仓库规则在同一分支推进。闭环时明确本次可独立交付范围，将未完成的后端/设备等事项记录为后续任务；这些 Pro 余项不自动成为独立验收的基础 UI 合并与发布前置条件。实际提交仍须完成对应构建、独立审查、PR 和 required check，并如实关闭或归档当前范围后再开启下一任务，不能并存多个日常活动分支。

## 6. 最小验收矩阵

| 场景 | 预期 |
|---|---|
| 无账号、无订单、模拟免费 | 现有免费连接与设置正常 |
| 同一 lifetime grant 访问两个版本的已发布测试功能 | 均允许，无需新增订单或功能清单 |
| 旧 featureIds、错账号/环境、缺失权益、非法时间 | 拒绝，不自动升级授权 |
| 未知/planned/experimental/disabled、版本/API/设备不支持 | 即使模拟 Pro 也拒绝并隐藏 |
| 可申请权限尚未授权 | 合格 Pro 用户可见申请入口，执行返回 permissionRequired |
| 两个不同协议会话窗口 | 各自决策，不受另一窗口的协议状态污染 |
| 两个订阅者和已打开弹层三态切换 | 立即同步；退订后不再回调 |
| 暂不可验证、明确撤销、缓存可用边界到时 | 分别保留可用可信权益、收回、提示重验 |
| 切账号、并发新旧验证、迟到回调 | 旧结果不能授权新账号 |
| 模拟与真实购买状态对照 | 订单、真实 grant、账号、缓存不变 |
| 重启与退出模拟 | 回到真实权益，不需重新购买且配置保留 |
| Release 实际 HAP | 无模拟授权可执行路径；沙盒开发 UI 不出现 |
| 已隐藏入口键盘/无障碍导航 | 不可选中，无空白占位，已有焦点合理转移 |

最低门禁：default@OhosTestCompileArkTS、assembleHap、定向策略/运行时测试、git diff --check、Light；测试模块受影响增加 ohosTest@OhosTestCompileArkTS。M2 增加 Release 构建与产物检查。设备不可用时明确记录，不把测试编译或 host 测试当成真机通过。

## 7. 当前准备结果与余项

- 已完成计划独立复核、代码入口核对、实施边界和验收矩阵。
- 已确认现有策略存在 featureIds、null 语义与订阅接线差距；后续按本计划修正。
- 构建隔离方案需要 M2 实施时验证真实产物；目前只确认工具链支持候选机制。
- 外部验单服务和真实设备仍是后续生产/设备验收条件，不阻塞 M1 类型与策略开发。
- M1 已实现功能目录、lifetime 权益策略、类型化验单结果、受控内存缓存与过期/时钟回拨保护；现有免费能力不变。
- 本次验证：16 项 host 策略/运行时检查 PASS；default@OhosTestCompileArkTS BUILD SUCCESSFUL in 56 s 813 ms；assembleHap BUILD SUCCESSFUL in 44 s 105 ms；Light 与 diff check PASS。
- M1 阶段提交：`eaca0300dbb75c1785348b1bdabda4961e873c3a`。
- M2 已实现账号转换开始同步隔离、重叠转换保护、统一运行时/无占位显示组件、订阅刷新、时间边界通知、Debug 三态与正式包裁剪；作为独立阶段提交。模拟不修改真实 grant，不解除未发布/API/设备/协议/系统权限/服务端边界。
- Release assembleHap：BUILD SUCCESSFUL in 2 min 10 s 755 ms；`check_pro_release.py` 对实际 HAP 中 ProRuntime setter/snapshot/decision 反汇编检查 PASS，setter 无模拟写入，decision 保留真实策略调用。modules.abc SHA256：`4eee962092bec62f7fe2ccf902fd46dd066dc9c6a5a0929227a8a41d1f4121a7`。
- 附加 `ohosTest@OhosTestCompileArkTS` 探测返回 00306054 task not found，与既有任务注册限制一致；本阶段未改 `entry/src/ohosTest`，默认强制两门均已通过。
- Release 包已保留数据覆盖安装并启动于 API 26 phone；设备正用于 SSH 会话，未完成 Pro 弹层三态、深浅色/焦点、多窗口和 API 23 实机验收。此处不把 host 测试或安装成功当作界面验收。
- 正式服务器验单、持久可信缓存、购买发货/退款仍属于 B4/M4；所有 Pro 功能预告保持 planned，正式收费关闭。

官方构建参考：[branchElimination 与 BuildProfile.DEBUG](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-hvigor-build-profile-app)。
