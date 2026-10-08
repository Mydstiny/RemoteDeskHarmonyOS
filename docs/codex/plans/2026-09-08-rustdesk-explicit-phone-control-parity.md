# RustDesk「控制手机」官方体验对齐计划（用户显式选择限定）

- 日期：2026-09-08。
- 状态：CODE_COMPLETE_REVIEW_PASS_DEVICE_PENDING；用户已授权并实施两条必要证据边界，手机新增入口仅接受本机真实点击证明。初次复核问题及追加的备份/帧队列问题均已修复，独立 `/root/review_explicit_phone` 对最终手机提交 `b97808f5` 正式 PASS。S5 真机验收未执行，整份计划不声明完成。
- 用户硬边界：仅涵盖用户选择「控制手机」的情况，不允许扩散或影响其他情况、功能模组。
- 本计划取代此前临时评估中的宽范围实施建议；临时评估只保留调查参考价值，不构成执行授权。
- 工作区基线：`codex/pro-purchase-foundation@cdc193958`，本地 main 为 `8edc18786`。Pro 与文件/剪贴板任务有并行改动；实施前刷新相关路径差量，不覆盖、不混合提交。
- 官方对照：RustDesk 稳定版 `1.4.9`；同时调查过 master `e8eead571516dac0669e64b186208979d79282eb`。旧版返回兼容边界为被控 RustDesk `1.3.8`，不是 Android 系统版本。

## 1. 唯一进入条件

本计划所有新增行为的前提均为：

`protocol === 'rustdesk' && rustdeskTargetDevice === 'phone' && explicitUserPhoneChoice`

`explicitUserPhoneChoice` 是本计划要求的选择来源契约，不表示当前代码已有同名字段。必须由真实用户选择或可核验的已保存手工选择得出，不能仅由目标字符串推断。

这里的「控制手机」指被控目标选择，与控制端设备是 PC、Pad 还是 Phone 无关；三种控制端只有满足上述条件才进入本计划。

1. 必须先验证用户选择，再查询实际被控平台、版本和权限。PeerInfo 只能决定已选手机会话内哪些动作可用，不能代替用户选择、更改主机类型或自动开启本计划。
2. 用户选择「控制电脑」、缺少字段、历史默认值、未知/非法值均不进入新增路径；即使握手返回 Android 也一样。仅仅竖屏、设备名包含手机或控制端本身是手机，均不算用户选择。
3. 用户选择「控制手机」且确认 Android：启用对应版本与权限允许的手机动作。平台未知时不猜测 Android 专用操作可用；平台不匹配时只在当前已选手机会话提示，不改为另一类型或修改其他会话。
4. 已保存且可核验为用户手工选择的 `phone` 可以沿用，不要求每次重复确认；来源不明者不启用新增路径，缺省记录不批量迁移、不自动补成 `phone`。特别是 `HostListPage.effectiveSheetRustDeskTargetDevice()` 会按锁定的 RustDesk Pro 平台计算 phone：该结果不是用户选择，必须排除。不得为确认来源而修改 Pro、导入/同步或存储结构。
5. 进入会话时固定该选择及会话身份；每个异步动作、延迟释放、重连回调均核对同一 session/owner/generation。旧会话的手机动作不得发到下一会话。
6. 活跃会话中若发生目标配置变化，应在受控退出/重新进入边界生效；不得让一个按下/抬起序列跨越两套策略。
7. 不得全局替换现有 `isRustDeskPhoneSessionForPeer()` 或 `isRustDeskPhoneSession()` 的含义；它们目前包含实际平台识别，直接重定义会影响未选择手机的既有路径。新增独立、显式选定的作用域判定，仅供本计划新增逻辑使用。

| 协议 | 用户目标选择 | 实际被控平台 | 本计划新增行为 |
|---|---|---|---|
| RustDesk | 明确 phone | Android | 在版本、权限允许时启用 |
| RustDesk | 明确 phone | 未知 | 保留明确选择，等待核验；不猜测 Android 专用动作 |
| RustDesk | 明确 phone | Windows/macOS/Linux/其他 | 当前手机会话提示能力不匹配；不修改其他路径 |
| RustDesk | 自动计算 phone/来源不明/Pro 平台锁定 | Android 或任意平台 | 不启用，不能将程序推导当用户选择 |
| RustDesk | computer/缺省/非法值 | Android 或任意平台 | 不启用，保持原有行为 |
| RDP/SSH/SFTP/VNC/Moonlight | 任意 | 任意 | 不启用，保持原有行为 |

