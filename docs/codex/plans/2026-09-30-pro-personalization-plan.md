# Pro「个性化方案」实施计划：自定义组合键 + SSH 终端皮肤

状态：IN_PROGRESS（计划确认后按阶段落地）
创建时间：2026-09-30 Asia/Shanghai
范围：Pro 目录项 `pro.personalization`（个性化方案）。本期由两部分组成：
1. **自定义组合键**：转为 Pro 功能（不再向免费用户开放），并重做编辑逻辑、扩大可用按键与动作范围。
2. **SSH 终端皮肤**：字体、文字色、背景色、16 色调色板、光标/选区、功能键栏、顶栏与其他界面配色成套切换，作为 Pro 功能；交互对齐 Termius 的换肤体验。
基线：`codex/pro-purchase-foundation` @ `64610fc38`。

## 0. 现状（代码事实）

### 0.1 自定义组合键
- 数据与校验：`services/RemoteCustomShortcutPolicy.ets`。只允许「≥1 个修饰键 + 1 个主键」，最多 32 个，名称由按键自动生成，不能改名、排序或组成序列；可选主键只有字母、数字、符号、F1–F24、方向键、常用导航键。
- 编辑入口：设置页 `VirtualKeyboardSettingsSheet`（section `custom`）与会话内 `RemoteModifierPanel` 的「自定义」库；会话侧由 `RemoteDesktop`（RDP/RustDesk/VNC）和 `MoonlightStreamPage` 以 `customizationEnabled: true` 打开，**当前对所有用户开放**。
- 发送：`RemoteDesktop.sendShortcutSequence` → `RemoteKeyDispatcher.sendShortcutSequenceMapped`（按下修饰键 → 主键 → 逆序释放）。
- 远端映射已支持但编辑器未开放的键：CapsLock(2074)、ScrollLock(2075)、PrintScreen(2079)、菜单键(2067)、NumLock(2102)、小键盘 0–9(2103–2112)、小键盘 ÷×−+.(2113–2117)、小键盘 Enter(2119)（见 `cpp/rdp/rdp_keymap.h`、`cpp/vnc/vnc_rfb_engine.cpp`）。

### 0.2 SSH 终端外观
- 终端由 xterm.js 5.3（`rawfile/ssh-terminal`）在 WebView 中渲染；`SshXtermSurface` 以 `profileEnabled` 决定是否套用 Profile 的前景/背景/调色板/字体/光标。
- Profile 体系已存在（`services/ssh/profile/SshTerminalProfilePolicy.ets`、`components/ssh/profile/SshTerminalProfileSheet.ets`），但只在「新 SSH 工作台」开启时生效；字体选项 `Menlo / JetBrains Mono / HarmonyOS Sans SC` **在鸿蒙设备上并不存在**（设备 `/system/fonts` 中唯一的等宽字体是 Noto Sans Mono），实际全部回退为系统等宽字体。
- 顶栏/底栏/功能键栏写死为深色：`chromeBg() = '#11151C'`、`chromeChipBg()`、`sshPal() = buildDark(accent)`，终端背景多处写死 `#0D0D0D`。
- 设置页「SSH 终端」卡片提供免费的文字颜色、字号、行距与预览（保留免费）。

## 1. 产品定义

### 1.1 自定义组合键（Pro）

**权益**：`ProEntries.visible('pro.personalization')` 为真时可用。非 Pro：会话面板的「自定义」页显示 Pro 说明卡与开通入口，不显示已保存项；设置页入口隐藏；已保存数据保留，重新开通后恢复。预设组合键（系统内置的常用快捷键库）保持免费。

