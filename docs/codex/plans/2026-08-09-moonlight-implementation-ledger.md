# Moonlight 完整升级实施台账

> 任务：`moonlight-complete-upgrade`
> 分支：`codex/moonlight-complete-upgrade`
> 初始基线：`main@aeb0cdac5`，与 `origin/main` 一致
> 总计划：`docs/superpowers/plans/2026-07-28-moonlight-harmonyos-complete-upgrade-plan.md`
> 台账状态：G0、D1、D2 本地/休眠策略、D3 本地生命周期以及 N1-01～N1-07 已形成 checkpoint；当前唯一代码任务为 N1-08 fail-closed typed NAPI/Host Service bridge；D2-05～D2-07、D3 在线/多设备和产品运行时仍等待外部回执，只把有可复现证据的项目标记为通过

## 1. 执行约束

1. 严格按总计划第 15 节的 G0 → D1 → D2/D3 → N1/N2/N3 → U1/S1 → R1 顺序推进。
2. Moonlight 是独立协议域。不得把 host、profile、trust、identity 或设置写进其他协议表。
3. 尚未通过能力探针、真实 Sunshine 和 ARM64 真机门禁的功能保持 fail closed，不以占位实现宣称支持。
4. AGC 三环境 schema receipt 完成前，`moonlightrecordv1` 不进入生产分布式表注册集合。
5. 每个代码任务将测试与实现同提交；阶段末执行 native/ArkTS 定向测试、双 Hvigor、assembleHap、Light 和一次有界复核。
6. 本任务最多使用两个审查智能体，模型只允许 `sol low`；不得因上下文压缩重复派发同一审查。
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
4. 运行 `scripts/dev_workflow.sh light`；任何未知许可证、缺失源码或哈希不一致直接阻断发布。

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

## 9. D2 本地数据层 checkpoint

| ID | 状态 | 落地产物与合同 |
| --- | --- | --- |
| D2-01 | PASS | owner-store schema 从 4 升为 5；用单一 schema policy 创建并逐列核验 `moonlightrecordv1` 19 列、`moonlightlocalrecords` 20 列、`moonlightappcache` 16 列；只有 `id` 是主键；owner 核验后写 `moonlightrecordv1_schema_19col_v1` receipt |
| D2-02 | PASS | `MoonlightRepository` 和 `CloudStore` port 携带完整 `AccountSessionLease`；写前/写后校验 owner、generation、storeInstance；upsert/tombstone 只事务写 local overlay + journal + readback；retry 幂等、mutation 复用隔离、同 id 跨 owner 隔离、云调用恒为零 |
| D2-03 | PASS | `MoonlightAppCacheService` 使用 owner+host+app SHA-256 key；完整/部分目录刷新语义分离；超期优先、再稳定 LRU；2048 条、64 MiB 总量、2 MiB 单项边界；cache 事务不触碰 profile/cloud/backup |
| D2-04 | PASS | `CloudTableAdapter` 增加 Moonlight exact 19 列合同；缺列、未知列、非 exact 20 列 mirror、`localonly=1` 全部拒绝；payload 保持 opaque，不做默认补齐 |
| D2-05 | EXTERNAL PENDING | 尚无 AGC 开发环境 schema/权限/索引/分页/删除 receipt | 不修改生产 `TABLES` |
| D2-06 | EXTERNAL PENDING | 尚无测试与生产环境等价 receipt | `moonlightCloudSchemaReady=false` |
| D2-07 | BLOCKED BY D2-05/06 | `CloudSyncPolicy` 仍精确返回既有 8 表，Moonlight 三表均不在注册集合 | 三环境回执齐全前禁止放行 |
| D2-08 | PASS | `CloudSensitiveTransferPolicy` 对 Moonlight 逐行 exact/semantic 验证；普通行不依赖 identity crypto；live identity 上传要求 configured crypto + authenticated ciphertext；reset 后既有密文只允许 opaque 下载保留 | 不沿用普通表“crypto off 可按明文上传”的规则；unsafe snapshot 只暂停 Moonlight 物理表 |
| D2-09 | PASS | 独立五 scope policy/store 默认 `[]`，固定 owner preference key；identity capability=false 时主动裁剪；stage→RDB projection→Preferences persist，失败回滚投影、内存和 durable 值 | 不复用 VNC prefs；所有步骤携带完整 account lease |
| D2-10 | PASS | dormant `MoonlightCloudSyncService` 完成 physical/logical/identity gate、cloud-first validate/materialize、tombstone、redacted quarantine、partial failure 和 selected local promotion | 只经 port 操作、页面不可拿 CloudStore；`cloudAttempted=false`，不改变 8 表注册集合 |

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
- 静态和运行时均确认 `CloudSyncPolicy` 仍只有既有 8 表；本次没有执行 Moonlight `setDistributedTables`。

