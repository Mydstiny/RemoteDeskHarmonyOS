# RustDesk Session Topbar Experience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a RustDesk-aligned, hideable in-session topbar for PC, Pad keyboard/mouse mode, and phone keyboard/mouse mode, while keeping RustDesk and RDP personalization settings fully independent.

**Architecture:** Put feature decisions in pure ArkTS policy modules with unit tests, then render a focused `RemoteSessionTopBar` component from `RemoteDesktop.ets`. Runtime actions that already exist call `ExtensionLoader`; unavailable RustDesk-official actions are shown disabled with a precise reason instead of pretending to work.

**Tech Stack:** ArkTS + ArkUI API 23, `AppStorage` / Preferences, existing `ExtensionLoader`, existing RustDesk native bridge.

## Global Constraints

- UI/interaction changes must be designed before implementation and verified before completion.
- RustDesk topbar applies to RustDesk sessions only.
- PC mode means `isDesktopDevice === true`, regardless of `currentBreakpoint`; small PC windows and full-screen PC windows both show the topbar.
- Pad/phone topbar applies only when `rustdeskControlMode === 2`.
- RDP settings keys stay under `rdp*`; RustDesk settings keys stay under `rustdesk*`.
- Do not change RDP stable startup rules: no ArkTS TCP preflight; initial renderer uses remote desktop size; real surface resize happens after renderer creation.
- Do not silently replace historical HostList bottom `HdsTabs`.
- Unsupported RustDesk official functions must be visibly disabled with a reason.
- Every code task runs targeted tests or at least `git diff --check`; build verification runs before final completion.

---

## File Structure

- Create `entry/src/main/ets/services/RemoteSessionTopBarPolicy.ets`
  - Owns pure visibility, layout, menu availability, and protocol-specific preference key rules.
- Create `entry/src/test/RemoteSessionTopBarPolicy.test.ets`
  - Unit coverage for PC small/full window visibility, Pad/phone keyboard/mouse visibility, RDP exclusion, disabled official actions, and RDP/RustDesk setting key separation.
- Modify `entry/src/test/List.test.ets`
  - Registers the new policy tests.
- Create `entry/src/main/ets/components/RemoteSessionTopBar.ets`
  - Renders the RustDesk-style topbar and menus. Receives state and callbacks from `RemoteDesktop`; does not call native APIs directly.
- Modify `entry/src/main/ets/pages/RemoteDesktop.ets`
  - Hosts the component only for RustDesk when policy says visible. Implements callbacks for disconnect, refresh, keyboard, file transfer, Ctrl+Alt+Del, privacy/audio/clipboard/session UI toggles, and disabled action toasts.
- Modify `entry/src/main/ets/pages/HostListPage.ets`
  - Cleans up misleading RDP preference persistence calls and adds separate RustDesk clipboard/file-paste settings if needed by the topbar.
- Optionally modify `entry/src/main/ets/types/rdpnapi.d.ts`, `entry/src/main/ets/services/ExtensionLoader.ets`, and native bridge files only if an already-supported action lacks a typed wrapper.

---

### Task 1: Pure Topbar Policy And Tests

**Files:**
- Create: `entry/src/main/ets/services/RemoteSessionTopBarPolicy.ets`
- Create: `entry/src/test/RemoteSessionTopBarPolicy.test.ets`
- Modify: `entry/src/test/List.test.ets`

**Interfaces:**
- Produces:
  - `export type RemoteTopBarDeviceClass = 'pc' | 'pad' | 'phone'`
  - `export type RemoteTopBarMenuId = 'control' | 'display' | 'keyboardMouse' | 'chat' | 'voice' | 'record'`
  - `export interface RemoteTopBarContext`
  - `export interface RemoteTopBarLayout`
  - `export interface RemoteTopBarActionAvailability`
  - `export function remoteTopBarDeviceClass(isDesktopDevice: boolean, breakpoint: string): RemoteTopBarDeviceClass`
  - `export function shouldShowRustDeskTopBar(protocol: string, isDesktopDevice: boolean, breakpoint: string, rustdeskControlMode: number): boolean`
  - `export function remoteTopBarLayout(isDesktopDevice: boolean, breakpoint: string): RemoteTopBarLayout`
  - `export function rustDeskActionAvailability(actionId: string): RemoteTopBarActionAvailability`
  - `export function protocolPreferenceOwner(key: string): string`
- Consumes: no production code beyond primitive values.

- [ ] **Step 1: Write failing tests**

Add this file:

