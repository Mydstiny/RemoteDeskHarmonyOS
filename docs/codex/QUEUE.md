# RemoteDesk Queue

Updated: 2026-09-19 Asia/Shanghai

## Now

- Overall Pro remainder: [2026-09-19 audit](plans/2026-09-19-pro-remaining.md); M3-M7 exit conditions, UI device/forms and AI acceptance/relay remain open. Immediate work: repair trusted activation after successful real sandbox payment. Original UI and simulation crash repaired; then manual delivery, restart/restore/refund acceptance.

- VNC LastRect: `e67724ac` + `21da46aa` code and independent review PASS; next original failing peer first/repeated updates and reconnect acceptance. [Repair scope](plans/2026-09-08-vnc-lastrect-update-repair.md).

- Pro execution boundary (2026-09-19): earlier network deferral revoked. Original public UI restored; prioritize real-device signed activation, restore and delivery after successful sandbox payment. Security-key testing excluded by latest user steering. Authentication, encryption and independent review remain mandatory.

- RustDesk explicit phone S5: code `f37ecffe` + `b97808f5` independently PASS; next actual Android/HarmonyOS official-client A/B and non-target isolation matrix. [Plan section 10](plans/2026-09-08-rustdesk-explicit-phone-control-parity.md); device details pending, no full-plan completion claim.

- RDP direct touch: accept text caret placement with slight finger jitter, real dragging, long-press right click, mouse in all three modes, keyboard open/closed and zoom after code repair `da9ad958`; device acceptance remains pending.

- File transfer / clipboard: `d3a4500d` implemented scope reviewed; new [RustDesk parity plan](plans/2026-09-08-rustdesk-file-transfer-parity.md) is PLAN_ONLY. Next P0 peer identity/compatibility and P1 system folder/URI validation, then P2-P6; continuous successor files need verified peer binding. Real drag-out is separate. Existing copy-only/shared branch boundaries remain.

- Remote AI UI: [parity cleanup](plans/2026-09-08-remote-ai-ui-parity.md) code `066493a7` independently PASS; next Phone/Pad/PC visual, large-font and keyboard acceptance. New 15 UI regressions plus existing lifecycle/entry checks PASS.

- Remote AI: [AI4 client integration](plans/2026-09-08-remote-ai-client-integration.md) implemented with passing code gates; checkpoint `7bdf00f6` independently reviewed; next actual HarmonyOS pairing/model/LAN and Phone/Pad/PC acceptance. Native v0.3.0 hosts remain released/deployed; RustDesk transport later.

0. Pro M7: vendor protocol, HTTP, CloudDB and signed App client independently reviewed (e3f47078+c5b647ff). Short-session 0b237613 independently PASS; dynamic CRL 78fc9fce independently PASS; native cloud entry cdc193958 and complete AGC package 2e0e7da8+42a0258b independently PASS. 2026-09-19 protected sandbox API and timer-only worker deployed; console401/empty-worker200 PASS, client db981019 pinned to function/public key, Debug installed preserving device data. Native authorization/product/payment passed; signed activation is failing and under investigation; worker remains disabled with manual execution for initial tests. AGC numeric-version publication remains open. Real SDK control-only snapshots, four concurrent transactions and packaged Linux PKIX/API/worker checks PASS; full sandbox deployment completed; notification endpoint pending. AGC test product/key verified and user-specified tester saved; actual IAP device acceptance pending. Public UI redesign withdrawn after user feedback. M6 USB INIT 3ea2859e+ff31ef7d scoped PASS; real libfido2/libcbor capability probe plus a5672b069 CBOR hardening independently PASS; code/provenance/Release gates passed. USB hardware/RDPEWA/PIN and phone authentication remain pending. First M5 direct SSH continuation ed537821+27716d2d+c64efc8e code review PASS; SSH sharing/PC/RDP code is also independently reviewed; actual cross-device/PC knock/icon/UI acceptance remains open.

