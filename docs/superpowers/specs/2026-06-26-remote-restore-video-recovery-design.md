# Remote Restore Video Recovery Design

## Goal

When an active RDP or RustDesk session is sent to the background through the system navigation gesture and later brought back to the foreground, the app must automatically restore video transmission without reconnecting or interrupting the existing background audio pipeline.

## Non-Goals

- Do not guarantee video rendering continues while the app is backgrounded. HarmonyOS may suspend the XComponent surface, EGL, GPU scheduling, or UI frame delivery.
- Do not reconnect the remote protocol session as part of normal foreground recovery.
- Do not change the RDP/RustDesk connect, audio, input, codec, or long-run video pressure paths that just passed validation.

## Recovery Contract

- Background: keep the protocol session and audio alive; detach/destroy only the foreground renderer surface path.
- Foreground: reattach the renderer, rebind the decoder/video pipeline when present, then start a video recovery watchdog.
- Target: request fresh video immediately and continue through the first 3 seconds.
- Fallback: keep requesting refreshes until 10 seconds after foreground restore.
- After 10 seconds: stop retrying and leave the session alive. Logs must contain enough detail for device diagnosis.

## Implementation Shape

- Extend `RemoteRestoreFrameRefreshPolicy.ets` from a short four-shot pump to a bounded 10-second schedule.
- Keep using `RemoteDesktop.scheduleRestoreFrameRefreshPump()` and `runRestoreFrameRefresh()` so the change remains in the recovery policy layer.
- Keep the protocol-specific work inside existing `requestFrameRefresh()` implementations:
  - RDP renders the current GDI primary buffer.
  - RustDesk sends `refresh_video` through the FFI handle.

## Risk Controls

- Only run refresh attempts when `connected=true`, `rendererHandle>0`, and `cleanupStarted=false`.
- Do not change background audio task behavior.
- Do not touch RustDesk streaming backpressure, video-starvation watchdog, or RDP frame pump internals.
- Preserve existing cleanup paths by clearing timers on background detach, restore entry, and disconnect cleanup.

## Validation

- Policy tests must prove the schedule includes immediate refresh, covers the 3-second target, and ends at 10 seconds.
- Native RDP/RustDesk regression tests must still pass.
- HAP build must pass.
- True-device logs should show repeated `runRestoreFrameRefresh: requested delay=...` entries up to 10 seconds if needed.
