# Shared Current State

## Active task

- Task: `cloud-sync-compatibility-first-recovery`
- Branch: `codex/system-clipboard-activation-fix`; user authorized work on the current branch.
- Increment: `54f9d25df..a4d0aebb1`.
- Phase: implemented, locally verified, independently reviewed and data-preserving installed on the primary acceptance device; user acceptance is pending.
- Plan: `docs/codex/plans/2026-08-28-cloud-sync-compatibility-first-recovery.md`

## Root cause and result

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
