# SSH/RDP/RustDesk 连接体验问题合并修复计划

日期：2026-07-16

本计划合并以下问题：SSH 私钥文件导入与密钥保险库、SSH 终端横屏、SSH 发送键
收起键盘、RDP/SSH 默认端口串值、RustDesk 局域网发现和直连失败，以及全 App
数据保存后的实时刷新、计数器、缩略信息和详情同步问题。

## 问题定位

### 1. 添加 SSH 主机的文件入口误打开图库

`entry/src/main/ets/pages/HostListPage.ets` 中的 `pickSshKey()` 使用了
`photoAccessHelper.PhotoViewPicker`，因此系统会打开图库。选择结果只写入
`sheetKeyPath`，没有通过 `fileIo` 读取私钥文本到 `sheetKeyText`。

SSH 连接实际优先消费 `sshKeyId`，回退消费 `sshKeyData`；`sshKeyPath` 本身不参与
SSH 认证。因此当前入口既没有导入到密钥保险库，也不能可靠地用于连接。

### 2. 密钥保险库缺少私钥文件导入

`KeyVaultPage.ets` 的“导入已有私钥”只进入粘贴表单，SSH 表单目前只有粘贴和生成
两种方式。项目中 TOTP 文件导入已经使用 `DocumentViewPicker + fileIo`，可以复用
同一套文件访问方式。

### 3. 关联问题：编辑主机可能丢失密钥引用

编辑 SSH 主机时恢复了 `sshKeyPath` 和 `sshKeyData`，但没有恢复 `sshKeyId`。
修复文件自动导入后，如果不补齐该字段，用户再次编辑并保存主机时可能丢失密钥保险库
引用。

## 修复方案

### 阶段一：统一文件读取和密钥解析

新增可复用的 SSH 私钥导入辅助逻辑：

1. 使用 `@kit.CoreFileKit` 的 `DocumentViewPicker` 和 `DocumentSelectOptions`。
2. 通过 `fileIo.openSync/statSync/readSync` 读取用户选择的 URI。
3. 使用 `TextDecoder` 解码，清理 BOM 和首尾空白，并限制文件大小。
4. 调用现有 `ExtensionLoader.inspectSshPrivateKey()` 校验格式、提取公钥、指纹、
   加密状态和密钥类型。
5. 统一构造 `SshKey`：标准 OpenSSH 格式使用 `formatVersion = 1`，保留
   `privateKeyEncrypted`，不输出私钥内容到日志。

### 阶段二：修复添加 SSH 主机流程

1. 将 `HostListPage.ets` 的 `PhotoViewPicker` 替换为 `DocumentViewPicker`。
2. 文件读取和解析成功后调用 `KeyVaultService.addSshKey()`。
3. 将新密钥的 ID 写入 `sheetKeyId`，并同步设置 `sheetKeyText` 和显示名称，
   保持现有连接兼容逻辑。
4. 加密私钥允许先保存到保险库，连接前继续由 SSH preflight 请求 passphrase。
5. 取消选择、空文件、格式错误、超限文件均显示明确提示，不保存半成品。

### 阶段三：为密钥保险库增加文件导入

在 `KeyVaultPage.ets` 的 SSH 添加表单中增加“从文件导入”入口，复用阶段一的读取、
解析和构造逻辑。默认名称取文件名，并允许用户在保存前修改；保存统一经过
`KeyVaultService.addSshKey()`，从而保留本地加密、云同步和数据变更通知链路。

### 阶段四：保持密钥引用一致

1. 编辑主机时恢复 `sheetKeyId` 和 `sheetKeyPassphrase`。
2. 用户切换到文件或粘贴模式时清空旧的 `sheetKeyId`。
3. 保存时保证 `sshKeyId`、`sshKeyData` 和界面显示状态一致。
4. 已有指纹时避免重复导入同一密钥；加密私钥无法取得指纹时按新条目处理。

## SSH 终端横屏方案

### 当前能力判断

