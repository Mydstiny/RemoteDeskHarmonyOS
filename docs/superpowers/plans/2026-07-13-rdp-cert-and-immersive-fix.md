# RDP Certificate Async Probe and Remote Immersive Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task with verification checkpoints. This work stays in the main workspace as explicitly requested by the user.

**Goal:** Move RDP certificate probing off the ArkTS/UI thread and add session-scoped navigation-bar immersion for connected RDP/RustDesk sessions without changing certificate trust or remote input semantics.

**Architecture:** Keep the existing synchronous NAPI function for compatibility, add a Promise-based NAPI function backed by `napi_create_async_work`, and make `HostListPage` use only the async facade with a generation guard. Add a pure `RemoteImmersivePolicy` for protocol/lifecycle decisions, then let `RemoteDesktop` apply and restore the Window API at connection, background restore, and cleanup boundaries.

**Tech Stack:** HarmonyOS NEXT API 23 ArkTS, N-API async work, C++17, FreeRDP/OpenSSL certificate probe, Hypium ArkTS tests, existing lightweight C++ policy test runner, DevEco hvigor.

## Global Constraints

- Preserve the existing RDP certificate trust policy, bindSheet order, certificate flags, and one-time certificate routing.
- Never call the synchronous certificate probe from an ArkTS UI path after this change.
- Use `napi_create_async_work`; do not substitute a timer or an ArkTS `async` keyword for thread offload.
- Do not call NAPI APIs from the native async execute callback.
- Hide navigation only for connected RDP/RustDesk sessions; do not change SSH/VNC or global host-list behavior.
- Do not add an app-owned bottom-edge swipe recognizer on the remote XComponent.
- Use local API 23 documentation and the project’s CODEWALK build command.
- Preserve existing repository changes and do not modify the unrelated AGPL plan.

---

### Task 1: Record the design and create red tests

**Files:**
- Create: `docs/superpowers/specs/2026-07-13-rdp-cert-and-immersive-design.md`
- Create: `docs/superpowers/plans/2026-07-13-rdp-cert-and-immersive-fix.md`
- Create: `entry/src/main/ets/services/RemoteImmersivePolicy.ets`
- Create: `entry/src/main/ets/services/RdpCertificateProbeLifecyclePolicy.ets`
- Test: `entry/src/ohosTest/ets/test/RemoteImmersivePolicy.test.ets`
- Test: `entry/src/ohosTest/ets/test/RdpCertificateProbeLifecyclePolicy.test.ets`
- Test: `entry/src/test/RemoteImmersivePolicy.test.ets`
- Test: `entry/src/test/RdpCertificateProbeLifecyclePolicy.test.ets`
- Modify: `entry/src/ohosTest/ets/test/List.test.ets`
- Modify: `entry/src/test/List.test.ets`

**Interfaces:**
- `shouldHideRemoteNavigation(protocol: string, connected: boolean): boolean`
- `shouldReapplyRemoteNavigation(protocol: string, connected: boolean, backgroundPreserved: boolean): boolean`
- `shouldRestoreRemoteNavigation(reason: string, backgroundPreserved: boolean): boolean`
- `nextRdpCertificateProbeGeneration(current: number): number`
- `shouldApplyRdpCertificateProbeResult(activeGeneration: number, resultGeneration: number, activeHostId: string, resultHostId: string): boolean`

- [x] **Step 1: Write the design and implementation plan to the main workspace.**

- [x] **Step 2: Add the policy tests before implementing the policy modules.**

Expected test assertions:

```ts
expect(shouldHideRemoteNavigation('rdp', true)).assertTrue();
expect(shouldHideRemoteNavigation('rustdesk', true)).assertTrue();
expect(shouldHideRemoteNavigation('ssh', true)).assertFalse();
expect(shouldHideRemoteNavigation('rdp', false)).assertFalse();
expect(shouldReapplyRemoteNavigation('rustdesk', true, true)).assertTrue();
expect(shouldRestoreRemoteNavigation('explicit-exit', false)).assertTrue();
expect(shouldRestoreRemoteNavigation('background-preserve', true)).assertFalse();
expect(shouldApplyRdpCertificateProbeResult(4, 4, 'host-a', 'host-a')).assertTrue();
expect(shouldApplyRdpCertificateProbeResult(4, 3, 'host-a', 'host-a')).assertFalse();
expect(shouldApplyRdpCertificateProbeResult(4, 4, 'host-a', 'host-b')).assertFalse();
```

