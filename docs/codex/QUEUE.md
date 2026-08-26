# Moonlight Complete Upgrade Queue

Updated: 2026-08-26 Asia/Shanghai

## Moonlight unclassified host-card parity

- Implemented and committed in `ce309559`: one unclassified RemoteHost/VNC/Moonlight card sequence, legacy order compatibility, common swipe/desktop actions, lock-gated full Moonlight edit Sheet, unified long-press multi-select/batch delete and cross-protocol drag ordering.
- Focused policy/service cases cover mixed and legacy order, filtered-card slot preservation, cross-protocol moves, collision-proof selection keys, full editable Moonlight persistence, order persistence and pairing-identity fencing.
- Exact ArkTS test compile, signed HAP assembly, diff check and Light compliance pass on 2026-08-25. Signed HAP SHA-256 is `fcd0dbddf0bf0ef9349ae86794b2ebb55fbae888162baabb25e7e09015c12a95`.
- Remaining acceptance: install the checkpoint when a Phone/Pad HDC target is available and exercise add/read/edit/lock/delete, long-press select-all/batch delete, cancel/commit reorder and Moonlight↔other-protocol drag movement. No HDC target was online at closeout, so runtime UI acceptance remains pending.

## Concurrent RustDesk persistence repair

- Implemented in the current uncommitted tree: background-safe in-memory RustDesk auth drafts, owner/device-local peer-2FA binding persistence and legacy migration, serialization/backup scrubbing, transactional endpoint/delete cleanup, and authoritative KeyVault snapshot gating so startup/scope-transition/read-failure emptiness cannot delete a persisted binding.
- Audited adjacent host mutation paths: RustDesk authentication handoff, SSH trust/passphrase/public-key switching, RDP credential CRUD, host lock/delete/bulk delete/group/direct-port updates and general Preferences writes now stop, rollback or display an explicit partial-save warning instead of claiming success after a failed write.
- Exact ArkTS test compile, signed HAP assembly, diff check, Light compliance and official HAP signature verification pass on 2026-08-23; isolated installed HAP SHA-256 is `f308ac7eee0adba1bdda0ae4e20639da928a30e9f1863f812e06d629e204eea7`.
- The exact package was installed with existing data preserved and started successfully on physical `SGT-AL10` (`192.168.3.235:38451`); the user confirmed password background/foreground retention.
- Remaining acceptance: create one new peer-2FA binding (the faulty prior build already deleted the old record), then verify background/process-relaunch readback on the target device. Device Hypium remains blocked by unregistered task `00306054`; independent review/isolated commit are still required before merge.

## Concurrent RustDesk view-only compatibility repair

- Implemented and committed in `1d07fed6`: consume remote `PermissionInfo`, enforce keyboard/clipboard/file denials, publish read-only diagnostics, and allow rate-limited video refresh after any initial frame even when the Windows session has no audio.
- Focused Rust permission/starvation tests, Rust compile, exact ArkTS test compile, signed HAP assembly, diff check and Light compliance pass on 2026-08-25.
- Remaining acceptance: reproduce against the reporter's custom Windows 1.4.9 fork after its CM lifecycle is corrected, confirm `仅查看` and continued frames beyond three seconds, and obtain independent review before merge. The reporter owns the separate CM fix.

## Concurrent RustDesk Windows presentation and session-control alignment

- Implemented in `6132ec0dc` and review remediation `3c10f8b4`: authenticated Windows PC hardware sessions apply the producer transform before the first frame, macOS/Linux and non-PC/software/Moonlight paths remain unchanged, and PC top-bar actions share the Phone/Pad rail's canonical content and styling.
- Rust `188/188`, host native `806/806`, exact ArkTS test compile, signed HAP assembly, diff check and Light compliance pass on 2026-08-26. Independent final review is P0/P1/P2 all zero; P3 contains only non-blocking deterministic test-coverage improvements.
- Remaining acceptance: install the current signed package and verify Windows output is upright through connect/reconnect/recovery while macOS remains upright; compare PC top bar with Phone/Pad rail for action order, wording, icons, disabled state, collapse behavior and glass treatment.

## Concurrent multi-protocol session-control visibility and collapsed-state parity

- Implemented in `5d4716b3`, review remediation `7d624600` and final Moonlight runtime remediation `26235ce5`: RDP/RustDesk/VNC/Moonlight PC collapsed controls share the rotated Phone/Pad rail geometry and glass treatment at `y=0`; Settings → Display & Interaction durably hides the selected protocols' real control bars, with legacy RustDesk/VNC migration and protocol-specific accessibility labels. Moonlight also dismisses an already-open control-center Sheet when hidden without dismissing connect, controller or stop Sheets; focused policy cases cover preference precedence and this exact predicate.
- Exact ArkTS test compile, signed HAP assembly, diff check and Light compliance pass on 2026-08-26. Signed HAP SHA-256 is `cc9de3eb32222cf59da55023b11d5fcdf2d55d7b94783295e0a52702ed33d5ff`; final independent review is P0/P1/P2/P3 all zero. Remaining acceptance on a PC/freeform HDC target must verify that all four collapsed handles touch the physical top edge with no black seam, match the rotated Phone/Pad rail and that every per-protocol switch hides/restores the correct live bar; no HDC target was online at closeout.

