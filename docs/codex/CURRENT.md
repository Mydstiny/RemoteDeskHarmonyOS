# Shared Current State

## Active task

- Task: `per-protocol-pinch-zoom-plan`
- Branch: `codex/per-protocol-pinch-zoom-plan` from `main@b84224869`.
- Increment: base implementation/review are complete at `714b791f8`; reset-affordance remediation is reviewed at `4211438a`; display/interaction selection sheets and Moonlight accordion parity are reviewed at `50e2c6b5`; real-device acceptance and PR closure remain.
- Phase: five-protocol pinch preferences, graphical canvas gestures/pointer follow, SSH font-pinch gating, protocol-specific reset controls and unified settings-sheet interaction are implemented; no native, Rust, FFI, dependency or resource changes.
- Plan: `docs/codex/plans/2026-08-29-per-protocol-pinch-zoom-and-pointer-follow.md`

## Per-protocol pinch zoom result

- RustDesk official mobile behavior was traced at `master@03a7fc599`: focal-point relative pinch and pan share one ScaleGesture; touchpad cursor movement pans hidden canvas after crossing the visible centre; physical/floating pointer paths add bounded canvas follow and edge scrolling.
- `显示与交互 → 双指缩放` now opens one editor for RDP, RustDesk, SSH, VNC and Moonlight, with per-protocol switches plus all-on/all-off actions. Values are device-local, migrate compatibly from the old shared preference, use touched-field merge and rollback on partial persistence failure, and publish live through AppStorage.
- RDP/RustDesk/VNC share focal pinch, same-stream pure two-finger canvas pan, Fit-state scroll/right-click preservation and strict-bounds safe-area/edge-area pointer follow. RustDesk remote App `TouchScale/TouchPan` is mutually exclusive with local canvas transform.
- Moonlight now owns the same GL canvas-transform lifecycle, keyboard/mouse-mode two-finger pan without a one-finger touch lane, synchronous versioned viewport mirroring for same-event absolute pointer mapping, and gesture cancellation before resize/PIP/rebind rebase. Relative and physical pointers reveal hidden canvas without cross-axis pollution.
- SSH keeps its existing terminal-font pinch semantics behind the SSH-specific switch; SFTP is unaffected. Disabling a graphical-protocol switch drains active gesture state and restores the base transform where applicable.
- Reset affordances now reuse existing chrome: RDP/Moonlight show a highlighted toolbar shortcut only while the canvas differs visibly from its current baseline and keep a stable control-center row; VNC has a permanent sidebar reset; RustDesk marks its existing Display action and reset row when modified. VNC/Moonlight narrow PC toolbars are viewport-bounded and horizontally scrollable. Reset preserves the selected display mode/rotation/flip/resolution, drains gesture ownership and clears pointer-follow before returning to the current mode baseline.
- SSH exposes `更多 → 恢复终端字号`: Profile zoom is an in-memory `host:generation` session override consumed by active and retained Xterm surfaces, and reset removes only that override without mutating the Profile. Legacy sessions return to and persist the default 18-point size.
- `显示与交互 → 会话侧栏与顶栏` now opens a transactional selection sheet for RDP/RustDesk/VNC/Moonlight, with protocol switches, all-show/all-hide, touched-field merge, rollback and device-local persistence; SSH remains under its existing `更多` menu. Hidden controls are restored by returning to this settings sheet.
- Moonlight's main settings section now stays mounted and uses the same common height/opacity/scale/translate/clip accordion lifecycle as the other protocol sections, so its expansion and leaf-sheet routing no longer pop through a separate conditional path.
- Settings-sheet increment verification at `50e2c6b5`: `default@OhosTestCompileArkTS` PASS (`BUILD SUCCESSFUL in 10 s 203 ms`); signed `assembleHap` PASS (`BUILD SUCCESSFUL in 23 s 225 ms`), SHA-256 `5efb54645bc3d5b48d91958a3dde8a1c3d66ff588c921922f8328e4fa46a2c86`; `git diff --check` and Light compliance PASS.
- Reset increment verification at `4211438a`: `default@OhosTestCompileArkTS` PASS (`BUILD SUCCESSFUL in 10 s 909 ms`); signed `assembleHap` PASS (`BUILD SUCCESSFUL in 31 s 919 ms`), SHA-256 `9b50e409bb58ef7073d066516de052f797313a46bf1ff2d0c66eb16c14a791f1`; `git diff --check` and Light compliance PASS.
- Verification after remediation: `default@OhosTestCompileArkTS` PASS (`BUILD SUCCESSFUL in 29 s 668 ms`); signed `assembleHap` PASS (`BUILD SUCCESSFUL in 16 s 174 ms`), SHA-256 `d0899ec8f965aea61154fb69ba2b527af83ec55f5d2cb8163612aba081d6e50c`; `git diff --check` and Light compliance PASS. The separate `ohosTest@OhosTestCompileArkTS` task remains unavailable (`00306054`), while the registered suites compile through the mandatory default test target.
- Independent review `/root/pinch_zoom_review`: base PASS at `714b791f8`; reset increment PASS at `4211438a`; settings-sheet increment PASS at `50e2c6b5` after correcting the hidden-control recovery copy; no remaining P0/P1/P2/P3. Real-device gesture, pointer, persistence, reset, settings-sheet and accordion acceptance is pending because HDC reported `Connect server failed`.
- Next: complete the expanded device matrix, then push the branch, open the PR, pass required checks and merge.

