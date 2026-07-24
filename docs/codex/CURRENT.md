# Shared Current State

Updated: 2026-07-24 Asia/Shanghai

## Repository

- Repository: Mydstiny/RemoteDeskHarmonyOS
- Repair branch: codex/rustdesk-pinch-zoom-fix
- Task: RustDesk/RDP canvas pinch zoom and input-stall repair
- Base: main at 28c3ff43 before this repair
- Final integration: the validated repair commits are to be merged back to main and the repair branch removed

## Result

- Non-blocking latest-value-wins canvas transform submission is implemented.
- Renderer registry/lifecycle lock scope is separated from upload, draw and eglSwapBuffers.
- Retained-frame redraw is wired for hardware decode, software decode and RDP; retained redraw wakes are coalesced.
- ArkTS pinch geometry and input ownership stay local and are released idempotently on end, cancel, surface loss, PIP, background, control-mode changes, disconnect and rejected native input.
- RustDesk touch scale/pan updates are bounded and coalesced while start/end barriers and reliable keyboard, mouse-button and text ordering remain intact.
- RDP input worker remains independent of renderer lifecycle work.

## Repair commits

- 80974c440: native non-blocking canvas redraw and renderer ownership changes.
- fb7355072, 44d2a51de, 5bc7a4be3: ArkTS pinch geometry and input lifecycle hardening.
- f43a8101b, 620544b14: RustDesk touch queue coalescing and reliable-order boundary flush.
- 6d16eb366: retained decoder redraw wake coalescing.
- e8112a1c1 and the final documentation update: repair plan and implementation record.

## Verification

- ArkTS default@OhosTestCompileArkTS: passed; existing repository/dependency warnings remain.
- Native RDP tests: 129 passed, 0 failed.
- RustDesk FFI lib tests: 140 passed, 0 failed, including local socket protocol tests in the permitted environment.
- Production assembleHap: BUILD SUCCESSFUL.
- git diff --check: required before final merge.

## Device acceptance still required

- RustDesk remote Windows: continuous pinch with active video, mouse click and keyboard down/up.
- RustDesk remote macOS: static desktop must redraw locally during pinch without a new remote frame.
- RDP Windows: retained BGRA redraw, frame-pump progress and keyboard/mouse delivery during pinch.
- Optional RustDesk remote-app TouchScale: bounded queue and start/update/end protocol order.
- API 23 lifecycle matrix: cancel, surface destroy/recreate, PIP, background/foreground, rotation and reconnect.

## Local-only boundary

- The user-owned untracked docs docs/SSH_MODULE_UPGRADE_PLAN.md and docs/superpowers/plans/2026-07-24-vnc-isolated-settings-cloud-upgrade.md are preserved and are not part of this repair.
- SDKs, signing profiles, device data, private addresses, credentials, raw logs and screenshots remain outside the shared records.