```ts
import { describe, it, expect } from '@ohos/hypium';
import {
  protocolPreferenceOwner,
  remoteTopBarDeviceClass,
  remoteTopBarLayout,
  rustDeskActionAvailability,
  shouldShowRustDeskTopBar
} from '../main/ets/services/RemoteSessionTopBarPolicy';

export default function remoteSessionTopBarPolicyTest() {
  describe('RemoteSessionTopBarPolicy_visibility', () => {
    it('pc_rustdesk_should_show_on_small_window', 0, () => {
      expect(shouldShowRustDeskTopBar('rustdesk', true, 'md', 0)).assertTrue();
    });

    it('pc_rustdesk_should_show_on_full_window', 0, () => {
      expect(shouldShowRustDeskTopBar('rustdesk', true, 'xl', 0)).assertTrue();
    });

    it('phone_rustdesk_should_show_only_in_keyboard_mouse_mode', 0, () => {
      expect(shouldShowRustDeskTopBar('rustdesk', false, 'sm', 2)).assertTrue();
      expect(shouldShowRustDeskTopBar('rustdesk', false, 'sm', 0)).assertFalse();
      expect(shouldShowRustDeskTopBar('rustdesk', false, 'sm', 1)).assertFalse();
    });

    it('pad_rustdesk_should_show_only_in_keyboard_mouse_mode', 0, () => {
      expect(shouldShowRustDeskTopBar('rustdesk', false, 'lg', 2)).assertTrue();
      expect(shouldShowRustDeskTopBar('rustdesk', false, 'lg', 0)).assertFalse();
    });

    it('rdp_should_not_show_rustdesk_topbar', 0, () => {
      expect(shouldShowRustDeskTopBar('rdp', true, 'xl', 2)).assertFalse();
      expect(shouldShowRustDeskTopBar('rdp', false, 'sm', 2)).assertFalse();
    });
  });

  describe('RemoteSessionTopBarPolicy_layout', () => {
    it('device_class_should_prefer_desktop_device_over_breakpoint', 0, () => {
      expect(remoteTopBarDeviceClass(true, 'sm')).assertEqual('pc');
      expect(remoteTopBarDeviceClass(false, 'lg')).assertEqual('pad');
      expect(remoteTopBarDeviceClass(false, 'sm')).assertEqual('phone');
    });

    it('pc_small_window_layout_should_be_compact_but_not_mobile', 0, () => {
      const layout = remoteTopBarLayout(true, 'md');
      expect(layout.deviceClass).assertEqual('pc');
      expect(layout.iconSize).assertEqual(44);
      expect(layout.maxVisibleButtons).assertEqual(7);
    });

    it('phone_layout_should_limit_visible_buttons', 0, () => {
      const layout = remoteTopBarLayout(false, 'sm');
      expect(layout.deviceClass).assertEqual('phone');
      expect(layout.iconSize).assertEqual(40);
      expect(layout.maxVisibleButtons).assertEqual(5);
    });
  });

  describe('RemoteSessionTopBarPolicy_actions', () => {
    it('existing_actions_should_be_enabled', 0, () => {
      expect(rustDeskActionAvailability('disconnect').enabled).assertTrue();
      expect(rustDeskActionAvailability('refreshFrame').enabled).assertTrue();
      expect(rustDeskActionAvailability('fileTransfer').enabled).assertTrue();
      expect(rustDeskActionAvailability('ctrlAltDel').enabled).assertTrue();
    });

    it('unwired_official_actions_should_be_disabled_with_reason', 0, () => {
      const chat = rustDeskActionAvailability('textChat');
      expect(chat.enabled).assertFalse();
      expect(chat.reason.length > 0).assertTrue();
      const record = rustDeskActionAvailability('recordSession');
      expect(record.enabled).assertFalse();
      expect(record.reason.length > 0).assertTrue();
    });
  });

  describe('RemoteSessionTopBarPolicy_preferences', () => {
    it('rustdesk_keys_should_not_be_owned_by_rdp', 0, () => {
      expect(protocolPreferenceOwner('rustdeskImageQuality')).assertEqual('rustdesk');
      expect(protocolPreferenceOwner('rustdeskCodec')).assertEqual('rustdesk');
      expect(protocolPreferenceOwner('rustdeskControlMode')).assertEqual('rustdesk');
      expect(protocolPreferenceOwner('rustdeskClipboardEnabled')).assertEqual('rustdesk');
    });

    it('rdp_keys_should_not_be_owned_by_rustdesk', 0, () => {
      expect(protocolPreferenceOwner('rdpDesktopPreset')).assertEqual('rdp');
      expect(protocolPreferenceOwner('rdpColorDepth')).assertEqual('rdp');
      expect(protocolPreferenceOwner('rdpControlMode')).assertEqual('rdp');
      expect(protocolPreferenceOwner('rdpClipboardEnabled')).assertEqual('rdp');
    });

    it('shared_visual_keys_should_be_shared', 0, () => {
      expect(protocolPreferenceOwner('currentTheme')).assertEqual('shared');
      expect(protocolPreferenceOwner('accentColor')).assertEqual('shared');
    });
  });
}
```

Modify `entry/src/test/List.test.ets`:

```ts
import remoteSessionTopBarPolicyTest from './RemoteSessionTopBarPolicy.test';
```

and inside `testsuite()`:

```ts
remoteSessionTopBarPolicyTest();
```

- [ ] **Step 2: Run tests to verify failure**

Run the project test target if available in DevEco, or proceed with source-level red check:

```powershell
rg -n "RemoteSessionTopBarPolicy" entry/src/main/ets entry/src/test
```

Expected before implementation: only the new test import references the missing policy module.

- [ ] **Step 3: Implement the policy**

Create `entry/src/main/ets/services/RemoteSessionTopBarPolicy.ets`:

```ts
export type RemoteTopBarDeviceClass = 'pc' | 'pad' | 'phone';

export type RemoteTopBarMenuId =
  'control' | 'display' | 'keyboardMouse' | 'chat' | 'voice' | 'record';

export interface RemoteTopBarContext {
  protocol: string;
  isDesktopDevice: boolean;
  breakpoint: string;
  rustdeskControlMode: number;
}

export interface RemoteTopBarLayout {
  deviceClass: RemoteTopBarDeviceClass;
  iconSize: number;
  itemGap: number;
  topOffset: number;
  maxVisibleButtons: number;
  menuWidth: number;
}

export interface RemoteTopBarActionAvailability {
  enabled: boolean;
  reason: string;
}

const RUSTDESK_ENABLED_ACTIONS: string[] = [
  'disconnect',
  'refreshFrame',
  'fileTransfer',
  'ctrlAltDel',
  'lockRemote',
  'toggleKeyboard',
  'displaySettings',
  'keyboardMouseSettings',
  'togglePrivacyMode',
  'toggleAudio',
  'toggleClipboard',
  'screenshot'
];

const RUSTDESK_DISABLED_REASONS: Record<string, string> = {
  'textChat': '文字聊天需要 RustDesk 会话消息通道接入后启用',
  'voiceCall': '语音通话需要 RustDesk 音频输入和通话信令接入后启用',
  'recordSession': '录制需要本地录屏/编码保存链路接入后启用',
  'remoteCamera': '查看摄像头需要 RustDesk 摄像头流接入后启用',
  'terminal': '终端需要 RustDesk 远程 shell 能力接入后启用',
  'tcpTunnel': 'TCP 隧道需要 RustDesk tunnel 控制通道接入后启用',
  'reverseAccess': '反转访问方向需要 RustDesk 反向会话协议接入后启用',
  'blockRemoteInput': '阻止用户输入需要远端权限控制协议接入后启用',
  'restartRemote': '重启远程电脑需要远端系统命令协议接入后启用'
};

export function remoteTopBarDeviceClass(isDesktopDevice: boolean, breakpoint: string): RemoteTopBarDeviceClass {
  if (isDesktopDevice) {
    return 'pc';
  }
  if (breakpoint === 'md' || breakpoint === 'lg' || breakpoint === 'xl') {
    return 'pad';
  }
  return 'phone';
}

export function shouldShowRustDeskTopBar(
  protocol: string,
  isDesktopDevice: boolean,
  breakpoint: string,
  rustdeskControlMode: number
): boolean {
  if (protocol !== 'rustdesk') {
    return false;
  }
  if (isDesktopDevice) {
    return true;
  }
  return rustdeskControlMode === 2;
}

export function remoteTopBarLayout(isDesktopDevice: boolean, breakpoint: string): RemoteTopBarLayout {
  const deviceClass = remoteTopBarDeviceClass(isDesktopDevice, breakpoint);
  if (deviceClass === 'pc') {
    return { deviceClass, iconSize: 44, itemGap: 8, topOffset: 8, maxVisibleButtons: 7, menuWidth: 360 };
  }
  if (deviceClass === 'pad') {
    return { deviceClass, iconSize: 44, itemGap: 8, topOffset: 8, maxVisibleButtons: 6, menuWidth: 340 };
  }
  return { deviceClass, iconSize: 40, itemGap: 6, topOffset: 6, maxVisibleButtons: 5, menuWidth: 300 };
}

export function rustDeskActionAvailability(actionId: string): RemoteTopBarActionAvailability {
  if (RUSTDESK_ENABLED_ACTIONS.indexOf(actionId) >= 0) {
    return { enabled: true, reason: '' };
  }
  const reason = RUSTDESK_DISABLED_REASONS[actionId] ?? '当前版本尚未接入该 RustDesk 官方能力';
  return { enabled: false, reason };
}

export function protocolPreferenceOwner(key: string): string {
  if (key.startsWith('rustdesk')) {
    return 'rustdesk';
  }
  if (key.startsWith('rdp')) {
    return 'rdp';
  }
  return 'shared';
}
```

- [ ] **Step 4: Run policy checks**

Run:

```powershell
rg -n "shouldShowRustDeskTopBar|protocolPreferenceOwner|remoteSessionTopBarPolicyTest" entry/src/main/ets entry/src/test
```

Expected: policy file, test file, and test registration are present.

- [ ] **Step 5: Commit**

```powershell
git add entry/src/main/ets/services/RemoteSessionTopBarPolicy.ets entry/src/test/RemoteSessionTopBarPolicy.test.ets entry/src/test/List.test.ets
git commit -m "test(rustdesk): add session topbar policy"
```

---

### Task 2: Preference Separation Cleanup

**Files:**
- Modify: `entry/src/main/ets/pages/HostListPage.ets`
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets`

**Interfaces:**
- Consumes: `protocolPreferenceOwner(key: string): string`.
- Produces:
  - `rustdeskClipboardEnabled` preference, default `true`.
  - `rustdeskFilePasteEnabled` preference, default `true`.
  - RDP save functions use `persistPref` or RDP-named helpers, not RustDesk-named helpers.

- [ ] **Step 1: Write preference policy assertions**

Extend `RemoteSessionTopBarPolicy.test.ets` with:

```ts
it('new_runtime_rustdesk_keys_should_be_rustdesk_owned', 0, () => {
  expect(protocolPreferenceOwner('rustdeskFilePasteEnabled')).assertEqual('rustdesk');
  expect(protocolPreferenceOwner('rustdeskClipboardEnabled')).assertEqual('rustdesk');
});
```

- [ ] **Step 2: Run source check**

Run:

```powershell
rg -n "persistRustDesk.*rdp|rdClipboardEnabled|rustdeskClipboardEnabled|rustdeskFilePasteEnabled" entry/src/main/ets/pages
```

Expected before cleanup: RDP save methods still call RustDesk-named persistence helpers; RustDesk clipboard/file-paste keys are absent.

- [ ] **Step 3: Add RustDesk preference state**

In `HostListPage.ets`, add storage links near existing RustDesk settings:

```ts
@StorageLink('rustdeskClipboardEnabled') rustdeskClipboardEnabled: boolean = true;
@StorageLink('rustdeskFilePasteEnabled') rustdeskFilePasteEnabled: boolean = true;
```

During preferences load, read defaults:

```ts
const savedRustDeskClipboardEnabled: boolean =
  prefs.getSync('rustdeskClipboardEnabled', true) as boolean;
const savedRustDeskFilePasteEnabled: boolean =
  prefs.getSync('rustdeskFilePasteEnabled', true) as boolean;
```

Assign and publish:

```ts
this.rustdeskClipboardEnabled = savedRustDeskClipboardEnabled;
this.rustdeskFilePasteEnabled = savedRustDeskFilePasteEnabled;
AppStorage.setOrCreate('rustdeskClipboardEnabled', this.rustdeskClipboardEnabled);
AppStorage.setOrCreate('rustdeskFilePasteEnabled', this.rustdeskFilePasteEnabled);
```

Add save helpers:

```ts
private saveRustDeskClipboardEnabled(on: boolean): void {
  this.rustdeskClipboardEnabled = on;
  this.persistPref('rustdeskClipboardEnabled', this.rustdeskClipboardEnabled);
}

