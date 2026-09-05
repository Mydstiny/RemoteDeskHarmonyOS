# RemoteDesk Queue

Updated: 2026-09-04 Asia/Shanghai

## Now

1. Run one consolidated feedback-batch device acceptance on HarmonyOS PC: Moonlight/RustDesk hardware-decoder flip and four visual/control combinations; RDP transient credentials, fullscreen pointer mapping, resolution negotiation/scaling and black-border behavior; Dock minimize input fencing; RustDesk nested toolbar, explicit H.265 negotiation/hardware decode, codec telemetry and bidirectional clipboard; SSH common commands; button-only exit; long classic host list; and the simplified Harmony shortcut settings, including the icon, current-device tab, explicit open/close wording, PC first-use four-protocol default and persistence after manual changes.
2. When a flip reproduces, export the schema-v4 diagnostic JSONL before reconnecting. Verify it contains one coherent redacted producer class, raw producer matrix, decoder-applied matrix, presentation mode, renderer manual transform, renderer registry generation and decoder binding generation; attach the capture for root-cause classification.
3. Reproduce the intermittent RDP disconnect with Application state, RDP connection and routing/gateway diagnostics selected and matching HDC hilog. Preserve the exact native ErrorInfo or symbolic fallback, transport-end reason, network generation/availability and reconnect timeline. A server `0x10` now requires strict `[E-RDP-ERRINFO-0x00000010]` evidence and means remote Windows DWM crashed; client/network termination displays `E-RDP-SESSION-END-UNCLASSIFIED` instead of fabricating `0x10`.
4. Run per-protocol M1-M3 device acceptance on HarmonyOS Phone/Pad/PC: IPv6 literal, AAAA-only, A/AAAA fallback, scope, save/restart, trust/preflight, real control/data traffic, same-network reconnect and route-generation change. Include RDP direct/Gateway, RustDesk ID/relay/direct/presence/file transfer, SSH direct/proxy/1-3 jump/forwarding/SFTP, VNC direct/repeater/TLS and Moonlight discovery/control/media.
5. Validate the completed RustDesk M4 UDP/KCP state machine against fixed-version hbbs/hbbr and controlled peers across symmetric NAT, CGNAT, UDP-blocked, TCP-only, global/IPv6-only, NAT64 and relay fallback before enabling AUTO, UDP/KCP or `nat_traversal_ipv6`.

## Next

1. Triage any consolidated device findings against the committed item boundary; use the schema-v4 generation/matrix chain for flip issues, verify RustDesk H.265 with `preflight config=H265`, `ffiCfg codec=5(H265)` and actual frame `codec=1`, and use the new RDP `source`/`code` classification to identify the original intermittent-disconnect source. Preserve the exact protocol, device type, window mode, decoder and reproduction sequence.
2. The user authorized merging before device acceptance on 2026-09-05. Push the reviewed branch, open the PR, pass `open-source-compliance`, merge to `main` and clean the merged branch; retain the device/topology acceptance items above as follow-up work.

## Later

1. Add a controllable Moonlight ProductStreaming accepted-to-active synchronous terminal barrier regression.
2. Extend network diagnostics from configured/candidate IP family facts to the resolver's actual winning family, owner and sanitized fallback stage.
3. Add real-RDB fault injection, app-clone acceptance and the remaining Android RustDesk orientation/settings acceptance.
