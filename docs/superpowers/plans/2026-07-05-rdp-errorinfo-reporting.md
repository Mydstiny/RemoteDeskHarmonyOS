# RDP ErrorInfo Reporting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a Windows/RDP server sends an official Set Error Info PDU such as `ERRINFO_CLOSE_STACK_ON_DRIVER_FAILURE (0x00000011)`, the app must show the same class of user warning as Microsoft Remote Desktop instead of silently staying on a blank or disconnected session.

**Architecture:** Treat server ErrorInfo as the authoritative RDP failure source. Native FreeRDP must advertise ErrorInfo support, convert `ErrorInfoEventArgs.code` into adapter `ERROR` state and a parseable message, and ArkTS must keep monitoring native state after the desktop enters `CONNECTED`. Local no-frame watchdog remains a fallback only when the server does not send ErrorInfo.

**Tech Stack:** ArkTS/ArkUI API 23, Hypium tests, FreeRDP 3.x PubSub ErrorInfo events, existing NAPI `getConnectionState()` / `getConnectionLastMessage()`, DevEco `assembleHap`.

## Global Constraints

- Keep RDP/RustDesk personalization independent; do not touch `rustdesk*` settings for this fix.
- Do not reintroduce RDP certificate trust-all behavior.
- Do not add ArkTS TCP preflight to the RDP startup path.
- RDP startup sizing rules stay unchanged: initial `setXComponentSurfaceId()` and `initRenderer()` use remote desktop size, actual surface resize happens after renderer creation.
- Every user-visible error must include a traceable diagnostic code.
- Use pure ArkTS policy tests for UI classification before wiring UI behavior.
- Preserve unrelated dirty files: `build-profile.json5`, `entry/oh-package.json5`, dirty `freerdp` submodule state, and existing docs/spec dirty files unless this task explicitly changes them.

---

## File Structure

- Create `entry/src/main/ets/services/RdpSessionErrorPolicy.ets`
  - Owns pure mapping from native RDP messages / ErrorInfo codes to dialog title, user copy, and display code.
- Create `entry/src/test/RdpSessionErrorPolicy.test.ets`
  - Locks `0x11` behavior and prevents conflating `0x11` with `0x112F`.
- Modify `entry/src/test/List.test.ets`
  - Registers the new policy test.
- Modify `entry/src/main/cpp/rdp/freerdp_adapter.cpp`
  - Enables `FreeRDP_SupportErrorInfoPdu`.
  - Converts `cbErrorInfo()` events into adapter `ERROR` state with parseable code.
  - Keeps existing logging but adds official `freerdp_get_error_info_*` data.
- Modify `entry/src/main/cpp/rdp/freerdp_adapter.h`
  - Only if the callback needs a new helper declaration; prefer file-local helpers in `.cpp` if possible.
- Modify `entry/src/main/ets/pages/RemoteDesktop.ets`
  - Starts/stops a post-connect RDP native-state monitor.
  - Uses `RdpSessionErrorPolicy` for connection-stage native errors, post-connect ErrorInfo, and watchdog fallback.
- Modify `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md`
  - Record completed scope, latest commit, validation, and true-device checklist.
- Modify `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md`
  - Add/complete a small RDP ErrorInfo UX task.
- Modify `C:\Users\14288\.codex\projects\C--Users-14288\memory\remote-desktop-project-state.md`
  - Record durable session outcome.
- Modify `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\CODEWALK.md`
  - Only if implementation establishes a durable RDP ErrorInfo rule.

---

### Task 1: Add Pure RDP Session Error Policy

**Files:**
- Create: `entry/src/main/ets/services/RdpSessionErrorPolicy.ets`
- Create: `entry/src/test/RdpSessionErrorPolicy.test.ets`
- Modify: `entry/src/test/List.test.ets`