## 10. D3 账户、删除、云状态和备份恢复 checkpoint

| ID | 状态 | 已落地合同 | 仍需完成/不得越界 |
| --- | --- | --- | --- |
| D3-01 | ONLINE BLOCKED / STATUS POLICY PASS | `MoonlightCloudStatusPolicy` 将 physical selection、五 scope、bootstrap、pending、quarantine、last success/error、identity crypto lock 分开建模 | `moonlightrecordv1` 尚未注册，禁止把策略结果当成在线同步；真实 request/retry/bootstrap wiring 等 D2-07 |
| D3-02 | LOCAL/DORMANT PASS | repository、selection、materializer 和 barrier 均携带完整 lease 并在事务/回调边界复核 owner、generation、storeInstance | 真实 CloudSyncCoordinator callback 尚不存在，必须在 D2-07 后补账号 A→B 迟到回调实测 |
| D3-03 | CONTRACT PASS / RUNTIME PORT PENDING | `SensitiveDataBarrier` 在 store quiesce 前调用 Moonlight drain；顺序固定为关闭 mutation/launch→session→pairing→identity restore→cloud/journal→runtime secrets；`AccountSessionCoordinator` 激活 store 后绑定新 lease；任一步失败保持切换 fail closed | N1 runtime port 未注册时是安全 no-op；真实 session/pairing/native secret drain 要在 N1/S1 后做强杀和超时验收 |
| D3-04 | PASS | 保持 Backup V3；可选 descriptor 与 `moonlightrecordv1`/`moonlightlocalrecords` 双 section 已进入 manifest/inventory；旧 V3 缺 section 等价于无 Moonlight；新 V3 未被旧 inventory 认识时必须拒绝 | 不增加 Backup V4；若后续发现旧 reader 静默忽略未知 section，立即停发并改 V4 |
| D3-05 | LOCAL RESTORE PASS / CLOUD PROMOTION BLOCKED | 两个 section 先 exact/owner/semantic 验证和去重冲突裁决，再只输出 `moonlightlocalrecords` 且 `localonly=1`；tombstone 保留，identity 冲突、等 envelope 歧义和 orphan profile/trust 隔离；恢复不会设置旧协议共用的“已恢复未上传”总 marker | 云已启用后的 cloud-first/promotion 等 D2-07；恢复中切账号、磁盘满、杀进程的设备级原子性仍归 D3-08 |
| D3-06 | LOCAL EXECUTION PASS / CLOUD+HOST PENDING | 六类命令从当前 owner 的业务行、cache、journal/quarantine/restore marker 和 secure identity inventory 生成预览，执行前重新计算；settings 已纳入“删全部”；本地删除/忘记 host/删 profile 由 CloudStore 单事务删除 exact set 并清 local-only journal，不制造 cloud delete；identity 安全材料先清、RDB 后清且分别报告终态；取消同步走独立 selection port | `ea32ffa`；缺真实 AGC terminal port 时删云/需 tombstone 的命令返回 `cloud_unavailable`，缺 N1 Host Control 时 unpair 返回 `host_unavailable`；U1 接线前不对用户暴露 |
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
| N1-08 | READY / FAIL-CLOSED BRIDGE ONLY | D1 typed contract、D2 app cache、D3 lease/barrier 和 N1-06/N1-07 均已冻结 | 只建独立 typed async NAPI/Host Service；production factory 首包前 unavailable，FAB、云、媒体、输入和六项 truth 不变 |

N1-01 的可复现证据：

