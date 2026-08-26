# Moonlight 完整升级实施台账

> 任务：`moonlight-complete-upgrade`
> 分支：`codex/moonlight-complete-upgrade`
> 初始基线：`main@aeb0cdac5`，与 `origin/main` 一致
> 总计划：`docs/superpowers/plans/2026-07-28-moonlight-harmonyos-complete-upgrade-plan.md`
> 台账状态：当前 HEAD `348b28083`，分支相对 `main` ahead 143。`9eadb35be` 完成实体手柄 runtime，`326f329f5` 完成 Sunshine 串流底层加固，`348b28083` 完成本地 launch/settings 流。当前未提交增量正在完成可选第九云表、旧八表兼容、owner-store v5、selection/reconcile/delete/backup 生命周期和兼容性优先下载；最终 HDC/UI 验收按用户要求等底层、云同步、UI 全部完成后统一执行。
> 2026-08-19 范围覆盖：2026-08-10 的云同步 parked 决策已撤销。`moonlightrecordv1` 改为“AGC 精确 schema 创建并确认后增量启用”；revision 0 只是部署前熔断。所有更早的 local-only/parked 文字均是历史记录，不得用来永久隐藏新功能。

## 1. 执行约束

1. 严格按总计划第 15 节的 G0 → D1 → D2/D3 → N1/N2/N3 → U1/S1 → R1 顺序推进。
2. Moonlight 是独立协议域。不得把 host、profile、trust、identity 或设置写进其他协议表。
3. 尚未通过能力探针、真实 Sunshine 和 ARM64 真机门禁的功能保持 fail closed，不以占位实现宣称支持。
4. `moonlightlocalrecords` 是始终可用的 owner-scoped 本地事实层，`moonlightappcache` 永远可重建且不进云；`moonlightrecordv1` 是唯一可选云表，只承载用户显式选择的 settings/host/profile。trust、identity、私钥和证书永久设备本地。
5. 每个代码任务将测试与实现同提交；阶段末执行 native/ArkTS 定向测试、双 Hvigor、assembleHap、Light 和一次有界复核；数据任务必须覆盖 owner lease、v4→v5、旧八表、备份、恢复、删除、空/坏/未来快照和账号切换。
6. 本任务最多保留两个审查智能体实例；当前云同步复核复用 `01a018c6-e83c-7ac3-a578-7330b528a3af`，不得因上下文压缩重复创建 reviewer。
7. 虚拟机用于开发期 UI 和基础能力验证；最终媒体、输入、功耗、后台和网络结论以用户 ARM64 实机验收为准。

## 2. G0 执行状态

| ID | 状态 | 当前证据 | 后续门禁 |
| --- | --- | --- | --- |
| G0-01 | PASS | 2026-08-09 从干净 `main@aeb0cdac5` 创建唯一任务分支；初始 ahead/behind 均为 0 | 状态文档和代码范围随 checkpoint 更新 |
| G0-02 | PASS | 官方四仓 HEAD、common-c 子模块、关键文件哈希已锁定，见第 3 节 | N1 vendoring 时重新核对 remote HEAD；任何升级重新审计 |
| G0-03 | PASS FOR N1-01 / RELEASE CONDITIONAL | GPL/AGPL、MIT、Apache-2.0、BSD-3-Clause 组合边界已落到 NOTICE、SPDX、artifact hashes、source offer 和离线 tree 校验 | 最终二进制发布仍需完整 release approval/源码归档；任何上游升级重新审计 |
| G0-04 | PASS FOR POLICY | 已核对 Sunshine `GHSA-ph75-mgxh-mv57`；最低允许版本固定为修复版 `v2026.516.143833` | N1 serverinfo 必须 fail closed 阻断更低或不可判定的危险版本；真实主机复测 |
| G0-05 | STATIC PASS / RUNTIME PENDING | API 23 双 ABI 编译和链接通过；虚拟机为 ARM64 API 24，系统服务存在 | 增加仓库内独立 probe target；探针必须在 HAP/AppSpawn 进程内运行，独立 `/data/local/tmp` 结果无效 |
| G0-06 | PARTIAL | 虚拟机确认 AVCodec、AudioPolicy、输入、网络、Keystore、Asset 服务；枚举到键盘/鼠标/触屏/触控板 | H.264 Surface、Opus、音频焦点、pointer capture、实体手柄和高级反馈需 HAP 内/实机探针 |
| G0-07 | EXTERNAL PENDING | 尚未登记两台可恢复的真实 Sunshine 主机 | 允许继续纯模型、构建和 local-only UI；不允许宣称 host-control/streaming ready |
| G0-08 | FROZEN FAIL-CLOSED | MVP 和首发禁用能力已冻结，见第 7 节 | 只有对应 capability receipt 通过后才能逐项打开 feature truth |

## 3. 2026-08-09 官方上游锁定

所有来源均为官方仓库，只把 commit 当作内容身份；标签只是可读版本名。

| 组件 | 官方来源 | 固定 revision | 可复现证据 |
| --- | --- | --- | --- |
| moonlight-common-c | `https://github.com/moonlight-stream/moonlight-common-c` | `e41355ea01670fd4c830b384009d31dd0339a705` | tree `405b39fdc543dceb7644bdcda65e1bb4c7a28ab2`；LICENSE SHA-256 `589ed823e9a84c56feb95ac58e7cf384626b9cbf4fda2a907bc36e103de1bad2` |
| common-c ENet | common-c gitlink，官方要求使用修改版 | `aca87840b57f045a1f7f9299e4b1b9b8e2a5e2f1` | LICENSE SHA-256 `77f94e3be39938801163844b8bf9a4f12badcc0da136e9886e7da14a816d74d3` |
| common-c nanors | common-c gitlink | `b1e3c22ca0cdc0bb83e3cd6ed1a2fc77869ed99a` | LICENSE SHA-256 `3fdda5f011d8490331950398e86427d67dfae05e048681476c2c6b8c34bdd033` |
| Moonlight Android | `https://github.com/moonlight-stream/moonlight-android` | `f10085f552b367cf7203007693d91c322a0a2936` | tree `ff0595858eaf30d170e8791d85f93a37dfa65346`；PairingManager SHA-256 `83858d10e77026777acbee6857c95a0af22dc025a0b1f76072704639ac5d572a`；NvHTTP SHA-256 `30a10971eb9b417162dc11948696cc3f32dc96bcb79da5afb6f207c8c1c0e152` |
| Moonlight Qt | `https://github.com/moonlight-stream/moonlight-qt` | `2e13ed9977bc31c73caf8428f08f58d793313ece` | tree `bd12a9a7737cf25744e2141337601a2c9a49bc4d`；其 common-c gitlink 与本次 pin 相同 |
| Moonlight 官方图标 | Moonlight Qt `app/res/moonlight.svg` | 随 Qt revision | SVG SHA-256 `6fd0ee4fe5b4aad5abaa5d5c9acb9f7d1bda0abadfe9d1582115de9b4ba16aa2` |
| Sunshine | `https://github.com/LizardByte/Sunshine` | 测试 pin `v2026.808.164219` / `25c06d79b54f3d092d3fedd5f5ba44989f394692` | 最低安全基线 `v2026.516.143833` / `14ffa6f...`；当前稳定标签另含 `v2026.726.710` / `7cb9207...` |
| MoonlightOH 参考 | `https://gitee.com/smdsbz/moonlight-ohos` | `a48821e2d309c4282d79a053e6a85245eb438a7b` | 2026-08-09 HEAD 复核未漂移；只用于 HarmonyOS 交互/平台证据，不作为依赖或资产源 |
| moonlight-harmonyos 参考 | `https://github.com/likuai2010/moonlight-harmonyos` | `e64392de5f00ee771140aa3f6e7d2b96db21e67a` | 2026-08-09 HEAD；只作历史实现对照 |

实施采用以下边界：

- 协议核心只 vendoring `moonlight-common-c` 及其固定 ENet/nanors 子模块。
- 配对、Host API 和证书语义参考 Moonlight Android，但不复制 Android UI/JNI/生命周期。
- 设置和输入语义参考 Moonlight Qt，但不移植 Qt/SDL。
- Sunshine 只作为互操作服务端，不进入客户端产物。
- MoonlightOH 只验证 HarmonyOS 页面、XComponent、OH_AVCodec/OHAudio 和输入路线，不复制其代码或视觉资产。

## 4. 许可证、品牌和发布合同

| 内容 | 许可证/边界 | 本项目动作 |
| --- | --- | --- |
| RemoteDeskHarmonyOS 组合产物 | AGPL-3.0-or-later | 继续以现有 AGPL 网络源码提供政策发布 |
| moonlight-common-c | GPL-3.0 | 与 AGPLv3 组合兼容；保留原 LICENSE、copyright、revision 和修改说明 |
| ENet | MIT | 保留 LICENSE 和 copyright；必须使用 common-c 固定 fork/revision |
| nanors | MIT | 保留 LICENSE 和 copyright |
| OpenSSL 3.4.1 | Apache-2.0，仓库已分发 | 复用现有静态产物，不重复引入；重新生成 SBOM/哈希即可 |
| Opus | BSD-3-Clause，仓库已分发 | 复用现有双 ABI 静态产物，不重复造轮子 |
| 官方 Moonlight SVG | 随 GPL 源仓分发；商标许可与代码许可是两条边界 | provenance/NOTICE/source bundle 与品牌审核通过前，产品继续使用 `sys.symbol.gamecontroller_fill` 回退，不把图标 ready 写死为 true |
| Sunshine | 不分发 | 记录测试版本和安全状态，不复制服务端源码/素材 |

N1-01 的同一提交必须：

1. 将原样上游源码、子模块和 LICENSE 放入独立 upstream 目录；项目改动仅放 patch/platform adapter。
2. 增加 `THIRD_PARTY_NOTICES.md` 项、SPDX package/relationship、`THIRD_PARTY_ARTIFACTS.sha256` 和固定 revision 清单。
3. 更新 `SOURCE_OFFER.md`，保证 HAP 对应源码归档可重建同一 common-c/ENet/nanors 内容。
4. 运行 `pwsh -NoProfile -File scripts/verify_open_source_release.ps1 -Mode Light`；任何未知许可证、缺失源码或哈希不一致直接阻断发布。

## 5. Sunshine 安全和兼容政策

1. `GHSA-ph75-mgxh-mv57` 是客户端证书校验绕过问题，关键修复基线为 `v2026.516.143833`。
2. serverinfo 能可靠判定主机低于基线时，配对和连接都阻断，显示“Sunshine 版本存在已知安全风险，请先升级”。
3. 版本不可判定、第三方 fork 或非标准版本字符串不自动等同安全；进入“需要确认/不支持”状态，并保存脱敏诊断，不静默放行。
4. 真实互操作主机优先固定到 `v2026.808.164219`；另保留一台最低允许版本用于兼容回归。
5. 发布前重新读取官方 advisories；所有本 pin 之后适用的高危/严重公告都必须有升级、阻断或明确不受影响的证据。

## 6. HarmonyOS API 23 / 虚拟机能力矩阵

### 6.1 SDK 双 ABI 静态探针

SDK 根：`/Users/mydestiny/Library/OpenHarmony/Sdk/23`。

同一最小 C++ 探针在 `arm64-v8a` 和 `x86_64` 均完成编译/链接，直接引用：

- `OH_AVCodec_GetCapability`
- `OH_AudioStreamBuilder_Create`
- `OH_GameDevice_GetAllDeviceInfos`
- `OH_Huks_GenerateKeyItem`
- `OH_Asset_Add`
- `OH_Input_GetDeviceIds`
- `OH_NetConn_HasDefaultNet`

双 ABI 链接所需 SDK 库均存在：`libnative_media_codecbase.so`、`libohaudio.so`、`libohgame_controller.z.so`、`libhuks_ndk.z.so`、`libasset_ndk.z.so`、`libohinput.so`、`libnet_connection.so`。

### 6.2 Game Controller Kit 边界

- API 23 SDK 包含 device enumeration、button/axis monitor 和 game pad 类型，API 引入版本为 21。
- 当前头文件未找到 rumble/vibration、LED、gyro/motion、accelerometer 或 battery API。
- 因此首版只允许“枚举 + 按键/轴输入”；振动、LED、运动和电量状态保持 `unsupported`，设置项隐藏，不用空回调伪装支持。

### 6.3 2026-08-09 虚拟机只读证据

| 项 | 结果 | 判定 |
| --- | --- | --- |
| 设备 | `127.0.0.1:5555`，ARM64，HarmonyOS emulator `6.1.0.125`，API 24 | 可用于 API 23 向上兼容和 UI 调试；不能代替 API 23/真实手柄真机 |
| 网络 | `NetConnManager` available，默认网络 `netId=101` | 基础网络服务可用；UDP/IPv6/NAT64 仍待流量级验证 |
| 媒体 | `AVCodecService`、`libnative_media_codecbase.so` 存在 | H.264 profile/level/Surface/首帧仍需 HAP 内 probe |
| 音频 | `AudioPolicyService` 存在，可查询 device/stream/pipe/session | OHAudio stereo、焦点、路由切换仍需 HAP 内 probe |
| 安全 | `KeystoreService`、`AssetService` 在 system ability list | HUKS key lifecycle、Asset owner 隔离仍需应用身份内测试 |
| 输入 | `MultimodalInput` 枚举 6 个设备：键盘、鼠标、触屏、触控板等 | 键鼠/触控基础存在；relative pointer capture、实体手柄仍 pending |

把 NDK 可执行文件直接放到 `/data/local/tmp` 运行得到 `probe_exit=127`，原因是该独立进程没有 AppSpawn/应用 linker namespace，无法加载 `libark_jsruntime.so` 及 platformsdk 依赖。此结果不证明 API 不支持，也不能算运行通过。仓库内 probe 必须由 HAP 内 NAPI 调用，记录每项 capability 的真实结果。

## 7. 冻结的 MVP 与 feature truth

### 7.1 首发允许范围

- Sunshine `v2026.516.143833` 或更高，首要测试版本为 `v2026.808.164219`。
- 局域网或用户自行保证可达的网络，不承诺免配置公网穿透。
- H.264 硬解、Opus stereo、60 fps 以内的设备/主机能力交集。
- 键盘、鼠标、触控；实体手柄只在枚举、映射、全量释放和真机证据都通过后开放。
- 默认断开只结束客户端流；显式“退出主机应用”使用独立确认命令。
- 配对身份默认仅本机安全存储；云身份同步默认关闭且必须单独通过密码学、恢复、撤销审查。

### 7.2 默认关闭/隐藏

- HEVC、AV1、HDR、YUV 4:4:4、7.1、120 fps/高刷。
- rumble、LED、motion、controller battery、多玩家高级反馈。
- 自动公网/NAT 穿透、UPnP 自动改路由、未经确认的计费网络串流。
- 官方品牌图标、Host Control、Streaming、Cloud Schema、Cloud Identity、Protocol Available 六个发布 truth 初值全部为 false。

### 7.3 不因 G0 外部条件阻塞的工作

在真实 Sunshine/ARM64 实机尚未提供时，可以继续：D1 全部纯模型/策略、D2 本地 schema/repository/cache 和未注册云表 adapter、D3 不触发真实 AGC 的纯策略/备份适配、U1 禁用入口和 local-only 页面骨架、native 双 ABI 编译。以下工作不得声称验收完成：真实配对、catalog/launch/quit、首帧串流、媒体性能、实体手柄、后台/PIP、网络切换和生产云同步。

## 8. D1 领域策略 checkpoint

| ID | 状态 | 落地产物与合同 |
| --- | --- | --- |
| D1-01 | PASS | `MoonlightModels.ets` 定义 Host/Address/App/Profile/Settings/TrustCandidate/IdentityMetadata/EffectiveSettings，字段有边界、枚举、安全默认值且不含 session secret |
| D1-02 | PASS | `MoonlightRecord.ets` 固定一张 19 列云 envelope、一张 20 列 local mirror 和独立 app cache 表名；owner/secret/localonly 矩阵有测试 |
| D1-03 | PASS | `MoonlightRecordPolicy.ets` 完成重复 key 预扫描、NFC canonical JSON、`_meta`、三类 hash domain、大小限制、逐 recordType 语义验证、嵌套敏感键拦截、tombstone 和稳定 quarantine reason |
| D1-04 | PASS | `MoonlightRecordConflictPolicy.ets` 固定 `resetEpoch > syncVersion > updatedAt`，覆盖 retry 幂等、mutation 复用损坏、同 envelope 异内容隔离、同 epoch tombstone、显式复活、字段合并和身份/trust/secret fail-closed |
| D1-05 | PASS | `MoonlightSettingsPolicy.ets` 完成 global→host→profile→session、作用域限制、requested/effective/adjustment 和 capability clipping |
| D1-06 | PASS | capability 与 feature truth 分离，平台/主机/网络取交集，六个发布 truth 默认全 false且下层不可越权 |
| D1-07 | PASS | `MoonlightSessionState.ets` 覆盖发现至停止/失败的阶段、generation/sequence fence、媒体/首帧门、重连重置、取消和稳定错误映射 |

测试聚合器登记 7 个 Moonlight describe、43 个 test。由于项目没有注册
`ohosTest@OhosTestCompileArkTS`（`00306054`），当前证据只证明测试源随
`default@OhosTestCompileArkTS` 编译且 focused allowlist/count 一致，不宣称
Hypium 真机执行通过。

## 9. D2 本地数据与可选云表 checkpoint

| ID | 状态 | 落地产物与合同 |
| --- | --- | --- |
| D2-01 | PASS / REVIEWING | owner-store schema 从 4 升为 5；三张 additive 表按有序 `name/type/pk` 精确核验，完整三表 fingerprint receipt 可读后才推进版本；任一 DDL/shape/receipt 失败保持 v4、旧表和数据原样，下次启动幂等重试 |
| D2-02 | PASS / REVIEWING | `MoonlightRepository` 和 `CloudStore` port 携带完整 `AccountSessionLease`；本地 overlay + journal + readback 保持 source of truth；云可用且用户已选择时才由独立 promotion 投影，提交事实与读回事实不混淆 |
| D2-03 | PASS | `MoonlightAppCacheService` 使用 owner+host+app SHA-256 key；完整/部分目录刷新语义分离；超期优先、再稳定 LRU；2048 条、64 MiB 总量、2 MiB 单项边界；cache 事务不触碰 profile/cloud/backup |
| D2-04 | PASS | `CloudTableAdapter` 增加 Moonlight exact 19 列合同；缺列、未知列、非 exact 20 列 mirror、`localonly=1` 全部拒绝；payload 保持 opaque，不做默认补齐 |
| D2-05 | READY FOR USER PROVISIONING | 19 列 `moonlightrecordv1` 应用合同已冻结，当前 reviewer 关闭后向用户给出精确列名、类型和唯一主键 | 用户在目标 AGC 环境创建并确认前保持 deployed revision 0 |
| D2-06 | EXTERNAL PENDING | 尚无真实 AGC schema/权限/注册/空表读写/分页/删除 receipt | 用户确认建表后执行；不能用本地 RDB receipt 冒充云环境 receipt |
| D2-07 | CODE PASS / DEPLOYMENT FUSE 0 | `CLOUD_SYNC_TABLES` 继续是旧 8 表 baseline；`OPTIONAL_CLOUD_SYNC_TABLES` 只有 `moonlightrecordv1`。启动先注册 8，再按 receipt+selection 尝试 9；失败重新确认 8 并隔离可选表 | 用户建表后把 deployed revision 0→1，真实验证 additive/replacement-like 两种平台语义 |
| D2-08 | PASS / REVIEWING | Moonlight 下载采用逐记录 exact/semantic/owner/version 校验，合法行与 redacted quarantine 原子落地；手动部分快照降级为非破坏 merge。上传只允许 settings/host/profile，并要求 exact owner/scope/journal 证明 | 单条坏/未来/跨 owner 行不得阻断整表拉取或旧八表；trust/secret/identity 不得进入 v1 云表 |
| D2-09 | PASS / REVIEWING | 物理表选择和 `settings/hosts/profiles` 逻辑范围默认 `[]`，durable intent 与 runtime availability 分离；账号切换中断形成 `reconcile_pending`/`pending_pull`，同账号重新激活或刷新时自动恢复 | 不复用 VNC prefs；暂时不可用不能重写用户选择 |
| D2-10 | CODE PASS / AGC PENDING | `MoonlightCloudSyncService` 已接入 CloudStore/Coordinator；自动 pull 支持安全 partial，materialization 与 promotion/reconcile 分阶段，后阶段失败可重启修复；manual 完整快照才可 authoritative replace | `cloudAttempted` 仍只描述 service 自身不发网络；真实网络动作由 coordinator/optional registration 持有 |

聚焦聚合器现登记 14 个 Moonlight describe、92 个 test；同样只声明
`default@OhosTestCompileArkTS` 编译注册通过，不把缺失的 Hypium 设备执行写成通过。
D2-01～D2-04 的代码与测试检查点为 `3bbdc61`；D2-08～D2-10 为 `5d9c2ff`。

### 9.1 ARM64 HarmonyOS 虚拟设备 RDB receipt

