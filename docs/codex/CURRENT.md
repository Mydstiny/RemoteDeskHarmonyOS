# Shared Current State

## Active task

- Task: `vnc-wheel-input-normalization`
- Branch/base: `codex/vnc-wheel-input-normalization` from synchronized `main@928372c6c`.
- Phase: first review findings remediated; preparing follow-up review.
- Plan: `docs/codex/plans/2026-08-27-vnc-wheel-input-normalization.md`

## Completed implementation

- A valid mouse-only `scrollStep` now overrides Axis lifecycle metadata, so a physical mouse is no longer routed through the continuous `/45` touchpad path.
- Physical mouse input maps each vendor event (`1`, `45` or `120`) to one portable RFB wheel detent; the VNC-only four-click baseline and 2x/3x timestamp burst were removed.
- Continuous HarmonyOS PC touchpad/bridge input now calibrates its raw unit per gesture, accumulates fractional motion, caps each sample and resets on BEGIN/END/CANCEL, idle gaps, source changes and direction changes.
- Phone/Pad virtual two-finger VNC input now uses vp-distance accumulation with a two-tick frame cap; forced minimum ticks, 32-tick bursts and the recursive post-release fling were removed.
- RDP, RustDesk and Moonlight wheel policies retain their existing source-specific paths. Native VNC still expands the requested delta exactly into RFB button-4/5 pairs.
- The shared policy suites are registered in both the default test compile and on-device runner; regression cases cover classification, vendor units, lifecycle isolation, virtual fractional movement and output budgets.
- Initial independent review of `c7633050` found two P1s, one P2 and one P3 test gap. The remediation keeps ambiguous `MOUSE + NONE` events discrete, immediately rebases `120/45 → 1` fine motion, forwards sub-`0.5vp` Phone/Pad samples and routes BEGIN/END/CANCEL through a shared tested policy.

## Verification

- `default@OhosTestCompileArkTS`: PASS after remediation, `BUILD SUCCESSFUL in 8 s 967 ms`.
- `assembleHap`: PASS with signing after remediation, `BUILD SUCCESSFUL in 17 s 16 ms`.
- Signed HAP SHA-256: `65d06b269cff68c05c3e759c00410444a67fec77e6284f025a3227e85413edab`.
- `git diff --check`: PASS.
- Open-source compliance `Light`: PASS.
- Additional `ohosTest@OhosTestCompileArkTS`: unavailable because the project task remains unregistered (`00306054`); no on-device test execution is claimed.
- `hdc list targets`: no online target, so install and live physical mouse/touchpad diagnostics remain external acceptance.

## Next / blockers

- Next: precise remediation commit and follow-up review by `/root/vnc_wheel_review`, then finalize the receipt/state.
- Environment limitation: no online HarmonyOS target; the source/build gates are otherwise clear.