## 1.1.4 release result

- The current app version is `1.1.4 / 1001004` across the app manifest, release registry, NAPI metadata, resources, diagnostics, documentation and SBOM.
- The current 1.1.4 release popup contains only the 10 new 1.1.4 cards for committed changes since 1.1.3 and ends at `welcome-1-1-4`. The 12 existing 1.1.3 cards remain unchanged in the historical `1.1.3` registry, but are excluded from the current popup. The settings entry and unit/device assertions use the 10-card current count.
- `设置 → 教程 → 本版本更新日志` now reloads the current 1.1.4 registry when the component appears and whenever that subpage is selected, and clamps any reused legacy page index to the current 10-page range.
- SBOM provenance identifies source snapshot `fc514ce36` and creation time `2026-08-28T15:50:20Z`; the snapshot includes the version update and final shortcut-editor refinement.
- Final verification: `default@OhosTestCompileArkTS` PASS (`BUILD SUCCESSFUL in 14 s 918 ms`); signed `assembleHap` PASS (`BUILD SUCCESSFUL in 38 s 510 ms`); signed HAP SHA-256 `45cd9c64b7c3a28c6a606594943d3ae79ba27c3e2216d87042edcc891267eada`; `git diff --check` and Light compliance PASS.
- Independent review `/root/release_1_1_4_review`: tutorial release-log refresh PASS with zero findings; no P0/P1/P2/P3.

## Existing cloud recovery result

- Device logs at `192.168.3.235:38451` showed Account Kit login and RDB creation succeeded, then optional historical account-store migration failed with `401 invalid parameters`; that optional failure was incorrectly surfaced as `账号物理数据域打开失败`.
- Canonical failure now falls back to the exact same account's hashed local store. Login and local CRUD remain available while cloud recovery is deferred; stale canonical data is never reverse-imported into that authoritative fallback.
- Local rows commit only when dirty intent is durable in the same RDB transaction. Broken checkpoints are quarantined before writes reopen, and startup/retry share the same durable cloud-admission state.
- Account migration preserves clear/delete and empty-table semantics. VNC/Moonlight exact schema and public-data rules, higher source schemas, account ownership and crypto ownership remain integrity boundaries rather than arbitrary availability policies.

## Verification