**操作广度**：
1. 按键分组扩充为：字母、数字、符号、功能键 F1–F24、方向、导航、**系统键**（CapsLock、ScrollLock、NumLock、PrintScreen、菜单键）、**小键盘**（0–9、÷ × − + .、Enter）。
2. 允许**单键动作**：系统键、功能键、小键盘键和导航键可以不带修饰键（例如单独的 PrintScreen、F5）；字母/数字/符号仍要求至少一个修饰键，避免误建成普通输入。
3. **按键序列**：一个自定义项最多 4 步，每步是一个组合（例如 VS Code 的 `Ctrl+K` → `Ctrl+S`），步间隔 80ms 发送。
4. 上限维持 32 个。

**操作逻辑**：
1. 自定义名称（可选，最长 16 字；为空时显示按键标签）。
2. 列表可上移/下移排序、复制、删除（删除需要确认）。
3. 编辑器改为「步骤卡片」：每步上方是修饰键切换（Ctrl/Alt/Shift/Win，macOS 模式显示 Option/Cmd），下方是分组页签 + 按键网格；实时显示整条组合的预览标签；「＋ 添加下一步」追加序列步骤。
4. 连接实体键盘时提供「录制」按钮：按下的组合直接写入当前步骤（`onKeyEvent` 捕获，录制期间不发往远端）。
5. 会话面板中的自定义项按保存顺序显示，名称优先；点按即发送整条序列。

**数据**：`remoteCustomShortcuts:v2`（版本 2：`{ id, name, steps: number[][] }`），读取时自动迁移 v1；序列化仍走白名单校验与 16KB 上限。

### 1.2 SSH 终端皮肤（Pro，对齐 Termius）

参照 Termius 的换肤体验：
- **主题画廊**：设置里以卡片网格展示全部皮肤，每张卡片是该皮肤渲染的迷你终端（提示符、`ls` 彩色输出、光标），点按立即应用并有选中勾；当前皮肤置顶高亮。
- **成套配色**：皮肤不仅改终端文字和背景，还同步改变终端页的顶栏、标签栏、功能键栏（额外按键条）、底部状态栏、面板/弹窗底色、分隔线和强调色，整体观感一致。
- **字体**：独立的字体列表，每项用该字体渲染示例文字；字号、行距沿用现有设置。
- **按主机覆盖**：主机可以指定自己的皮肤（例如生产环境用红色调皮肤提醒）；未指定时用全局皮肤。
- **亮色/暗色皮肤都有**，终端页状态栏文字颜色随皮肤亮度自动切换。

**皮肤定义**（`SshSkin`）：
```
id, name, dark: boolean,
terminal: { background, foreground, cursor, cursorAccent, selection, palette[16] },
chrome:   { bar, barText, barTextDim, chip, chipText, keyBar, key, keyText, keyActive, divider, sheet, accent }
```
所有颜色都是本地常量，不从网络加载。

**内置皮肤（首批 12 款，配色取公开发布的开源终端配色方案）**：默认深色（现有绿字黑底的精修版）、Dracula、Nord、One Dark、Monokai、Solarized Dark、Solarized Light、Gruvbox Dark、Tokyo Night、Catppuccin Mocha、GitHub Light、Material Ocean。

**自定义皮肤（用户自由搭配）**：
- 任一内置皮肤可「复制为自定义」，也可从空白新建；最多保存 20 个自定义皮肤，可改名、删除。
- 编辑器分区：**终端**（背景色、文字色、光标色、选区色、16 色调色板逐格可改）、**字体**（字体、字重、字号、行距）、**界面**（顶栏、功能键栏、按键、按键文字、强调色、面板底色；提供「根据终端背景自动生成」一键搭配）。
- 颜色选择器：常用色板 + 色相/亮度调节 + `#RRGGBB` 输入；编辑时顶部实时预览（迷你终端 + 顶栏 + 功能键栏），保存前可对比「修改前/修改后」。
- 对比度保护：文字与背景对比度低于 3:1 时提示，但不强制。
- 自定义皮肤与内置皮肤一起出现在主题画廊，并随账号同步（`usersettings` 行 `pro.skin.custom.<id>`）。