- 设备：`127.0.0.1:5555`，ARM64 HarmonyOS API 24。
- 安装：当前签名 `entry-default-signed.hap` 覆盖安装并由 AppSpawn 启动。
- 物理库：`remotedesktop_device_local.db`；`PRAGMA user_version=5`。
- `PRAGMA table_info`：云候选/本地 mirror/cache 分别严格 19/20/16 列，顺序、类型和唯一 `id` 主键与 policy 一致。
- receipt：owner=`device-local`、store=`remotedesktop_device_local.db`、status=`completed`、counts=`19/20/16`。
- 杀进程重开后：`tables=3`、同 migration receipt `count=1`，证明重复打开幂等且没有重复回执。
- 当前静态合同确认旧 8 表 baseline 与第 9 表 optional superset 分离；revision 0 阶段不会执行 Moonlight `setDistributedTables`。用户建表并启用 revision 1 后必须重新采集真实注册 receipt。

## 10. D3 账户、删除、云状态和备份恢复 checkpoint

| ID | 状态 | 已落地合同 | 仍需完成/不得越界 |
| --- | --- | --- | --- |
| D3-01 | CODE WIRED / AGC PENDING | `MoonlightCloudStatusPolicy`、physical selection、logical scopes、bootstrap、pending、quarantine、last success/error 已接入现有云管理边界；revision 0 时诚实显示未部署/不可用 | revision 1 后采集 request/retry/bootstrap 和 UI 状态 receipt |
| D3-02 | CODE PASS / REAL ACCOUNT PENDING | repository、selection、materializer、coordinator callback 和 barrier 均携带完整 lease，并在事务/回调边界复核 owner、generation、storeInstance；迟到账号回调 fail closed | 真实账号 A→B→A、进程杀死和网络迟到回调仍需设备级验证 |
| D3-03 | CONTRACT PASS / RUNTIME PORT PENDING | `SensitiveDataBarrier` 在 store quiesce 前调用 Moonlight drain；顺序固定为关闭 mutation/launch→session→pairing→identity restore→cloud/journal→runtime secrets；`AccountSessionCoordinator` 激活 store 后绑定新 lease；任一步失败保持切换 fail closed | N1 runtime port 未注册时是安全 no-op；真实 session/pairing/native secret drain 要在 N1/S1 后做强杀和超时验收 |
| D3-04 | PASS | 保持 Backup V3；可选 descriptor 与 `moonlightrecordv1`/`moonlightlocalrecords` 双 section 已进入 manifest/inventory；旧 V3 缺 section 等价于无 Moonlight；新 V3 未被旧 inventory 认识时必须拒绝 | 不增加 Backup V4；若后续发现旧 reader 静默忽略未知 section，立即停发并改 V4 |
| D3-05 | CODE PASS / AGC PENDING | 恢复先 exact/owner/semantic 验证，再只写 `moonlightlocalrecords localonly=1`；云激活前保持 quarantine，首次 cloud-first 后才允许 promotion；旧 V3 缺 Moonlight section 等价于无 Moonlight且不影响旧表 | 真实云激活、磁盘满、恢复中切账号/杀进程仍归 D3-08 |
| D3-06 | CODE PASS / AGC+HOST PENDING | 删除 checkpoint、tombstone 上传、selection cleanup、账号 lease 和本地保留策略已接入；取消 scope 不制造隐式远端删除，明确删除继续收敛 | 真实云 terminal receipt、失败恢复和 Host Control unpair 仍需验证 |
| D3-07 | POLICY PASS / UI PENDING | 云状态不再压成单一“已同步”布尔；异常计数和 identity lock 均为独立状态 | U1-11 才接设置页面；physical/schema truth 为 false 时 UI 必须显示不可用/关闭 |
| D3-08 | EXTERNAL PENDING | 纯策略与构建矩阵已有自动测试覆盖 | 双设备、双账号、device-local、真实云、恢复中故障和既有 8 表同步回归尚无 receipt |

### 10.1 便携备份 V3 冻结矩阵

| 内容 | redacted | full | 恢复终态 |
| --- | --- | --- | --- |
| settings / host / profile | 包含 | 包含 | 当前 owner 的 local overlay，`localonly=1` |
| trust candidate | 排除 | 可包含 | 仍只是候选；没有本机 trust receipt |
| secret / client identity / PIN / token / private key | 排除 | 排除 | 无恢复通道，明确要求重新配对 |
| app cache / journal / quarantine / receipt / bootstrap / selection / recovery marker | 排除 | 排除 | 不创建、不推断 |

源库 admission 比导出过滤更严格：未知列、缺列、外来 owner、重复 id、
非法 `localonly` 或语义损坏会让整次备份失败，不能通过“过滤掉坏行”生成看似
成功的不完整文件。restore 重新绑定目标 owner，但不会把来源 owner、设备 ID 或
writer origin 另存成设备配置；下一次本机写入继续使用目标 owner-store 的 origin。

D3 账户生命周期代码检查点为 `05e96d3`；便携备份/本地恢复检查点为
`b27a58a`；本地删除命令检查点为 `ea32ffa`。聚焦聚合器现登记 19 个 Moonlight describe、138 个 test；只声明
`default@OhosTestCompileArkTS` 编译注册通过，不声明 Hypium 设备执行。

## 11. N1 官方 common-c checkpoint

| ID | 状态 | 当前证据 | 唯一下一边界 |
| --- | --- | --- | --- |
| N1-01 | PASS | `0013ba034` 原样纳入 common-c `e41355e...`、ENet `aca8784...`、nanors `b1e3c22...` 共 117 个文件；锁文件记录 commit/tree/license/file manifest/build receipt；校验器离线重建三个官方 Git tree，并把两个子模块按 `160000` gitlink 注入 common-c tree | 不再编辑 upstream；升级 revision 时必须重新生成 lock、NOTICE、SPDX、hash、source offer 和双 ABI receipt |
| N1-02 | PASS | `99edc58` 新增唯一项目 CMake 边界，standalone/product 共用同一 static/PIC/OpenSSL/warning policy；两 ABI 私有链接 `common-c`/ENet，但链接前后动态符号、NAPI 相关面和 423 项 HAP 清单完全一致 | 不回开构建边；N1-03 只能新增 session owner 与定向测试，不接 NAPI/runtime UI |
| N1-03 | PASS | `18cdd39aa` 新增 hidden pure-native owner；13 个确定性用例证明并发 start、cancel/interrupt 栅栏、stop/drain、stale key、异常和析构；全量 native 355/355 | 不回开 owner 车道；N1-04 只能以 exact request key 消费其归属合同，不另建 active pointer/singleton |
| N1-04 | PASS | `fd2d7ec92` 新增 transport-injected pure-native Host API；15 个确定性用例覆盖 official request/XML、exact cancel/deadline、地址 fallback、mutation unknown、trust/cancel verification、fuzz 与脱敏；全量 native/ASan/UBSan 370/370 | 不回开 Host API parser/request owner；N1-05 只提供 owner-scoped identity/短期 TLS material lease，不创建第二套 HTTP、pairing 或 NAPI |
| N1-05 | PASS | `599882ada` 新增 hidden pure-native secure identity core：owner+installation opaque alias、RSA-2048 client cert、move-only sign/TLS lease、zeroization、exact mutation/drain/inventory/delete 和 fail-closed HUKS/Asset boundary；14 个定向用例；native/ASan/UBSan 384/384 | HAP/AppSpawn runtime proof 缺失，product backend 保持 unavailable；N1-06 只能消费注入 seam 做 dormant pairing，不得以 plaintext/software store 绕过 |
| N1-06 | CONTRACT PASS / DORMANT | `6f7094038` 新增 hidden injected pairing state machine，逐包复用 N1-04、逐签名复用 N1-05；15 组 pairing 故障/竞态用例，native/ASan/UBSan 400/400 | product identity backend 仍 unavailable；无 NAPI/UI/真实 trust port/真实 Sunshine，不宣称可配对 |
| N1-07 | CONTRACT PASS / DORMANT | `019ed98b4` 新增 hidden injected Host Control，复用 N1-04 完成 authenticated catalog/asset、launch/resume/explicit quit、三段 truth、generation/cancel/deadline、maybe-sent no replay 和 launch material/RTSP cleanse；26 组定向用例，native/ASan/UBSan 426/426 | product identity/transport 仍 unavailable；无 NAPI/UI/真实 Sunshine，不宣称目录或主机控制可用 |
| N1-08 | CONTRACT PASS / DORMANT | `aecd2ea4e` 新增 NAPI-free exact bridge、五个独立 `moonlight*` NAPI 属性和 lease/cache-fenced `MoonlightHostService`；product runtime 首包前 `runtime_proof_required`；14 native + 13 ArkTS focused cases，普通/ASan/UBSan 440/440 | 无真实 identity/transport/trust/commit/Sunshine 回执；FAB、云注册、媒体、输入和六项 truth 不变；N2-01 只能建纯 stream offer，不得把 bridgeCompiled 当可用 |
| N2-01 | CONTRACT PASS / DORMANT | `db5865c53` 新增 project-owned deterministic stream offer、四类 generation/source/version/expiry capability snapshot、stable adjustment 和同源 launch projection；36 focused cases，全量/ASan/UBSan 476/476 | 无 common-c wire/NAPI/RTSP/media/input/UI/cloud caller；`selectedCodec` 始终 absent，FAB、8 表在线注册和六项 truth 不变；N2-02 只能建唯一 adapter/RTSP callback owner |
| N2-02 | CONTRACT PASS / DORMANT | `248e704ab` 新增唯一 hidden common-c adapter，并只为既有 owner 增加 exact-key non-blocking `requestStop`；官方 struct/mask、RI/IV、process-global router、11-stage/deadline/termination、setup-derived video/audio、callback drain/cleanse 共 21 个 focused case；普通与 ASan/UBSan 497/497 | product media port 恒 unavailable，archive 无 NAPI/ArkTS/UI/cloud caller；transport-ready 不是首帧，8 表、灰色 FAB 和六项 truth 不变；N2-03 只能建立 bounded video decode-unit bridge |
| N2-03 | CONTRACT PASS / DORMANT | `34d2ffa7a` 新增 hidden `MoonlightVideoBridge`、owned AU/config generation、IDR/backpressure/teardown，并在唯一 adapter `.cpp` 内 bounded 投影官方 `DECODE_UNIT/LENTRY`；8 focused bridge + 1 adapter case；普通/strict/TSan 506/506、ASan/UBSan 三轮、analyzer 全通过 | product sink unavailable、`firstFrameReady=false`，无 OH_AVCodec/Surface/NAPI/UI/cloud/audio/input；8 表、灰色 FAB、11 false inputs 和六项 truth 不变；N2-04 只能复用既有 decoder owner |
| N2-04 | CONTRACT PASS / DORMANT | `bee0ac1da` 新增 hidden pure sink + OHOS port，复用既有 decoder/renderer exact owner；H.264 config-IDR recreate、typed pressure/stale/failure 和 output→NativeImage→actual swap 三段首帧；9 focused case；普通/strict/TSan 515/515、ASan 三轮、analyzer、双 ABI/callback carrier通过 | archive 无 factory caller/NAPI/ArkTS/UI/cloud/audio/input；HAP runtime media proof 缺失，8 表、灰色 FAB、11 false inputs 和六项 truth 不变；N2-05 只能增加 pure-native Surface lifecycle |
| N2-05 | CONTRACT PASS / DORMANT | `7992279c7` 新增 hidden pure-native Surface lifecycle；无 Surface 在 copy/queue 前 typed drop，temporary suspend exact detach 且保留 decoder handle，同 key/decoder/display + 更高 Surface/renderer/runtime-proof generation 才 rebind；8 focused case；普通/strict/TSan 523/523、ASan 三轮、analyzer、双 ABI/callback carrier通过 | 无 ArkTS/PIP/NAPI/cloud/audio/input/product caller；423-path HAP、动态 ABI、8 表、灰色 FAB、11 false inputs 和六项 truth 不变；N2-06 已完成 |
| N2-06 | CONTRACT PASS / DORMANT `8d2fd15b3` | hidden pure-native `MoonlightAudioBridge`；exact 48 kHz stereo family-1 Opus multistream→interleaved S16LE，common-c `nullptr+0` PLC、1400-byte packet、23040-byte PCM、single in-flight、owner/config/operation generation、typed failures、stop timeout retry、cleanup/zeroization；10 new tests PASS；两 ABI product native/link probe PASS | 不接 `audio_player`/OHAudio/NAPI/ArkTS/UI/cloud/input/product caller；FAB、8 cloud tables、六项 truth 保持关闭；其后 N2-07 checkpoint 已重新通过双 Hvigor |
| N2-07 | CONTRACT PASS / DORMANT `9272f1c9c` | hidden exact-owner `MoonlightAudioPlayerSink` 将 N2-06 PCM 委托给既有 `DispatchActiveNative`/`SuspendActiveNative`/`TakeActiveNative` 与共享 owner lease；48 kHz stereo、generation fence、mute/focus/background/pause/resume/stop/cleanup 和迟到 PCM 均有 typed 合同；10 个 focused case | 不新增 OHAudio renderer、registry、queue、线程、singleton、NAPI、ArkTS 或 product caller；N2-08 才增加纯 native media clock/stats，任何音频结果仍不改变首帧、FAB、streaming 或 release truth |
| N2-08 | CONTRACT PASS / DORMANT `57b1d7da4` | hidden pure-native `MoonlightMediaClockStats`；exact session/window/source generation、最多 256 槽 fixed window、absent 与 measured zero 分离、network/decode/render/end-to-end/audio queue p50/p95/max、common-c RTP/FEC/recovery/OOS/invalid 精确增量、audio underrun/drop、reset baseline、节流和饱和计数；13 个 focused case | 私有 archive 未被无 caller 的 `rdpnapi` 拉入，双 ABI 动态符号集合与 N2-07 完全一致；不接 NAPI/ArkTS/UI/cloud/log/product caller；N2-09 等待外部实机，N3-01 已完成 |
| N3-01 | CONTRACT PASS / DORMANT `fe46025ef` | hidden pure-native `MoonlightInputBridge`；exact session/owner/input/source generation、device/source/sequence/timestamp、固定 32 lanes/64-byte payload、typed stale/duplicate/backpressure、focus/stop neutral flush、retry/resume/cleanup 和并发序列化；12 个 focused case | 复用唯一 `MoonlightSessionOwner` 与共享 `SessionSinkOwnerLease`；未改公共 `InputHandler`，archive 无 caller 且未进入 `rdpnapi`；不接 NAPI/ArkTS/UI/cloud/product caller；N3-02 下一 |
| N3-02 | CONTRACT PASS / DORMANT `a552b30a2` | hidden `MoonlightKeyboardMapper`；HarmonyOS namespace→官方 prefixed VK、双侧四类 modifier、once/lock、strict UTF-8 text、逐命令状态提交、精确 retry、跨设备 key-up 拒绝、8 普通键+8 modifier 全释放和物理 Esc 本地逃生；15 个 focused case | 私有 archive 无 caller 且未进入 `rdpnapi`；无公共 InputHandler/NAPI/ArkTS/UI/cloud/thread/queue；仅修正 N3-01 测试接受合法 stop-first 串行结果；N3-03 下一 |
| N3-03 | CONTRACT PASS / DORMANT `1787da821` | hidden `MoonlightPointerMapper`；absolute/relative motion、官方五键、横纵滚轮、physical-pixel content rect、letterbox/fill/1:1/pan、四向旋转、DPI/fraction residual、exact geometry/source generation、逐命令状态提交和精确 retry；18 个 focused case | capture/constraint/raw-relative 仅有 capability resolution，product unavailable；私有 archive 无 caller 且未进入 `rdpnapi`；无公共 InputHandler/NAPI/ArkTS/UI/cloud/thread/queue；N3-04 下一 |
| N3-04 | CONTRACT PASS / DORMANT `ebd2fa0bc5` | hidden `MoonlightTouchMapper`；官方 28-byte direct-touch body、10 个稳定 contact id、cancel/cancel-all、旋转/content rect、overlay lifetime ownership；触控板复用 N3-03 完成一指/双指/长按/三指本地动作，固定 3 contacts/16 observed lanes、exact generation 和 retry；21 个 focused case | direct capability/platform listener 均 fail closed；私有 archive 无 caller 且未进入 `rdpnapi`；无公共 InputHandler/NAPI/ArkTS/UI/cloud/thread/queue；N3-05 下一 |
| N3-05 | CONTRACT PASS / DORMANT `1aadfba24` | hidden `MoonlightControllerMapper`；official arrival/state 参数投影、API 23 button/axis/trigger/hat、7%/13% deadzone、Y 反向、stable slot 0、full-state frame、background neutral、disconnect active-mask clear、exact device/source generation 与 retry；16 个 focused case | GameControllerKit 仅 compile-link probe；无双手柄真机证据时一槽，反馈能力全关闭；archive 无 caller 且未进入 `rdpnapi`；无公共 InputHandler/NAPI/ArkTS/UI/cloud/thread/queue；N3-06 下一 |
| N3-06 | CONTRACT PASS / DORMANT `baa9cafef` | hidden `MoonlightControllerFeedback`；official API∩physical-device evidence、rumble/trigger rumble/RGB LED/adaptive trigger/motion/battery typed command、single pending retry、200Hz/120s 上限、exact owner/device/operation generation 与 release lifecycle；16 个 focused case | API 23 product evidence 全 false，capability false 零 port 调用；archive 无 caller 且未进入 `rdpnapi`；无公共 InputHandler/NAPI/ArkTS/UI/cloud/thread/queue；N3-07 下一 |
| N3-07 | CONTRACT PASS / DORMANT `02cb13aae` + `36b4e13df` + `337c4f35e` + `ee073afcb` | hidden policy 在 mapper release 前原子关闭真实 bridge admission，只接受 lifecycle release；组合 touch→pointer→keyboard→controller→bridge，覆盖 12 trigger、component failure/owner loss、pending/suspended→stop、exact terminal replay、stale stop 和 local terminal；26 个 focused case | 私有 archive 无 caller且未进入 `rdpnapi`；无公共 InputHandler/NAPI/ArkTS/UI/cloud/thread/queue；N3-08 下一 |
| N3-08 | CONTRACT PASS / DORMANT `fef723770` + `6787cc3fb` | hidden fixed-capacity controller aggregator/layout validator；native physical full-state/virtual semantics 只走 N3-05→N3-01→common-c；独立 boundary-retry/resume generation、retired-lane tombstone、20 次双向换源、unknown phase/NaN fail closed、single pending、12 lifecycle/edit zero-send；28 aggregator cases | 双 ABI archive 无 caller且未进入 `rdpnapi`；真实 listener/NAPI 留到 S1-05A；无公共 InputHandler/ArkTS/UI/cloud/thread/第二 owner/port/slot/queue；U1-01～03 已完成 |
| U1-01～03 | PASS `c38ff6265` + review fixes `71e9902c9`, `7eaad950b` | RustDesk 与 Moonlight 复用同一 `protocolOption()`；默认灰色 0.58、唯一“即将支持”、点击空 route；官方 Moonlight Qt 几何的可着色 SVG、唯一系统 fallback 与精确合规链已落盘 | 未改 RustDesk/其他协议页面、HostList FAB owner、native 或云；HDC 实际点击零导航；U1-04 已完成 |
| U1-04 | CONTRACT PASS / DORMANT `dd6ec9c5` | RustDesk 风格四步 add flow + pure policy；自动/手动、验证、PIN、certificate trust、catalog、local commit truth、dirty dismiss 与 exact owner/generation 已冻结；10 个新增测试 | picker 仍 false，所有 runtime/persistence ports 默认 fail closed；无云/native/其他协议业务调用；U1-05 已完成 |
| U1-05 | CONTRACT PASS / DORMANT `46a2e7d3` + `a73b8959` + `094a8b3b` | 原生 Sheet `onDisappear` 后只交接稳定本地主机 ID + owner/generation；无 fixed delay/第二 Sheet；repository committed 与 catalog eligibility 分离，快速双写及 committed-without-ID 重写被阻断；8 shared cases，Moonlight 聚合 162 tests/21 describe | picker/Host Control/native/runtime/cloud 仍 false；U1-06～U1-12 UI shell 已落地 |
| U1-06 | UI CONTRACT PASS / DORMANT `6b0c1aa8` | `MoonlightHostDetailPage` 与 `MoonlightAppCatalogPage` 已注册 Navigation；首页 add-save handoff 以稳定本地主机 ID 打开目录；目录/详情只读本地 records/cache，刷新有 owner/generation fence；空、旧、部分、离线、主机忙、大目录和坏封面均 fail closed | 不接真实 Host Control/runtime/cloud；picker 仍 false；真实目录数据与在线状态待 S1/N2 runtime receipt |
| U1-07 | UI CONTRACT PASS / DORMANT `6b0c1aa8` | RustDesk 风格 `MoonlightLaunchSheet`、连接阶段 overlay、取消/失败/主机忙/输入能力提示与 start-before-launch preflight 壳已接入目录；未满足 runtime proof 时不能发起 launch | 不宣称真实 launch、RTSP、首帧或 quit；S1-01/S1-02 负责 coordinator 装配 |
| U1-08 | UI CONTRACT PASS `6b0c1aa8` | `SettingsAccordionPolicy` 在 VNC 后、安全前提供 Moonlight 单卡；9 个 protocol sections 统一进入一个设置 surface，排版沿用 RustDesk/Theme token | 不重复公共 display/PIP/host-management；公共设置仍由现有入口拥有 |
| U1-09 | UI CONTRACT PASS `6b0c1aa8` | Moonlight settings routes 采用连续 24–32 mode，route→section/title/height 由 `SettingsSheetRoutePolicy` 统一解析；无独立跳转大杂烩 | route 只打开对应 leaf；真实 profile/host/session persistence 仍 local-only |
| U1-10 | UI CONTRACT PASS / LOCAL ONLY `6b0c1aa8` | 快速、画面、音频、输入、网络安全、后台、诊断、云范围、Trust 九个 leaf 已接入 bindSheet；公共 display/PIP 和冗余“主机管理”已移除，主机管理归首页；本地设置服务负责 normalize/read/save；legacy readable metadata 与 new-write allowlist 已分离 | 不接 Moonlight cloud；云范围与 Trust 继续显示禁用/原因，不能把本地状态写成云同步 |
| U1-11 | UI CONTRACT PASS / PARKED CLOUD `6b0c1aa8` | 云范围 leaf 可展示 local-only/未启用状态并复用现有 settings surface；未注册 `moonlightrecordv1`，未增加 cloud table 或 transfer | 只有未来 AGC/crypto/identity receipt 齐全后才评估云端；本轮不改 CloudStore |
| U1-12 | PARTIAL VISUAL ACCEPTANCE `6b0c1aa8` | latest fresh r2 signed HAP 已在 PC/phone 安装启动；PC full-screen、phone nine-section accordion、quick/network/lower bindSheet 均已截图验收；网络安全 sheet 的证书变化开关为强制安全状态且不可操作；代码只用现有 Theme/breakpoint/accessibility tokens | 真实能力开放后仍需重做可达 add/connection/stream runtime 验收；不使用旧截图替代新证据 |