- `default@OhosTestCompileArkTS`: PASS (`BUILD SUCCESSFUL in 6 s 201 ms`).
- `assembleHap`: PASS, signed (`BUILD SUCCESSFUL in 50 s 090 ms`).
- Signed HAP SHA-256: `b6bad805365e0af421336fbe796a25cb5baaa28d651a8e1e14e356df733a8ca3`.
- `git diff --check` and Light open-source compliance: PASS.
- `ohosTest@OhosTestCompileArkTS`: unavailable (`00306054`, task is not registered); focused policies compile through the mandatory test target.
- Independent review `/root/cloud_sync_fix_review`: PASS; no remaining P0/P1/P2. Non-blocking P3 is deeper real-RDB fault-injection coverage.

## Authorized RustDesk desktop-flip increment

- Commits `56db7e612`, `a77e28f3` and `10c149fce` add a PC-only RustDesk top-bar flip icon with a compact three-action popup: image only, image plus controls, and reset.
- The selected mode is stored per host in device-local personalization, restored across sessions and excluded from cloud-base change detection. Visual and control rotations are independent; PIP and foreground renderer rebinds reapply the visual mode.
- Authenticated peer platform wins over stale host metadata. Android/iOS peers drain input, reset only the live desktop-flip transform and close the popup; the saved computer preference remains available for a later desktop peer. Phone/Pad viewers and RustDesk phone targets do not expose the action.
- Continuity reconnects retain the last authenticated peer platform across transient `unknown` diagnostics, preventing mobile sessions from briefly reapplying a stale computer flip during re-authentication.
- Verification: `default@OhosTestCompileArkTS` PASS (`BUILD SUCCESSFUL in 18 s 232 ms`); signed `assembleHap` PASS (`BUILD SUCCESSFUL in 26 s 727 ms`); signed HAP SHA-256 `db785d6f17a1f8305b62bd1503c5717eb8cee7b324e467e5aba3b721cf3239a7`; `git diff --check` and Light compliance PASS. PC real-device UI/mapping acceptance is pending.
- Independent review `/root/rustdesk_desktop_flip_review`: PASS after closing one P1 mobile-peer scope issue and one P2 continuity `unknown` transition; no remaining P0/P1/P2.

## Per-protocol wheel-direction increment

- Commits `23ec26df1`, `6f1efab8a` and `701969cb1` replace the shared wheel switch with a `显示与交互` editor for RDP, RustDesk, SSH, VNC and Moonlight, including all-normal and all-reverse actions. SFTP is explicitly unaffected.
- Each protocol now owns a device-local key and applies direction at its runtime boundary exactly once. Existing shared behavior migrates compatibly for RDP/RustDesk/VNC; SSH and Moonlight default to normal direction.
- Editor saves use a touched-field patch merged with the latest live values, so changing one protocol cannot revert another protocol changed while the sheet was open. Multi-key persistence has best-effort rollback, and VNC keeps its old cloud payload field only as migration input.
- Verification: `default@OhosTestCompileArkTS` PASS (`BUILD SUCCESSFUL in 12 s 339 ms`); signed `assembleHap` PASS (`BUILD SUCCESSFUL in 31 s 407 ms`); signed HAP SHA-256 `d7221652b6ba51f07e6f64752e096eb10f29d40548c92aa08b26eea5335d30d8`; `git diff --check` and Light compliance PASS. The separate `ohosTest@OhosTestCompileArkTS` task remains unregistered (`00306054`).
- Independent review `/root/per_protocol_wheel_review`: PASS after closing the stale-editor P2 and tightening persistence/SSH ownership; no remaining P0/P1/P2. ArkWeb WheelEvent and five-protocol real-device input acceptance remain pending.

## Device acceptance / blockers

- The fixed HAP was installed successfully on `192.168.3.235:38451` with `install -r`, preserving app data, and `EntryAbility` started successfully. Acceptance must verify login remains usable after the historical migration `401`, exact-owner local data visibility, local save/restart/offline behavior, canonical recovery and no stale-row resurrection.
- Prior remote keyboard/sidebar acceptance on `.235` remains queued. `.236:40123` still requires a release-provisioned HAP or explicit destructive-uninstall authorization; its existing data remains preserved.