private saveRustDeskFilePasteEnabled(on: boolean): void {
  this.rustdeskFilePasteEnabled = on;
  this.persistPref('rustdeskFilePasteEnabled', this.rustdeskFilePasteEnabled);
}
```

- [ ] **Step 4: Rename misleading persistence calls**

In `HostListPage.ets`, change these methods:

```ts
private saveRdpDesktopPreset(preset: number): void {
  this.rdpDesktopPreset = preset >= 0 && preset <= 3 ? preset : 1;
  this.persistPref('rdpDesktopPreset', this.rdpDesktopPreset);
}

private saveRdpColorDepth(depth: number): void {
  this.rdpColorDepth = depth === 16 || depth === 24 ? depth : 32;
  this.persistPref('rdpColorDepth', this.rdpColorDepth);
}

private saveRdpAudioEnabled(on: boolean): void {
  this.rdpAudioEnabled = on;
  this.persistPref('rdpAudioEnabled', this.rdpAudioEnabled);
}

private saveRdpClipboardEnabled(on: boolean): void {
  this.rdpClipboardEnabled = on;
  this.persistPref('rdpClipboardEnabled', this.rdpClipboardEnabled);
}

private saveRdpControlMode(mode: number): void {
  this.rdpControlMode = this.clampRdpControlMode(mode);
  this.persistPref('rdpControlMode', this.rdpControlMode);
}
```

- [ ] **Step 5: Use protocol-specific clipboard at connect time**

In `RemoteDesktop.ets`, change `rdClipboardEnabled` assignment in `cfg`:

```ts
rdClipboardEnabled: host.protocol === 'rustdesk' ?
  (AppStorage.get<boolean>('rustdeskClipboardEnabled') ?? true) :
  (AppStorage.get<boolean>('rdpClipboardEnabled') ?? true),
```

- [ ] **Step 6: Run checks**

Run:

```powershell
rg -n "persistRustDesk.*rdp|rdClipboardEnabled: AppStorage.get<boolean>\\('rdpClipboardEnabled'\\)" entry/src/main/ets/pages
```

Expected: no matches.

- [ ] **Step 7: Commit**

```powershell
git add entry/src/main/ets/pages/HostListPage.ets entry/src/main/ets/pages/RemoteDesktop.ets entry/src/test/RemoteSessionTopBarPolicy.test.ets
git commit -m "fix(settings): separate rustdesk and rdp preferences"
```

---

### Task 3: RemoteSessionTopBar Component

**Files:**
- Create: `entry/src/main/ets/components/RemoteSessionTopBar.ets`

**Interfaces:**
- Consumes:
  - `RemoteTopBarLayout`
  - `rustDeskActionAvailability(actionId: string)`
- Produces:
  - ArkUI component `RemoteSessionTopBar` with prop callbacks:
    - `onDisconnect(): void`
    - `onRefreshFrame(): void`
    - `onOpenKeyboard(): void`
    - `onOpenFileTransfer(): void`
    - `onCtrlAltDel(): void`
    - `onLockRemote(): void`
    - `onTogglePrivacy(on: boolean): void`
    - `onToggleAudio(on: boolean): void`
    - `onToggleClipboard(on: boolean): void`
    - `onToggleFilePaste(on: boolean): void`
    - `onUnsupported(actionId: string, reason: string): void`

- [ ] **Step 1: Create component shell**

Create `RemoteSessionTopBar.ets`:

```ts
import { promptAction } from '@kit.ArkUI';
import { RemoteTopBarLayout, rustDeskActionAvailability } from '../services/RemoteSessionTopBarPolicy';

export interface RemoteSessionTopBarActions {
  onDisconnect: () => void;
  onRefreshFrame: () => void;
  onOpenKeyboard: () => void;
  onOpenFileTransfer: () => void;
  onCtrlAltDel: () => void;
  onLockRemote: () => void;
  onTogglePrivacy: (on: boolean) => void;
  onToggleAudio: (on: boolean) => void;
  onToggleClipboard: (on: boolean) => void;
  onToggleFilePaste: (on: boolean) => void;
  onUnsupported: (actionId: string, reason: string) => void;
}

@Component
export struct RemoteSessionTopBar {
  @Prop layout: RemoteTopBarLayout;
  @Prop privacyMode: boolean;
  @Prop audioEnabled: boolean;
  @Prop clipboardEnabled: boolean;
  @Prop filePasteEnabled: boolean;
  @State collapsed: boolean = false;
  @State pinned: boolean = false;
  @State activeMenu: string = '';
  actions: RemoteSessionTopBarActions = {
    onDisconnect: (): void => {},
    onRefreshFrame: (): void => {},
    onOpenKeyboard: (): void => {},
    onOpenFileTransfer: (): void => {},
    onCtrlAltDel: (): void => {},
    onLockRemote: (): void => {},
    onTogglePrivacy: (_on: boolean): void => {},
    onToggleAudio: (_on: boolean): void => {},
    onToggleClipboard: (_on: boolean): void => {},
    onToggleFilePaste: (_on: boolean): void => {},
    onUnsupported: (_actionId: string, reason: string): void => {
      promptAction.showToast({ message: reason, duration: 1800 });
    }
  };
}
```

- [ ] **Step 2: Add helper methods**

Add methods inside the struct:

```ts
private runAction(actionId: string, action: () => void): void {
  const availability = rustDeskActionAvailability(actionId);
  if (!availability.enabled) {
    this.actions.onUnsupported(actionId, availability.reason);
    return;
  }
  action();
}

private toggleMenu(menu: string): void {
  this.activeMenu = this.activeMenu === menu ? '' : menu;
}

private closeMenus(): void {
  this.activeMenu = '';
}

