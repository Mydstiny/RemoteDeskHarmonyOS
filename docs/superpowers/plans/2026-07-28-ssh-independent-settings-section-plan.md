# SSH 独立设置栏位设计与迁移计划

> 日期：2026-07-28
> 目标仓库：RemoteDeskHarmonyOS
> 计划性质：设计与分阶段实施基线
> 当前结论：建议新增“SSH 终端”独立设置栏位，暂不新增独立顶级页面

## 1. 结论

SSH 适合像 RDP、RustDesk 一样在现有设置面板中新增独立栏位。

推荐第一阶段采用以下形态：

- 在 HostListPage 的设置面板中新增“SSH 终端”折叠栏位。
- “SSH 终端”必须紧跟“RustDesk”栏位之后，位于“数据安全”之前；不改变 RDP、RustDesk、VNC 现有栏位顺序。
- 将当前“个性化”里的“终端字体颜色”和“终端字体大小”移动到“SSH 终端 > 终端显示”。
- SSH 主机指纹管理本阶段不迁移，继续保留在“数据安全”栏位和逐主机 SSH 预检流程中；不得新增第二个入口或改变其数据 owner。
- 在 SSH 栏位中增加本阶段已经生效的终端显示入口，以及 SSH 主机和密钥保险库快捷入口。
- 逐主机的地址、端口、用户名、认证方式、密钥绑定和代理覆盖仍保留在 SSH 主机新增/编辑流程中。
- SSH 密钥保险库继续作为独立资源页，但在 SSH 栏位中提供快捷入口。

不建议第一阶段复制 VNC 的方式直接建立一个新的 SSHSettingsPage。VNC 之所以采用独立页面，是因为它拥有独立的 host、gateway、trust 数据 owner 和专用云表。SSH 当前仍复用 RemoteHost、SSH 密钥保险库和 usersettings；立即拆成新页面会造成配置来源重复、迁移复杂和 HostListPage/SSH 页面状态不一致。

后续如果 ProxyJump、端口转发、known_hosts、连接配置集和高级 SFTP 管理使栏位内容明显超过设置面板承载能力，再把同一套 SshSettingsService 复用到独立的 SSH 设置页面；不能先复制一套数据模型再迁移。

## 2. 当前代码事实

### 2.1 当前设置面板

当前 HostListPage 的 settingsContent 已经使用统一的 accordion 结构，已有：

- 个性化
- 云同步
- 实况窗
- 显示与交互
- Windows RDP
- RustDesk
- SSH 终端
- 数据安全
- 教程
- 关于

SSH 现已拥有独立 accordion，并严格位于 Windows RDP、RustDesk 之后，数据安全之前。设置栏位的路由和动画由以下策略负责：

- entry/src/main/ets/pages/HostListPage.ets
- entry/src/main/ets/services/SettingsAccordionPolicy.ets
- entry/src/main/ets/services/SettingsSheetRoutePolicy.ets
- entry/src/main/ets/services/CloudSyncSettingsPolicy.ets

### 2.2 当前 SSH 相关配置分布

