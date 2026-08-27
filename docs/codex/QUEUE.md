# RustDesk Orientation and Diagnostics Queue

Updated: 2026-08-27 Asia/Shanghai

## Now

1. Make RustDesk presentation platform-independent and canonically upright.
2. Add build-identifiable, privacy-safe runtime facts to all supported connection-component diagnostics.
3. Add focused tests and run native, ArkTS, HAP, diff and compliance gates.
4. Obtain independent review, remediate findings, then push, PR and merge when all gates pass.

## Next

1. Install the new signed HAP and verify Windows connect/reconnect/recovery remains upright while macOS remains unchanged.
2. Export one all-module log and verify it contains build, backend, geometry, lifecycle and presentation evidence without endpoint, credential, peer ID or free-form text leakage.

## Later / external acceptance

- Exercise long-running reconnect, Moonlight-to-RustDesk handoff, process restart and network-transition cases on real devices.
- Run device Hypium when the `ohosTest` task registration issue `00306054` is resolved.
