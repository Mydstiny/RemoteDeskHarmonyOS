# RDP Certificate And No-Frame Error UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add SSH-fingerprint-style RDP certificate verification before connection, and show a screenshot-style user error when RDP connects but no remote image is displayed.

**Architecture:** Keep RDP preflight in `HostListPage.ets`, mirroring the existing SSH preflight bindSheet flow. Use a pure ArkTS policy for states/copy, a short-lived token service to carry approved certificate data into `RemoteDesktop.ets`, and native FreeRDP callbacks that accept only valid or user-approved certificates. Add native render counters and an ArkTS first-frame watchdog so “connected but black/no frame” becomes a clear modal error instead of a silent bad session.

**Tech Stack:** ArkTS + ArkUI API 23 bindSheet, Hypium tests, existing `RemoteHost` / `CloudStore` / `ExtensionLoader`, FreeRDP 3.x certificate callbacks, NAPI `librdpnapi.so`, DevEco `assembleHap`.

## Global Constraints

- Do not reintroduce ArkTS TCP preflight for RDP.
- Do not change RDP startup sizing rules: initial renderer dimensions use remote desktop size; actual surface resize happens after renderer creation.
- RDP certificate preflight happens before routing into `RemoteDesktop`, mirroring SSH host-key preflight.
- Native RDP certificate callbacks must not trust all certificates silently after this change.
- User-approved certificate trust must be host/fingerprint scoped and short-lived for the current connection token.
- Connection failure and no-frame failure must produce a clear modal error with title, message, and error code like the supplied screenshot.
- Existing RustDesk topbar and RDP/RustDesk preference separation must remain untouched.
- Keep this feature RDP-only; SSH and RustDesk flows must not be routed through RDP certificate code.

---

## Current Code Anchors

- SSH preflight model to copy: `entry/src/main/ets/pages/HostListPage.ets`
  - State fields around `sshPreflightState`.
  - Routing hook in `connectToHost(host)`.
  - Independent bindSheet host around `.bindSheet($$this.showSshPreflight, this.sshPreflightPanel(), ...)`.
  - Builder functions `sshPreflightPanel`, `sshPreflightTitle`, `sshPreflightButtonsContent`.
- RDP connection entry: `entry/src/main/ets/pages/RemoteDesktop.ets`
  - `doConnect(host)` builds `SessionConfig`, calls `loader.connect(cfg)`, waits for native connected state.
  - Existing errors set `connectionError` and `connectionErrorDetail`.
- Native certificate issue to fix: `entry/src/main/cpp/rdp/freerdp_adapter.cpp`
  - `cbVerifyCertificate`, `cbVerifyCertificateEx`, `cbVerifyChangedCertificateEx`, and `cbVerifyX509Certificate` currently return temporary trust.
- Native render counters already exist:
  - `Impl::paintCount`, `renderedPaintCount`, `firstPaintUs` in `freerdp_adapter.cpp`.

---

## File Structure

- Create `entry/src/main/ets/services/RdpCertificatePreflightPolicy.ets`
  - Pure preflight state, warning copy, button policy, and trust classification.
- Create `entry/src/test/RdpCertificatePreflightPolicy.test.ets`
  - Unit coverage for untrusted root, host mismatch, trusted match, changed fingerprint, and probe error.
- Create `entry/src/main/ets/services/RdpPreflightService.ets`
  - Short-lived approved-certificate token store, same role as `SshPreflightService`.
- Modify `entry/src/main/ets/types/rdpnapi.d.ts`
  - Add `RdpCertificateInfo`, `RdpRenderStats`, `probeRdpCertificate`, `getRdpRenderStats`, and `SessionConfig` certificate fields.
- Modify `entry/src/main/ets/services/ExtensionLoader.ets`
  - Add safe wrappers for the two new NAPI calls.
- Modify `entry/src/main/ets/model/RemoteHost.ets`
  - Add RDP certificate trust fields.
- Modify `entry/src/main/ets/services/CloudStore.ets`
  - Add migration, row write, and row read support for RDP certificate trust fields.
- Modify `entry/src/main/ets/pages/HostListPage.ets`
  - Add RDP bindSheet preflight, probe, trust, and route flow.
- Modify `entry/src/main/ets/pages/RemoteDesktop.ets`
  - Consume token, pass certificate approval to native, show structured error modal, and add first-frame watchdog.
- Modify `entry/src/main/cpp/rdp/freerdp_adapter.cpp`
  - Capture certificate data, enforce certificate policy, expose render stats.
- Modify `entry/src/main/cpp/extensions/extension_loader_napi.cpp`
  - Add `probeRdpCertificate` and `getRdpRenderStats`.

---

### Task 1: Pure RDP Certificate Preflight Policy

**Files:**
- Create: `entry/src/main/ets/services/RdpCertificatePreflightPolicy.ets`
- Create: `entry/src/test/RdpCertificatePreflightPolicy.test.ets`
- Modify: `entry/src/test/List.test.ets`

**Interfaces:**
- Produces:

```ts
export enum RdpCertificatePreflightState {
  PROBING = 0,
  TRUST_FIRST_TIME = 1,
  TRUSTED_MATCH = 2,
  CERTIFICATE_CHANGED = 3,
  ERROR = 4
}

export interface RdpCertificateProbeView {
  ok: boolean;
  fingerprintSha256: string;
  commonName: string;
  subject: string;
  issuer: string;
  flags: number;
  rootTrusted: boolean;
  hostMismatch: boolean;
  errorMessage: string;
}

export interface RdpCertificateTrustView {
  trustMode: number;
  savedFingerprintSha256: string;
}

export function classifyRdpCertificateProbe(
  probe: RdpCertificateProbeView,
  trust: RdpCertificateTrustView
): RdpCertificatePreflightState;

export function rdpCertificateWarningMessage(
  hostLabel: string,
  rootTrusted: boolean,
  hostMismatch: boolean
): string;

export function shouldRequireRdpCertificateConfirmation(
  state: RdpCertificatePreflightState
): boolean;
```

- Consumes: no production code.

- [ ] **Step 1: Write failing tests**

Create `entry/src/test/RdpCertificatePreflightPolicy.test.ets`:

```ts
import { describe, it, expect } from '@ohos/hypium';
import {
  classifyRdpCertificateProbe,
  RdpCertificatePreflightState,
  rdpCertificateWarningMessage,
  shouldRequireRdpCertificateConfirmation
} from '../main/ets/services/RdpCertificatePreflightPolicy';

export default function rdpCertificatePreflightPolicyTest() {
  describe('RdpCertificatePreflightPolicy', (): void => {
    it('untrusted_first_time_should_require_confirmation', 0, (): void => {
      const state = classifyRdpCertificateProbe({
        ok: true,
        fingerprintSha256: 'SHA256:first',
        commonName: '47.116.203.64',
        subject: 'CN=47.116.203.64',
        issuer: 'CN=SelfSigned',
        flags: 0x00000001,
        rootTrusted: false,
        hostMismatch: false,
        errorMessage: ''
      }, { trustMode: 0, savedFingerprintSha256: '' });
      expect(state).assertEqual(RdpCertificatePreflightState.TRUST_FIRST_TIME);
      expect(shouldRequireRdpCertificateConfirmation(state)).assertTrue();
    });

    it('trusted_same_fingerprint_should_match', 0, (): void => {
      const state = classifyRdpCertificateProbe({
        ok: true,
        fingerprintSha256: 'SHA256:same',
        commonName: 'server',
        subject: 'CN=server',
        issuer: 'CN=Root',
        flags: 0,
        rootTrusted: true,
        hostMismatch: false,
        errorMessage: ''
      }, { trustMode: 1, savedFingerprintSha256: 'SHA256:same' });
      expect(state).assertEqual(RdpCertificatePreflightState.TRUSTED_MATCH);
      expect(shouldRequireRdpCertificateConfirmation(state)).assertFalse();
    });

    it('trusted_changed_fingerprint_should_warn_changed', 0, (): void => {
      const state = classifyRdpCertificateProbe({
        ok: true,
        fingerprintSha256: 'SHA256:new',
        commonName: 'server',
        subject: 'CN=server',
        issuer: 'CN=Root',
        flags: 0,
        rootTrusted: true,
        hostMismatch: false,
        errorMessage: ''
      }, { trustMode: 1, savedFingerprintSha256: 'SHA256:old' });
      expect(state).assertEqual(RdpCertificatePreflightState.CERTIFICATE_CHANGED);
      expect(shouldRequireRdpCertificateConfirmation(state)).assertTrue();
    });

    it('probe_error_should_be_error_state', 0, (): void => {
      const state = classifyRdpCertificateProbe({
        ok: false,
        fingerprintSha256: '',
        commonName: '',
        subject: '',
        issuer: '',
        flags: 0,
        rootTrusted: false,
        hostMismatch: false,
        errorMessage: 'connect failed'
      }, { trustMode: 0, savedFingerprintSha256: '' });
      expect(state).assertEqual(RdpCertificatePreflightState.ERROR);
    });

    it('warning_copy_should_match_requested_root_certificate_text', 0, (): void => {
      const msg = rdpCertificateWarningMessage('47.116.203.64', false, false);
      expect(msg).assertEqual('你正在连接到 RDP 主机 “47.116.203.64”。无法将证书反向验证到根证书。你的连接可能不安全。是否要继续？');
    });

    it('warning_copy_should_append_hostname_mismatch', 0, (): void => {
      const msg = rdpCertificateWarningMessage('47.116.203.64', false, true);
      expect(msg.indexOf('证书名称与当前主机不匹配。') >= 0).assertTrue();
    });
  });
}
```

- [ ] **Step 2: Register the test**

Modify `entry/src/test/List.test.ets`:

```ts
import rdpCertificatePreflightPolicyTest from './RdpCertificatePreflightPolicy.test';
```

and inside `testsuite()`:

```ts
rdpCertificatePreflightPolicyTest();
```

- [ ] **Step 3: Add the policy implementation**

Create `entry/src/main/ets/services/RdpCertificatePreflightPolicy.ets`:

```ts
export enum RdpCertificatePreflightState {
  PROBING = 0,
  TRUST_FIRST_TIME = 1,
  TRUSTED_MATCH = 2,
  CERTIFICATE_CHANGED = 3,
  ERROR = 4
}

export interface RdpCertificateProbeView {
  ok: boolean;
  fingerprintSha256: string;
  commonName: string;
  subject: string;
  issuer: string;
  flags: number;
  rootTrusted: boolean;
  hostMismatch: boolean;
  errorMessage: string;
}

export interface RdpCertificateTrustView {
  trustMode: number;
  savedFingerprintSha256: string;
}

export function classifyRdpCertificateProbe(
  probe: RdpCertificateProbeView,
  trust: RdpCertificateTrustView
): RdpCertificatePreflightState {
  if (!probe.ok || probe.fingerprintSha256.length === 0) {
    return RdpCertificatePreflightState.ERROR;
  }
  if (trust.trustMode === 1 && trust.savedFingerprintSha256.length > 0) {
    return trust.savedFingerprintSha256 === probe.fingerprintSha256 ?
      RdpCertificatePreflightState.TRUSTED_MATCH :
      RdpCertificatePreflightState.CERTIFICATE_CHANGED;
  }
  return RdpCertificatePreflightState.TRUST_FIRST_TIME;
}

export function rdpCertificateWarningMessage(
  hostLabel: string,
  rootTrusted: boolean,
  hostMismatch: boolean
): string {
  let message: string = '你正在连接到 RDP 主机 “' + hostLabel + '”。';
  if (!rootTrusted) {
    message += '无法将证书反向验证到根证书。你的连接可能不安全。是否要继续？';
  } else {
    message += '此证书已通过根证书验证。是否继续连接？';
  }
  if (hostMismatch) {
    message += ' 证书名称与当前主机不匹配。';
  }
  return message;
}

export function shouldRequireRdpCertificateConfirmation(
  state: RdpCertificatePreflightState
): boolean {
  return state === RdpCertificatePreflightState.TRUST_FIRST_TIME ||
    state === RdpCertificatePreflightState.CERTIFICATE_CHANGED;
}
```

- [ ] **Step 4: Verify source references**

Run:

```powershell
rg -n "RdpCertificatePreflightPolicy|rdpCertificatePreflightPolicyTest|rdpCertificateWarningMessage" entry/src/main/ets entry/src/test
```

Expected: policy file, test file, and `List.test.ets` registration.

- [ ] **Step 5: Commit**

```powershell
git add entry/src/main/ets/services/RdpCertificatePreflightPolicy.ets entry/src/test/RdpCertificatePreflightPolicy.test.ets entry/src/test/List.test.ets
git commit -m "test(rdp): add certificate preflight policy"
```

---

### Task 2: Persist RDP Certificate Trust On Hosts

**Files:**
- Modify: `entry/src/main/ets/model/RemoteHost.ets`
- Modify: `entry/src/main/ets/services/CloudStore.ets`

**Interfaces:**
- Produces `RemoteHost` fields:

```ts
rdpCertificateFingerprintSha256: string = '';
rdpCertificateSubject: string = '';
rdpCertificateIssuer: string = '';
rdpCertificateCommonName: string = '';
rdpCertificateTrustedAt: number = 0;
rdpCertificateTrustMode: number = 0;
rdpCertificateAllowUntrustedRoot: boolean = false;
rdpCertificateAllowHostMismatch: boolean = false;
```

- Consumes: Task 1 policy classification.

- [ ] **Step 1: Add fields to RemoteHost**

In `RemoteHost.ets`, add fields near the existing SSH host-key trust fields:

```ts
// RDP certificate trust
rdpCertificateFingerprintSha256: string = '';
rdpCertificateSubject: string = '';
rdpCertificateIssuer: string = '';
rdpCertificateCommonName: string = '';
rdpCertificateTrustedAt: number = 0;
rdpCertificateTrustMode: number = 0; // 0=unknown, 1=trusted
rdpCertificateAllowUntrustedRoot: boolean = false;
rdpCertificateAllowHostMismatch: boolean = false;
```

- [ ] **Step 2: Extend `toJSON()`**

Add these keys to the object returned by `RemoteHost.toJSON()`:

```ts
rdpCertificateFingerprintSha256: this.rdpCertificateFingerprintSha256,
rdpCertificateSubject: this.rdpCertificateSubject,
rdpCertificateIssuer: this.rdpCertificateIssuer,
rdpCertificateCommonName: this.rdpCertificateCommonName,
rdpCertificateTrustedAt: this.rdpCertificateTrustedAt,
rdpCertificateTrustMode: this.rdpCertificateTrustMode,
rdpCertificateAllowUntrustedRoot: this.rdpCertificateAllowUntrustedRoot,
rdpCertificateAllowHostMismatch: this.rdpCertificateAllowHostMismatch,
```

- [ ] **Step 3: Extend `fromJSON()`**

Add safe parsing:

```ts
if (json.rdpCertificateFingerprintSha256) {
  host.rdpCertificateFingerprintSha256 = json.rdpCertificateFingerprintSha256;
}
if (json.rdpCertificateSubject) { host.rdpCertificateSubject = json.rdpCertificateSubject; }
if (json.rdpCertificateIssuer) { host.rdpCertificateIssuer = json.rdpCertificateIssuer; }
if (json.rdpCertificateCommonName) { host.rdpCertificateCommonName = json.rdpCertificateCommonName; }
if (json.rdpCertificateTrustedAt) { host.rdpCertificateTrustedAt = json.rdpCertificateTrustedAt; }
if (json.rdpCertificateTrustMode) { host.rdpCertificateTrustMode = json.rdpCertificateTrustMode; }
if (json.rdpCertificateAllowUntrustedRoot !== undefined) {
  host.rdpCertificateAllowUntrustedRoot = json.rdpCertificateAllowUntrustedRoot;
}
if (json.rdpCertificateAllowHostMismatch !== undefined) {
  host.rdpCertificateAllowHostMismatch = json.rdpCertificateAllowHostMismatch;
}
```