**Interfaces:**
- Produces:
  - `export interface RdpSessionErrorDialogModel { title: string; message: string; code: string; source: RdpSessionErrorSource; }`
  - `export enum RdpSessionErrorSource { SERVER_ERROR_INFO = 'server-error-info', LOCAL_RENDER_WATCHDOG = 'local-render-watchdog', CONNECT_FAILURE = 'connect-failure' }`
  - `export function normalizeRdpErrorCode(raw: string, fallback: string): string`
  - `export function rdpSessionErrorFromNativeMessage(message: string, fallbackCode: string): RdpSessionErrorDialogModel`
  - `export function rdpNoFrameWatchdogError(): RdpSessionErrorDialogModel`
- Consumes:
  - Existing native messages from `ExtensionLoader.getConnectionLastMessage(sessionId)`.

- [ ] **Step 1: Write the failing policy test**

Add `entry/src/test/RdpSessionErrorPolicy.test.ets`:

```ts
import { describe, it, expect } from '@ohos/hypium';
import {
  normalizeRdpErrorCode,
  rdpNoFrameWatchdogError,
  rdpSessionErrorFromNativeMessage,
  RdpSessionErrorSource
} from '../main/ets/services/RdpSessionErrorPolicy';

export default function rdpSessionErrorPolicyTest() {
  describe('RdpSessionErrorPolicy', (): void => {
    it('server_errorinfo_0x11_should_match_microsoft_graphics_driver_dialog', 0, (): void => {
      const model = rdpSessionErrorFromNativeMessage(
        'RDP server ErrorInfo: ERRINFO_CLOSE_STACK_ON_DRIVER_FAILURE [E-RDP-ERRINFO-0x00000011] The display driver in the remote session was unable to complete all the tasks required for startup.',
        '0x10'
      );
      expect(model.title).assertEqual('你的会话已断开');
      expect(model.message).assertEqual('远程会话中的图形显示组件启动失败。');
      expect(model.code).assertEqual('0x11');
      expect(model.source).assertEqual(RdpSessionErrorSource.SERVER_ERROR_INFO);
    });

    it('server_errorinfo_0x112f_should_not_be_collapsed_to_0x11', 0, (): void => {
      const model = rdpSessionErrorFromNativeMessage(
        'RDP server ErrorInfo: ERRINFO_GRAPHICS_SUBSYSTEM_FAILED [E-RDP-ERRINFO-0x0000112F] The server-side graphics subsystem is in an error state and unable to continue graphics encoding.',
        '0x10'
      );
      expect(model.title).assertEqual('你的会话已断开');
      expect(model.message).assertEqual('远程会话图形子系统出现错误，无法继续图形编码。');
      expect(model.code).assertEqual('0x112F');
      expect(model.source).assertEqual(RdpSessionErrorSource.SERVER_ERROR_INFO);
    });

    it('local_no_frame_watchdog_should_remain_fallback_0x11', 0, (): void => {
      const model = rdpNoFrameWatchdogError();
      expect(model.title).assertEqual('你的会话已断开');
      expect(model.message).assertEqual('远程会话中的图形显示组件启动失败。');
      expect(model.code).assertEqual('0x11');
      expect(model.source).assertEqual(RdpSessionErrorSource.LOCAL_RENDER_WATCHDOG);
    });

    it('normalize_should_shorten_8_digit_server_codes_for_dialog', 0, (): void => {
      expect(normalizeRdpErrorCode('0x00000011', '0x10')).assertEqual('0x11');
      expect(normalizeRdpErrorCode('0x0000112F', '0x10')).assertEqual('0x112F');
      expect(normalizeRdpErrorCode('', '0x10')).assertEqual('0x10');
    });
  });
}
```

- [ ] **Step 2: Register the failing test**

Modify `entry/src/test/List.test.ets`:

```ts
import rdpSessionErrorPolicyTest from './RdpSessionErrorPolicy.test';
```

Inside `testsuite()` append:

```ts
  rdpSessionErrorPolicyTest();
```

- [ ] **Step 3: Run the test target to confirm current blocker / failing state**

Run:

```powershell
$env:DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
$env:OHOS_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' `
  'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' `
  --mode module -p module=entry -p product=default default@OhosTestBuildArkTS `
  --analyze=normal --parallel --incremental --daemon
