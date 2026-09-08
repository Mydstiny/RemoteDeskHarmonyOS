# VNC LastRect update repair

Status: code checkpoints e67724ac + 21da46aa; independent review PASS; peer/device acceptance pending.

## Evidence and scope

- User reported `VNC update contains too many rectangles [E-VNC-CONNECTION]` and authorized repair on 2026-09-08.
- Supplied schema-2 log identifies build `1.1.4+a43cf951b975`, with eight captured events and zero reported drops. It shows a VNC request followed by ERROR in 256 ms, but contains neither native error text nor rectangle headers.
- The reported build and pre-repair checkout have identical `receiveFramebufferUpdate` bodies. Both advertise LastRect but reject any declared count above 4096 before reading rectangles.
- [RFB LastRect specification](https://github.com/rfbproto/rfbproto/blob/master/rfbproto.rst#lastrect-pseudo-encoding): advertised count can be an upper bound, commonly 65535; a LastRect pseudo-rectangle ends the update early.
- The bug is independently reproducible using a single Raw rectangle plus LastRect. The supplied log alone does not prove that this user's peer sent 65535; actual excessive work or prior stream misalignment remain distinguishable hypotheses.
- Existing runtime snapshot `connected` represents an active local session lifecycle, not proof of RFB handshake completion. Zero frames in the 5-ms snapshot is not an end-of-session frame count.

## Implemented behavior

- Accept any 16-bit advertised count, reading at most 4096 non-LastRect rectangles plus one final header. Stop on LastRect before applying the work limit; reject a 4097th non-LastRect before its payload.
- Retain the existing rectangle coordinates, pixel, cursor, compressed-input and decompression bounds. Pseudo-rectangles count against the work budget. No unlimited loop, pixel-format change, encoding preference change, transport/authentication change or protocol dependency update.
- A complete update emits one combined frame. Failed/incomplete updates do not emit their partial framebuffer. Single-rectangle ZRLE retains its existing request pipeline; an unknown-count LastRect update does not pipeline early.
- Native errors after a complete FBU header append `[VNC-FBU reason=N advertised=N processed=N encoding=N]`. The native log also records the update sequence. Only numeric facts are exported, not the surrounding native/server text.
- `reason`: 1 actual rectangle limit; 2 incomplete rectangle header; 3 payload/decode/geometry/request failure; 4 unsupported encoding. Header-stage encoding is 0 (unknown), not evidence of Raw.
- JSONL `vnc_update_rejected`: `code=reason`, `count=advertised`; `vnc_update_progress`: `code=encoding`, `count=processed`. They share `sessionRef`. State transitions and successful failure facts are deduplicated separately. A delayed/unavailable message is retried; successful facts are recorded once per ERROR transition and capture. No cross-protocol or inactive-capture lookup.
- Review correction: the engine stores its message before publishing the state; VNC NAPI reads that same active engine instead of waiting for the external callback cache. Callback invocation remains outside the message mutex, preserving reentrant stop/state behavior. Detached/non-VNC sessions retain the existing cache fallback.
- A failure before the complete FBU header still follows existing transport diagnostics; the numeric suffix does not claim that such a header was read.

## Verification

- `python3 scripts/tests/test_vnc_framebuffer_update.py --openssl-prefix <host-openssl-prefix> --sanitize`: 22 PASS, actual native engine and POSIX socketpair transport, ASan/UBSan.
- Covers fixed/unknown counts, 4096 boundary, non-sentinel upper bound, LastRect then another update with one-byte writes, Raw/CopyRect/ZRLE/cursor/resize, malformed/truncated input, missing terminator, actual limit and no partial frame on failure. Delayed and reentrant state callbacks verify message publication before terminal polling.
- `RDP_TYPESCRIPT_PATH=<DevEco-TypeScript-module> node scripts/tests/test_vnc_update_diagnostics.cjs`: 8 PASS, actual ArkTS parsing/capture/JSONL serialization and facade method. Covers numeric bounds, message redaction, session pairing, repeat suppression, capture restart, other protocols, native diagnostic failure isolation and old-message-to-valid-suffix retry.
- Negative control: substituting the exact reported-build FBU body into the current host harness passes the three basic fixed-count cases and fails the first LastRect acceptance case (abort exit -6). No application sources were changed by this experiment.
- Current OHOS compile-command syntax checks: engine, adapter and NAPI on arm64-v8a and x86_64 PASS.
- Mandatory `default@OhosTestCompileArkTS`: exit 0, `BUILD SUCCESSFUL in 5 s 147 ms`.
- Mandatory signed `assembleHap`: exit 0, `BUILD SUCCESSFUL in 6 s 951 ms`; `SignHap` 915 ms.
- `pwsh -NoProfile -File scripts/verify_open_source_release.ps1 -Mode Light` and `git diff --check`: PASS.
- Initial sandbox compile could not write the configured Hvigor cache (EPERM); authorized elevated retry passed. No build/signing configuration changed.

Mandatory commands from the App root:

```sh
source scripts/macos_env.sh
hvigorw --mode module -p module=entry -p product=default default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon
hvigorw --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --no-daemon
```

## Closure and remaining acceptance

- Independent reviewer `/root/review_vnc_update`: initial review found one P2 (ERROR could precede the external message cache, then facade deduplication lost the diagnostic). Corrected in 21da46aa; same-reviewer final PASS on e67724ac + 21da46aa, no remaining blocking findings. Reviewer independently reran all 22 native sanitizer and 8 host checks; verified message publication, lock ordering, immediate cleanup ordering and reviewed source identity.
- Real failing peer: NOT RUN. Reconnect from a build containing the repair; verify initial and repeated updates, screen activity, resize/cursor, disconnect/reconnect. If an error persists, export `connection.vnc` to obtain the new numeric failure events and correlate native VNC diagnostics where available.
- User's server software/version and actual RFB packet count remain unavailable. Do not label this incident as packet-proven 65535 or claim complete VNC server/device compatibility.
- Preserve shared `codex/pro-purchase-foundation`; unfinished Pro work and other device acceptance prohibit aggregate branch closure/merge. This is a separately committed VNC repair.
