# Remote IME Cursor Sync Design

**Date:** 2026-07-12

**Status:** Proposed for user review

## 1. Goal

Make the HarmonyOS system virtual keyboard's space-bar swipe/caret-drag gesture move the caret in the active remote editor for both RDP and RustDesk sessions, while eliminating probabilistic long-text loss, duplication, and insertion-position drift.

The feature must preserve the existing system keyboard and IME. A custom replacement keyboard or a separate long-press arrow toolbar is not an acceptable substitute for the requested gesture.

## 2. Current implementation and confirmed failure modes

### 2.1 Both remote protocols share one ArkTS keyboard capture path

`RemoteDesktop.ets` opens `RemoteDesktopKeyboard` from both the common control panel and the RustDesk top bar. The hidden component is currently a one-pixel `TextInput` backed by `keyboardText` and `TextInputController`.

The protocol-specific path starts only after `ExtensionLoader.sendText()` or `ExtensionLoader.sendKey()`:

- RDP: NAPI -> `FreeRdpAdapter::sendText/sendKey()` -> native RDP input queue -> FreeRDP input APIs.
- RustDesk: NAPI -> `RustDeskBridge::sendText/sendKey()` -> Rust FFI `ControlMsg` channel -> encrypted RustDesk `KeyEvent`.

The requested gesture must therefore be solved at the shared ArkTS capture layer, with protocol-specific ordering fixes below it.

### 2.2 The current buffer invalidates system-keyboard caret gestures

After every accepted insert or delete, `resetKeyboardBuffer()` sets `keyboardText` to an empty string and forces `caretPosition(0)`. The system IME has no persistent editable content or caret range on which its space-bar swipe gesture can operate.

The existing `keyboardEditBarBuilder()` has Left/Right buttons but is not mounted in the page tree. Even if mounted, it would be an auxiliary toolbar and would not satisfy the requested system-keyboard gesture.

### 2.3 ArkTS has two potential text-send paths

`handleKeyboardSoftInsert()` sends `info.insertValue` during `onWillInsert`. `handleKeyboardChangeGuard()` may also send a non-empty value from `onChange`. The actual callback sequence varies by input method and composition state, so the current source-level contract does not prove exactly-once delivery.

API 23 documents a safer boundary:

- `onWillInsert/onWillDelete` decide whether the local edit is allowed.
- `onDidInsert/onDidDelete` report the completed edit.
- `onTextSelectionChange` reports selection and caret position changes.
- Pre-edit/candidate composition is not reported as a completed insertion by `onDidInsert` until it is committed.

### 2.4 RDP can silently evict long-text events

`FreeRdpAdapter::sendText()` converts UTF-8 to UTF-16 and enqueues two separate input events per UTF-16 code unit. The shared native queue is capped at 256 events. When full, a new priority input currently removes the oldest event with `pop_front()`, even when that event is keyboard or Unicode input.

This means roughly 128 BMP code units can fill the queue when the worker is delayed. A long insert can lose early characters or split Unicode down/release pairs. A following caret move is then applied to a different remote string length, producing apparent insertion-position drift.

RustDesk already represents a committed text insert as one `ControlMsg::Text`, but it still needs ordering and device validation with a caret gesture immediately following a large text commit.

## 3. Product behavior

### 3.1 Required user flow

1. The user places the remote caret with touch or mouse.
2. The user opens the system virtual keyboard from either supported remote keyboard entry.
3. Text entry is committed once to the remote editor.
4. The user swipes left or right on the system keyboard's space bar.
5. The remote caret moves left or right by the same relative number of editable positions.
6. Subsequent committed text is inserted at that remote position.

This flow must work for RDP and RustDesk without changing the remote application or installing a helper on the remote host.

### 3.2 Explicit semantic boundary

The client does not receive the remote application's real text, selection, grapheme boundaries, or absolute caret position. The implementation can therefore guarantee relative movement only from the most recent synchronized anchor.

The anchor is reset when:

- the keyboard opens;
- the user sends pointer/touch input to the remote surface while the keyboard is open;
- the remote session loses input eligibility, backgrounds, disconnects, reconnects, or changes protocol;
- the keyboard closes or loses editing state unexpectedly.

After reset, the next local shadow-caret position becomes the new zero point. No stale delta is sent to the remote host.

Selection expansion and remote selection mirroring are outside the initial scope. A collapsed-caret move is supported. If API/device evidence shows that the system gesture produces a non-collapsed selection, the client collapses it locally without synthesizing Shift+Arrow.

## 4. Selected architecture

### 4.1 Shared shadow editing session