| 当前配置 | 当前 owner/位置 | 当前作用域 | 计划归属 |
| --- | --- | --- | --- |
| sshTerminalForegroundColor（兼容 terminalFgColor） | SshSettingsService、AppStorage、RemoteDesktopAppPrefs、usersettings | 全局终端显示 | SSH 终端 / 终端显示 |
| sshTerminalFontSize（兼容 terminalFontSize） | SshSettingsService、AppStorage、RemoteDesktopAppPrefs、usersettings | 全局终端显示 | SSH 终端 / 终端显示 |
| useNativeTerminalCore | AppStorage、RemoteDesktopAppPrefs | 全局实现开关 | SSH 终端 / 高级，默认不向普通用户暴露 |
| SSH 主机指纹 | RemoteHost、CloudStore、数据安全栏位 | 逐主机信任 | 本阶段继续留在数据安全；后续 known_hosts 完整实现时单独评审 |
| 地址、端口、用户名 | RemoteHost、SshAddFlow、HostListPage | 逐主机 | SSH 主机新增/编辑 |
| 密码 | RemoteHost 加密存储 | 逐主机敏感数据 | SSH 主机新增/编辑，不进入全局设置 |
| SSH 密钥绑定 | SshKey、KeyVaultService、RemoteHost.sshKeyId | 逐主机引用 | 密钥保险库和 SSH 主机编辑 |
| 私钥 passphrase | 加密 host/key 数据 | 逐主机敏感数据 | SSH 主机编辑/连接预检 |
| proxyHost/proxyPort/proxyUsername | RemoteHost、SSH 主机编辑 | 逐主机代理覆盖 | SSH 主机编辑；未来可增加全局默认代理 |
| SSH 终端字号/颜色 | SshTerminal、NativeTerminalRenderer、TerminalEmulator | 全局终端体验 | SSH 终端 / 终端显示 |
| PTY 尺寸 | SshTerminal 根据窗口动态计算 | 当前会话 | 保持自动适配；未来可增加默认尺寸 |
| 粘贴、鼠标、滚动模式 | SshTerminal、SshTerminalInputPolicy、SshTerminalScrollPolicy | 当前终端交互 | SSH 终端 / 输入与滚动 |
| SFTP 操作 | SshTerminal 和 native SSH adapter | 当前会话 | SSH 终端 / SFTP |

### 2.3 当前云同步约束

sshTerminalForegroundColor 和 sshTerminalFontSize 已加入 usersettings 可同步白名单，并继续兼容旧 terminalFgColor、terminalFontSize。首期不新建 sshsettings 云表，不改变 usersettings 表结构，不把 SSH 密码、私钥、proxy 密码、OTP 或命令内容放进普通 settings。

RemoteHost 和 SshKey 已经有各自的加密/同步路径，SSH 栏位只应调用既有 service，不应复制一份敏感数据。

## 3. 目标信息架构

设置面板目标顺序：

1. 账号
2. 个性化
3. 云同步
4. 实况窗
5. 显示与交互
6. Windows RDP
7. RustDesk
8. SSH 终端
9. 数据安全（SSH 主机指纹仍在这里）
10. 教程
11. 关于
12. 反馈、评价

“SSH 终端”栏位标题副文案建议：

> 终端显示、SSH 主机与密钥

“个性化”栏位副文案改为：

> 添加方式、主题色、壁纸与光晕

“数据安全”栏位继续保留跨协议的应用加密、2FA 隐私保护、总体安全说明和 SSH 主机指纹管理。本阶段不迁移 trust UI、路由、数据 owner 或 RemoteHost 字段；后续 known_hosts 完整实现时再单独评审。

## 4. SSH 栏位的内容设计

### 4.1 终端显示

第一期必须包含：

- 终端字体颜色：复用当前 terminalFgColor 的颜色选择器。
- 终端字号：复用当前 terminalFontSize 的选择器和 12～32vp 校验范围。
- 终端字体预览：展示当前字号、颜色、等宽字体示例和 ANSI 控制序列示例。
- 恢复默认值：恢复现有默认颜色和字号。

第二期可增加：

- 终端背景色。
- 等宽字体族选择。
- 光标样式：块、下划线、竖线。
- 光标闪烁。
- 行间距和左右内边距。
- ANSI 16 色/256 色主题。
- 默认终端主题预设。

注意：只有 renderer 和 terminal_core 已经支持的控制项才能显示为可用开关。未实现能力应显示“计划支持”或暂不显示，不能把只保存、不生效的字段伪装成完成。

### 4.2 输入、粘贴与滚动

第一期可以承载当前已存在的行为开关或策略：

- 多行粘贴确认。
- bracketed paste 的兼容策略。
- 粘贴大小限制提示。
- 自动滚动到底部。
- 触摸滚轮方向。
- 鼠标跟踪和 SGR 鼠标模式的兼容说明。
- 连接后自动聚焦终端输入。