1. Run one consolidated feedback-batch device acceptance on HarmonyOS PC: Moonlight/RustDesk hardware-decoder flip and four visual/control combinations; RDP transient credentials, fullscreen pointer mapping, resolution negotiation/scaling and black-border behavior; Dock minimize input fencing; RustDesk nested toolbar, explicit H.265 negotiation/hardware decode, codec telemetry and bidirectional clipboard; SSH authentication-before-navigation, compact phone More menu, common commands and adaptive command-editor sizing/keyboard behavior; button-only exit; long classic host list; and the simplified Harmony shortcut settings, including the icon, current-device tab, explicit open/close wording, PC first-use four-protocol default and persistence after manual changes.
2. If a user later reports a flip, export the schema-v5 diagnostic JSONL before reconnecting and use the PC flip menu to mark normal/upside-down/horizontal-mirror orientation. Real-device acceptance is unavailable and does not block the committed repair. Verify it contains one coherent redacted producer class, raw producer matrix, decoder-applied matrix, presentation mode, renderer manual transform, renderer registry generation and decoder binding generation; attach the capture for root-cause classification.
3. Reproduce the intermittent RDP disconnect with Application state, RDP connection and routing/gateway diagnostics selected and matching HDC hilog. Preserve the exact native ErrorInfo or symbolic fallback, transport-end reason, network generation/availability and reconnect timeline. A server `0x10` now requires strict `[E-RDP-ERRINFO-0x00000010]` evidence and means remote Windows DWM crashed; client/network termination displays `E-RDP-SESSION-END-UNCLASSIFIED` instead of fabricating `0x10`.
4. Run per-protocol M1-M3 device acceptance on HarmonyOS Phone/Pad/PC: IPv6 literal, AAAA-only, A/AAAA fallback, scope, save/restart, trust/preflight, real control/data traffic, same-network reconnect and route-generation change. Include RDP direct/Gateway, RustDesk ID/relay/direct/presence/file transfer, SSH direct/proxy/1-3 jump/forwarding/SFTP, VNC direct/repeater/TLS and Moonlight discovery/control/media.
5. Validate the completed RustDesk M4 UDP/KCP state machine against fixed-version hbbs/hbbr and controlled peers across symmetric NAT, CGNAT, UDP-blocked, TCP-only, global/IPv6-only, NAT64 and relay fallback before enabling AUTO, UDP/KCP or `nat_traversal_ipv6`.

## Next

- E2EE: [fault isolation, recovery and legacy compatibility](plans/2026-09-07-e2ee-resilience-legacy-compatibility.md) saved and independently reviewed; implementation awaits user authorization. Preserve healthy functions under partial failure and old enabled-App data; complete E0–E7 without widening to independent protocol encryption or treating the optional off state as a defect.



- Base UI: original rounded layouts restored and basic phone screenshots checked after user rejected the installed redesign. Historical ten-batch code PASS is not visual acceptance. Future accessibility/window fixes must preserve accepted appearance; API23/26 device matrix remains open.

- M5 SSH Share Kit eca8f8aa, PC SSH 3fc4a578 and RDP 35e38224 + 13413239 independently PASS. RDP paired-fence finding closed. Real App Link/fragment, Windows and Phone/Pad/PC cross-device acceptance remain open.

0. Pro M5/M6/M7: proceed with connection sharing/official continuation, USB FIDO2 and phone-passkey feasibility, then trusted production purchase/restore/offline/refunds. ACL/App Linking and backend configuration are not confirmed; production checkout and unaccepted features remain disabled.

1. Triage any consolidated device findings against the committed item boundary; use the schema-v5 generation/matrix chain for flip issues, verify RustDesk H.265 with `preflight config=H265`, `ffiCfg codec=5(H265)` and actual frame `codec=1`, and use the new RDP `source`/`code` classification to identify the original intermittent-disconnect source. Preserve the exact protocol, device type, window mode, decoder and reproduction sequence.
2. Previous code integration is on main@8edc18786; retain the device/topology acceptance items above as follow-up work.

## Later

1. Add a controllable Moonlight ProductStreaming accepted-to-active synchronous terminal barrier regression.
2. Extend network diagnostics from configured/candidate IP family facts to the resolver's actual winning family, owner and sanitized fallback stage.
3. Add real-RDB fault injection, app-clone acceptance and the remaining Android RustDesk orientation/settings acceptance.
