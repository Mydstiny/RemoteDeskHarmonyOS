# Remote cursor stutter repair plan

Status: code implementation and automated gates complete; real-device acceptance outstanding
Updated: 2026-07-22 Asia/Shanghai
Primary target: Phone/Pad virtual-touchpad mode with the official/real cursor style
Protocols in scope: RustDesk and RDP

## 1. Problem statement

The official cursor bitmap now renders with a generally correct shape, but cursor motion can be severely stuttered, refresh in visible jumps, become stuck, or disappear during a long-running connection. Previous device evidence also showed the cursor work coinciding with connection-page and video-pipeline stalls.

The strongest captured device evidence is:

```text
remote-cursor state session=1 shapeRevision=20 positionRevision=2 visible=0 pixelMap=1 position=0,0
touchpad-curve ... prediction=998.58,987.67 ... authoritative=0.00,0.00
touchpad-curve ... prediction=874.32,918.12 ... authoritative=0.00,0.00
```

This proves that the bitmap can remain available while the native position revision stops, native visibility becomes false, and local touchpad prediction continues to move. The issue must therefore be treated as a position-synchronization and lifecycle problem, not merely as an image-scaling or ArkUI animation problem.

This document is a repair plan only. The cursor issue remains unresolved until the complete real-device acceptance matrix passes.

## Implementation checkpoint (2026-07-21)

The current checkpoint implements the safe portions of this plan without
claiming the long-run device outcome:

- ArkTS now owns an explicit local target, displayed position, and remote
  observation state; delayed remote coordinates cannot replace active local
  touchpad motion.
- A far remote coordinate can take ownership only when it arrives after the
  remote-silence interval following the last local input. Multiple early,
  delayed coordinates do not count as an acknowledgement.
- Cursor position availability and visibility revisions are independent in the
  native snapshot, so an initial `0,0` value or visibility toggle cannot be
  mistaken for a position update.
- Cursor polling is reduced from 16 ms to 33 ms, renderer-size synchronization
  is removed from the polling cadence, and ArkUI cursor view revisions are
  frame-coalesced.
- The metadata poll now always uses `includePixels=false`. When
  `shapeRevision` changes, RGBA is fetched through a NAPI worker and exposed
  as an external `ArrayBuffer`; the ArkTS completion path creates the
  `PixelMap` asynchronously and keeps the previous map visible until the new
  one is ready. No cursor timer copies a full bitmap on the ArkUI thread.
- RustDesk control-message logging is aggregated into sampled diagnostics
  rather than synchronously logging every mouse message.
- The unused floating mouse and floating joystick are removed from settings,
  session UI, runtime state, and cloud-sync eligibility. Existing persisted
  keys are intentionally left untouched but no longer read or applied.

The event-driven native cursor path described in Phase D and the complete
real-device endurance matrix remain open. The updated HAP was installed on
device `38451`, but the device was locked and could not launch the app for the
post-install UI and live-session verification.

## 2. Required outcomes

The repaired implementation must satisfy all of the following:

1. Local touchpad motion updates the displayed pointer within one UI frame and never waits for a remote position echo.
2. Delayed, duplicated, sparse, or reordered remote position messages cannot pull an active local prediction backward.
3. When the controlled endpoint moves its pointer independently, that position can influence the controller after local input becomes idle.
4. Cursor shape, position, visibility, connection lifecycle, and rendering lifecycle are independent state dimensions.
5. Cursor processing cannot synchronously block the UI, decoder, frame callback, or GL presentation pipeline.
6. Background restore, rotation, scaling, display switching, resolution changes, and reconnect isolate old cursor events by session generation.
7. Thirty-minute and two-hour real-device runs show no permanent cursor disappearance, frozen revision, input jump, or measurable video regression.

## 3. Current root-cause model

### 3.1 Missing reliable RustDesk position source

The Rust FFI currently updates its cursor position only when the peer sends a `cursor_position` message. Sending a local absolute mouse event does not advance the same cursor state. If the peer does not echo local movement, suppresses position events, or the cursor callback path stops, the controller has no continuing authoritative position source.

### 3.2 Local prediction is mixed with a false acknowledgement model