N1-01 的可复现证据：

- `verify_moonlight_vendor.py` 在 Git worktree 与无 `.git` 的普通源码归档中均 PASS；后者只跳过 Git index 检查，117 个工作树字节、license、artifact hash、SPDX、NOTICE 和三个官方 tree 仍全部核验。
- shell 与 PowerShell 7 均在新临时目录构建 `arm64-v8a`、`x86_64`，四个 archive SHA-256 与 `UPSTREAM.lock.json` 一致；Release 合规模式实际调用同一 PowerShell 双 ABI 门禁，Light 只执行快速离线门禁。
- nanors 原始 `make check` 的 6 个 Perl test 文件及 RS16/RS16 AFFT 最终测试通过；common-c/ENet 本 revision 没有上游 CMake test target。
- 合规生成器连续两次运行三份输出 hash 完全一致；签名 HAP 与两 ABI `librdpnapi.so` 都没有 Moonlight/common-c/ENet 文件或符号，现有八张云表未改变。
- 首个 `gpt-5.6-sol low` 有界审查确认官方 commit/tree/gitlink/117 文件字节与产品隔离，提出的 tree 绑定、源码归档模式、NOTICE 幂等和 Release 双 ABI 四项问题均已修复并由上述机器门禁覆盖；后续只复用既有 reviewer task，不为同一 checkpoint 新建实例。

N1-02 必须按以下原子步骤执行：

1. 先保存两 ABI `librdpnapi.so` 的 exported/undefined symbol inventory、签名 HAP 文件清单和现有 native/Hvigor 结果，作为回归基线；build timestamp 导致的整文件 hash 不能当 ABI 判据。
2. 新建唯一项目边界 `entry/src/main/cpp/moonlight/CMakeLists.txt`；由它设置目录作用域的 `BUILD_SHARED_LIBS=OFF`、`ENET_NO_INSTALL=ON`、PIC、现有 OpenSSL include/crypto archive，并 `add_subdirectory(upstream/moonlight-common-c)`。禁止修改 upstream。
3. 该边界必须校验 `moonlight-common-c` 与 `enet` 都是 `STATIC_LIBRARY`，仅在这两个第三方 target 上保留 API 23 Clang 的 `-Wno-unused-command-line-argument`；不得降低 `rdpnapi` 或其他协议 warning policy。
4. 将 N1-01 的 standalone `vendor-build/CMakeLists.txt` 改为消费同一项目边界，消除两套 target 定义；重跑 shell/PowerShell receipt，证明重构没有改变四个 archive。
5. 主 `entry/src/main/cpp/CMakeLists.txt` 只在现有 `ssl`/`crypto` imported target 定义后加入 Moonlight 子目录，并用 `PRIVATE`/`LINK_ONLY` 语义把包装 target 接到 `rdpnapi`。不使用 `include_directories()`、`add_definitions()`、`link_directories()` 或 `--whole-archive`。
6. 不新增 `ALL_SOURCES`、`napi_init.cpp`、extension registry、ProtocolAdapter、ArkTS 声明、云表、资源、FAB/设置页或 feature truth；N1-02 完成后 UI 仍只有灰色“即将支持”。
7. 两 ABI产品构建后验证：common-c/ENet 目标实际参与依赖图；`rdpnapi` 没有未解析 `Li*`/`enet_*`/OpenSSL 符号；没有新增 NAPI export；upstream 路径没有传播为全局 include；RDP/RustDesk/SSH/VNC native tests 仍通过。
8. 重跑 N1-01 双 ABI receipt、`default@OhosTestCompileArkTS`、signed `assembleHap`、TOTP/Light、diff/state 门禁；单独 checkpoint 后才允许领取 N1-03。

N1-02 完成证据：

- 代码 checkpoint `99edc58` 只修改主 CMake、新项目边界和 standalone wrapper；上游、NAPI、ArkTS、云注册、资源和 UI 零变化。
- arm64-v8a/x86_64 的 link graph 都包含 common-c、ENet 和既有 ABI 对应 OpenSSL crypto archive；47 个非上游产品 compile command 均无 upstream include path。
- 链接前后两 ABI动态定义/未定义 symbol inventory 与 `napi|register|init` 审计集合逐字相同，没有未解析 `Li*`、`enet_*`、`OPENSSL_*`；因无引用，静态 archive 没有被 whole-archive 拉入产品。
- 签名 HAP 路径 inventory 前后均为 423 项且逐字相同；灰色 Moonlight FAB、“即将支持”和所有 capability truth 未改变。
- host native tests 在允许 loopback socket 的环境中 342/342 PASS；shell/PowerShell 双 ABI构建仍命中四个 N1-01 locked receipt。
- 两项 Hvigor、signed HAP、Git tree/index vendor gate、TOTP、Light、diff/state 均在最终 N1-02 源码上 PASS；未新增 Hypium/真实 Sunshine/用户实机声明。

N1-03 必须按以下原子步骤执行：

1. 先保存 `99edc58` 的 native test 总数、两 ABI动态符号/HAP inventory 与构建结果；N1-03 不得以旧协议代码改动换取 Moonlight owner。
2. 仅新建 `moonlight/core/MoonlightSessionOwner.h/.cpp` 和 `test/moonlight_session_owner_test.cpp`，并在主 CMake 的独立 `MOONLIGHT_SOURCES` 与 host test source 中登记；public header 不暴露 common-c 结构或上游 include。
3. 定义非零且不可重绑定的 `sessionId + generation + ownerToken` key、`idle/starting/running/stopping/stopped/failed` 生命周期和 per-owner cancel token；所有 mutation/callback/stop 都要求 exact key。
4. 用唯一进程级 coordinator 串行 future common-c `start → interrupt/stop` operation；第二个 start 立即返回 stable busy，不排队、不抢占。操作通过窄 callable/driver seam 注入测试，N1-03 不构造假的 server/stream config，也不调用 Host API。
5. stop 在 starting 时只请求一次 cancel/interrupt，并等待 start 返回后才允许 stop；running 时 stop 最多调用一次；重复 stop 幂等，stale stop 零副作用。超时后保持 stopping 和全局车道占用，不能放行新 session。
6. callback/worker 使用不可复制 RAII lease：只在 exact current key 且 admission open 时计数；stop 先关 admission，再等待已入场 lease 归零。旧 generation、owner token、关门后和新 session 建立后的迟到 callback 必须拒绝，不能查询可变 `g_activeConnection` 后归到新 owner。
7. 定向测试至少覆盖：非法零 key、两个并发 start、start 失败释放、stop-during-blocked-start、重复 stop、stale stop、callback/worker drain、drain timeout fail closed、旧 generation callback、exact snapshot/count、驱动异常边界和析构无遗留线程；每个测试使用有界 barrier/deadline，不 sleep 猜时序。
8. N1-03 不新增 NAPI/ArkTS、Host API、媒体、输入、HUKS、云、路由、资源或 feature flag；通过新增 native tests、既有 342 项回归、双 ABI产品编译/符号隔离、两项 Hvigor、signed HAP、TOTP/Light、diff/state 后单独提交，才允许 N1-04。

N1-03 完成证据：

- 代码 checkpoint `18cdd39aa` 只修改主 CMake，并新增
  `MoonlightSessionOwner.h/.cpp` 与一个 focused native test 文件；没有 NAPI、
  ArkTS、Host API、媒体、输入、云、资源或 capability truth 变化。
- key 固定为非零 `sessionId + generation + ownerToken`；process singleton 是
  唯一生产 owner，测试实例只在既有 `RDP_NATIVE_CALLBACK_TESTING` 下可创建。
- start/interrupt/stop、callback 和 worker 都被 exact key 与 move-only lease
  约束。cancel 在 common-c interrupt flag 初始化后的显式 fence 才触发，且
  interrupt 从预留开始到返回始终占用 control operation；新 start 和 stop 不会
  越过尚未返回的 interrupt。
- 13 个新用例使用 barrier/deadline 覆盖两个真实并发 start、stop-during-start、
  late interruptible fence、interrupt-before-stop、新 start 仲裁、start/stop/
  interrupt 异常、stale generation、callback/worker drain、timeout fail closed、
  重复 stop 与析构 join；沙箱外全量 **355/355 PASS**。
- arm64-v8a/x86_64 产品编译各有 48 个非上游 compile command，恰有一个 owner
  command 且 upstream include leak 为 0；两 ABI defined/undefined/
  `napi|init|register` inventories 与基线逐字相同，签名 HAP 仍为同一 423 项。
- 最终源码上的两项 Hvigor、signed HAP、vendor 三 tree/117 文件、TOTP、Light、
  diff/state 全部 PASS；HDC 仍为 `Connect server failed`，未新增设备运行声明。

### 11.1 N1-04 唯一执行合同

N1-04 只建立可复用的 native Host API 协议核心，不把入口改为可点击，也不提前
实现 N1-05 secure identity、N1-06 pairing 状态机、N1-07 用户级命令或 N1-08
NAPI。必须按以下原子步骤执行：

1. 以 `18cdd39aa` 保存 355 项 native、两 ABI symbol/NAPI audit、48 条产品
   compile command 和 423 项 HAP inventory；允许修改的代码仅为主 CMake、新建
   `moonlight/core/MoonlightHostApi.h/.cpp`、一个 focused native test 文件。发现
   必须改旧协议或公共网络层时先停止并更新合同，不复制 VNC/RDP 的私有 socket
   helper。
2. public header 只暴露项目自有 C++17 value types/PIMPL：endpoint、operation、
   immutable request、bounded response、server-info、app entry、launch/quit result、
   stable error 和 diagnostic snapshot。不得包含 common-c、OpenSSL、ArkUI/NAPI
   header，也不得接受或返回 PIN、PEM 私钥、session token、`rikey` 原始 bytes。
3. 每个操作使用非零 `requestId + generation + ownerToken` exact key 和共享 cancel
   state；开始、每次地址尝试、transport 返回、XML commit 前都复核 exact key 与
   monotonic absolute deadline。迟到 response 只能得到 `stale/cancelled`，不能
   发布给新 generation；析构必须 cancel 并 drain，不 detach worker。
4. URL builder 对齐锁定的官方 `NvHTTP`：默认 HTTP `47989`、HTTPS `47984`，
   固定协议兼容 `uniqueid=0123456789ABCDEF`，每请求独立 UUID；IPv6 使用 bracket
   authority，SNI/serverName 与连接地址分离，query 逐值 percent-encode。只允许
   GET、`http/https`、端口 `1..65535` 和白名单 endpoint；禁止 redirect、proxy、
   user-info、fragment、CR/LF 和调用者注入重复保留参数。
5. endpoint/字段合同固定为：`serverinfo` 可在未配对 HTTP 读取候选，已有 pin 时
   先走 HTTPS；`applist`/`appasset`/pair challenge/launch/resume/cancel 必须是
   authenticated HTTPS。`pair`/`unpair` 的低层 request 形状可构造，但 N1-06 前
   不执行配对密码学；launch/resume 只消费调用者给出的 opaque launch material，
   N1-04 不生成/持久化 `rikey`；`rikey` 必须是 32 hex、`rikeyid` 兼容官方
   `SecureRandom.nextInt()` 的 signed 32-bit，且 request 固定 `corever=1`。cancel
   返回 200 后还必须用 authenticated HTTPS `serverinfo` 复核 `currentgame=0`；忙、
   失败或无法判定都不能写成功。证书不匹配只能返回 `trustConflict`；允许为重新
   配对读取 HTTP 候选，但绝不能借此维持 paired/launch truth。
6. transport 是唯一注入 seam，接收 immutable request、absolute deadline、
   cancel probe 和 response budget，返回 DNS/connect/TLS/HTTP/body 阶段及
   `notSent / sentResponseUnknown / confirmedResponse` 发送事实。N1-04 的生产对象
   没有 NAPI 调用者；N1-05 再提供 owner-scoped TLS client identity adapter。
   read-only 请求可按稳定地址优先级顺序尝试；mutation 一旦可能已发送就不得
   自动换地址重放，必须返回 `unknown` 交给显式用户重试/主机复核。
7. 全部输入先过 budget：URL ≤ 8 KiB、body ≤ 4 MiB、XML depth ≤ 32、elements
   ≤ 16384、每元素 attributes ≤ 16、name ≤ 64 bytes、attribute ≤ 1 KiB、单 text
   node ≤ 256 KiB、apps ≤ 2048、title ≤ 1 KiB。只允许一个有界且位于 root 前的
   XML declaration；拒绝其他 processing instruction、DTD、DOCTYPE、外部/自定义
   entity、NUL、非法 UTF-8、未闭合/错配标签、重复 root 和 trailing
   non-whitespace；只解码五个 XML builtin entity 与合法 numeric entity。
8. root 必须带唯一十进制 `status_code`；按官方兼容行为接受 `0..UINT32_MAX` 后映射
   到 signed 32-bit（包括 `0xFFFFFFFF → -1`），只有 200 进入业务解析。
   serverinfo 必填 `uniqueid/appversion/state/PairStatus/currentgame`，version 必须为
   四段有界整数；其余 hostname、HTTPS/External port、地址、GFE/GPU、codec/luma
   是有界 optional。app list 只提交正整数唯一 ID、非空 title 和可选 HDR；未知字段
   忽略，缺字段计入 bounded partial，冲突 duplicate ID 或同 ID 不同 title 整批失败。
9. timeout 使用一次 absolute budget，不因 DNS、地址切换或 body progress 重置；
   参考官方 3s short-connect、5s long-connect、7s read，但 caller budget 下限固定
   100ms，普通操作上限 30s，只有用户正在等待 PIN 的初始 `getservercert` pair
   阶段可到 120s。HTTP transport status 与 XML root status 分开保存；404、401、
   TLS version、chain、pin mismatch、timeout、cancel、body-too-large、malformed XML、
   host busy 和 action unknown 都有稳定 code，不能压成一个“连接失败”。
10. diagnostics 只保留 operation、stage、attempt index、family、port、HTTP/XML status、
    byte count、duration、stable code 和 masked endpoint；不得保存完整 host、query、
    UUID、证书、PIN、token、`rikey`、XML body 或 app title。错误字符串和测试输出做
    secret canary 扫描；request 的 debug formatter 必须把所有 query value redact。
11. focused tests 至少覆盖官方 serverinfo/applist/launch/resume/cancel fixtures、未知
    字段、partial app、duplicate ID、status `0xFFFFFFFF`、DTD/entity bomb、深度/
    数量/长度/UTF-8/截断、URL/IPv4/IPv6/percent encoding、HTTP 与 XML status、TLS/
    pin 错误、deadline/cancel/stale generation、read-only fallback、mutation no-replay、
    unknown result 和日志 canary。通过全量 native、双 ABI产品编译/符号/HAP 隔离、
    双 Hvigor、vendor/TOTP/Light/diff/state 后单独 checkpoint，才允许 N1-05。

N1-04 完成证据：

- 代码 checkpoint `fd2d7ec92` 只修改主 CMake，并新增
  `MoonlightHostApi.h/.cpp` 与一个 focused native test 文件；没有 NAPI、ArkTS、
  production transport/identity、pairing orchestration、媒体、输入、云、资源、UI
  或 feature truth 变化。
- public PIMPL/header 无 common-c、OpenSSL、NAPI/ArkUI include；每个请求绑定非零
  `requestId + generation + ownerToken`，使用同一 monotonic absolute deadline、
  exact cancellation/stale fence，析构 cancel/drain 且没有 worker/detach。
- request builder 对齐锁定的官方 Android revision，包括端口、fixed uniqueid、逐请求
  UUID、IPv6/SNI 分离、pair/app/launch/resume/cancel query；只读按 caller 冻结地址
  顺序 fallback，mutation 只有 `notSent` 才可重试，任何 maybe-sent 结果均为
  `actionUnknown`。cancel 以 authenticated `serverinfo/currentgame` 再确认。
- parser 事务式提交并实施 4 MiB/32 depth/16384 element/16 attrs/64-byte name/
  1 KiB attr/256 KiB text/2048 apps/1 KiB title 全部预算；允许唯一 leading XML
  declaration，拒绝其他 PI、DTD/custom entity、NUL、非法 UTF-8、重复 root 与尾随
  junk。15 个定向用例还包含 512 个确定性随机 body 与截断 corpus。
- 沙箱外全量 native **370/370 PASS**；同一 370 项在 ASan/UBSan 下 PASS、无报告。
  macOS sanitizer 不支持 leak detection，因此明确以 `detect_leaks=0` 运行，未伪造
  LSan 证据。
- arm64-v8a/x86_64 各保持 48 个 `rdpnapi` compile command，并恰有一个 private
  Host API archive command、零 upstream include leak；defined/undefined/
  `napi|init|register` inventories 分别保持 16103/698/716 与 15634/696/711，均和
  N1-03 基线逐字相同；签名 HAP 仍为同一 423 项。
- 最终代码上的双 Hvigor、双 ABI platform probe、common-c 四个 locked receipt、
  vendor 三 tree/117 文件/合规生成幂等、TOTP、Light 与 diff 均 PASS；HDC 仍为
  `Connect server failed`，未新增 Hypium、真实 Sunshine 或用户实机声明。

### 11.2 N1-05 secure identity 完成事实

N1-05 代码 checkpoint 为 `599882ada`。本步只新增
`MoonlightSecureIdentity.h/.cpp`、窄平台 backend/probe、一个 focused native test
文件和主 CMake 私有静态归档接线；没有修改 `host_locker.cpp`、`DataCrypto`、旧协议
credential store、ArkTS/NAPI、云表、资源、路由、UI 或六项 capability truth。

1. alias 输入只能是已验证的 lowercase SHA-256 owner fingerprint 与 installation ID；
   以 domain-separated SHA-256 派生固定 64 字符 `rdml-v1-` + 56 hex。原始 owner、
   UnionID 和 installation ID 不出现在 alias、metadata、diagnostic 或 inventory。
2. 生成材料严格对齐锁定的 Moonlight Android revision
   `f10085f552b367cf7203007693d91c322a0a2936`：RSA-2048、public exponent 65537、
   SHA256withRSA、自签 X.509 v3、单一 CN `NVIDIA GameStream Client`、正 8-byte
   随机 serial、约 20 年有效期、PEM LF 与 PKCS#8。提交前重新解析并验证算法、
   位数、指数、subject、serial、时间窗、自签名、key/cert pair、canonical DER/PEM
   和 SHA-256 fingerprint；坏随机源与 partial 结果 fail closed。
3. private material 只存在于 move-only secure buffer/lease。buffer 尽力 `mlock` 并
   把 page-lock 事实显式暴露为 capability/测试证据，所有释放路径用
   `OPENSSL_cleanse` 后 `munlock`；签名与 `SSL_CTX` 配置不返回 private bytes，lease
   结束后 EVP key 由 OpenSSL 释放。日志和 terminal result 只含 masked alias、stable
   code、operation 与 duration。
4. 每个 alias 只有一个 mutation owner，operation key 固定为非零
   `requestId + generation + ownerToken`。ensure/rotate/delete/acquire/inventory/cancel
   都实施 exact stale/cancel fence；delete/rotate 先关新 lease admission 再 drain。
   store/erase 调用前 cancel 胜出，已成功原子提交后 commit 胜出；unknown outcome
   关闭 admission 并要求显式 delete repair，不做危险回滚。已有 identity 的 ensure
   被取消也绝不删除原记录。