未来可增加：

- 选择后自动复制。
- 复制时是否包含换行。
- 滚动回看时暂停自动跟随。
- scrollback 行数上限。
- Ctrl/Alt/Meta 修饰键行为。
- 移动端虚拟键盘快捷键布局。

将当前 SshTerminal 中的硬编码默认值逐步移动到 typed settings service；在此之前不要在 UI 中暴露对应选项。

### 4.3 连接与会话

建议的设置项：

- 默认 SSH 端口：22。
- 连接超时。
- keepalive 周期。
- 断线后的重试次数和退避策略。
- 前后台恢复策略。
- 连接后自动打开键盘。
- 默认终端列数和行数，默认仍为自动适配。
- 默认 Shell/登录命令：只在后端真正支持独立 channel 后启用。
- 是否启用压缩：待算法和性能验证后启用。

作用域规则：

- 默认端口、超时、keepalive、重试策略属于全局 SSH 默认值。
- 主机上的显式值优先于全局默认值。
- 已建立会话不因设置改变而静默重建；新连接或用户明确点击“应用到当前会话”时才生效。
- 当前会话的 PTY 尺寸继续由窗口布局实时决定，不被全局默认值强行覆盖。

### 4.4 SFTP

建议设置项：

- 默认本地下载目录：只保存在本机，不云同步。
- 是否显示隐藏文件。
- 覆盖文件前确认。
- 断点续传默认开关。
- 并发传输数：首期固定为 1，后续在 worker/连接模型完成后开放。
- 传输失败后的重试次数。
- 上传完成后是否校验文件大小或 checksum。

SFTP 主机路径、远端当前目录和单次传输状态属于会话状态，不应写入全局设置。

### 4.5 安全与信任（本阶段不迁移）

本阶段不在 SSH 栏位中提供新的指纹管理入口。现有能力继续由“数据安全”栏位提供：

- 已信任 SSH 主机数量。
- SSH 主机指纹预检、首次信任、变更阻断和撤销流程。
- 查看算法、SHA256 指纹、主机地址和首次信任时间。

后续 known_hosts 完整实现并完成迁移评审后再考虑：

- 主机模式匹配。
- hashed hostname。
- 多个 key 的轮换记录。
- 变更 key 的差异确认。
- known_hosts 导入/导出。

安全默认值：

- 未知 host key 不得静默接受。
- 主机 key 变更必须阻断连接并展示旧/新指纹。
- 信任记录管理不得显示私钥、密码、OTP 或 proxy 密码。
- 清除信任必须二次确认，并明确下次连接会重新询问。

SSH 栏位只提供“主机指纹仍在数据安全中管理”的说明，不复制可点击的 trust action。

### 4.6 网络与高级

本阶段不新增连接、SFTP、代理和高级网络控件。现有逐主机连接流程保持原样；只有后端和会话 owner 完成后，才按 Phase 3/4 增加对应全局默认值。

后续可提供已经实现并且可以安全解释的能力：

- 默认代理类型：直连、HTTP CONNECT、SOCKS5。
- 代理使用说明。
- 代理默认值是否应用到新建主机。

代理的账号、密码和逐主机覆盖仍放在 SSH 主机编辑流程。ProxyJump、Bastion、端口转发、agent、FIDO2、PKCS#11、GSSAPI、算法列表、compression 和 rekey 在对应 native 能力完成前不要开放设置项。

## 5. 全局设置与逐主机设置的边界

这是本次设计的核心，不应因为新增栏目而把所有 SSH 字段都搬进一个全局对象。

### 5.1 放入 SSH 独立栏位

- 终端颜色、字号和渲染外观。
- 本阶段已实现的 SSH 主机和密钥保险库快捷入口。
- 主机指纹位置说明；不提供第二个 trust 管理入口。
- 后续实现全局输入、连接、SFTP 默认值后再逐项加入。
- SSH 密钥保险库入口。
- 未来的 SSH 默认代理和协议策略。

### 5.2 保留在主机新增/编辑

