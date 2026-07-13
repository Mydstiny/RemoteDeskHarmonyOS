# Remote IME cursor synchronization validation

Date: 2026-07-13

## Implemented behavior

- The RDP and RustDesk system keyboard entry points now share a persistent local shadow `TextArea`.
- Completed IME inserts and deletes are delivered exactly once through `onDidInsert` and `onDidDelete`.
- System IME selection changes, including spacebar glide / caret drag, become ordered relative Left/Right key taps.
- The ArkTS FIFO keeps a large cursor movement ahead of text typed after it.
- RDP text is an atomic UTF-16 `TextBatch`; keyboard/text input is never evicted at the queue soft limit.
- RustDesk keeps its existing mpsc channel and now has protobuf-builder and FIFO tests for Text -> Left -> Text.

## Local verification

| Check | Result |
| --- | --- |
| Native queue tests | `75 passed, 0 failed` |
| Rust FFI tests | `72 passed, 0 failed` (`cargo test --lib --no-default-features`) |
| RustDesk ABI libraries | arm64-v8a and x86_64 rebuilt; both expose `rustdesk_get_transfer_status` and `rustdesk_get_clipboard` |
| Production HAP | `assembleHap` successful; signed HAP produced at `entry/build/default/outputs/default/entry-default-signed.hap` |
| Static contracts | No legacy per-character RDP enqueue / queue-front eviction path remains; all three RDP queue metrics are exported from native through ArkTS |

## ArkTS test-target recovery

- `HdsTabs` now uses the ArkTS form that places its complete modifier chain before the content block. It retains all four tabs, the immersive material, floating dimensions, handedness adaptation, bottom position, horizontal-pan guard, and animation behavior.
- `default@OhosTestCompileArkTS` completed successfully on 2026-07-13. It is the current SDK's ArkTS test-compilation entry point and resolves `UIDesignKit`, `AccountKit`, and `ScanKit` correctly.
- The obsolete `default@OhosTestBuildArkTS` webpack task does not receive HarmonyOS extension API paths and can fail while emitting a secondary SourceMap `share` error. It is not used as the test acceptance gate.
- The complete `onDeviceTest` graph also compiled `ohosTest@OhosTestCompileArkTS` successfully. Its former stale `RemoteHost.isFavorite` assertions were updated to validate the supported `groupId` round trip instead.

## Emulator smoke test

- Target: `127.0.0.1:5555`, HarmonyOS emulator 6.1 SP12, `x86_64`.
- Installed the signed HAP with `hdc install -r`: success.
- Started `com.example.remotedesktop/EntryAbility`: success; application process observed.

## Required manual remote-host acceptance

The emulator did not provide an authorized RDP or RustDesk text-editor session, so these checks remain manual rather than fabricated:

1. On each protocol, type text, glide the system IME spacebar left/right, and insert markers before and after the movement.
2. Validate Chinese candidate commit, BMP + emoji text, Enter, Backspace, Forward Delete, and long 500/2,000/8,000 UTF-16 unit batches.
3. Confirm touch/mouse/background/disconnect/reconnect resets do not replay a previous IME generation.
4. Check diagnostics only for queue counts and UTF-16 unit counts; never log input text.