5. backend contract 要求 store 前加密、load 返回新解密的 move-only buffer、每次
   平台 I/O 自带有限 deadline、原子持久化且无 plaintext fallback。API 23 双 ABI
   编译探针确认 HUKS alias 上限 64、RSA-2048/SHA-256/PKCS#1 signer、AES-GCM wrapping
   与 Asset metadata API 可链接；Asset secret 小于 1024 bytes，不能直接容纳 PKCS#8
   或靠分片绕过。编译链接不能证明 AppSpawn 权限、硬件语义、TLS provider 或原子
   encrypted blob，因此 product backend 正确返回 `RuntimeProofRequired` 且所有
   storage operation 为 unavailable。
6. 14 个定向用例覆盖 alias owner/install 隔离、官方证书、签名/TLS、page lock/
   cleanse、owner inventory/exact deletion、cross-owner、lease drain/timeout、rotation、
   concurrent ensure/cancel、commit-wins race、corruption/AAD-equivalent mismatch、
   outcome unknown、已知失败 rollback、entropy failure、orphan/duplicate inventory 和
   unproven capability。fake plaintext backend 只编译进 `RDP_TESTS_ONLY` host target，
   不进入产品归档。
7. 沙箱外全量 native **384/384 PASS**，ASan/UBSan 同为 **384/384 PASS** 且无
   sanitizer 报告；macOS 不支持该二进制的 LSan，明确使用 `detect_leaks=0`，没有
   伪造 leak receipt。strict warnings、`clang --analyze`、双 ABI API 23 strict build
   和 platform probe 均通过。
8. arm64-v8a/x86_64 产品仍各为 48 个 `rdpnapi` compile command，并分别有 1 个
   private Host API 与 2 个 private secure-identity compile command，零 upstream
   include leak。defined/undefined/`napi|init|register` inventory 保持
   16103/698/716 与 15634/696/711，和 N1-04 基线逐字相同；签名 HAP 仍为 423 项。
9. 最终文档状态上的两项 Hvigor 均退出 0，signed `assembleHap` 为
   `BUILD SUCCESSFUL in 21 s 735 ms`；vendor 三 tree/117 文件、shell/PowerShell 四个
   archive receipt、TOTP 251 assets、Light 和 diff 全部 PASS。HDC 返回
   `Connect server failed`，所以本步没有 HAP runtime HUKS、Hypium、真实 Sunshine
   或用户 ARM64 真机声明。

N1-06 的唯一合法入口是依赖注入的 dormant native pairing state machine：所有
HTTP/XML 必须经 N1-04，所有 client cert/signing 必须经 N1-05 exact lease；不得复制
transport、parser、certificate generator 或 secret store。product identity backend
仍 unavailable，因此 N1-06 只能形成 host-test/platform-static checkpoint，不能被
NAPI/UI 或签名 HAP runtime 调用。详细原子步骤以主计划第 15.7.5 节为准。

### 11.3 N1-06 pairing 完成事实

N1-06 代码 checkpoint 为 `6f7094038`。本步新增 hidden
`MoonlightPairingManager.h/.cpp`、一个 focused native test、主 CMake 私有静态归档，
并只为 N1-04 Host API 增加 pure validation 和 ephemeral wire scratch 清零；没有 NAPI、
ArkTS、UI、云表、cache、媒体、输入、production transport/identity/trust wiring 或
capability truth。

1. 状态机固定为 idle/preflight/get-cert/trust/client challenge/server challenge/secret
   verification/client secret/final challenge/commit/paired 与 fail/cancel 终态。每个
   owner+host 只有一个 mutation lane，key 是 exact request+generation+ownerToken；
   admission 插入事务式回滚，析构关闭 admission 并 drain。
2. wire 与锁定 Android revision 一致：四步 `/pair` mutation 是 HTTP，只有最终
   `phrase=pairchallenge` 为 HTTPS；candidate pin 与同一 identity lease 冻结到 final。
   generation>=7 固定 SHA-256，legacy SHA-1 只允许显式 opt-in，无 downgrade。
3. 4-digit PIN、16-byte salt/client challenge/client secret、PIN-derived AES-128 ECB
   zero-padding key、challenge hash、server secret/signature 与 client signature assembly
   都在 secure buffer；Host API URL/XML/body/query scratch 同步清零且 diagnostic 全脱敏。
4. server cert 做 bounded/canonical DER、self-signature、有效期、RSA>=2048/EC>=256、
   SHA-256 fingerprint；server secret signature 先验签，再常量时间比较 challenge hash。
   trust port 只见 bounded label/subject/issuer/validity/fingerprint 与 masked host。
5. 一次 monotonic deadline 覆盖所有主步骤；剩余不足 Host API 100ms 下限时零发包。
   trust/TLS bind/commit 均可 exact cancel；maybe-sent 永不 replay。失败后最多一次独立
   2s unpair，原始 Host error 不被 cleanup 覆盖。
6. atomic commit known-failure rollback+unpair；commit/rollback unknown 调
   `recordRepairRequired` 并冻结 lane，下一请求在首包前返回 repair-required。commit
   confirmed 后 late cancel 不反写失败。
7. 15 组 pairing 测试覆盖 SHA-256/SHA-1、wrong PIN、MITM、空/坏/超长 cert、跨阶段
   字段、后半段 HTTP/XML/hex/paired failure、trust reject/timeout/stale、deadline、
   maybe-sent/cleanup unknown、rollback/repair、并发与 trust/TLS/commit/destructor drain。
   Host API 现为 16 组，identity 14 组，owner 13 组。
8. 沙箱外 native **400/400 PASS**，ASan/UBSan **400/400 PASS** 且无报告；LSan 在该
   macOS runtime 不支持，明确 `detect_leaks=0`。strict `-Werror` 与 Host API/pairing/
   pairing-test 三份 analyzer 均零诊断。
9. arm64-v8a/x86_64 产品每 ABI仍为 48 个 `rdpnapi`、1 个 Host API、2 个 identity、
   1 个 pairing compile command；pairing 零 upstream include leak。defined/undefined/
   NAPI inventories 保持 16103/698/716 与 15634/696/711，签名 HAP 仍 423 路径。
10. 最终两项 Hvigor、双 ABI API 23 platform probe、三 tree/117 文件、合规生成幂等、
    TOTP 251 assets、Light 与 diff 全 PASS。HDC 为 `Connect server failed`，所以无新增
    Hypium、HAP runtime identity、真实 Sunshine 或用户 ARM64 真机声明。

### 11.4 N1-07 Host Control 完成事实

N1-07 代码 checkpoint 为 `019ed98b4`。本步只新增 hidden
`MoonlightHostControl.h/.cpp`、一个 focused native test 和主 CMake 私有归档接线；
没有 NAPI、ArkTS、UI、cache/cloud、媒体、输入、production identity/transport 或
capability truth 变化。

1. public C++17 value/PIMPL 只依赖 N1-04 Host API；access port 必须证明 exact owner/
   generation 已具备 client identity、certificate pin 和 authenticated transport，
   production port 缺失时首包前 unavailable。
2. catalog 事务提交 owner+host+server UUID+generation snapshot，接受 complete empty，
   拒绝 partial、零/重复 app ID；asset 只取同 generation 的已知 app，不落盘、不解码。
3. launch 只允许 idle；同 app 返回 `ResumeRequired`、其他 app 返回 `HostBusy`，绝不
   auto-resume/quit。resume 只允许 exact running app；invalid app 在 mutation 前拒绝。
4. launch/resume 的 move-only 16-byte RI key、query scratch 和 transient RTSP 都被清零。
   accepted+RTSP 之后仍必须 authenticated serverinfo postcheck；不确定结果清 RTSP、
   返回 `OutcomeUnknown` 且不重放。
5. quit 是独立显式命令：idle 是 idempotent success，非 idle 要用户确认和 optional
   expected app match；实际执行复用 N1-04 cancel+authenticated idle verification。
6. exact request+generation+ownerToken、一次 absolute deadline、generation watermark、
   same-lane read/write fence、跨 host read 并行和全进程单 mutation 均已测试；析构
   exact cancel/drain，不 detach。
7. 26 组新用例覆盖完整/部分/空/重复 catalog、asset、unpaired/pin/UUID、launch/
   resume/quit truth、not-sent fallback、maybe-sent no replay、deadline/cancel/stale、并发、
   secret canary 与 destructor drain；全量 native/ASan/UBSan **426/426 PASS**。
8. strict `-Werror`、Host Control 与测试 analyzer 零诊断；双 ABI platform probe、vendor
   三 tree/117 文件、TOTP 251 entries、Light、两项 Hvigor 均 PASS。
9. arm64/x86 dynamic inventories 仍为 16103/698/716 与 15634/696/711，HAP 仍 423
   路径；每 ABI 86 条 compile command 中有 48 条 `rdpnapi`、1 Host API、2 identity、
   1 pairing、1 Host Control，Host Control 零 upstream include 且不出现在动态符号。
10. HDC 仍返回 `Connect server failed`，所以没有新增 Hypium、HAP runtime identity/
    transport、真实 Sunshine 或用户 ARM64 真机声明。

### 11.5 N1-08 typed bridge 完成事实

N1-08 代码 checkpoint 为 `aecd2ea4e`；本轮 sanitizer 发现的既有
`ExecutorDeferredOwner` 初始化竞态以独立 checkpoint `aa3b947` 修复。除该最小原生
生命周期修复外，本步只修改主 CMake、`napi_init.cpp`、唯一发布 d.ts、测试聚合器，并
新增 `MoonlightNativeBridge`、独立 Moonlight NAPI、`MoonlightHostService` 和 focused
tests；没有修改 UI、路由、资源、FeaturePolicy、云表注册、媒体、输入或其他协议。

1. NAPI-free bridge 以 exact 非零 request/generation/owner key、owner/host generation
   watermark、duplicate retirement、active registry、bounded 256 event queue、exact
   cancel/cancelOwner 和 shutdown cancel/drain 管理进程边界；PIN、RI key、RTSP scratch
   在所有终态清零。
2. product `MoonlightUnavailableRuntimePort` 的 identity/transport/trust/commit/pairing/
   host-control capability 全 false，任何操作在 DNS/socket/TLS 前稳定返回
   `runtime_proof_required`；fake runtime 只存在于 host test，不进入 release truth。
3. NAPI 只增加五个 `moonlight*` 属性，exact parser 拒绝 unknown field/type、NaN/
   Infinity、非 safe integer、越界字符串/数组和 binary shape；worker 不创建 JS value，
   completion 单次 settlement，env cleanup 关闭 admission、取消 work、shutdown/drain。
4. 发布声明只更新 `entry/src/main/cpp/types/librdpnapi/index.d.ts`；旧
   `entry/src/main/ets/types/rdpnapi.d.ts` 经消费者盘点不是同一发布镜像，因此未复制一份
   drifting declaration。
5. ArkTS `MoonlightHostService` 只消费 injected native/lease/cache ports。请求、结果、
   event 和 cache 前后都复核 ownerScope/storeIdentity/generation/storeInstance；stale 只
   计数丢弃。只有 confirmed、complete、partial=0、唯一正 app ID 的 catalog 才调用现有
   app cache complete refresh，cache failure 不篡改 native truth。
6. 14 个新增 native case 覆盖 product packet-free unavailable、exact DTO、typed result/
   event、duplicate key retirement、external cancel-before-runtime、bounded result/event、
   stale/cancel/cross-owner、secret cleanse、exception 和 destructor drain；全量普通测试
   **440/440 PASS**。
7. ASan/UBSan 首次复跑捕获 deferred owner 的 thread-before-state 初始化；成员声明顺序
   修复后连续三轮均 **440/440 PASS**。bridge/NAPI/test/deferred-owner 四份
   `clang --analyze` 均零诊断，strict `-Wall -Wextra -Werror` 通过。
8. 13 个新增 ArkTS case 覆盖 native 注入、lease/store 重开、A→B stale、完整/部分目录
   cache、cache/release exception、launch material release、cancel/dispose/event；聚合器现
   为 20 个 describe、151 个 compile-registered Moonlight test。Hypium 未执行。
9. 最终双 ABI defined 与 `napi|init|register` 集合和 N1-07 逐项相同；undefined 无删除且
   仅增加 `napi_add_env_cleanup_hook`、`napi_cancel_async_work`、`napi_create_error`、
   `napi_get_property_names`、`napi_get_typedarray_info`、`napi_has_named_property`、
   `napi_is_typedarray` 七项。inventory 为 arm64 16103/705/716、x86 15634/703/711。
10. 每 ABI 88 条 compile command 中 48 条仍为 `rdpnapi`；bridge/NAPI 两条位于最后链接
    且 `--exclude-libs` 的 private archive，upstream include leak=0。signed HAP 仍 423
    路径；两项 Hvigor、双 ABI probe、vendor 三 tree/117 文件、TOTP 251、Light 和 diff
    全 PASS。HDC 仍为 `Connect server failed`，无新增 runtime/Sunshine/真机声明。

N2-01 已由 `db5865c53` 按主计划第 15.7.8 节完成：private/hidden archive 只含
project-owned requested/effective/capability/adjustment 类型、deterministic resolver 与同源
launch projection。36 个 focused case 使普通和连续三轮 ASan/UBSan 全量达到 476/476；
strict/analyzer、两 ABI 产品编译、symbol/NAPI/include/HAP isolation、双 Hvigor、platform、
vendor/TOTP/Light 全通过。每 ABI 只增加一条 stream-config command（总数 89、`rdpnapi`
仍 48），动态 inventory 与 423 路径 HAP 逐项不变。`offer_ready` 仍不是 negotiated，
`selectedCodec` 始终 absent，在线云注册、FAB 和六项 truth 没有变化。

## 12. 2026-08-10 N1-01～N2-05 checkpoint 验证

- `default@OhosTestCompileArkTS`：N2-01 最终源码后 **BUILD SUCCESSFUL**；20 个
  describe、151 个 Moonlight test 编译注册，不声明设备执行。
- signed `assembleHap`：N2-01 最终源码后 **BUILD SUCCESSFUL**；signed HAP 为 423
  路径，SHA-256 `095700a5af1823645689d913b4c995f5cca662eafa6202fec12b0eb68156a0ac`。
- host `rdp_native_tests`：普通 **476/476 PASS**；ASan/UBSan 连续三轮 **476/476 PASS**，
  `detect_leaks=0` 仅因为当前 macOS sanitizer runtime 不支持。
- stream config 与 focused test strict `-Wall -Wextra -Wpedantic -Werror` 通过，analyzer
  零诊断；两 ABI 产品 config command 也保持 strict `-Werror`。
- `scripts/probe_moonlight_platform.sh`：arm64-v8a、x86_64 API 23 compile/link 均 PASS；
  这不是 HAP/AppSpawn runtime receipt。
- `verify_open_source_release.ps1 -Mode Light`、三个官方 Git tree/117 exact file vendor
  gate、TOTP 251 entries 均 PASS；本步不改任何 upstream byte 或 compliance pin。
- product ABI audit：defined/undefined/NAPI-filtered 集合与 N1-08 逐项相同，仍为 arm64
  16103/705/716、x86_64 15634/703/711；每 ABI 89 条 command 中 `rdpnapi` 仍 48，新增
  config command 无 upstream include；HAP path inventory 零变化。
- `CloudSyncPolicy.CLOUD_SYNC_TABLES` 静态复核仍精确为既有 8 表；Moonlight cloud、
  local mirror 和 app cache 均未进入在线注册集合，所有 feature truth 仍 false。
- HDC 当前 `list targets` 无输出并在人工中断后退出；早期 ARM64 API 24 RDB receipt 仍有效，但本次
  没有新增虚拟设备 Hypium、HUKS/TLS、真实 Sunshine 或用户 ARM64 真机证据。

N2-02 `248e704ab` 在上述 N2-01 基线上只增加一个 dormant native archive、一个显式
EXCLUDE_FROM_ALL 官方 common-c link probe、20 个 adapter case，以及由失败测试冻结的
owner `requestStop` case。adapter header 不暴露 `Limelight.h`；product `.cpp` 精确初始化
并映射 `SERVER_INFORMATION`、`STREAM_CONFIGURATION` 和全部 callback struct，唯一调用
`LiStartConnection/LiInterruptConnection/LiStopConnection`。process-global router 只保存
accepted exact key/weak invocation，高水位阻断旧 owner；所有 callback 经 owner/local lease，
finalize 先关闭 admission、等待 in-flight、退休 router，再清 RI key/IV/key ID/RTSP/backing。
setup/init 是 negotiated video/audio 的唯一真值，11 个 stage 严格单调，scheduler 只调用
owner 的 non-blocking stop request；`transportReady` 永不产生 `firstFrameReady`。

- host 普通测试 **497/497 PASS**；ASan/UBSan 连续三轮 **497/497 PASS**，macOS runtime
  不支持 leak sanitizer，故明确使用 `detect_leaks=0`。strict
  `-Wall -Wextra -Wpedantic -Werror` 与四份 clang analyzer 均通过。
- TSan binary 可构建；全量运行在进入 Moonlight 用例前停于既有
  `rustdesk_continuity_executor_deferred_owner_reclaims_after_release` 的 TSan 定时断言，
  之前无 `ThreadSanitizer`/race/SUMMARY 输出。N2-02 的 async blocked-media callback、
  external termination、stale callback 与 destructor barrier 在普通/ASan 中确定性通过，
  作为本机可用的等价 race harness；不把未完成的全量 TSan 写成 PASS。
- 两 ABI 产品 `rdpnapi` 与 `moonlight_common_c_adapter_link_probe` 均编译链接；每 ABI
  90 条永久 command 中 `rdpnapi` 仍 48、adapter 恰 1，零 upstream include leak。
  arm64 16103/705、x86_64 15634/703 的 defined/undefined name+type 集合，以及各 147
  条 NAPI name+type+size 子集均与 N2-01 基线逐项相同。
- `default@OhosTestCompileArkTS` 与 signed `assembleHap` 均 **BUILD SUCCESSFUL**；HAP
  SHA-256 `3d67e3a743207d39df8e4bb81ba7f49efd7acd8896f412000defc6670af05578`，排序后
  423 路径与基线逐项相同且无 adapter/common-c 新路径。
- API 23 双 ABI platform probe、三棵官方 Git tree/117 exact files、TOTP 251 entries、
  Light、diff 均 PASS。在线云注册仍精确 8 表；Moonlight FAB disabled/“即将支持”各
  1 项，11 个 feature input 初值和六项发布 truth 均未放行。
- 第二个允许的 `gpt-5.6-sol low` reviewer 只读审查
  `49735f1a1..248e704ab`，对官方映射、owner/router、竞态、cleanse、产品隔离、测试与
  本节事实给出 PASS、无 P0/P1/P2；后续复核复用既有 task ID，不得创建第三个 reviewer。

N2-03 `34d2ffa7a` 在 N2-02 后只新增 hidden/private `MoonlightVideoBridge` archive、8 个
focused bridge case，并把 adapter opaque payload seam 收窄为 project-owned typed view。
锁定上游事实为：`LENTRY` 只有 `next/data/length/bufferType`，`DECODE_UNIT` 只有
`frameNumber` 而无 decodeNumber；本地 offset 按链顺序计算。adapter 在 callback lease 内
最多投影 64 项，单 fragment 4 MiB、总 AU 16 MiB、config 1 MiB，先拒绝 null、负数、
unknown、cycle、溢出、长度不一致、time/colorspace 和非法链形状，再同步交给 bridge；
header/bridge/tests 均不 include `Limelight.h`。

bridge 在 sink 前复制连续 owned bytes 和 fragment offset，保存 H.264 SPS/PPS、HEVC
VPS/SPS/PPS；AV1 只接受 picture data。config generation 只随内容变化且被 accepted 的 IDR
增长。P frame 在首个 accepted IDR 前，以及 backpressure/need-IDR 后保持 gated；bridge 与
adapter 各自合并一次 IDR 请求，accepted IDR 才解除。exact key/profile、owner-token
high-water、serialized submit、admission-close→in-flight drain→config clear 和析构 drain
均已冻结。product unavailable sink 不创建 decoder，`firstFrameReady` 始终 false。

- host 普通测试、strict `-Wall -Wextra -Wpedantic -Werror` 与完整 TSan 均
  **506/506 PASS**；ASan/UBSan clean rebuild 连续三轮 **506/506 PASS**，当前 macOS
  leak sanitizer 不支持，故显式 `detect_leaks=0`；scan-build 全 native 目标零报告。
- 两 ABI 产品 `rdpnapi` 与官方 adapter link probe 均通过；每 ABI 91 条永久 command 中
  `rdpnapi` 48、adapter 1、video bridge 1、probe 0。bridge 无 OH_AVCodec、Surface、NAPI、
  ArkTS include；除 adapter `.cpp` 外产品代码无 `Limelight.h` include。
- arm64 16103/705、x86_64 15634/703 的 defined/undefined name+type 集合及各 147 条
  NAPI name+type+size 子集与 N2-02 基线逐项相同。
- `default@OhosTestCompileArkTS` 和 signed `assembleHap` 均 **BUILD SUCCESSFUL**；HAP
  SHA-256 `d5311acdf2d8e02385cf7bf2d33bd737e971584058b0c90d9ef7c1a0bfa9d045`，排序后
  423 路径与基线逐项相同。
