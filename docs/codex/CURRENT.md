# Shared Current State

## Active task

- Task: `all-protocol-ipv6-upgrade`.
- Branch: `codex/per-protocol-pinch-zoom-plan`; IPv6 task baseline `5a0e05515`, current reviewed code checkpoint `d3f07f4e`, branch remains based on `main@b84224869` as explicitly authorized by the user.
- Plan: `docs/codex/plans/2026-08-29-all-protocol-ipv6-upgrade.md`.
- Phase: M0 automated contract gate complete; M1 code-side checkpoint complete and independently reviewed; real-device M1 acceptance is active. M2 Happy Eyeballs, M3 discovery/control-data and M4 RustDesk NAT remain pending.

## Delivered IPv6 checkpoint

- Endpoint V2 now gives RDP, RustDesk, SSH/SFTP, VNC and Moonlight one fail-closed contract for hostname, IPv4, IPv6, bracket, port, canonical write, zone/scope and length handling across ArkTS and native boundaries.
- Equivalent endpoint forms no longer rely on ad-hoc colon splitting for trust/route identities. RDP separates connect host, target server name and client hostname; IPv6 literals do not emit SNI. FreeRDP arm64-v8a/x86_64 prebuilts include the locked literal-SNI correction.
- RustDesk configured ID/relay/direct TCP paths share a bounded deadline and cancellation lifecycle. Rust and C++ resolver workers are lifetime-safe and capped at eight process-wide; connection admission failures roll back all session, adapter, SSH facade and network-observer publication.
- SSH proxy/jump inputs and synchronous public-key installation use strict Endpoint V2/NAPI validation, bounded strings, secret clearing and exception-safe ownership. RDP/VNC probes and Moonlight/common NAPI inputs use the same fail-closed boundary.
- All five capability families remain disabled until their plan-specific real-device exit criteria pass. In particular, parser/build success is not a product claim for `configured_endpoint_ipv6`; M2–M4 have not been implemented.

## Verification and review

- Rust unit suite: PASS, 209/209. OHOS RustDesk FFI release archives: PASS for arm64-v8a and x86_64; SHA-256 `f957a871f9d3e9749000fad62199503d37676e087e6cbe8a883a17297dfd5f8c` and `2bb4e6bd029ed14efef98279a17bc5f81ac51af8691d3e52f6d08245e95ece03`.
- Native endpoint/protocol suite reached 838/838 before the final admission/resolver hardening; the final production native sources compiled in both mandatory Hvigor gates.
- `default@OhosTestCompileArkTS`: PASS (`BUILD SUCCESSFUL in 6 s 651 ms`).
- Signed `assembleHap`: PASS (`BUILD SUCCESSFUL in 59 s 25 ms`); HAP SHA-256 `afb0416175e377c5d0e00b90083b7f2c05cbb5e0b079fae63f0430bfcdabfffa`.
- `git diff --check` and Light open-source compliance: PASS.
- Independent review `/root/ipv6_shared_rdp_review`: PASS at `d3f07f4e`; both prior P2 findings are closed and final P0/P1/P2 counts are zero.

## Next and blockers

- Next: connect a HarmonyOS Phone/Pad/PC target and run the M1 IPv6 literal plus AAAA-only matrix for each protocol, including save/restart, trust/preflight, real session, same-network reconnect and SFTP file operations. Only then enable each protocol's `configured_endpoint_ipv6` capability independently.
- Blocker: HDC returned `Connect server failed`; no target or controlled IPv6/AAAA-only protocol endpoints were available in this session. This blocks device acceptance, not the reviewed code checkpoint.
- Older RDP high-DPI, gesture/settings, bindSheet, RustDesk quality/multimonitor, release and cloud-recovery device matrices remain queued and were not overwritten by this task.
