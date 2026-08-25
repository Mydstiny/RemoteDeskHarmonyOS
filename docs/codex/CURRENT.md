# Shared Current State

## Active task

- Task: `moonlight-complete-upgrade`
- Base: `main@aeb0cdac5`; branch: `codex/moonlight-complete-upgrade`
- Code checkpoint: `10a0c25f`; the following state-document commit does not change reviewed code.
- Phase: the complete Moonlight implementation remains in device acceptance; the independently reviewed adaptive guidance, durable visibility policy, RDP/RustDesk LAN-discovery address policy and remote virtual-keyboard/shortcut redesign are committed.
- Authoritative plan: `docs/superpowers/plans/2026-07-28-moonlight-harmonyos-complete-upgrade-plan.md`
- Live ledger: `docs/codex/plans/2026-08-09-moonlight-implementation-ledger.md`

## Concurrent RustDesk persistence repair

- The user-requested RustDesk password/2FA persistence repair is implemented in the current working tree without changing the active Moonlight task or overwriting its concurrent edits.
- RustDesk authentication input now survives ordinary background/foreground Sheet reconstruction in a process-memory-only, owner/account-generation/host-fenced draft. Explicit cancel, host deletion, account transition and crypto reset clear the draft; passwords never enter Preferences, AppStorage, cloud rows or backups unless the user selects “remember” and authentication succeeds.
- RustDesk peer 2FA binding now uses a dedicated owner/device-local Preferences store, hydrates only when the endpoint, device and KeyVault entry still match, migrates provable legacy local data once, and is removed transactionally on endpoint change or host deletion. KeyVault separately publishes whether the current account TOTP snapshot is authoritative, so cold start, failed RDB reads and account transitions defer cleanup instead of mistaking “not loaded yet” for a deleted entry. RemoteHost/cloud/backup serialization no longer exports the device-local binding.
- Host/RDP/SSH mutation flows now check persistence results before success UI or connection handoff; failed writes retain the editor where possible, rollback coupled local secrets/bindings, and report partial-success cases explicitly.
- Current uncommitted tree verification on 2026-08-23: exact `default@OhosTestCompileArkTS` PASS, exact signed `assembleHap` PASS, `git diff --check` PASS, Light open-source compliance PASS and official `hap-sign-tool verify-app` PASS. Isolated installed HAP SHA-256: `f308ac7eee0adba1bdda0ae4e20639da928a30e9f1863f812e06d629e204eea7`.
- That exact HAP was installed with data preservation and `EntryAbility` started successfully on physical device `SGT-AL10` at `192.168.3.235:38451`. The user confirmed password background/foreground retention. The earlier faulty build already deleted the old peer-2FA binding, so one new binding is required before interactive background/process-relaunch readback can be accepted.
- Device Hypium execution remains blocked because `ohosTest@OhosTestCompileArkTS` is not registered (`00306054`). The working tree also contains pre-existing overlapping Moonlight/keyboard/SSH edits, so this repair is not committed or merged as an isolated checkpoint.

## Concurrent VNC preflight alignment repair

- The user-reported VNC regression is repaired and isolated for this commit: Phone/Pad and PC/2in1 settings/add-and-connect flows now return to HostList for the same lock → certificate/plaintext-risk → credential preflight before RemoteDesktop is opened. The legacy password Sheet and its state/callbacks are removed from the connection page.
- Explicit no-password, one-shot and saved-password decisions are distinct. Native authentication retry returns to HostList; a saved password is replaced only when a non-empty saved value was actually sent. One-shot credentials and plaintext decisions are process-memory-only, one-shot and bound to endpoint/store/account generation; stale endpoints, account transitions, cancellation and owned attempt aborts fail closed and clear their handoffs.
- Final verification on 2026-08-24: exact `default@OhosTestCompileArkTS` PASS, exact signed `assembleHap` PASS, `git diff --check` PASS and Light open-source compliance PASS. Independent review is P0/P1/P2/P3 all zero.
- Runtime device interaction remains pending. The repair is isolated with hunk-level staging so overlapping user-owned Moonlight/RustDesk/SSH work remains outside this commit.

## Current product boundary

