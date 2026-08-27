# Shared Current State

## Active task

- Task: `vnc-cursor-wheel-regression`
- Branch/base: `codex/vnc-cursor-wheel-regression` from synchronized `main@0b8e5bf60`.
- Phase: independent follow-up review of device-feedback checkpoint `dfb74ded6`.
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
- Native RFB wheel bursts are built by a tested byte-level helper that preserves held buttons, clamps coordinates and bounds one logical event to 32 button-4/5 down/up pairs.
- Local VNC move/wheel prediction updates cursor coordinates only; an authoritative protocol-hidden cursor cannot be resurrected until the server sends a new visible cursor shape.
- Device acceptance required at least 5x more scroll distance. Virtual touchpad, physical touchpad and physical mouse now share one VNC-only final wire gain of 5, while the native bounded burst accepts the maximum supported 40-step mouse event without truncation.

## Verification

- Baseline `main@0b8e5bf60` was clean and equal to `origin/main` when the task started.
- Focused ArkTS policy tests are compile-registered by the passing test target.
- Host native suite: PASS, `813 passed, 0 failed`, including transparent VNC cursor and exact wheel-burst wire cases.
- Final exact `default@OhosTestCompileArkTS`: PASS (`BUILD SUCCESSFUL in 6 s 622 ms`).
- Final exact signed `assembleHap`: PASS (`BUILD SUCCESSFUL in 15 s 638 ms`).
- Signed HAP SHA-256: `4ff98d309c2bd11bee2021e3056f974279ecf6a55c4a769ed6a0a4ed24c25952`.
- `git diff --check` and open-source compliance Light: PASS.
- Initial independent review of `dcf1b2fc4`: FAIL on permanent auto-pointer fallback and missing state/wire coverage; both findings were remediated in `45eb2c293`.
- Follow-up review of `45eb2c293`: FAIL because local prediction could overwrite protocol-hidden visibility and the end-to-end ownership transition lacked coverage; both findings are remediated in `abc3ce5b8`.
- Previous cursor/wheel re-review by `/root/vnc_wheel_review`: PASS at `abc3ce5b8`; device feedback then superseded the wheel-output checkpoint.
- Follow-up review of `dfb74ded6`: in progress as `/root/vnc_wheel_review`.

## Next

1. Complete follow-up review of `dfb74ded6`.
2. Install the reviewed signed HAP on `192.168.3.236:40123` for user acceptance.
3. Complete push/PR/main closure after acceptance.

## Blockers

- None.