```

Expected today: this target may still fail on the existing `HostListPage.ets` / DevEco sourcemap blocker. If so, record that blocker and continue with production build verification later. If the blocker is absent, expect failure because `RdpSessionErrorPolicy.ets` does not exist yet.

- [ ] **Step 4: Implement the policy**

Create `entry/src/main/ets/services/RdpSessionErrorPolicy.ets`:

```ts
export enum RdpSessionErrorSource {
  SERVER_ERROR_INFO = 'server-error-info',
  LOCAL_RENDER_WATCHDOG = 'local-render-watchdog',
  CONNECT_FAILURE = 'connect-failure'
}

export interface RdpSessionErrorDialogModel {
  title: string;
  message: string;
  code: string;
  source: RdpSessionErrorSource;
}

function extractFirstHexCode(text: string): string {
  const marker: string = '0x';
  const idx: number = text.indexOf(marker);
  if (idx < 0) {
    return '';
  }
  let code: string = marker;
  for (let i = idx + 2; i < text.length; i++) {
    const ch: string = text.charAt(i);
    const isHex: boolean = (ch >= '0' && ch <= '9') ||
      (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F');
    if (!isHex) {
      break;
    }
    code += ch;
  }
  return code.length > 2 ? code : '';
}

export function normalizeRdpErrorCode(raw: string, fallback: string): string {
  const code: string = raw.length > 0 ? raw : fallback;
  if (code.length <= 2) {
    return fallback;
  }
  const upper: string = code.toUpperCase();
  if (!upper.startsWith('0X')) {
    return fallback;
  }
  let hex: string = upper.substring(2);
  while (hex.length > 1 && hex.charAt(0) === '0') {
    hex = hex.substring(1);
  }
  return '0x' + hex;
}

function modelForCode(code: string, source: RdpSessionErrorSource): RdpSessionErrorDialogModel {
  switch (code) {
    case '0xF':
    case '0x10':
    case '0x11':
    case '0x12':
      return {
        title: '你的会话已断开',
        message: '远程会话中的图形显示组件启动失败。',
        code,
        source
      };
    case '0x112D':
      return {
        title: '你的会话已断开',
        message: '服务器不支持当前请求的图形模式。',
        code,
        source
      };
    case '0x112E':
      return {
        title: '你的会话已断开',
        message: '远程会话图形子系统重置失败。',
        code,
        source
      };
    case '0x112F':
      return {
        title: '你的会话已断开',
        message: '远程会话图形子系统出现错误，无法继续图形编码。',
        code,
        source
      };
    default:
      return {
        title: '你的会话已断开',
        message: '远程桌面会话被服务器断开。',
        code,
        source
      };
  }
}

export function rdpSessionErrorFromNativeMessage(message: string, fallbackCode: string): RdpSessionErrorDialogModel {
  const code: string = normalizeRdpErrorCode(extractFirstHexCode(message), fallbackCode);
  const source: RdpSessionErrorSource = message.indexOf('E-RDP-ERRINFO-0x') >= 0
    ? RdpSessionErrorSource.SERVER_ERROR_INFO
    : RdpSessionErrorSource.CONNECT_FAILURE;
  return modelForCode(code, source);
}

export function rdpNoFrameWatchdogError(): RdpSessionErrorDialogModel {
  return modelForCode('0x11', RdpSessionErrorSource.LOCAL_RENDER_WATCHDOG);
}
```

- [ ] **Step 5: Re-run checks for this task**

Run `default@OhosTestBuildArkTS` again if the known blocker is absent. Always run:

```powershell
git diff --check -- entry/src/main/ets/services/RdpSessionErrorPolicy.ets entry/src/test/RdpSessionErrorPolicy.test.ets entry/src/test/List.test.ets
```

Expected: no whitespace errors except existing CRLF warnings.

- [ ] **Step 6: Commit Task 1**

```powershell
git add entry/src/main/ets/services/RdpSessionErrorPolicy.ets entry/src/test/RdpSessionErrorPolicy.test.ets entry/src/test/List.test.ets
git commit -m "test(rdp): add session error policy"
```

---

### Task 2: Surface FreeRDP Server ErrorInfo Through Native State

**Files:**
- Modify: `entry/src/main/cpp/rdp/freerdp_adapter.cpp`
- Modify: `entry/src/main/cpp/rdp/freerdp_adapter.h` only if needed

**Interfaces:**
- Consumes:
  - FreeRDP `ErrorInfoEventArgs.code`.
  - Existing `Impl::setState(ConnectionState, std::string)`.
  - Existing NAPI `getConnectionState()` and `getConnectionLastMessage()`.
- Produces:
  - Native state `ConnectionState::ERROR`.
  - Message containing `[E-RDP-ERRINFO-0x00000011]` for ArkTS parsing.

- [ ] **Step 1: Add a file-local adapter lookup for ErrorInfo callback context**

In `freerdp_adapter.cpp`, add near the existing file-static helpers:

```cpp
static std::mutex g_rdpContextOwnerMutex;
static std::map<::rdpContext*, FreeRdpAdapter::Impl*> g_rdpContextOwners;

static void registerRdpContextOwner(::rdpContext* context, FreeRdpAdapter::Impl* owner) {
    if (!context || !owner) {
        return;
    }
    std::lock_guard<std::mutex> lock(g_rdpContextOwnerMutex);
    g_rdpContextOwners[context] = owner;
}

static void unregisterRdpContextOwner(::rdpContext* context) {
    if (!context) {
        return;
    }
    std::lock_guard<std::mutex> lock(g_rdpContextOwnerMutex);
    g_rdpContextOwners.erase(context);
}

static FreeRdpAdapter::Impl* findRdpContextOwner(::rdpContext* context) {
    std::lock_guard<std::mutex> lock(g_rdpContextOwnerMutex);
    auto it = g_rdpContextOwners.find(context);
    return it == g_rdpContextOwners.end() ? nullptr : it->second;
}
```

If `Impl` is private and inaccessible from file-local helpers, move these helpers below the `Impl` declaration or add a `friend` declaration in `freerdp_adapter.h`. Prefer moving helpers below `Impl` in the `.cpp` to avoid widening the public header.

- [ ] **Step 2: Register/unregister the owner at instance lifecycle boundaries**

After `freerdp_context_new(instance_)` succeeds and `instance_->context` exists:

```cpp
registerRdpContextOwner(instance_->context, impl_.get());
```

In cleanup before or immediately after `freerdp_context_free(instance_)`:

```cpp
if (instance_ && instance_->context) {
    unregisterRdpContextOwner(instance_->context);
}
```

Do not unregister after the context memory is already freed if the pointer cannot be read safely.

- [ ] **Step 3: Explicitly advertise ErrorInfo support**

Near the other FreeRDP settings setup in `freerdp_adapter.cpp`, set:

```cpp
freerdp_settings_set_bool(s, FreeRDP_SupportErrorInfoPdu, TRUE);
```

This ensures FreeRDP emits `RNS_UD_CS_SUPPORT_ERRINFO_PDU` in early capability flags.

- [ ] **Step 4: Add raw ErrorInfo formatter**

Add a helper:

```cpp
static std::string rdpErrorInfoMessage(UINT32 code) {
    char codeBuf[11] = {0};
    std::snprintf(codeBuf, sizeof(codeBuf), "0x%08X", static_cast<unsigned int>(code));
    const char* name = safeFreeRdpString(freerdp_get_error_info_name(code), "UNKNOWN_ERRINFO");
    const char* official = safeFreeRdpString(freerdp_get_error_info_string(code), "");
    const char* category = safeFreeRdpString(freerdp_get_error_info_category(code), "UNKNOWN");
    std::string message = std::string("RDP server ErrorInfo: ") + name +
        " [E-RDP-ERRINFO-" + codeBuf + "] category=" + category;
    if (official[0] != '\0') {
        message += " ";
        message += official;
    }
    return message;
}
```

- [ ] **Step 5: Update `cbErrorInfo()` to publish native error state**

Replace the log-only body with:

```cpp
void FreeRdpAdapter::cbErrorInfo(void* context, const ErrorInfoEventArgs* e) {
    auto* rdpContext = static_cast<::rdpContext*>(context);
    const UINT32 code = e ? e->code : 0;
    const UINT32 selectedProtocol = rdpContext && rdpContext->settings
        ? freerdp_settings_get_uint32(rdpContext->settings, FreeRDP_SelectedProtocol)
        : 0;
    const char* errName = safeFreeRdpString(freerdp_get_error_info_name(code), "UNKNOWN_ERRINFO");
    const char* official = safeFreeRdpString(freerdp_get_error_info_string(code), "");
    OH_LOG_ERROR(LOG_APP,
                 "[RDP] ErrorInfo event: raw=0x%{public}08X (%{public}s) selectedProtocol=0x%{public}08X official=%{public}s",
                 code, errName, selectedProtocol, official);
    if (code == 0) {
        return;
    }
    FreeRdpAdapter::Impl* owner = findRdpContextOwner(rdpContext);
    if (!owner) {
        OH_LOG_WARN(LOG_APP, "[RDP] ErrorInfo owner missing: raw=0x%{public}08X", code);
        return;
    }
    owner->setState(ConnectionState::ERROR, rdpErrorInfoMessage(code));
}
```

Do not call `freerdp_disconnect()` inside the callback; it may run on the FreeRDP event loop thread. The session loop and ArkTS cleanup will handle disconnect after state is surfaced.

- [ ] **Step 6: Guard against overwriting ERROR state with DISCONNECTED**

Inspect `startEventLoop()` and cleanup state transitions. If a server ErrorInfo was already published, do not replace `ConnectionState::ERROR` / lastMessage with plain `"Disconnected"`. Use the minimal check:

```cpp
if (impl_->getState() != ConnectionState::ERROR) {
    impl_->setState(ConnectionState::DISCONNECTED, "Disconnected");
}
```

Apply only in RDP event-loop disconnect paths, not unrelated adapters.

- [ ] **Step 7: Run native scoped checks**

```powershell
git diff --check -- entry/src/main/cpp/rdp/freerdp_adapter.cpp entry/src/main/cpp/rdp/freerdp_adapter.h
```

Expected: no whitespace errors except existing CRLF warnings.

- [ ] **Step 8: Commit Task 2**

```powershell
git add entry/src/main/cpp/rdp/freerdp_adapter.cpp entry/src/main/cpp/rdp/freerdp_adapter.h
git commit -m "fix(rdp): surface server error info"
```

---

### Task 3: Add Post-Connect RDP Native State Monitor in ArkTS

**Files:**
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets`
- Consume: `entry/src/main/ets/services/RdpSessionErrorPolicy.ets`

**Interfaces:**
- Consumes:
  - `rdpSessionErrorFromNativeMessage(message, fallbackCode)`
  - `rdpNoFrameWatchdogError()`
- Produces:
  - A timer that polls native state after RDP is connected and shows the official dialog on `ERROR` or server-disconnect with ErrorInfo message.

- [ ] **Step 1: Import the policy**

At the imports in `RemoteDesktop.ets`, add:

```ts
import {
  rdpNoFrameWatchdogError,
  rdpSessionErrorFromNativeMessage,
  RdpSessionErrorDialogModel
} from '../services/RdpSessionErrorPolicy';
```

- [ ] **Step 2: Add monitor timer state**

Near existing `rdpRenderWatchdogTimer`, add:

```ts
private rdpNativeStateMonitorTimer: number = -1;
```

- [ ] **Step 3: Add timer cleanup**

Add:

```ts
private clearRdpNativeStateMonitor(): void {
  if (this.rdpNativeStateMonitorTimer !== -1) {
    clearTimeout(this.rdpNativeStateMonitorTimer);
    this.rdpNativeStateMonitorTimer = -1;
  }
}
```

Call this from every cleanup path that currently calls `clearRdpRenderWatchdog()`, including connect failure, `disconnectAndCleanup()`, and page destroy cleanup.

- [ ] **Step 4: Add a model-based dialog helper**

Add:

```ts
private showRdpSessionErrorModel(model: RdpSessionErrorDialogModel): void {
  this.showRdpSessionError(model.message, model.code);
}
```

Keep the existing `showRdpSessionError(message, code)` to minimize UI changes.

- [ ] **Step 5: Add post-connect monitor**

Add:

```ts
private startRdpNativeStateMonitor(sessionId: number, attemptId: number): void {
  this.clearRdpNativeStateMonitor();
  const poll = (): void => {
    if (attemptId !== this.connectAttemptId || this.sessionId !== sessionId ||
      !this.connected || !this.pendingHost || this.pendingHost.protocol !== 'rdp') {
      this.rdpNativeStateMonitorTimer = -1;
      return;
    }
    const state: number = this.loader.getConnectionState(sessionId);
    if (state === 4 || state === 0) {
      const nativeMessage: string = this.loader.getConnectionLastMessage(sessionId);
      hilog.error(RD_DOMAIN, RD_TAG, 'RDP native post-connect state=' + state.toString() +
        ' message=' + safeError(nativeMessage));
      if (nativeMessage.indexOf('E-RDP-ERRINFO-0x') >= 0 || state === 4) {
        const model: RdpSessionErrorDialogModel =
          rdpSessionErrorFromNativeMessage(nativeMessage, state === 4 ? '0x10' : '0x11');
        this.connectionError = model.title;
        this.connectionErrorDetail = model.message + '错误代码: ' + model.code;
        this.showRdpSessionErrorModel(model);
        this.disconnectAndCleanup('rdp-native-errorinfo');
      }
      this.rdpNativeStateMonitorTimer = -1;
      return;
    }
    this.rdpNativeStateMonitorTimer = setTimeout(poll, 500);
  };
  this.rdpNativeStateMonitorTimer = setTimeout(poll, 500);
}
```

If `disconnectAndCleanup()` currently clears the dialog state, adjust it so cleanup does not hide `showRdpSessionErrorDialog` when reason is `rdp-native-errorinfo` or `rdp-render-watchdog`.

- [ ] **Step 6: Start monitor after RDP connected**

After `this.startRdpRenderWatchdog(sid, attemptId);`, add:

```ts
this.startRdpNativeStateMonitor(sid, attemptId);
```

- [ ] **Step 7: Use policy in connection-stage catch and watchdog**

In the RDP connect catch:

```ts
const model: RdpSessionErrorDialogModel =
  rdpSessionErrorFromNativeMessage(this.connectionErrorDetail, '0x10');
this.showRdpSessionErrorModel(model);
```

In `startRdpRenderWatchdog()`, replace direct literals:

```ts
const model: RdpSessionErrorDialogModel = rdpNoFrameWatchdogError();
this.connectionError = model.title;
this.connectionErrorDetail = model.message + '错误代码: ' + model.code;
this.showRdpSessionErrorModel(model);
```

- [ ] **Step 8: Run ArkTS scoped checks**

```powershell
git diff --check -- entry/src/main/ets/pages/RemoteDesktop.ets
```

Expected: no whitespace errors except existing CRLF warnings.

- [ ] **Step 9: Commit Task 3**

```powershell
git add entry/src/main/ets/pages/RemoteDesktop.ets
git commit -m "fix(rdp): monitor server error info after connect"
```

---

### Task 4: Production Build, Device Validation, and Project State Updates

**Files:**
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md`
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md`
- Modify: `C:\Users\14288\.codex\projects\C--Users-14288\memory\remote-desktop-project-state.md`
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\CODEWALK.md` only if adding a durable rule.

**Interfaces:**
- Consumes:
  - Commits from Tasks 1-3.
  - Build and device validation output.
- Produces:
  - Verified HAP build.
  - Updated handoff/task/memory records.

- [ ] **Step 1: Run production build**

```powershell
$env:DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
$env:OHOS_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' `
  'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' `
  --mode module -p module=entry -p product=default assembleHap `
  --analyze=normal --parallel --incremental --daemon
```

Expected: `BUILD SUCCESSFUL`. Existing AGConnect/deprecated API warnings are not blockers.

- [ ] **Step 2: Run final scoped diff check**

```powershell
git diff --check -- `
  entry/src/main/ets/services/RdpSessionErrorPolicy.ets `
  entry/src/test/RdpSessionErrorPolicy.test.ets `
  entry/src/test/List.test.ets `
  entry/src/main/cpp/rdp/freerdp_adapter.cpp `
  entry/src/main/cpp/rdp/freerdp_adapter.h `
  entry/src/main/ets/pages/RemoteDesktop.ets
```

Expected: no whitespace errors except existing CRLF warnings.

- [ ] **Step 3: Collect true-device logs for the screenshot scenario**

Use the target device shown by `hdc list targets`:

```powershell
$hdc = 'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
$target = '<device-host:port>'
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$raw = "$env:USERPROFILE\Desktop\rdp-errorinfo-$ts-raw.log"
$key = "$env:USERPROFILE\Desktop\rdp-errorinfo-$ts-key.log"
& $hdc -t $target hilog -r
& $hdc -t $target hilog > $raw
Select-String -Path $raw -Pattern 'RDP] ErrorInfo event|E-RDP-ERRINFO|RDP native post-connect state|showRdpSessionError|render watchdog|SupportErrorInfoPdu|RNS_UD_CS_SUPPORT_ERRINFO_PDU' |
  Set-Content $key -Encoding UTF8
Write-Host "RAW: $raw"
Write-Host "KEY: $key"
```

Expected markers when the Windows server reproduces the screenshot state:

```text
[RDP] ErrorInfo event: raw=0x00000011
E-RDP-ERRINFO-0x00000011
RDP native post-connect state=4
```

Expected UI: dialog title `你的会话已断开`, message `远程会话中的图形显示组件启动失败。`, code `0x11`.

- [ ] **Step 4: Regression matrix**

Verify manually:

```text
1. Normal RDP host still connects and renders first frame.
2. RDP certificate preflight still appears before first untrusted certificate connection.
3. Clicking “继续连接” remains one-time and does not create persistent trust.
4. Clicking “信任” still allows later trusted-match auto-connect without sheet flash.
5. Server ErrorInfo 0x11 shows immediately from native state, without waiting 12 seconds when FreeRDP receives the PDU.
6. If server sends no ErrorInfo but no frame renders, the existing watchdog still shows 0x11 after timeout.
7. RustDesk connect, topbar, and settings are unaffected.
```

- [ ] **Step 5: Update project state**

Append a concise handoff section with:

```text
Latest commit:
Build:
Root cause:
Fix:
Device validation:
Known blockers:
Next validation:
```

Add a durable CODEWALK rule only after implementation is confirmed:

```text
RDP Server ErrorInfo rule: FreeRDP clients must advertise `FreeRDP_SupportErrorInfoPdu`, subscribe to `ErrorInfo`, and surface non-zero `ErrorInfoEventArgs.code` to ArkTS as `ConnectionState::ERROR` with `[E-RDP-ERRINFO-0x...]`. ArkTS must keep monitoring native state after `CONNECTED`; render watchdog is only a fallback when the server does not send ErrorInfo.
```

- [ ] **Step 6: Final commit**

```powershell
git add C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md `
        C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md `
        C:\Users\14288\.codex\projects\C--Users-14288\memory\remote-desktop-project-state.md `
        C:\Users\14288\DevEcoStudioProjects\Mission_transformation\CODEWALK.md
git commit -m "docs: record rdp error info handling"
```

If `CODEWALK.md` was not changed, omit it from `git add`.

---

## Self-Review Checklist

- Spec coverage: The plan covers Microsoft/FreeRDP ErrorInfo detection, native propagation, ArkTS post-connect monitoring, policy-level UI mapping, watchdog fallback, and RDP/RustDesk isolation.
- Placeholder scan: No `TBD` / `TODO` / vague “handle appropriately” steps remain.
- Type consistency: Policy model and helper names are defined in Task 1 and consumed with the same names in Task 3.
- Risk boundary: No RDP startup sizing changes, no certificate trust relaxation, no RustDesk behavior changes.
- Verification: Production build is required before final state updates; ohosTest blocker is explicitly recorded if still present.
