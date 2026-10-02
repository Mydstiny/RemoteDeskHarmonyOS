# RemoteDesk Queue

Updated: 2026-10-02 Asia/Shanghai

## Now

- 电脑端 RemoteDesk 插件：Codex/DSH 二维码默认、`remotedesk://pair` 链接回退和 App 解析已实现；本机 Codex/DSH 服务与 loopback 控制面板可达，Claude Code 仅完成 2.1.286 probe-only 骨架，等待独立协议/权限/会话验收后再做功能对齐。

- Pro「诊断与 AI 帮助」全应用 Agent checkpoint `2e6a0c73` 已提交：在 `f4a7ab01` 基础上扩展可回滚 settingProposals 目录（协议音频/剪贴板/驱动器、诊断、显示/输入手势、沉浸光感和主机列表偏好），应用写入前校验实时 AppStorage；TLS、证书预检、地址、凭据、密钥和代理继续排除。`default@OhosTestCompileArkTS` 7.319 s、签名 `assembleHap` 10.295 s 通过；`ohosTest@OhosTestCompileArkTS` 任务 `00306054` 不存在；AI entries 4/4、lifecycle 8/8、final boundaries/races PASS，动作注册 81/81 映射，UI parity 为声明检查 25/26。最新 HAP 已安装到 MatePad Mini 与 Mate 80 Pro Max；真实 Provider/设备/邮件验收未完成，继续保持 experimental。详见[基础计划](plans/2026-10-01-pro-diagnostic-ai-help-upgrade.md)与[账户登录/Coding Plan/UI 计划](plans/2026-10-02-pro-diagnostic-ai-account-coding-plan-upgrade.md)。

- RDP/RustDesk 高级显示计划：[2026-10-01 计划](plans/2026-10-01-rdp-rustdesk-pro-display-resolution-scale-plan.md) 的 P1 运行时闭环已实现，`b69d3c9f` 经 `/root/review_display_final` PASS，并补齐 marker 失败 fail-closed 回归；RDP/RustDesk profile 已按账号×主机×协议×设备隔离，RustDesk 能力/Pro/peer 权限门控保持封闭。编译、assembleHap、显示选择 5/5、Pro entry/runtime、Light/diff/state PASS；ohosTest 为 00306054。下一步是实际 Windows/RustDesk peer/设备矩阵与 Release/PR 验收。

- Pro 工作区与高级主机管理：W0/H1/S1/S2/S3 基础实现已提交准备；继续 H2 分组胶囊/H3 批量操作/H4 导入导出/S3 编辑器/S4 当前会话捕获，并完成设备验收。

- Pro 反馈渠道（613b5126）：当前 session 任务为更新 Pro 反馈的两种二维码；QQ 竖版二维码按原始比例解码，签名 HAP 已部署到三台设备。

- RDP domain connection repair: guarded “跳过连接前证书预检” switch is in `f06bcf620`; `b17d8d90` adds a one-time direct-attempt hint and `d10db1076` unifies successful HarmonyOS DNS candidates with the live direct/transparent FreeRDP transport while keeping hostname certificate identity; validate the direct hostname path and live certificate behavior on a real endpoint.

- Full acceptance step 3 (READY): M3 preset app icon + Pro feature visibility/personalization panel per [checklist](plans/2026-09-27-full-acceptance-checklist.md); then M4 knock transfer, M5 share/continuation, M7 remainder. Remote AI A1-A13 deferred by user. Step-2 fix review PASS (a545277b6..01713b8e8).

- Feedback repair checkpoint: accept exact system shortcuts, bidirectional files/file-station drag, repeated buttons, Pad reverse landscape and PC hardware inversion on devices. [Scope](archive/2026-09/2026-09-23-feedback-repair-checkpoint.md). No target was available at that checkpoint; a target is now connected but not yet used for acceptance. Broad system key capture and PC inversion remain unresolved.

- RustDesk UI feedback follow-up: commit `460f2797` and four-file independent review PASS; host gates pass for stale menu checkmarks, keyboard-linked wheel direction and stuck toolbar Tips. Verify the reported Phone/Pad UI on device; a connected HDC target has not yet been used.

- Current Pad increment: Pro badges + AI card/add/edit/settings parity, gated production wiring and Release default-denial checker independently PASS. Authorized full backup/Debug migration and same-account signed sandbox restore PASS; restart/repeated restore/live settings summary and basic AI device UI checks PASS; remaining actual AI pairing/session and full matrix open. [Evidence](archive/2026-09/2026-09-19-pro-ai-pad-functional.md). Production configuration and worker timer remain off.