- The former “Moonlight permanently local-only” decision is superseded. Local storage remains the always-available source of truth, while one optional ninth cloud table becomes available after its exact AGC schema is provisioned and the deployment revision is enabled.
- The deployed eight-table cloud baseline is registered first and remains unchanged. `moonlightrecordv1` is attempted only as an optional nine-table superset; optional failure re-asserts the legacy eight-table registration and cannot silently rewrite durable user selection.
- New installs and upgraded installs do not auto-enable Moonlight cloud sync. Physical-table selection and logical `settings` / `hosts` / `profiles` scopes require explicit user consent; private client identity, pairing trust and certificates remain device-local.
- Moonlight download is compatibility-first: the transport may pull the table, then the Moonlight materializer validates rows individually. Valid rows commit, malformed/future/cross-owner rows receive redacted quarantine records, and one bad optional row cannot block the old eight tables.
- A fully valid manual snapshot may replace selected local scopes. A partial snapshot automatically degrades to non-destructive merge, preserving local rows absent from the incomplete snapshot while still applying valid cloud rows.
- Upload remains strict: exact schema, active owner, public record type, selected logical scope and durable mutation-journal proof are required before a physical-table native-first transfer.
- Owner-store v5 adds only `moonlightrecordv1` (19 columns), `moonlightlocalrecords` (20 columns) and `moonlightappcache` (16 columns). Migration is additive/idempotent and advances v4→v5 only after all three exact name/type/PK checks and the full-schema receipt succeed.
- RustDesk-style FAB/add flow, adaptive phone/PC host surfaces, six protocol settings sheets plus one data-management sheet, metered-network launch gate, catalog/launch, H.264/Opus runtime and unified keyboard/pointer/touch/virtual/physical-controller paths are implemented.
- The PC Moonlight directory no longer has a one-off top-right text button. It uses the same shared 64×64 bottom `+` FAB and routing logic as the existing PC host pages.
- Reconnect, Surface/PIP/background audio lifecycle, crash-recovery choices, explicit disconnect-versus-quit, host rename/forget/unpair, local-data deletion and secure-identity deletion are wired through owner/account/generation-fenced production services. Real Sunshine, physical-controller and long-run receipts remain acceptance gates rather than implementation claims.
- GameControllerKit remains activation-time dynamic loading for Moonlight sessions only; unrelated protocols do not gain a mandatory runtime dependency.
- Guidance is layered instead of one long manual: first install stays at seven pages, Settings provides a device/protocol-filtered operation center and five-protocol connection preparation, and SSH/Moonlight add foreground-safe contextual hints. Automatic hints are durably shown once by default; Settings → Tutorial → Operation Guide Center exposes an “always show” switch that permits at most one hint per exact live SSH/Moonlight/RDP/RustDesk/VNC session, including across ArkUI page rebuilds. Security and functional decisions remain repeatable when the live connection requires them.
- VNC connections started from the dedicated settings page now preserve the existing Phone/Pad in-page route, while PC/2in1 returns a credential-free one-shot intent to HostList so lock, certificate, authentication and independent-window ownership remain centralized.
- RDP now exposes LAN search beside the existing address/port entry, and both RDP and RustDesk require LAN-discovered hosts to choose static or dynamic before continuing. Static uses normal cloud sync without address refresh; dynamic remains local-only and refreshes by RDP certificate identity or RustDesk Peer ID. Manually entered hosts retain their previous behavior.
- Remote keyboard controls are now entered from the RDP/RustDesk/VNC/Moonlight session rail rather than a standalone modifier FAB. The translucent panel has an explicit close button, title-bar drag with safe-area/IME clamping, a full-screen transparent hit-test root and a blocking panel body, so only the connection pixels physically under the panel stop receiving touch.
- The session panel supports switchable Windows/macOS shortcut catalogs, complete modifier/function/navigation keys and persisted custom shortcuts. Settings now includes virtual-keyboard controls plus the regular-app-safe HarmonyOS API 23 surface: simple-keyboard mode, current/all/enabled IME and subtype inspection, system IME settings and per-IME detail routing; privileged current-IME switching remains intentionally excluded.

## Latest verification

- Exact `default@OhosTestCompileArkTS`: PASS on 2026-08-23 for the remote-keyboard tree through `10a0c25f` plus preserved concurrent worktree changes.
- Exact `assembleHap`: PASS on the same tree. Signed HAP SHA-256: `39dc57ce3351c1834700fec72053d23475a4cebe45531fc961f46439f0db0ed9`.
- Host native suite outside the socket-restricted sandbox: `780 passed, 0 failed`; this includes the Moonlight product input/runtime tests and the existing adjacent-protocol fixtures.
- `git diff --check` and Light open-source compliance: PASS on 2026-08-23. Pinned Moonlight vendor reconstruction (3 Git trees / 117 exact files) and dual-ABI GameControllerKit ELF isolation also remain PASS.
- Committed checkpoints include `9eadb35be`, `326f329f5`, `348b28083`, `aff7fdf03`, `2d9ce0024`, `2c9120e98`, `94fa21f8f`, `6abd75469`, guidance visibility `4739e67ac`, `ef836f38d`, `20bc9d60`, `232f18b9`, LAN policy `2c1132385`, `c2478e484`, `a8845458`, and remote keyboard `27c3b786`, `c8569d8f`, `10a0c25f`.
- The adaptive-guidance reviewer found four P2s in the first checkpoint (device-init timing, one-shot retry, 480vp reachability and protocol localization). `94fa21f8f` closes all four; final independent review is P0/P1/P2/P3 all zero.
- The persistent-visibility reviewer found exact-session/page-rebuild and success-before-marker edge cases, then one unknown SSH generation edge. `20bc9d60` and `232f18b9` close them; final independent review is P0/P1/P2/P3 all zero for SSH, Moonlight, RDP, RustDesk and VNC.
- The independent VNC settings-handoff review for `6abd75469` is P0/P1/P2/P3 all zero; it verified Phone/Pad routing, PC intent expiry/single consumption, account-scoped host reload and the unchanged HostList security/window path.
- The independent LAN-policy review for `a8845458` is P0/P1/P2/P3 all zero. It verified mandatory post-discovery policy choice, manual-entry compatibility, local-only dynamic persistence/refresh, normal static cloud sync, owner-fenced secrets and strict RDP preflight recognition.
- The reused remote-keyboard reviewer first found missing sidebar checkpoint coverage, landscape reachability, imprecise custom-key grouping and Win/Cmd latch semantics, then found safe-height and VNC rail placement regressions. `c8569d8f` and `10a0c25f` close every finding; final independent review is P0/P1/P2/P3 all zero.
- The reused reviewer closed the final native receipt, immutable facade identity, HostList preflight/2FA retry and A→B anti-misdisconnect findings with P0/P1/P2/P3 all zero. Final cloud/device integration evidence remains pending after AGC deployment.
- Device `ohosTest` remains blocked by unregistered task `00306054`; no device Hypium pass is claimed.
- The exact keyboard HAP was installed and `EntryAbility` started successfully on phone simulator `127.0.0.1:5555`; earlier revision-1 startup also passed on PC simulator `127.0.0.1:5557`. The phone currently remains at the existing LoginPage gate, so no keyboard-panel drag/touch-through device PASS or reused screenshot is claimed.