- API 23 arm64-v8a/x86_64 platform probe、三棵官方 Git tree/117 exact files、TOTP 251、
  Light、diff 均 PASS。在线云表仍精确为原有 8 张；FAB 中 Moonlight/disabled/“即将支持”
  各 1；11 个 feature inputs 默认 false，六项 snapshot 无默认放行；平台能力默认
  11 pending、1 unsupported、0 supported。
- 两个 reviewer 实例已在 N1-01 和 N2-02 建立。本 checkpoint 完成逐文件自审和全部机器门禁，
  但尚未复用既有 reviewer 取得匹配回执；状态命令应报告 `RESUME_REVIEW/REVIEW_REQUIRED`，
  不得创建第三个实例或伪造 receipt。

N2-04 `bee0ac1da` 在 N2-03 后新增一个 hidden/private pure
`MoonlightOwnedVideoDecoderSink`、一个 OHOS-only `MoonlightHardwareDecoderPort`、9 个
focused sink case，并只对既有 renderer/decoder 增加 hidden exact-owner typed seam。
bridge 仍不 include NAPI/平台头；它只把 prospective codec configuration generation 随同
IDR 交给 sink，并在 sink accepted 后提交。sink start 同时校验 exact key/profile/尺寸、
decoder/renderer/display handle+generation、handle ownership 和 runtime proof；port 只读取
当前 shared owner，不调用全局 owner/display setter，也不创建第二 registry、active pointer、
callback lane 或 retire owner。

MVP 只接受 H.264 8-bit 4:2:0。第二个配置 generation 的 IDR 复用既有 recovery/recreate，
新的 decoder generation 只有在其余 binding 字段逐项相同时才原子接纳。`DecodeOwnedNative`
把 queue pressure、pipeline transition、need-keyframe、owner/display/generation stale 和平台
failure 分开；旧 `Decode/DecodeNative` 结果保持不变。首帧要求 exact generation 下
RenderOutputBuffer、NativeImage update、actual EGL swap 三段均成功；swap 后再次核对 active
renderer handle/generation，旧 Surface 的实际 draw 不会成为新 Surface 的 first-frame ack。
stop 关闭 admission、drain submit，再复用 exact detach/destroy/deferred retirement。

- host 普通、strict `-Wall -Wextra -Wpedantic -Werror` 与完整 TSan 均
  **515/515 PASS**；ASan/UBSan clean rebuild 连续三轮 **515/515 PASS**，scan-build 全
  native 目标零报告。
- arm64-v8a/x86_64 产品 `rdpnapi`、sink archive 和 callback-entry carrier 均编译链接；
  每 ABI 93 条永久 command 中 `rdpnapi=48`、adapter=1、video bridge=1、decoder sink=2。
- ABI 与 N2-03 逐项一致：arm64 defined/undefined 16103/705、x86_64 15634/703，两个 ABI
  的 NAPI name+type+size 子集各 147；新增 seam 全部 hidden，HAP 不增加调用面。
- 最终 `default@OhosTestCompileArkTS` 与 signed `assembleHap` 均 BUILD SUCCESSFUL；HAP
  SHA-256 `65db3cb5d303dd37c86fbefac514fa2bc7f9749ba6a5487151a14648b752e1bd`，排序后
  423 paths 与 N2-03 基线逐项相同。
- API 23 双 ABI platform probe、官方 common-c link probe、三棵 Git tree/117 files、
  TOTP 251 与前置 Light/vendor receipt 保持通过；在线云表仍精确 8 张，FAB 的 Moonlight、
  disabled 和“即将支持”各 1，11 个 feature inputs 默认 false，平台能力默认
  11 pending/1 unsupported/0 supported。
- 产品 archive 仍无 factory caller、NAPI/ArkTS 路由或 session coordinator；HAP/AppSpawn
  H.264/NativeImage/renderer receipt 缺失，故本 checkpoint 不声明真实解码或首帧可用。
  尚未复用既有 reviewer，只记录逐文件自审和机器门禁。

N2-05 `7992279c7` 在 N2-04 后只新增 hidden/private
`MoonlightVideoSurfaceLifecycle` 和 8 个 focused case，并为 N2-04 sink/port 增加最窄的
exact detach/rebind seam。它没有修改 `RemoteDesktop.ets`、`RemoteSessionPipService`、NAPI、
ArkTS、云、音频或输入，也没有任何 product factory caller。状态固定为
`AwaitingSurface/Bound/Suspending/SuspendedNoSurface/Rebinding/Stopping/Stopped`；命令携带
exact key 和单调 operation generation，binding 同时携带 Surface、renderer 与 runtime-proof
generation。

初始无 Surface 时的 gate 位于 `MoonlightVideoBridge::submit` 之前；即使传入 null 16 MiB
borrowed fragment，也以 `NoSurface` 返回、owned bytes 为 0、sink 调用为 0，只合并一次 IDR
需求。初始 bind 才按 exact contract start sink/bridge。temporary suspend 先关闭 admission、
drain submit、清 first-frame，再 exact detach pipeline；decoder registry handle、codec config
generation 和网络连接保留。rebind 复用同一 decoder handle/key/profile/display/config，只接受
严格更新的 Surface/renderer/runtime-proof generation；重新开放 admission 后保持等 IDR，
新 IDR 前 P frame 仍被拒绝。同 Surface generation 的 resize 只更新 viewport，不改变 binding、
remote negotiated dimensions 或既有 first-frame receipt。stop exact、幂等、timeout 后可重试，
完成后 lifecycle 可被更高 owner token 复用。

- host 普通、strict `-Wall -Wextra -Wpedantic -Werror` 与完整 TSan 均
  **523/523 PASS**；ASan/UBSan clean rebuild 最终连续三轮 **523/523 PASS**，当前 macOS
  leak sanitizer 不支持，故显式 `detect_leaks=0`；scan-build 全目标零报告。一次较早的 ASan
  run 在未改动的 common-c timing case 443 失败且无 sanitizer report，随后 fail-fast 三轮及
  最终源码三轮均通过，不把该非复现结果隐藏或误记为 sanitizer defect。
- arm64-v8a/x86_64 产品 `rdpnapi`、sink/lifecycle archive 和 callback-entry carrier 均通过；
  每 ABI 94 条永久 command 中 `rdpnapi=48`、adapter=1、video bridge=1、
  decoder sink/lifecycle=3。动态 ABI 与 N2-04 逐项一致：arm64 16103/705、x86_64
  15634/703 defined/undefined，两 ABI NAPI name+type+size 子集各 147。
- 最终 `default@OhosTestCompileArkTS` 与 signed `assembleHap` 均 BUILD SUCCESSFUL；HAP
  SHA-256 `e2598c67896e04949409dbe93d26ec8a7ee390a53e1052aa0c7c8e0c692453c8`，排序后
  423 paths 与 N2-04 基线逐项相同。API 23 双 ABI probe、common-c link probe、三 Git
  tree/117 files、TOTP 251、vendor/Light 和 diff 均通过。
- 在线云注册仍精确 8 表；FAB 中 Moonlight、disabled、“即将支持”各 1；11 个 feature
  inputs 默认 false，平台能力默认 11 pending/1 unsupported/0 supported；changed ArkTS/cloud
  files 为 0。`hdc list targets` 返回 `[Empty]`，本 checkpoint 不声明 HAP/AppSpawn
  Surface/PIP runtime、真实解码或首帧可用；尚未复用既有 reviewer，只记录逐文件自审和机器门禁。

N2-07 `9272f1c9c` 只新增 hidden/private `MoonlightAudioPlayerSink`、production port 和 10 个
focused case，并只在 CMake 中加入私有源文件。sink 将 `MoonlightAudioStreamIdentity.key` 精确
映射到既有 `DecoderSessionIdentity`，所有 PCM、暂停、恢复、停止和清理由 owner/config/
operation generation fence 保护；production port 只委托既有 `DispatchActiveNative`、
`SuspendActiveNative`、`TakeActiveNative` 和 `SharedSessionSinkOwnerLease`。它没有修改
`audio_player.*`、共享队列、RDP/RustDesk/SSH/VNC 业务源码，也没有新增 renderer、registry、
worker、singleton、NAPI、ArkTS、UI、云或 product caller。

- host normal/strict/ASan/UBSan 最终均为 **548 total / 532 pass / 16 fail**，10 个 N2-07
  用例全 PASS；16 项均为既有 VNC 本地 TLS fixture `start()` 失败。最终 TSan 同为
  **532/16** 且无 ThreadSanitizer 报告；首次 TSan 额外一项非复现失败为 **531/17**，同样无
  sanitizer 报告，已如实保留。
- arm64-v8a/x86_64 产品 native 均重新配置并成功链接，新 sink 两个 translation units 实际进入
  `rdpnapi`；两 ABI 动态符号中均无 `MoonlightAudioPlayer`/production factory export。
- 最终两项 Hvigor BUILD SUCCESSFUL（6.017s/13.904s）；signed HAP SHA-256
  `a1d6e72894e2596e431f5dd4806c833611adea942559e5b52afe615abd766ef3`，归档 333 paths；
  Light 与 `git diff --check` PASS。HDC 当前无 target，因此不声明 OHAudio/AppSpawn、真实
  Sunshine 或 ARM64 实机运行时能力。

N2-08 `57b1d7da4` 只新增 hidden/private `MoonlightMediaClockStats`、13 个 focused case 和
独立私有 CMake archive。它使用 exact `MoonlightSessionKey + windowGeneration`、owner/window/
source generation fence 和固定最多 256 槽窗口，区分 absent 与 measured zero；有界汇总
network assembly、decode queue、decode、render、end-to-end、common-c host processing latency、
audio queue 的 p50/p95/max/current count/total，并精确投影 RTP media/FEC/recovered/recovery
failure/OOS/invalid/invalid FEC、audio underrun/drop 增量。累计源 reset/decrease 会重建 baseline，
video stride 与 RTP/audio 时间节流、计数饱和、stop/cleanup/stale callback 均有确定性合同。

- host normal 与 strict `-Wall -Wextra -Wpedantic -Werror` 均为 **561 total / 545 pass / 16 fail**；
  13 个 N2-08 用例全 PASS，16 项仍全是既有 VNC 本地 TLS fixture `start()` 失败。ASan/UBSan
  连续三轮和最终 TSan 同为 **545/16** 且无 sanitizer report；macOS 按既有约束使用
  `detect_leaks=0`。focused clang analyzer 对新增实现/测试为零诊断。
- arm64-v8a/x86_64 产品 native 均重新配置并成功链接；两个私有 archive 非空，但由于没有
  runtime caller，其 object 未被拉入 `rdpnapi`，本地/动态符号均无 `MoonlightMediaClockStats`。
  动态 defined/undefined 集合与 N2-07 产品逐项相同：arm64 **16114/705**、x86_64
  **15645/703**；因此没有新增 NAPI export 或跨协议 ABI 面。
- 最终双 Hvigor BUILD SUCCESSFUL；signed HAP SHA-256
  `5bf7cd91809c7c9e46cf15aa1d8b963946f0d805b91a867ef98492aa441860fe`，归档 333 paths；
  Light 与 `git diff --check` PASS。N2-08 未修改 common-c、共享 telemetry/render/audio 或
  RDP/RustDesk/SSH/VNC 业务源码，也未新增线程、队列、singleton、NAPI、ArkTS、UI、云、日志
  或 product caller；HDC 当前无 target，不声明真实 Sunshine/ARM64 runtime 能力。

N3-01 `fe46025ef` 只新增 hidden/private `MoonlightInputBridge`、12 个 focused case 和独立私有
CMake archive。每个 bounded event 都带 exact `MoonlightSessionKey + inputGeneration`、device、
source/source generation、sequence 和 monotonic timestamp；bridge 使用固定最多 32 个 source
lane 和 64-byte payload，不分配事件队列，不创建线程。owner gate 先获取既有共享跨协议
`SessionSinkOwnerLease`，再获取唯一 `MoonlightSessionOwner` exact callback lease，且只允许
`Running + admissionOpen + !cancellationRequested`，因此 Starting/stale/其他协议 owner 均 fail closed。

- host normal 连续三轮与 strict `-Wall -Wextra -Wpedantic -Werror` 最终均为 **573 total / 557 pass /
  16 fail**；12 个 N3-01 用例全 PASS，16 项仍全是既有 VNC 本地 TLS fixture `start()` 失败。
  ASan/UBSan 连续三轮和 TSan 同为 **557/16** 且无 sanitizer report；focused clang analyzer 对
  新增实现/测试零诊断。
- arm64-v8a/x86_64 产品 native 均重新配置并成功链接；两个私有 archive 非空，但由于没有
  runtime caller，其 object 未被拉入 `rdpnapi`。产品与 HAP 内 `rdpnapi` 的本地/动态符号均无
  `MoonlightInput`；defined/undefined 动态符号数量仍为 arm64 **16114/705**、x86_64
  **15645/703**，与 N2-08 基线一致。
- 最终双 Hvigor BUILD SUCCESSFUL；signed HAP SHA-256
  `645308dff61bb65c959ddb9f704eba1334f04fca5af74af59131183965326ba9`，归档 333 paths；
  Light 与 `git diff --check` PASS。N3-01 未修改 common-c、公共 `InputHandler`、共享
  telemetry/render/audio 或 RDP/RustDesk/SSH/VNC 业务源码，也未新增 NAPI、ArkTS、UI、云、
  日志或 product caller；HDC 当前无 target，不声明真实 Sunshine/ARM64 输入运行时能力。

N3-02 `a552b30a2` 新增 hidden/private `MoonlightKeyboardMapper`、15 个 focused case 和独立私有
CMake archive。映射复用工程既有 HarmonyOS key namespace，严格输出官方 common-c 的
`0x8000 | Win32 VK`、down/up、modifier mask 与 non-normalized flag；物理键和 on-screen UTF-8
文本是独立路径，物理 Esc 永远只作为本地逃生。状态固定上限为 8 个普通键和双侧四类 modifier，
单次最多 16 个命令，覆盖一次/锁定 modifier、跨设备错误 key-up、反序全释放、owner loss、
backpressure/port failure 精确 suffix retry 和 pending payload 清理；未新增线程、队列、singleton
或第二个 owner/adapter。

- host normal 连续三轮、strict `-Wall -Wextra -Wpedantic -Werror`、ASan/UBSan 连续三轮和 TSan
  最终均为 **588 total / 572 pass / 16 fail**；15 个 N3-02 用例全 PASS，16 项仍仅为既有 VNC
  本地 TLS fixture `start()` 失败，sanitizer 无报告；focused clang analyzer 零诊断。N3-01 并发
  测试只修正为同时接受 duplicate-first 与 stop-first 两种合法 mutex 串行结果，生产 bridge 未改。
- arm64-v8a/x86_64 产品 native 均重新配置并链接；keyboard archives 非空，但无 caller 时 object
  未被拉入 `rdpnapi`。本地/动态符号无 `MoonlightKeyboard`/`MoonlightInput`，动态
  defined/undefined 仍为 arm64 **16114/705**、x86_64 **15645/703**，与 N2-08/N3-01 相同。
- 最终双 Hvigor BUILD SUCCESSFUL；signed HAP 共 333 paths；Light 与
  `git diff --check` PASS。无 common-c、公共 `InputHandler`、共享 telemetry/render/audio、
  RDP/RustDesk/SSH/VNC 生产业务源、NAPI、ArkTS、UI、云、日志或 product caller 变化；HDC 无
  target，不声明真实设备输入或 Sunshine runtime 能力。

N3-03 `1787da821` 新增 hidden/private `MoonlightPointerMapper`、18 个 focused case 和独立私有
CMake archive。映射合同使用 physical surface pixel 与有 generation 的 content rect，支持
letterbox/fill/1:1/pan、四向旋转和 DPI 不变的 absolute 坐标；黑边 fail closed，不夹取到远端。
relative motion 保留小数残差且对非有限值/int16 overflow fail closed；按钮只接受官方五键并按
device/source 精确归属，absolute press 由 position+button 原子事务发送，出界 press 被抑制但
release 仍可送达以避免幽灵按键。横纵滚轮、反序 release-all、逐命令状态提交、backpressure/
port failure 未接受后缀精确续传和 pending 清理由固定容量状态机覆盖。

- host normal 连续三轮与 strict `-Wall -Wextra -Wpedantic -Werror` 最终均为 **606 total /
  590 pass / 16 fail**；18 个 N3-03 用例全 PASS，16 项仍仅为既有 VNC 本地 TLS fixture
  `start()` 失败。ASan/UBSan 连续三轮和最终 TSan 同为 **590/16** 且无 sanitizer report；
  focused clang analyzer 零诊断。
- arm64-v8a/x86_64 产品 native 均重新配置并链接；两个 pointer archives 均含
  `MoonlightPointerMapper.cpp.o`，但无 caller 时 object 未被拉入 `rdpnapi`。本地/动态符号无
  `MoonlightPointer`/`MoonlightKeyboard`/`MoonlightInput`，动态 defined/undefined 仍为 arm64
  **16114/705**、x86_64 **15645/703**，与 N2-08/N3-01/N3-02 相同。
- 最终双 Hvigor BUILD SUCCESSFUL；signed HAP 共 333 paths；Light 与 `git diff --check` PASS。
  只新增 Moonlight pointer 私有文件、focused test 与 CMake target；未修改 common-c、公共
  `InputHandler`、共享 telemetry/render/audio、RDP/RustDesk/SSH/VNC 生产业务源、NAPI、ArkTS、
  UI、云、日志或 product caller。capture/constraint/raw-relative 仍无平台接线，不声明真机能力。

N3-04 `ebd2fa0bc5` 新增 hidden/private `MoonlightTouchMapper`、21 个 focused case 和独立私有
CMake archive，并只给 N3-03 pointer mapper 增加共享 normalized transform、原子 click 与双轴
scroll 事务。direct 模式严格输出官方 common-c 28-byte body，只在 host capability 明确存在时
启用；最多 10 个稳定非零 wire id，覆盖 down/move/up/cancel/cancel-all、pressure/ellipse/rotation、
physical-pixel content rect、黑边拒绝、overlay 整个 contact 生命周期归属、geometry/hit-map
generation 与 mode-switch flush。touchpad 最多 3 个 contact，覆盖一指光标/左键、双指滚动/右键、
长按拖拽、三指本地工具条，overlay-owned contact 不参与远端手势；固定 16 个 observed source lane，
single pending、逐命令提交、未接受 suffix retry、取消和析构清理由有界状态机完成。

- host normal 连续三轮与 strict `-Wall -Wextra -Wpedantic -Werror` 最终均为 **627 total /
  611 pass / 16 fail**；21 个 N3-04 用例全 PASS，16 项仍仅为既有 VNC 本地 TLS fixture
  `start()` 失败。ASan/UBSan 连续三轮和最终 TSan 同为 **611/16** 且无 sanitizer report；
  focused clang analyzer 对 touch/pointer 实现零诊断。过程中只观察到既有 common-c 时序用例的
  非连续偶发波动，最终三轮正常回归连续稳定，不修改该测试或生产 adapter。
- arm64-v8a/x86_64 产品均生成含 `MoonlightTouchMapper.cpp.o` 的私有 archive；无 caller 时
  touch/pointer object 不进入 `rdpnapi`。两 ABI 动态 defined/undefined 仍为 arm64
  **16114/705**、x86_64 **15645/703**，本地/动态符号无 `MoonlightTouch`/`MoonlightPointer`/
  `MoonlightInput`，与 N3-03 基线一致。
- 最终双 Hvigor BUILD SUCCESSFUL；signed HAP 共 333 paths；Light、117-file vendor gate 和
  `git diff --check` PASS。未修改 common-c、公共 `InputHandler`、共享 telemetry/render/audio、
  RDP/RustDesk/SSH/VNC 生产业务源、NAPI、ArkTS、UI、云、日志或 product caller。HDC 返回
  `Connect server failed`，不声明真实设备 direct-touch、touchpad 或 Sunshine runtime 能力。

N3-05 `1aadfba24` 新增 hidden/private `MoonlightControllerMapper`、16 个 focused case、独立私有
CMake archive，并扩展只负责验证 SDK 符号可链接的 platform probe。项目自有 28-byte command body
直接投影 pinned common-c 的 `LiSendControllerArrivalEvent()` 与 `LiSendMultiControllerEvent()`
参数；profile 只能使用当前枚举且属于 API 23 保守集合的按钮。映射采用成熟 Moonlight Android 的
7% radial stick deadzone、`0x7FFE` 量程、不重缩放与 Y 反向，以及 13% trigger deadzone；hat 以
±0.5 阈值生成 dpad。状态机固定 slot 0 和 8 个 observed lanes，按 device/source generation、
sequence、timestamp 做 exact fence；full-state frame 只有 bridge 接受后才提交，background 发送
active-mask=1 的 neutral，disconnect 发送 active-mask=0 的全中立 frame 并在接受后释放槽位。

- host normal 连续三轮与 strict `-Wall -Wextra -Wpedantic -Werror` 最终均为 **643 total /
  627 pass / 16 fail**；16 个 N3-05 用例全 PASS，16 项失败仍仅为既有 VNC 本地 TLS fixture
  `start()`。ASan/UBSan 连续三轮与最终 TSan 同为 **627/16**，无 sanitizer report；focused
  clang analyzer 零诊断。