Create a pure ArkTS `RemoteImeSessionPolicy` and keep lifecycle state in `RemoteDesktop`.

The policy owns calculations only:

- shadow buffer initialization and bounded recentering;
- selection-change classification;
- caret delta calculation;
- expected selection changes caused by a local insert/delete;
- remote delete direction/count;
- lifecycle reset reasons;
- privacy-safe diagnostic metadata.

`RemoteDesktop` remains responsible for ArkUI callbacks and calls into `ExtensionLoader` only for policy-produced commands.

### 4.2 Persistent hidden TextArea

Replace the current empty-after-every-key `TextInput` with a hidden, focused `TextArea` using the existing `keyboardText` state and a `TextAreaController`.

The component remains mounted in the root page so keyboard focus does not depend on a sheet being present. It uses the system IME and remains visually unobtrusive. It does not render its content over the remote desktop.

When the keyboard opens, initialize a bounded shadow buffer with neutral padding before and after a central anchor. The padding provides editable positions so the system IME can move its caret left or right even though the client cannot read the remote application's surrounding text.

Use a finite window rather than an ever-growing mirror:

- center anchor: 2048 UTF-16 positions;
- recenter threshold: within 256 positions of either edge;
- maximum retained committed user text: 4096 UTF-16 units around the current caret;
- clear all shadow text immediately when the keyboard session closes.

Recenter operations are local maintenance and must be guarded so their programmatic selection callback never emits remote arrow events.

### 4.3 Exactly-once text and delete delivery

The callback contract is:

- `onWillInsert`: return `true`; record the expected local mutation, but send nothing remotely.
- `onDidInsert`: send `insertValue` exactly once; update the expected shadow selection.
- `onWillDelete`: return `true`; record direction, value length, and expected selection, but send nothing remotely.
- `onDidDelete`: send the corresponding Backspace or Forward Delete command exactly once.
- `onChange`: update the bound shadow value only; never call `sendText()` or `sendKey()`.
- `onTextSelectionChange`: ignore selection changes matching a pending insert/delete/recenter; translate only an independent collapsed-caret change into remote Left/Right commands.
- `onSubmit`: enqueue Enter after all earlier committed text and caret commands; keep the keyboard editing state as today.

IME preview/candidate text is local until committed. No Latin pre-edit sequence, unfinished pinyin, or intermediate candidate string is sent remotely.

### 4.4 Relative-caret command generation

For an independent collapsed selection change:

1. Compare the new caret index with the last synchronized shadow index.
2. A negative delta produces that many Left taps; a positive delta produces that many Right taps.
3. Cap one callback burst at 256 taps to protect the UI and native queue. If the raw delta is larger, send it in ordered chunks scheduled across event-loop turns.
4. Update the synchronized shadow index only after the commands have been accepted by the ArkTS dispatch layer.

The same command generator is used for RDP and RustDesk. It uses existing Harmony key codes `KEYCODE_DPAD_LEFT` and `KEYCODE_DPAD_RIGHT` and respects `canForwardInput('key')` and the RustDesk browse-mode guard.

### 4.5 Ordered input contract

All non-disposable input must preserve enqueue order:

`TextBatch A -> caret movement -> TextBatch B -> delete -> Enter`

may never be reordered, partially dropped, or interleaved inside a text batch.

Mouse-move events remain disposable and coalescible. Mouse buttons, wheels, key events, text batches, and Unicode down/release pairs are non-disposable.

## 5. RDP native queue design

Add `TextBatch` to the RDP queued input type. A queued batch stores the already-converted UTF-16 sequence as one logical queue item.

`FreeRdpAdapter::sendText()` performs UTF-8 validation/conversion and enqueues the complete batch. The worker expands the batch into Unicode down/release calls only after it becomes the front item. No subsequent arrow, delete, or Enter event can overtake the batch.

Queue-pressure rules become:

- consecutive mouse moves may be replaced by the newest move;
- queued mouse moves may be purged before a non-disposable input;
- a full queue may reject or drop a new mouse move;
- a full queue must never remove an existing non-disposable input;
- text batches count as one logical event for queue depth and also report their UTF-16 unit count for diagnostics.

No RDP certificate, authentication, ErrorInfo/no-frame sheet, renderer, audio, clipboard, rdpdr/shared drive, or graphics setting may change.

## 6. RustDesk input design

Retain one committed string per `ControlMsg::Text`. The existing Rust channel is FIFO, and the streaming loop serially handles `ControlMsg::Text` and `ControlMsg::KeyEvent`.

Add tests and low-volume diagnostics proving that a text command followed by N cursor commands is emitted in that exact order. Do not change RustDesk encryption, frame reader, video/audio, clipboard, relay, file transfer, or top-bar behavior.