- 主机名称、地址、端口。
- 登录用户名。
- 密码认证或公钥认证选择。
- 绑定哪一个 SSH 密钥。
- 该主机的私钥 passphrase。
- 该主机的代理覆盖。
- 该主机的 host key 信任结果。
- 该主机的远端默认目录或连接标签。

### 5.3 不能放入普通全局 settings

- 密码。
- 私钥正文。
- 私钥 passphrase。
- proxy 密码。
- OTP/MFA 响应。
- 远端命令历史。
- 远端文件内容。

这些数据必须继续使用 KeyVault、DataCrypto 或按主机绑定的加密 owner。设置页面只显示“已配置”“需要重新输入”或引用 ID。

## 6. 数据模型与存储方案

### 6.1 新增 typed service

已新增 SshSettingsService 和 SshSettingsPolicy，避免继续在 HostListPage 中直接散落 AppStorage key。后续扩展更多字段时继续沿用这两个 owner。

建议模型：

- schemaVersion
- terminalFontSizeVp
- terminalForegroundColor
- terminalBackgroundColor
- terminalFontFamily
- cursorStyle
- cursorBlink
- pasteConfirm
- bracketedPastePolicy
- scrollbackLines
- autoFocusInput
- connectTimeoutMs
- keepaliveIntervalMs
- reconnectPolicy
- defaultCols
- defaultRows
- sftpShowHidden
- sftpConfirmOverwrite
- sftpResumeEnabled
- sftpRetryCount
- defaultProxyType
- defaultProxyHost
- defaultProxyPort
- defaultProxyUsername

模型必须区分“已实现字段”和“保留字段”。未实现字段不能被保存后误认为已经生效。

### 6.2 存储和同步

首期沿用现有 owner：

- 本地持久化：RemoteDesktopAppPrefs。
- 运行时响应：AppStorage 或 service 的订阅回调。
- 跨设备可复用偏好：usersettings。
- 主机和密钥：remotehosts、sshkeys 既有路径。
- 敏感字段：DataCrypto/KeyVault，不进入普通 usersettings。

建议对新 key 使用 ssh 前缀，例如：

- sshTerminalFontSize
- sshTerminalForegroundColor
- sshPasteConfirm
- sshConnectTimeoutMs

旧 key terminalFgColor、terminalFontSize 作为兼容别名保留一个迁移周期，避免旧版本回写时丢数据。

### 6.3 迁移顺序

启动时按以下优先级读取：

1. 新命名空间 key 且通过校验。
2. 旧 terminalFgColor、terminalFontSize 等兼容 key。
3. 默认值。

第一次成功读取后：

1. 写入新 key。
2. 保留旧 key 一个版本用于旧版本回滚。
3. 记录 sshSettingsSchemaVersion。
4. 后续新版本只以新 key 为主。

迁移不能覆盖用户已有的有效值，不能把旧版本的默认值误判成用户选择。颜色必须验证为合法颜色格式，字号必须限制在 12～32vp。

## 7. 组件与路由设计

### 7.1 推荐拆分

不建议长期把全部 SSH 控件继续堆入 HostListPage。当前为控制改动范围，SSH accordion 的首期内容暂内联在 HostListPage；后续扩展到连接、SFTP 和高级网络设置时再拆成：

- SshSettingsSection.ets：SSH accordion 内容和分组卡片。
- SshSettingsService.ets：typed settings、加载、保存、订阅。
- SshSettingsPolicy.ets：默认值、范围校验、迁移和 feature gate。
- SshTrustManagerSheet.ets：指纹和信任记录管理。
- SshTerminalAppearanceSheet.ets：颜色、字号、预览。
- SshConnectionDefaultsSheet.ets：连接/SFTP/代理默认值。

HostListPage 只负责：

- 展开/折叠 section。
- 打开设置面板。
- 连接到现有 KeyVault、SSH 主机列表和 trust service。
- 处理路由返回和页面生命周期。

### 7.2 现有路由复用

