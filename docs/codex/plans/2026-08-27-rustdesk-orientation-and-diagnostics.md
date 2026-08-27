# RustDesk Orientation and Cross-Protocol Diagnostics Plan

## Goal

Ship one deterministic RustDesk presentation rule that cannot change with peer OS labels, and make exported diagnostics sufficient to identify the installed build and the runtime path used by every connection component without collecting secrets or endpoint identities.

## Work packages

1. **Canonical RustDesk presentation**
   - Return identity presentation for Windows, macOS, Linux and unknown RustDesk peers.
   - Keep producer transform inspection as telemetry only.
   - Replace OS-branch tests with platform-invariance and transform-classification coverage.

2. **Diagnostic schema and build identity**
   - Version the JSONL schema update.
   - Add a stable diagnostic build identifier and numeric application version code to the manifest.
   - Use fixed, validated categorical/numeric runtime facts; reject arbitrary text and sensitive identifiers.

3. **All-component runtime capture**
   - RDP: state, backend/codec, geometry, frame/traffic and latency evidence.
   - RustDesk: the same shared decoder facts plus canonical presentation and observed producer-transform class.
   - VNC: state, encoding/geometry/frame/traffic evidence.
   - Moonlight: lifecycle and bounded stream/backend/geometry counters.
   - SSH/SFTP: lifecycle and bounded terminal/transfer counters without commands, paths, hostnames or payloads.
   - Deduplicate/throttle snapshots so capture does not become a performance or storage problem.

4. **Verification and delivery**
   - Run focused native and ArkTS tests, both exact Hvigor gates, `git diff --check` and Light compliance.
   - Commit checkpoints, obtain an independent sub-agent review, fix all blocking findings and rerun affected gates.
   - Push, create a PR, wait for required `open-source-compliance`, merge and return to synchronized `main`.

## Acceptance boundaries

- Source/build verification cannot substitute for real Windows/macOS visual acceptance.
- Existing 1.1.2 support logs are diagnostic inputs only; they do not identify the exact source revision.
- Exported diagnostics must never include credentials, TOTP secrets, peer IDs, endpoints, usernames, commands, paths, clipboard data or free-form native error strings.
