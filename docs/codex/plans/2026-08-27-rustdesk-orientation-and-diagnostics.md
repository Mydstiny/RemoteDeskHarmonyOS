# RustDesk Orientation, Resize and Cross-Protocol Diagnostics Plan

## Goal

Ship one deterministic RustDesk presentation rule that cannot change with peer OS labels, make PC window resizing responsive even on a quiet desktop, and keep exported diagnostics sufficient to identify the installed build and runtime path without collecting secrets or endpoint identities.

## Work packages

1. **Validated RustDesk presentation**
   - Use one platform-invariant policy for Windows, macOS, Linux and unknown peers.
   - Apply only the identity/flip-X/flip-Y/rotate-180 matrices reported by the local NativeImage producer; retain the last valid matrix after read failure or malformed input.
   - Keep peer OS as telemetry only, never as an orientation switch.
   - Cover platform invariance, accepted axis-aligned transforms and malformed-matrix rejection.

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

4. **PC resize responsiveness**
   - Publish input geometry immediately while coalescing repeated ArkUI size callbacks to one update per display interval.
   - Move overlay restoration and pointer ownership work to a bounded settle phase.
   - Request a retained-frame redraw after the renderer viewport changes so a quiet remote desktop does not wait seconds for another encoded frame.

5. **Verification and delivery**
   - Run focused native and ArkTS tests, both exact Hvigor gates, `git diff --check` and Light compliance.
   - Commit checkpoints, obtain an independent sub-agent review, fix all blocking findings and rerun affected gates.
   - Push, create a PR, wait for required `open-source-compliance`, merge and return to synchronized `main`.

## Acceptance boundaries

- Source/build verification cannot substitute for real Windows/macOS visual acceptance.
- Simulator acceptance requires the saved Windows peer to approve the connection or provide a valid device password.
- Existing 1.1.2 support logs are diagnostic inputs only; they do not identify the exact source revision.
- Exported diagnostics must never include credentials, TOTP secrets, peer IDs, endpoints, usernames, commands, paths, clipboard data or free-form native error strings.

## Live regression evidence and remediation

- On the HarmonyOS PC simulator, the affected Windows H.264 hardware-decode session reported `producer transform class=flip_y` while the merged build forced `presentation=identity`.
- The screenshot showed a vertical inversion: the Windows taskbar moved to the top, text was upside down, and left/right placement remained unchanged. This explains why mouse coordinates stayed correct.
- The macOS control session used the software VP9/raw path and did not consume a NativeImage producer transform.
- Window-manager resize emitted multiple intermediate sizes, while quiet RustDesk desktops sometimes waited four to five seconds for another decoded frame. The remediation coalesces resize work and explicitly redraws the retained texture.