SSH 终端当前没有主动锁定横屏，但画布容器使用实际宽高布局；`onAreaChange` 会更新
`termAreaW/termAreaH`，`recalcGrid()` 会重新计算 `termCols/termRows`，随后调用
`resizePty()`。因此画布本身具备横屏后的自适应能力，不应通过 Canvas 的 CSS 旋转
来“横过来”，否则会破坏触摸坐标、键盘锚点和 PTY 行列计算。

RDP 页面已经在 `RemoteDesktop.ets` 中使用 `window.Window.setPreferredOrientation()`
锁定 `LANDSCAPE`，退出时恢复 `UNSPECIFIED`，SSH 可以复用该生命周期方案。

### 修复方案

1. 进入 SSH 页面时，在手机/平板上请求窗口横屏；2in1/桌面设备保持系统当前方向。
2. 在页面退出、连接失败返回和后台恢复路径中恢复原方向，避免影响主机列表和其他协议。
3. 横屏完成后依赖现有 `onAreaChange → recalcGrid → resizePty` 链路更新终端尺寸。
4. 保留用户手动旋转和系统方向失败时的自适应回退，不把横屏锁定当成连接前置条件。

### 验证重点

- 手机竖屏进入 SSH 后自动横屏，返回主机列表恢复原方向。
- Pad 横屏和竖屏进入、系统手动旋转、键盘弹出/收起。
- 横屏后列数增加、行数变化、远端窗口尺寸同步，终端触摸滚动和虚拟键栏位置正常。

## SSH 虚拟键盘发送键

### 定位结果

`SshTerminal.ets` 的隐藏 `TextInput` 设置了 `EnterKeyType.Send`，但 `onSubmit` 只发送
回车并清空输入缓存，没有调用 `SubmitEvent.keepEditableState()`。

API 23 的行为是：非 TV 设备按下输入法回车后默认失焦并收起键盘。RDP 页面已经使用
`keepEditableState()` 和延迟重新聚焦，SSH 页面应保持一致。

### 修复状态

该问题已在当前工作区先行修复：SSH `onSubmit` 已保留编辑态，并在 30ms 后重新请求
`sshKbInput` 焦点。尚未提交，仍需真机确认连续输入命令时键盘保持展开。

## RDP/SSH 添加主机默认端口串值

### 定位结果

1. `HostListPage.ets` 使用单一 `@State portVal` 同时承载 RDP、RustDesk、SSH 端口。
2. 协议按钮点击时虽然写入了 3389/21116/22，但端口输入通过通用
   `fieldRow()` 创建，没有协议稳定 ID，也没有独立的每协议端口文本状态。
3. ArkUI 可能复用同一个 `TextInput` 节点并保留其内部文本，导致界面偶尔显示上一个
   协议的端口；保存路径又直接使用 `portVal`，形成“显示端口”和“保存端口”不一致。
4. `RemoteHost.getDefaultPort()` 本身的 RDP=3389、RustDesk=21116、SSH=22 映射正确，
   根因更接近表单控件状态复用，而不是默认常量错误。

### 修复方案

1. 引入统一的协议端口策略，并让协议切换只通过该策略设置端口。
2. 采用每协议独立的端口状态，或给端口 `TextInput` 使用包含协议的稳定 ID，避免
   RDP 和 SSH 复用输入控件内部状态。
3. 明确切换协议时的产品语义：未修改过的端口显示协议默认值；用户修改过的端口只
   保存在对应协议，不带到另一个协议。
4. 保存前再次按当前协议校验和归一化端口，防止旧控件文本进入 `RemoteHost`。

### 验证重点

- 添加表单初始 RDP=3389。
- RDP→SSH 显示 22，SSH→RDP 显示 3389，反复切换不串值。
- 修改 RDP 为自定义端口后切换到 SSH，再切回 RDP，RDP 自定义端口仍正确。
- 不点击保存直接关闭后重新添加，表单恢复 RDP 默认值。
- 编辑已有主机时协议按钮不可切换，原端口保持不变。

## RustDesk 局域网发现和直连

### 当前能力判断

RustDesk 代码确实包含直连能力，但局域网发现和直连链路目前存在多个高风险点：

