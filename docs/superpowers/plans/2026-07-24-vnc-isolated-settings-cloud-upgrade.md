# VNC 独立设置、完整中继与云同步/加密升级实体计划

> 计划日期：2026-07-24  
> 状态：代码实施完成；自动化验证通过；待华为云建表、真实中继/设备验收  
> 适用仓库：RemoteDeskHarmonyOS  
> 本计划同时作为实施记录和后续验收清单；华为云端尚未由本任务直接创建表。

## 0.1 用户约束修订：云端只增加一张表

本节是 2026-07-24 后续确认的最新约束，优先级高于本文后续仍保留的“五张 VNC 云表”历史草案。实际实施只能向华为云端增加一张表：`vncrecord`。代码已经按此约束实现；后续云端部署和验收均以本节为准；历史五表内容仅作为已否决的拆分方案留档，不能照抄部署。

### 唯一云表：`vncrecord`

一张表通过 `recordtype` 区分设置、主机、网关、密钥和 trust 记录，通过 `ownerid` 建立逻辑关系。所有 VNC 记录仍使用独立 namespace，不进入 `remotehosts`、`usersettings` 或 `rustdeskrelays`。

| 字段 | 类型 | 用途 |
| --- | --- | --- |
| `id` | String/TEXT PRIMARY KEY | CryptoArchitectureKit 随机记录 ID |
| `userid` | String/TEXT | 稳定华为账号 scope |
| `recordtype` | String/TEXT | `settings`、`host`、`gateway`、`secret`、`trust` |
| `ownerid` | String/TEXT | host/gateway/账户逻辑 owner ID |
| `ownertype` | String/TEXT | `account`、`host`、`gateway` |
| `secretkind` | String/TEXT | secret 行的非敏感类型；其他行为空 |
| `payload` | String/TEXT | canonical JSON；secret 行只放元数据，禁止放明文 secret |
| `ciphertext` | String/TEXT | 仅 secret 行使用的 VNC v2 AAD 密文 |
| `envelopeversion` | Integer | 当前 secret 行必须为 2，非 secret 行为 0 |
| `cryptoversion` | Integer | 当前 VNC crypto contract 版本 |
| `keyversion` | Integer | DEK/key 版本 |
| `aadversion` | Integer | AAD 版本 |
| `payloadhashsha256` | String/TEXT | canonical payload 完整性摘要 |
| `syncversion` | Integer | 记录版本 |
| `schemaversion` | Integer | 行 payload/schema 版本 |
| `resetepoch` | Integer | VNC 加密重置 epoch |
| `createdat` | Integer | 创建时间 |
| `updatedat` | Integer | 最后修改时间 |
| `deletedat` | Integer | tombstone 时间，0 表示未删除 |

云表部署时只创建 `vncrecord` 这 19 个字段和 `id` 端侧去重主键。`payload` 是非敏感记录的唯一业务载荷；`ciphertext` 是 secret 记录的唯一敏感载荷。`recordtype=secret` 时，`payload` 只能包含 `secretkind`、owner 引用和展示元数据，不能包含密码、token、私钥或其 base64 明文。

为了保证 secrets 默认不同步，本地 RDB 额外使用不注册到云端的 `vnclocalrecords` 表保存完整 VNC 本地状态。只有用户显式开启 VNC secret sync 且 crypto ready 时，`VncCloudSyncService` 才把加密 secret 镜像到 `vncrecord`；关闭后保留本地密文并停止本机对云镜像的投影，不写反向云 tombstone。只有用户明确删除记录时才写普通删除 tombstone，避免某台未选择或未解锁的设备撤回其他设备仍在使用的共享云行。这样一张云表仍能保持 secret opt-in，不依赖云端按行过滤能力。

### 关系和同步规则

- `recordtype=settings`：每个 `userid` 一个账户设置记录，`ownerid` 等于账户 settings ID。
- `recordtype=host`：`payload.gatewayId` 只能引用同一 `userid` 的 gateway 行。
- `recordtype=gateway`：Repeater/WebSocket/public relay/SSH tunnel 的非敏感端点和 capability 配置进入 payload。
- `recordtype=secret`：`ownerid` 指向 host 或 gateway，`secretkind` 指定 VNC password、Repeater target token、gateway access token 或证书引用，密文进入 ciphertext。
- `recordtype=trust`：证书指纹和用户确认状态进入 payload；新设备不能因云恢复自动信任。
- `deletedat` 和 `resetepoch` 对所有 recordtype 生效，旧设备不得复活已删除或旧 epoch 的记录。
- CloudStore 只把 `vncrecord` 注册为新的 distributed cloud table；`vnclocalrecords`、VNC retry/journal 和诊断表永远是本地表。

本文后续凡出现 `vnchosts`、`vncgateways`、`vncsecrets`、`vncsettings` 或 `vnctrusts` 作为云表名称，均应转换为 `vncrecord` 中对应的 `recordtype`；实现代码不得注册这五个名称。

### 0.2 本轮代码实施记录（2026-07-25）

- [x] `VncSettingsPage`、`VncSettingsService`、`VncHostService`、`VncGatewayService`、`VncSecretService` 和 `VncTrustService` 已形成独立 VNC owner 链路；RDP、RustDesk、SSH/SFTP 仍使用各自 owner。
- [x] 云端只新增 `vncrecord`；`recordtype` 为 `settings`、`host`、`gateway`、`secret`、`trust`，本地覆盖表为 `vnclocalrecords`，不注册分布式云表。
- [x] VNC secret 使用 `DataCrypto.encryptField()` 的 AES-GCM v2 envelope，AAD 绑定 scope/table/record/field/schema；secret 默认不上传，只有 VNC 选择器、crypto 解锁和用户确认同时满足才镜像到云表。
- [x] `cryptoparams.vnc_reset_epoch` 已成为非敏感 reset marker：加密重置时递增，VNC 新行自动绑定当前 epoch，读取/改写旧 epoch 时 fail closed；本地备份恢复也不能降低 epoch。
- [x] Native 已接入 RFB 3.3/3.7/3.8、VNC DES password、Raw/CopyRect/DesktopSize、BGRA、键鼠/剪贴板以及 UltraVNC Repeater viewer mode12；mode2 已按官方 server-side listener 的固定字段契约完成边界和 fixture 校验，但 HarmonyOS viewer 不冒充 server 端、不开放 mode2 viewer 连接；WebSocket、公网 relay、SSH tunnel/reverse listen 仍由运行时 gate 关闭。
- [x] 自动化验证：`default@OhosTestCompileArkTS`、`assembleHap`、Native `144 passed, 0 failed`、`git diff --check`。
- [ ] 待用户在华为云端创建唯一 `vncrecord` 表，并用两台 API 23 设备完成云同步、真实 VNC server/Repeater 和 reset 验收；这些外部步骤不由本地代码自动完成。

## 0. 执行边界

本计划解决四类连接之间的边界问题：RDP、RustDesk、SSH/SFTP、VNC。VNC 必须成为自己的产品域、数据域、设置域、连接域和同步域。现有的共享基础设施可以继续复用，但共享接口必须是无协议业务语义的基础能力，并且每次调用都携带 protocol=vnc 或明确的 VNC namespace。

本次执行已完成：VNC namespace、独立设置页和服务、唯一云表/本地镜像、secret 默认不同步、VNC v2 AAD、RFB/Repeater native 链路、隔离测试和构建验证。尚未完成的仅是云端实际建表、真实 UltraVNC 双端/API 23 设备验收，以及没有后端契约的 WebSocket、公网 relay、SSH tunnel/reverse listen。

执行本计划时遵守以下规则：

- [x] 所有实现放在单独的 VNC 工作分支中；不把 VNC 提交混入 RDP、RustDesk 或 SSH/SFTP 分支。
- [x] VNC feature gate 和 transport allowlist fail-closed；依赖、契约或安全状态不完整时不可连接，不影响其他协议。
- [x] 关键任务已补测试并完成自动化验证；真实设备/云端门禁仍保留在后文。
- [x] 不使用 git reset --hard、git checkout -- 或覆盖用户已有变更。
- [x] 云端 schema 只增加 `vncrecord`；不向 remotehosts、rustdeskrelays、usersettings 追加 VNC 业务字段。
- [x] 任何 VNC 密码、Repeater target token、gateway token、客户端私钥或私钥引用都不得进入日志、Toast、普通备份或其他协议表的明文字段。

## 1. 目标与完成定义

### 1.1 产品目标

完成后，用户可以在独立的 VNC 设置页中管理 VNC 默认行为，在主机列表中添加和使用 VNC 主机，在可信网络或明确开启的安全传输下建立真实 RFB 会话，并按用户选择同步 VNC 配置、网关、凭据和信任记录。

“完整 VNC 中继功能”在本计划中的定义不是把一个地址字段显示出来，而是包含以下可验证的链路：

1. 直连 TCP：VNC viewer 直接连接 VNC server，默认端口 5900。
2. UltraVNC Repeater：HarmonyOS viewer 支持经上游源码验证的 mode 12 配对流程；mode 2 只定义 server-side listener 的固定字段契约，不能在 viewer 端伪装成同一流程。配对成功后将连接作为字节流交给 RFB engine。
3. WebSocket gateway：支持明确的 binary WebSocket gateway 协议，处理连接、认证、二进制帧、心跳、背压、关闭和重连。
4. 公网 relay：只有在项目拥有版本化 gateway endpoint 和认证契约时才启用；没有服务端契约时保持 feature gate 关闭，不把普通 TCP Repeater 冒充为公网 relay。
5. SSH tunnel：作为后续 transport，通过独立 SSH 凭据和隧道服务接入；不复用 VNC password 或 RustDesk relay credential。
6. reverse/listen：作为独立的 server-side/反向连接阶段，不在直连或 Repeater 代码中偷偷推断支持。

每种中继都必须能显示实际状态：未配置、配置无效、正在配对、已建立字节通道、RFB 握手失败、认证失败、TLS 不符合策略、目标离线、用户取消、超时和已断开。不能仅以“已保存”显示“已在线”或“可连接”。

### 1.2 不能被破坏的现有行为