## 2. 不允许扩散的边界

### 本计划允许的未来实现

- 已明确选择手机的 RustDesk 会话内：手指/鼠标/实体触控板输入、手机操作栏、本地画布缩放和方向适配、该会话的输入权限提示与输入终止。
- 仅为上述功能服务的手机专用 ArkTS 策略、窄 NAPI/FFI 适配、会话状态和定向测试。
- 在共用文件中增加可证明只被上述作用域调用的分支；非目标分支必须保留原有 UI、事件、状态与副作用。

### 明确排除

- RustDesk「控制电脑」及未显式选择手机的全部会话；不顺带修复它们的输入、方向、缩放、快捷键或显示问题。
- RDP、SSH/SFTP、VNC、Moonlight；Pro/IAP、远程 AI、USB/FIDO、账号、云同步、连接共享、主机管理和其他功能模组。
- 文件传输、剪贴板、音频、聊天、录屏的功能改造或新增。原评估中的配套扩展阶段从本计划删除；这些功能只做“行为未被改变”的回归观察。
- 共享 TouchScale 合并算法修复、通用输入队列重构、全局渲染器变换规则、编解码器、通用 IME/快捷键/焦点框架升级。
- hbbs/hbbr、直连/中继/NAT、认证、密码/2FA、网络路由、全局重连状态机的改造。
- 官方 Android 被控端修改、原生 HarmonyOS/iOS 被控能力、新多点触控协议、绕过采集授权/锁屏。
- 全局设置默认值、偏好持久化格式、批量主机迁移、共享数据库结构、依赖/proto/SDK/构建流程升级。

发现必须修改排除项才能继续时，当前增量停止扩大，只记录依赖及可局部替代方案；另行取得明确范围授权前不得处理。不得以“顺便修复”“官方对齐需要”或“共享函数更合理”为由扩大范围。

## 3. 评估发现与本计划处理

以下基于源码对照；“有实现”不等于真机通过。引用均使用仓库路径与符号，不依赖临时目录或评估机器绝对路径。

| 编号 | 已观察到的差距/风险 | 本计划内处理方式 | 主要源码证据 |
|---|---|---|---|
| P01 | `currentControlMode()` 沿用全局模式；手指可能进入移动光标模式 | 仅显式 phone 会话计算临时有效输入策略；直接触控默认不写回全局 | [RemoteDesktop](../../../entry/src/main/ets/pages/RemoteDesktop.ets)，`currentControlMode` |
| P02 | 工具栏缺少完整手机动作；Rust 发送层只有左/中/右映射，不能表达官方 Back | 增加手机专用动作入口与受限发送适配，不改变普通鼠标按钮映射 | [工具栏策略](../../../entry/src/main/ets/services/RemoteSessionTopBarPolicy.ets)，`RUSTDESK_PRIMARY_ACTION_IDS`；[connector](../../../rustdesk_ffi/src/connector.rs)，`send_control_message` 内按钮映射 |
| P03 | PC 实体触控板发送桌面滚轮和 Ctrl/Command 加减键 | 仅目标会话走 Android 连续 TouchPan 路由；捏合仅改变当前本地画布 | [RemoteDesktop](../../../entry/src/main/ets/pages/RemoteDesktop.ets)，`handleRustDeskPhysicalTouchpadAxis`、`sendRustDeskPhysicalTouchpadZoom` |
| P04 | 远端 App TouchScale 的判定不区分 Android 能力；官方 Android 不处理该 scale 消息 | 在显式 phone 会话限制不支持的入口/行为；不更改全局开关及桌面路径 | [RemoteDesktop](../../../entry/src/main/ets/pages/RemoteDesktop.ets)，`shouldUseRustDeskRemoteAppTouchScale` |
| P05 | 本地 TouchPan 直接发新减旧，Android 接收用当前位置减增量；直接跟手目标可能反向 | 在手机专用适配器定义绝对坐标与 pan 增量，不用全局滚轮反转补偿 | [RemoteDesktop](../../../entry/src/main/ets/pages/RemoteDesktop.ets)，`updateRustDeskRemoteAppTouchPanAt`；[bridge](../../../entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp)，`sendTouchPan` |
| P06 | 手机方向仍受保存类型与自适应开关限制，可能在控制端强制横屏 | 只在显式 phone 会话提供清楚的方向/画布策略，保留已有明确选择 | [方向策略](../../../entry/src/main/ets/services/RemoteOrientationPolicy.ets)，`canUseRustDeskAdaptiveOrientation`、`rustDeskOrientationPolicy` |
| P07 | 同一 display 横竖变化与主动切显示器不具有完全相同的首帧门禁 | 只为目标会话增加几何待提交与输入放行条件；不得改变全局渲染规则 | [显示 gate](../../../entry/src/main/cpp/rustdesk/rustdesk_display_switch_gate.h)，`observeDisplay`；[RemoteDesktop](../../../entry/src/main/ets/pages/RemoteDesktop.ets)，`syncRustDeskDisplayCatalog` |
| P08 | 页面补发 Up 时，Rust 可能已因权限拒绝清队列；页面释放不代表远端收到 | 目标会话停止新输入、清本地手势、展示持续状态；不绕过拒绝 | [RemoteDesktop](../../../entry/src/main/ets/pages/RemoteDesktop.ets)，`releaseRustDeskInputBeforeBlock`；[control inbox](../../../rustdesk_ffi/src/control_inbox.rs)，`update_permission` |