private topbarWidth(): number {
  const count = Math.max(1, this.layout.maxVisibleButtons);
  return count * this.layout.iconSize + (count + 1) * this.layout.itemGap;
}
```

- [ ] **Step 3: Render collapsed handle**

Add a collapsed branch in `build()`:

```ts
build() {
  Stack() {
    if (this.collapsed) {
      Row() {
        Text('••')
          .fontSize(20)
          .fontColor('#444444')
      }
      .width(58)
      .height(28)
      .justifyContent(FlexAlign.Center)
      .backgroundColor('rgba(255,255,255,0.92)')
      .borderRadius({ bottomLeft: 8, bottomRight: 8 })
      .shadow({ radius: 8, color: 'rgba(0,0,0,0.22)', offsetY: 2 })
      .onClick((): void => { this.collapsed = false; })
    } else {
      this.toolbarBody()
    }
  }
  .width('100%')
  .height(this.collapsed ? 32 : 92)
  .position({ x: 0, y: this.layout.topOffset })
  .hitTestBehavior(HitTestMode.Transparent)
}
```

- [ ] **Step 4: Render toolbar buttons**

Add builders:

```ts
@Builder toolbarBody() {
  Column() {
    Row() {
      this.iconButton('pin', this.pinned ? '📌' : '📍', (): void => {
        this.pinned = !this.pinned;
      }, this.pinned ? '#3A3A3A' : '#2E88F6')
      this.iconButton('control', '⚡', (): void => { this.toggleMenu('control'); }, '#2E88F6')
      this.iconButton('display', '▣', (): void => { this.toggleMenu('display'); }, '#2E88F6')
      this.iconButton('keyboardMouse', '⌨', (): void => { this.toggleMenu('keyboardMouse'); }, '#2E88F6')
      this.iconButton('chat', '☎', (): void => { this.toggleMenu('chat'); }, '#2E88F6')
      this.iconButton('record', 'REC', (): void => {
        this.runAction('recordSession', (): void => {});
      }, '#2E88F6')
      this.iconButton('close', '×', (): void => { this.actions.onDisconnect(); }, '#FF5353')
    }
    .padding({ left: this.layout.itemGap, right: this.layout.itemGap, top: 6, bottom: 6 })
    .backgroundColor('rgba(255,255,255,0.94)')
    .borderRadius(8)
    .shadow({ radius: 10, color: 'rgba(0,0,0,0.24)', offsetY: 2 })

    Row() {
      Text('••')
        .fontSize(18)
        .fontColor('#444444')
      Text(this.collapsed ? '展开' : '收起')
        .fontSize(10)
        .fontColor('#444444')
        .margin({ left: 4 })
    }
    .height(28)
    .padding({ left: 10, right: 10 })
    .backgroundColor('rgba(255,255,255,0.92)')
    .borderRadius({ bottomLeft: 7, bottomRight: 7 })
    .onClick((): void => { this.collapsed = true; this.closeMenus(); })

    if (this.activeMenu === 'control') { this.controlMenu() }
    if (this.activeMenu === 'display') { this.displayMenu() }
    if (this.activeMenu === 'keyboardMouse') { this.keyboardMouseMenu() }
    if (this.activeMenu === 'chat') { this.chatMenu() }
  }
  .alignItems(HorizontalAlign.Center)
  .width('100%')
}

@Builder iconButton(id: string, label: string, action: () => void, color: string) {
  Button(label)
    .width(this.layout.iconSize)
    .height(this.layout.iconSize)
    .fontSize(label === 'REC' ? 12 : 22)
    .fontColor('#FFFFFF')
    .backgroundColor(color)
    .borderRadius(10)
    .padding(0)
    .onClick(action)
}
```

- [ ] **Step 5: Render menus with enabled and disabled entries**

Add menu builders:

```ts
@Builder controlMenu() {
  Column() {
    this.menuItem('发送剪贴板按键', 'toggleClipboard', (): void => {
      this.actions.onToggleClipboard(!this.clipboardEnabled);
    }, this.clipboardEnabled)
    this.menuItem('传输文件', 'fileTransfer', (): void => { this.actions.onOpenFileTransfer(); })
    this.menuItem('插入 Ctrl + Alt + Del', 'ctrlAltDel', (): void => { this.actions.onCtrlAltDel(); })
    this.menuItem('锁定远程电脑', 'lockRemote', (): void => { this.actions.onLockRemote(); })
    this.menuItem('刷新画面', 'refreshFrame', (): void => { this.actions.onRefreshFrame(); })
    this.menuItem('截屏', 'screenshot', (): void => { this.runAction('screenshot', (): void => {}); })
    this.menuItem('文字聊天', 'textChat', (): void => {})
    this.menuItem('语音通话', 'voiceCall', (): void => {})
    this.menuItem('录制', 'recordSession', (): void => {})
  }
  .width(this.layout.menuWidth)
  .padding(12)
  .backgroundColor('rgba(255,255,255,0.96)')
  .borderRadius(10)
  .shadow({ radius: 10, color: 'rgba(0,0,0,0.22)', offsetY: 2 })
}

@Builder displayMenu() {
  Column() {
    this.menuItem('原始尺寸', 'displaySettings', (): void => {})
    this.menuItem('适应窗口', 'displaySettings', (): void => {})
    this.menuItem('画质', 'displaySettings', (): void => {})
    this.menuItem('编解码', 'displaySettings', (): void => {})
    this.menuItem('分辨率', 'displaySettings', (): void => {})
    this.checkItem('隐私模式', 'togglePrivacyMode', this.privacyMode, (): void => {
      this.actions.onTogglePrivacy(!this.privacyMode);
    })
    this.checkItem('静音', 'toggleAudio', !this.audioEnabled, (): void => {
      this.actions.onToggleAudio(!this.audioEnabled);
    })
    this.checkItem('允许复制粘贴文件', 'toggleFilePaste', this.filePasteEnabled, (): void => {
      this.actions.onToggleFilePaste(!this.filePasteEnabled);
    })
  }
  .width(this.layout.menuWidth)
  .padding(12)
  .backgroundColor('rgba(255,255,255,0.96)')
  .borderRadius(10)
  .shadow({ radius: 10, color: 'rgba(0,0,0,0.22)', offsetY: 2 })
}

