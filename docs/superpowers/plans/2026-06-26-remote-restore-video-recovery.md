# Remote Restore Video Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend foreground video recovery for preserved RDP/RustDesk sessions so returning from the background automatically requests fresh video through a 3-second target and 10-second fallback window.

**Architecture:** Keep the existing background detach and foreground reattach flow. Change only the restore refresh policy schedule and its tests; protocol-specific refresh behavior stays in existing RDP/RustDesk `requestFrameRefresh()` implementations.

**Tech Stack:** ArkTS policy service and Hypium policy tests; existing C++ native regression suite; DevEco hvigor HAP build.

## Global Constraints

- Do not guarantee or require video rendering while the app is backgrounded.
- Do not reconnect protocol sessions during normal foreground recovery.
- Do not touch the validated RustDesk long-run video path, audio pipeline, or RDP connect path.
- Preserve timer cleanup on detach, restore entry, and disconnect cleanup.
- Recovery schedule must include immediate refresh, cover 3000 ms, and end at 10000 ms.

---

### Task 1: Restore Refresh Policy Schedule

**Files:**
- Modify: `entry/src/main/ets/services/RemoteRestoreFrameRefreshPolicy.ets`
- Modify: `entry/src/ohosTest/ets/test/RemoteRestoreFrameRefreshPolicy.test.ets`

**Interfaces:**
- Consumes: `getRestoreFrameRefreshDelaysMs(): number[]`
- Produces: A schedule ending at 10000 ms with entries at 0 ms, 3000 ms, and 10000 ms.

- [ ] **Step 1: Write the failing test**

```typescript
it('restore_refresh_should_cover_target_and_fallback_windows', 0, (): void => {
  const delays: number[] = getRestoreFrameRefreshDelaysMs();
  expect(delays[0]).assertEqual(0);
  expect(delays.indexOf(3000)).assertLarger(-1);
  expect(delays[delays.length - 1]).assertEqual(10000);
});
```

- [ ] **Step 2: Run a lightweight policy check to verify it fails before implementation**

Run:

```powershell
$p='entry/src/main/ets/services/RemoteRestoreFrameRefreshPolicy.ets'
$text=Get-Content -Raw $p
$m=[regex]::Match($text,'RESTORE_FRAME_REFRESH_DELAYS_MS:\s*number\[\]\s*=\s*\[([^\]]+)\]')
$delays=$m.Groups[1].Value -split ',' | ForEach-Object { [int]($_.Trim()) }
if ($delays[0] -ne 0 -or -not ($delays -contains 3000) -or $delays[-1] -ne 10000) { throw 'restore refresh schedule does not cover 3s/10s contract' }
```

Expected before implementation: FAIL with `restore refresh schedule does not cover 3s/10s contract`.

- [ ] **Step 3: Write minimal implementation**

```typescript
const RESTORE_FRAME_REFRESH_DELAYS_MS: number[] = [
  0,
  120,
  300,
  700,
  1200,
  2000,
  3000,
  5000,
  7000,
  10000
];
```

- [ ] **Step 4: Run the policy check again**

Expected after implementation: PASS.

- [ ] **Step 5: Run regression verification**

Run:

```powershell
build\rdp-native-tests\rdp_native_tests.exe
& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js" --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --daemon
```

Expected: native tests pass; HAP build succeeds.

- [ ] **Step 6: Commit**

```bash
git add entry/src/main/ets/services/RemoteRestoreFrameRefreshPolicy.ets entry/src/ohosTest/ets/test/RemoteRestoreFrameRefreshPolicy.test.ets docs/superpowers/specs/2026-06-26-remote-restore-video-recovery-design.md docs/superpowers/plans/2026-06-26-remote-restore-video-recovery.md
git commit -m "fix(remote): extend foreground video recovery"
```

## Self-Review

- Spec coverage: schedule contract, no background video guarantee, no reconnect, no audio changes, and validation are all covered by Task 1.
- Placeholder scan: no TBD/TODO placeholders.
- Type consistency: `getRestoreFrameRefreshDelaysMs(): number[]` matches the existing production interface.