P05 是按代码符号推导的行为差异；P07/P08 是时序保证不足。均未进行设备故障复现，不写成已复现的卡键、误点或旋转故障。

已有直接触控 MOVE → LEFT_DOWN → MOVE → LEFT_UP、手机长按交给被控端识别、双指避免误发右键、Fit/坐标映射、后台输入隔离等基础继续复用。只补齐本计划目标会话内的差距，不重新整理其他分支。

## 4. 官方行为契约

1. 手机专用“返回”：Android 被控 RustDesk 1.3.8 起使用 Back 按钮，旧版按官方规则兼容右键；新版右键释放是长按。版本未知时不能伪装已核验，也不能将未知按钮降级为左键。原非 phone 鼠标路径不变。
2. 主页使用中键点击，最近应用使用中键按住后释放；手机按钮以受 session/owner/generation 约束的事务实现。界面消失、权限变化和会话终止后不得继续定时操作。
3. 音量、电源使用经官方接收端核对的键序列；电源表示系统电源菜单，不承诺锁屏绕过或任意解锁。
4. 手指直接触控使用远端绝对点；实体触控板连续平移使用官方 TouchPan；本地画布平移是独立操作。坐标、符号和旋转转换集中在目标会话适配层。
5. 官方 Android 接收端没有 TouchScale 原生双指缩放实现。因此本计划只保证本地画布缩放，不新增手机 App 原生多点缩放。已保存的全局远端缩放开关保留，仅在当前目标会话中限制不可用能力。
6. 实际 peer 平台/版本/权限是动作能力依据，但它们永远不能越过“用户显式选择 phone”的首要条件。

官方来源（固定版本）：