@Builder keyboardMouseMenu() {
  Column() {
    this.menuItem('打开虚拟键盘', 'toggleKeyboard', (): void => { this.actions.onOpenKeyboard(); })
    this.menuItem('浏览模式', 'keyboardMouseSettings', (): void => {})
    this.menuItem('显示我的光标', 'keyboardMouseSettings', (): void => {})
    this.menuItem('相对鼠标模式', 'keyboardMouseSettings', (): void => {})
    this.menuItem('鼠标滚轮反向', 'keyboardMouseSettings', (): void => {})
    this.menuItem('交换鼠标左右键', 'keyboardMouseSettings', (): void => {})
    this.menuItem('触控板速度', 'keyboardMouseSettings', (): void => {})
  }
  .width(this.layout.menuWidth)
  .padding(12)
  .backgroundColor('rgba(255,255,255,0.96)')
  .borderRadius(10)
  .shadow({ radius: 10, color: 'rgba(0,0,0,0.22)', offsetY: 2 })
}

@Builder chatMenu() {
  Column() {
    this.menuItem('文字聊天', 'textChat', (): void => {})
    this.menuItem('语音通话', 'voiceCall', (): void => {})
  }
  .width(180)
  .padding(12)
  .backgroundColor('rgba(255,255,255,0.96)')
  .borderRadius(10)
  .shadow({ radius: 10, color: 'rgba(0,0,0,0.22)', offsetY: 2 })
}
```

Add row helpers:

```ts
@Builder menuItem(label: string, actionId: string, action: () => void, checked?: boolean) {
  Row() {
    Text(checked === undefined ? ' ' : (checked ? '✓' : '□'))
      .width(28)
      .fontSize(18)
      .fontColor(checked ? '#1677FF' : '#777777')
    Text(label)
      .fontSize(16)
      .fontColor(rustDeskActionAvailability(actionId).enabled ? '#111111' : '#777777')
      .layoutWeight(1)
  }
  .height(40)
  .onClick((): void => {
    this.runAction(actionId, action);
  })
}

@Builder checkItem(label: string, actionId: string, checked: boolean, action: () => void) {
  this.menuItem(label, actionId, action, checked)
}
```

- [ ] **Step 6: Source check**

Run:

```powershell
rg -n "RemoteSessionTopBar|RemoteSessionTopBarActions|rustDeskActionAvailability" entry/src/main/ets/components/RemoteSessionTopBar.ets
```

Expected: component, action interface, and availability usage are present.

- [ ] **Step 7: Commit**

```powershell
git add entry/src/main/ets/components/RemoteSessionTopBar.ets
git commit -m "feat(rustdesk): add session topbar component"
```

---

### Task 4: Wire RustDesk Topbar Into RemoteDesktop

**Files:**
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets`

**Interfaces:**
- Consumes:
  - `shouldShowRustDeskTopBar(...)`
  - `remoteTopBarLayout(...)`
  - `RemoteSessionTopBar`
- Produces:
  - Runtime RustDesk topbar visible in PC any breakpoint and non-PC keyboard/mouse mode.
  - Existing RDP UI remains unchanged.

- [ ] **Step 1: Add imports and state**

Add imports:

```ts
import { RemoteSessionTopBar, RemoteSessionTopBarActions } from '../components/RemoteSessionTopBar';
import {
  remoteTopBarLayout,
  shouldShowRustDeskTopBar
} from '../services/RemoteSessionTopBarPolicy';
```

Add storage props near existing RustDesk settings:

```ts
@StorageLink('rustdeskPrivacyMode') rustdeskPrivacyMode: boolean = false;
@StorageLink('rustdeskAudioEnabled') rustdeskAudioEnabled: boolean = true;
@StorageLink('rustdeskClipboardEnabled') rustdeskClipboardEnabled: boolean = true;
@StorageLink('rustdeskFilePasteEnabled') rustdeskFilePasteEnabled: boolean = true;
```

- [ ] **Step 2: Add action helpers**

Add methods:

```ts
private shouldShowRustDeskSessionTopBar(): boolean {
  const host: RemoteHost | null = this.pendingHost;
  if (!host) { return false; }
  return shouldShowRustDeskTopBar(host.protocol, this.isDesktopDevice, this.breakpoint, this.rustdeskControlMode);
}

private toastUnsupportedRustDeskAction(_actionId: string, reason: string): void {
  promptAction.showToast({ message: reason, duration: 2200 });
}

private setRustDeskPrivacyMode(on: boolean): void {
  this.rustdeskPrivacyMode = on;
  AppStorage.setOrCreate('rustdeskPrivacyMode', on);
  promptAction.showToast({ message: on ? '隐私模式将在下次连接时请求启用' : '隐私模式将在下次连接时关闭', duration: 1800 });
}

private setRustDeskAudioEnabled(on: boolean): void {
  this.rustdeskAudioEnabled = on;
  AppStorage.setOrCreate('rustdeskAudioEnabled', on);
  promptAction.showToast({ message: on ? '远端音频已启用' : '远端音频将在下次连接时静音', duration: 1800 });
}

private setRustDeskClipboardEnabled(on: boolean): void {
  this.rustdeskClipboardEnabled = on;
  AppStorage.setOrCreate('rustdeskClipboardEnabled', on);
  promptAction.showToast({ message: on ? 'RustDesk 剪贴板已允许' : 'RustDesk 剪贴板已禁用', duration: 1600 });
}

private setRustDeskFilePasteEnabled(on: boolean): void {
  this.rustdeskFilePasteEnabled = on;
  AppStorage.setOrCreate('rustdeskFilePasteEnabled', on);
  promptAction.showToast({ message: on ? 'RustDesk 文件粘贴已允许' : 'RustDesk 文件粘贴已禁用', duration: 1600 });
}
```