ArkTS maintains local prediction and remote authoritative coordinates, but a remote coordinate contains no local send sequence. The current timeout/tolerance policy can still treat a delayed coordinate as acknowledgement and replace a newer displayed prediction. That produces the characteristic pattern of smooth local motion followed by periodic jumps.

### 3.3 A 16 ms poll does not create 60 Hz cursor data

ArkTS synchronously polls the cursor snapshot every 16 ms. Each poll crosses NAPI, looks up the session, locks the native cursor store, copies state, and creates a JS object. This work cannot increase the rate of peer `cursor_position` messages; it only rereads the same revision and adds fixed UI-thread pressure.

### 3.4 Three unsynchronized clocks exist

Pointer behavior currently combines:

- HarmonyOS touch-event cadence;
- a 16 ms mouse-move flush cadence;
- an uncontrolled RustDesk/RDP remote-position cadence.

No single state machine owns the displayed position across these clocks.

### 3.5 Visibility preservation masks a dead position path

Keeping the last RustDesk bitmap visible when native reports `visible=false` prevents immediate disappearance, but it does not restore position updates. The result can be a valid image permanently displayed at a stale coordinate.

## 4. Phase A — establish complete observability

Behavior must not be changed in this phase. Add sampled diagnostics first so every layer can be correlated on one timeline.

### 4.1 Rust FFI metrics

Add per-session counters and monotonic timestamps for:

- received `cursor_position`, `cursor_data`, and `cursor_id` messages;
- emitted position, shape, and visibility callbacks;
- last remote cursor coordinate and callback time;
- locally queued mouse moves and their last coordinate/time;
- network read-loop activity and last decoded message kind;
- received video frames and last frame time;
- cursor callback duration and maximum observed duration;
- stream termination reason and generation.

### 4.2 C++ bridge metrics

Record:

- entry and exit counts for each `onFfiCursor` kind;
- cursor-store writes, duplicate suppression, and revision changes;
- snapshot reads, mutex wait, copy time, and pixel-copy occurrence;
- callback and video-frame thread identifiers;
- last position revision time;
- disconnect callback time versus ArkTS connected state.

### 4.3 ArkTS metrics

Record, with bounded sampling:

- touch events and local display updates;
- queued, coalesced, and sent mouse moves;
- local target, displayed, and remote observed positions;
- position owner and state-machine transition reason;
- accepted, ignored, and smoothed remote updates;
- remote silence duration and correction distance;
- cursor event/poll duration and UI update interval;
- renderer/frame timing around cursor stalls.

### 4.4 Baseline reproduction on device 38451

Capture continuously from before connection through:

1. ten seconds idle after first frame;
2. thirty seconds slow movement;
3. thirty seconds rapid movement;
4. thirty seconds fine positioning over small targets;
5. pointer movement from the controlled endpoint;
6. thirty seconds idle after local movement;
7. background and foreground transition;
8. at least twenty minutes connected.

The baseline must establish where `cursor_position` stops, whether video and the network read loop remain active, whether mouse events still enter the Rust queue, and whether controlled-end movement restarts position callbacks.

## 5. Phase B — introduce a single pointer-ownership state machine

### 5.1 Separate coordinates

Replace ambiguous shared coordinates with explicit state:

```text
displayPosition        ArkUI position drawn now
localTargetPosition    latest position produced by local input
remoteObservedPosition latest position reported by the protocol
```

Protocol callbacks must not directly and unconditionally overwrite `displayPosition`.

### 5.2 Explicit ownership states

Use the following states:

```text
Disconnected
IdleRemote
LocalGesture
LocalSettling
RemoteCorrection
RemoteSilent
```

- `LocalGesture`: local input fully owns display position.
- `LocalSettling`: final local events are being flushed; stale remote values are ignored.
- `IdleRemote`: remote independent movement may own display position.
- `RemoteCorrection`: a trusted remote difference is converged without a backward jump.
- `RemoteSilent`: the protocol is connected but has stopped reporting positions; retain the local position.
- `Disconnected`: invalidate callbacks and release session-scoped state.

### 5.3 Local input policy

For every valid touchpad movement:

1. calculate the pointer curve;
2. update `localTargetPosition`;
3. update `displayPosition` in the same UI frame;
4. coalesce and queue the latest protocol mouse position;
5. do not wait for a peer echo or timeout before displaying it.