复用 SettingsSheetRoutePolicy 的 leaf sheet 生命周期，不新增第二套 bindSheet 状态机。

SSH 栏位中的入口建议：

- “终端显示”打开已有颜色/字号能力的统一 sheet。
- “SSH 主机”关闭设置面板并切换 curTab=2。
- “SSH 密钥保险库”切换到已有密钥页。
- “主机指纹”本阶段不在 SSH 栏位新增入口，继续使用数据安全栏位的统一 trust sheet。
- “连接默认值”暂不显示，待连接会话 owner 实际支持后再增加。

PC 端可在设置栏位中显示“管理 SSH 主机”按钮；手机/平板使用同一入口关闭设置后切换到 SSH 主机列表，避免嵌套页面和 Sheet 叠加。

## 8. 分阶段实施

### Phase 0：确认信息架构

- 确认 SSH section 紧跟 RDP、RustDesk 之后、数据安全之前。
- 确认终端字体颜色和字号从个性化迁出。
- 确认 SSH 主机指纹本阶段不从数据安全迁出。
- 确认逐主机连接字段不搬到全局。
- 输出 UI 线框和字段作用域表。

验收：产品、交互和安全负责人对“全局 vs 逐主机”边界签字。

### Phase 1：无行为变化的设置抽取

- 建立 SshSettingsService、SshSettingsPolicy。
- 迁移 terminalFgColor、terminalFontSize 的读写到 sshTerminalForegroundColor、sshTerminalFontSize。
- 保留旧 key 兼容。
- 保证打开 SSH 页面、已有连接和现有云同步行为不变。

验收：

- 老用户的颜色和字号不丢失。
- HostListPage 和 SshTerminal 读取同一份运行时设置。
- 云端旧 usersettings 可以恢复。
- 旧版本回滚不会得到空值。

### Phase 2：SSH accordion 和现有设置搬迁

- 新增 SSH section header 和内容卡片。
- 删除个性化中的终端颜色/字号行。
- 增加 SSH 主机和密钥保险库快捷入口；不增加第二个指纹管理 action row。
- 保留已有 sheet 动画、关闭和页面恢复行为。

验收：

- 设置面板只有一个 SSH 入口。
- 终端颜色和字号在新位置可修改并立即作用于已打开终端或下一次打开终端。
- SSH 栏位位于 RustDesk 之后，数据安全仍保留 SSH 主机指纹入口。
- RDP、RustDesk、VNC 设置位置和行为不变。

### Phase 3：补齐已有后端能力的设置项

按已经落地的 SSH 能力逐项开放：

- 粘贴保护。
- bracketed paste。
- 鼠标跟踪和滚动行为说明。
- 连接超时和手动重试。
- SFTP 覆盖/续传基础策略。
- 已有 host key 信任管理继续由“数据安全”栏位负责，不作为本阶段 SSH 栏位迁移项。
- HTTP CONNECT/SOCKS5 默认代理说明。

每个 UI 控件必须对应实际 native/ArkTS 行为，并有错误提示和默认值。

### Phase 4：高级 SSH 设置

待后端完成后再开放：

- 自动/后台重连。
- ProxyJump/Bastion。
- 多 channel/端口转发。
- keyboard-interactive prompt UI。
- known_hosts 完整管理。
- compression、rekey、算法策略。
- agent、证书、FIDO2、PKCS#11、GSSAPI。
- 完整 SFTP 传输策略。

## 9. 测试与验收矩阵

### 9.1 设置迁移

- 全新安装显示正确默认颜色和字号。
- 旧版本只有 terminalFgColor 时可以迁移。
- 旧版本只有 terminalFontSize 时可以迁移。
- 新旧 key 同时存在时按新 key 优先。
- 非法颜色、越界字号回退默认值。
- 重复启动不会反复覆盖用户修改。

### 9.2 UI 位置和生命周期

