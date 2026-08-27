# Shared Current State

## Active task

- Task: `vnc-cursor-wheel-regression`
- Branch/base: `codex/vnc-cursor-wheel-regression` from synchronized `main@0b8e5bf60`.
- Phase: implementation.
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

## Planned implementation

- Map discrete VNC mouse events to bounded `scrollStep` ticks, with sign-only fallback when the coefficient is unavailable.
- Use `4vp` per virtual VNC tick with a maximum of 4 per sample; retain fractional accumulation without recursive fling or release backlog.
- Use two normalized physical-touchpad samples per VNC tick with a maximum of 4, preserving lifecycle, source, idle and direction resets.
- In VNC auto cursor mode, keep the system pointer during fallback/bootstrap and hide it only after a valid protocol cursor has been installed; explicit hidden mode remains authoritative.
- Update focused policy tests with captured device values and cursor transition coverage.

## Verification

- Baseline `main@0b8e5bf60` was clean and equal to `origin/main` when the task started.
- Focused ArkTS tests: pending.
- Exact `default@OhosTestCompileArkTS`: pending.
- Exact signed `assembleHap`: pending.
- `git diff --check` and open-source compliance Light: pending.
- Independent review: pending.

## Next

1. Implement the policy and integration changes.
2. Run focused tests and mandatory gates, then create a precise checkpoint commit.
3. Obtain independent review, remediate findings and repeat required gates.
4. Install the signed HAP on `192.168.3.236:40123` for user acceptance.

## Blockers

- None.