**内置字体（随应用打包，均为 SIL OFL 1.1 开源许可）**：JetBrains Mono、Fira Code、Source Code Pro、IBM Plex Mono（各含常规与粗体，Latin 子集 woff2，合计约 150KB）；另提供系统自带的 Noto Sans Mono 与「系统默认」。中文等非拉丁字符自动回退到系统字体。许可证文本随字体放入 `rawfile/ssh-terminal/fonts/`，并登记到 `THIRD_PARTY_NOTICES.md` 与 `REUSE.toml`。

**权益与优先级**：
- 皮肤与字体仅 Pro 可用；非 Pro 使用「默认深色」与系统等宽字体，设置里的皮肤/字体入口显示 Pro 标并在非 Pro 时隐藏。
- 生效优先级：会话 Profile 显式设置（工作台）＞ 主机皮肤 ＞ 全局皮肤 ＞ 免费外观设置（文字颜色/字号/行距）。
- 免费外观设置（文字颜色、字号、行距）继续免费；启用皮肤时文字颜色以皮肤为准，设置页会说明这一点。
- Pro 失效后回到免费外观，已选皮肤保留，重新开通后恢复。

**同步**：全局皮肤、字体和主机皮肤映射通过 `usersettings`（`pro.skin.v1`）随账号同步；不包含任何主机地址或凭据。

## 2. 实现设计

### 2.1 新增/修改文件

| 文件 | 内容 |
|---|---|
| `services/pro/personalization/ProPersonalization.ets` | 权益判定 `personalizationAvailable()`，统一走 `ProEntries.visible('pro.personalization')` |
| `services/RemoteCustomShortcutPolicy.ets` | v2 模型（名称、步骤）、新按键分组、单键规则、序列校验、v1→v2 迁移、排序/复制 |
| `components/VirtualKeyboardSettingsSheet.ets` | 新编辑器（步骤卡片、录制、命名、排序），非 Pro 时显示 Pro 说明 |
| `components/RemoteModifierPanel.ets` | 自定义页按权益显示；名称优先；序列发送 |
| `pages/RemoteDesktop.ets`、`pages/MoonlightStreamPage.ets` | `customizationEnabled` 改为按权益；按步骤调用 `sendShortcutSequence` |
| `services/ssh/skin/SshSkinCatalog.ets` | 12 款皮肤常量、字体清单 |
| `services/ssh/skin/SshSkinStore.ets` | 全局皮肤/字体/主机覆盖，读写 `usersettings`，账号作用域，订阅 |
| `services/ssh/skin/SshSkinPolicy.ets` | 解析优先级、Pro 失效回退、颜色校验（纯函数，便于 Node 测试） |
| `components/ssh/skin/SshSkinGallery.ets` | 主题画廊（迷你终端卡片网格） |
| `components/ssh/skin/SshFontPicker.ets` | 字体列表（逐项预览） |
| `components/SshXtermSurface.ets` + `rawfile/ssh-terminal/index.html` | 接收皮肤主题与字体；`@font-face` 声明内置字体；主题切换不重建会话 |
| `pages/SshTerminal.ets` | `chromeBg/chromeChipBg/sshPal` 与写死的 `#0D0D0D` 改为从当前皮肤取值；功能键栏、标签栏、状态栏跟随 |
| `pages/HostListPage.ets` | 设置「SSH 终端」卡片增加「终端皮肤」「终端字体」两行（Pro）；主机编辑器增加「皮肤」选项 |
| `services/pro/ProFeatureCatalog.ets` | `pro.personalization` 描述与进度更新，Debug 可用、Release 保持关闭 |

