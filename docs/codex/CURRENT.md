# Shared Current State

## Active task

- Task: `moonlight-complete-upgrade`
- Base: `main@aeb0cdac5`; branch: `codex/moonlight-complete-upgrade`
- Code checkpoint: `232f18b9`; the following state-document commit does not change reviewed code.
- Phase: the complete Moonlight implementation remains in device acceptance; the independently reviewed adaptive guidance, durable visibility policy and RDP/RustDesk LAN-discovery address-policy increments are committed.
- Authoritative plan: `docs/superpowers/plans/2026-07-28-moonlight-harmonyos-complete-upgrade-plan.md`
- Live ledger: `docs/codex/plans/2026-08-09-moonlight-implementation-ledger.md`

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

## Latest verification

- Exact `default@OhosTestCompileArkTS`: PASS on 2026-08-23 for the guidance visibility tree through `232f18b9` plus preserved concurrent worktree changes.
- Exact `assembleHap`: PASS on the same tree plus final state-document updates. Signed HAP SHA-256: `fa8df1ca75129beca39852390c34b16f47628c1bbb0d761ee4e5673cf28d360b`.
- Host native suite outside the socket-restricted sandbox: `780 passed, 0 failed`; this includes the Moonlight product input/runtime tests and the existing adjacent-protocol fixtures.
- `git diff --check` and Light open-source compliance: PASS on 2026-08-23. Pinned Moonlight vendor reconstruction (3 Git trees / 117 exact files) and dual-ABI GameControllerKit ELF isolation also remain PASS.
- Committed checkpoints include `9eadb35be`, `326f329f5`, `348b28083`, `aff7fdf03`, `2d9ce0024`, `2c9120e98`, `94fa21f8f`, `6abd75469`, guidance visibility `4739e67ac`, `ef836f38d`, `20bc9d60`, `232f18b9`, plus LAN policy `2c1132385`, `c2478e484` and `a8845458`.
- The adaptive-guidance reviewer found four P2s in the first checkpoint (device-init timing, one-shot retry, 480vp reachability and protocol localization). `94fa21f8f` closes all four; final independent review is P0/P1/P2/P3 all zero.
- The persistent-visibility reviewer found exact-session/page-rebuild and success-before-marker edge cases, then one unknown SSH generation edge. `20bc9d60` and `232f18b9` close them; final independent review is P0/P1/P2/P3 all zero for SSH, Moonlight, RDP, RustDesk and VNC.
- The independent VNC settings-handoff review for `6abd75469` is P0/P1/P2/P3 all zero; it verified Phone/Pad routing, PC intent expiry/single consumption, account-scoped host reload and the unchanged HostList security/window path.
- The independent LAN-policy review for `a8845458` is P0/P1/P2/P3 all zero. It verified mandatory post-discovery policy choice, manual-entry compatibility, local-only dynamic persistence/refresh, normal static cloud sync, owner-fenced secrets and strict RDP preflight recognition.
- The reused reviewer closed the final native receipt, immutable facade identity, HostList preflight/2FA retry and A→B anti-misdisconnect findings with P0/P1/P2/P3 all zero. Final cloud/device integration evidence remains pending after AGC deployment.
- Device `ohosTest` remains blocked by unregistered task `00306054`; no device Hypium pass is claimed.
- The exact revision-1 HAP was installed and `EntryAbility` started successfully on phone simulator `127.0.0.1:5555` and PC simulator `127.0.0.1:5557`. No old screenshots are reused; final acceptance still requires fresh PC/phone evidence from this package.

## Next and blockers

- Immediate: the user explicitly confirmed that the inspected 19-column `moonlightrecordv1` table is deployed. `MOONLIGHT_CLOUD_SCHEMA_DEPLOYED_REVISION` is now 1, admitting the optional-nine registration path while preserving the legacy core-eight-first fallback.
- Compatibility remains the first release gate: Moonlight record-level rejection must never turn into a whole-table/core-eight pull failure, while uploads and destructive operations remain strict.
- Verify real optional registration, core-eight coexistence, old-version upgrade, upload/download/delete/conflict/account-switch/crypto-reset lifecycles, then run one final UI/full-function acceptance pass.
- External acceptance still needs a reachable Sunshine host, physical controller, ARM64 device and long-run/network/lifecycle scenarios.
- Fresh guide-center phone/PC/freeform-window visual evidence is still pending because no HDC target was online on 2026-08-23. Unrelated concurrent Moonlight and SSH worktree changes remain preserved and excluded from the guidance checkpoints/review.
- Real-network acceptance should still exercise RDP certificate identity and RustDesk Peer ID across a DHCP address change; this is runtime evidence, not an implementation blocker.