## Concurrent VNC preflight alignment repair

- Implemented in the VNC preflight alignment commit: one HostList-owned lock/certificate-or-plaintext/credential flow for every device class, no password UI on RemoteDesktop, one-shot settings/add credentials without duplicate prompting, HostList-owned native auth retry, and endpoint/account-bound credential/plaintext handoffs.
- Exact ArkTS test compile, signed HAP assembly, diff check and Light compliance pass on 2026-08-24; final independent review is P0/P1/P2/P3 all zero.
- Remaining acceptance is real-device interaction for saved, one-shot, explicit no-password, plaintext, TLS first-trust/change and auth-retry cases. The implementation is isolated with hunk-level staging from the overlapping user-owned edits in the same large pages.

## Closed in committed checkpoints

- `9eadb35be`: physical-controller runtime hardening, independent arrival/state sequencing, slot-0 controller launch contract and ArkTS/native readiness truth.
- `326f329f5`: Sunshine discovery, Host API/pairing/catalog/launch, common-c RTSP/media/input runtime and clean lifecycle hardening.
- `348b28083`: local launch/settings/FAB/data-flow closeout.
- `aff7fdf03`: lifecycle/recovery, PC session-window integration, compatibility-first optional cloud path, exact teardown and final PC Moonlight FAB unification.
- `2d9ce0024`: enable the explicitly confirmed deployed `moonlightrecordv1` schema at revision 1 and prepare the cloud-enabled acceptance package.
- `2c9120e98` + `94fa21f8f`: adaptive phone/Pad/PC first-run and settings guidance, protocol-local operation lessons, five-protocol connection preparation, foreground-safe SSH/Moonlight hints and review remediation.
- `4739e67ac` + `ef836f38d` + `20bc9d60` + `232f18b9`: persist automatic guidance as once-ever by default, add the Tutorial “always show” control, expand SSH/Moonlight lessons, and fence SSH/Moonlight/RDP/RustDesk/VNC prompts by exact live session across page rebuilds. Final independent review is P0/P1/P2/P3 all zero.
- `6abd75469`: route PC/2in1 VNC settings connections back through HostList's lock, certificate, authentication and independent-window path while retaining Phone/Pad navigation.
- `2c1132385` + `c2478e484` + `a8845458`: add RDP LAN search and require LAN-discovered RDP/RustDesk hosts to choose static cloud-sync or dynamic local-only/auto-refresh policy, with owner fencing, strict RDP recognition and independent P0/P1/P2/P3-zero review.
- `27c3b786` + `c8569d8f` + `10a0c25f`: replace the standalone modifier FAB with session-rail entry across RDP/RustDesk/VNC/Moonlight, add switchable Windows/macOS catalogs, function/navigation/custom shortcuts and official regular-app-safe HarmonyOS virtual-keyboard settings, then close touch-boundary, drag, landscape/IME reachability and VNC avoidance findings. Final independent review is P0/P1/P2/P3 all zero.
- RustDesk-style FAB/add flow, adaptive phone/PC Moonlight host surfaces, six owned settings sheets, metered launch admission, local repository/cache and all input classes are wired.

## Non-cloud closeout

- Product wiring is complete for discovery/verify/pair/trust/save, host detail/catalog/launch, H.264/Opus, keyboard/pointer/touch, virtual and physical-controller ingress, reconnect, Surface/PIP/background audio and explicit stop/quit.
- Local lifecycle is complete for settings readback, host rename/forget/unpair, cache cleanup, crash-recovery choices, local-data deletion and secure-identity deletion with owner/account/generation fences.
- Exact compile and assemble pass on a clean staged-index export; signed HAP SHA-256 is `4b239974cd8c46377ff17b7dfa0a85dab571e6667df7cccb8686e16428dc657c`. Host native outside the restricted sandbox is `780/780` PASS; dual-ABI GameControllerKit isolation and pinned-vendor reconstruction pass.
- PC big-screen Moonlight now uses the same shared bottom `+` FAB as the other host categories; the duplicate top text button has been removed.
- Shared native teardown now uses exact session/generation/owner-token/facade ownership and explicit synchronous Complete/Failed receipts. HostList preflight/2FA cancellation, timeout, error and NAPI retry retain the original immutable identity; the A→B delayed-callback regression is compile-registered and final focused review is P0/P1/P2/P3 all zero.
- The revision-1 package is installed and started on phone simulator `127.0.0.1:5555` and PC simulator `127.0.0.1:5557`; fresh screenshots and Sunshine/physical-controller/long-run acceptance remain pending.
- The final guidance review is P0/P1/P2/P3 all zero after closing device-init timing, blocked-hint retry, 480vp Sheet reachability and protocol-localization findings. Exact test compile, assemble, diff check and Light compliance pass on 2026-08-22.
- The persistent visibility follow-up review is P0/P1/P2/P3 all zero after closing exact-session, page-rebuild, successful-presentation marker and unknown SSH generation findings. Exact test compile, assemble, diff check and Light compliance pass on 2026-08-23; device `ohosTest` remains blocked by unregistered task `00306054`.
- The VNC settings-handoff review is P0/P1/P2/P3 all zero; exact test compile, assemble, diff check and Light compliance pass for `6abd75469` before later unrelated Sheet-policy working-tree changes appeared.
- The LAN address-policy review is P0/P1/P2/P3 all zero. Exact ArkTS compile, signed HAP assembly, diff check and Light compliance pass for `a8845458`; device `ohosTest` remains blocked by the unregistered `00306054` task.
- The remote-keyboard review is P0/P1/P2/P3 all zero at `10a0c25f`. Exact ArkTS test compile and signed HAP assembly pass; the latest package installs and starts on `127.0.0.1:5555`, while live panel drag/touch-through evidence remains blocked behind the existing LoginPage gate.