- [ ] **Step 4: Add CloudStore migration columns**

In `CloudStore.ets`, extend the host table migration area with:

```ts
'rdpcertificatefingerprintsha256 TEXT',
'rdpcertificatesubject TEXT',
'rdpcertificateissuer TEXT',
'rdpcertificatecommonname TEXT',
'rdpcertificatetrustedat INTEGER',
'rdpcertificatetrustmode INTEGER',
'rdpcertificateallowuntrustedroot INTEGER',
'rdpcertificateallowhostmismatch INTEGER'
```

- [ ] **Step 5: Add CloudStore write mapping**

Where host values are written into `vb`, add:

```ts
vb['rdpcertificatefingerprintsha256'] = h.rdpCertificateFingerprintSha256;
vb['rdpcertificatesubject'] = h.rdpCertificateSubject;
vb['rdpcertificateissuer'] = h.rdpCertificateIssuer;
vb['rdpcertificatecommonname'] = h.rdpCertificateCommonName;
vb['rdpcertificatetrustedat'] = h.rdpCertificateTrustedAt;
vb['rdpcertificatetrustmode'] = h.rdpCertificateTrustMode;
vb['rdpcertificateallowuntrustedroot'] = h.rdpCertificateAllowUntrustedRoot ? 1 : 0;
vb['rdpcertificateallowhostmismatch'] = h.rdpCertificateAllowHostMismatch ? 1 : 0;
```

- [ ] **Step 6: Add CloudStore read mapping**

Where a `RemoteHost` is reconstructed from `ResultSet`, add:

```ts
h.rdpCertificateFingerprintSha256 = getStr('rdpcertificatefingerprintsha256');
h.rdpCertificateSubject = getStr('rdpcertificatesubject');
h.rdpCertificateIssuer = getStr('rdpcertificateissuer');
h.rdpCertificateCommonName = getStr('rdpcertificatecommonname');
const rdpCertTrustedAtIdx: number = rs.getColumnIndex('rdpcertificatetrustedat');
if (rdpCertTrustedAtIdx >= 0) { h.rdpCertificateTrustedAt = rs.getLong(rdpCertTrustedAtIdx); }
const rdpCertTrustModeIdx: number = rs.getColumnIndex('rdpcertificatetrustmode');
if (rdpCertTrustModeIdx >= 0) { h.rdpCertificateTrustMode = rs.getLong(rdpCertTrustModeIdx); }
const allowRootIdx: number = rs.getColumnIndex('rdpcertificateallowuntrustedroot');
if (allowRootIdx >= 0) { h.rdpCertificateAllowUntrustedRoot = rs.getLong(allowRootIdx) === 1; }
const allowMismatchIdx: number = rs.getColumnIndex('rdpcertificateallowhostmismatch');
if (allowMismatchIdx >= 0) { h.rdpCertificateAllowHostMismatch = rs.getLong(allowMismatchIdx) === 1; }
```

- [ ] **Step 7: Verify field references**

Run:

```powershell
rg -n "rdpCertificateFingerprintSha256|rdpcertificatefingerprintsha256|rdpCertificateAllowUntrustedRoot" entry/src/main/ets/model entry/src/main/ets/services
```

Expected: model JSON mapping and CloudStore migration/read/write mapping.

- [ ] **Step 8: Commit**

```powershell
git add entry/src/main/ets/model/RemoteHost.ets entry/src/main/ets/services/CloudStore.ets
git commit -m "feat(rdp): persist certificate trust metadata"
```

---

### Task 3: Define Native API Types And ArkTS Wrappers

**Files:**
- Modify: `entry/src/main/ets/types/rdpnapi.d.ts`
- Modify: `entry/src/main/ets/services/ExtensionLoader.ets`

**Interfaces:**
- Produces:

```ts
export interface RdpCertificateInfo {
  ok: boolean;
  host: string;
  port: number;
  commonName: string;
  subject: string;
  issuer: string;
  fingerprintSha256: string;
  flags: number;
  rootTrusted: boolean;
  hostMismatch: boolean;
  errorCode: number;
  errorMessage: string;
}

export interface RdpRenderStats {
  paintCount: number;
  renderedPaintCount: number;
  firstPaintMs: number;
  lastPaintMs: number;
  lastRenderResult: number;
}
```

- Adds declarations:

```ts
export function probeRdpCertificate(host: string, port: number, serverName: string): RdpCertificateInfo;
export function getRdpRenderStats(sessionId: number): RdpRenderStats;
```

- Extends `SessionConfig`:

```ts
expectedRdpCertificateFingerprintSha256?: string;
rdpAllowUntrustedRoot?: boolean;
rdpAllowHostMismatch?: boolean;
```

- [ ] **Step 1: Update `rdpnapi.d.ts`**

Add the exact interfaces and declarations above.

- [ ] **Step 2: Update `ExtensionLoader.ets` imports**

Change the import line to include:

```ts
RdpCertificateInfo, RdpRenderStats
```

- [ ] **Step 3: Add `ExtensionLoader.probeRdpCertificate`**

Add:

```ts
probeRdpCertificate(host: string, port: number, serverName: string): RdpCertificateInfo {
  try {
    return rdpnapi.probeRdpCertificate(host, port, serverName) as RdpCertificateInfo;
  } catch (err) {
    hilog.error(DOMAIN, TAG, '[ExtensionLoader] probeRdpCertificate: ' + JSON.stringify(err));
    return {
      ok: false,
      host,
      port,
      commonName: '',
      subject: '',
      issuer: '',
      fingerprintSha256: '',
      flags: 0,
      rootTrusted: false,
      hostMismatch: false,
      errorCode: -1,
      errorMessage: 'RDP 证书探测异常'
    };
  }
}
```

- [ ] **Step 4: Add `ExtensionLoader.getRdpRenderStats`**

Add:

```ts
getRdpRenderStats(sessionId: number): RdpRenderStats {
  try {
    return rdpnapi.getRdpRenderStats(sessionId) as RdpRenderStats;
  } catch (err) {
    hilog.error(DOMAIN, TAG, '[ExtensionLoader] getRdpRenderStats: ' + JSON.stringify(err));
    return {
      paintCount: 0,
      renderedPaintCount: 0,
      firstPaintMs: 0,
      lastPaintMs: 0,
      lastRenderResult: -1
    };
  }
}
```

- [ ] **Step 5: Verify declarations**

Run:

```powershell
rg -n "RdpCertificateInfo|RdpRenderStats|probeRdpCertificate|getRdpRenderStats|expectedRdpCertificateFingerprintSha256" entry/src/main/ets
```

Expected: d.ts plus ExtensionLoader wrappers.

- [ ] **Step 6: Commit**

```powershell
git add entry/src/main/ets/types/rdpnapi.d.ts entry/src/main/ets/services/ExtensionLoader.ets
git commit -m "feat(rdp): declare certificate probe and render stats APIs"
```

---

### Task 4: Native Certificate Probe And Connection Enforcement

**Files:**
- Modify: `entry/src/main/cpp/rdp/freerdp_adapter.cpp`
- Modify: `entry/src/main/cpp/extensions/extension_loader_napi.cpp`

**Interfaces:**
- Consumes Task 3 NAPI declarations.
- Produces native functions:
  - `probeRdpCertificate(host, port, serverName)`
  - `getRdpRenderStats(sessionId)`