RustDesk currently converts non-modifier control-key down into a one-shot `press` and ignores the matching release. The shared ArkTS gesture translator must therefore send discrete taps rather than relying on remote key-hold autorepeat.

## 7. Diagnostics and error handling

Never log the shadow text, inserted text, deleted text, candidate text, or derived character values.

Permitted fields:

- session id and protocol;
- monotonically increasing input sequence;
- source (`didInsert`, `didDelete`, `selection`, `submit`, `recenter`);
- UTF-16 unit count;
- old/new selection indices and signed delta;
- policy result (`ignoredExpected`, `remoteLeft`, `remoteRight`, `reset`);
- native queue logical depth, text-unit depth, max depth, and rejected mouse-move count.

If input forwarding becomes unavailable during a gesture, reset the anchor and stop scheduling remaining cursor chunks. Do not replay them after reconnect or foreground restore.

## 8. Test strategy

### 8.1 Pure ArkTS policy tests

Cover:

- initial centered shadow selection;
- programmatic initialization and recenter callbacks are ignored;
- insertion-related selection changes are ignored;
- deletion-related selection changes are ignored;
- independent left/right moves produce exact signed deltas;
- collapsed movement only; selection expansion does not emit Shift behavior;
- 256-command chunking;
- pointer input, keyboard close, background, disconnect, and session change reset state;
- no diagnostic result contains text content.

### 8.2 RDP native tests

Cover:

- 8,000 UTF-16 units remain one ordered logical text batch;
- the worker emits Unicode down and release for every unit;
- a following arrow is emitted only after the complete text batch;
- queue pressure never evicts key, Unicode, text, button, wheel, or delete events;
- mouse moves remain coalescible/droppable;
- surrogate pairs stay adjacent and retain down/release pairing;
- queue metrics count logical events and text units separately.

### 8.3 Rust unit tests

Cover:

- `Text -> Left x N -> Text` retains channel and wire-send order;
- committed CJK and emoji text stays a single `seq` event;
- control-key releases remain intentionally ignored without affecting subsequent text order;
- disconnect stops pending cursor chunks instead of replaying them into a new session.

### 8.4 Device matrix

Run on a real HarmonyOS phone or Pad with the system keyboard and both protocols:

- English: type 500 characters, swipe left, insert a marker, swipe right, insert another marker.
- Chinese IME: type pinyin, change candidate, commit Chinese text, swipe, insert again; unfinished composition must not appear remotely.
- Emoji: commit single-code-point and surrogate-pair emoji, then swipe and insert markers.
- Multiline: enter at least 20 lines, swipe within recently entered text, insert and delete.
- Large commit: 500, 2,000, and 8,000 UTF-16 units followed immediately by swipe and insertion.
- Lifecycle: click the remote surface, close/reopen the keyboard, Home/background/foreground, disconnect/reconnect, and switch between RDP and RustDesk hosts.

Validate in Windows Notepad for RDP and a plain-text editor for RustDesk. Compare the final remote text against a prepared expected string and capture privacy-safe logs.

## 9. Acceptance criteria

- The system keyboard's space-bar swipe moves the remote caret in the same direction and by the same relative amount for RDP and RustDesk.
- Text committed after the gesture appears at the intended remote position.
- Committed input is delivered exactly once; IME preview and candidate changes are not prematurely sent.
- No keyboard or text input is silently dropped under the tested RDP queue pressure.
- Large text followed immediately by caret movement preserves strict order.
- Closing/reopening or resetting the session cannot replay stale movement.
- Input diagnostics contain no user text.
- Existing native tests pass, the Rust FFI tests pass for both supported ABIs, and the production `assembleHap` build succeeds.

## 10. Scope exclusions

- Absolute remote caret or document-content synchronization.
- Remote selection expansion through Shift+Arrow.
- Word-level movement, Home/End, or custom arrow-key repeat UI.
- SSH terminal input behavior and `VirtualKeyBar`.
- VNC, whose current adapter remains a mock.
- Clipboard paste policy changes.
- Any RDP/RustDesk video, audio, background-session, certificate, authentication, file-transfer, or rendering changes.

## 11. Rollback strategy

Keep the change separable into ArkTS shadow-session commits and RDP queue commits. If a device-specific IME does not emit usable `onTextSelectionChange` events, disable gesture translation behind the shared policy without reverting the RDP no-drop text-batch correction.

The previous keyboard capture implementation must not be restored wholesale if it reintroduces empty-buffer caret behavior or RDP input eviction. A rollback may fall back to committed text/delete only while leaving the corrected input-order contract intact.
