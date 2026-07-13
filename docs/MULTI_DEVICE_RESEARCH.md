# 一次开发多端部署 & PC 端设计 — 理解与实践

> 基于 HarmonyOS 官方文档 + RemoteDesktop/Melotopia 项目实战

---

## 一、断点系统: 四个断点，以窗口宽度 vp 为基准

| 断点 | 宽度 (vp) | 设备 | 布局特征 |
|------|----------|------|---------|
| **sm** | 320 ~ 600 | 手机竖屏 | 单列、底部导航、Bottom Sheet、FAB |
| **md** | 600 ~ 840 | 手机横屏 / 小平板 | Navigation Auto 模式在此处切换为分栏 |
| **lg** | 840 ~ 1440 | 平板 / 折叠屏展开 | 侧边导航适用、Sheet 居中弹出 |
| **xl** | ≥ 1440 | PC / 2in1 / 大屏 | 自由窗口、键盘鼠标、多窗口、垂直侧边栏 |

**核心理念**: 不是"为每种设备写一套 UI"，而是"用同一套代码响应窗口宽度变化"。ArkUI 通过 `@State` + `window.on('windowSizeChange')` 实现实时响应，窗口拖动时 UI 即时重排。

---

## 二、PC 端导航: Navigation > Router

### Router 的问题

RemoteDesktop 当前使用 `router.pushUrl()/replaceUrl()` — 这是**已被官方标记为 deprecated** 的 API。Router 最大的问题是**不支持多端适配**：

- Router 永远是全屏单页跳转，PC 上无法展示"左侧列表 + 右侧详情"的分栏布局
- Router 没有 `NavigationMode.Auto/Split` — 这是多端部署的核心能力

### Navigation 的正确用法

```
Navigation Mode:
  Auto   ← 推荐: 窗口 <600vp 自动 Stack, ≥600vp 自动 Split
  Split  ← 始终分栏: 左导航固定, 右内容切换
  Stack  ← 始终单页 (手机默认)
```

PC (xl) 场景下:
- Navigation 自动进入 **Split 模式**: 左侧竖列导航栏固定，右侧内容区显示当前选中页
- 用户拖动窗口缩小到 <600vp → 自动切换为 Stack 模式 (单页全屏)，导航栏移到底部
- **一套代码，零判断** — Navigation 框架内部处理所有切换

### 当前项目的问题

RemoteDesktop 三个页面 (SshTerminal, RemoteDesktop, LoginPage) 全部用 `router.pushUrl` 跳转而非 Navigation 子页面。这意味着即使窗口 2000vp 宽，它们也是全屏显示的，完全浪费 PC 大屏空间。

**正确的做法**: 根组件用 `Navigation` + `NavPathStack`，所有子页面注册为 `@Builder` 到 `navDestination` 的 pageMap 中。

---

## 三、PC 端 HdsTabs: 底部栏 → 侧边栏

### 当前实现

HostListPage 用 `HdsTabs` + `barPosition(End)` + `vertical(false)` — 始终底部悬浮栏，所有断点一样。

### 正确的多端适配

```typescript
HdsTabs({ controller })
  .barPosition(isPC ? BarPosition.Start : BarPosition.End)
  .vertical(isPC)   // PC: 竖列侧边栏, 手机: 横排底部栏
```

PC 端: `barPosition.Start` + `vertical(true)` → 左侧竖列导航栏，与 Windows/macOS 原生应用一致。栏宽可通过 `barWidth` 或 `navBarWidth` 控制。

---

## 四、PC 端窗口管理

### 自由窗口模式
PC 和 2in1 设备上，HarmonyOS 默认以**自由窗口**（可拖动、可缩放）运行应用。需要:

1. **`module.json5` 声明设备类型**:
   ```json
   "deviceTypes": ["phone", "tablet", "2in1"]
   ```

2. **设置窗口最小/最大尺寸**:
   ```typescript
   win.setWindowLimits({ minWidth: 600, minHeight: 400, maxWidth: 2560, maxHeight: 1600 })
   ```
   当前项目未设置，PC 上窗口可缩到不可用尺寸。