- [1.4.9 发布](https://github.com/rustdesk/rustdesk/releases/tag/1.4.9)。
- [控制端手机动作与实体触控板](https://github.com/rustdesk/rustdesk/blob/1.4.9/flutter/lib/models/input_model.dart)：`onMobileBack`、`onMobileHome`、`onMobileApps`、`onPointerPanZoomStart/Update/End`。
- [官方 Android 输入接收](https://github.com/rustdesk/rustdesk/blob/1.4.9/flutter/android/app/src/main/kotlin/com/carriez/flutter_hbb/InputService.kt)：`onMouseInput`、`onTouchInput`、`onKeyEvent`。
- [PointerDeviceEvent 分发](https://github.com/rustdesk/rustdesk/blob/1.4.9/src/server/connection.rs)：Android 分发 PanStart/Update/End，未分发 ScaleUpdate。
- [官方触摸模式](https://github.com/rustdesk/rustdesk/blob/1.4.9/flutter/lib/models/model.dart)、[手势处理](https://github.com/rustdesk/rustdesk/blob/1.4.9/flutter/lib/common/widgets/remote_input.dart)。

## 5. 分阶段执行计划（S0–S4 代码待独立复核，S5 设备验收未执行）

| 阶段 | 限定工作 | 完成条件 |
|---|---|---|
| S0 范围锁定 | 刷新基线；固定显式 phone 判定、会话身份及正负例；记录原有非目标路径行为 | 先证明 Android 自动识别不能扩大范围；并行修改清楚分离 |
| S1 手机会话策略 | 专用有效输入模式、真实平台/版本/权限能力；处理未知及不匹配；默认直触但保留全局偏好 | P01；全部入口都依赖显式选择，关闭/切换后无状态污染 |
| S2 手机操作栏 | 仅目标会话可见/可触发的返回、主页、最近应用、音量、电源；窄发送适配与取消 | P02；官方版本契约正确；非 phone 不新增按钮、不改变任何鼠标事件 |
| S3 手机手势 | 目标会话的手指、鼠标、实体触控板、pan 符号、本地双指画布缩放及边界释放 | P03–P05；不调用 Android 不支持的远端缩放；共享队列算法不变 |
| S4 手机画面与输入状态 | 目标会话的方向、键盘占用视区、同屏几何切代、权限关闭恢复和输入终止 | P06–P08；不改其他会话窗口方向/渲染/权限状态机 |
| S5 限定验收 | 同手机官方 A/B，完成目标正例与全部隔离负例；记录未验证边界 | 无关键误操作；所有非目标路径行为与基线一致；不得靠修复其他模块使验收变绿 |

文字输入仅验收当前手机会话入口、焦点与可用视区的衔接。若发现通用 IME、字符编码或键盘框架缺陷，只记录为范围外依赖，不在本计划修复。剪贴板/文件/音频/聊天同样只检查未受影响，不增设实施阶段。

## 6. 文件及改动约束

- 优先新增手机专用策略/动作适配文件及对应定向测试，避免复制或重构共用实现。
- 可能增加受限调用点的文件：`RemoteDesktop.ets`、`RemoteSessionTopBar.ets`、`RemoteSessionTopBarPolicy.ets`，以及确需新增手机动作 API 的 `ExtensionLoader.ets`、NAPI 类型声明、`extension_loader_napi.cpp`、`rustdesk_bridge.{h,cpp}`、`rustdesk_ffi/src/{lib,connector}.rs`。
- 上述清单不是整个文件的修改授权。每个改动点必须说明显式 phone 条件如何保护它，如何在另一会话/失效代际/普通协议下保持无副作用。
- native 无法仅靠按钮枚举判定作用域时，必须采用受会话身份约束的手机专用入口或上下文；不得将一个新增全局布尔值供所有会话共用。
- 方向/几何与权限相关共用文件是证据和复用对象；若需要修改，也只能新增手机会话限定的策略接入，不能替换原有全局默认规则。
- 每个增量先检查允许路径与实际 diff；存在排除项改动即视为范围失败。局部修复各自提交，保护其他任务改动。
- 不创建新任务分支或持久 worktree，不修改全局配置，不升级依赖，不提交设备数据或机器路径。

## 7. 验收矩阵

正例全部先满足：用户明确选「控制手机」且协议为 RustDesk。控制端覆盖 PC/Pad/Phone 及鼠标、实体触控板、手指；实际 Android 覆盖不同厂商、Android 12 及以下与 13+；RustDesk 1.4.9 为主，旧版兼容承诺需增加 1.3.8 前版本。API 26 与保留 API 23 目标按设备可用性分别记录。

| 编号 | 目标会话正例 | 通过标准 |
|---|---|---|
| A01 | 显式 phone，实际 Android，原全局触控板模式 | 手指有效模式正确；不写回全局 |
| A02 | 实际平台未知/非 Android | 不伪造专用能力；不自动修改用户类型 |
| A03 | 返回：新旧被控版本 | 正确 Back/兼容语义；不误发左键 |
| A04 | 右键、长按与返回 | 新版长按和返回分离，无双触发 |
| A05 | 主页与最近应用 | 点击/按住时序正确；无残留中键 |
| A06 | 最近应用事务中退出/取消/重连 | 旧定时器不发送到后续会话 |
| A07 | 音量与电源菜单 | 手机动作准确，不改变本机状态 |
| A08 | 单击、双击、四角/中心点按 | 稳态命中误差不超过 2 个远端像素，无重复点击 |
| A09 | 长按选择、拖图标、快速及斜向滑动 | 跟手方向正确，结束无残留拖动 |
| A10 | 滑出画面、Cancel、第二/第三指介入 | 不补错误点击，终止后重新起序列 |
| A11 | 实体触控板横纵/斜向平移 | TouchPan 起止成对、方向正确、速度可控 |
| A12 | 实体触控板捏合 | 不误发桌面快捷键；只按本地画布能力处理 |
| A13 | Phone/Pad 双指缩放和平移 | 单指升级双指无误长按/返回；抬指不补点 |
| A14 | 历史远端 App 缩放开关开启 | 当前手机会话不虚报原生缩放；原偏好不被改写 |
| A15 | 画布 0/90/180/270 度与缩放 | 显示、光标、点按、pan 契约一致 |
| A16 | 远端旋转：通知先到/帧先到/连续旋转 | 新输入几何不得搭配旧画面误点 |
| A17 | 窗口变化、键盘出现、最小化/PIP/恢复 | 仅当前目标视区正确；不操作时输入被隔离 |
| A18 | 仅观看、拒绝输入、拖动中撤销再开放 | 原因清楚、不绕过拒绝、不重放旧输入 |
| A19 | 中文/emoji/选区/功能键及软键盘衔接 | 记录现有能力与限制；不以此扩展通用 IME 修改范围 |
| A20 | 熄屏唤醒、服务重启、LAN/中继重连 | 仅验证手机适配的身份/权限/几何恢复；不修改网络或授权机制 |

下面是交付阻断项，不是其他模组的新需求。出现回归只撤销或修正本计划增量，禁止顺带修改被回归模组。

| 编号 | 隔离负例 | 必须保持的结果 |
|---|---|---|
| N01 | 选择 computer，但 peer 是 Android | 新计划不启用；原输入/UI/方向行为不变 |
| N02 | 未填写/默认/非法/来源不明，以及 Pro 平台锁定自动生成 phone | 不推断用户选择、不启用、不迁移记录 |
| N03 | 控制端是手机，但目标选 computer | 不因本机形态启用手机目标逻辑 |
| N04 | 普通 Windows/macOS/Linux RustDesk 会话 | 无新增手机 UI/动作；键鼠、缩放、方向不变 |
| N05 | RDP、SSH/SFTP、VNC、Moonlight | 新入口不可触发；事件流与既有功能不变 |
| N06 | 手机会话退出后进入普通会话 | 无 timer/模式/视口/权限/按钮状态继承 |
| N07 | 多窗口目标会话与普通会话并存 | 手机操作只作用所属 session/owner/generation |
| N08 | 保存的全局模式/缩放/方向及主机配置 | 操作前后持久值不变；显式选择不被自动覆盖 |
| N09 | 绕过 UI 直接调用新增动作入口 | 非目标/失效身份请求无副作用，不能回退左键 |
| N10 | 目标会话操作前后的文件/剪贴板/音频/聊天 | 行为不变；不新增、重构或修改其服务 |
| N11 | Pro、账号、云同步、远程 AI、其他主机 | 无代码/配置/状态/存储副作用 |
| N12 | 开关回滚本次手机专用适配 | 只回滚本增量，普通会话与并行任务无需一起回退 |

性能使用同手机同网络的官方 A/B，记录首帧、输入反馈 p50/p95、帧率与资源占用；阈值待基线实测，不填写虚构数值。不允许为追求该指标修改共用编解码器或其他协议。

## 8. 执行与验证记录

用户已授权实施。执行开始基线为 `4719e6dcd`，继续同一活动分支，保护并行 Pro/RDP 增量。每个代码增量按项目要求完成定向测试、当次 `default@OhosTestCompileArkTS`、签名 `assembleHap`、适用双 ABI、Light 合规、`git diff --check` 与独立复核。所有范围隔离负例均为完成条件；构建成功不能代替设备体验证明。

### 8.1 计划保存阶段的历史记录

以下是最初只保存计划时的记录，不代表实施阶段当前构建状态：

- 结构/范围/引用：PASS；20 项手机会话正例、12 项隔离负例，仓库相对引用均存在，未引用临时路径。
- `default@OhosTestCompileArkTS`：FAIL，exit 255，`BUILD FAILED in 1 s 475 ms`；`default@CompileResource` 报 `11211117`，中间资源 `string 2.json` 与 `string.json` 的 `page_show` 重复。初次沙箱缓存 EPERM 已经通过授权重试消除，最终失败为资源冲突。
- 签名 `assembleHap`：FAIL，exit 255，`BUILD FAILED in 741 ms`；同一资源冲突，未执行至签名成功。
- Light 合规：PASS，exit 0，`Open-source compliance gate passed (Light).`；文档 whitespace：PASS；逐行尾空白与文件末尾检查通过，`git diff --no-index --check /dev/null <本计划路径>` 无错误输出（exit 1 为新增文件差异状态）。
- 设备验证：未执行；所有实施阶段均未开始。

本次两项构建失败仅作为当前工作区门禁事实；没有证据将资源重复归因于本计划文本，也未清理缓存、修改资源、修复并行代码或安装应用。计划文件已保存，应用构建门禁尚未通过，不作完整工程交付声明。

本次执行命令（应用根目录，按顺序）：

```sh
source scripts/macos_env.sh
hvigorw --mode module -p module=entry -p product=default default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon
hvigorw --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --no-daemon
pwsh -NoProfile -File scripts/verify_open_source_release.ps1 -Mode Light -RepositoryRoot .
```

### 8.2 已授权的手机限定实现（检查点待复核）

- S0/S1：独立 `RustDeskExplicitPhonePolicy` 校验 protocol、phone、manual 及无 Pro 推导字段；连接配置只复制本次选择，不修改主机、偏好或 schema。有效手指模式临时为直触。保留原 `isRustDeskPhoneSession*` 与非目标路径。
- S2：独立手机菜单提供返回、主页、最近应用、音量和电源菜单。Android/版本由已认证 PeerInfo 决定；未知版本不发返回。专用 native/FFI 入口验证 session、owner、generation 和同 session 下的 transport epoch；延迟释放不会投向重连后的核心。普通鼠标按钮映射未改。
- S3：实体触控板用成对 TouchPan，集中用绝对端点差表达 Android 减法语义；捏合只用已有本地画布能力，不发远端 TouchScale 或桌面快捷键。取消、权限关闭、退出、几何变化清本地手机事务；不写全局方向/缩放/输入模式。
- S4：方向菜单只改变本次手机会话的方向策略，初值保留已有主机方向选择。持续显示仅观看、权限、平台或画面等待状态。手机专用几何 gate 等待 display epoch、编码尺寸、实际成功呈现的纹理比例和页面坐标采用；非 phone 不安装 renderer observer、不开启 Rust phone input barrier。原渲染变换规则和共享 TouchScale 合并算法未改。
- 定向验证：14 项生产策略/页面/定时器宿主检查 PASS；18 项 native gate/原显示切换检查 PASS；4 项 Rust 手机版本、动作编码、FFI 事务、权限/几何隔离检查 PASS；18 项原 RDP 直接触控回归 PASS。
- 当次门禁：`default@OhosTestCompileArkTS` exit 0，`BUILD SUCCESSFUL in 7 s 904 ms`；签名 `assembleHap` exit 0，`BUILD SUCCESSFUL in 1 min 6 s 929 ms`，`SignHap... after 960 ms`；Light 合规与 `git diff --check` PASS。最终双 ABI 与独立复核结果随后追加。
- 构建环境处理：仅逐字节核验并移出 `resource_str` 四个语言目录中的重复生成 `string 2.json` 至临时备份，未修改源资源或全局构建配置；前两次重跑先后被 base/en_US 重复资源阻断。
- S5：设备条件已询问，尚未收到。本记录不宣称实际点击误差、手势符号/速度、旧版 Android 返回、软键盘、熄屏、LAN/中继、性能 A/B 或非目标协议完整设备矩阵通过。
- 并行边界：同一工作区另有 Pro/RDP 接续与独立呈现指标改动；手机提交只包含本计划 hunks，不为这些任务授予范围或写审查结论。活动分支尚有其他任务，不能以本增量代替整分支 PR/合并闭环。


## 9. 初次独立复核阻塞与最小范围授权过程（历史，2026-09-08）

`/root/review_explicit_phone` 对 `08ccf6b6` 的独立复核为 FAIL：

1. 共享 renderer 的零上下文选择暂存造成提交快照函数错位。工作树构建成功未覆盖此快照；已从索引快照重建正确函数位置，并用准确索引 cpp/header 完成 arm64-v8a/x86_64 syntax 检查。后续不得将含并行变更的工作树构建等同独立提交验证。
2. 来源证明不足：生产 `RemoteHost.fromJSON` 会将缺失/空 sourceType 归一化成 manual；旧记录 target=phone 因而误被判为显式选择。14 项原 host 检查没有覆盖这条生产归一化链，不能证明 N02。
3. 旧 batch 重放：仅 bool 几何门无法淘汰 sender 已 dequeue 的旧输入。已加手机专用 epoch，dequeue 在手机门锁内捕获，关闭递增，发送持锁核对；close/reopen 后旧 batch 回归检查通过，Rust 全量 313 PASS。普通会话保留现有队列行为。
4. 实际呈现证明不足：新 540×1200 通知/编码帧之后，旧 1080×2400 纹理因同宽高比可误确认新 epoch。需将真实解码输出身份带到成功呈现回执，不能以最新全局 epoch 或当前 Decode 调用代替输出帧身份。

当时检查点保护（已由第 10 节授权修复取代）：`explicitPhoneImplementationReady()` 固定 false，连接配置先检查此门；这批新手机策略不进入应用会话。现有控制手机行为继续使用原路径。此保护并非问题 2/4 已修复，也不作为功能验收 PASS。

计划第 1.4 节禁止“为确认来源而修改 Pro、导入/同步或存储结构”，第 2 节排除了“编解码器”。现有作用域无法提供上述两项证明，先保留检查点，不扩大修改。拟请求的最小扩展仅为：

- **选择证据边界**：允许在现有用户选项及记录反序列化边界传递手机专用选择来源证据；缺失/默认/自动推导保持未知，未知只能由用户重新明确选择获得。仅消费者为本计划手机入口，不改 Pro 推断、存量字段含义、其他主机行为、数据库 schema，不批量迁移。
- **呈现证据边界**：允许在 RAW/硬件解码输出与 renderer 成功呈现之间增加手机专用帧身份旁路回执；RAW 使用实际输出 AVFrame PTS，硬件核对输出 PTS 和已 Update 的 NativeImage timestamp。保留纹理重绘沿用原身份；映射未知持续阻断，不改 codec 算法、全局变换或非手机帧路由。

硬件 SDK 的现有头文件没有证明 NativeImage timestamp 与输入 PTS/AtTime 的映射，不能假定直接相等或固定倍数。授权后仍须官方证据/定向验证及真机证明；不能用构建成功替代。

S5 全部真机正例及 N01–N12 隔离负例仍 NOT RUN。当前不 push/merge 整个含并行未完成 Pro 工作的活动分支。

### 本轮检查点结果

- 修复提交：`35d3855c`；同一 reviewer 窄复查确认快照错位修复、已出队旧 batch 拒绝、正常新连接新增入口关闭。整体仍 BLOCKED，原来源/画面问题没有冒充解决。
- 验证：15 phone host checks；Rust 313 PASS（reviewer 独立重跑 stale batch 定向 1 PASS）；arm64-v8a/x86_64 Rust 构建 PASS；准确索引 renderer cpp/header 双 ABI syntax PASS；testCompile 16 s 36 ms、signed assembleHap 1 min 6 s 16 ms（SignHap 1 s 17 ms），exit 0；Light/diff PASS。
- 编译限制：App 两门运行于共享工作树，含并行 Pro/RDP 未审变更；单独提交 renderer 另做了准确索引语法检查。没有对整个共享 HAP 作代码审查或设备验收声明。
- 无存储扩展的来源替代方案：允许范围内的 RemoteDesktop 连接边界可要求用户作一次明确的“本次控制手机”选择，凭证只绑定 attempt/目标/配置，取消或更换即失效；不从归一化 manual 恢复证明。该替代会增加连接选择步骤，尚未实施；跨重启免确认则需要选择产生点到持久化的完整证据链，不能只修 policy。
- 页面禁用门不撤销此前已启用的 native 会话，也不是阻止内部直接构造 native 配置的全局开关。本轮未安装或运行此检查点到设备。


## 10. 两条证据边界已授权（2026-09-08）

用户在听取“持久化真实选择标记 + 手机专用实际解码/呈现帧回执”的推荐方案后明确回复“可以”。这仅覆盖下列必要调用边界，不扩展其他协议/Pro 行为、解码算法、输出调度或全局渲染规则。

- 选择标记由经典/新版添加编辑界面的真实“控制手机”点击产生，本机 localextensions 保存；RemoteHost 只保留运行时镜像，通用 toJSON/fromJSON 不序列化或恢复标记。因此缺省、导入和云端字段无法产生选择证明，旧记录需重新点击一次。动态 LAN 本机记录也保存独立标记。无数据库 schema 或云端表变更。
- 手机解码输入使用单调且不复用的内部 PTS token；原始 timestamp 留在 ingress/receipt 中用于诊断。有限映射保存该帧 owner、transport、geometry、display 与编码尺寸；RAW 查实际 AVFrame::pts，硬解先确认实际输出 attr.pts，再以成功 UpdateSurfaceImage 后的 GetTimestamp 原值匹配。未知映射不猜测、不放行。
- 已成功呈现后才回执；旧纹理保留旧 ticket，decoder clear/rebind 使旧 ticket 失效。帧身份只在 phone receipt 非空时创建，普通输入 timestamp 与即时/AtTime 调度维持原实现。
- 手机新增 GLRenderer observer 全部撤去，回执放到 decoder 现有的成功呈现 callback，避免污染其他会话和并行 Pro 指标。
- 公开 OpenHarmony 证据：HDecoder `7ed395e1fc920c2cae2bd2834437c48eac5b8d6b` 的 FlushBuffer 使用输出 PTS 原值作为 timestamp，AtTime 的 desiredPresentTimestamp 单独保存；SurfaceImage `46a11e91c9709942196ad2a7afea2e0fcd1349f3` 保存实际 Acquire buffer 的 timestamp。它们是公开旧快照，不能替代 HarmonyOS API23/26 真机证据；实现严格匹配原值，失败保持输入关闭。

### 10.1 追加复核问题与修复

- 本机标记不能进入便携备份。remotehosts 导出 payload 仅剔除 `localrustdeskphonechoice`；完整/脱敏备份可用且不能恢复选择证明。两个本机 rollback snapshot 校验入口仅允许该字段严格为 `'1'`，保留同设备事务回滚；portable/import 默认仍拒绝。生产 create/validate 及来源恢复回归通过，源本机数据未被导出操作修改。
- 帧 epoch 必须在 Rust socket/ACK 路径入队时与 display/width/height 在同一锁下捕获，不能出队后按当前几何补标签。V2 回调期间通过线程、帧指针和 userData 精确匹配的 RAII 旁路读取不可变 epoch，退出恢复前值，跨线程/错误身份/缺失符号返回 0。V1/V2 ABI 仍为 48/56 字节，普通队列、解码调度与回调签名 ABI 保持原有契约。
- 生产 dispatch→worker queue→A/B/A 通知→实际出队回调回归，验证旧 A 不会被贴为新 A；独立复核已重跑。C++ 的手机 receipt 立即捕获该值，不再调用当前 gate 推导 epoch。
- 代码检查点 `f37ecffe8` 的 26 个完整目标文件已提交；额外四文件修复已单独提交 `b97808f5`。准确索引 native 五个 cpp 及头文件完成 arm64-v8a/x86_64 syntax 验证，未将共享工作树构建等同独立提交快照。
- 当前定向证据：15 手机宿主、9 来源/备份宿主、30 native、Rust 全量 315 检查通过。同一 reviewer 独立复跑来源/备份 9、策略 15、native 30、Rust phone_geometry 3 通过。最终当次 testCompile `BUILD SUCCESSFUL in 5 s 918 ms`、签名 assembleHap `BUILD SUCCESSFUL in 7 s 301 ms`（SignHap 1 s 86 ms），均 exit 0；Light/diff PASS。两个 ABI 的实际 librdpnapi.so 中 `rustdesk_current_phone_frame_geometry_epoch_v1` 均为已定义 T 符号。同一 reviewer 正式 PASS 绑定 `b97808f5c6ccaef1cda879e263d27f09f231273d`，沿用 `08ccf6b6 → 35d3855c → f37ecffe` 的范围复核；无剩余代码问题。

S5 真机仍未验收：A01–A20 与 N01–N12 的设备矩阵、实际 NativeImage timestamp 映射、精度/速度、首帧/反馈 p50/p95、API23/26 PC/Pad/Phone 与 Android 厂商/版本、LAN/中继均不得以以上宿主或构建证据替代。
