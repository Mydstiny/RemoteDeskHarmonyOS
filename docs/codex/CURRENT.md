# Shared Current State

## Active task

- Task: `vnc-cursor-wheel-regression`
- Branch/base: `codex/vnc-cursor-wheel-regression` from synchronized `main@0b8e5bf60`.
- Phase: reviewed device acceptance for 1.1.3 10x wheel checkpoint `8e9ed4ea8`.
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
- VNC auto cursor ownership is evidence-based: legacy RFB 3.3/macOS bootstrap keeps the system pointer, modern RFB 3.7/3.8 without Cursor pseudo uses its framebuffer-composited cursor, a protocol shape atomically replaces the default pointer, and protocol/explicit hidden states hide it.
- Non-zero VNC protocol cursor rectangles with an all-transparent mask are treated as hidden and cannot replace the local pointer.
- Native RFB wheel bursts are built by a tested byte-level helper that preserves held buttons, clamps coordinates and bounds one logical event to 128 button-4/5 down/up pairs.
- Local VNC move/wheel prediction updates cursor coordinates only; an authoritative protocol-hidden cursor cannot be resurrected until the server sends a new visible cursor shape.
- Device acceptance required another 2x increase after the 5x checkpoint. Virtual touchpad, physical touchpad and physical mouse now share one VNC-only final wire gain of 10, while the native bounded burst accepts the maximum supported 80-step mouse event without truncation.
- The repair release remains `1.1.3`; its cumulative update content is intentionally unchanged per product decision. SBOM provenance now points to source commit `5c20204b2` without dropping TOTP or Moonlight vendor inventory.

## Verification

- Baseline `main@0b8e5bf60` was clean and equal to `origin/main` when the task started.
- Focused ArkTS policy tests are compile-registered by the passing test target.
- Current-source target native wheel case: PASS, directly validating all 80 wheel down/up pairs. Full host suite: `797 passed, 16 failed`; all 16 failures are the known TLS `fixture.start()` environment baseline and are unrelated to this change.
- Exact `default@OhosTestCompileArkTS`: PASS (`BUILD SUCCESSFUL in 1 min 6 s 939 ms`).
- Exact signed `assembleHap`: PASS (`BUILD SUCCESSFUL in 1 min 20 s 803 ms`).
- `git diff --check` and open-source compliance Light: PASS.
- Initial independent review of `dcf1b2fc4`: FAIL on permanent auto-pointer fallback and missing state/wire coverage; both findings were remediated in `45eb2c293`.
- Follow-up review of `45eb2c293`: FAIL because local prediction could overwrite protocol-hidden visibility and the end-to-end ownership transition lacked coverage; both findings are remediated in `abc3ce5b8`.
- Previous cursor/wheel re-review by `/root/vnc_wheel_review`: PASS at `abc3ce5b8`; device feedback then superseded the wheel-output checkpoint.
- Follow-up review of `dfb74ded6` by `/root/vnc_wheel_review`: PASS, P0/P1/P2/P3 all zero.
- Release follow-up review found stale SBOM provenance and incomplete 80-step regression coverage; both were remediated in `8e9ed4ea8`.
- Final independent review of `5c20204b2..8e9ed4ea8` by `/root/vnc_wheel_review`: PASS, P0/P1/P2/P3 all zero.

## Next

1. Install the reviewed 1.1.3 10x signed HAP on `192.168.3.236:40123` for user acceptance.
2. Complete push/PR/main closure after acceptance.

## Blockers

- None.
