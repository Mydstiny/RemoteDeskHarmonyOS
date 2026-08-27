# Shared Current State

## Active task

- Task: `vnc-cursor-wheel-regression`
- Branch/base: `codex/vnc-cursor-wheel-regression` from synchronized `main@0b8e5bf60`.
- Phase: independent review of checkpoint `dcf1b2fc4`.
- Plan: `docs/codex/plans/2026-08-27-vnc-cursor-wheel-regression.md`

## Objective

- Restore normal VNC scroll distance for virtual two-finger input, HarmonyOS PC physical touchpads and physical mouse wheels.
- Preserve the HarmonyOS user-configured mouse `scrollStep` instead of collapsing every wheel event to one RFB click.
- Keep the local system pointer visible during macOS Screen Sharing cursor bootstrap, then switch only when a valid protocol cursor is ready.
- Leave RDP, RustDesk and Moonlight input behavior unchanged.

## Evidence

- Device `192.168.3.236:40123` reported physical mouse `raw=45`, `scrollStep=3`, but VNC forwarded `delta=1`.
- Virtual two-finger samples were commonly `2-8vp`; the current `10vp` threshold and maximum delta 2 visibly under-scroll.
- API 23 documents mouse vertical-axis values as degrees that already include the user's `scrollStep`; touchpad values are continuous px without that multiplier.
- RDP emits a standard `0x78` wheel magnitude and RustDesk has a dedicated two-dimensional high-resolution touchpad path; RFB only has button-4/5 clicks and therefore needs explicit bounded protocol compensation.
- macOS Screen Sharing delayed its first real cursor shape for about 56 seconds while auto mode hid the local pointer based only on the absence of a native cursor.

## Implemented

- Discrete VNC mouse events preserve bounded `scrollStep` ticks, with sign-only fallback when the coefficient is unavailable.
- Virtual VNC input uses `4vp` per tick with a maximum of 4 per sample; fractional accumulation remains bounded without recursive fling or release backlog.
- Physical VNC touchpads use two normalized samples per tick with a maximum of 4 while preserving lifecycle, source, idle and direction resets.
- VNC auto cursor mode keeps the system pointer during fallback/bootstrap; explicit hidden mode remains authoritative.
- Non-zero VNC protocol cursor rectangles with an all-transparent mask are treated as hidden and cannot replace the local pointer.

## Verification

- Baseline `main@0b8e5bf60` was clean and equal to `origin/main` when the task started.
- Focused ArkTS policy tests are compile-registered by the passing test target.
- Host native suite: PASS, `812 passed, 0 failed`, including the new transparent VNC cursor case.
- Final exact `default@OhosTestCompileArkTS`: PASS (`BUILD SUCCESSFUL in 14 s 401 ms`).
- Final exact signed `assembleHap`: PASS (`BUILD SUCCESSFUL in 36 s 481 ms`).
- Signed HAP SHA-256: `de2bff70d6562270abe4d5cdafb17ea15b30d58833dc6979a00c31e83c222509`.
- `git diff --check` and open-source compliance Light: PASS.
- Independent review: in progress as `/root/vnc_wheel_review`.

## Next

1. Obtain independent review of `0b8e5bf60..dcf1b2fc4`.
2. Remediate findings and repeat required gates.
3. Install the signed HAP on `192.168.3.236:40123` for user acceptance.
4. Complete push/PR/main closure after acceptance.

## Blockers

- None.