- Produces FreeRDP certificate enforcement:
  - valid chain/host accepted.
  - untrusted root accepted only with matching approved fingerprint and `rdpAllowUntrustedRoot`.
  - host mismatch accepted only with matching approved fingerprint and `rdpAllowHostMismatch`.
  - changed fingerprint rejected.

- [ ] **Step 1: Add certificate policy fields to native session config**

In the native config struct parsed from `SessionConfig`, add:

```cpp
std::string expectedRdpCertificateFingerprintSha256;
bool rdpAllowUntrustedRoot = false;
bool rdpAllowHostMismatch = false;
```

In the NAPI config parser, read:

```cpp
cfg.expectedRdpCertificateFingerprintSha256 =
    GetOptionalString(env, config, "expectedRdpCertificateFingerprintSha256");
cfg.rdpAllowUntrustedRoot = GetOptionalBool(env, config, "rdpAllowUntrustedRoot", false);
cfg.rdpAllowHostMismatch = GetOptionalBool(env, config, "rdpAllowHostMismatch", false);
```

Before editing this parser, run:

```powershell
rg -n "GetOptionalString|GetOptionalBool|GetStringProperty|GetBoolProperty|SessionConfig" entry/src/main/cpp/extensions/extension_loader_napi.cpp
```

If `GetOptionalString` / `GetOptionalBool` do not exist, add these helpers next to the existing config parser:

```cpp
static std::string GetOptionalString(napi_env env, napi_value obj, const char* name) {
    napi_value value;
    bool has = false;
    napi_has_named_property(env, obj, name, &has);
    if (!has) {
        return "";
    }
    napi_get_named_property(env, obj, name, &value);
    size_t len = 0;
    napi_get_value_string_utf8(env, value, nullptr, 0, &len);
    std::string out(len, '\0');
    napi_get_value_string_utf8(env, value, out.data(), len + 1, &len);
    return out;
}

static bool GetOptionalBool(napi_env env, napi_value obj, const char* name, bool fallback) {
    napi_value value;
    bool has = false;
    napi_has_named_property(env, obj, name, &has);
    if (!has) {
        return fallback;
    }
    bool out = fallback;
    napi_get_named_property(env, obj, name, &value);
    napi_get_value_bool(env, value, &out);
    return out;
}
```

- [ ] **Step 2: Store certificate approval in `FreeRdpAdapter::Impl`**

Add:

```cpp
std::string expectedCertFingerprintSha256;
bool allowUntrustedRoot = false;
bool allowHostMismatch = false;
std::string lastCertFingerprintSha256;
std::string lastCertSubject;
std::string lastCertIssuer;
std::string lastCertCommonName;
DWORD lastCertFlags = 0;
```

Set these fields from config before `freerdp_connect(instance_)`.

- [ ] **Step 3: Replace silent trust callbacks**

Replace the current callbacks returning `2` unconditionally. The callback should:

```cpp
const bool rootIssue = (flags != 0);
const bool fingerprintMatches =
    !impl->expectedCertFingerprintSha256.empty() &&
    impl->expectedCertFingerprintSha256 == fingerprintSha256;
const bool allowedByUser =
    fingerprintMatches &&
    ((!rootIssue || impl->allowUntrustedRoot) &&
     (!hostMismatch || impl->allowHostMismatch));
if (!rootIssue && !hostMismatch) {
    return 1;
}
if (allowedByUser) {
    return 2;
}
impl->setState(ConnectionState::FAILED, "RDP certificate was not approved");
return 0;
```

Implementation detail: FreeRDP callbacks are static. Retrieve `FreeRdpAdapter*` through `instance->context` or the same pattern already used by other callbacks in this file. If one callback variant does not provide fingerprint material, store the available data and reject unless valid.

- [ ] **Step 4: Implement certificate probe mode**

Add a probe helper that uses FreeRDP connection setup with a probe flag:

```cpp
struct RdpCertificateProbeResult {
    bool ok = false;
    std::string host;
    uint16_t port = 3389;
    std::string commonName;
    std::string subject;
    std::string issuer;
    std::string fingerprintSha256;
    DWORD flags = 0;
    bool rootTrusted = false;
    bool hostMismatch = false;
    int errorCode = 0;
    std::string errorMessage;
};
```

The probe callback captures certificate data, returns temporary trust only for the probe, then aborts before a persistent desktop session is recorded. If FreeRDP requires auth to reach the callback in this build, use FreeRDP auth-only mode or connect with empty credentials and stop immediately after certificate callback fires.

- [ ] **Step 5: Add NAPI result object builder**

In `extension_loader_napi.cpp`, add `NapiProbeRdpCertificate` that returns object properties:

```cpp
ok, host, port, commonName, subject, issuer, fingerprintSha256,
flags, rootTrusted, hostMismatch, errorCode, errorMessage
```

- [ ] **Step 6: Add render stats NAPI**

In `freerdp_adapter.cpp`, expose the existing counters:

```cpp
paintCount
renderedPaintCount
firstPaintMs
lastPaintMs
lastRenderResult
```

Add `NapiGetRdpRenderStats` to `extension_loader_napi.cpp`.

- [ ] **Step 7: Register NAPI methods**

In `ExtensionLoaderNapi::Init`, register:

```cpp
napi_create_function(env, "probeRdpCertificate", NAPI_AUTO_LENGTH, NapiProbeRdpCertificate, nullptr, &fn);
napi_set_named_property(env, exports, "probeRdpCertificate", fn);
napi_create_function(env, "getRdpRenderStats", NAPI_AUTO_LENGTH, NapiGetRdpRenderStats, nullptr, &fn);
napi_set_named_property(env, exports, "getRdpRenderStats", fn);
```

- [ ] **Step 8: Verify native markers**

Run:

```powershell
rg -n "probeRdpCertificate|getRdpRenderStats|expectedRdpCertificateFingerprintSha256|RDP certificate was not approved|临时信任|信任所有" entry/src/main/cpp
```

Expected: new APIs exist; old unconditional “信任所有/临时信任” callbacks are gone or only present in probe-specific logging.

- [ ] **Step 9: Build check**

Run the project build command from `CODEWALK.md`:

```powershell
& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js" --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --daemon
```

Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 10: Commit**

```powershell
git add entry/src/main/cpp/rdp/freerdp_adapter.cpp entry/src/main/cpp/extensions/extension_loader_napi.cpp
git commit -m "feat(rdp): enforce approved certificate trust"
```

---

### Task 5: RDP Preflight Token Service

**Files:**
- Create: `entry/src/main/ets/services/RdpPreflightService.ets`

**Interfaces:**
- Produces:

```ts
export interface RdpPreflightToken {
  hostId: string;
  fingerprintSha256: string;
  allowUntrustedRoot: boolean;
  allowHostMismatch: boolean;
  createdAt: number;
}

export class RdpPreflightService {
  static getInstance(): RdpPreflightService;
  createToken(token: Omit<RdpPreflightToken, 'createdAt'>): string;
  consumeToken(id: string): RdpPreflightToken | null;
}
```

- [ ] **Step 1: Create token service**

Create `entry/src/main/ets/services/RdpPreflightService.ets`:

```ts
export interface RdpPreflightToken {
  hostId: string;
  fingerprintSha256: string;
  allowUntrustedRoot: boolean;
  allowHostMismatch: boolean;
  createdAt: number;
}

type RdpPreflightTokenInput = Omit<RdpPreflightToken, 'createdAt'>;

export class RdpPreflightService {
  private static instance: RdpPreflightService | null = null;
  private tokens: Map<string, RdpPreflightToken> = new Map<string, RdpPreflightToken>();
  private readonly ttlMs: number = 120000;

  static getInstance(): RdpPreflightService {
    if (RdpPreflightService.instance === null) {
      RdpPreflightService.instance = new RdpPreflightService();
    }
    return RdpPreflightService.instance;
  }

  createToken(token: RdpPreflightTokenInput): string {
    const id: string = Date.now().toString() + '-' + Math.floor(Math.random() * 1000000).toString();
    this.tokens.set(id, {
      hostId: token.hostId,
      fingerprintSha256: token.fingerprintSha256,
      allowUntrustedRoot: token.allowUntrustedRoot,
      allowHostMismatch: token.allowHostMismatch,
      createdAt: Date.now()
    });
    return id;
  }

  consumeToken(id: string): RdpPreflightToken | null {
    const token: RdpPreflightToken | undefined = this.tokens.get(id);
    this.tokens.delete(id);
    if (!token) { return null; }
    if (Date.now() - token.createdAt > this.ttlMs) {
      return null;
    }
    return token;
  }
}
```

- [ ] **Step 2: Verify service**

Run:

```powershell
rg -n "RdpPreflightService|RdpPreflightToken|consumeToken" entry/src/main/ets/services/RdpPreflightService.ets
```

Expected: service, token interface, create/consume methods.

- [ ] **Step 3: Commit**

```powershell
git add entry/src/main/ets/services/RdpPreflightService.ets
git commit -m "feat(rdp): add certificate preflight token service"
```

---

### Task 6: HostListPage RDP Certificate BindSheet

**Files:**
- Modify: `entry/src/main/ets/pages/HostListPage.ets`

**Interfaces:**
- Consumes:
  - `RdpCertificateInfo` from `rdpnapi.d.ts`
  - `RdpCertificatePreflightState`, `classifyRdpCertificateProbe`, `rdpCertificateWarningMessage`
  - `RdpPreflightService`
- Produces:
  - RDP connection now routes through `openRdpPreflight(host)`.
  - `rdpPreflightToken` route param for `RemoteDesktop`.

- [ ] **Step 1: Add imports**

Add:

```ts
import { RdpCertificateInfo } from '../types/rdpnapi';
import {
  classifyRdpCertificateProbe,
  RdpCertificatePreflightState,
  rdpCertificateWarningMessage
} from '../services/RdpCertificatePreflightPolicy';
import { RdpPreflightService } from '../services/RdpPreflightService';
```

- [ ] **Step 2: Add RDP preflight state**

Near SSH preflight state fields, add:

```ts
@State showRdpPreflight: boolean = false;
@State rdpPreflightState: number = RdpCertificatePreflightState.PROBING;
private rdpPreflightOpenedAt: number = 0;
@State rdpPreflightHostId: string = '';
@State rdpPreflightHostLabel: string = '';
@State rdpPreflightInfo: RdpCertificateInfo | null = null;
@State rdpPreflightError: string = '';
@State rdpPreflightShowCertificate: boolean = false;
```

- [ ] **Step 3: Route RDP through preflight**

Change `connectToHost(host)` branch:

```ts
if (host.protocol === 'ssh') {
  this.openSshPreflight(host);
} else if (host.protocol === 'rdp') {
  this.openRdpPreflight(host);
} else {
  const params: Record<string, Object> = {};
  params['hostId'] = host.id;
  router.pushUrl({ url: 'pages/RemoteDesktop', params: params });
}
```

- [ ] **Step 4: Add preflight open/cancel/dismiss helpers**

Add near SSH helpers:

```ts
private openRdpPreflight(host: RemoteHost): void {
  this.rdpPreflightOpenedAt = Date.now();
  this.rdpPreflightHostId = host.id;
  this.rdpPreflightHostLabel = host.host + ':' + host.port.toString();
  this.rdpPreflightState = RdpCertificatePreflightState.PROBING;
  this.rdpPreflightInfo = null;
  this.rdpPreflightError = '';
  this.rdpPreflightShowCertificate = false;
  this.showRdpPreflight = true;
  this.doRdpPreflightProbe(host);
}

private doRdpPreflightCancel(): void {
  this.showRdpPreflight = false;
  this.rdpPreflightHostId = '';
}

private rdpPreflightSheetHeight(): SheetSize | number {
  return SheetSize.FIT_CONTENT;
}

private isRdpPreflightBusy(): boolean {
  return this.rdpPreflightState === RdpCertificatePreflightState.PROBING;
}

private handleRdpPreflightSheetDismiss(action: DismissSheetAction): void {
  const elapsed: number = Date.now() - this.rdpPreflightOpenedAt;
  if (elapsed < 500 || this.isRdpPreflightBusy()) {
    return;
  }
  this.doRdpPreflightCancel();
  action.dismiss();
}

private getRdpPreflightHost(): RemoteHost | undefined {
  return this.srv.getHost(this.rdpPreflightHostId);
}
```

- [ ] **Step 5: Add probe method**

```ts
private async doRdpPreflightProbe(host: RemoteHost): Promise<void> {
  try {
    await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 80); });
    const serverName: string = host.customHostname.length > 0 ? host.customHostname : host.host;
    const info: RdpCertificateInfo = this.loader.probeRdpCertificate(host.host, host.port, serverName);
    this.rdpPreflightInfo = info;
    if (!info.ok) {
      this.rdpPreflightState = RdpCertificatePreflightState.ERROR;
      this.rdpPreflightError = info.errorMessage || '无法读取 RDP 证书';
      return;
    }
    this.rdpPreflightState = classifyRdpCertificateProbe({
      ok: info.ok,
      fingerprintSha256: info.fingerprintSha256,
      commonName: info.commonName,
      subject: info.subject,
      issuer: info.issuer,
      flags: info.flags,
      rootTrusted: info.rootTrusted,
      hostMismatch: info.hostMismatch,
      errorMessage: info.errorMessage
    }, {
      trustMode: host.rdpCertificateTrustMode,
      savedFingerprintSha256: host.rdpCertificateFingerprintSha256
    });
    if (this.rdpPreflightState === RdpCertificatePreflightState.TRUSTED_MATCH) {
      this.doRdpPreflightReady(host, info);
    }
  } catch (err) {
    this.rdpPreflightState = RdpCertificatePreflightState.ERROR;
    this.rdpPreflightError = 'RDP 证书预检异常: ' + (err instanceof Error ? err.message : JSON.stringify(err));
  }
}
```

- [ ] **Step 6: Add trust and route methods**

```ts
private doRdpPreflightTrustAndContinueWrap(): void {
  const host: RemoteHost | undefined = this.getRdpPreflightHost();
  if (!host || !this.rdpPreflightInfo) { return; }
  const info: RdpCertificateInfo = this.rdpPreflightInfo;
  const updated: RemoteHost = RemoteHost.fromJSON(host.toJSON());
  updated.rdpCertificateFingerprintSha256 = info.fingerprintSha256;
  updated.rdpCertificateSubject = info.subject;
  updated.rdpCertificateIssuer = info.issuer;
  updated.rdpCertificateCommonName = info.commonName;
  updated.rdpCertificateTrustedAt = Date.now();
  updated.rdpCertificateTrustMode = 1;
  updated.rdpCertificateAllowUntrustedRoot = !info.rootTrusted;
  updated.rdpCertificateAllowHostMismatch = info.hostMismatch;
  this.srv.updateHost(updated);
  this.refreshHostListView();
  this.doRdpPreflightReady(updated, info);
}

private doRdpPreflightRetryWrap(): void {
  const host: RemoteHost | undefined = this.getRdpPreflightHost();
  if (host) {
    this.rdpPreflightState = RdpCertificatePreflightState.PROBING;
    this.doRdpPreflightProbe(host);
  }
}

private doRdpPreflightReady(host: RemoteHost, info: RdpCertificateInfo): void {
  const tokenId: string = RdpPreflightService.getInstance().createToken({
    hostId: host.id,
    fingerprintSha256: info.fingerprintSha256,
    allowUntrustedRoot: !info.rootTrusted,
    allowHostMismatch: info.hostMismatch
  });
  this.showRdpPreflight = false;
  this.rdpPreflightHostId = '';
  const params: Record<string, Object> = {};
  params['hostId'] = host.id;
  params['rdpPreflightToken'] = tokenId;
  router.pushUrl({ url: 'pages/RemoteDesktop', params: params });
}
```