Create actions object:

```ts
private rustDeskTopBarActions(): RemoteSessionTopBarActions {
  return {
    onDisconnect: (): void => {
      this.disconnectAndCleanup('rustdesk-topbar-close');
      this.goBack();
    },
    onRefreshFrame: (): void => {
      this.loader.requestFrameRefresh();
      promptAction.showToast({ message: '已请求刷新远端画面', duration: 1200 });
    },
    onOpenKeyboard: (): void => {
      this.openKeyboard();
    },
    onOpenFileTransfer: (): void => {
      this.openFileTransferPicker();
    },
    onCtrlAltDel: (): void => {
      this.sendCtrlAltDel();
    },
    onLockRemote: (): void => {
      this.sendVirtualKeyTap(KEYCODE_L, 'Lock');
    },
    onTogglePrivacy: (on: boolean): void => {
      this.setRustDeskPrivacyMode(on);
    },
    onToggleAudio: (on: boolean): void => {
      this.setRustDeskAudioEnabled(on);
    },
    onToggleClipboard: (on: boolean): void => {
      this.setRustDeskClipboardEnabled(on);
    },
    onToggleFilePaste: (on: boolean): void => {
      this.setRustDeskFilePasteEnabled(on);
    },
    onUnsupported: (actionId: string, reason: string): void => {
      this.toastUnsupportedRustDeskAction(actionId, reason);
    }
  };
}
```

If `openFileTransferPicker()` does not exist under that exact name, use the existing picker entry found by `rg -n "FilePicker|fileTransfer|submitFileToRustDesk|handleFileDrop" entry/src/main/ets/pages/RemoteDesktop.ets` and name the wrapper `openRustDeskFileTransferFromTopBar()`.

- [ ] **Step 3: Render component**

In `build()`, before the old PC-only disconnect button, add:

```ts
if (this.connected && this.shouldShowRustDeskSessionTopBar()) {
  RemoteSessionTopBar({
    layout: remoteTopBarLayout(this.isDesktopDevice, this.breakpoint),
    privacyMode: this.rustdeskPrivacyMode,
    audioEnabled: this.rustdeskAudioEnabled,
    clipboardEnabled: this.rustdeskClipboardEnabled,
    filePasteEnabled: this.rustdeskFilePasteEnabled,
    actions: this.rustDeskTopBarActions()
  })
}
```

Change old PC-only disconnect button condition so RustDesk sessions do not show a duplicate close button:

```ts
if (this.connected && this.isDesktopDevice && this.breakpoint === 'xl' &&
  (!this.pendingHost || this.pendingHost.protocol !== 'rustdesk')) {
```

- [ ] **Step 4: Guard file paste setting**

In file-drop and file-transfer RustDesk paths, add:

```ts
if (this.pendingHost && this.pendingHost.protocol === 'rustdesk' && !this.rustdeskFilePasteEnabled) {
  promptAction.showToast({ message: 'RustDesk 文件粘贴已禁用', duration: 1600 });
  return;
}
```

- [ ] **Step 5: Run source checks**

Run:

```powershell
rg -n "shouldShowRustDeskSessionTopBar|RemoteSessionTopBar|rustDeskTopBarActions|rustdeskFilePasteEnabled" entry/src/main/ets/pages/RemoteDesktop.ets
```

Expected: all symbols are present and only RustDesk uses the new topbar.

- [ ] **Step 6: Commit**

```powershell
git add entry/src/main/ets/pages/RemoteDesktop.ets
git commit -m "feat(rustdesk): show topbar in pc and keyboard mouse modes"
```

---

### Task 5: Display And Keyboard/Mouse Menu State

**Files:**
- Modify: `entry/src/main/ets/components/RemoteSessionTopBar.ets`
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets`
- Modify: `entry/src/main/ets/pages/HostListPage.ets` if shared settings rows need matching labels.

**Interfaces:**
- Produces:
  - UI state for view scale mode: `'original' | 'fit' | 'custom'`.
  - UI state for RustDesk runtime menu values: image quality, codec, show local cursor, relative mouse, inverse wheel, swap buttons, touchpad speed.
  - Settings are stored with `rustdesk*` keys only.

- [ ] **Step 1: Add RustDesk runtime menu keys**

Use these keys:

```ts
rustdeskViewScaleMode: 'fit'
rustdeskShowLocalCursor: true
rustdeskRelativeMouseMode: false
rustdeskReverseWheel: false
rustdeskSwapMouseButtons: false
rustdeskTouchpadSpeed: 1.0
```

Add storage links in `RemoteDesktop.ets` and load/publish defaults in `HostListPage.ets` using `persistPref`.

- [ ] **Step 2: Extend policy tests**

Add:

```ts
it('keyboard_mouse_runtime_keys_should_be_rustdesk_owned', 0, () => {
  expect(protocolPreferenceOwner('rustdeskViewScaleMode')).assertEqual('rustdesk');
  expect(protocolPreferenceOwner('rustdeskShowLocalCursor')).assertEqual('rustdesk');
  expect(protocolPreferenceOwner('rustdeskRelativeMouseMode')).assertEqual('rustdesk');
  expect(protocolPreferenceOwner('rustdeskReverseWheel')).assertEqual('rustdesk');
  expect(protocolPreferenceOwner('rustdeskSwapMouseButtons')).assertEqual('rustdesk');
  expect(protocolPreferenceOwner('rustdeskTouchpadSpeed')).assertEqual('rustdesk');
});
```

- [ ] **Step 3: Wire menu actions**

Add callbacks to `RemoteSessionTopBarActions`:

```ts
onSetViewScaleMode: (mode: string) => void;
onSetRustDeskImageQuality: (quality: number) => void;
onSetRustDeskCodec: (codec: number) => void;
onToggleShowLocalCursor: (on: boolean) => void;
onToggleRelativeMouse: (on: boolean) => void;
onToggleReverseWheel: (on: boolean) => void;
onToggleSwapMouseButtons: (on: boolean) => void;
onSetTouchpadSpeed: (speed: number) => void;
```

In `RemoteDesktop.ets`, implement each callback by updating `AppStorage` and showing a short toast. For codec and quality, toast text must say whether it applies immediately or on reconnect. With the current bridge, use this copy:

```ts
promptAction.showToast({ message: '画质偏好已保存，当前会话保持稳定，重连后完全生效', duration: 2000 });
```

- [ ] **Step 4: Apply input toggles in existing input paths**

In `handleXComponentMouse` before sending button:

```ts
let sendButton = event.action === MouseAction.Release && mappedButton < 0 ?
  this.physicalMouseDownButton : mappedButton;
