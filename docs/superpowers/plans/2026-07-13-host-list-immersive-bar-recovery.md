# Host List Immersive Bar Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `executing-plans` to execute this plan in the main workspace, task by task. Do not create or use a git worktree.

**Goal:** Restore the historically working HDS immersive floating bottom bar, remove the visible “全部” workspace chip without losing filter reset, and suppress the misleading unknown-health label.

**Architecture:** Restore the `HdsTabs { TabContent... }.modifier()` construction order from commit `948a0e3a`, because that is the last known good runtime structure. Keep workspace state transitions in `HostWorkspacePolicy`, so the UI can toggle an active group off without duplicating logic. Health copy remains a pure policy output; the UI renders it only when non-empty.

**Tech Stack:** HarmonyOS NEXT API 23 ArkTS, HDS `HdsTabs`, Hypium, DevEco hvigor.

## Global Constraints

- Preserve all existing floating-bar values: overlap, horizontal pan guard, end position, 64vp height, width ranges, gradient mask, immersive adaptive material, handedness adaptation, divider, animation, and tab change behavior.
- Keep all four existing tab contents and tab-bar builders unchanged.
- Do not restore the visible “全部” chip; an active group must toggle back to the unfiltered state on a second tap.
- Do not report “尚未检测” until the application has an actual host-health probe writer.
- Do not modify unrelated RDP certificate, remote navigation immersion, input, cloud, or user-untracked planning work.

---

### Task 1: Add policy regression tests and observe the red compile

**Files:**
- Modify: `entry/src/test/HostWorkspacePolicy.test.ets`
- Create: `entry/src/ohosTest/ets/test/HostWorkspacePolicy.test.ets`
- Modify: `entry/src/ohosTest/ets/test/List.test.ets`

**Interfaces:**
- Add `nextWorkspaceGroupId(currentGroupId: string, tappedGroupId: string): string` to `HostWorkspacePolicy`.
- `displayConnectionHealth(ConnectionHealth.UNKNOWN, latencyMs)` returns `''`.

- [x] Add the following tests before production changes:

```ts
expect(displayConnectionHealth(ConnectionHealth.UNKNOWN, 0)).assertEqual('');
expect(displayConnectionHealth(ConnectionHealth.UNKNOWN, 48)).assertEqual('');
expect(nextWorkspaceGroupId('', 'ops')).assertEqual('ops');
expect(nextWorkspaceGroupId('ops', 'ops')).assertEqual('');
```

- [x] Run the actual `onDeviceTest` compilation graph and confirm it fails because `nextWorkspaceGroupId` is not exported. The default test-compile task does not include the `ohosTest` source set.

### Task 2: Implement the minimal policy and restore the historical HDS structure

**Files:**
- Modify: `entry/src/main/ets/services/HostWorkspacePolicy.ets`
- Modify: `entry/src/main/ets/pages/HostListPage.ets`

- [x] Implement `nextWorkspaceGroupId` by normalizing the tapped group and returning `''` only when it equals the active group.
- [x] Return `''` for `ConnectionHealth.UNKNOWN`, regardless of stored latency.
- [x] Render `HostConnectionHealth` only for a non-empty policy result.
- [x] Remove the `Text('全部')` workspace chip and use `nextWorkspaceGroupId` from group chip clicks.
- [x] Restore the HDS construction order exactly: content block first, then the unchanged modifier chain.

### Task 3: Verify the UI recovery and non-regression

**Files:**
- Modify: `docs/superpowers/plans/2026-07-13-host-list-immersive-bar-recovery.md`

- [x] Compile the `ohosTest` source set in the `onDeviceTest` graph, then run only the new `HostWorkspacePolicy` class on `127.0.0.1:5555`: `Tests run: 2, Failure: 0, Error: 0, Pass: 2`.
- [x] Run signed production `assembleHap`: `BUILD SUCCESSFUL in 14 s 765 ms`.
- [x] Inspect the final HDS block against the historical `948a0e3a` construction order and confirm every floating-bar modifier/value is preserved.
- [x] Install/launch on `127.0.0.1:5555`; screenshots show the restored floating bar, no “全部”, no “尚未检测”, and a successful Host → Key Vault tab switch.
- [x] Run `git diff --check`, update the task checklist, and commit only the intended source, tests, and plan.

## Verification boundary

The full 115-test device suite starts but the pre-existing `CloudSync_RemoteHost_CRUD` case terminates the app at item 15. It is outside this UI/policy change and prevents a whole-suite green result. The newly added `HostWorkspacePolicy` class was therefore run independently and passed both tests on-device.
