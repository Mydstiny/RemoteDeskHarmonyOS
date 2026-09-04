# Shared Current State

## Active task

- Task: `all-protocol-ipv6-upgrade`, continued on the existing branch for the 2026-09-04 twelve-item user-feedback repair batch.
- Branch: `codex/per-protocol-pinch-zoom-plan`; task baseline `5a0e05515`, reviewed feedback checkpoint `fd9289d5`, version checkpoint `a0d4f18d`, and SBOM checkpoint `23635f4a`, based on the user-authorized `main@b84224869`.
- Relative state at `23635f4a`: ahead of `main` by 167 commits, behind by 0, one worktree, clean.
- Plan: `docs/codex/plans/2026-08-29-all-protocol-ipv6-upgrade.md`.
- Phase: IPv6 M0-M4 local code and the twelve-item feedback repair batch are code-complete and independently reviewed; user-managed consolidated real-device acceptance and fixed-server topology release acceptance remain pending.

## Delivered feedback repair batch

1. `cec31d4a1` adds a PC-only Moonlight manual flip fallback equivalent to RustDesk and upgrades flip diagnostics to schema v4. Logs now preserve redacted producer class, raw/applied matrices, presentation mode, renderer/manual transform, renderer registry generation and decoder binding generation in one coherent snapshot, with strict import/export bounds. Absolute and relative input use the matching mirrored coordinate/delta model.
2. `69c1c7f1c` adds connection-time RDP account/password prompting with an ephemeral handoff; credentials are not written into host persistence, backups or logs.
3. `58ac524ab` replays authoritative RDP desktop geometry into the input pipeline after resize/fullscreen changes so pointer mapping no longer remains on a stale quarter-size viewport.
4. `91f29f02e` adds nested RustDesk toolbar choices for settings that have selectable sub-options and hover labels for toolbar buttons.
5. `07af36880` separates RustDesk preferred and negotiated/active codec telemetry so the diagnostics HUD follows codec changes without misreporting an unconfirmed stream codec.
6. `9e32e5c99` unifies RDP resolution presets, dynamic display negotiation, scaling and viewport fitting to avoid mismatched remote resolution and unnecessary black borders.
7. `699d10184` fences pointer dispatch across window focus/visibility generations so minimizing from the HarmonyOS PC Dock cannot leak a synthetic right click to the remote session.
8. `d83a85811` adds editable, encrypted SSH common commands under More, preserves their stored order and inserts a selected command into the terminal without automatically executing it.
9. `12fb5d96c` adds button-only session exit protection. When enabled, shortcut exits are blocked and the top/side control surface cannot be hidden.
10. `9d3e5f853` restores RustDesk remote-to-local text clipboard synchronization with loop suppression and lifecycle-safe listeners while preserving local-to-remote paste.
11. `7a61eac49` increases the classic host-list bottom safe area so the final host card remains operable above the FAB.
12. `95c4c5f1a` adds the persistent device/protocol Harmony shortcut capture matrix and guarded input service. Follow-up `25a73122b` fixes the missing settings icon, defaults to the current-device tab, reduces the UI to three device tabs plus four protocol switches, removes the ambiguous master toggle, shortens the sheet to 560 and adds explicit accessibility names. Follow-up `fd9289d5c` makes PC first-use defaults block the four supported protocols while preserving saved choices, treats malformed saved data as all-off, preserves runtime state on read failure, and makes every label explicit that opening a switch blocks locally and sends to the remote while closing it leaves handling to HarmonyOS.

## Version 1.1.5.1 checkpoint

- `a0d4f18d` updates the application, native user agent, UI/version resources, diagnostic metadata, release-note tests, README, user guide and SBOM generator to `1.1.5.1` / `1001006`. The current release contains 14 pages: introduction, the twelve numbered repairs above and a conclusion; the historical `1.1.5` notes and dependency `aho-corasick 1.1.5` remain unchanged.
- `23635f4a` refreshes the SPDX document metadata against the version checkpoint without changing the dependency graph.

## Verification and review

- Each feedback item was committed only after its scoped implementation checks and reviewer follow-up were clean. `/root/review_item1` gave item 1 a final P0=0, P1=0, P2=0, P3=0 result; `/root/review_item2` iteratively reviewed items 2-12, found and closed the PC-default transient-read P1, and gave `fd9289d5` a final P0=0, P1=0, P2=0, P3=0 result.
- Latest full native suite PASS 997/997. Latest targeted RustDesk Harmony shortcut tests PASS 2/2, with 254 unrelated tests filtered; `cargo fmt --check` PASS.
- Required `default@OhosTestCompileArkTS` and signed `assembleHap` PASS after the final code checkpoint and again after the coordination-state refresh. The latest runs reported `BUILD SUCCESSFUL in 4 s 723 ms` and `BUILD SUCCESSFUL in 5 s 730 ms`; `pack.info` is `1.1.5.1` / `1001006`. The development-signed HAP is intentionally not content-addressed here because its signing output changes between otherwise identical builds.
- `git diff --check` and Light open-source compliance PASS. Existing ArkTS/generated-protobuf warnings are non-fatal and were not introduced as new errors.
- The optional `ohosTest@OhosTestCompileArkTS` probe was attempted and returned `00306054` because this project exposes no such task; it did not replace either mandatory `default@OhosTestCompileArkTS` or `assembleHap` gate.
- After the PC-default and explicit switch-semantics follow-up, required `default@OhosTestCompileArkTS` PASS and signed `assembleHap` PASS with `BUILD SUCCESSFUL in 16 s 495 ms`; `git diff --check` and Light compliance PASS. `/root/review_item2` re-reviewed the final code and test increment and reported P0=0, P1=0, P2=0 and P3=0.
- `/root/review_item2` independently reviewed the `1.1.5.1` release increment, found one P2 overclaim that SSH common commands supported sorting, then verified the wording/test remediation and the refreshed SBOM with final P0=0, P1=0, P2=0 and P3=0.
- Real-device behavior is intentionally not claimed. The user will run one consolidated acceptance pass after all twelve local repairs are delivered.

## Next and blockers

- Next: run the consolidated HarmonyOS Phone/Pad/PC acceptance matrix in `QUEUE.md`. If flip still reproduces, export the new schema-v4 JSONL immediately after reproduction; the producer/decoder/renderer matrices and generation chain are designed to distinguish source-buffer inversion, decoder output transform, renderer application and stale-instance evidence in one capture.
- Continue the existing M1-M3 IPv6 and fixed hbbs/hbbr RustDesk M4 topology matrices during the same release acceptance window.
- Reproduce the intermittent RDP `0x10` report with Application state, RDP connection and routing/gateway diagnostics enabled plus matching HDC hilog. A genuine FreeRDP ErrorInfo `0x00000010` means the remote Windows session DWM terminated unexpectedly, but the current ArkTS error path also uses `0x10` as the fallback when no parseable native code exists. The supplied captures contain no RDP events and no device is currently connected, so the popup alone cannot distinguish a real server DWM crash from a client/network/resize failure mislabeled by the fallback.
- Blocker for release acceptance only: no controlled device/topology result has been supplied yet. Code implementation, independent review and host-side gates are complete; product capability flags that were already release-gated remain disabled until their separate topology matrix passes.