- Overall Pro remainder: [2026-09-19 audit](plans/2026-09-19-pro-remaining.md); M3-M7 exit conditions, UI device/forms and AI acceptance/relay remain open. Actual sandbox purchase/auth/activation/manual delivery/restart/restore now PASS. Refund recovery0a4f9c21 and authenticated delivered-order route1c466f39 reviewed. Updated client restore passed; newest Debug installed. API route deployed; actual user refund, signed revocation, restart and repeat restore PASS despite vendor UI timeout. Next: cross-account/offline matrix, notification and numeric version, then production prerequisites. Original UI and simulation crash repaired.

- VNC LastRect: `e67724ac` + `21da46aa` code and independent review PASS; next original failing peer first/repeated updates and reconnect acceptance. [Repair scope](plans/2026-09-08-vnc-lastrect-update-repair.md).

- Pro execution boundary (2026-09-19): earlier network deferral revoked. Original public UI restored; core signed activation, restore and delivery now pass; continue remaining offline/account/device and production prerequisites. Security-key testing excluded by latest user steering. Authentication, encryption and independent review remain mandatory.

- RustDesk explicit phone S5: code `f37ecffe` + `b97808f5` independently PASS; next actual Android/HarmonyOS official-client A/B and non-target isolation matrix. [Plan section 10](plans/2026-09-08-rustdesk-explicit-phone-control-parity.md); device details pending, no full-plan completion claim.

- RDP direct touch: accept text caret placement with slight finger jitter, real dragging, long-press right click, mouse in all three modes, keyboard open/closed and zoom after code repair `da9ad958`; device acceptance remains pending.

- File transfer / clipboard: `d3a4500d` scope remains reviewed; checkpoint `8b58e010` now gives RustDesk remote send/receive a shared explorer with address bar, breadcrumbs, folder/file rows, direct entry and new-folder/refresh actions. `test_transfer_page_ownership.cjs` 37, continuous clipboard 11 and PC remote clipboard 26 pass; device UI and real drag-out/cross-device acceptance remain open. Continue the [RustDesk parity plan](plans/2026-09-08-rustdesk-file-transfer-parity.md) with P0 peer identity/compatibility and P1 system folder/URI validation.

- Remote AI UI: [parity cleanup](plans/2026-09-08-remote-ai-ui-parity.md) code `066493a7` independently PASS; next Phone/Pad/PC visual, large-font and keyboard acceptance. New 15 UI regressions plus existing lifecycle/entry checks PASS.

- Remote AI: [AI4 client integration](plans/2026-09-08-remote-ai-client-integration.md) implemented with passing code gates; checkpoint `7bdf00f6` independently reviewed; next actual HarmonyOS pairing/model/LAN and Phone/Pad/PC acceptance. Native v0.3.0 hosts remain released/deployed; RustDesk transport later.

0. Pro M7: vendor protocol, HTTP, CloudDB and signed App client independently reviewed (e3f47078+c5b647ff). Short-session 0b237613 independently PASS; dynamic CRL 78fc9fce independently PASS; native cloud entry cdc193958 and complete AGC package 2e0e7da8+42a0258b independently PASS. 2026-09-19 protected sandbox API and timer-only worker deployed; console401/empty-worker200 PASS, client db981019 pinned to function/public key, Debug installed preserving device data. Native authorization/product/payment/signed activation/manual delivery/restart/restore passed; worker remains disabled with manual execution for initial tests. AGC numeric-version publication remains open. Real SDK control-only snapshots, four concurrent transactions and packaged Linux PKIX/API/worker checks PASS; full sandbox deployment completed; notification endpoint pending. AGC test product/key verified and user-specified tester saved; actual core IAP device acceptance PASS; actual refund/revocation/restart PASS; remaining offline/cross-account pending. Public UI redesign withdrawn after user feedback. M6 USB INIT 3ea2859e+ff31ef7d scoped PASS; real libfido2/libcbor capability probe plus a5672b069 CBOR hardening independently PASS; code/provenance/Release gates passed. USB hardware/RDPEWA/PIN and phone authentication remain pending. First M5 direct SSH continuation ed537821+27716d2d+c64efc8e code review PASS; SSH sharing/PC/RDP code is also independently reviewed; actual cross-device/PC knock/icon/UI acceptance remains open.