## Next and blockers

- Immediate: the user explicitly confirmed that the inspected 19-column `moonlightrecordv1` table is deployed. `MOONLIGHT_CLOUD_SCHEMA_DEPLOYED_REVISION` is now 1, admitting the optional-nine registration path while preserving the legacy core-eight-first fallback.
- Compatibility remains the first release gate: Moonlight record-level rejection must never turn into a whole-table/core-eight pull failure, while uploads and destructive operations remain strict.
- Verify real optional registration, core-eight coexistence, old-version upgrade, upload/download/delete/conflict/account-switch/crypto-reset lifecycles, then run one final UI/full-function acceptance pass.
- External acceptance still needs a reachable Sunshine host, physical controller, ARM64 device and long-run/network/lifecycle scenarios.
- Fresh guide-center and keyboard-panel phone/PC/freeform-window visual evidence is still pending. A phone HDC target is online and the latest package starts, but the existing LoginPage gate prevents reaching a live connection; unrelated concurrent Moonlight and SSH worktree changes remain preserved and excluded from these checkpoints/reviews.
- Real-network acceptance should still exercise RDP certificate identity and RustDesk Peer ID across a DHCP address change; this is runtime evidence, not an implementation blocker.

## Concurrent SSH workbench closeout

- The reported SSH workbench UI/runtime defects are closed in isolated commits: unified header menu `ed86fb90b`; responsive sidebar and four-pane readability `ae0eff3ff`, `859e4a278`; responsive inspector/status/tab chrome `cb02c836c`, `9eeca40dc`, `02311fb89`; immersive maximize and one-pane restore `ee448c2dd`, `9325ea71b`; compact tabs and PC SFTP popup `147abc5f3`, `ca091d384`; adaptive new-session/forwarding Sheets `d2e0aa503`, `2314add74`; touch terminal/input and new-session handoff `dae7a8354`, `585571989`, `0b419443a`; F6/Shift+F6 focus cycling `b9b3db2af`.
- Exact `default@OhosTestCompileArkTS`, signed `assembleHap`, `git diff --check` and Light open-source compliance pass for the final SSH tree on 2026-08-23. The installed signed HAP SHA-256 is `4ce5efbf1daf48dbcfa19657287d9aa713d863248f18fc9bf13357d50bdf1178`.
- API 24 PC/2in1 runtime acceptance passes on `127.0.0.1:5557`: the SSH page loads without an ABC fault, key-auth connection reaches a live terminal, system maximize removes the white system title frame, restored workspaces remain one pane, the final new-session selector and SFTP transfer center render as native popups, and terminal input still works after the `title_actions → sidebar → tab_strip → pane_host` F6 cycle and reverse Shift+F6 step. Evidence SHA-256 values are `e6dbc028a2600813dbc90b953f617a763b2d62a8e35ddf6fa449c4e073ddef5e` (terminal/input), `9700b1c7fbf42f477fd39857a09c87fe1a4a410f945cd8a96cdbc4cebe473f47` (new-session popup) and `6eee1600f09aa95ef180ac840c37258abb3383cb53815230f2895cb5204fc924` (SFTP popup).
- Phone/Pad implementation is complete for the single visible xterm owner, stable native Sheet host, focus suspension/restoration and post-disappear host handoff. Per the user's explicit test constraint, API 26 Phone/Pad runtime acceptance is deferred and no API 26 PASS is claimed.