While a finger is active, a move is pending, or the local-settling window is active, remote positions cannot directly replace the display coordinate.

### 5.4 Remove false acknowledgement semantics

Remove the behavior that treats an unsequenced remote coordinate as acknowledgement of a specific local move. In particular, replace the 250 ms timeout plus 4 px tolerance policy that can snap prediction back to an older remote coordinate.

Local sequence numbers remain useful only for connection-generation isolation, queue coalescing, and diagnostics. They cannot prove which local move a RustDesk `cursor_position` acknowledges.

## 6. Phase C — repair RustDesk synchronization semantics

### 6.1 Track locally queued movement in the Rust FFI

When `rustdesk_send_mouse()` successfully queues an absolute movement, update a separate local-target record containing coordinate, generation, sequence, and monotonic time. Do not label it as a peer-authoritative position.

This tracking belongs as close as practical to the Rust control-message queue, because that layer can distinguish an ArkTS request from a movement actually accepted for protocol transmission.

### 6.2 Preserve remote observation as an independent source

Peer `cursor_position` remains `remoteObservedPosition`. It is used to detect controlled-end physical-mouse movement and to converge after local input becomes idle.

A remote position may take ownership only when:

- no local gesture is active;
- no local movement remains pending;
- the settling interval has elapsed;
- the event belongs to the current connection generation; and
- it is near the final local target or arrives after the configured remote-silence interval.

### 6.3 Investigate the stopped callback path

Trace and resolve why device evidence reaches `visible=false`, `positionRevision=2`, and `position=0,0` while ArkTS remains connected. Audit:

- every Rust receive-loop exit and partial-stream termination path;
- the source of each visibility-false event;
- `onFfiDisconnect`, `ffiStreamEnded`, and ArkTS connected-state ordering;
- handle states where video/input continue but cursor callbacks stop;
- whether the peer intentionally suppresses local absolute-move echoes;
- display switch, rotation, and coordinate-space changes;
- the upstream RustDesk mobile `syncCursorPosition()` behavior and any required request/event.

If the protocol does not guarantee local movement echo, local ownership is the permanent design, not a fallback.

## 7. Phase D — replace synchronous 16 ms polling

### 7.1 Preferred event-driven path

Publish a lightweight native event whenever position, shape, visibility, lifecycle, or session generation changes. Position events contain only metadata:

```text
sessionId
generation
positionRevision
shapeRevision
visibilityRevision
x
y
visible
monotonicTimestamp
```

Cursor RGBA is not copied through every event. ArkTS fetches pixels only when `shapeRevision` changes or a bounded health refresh proves necessary.

Native code must release the cursor-store mutex before invoking any callback toward ArkTS.

### 7.2 Health fallback

Retain a 500–1000 ms health check only for event-loss detection and session reconciliation. It must not drive normal cursor animation and must not fetch pixels unless necessary.

### 7.3 Remove renderer work from cursor cadence

`syncRustDeskLogicalSizeFromRenderer()` must run only on renderer/display events such as first frame, viewport revision, surface resize, rotation, display switch, remote resolution change, or foreground reattach. It must not execute at cursor polling frequency.

## 8. Phase E — unify display and lifecycle behavior

### 8.1 One display coordinate

The official arrow, circle indicator, click indicator, drag handling, and button events must all consume the same `displayPosition` snapshot.

### 8.2 Frame-level UI coalescing

Touch events may update the latest local target at device cadence, but ArkUI should commit at most one display revision per UI frame. The display scheduler performs no NAPI calls and takes no native mutex.

### 8.3 Remote correction policy

Apply smoothing only to trusted remote correction, never to active local movement:

- negligible error: ignore;
- small error: converge over two or three frames;
- medium error: converge over approximately 50–100 ms;
- confirmed independent large remote movement: switch immediately or with a minimal transition;
- coordinate-space change: remap explicitly instead of applying normal correction.

Thresholds are policy constants backed by tests, not values tuned informally on one device.

### 8.4 Independent lifecycle fields

Maintain independent state for:

```text
sessionConnected
shapeAvailable
positionAvailable
protocolVisible
localPointerRequested
```

Add an independent `visibilityRevision`; visibility changes must not increment `positionRevision`. Shape and visibility changes cannot reset position. A local touchpad pointer can remain visible during temporary protocol visibility loss, but true disconnect, user disablement, or control-mode exit hides it deterministically.