- RDP 继续使用自己的 RemoteHost 字段、FreeRDP 配置、凭据和网关设置。
- RustDesk 继续使用自己的 ID/Relay/API/账户/Key 结构和页面。
- SSH/SFTP 继续使用自己的 key、host-key trust、terminal、proxy 和文件传输路径。
- VNC 不读取或写入 rdpAudioEnabled、rdpControlMode、rustdeskCodec、rustdeskPrivacyMode、RustDesk relay 字段、SSH key 字段或普通 usersettings payload。
- 统一 HostList 如果需要展示 VNC，只能使用只读投影；统一列表不能反向成为 VNC 的数据 owner。
- VNC raw framebuffer 不进入 RustDesk 的 H.264/VPx decoder；VNC 只走独立的 BGRA/raw frame 入口。

### 1.3 分阶段交付目标

| 里程碑 | 内容 | 默认状态 |
| --- | --- | --- |
| M0 | namespace、`vncrecord` 单表、VNC v2 加密 envelope、独立 settings contract | 代码完成；待云端建表 |
| M1 | 直连 RFB 3.3/3.7/3.8、VNC password、Raw/CopyRect、BGRA、键鼠、view-only | 代码/自动化完成；待 API 23 实机 |
| M2 | UltraVNC Repeater viewer mode12、mode2 server-side 字段契约、target 配对、字节中继 | viewer 代码/fixture 完成；mode2 server-side 组件和真实 Repeater 双端仍待部署验收 |
| M3 | WebSocket gateway、TLS/pinning、文本剪贴板 | 契约草案/运行时 gate；未部署，不宣称可用 |
| M4 | 公网 relay/SSH tunnel/reverse listen 的版本化 transport | 后端契约和实机环境缺失，保持 unavailable |

## 2. 当前代码基线和问题

审计基线为当前仓库 main 分支的 28c3ff43。以下是实施前的历史基线；实施结果和当前限制以本计划第 0.1 节、实施记录及最终门为准。

| 当前事实 | 位置 | 对升级的影响 |
| --- | --- | --- |
| VNC adapter 仍是拒绝连接的 mock；defaultPort 为 5900，protocolVersion 返回 unsupported | entry/src/main/cpp/vnc/vnc_adapter.cpp、vnc_adapter.h | 需要在 adapter 后增加 VncSession，不能把握手和第三方类型直接塞进 adapter |
| VNC 已注册到 extension system，ArkTS 能识别 RemoteProtocol.vnc，但 capability policy 仍明确不可用 | entry/src/main/ets/services/RemoteSessionCapabilityPolicy.ets、RemoteDesktop.ets | 保留诚实的 unavailable 状态，按 session capability 逐项开放 |
| 当前 RemoteHost 包含 RDP、RustDesk、SSH 和通用字段，remotehosts 是混合云表 | entry/src/main/ets/model/RemoteHost.ets、CloudStore.ets | 不能继续在 RemoteHost 或 remotehosts 增加 VNC 专属字段 |
| CloudTableAdapter 对 remotehosts 有大量协议扩展和 displayconfig 兼容逻辑 | entry/src/main/ets/services/CloudTableAdapter.ets | VNC 必须增加独立白名单，不能复用 displayconfig extension |
| VncRelayConfig/VncRelayConfigService 已经有本地 VNC Repeater 配置，但仍使用 Preferences | entry/src/main/ets/model/VncRelayConfig.ets、VncRelayConfigService.ets | 一次性安全迁移为 `vncrecord(recordtype=gateway/secret)`，旧 service 最终只能是兼容 facade |
| VNC Repeater 表单嵌在 RustDeskRelayPage，Modern FAB 也从中继资源流程进入 | entry/src/main/ets/pages/RustDeskRelayPage.ets、components/resourceadd/modern/ModernRelayAddFlow.ets | UI 视觉和状态边界不够；必须迁移到独立 VNC settings/gateway flow |
| 当前正式云链路是 CloudStore + CloudSyncCoordinator + HarmonyOS distributed cloud table；CloudSyncService.ets 是另一个自定义 REST API 实现 | entry/src/main/ets/services/CloudStore.ets、CloudSyncCoordinator.ets、CloudSyncService.ets | VNC 只能接入正式 CloudStore 链路，不允许无意中双写 REST 和 HarmonyOS cloud |
| 现有同步表为 cryptoparams、usersettings、remotehosts、rdpcredentials、rustdeskrelays、sshkeys、totpentries | CloudSyncPolicy.ets、CloudStore.ets | 新增一个 `vncrecord` 物理表；用 `recordtype` 和独立选择器区分五类 VNC 逻辑记录 |
| 当前 DataCrypto 为 PBKDF2-SHA256 100,000 次、AES-256-GCM、空 AAD 的 v1 envelope | entry/src/main/ets/services/DataCrypto.ets | VNC 只能使用绑定 table/record/field 的 v2 envelope；现有 v1 继续兼容，不能全局硬切 |
| 当前 settings 主要由 HostListPage 的 accordion/leaf sheet 管理，路由登记在 main_pages.json | entry/src/main/ets/pages/HostListPage.ets、SettingsAccordionPolicy.ets、SettingsSheetRoutePolicy.ets、resources/base/profile/main_pages.json | VNC 采用新建的独立 page 和 route，不把 VNC 设置塞进 RDP/RustDesk sheet |

当前最重要的缺口是数据 ownership，而不是多加几个 VNC UI 字段：VNC 目前既有一个本地独立的 Repeater 配置，又有可能被通用 host 添加流程当成 RemoteHost，同时页面入口还挂在 RustDesk relay 页面。实施顺序必须先固定 ownership 和迁移边界，再接 native engine。

## 3. 官方依据和方案决策

### 3.1 RFB/VNC

