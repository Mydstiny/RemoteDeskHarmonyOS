# Background Video Prewarm LiveView Design

## Goal

When the user enables connection live view, RDP and RustDesk should keep the remote video pipeline warm in the background at low cost so foreground return is immediately usable more often, while preserving the existing foreground restore recovery as the mandatory fallback.

## Decision

Use **low-power background video prewarm**, not full-speed background XComponent rendering.

The app must not keep swapping frames into the foreground XComponent surface while backgrounded. HarmonyOS can pause or replace the surface, and rendering into a stale EGL/window target is exactly the class of failure that caused the current background-return freeze. Background prewarm keeps protocol and frame ingestion alive, optionally keeps decoder/keyframe state warm, and stores enough last-frame state to make return faster. Foreground return still rebinds the real surface and still uses `requestFrameRefresh()` plus decoder recovery when output is stale.

## Setting Binding

Background video prewarm is enabled only when:

- `liveViewEnabled === true`
- `liveViewMode` is `AVSESSION` or `NOTIFICATION`
- the active remote session has real video activity
- the app is backgrounded
- the session is RDP or RustDesk and the protocol is still connected

If live view is disabled, the current conservative behavior remains: detach renderer on background and rely on foreground restore refresh/recovery.

## Architecture

Add a small policy layer for background video prewarm decisions:

- `OFF`: live view disabled, no video, protocol disconnected, or foreground
- `LOW_FPS_PREWARM`: background + live view enabled + video activity
- `AUDIO_ONLY`: audio activity without video; keep existing audio/AVSession behavior

RustDesk and RDP share this policy but apply it through protocol-specific mechanisms:

- RustDesk: keep frame ingestion and decoder recovery readiness, rate-limit decode/prewarm work, do not render to stale XComponent surfaces.
- RDP: continue receiving FreeRDP frame updates, keep a latest-frame snapshot or pump state while renderer is detached, rate-limit expensive work, and on foreground push the latest valid frame immediately before requesting a full refresh.

Foreground recovery stays in place:

1. reattach renderer to current XComponent surface
2. bind decoder/output pipeline if a decoder exists
3. render latest safe frame if available
4. request protocol frame refresh
5. arm decoder recovery when hardware decoder output needs a keyframe reset

## RDP Catch-Up Scope

RDP must reach parity with the current RustDesk recovery level:

- background return must not require protocol reconnect
- renderer detach must not destroy protocol state
- foreground return must display either a latest cached frame or the next server frame quickly
- if no frame arrives, request refresh and keep the existing no-frame/ErrorInfo behavior separate
- RDP audio remains governed by the existing rdpsnd PCM boundary policy and is not part of this feature

RDP does not use the RustDesk hardware decoder path for raw GDI frames. Its parity target is equivalent user behavior, not identical native implementation.

## Live View Behavior

AVSession remains the preferred live-view identity when `liveViewMode === AVSESSION`. It registers the remote session as `video`, updates metadata, registers play/pause commands, and keeps `audioPlayback` paired with real remote audio or video activity.

The notification setting is implemented as a normal `SERVICE_INFORMATION` background notification. API 23 does not allow a third-party app to directly create `SYSTEM_LIVE_VIEW` content or the `LIVE_VIEW` slot; a system proxy must create the initial live view with the same ID before a third-party app can update it. Remote sessions therefore use the supported normal notification path and do not pretend to be a file-transfer `dataTransfer` live view. This notification does not unlock full background rendering by itself; it only enables the same low-power prewarm policy.

## Safety Rules

- Never render to a surface after `onSurfaceDestroyed` or XComponent destroy.
- Never use background prewarm to reconnect RDP/RustDesk.
- Never make the restore path depend on background prewarm; prewarm is an optimization.
- Never full-speed decode/render in background by default.
- Rate-limit background video work to a small target, initially 1 fps for latest-frame/prewarm work and at most 5 fps after device evidence proves it is safe.
- Keep all new behavior behind pure policies and focused tests before production wiring.

## Observability

Add low-volume logs for:

- prewarm policy decision: disabled/off/low-fps/audio-only
- background frame accepted/skipped counters
- RDP latest-frame cache update and foreground immediate-present attempt
- RustDesk decoder prewarm armed/skipped state
- foreground recovery path used: latest-frame, request-refresh, decoder-recovery

Avoid logging raw host, username, password, paths, tokens, or server keys.

## Validation Matrix

Minimum validation before marking complete:

- RustDesk video-only: live view enabled, background 30 seconds, return via recent tasks, video visible without reconnect.
- RustDesk audio+video: AVSession pause/play still mutes/unmutes audio and foreground video returns.
- RDP video-only: background 30 seconds, return via recent tasks, latest/cached frame or next frame visible without reconnect.
- RDP audio+video: rdpsnd remains stable, AVSession pause/play behavior remains correct, foreground video returns.
- Live view disabled: behavior stays conservative and foreground recovery still works.
- Invalid return path note: do not use `aa start -a EntryAbility -b com.example.remotedesktop` as a foreground restore test.

## Open Constraints

HarmonyOS live view/AVSession does not provide a public surface for arbitrary remote desktop frame presentation. This feature therefore treats live view as the system identity and keepalive signal, not as a direct remote-frame rendering target.