3. **检测自由窗口状态**:
   ```typescript
   win.isInFreeWindowMode()        // 当前是否自由窗口
   win.on('freeWindowModeChange')  // 监听切换
   ```

4. **沉浸式全屏**:
   ```typescript
   win.setWindowLayoutFullScreen(true)
   ```
   当前项目已正确设置。

### 标题栏避让
自由窗口有系统标题栏（最大化/最小化/关闭按钮区域）。调用 `win.getTitleButtonRect()` 获取按钮区域，避免 UI 元素被遮挡。

---

## 五、PC 端输入适配

| 交互 | 手机 | PC 需要额外支持 |
|------|------|---------------|
| 导航 | 触摸滑动 | **键盘快捷键** (Ctrl+N/Tab/Esc) |
| 操作 | 点击/长按/滑动 | **右键菜单** (context menu) |
| 滚动 | 触摸滑动 | **鼠标滚轮 + 触控板** (已自然支持) |
| 焦点 | 无 | **Tab 键焦点循环**、方向键导航 |
| 悬停 | 无 | **hover 态** (当前仅 touch press) |

---

## 六、PC 端布局: Sheet 和卡片

### Sheet 类型
```typescript
preferType: breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER
```
手机: Bottom Sheet (底部弹出)，PC: Center Sheet (居中弹窗) — 当前项目**已正确实现**。

### 卡片宽度
手机: `width('100%')`，PC: `maxWidth(720)` + 居中。
当前项目设置卡片未设 maxWidth，PC 上卡片会拉伸到全屏宽 — 应该加约束。

### 搜索栏
手机: 全宽或 92%，PC: 60%宽 + 居中。
当前项目固定 92%，PC 上偏窄。

---

## 七、当前 RemoteDesktop 项目状态评估

### ✅ 做得对的

| 项目 | 状态 |
|------|------|
| BreakpointUtil 阈值 (600/840/1440) | ✅ 完全正确 |
| AppStorage 同步断点 (`currentBreakpoint`, `isWideScreen`, `isPC`) | ✅ |
| Sheet 断点适配 (BOTTOM/CENTER) | ✅ |
| `deviceTypes: ["2in1"]` | ✅ |
| `setWindowLayoutFullScreen(true)` 沉浸式窗口 | ✅ |
| HdsTabs 悬浮栏 + systemMaterialEffect | ✅ |
| 深色/浅色/跟随系统主题 | ✅ |

### ❌ 需要修复的

| 优先级 | 问题 | 影响 |
|--------|------|------|
| 🔴 P0 | 使用 deprecated Router API，未用 Navigation | PC 端无法分栏，多端部署根基缺失 |
| 🔴 P0 | HostListPage 内重复断点计算 (520vp≠600vp) | 不同页面断点不一致 |
| 🟡 P1 | 未设置窗口最小/最大尺寸 | PC 自由窗口可缩到无法使用 |
| 🟡 P1 | PC 端无侧边栏 (barPosition.Start/vertical=true) | PC 体验不原生 |
| 🟡 P1 | 无键盘快捷键 | PC 基本交互缺失 |
| 🟢 P2 | 无右键菜单/hover 态 | PC 鼠标交互不完整 |
| 🟢 P2 | 卡片/搜索栏无 maxWidth 约束 | PC 大屏布局松散 |

---

## 八、推荐的渐进路线

### Phase 1: 修复基础 (低风险)
1. 统一断点: HostListPage 改为读 `AppStorage.get('currentBreakpoint')`，删除本地 `updateBreakpoint()`
2. 加窗口尺寸限制: EntryAbility 中 `setWindowLimits({minWidth: 360, minHeight: 480})`
3. 卡片加 `maxWidth`: 设置卡片 `maxWidth(720)` + 居中

### Phase 2: Navigation 迁移 (中风险)
4. 将路由从 Router 迁移到 `Navigation` + `NavPathStack`
5. SshTerminal/RemoteDesktop 注册为 NavDestination 子页面
6. PC 端自动获得分栏布局

### Phase 3: PC 原生体验
7. HdsTabs xl 断点切换侧边栏
8. 键盘快捷键 (Ctrl+N 新建主机, Ctrl+F 搜索, Esc 返回)
9. 右键菜单 / hover 态
