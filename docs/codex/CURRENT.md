# Shared Current State

## Active task

- Task: `all-protocol-ipv6-upgrade`.
- Branch: `codex/per-protocol-pinch-zoom-plan`; task baseline `5a0e05515`, IPv6/RustDesk M4 checkpoint `f7228c4a`, post-review hardening checkpoint `fa98d94f`, 1.1.5 release checkpoint `fb30744b`, final SBOM checkpoint `ce5ab902`, based on the user-authorized `main@b84224869`.
- Relative state at `ce5ab902`: ahead of `main` by 138 commits, behind by 0, one worktree, clean.
- Plan: `docs/codex/plans/2026-08-29-all-protocol-ipv6-upgrade.md`.
- Phase: M0-M4 local code, post-review hardening, 1.1.5 metadata/Swiper, compliance and cumulative review complete; real-device and fixed-server topology release acceptance remains pending.

## Delivered local checkpoint

- Endpoint V2 gives RDP, RustDesk, SSH/SFTP, VNC and Moonlight one fail-closed hostname/IPv4/IPv6/bracket/port/scope contract. Shared-budget Happy Eyeballs, network-generation fences and protocol-specific identity handling cover persistence, ArkTS, NAPI and native boundaries.
- RDP direct/Gateway, VNC direct/repeater/TLS, Moonlight discovery/control/media, SSH/SFTP direct/proxy/jump/forwarding/file operations and RustDesk ID/relay/direct/presence/file transfer use canonical route data and bounded stale-work cancellation.
- RustDesk's executable UDP/KCP/NAT state machine uses the pinned official transport, same-family lease and one shared route deadline while retaining relay fallback. Product AUTO, UDP/KCP, NAT and all five IPv6 capability families remain disabled until their device matrices pass.
- Moonlight's add-shell FAB remains available when its optional runtime probe is unavailable; pairing, requests and streaming retain their independent gates. Optional network-observer failures conservatively fence stale work without disabling any protocol module.
- Diagnostic schema v3 records only redacted configured route and hostname/IPv4/IPv6/scoped-IPv6 candidate facts for all five connection paths; it does not claim the actual resolver winner or expose raw endpoints.
- Application metadata, native startup version, user-visible version text, diagnostics tests, release documentation and SBOM now agree on `1.1.5` / `1001005`.
- The current update Swiper contains exactly 14 pages: one 1.1.5 overview, eight retained feature cards, four new protocol/session/display/recovery cards and one generic completion page. Current content contains no `1.1.4`, shows `1.1.5` on only the overview, and derives “查看全部 N 项” from the registry count. Explicit historical lookup still returns the original 10-page 1.1.4 and 12-page 1.1.3 releases.

## Verification and review

- IPv6/RustDesk checkpoint: Rust PASS 250/250 without default features and 260/260 with host-linkable `alacritty_terminal`; OHOS RustDesk FFI arm64-v8a/x86_64 release builds PASS; native endpoint/protocol suite PASS 976/976, including a real IPv6 `::1` Paramiko SSH fixture and exact file-descriptor reuse isolation.
- 1.1.5 final code/compliance gates: `default@OhosTestCompileArkTS` PASS in 6 s 408 ms; signed `assembleHap` PASS in 8 s 717 ms; `pack.info` is `1.1.5` / `1001005`; signed HAP SHA-256 `d08730dd6cd61e54d15e9abe1023028655e778ae2351ac2a2a4720761ef9737f`; `git diff --check` and Light open-source compliance PASS.
- SBOM root package is `1.1.5` and its document name/namespace are anchored to reviewed release-code checkpoint `fb30744bd8dbda7be355cd8beff87fdb90cab621`.
- `/root/release_115_review` found one P2 hard-coded 10-page count; `fb30744b` replaced it with the registry-derived count and added unit/ohosTest coverage. The reviewer then verified `ce5ab902` as metadata-only and reported final P0=0, P1=0, P2=0 and P3=0. Earlier shared/RDP/VNC/Moonlight, SSH/SFTP and RustDesk reviews remain valid.
- Non-blocking known gaps: Moonlight accepted-to-active synchronous terminal completion has layered common-C/ArkTS coverage but no direct production-runtime barrier fixture; diagnostic family facts do not yet report the resolver's actual winning candidate or fallback stage.

## Next and blockers

- Next: run the 1.1.5 update Swiper layout/interaction matrix and M1-M3 IPv6 literal, AAAA-only, dual-stack fallback, discovery/control-data, reconnect, trust and SFTP matrices on HarmonyOS Phone/Pad/PC.
- RustDesk M4 release acceptance requires fixed-version hbbs/hbbr and controlled-peer coverage for symmetric NAT, CGNAT, UDP-blocked, TCP-only, global/IPv6-only, NAT64 and relay fallback before enabling any gated capability.
- Blocker: `hdc list targets` returned `Connect server failed`; no target or controlled IPv6/AAAA-only/NAT64/VPN protocol endpoints were available. This blocks device/release acceptance, not the locally verified 1.1.5 package checkpoint.
- Older RDP high-DPI, gesture/settings, bindSheet, RustDesk quality/multimonitor and cloud-recovery device matrices remain queued and were not overwritten by this task.
