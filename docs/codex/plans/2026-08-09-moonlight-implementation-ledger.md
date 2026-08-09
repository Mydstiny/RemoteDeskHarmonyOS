# Moonlight 完整升级实施台账

> 任务：`moonlight-complete-upgrade`
> 分支：`codex/moonlight-complete-upgrade`
> 初始基线：`main@aeb0cdac5`，与 `origin/main` 一致
> 总计划：`docs/superpowers/plans/2026-07-28-moonlight-harmonyos-complete-upgrade-plan.md`
> 台账状态：G0、D1、D2 本地/休眠策略、D3 本地生命周期以及 N1-01 官方源码隔离 vendoring 已形成 checkpoint；D2-05～D2-07 与 D3 在线/多设备部分等待外部回执；只把有可复现证据的项目标记为通过

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
| N1-02 | READY | 主 `CMakeLists.txt` 已有 ABI 选择、现有 OpenSSL 3.4.1 imported `ssl`/`crypto`、`rdpnapi` shared target 和 RDP-only native test early return；N1-01 wrapper 已证明 API 23 两 ABI静态构建 | 只建立 target-scoped product link；不加 NAPI/runtime/UI，不把 upstream include/宏变为目录或全局属性 |
| N1-03～N1-08 | PENDING | D1 session/host/pairing/catalog 合同与 D3 runtime ports 已冻结 | 必须逐 ID 推进；N1-02 未通过前不创建 runtime owner |

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

## 12. 2026-08-10 checkpoint 验证

- `default@OhosTestCompileArkTS`：N1-01 最终源码后退出码 0；19 个 describe、138 个 Moonlight test 编译注册。
- signed `assembleHap`：N1-01 最终源码后退出码 0，`BUILD SUCCESSFUL in 7 s 74 ms`。
- host `rdp_native_tests`：沙箱内本地 TLS fixture 因 socket 监听限制为
  326/342；按门禁在沙箱外复跑为 **342/342 PASS**，确认不是代码回归。
- `scripts/probe_moonlight_platform.sh`：arm64-v8a、x86_64 均 PASS。
- `verify_open_source_release.ps1 -Mode Light`：N1-01 后 PASS；Release 中 Moonlight 双 ABI子门通过，完整发布仍被两个外部 approval boolean 正确阻断。
- `verify_moonlight_vendor.py`：三个官方 Git tree、117 个 exact 文件、Git index 与无 Git 源码归档模式均 PASS；合规生成器幂等 PASS。
- `build_moonlight_common_vendor.sh/.ps1`：API 23 arm64-v8a/x86_64 静态 archive 均匹配锁定 receipt。
- `git diff --check`、`codex_state validate`：N1-01 代码 checkpoint 后 PASS。
- `CloudSyncPolicy.CLOUD_SYNC_TABLES` 静态复核仍精确为既有 8 表；Moonlight 云表、local mirror 和 app cache 均未进入在线注册集合。
- HDC 当前返回 `Connect server failed`；早期 ARM64 API 24 RDB receipt 仍有效，但本次没有新增虚拟设备 Hypium 或恢复运行时证据。

## 13. 下一执行序列

1. 严格按第 11 节 8 步执行 N1-02，只建立 project-owned 静态 target 与 `rdpnapi` 的私有构建边；不接 NAPI/runtime/UI，不改变 capability truth。
2. D2-05/06 由 AGC 开发/测试/生产环境提供 schema/授权/索引 receipt；缺失时 D2-07、D3-01 在线 wiring、D3-05 cloud-first promotion、D3-06 cloud terminal 和 D3-08 云矩阵继续阻断。
3. N1 Host Control port 可用后再接 D3-06 remote unpair；端口失败只允许返回带 warning 的真实本地终态，不伪造主机已解绑。
4. 补 HAP 内 typed capability probe；真实 Sunshine 和用户 ARM64 真机未提供前，host-control/streaming/protocol truth 继续为 false。