## 9. RDP protocol policy

Share the pointer-ownership state machine without assuming identical feedback semantics. Each protocol adapter must declare capabilities equivalent to:

```text
supportsAuthoritativeCursorPosition
echoesLocalAbsoluteMovement
supportsRemoteIndependentMovement
supportsCursorVisibility
```

For RDP, preserve FreeRDP shape callbacks and verify whether a reliable remote position source exists. If it does not, local target position owns the display exactly as in RustDesk. Controlled-end movement support must be demonstrated by protocol/device evidence rather than inferred.

## 10. Automated verification

### 10.1 ArkTS policy tests

Cover at least:

1. continuous local movement with no remote positions;
2. delayed remote positions during local movement;
3. local settling followed by a close remote position;
4. local settling followed by a clearly stale position;
5. controlled-end movement while locally idle;
6. duplicated, reordered, and burst remote events;
7. protocol visibility false while the session remains connected;
8. shape-before-position and position-before-shape;
9. background/foreground restore;
10. old-generation events after reconnect;
11. resolution, rotation, scale, and display changes;
12. malformed, out-of-bounds, NaN, and extreme coordinates;
13. prolonged remote silence followed by recovery;
14. no backward snap after the former acknowledgement timeout.

### 10.2 Rust tests

Cover:

- local mouse queue tracking separate from remote observation;
- independent shape, position, and visibility ordering;
- duplicate position suppression;
- callback generation isolation;
- receive-loop and cursor-silence metrics;
- callback failure or slowness without blocking network reads;
- stream end and disconnect emitting one coherent lifecycle transition.

### 10.3 C++ tests

Cover:

- independent position, shape, and visibility revisions;
- metadata snapshot without RGBA copying;
- callback invocation after releasing the store mutex;
- session reset and generation isolation;
- concurrent callback unregister/destruction safety;
- high-frequency position writes concurrent with video callbacks.

### 10.4 Performance tests

Measure:

- cursor-store mutex wait under at least 10,000 updates;
- cursor event throughput and callback duration;
- position latency during maximum-size shape updates;
- cursor and video callback concurrency;
- elimination of approximately 60 idle NAPI cursor reads per second;
- video receive, decode, and present FPS with cursor off versus on.

## 11. Real-device acceptance matrix

Run RustDesk and RDP separately on Phone and Pad where available.

| Scenario | RustDesk | RDP |
|---|---:|---:|
| Slow fine positioning | Required | Required |
| Fast cross-screen movement | Required | Required |
| Repeated small-button targeting | Required | Required |
| Long-press drag | Required | Required |
| Controlled-end physical mouse movement | Required | Required where supported |
| Canvas zoom/pan and fixed scale | Required | Required |
| Rotation/display/resolution change | Required | Required where supported |
| Background/foreground restore | Required | Required |
| Reconnect and generation isolation | Required | Required |
| Thirty-minute run | Required | Required |
| Two-hour run | Required | At least one full run |

Acceptance requires:

- no visible backward jump during active local movement;
- no permanent disappearance or frozen revision;
- local display latency no greater than one UI frame under normal load;
- controlled-end independent movement appears on the controller after local idle;
- small-target accuracy comparable to circle mode;
- no material receive/decode/present FPS regression;
- no connection-page, decoder, renderer, or video-pipeline freeze.

## 12. Implementation and commit sequence

The workspace currently contains an active `codex/rustdesk-performance-diagnostics` branch and unrelated uncommitted work. Before implementation, reconcile task ownership and preserve every user/session-owned file. Never use `git add -A`.

Implement in independently revertible checkpoints:

```text
test(cursor): add cursor synchronization diagnostics
refactor(cursor): introduce pointer ownership state machine
fix(rustdesk): separate local target and remote cursor observation
refactor(cursor): replace polling with native cursor events
fix(cursor): unify visibility and session lifecycle
test(cursor): add long-run cursor regression coverage
```

Do not commit device logs, screenshots, `.appanalyzer/`, signed artifacts, local profiles, or machine-specific diagnostics. Retain a narrowly scoped runtime fallback until the event-driven path completes device acceptance.

## 13. Verification gates

Each applicable implementation checkpoint must pass:

- RustDesk FFI host tests;
- native cursor/bridge tests;
- ArkTS pointer-policy tests;
- `default@OhosTestCompileArkTS`;
- production `assembleHap`;
- `git diff --check`;
- Light open-source compliance.

The task remains open after code gates. It can be declared complete only after the full real-device matrix, including the long-run tests and video-performance comparison, succeeds.

## 14. Stop and rollback conditions

Stop the rollout and restore the last accepted cursor mode if any build shows:

- connection-page or video-pipeline freezing;
- cursor callbacks blocking frame delivery;
- permanent pointer loss;
- uncontrolled coordinate teleportation;
- stale-generation input or cursor events after reconnect;
- material video FPS or latency regression;
- inability to retain the circle cursor as a safe release fallback.

The circle style remains the release-safe fallback until the official cursor passes all acceptance gates.

## 15. Final implementation checkpoint (2026-07-22)

The scoped implementation is now present in the active branch. The remaining
device gate is deliberately separate from the code gate because device `38451`
was not available for a fresh live-session run in this checkpoint.

### 15.1 Implemented contracts

- `RemoteCursorStore` and both NAPI declaration surfaces expose `fallbackShape`.
  RustDesk bootstrap arrows are marked as controller-side fallback state; protocol
  shapes and `SetDefault` clear that state and advance `shapeRevision`.
- Cursor bitmap ownership is revision-based. A valid `PixelMap` is retained until
  its shape revision changes; failed loads retry at a bounded one-second cadence.
  Replaced maps are retired for two render frames before native release, avoiding
  the invalid-handle/disappearance window seen in long sessions.
- Shape pixels never travel through the synchronous 33 ms metadata poll. The
  worker-side snapshot transfers the RGBA allocation with an external
  `ArrayBuffer`; stale session/revision completions are rejected before
  `createPixelMap`, so a cursor-shape transition cannot block the page or video
  pipeline while copying a large bitmap.
- The fallback arrow uses a fixed 22vp edge. Protocol cursors use one uniform
  scale with 18–48vp bounds, preserving aspect ratio and hotspot alignment.
  Renderer viewport snapshots are normalized from their producing surface into the
  current ArkUI surface before cursor or input coordinate conversion.
- Phone/Pad virtual-touchpad mode explicitly hides the HarmonyOS system pointer;
  direct touch, keyboard/mouse mode, disconnect, background detach, surface
  destruction, and page disappearance restore it. This policy is scoped away from
  PC devices and is covered by pure policy tests.
- RDP input now keeps reliable FIFO barriers plus one replaceable pending move.
  The latest move is materialized before click/drag/wheel/text/key events, and the
  worker no longer holds `inputQueueMutex` while entering FreeRDP. Worker generation
  checks are atomic and repeated after acquiring the FreeRDP instance lock.

### 15.2 Automated evidence

- RustDesk FFI host suite: `125 passed, 0 failed` with
  `cargo test --manifest-path rustdesk_ffi/Cargo.toml --lib --no-default-features`.
- Native suite: `122 passed, 0 failed`; the new fallback-shape, high-rate move,
  click-barrier, wheel/text ordering, and queue-clear cases pass.
- `default@OhosTestCompileArkTS`: passed.
- Non-daemon production `assembleHap`: passed, including native Ninja build,
  ArkTS compilation, packaging, and local signing.
- The production native build includes the asynchronous cursor-pixel NAPI
  export and its four-argument OHOS `napi_create_arraybuffer` compatibility
  path; no synchronous ArkTS `getRemoteCursorSnapshot(..., true)` call remains.
- `git diff --check`: passed; Light open-source compliance: passed.

### 15.3 Device acceptance still required

On unlocked device `38451`, run separate RustDesk and RDP sessions in Phone/Pad
touchpad mode and compare circle versus official cursor for fine targeting,
fast movement, drag, shape transitions, reconnect, visibility recovery, custom
scale/resolution, rotation, and at least a thirty-minute video soak. Confirm the
system pointer does not duplicate the drawn cursor, RDP physical-mouse movement
does not stutter, and the connection/video pipeline remains responsive. A real
remote physical-mouse move must only take ownership after local touchpad input is
idle; if the endpoint emits no position callback, local prediction must remain
stable. Do not mark the task release-ready from automated gates alone.
