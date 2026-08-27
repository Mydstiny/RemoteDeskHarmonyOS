# RustDesk Orientation and Resize Remediation Queue

Updated: 2026-08-27 Asia/Shanghai

## Now

1. Obtain Windows-side approval and capture upright-image plus small/large-window resize evidence on the simulator.
2. Obtain an independent re-review of remediation checkpoint `1c0e93198`.
3. Push, create the PR, wait for required `open-source-compliance`, merge, synchronize `main` and remove the merged task branch.

## Next

1. Rebuild and reinstall the final merged signed HAP so its embedded build identity matches `main`.
2. Verify Windows connect/reconnect/recovery remains upright and macOS remains unchanged on physical hardware.
3. Export one all-module log and verify it contains build, backend, geometry, lifecycle and presentation evidence without endpoint, credential, peer ID or free-form text leakage.

## Later / external acceptance

- Exercise long-running reconnect, Moonlight-to-RustDesk handoff, process restart and network-transition cases on real devices.
- Run device Hypium when the `ohosTest` task registration issue `00306054` is resolved.