- `verify_moonlight_vendor.py` 在 Git worktree 与无 `.git` 的普通源码归档中均 PASS；后者只跳过 Git index 检查，117 个工作树字节、license、artifact hash、SPDX、NOTICE 和三个官方 tree 仍全部核验。
- shell 与 PowerShell 7 均在新临时目录构建 `arm64-v8a`、`x86_64`，四个 archive SHA-256 与 `UPSTREAM.lock.json` 一致；Release 合规模式实际调用同一 PowerShell 双 ABI 门禁，Light 只执行快速离线门禁。
- nanors 原始 `make check` 的 6 个 Perl test 文件及 RS16/RS16 AFFT 最终测试通过；common-c/ENet 本 revision 没有上游 CMake test target。
- 合规生成器连续两次运行三份输出 hash 完全一致；签名 HAP 与两 ABI `librdpnapi.so` 都没有 Moonlight/common-c/ENet 文件或符号，现有八张云表未改变。
- 首个 `gpt-5.6-sol low` 有界审查确认官方 commit/tree/gitlink/117 文件字节与产品隔离，提出的 tree 绑定、源码归档模式、NOTICE 幂等和 Release 双 ABI 四项问题均已修复并由上述机器门禁覆盖；不为同一 checkpoint 重派审查。最终整合前只剩一个 reviewer 名额。

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

N1-08 的唯一合法入口是主计划第 15.7.7 节定义的 fail-closed typed bridge：独立
Moonlight NAPI 负责 exact DTO、async work、单次 settlement、取消与 env teardown，
ArkTS `MoonlightHostService` 负责完整账户 lease、迟到结果丢弃和既有 app cache 提交。
production factory 在 runtime identity/transport/trust/commit 未证明时必须零网络返回
unavailable；不得扩张 `ProtocolAdapter`、接 UI/媒体/输入/云或改变六项 truth。

## 12. 2026-08-10 N1-01～N1-07 checkpoint 验证

- `default@OhosTestCompileArkTS`：N1-07 最终源码后退出码 0；既有 19 个 describe、
  138 个 Moonlight test 编译注册，本步没有新增 ArkTS 测试 surface。
- signed `assembleHap`：N1-07 最终源码后退出码 0；423 项路径 inventory 与 N1-06
  一致。
- host `rdp_native_tests`：N1-07 最终二进制为 **426/426 PASS**，ASan/UBSan 同为
  426/426；新增 26 组 Host Control 用例。
- `scripts/probe_moonlight_platform.sh`：arm64-v8a、x86_64 均 PASS。
- `verify_open_source_release.ps1 -Mode Light`：N1-07 后 PASS；Release 中 Moonlight 双
  ABI子门通过，完整发布仍被两个外部 approval boolean 正确阻断。
- `verify_moonlight_vendor.py`：三个官方 Git tree、117 个 exact 文件、Git index 与无 Git 源码归档模式均 PASS；合规生成器幂等 PASS。
- `build_moonlight_common_vendor.sh/.ps1`：API 23 arm64-v8a/x86_64 静态 archive 均匹配锁定 receipt。
- `git diff --check`：N1-07 代码 checkpoint 后 PASS；`codex_state validate` 在本次
  状态文档更新后执行并记录。
- `CloudSyncPolicy.CLOUD_SYNC_TABLES` 静态复核仍精确为既有 8 表；Moonlight 云表、local mirror 和 app cache 均未进入在线注册集合。
- HDC 当前返回 `Connect server failed`；早期 ARM64 API 24 RDB receipt 仍有效，但本次没有新增虚拟设备 Hypium 或恢复运行时证据。

## 13. 下一执行序列

1. 严格按主计划第 15.7.7 节执行 N1-08，只建立独立 typed async NAPI 与 ArkTS
   `MoonlightHostService`；native exact key/cancel/teardown 与 ArkTS account lease/cache
   commit 各守边界。production factory 在 HAP identity/transport/trust/commit 未证明时
   首包前 unavailable；不得接 FAB/路由/媒体/输入/云或改变 feature truth。
2. D2-05/06 由 AGC 开发/测试/生产环境提供 schema/授权/索引 receipt；缺失时 D2-07、D3-01 在线 wiring、D3-05 cloud-first promotion、D3-06 cloud terminal 和 D3-08 云矩阵继续阻断。
3. N1 Host Control port 可用后再接 D3-06 remote unpair；端口失败只允许返回带 warning 的真实本地终态，不伪造主机已解绑。
4. 补 HAP 内 typed capability probe；真实 Sunshine 和用户 ARM64 真机未提供前，host-control/streaming/protocol truth 继续为 false。
