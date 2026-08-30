# Shared Current State

## Active task

- Task: `all-protocol-ipv6-upgrade`.
- Branch: `codex/per-protocol-pinch-zoom-plan`; task baseline `5a0e05515`, code checkpoint `8e7d8a8c`, review-scope checkpoint `671afcc2`, based on the user-authorized `main@b84224869`.
- Relative state at the review checkpoint: ahead of `main` by 96 commits, behind by 0, one worktree, clean.
- Plan: `docs/codex/plans/2026-08-29-all-protocol-ipv6-upgrade.md`.
- Phase: M0-M3 code-side implementation complete; M4 release boundary complete but executable UDP/KCP NAT transport and all real-device exit criteria remain pending. Final cumulative review is in progress.

## Delivered IPv6 code checkpoint

- Endpoint V2 gives RDP, RustDesk, SSH/SFTP, VNC and Moonlight one fail-closed hostname/IPv4/IPv6/bracket/port/scope contract across persistence, ArkTS, NAPI and native boundaries. Route, certificate and host-key identities use canonical typed inputs rather than ad-hoc colon splitting.
- Shared-budget Happy Eyeballs interleaves A/AAAA candidates, cancels losers and respects deadlines. Network-generation fences retire stale DNS, connect, reconnect, pairing, probe and presence work after route changes.
- RDP separates transport host, target server name and client hostname; literals omit SNI. Direct and Gateway routes use the patched, reproducibly built dual-stack FreeRDP artifacts. VNC separates scoped transport from TLS identity and covers direct/repeater recovery. Moonlight carries the numeric control winner and scope into media, with family-aware mDNS deduplication.
- SSH/SFTP direct, HTTP/SOCKS, ProxyJump, forwarding, probe/auth/key-install and file operations share canonical route data, bounded cancellation, host-key trust and transient-secret ownership.
- RustDesk configured ID/relay/direct, presence, screen and file transfer share resolver, route-planner and network-generation rules. Official `socket_addr_v6` remains a UDP/KCP candidate; UDP-only routes fail closed and relay fallback remains available.
- The versioned RustDesk transport-capability ABI publishes only supported Direct/Relay TCP behavior. AUTO, UDP/KCP and NAT traversal remain disabled. All five product-facing IPv6 capability families remain false until their plan-specific device matrices pass.

## Verification and review

- Rust: PASS, 237/237 without default features and 247/247 with full features. OHOS RustDesk FFI release builds and required symbol checks: PASS for arm64-v8a and x86_64.
- Native endpoint/protocol suite: PASS, 926/926.
- `default@OhosTestCompileArkTS`: PASS (`BUILD SUCCESSFUL in 6 s 57 ms` at the code checkpoint; `6 s 161 ms` after the review-scope documentation change).
- Signed `assembleHap`: PASS (`BUILD SUCCESSFUL in 52 s 275 ms` at the code checkpoint; `7 s 842 ms` after the review-scope documentation change). HAP SHA-256: `9fd1b8c57607403031a75f67198a3238ecd340e2deefe09dae9f0c2b105b8070`.
- Rust format, `git diff --check` and Light open-source compliance: PASS.
- Prior scoped reviews are PASS. Final cumulative reviewers `/root/ipv6_shared_rdp_review`, `/root/ipv6_ssh_review` and `/root/ipv6_rustdesk_review` are rechecking the immutable checkpoint; no final receipt is claimed yet.
- Non-blocking known gap: Moonlight accepted-to-active synchronous terminal completion has layered common-C/ArkTS coverage but no direct production-runtime barrier fixture.

## Next and blockers

- Next: finish cumulative review and receipt, then run M1-M3 IPv6 literal, AAAA-only, dual-stack fallback, discovery/control-data, reconnect, trust and SFTP matrices on HarmonyOS Phone/Pad/PC before enabling any protocol capability independently.
- RustDesk M4 still requires an executable cancellable UDP/KCP NAT state machine plus fixed-version hbbs/hbbr and controlled-peer coverage for symmetric NAT, CGNAT, UDP-blocked, IPv6-only, NAT64 and relay fallback. This does not block the lower capability levels of other protocols.
- Blocker: `hdc list targets` returned `Connect server failed`; no target or controlled IPv6/AAAA-only/NAT64/VPN protocol endpoints were available. This blocks device/release acceptance, not the locally verified code checkpoint.
- Older RDP high-DPI, gesture/settings, bindSheet, RustDesk quality/multimonitor, release and cloud-recovery device matrices remain queued and were not overwritten by this task.