The tests were written before the policy modules. The focused compile task in this project did not include the new test entry until the full `onDeviceTest` graph; the later full graph compiled the test sources successfully. The unavailable isolated red result is recorded rather than being presented as a test failure.

### Task 2: Implement the pure lifecycle policies and turn tests green

**Files:**
- Modify: `entry/src/main/ets/services/RemoteImmersivePolicy.ets`
- Modify: `entry/src/main/ets/services/RdpCertificateProbeLifecyclePolicy.ets`
- Modify: `entry/src/ohosTest/ets/test/RemoteImmersivePolicy.test.ets`
- Modify: `entry/src/ohosTest/ets/test/RdpCertificateProbeLifecyclePolicy.test.ets`
- Modify: `entry/src/ohosTest/ets/test/List.test.ets`

**Interfaces:**
- The two policy modules export exactly the signatures in Task 1 and contain no UI, NAPI, or Window imports.

- [x] **Step 1: Implement the minimal deterministic policy functions.**

`RemoteImmersivePolicy` returns true only for `rdp`/`rustdesk` plus connected state. Reapply is true only for a connected supported protocol after a preserved background restore. Restore returns false only for the explicit background-preserve reason while the session is preserved.

`RdpCertificateProbeLifecyclePolicy` increments generation monotonically and accepts a result only when both generation and host ID match.

- [x] **Step 2: Run the same focused compile path.**

The `onDeviceTest` ArkTS compile stage completed without errors for the new policy modules/tests. Device execution was blocked later by the missing hvigor `connect-key` configuration.

### Task 3: Add a genuinely asynchronous native RDP certificate probe

**Files:**
- Modify: `entry/src/main/cpp/extensions/extension_loader_napi.cpp:211-255, 1915-1919`
- Test/build surface: `entry/src/main/cpp/CMakeLists.txt` only if a focused native bridge policy test is needed; do not link a second OpenSSL implementation.

**Interfaces:**
- Add `napi_value NapiProbeRdpCertificateAsync(napi_env env, napi_callback_info info)`.
- Export JS function `probeRdpCertificateAsync(host: string, port: number, serverName: string): Promise<RdpCertificateInfo>`.

- [x] **Step 1: Add an async work data structure and bridge contract source check.**

The work data owns host, port, server name, `std::shared_ptr<ProtocolAdapter>`, result, error text, deferred, async work handle, and a `bool` indicating worker failure. The contract check must verify that the new export name is registered and the existing sync export remains registered; use source/build validation if a NAPI runtime test is unavailable.

- [x] **Step 2: Implement execute and complete callbacks.**

Execute calls only `adapter->probeRdpCertificate(...)` and stores plain C++ data. Complete creates the JS certificate object on the JS thread, resolves on success, rejects on async setup/worker failure, deletes async work, and frees work data. If the adapter is missing, resolve a normal certificate error result matching the sync function rather than blocking or throwing from execute.

- [x] **Step 3: Register `probeRdpCertificateAsync` beside the sync function.**

Do not remove or change `probeRdpCertificate`. Add a stable log marker for async start/complete and preserve all existing result property names.

- [x] **Step 4: Build the native/HAP target enough to compile the NAPI bridge.**

Run the CODEWALK hvigor command. Expected result: `BUILD SUCCESSFUL`. If native CMake is blocked by a pre-existing external library problem, record the exact error and still run ArkTS/source checks; do not claim runtime verification.

### Task 4: Switch the RDP certificate UI to async with stale-result protection

**Files:**
- Modify: `entry/src/main/ets/types/rdpnapi.d.ts:30`
- Modify: `entry/src/main/ets/services/ExtensionLoader.ets:93-110`
- Modify: `entry/src/main/ets/pages/HostListPage.ets:1622-1745`

**Interfaces:**
- `rdpnapi.probeRdpCertificateAsync(host, port, serverName): Promise<RdpCertificateInfo>`.
- `ExtensionLoader.probeRdpCertificateAsync(host, port, serverName): Promise<RdpCertificateInfo>`.
- `HostListPage.doRdpCertificateProbe(host, generation): Promise<void>`.

- [x] **Step 1: Add the async declaration and facade method.**

The facade must not fall back to the synchronous method. On bridge failure, reject or return the same shaped error object through a Promise so UI code stays non-blocking.

- [x] **Step 2: Thread a generation through open, retry, cancel, and probe.**

Increment the generation when opening/retrying/cancelling. Keep the current 80/160 ms render delay only as a short UI yield if needed; the network call must be awaited through `probeRdpCertificateAsync`. Before every state mutation after `await`, require `shouldApplyRdpCertificateProbeResult(...)`.