- [ ] **Step 7: Add independent bindSheet host**

Near the SSH preflight bindSheet in `build()`, add:

```ts
Column().width('100%').height('100%').hitTestBehavior(HitTestMode.None)
  .bindSheet($$this.showRdpPreflight, this.rdpPreflightPanel(), {
    height: this.rdpPreflightSheetHeight(),
    preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
    dragBar: this.breakpoint === 'sm',
    backgroundColor: Color.Transparent,
    blurStyle: BlurStyle.NONE,
    showClose: false,
    maskColor: 'rgba(0,0,0,0.4)',
    onWillDismiss: (action: DismissSheetAction): void => { this.handleRdpPreflightSheetDismiss(action); }
  })
```

- [ ] **Step 8: Add RDP preflight panel builder**

Add builders modeled after SSH but with screenshot copy:

```ts
@Builder rdpPreflightPanel() {
  Column() {
    Row() {
      SymbolGlyph($r('sys.symbol.lock_shield'))
        .fontSize(52)
        .fontColor([this.accentColor])
        .margin({ right: 14 })
      Text(this.rdpPreflightTitleText())
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.pal().text)
        .fontFamily(this.font())
        .layoutWeight(1)
    }.width('100%').margin({ bottom: 18 })

    if (this.rdpPreflightState === RdpCertificatePreflightState.PROBING) {
      this.rdpPreflightLoadingContent()
    } else if (this.rdpPreflightState === RdpCertificatePreflightState.ERROR) {
      this.rdpPreflightErrorContent()
    } else {
      this.rdpPreflightWarningContent()
    }

    this.rdpPreflightButtonsContent()
  }
  .width('100%')
  .padding(20)
  .backgroundColor(this.pal().bg)
  .backgroundBlurStyle(BlurStyle.Regular)
  .borderRadius(this.breakpoint === 'sm' ? { topLeft: 20, topRight: 20, bottomLeft: 0, bottomRight: 0 } : 20)
  .constraintSize({ maxWidth: 760 })
  .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
}

private rdpPreflightTitleText(): string {
  if (this.rdpPreflightState === RdpCertificatePreflightState.PROBING) { return '正在检查 RDP 证书...'; }
  if (this.rdpPreflightState === RdpCertificatePreflightState.CERTIFICATE_CHANGED) { return 'RDP 主机证书已改变'; }
  if (this.rdpPreflightState === RdpCertificatePreflightState.ERROR) { return 'RDP 证书检查失败'; }
  return 'RDP 证书需要确认';
}
```

Add content builders:

```ts
@Builder rdpPreflightLoadingContent() {
  Column() {
    LoadingProgress().width(32).height(32).color(this.accentColor)
    Text('正在检查 ' + this.rdpPreflightHostLabel + ' 的远程桌面证书')
      .fontSize(14).fontColor(this.pal().text2).fontFamily(this.font()).margin({ top: 12 })
  }.width('100%').padding({ top: 24, bottom: 28 })
}

@Builder rdpPreflightWarningContent() {
  Column() {
    Text(rdpCertificateWarningMessage(
      this.rdpPreflightHostLabel,
      this.rdpPreflightInfo ? this.rdpPreflightInfo.rootTrusted : false,
      this.rdpPreflightInfo ? this.rdpPreflightInfo.hostMismatch : false
    ))
      .fontSize(16)
      .fontWeight(FontWeight.Bold)
      .fontColor(this.pal().text)
      .fontFamily(this.font())
      .margin({ bottom: 18 })
    if (this.rdpPreflightShowCertificate) {
      this.rdpCertificateDetailCard()
    }
  }.width('100%')
}

@Builder rdpCertificateDetailCard() {
  Column() {
    if (this.rdpPreflightInfo) {
      this.rdpCertificateLine('通用名', this.rdpPreflightInfo.commonName)
      this.rdpCertificateLine('主题', this.rdpPreflightInfo.subject)
      this.rdpCertificateLine('颁发者', this.rdpPreflightInfo.issuer)
      this.rdpCertificateLine('SHA256', this.rdpPreflightInfo.fingerprintSha256)
      this.rdpCertificateLine('Flags', '0x' + this.rdpPreflightInfo.flags.toString(16).toUpperCase())
    }
  }.width('100%').padding(14).backgroundColor(this.pal().surface).borderRadius(10)
}

@Builder rdpCertificateLine(label: string, value: string) {
  Row() {
    Text(label).width(72).fontSize(12).fontColor(this.pal().text3).fontFamily(this.font())
    Text(value.length > 0 ? value : '(空)')
      .fontSize(12)
      .fontColor(this.pal().text)
      .fontFamily('monospace')
      .layoutWeight(1)
  }.width('100%').margin({ bottom: 6 })
}

@Builder rdpPreflightErrorContent() {
  Column() {
    Row() {
      SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
        .fontSize(36).fontColor(['#FF5252'])
      Text(this.rdpPreflightError || '无法读取 RDP 证书')
        .fontSize(14).fontColor('#FF5252').fontFamily(this.font()).margin({ left: 10 }).layoutWeight(1)
    }.width('100%').margin({ bottom: 12 })
    Text('请确认远程桌面服务已开启，网络可达，端口为 RDP 服务端口。')
      .fontSize(12).fontColor(this.pal().text3).fontFamily(this.font())
  }.width('100%').padding({ top: 18, bottom: 18 })
}
```

Add buttons:

```ts
@Builder rdpPreflightButtonsContent() {
  Row() {
    if (this.rdpPreflightState === RdpCertificatePreflightState.PROBING) {
      Button('取消').fontSize(14).height(40).layoutWeight(1)
        .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(10)
        .onClick(() => { this.doRdpPreflightCancel(); })
    } else if (this.rdpPreflightState === RdpCertificatePreflightState.ERROR) {
      Button('取消').fontSize(14).height(40).layoutWeight(1)
        .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(10)
        .onClick(() => { this.doRdpPreflightCancel(); })
      Button('重试').fontSize(14).height(40).layoutWeight(1)
        .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(10).margin({ left: 12 })
        .onClick(() => { this.doRdpPreflightRetryWrap(); })
    } else {
      Button(this.rdpPreflightShowCertificate ? '隐藏证书' : '显示证书')
        .fontSize(14).height(40).layoutWeight(1)
        .backgroundColor(this.pal().surface).fontColor(this.pal().text).borderRadius(10)
        .onClick(() => { this.rdpPreflightShowCertificate = !this.rdpPreflightShowCertificate; })
      Button('取消').fontSize(14).height(40).layoutWeight(1)
        .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(10).margin({ left: 12 })
        .onClick(() => { this.doRdpPreflightCancel(); })
      Button('继续').fontSize(14).height(40).layoutWeight(1)
        .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(10).margin({ left: 12 })
        .onClick(() => { this.doRdpPreflightTrustAndContinueWrap(); })
    }
  }.width('100%').margin({ top: 18 })
}
```

- [ ] **Step 9: Verify HostList source**

Run:

```powershell
rg -n "showRdpPreflight|openRdpPreflight|doRdpPreflightProbe|rdpPreflightPanel|rdpPreflightToken" entry/src/main/ets/pages/HostListPage.ets
```

Expected: state, probe, bindSheet, route token.

- [ ] **Step 10: Commit**

```powershell
git add entry/src/main/ets/pages/HostListPage.ets
git commit -m "feat(rdp): add certificate preflight sheet"
```