1. Run one consolidated feedback-batch device acceptance on HarmonyOS PC: Moonlight/RustDesk hardware-decoder flip and four visual/control combinations; RDP transient credentials, fullscreen pointer mapping, resolution negotiation/scaling and black-border behavior; Dock minimize input fencing; RustDesk nested toolbar, explicit H.265 negotiation/hardware decode, codec telemetry and bidirectional clipboard; SSH authentication-before-navigation, compact phone More menu, common commands and adaptive command-editor sizing/keyboard behavior; button-only exit; long classic host list; and the simplified Harmony shortcut settings, including the icon, current-device tab, explicit open/close wording, PC first-use four-protocol default and persistence after manual changes.
2. If a user later reports a flip, export the schema-v5 diagnostic JSONL before reconnecting and use the PC flip menu to mark normal/upside-down/horizontal-mirror orientation. Real-device acceptance is unavailable and does not block the committed repair. Verify it contains one coherent redacted producer class, raw producer matrix, decoder-applied matrix, presentation mode, renderer manual transform, renderer registry generation and decoder binding generation; attach the capture for root-cause classification.
3. Reproduce the intermittent RDP disconnect with Application state, RDP connection and routing/gateway diagnostics selected and matching HDC hilog. Preserve the exact native ErrorInfo or symbolic fallback, transport-end reason, network generation/availability and reconnect timeline. A server `0x10` now requires strict `[E-RDP-ERRINFO-0x00000010]` evidence and means remote Windows DWM crashed; client/network termination displays `E-RDP-SESSION-END-UNCLASSIFIED` instead of fabricating `0x10`.
4. Run per-protocol M1-M3 device acceptance on HarmonyOS Phone/Pad/PC: IPv6 literal, AAAA-only, A/AAAA fallback, scope, save/restart, trust/preflight, real control/data traffic, same-network reconnect and route-generation change. Include RDP direct/Gateway, RustDesk ID/relay/direct/presence/file transfer, SSH direct/proxy/1-3 jump/forwarding/SFTP, VNC direct/repeater/TLS and Moonlight discovery/control/media.
5. Validate the completed RustDesk M4 UDP/KCP state machine against fixed-version hbbs/hbbr and controlled peers across symmetric NAT, CGNAT, UDP-blocked, TCP-only, global/IPv6-only, NAT64 and relay fallback before enabling AUTO, UDP/KCP or `nat_traversal_ipv6`.

## Next

- E2EE: [fault isolation, recovery and legacy compatibility](plans/2026-09-07-e2ee-resilience-legacy-compatibility.md) saved and independently reviewed; implementation awaits user authorization. Preserve healthy functions under partial failure and old enabled-App data; complete E0–E7 without widening to independent protocol encryption or treating the optional off state as a defect.



- Base UI: original rounded layouts restored and basic phone screenshots checked after user rejected the installed redesign. Historical ten-batch code PASS is not visual acceptance. Future accessibility/window fixes must preserve accepted appearance; API23/26 device matrix remains open.

- M5 SSH Share Kit eca8f8aa, PC SSH 3fc4a578 and RDP 35e38224 + 13413239 independently PASS. RDP paired-fence finding closed. Real App Link/fragment, Windows and Phone/Pad/PC cross-device acceptance remain open.

- M5 continuation Phone/Pad device acceptance PASS 2026-09-30 for SSH/RDP/RustDesk/VNC (auto arming, per-protocol switches, credential picker, opt-in credential transfer for all four; commits 00644b216..f690e6cf0). Independent review of the continuation/credential-transfer increment is still required before merge. Open: VNC cloud sync on Pad stuck in restore quarantine with only Moonlight selected (device state; verify after re-selection), PC continuation, knock share.

0. Pro M5/M6/M7: proceed with connection sharing/official continuation, USB FIDO2 and phone-passkey feasibility, then trusted production purchase/restore/offline/refunds. ACL/App Linking and backend configuration are not confirmed; production checkout and unaccepted features remain disabled.

1. Triage any consolidated device findings against the committed item boundary; use the schema-v5 generation/matrix chain for flip issues, verify RustDesk H.265 with `preflight config=H265`, `ffiCfg codec=5(H265)` and actual frame `codec=1`, and use the new RDP `source`/`code` classification to identify the original intermittent-disconnect source. Preserve the exact protocol, device type, window mode, decoder and reproduction sequence.
2. Previous code integration is on main@8edc18786; retain the device/topology acceptance items above as follow-up work.

## Later

0. Add a controllable Moonlight ProductStreaming accepted-to-active synchronous terminal barrier regression.
1. Extend network diagnostics from configured/candidate IP family facts to the resolver's actual winning family, owner and sanitized fallback stage.
2. Add real-RDB fault injection, app-clone acceptance and the remaining Android RustDesk orientation/settings acceptance.