- arm64-v8a/x86_64 均生成含 `MoonlightControllerMapper.cpp.o` 的私有 archive；API 23
  GameControllerKit device online/offline、button、双摇杆、双 trigger、event device id/source type
  符号 compile-link PASS。无 caller 时 object 未进入 `rdpnapi`，两 ABI dynamic defined/undefined
  仍为 arm64 **16114/705**、x86_64 **15645/703**，产品库无 mapper 符号或 controller runtime
  依赖。SDK 未发现官方 rumble/LED/motion/battery 输出 API，因此反馈 capability 保持 unsupported。
- 最终双 Hvigor BUILD SUCCESSFUL，signed HAP 共 333 paths；Light、117-file vendor、TOTP brand
  manifest 与 `git diff --check` PASS。未修改 common-c、公共 `InputHandler`、共享 telemetry/
  render/audio、RDP/RustDesk/SSH/VNC 生产业务源、NAPI、ArkTS、UI、云、日志或 product caller。
  HDC 返回 `Connect server failed`，不声明 HAP/真机实体控制器、双手柄或 Sunshine runtime 能力。

N3-06 `baa9cafef` 新增 hidden/private `MoonlightControllerFeedback`、16 个 focused case 和独立
私有 archive。合同逐能力使用 official API 与 exact physical-device evidence 的交集；API 23
product evidence 固定全 false，所以 rumble、trigger rumble、RGB LED、adaptive trigger、motion
与 battery 均返回 explicit unsupported 且零 port 调用。未来有双证据时仍由 exact owner、controller
slot、device/device-generation、operation-generation 和 monotonic timestamp 栅栏约束；只允许一个
pending command 精确重试。motion 最高 200Hz、重复/过快 sample 本地抑制，battery 同状态 120 秒
刷新，port unsupported 只降级对应能力；suspend/unbind/cleanup/destructor 释放本地 effect/sensor/
LED ownership，resume 不重放。

- host normal 连续三轮与 strict 最终均为 **659 total / 643 pass / 16 fail**；16 个 N3-06 用例
  全 PASS，16 项失败仍仅为既有 VNC 本地 TLS fixture `start()`。ASan/UBSan 最终连续三轮与
  TSan 同为 **643/16**，无 sanitizer report；focused clang analyzer 零诊断。
- arm64-v8a/x86_64 archive 分别为 352518/343878 bytes 且含单一 feedback object；无 caller 时
  object 未进入 `rdpnapi`，dynamic defined/undefined 仍为 arm64 **16114/705**、x86_64
  **15645/703**，产品库无 feedback 符号或 `ohgame_controller` dependency。
- `default@OhosTestCompileArkTS` 与 signed `assembleHap` 均 BUILD SUCCESSFUL；HAP 333 paths。
  Light、117-file vendor、TOTP 与 `git diff --check` PASS。未修改 common-c、公共
  `InputHandler`、共享 telemetry/render/audio、RDP/RustDesk/SSH/VNC 业务源、NAPI、ArkTS、UI、
  云、日志或 product caller。HDC `Connect server failed`，不声明真机 feedback runtime 能力。

N3-07 `02cb13aae`、审查修复 `36b4e13df`/`337c4f35e` 与终止回放证据补强 `ee073afcb` 新增 hidden/private policy、26 个
focused case 和独立私有
archive。它不定义第二套输入端口，直接组合既有 `MoonlightTouchMapper`、`MoonlightPointerMapper`、
`MoonlightKeyboardMapper`、`MoonlightControllerMapper` 与唯一 `MoonlightInputBridge`。固定顺序为
touch cancel→pointer release→keyboard release→controller neutral/disconnect→bridge neutral；覆盖
overlay、control mode、rotation、focus、PIP、background、screen lock、Surface detach、reconnect、
session stop、input generation change 和 controller disconnect。每个阶段保留 exact context 与 pending
suffix，其他请求不得越过；重复请求幂等。`beginFlush()` 在 release 前把唯一 bridge 推进
`ReleasePending`，普通 mapper input 被拒绝，只有 boundary 内的 lifecycle release 可继续。非终止触发
进入 suspend 并只以更高 operation generation resume；reconnect/stop/generation 终止旧输入。
suspend boundary 重试不重放 mapper；terminal 可从 component pending 或 suspended 升级，component
永久失败/owner loss 会丢弃全部 mapper 本地状态并继续 stop，remote stop 失败则 local-terminal。
stale terminal request 不清本地状态；pending→terminal 的 mapper drain context 与 completion replay key
分离，remote/local-terminal 两种 exact stop 重放都返回 `AlreadyApplied` 且零端口副作用。

- host normal 与 strict 均为 **685 total / 669 pass / 16 fail**；26 个 N3-07 用例全 PASS，16 项失败
  仍仅为既有 VNC 本地 TLS fixture `start()`。ASan/UBSan 顺序连续三轮与 TSan 同为 **669/16**，无
  sanitizer/data-race report；七份 focused host clang analyzer 均为零诊断。
- arm64-v8a/x86_64 archive 分别为 369470/361710 bytes 且各含一个 policy object；无 caller 时
  object 未进入 `rdpnapi`，dynamic defined/undefined 仍为 arm64 **16114/705**、x86_64
  **15645/703**，产品库无 flush-policy 符号。
- 双 Hvigor 与 signed `assembleHap` BUILD SUCCESSFUL，HAP 333 paths；Light、117-file vendor、TOTP
  与 `git diff --check` PASS。未修改 common-c、公共 `InputHandler`、共享 telemetry/render/audio、
  RDP/RustDesk/SSH/VNC 业务源、NAPI、ArkTS、UI、云、日志或 product caller。HDC 返回
  `Connect server failed`，不声明 HAP/虚拟机/真机输入 runtime。
- 复用既有 `gpt-5.6-sol low` task `019fe966-d99a-7ce1-8b53-4ef725597053` 完成最终只读复核；
  `ee073afcb` 后 P0/P1/P2/P3 均为 0。复核确认两条 terminal replay 测试固定旧 suspend
  sequence/timestamp 与 event/flush 零增量，私有 archive 无 caller，不影响旧协议功能或性能。

## 12.16 N3-08 dormant physical/virtual controller aggregator checkpoint（2026-08-11）

- `fef723770` 新增 hidden fixed-capacity `MoonlightControllerAggregator`、归一化虚拟布局 value objects
  与确定性 validator。validator 校验 version/enum/unique id/finite value/最小热区/safe area/冲突区/
  互斥 dpad/容量，合法数据确定性 clamp，损坏布局整体回退固定安全布局；编辑态不产生远端输入。
- `ingestPhysical()` 是后续 HarmonyOS GameController listener 的纯 native 完整状态入口；它把物理来源
  固定映射为 `GameController`，虚拟语义固定映射为 `VirtualController`，两者都只调用既有 N3-05
  mapper，继而走 N3-01 bridge 与 official common-c。没有第二 encoder、owner、port、slot、queue 或线程。
- physical↔virtual 双向换源关闭新输入，先由 N3-07 接受 controller disconnect/active-mask=0，再确认
  mapper 的 active/device/source/source-generation 已清空，随后用更高 operation/source generation
  resume/connect。removal 或 target connect 的永久失败升级 SessionStop，目标来源同一会话不得接管。
- reviewer 首轮发现 boundary retry、8-lane generation exhaustion、unknown phase 与 inactive-hat NaN；
  `6787cc3fb` 增加独立 retry/resume generation、HandoffBoundaryPending/HandoffResuming、retired-lane
  tombstone 原位复用及 exhaustive fail-closed，并覆盖 boundary/resume/arrival/20 次换源旧回放。
- host normal/strict、ASan/UBSan 连续三轮与 TSan 均为 **714 total / 698 pass / 16 fail**；16 项失败
  仍只来自既有 VNC 本地 TLS fixture `start()`，28 个 aggregator 和 17 个 mapper tests 全 PASS，
  sanitizer/race report 为零，四份 analyzer 零诊断。
- arm64-v8a/x86_64 aggregator archives 各含一个 object（463352/454608 bytes）；无 caller 时 object 未进入
  `rdpnapi`，产品库无 aggregator 动态符号，defined/undefined 仍为 arm64 **16114/705**、x86_64
  **15645/703**。两项 Hvigor、signed HAP 与 diff check PASS。
- Light 合规门（含 unchanged vendor/TOTP 检查）PASS；未修改 common-c、公共 `InputHandler`、共享 telemetry/render/audio、RDP/RustDesk/SSH/VNC 业务源、
  NAPI、ArkTS、UI 或云。真实 HarmonyOS GameController listener 与 `MoonlightControllerOverlay` 的窄
  typed NAPI ingress 明确保留到 S1-05A；当前不能声明实体手柄或 Moonlight 产品串流 runtime 可用。
- 复用 reviewer task `019fe966-d99a-7ce1-8b53-4ef725597053` 完成修复复核，P0/P1/P2/P3 全 0；
  receipt `moonlight-n3-08-gpt5-6787cc3fb-2026-08-11`，未创建新 reviewer。

## 12.17 U1-01～U1-03 RustDesk 风格灰色入口 checkpoint（2026-08-11）

- `c38ff6265` 只在现有 `HostProtocolPicker.protocolOption()` 内为 Moonlight 增加官方品牌资源分支；
  RustDesk 与 Moonlight 的卡片高度、圆角、标题/副标题、间距、未来 enabled route 和单 Sheet owner
  合同保持一致。`moonlightProtocolAvailable` 默认 false，禁用态固定 0.58 opacity、唯一“即将支持”，
  点击由纯 `HostProtocolPickerPolicy` 返回空 route。
- Moonlight Qt revision `2e13ed9977bc31c73caf8428f08f58d793313ece` 的官方 SVG 原始 SHA-256
  `6fd0ee4fe5b4aad5abaa5d5c9acb9f7d1bda0abadfe9d1582115de9b4ba16aa2`；本地只做确定性
  `currentColor` 单色转换，SHA-256 `4f5ef547e33767287e3438a6d1598a1bdef6e49df4678a5f7f214ec58c9e5886`。
  加载失败回退 `gamecontroller_fill`，NOTICE/SPDX/provenance/source offer/artifact hash 同步。
- 新增 3 个 pure policy tests 并注册，Moonlight focused 总数变为 154 tests / 21 describe；两项 Hvigor、
  signed HAP、Light、117-file vendor、SBOM JSON、资源 hash 和 diff check 均通过。
- signed HAP 已通过沙箱外 HDC 安装/启动。协议选择页实际显示禁用色官方 Moonlight 图标；点击卡片后
  UI tree 仍包含“添加远程主机”“Moonlight”和唯一“即将支持”，没有进入任何添加路由。
- 精确隔离检查确认 `RustDeskAddFlow.ets`、`HostListPage.ets`、CloudStore、CloudSyncPolicy、native 和
  其他协议业务源码未改；在线云表仍为原 8 表。禁用入口不读写本地数据、不调用 native/network、
  不创建线程/定时器/后台任务，不改变其他组件功能或性能。
- reviewer 首轮发现 REUSE 许可覆盖冲突、Light 对图标 SBOM/NOTICE/source offer 约束不足、计划中三处
  混合 UI 来源及 fallback/callback/tint 测试缺口；`71e9902c9` 增加 exact-path GPL override 和上游
  copyright、精确合规门禁，统一 RustDesk/protocol-neutral UI 来源，并让禁用 dispatch、fallback mode
  与 tint policy 进入实际组件路径和定向断言。两项 Hvigor、signed HAP、Light 与 diff 已重跑通过。
- reviewer 二轮继续发现根 `GPL-3.0-only` 正文、SPDX `packageVerificationCode` 和实际 fallback resource
  锁定缺口；`7eaad950b` 补入与 pinned 上游字节一致的 GPLv3 正文及 exact-hash 门禁，为单文件图标
  package 增加可复现 verification code，并让 `protocolIcon()`、descriptor、组件和测试共同消费唯一
  `moonlightSystemFallbackIcon()`。两项 Hvigor、signed HAP、Light 与 diff 再次通过。
- 同一 reviewer task `019fe966-d99a-7ce1-8b53-4ef725597053` 最终复核 PASS，P0/P1/P2/P3 全 0；
  独立重算 GPL/SVG/SPDX hash 与 verification code，复跑 Light/diff，并确认累计增量未触及 native、云、
  RustDesk 添加流或其他协议页面。receipt `moonlight-u1-01-03-gpt5-7eaad950b-2026-08-11`。
- U1-04 只能新建 Moonlight 本地四步添加流，并直接沿用 RustDesk 的 header、模式卡、字段、错误、
  主按钮、返回/关闭和单 Sheet 生命周期；不得复制 RustDesk 业务状态，也不得以其他协议页抽 scaffold。

## 12.18 U1-04 RustDesk 风格四步本地添加合同 checkpoint（2026-08-11）

- `dd6ec9c5` 新增 `MoonlightHostAddFlow.ets` 与 `MoonlightHostAddFlowPolicy.ets`。四步固定为
  查找主机→验证主机→配对与信任→完成；20vp 留白、36vp 返回、20/12vp 标题层级、模式卡、
  44vp 字段/主按钮、错误提示和单 Sheet 生命周期直接沿用 RustDesk 现有语法。
- 自动发现结果必须同时匹配 owner token 与独立 discovery generation；离开、切手动、验证和重扫
  均先 pause/cancel。验证、配对、信任、目录和保存继续使用 operation generation，迟到回调不提交。
- PIN 仅接受 4 位数字并使用绝对 deadline；异常、返回、取消、过期和消失统一停止 timer、取消 owner、
  增长 generation、清 PIN/expiry。await pairing 返回后在提交前再次检查 deadline。
- 证书指纹必须是 64 位 SHA-256；certificate changed 在 step 2 阻断，防御性 pairing completion 也
  保留 changed。信任持久化失败与用户显式拒绝是两个 transition；拒绝会清 paired/temporary identity，
  不能绕过重新配对。duplicate UUID 只允许打开已有主机，不创建重复记录。
- 完成页只在 port 返回 `localCommitted=true` 后设置本地保存成功并触发 `onSaved`；默认 discovery、
  verify、pairing、trust、catalog、save ports 全部 fail closed，未接真实 Host Control 或 repository。
- `HostListPage` 只增加 thin dormant route 和 owner token，并显式传
  `moonlightProtocolAvailable: false`。因此当前产品不会挂载该组件，不访问 network/native/repository，
  不启动 timer/thread/background work；在线云表仍为 8 表，Moonlight 云路径继续 parked。
- 10 个新 policy cases 使 Moonlight 聚合达到 161 tests / 21 describe，覆盖地址、dirty、duplicate、
  四步 local truth、迟到 operation、PIN expiry、changed certificate、有效指纹、discovery fence、
  trust failure/reject 和绝对 deadline。两项 Hvigor、signed HAP、Light、117-file vendor 与 diff PASS。
- 最终 signed HAP SHA-256 为
  `847874f51e54a4bac23c779fcb1c544cda7a6b7d17a6f473ba8c4da9c9937d97`；沙箱外 HDC 安装/启动成功。
  点击灰态 Moonlight 后 UI tree 仍只有“添加远程主机”“Moonlight”“即将支持”，无添加流程路由。
- 复用 reviewer task `019fe966-d99a-7ce1-8b53-4ef725597053`。首轮问题全部修复后最终
  P0/P1/P2/P3 为 0；未创建新 reviewer。该 U1-04 checkpoint 当时以 U1-05 为下一 UI 合同；
  U1-05 现已完成且仍未开放 picker。

## 12.19 U1-05 RustDesk 单 Sheet 保存后交接合同 checkpoint（2026-08-11）

- `46a2e7d3` 新增 protocol-neutral `HostAddPostSaveHandoff`，只携带 destination、稳定本地主机 ID、
  owner token 和 generation；不携带 host snapshot、route object、callback、secret 或协议状态。
  `HostListPage` 只在共享 Add Sheet 的原生 `onDisappear` 后消费，未新增 fixed delay、第二 Sheet、
  Navigation route、timer、network、native、repository 或 cloud 调用。
- `MoonlightLocalSaveResult` 必须同时报告 repository `localCommitted` 和稳定 `hostId`。正常
  “保存并打开”只有两者均满足才创建 `moonlight_catalog` handoff；目标页未来必须按 ID 从本地
  repository/cache 重读，不能使用 Sheet 回调中的对象副本。
- `a73b8959` 在 repository port 前增加 `activeOperation/savedLocally` 门禁，极快双击只能产生一次
  本地写入。`094a8b3b` 进一步分离“已经持久提交”和“允许目录交接”：若
  `localCommitted=true + blank hostId`，状态仍为 terminal committed、保留诊断、禁止再次保存；
  HostList 只在 page active、Sheet 未 closing、owner exact 时安全关闭，不创建目录 handoff。
- 共享 handoff policy 当前 8 cases，覆盖 rapid tap、native Sheet animation、page close、stale owner、
  late generation、invalid payload 和 committed-without-ID 安全关闭；Moonlight 聚合为 162 tests /
  21 describe，全部 compile-registered，仍不声明设备 Hypium 执行。
- 最终代码 `094a8b3b` 后两项 Hvigor、Light、117-file vendor 与 `git diff --check` PASS；signed HAP
  当前证书重签 SHA-256 为 `89ab30e1327e9f902e2370cfa9308fc5a29f9d559e7aaedf2168becb5e3883af`。
  沙箱外 HDC 在 `127.0.0.1:5555` 安装/启动成功；最终 UI tree 中 RustDesk、Moonlight 和
  “即将支持”各 1，Moonlight 父行 opacity 0.58，点击后无“添加 Moonlight 主机”或 `1/4`。
- 复用 reviewer task `019fe966-d99a-7ce1-8b53-4ef725597053`；首轮唯一 P2 为 committed-without-ID
  可重写风险，`094a8b3b` 修复后最终 P0/P1/P2/P3 全 0。复核确认 UI 继续只以 RustDesk 为基线，
  未修改 RustDeskAddFlow、其他协议业务、native、NAPI 或 cloud，也无现有组件功能/性能回归。
- U1-05 当时的“实际目录页仍不存在”限制已由 `2c37b0edf` 解除为 UI shell：U1-06～U1-12
  的本地页面、设置 leaf、启动/连接/串流浮层均已创建并注册；它们仍不代表真实 Host Control、
  Sunshine、首帧、实体手柄或云同步能力已开放。

## 12.20 U1-06～U1-12 本地 UI shell closeout（2026-08-11）

- `2c37b0edf` 将 U1-06～U1-12 的 UI contract 落到当前源码：新增本地-only 主机详情、按主机分类的应用目录、设置页和串流页；新增 launch sheet、连接阶段、session toolbar、control center、实体/虚拟控制器浮层与 diagnostics HUD。所有页面均保持 capability/runtime fail closed，不把占位数据伪装成在线主机、可启动应用或已连接串流。
- 首页是主机管理的唯一入口：共享 RustDesk add Sheet 的保存后原生 `onDisappear` handoff 只交接稳定 ID，随后由 `MoonlightAppCatalogPage`/`MoonlightHostDetailPage` 重新读取本地 `CloudStore` records/cache。设置页不再出现单独“主机管理”入口；Moonlight 只保留快速、画面、音频、输入、网络安全、后台、诊断、云范围、Trust 九个 section。
- 公共 display/PIP 选项不在 Moonlight 重复，公共设置仍由现有 host/session surface 拥有。`SettingsSheetRoutePolicy` 只负责 Moonlight 24–32 leaf route；每个 route 都进入同一 bindSheet 生命周期，不允许任意跨入口跳转。
- PC 采用独立的 RustDesk 风格 sidebar Moonlight 槽位，FAB 仍显式传 `moonlightProtocolAvailable=false`；灰色、0.58 parent opacity、唯一“即将支持”、点击无 route 均保持。该槽位不创建 timer、network、native、repository、cloud 或后台任务。
- Fresh evidence 仅使用本次重新安装后的文件：PC full `/private/tmp/moonlight-final-20260811-pc-full.jpeg`/`.json`；phone settings `/private/tmp/moonlight-final-20260811-phone-settings.jpeg`/`.json`。PC 主 RDP 页面保持原样且 Moonlight 为灰色独立栏位；phone 显示 `串流画面、音频、控制与本地安全设置` 且 UI tree 无“主机管理”。不引用任何旧截图。
- 当前 exact `default@OhosTestCompileArkTS` 与 `assembleHap` 均 BUILD SUCCESSFUL，signed HAP 已经由沙箱外 HDC 安装/启动到 `127.0.0.1:5555` 与 `127.0.0.1:5557`。162 Moonlight tests/21 describe 与 8 shared handoff cases 为 compile-registered；`ohosTest` 仍因 `00306054` 未注册而不能宣称设备 PASS。
- 增量隔离审查只覆盖 `094a8b3b..2c37b0edf` 的 Moonlight UI/HostList 路径；不包含用户未提交的 `CloudStore.ets`。RustDesk、RDP、SSH/SFTP、VNC 业务源、native、`CloudSyncPolicy` 和线上 8 表注册均未被 Moonlight checkpoint 改动。

## 12.21 U1 UI review-fix closeout（2026-08-11）

