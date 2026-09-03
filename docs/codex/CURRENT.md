# Shared Current State

## Active task

- Task: `all-protocol-ipv6-upgrade`, continued on the existing branch for the 2026-09-04 twelve-item user-feedback repair batch.
- Branch: `codex/per-protocol-pinch-zoom-plan`; task baseline `5a0e05515`, reviewed IPv6/SBOM checkpoint `f59f31d9`, and reviewed feedback-batch code checkpoint `95c4c5f1`, based on the user-authorized `main@b84224869`.
- Relative state at `95c4c5f1`: ahead of `main` by 159 commits, behind by 0, one worktree, clean.
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
8. `d83a85811` adds editable, encrypted SSH common commands under More, with persistent ordering and direct insertion/execution actions.
9. `12fb5d96c` adds button-only session exit protection. When enabled, shortcut exits are blocked and the top/side control surface cannot be hidden.
10. `9d3e5f853` restores RustDesk remote-to-local text clipboard synchronization with loop suppression and lifecycle-safe listeners while preserving local-to-remote paste.
11. `7a61eac49` increases the classic host-list bottom safe area so the final host card remains operable above the FAB.
12. `95c4c5f1a` renames Virtual Keyboard settings to Keyboard and adds a persistent device/protocol matrix for blocking HarmonyOS shortcuts. The capture service is focus-, session-, modal-, owner- and generation-gated, retries failed unsubscription, releases held keys exactly once, and only forwards each protocol's verified media/volume key intersection.

## Verification and review

- Each feedback item was committed only after its scoped implementation checks and reviewer follow-up were clean. `/root/review_item1` gave item 1 a final P0=0, P1=0, P2=0, P3=0 result; `/root/review_item2` iteratively reviewed items 2-12 and gave item 12/final cumulative state the same zero-finding result.
- Latest full native suite PASS 997/997. Latest targeted RustDesk Harmony shortcut tests PASS 2/2, with 254 unrelated tests filtered; `cargo fmt --check` PASS.
- Required `default@OhosTestCompileArkTS` and signed `assembleHap` PASS after the final code checkpoint and again after the coordination-state refresh. The post-refresh signed build reported `BUILD SUCCESSFUL in 5 s 303 ms`; `pack.info` remains `1.1.5` / `1001005`, and signed HAP SHA-256 is `33cf72776db53799ee38d6ec779d37297c56175efdf507991bd4727a47f78130`.
- `git diff --check` and Light open-source compliance PASS. Existing ArkTS/generated-protobuf warnings are non-fatal and were not introduced as new errors.
- The optional `ohosTest@OhosTestCompileArkTS` probe was attempted and returned `00306054` because this project exposes no such task; it did not replace either mandatory `default@OhosTestCompileArkTS` or `assembleHap` gate.
- Real-device behavior is intentionally not claimed. The user will run one consolidated acceptance pass after all twelve local repairs are delivered.

## Next and blockers

- Next: run the consolidated HarmonyOS Phone/Pad/PC acceptance matrix in `QUEUE.md`. If flip still reproduces, export the new schema-v4 JSONL immediately after reproduction; the producer/decoder/renderer matrices and generation chain are designed to distinguish source-buffer inversion, decoder output transform, renderer application and stale-instance evidence in one capture.
- Continue the existing M1-M3 IPv6 and fixed hbbs/hbbr RustDesk M4 topology matrices during the same release acceptance window.
- Blocker for release acceptance only: no controlled device/topology result has been supplied yet. Code implementation, independent review and host-side gates are complete; product capability flags that were already release-gated remain disabled until their separate topology matrix passes.