---

### Task 7: RemoteDesktop Certificate Token And Error Dialog

**Files:**
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets`

**Interfaces:**
- Consumes:
  - `RdpPreflightService`
  - `RdpPreflightToken`
  - `SessionConfig.expectedRdpCertificateFingerprintSha256`
- Produces:
  - User-facing modal error state.
  - RDP config certificate fields.

- [ ] **Step 1: Add imports**

```ts
import { RdpPreflightService, RdpPreflightToken } from '../services/RdpPreflightService';
```

- [ ] **Step 2: Add state**

Near `connectionError`, add:

```ts
@State showSessionErrorDialog: boolean = false;
@State sessionErrorTitle: string = '';
@State sessionErrorMessage: string = '';
@State sessionErrorCode: string = '';
private rdpPreflightToken: RdpPreflightToken | null = null;
```

- [ ] **Step 3: Consume route token**

In the route-param parsing block that reads `hostId`, add:

```ts
const rdpPreflightTokenId: string = (p['rdpPreflightToken'] as string) || '';
if (rdpPreflightTokenId.length > 0) {
  this.rdpPreflightToken = RdpPreflightService.getInstance().consumeToken(rdpPreflightTokenId);
}
```

Before editing, locate the route params variable with:

```powershell
rg -n "getParams|hostId|sshPreflightToken" entry/src/main/ets/pages/RemoteDesktop.ets
```

Add the token consume block immediately after the existing `hostId` read in that same function.

- [ ] **Step 4: Add structured error helper**

Add:

```ts
private showRemoteSessionError(title: string, message: string, code: string): void {
  this.sessionErrorTitle = title;
  this.sessionErrorMessage = message;
  this.sessionErrorCode = code;
  this.connectionError = title;
  this.connectionErrorDetail = message + ' 错误代码: ' + code;
  this.showSessionErrorDialog = true;
}
```

- [ ] **Step 5: Add modal builder**

Add near existing builders:

```ts
@Builder sessionErrorDialogBuilder() {
  Column() {
    SymbolGlyph($r('sys.symbol.exclamationmark_triangle_fill'))
      .fontSize(76)
      .fontColor(['#F2C200'])
      .margin({ bottom: 30 })
    Text(this.sessionErrorTitle)
      .fontSize(22)
      .fontWeight(FontWeight.Bold)
      .fontColor(this.pal().text)
      .fontFamily(this.font())
      .width('100%')
      .margin({ bottom: 24 })
    Text(this.sessionErrorMessage)
      .fontSize(18)
      .fontColor(this.pal().text)
      .fontFamily(this.font())
      .width('100%')
      .margin({ bottom: 22 })
    Text('错误代码: ' + this.sessionErrorCode)
      .fontSize(18)
      .fontColor(this.pal().text)
      .fontFamily(this.font())
      .width('100%')
      .margin({ bottom: 42 })
    Button('关闭')
      .height(52)
      .width('100%')
      .fontSize(18)
      .fontWeight(FontWeight.Bold)
      .fontColor('#FFFFFF')
      .backgroundColor(this.accentColor)
      .borderRadius(28)
      .onClick((): void => {
        this.showSessionErrorDialog = false;
        this.goBack();
      })
  }
  .width(this.breakpoint === 'sm' ? '92%' : 520)
  .padding({ left: 42, right: 42, top: 52, bottom: 30 })
  .backgroundColor('rgba(235,235,235,0.96)')
  .borderRadius(42)
  .shadow({ radius: 18, color: 'rgba(0,0,0,0.24)', offsetY: 4 })
}
```

- [ ] **Step 6: Render dialog overlay**

In root `Stack()` build body, add after the main content:

```ts
if (this.showSessionErrorDialog) {
  Stack() {
    this.sessionErrorDialogBuilder()
  }
  .width('100%')
  .height('100%')
  .backgroundColor('rgba(0,0,0,0.48)')
  .alignContent(Alignment.Center)
}
```

- [ ] **Step 7: Pass certificate token into `SessionConfig`**

Before `const cfg: SessionConfig = { ... }`, add:

```ts
let expectedRdpCertificateFingerprintSha256: string = '';
let rdpAllowUntrustedRoot: boolean = false;
let rdpAllowHostMismatch: boolean = false;
if (host.protocol === 'rdp') {
  if (!this.rdpPreflightToken || this.rdpPreflightToken.hostId !== host.id ||
      this.rdpPreflightToken.fingerprintSha256.length === 0) {
    throw new Error('RDP 连接缺少证书预检授权 [E-RDP-CERT-PREFLIGHT]');
  }
  expectedRdpCertificateFingerprintSha256 = this.rdpPreflightToken.fingerprintSha256;
  rdpAllowUntrustedRoot = this.rdpPreflightToken.allowUntrustedRoot;
  rdpAllowHostMismatch = this.rdpPreflightToken.allowHostMismatch;
}
```

Inside `cfg`, add:

```ts
expectedRdpCertificateFingerprintSha256: expectedRdpCertificateFingerprintSha256,
rdpAllowUntrustedRoot: rdpAllowUntrustedRoot,
rdpAllowHostMismatch: rdpAllowHostMismatch,
```

- [ ] **Step 8: Map catch errors to modal copy**

Replace the catch block ending with `connectionError` assignment with:

```ts
const errObj: Error = err as Error;
const detail: string = errObj.message ? errObj.message : '未知连接错误 [E-CONNECT-UNKNOWN]';
if (detail.indexOf('[E-RENDERER-INIT]') >= 0) {
  this.showRemoteSessionError('你的会话已断开', '远程会话中的图形显示组件启动失败。', '0x11');
} else if (detail.indexOf('[E-RDP-CERT') >= 0 || detail.indexOf('certificate') >= 0) {
  this.showRemoteSessionError('你的会话已断开', '远程主机证书未通过本次连接验证。', '0x12');
} else {
  this.showRemoteSessionError('你的会话已断开', detail, '0x13');
}
console.error('[RD-DIAG] Connection failed: ' + safeError(detail));
```

- [ ] **Step 9: Verify source**

Run:

```powershell
rg -n "RdpPreflightService|rdpPreflightToken|showRemoteSessionError|sessionErrorDialogBuilder|expectedRdpCertificateFingerprintSha256" entry/src/main/ets/pages/RemoteDesktop.ets
```

Expected: token consumption, cfg fields, modal error state.

- [ ] **Step 10: Commit**

```powershell
git add entry/src/main/ets/pages/RemoteDesktop.ets
git commit -m "feat(rdp): require certificate token and show session errors"
```

---

### Task 8: RDP First-Frame Watchdog

**Files:**
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets`
- Modify: `entry/src/main/cpp/rdp/freerdp_adapter.cpp`
- Modify: `entry/src/main/cpp/extensions/extension_loader_napi.cpp`

**Interfaces:**
- Consumes:
  - `ExtensionLoader.getRdpRenderStats(sessionId)`
- Produces:
  - `waitForRdpFirstFrame(sessionId: number, attemptId: number): Promise<boolean>`

- [ ] **Step 1: Ensure native records `lastRenderResult` and `lastPaintUs`**

In `freerdp_adapter.cpp::Impl`, add:

```cpp
int lastRenderResult = 0;
int64_t lastPaintUs = 0;
```

In `cbEndPaint`, update:

```cpp
self->impl_->lastPaintUs = nowUs;
...
self->impl_->lastRenderResult = ret;
```

- [ ] **Step 2: Implement native render stats getter**

Expose:

