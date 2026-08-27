# Shared Current State

## Active task

- Task: `vnc-wheel-input-normalization`
- Branch/base: `codex/vnc-wheel-input-normalization` from synchronized `main@928372c6c`.
- Phase: implementation verified; preparing checkpoint for independent review.
- Plan: `docs/codex/plans/2026-08-27-vnc-wheel-input-normalization.md`

## Completed implementation

- A valid mouse-only `scrollStep` now overrides Axis lifecycle metadata, so a physical mouse is no longer routed through the continuous `/45` touchpad path.
- Physical mouse input maps each vendor event (`1`, `45` or `120`) to one portable RFB wheel detent; the VNC-only four-click baseline and 2x/3x timestamp burst were removed.
- Continuous HarmonyOS PC touchpad/bridge input now calibrates its raw unit per gesture, accumulates fractional motion, caps each sample and resets on BEGIN/END/CANCEL, idle gaps, source changes and direction changes.
- Phone/Pad virtual two-finger VNC input now uses vp-distance accumulation with a two-tick frame cap; forced minimum ticks, 32-tick bursts and the recursive post-release fling were removed.
- RDP, RustDesk and Moonlight wheel policies retain their existing source-specific paths. Native VNC still expands the requested delta exactly into RFB button-4/5 pairs.
- The shared policy suites are registered in both the default test compile and on-device runner; regression cases cover classification, vendor units, lifecycle isolation, virtual fractional movement and output budgets.

## Verification

- `default@OhosTestCompileArkTS`: PASS, `BUILD SUCCESSFUL in 27 s 289 ms`.
- `assembleHap`: PASS with signing, `BUILD SUCCESSFUL in 17 s 319 ms`.
- Signed HAP SHA-256: `b873c530743e17336ea3283ac4899e7e9ca074f63a6c7db23483f2b0c2680339`.
- `git diff --check`: PASS.
- Open-source compliance `Light`: PASS.
- Additional `ohosTest@OhosTestCompileArkTS`: unavailable because the project task remains unregistered (`00306054`); no on-device test execution is claimed.
- `hdc list targets`: no online target, so install and live physical mouse/touchpad diagnostics remain external acceptance.

## Next / blockers

- Next: precise checkpoint commit, independent review, any required repair, then repeat gates and finalize.
- Environment limitation: no online HarmonyOS target; the source/build gates are otherwise clear.