### 2.2 关键规则
1. 所有新入口登记到 `test_pro_entry_gating`；非 Pro 不显示保存项、不可编辑。
2. 自定义组合键序列发送时每一步都完整按下并释放，不残留修饰键；会话断开或失焦时调用现有 `releaseAllHeldKeys`。
3. 皮肤颜色只接受 `#RRGGBB`；字体名只接受目录内的白名单，WebView 中不拼接任意字符串。
4. 切换皮肤只更新 xterm `options.theme/fontFamily` 与 ArkUI 状态，不断开连接、不清空回滚缓冲。
5. Release 构建中 `pro.personalization` 仍为「敬请期待」，`check_pro_release` 必须通过。

## 3. 分阶段落地

| 阶段 | 内容 | 验收 |
|---|---|---|
| P0 | 目录与门控：`pro.personalization` 调为 experimental；权益工具函数；门控测试登记 | 门控测试 PASS |
| P1 | 自定义组合键转 Pro：会话面板与设置入口按权益显示；非 Pro 说明卡 | 免费/Pro 切换实机检查 |
| P2 | 组合键 v2：命名、排序、复制、系统键与小键盘、单键动作、4 步序列、v1 迁移 | Node 测试覆盖校验/迁移/序列 |
| P3 | 编辑器重做与实体键盘录制；会话面板名称与序列发送 | RDP/RustDesk/VNC/Moonlight 实机发送 |
| S1 | 皮肤目录、Store、Policy 与同步；Pro 失效回退 | Node 测试覆盖优先级与回退 |
| S2 | 终端套用皮肤（xterm 主题）与界面配色（顶栏/功能键栏/标签栏/状态栏/面板） | 12 款皮肤实机走查 |
| S3 | 内置字体打包（下载经用户同意）、`@font-face`、字体选择器、合规登记 | 字体真实生效、Light 合规 PASS |
| S4 | 设置主题画廊、字体选择、主机皮肤覆盖 | Termius 式换肤体验走查 |
| S5 | 自定义皮肤编辑器（终端/字体/界面三区、颜色选择器、实时预览、复制内置皮肤、自动搭配） | 自建皮肤保存、同步、应用 |
| R | Release pruning、独立复核、文档与验收记录 | 复核 PASS |

每个阶段：相关 Node 测试 → `default@OhosTestCompileArkTS` → `assembleHap` → 安装两台设备 → 单独提交。

## 4. 验收清单（新增）

- PZ1 免费用户：会话面板「自定义」页只显示 Pro 说明；设置无自定义组合键入口；预设组合键可用。
- PZ2 Pro 用户：新建带名称的组合键、单键 PrintScreen、小键盘键、2 步序列；排序、复制、删除；旧 v1 数据自动迁移。
- PZ3 RDP、RustDesk、VNC、Moonlight 各发送一次自定义组合键和序列，远端响应正确且无修饰键残留。
- PZ4 实体键盘录制组合键。
- SK1 主题画廊 12 款皮肤预览与实际终端一致；切换即时生效且不断开会话。
- SK2 顶栏、标签栏、功能键栏、状态栏、面板随皮肤成套变化；亮色皮肤下文字清晰。
- SK3 四款内置字体真实生效（与系统等宽字体可见差异）；中文正常回退。
- SK4 主机皮肤覆盖全局皮肤；两台设备同步一致。
- SK6 复制内置皮肤并逐项修改字体、文字色、背景、调色板、功能键栏与顶栏颜色；保存后终端与界面按自定义生效，另一台设备同步可见。
- SK5 Pro 撤销后回到免费外观，重新开通后恢复原皮肤与字体。

## 5. 风险

| 风险 | 对策 |
|---|---|
| 免费用户已有自定义组合键被收回引起不满 | 数据保留不删除；说明卡明确「已保存 N 个，开通 Pro 后恢复」 |
| WebView 字体加载失败 | `@font-face` 失败自动回退系统等宽字体；设置中标注实际生效字体 |
| 亮色皮肤与现有写死深色的组件冲突 | S2 把终端页全部颜色改为皮肤取值，并以亮色皮肤逐页走查 |
| 包体增大 | 仅 Latin 子集 woff2，约 150KB |