## Current cloud/data increment

- Additive owner-store v5 migration verifies all three Moonlight tables by ordered name/type/primary-key contract and writes a complete schema fingerprint receipt before advancing the version.
- Existing eight cloud tables are an immutable registration baseline. The optional Moonlight table is registered only as a post-baseline superset and is removed from runtime selection whenever unavailable.
- Durable physical selection force-adds Moonlight once without changing any legacy table choice; logical selection is always the complete portable `settings` / `hosts` / `profiles` set. Runtime registration failure never rewrites either durable selection.
- `reconcile_pending` and `pending_pull` resume deterministically after the same account is activated or the cloud registration is refreshed.
- Automatic Moonlight pulls commit valid rows and redacted quarantines atomically; later promotion/reconcile failures remain restart-repairable and do not falsely claim the committed download was rolled back.
- Manual partial snapshots use non-destructive merge rather than rolling back the whole cloud database. Only a fully valid snapshot can delete selected local rows missing from cloud.
- `30d50967` accepts only the same-owner/same-generation/same-platform-proof canonical→hashed local fallback as a successful rebind, preventing account-coordinator rollback when another account owns the canonical store.
- Real 1.0.7/1.0.8/1.1.1 schema replay, exact ArkTS test compile, signed HAP assembly, diff check and Light compliance pass on 2026-08-26. The 1.1.1 case preserves all 17 seeded tables and exact Moonlight PK contracts across two current migration passes.

## Immediate next

1. Phone upload is live-PASS for all nine business tables, including `moonlightrecordv1 3/3`. Unlock Pad `192.168.3.236:40123`; the exact package is already installed with `-r`, but `aa start` still returns lock-screen error `10106102`.
2. Complete compatibility-first cloud upload/download/delete/conflict/account-switch/crypto-reset tests; bad Moonlight rows must be isolated rather than blocking pulls.
3. When device conditions return, run a true uninstall/reinstall cold start before fresh PC/phone/freeform-window guide and remote-keyboard screenshots plus live panel drag/touch-through acceptance; source/build cold-start hardening is complete but is not a device PASS.
4. On a real DHCP LAN, verify RDP certificate-fingerprint and RustDesk Peer-ID refresh after address changes; manually entered and static-discovered hosts must remain unchanged.

## External gates

- The user explicitly confirmed deployment of the inspected AGC table; revision 1 is enabled. Real registration and transfer receipts remain part of device acceptance.
- Real Sunshine pair/catalog/launch/first-frame/stop, physical-controller, ARM64, network transition and long-run receipts remain pending.
- `ohosTest` task `00306054` is still unregistered.
- The current phone simulator accepts and starts the latest HAP, but its LoginPage gate blocks live connection UI acceptance; old screenshots cannot be reused.

## SSH workbench closeout

- All reported SSH header, sidebar, inspector, status bar, tab chrome, immersive maximize, restored-layout, PC SFTP popup, adaptive new-session/forwarding Sheet, touch terminal/input, connected-session handoff and F6/Shift+F6 focus-cycle defects are implemented in isolated commits through `b9b3db2af`.
- Final API 24 PC/2in1 acceptance passes for page loading, key-auth connection, single-pane restore, immersive maximize, new-session popup, SFTP popup, forward/reverse focus cycling and terminal input after cycling. Exact test compile, signed HAP assembly, diff check and Light compliance pass; installed HAP SHA-256 is `4ce5efbf1daf48dbcfa19657287d9aa713d863248f18fc9bf13357d50bdf1178`.
- API 26 Phone/Pad runtime testing is intentionally deferred at the user's request because no test conditions are available. This is an explicit acceptance deferral, not a claimed runtime PASS and not an open implementation item.