1. `RustDeskLanDiscoveryService` 向 `255.255.255.255:21116` 发送项目自定义的
   `RDCM` 探测包，并按自定义格式解析响应。仓库内的 `rustdesk_vendor` 没有对应的
   `RDCM` 实现，说明这不是已验证的上游 RustDesk 发现协议，真实 RustDesk 设备很可能
   不会响应。
2. 发现结果把设备端口固定为 21116，并在 `addLanPeer()` 中直接作为直连端口保存。
   21116 是 RustDesk ID/rendezvous 服务常用端口；被控端直连默认端口应与 21118 区分，
   当前全局直连设置使用 21118，但主机级直连和 LAN 发现默认使用 21116，存在明确的
   端口错误。
3. ArkTS → C++ → Rust 的直连开关传递链路存在：`rdDirectIp` →
   `direct_connection` → `connect_direct()`。但 `connect_direct()` 绕过 rendezvous，
   直接要求对端先发送原始 `PublicKey`，随后进行自定义的加密握手和登录；现有测试只
   覆盖本地 mock peer，没有真实 RustDesk 被控端兼容性证据。
4. 因此当前“有直连代码”不等于“已实现可靠的 RustDesk 局域网直连”。用户反馈无法
   连接与发现协议不兼容、21116/21118 端口混用、以及真实被控端握手差异都可能相关。

### 修复方案

1. 统一 RustDesk 端口常量和语义：ID/rendezvous、relay、peer direct 分开定义，禁止
   在发现服务、主机表单、连接配置中散落数字常量。
2. 将主机级直连和 LAN 发现的默认 peer 端口统一到正确的被控端直连端口；发现结果
   不再盲目把发现服务端口当成 peer 端口。
3. 重新确认并实现与真实 RustDesk 客户端匹配的局域网发现方式；如果上游没有可复用
   的广播协议，则优先提供“局域网 IP/端口直连 + TCP 预检”，不要继续依赖未验证的
   自定义 `RDCM` 广播。
4. 对 `connect_direct()` 增加真实 RustDesk 目标验收；若其 PublicKey 首包或登录协议
   与官方被控端不兼容，应改为复用官方兼容的 rendezvous/peer 连接流程，或暂时隐藏
   “直连此设备”开关，避免给用户一个不可用的连接入口。
5. 增加连接前诊断：目标不可达、端口拒绝、握手类型错误、密码错误、被控端未开启
   直连分别显示，不能统一成“连接失败”。

### 验证重点

- 同一局域网真实 RustDesk 被控端发现成功并显示正确 IP/peer 端口。
- 直接输入 IP、端口、远程 ID 和设备密码后可连接。
- 21116/21117/21118 端口配置分别验证，不允许错误回退。
- 无中继、仅局域网、跨网中继三种路径分别验证。
- 请求被控端批准模式与直连模式互斥关系保持正确。
- Rust FFI 直连 mock 测试、真实 RustDesk 设备测试、双 ABI HAP 构建。

## 全 App 实时刷新审计与修复合并项

### 已确认正常的刷新链路

1. `HostSyncService` 对主机新增、修改、删除、最后连接时间、RDP 凭据、中继和
   RustDesk Pro 地址簿变更均会触发 `onDataChange()`。
2. `HostListPage` 的监听器会调用 `load()`，统一刷新主机数组、总数、锁定数、RDP、
   RustDesk、SSH 计数器、筛选列表和 `HostDataSource`。
3. SSH 指纹和 RDP 证书信任保存后，都会重新构造 `RemoteHost`、调用
   `HostSyncService.updateHost()`，再刷新 `sshTrustedHostsView` 和
   `rdpTrustedHostsView`。设置页的外部数量卡片与内部详情 Sheet 使用同一组刷新后的
   状态，当前设计能够同步更新。
4. `KeyVaultService` 对 SSH 密钥和 TOTP 的 CRUD 均通知；`HostListPage` 的密钥/2FA
   摘要和 `KeyVaultPage` 列表均有监听刷新。