- 个性化中不再出现终端颜色和字号。
- SSH 栏位展开、折叠、旋转和返回后状态稳定。
- 设置面板关闭再打开不会丢失临时选择。
- 颜色/字号 sheet 关闭动画完成前不会叠加第二个 sheet。
- PC、手机、平板的设置栏位均可访问。

### 9.3 跨协议隔离

- 修改 SSH 颜色/字号不改变 RDP/RustDesk/VNC 画面。
- 修改 SSH 连接默认值不改变已有 RDP/RustDesk/VNC 主机。
- SSH 设置加载失败时 RDP/RustDesk/VNC 仍可连接。
- VNC 专用设置和 vncrecord 云表不受影响。
- 不新增 SSH 对 RDP gateway 字段的隐式依赖。

### 9.4 安全和云同步

- usersettings 只同步白名单中的非敏感 SSH 偏好。
- 密码、私钥、passphrase、proxy 密码和 OTP 不进入 usersettings。
- 数据安全中的 host key 管理入口和逐主机信任流程不发生迁移。
- 新设备恢复颜色/字号后不自动信任陌生 host key。
- 云同步失败时本地 SSH 设置仍可保存和使用。
- 加密锁定时不显示敏感字段明文。

### 9.5 构建门禁

未来发生 ArkTS、native、Rust、测试或配置改动时，必须执行：

- default@OhosTestCompileArkTS
- assembleHap

本次实施已执行 `default@OhosTestCompileArkTS`、生产 `assembleHap`、`git diff --check` 和 Light 合规门；`ohosTest@OhosTestCompileArkTS` 因当前任务图未注册而返回 `00306054`。颜色/字号迁移策略已有单元测试源码，但仍需在 API 23 PC、手机、平板和真实 SSH 主机上完成 UI、生命周期、云恢复及信任边界验收。

## 10. 不影响其他模组的约束

- 不修改 RDP、RustDesk、VNC 的协议 adapter。
- 不把 SSH 配置写进 RDP gateway 或 RustDesk relay 数据 owner。
- 不改变 RemoteHost 中已有非 SSH 字段的序列化语义。
- 不新增 usersettings 的隐式全量同步；所有新 key 必须进入显式白名单。
- 不新增敏感字段到普通 settings。
- 不在 HostListPage 中复制一份终端状态；终端页和设置页必须通过 service/Storage 订阅共享。
- 不因 SSH 设置加载或云同步异常阻塞主机列表、RDP、RustDesk、VNC。
- 不将未实现的高级 SSH 控件作为可用功能展示。

## 11. 建议的产品文案

栏位标题：

> SSH 终端

当前副标题：

> 终端显示、SSH 主机与密钥

后续能力完成后的分组副标题建议：

分组标题：

- 终端显示
- 输入与滚动
- 连接与会话
- SFTP
- 安全与信任
- 高级网络

敏感设置的说明：

> 密码、私钥和 OTP 不属于通用设置；请在主机配置或密钥保险库中管理。

信任设置的说明：

> 主机指纹按服务器和端口保存。指纹变化时连接会被阻断，需要人工确认。

## 12. 最终判断

新增 SSH 独立设置栏位是合理且必要的，能解决当前“SSH 终端设置隐藏在个性化、主机指纹又分散在安全栏位”的信息架构问题。

最稳妥的落地顺序是：

1. 在现有设置面板增加 SSH accordion，位置固定在 RDP、RustDesk 之后、数据安全之前。
2. 搬迁颜色、字号；SSH 指纹入口继续留在数据安全，不新增第二个管理入口。
3. 抽取 SshSettingsService，完成旧 key 迁移并保持云同步兼容。
4. 再按后端完成度逐步增加连接、输入、SFTP 和高级网络选项。
5. 只有当 SSH 配置规模超过 accordion 的承载能力时，才把同一 service 复用到独立 SSH 设置页。

本计划不建议现在创建新的 SSH 云表，也不建议现在把逐主机 SSH 连接资料全部搬到全局设置。SSH 主机指纹管理暂不迁移，后续 known_hosts 完整实现时另行评审。