- [RFB protocol specification](https://github.com/rfbproto/rfbproto/blob/master/rfbproto.rst)：用于版本协商、security types、ServerInit、SetPixelFormat、SetEncodings、FramebufferUpdate、PointerEvent、KeyEvent、ClientCutText/ServerCutText 和错误处理。
- [LibVNC/libvncserver](https://github.com/LibVNC/libvncserver)：只引入经过审计和固定 commit 的 LibVNCClient；第三方类型只能出现在 LibVncEngine 内部。
- [UltraVNC mode 12 listener](https://github.com/UltraVNC/UltraVNC/blob/main/repeater/mode12_listener.cpp) 和 [mode 2 listener](https://github.com/UltraVNC/UltraVNC/blob/main/repeater/mode2_listener_server.cpp)：用于建立独立的 Repeater pairing parser 和真实字节流测试向量。Repeater 配对头不是 RFB ServerInit，必须先完成准确的 readExact/writeAll 和 target matching，再把 socket 交给 RFB engine。

RFB 方案决策：

- V1 协商 RFB 3.3、3.7、3.8，security type 使用 allowlist；服务端提供未实现或被本地安全策略拒绝的类型时明确失败。
- V1 先支持独立 VNC password、Raw、CopyRect 和 macOS 实际需要且通过 fuzz/security gate 的最小编码集合；Tight、ZRLE、Hextile、JPEG、TLS/VeNCrypt、SASL、Apple 私有认证均以独立 capability 开放。
- VNC framebuffer 在 native 线程中完成有界复制/解码为 BGRA，再通过 generation-safe raw renderer 提交；不能复用 encoded video callback。
- 输入必须由 VNC 专属 mapper 转换为 pointer/key event，不能把 RDP scancode 或 RustDesk control mode 当成 VNC 语义。

### 3.2 HarmonyOS 官方约束

- [Socket connection](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/socket-connection)：connect/read/write/close、超时和取消必须运行在 worker/native transport 中；不得在 ArkUI 线程执行阻塞 socket 操作。
- [Node-API thread safety](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/use-napi-thread-safety)：native worker 不直接操作 ArkTS 对象或 JS reference，使用现有 N-API 安全派发边界；回调必须带 session generation，防止旧线程事件进入新页面。
- [Native WebSocket guidelines](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/native-websocket-guidelines)：只有 WebSocket gateway 采用 WebSocket transport；Raw TCP RFB 和 UltraVNC Repeater 不套 WebSocket API。后台、surface detach、socket 重建和关闭都必须遵守生命周期要求。
- 当前工程按 HarmonyOS NEXT API 23 运行。计划不引入 API 26 的 @kit.uiMaterial，新 page、route、socket bridge、crypto API 都必须先过 API 23 编译和双 ABI 构建。

### 3.3 HarmonyOS 云空间和本地实现

当前 CloudStore 已采用 relationalStore.setDistributedTables(..., DISTRIBUTED_CLOUD, { autoSync: false })，由 CloudSyncCoordinator 显式串行执行 cloud-first/native-first，并设置 Wi-Fi 云策略。新增 VNC 必须沿用这条正式链路。

当前自定义 CloudSyncService.ets 使用 @kit.NetworkKit 调用 api.remotedesktop.app REST endpoint，它与 HarmonyOS distributed cloud table 不是同一个实现。VNC 不加入该旧 REST 路径；未来如需服务端 relay API，必须另建版本化 gateway endpoint，不把 VNC 业务数据偷偷双写到 /hosts、/keys 或 /totp。

## 4. VNC 强隔离架构

### 4.1 组件拓扑

~~~mermaid
flowchart TD
  VSP["VncSettingsPage"] --> VSS["VncSettingsService"]
  HLP["HostList read-only projection"] --> VHS["VncHostService"]
  VHS --> VCS["VncCloudSyncService"]
  VSS --> VCS
  VGS["VncGatewayService"] --> VCS
  VSEC["VncSecretService"] --> CRYPTO["DataCrypto v2 / AAD"]
  VTS["VncTrustService"] --> VCS
  VCS --> CST["CloudStore generic table executor"]
  VCS --> CSC["CloudSyncCoordinator scoped request"]
  VHS --> SESSION["VncSession"]
  VGS --> TRANSPORT["Direct / Repeater / WebSocket / SSH transport"]
  SESSION --> TRANSPORT
  SESSION --> ENGINE["IVncEngine / LibVncEngine"]
  ENGINE --> FRAME["BGRA generation-safe renderer"]
~~~

### 4.2 VNC 专属 owner

新增或重命名后的 service 职责固定如下：

| 组件 | owner | 允许依赖 | 明确禁止 |
| --- | --- | --- | --- |
| VncHostService | VNC 主机描述、列表、CRUD、迁移标记 | VncCloudSyncService、VNC models、只读 projection | HostSyncService 作为 owner；RemoteHost.password |
| VncSettingsService | VNC 默认连接和安全偏好 | VncSettings、VNC policy、VNC cloud | RDP/RustDesk setting key、通用 usersettings |
| VncGatewayService | Repeater/gateway 配置和 capability 状态 | VncGateway、VncSecretService | RustDeskRelayConfig、rustdeskrelays |
| VncSecretService | VNC password/token/cert reference | DataCrypto v2、VNC secret table | 明文 Preferences、普通备份、日志 |
| VncTrustService | TLS/VeNCrypt fingerprint/pinning | `vncrecord(recordtype=trust)`、用户确认 policy | 自动信任云下发 fingerprint |
| VncCloudSyncService | 一个 VNC 物理表内五类逻辑记录的同步、冲突、墓碑、恢复 | CloudStore generic executor、Coordinator scoped API | CloudSyncService REST、HostSyncService |
| VncSession | 单次连接生命周期、RFB capability、输入和帧 | VNC native bridge/transport/renderer | RDP/RustDesk session state |
| VncGatewayTransport | 连接、配对、二进制 relay、取消和超时 | HarmonyOS socket/WebSocket/SSH primitives | 解析 RDP、RustDesk 或 SSH 业务 payload |

共享设施只允许提供：表执行器、事务、通用 DataCrypto 原语、N-API 线程安全派发、renderer surface/generation 接口、active session registry 和统一列表的只读投影接口。共享设施不得拥有 VNC password、VNC settings 或 gateway target token。

### 4.3 Namespace 和调用契约

所有 VNC 数据、缓存、任务和事件使用以下固定标识：

~~~text
protocol: vnc
dataScope: vnc
cryptoScope: remotedesktop|vnc
schemaVersion: 1
envelopeVersion: 2
~~~

共享 API 需要增加 scope 参数或等价的 typed wrapper；当前实现对应的调用形态是：

~~~text
CloudStore.pushTable('vncrecord')
CloudSyncCoordinator.requestVncTableAutomaticPush()
DataCrypto.encryptField('remotedesktop|vnc', 'vncrecord', recordId, 'ciphertext', value, schemaVersion, keyVersion, aadVersion)
~~~

没有 scope 的旧兼容入口只能继续服务既有 RDP/RustDesk/SSH 路径；VNC 新代码不得调用它。

## 5. 独立 VNC 设置页

### 5.1 页面和路由

新增独立 @Entry 页面，不放进 RustDesk relay page 的 sheet：

~~~text
entry/src/main/ets/pages/VncSettingsPage.ets
entry/src/main/ets/services/VncModelPolicy.ets
entry/src/main/ets/services/VncSettingsService.ets
entry/src/main/ets/model/VncRecord.ets
entry/src/test/VncRecordPolicy.test.ets
entry/src/main/resources/base/profile/main_pages.json
~~~

HostListPage 只增加一个“VNC 设置”入口，使用现有 router 进入 pages/VncSettingsPage。页面返回时不重置其他协议设置，也不触发 RDP/RustDesk/SSH 的重新加载。

### 5.2 页面管理的字段

默认值和可选范围由 VncModelPolicy 统一定义，Builder 不得自行猜默认值：

| 分组 | 设置 | 初始策略 |
| --- | --- | --- |
| 连接 | 默认 transport | direct_tcp |
| 连接 | 默认端口 | 5900，范围 1-65535 |
| 连接 | connect timeout | 10,000 ms；认证 15,000 ms；首帧 15,000 ms |
| 连接 | 空闲/刷新策略 | autorefresh=true，由 session 负责 request update |
| 显示 | view-only | 默认 true，避免新连接无意控制远端 |
| 显示 | scaling | fit / integer / one_to_one / pan |
| 显示 | encoding profile | safe_default，只启用已验证编码 |
| 交互 | 文本 clipboard | 默认关闭，按 session capability 开放 |
| 安全 | default security policy | 默认拒绝 None authentication；明文只允许用户明确开启 |
| 安全 | allow plaintext | 默认 false；开启时还必须满足 trusted LAN/VPN policy |
| 安全 | require TLS/VeNCrypt | 默认按 server capability 和用户策略拒绝不安全回退 |
| 安全 | trust/pinning | 默认首次连接询问，云同步 pin 不能自动信任 |
| 中继 | 默认 gateway | 仅引用 `vncrecord(recordtype=gateway).id`，不复制 token |
| 中继 | Repeater mode | viewer 使用 mode12；mode2 仅适用于独立 server-side listener，必须选择对应角色和目标配对策略 |
| 同步 | sync VNC preferences | 默认 true，可单独关闭 |
| 同步 | sync VNC secrets | 默认 false，开启前要求 master crypto ready 和二次确认 |
| 同步 | sync trust/pinning | 默认 false；开启后仍要求新设备确认 |

页面必须明确区分三种状态：

1. 设置已保存：只代表 RDB/Preferences 写入成功。
2. 云同步已选择：只代表用户选择了 VNC 表，不代表密钥已上传。
3. 连接可用：必须由 VNC native engine 和当前 capability 确认。

### 5.3 设置隔离规则

新页面不得读取、写入或监听以下值：

~~~text
rdpAudioEnabled
rdpClipboardEnabled
rdpControlMode
rdpAuthIdentityMode
rustdeskReverseWheel
rustdeskImageQuality
rustdeskCodec
rustdeskPrivacyMode
rustdeskControlMode
usersettings.payload
~~~

AppStorage 如继续使用，只能作为短期 UI mirror；真实保存必须由 VncSettingsService 写入
`vncrecord(recordtype=settings)`。页面销毁、进后台或切换 tab 不能把内存镜像反写为其他协议设置。

### 5.4 现有 VNC relay UI 迁移

现有 RustDeskRelayPage 中的 VNC card、VNC edit sheet 和相关计数不得在最终版本继续作为 VNC owner。迁移顺序：

- [x] 新页面和 VncGatewayService 已可读写独立的 VNC owner 数据。
- [x] VncRelayConfigService 已变为旧 Preferences 的一次性迁移 facade，不再持有最终可变 relay 集合。
- [x] ModernRelayAddFlow 的 VNC 分支已移除；RustDesk 分支继续独立运行。
- [x] RustDeskRelayPage 已删除 VNC UI 和 VNC owner import，只保留 RustDesk relay。
- [x] 旧 VNC Preferences 只有在完整迁移成功后清除；失败时保留旧输入并不上传明文。

## 6. VNC 主机、网关和会话模型

### 6.1 模型边界

实际落地使用一个独立行模型，通过 `recordType` 区分五类逻辑记录：

~~~text
entry/src/main/ets/model/VncRecord.ets
entry/src/main/ets/services/VncModelPolicy.ets
entry/src/main/ets/services/VncRecordPolicy.ets
~~~

VncHost 不继承 RemoteHost，也不复制 RDP/RustDesk/SSH 字段。连接页接收 VncSessionConfig，由 VNC service 从 VNC owner 组装，不能让 RemoteDesktop 通过通用 password 字段猜协议。

### 6.2 VNC session 状态

~~~text
IDLE
  -> RESOLVING
  -> CONNECTING
  -> PAIRING              (仅 Repeater/gateway)
  -> RFB_VERSION
  -> SECURITY_NEGOTIATION
  -> AUTHENTICATING
  -> SERVER_INIT
  -> RUNNING
  -> CLOSING
  -> DISCONNECTED / FAILED
~~~

每次 session 都有随机 sessionId 和递增 generation。所有 native 回调、frame callback、clipboard event、surface event、重连任务都必须核对 generation；旧 session 的事件不得进入新 session。

## 7. 完整中继设计

### 7.1 通用 transport 契约

新增项目自有接口，第三方 socket 类型不越过 transport：

~~~text
IVncTransport
  open(endpoint, timeout, cancelToken)
  readExact(buffer, length, deadline)
  writeAll(buffer, length, deadline)
  flush()
  peerInfo()
  isEncrypted()
  close(reason)

IVncGatewayPairer
  pair(transport, gatewayConfig, targetSecret, deadline)
  result(): { targetMatched, mode, peerFingerprint, error }
~~~

强制行为：

- readExact 处理短读、EOF、超时和取消；不得把一次 read 当成完整 preamble。
- writeAll 处理短写和背压；不得在 UI 线程直接 write。
- disconnect() 必须唤醒阻塞 read，并在固定 join deadline 内结束 worker。
- 建立 RFB 前必须完成 gateway pairing；pairing 失败不能被误报为 RFB auth failure。
- relay 只转发有界二进制流；不得在日志中记录密码、token、RFB payload 或剪贴板正文。

### 7.2 直连 TCP

DirectTcpTransport 是 M1 唯一 transport：

- 默认 host/port 来自 VncHost，port 默认 5900。
- DNS、IPv4/IPv6、connect timeout、socket close 和后台恢复遵守 HarmonyOS Socket 官方约束。
- 明文 VNC 只在安全 policy 明确允许时连接；“能连上”不能覆盖用户的 TLS/明文策略。
- 首次连接、server name、协商 security type、认证失败原因都归一化为 VNC error code。

### 7.3 UltraVNC Repeater mode 12 / mode 2

两种 mode 必须实现为两个独立的 parser/fixture，并明确 viewer/server-side 角色，不允许 if (mode) 分支里拼接未经验证的字符串：

- UltravncMode12Pairer：依据固定 commit 的 mode12_listener.cpp 行为实现 viewer/server 端 target pairing。
- UltravncMode2Pairer：依据固定 commit 的 mode2_listener_server.cpp 行为实现对应 server-side pairing。
- 每个 pairer 都要有明确角色、target ID/token、preamble 长度、字符编码、终止条件、服务端响应和错误码。
- preamble 使用 pinned upstream test vector；长度必须由解析器常量和测试向量共同验证，不使用“读到换行”替代固定长度读取。
- pairing 成功后，transport 只保留 opaque byte stream；RFB version greeting 必须从 pairing parser 输出之后开始。
- target ID 如果只是公开路由提示可在 gateway payload 的非敏感 label；如果具有访问能力、可猜测或短期有效，必须放到 `vncrecord(recordtype=secret, secretkind=repeater_token)`。
- Repeater 本身不提供端到端加密保证。若 RFB 层没有 TLS/VeNCrypt，页面必须显示“中继只转发、链路仍可能是明文”的安全状态。
- pairing timeout、target not found、target busy、gateway refused、server EOF、重连和用户取消必须分别统计。

mode 12/mode 2 的协议验收不能只用“两个设备最终能看到画面”：必须先用 scripted byte fixture 验证每一个字节和边界；当前 HarmonyOS viewer 只做 mode12 的真实透明转发，mode2 需要单独部署 server-side listener 后再验收。

### 7.4 WebSocket gateway

WebSocket gateway 是不同于 UltraVNC Repeater 的协议：

- 连接地址必须是 wss://，除非用户显式开启 trusted LAN 的 ws://。
- 只接受 binary message；text message、未知 control message 和超限 frame 立即关闭。
- 明确定义 gateway hello、认证、target selection、RFB stream、ping/pong、close code 和版本号。
- gateway token 只从 VncSecretService 解密到短生命周期内存；不放入 URL query 或日志。
- 需要有最大 frame size、累计接收上限、backpressure、idle timeout 和 cancel path。
- TLS certificate fingerprint 进入 VncTrustService，云同步 pin 只作为待确认候选，不自动信任。

需新增协议文档：

~~~text
docs/VNC_GATEWAY_PROTOCOL.md
~~~

该文档在没有后端确认前只能标记 draft；服务端不存在或契约未锁定时，public_relay 和 WebSocket gateway 不得开启。

### 7.5 公网 relay 和 SSH tunnel

公网 relay 必须具备：版本化 endpoint、account scope、gateway access token、target allocation、连接过期时间、TLS、审计 ID、最大连接数、关闭原因和服务端错误码。不能直接把 VncGateway.kind=public_relay 当成普通 host/port。

SSH tunnel 必须由独立 VncSshTunnelTransport 调用独立 SSH tunnel service：

- SSH username、private key reference、passphrase、host-key fingerprint 各自绑定到 VNC gateway owner。
- 不复用 SSH terminal 的 channel buffer、RDP gateway 字段或 RustDesk relay key。
- SSH 隧道只负责提供本地 loopback/stream，RFB 仍由 VNC engine 解析。
- 任一 SSH host-key 未确认时不建立 VNC session。

reverse/listen mode 只有在有明确 server-side protocol、端口暴露策略、身份绑定和 HarmonyOS 后台限制评估后才加入。没有这些条件时必须在 capability 中标为 unavailable。

## 8. 五类逻辑记录的完整设计

本节 8.2-8.6 保留了最初拆表方案的业务字段清单，作为逻辑记录设计和字段审计参考；它们不是云端表名，也不能按五张表部署。实际部署只有第 0.1 节列出的 `vncrecord` 19 列，代码通过 `recordtype` 映射 settings/host/gateway/secret/trust。若本节历史清单与第 0.1 节冲突，以第 0.1 节和 `VncRecordPolicy.ets` 为准。

### 8.1 统一字段规则

- 表名和字段名全部使用当前工程的无下划线约定；AGC 云空间类型使用 String/Integer，本地 RDB 使用 TEXT/INTEGER。
- Boolean 使用 0/1，时间使用毫秒 Unix epoch，版本使用非负整数，SHA-256 使用小写十六进制字符串。
- 每条逻辑记录的 id 都是端侧去重主键。业务实体 ID 使用 CryptoArchitectureKit 安全随机值；不能只用时间戳作为唯一依据。`recordtype=settings` 的单例记录可以在账号 scope 内由本地稳定映射保持幂等，但不能包含账号密码或可推导密钥。
- userid 是稳定的华为账号 scope，不使用设备 ID 代替，不在无账号 scope 时把数据写成全局记录。
- syncversion、schemaversion、updatedat、deletedat 都由 service 维护；删除使用 tombstone，deletedat=0 表示未删除。
- 云端不保存健康、延迟、最后连接、帧缓存、剪贴板历史或 active session。
- 所有写入先经过表字段白名单；未知列、错误 scope、错误 envelope 或错误 owner 都 fail closed。

### 8.2 `vncrecord(recordtype=host)`：VNC 主机非敏感描述

用途：保存可跨设备恢复的 VNC 主机描述和显示偏好，不保存 VNC password、target token 或私钥。

| 字段 | 类型 | 必填/默认 | 说明 |
| --- | --- | --- | --- |
| id | String/TEXT | 主键 | 随机 VNC host ID |
| userid | String/TEXT | 必填 | 华为账号 scope |
| label | String/TEXT | 必填 | 用户显示名称 |
| host | String/TEXT | 必填 | 直连主机或 gateway 目标地址 |
| port | Integer | 5900 | 1-65535 |
| authmode | String/TEXT | vnc_password | vnc_password、macos_account、vencrypt、x509 |
| transportmode | String/TEXT | direct_tcp | direct_tcp、ultravnc_repeater、websocket_gateway、public_relay、ssh_tunnel |
| gatewayid | String/TEXT | 空 | 引用 `recordtype=gateway` 的 id，不是 token |
| viewonly | Integer | 1 | 0/1；新连接默认只读 |
| scalingmode | String/TEXT | fit | fit、integer、one_to_one、pan |
| encodingprofile | String/TEXT | safe_default | 只引用已审核 profile |
| clipboardmode | String/TEXT | off | off、text_send、text_receive、text_bidirectional |
| enabled | Integer | 1 | 是否允许出现在 VNC 列表 |
| isfavorite | Integer | 0 | 仅 UI 排序语义 |
| groupid | String/TEXT | 空 | VNC 自己的 group reference |
| sortorder | Integer | 0 | VNC 列表排序 |
| syncversion | Integer | 1 | 记录版本 |
| schemaversion | Integer | 1 | 行格式版本 |
| createdat | Integer | 当前时间 | 创建时间 |
| updatedat | Integer | 当前时间 | 最后修改时间 |
| deletedat | Integer | 0 | tombstone 时间 |

禁止加入：username、password、passward、rdpcredentialid、rustdeskrelayid、sshkeyid、gatewayhost、RDP certificate 字段、SSH host key 字段和健康字段。

### 8.3 `vncrecord(recordtype=gateway)`：Repeater/gateway 非敏感配置

| 字段 | 类型 | 必填/默认 | 说明 |
| --- | --- | --- | --- |
| id | String/TEXT | 主键 | 随机 gateway ID |
| userid | String/TEXT | 必填 | 华为账号 scope |
| kind | String/TEXT | 必填 | ultravnc_repeater、websocket_gateway、public_relay、ssh_tunnel |
| host | String/TEXT | 必填 | gateway host/DNS |
| port | Integer | 按 kind | Repeater 常见端口由用户填写；不得默认为 RDP 443 |
| tlsmode | String/TEXT | required | required、opportunistic、disabled_lan_only |
| serverrole | String/TEXT | viewer | viewer、server、bidirectional |
| targetmode | String/TEXT | none | none、numeric_id、opaque_token、allocated_target |
| targetlabel | String/TEXT | 空 | 只存用户可见的非敏感标签；不存可用 token |
| certificatefingerprintsha256 | String/TEXT | 空 | 已确认或待确认的证书指纹 |
| enabled | Integer | 1 | 是否可被选择 |
| syncversion | Integer | 1 | 记录版本 |
| schemaversion | Integer | 1 | 行格式版本 |
| createdat | Integer | 当前时间 | 创建时间 |
| updatedat | Integer | 当前时间 | 最后修改时间 |
| deletedat | Integer | 0 | tombstone 时间 |

targetId 若只是公开路由提示可在 gateway payload 作为非敏感 label；任何拥有访问能力、短期有效或可猜测后直接接入目标的值都必须进入 `recordtype=secret`。

### 8.4 `vncrecord(recordtype=secret)`：VNC 敏感值

这类记录不允许任何明文 secret 列。ciphertext 必须是 VNC envelope v2；在 crypto locked、账号 scope 不匹配或 AAD 不匹配时不能解密使用。

| 字段 | 类型 | 必填/默认 | 说明 |
| --- | --- | --- | --- |
| id | String/TEXT | 主键 | 随机 secret record ID |
| userid | String/TEXT | 必填 | 华为账号 scope |
| ownerid | String/TEXT | 必填 | `recordtype=host` 或 `recordtype=gateway` 的 id |
| ownertype | String/TEXT | 必填 | host 或 gateway |
| secretkind | String/TEXT | 必填 | vnc_password、repeater_target_token、gateway_access_token、client_certificate_reference、client_private_key_reference；后续可扩展 vnc_username |
| ciphertext | String/TEXT | 必填 | 仅 envelope v2 密文 |
| envelopeversion | Integer | 2 | 当前必须为 2 |
| cryptoversion | Integer | 2 | VNC crypto contract 版本 |
| keyversion | Integer | 1 | DEK/key version |
| aadversion | Integer | 1 | AAD contract 版本 |
| syncversion | Integer | 1 | 记录版本 |
| schemaversion | Integer | 1 | 行格式版本 |
| createdat | Integer | 当前时间 | 创建时间 |
| updatedat | Integer | 当前时间 | 最后修改时间 |
| deletedat | Integer | 0 | tombstone 时间 |

禁止：password、token、secret、privatekey 等 plaintext 字段；禁止把密码塞进 ownerid、targetlabel、usersettings.payload 或 remotehosts.passward。

### 8.5 `vncrecord(recordtype=settings)`：VNC 独立全局设置

| 字段 | 类型 | 必填/默认 | 说明 |
| --- | --- | --- | --- |
| id | String/TEXT | 主键 | VNC settings singleton record |
| userid | String/TEXT | 必填 | 华为账号 scope |
| defaulttransportmode | String/TEXT | direct_tcp | 默认 transport |
| defaultport | Integer | 5900 | 默认连接端口 |
| defaultviewonly | Integer | 1 | 默认只读 |
| defaultscalingmode | String/TEXT | fit | 默认缩放 |
| defaultsecuritypolicy | String/TEXT | require_safe_auth | 明文/TLS/VeNCrypt 策略 |
| defaultencodingprofile | String/TEXT | safe_default | 默认编码 profile |
| defaultclipboardmode | String/TEXT | off | 默认文本剪贴板策略 |
| connecttimeoutms | Integer | 10000 | 连接超时 |
| autorefresh | Integer | 1 | 是否自动请求 framebuffer update |
| syncpreferences | Integer | 1 | VNC 设置同步意图 |
| syncsecrets | Integer | 0 | VNC secret 云同步意图，仍需本机显式确认 |
| synctrust | Integer | 0 | trust/pinning 云同步意图 |
| schemaversion | Integer | 1 | 行格式版本 |
| syncversion | Integer | 1 | 记录版本 |
| createdat | Integer | 当前时间 | 创建时间 |
| updatedat | Integer | 当前时间 | 最后修改时间 |
| deletedat | Integer | 0 | tombstone 时间 |

`recordtype=settings` 只保存偏好，不保存密码、token、account password、TLS private key、运行时 session 状态或健康状态。

### 8.6 `vncrecord(recordtype=trust)`：TLS/VeNCrypt/pinning 信任记录

| 字段 | 类型 | 必填/默认 | 说明 |
| --- | --- | --- | --- |
| id | String/TEXT | 主键 | 随机 trust record ID |
| userid | String/TEXT | 必填 | 华为账号 scope |
| hostid | String/TEXT | 可选 | `recordtype=host` 的 id |
| gatewayid | String/TEXT | 可选 | `recordtype=gateway` 的 id |
| fingerprintsha256 | String/TEXT | 必填 | 证书 SHA-256 指纹 |
| certsubject | String/TEXT | 可选 | 展示信息，不能作为唯一信任依据 |
| certissuer | String/TEXT | 可选 | 展示信息 |
| trustmode | String/TEXT | accepted | accepted、pin、revoked |
| trustedat | Integer | 0 | 用户确认时间 |
| expiresat | Integer | 0 | 0 表示不设置过期，但 policy 可强制过期 |
| revokedat | Integer | 0 | 吊销时间 |
| syncversion | Integer | 1 | 记录版本 |
| schemaversion | Integer | 1 | 行格式版本 |
| createdat | Integer | 当前时间 | 创建时间 |
| updatedat | Integer | 当前时间 | 最后修改时间 |
| deletedat | Integer | 0 | tombstone 时间 |

云端下发的 fingerprint 不能自动变成 pin。新设备首次使用同步 trust 时必须显示 host/gateway、subject、issuer、fingerprint 和来源设备，让用户重新确认；冲突默认拒绝自动合并。

### 8.7 明确不进入云端的表/数据

以下内容设备本地或 session 临时保存，不注册到 setDistributedTables：

~~~text
vncconnections
vncdiagnostics
vnchealthobservations
vncframecache
vncactive_sessions
vncclipboard_history
vncnetwork_probe_cache
~~~

健康、latency、lastConnected、server framebuffer、临时 pairing response、剪贴板历史和连接日志都不参与云冲突。

## 9. 云同步组件升级

### 9.1 组件变更矩阵

| 组件 | 升级内容 | 兼容要求 |
| --- | --- | --- |
| CloudTableAdapter.ets | 保持旧表白名单；VNC 使用 `vncrecord` 的 recordtype/字段白名单、project/normalize、未知字段拒绝 | VNC 字段不得进入 remotehosts；旧协议投影结果不变 |
| CloudStore.ets | 建一个 `vncrecord` 表和本地 `vnclocalrecords` 镜像、迁移、注册 distributed table、VNC CRUD、scope 回调、VNC reset marker | 旧七张表的 SQL、同步顺序和 callback 语义不回归 |
| CloudSyncPolicy.ets | 增加 scope-aware table order 和 VNC selection expansion | 既有全量同步不自动包含 VNC secrets |
| VncCloudSyncSelectionPolicy.ets / VncCloudSyncSelectionStore.ets | 增加 VNC 专属 selection group 和 crypto dependency | 没有选择 `recordtype=secret` 时不拉取/上传 secret 行 |
| CloudSyncSelectionStore.ets | 新增 vncCloudSyncSelectedTables，与旧 cloudSyncSelectedTables 分开 | 旧选择器的值不能控制 VNC |
| CloudSyncCoordinator.ets | request scope、request ID、per-scope progress、VNC retry key、secret consent gate | 既有 RDP/RustDesk/SSH retry 不改变；空快照保护继续有效 |
| CloudSyncCoordinatorPolicy.ets | VNC error kind、冲突、tombstone、selection snapshot、reset epoch policy | 失败原因不泄露密文或 token |
| CloudSyncService.ets | VNC 维持明确排除；增加静态/架构测试证明没有 VNC caller | 不做 REST 双写，不改现有 endpoint 行为 |
| DataCrypto.ets | 增加 VNC v2 envelope、AAD、key version、locked fail-closed、迁移和 reset hook | RDP/RustDesk/SSH/TOTP v1 继续可解密 |
| LocalBackupPolicy.ets | 增加 VNC 表和敏感字段策略；默认不导出明文 VNC secret | 现有备份兼容；VNC secret 需二次确认和重新解锁 |
| HostSyncService.ets | 只保留既有协议；不解析 VNC 表；改为接收只读 unified projection（如需要） | 不因 VNC cloud event 重载或清空其他协议 |
| HostListPage.ets | VNC 入口、VNC projection、独立设置 route | 不把 VNC 表写回 RemoteHost |
| RustDeskRelayPage.ets | 删除 VNC card/form/import | RustDesk relay UX 和云数据不变 |

### 9.2 正式同步顺序

当 VNC scope 被选中时，顺序固定为：

~~~text
cryptoparams (仅 secrets/trust policy 需要时)
  -> vncrecord(recordtype=settings/host/gateway/secret/trust)
~~~

与既有协议同时同步时，执行器先按每个 scope 冻结 selection snapshot，再按全局依赖顺序逐表执行。不能用时间戳决定 cloud-first/native-first 方向：

- 启动恢复、云事件确认后的下载、手动下载：cloud-first。
- 本地编辑后的自动 push、用户明确确认的手动上传：native-first。
- 云端空快照、账号不匹配、解密失败、selection 变化或墓碑清理失败时，不得清空本地 VNC。

### 9.3 VNC 专属选择和用户确认

新增本地 preference key：

~~~text
vncCloudSyncSelectedTables
~~~

可选逻辑范围：settings、hosts、gateways、secrets、trust；物理上传/下载始终通过 `vncrecord`，不能把逻辑范围误报成五张云表。建议 UI 提供三个预设：

- 仅设置：只同步 `recordtype=settings`。
- 配置：同步 settings、hosts、gateways，不同步 secrets/trust。
- 完整 VNC：在用户重新解锁 master crypto 并确认风险后，才允许加入 secrets；trust 仍需要新设备二次确认。

普通“上传全部”不能隐式加入 `recordtype=secret`。普通“下载全部”不能隐式覆盖本地 VNC secrets。VNC 的上传、下载、删除、reset 需要独立的 VNC confirmation sheet 和 scope-specific progress。

### 9.4 VncCloudSyncService

新增：

~~~text
entry/src/main/ets/services/VncCloudSyncService.ets
entry/src/main/ets/services/VncCloudSyncSelectionPolicy.ets
entry/src/main/ets/services/VncCloudSyncSelectionStore.ets
~~~

服务负责：

- `vncrecord` 内 settings、host、gateway、secret、trust 五类记录的 CRUD。
- 启动 cloud-first restore 和本地缓存恢复。
- 手动 native-first upload、cloud-first download。
- VNC-specific table selection、request ID、retry/journal 和 per-table progress。
- cloud apply 后只通知 VncHostService、VncSettingsService、VncGatewayService、VncTrustService。
- VncSecretService 只有在 crypto ready 和用户明确允许时才 apply plaintext 到内存；locked 时保留密文和 redacted model。
- 云端空 snapshot 不清空本地；恢复失败必须 rollback 当前 VNC scope 的事务快照。

CloudStore 的通用 callback 要能携带 changed tables 或 scope；不能让当前 HostSyncService 无条件响应所有 VNC table 变化。若保留旧无参数 callback，必须增加新的 scoped callback 并让 VNC 只订阅新的接口。

### 9.5 冲突、删除和旧设备

- 每条记录使用 syncversion、updatedat、deletedat；删除只写 tombstone。
- tombstone 保留时间必须覆盖最长支持版本的离线周期，避免旧设备重新上传已删除记录。
- host/gateway 非敏感字段可按版本和更新时间做确定性合并，但合并结果要记录来源。
- `recordtype=secret` 冲突禁止静默覆盖；显示“设备 A/设备 B”两份 redacted metadata，用户解锁后选择。
- `recordtype=settings` 可按 syncversion 覆盖，但必须显示设备和时间来源；不能改其他协议 settings。
- `recordtype=trust` 冲突默认保留本地 pin 并要求重新确认；云端较新 fingerprint 不能自动取代本地 pin。
- deletedat、reset epoch、syncversion 都不能记录 secret plaintext。
- 账号切换、华为云空间不可用、云表未部署或数据格式不认识时，保留本地 VNC，不把数据归属到新账号。

## 10. 加密升级设计

### 10.1 当前 v1 兼容范围

当前 DataCrypto 使用 PBKDF2-SHA256 100,000 iterations、32-byte salt、AES-256-GCM、12-byte IV、16-byte tag，密文形态为：

~~~text
1:base64(iv):base64(ciphertext+tag)
~~~

当前 GCM AAD 为空，并且旧 v1 解密允许非密文格式作为明文兼容。该兼容行为只能保留在旧协议迁移边界；VNC 新数据不得使用明文 fallback。

### 10.2 VNC v2 API 和 envelope

可以新建 DataCryptoV2.ets，也可以在 DataCrypto.ets 中增加严格的 v2 API；最终选择以 API 23 编译和现有调用面最小为准。接口至少包含：

~~~text
encryptField(scope, table, recordId, fieldName, plaintext): string
decryptField(scope, table, recordId, fieldName, envelope): string
isV2Envelope(value): boolean
validateEnvelopeMetadata(scope, table, recordId, fieldName, envelope): boolean
~~~

V2 形态：

~~~text
2:<base64(canonical-header)>:<base64(iv)>:<base64(ciphertext+tag)>
~~~

header 至少包含：

~~~text
scope=remotedesktop|vnc
table=vncrecord
recordId=<record id>
field=ciphertext
algorithm=AES-256-GCM
keyVersion=1
aadVersion=1
~~~

GCM AAD 为 header 的 canonical UTF-8 表示，至少绑定：

~~~text
remotedesktop|vnc|<table>|<recordId>|<field>|<schemaVersion>
~~~

这样可以阻断把 VNC password 密文复制到 RustDesk key、把 gateway token 交换到另一个 VNC record、跨 field 重放和跨表字段替换。header 不能由解密方随意信任；必须先解析、规范化、核对 scope/table/record/field/schema，再用同样 AAD 验证 GCM。

### 10.3 密钥和锁定策略

- 初始 v2 可以复用已经解锁的 DEK，使用 keyVersion 记录版本；不要在没有迁移 UX 的情况下强迫用户重新输入 master password。
- 后续如采用每 scope 子密钥或 KDF 参数升级，必须通过 HarmonyOS API 23 可用性测试、独立 cryptoversion 和双版本解密，不得悄悄改变 RDP/RustDesk/SSH/TOTP v1。
- `recordtype=secret` 只接受 v2 envelope。envelopeversion != 2、AAD 不匹配、GCM tag 失败、key version 不支持时，记录不可用并返回明确错误；绝不能把密文当明文继续连接。
- crypto locked 时，VNC UI 只能显示 redacted 状态；用户可以临时输入密码建立一次连接，但不能写本地明文、Preferences 或云端。
- 解锁/锁定只通知 VNC secret service 刷新 redacted/decrypted memory；不通知 RDP/RustDesk/SSH service 改变协议设置。
- 日志只能记录 secretkind、record ID 的不可逆短摘要、envelope version 和失败类别；不能记录密文、AAD、明文或 token。

### 10.4 v1 -> v2 迁移

- VNC 新数据只写 v2。
- 现有 remotehosts.protocol=vnc 的 password 和旧 VncRelayConfig.targetId 不能被自动当作 VNC v2 密文；先读取、显示迁移范围、要求 crypto ready 和用户确认。
- 迁移顺序是：解锁 -> 建立 VNC owner -> v2 加密 -> 写入 `recordtype=secret` -> 事务校验 -> 写入迁移标记 -> 再清理旧明文副本。
- 任一步失败，保留旧本地数据并标记 pending；不上传新表、不删除旧值、不产生半成品 secret row。
- 迁移必须幂等、可重试、按 owner/secretkind 去重；重启不能重复创建 token。
- 现有 RDP/RustDesk/SSH/TOTP v1 迁移保持原流程；VNC 迁移不读取 rustdeskrelays.key、usersettings.payload 或非 VNC 的 remotehosts 行。

### 10.5 resetEncryption 扩展

DataCrypto.resetEncryption() 的 VNC 行为必须独立可审计：

- 删除/墓碑化本地 secret 行，清除 gateway secret、VNC password、client key reference 的可用内存值。
- 清理 VNC trust sync state 和未完成的 VNC retry/journal 中可能指向旧密文的可恢复内容。
- 在 cryptoparams 写入不含 secret 的 VNC reset epoch/marker，让其他设备拒绝旧 epoch 的 VNC 密文和旧 retry。
- 通知 VncCloudSyncService、VncSecretService、VncTrustService 清理内存；不让 HostSyncService 将 VNC reset 当成 RDP/RustDesk/SSH reset。
- 云端删除通过 tombstone 和 reset marker 完成，不能只清空当前设备。
- 重置完成后，不得存在旧密文仍可被解锁使用的路径；如果云端不可用，界面必须明确显示“本地已清除，云端删除待完成”，不能假报成功。

## 11. 旧数据和配置迁移

### 11.1 remotehosts.protocol=vnc 迁移

当前通用 host flow 可能已经产生 VNC RemoteHost 行。第一次启用新 VNC 数据域时执行受控迁移：

- [ ] 只扫描 remotehosts 中 protocol == vnc 的行；RDP、RustDesk、SSH 行不得被触碰。
- [ ] 只复制 VNC 通用非敏感字段到 `recordtype=host`：label、host、port、favorite、group、sort、created/updated 和经过校验的 display preference。
- [ ] RemoteHost.username/password/passward/gatewayHost/gatewayPort 不直接复制为 VNC credential；密码若要迁移必须经过用户确认和 v2 encryption。
- [ ] 原行成功迁移后写入明确的 legacy migration marker，VNC 列表隐藏原行；在兼容窗口结束前不物理删除，避免旧版本数据恢复造成丢失。
- [ ] 清理或 tombstone 原行中可能存在的 VNC password，避免旧版本继续把 VNC secret 上传到 remotehosts.passward。
- [ ] 迁移完成后，任何新建/编辑/删除 VNC 都不再写 remotehosts；旧行只作为可回滚的迁移审计残留。
- [ ] 若云端 remotehosts 没有可安全 tombstone 的能力，先升级旧表的兼容删除/过滤策略，再发布允许 VNC cloud sync 的版本；不能以物理删除代替云端冲突策略。

### 11.2 VncRelayConfigService Preferences 迁移

- [ ] 读取 VncRelayConfigs/relays 只用于一次性迁移。
- [x] name/host/port 建立 `recordtype=gateway`，transport 固定为 `ultravnc_repeater`。
- [x] targetId 根据 Repeater 语义分类；访问性目标进入加密 `recordtype=secret`，非敏感目标只作为用户确认的 gateway payload label。
- [ ] 迁移前检查 DataCrypto 状态；未解锁时不把 targetId 写入新的明文 RDB。
- [ ] 新记录云同步只有在用户选择 VNC gateway/secrets 后才发生；旧 Preferences 内容不自动上传。
- [ ] 新服务读写成功并经过重启校验后，才清理旧 Preferences；失败保留旧数据和 pending marker。

## 12. 文件级实施任务

以下任务是实际开发顺序和验收映射；代码项已实施的标为完成，依赖云端或真实设备的项目继续保留为待验收。

### Task 1：冻结 VNC namespace、隔离契约和 feature gate

预计文件：

~~~text
entry/src/main/ets/services/VncModelPolicy.ets
entry/src/main/ets/services/VncRecordPolicy.ets
entry/src/main/ets/services/VncGatewayProtocolPolicy.ets
entry/src/main/ets/services/RemoteSessionCapabilityPolicy.ets
entry/src/test/VncRecordPolicy.test.ets
entry/src/test/VncGatewayProtocolPolicy.test.ets
docs/VNC_GATEWAY_PROTOCOL.md
~~~

- [x] 已定义 protocol=vnc、scope、schema/envelope version、错误码和 capability 枚举。
- [x] feature gate 默认 fail closed；gate 失败原因可诊断但不显示为“连接成功”。
- [x] VNC service、VNC cloud projection 与其他协议 owner 的静态边界已落实；跨模块隔离仍需在真实设备回归中复核。
- [x] VNC cloud projection 只允许 `vncrecord` 字段，secret payload 禁止敏感明文。
- [x] gateway protocol draft 版本和未部署时的 unavailable 行为已固定。

完成标准：没有新的模型或页面可以在缺少 VNC scope 的情况下访问其他协议的状态。

### Task 2：定义五类 VNC record model 和本地 validation

预计文件：

~~~text
entry/src/main/ets/model/VncRecord.ets
entry/src/main/ets/services/VncModelPolicy.ets
entry/src/main/ets/services/VncRecordPolicy.ets
entry/src/test/VncRecordPolicy.test.ets
~~~

- [x] `VncRecord` 加 `VncModelPolicy`/`VncRecordPolicy` 只包含 VNC 字段和 VNC 专属校验。
- [x] port、timeout、transport、secret kind、trust payload 和布尔值做边界校验。
- [x] ID 使用 CryptoArchitectureKit 随机值；禁止时间戳-only ID。
- [x] `toJSON/fromJSON` 与 cloud row 转换只接受当前 VNC schema 和受控兼容值。
- [x] locked 状态下 secret service 只产生 redacted presence，不返回密文或明文。

完成标准：五类 VNC record 可独立序列化、校验、比较 revision，且不依赖 RemoteHost。

### Task 3：添加 VNC 云表、schema migration 和字段白名单

预计文件：

~~~text
entry/src/main/ets/services/CloudStore.ets
entry/src/main/ets/services/CloudTableAdapter.ets
entry/src/main/ets/services/CloudStoreMutationPolicy.ets
entry/src/main/ets/services/LocalBackupPolicy.ets
entry/src/test/VncRecordPolicy.test.ets
docs/superpowers/plans/2026-07-24-vnc-isolated-settings-cloud-upgrade.md
~~~

- [ ] 在 AGC 开发/测试容器创建唯一 `vncrecord` 表，勾选端侧去重主键 `id`，逐列核对第 0.1 节 schema。
- [x] createTables() 使用幂等 CREATE TABLE IF NOT EXISTS；当前 schema 在本地初始化时可重试。
- [x] setDistributedTables 注册 `vncrecord`，保持 autoSync=false，由 coordinator 显式协调。
- [x] CloudStore/VncRecordPolicy 为 `vncrecord` 建立完整 cloud/local columns 和 type conversion。
- [x] VNC 表 unknown column、wrong owner、wrong scope 和 wrong envelope 行在 VNC policy/CloudStore 边界被拒绝。
- [x] LocalBackupPolicy 加入 VNC 表和本地镜像，但默认不导出 plaintext VNC secrets。
- [ ] schema migration 失败时只关闭 VNC scope，不让旧七张表不可用。

完成标准：双 ABI 本地构建可启动，VNC 单表能创建/读取/按 recordtype 投影，旧七表 diff 不变；AGC schema 文档与实际字段逐列一致。

### Task 4：实现 DataCrypto v2、AAD 和 VNC secret service

预计文件：

~~~text
entry/src/main/ets/services/VncSecretService.ets
entry/src/main/ets/services/DataCrypto.ets
entry/src/test/VncRecordPolicy.test.ets
~~~

- [x] 在 DataCrypto.ets 实现 v2 header canonicalization、AAD 计算、AES-256-GCM encrypt/decrypt 和 key version。
- [ ] 覆盖 wrong scope/table/recordId/field/schemaVersion、tamper、wrong key、truncated envelope、unknown version、empty secret 和 Unicode secret。
- [x] v1 继续能被原有 RDP/RustDesk/SSH/TOTP 读取；VNC 只写 v2。
- [x] locked、reset、decrypt failure 均 fail closed，不返回密文作为明文。
- [x] secret memory 生命周期最短化，连接结束和 lock 时清除可用值。
- [x] 记录 `resetepoch`，本机和云端 reset 路径清理 VNC 密文、trust marker 和 retry；其他设备通过 reset 状态拒绝旧数据。

完成标准：通过 cross-table substitution test；将 VNC 密文复制到任意既有协议字段或另一个 VNC record 后解密必失败。

### Task 5：升级 CloudSyncPolicy、selection、coordinator 和恢复状态

预计文件：

~~~text
entry/src/main/ets/services/CloudSyncPolicy.ets
entry/src/main/ets/services/CloudSyncSelectionPolicy.ets
entry/src/main/ets/services/CloudSyncSelectionStore.ets
entry/src/main/ets/services/CloudSyncCoordinator.ets
entry/src/main/ets/services/CloudSyncCoordinatorPolicy.ets
entry/src/main/ets/services/CloudSyncSheetPolicy.ets
entry/src/test/CloudSyncPolicy.test.ets
entry/src/test/CloudSyncCoordinatorPolicy.test.ets
~~~

- [x] 增加 VNC table order、VNC scope、selection key 和 crypto dependency。
- [x] VNC request 使用独立入口、冻结的 VNC table list、direction、source 和 user confirmation gate。
- [x] retry key 按 VNC table/scope 分开；不会覆盖 RustDesk/RDP/SSH retry。
- [x] cloud-first empty snapshot、账号不匹配、墓碑清理失败和 crypto failure 不会自动清空本地 VNC。
- [x] secret upload/download 需要独立选择和 crypto 解锁；普通全量操作不自动包含 `recordtype=secret`。
- [x] progress 到 terminal SYNC_FINISH 前不得报告成功；VNC request 与 shared coordinator 使用独立结果状态。

完成标准：旧同步 policy 测试全部通过，VNC 选择变化不会改变旧表 selection；重启后 retry/journal 能按 VNC scope 恢复。

### Task 6：实现 VncCloudSyncService 和四个业务 service

预计文件：

~~~text
entry/src/main/ets/services/VncCloudSyncService.ets
entry/src/main/ets/services/VncHostService.ets
entry/src/main/ets/services/VncSettingsService.ets
entry/src/main/ets/services/VncGatewayService.ets
entry/src/main/ets/services/VncTrustService.ets
entry/src/main/ets/services/VncRelayConfigService.ets
entry/src/test/VncRecordPolicy.test.ets
~~~

- [x] 所有 CRUD 带 userid scope 和 `vncrecord` owner boundary。
- [x] 启动先保留本地缓存，再进行 cloud-first；云服务不可用不能把列表置空。
- [x] 云 apply 后只通知 VNC service，不触发 HostSyncService.loadFromCloud()。
- [ ] host/gateway 采用确定性 merge；secret 冲突保留两份候选并要求用户选择；trust 冲突要求重新 pin。
- [x] 删除使用 tombstone；VNC 物理镜像受本地/云选择边界控制。
- [x] reset 处理 VNC epoch、memory clear、retry clear 和 cloud tombstones。

完成标准：模拟空云、旧云、断网、账号切换、冲突、删除、重启和 locked 状态时，VNC 数据不丢且不串到其他协议。

### Task 7：独立 settings page 和 VNC gateway flow

预计文件：

~~~text
entry/src/main/ets/pages/VncSettingsPage.ets
entry/src/main/ets/services/VncModelPolicy.ets
entry/src/main/ets/services/VncGatewayProtocolPolicy.ets
entry/src/main/ets/pages/HostListPage.ets
entry/src/main/ets/pages/RustDeskRelayPage.ets
entry/src/main/ets/components/resourceadd/modern/ModernRelayAddFlow.ets
entry/src/main/ets/components/resourceadd/ResourceFabPicker.ets
entry/src/main/resources/base/profile/main_pages.json
entry/src/test/VncRecordPolicy.test.ets
entry/src/test/VncGatewayProtocolPolicy.test.ets
~~~

- [x] 已注册 pages/VncSettingsPage，使用 API 23 可用的 ArkUI 组件。
- [x] HostList 入口只导航到 VNC page；页面保存只调用 VncSettingsService。
- [x] gateway/repeater 编辑已从 RustDesk page 和 generic relay flow 移到 VNC flow。
- [x] 旧 VNC Preferences 只走 migration facade；新保存不再写 VncRelayConfigs。
- [x] 页面显示 plaintext/TLS/pinning/secret sync 风险状态，不显示虚假的“在线”。
- [x] 页面不持有可跨页面复用的 plaintext secret；secret service 只在加密解锁时 materialize。
- [x] 主设置页以独立顶层 VNC accordion 提供入口；入口只导航到完整 VNC page，不初始化云同步或其他协议的新增流程。
- [x] 全局关闭加密在发现活动 VNC v2 密文时 fail closed；不会清除 DEK 后留下不可恢复的 VNC 密码/令牌。
- [x] VNC 设置保存先提交 logical scope 边界再写 `recordtype=settings`；保存失败会恢复旧 scope，避免关闭同步时先把新设置推到云端。

完成标准：RDP/RustDesk/SSH settings snapshot 在打开、编辑、保存 VNC settings 前后完全相同；RustDesk page 不再包含 VNC owner。

### Task 8：接入真实 RFB native engine

实际实现为自有、边界受限的 RFB/transport engine；当前没有把 LibVNCClient 第三方类型引入工程：

~~~text
entry/src/main/cpp/vnc/vnc_transport.h/.cpp
entry/src/main/cpp/vnc/vnc_rfb_engine.h/.cpp
entry/src/main/cpp/vnc/vnc_des.h/.cpp
entry/src/main/cpp/vnc/vnc_adapter.h/.cpp
entry/src/main/cpp/extensions/protocol_adapter.h
entry/src/main/cpp/extensions/extension_loader_napi.cpp
entry/src/main/cpp/CMakeLists.txt
~~~

- [x] 不引入未审计的 LibVNCClient 二进制或第三方 RFB 类型；native 依赖边界保持在现有工程。
- [x] direct TCP 支持版本协商、security allowlist、VNC password、ServerInit、Raw/CopyRect、BGRA、首帧、resize、键鼠、view-only。
- [x] 最大宽高、总像素、矩形面积、编码数据长度和乘法全部有界检查。
- [x] framebuffer callback 在 native 内完成稳定存储；通过 raw BGRA 入口，不进入视频 decoder。
- [ ] surface detach/attach、前后台、主动 disconnect、connect timeout、首帧 timeout 和旧 generation 全部有测试。

完成标准：真实 macOS VNC server 在 direct TCP 下通过双 ABI HAP、键鼠和断连/重连验收；其他三个协议的 renderer/decoder 行为无 diff。

### Task 9：实现 UltraVNC Repeater transport

预计文件：

~~~text
entry/src/main/cpp/vnc/vnc_transport.h/.cpp
entry/src/main/cpp/vnc/vnc_transport_policy.h
entry/src/main/cpp/test/vnc_transport_policy_test.cpp
docs/VNC_GATEWAY_PROTOCOL.md
~~~

- [x] 固定 mode12 viewer 以及 mode2 server-side 的字节/角色边界，并在 `docs/VNC_GATEWAY_PROTOCOL.md` 中记录版本和字段契约。
- [x] pairing 成功前不调用 RFB engine；成功后只交付 transport byte stream。
- [x] target secret 从 VncSecretService 获取，日志和诊断只显示 redacted target reference。
- [ ] 实机用 UltraVNC Repeater viewer/server 双端验证 mode12 配对、桌面显示、键鼠、断连和重连；mode2 需另行部署并验收 server-side listener，不能由当前 HarmonyOS viewer 代替。
- [x] Repeater 明文/TLS 状态映射到 VNC security policy；拒绝不安全回退时返回明确错误。

完成标准：mode12 和 mode2 不能互相误解析；重复连接、目标不在线和中继重启都不会卡住 UI 或残留旧 session。

### Task 10：实现 WebSocket/public relay/SSH transport gate

预计文件：

~~~text
entry/src/main/cpp/vnc/vnc_transport.h/.cpp
entry/src/main/ets/services/VncGatewayProtocolPolicy.ets
entry/src/test/VncGatewayProtocolPolicy.test.ets
~~~

- [ ] 先完成 docs/VNC_GATEWAY_PROTOCOL.md 的 endpoint/version/auth/close/heartbeat 契约，再写客户端。
- [ ] WebSocket 只接受 binary，具备 frame/byte/idle/backpressure 上限；只在 wss 或可信 LAN policy 下允许 ws。
- [x] public relay 没有正式 endpoint 时运行时 unavailable，不提供假连接。
- [ ] SSH tunnel 使用独立 SSH credential/trust owner；不得复用 SshTerminal channel state。
- [x] 每种 transport 单独 capability、错误码和运行时 gate；真实环境仍待部署后验收。

完成标准：每种 transport 的成功路径、协议版本不兼容、token 失效、TLS pin 变化、网络中断和用户取消都能单独诊断。

### Task 11：统一列表只读投影和连接路由

预计文件：

~~~text
entry/src/main/ets/services/UnifiedHostProjectionService.ets
entry/src/main/ets/services/VncHostService.ets
entry/src/main/ets/pages/HostListPage.ets
entry/src/main/ets/pages/RemoteDesktop.ets
entry/src/main/ets/services/RemoteSessionCapabilityPolicy.ets
entry/src/test/UnifiedHostProjection.test.ets
~~~

- [ ] VNC list item 使用 VncHostRef，不把 VNC model cast 成 RemoteHost。
- [ ] 统一列表只读取 VNC service；编辑、删除和连接回到 VNC owner。
- [ ] RemoteDesktop 接收 typed VNC session params，禁止从通用 username/password/gatewayHost 猜 VNC 配置。
- [ ] capability 来自 RFB/gateway handshake 和本地 policy 的交集；view-only 时控制按钮关闭。
- [ ] 旧 VNC RemoteHost migration marker 行不再出现在列表。

完成标准：同一 VNC host 从统一列表、VNC page、重新启动和云恢复进入的结果一致，且 RDP/RustDesk/SSH 列表签名不变。

### Task 12：双设备云同步、备份恢复和发布门

预计文件：

~~~text
docs/AGC_VNC_CLOUD_SCHEMA.md
docs/VNC_CLOUD_SYNC_RUNBOOK.md
docs/VNC_SECURITY_TEST_MATRIX.md
docs/VNC_RELEASE_CHECKLIST.md
entry/src/test/*Vnc*.test.ets
~~~

- [ ] AGC 测试容器逐列核对唯一 `vncrecord` 表、去重主键、String/Integer 类型和发布状态。
- [ ] 两台 HarmonyOS API 23 设备使用同一华为账号，分别验证 settings/hosts/gateways/secrets/trust 的选择矩阵。
- [ ] 验证 cloud-first 空库恢复不会反向覆盖云端，native-first 上传需要确认且不隐式上传 secrets。
- [ ] 验证 master password lock/unlock/reset、错误密码、旧设备、账号切换、断网重试和 tombstone retention。
- [ ] 验证 HAP 双 ABI、ArkTS 编译、native test、静态隔离、git diff --check 和许可证/SBOM。

完成标准：所有发布门通过，VNC 可独立回滚/关闭，其他三个协议的既有测试和实机回归全部通过。

## 13. 测试和验收矩阵

### 13.1 隔离测试

- [ ] VNC settings 保存前后 RDP/RustDesk/SSH settings snapshot byte-for-byte 不变。
- [ ] VNC CRUD 不调用 HostSyncService，不触发 remotehosts、rustdeskrelays、usersettings 写入。
- [ ] VNC cloud event 只刷新 VNC service；其他协议内存 map 和 UI revision 不变化。
- [ ] RustDesk relay page 不再创建、编辑或删除 VNC gateway。
- [ ] 普通 cloud upload/download 不包含 VNC tables；VNC 完整同步也不包含其他协议表，除按依赖需要的 cryptoparams。
- [ ] old VNC migration 只匹配 protocol=vnc，不会把 RDP/RustDesk/SSH 行迁移为 VNC。

### 13.2 加密测试

- [ ] v2 round trip：ASCII、Unicode、空值、长值和随机值。
- [ ] 改动 scope/table/recordId/field/schemaVersion/header、ciphertext、IV、tag 任一项都解密失败。
- [ ] 将 `recordtype=secret` ciphertext 放入 RDP credential、RustDesk key、SSH private key 或另一个 VNC owner 后均失败。
- [ ] locked 时不能连接已保存 secret，除非用户在本次 session 中临时输入；临时值不落盘。
- [ ] reset 后本机和第二台设备都不能继续使用旧 VNC secret；云端不可用时显示 pending，不假报完成。
- [ ] crash/restart 在迁移的每个事务点都能恢复，不产生明文副本或重复 secret row。

### 13.3 云同步测试

- [ ] 首次新设备 cloud-first 恢复 settings/hosts/gateways。
- [ ] 未选择 `recordtype=secret` 时，空的 VNC secrets 不覆盖本地已保存临时配置。
- [ ] 选择 secrets 但 crypto locked 时阻止 apply，保留 ciphertext 和待解锁状态。
- [ ] 云端空 snapshot、错误账号、云表未部署、网络超时、progress 非 terminal success 都不能清空本地。
- [ ] 同一 record 双设备编辑：host 可确定性合并，secret 进入用户冲突，trust 要求重新 pin。
- [ ] 删除在离线设备、旧版本设备、恢复和重试后不会复活。
- [ ] 选择变化后，旧 retry 不会上传已取消的 VNC table。

### 13.4 Relay/RFB 测试

- [ ] Direct TCP RFB 3.3/3.7/3.8 handshake、VNC password、Raw/CopyRect、首帧和 incremental update。
- [x] Repeater mode12 viewer / mode2 server-side byte-exact pairing、target mismatch、短读/短写、timeout、cancel、server EOF 的本地 fixture；真实 mode12 仍待端点验收，mode2 仍待 server-side 组件验收。
- [ ] WebSocket binary-only、ping/pong、oversize、text frame、token failure、TLS pin change、backpressure。
- [ ] RFB password authentication 与 gateway token authentication 分开，错误原因不混淆。
- [ ] view-only 不发送 pointer/key；断开时清理 pressed-state 和 clipboard event。
- [ ] surface detach/attach、前后台、网络切换、重复 connect、快速 disconnect 和旧 generation callback。

### 13.5 HarmonyOS 和发布测试

- [ ] API 23 ArkTS compile，不引用 API 26 UI component。
- [ ] arm64-v8a 和 x86_64 native build、HAP assemble、ABI artifact hash。
- [ ] native worker 不直接触碰 ArkTS/JS object；N-API callback 全部走 thread-safe dispatch。
- [ ] socket/WebSocket 在前后台、surface destroy、window close 和 process restart 下没有永久阻塞。
- [ ] 旧版安装升级、旧版回滚后再次启动、新版 feature gate 关闭时数据仍可读且无跨协议污染。
- [ ] NOTICE、GPL/LibVNCClient、SBOM、provenance 和安全公告处理记录完整。

## 14. 迁移、发布和回滚策略

### 14.1 发布顺序

1. 在 AGC 测试容器创建唯一 `vncrecord` 表并验证 schema，不发布功能开关。
2. 发布只包含模型、schema、crypto v2 和 disabled services 的内部构建；验证旧七表不变。
3. 发布独立 VNC settings page，但默认连接 gate 关闭；验证 Preferences 迁移和页面隔离。
4. 开启 VNC cloud settings/hosts/gateways 同步，不开启 secrets。
5. 经过双设备和安全门后，按用户确认开启 VNC secrets 同步。
6. 开启 direct RFB，再按 gateway 类型逐个开启 Repeater、WebSocket、public relay、SSH tunnel。
7. 清理旧 VncRelayConfigService 的 owner 角色和 RustDesk page 中的 VNC UI；保留只读兼容迁移代码直到旧版本支持窗口结束。

### 14.2 回滚

- [x] VNC runtime gate 可单独关闭；关闭只阻止新连接和新 VNC sync，不删除 VNC host/gateway 逻辑记录或加密数据。
- [ ] schema 采用 additive migration；已有 VNC 云表不能在生产中直接删除或重命名。
- [ ] DataCrypto v2 永远保留双读兼容；代码回滚到不认识 v2 时，VNC secret 显示 locked/unavailable，不能按明文处理。
- [ ] cloud sync 异常时按 VNC scope 熔断，不熔断 RDP/RustDesk/SSH 的同步队列。
- [ ] relay endpoint 异常时仅禁用对应 gateway kind/record，不把 gateway failure 映射为 VNC host deletion。
- [ ] 旧 Preferences 和 legacy VNC row 只有在新记录加密、重启、云恢复和用户确认都成功后才清理；回滚窗口内保留可恢复 marker。
- [ ] 回滚验证必须包括“新版写入 v2 后旧版启动”的行为：旧版不得显示或上传 VNC secret，不得清空其他协议数据。

## 15. 最终完成门

只有以下条件全部满足，才可以把 VNC 标记为可用：

- [ ] VNC 有独立 page、model、service、cloud selection、secret service、trust store 和 session；没有以 RDP/RustDesk/SSH service 作为 owner。
- [ ] remotehosts、rustdeskrelays、usersettings 没有新增 VNC 业务字段，新建 VNC 数据不写这些表。
- [ ] 唯一 `vncrecord` 云表已经在 AGC 逐列创建、注册、同步和双设备验证；secret recordtype 不在普通全量同步中。
- [ ] VNC secret 全部使用 v2 AAD envelope；locked、wrong AAD、reset、账号切换和云恢复行为均 fail closed。
- [ ] 直连 RFB 和 UltraVNC mode12 viewer 通过真实环境；mode2 需独立 server-side listener 环境；WebSocket/public relay/SSH tunnel 只有在其协议契约和环境通过后才宣称可用。
- [ ] Relay pairing 与 RFB handshake 分层，短读/短写/超时/取消/重连/后台恢复均通过测试。
- [ ] raw BGRA renderer、surface lifecycle、input mapper 和 capability policy 通过 VNC 专属测试，现有视频 decoder 和其他协议回归通过。
- [ ] API 23、双 ABI、HAP、双设备云同步、加密、迁移、备份、reset、回滚和开源合规门全部通过。
- [ ] 用户可以只关闭 VNC sync 或 VNC feature，不影响 RDP、RustDesk、SSH/SFTP 的设置和数据。

## 16. 本轮结论

当前实现已经建立 VNC namespace、独立 settings/service、`vncrecord` 单表和 `vnclocalrecords` 本地镜像，完成 VNC v2 AAD、直连 RFB、UltraVNC mode12 viewer 以及 mode2 server-side 角色边界/fixture、隔离策略和自动化验证。RDP、RustDesk、SSH/SFTP 仍保留各自 owner 和同步表。

当前必须如实区分：代码已具备直连 TCP 和 UltraVNC Repeater viewer mode12 的实现，mode2 仅完成官方 server-side listener 契约校验，尚未用真实 UltraVNC 双端和 API 23 设备验收；WebSocket gateway、公网 relay、SSH tunnel、reverse/listen 因服务端协议/后端部署未提供而显式关闭，不能宣称“公网完整中继已上线”。华为云端只需部署第 0.1 节的 `vncrecord` 一张表，部署和双设备验证由后续执行。