```cpp
RdpRenderStats FreeRdpAdapter::getRenderStats() const {
  RdpRenderStats stats;
  stats.paintCount = impl_->paintCount;
  stats.renderedPaintCount = impl_->renderedPaintCount;
  stats.firstPaintMs = impl_->firstPaintUs > 0 ? impl_->firstPaintUs / 1000 : 0;
  stats.lastPaintMs = impl_->lastPaintUs > 0 ? impl_->lastPaintUs / 1000 : 0;
  stats.lastRenderResult = impl_->lastRenderResult;
  return stats;
}
```

If there is no header struct yet, add it next to the adapter declarations.

- [ ] **Step 3: Implement `NapiGetRdpRenderStats`**

In `extension_loader_napi.cpp`, find the active connection by `sessionId`; if absent, return zeros. Return:

```cpp
paintCount, renderedPaintCount, firstPaintMs, lastPaintMs, lastRenderResult
```

- [ ] **Step 4: Add ArkTS wait method**

In `RemoteDesktop.ets`, add:

```ts
private async waitForRdpFirstFrame(sessionId: number, attemptId: number): Promise<boolean> {
  const startedAt: number = Date.now();
  const refreshAt: number[] = [1200, 2500, 5000];
  let refreshIndex: number = 0;
  while (Date.now() - startedAt < 8000) {
    if (attemptId !== this.connectAttemptId || this.sessionId !== sessionId) {
      return false;
    }
    const stats = this.loader.getRdpRenderStats(sessionId);
    if (stats.renderedPaintCount > 0) {
      hilog.info(RD_DOMAIN, RD_TAG, 'RDP first frame ready rendered=' +
        stats.renderedPaintCount.toString() + ' paints=' + stats.paintCount.toString());
      return true;
    }
    const elapsed: number = Date.now() - startedAt;
    if (refreshIndex < refreshAt.length && elapsed >= refreshAt[refreshIndex]) {
      this.loader.requestFrameRefresh();
      refreshIndex++;
    }
    await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 250); });
  }
  const finalStats = this.loader.getRdpRenderStats(sessionId);
  hilog.error(RD_DOMAIN, RD_TAG, 'RDP first frame timeout paints=' +
    finalStats.paintCount.toString() + ' rendered=' + finalStats.renderedPaintCount.toString() +
    ' lastRender=' + finalStats.lastRenderResult.toString() +
    ' nativeMessage=' + this.loader.getConnectionLastMessage(sessionId));
  throw new Error('远程会话已建立，但没有收到可显示的远程画面。 [E-RDP-NO-FIRST-FRAME]');
}
```

- [ ] **Step 5: Call watchdog before marking connected**

After:

```ts
const nativeReady: boolean = await this.waitForNativeConnected(...);
```

add:

```ts
if (host.protocol === 'rdp') {
  await this.waitForRdpFirstFrame(sid, attemptId);
}
```

Keep `this.connected = true` after this call.

- [ ] **Step 6: Map no-frame error to `0x11`**

In the catch mapping from Task 7, add:

```ts
if (detail.indexOf('[E-RDP-NO-FIRST-FRAME]') >= 0) {
  this.showRemoteSessionError('你的会话已断开', '远程会话中的图形显示组件启动失败。', '0x11');
}
```

Place it before the generic native-connect branch.

- [ ] **Step 7: Verify source**

Run:

```powershell
rg -n "waitForRdpFirstFrame|getRdpRenderStats|E-RDP-NO-FIRST-FRAME|lastRenderResult|lastPaintUs" entry/src/main/ets/pages/RemoteDesktop.ets entry/src/main/cpp
```

Expected: ArkTS watchdog, native counters, NAPI getter.

- [ ] **Step 8: Commit**

```powershell
git add entry/src/main/ets/pages/RemoteDesktop.ets entry/src/main/cpp/rdp/freerdp_adapter.cpp entry/src/main/cpp/extensions/extension_loader_napi.cpp
git commit -m "feat(rdp): report connected sessions without first frame"
```

---

### Task 9: Build, Regression Checks, And Handoff

**Files:**
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md`
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md`
- Modify: `C:\Users\14288\.codex\projects\C--Users-14288\memory\remote-desktop-project-state.md`
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\CODEWALK.md` if certificate/no-frame rules should become permanent.

- [ ] **Step 1: Run whitespace checks**

```powershell
git diff --check -- entry/src/main/ets/services/RdpCertificatePreflightPolicy.ets entry/src/test/RdpCertificatePreflightPolicy.test.ets entry/src/test/List.test.ets entry/src/main/ets/services/RdpPreflightService.ets entry/src/main/ets/types/rdpnapi.d.ts entry/src/main/ets/services/ExtensionLoader.ets entry/src/main/ets/model/RemoteHost.ets entry/src/main/ets/services/CloudStore.ets entry/src/main/ets/pages/HostListPage.ets entry/src/main/ets/pages/RemoteDesktop.ets entry/src/main/cpp/rdp/freerdp_adapter.cpp entry/src/main/cpp/extensions/extension_loader_napi.cpp
```

Expected: no whitespace errors. CRLF warnings are acceptable.

- [ ] **Step 2: Run build**

```powershell
& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js" --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --daemon
```

Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 3: Manual validation matrix**

Validate:

```text
RDP self-signed first connection:
  HostListPage shows certificate bindSheet before RemoteDesktop route.
  Copy includes: 无法将证书反向验证到根证书。
  Cancel does not connect.
  显示证书 expands CN/subject/issuer/SHA256/flags.
  继续 stores trust and connects.

RDP trusted same certificate:
  Same saved fingerprint should not ask again, or should auto-route after quick probe depending on implementation.

RDP changed certificate:
  Sheet shows certificate changed warning.
  Connection does not proceed until the user explicitly continues.

RDP native connect failure:
  User sees modal title 你的会话已断开.
  Error code is 0x13 unless certificate-specific.

RDP renderer init failure or no first frame:
  User sees modal title 你的会话已断开.
  Message: 远程会话中的图形显示组件启动失败。
  Error code: 0x11.

RDP normal:
  First frame appears before input-ready gate.
  Existing startup sizing rule remains: initRenderer uses remote desktop size; resizeRenderer happens after init.

SSH:
  Existing SSH fingerprint bindSheet still works.

RustDesk:
  No RDP certificate preflight appears.
  RustDesk topbar behavior remains unchanged.
```

- [ ] **Step 4: Update handoff files**

Record:

```text
Summary: RDP certificate preflight added before connection; native FreeRDP certificate callbacks no longer trust all silently; RDP connected-without-first-frame now reports modal error 0x11.
Validation: diff check, assembleHap result, device matrix result.
Known limitations: exact certificate probe behavior depends on FreeRDP callback timing; any probe fallback used should be documented.
```

- [ ] **Step 5: Final commit**

```powershell
git add C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md C:\Users\14288\.codex\projects\C--Users-14288\memory\remote-desktop-project-state.md C:\Users\14288\DevEcoStudioProjects\Mission_transformation\CODEWALK.md
git commit -m "docs: record rdp certificate and no-frame ux upgrade"
```

---

## Self-Review

**Spec coverage:** The plan covers the user’s two requested RDP optimizations: root-certificate verification before connection with an SSH-like bindSheet, and a screenshot-style modal error for connected sessions that cannot display a frame. It also preserves RDP startup sizing constraints and RustDesk/RDP preference separation.

**Placeholder scan:** No task contains deferred implementation language. The only implementation uncertainty is explicitly bounded: if FreeRDP probe timing cannot collect a certificate before auth, use auth-only or lightweight TLS probe and keep the same result shape.

**Type consistency:** `RdpCertificateInfo`, `RdpRenderStats`, `RdpPreflightToken`, route param `rdpPreflightToken`, and `SessionConfig.expectedRdpCertificateFingerprintSha256` are consistently named across tasks.

**Risk notes:** This plan intentionally changes native certificate trust behavior. Test with both self-signed Windows RDP and a trusted certificate host before merging. The first-frame watchdog should be RDP-only and must not delay RustDesk sessions.
