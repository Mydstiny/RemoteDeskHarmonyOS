# Shared Current State

## Active task

- Task: `all-protocol-ipv6-upgrade`.
- Branch: `codex/per-protocol-pinch-zoom-plan`; task baseline `5a0e05515`, M4 implementation checkpoint `f7228c4a`, compliance checkpoint `041c5166`, post-review hardening checkpoint `fa98d94f`, based on the user-authorized `main@b84224869`.
- Relative state at the hardening checkpoint: ahead of `main` by 133 commits, behind by 0, one worktree, clean.
- Plan: `docs/codex/plans/2026-08-29-all-protocol-ipv6-upgrade.md`.
- Phase: M0-M4 local code-side implementation, post-review hardening, compliance and cumulative review complete; real-device and fixed-server topology release acceptance remains pending.

## Delivered IPv6 code checkpoint

- Endpoint V2 gives RDP, RustDesk, SSH/SFTP, VNC and Moonlight one fail-closed hostname/IPv4/IPv6/bracket/port/scope contract across persistence, ArkTS, NAPI and native boundaries. Route, certificate and host-key identities use canonical typed inputs rather than ad-hoc colon splitting.
- Shared-budget Happy Eyeballs interleaves A/AAAA candidates, cancels losers and respects deadlines. Network-generation fences retire stale DNS, connect, reconnect, pairing, probe and presence work after route changes.
- RDP separates transport host, target server name and client hostname; literals omit SNI. Direct and Gateway routes use the patched, reproducibly built dual-stack FreeRDP artifacts. VNC separates scoped transport from TLS identity and covers direct/repeater recovery. Moonlight carries the numeric control winner and scope into media, with family-aware mDNS deduplication.
- SSH/SFTP direct, HTTP/SOCKS, ProxyJump, forwarding, probe/auth/key-install and file operations share canonical route data, bounded cancellation, host-key trust and transient-secret ownership. Handshake, interactive authentication, channel/SFTP reads, window adjustment and teardown are generation-admitted; interactive response allocations are wiped before release.
- RustDesk configured ID/relay/direct, presence, screen and file transfer share resolver, route-planner and network-generation rules. Official `socket_addr_v6` drives the pinned official KCP transport; a same-family NAT lease spans registration/heartbeat through route selection, AUTO races TCP and UDP/KCP under one deadline, and all-direct failure retains relay fallback.
- KCP application flush, session cancellation and normal last-owner teardown are bounded. A handshaken ACK-blackhole regression proves that the independent absolute three-second graceful deadline terminates even when the official KCP window and queues are backpressured.
- Moonlight's add-shell FAB and protocol card remain available when an optional native runtime probe is unavailable; pairing, requests and streaming keep their independent runtime gates. Optional network-observer registration/tracking failures now degrade to conservative stale-work fencing without disabling RDP, RustDesk, SSH/SFTP, VNC or Moonlight, and first registration is serialized so concurrent callers cannot publish conflicting availability.
- Diagnostic schema v3 records strictly redacted configured endpoint/route and hostname/IPv4/IPv6/scoped-IPv6 candidate facts for every RDP, RustDesk, SSH/SFTP, VNC and Moonlight connection path. These closed family values describe configured/candidate data only; actual post-DNS winner family and fallback stage remain future resolver telemetry.
- The versioned RustDesk transport-capability ABI still publishes only Direct/Relay TCP behavior. AUTO, UDP/KCP and NAT traversal remain disabled. All five product-facing IPv6 capability families remain false until their plan-specific device matrices pass.

## Verification and review

- Rust: PASS, 250/250 without default features and 260/260 with host-linkable `alacritty_terminal`. OHOS RustDesk FFI release builds and required symbol checks: PASS for arm64-v8a and x86_64.
- Native endpoint/protocol suite: PASS, 976/976, including a real IPv6 `::1` Paramiko SSH fixture, complete authentication/live-channel coverage, deferred teardown and exact file-descriptor reuse isolation.
- Code checkpoint gates: `default@OhosTestCompileArkTS` PASS in 6 s 534 ms; signed `assembleHap` PASS in 1 min 955 ms. Post-SBOM gates: PASS in 6 s 7 ms and 8 s 276 ms; signed HAP SHA-256 `20671712d2c55d67deaa3485c5f5da769af0714948c1185d7d81a8a4f5a8a64f`.
- Post-review hardening gates at `fa98d94f`: `default@OhosTestCompileArkTS` PASS in 7 s 163 ms; signed `assembleHap` PASS in 9 s 351 ms; native suite 976/976; `git diff --check` and Light open-source compliance PASS.
- Coordination-document gates after the final state/receipt refresh: `default@OhosTestCompileArkTS` PASS in 7 s 175 ms; signed `assembleHap` PASS in 8 s 803 ms.
- Final cumulative review is PASS through `fa98d94f`: `/root/ipv6_shared_rdp_review` found and verified closure of the observer-registration P1 and theme-contrast P3, then reported P0=0, P1=0, P2=0 and P3=0. Earlier shared/RDP/VNC/Moonlight, SSH/SFTP and RustDesk reviews remain valid.
- Non-blocking known gaps: Moonlight accepted-to-active synchronous terminal completion has layered common-C/ArkTS coverage but no direct production-runtime barrier fixture; diagnostic family facts do not yet report the resolver's actual winning candidate or fallback stage.

## Next and blockers

- Next: run M1-M3 IPv6 literal, AAAA-only, dual-stack fallback, discovery/control-data, reconnect, trust and SFTP matrices on HarmonyOS Phone/Pad/PC before enabling any protocol capability independently.
- RustDesk M4 release acceptance now only requires fixed-version hbbs/hbbr and controlled-peer coverage for symmetric NAT, CGNAT, UDP-blocked, TCP-only, global/IPv6-only, NAT64 and relay fallback; the executable local UDP/KCP state machine is complete. This does not block lower capability levels of other protocols.
- Blocker: `hdc list targets` returned `Connect server failed`; no target or controlled IPv6/AAAA-only/NAT64/VPN protocol endpoints were available. This blocks device/release acceptance, not the locally verified code checkpoint.
- Older RDP high-DPI, gesture/settings, bindSheet, RustDesk quality/multimonitor, release and cloud-recovery device matrices remain queued and were not overwritten by this task.