5. `RustDeskRelayPage` 已通过替换选中中继对象刷新健康状态、延迟和 PC 详情面板，
   `RustDeskRelayHealthPolicy` 已有对应回归测试。

### 确定需要修复的问题

#### 1. 主机、SSH 密钥和 TOTP 删除存在重复数据源操作（P1）

服务删除会同步触发页面监听器，监听器已经执行 `replaceAll()`；删除流程随后又在
   动画结束时调用 `DataSource.removeItem()`。这会对已经更新过的数据源再次按旧索引
   删除，可能导致下一条记录暂时消失，之后重新进入页面又恢复。

涉及路径：

- `HostListPage.ets`：单个主机删除和批量主机删除。
- `KeyVaultPage.ets`：SSH 密钥单删、批量删除、TOTP 单删、批量删除。

修复原则：服务通知刷新和动画数据源删除只能保留一种。优先采用“服务完成删除后
统一 `load()`，由稳定 ID 的列表动画负责退场”，不再对已 `replaceAll()` 的数据源按旧
索引二次删除。批量操作应合并为一次刷新，避免每条记录触发一次重建。

#### 2. 云端加密状态变化不会同步更新安全卡片（P1）

`CloudStore.checkCryptoStatusChange()` 会通知 HostSync/KeyVault 服务重载数据，但
`HostListPage` 的 `cryptoEnabled` 和 `cryptoUnlocked` 主要只在页面显示、Sheet 关闭
或本地加密操作后刷新。跨设备启用、关闭或重置加密时，安全卡片可能保留旧状态。

修复：将加密状态刷新纳入统一数据变更回调，或增加独立的加密状态观察接口；重置、
解密、锁定和云端恢复后都刷新安全卡片。

#### 3. SSH 公钥安装 Sheet 的主机列表不是实时数据（P2）

`SshKeyInstallSheet` 只在 `aboutToAppear()` 获取一次 SSH 主机快照，没有订阅
`HostSyncService.onDataChange()`。Sheet 保持打开时，如果发生云端恢复、主机删除、
主机凭据修改或新增 SSH 主机，选择列表和选中对象仍是旧数据。

修复：增加监听与取消订阅；刷新时按主机 ID 重绑 `selectedHost`，若主机已删除则清空
选择并提示用户，避免使用失效凭据继续安装。

#### 4. 主机连接健康字段没有闭环写入（P2）

主机卡片会读取 `lastHealth` 和 `lastLatency`，但当前没有连接成功/失败路径写入这两个
字段，因此“连接正常/延迟”等摘要基本不会出现。`RemoteDesktop` 当前还明确跳过了
RDP 的 `lastConnected` 更新，SSH/RustDesk 与 RDP 的行为不一致。

修复：在 `HostSyncService` 增加统一的 `updateConnectionHealth()`，由 RDP、RustDesk、
SSH 连接成功、失败和断开路径写入健康状态、延迟和最后连接时间，并通过同一通知刷新
主机卡片。需要明确 RDP 是否保留当前“跳过 lastConnected”的诊断策略；若无产品要求，
应统一三种协议的行为。

#### 5. 旧 SSH 前置校验路径绕过 HostSyncService（P2）

当前主流程使用 `HostListPage` 的新式前置校验，但旧的 `SshPreflightSheet` 仍直接写
`CloudStore`。如果该组件被重新启用，主机内存、计数器、信任列表和详情页不会收到
统一通知。

修复：迁移到 `HostSyncService.updateHost()`，或删除旧实现，避免保留第二套写入路径。

### 一致性风险与预防性修复

1. `HostSyncService.loadFromCloud()` 和 `KeyVaultService.loadFromCloud()` 会无条件清空
   并替换内存数据；相比 RustDesk 中继健康状态已有时间戳保护，主机、密钥和 TOTP
   缺少“本地较新数据不被旧云快照覆盖”的保护。需要增加同步版本/更新时间判断，或
   对本地写入后的云端回调做合并和去重。
