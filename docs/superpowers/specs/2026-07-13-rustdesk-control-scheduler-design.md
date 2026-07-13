# RustDesk Control Scheduler Design

## Objective

Prevent a long-lived RustDesk session from accumulating obsolete control work and starving encrypted network receives, while preserving the recently added lossless IME ordering contract.

## Current failure mode

`rustdesk_ffi` currently places every control event in an unbounded `std::sync::mpsc::channel`. The streaming loop repeatedly calls `try_recv()` until the channel is empty and only then calls `crypto.recv()`. A continuous 16 ms mouse stream, pressure reports, or a temporarily slow callback can therefore postpone reads indefinitely and make both media and input appear progressively late.

## Chosen design

Replace the channel with an `Arc<ControlInbox>` shared by FFI callers and the streaming thread.

- A FIFO `VecDeque<ControlMsg>` retains reliable messages: text, key down/up, mouse button, wheel, clipboard, and the existing streaming file-request message. The FIFO keeps `Text -> cursor key -> Text` byte-for-byte ordered.
- `MouseMove` is a single replaceable slot. Replacing it records a coalescing counter; only the most recent location is sent.
- `RefreshVideo` is a boolean pending flag and `VideoPressure` is a replaceable latest-level slot. Duplicate/stale state requests are coalesced.
- The consumer takes at most eight items per iteration. After that bounded batch it must return to the encrypted receive path. Reliable FIFO work is selected first; replaceable work fills unused batch capacity.
- Shutdown is an atomic side channel, not a queue item. Disconnect sets the flag, shuts down the cloned TCP socket, then joins the streaming thread. The read is therefore interrupted even if media is idle or control work is pending.
- Diagnostics are low-frequency Rust logs only: reliable depth/high-water mark, coalesced mouse/refresh/pressure counts, batch-limit hits, `crypto.recv()` gap, video callback duration, and video-ACK write duration. No NAPI/ArkTS API is added in this phase.

## Ordering and compatibility rules

- No text, key, click, wheel, clipboard, or file-request event may be dropped or reordered.
- A coalesced mouse movement may be sent after a later reliable event. This is safe because button events already carry their target coordinates; preserving stale hover positions is less important than preserving clicks and IME input.
- Existing video frame ownership, decoder queues, audio queues, codec negotiation, relay protocol, and C++ callback signatures stay unchanged.
- The second phase, separating video callback/ACK from receive, is conditional on diagnostics showing a stable control inbox while callback/ACK time or ingress gaps grow. It is not part of this change.

## Acceptance criteria

1. Rust tests prove mouse, refresh, and pressure coalescing; reliable FIFO ordering; eight-item batch fairness; and shutdown priority.
2. Existing IME FIFO regression remains green.
3. A disconnect cannot wait behind a control backlog because it shuts down the TCP socket before joining.
4. Both OHOS Rust targets rebuild and the production HAP links the resulting FFI libraries.
5. A 30-60 minute device matrix can distinguish a growing control backlog from decoder/remote/relay cadence issues using the new logs.

## Out of scope

- Replacing the self-implemented RustDesk protocol with upstream core.
- Changing codec/decoder behavior or decoupling the video callback thread.
- File-transfer concurrency redesign and C++ FFI-handle lifetime redesign; both remain follow-up work after this focused latency fix.