- `6b0c1aa8` 收口了 U1 UI 增量复核发现：`MoonlightRecordPolicy` 将旧记录可读字段与新写入 allowlist 分离，旧数据先读后 normalize；`MoonlightRecordPolicy.test.ets` 增加 baseline replay/normalization 回归。
- `MoonlightSettingsPage` 的两个证书变化开关按安全合同固定为开启且不可操作，并说明变化时必须重新核对与配对；保存流程以 `localCommitted` 作为本地提交终态，即使回读确认暂失败也清理 dirty，避免重复写入。`MoonlightSettingsLocalService.test.ets` 覆盖 `readback_failed + localCommitted`。
- `MoonlightStreamPage` 负责 bindSheet reopen timer 的 page-active、generation、取消和离开清理，避免离页后旧 timer 重开浮窗；PC sidebar 改为使用 `MoonlightBrandIcon` 的官方几何可着色资源/回退图标，仍保持 0.58 灰态、唯一“即将支持”、点击无 route。
- 复用 reviewer task `019fe966-d99a-7ce1-8b53-4ef725597053` 对 `2c37b0edf..6b0c1aa8` 复核，P0/P1/P2/P3 全部为 0；增量隔离确认 RDP、RustDesk、SSH/SFTP、VNC、公共输入、native/CMake/NAPI、`CloudSyncPolicy` 与现有云表注册未变更。用户 `CloudStore.ets` 仍排除且未暂存。
- 最新 fresh r2 证据只使用本次最新 HAP 重装后生成的文件：PC `/private/tmp/moonlight-final-20260811-r2-pc-full.jpeg`；phone `/private/tmp/moonlight-final-20260811-r2-phone-settings.jpeg`、`...-scroll.jpeg`；accordion `/private/tmp/moonlight-final-20260811-r2-moonlight-accordion.jpeg`、`...-lower.jpeg`；quick sheet `/private/tmp/moonlight-final-20260811-r2-quick-sheet.jpeg`；network sheet `/private/tmp/moonlight-final-20260811-r2-network-sheet.jpeg`，每项均有对应 `.json` UI tree。r2 证明 PC RDP 主页未受影响、Moonlight 独立灰栏位存在、手机九段设置统一排版、无重复“主机管理”、网络安全开关为不可操作的安全状态。
- `default@OhosTestCompileArkTS`、`assembleHap` 均按项目强制命令重新 BUILD SUCCESSFUL；最终签名 HAP SHA-256 为 `7a723ce9b300d6b8e131006472ed2efa8d7985a8cd672385857e468a84181b87`；沙箱外 HDC 已在 `127.0.0.1:5555` 与 `127.0.0.1:5557` 安装并启动。`ohosTest` 仍因 `00306054` 未注册而不宣称设备 PASS。

## 12.22 S1-01/S1-02 dormant session coordinator checkpoint（2026-08-12）

- `8b1ccd22` 在既有状态模型中加入 `RemoteProtocol.moonlight` 和 capability policy。Moonlight 的 clipboard/file/multi-display 能力明确保持 unavailable；streaming 只有在 runtime、Host Control 和 transport 三项事实同时为 true 时才可能打开，当前 product runtime port 为 `null`，所以仍 fail closed。
- `ActiveRemoteSessionRegistry` 继续是唯一 active-session owner。Moonlight marker 只在 native launch 已被接受后登记，地址字段固定为空；transient `hostAddress` 只随 start request 传给未来 runtime port，不能写入 AppStorage/registry。清理使用 ownerScopeId、accountGeneration、sessionId、protocol 的 exact match，避免迟到回调清掉其他协议会话。
- `MoonlightSessionCoordinator` 是无 socket/native/media/cloud 的纯 ArkTS dormant seam：校验 scope 与请求、拒绝 runtime 缺失、拒绝重复/跨协议活动会话、generation/sequence fence、要求 nativeSessionId 和 Surface ID、按 first-frame 后才允许 streamStable，并统一 stop/cancel/transport-loss/owner-account invalidation 清理。
- `MoonlightAppCatalogPage` 只负责把当前本地主机的首选地址格式化为一次性参数；`MoonlightStreamPage` 绑定当前 AccountSessionCoordinator scope，账户切换时使旧回调失效，离开页面时取消 route-owned session 并退订监听。未修改 CloudStore、cloud table、common-c/native/NAPI/GameController/OHAudio 或既有协议业务路径。
- 新增 6 个 `MoonlightSessionCoordinator` focused cases、1 个 capability case，并注册到 `List.test.ets`；该 suite 仍为 compile-registered，`ohosTest` 因 `00306054` 未注册而不宣称设备执行 PASS。
- `default@OhosTestCompileArkTS` 与 `assembleHap` 均在 `8b1ccd22` 后按强制命令退出 0；signed HAP SHA-256 为 `2dfcac96bb2b3873b4a8e31623f1bf37e67197b394857b0dac91bf97eb6f7258`。沙箱外 HDC 已将该 HAP 安装并启动于 PC `127.0.0.1:5555` 与手机 `127.0.0.1:5557`。
- 本 checkpoint 只使用 2026-08-12 新截图证据：`/private/tmp/moonlight-final-20260812-s1-final-pc-root.jpeg`、`/private/tmp/moonlight-final-20260812-s1-final-pc-picker.jpeg`、`/private/tmp/moonlight-final-20260812-s1-final-pc-picker-click.jpeg` 及对应 JSON。PC 上 RDP 仍为活动页；Moonlight 是独立灰色协议项，显示官方几何可着色图标与“即将支持”；点击后仍停留在 `pages/HostListPage`。
- `4548499c` 修复了 review 指出的三项 P1：reserve/promote 原子跨协议仲裁、prelaunch cancel 与 stop failure/timeout 的本地终止清理、native session ID callback fence；新增 3 个 focused cases，合计 9 个 coordinator cases。
- `647113a5` 增加实际 5 秒 stop watchdog，并修正 prelaunch cancel 测试为“stopped 或 watchdog terminal 后清除 reservation”；复用 reviewer task 对完整 `6b0c1aa8..647113a5` 范围最终 PASS，无 actionable findings。
- 本 checkpoint 最终只使用 2026-08-12 最新 HAP 重装后重新抓取并查看的 `final3` 证据：PC 根页 `/private/tmp/moonlight-final-20260812-s1-final3-pc-root.jpeg`；手机根页、协议选择器及禁用点击 `/private/tmp/moonlight-final-20260812-s1-final3-phone-root.jpeg`、`/private/tmp/moonlight-final-20260812-s1-final3-phone-picker.jpeg`、`/private/tmp/moonlight-final-20260812-s1-final3-phone-picker-click.jpeg`；设置/展开/bindSheet `/private/tmp/moonlight-final-20260812-s1-final3-phone-settings.jpeg`、`/private/tmp/moonlight-final-20260812-s1-final3-phone-settings-lower.jpeg`、`/private/tmp/moonlight-final-20260812-s1-final3-phone-moonlight-accordion2.jpeg`、`/private/tmp/moonlight-final-20260812-s1-final3-phone-quick-sheet2.jpeg`。PC RDP 仍为活动页；Moonlight 是独立灰色协议项，显示官方几何可着色图标与“即将支持”；点击后仍停留在 `pages/HostListPage`；无旧截图进入当前验收结论。
- 最终部署签名 HAP SHA-256 为 `95d9cc17067981b7e5c4bdae3ec7fe3d0de14060a0dc75e87b638dca328fe504`。
- PC 大屏 final4 新图 `/private/tmp/moonlight-final-20260812-s1-final4-pc-maximized2.jpeg` 已确认独立灰色 Moonlight 侧栏栏位；`/private/tmp/moonlight-final-20260812-s1-final4-pc-picker2.jpeg` 与 `/private/tmp/moonlight-final-20260812-s1-final4-pc-picker-click.jpeg` 已确认大屏添加 FAB、灰色“即将支持”和禁用点击无路由副作用。手机 final4 新图为 `/private/tmp/moonlight-final-20260812-s1-final4-phone-root.jpeg`、`/private/tmp/moonlight-final-20260812-s1-final4-phone-picker2.jpeg`、`/private/tmp/moonlight-final-20260812-s1-final4-phone-picker-click.jpeg`、`/private/tmp/moonlight-final-20260812-s1-final4-phone-settings-top.jpeg`、`/private/tmp/moonlight-final-20260812-s1-final4-phone-settings-lower2.jpeg`、`/private/tmp/moonlight-final-20260812-s1-final4-phone-moonlight-accordion2.jpeg`、`/private/tmp/moonlight-final-20260812-s1-final4-phone-quick-sheet3.jpeg`；全部为本轮重新抓取并查看，不使用旧截图。
- 代码增量复核复用 reviewer task `019fe966-d99a-7ce1-8b53-4ef725597053`，最终范围为 `6b0c1aa8..647113a5`，PASS 且无 actionable findings。唯一下一实现边界改为 S1-03；N2-09、S1-05A 和真实媒体/手柄/长稳验收继续 external pending。

## 12.23 S1-03 connection-stage snapshot contract checkpoint（2026-08-12）

- 代码 checkpoint `75d769c2` 只修改 5 个 Moonlight 页面/服务/测试文件：
  `MoonlightSessionCoordinator.ets` 增加 ownerScope/accountGeneration/hostId/appId 精确过滤的
  `subscribeForRoute()`，立即回放当前 route 快照，并在 start、runtime event、cancel/stop、invalidate/
  terminal cleanup 后发布；监听器异常被隔离，reset 和退订都清空引用。没有建立第二个 session owner、线程、
  timer、transport、media、input、native、NAPI 或云调用。
- `MoonlightStreamPage.ets` 现在只消费 coordinator snapshot：phase、errorCode、degradationReasons、
  elapsedMs、firstFrameSeen 均来自实际状态；页面出现/账号切换重新绑定，消失时 cancel route-owned session、
  清理 elapsed timer、退订监听。connect stage 仅在首帧前显示，streaming/failed/disconnected 均按真实终态
  收束，取消动作走 coordinator stop/cancel，重试继续明确 fail closed。
- `MoonlightUiPolicy.ets` 修正 disconnected 的标题和详情，避免已结束连接再次显示“等待首帧”；新增 coordinator
  scoped-delivery case，UI policy 追加 disconnected presentation 断言。文档约定的 focused aggregate 为
  163 tests / 21 describe，加 8 个 shared host-add handoff cases；均只 compile-registered。
- 强制 `default@OhosTestCompileArkTS` 与 `assembleHap` 均 BUILD SUCCESSFUL；最终签名 HAP SHA-256 为
  `a89fc076f3edc9ca502d94fd53b0fdbb4b61c14c14bf242a250225f76917e077`。最终 HAP 已由沙箱外 HDC 重装并启动在
  PC `127.0.0.1:5555` 与手机 `127.0.0.1:5557`；只使用本次新抓取并查看的证据：
  `/private/tmp/moonlight-s103-final-20260812-pc-root.jpeg`、`...-pc-max.jpeg`、`...-pc-picker.jpeg`、
  `...-pc-picker-click.jpeg`、`...-phone-root.jpeg`、`...-phone-picker.jpeg`。PC 侧栏和两端添加弹层仍为
  灰色官方可着色图标/“即将支持”，点击禁用项无导航副作用；RDP 页面保持原样。
- `ohosTest@OhosTestCompileArkTS` 仍因 `00306054` 未注册而不能执行 Hypium；不把模拟器 UI 验收写成真实
  Sunshine、媒体首帧、OHAudio/Surface、实体手柄或发布能力。`git diff --check`、状态校验和静态隔离通过。
  复用 reviewer task `019fe966-d99a-7ce1-8b53-4ef725597053` 对本次 5 文件范围复核，P0/P1/P2/P3 全 0；
  CloudStore 与 RDP/RustDesk/SSH/SFTP/VNC、公共输入、native/CMake/NAPI、CloudSyncPolicy 和既有云表均未改。

## 12.24 S1-04 responsive session toolbar/control-center checkpoint（2026-08-12）

- 代码 checkpoint 为 `665df714`，建立在 `fae7c36dd` 与 `f7f39c0f` 之上。允许修改范围只有
  `MoonlightUiPolicy.ets`、`MoonlightSessionToolbar.ets`、`MoonlightStreamPage.ets` 和
  `MoonlightUiPolicy.test.ets`；用户 `CloudStore.ets` 未暂存、未修改，其他协议业务、公共输入、native/
  CMake/NAPI、GameController/OHAudio/Surface、CloudSyncPolicy 与既有云表注册均未触及。
- 工具栏按 RustDesk 视觉语法完成 phone/pad edge rail、desktop md/lg 5/7 项和 desktop xl 顶部布局。edge
  rail 使用 `Scroll` + 360vp `maxHeight`；non-xl 使用显式收起；只有 xl 使用 pin + 5 秒 auto-hide。
  `menuOpen` 与 breakpoint 通过 `@Watch` 清理/重建计时器，排队回调重新读取最新 policy，避免 Sheet 或断点
  变化后的旧 timer 折叠新布局。control center 已按断点响应式计算尺寸，所有动作仍 capability fail closed。
- 新增 responsive/边界与 Sheet-open、close、xl→lg policy cases；文档 focused aggregate 更新为 165 个
  Moonlight tests / 21 describe，加 8 个 shared handoff cases，均 compile-registered。纯 ArkUI timer 无法在
  policy unit test 中直接实例化，复核将其记录为不阻塞 P3。
- 强制 `default@OhosTestCompileArkTS` 与 `assembleHap` 均 `BUILD SUCCESSFUL`；最终当前工作区 signed HAP SHA-256 为
  `cb1086ccaf57ada2e7cc1d879e5df6d75ee1b249c2cfdc58d176f7e9545d1d99`。HAP 已由沙箱外 HDC 安装/启动在 PC
  `127.0.0.1:5555` 与手机 `127.0.0.1:5557`；用户 `CloudStore.ets` 仍是任务外的未暂存变更。
- 本次收尾仅使用最终 HAP 新抓取并查看的 UI 证据：`/private/tmp/moonlight-s104-final-cb1086-20260812-pc-root.jpeg`、
  `...-pc-max2.jpeg`、`...-pc-picker2.jpeg`、`...-pc-picker-click.jpeg`、`...-phone-root.jpeg`、
  `...-phone-picker2.jpeg`、`...-phone-picker-click.jpeg`。PC 独立 Moonlight 侧栏、两端灰态 picker、两端
  禁用点击无导航副作用均通过；不使用旧截图。该证据仅证明模拟器 UI 壳，不证明 Sunshine、首帧、实体手柄或发布能力。
- 复用 reviewer task `019fe966-d99a-7ce1-8b53-4ef725597053` 最终 PASS：P0/P1/P2=0，P3=1（可接受测试可测性
  限制）。下一任务唯一入口改为 S1-05A；Moonlight cloud sync、`moonlightrecordv1`、runtime/media/release truth
  继续 parked/false；`ohosTest` 仍阻塞于未注册任务 `00306054`。

## 12.26 U1-13 本地主机保存与数据管理收口（2026-08-12）

- 代码 checkpoint：`db750cdb`。本 checkpoint 只修改 `MoonlightHostAddFlow.ets`、`HostListPage.ets`、
  `HostAddConnectionHandoffPolicy.ets`、`MoonlightHostAddFlowPolicy.ets`、新增
  `MoonlightLocalHostService.ets` 及其三组定向测试/注册；用户的 `CloudStore.ets` 没有暂存或修改。
- `MoonlightLocalHostService` 只依赖已存在的 `MoonlightRepositoryPort`。保存前校验 step 4、paired、trusted、
  SHA-256 指纹、owner token、account lease、state generation 与 save operation；host/trust 使用 owner-scoped
  稳定 ID，检测同 UUID 重复，并将两行以 `localOnly=1` 写入已有本地表。没有新增云表、CloudSyncPolicy、缓存、
  网络、native、NAPI、媒体、音频、输入、session registry 或后台任务调用。
- 两条本地记录在第一条写入前全部构造完成；每次 upsert 经过仓储 readback。第二条失败、readback 失败或异常时，
  通过更高 `syncVersion` 的前向 tombstone/恢复记录补偿，区分 `not_committed`、`partial`、`uncertain`；tombstone
  可在下一次有效保存中显式以 `resetEpoch + 1` 复活。partial/uncertain 会锁定保存按钮，禁止普通重试和错误的
  catalog handoff。
- Add Sheet 的正常保存与“查看已有主机/保存并打开目录”继续复用 RustDesk 风格的单 Sheet owner；只携带稳定 host ID、
  owner token 和 generation，并且只在原生 `onDisappear` 后路由到详情/目录。没有 fixed delay、第二 Sheet 或
  直接传递 host snapshot。
- U1-13 定向覆盖：8 个本地保存/回滚/租约/重复/复活/readback/partial cases，1 个 partial/uncertain retry policy
  case，1 个 existing-host detail handoff case。它们已注册并通过 `default@OhosTestCompileArkTS` 编译；
  `ohosTest` 仍因 `00306054` 未注册而不能宣称设备 Hypium PASS。
- 本 checkpoint 两项强制 Hvigor 均 `BUILD SUCCESSFUL`。最新 signed HAP：
  `entry/build/default/outputs/default/entry-default-signed.hap`，SHA-256
  `8b54784ac3112b30a5630ef074d35150fd7271099920e54ab97809ef1546263e`。HDC 已在 PC `127.0.0.1:5555` 与手机
  `127.0.0.1:5557` 安装/启动。只查看最新 HAP 证据目录 `/private/tmp/moonlight-final-gate.bIGtZD/`：
  `pc-root.png`、`phone-root.png`、`pc-picker-open.png`、`phone-picker-open.png`、`pc-max.png`、
  `phone-settings-open.png`、`phone-moon-expanded.png` 和 `phone-quick.png`；没有使用旧截图。
- 最新证据确认：PC 大屏侧栏 Moonlight 独立且保持禁用；手机/PC FAB 的 Moonlight 使用灰色可着色图标并显示
  “即将支持”；手机设置页公共“主页与主机列表”仍是主机管理唯一入口，Moonlight 没有重复主机管理项；
  Moonlight 已展开为协议专属设置分组，并实际打开“快速设置”bindSheet，继续使用统一 RustDesk/Theme 排版。
- 复用 reviewer task `019fe966-d99a-7ce1-8b53-4ef725597053` 完成增量复核：PASS，P0/P1/P2=0；唯一 P3 是
  测试端口尚未直接抛异常导致的外层 catch/补偿异常分支覆盖限制，不阻塞当前本地数据收口。审查确认没有 RDP、
  RustDesk、SSH/SFTP、VNC、公共输入、native/CMake/NAPI、CloudSyncPolicy 或既有云表注册改动。

当前 U1-13 数据边界：

~~~text
RustDesk-style add Sheet (step 4, trusted, save)
  -> MoonlightLocalHostService
  -> existing MoonlightRepositoryPort / existing local Moonlight records
  -> host row + trust row, localOnly=1, readback and forward compensation
  -> onDisappear-only stable-ID handoff to existing local detail/catalog shell

No path to moonlightrecordv1, cloud selection/transfer, app cache, network, native/media/input/session runtime.
~~~

U1-13 完成的是“本地主机记录可安全保存”的产品边界，不是 Moonlight 真实联网能力。真实 Sunshine pairing/Host
Control、目录刷新、launch、视频首帧、OHAudio/Surface、实体手柄、媒体、网络/温控/长稳和 release truth 继续关闭。
下一任务唯一入口仍为 S1-05A：GameControllerKit listener → typed NAPI → N3-08/N3-05/N3-01/common-c，不能在
ArkTS 直接编码或发送控制器线协议。

## 13. 下一执行序列

1. N2-09 保持 EXTERNAL PENDING：必须由真实 Sunshine 与用户 ARM64 实机完成 720p/1080p、
   30/60fps、两小时、温控、前后台/PIP/旋转和网络矩阵；不得用 host 单测或虚拟机代替。
2. U1-06～U1-12 的 local-only UI shell 已完成：主机管理归首页、目录/详情读本地 records/cache、设置统一进入
   同一 bindSheet、连接/串流浮层保持 dormant；不接真实 Host Control/runtime/cloud，不把 cache 或请求态伪装成在线/已刷新。
3. S1-01/S1-02/S1-03/S1-04 已完成 dormant registry/coordinator、connection-stage snapshot contract 与 RustDesk
   风格会话 toolbar/control-center contract；下一实现序列为 S1-05A，保持 N2-08 与 N3-01～N3-08 dormant，不把任何结果变成 video
   first-frame、streaming/protocolAvailable、FAB 或 release truth。
4. S1-05A 才接真实 HarmonyOS GameController listener 与虚拟 typed NAPI；S1-08 才按现有
   `NativeSessionHandles`、Surface/PIP/background 生命周期装配媒体。U1/S1 设置、目录和连接浮层
   继续只消费 local Repository/cache、Host Control 和 media prerequisites。
5. Moonlight 云同步（`moonlightrecordv1`、selection/transfer/secret recovery）继续 parked；
   真实 Sunshine、设备/网络/功耗矩阵和用户 ARM64 实机验收仍是外部门禁。

## 12.27 设置/FAB/本地数据最终收口（2026-08-12）

本轮没有新增代码；只对当前 HAP 复验设置、FAB 和本地数据边界。最新手机证据位于
`/private/tmp/moonlight-ui-closeout2.PFyRlJ/`：`root-5557.jpeg`、`settings-toggle-check.jpeg`、
`settings-lower-closeout.jpeg`、`moonlight-quick-sheet-closeout.jpeg` 及对应 UI tree 均来自本轮 HDC，且已实际查看。