2. `RustDeskProCredentialStore` 已补充独立 `onDataChange()` 通知，RustDesk 中继页订阅
   后，Pro 登录、同步、过期和退出会立即刷新账户状态、统计和详情面板。
3. RustDesk LAN 扫描结果只在 15 秒扫描 Promise 完成后一次性显示。如果产品要求
   “发现即显示”，应增加逐条结果回调；否则在计划中明确这是扫描结束汇总行为。

## 合并后的执行顺序

1. 完成 SSH 私钥文件读取、密钥保险库导入、主机 `sshKeyId` 引用一致性修复。
2. 完成 SSH 横屏生命周期、虚拟键盘发送键和 RDP/SSH 端口状态隔离。
3. 完成主机、密钥、TOTP 删除路径的数据源重复操作修复，统一刷新入口和批量刷新。
4. 补齐加密状态、SSH 公钥安装 Sheet、证书信任列表和主机计数器的实时刷新回归。
5. 补齐主机连接健康、延迟和最后连接时间的统一写入及刷新策略。
6. 完成 RustDesk LAN 发现、peer 端口、直连握手和中继回退的真实设备验证。
7. 最后执行 ArkTS 编译、HAP 构建、定向测试、真实设备矩阵和 Light 合规检查。

## 验证计划

- RSA、ED25519、加密私钥、无扩展名 `id_rsa`、BOM 文本、空文件和非法私钥文件。
- 添加主机后密钥是否出现在密钥保险库，主机是否保存 `sshKeyId`。
- 重启应用、重新编辑主机后密钥引用是否仍然存在。
- 加密私钥连接时是否正常进入 passphrase preflight。
- SSH 发送键连续输入和键盘保持展开。
- SSH 横屏进入、退出恢复、PTY 行列同步。
- RDP/SSH 端口切换、保存和重新打开表单。
- RustDesk LAN 发现、peer 直连、rendezvous/relay 回退和真实设备错误诊断。
- 添加主机后总数、协议计数、锁定数和设置页摘要立即变化。
- SSH 指纹/RDP 证书信任、忘记和重新获取后，外部数量卡片与内部详情同时变化。
- 主机、SSH 密钥、TOTP 单删和批量删除不误删相邻记录，动画结束后列表与服务数据一致。
- 云端恢复、加密启用/关闭/重置后，列表、计数器、安全状态和详情均与服务数据一致。
- SSH 公钥安装 Sheet 打开期间主机新增、删除、修改时，选择列表和选中对象正确更新。
- RDP、RustDesk、SSH 连接成功/失败后的健康状态、延迟和最后连接摘要正确刷新。
- `default@OhosTestCompileArkTS`。
- `assembleHap`。
- 定向密钥保险库、端口策略、RustDesk endpoint/FFI 测试，受影响 ABI、
  `git diff --check` 和 Light 合规检查。

## 执行边界

当前工作区已有 RustDesk 相关修改，且活动分支为
`codex/rustdesk-pro-account-sync`。业务代码修复应等当前任务合并或明确归档后，
从同步的 `main` 创建独立任务分支；本计划文档单独落盘，不覆盖现有用户修改。

## 当前实现与验证状态

本轮已按以上合并项落地代码：SSH 文件导入及密钥保险库引用、SSH 横屏与发送键、RDP/SSH
端口隔离、主机/凭据/密钥/TOTP 的统一实时刷新、SSH 指纹和 RDP 证书详情同步、连接健康
状态写入、RustDesk 官方 LAN PeerDiscovery/21118 直连以及旧云快照保护均已完成本地实现。
RustDesk Pro 凭据存储也已接入实时变更通知。

本地验证结果：RustDesk FFI `cargo test --no-default-features` 为 91/91，
`default@OhosTestCompileArkTS`、生产 `assembleHap`、`git diff --check` 和 Light 合规门
通过。`onDeviceTest` 已完成测试 ArkTS 编译、测试 HAP 打包/签名，但设备覆盖率阶段因本机
缺少 hvigor `connect-key` 阻塞；真实 RustDesk 被控端 LAN/直连矩阵仍需设备条件补测。