- [x] **Step 3: Keep existing certificate decision and routing behavior unchanged.**

The same `RdpCertificateInfo` flags drive `TRUSTED`, `UNTRUSTED`, `MISMATCH`, and error states. Preserve the existing sheet dismiss guard and bindSheet ordering.

- [x] **Step 4: Run ArkTS compilation and inspect source for sync UI calls.**

Run `rg -n "probeRdpCertificate\(" entry/src/main/ets/pages/HostListPage.ets` and confirm no sync call remains in the page. The only page call must be `probeRdpCertificateAsync`.

### Task 5: Apply session-scoped navigation immersion

**Files:**
- Modify: `entry/src/main/ets/pages/RemoteDesktop.ets:36-80, 247-300, 2460-2515, 2526-2580, 2828-2845`
- Use: `entry/src/main/ets/services/RemoteImmersivePolicy.ets`

**Interfaces:**
- Add `private remoteNavigationHidden: boolean = false`.
- Add `private async setRemoteNavigationHidden(hidden: boolean, reason: string): Promise<void>`.

- [x] **Step 1: Implement best-effort Window API application.**

Use the existing host context and `window.getLastWindow(ctx)`. When hiding, call `setSpecificSystemBarEnabled('navigation', false, false)` and then best-effort `navigationIndicator=false`. When restoring, set both back to true. Catch each API failure with fixed diagnostic codes; never throw into connect/cleanup.

- [x] **Step 2: Hide only after the native session is connected.**

After `this.connected = true` and orientation/keep-screen setup, call the hide method for RDP/RustDesk. Do not hide on connect start, certificate preflight, host list, SSH, or VNC.

- [x] **Step 3: Reapply after background render restore.**

After `doBackgroundRestoreRender` marks the session connected, call the same hide method. `detachForBackground` must not restore it.

- [x] **Step 4: Restore during explicit cleanup and error cleanup.**

Call restore from `disconnectAndCleanup` before it finishes. Keep the call best-effort and do not make system-bar failure change connection teardown.

- [x] **Step 5: Add a comment documenting system gesture ownership.**

Document that the first edge swipe/reveal and subsequent home navigation are OS-owned and deliberately not reimplemented on the remote surface.

### Task 6: Verify, update handoff artifacts, and report limitations

**Files:**
- Modify: `.planning/2026-07-13-rdp-cert-and-immersive-fix/` progress/findings if needed
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md` and `TASKS.md` only if write access is available
- Modify: `remote-desktop-project-state.md` only if write access is available in the configured memory location

- [x] **Step 1: Run formatting/source checks.**

Run `git diff --check` and targeted `rg` checks for synchronous page calls, exported async NAPI name, navigation hide/restore call sites, and fixed diagnostic codes.

- [x] **Step 2: Run production build.**

Use:

```powershell
$env:DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'; $env:OHOS_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'; & 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --daemon
```

Expected: `BUILD SUCCESSFUL`.

- [x] **Step 3: Run existing native tests and the available ohosTest compile target.**

Record pass counts and any pre-existing target/device limitation. At minimum, compile the HAP and run the existing lightweight native test executable if it is already built.

- [x] **Step 4: Device install/launch smoke; remote-session matrix remains explicitly unverified.**

On available emulators, verify host-list bars remain unchanged, RDP/RustDesk connected page hides navigation, edge swipe behavior remains OS-owned, explicit back restores bars, and background-preserved restore re-hides. If no reachable RDP/RustDesk endpoint is configured, mark those runtime cases unverified rather than simulating success.

- [x] **Step 5: Update project handoff/state and attempt the required commit.**

Use `apply_patch` for handoff/state files when writable. Run `git status --short`; commit only intended product/plan files. The main-workspace planning/progress records were updated and the intended changes were committed. The external `Mission_transformation` handoff/state files were not writable under the current sandbox, so that limitation is reported explicitly.

## Verification Results

- Native HAP build after fixing the API 23 `napi_create_async_work` signature: `BUILD SUCCESSFUL`.
- Existing lightweight native suite: `75 passed, 0 failed`.
- `onDeviceTest` reached and completed `ohosTest@OhosTestCompileArkTS` and packaged the test HAP; the final device coverage task failed because hvigor requires a configured `connect-key`.
- Signed HAP installed and launched successfully on `127.0.0.1:5555` and `127.0.0.1:5557`.
- No reachable RDP/RustDesk endpoint was available for runtime certificate timeout/cancel or connected navigation gesture verification.