- 首页保持主机管理唯一入口；FAB 的 Moonlight 仍是灰色可着色图标、“即将支持”、无导航和无后台动作；PC 大屏独立灰色栏位不变。
- 设置页是公共应用设置进入 Moonlight 协议分组，再进入九个 leaf 的单一 `bindSheet` 路由；没有重复“主机管理”、公共显示或 PIP 设置。
- 九个 leaf 在最新展开截图中全部可见：快速设置、画面、音频、控制与手柄、网络与安全、后台串流、诊断、云同步范围、配对与信任。
- 快速设置 bindSheet 的三档体验预设、接收音频、自动重连和保存状态均已看到；Moonlight 数据保持本地范围。
- 本地主机保存仍只通过已有 `MoonlightRepositoryPort` 写 host/trust，`localOnly=1`，readback/补偿/稳定 ID 合同不变；没有新增云表、
  `moonlightrecordv1`、CloudSyncPolicy、cache、网络、native、NAPI、媒体或公共输入路径。

因此 U1-13 的设置/FAB/本地数据产品壳已收口；S1-05A、S1-08、N2-09、真实设备 Hypium 和发布 truth 仍是后续门禁，不能由本轮
模拟器 UI/HAP 证据替代。

## 12.28 当前签名 HAP/UI 最终验收（2026-08-12）

最终只认当前签名包 `entry/build/default/outputs/default/entry-default-signed.hap`，SHA-256
`8a5209d438b253ccb78df6e29734bb1afdde2eb3da281aea8e3ed30c04862419`。它已安装/启动于 PC `127.0.0.1:5555` 和手机
`127.0.0.1:5557`；最新证据目录为 `/private/tmp/moonlight-current-hap-20260812/`。

- `pc-root.jpeg` / `phone-root.jpeg`：首页主机管理和空状态未受影响。
- `pc-picker.jpeg` / `phone-picker.jpeg`：RustDesk 风格单 Sheet 中 Moonlight 使用官方可着色几何图标、灰态显示“即将支持”，不进入添加路由。
- `moon-expanded.jpeg` / `settings-lower.jpeg`：当前包的 Moonlight 九个 leaf 分两张滚动截图完整可见，包含控制与手柄、云同步范围和配对与信任。
- `quick.jpeg`：当前包真实打开唯一 Moonlight 快速设置 bindSheet，三档预设、接收音频、自动重连和保存状态可见。

本次仍未新增实现代码。设置仍走公共设置 → Moonlight 协议分组 → leaf → 单 bindSheet；数据仍由 `MoonlightLocalHostService`
通过现有本地 `MoonlightRepositoryPort` 写入 `localOnly=1` 的 host/trust；云表、网络、媒体、native/NAPI 和实体手柄链路均未打开。

## 12.29 U1-14 adaptive FAB/add-shell and S1-05A isolation closeout（2026-08-12）

- `HostProtocolPickerPolicy` 现在把 `routeEnabled`、`runtimeAvailable` 和 `shellOnly` 分开。FAB 进入本地添加壳时只打开 route gate；`moonlightProtocolAvailable` 仍为 false，Moonlight 卡显示 `仅添加`、不显示运行 chevron，避免把可审查 UI 壳误报为可串流。
- `MoonlightHostAddFlow` 的候选发现区使用 bounded `Scroll`，动作区在 Scroll 外保持可见；两组完成按钮使用显式间距。`HostListPage` 在 phone/pad/desktop 全部使用 `FIT_CONTENT`，PC 不再出现强制大 Sheet 的空白尾部。
- `MoonlightGameControllerListener` 仅在 native focused test target 保留，产品 `MOONLIGHT_SOURCES`、`rdpnapi`、共享 NAPI、d.ts、common-c product input port 和产品 GameControllerKit link 均不包含它；失败注册 drain callback leases，dispatch mutex 串行 sink 事件，reconnect 仍换 generation。
- 当前签名 HAP 为 `dfb5ec2c4dd9e67630c805fcce34b6d3eb9871765fccc910a77d86d6cbb1f16d`，精确双 Hvigor 门禁通过；新 PC/手机证据仅认 `/private/tmp/moonlight-fab-final2-20260812/`，picker tree 均有 `仅添加`。
- native `rdp_native_tests` 编译成功，结果 `701 passed, 16 failed, 717 total`；16 项既有本地 TLS fixture 启动失败，Moonlight listener/controller 测试通过。`CloudStore.ets` 继续是用户-owned unstaged，云同步不在本 checkpoint。
- 本 checkpoint 只改变 Moonlight UI gate/隔离 foundation，不改变其他协议业务、公共输入 owner、云表、云同步或 release truth；下一唯一实现边界为 S1-05A 的 session-owned controller sink 绑定。

## 12.30 最终提交前收口验证（2026-08-12）

- 修正 listener 回调所有权收口：process-global callback registry 以 `shared_ptr` 持有当前 `Impl`，注册失败/注销路径清理 owner；sink 回调只维护 callback depth，deferred stop 由最外层 callback lease 在回调完全返回后执行，避免 sink 同步调用 `stop()` 自等待。
- 当前产品 HAP 精确双 Hvigor 门禁均 `BUILD SUCCESSFUL`，最终签名包 SHA-256 为
  `dfa10941f60946e30a7f288688da655c53c5f50b98a13bdcbc563b555267377d`；该 listener 变更不进入产品 `rdpnapi`，不改变 HAP 的 Moonlight runtime gate。最终包已重新安装/启动于 PC `5555` 与手机 `5557`，新首页证据为 `/private/tmp/moonlight-final-committed-ui.JX0JXs/`。
- host focused `rdp_native_tests` 从本次工作树重新配置、编译并运行：`701 passed, 16 failed, 717 total`；16 个失败仍是既有本地 TLS fixture 启动失败，Moonlight listener/controller 用例全部通过。OHOS API 23 arm64 listener translation unit syntax check 通过。
- `CloudStore.ets` 仍保持用户-owned unstaged；不接入 Moonlight 云同步。RDP、RustDesk、SSH/SFTP 的业务源、公共输入 owner、产品 NAPI/CMake link graph 未改变。

## 12.25 当前收尾复核（2026-08-12）

- 当前代码 checkpoint 仍为 `665df714`，文档收尾提交为 `b1ac85dcc`；当前工作树唯一未提交文件是用户-owned
  `entry/src/main/ets/services/CloudStore.ets`，未读取其业务意图、未暂存、未修改。
- 最新当前 HAP 为 `entry/build/default/outputs/default/entry-default-signed.hap`，SHA-256 为
  `cb1086ccaf57ada2e7cc1d879e5df6d75ee1b249c2cfdc58d176f7e9545d1d99`。本次 UI 验收只使用并查看新抓取的
  `/private/tmp/moonlight-current-pc-20260812-01.png`、`moonlight-current-phone-20260812-01.png`、
  `moonlight-current-pc-20260812-02.png`、`moonlight-current-phone-20260812-02.png` 和
  `/private/tmp/moonlight-settings-phone-real-20260812-06.png`。
- 首页承担主机管理；公共“主页与主机列表”仍是应用级设置，不是 Moonlight 重复入口。Moonlight 协议设置
  展开内容只有九个 protocol leaves，含“控制与手柄”，没有主机管理 leaf。PC/手机 picker 的 Moonlight
  仍灰态并显示“即将支持”，点击不导航；`moonlightProtocolAvailable=false` 保持不变。
- common-c 的官方 controller arrival/state API、N3-05 mapper 与 N3-08 aggregator 已有静态/合同证据；但
  `ProductDriverPort` 尚无 controller input port，HarmonyOS GameControllerKit listener 与 typed NAPI caller
  尚未实现，因此实体手柄信号链路仍是 S1-05A，不得写成已支持。
- 本次文档收尾的隔离结论：没有新增或修改 RDP/RustDesk/SSH/SFTP 业务路径、公共输入 owner、既有 native
  runtime caller、云表注册或 CloudStore；现有 reviewer receipt 继续覆盖 S1-04 代码范围并为 PASS。

## 12.31 S1-05A / N2-09 本地串流可行性产品接线（2026-08-13）

本节取代 12.25、12.29、12.30 中“仅添加、产品无 listener/common-c input caller、FAB
禁用”的旧当前态描述；旧节只保留历史 checkpoint 证据。

### 已落地产品链路

1. `HostListPage` 的 FAB、手机目录和 PC 独立 Moonlight tab 均进入 RustDesk 风格的本地添加/主机
   管理流程；主页绘制保持 capability=false 且不查询 native。只有用户明确点击 FAB 打开 modern picker 后才
   探测真实 capability，因此其他协议用户不会因首页渲染初始化 Moonlight identity/Asset/transport。
2. LAN discovery/verify、PIN pairing、本地 host/trust 保存、应用目录在线刷新与 local app cache、launch
   和 Catalog→Stream handoff 已使用同一 owner token、operation generation、exact account lease、installation
   ID 与 store instance fence。账号变化、离页、导航失败、reservation 失败都会取消 owner 并拒绝迟到回调。
3. 串流使用 pinned official common-c；当前产品 offer 保守限定 H.264、8-bit YUV420、stereo Opus、低延迟，
   bitrate 已接 launch。Surface/HarmonyOS H.264 decoder、Opus/OHAudio、video/audio live readiness、首帧和
   terminal receipt 均进入 typed NAPI/ArkTS state，不再以 transport setup 伪装媒体就绪。
4. keyboard、pointer、touch、virtual controller 与 HarmonyOS physical controller 共用一个 session-owned
   `MoonlightProductInputRuntime`。终态输入释放由 common-c terminal worker 执行；backpressure 保留一个 exact
   pending operation；virtual/physical handoff 必须 remove-first；end/cancel 发送失败时 ArkTS 尝试 native neutral，
   neutral 也失败则冻结整个输入而不隐藏控制器。
5. GameControllerKit 只在 Moonlight 会话激活实体手柄时 `dlopen`/`dlsym`。库/符号不可用只使实体 listener
   启动失败，虚拟控制器及其他输入仍可用；两个产品 ABI 的 `librdpnapi.so` 均无
   `libohgame_controller.z.so` `DT_NEEDED`，也无 unresolved `OH_Game*`/`GameController` symbol。
6. 本地主机支持稳定 ID 重命名和删除；删除覆盖 host-owned local records 与 app cache，部分失败前向回滚；
   删除确认捕获并复核 page、host、owner、account generation、store identity/instance。没有 Moonlight 云注册、
   云 selection/transfer 或 secret recovery。

### 2026-08-13 当前门禁

- exact `default@OhosTestCompileArkTS`: PASS。
- exact `assembleHap`: PASS；signed HAP SHA-256
  `3ec6e5abb4c685d83097ce49793c408301679d8aed19f8376f611456b8a26d85`。
- DevEco `arm64-v8a` / `x86_64` `rdpnapi`: PASS；双 ABI ELF GameControllerKit 隔离：PASS。
- host native suite：711/727 PASS，Moonlight media/input/controller 用例全部 PASS；16 个无关的既有 local TLS
  fixture `start()` 失败未被本增量改变。
- HDC 沙箱外已把该精确 signed HAP 安装并启动到手机 `127.0.0.1:5555` 和 PC `127.0.0.1:5557`。本轮只验收
  当前包的新截图：手机 FAB 的 Moonlight 已启用并使用官方几何可着色图标，添加页会启动真实 LAN discovery；
  PC 有独立自适应 Moonlight 分类，六个可见专属设置 bindSheet 已在手机/PC 检查。当前网络没有 Sunshine，发现
  结果为 0；两个模拟器的安全身份证明不可用，故 `hostControlReady=false`，PIN 配对前即 fail closed。
- 用户-owned `entry/src/main/ets/services/CloudStore.ets` 未暂存、未纳入本 checkpoint；相邻协议业务源码未改。
- 最终代码 checkpoint：`bc630af34`。复用 ArkTS/UI 与 native/media reviewer 完成终审，P0/P1/P2=0；
  账号租约保存 fence、FAB/配对两层能力、真实错误文案、加密/延迟 fail-closed 策略和相邻协议隔离均已复核。

### 尚未完成与唯一继续顺序

1. N2-09 先在目标设备证明或修复 Asset Store 安全身份，再使用真实 Sunshine 完成
   discovery→HTTP verify→pair→catalog→launch→H.264/Opus first frame→input/controller→stop 回执，分别在 PC/手机
   当前包抓取全新截图和日志。
2. 清理无可见入口的旧九路设置 builder/route 技术债；公共 display、PIP 和主机管理继续只保留一份，不在
   Moonlight 重复。
3. 验收网络切换、旋转、前后台、热状态、两小时长稳、ARM64 实机与实体手柄；完成前只能称“可测试的产品
   可行性框架”，不能称完整 Moonlight 发布能力。
4. Moonlight 云同步继续 PARKED，不得把后续设备收口扩大为云表工作。

## 12.32 N2-09A API-23 安全身份运行时闭环（2026-08-13）

本节覆盖 12.31 中“模拟器 `hostControlReady=false`、需先修复 Asset Store”的旧当前态。代码
checkpoint 为 `ef13ca19`；用户 `CloudStore.ets` 增量仍未暂存、未纳入本轮。

- 根因来自 API-23 Asset Store 的 CE/DE 选择契约：identity/probe 添加时使用
  `ASSET_TAG_REQUIRE_ATTR_ENCRYPTED=true` 写入 credential-encrypted 数据库，但旧 query/remove/list 未携带同一
  selector，因而读取了另一数据库。现 add/query/remove/list 全部一致使用 CE。
- Asset Store 不允许无精确 alias 的 `RETURN_ALL`。probe 清理与 identity inventory 先以
  `RETURN_ATTRIBUTES` 枚举；需要明文 manifest 时再通过 alias、identity、kind、owner 全匹配的 exact query 获取。
- runtime probe owner 为 `runtime-contract:v2:<wall-clock-ms>:<random>`。当前 probe 只清理自身；其他 fresh probe
  不被删除。进程崩溃遗留项达到 5 分钟后按最多 257 条的批次精确删除，每轮至少取得删除进展并重查，因此超过
  单批上限也不会永久占满配额。旧固定 owner 只用于一次兼容清理。
- identity inventory 在属性枚举与 exact manifest 查询之间遇到跨进程删除时执行两次有界快照尝试；第二次仍失效
  返回 `Busy`，不把正常并发删除误报为 `Corrupt`。
- capability truth 只在用户显式打开 FAB picker 后计算和记录；成功时 blocker 为 `none`。首页绘制仍不初始化
  Moonlight native/security，日志只含布尔 capability 与有界 blocker，不记录 PIN、host、certificate 或 secret。

最终门禁：双 ABI platform link probe PASS；精确 `default@OhosTestCompileArkTS` 与 `assembleHap` PASS；签名 HAP
SHA-256 为 `7e84303d06b33926fa702a2384584010612a2517b88aa38aad8d7e4c23096318`。该精确包已通过沙箱外
HDC 安装/启动于手机 `127.0.0.1:5555` 与 PC `127.0.0.1:5557`，两端均记录
`bridge=identity=transport=pairing=hostControl=1 blocker=none`。仅使用并实际查看本包新截图
`/private/tmp/moonlight-phone-picker-7e84303d.jpeg` 与
`/private/tmp/moonlight-pc-picker-7e84303d.jpeg`；入口启用、官方可着色图标和自适应 Sheet 均通过。

复用既有 Luna Max native/media reviewer 完成两轮定点复核；最终 P0/P1/P2/P3=0，并明确关闭“并发误删”和
“崩溃孤儿配额耗尽”。117-file vendor、Light 合规、双 ABI GameControllerKit ELF 隔离与 `git diff --check`
全部 PASS。相邻协议业务实现、公共输入 owner、云表和云同步路径未改变。

N2-09A 至此关闭。当前唯一可本地继续任务为 S1-06 settings closeout；N2-09B/C 仍需真实 Sunshine 与实体手柄，
不得由模拟器 capability/UI 证据替代真实配对、首帧、音频、输入和 stop receipt。

### 2026-08-13 S1-06 设置与本地持久化收口

S1-06 已在 `1af10374` 关闭。Moonlight 设置目录从历史九路收敛为六个协议专属 bindSheet：画面、音频、
控制与手柄、网络与安全、诊断、配对与信任。画面预设和无 Surface 策略归入画面，后台音频归入音频，重连预算
与加密归入网络与安全；公共显示、PIP、系统音量和首页主机管理不再重复。隐藏 quick/background/cloud route、
builder 与跳转入口已删除，Moonlight 云同步继续 PARKED。

本地设置保存修复了空 public-record ciphertext 在设备 TextEncoder 上触发异常的问题；Moonlight 本地记录和 mutation
journal 保持同一事务原子提交，并在 commit 后做 owner-scoped durable readback。手机实测设置保存、进程重启回读和
恢复默认均通过。改动未注册 Moonlight 云表、未进入 CloudSyncCoordinator，也未修改 native/session 热路径或相邻协议
业务文件。

手机与 PC 最新包逐页查看了六个设置页；手机另验收通用 FAB picker、Moonlight 自动发现、手动地址和自定义端口，
PC 验收独立 Moonlight 栏位及自适应添加页。精确 test compile 与 signed assemble 均 PASS；最终签名 HAP SHA-256 为
`83815f082b62dbe1f773a64ffcb224facd9b30cf8253298f36530e3a1cd4e027`，已重新安装并启动于 `127.0.0.1:5555` 和
`127.0.0.1:5557`。下一任务为需要真实 Sunshine 的 N2-09B；实体手柄、ARM64 和长稳仍属于 N2-09C/R1 外部验收。

### 2026-08-18 honesty / metered launch-gate increment

Uncommitted closeout on top of `9d64f9ac`. Moonlight settings that are not runtime-wired are now
honest status rows (`尚未开放`) instead of fake toggles: HDR, YUV 4:4:4, background audio, HUD/log,
rumble, system-shortcut forwarding, reconnect budget and Surface-destroy policy. Metered-network
policy is a real launch gate: `connection.isDefaultNetMeteredSync()`, unknown treated as metered,
`ask` requires one-shot sheet approval, and `startSelected()` re-checks before launch.

`CloudStore.commitMoonlightLocalRecord()` now reports transaction commit truth only.
`MoonlightRepository` owns the post-commit lease/readback so a durable write can keep
`localCommitted=true` when verification later fails. Moonlight remains local-only; cloud sync stays
PARKED. Adjacent protocol business files are unchanged.

Exact `default@OhosTestCompileArkTS` and `assembleHap` PASS on 2026-08-18. Signed HAP SHA-256
`93a666c1e35ba539132231758816baf0312b4abff6e6f542a0bfcb24f765e662`. The launch-sheet action area
uses a vertical adaptive stack so metered-network approval cannot squeeze four actions into one row;
unavailable settings status pills are muted. This increment is not committed and has not been installed
on the current simulators in this turn; `hdc list targets` works, but `hdc install -r` is still rejected
by the external approval service. Do not reuse old screenshots as evidence for this dirty tree.

### 2026-08-19 non-cloud implementation closeout

- FAB/add, local hosts, detail/catalog/launch, H.264/Opus, all MVP input classes, reconnect, Surface/PIP/background
  audio, crash recovery, explicit disconnect/quit and local deletion/unpair/identity lifecycle are production-wired.
  Every asynchronous path remains owner/account/generation/store fenced; account switching drains the Moonlight
  runtime before the next owner store can activate.
- Shared remote-session teardown is exact-owner and exact-generation fenced for Moonlight, RustDesk and SSH window
  handoff failures. Connect failures route through the same native teardown receipt, and only native `Complete`
  releases the registry; rejected, `Unknown` or failed teardown remains tracked for retry instead of clearing a newer
  session. This hardening does not initialize Moonlight or GameControllerKit on any unrelated protocol path.
- Product terminal input truth now requires complete remote neutral release plus accepted boundary and teardown.
  Product tests compile the real `MoonlightCommonCInputPort.cpp` and stub only the official `LiSend*` C ABI, covering
  success, permanent backpressure, port failure, owner loss/local-only and repeated terminal receipts.
- Runtime poll tests drive the production callback through an injected scheduler rather than a public test hook;
  63 misses, the 64th miss, first-frame timeout and exact terminal reconnect are covered without exposing mutable
  production state.
- Exact `default@OhosTestCompileArkTS` and `assembleHap` PASS. Signed HAP SHA-256:
  `9dca00f47309c5048ae5497bd83523dd83fc5aef493ed464da9d77b77f52e8c8`.
  Host native outside the restricted sandbox: `780 passed, 0 failed`; vendor reconstruction and dual-ABI
  GameControllerKit ELF isolation PASS. HostList RustDesk preflight/2FA now captures the exact immutable native/facade
  owner immediately after connect; cancellation, generation/account invalidation, timeout, catch and NAPI retry never
  recapture a later facade. The regression simulates A's first submission throwing, mutates the caller-visible facade to
  B, and proves both attempts still target A. Final focused review: P0/P1/P2/P3 all zero.
- No final HDC install or screenshot acceptance was performed, per user instruction. The deployment fuse remains 0
  until the user explicitly confirms the exact AGC `moonlightrecordv1` table; only then may cloud integration proceed.