if (this.rustdeskSwapMouseButtons) {
  if (sendButton === 0) { sendButton = 2; }
  else if (sendButton === 2) { sendButton = 0; }
}
```

In wheel sending path:

```ts
const wheelDelta = this.rustdeskReverseWheel ? -delta : delta;
this.loader.sendMouseWheel(this.sessionId, src['x'], src['y'], wheelDelta);
```

In touchpad pointer movement:

```ts
const speed = Math.max(0.4, Math.min(2.2, this.rustdeskTouchpadSpeed));
const nextX = this.remoteCursorX + this.remoteDeltaFromLocal(stepDx, 'x') * speed;
const nextY = this.remoteCursorY + this.remoteDeltaFromLocal(stepDy, 'y') * speed;
```

- [ ] **Step 5: Run source checks**

Run:

```powershell
rg -n "rustdeskReverseWheel|rustdeskSwapMouseButtons|rustdeskTouchpadSpeed|rustdeskViewScaleMode" entry/src/main/ets
```

Expected: state exists, menu uses it, and input paths consume relevant values.

- [ ] **Step 6: Commit**

```powershell
git add entry/src/main/ets/components/RemoteSessionTopBar.ets entry/src/main/ets/pages/RemoteDesktop.ets entry/src/main/ets/pages/HostListPage.ets entry/src/test/RemoteSessionTopBarPolicy.test.ets
git commit -m "feat(rustdesk): wire topbar display and input settings"
```

---

### Task 6: Verification, Build, And Handoff Updates

**Files:**
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md`
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md`
- Modify: `C:\Users\14288\.codex\projects\C--Users-14288\memory\remote-desktop-project-state.md`
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\CODEWALK.md` only if this establishes a reusable rule.

**Interfaces:**
- Produces final validation record.

- [ ] **Step 1: Run whitespace checks**

```powershell
git -C C:\Users\14288\DevEcoStudioProjects\RemoteDesktop diff --check -- entry/src/main/ets/services/RemoteSessionTopBarPolicy.ets entry/src/test/RemoteSessionTopBarPolicy.test.ets entry/src/test/List.test.ets entry/src/main/ets/components/RemoteSessionTopBar.ets entry/src/main/ets/pages/RemoteDesktop.ets entry/src/main/ets/pages/HostListPage.ets
```

Expected: no whitespace errors. CRLF warnings are acceptable if existing project files produce them.

- [ ] **Step 2: Run production build**

Use the CODEWALK build command:

```powershell
& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js" --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --daemon
```

Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 3: Manual verification matrix**

Verify on device or emulator:

```text
RustDesk PC small window: topbar visible, collapses, expands, disconnects, refresh works.
RustDesk PC full screen: topbar visible, no duplicate old PC close button.
RustDesk Pad keyboard/mouse mode: topbar visible.
RustDesk Pad touchpad mode: topbar hidden.
RustDesk phone keyboard/mouse mode: topbar visible with compact width.
RustDesk phone touchpad/direct-touch mode: topbar hidden.
RDP PC small/full: RustDesk topbar hidden; existing RDP controls unchanged.
RDP settings: changing RDP desktop preset/color depth/control mode does not change RustDesk settings.
RustDesk settings: changing RustDesk quality/codec/control/audio/privacy/clipboard/file-paste does not change RDP settings.
```

- [ ] **Step 4: Update handoff files**

Record:

```text
Summary: RustDesk official-aligned hideable topbar added for PC all window sizes and Pad/phone keyboard-mouse mode. RDP and RustDesk personalization keys separated.
Validation: diff check result, build result, device matrix result.
Known disabled official actions: chat, voice call, recording, camera, terminal, TCP tunnel, block remote input, reverse access, restart remote.
```

- [ ] **Step 5: Final commit**

```powershell
git add C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md C:\Users\14288\.codex\projects\C--Users-14288\memory\remote-desktop-project-state.md
git commit -m "docs: record rustdesk topbar experience upgrade"
```

---

## Self-Review

**Spec coverage:** The plan covers PC small/full windows, Pad/phone keyboard/mouse mode, official RustDesk-aligned toolbar structure, hide/collapse behavior, feature availability, and RDP/RustDesk setting separation.

**Placeholder scan:** No task depends on an unspecified file or unnamed function. Disabled official actions have explicit reasons.

**Type consistency:** Policy types are consumed by the component; component callbacks are consumed by `RemoteDesktop`; preference keys are covered by policy tests and by HostList/RemoteDesktop wiring.

**Risk notes:** Runtime quality, codec, privacy, and audio behavior currently depend on the existing bridge. The first implementation stores those choices safely and uses toasts when reconnect is required. Native runtime control can be added as a separate protocol task after this UI upgrade is stable.
