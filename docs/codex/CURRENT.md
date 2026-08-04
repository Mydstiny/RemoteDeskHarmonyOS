# Shared Current State

This file is the compact startup resume card for the active branch. The branch
contains the completed SSH checkpoint and the user-authorized RustDesk host
homepage card follow-on.

## Active Task

- Task: `ssh-terminal-complete-upgrade`
- Base: `main@d2769ad4b`
- Branch: `codex/ssh-terminal-complete-upgrade`
- HEAD: `e877d12c2` (SSH checkpoint plus homepage card implementation committed
  on this same branch)
- Phase: RustDesk host homepage grouped-card implementation reviewed; device
  acceptance remains open
- Scope: user-authorized HostListPage grouped-card UI and strategy tests, while
  preserving the completed SSH checkpoint and existing protocol owners.

## Progress

- WP-T0 diagnostics baseline is implemented: schema v2, payload-free counters,
  ordered timestamp sampling, explicit queue/callback coverage and no per-key
  INFO logging.
- WP-T1 native writer path is implemented: bounded FIFO (256 items/256 KiB),
  reserved control quota (64 items/16 KiB), generation checks, queue-full
  status, teardown admission gate, and paste chunking/ArkTS retry queues.
- WP-T2 working tree now has one session owner reactor: terminal input, reader,
  SFTP, command channels, signal/EOF, PTY resize and keepalive all route through
  one command queue; resize is coalesced and input is drained between 50 ms
  network slices. The legacy read path is non-blocking and no input writer
  thread remains.
- Physical-keyboard/IME policy is in the declared SSH scope: device-aware
  Unicode/CJK/emoji, CapsLock/AltGr, focus and duplicate-change suppression.
- WP-S0 SFTP integrity floor is implemented: 0B upload/download, remote/local
  `.partial` staging, identity-bound resume, fsync/size verification, atomic
  commit and explicit partial retention on cancel/failure. Zero-byte uploads
  explicitly create the remote partial before rename.
- WP-S1 metadata foundation is implemented: bounded SSH-only Task Store,
  mutation-versioned/coalesced durable writes, and fail-closed unknown-size
  records. It is not the complete background task engine or provider layer.

## Homepage Follow-on

- Added the local `groupedHostCards` personalization switch; it is active only
  on Phone, Pad and PC small-window modes.
- PC large-window mode (`isDesktopDevice && breakpoint === 'xl'`) keeps the
  existing left protocol sidebar and categorized host list even when the switch
  is on.
- Added fixed RDP/RustDesk/SSH/VNC projections, RustDesk ID display, conservative
  presence labels, explicit host actions and no swipe actions in grouped mode.
- Phone uses one settings-style card per type; Pad and PC small-window use two
  equal 220vp cards per row. Details stay below the selected row and span the
  content width.

## Verification

- `git diff --check`: passed on `e877d12c2` and after final state preparation.
- Host native tests: `253 passed, 16 failed, 269 total`; all failures are the
  existing VNC TLS fixture startup failures; SSH diagnostics and queue policy
  tests pass.
- `default@OhosTestCompileArkTS`: passed on 2026-08-04 after the homepage
  implementation (warnings only).
- `assembleHap`: passed on 2026-08-04 with `BUILD SUCCESSFUL` and signing.
- `ohosTest@OhosTestCompileArkTS`: blocked; task is not registered (`00306054`).
- Light compliance: blocked by baseline SBOM package
  `totp-reviewed-brand-assets` declaring `NOASSERTION`; no SBOM/dependency
  change was made in this task.
- HDC: no device currently listed; grouped-card geometry, RustDesk presence,
  and Phone/Pad/PC runtime evidence remain unavailable.

## Review

- Review mode: user-authorized concentrated homepage self-review PASS on
  `e877d12c2`; no P0/P1/P2 findings in the reviewed scope.
- The previous SSH self-review PASS remains valid for the committed SSH
  checkpoint; this receipt adds the homepage scope and does not claim an
  independent reviewer or device acceptance.
- No device PASS is claimed: HDC is unavailable and `ohosTest` is unregistered.

## Next

1. Restore HDC for Phone/Pad/PC geometry and RustDesk presence acceptance.
2. Resolve the baseline Light SBOM `NOASSERTION` entry before release checks.
3. Resume WP-S1/S2 durable transfer tasks after this follow-on closes.

## Blockers

- No HDC target is connected, so real-device latency, focus, orientation,
  lifecycle, Pad layout and PC/2in1 drag/drop remain unverified.
- `ohosTest@OhosTestCompileArkTS` is not registered in this project; native and
  default ArkTS compile/build evidence is available instead.
- Light open-source compliance is blocked by the pre-existing
  `totp-reviewed-brand-assets` SBOM `NOASSERTION` license entry.
- A real OpenSSH bastion/ProxyJump and forwarding endpoint is not available;
  those Level B capabilities remain planned/gated and are not enabled here.
