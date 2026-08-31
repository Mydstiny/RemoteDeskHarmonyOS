# Shared Current State

## Active task

- Task: `all-protocol-ipv6-upgrade`.
- Branch: `codex/per-protocol-pinch-zoom-plan`; task baseline `5a0e05515` is the 1.1.4 checkpoint, blocker-remediation code checkpoint `a1991db21`, and reviewed SBOM checkpoint `f59f31d9`, based on the user-authorized `main@b84224869`.
- Relative state at `f59f31d9`: ahead of `main` by 143 commits, behind by 0, one worktree, clean.
- Plan: `docs/codex/plans/2026-08-29-all-protocol-ipv6-upgrade.md`.
- Phase: M0-M4 local code, 1.1.5 metadata/14-page Swiper, blocker remediation, compliance and cumulative review complete; real-device and fixed-server topology release acceptance remains pending.

## Delivered local checkpoint

- Endpoint V2 gives RDP, RustDesk, SSH/SFTP, VNC and Moonlight one fail-closed hostname/IPv4/IPv6/bracket/port/scope contract. Shared-budget Happy Eyeballs, network-generation retirement and protocol-specific identity handling cover persistence, ArkTS, NAPI and native boundaries.
- The full `5a0e05515..a1991db21` 1.1.4-to-current regression scan found and removed three false blockers: `0e14b13fa` validates optional ports only for the active route, `73cd265c5` lets actual endpoint I/O decide reachability when the default-network observer reports unavailable, and `a1991db21` parses only fields owned by the active protocol.
- Those fixes remove the confirmed RustDesk `E-RUSTDESK-PREFLIGHT-2` path and the same-class VNC/RDP/SSH/Moonlight launch failures without weakening VNC/RDP certificate and trust checks, account scope, plaintext consent, Moonlight runtime gates or RustDesk unreleased transport gates.
- Moonlight's FAB add entry remains enabled independently from its optional runtime probe. Network-generation changes still retire stale DNS/socket work, but a missing default network no longer globally disables LAN, VPN or link-local endpoint attempts.
- Diagnostic schema v3 records redacted `configuredEndpointFamily`, `configuredRouteFamily`, `ipv4Candidate`, `ipv6Candidate` and `scopedIpv6` facts for all five protocol paths; it does not expose raw endpoints or claim the resolver winner.
- Application metadata, native startup version, UI text, diagnostics, release documents and SBOM agree on `1.1.5` / `1001005`. The current Swiper has exactly 14 pages, contains no `1.1.4`, displays `1.1.5` only on its overview and derives the item count from the registry; explicit 1.1.4/1.1.3 history remains available.
- RustDesk UDP/KCP/NAT implementation remains fail-closed at the product boundary: AUTO, UDP/KCP, NAT and all five IPv6 capability families stay disabled until their controlled device matrices pass.

## Verification and review

- Native endpoint/protocol suite PASS 979/979 after the three blocker fixes, including active-route port isolation, observer degradation and cross-protocol field-isolation regressions.
- Required DevEco gates after the reviewed SBOM checkpoint: `default@OhosTestCompileArkTS` PASS in 6 s 683 ms; signed `assembleHap` PASS in 8 s 131 ms. `pack.info` is `1.1.5` / `1001005`; signed HAP SHA-256 is `114dae916984b93f3c87283012e46886646e38f586457d582441fba09f7fc28f`.
- `git diff --check` and Light open-source compliance PASS. SBOM root package is `1.1.5`; its document name/namespace anchor code checkpoint `a1991db21`, with 144 packages and 406 relationships unchanged.
- `/root/ipv6_blocker_review_retry` independently scanned the complete `5a0e05515..a1991db21` IPv6 increment and then verified `f59f31d9` as SBOM-metadata-only. Final findings are P0=0, P1=0, P2=0 and P3=0.
- Earlier shared/RDP/VNC/Moonlight, SSH/SFTP, RustDesk and 1.1.5 release reviews remain valid. Existing ArkTS/dependency warnings are non-fatal and were not introduced by the SBOM refresh.

## Next and blockers

- Next: run the 1.1.5 update-Swiper layout/interaction matrix and M1-M3 IPv6 literal, AAAA-only, dual-stack fallback, discovery/control-data, reconnect, trust and SFTP matrices on HarmonyOS Phone/Pad/PC.
- RustDesk M4 release acceptance requires fixed-version hbbs/hbbr and controlled peers for symmetric NAT, CGNAT, UDP-blocked, TCP-only, global/IPv6-only, NAT64 and relay fallback before enabling any gated capability.
- Blocker: both SDK-selected and DevEco-bundled `hdc list targets` returned no target. No controlled IPv6/AAAA-only/NAT64/VPN endpoints were available, so real-device/release acceptance is not claimed.
- Older RDP high-DPI, gesture/settings, bindSheet, RustDesk quality/multimonitor and cloud-recovery device matrices remain queued and were not overwritten by this task.
