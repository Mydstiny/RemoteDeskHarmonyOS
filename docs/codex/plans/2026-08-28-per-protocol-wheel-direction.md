# Per-protocol wheel direction plan

## Goal

Replace the shared RDP/RustDesk/VNC wheel-direction toggle with one editor that
selects wheel reversal independently for RDP, RustDesk, SSH, VNC and Moonlight.
Every graphical protocol must apply the selected direction to physical mouse,
physical touchpad and virtual-touchpad wheel traffic at its final wire boundary.
SSH applies the preference to terminal wheel/alternate-buffer/mouse-tracking
traffic while local SFTP lists retain the platform direction.

## Compatibility contract

- Keep `rustdeskReverseWheel` as the RustDesk key so an existing RustDesk
  preference is never lost.
- Add device-local `rdpReverseWheel`, `sshReverseWheel`, `vncReverseWheel` and
  `moonlightReverseWheel` keys plus a versioned migration marker.
- On first migration, an explicitly stored legacy `rustdeskReverseWheel` value
  seeds RDP, RustDesk and VNC because those protocols currently share it.
- When that legacy key is absent, the old VNC settings payload may seed only
  VNC. SSH and Moonlight remain normal because the old toggle never controlled
  them.
- Existing per-protocol keys always win and migration is idempotent. All wheel
  keys remain device-local and never enter the generic cloud usersettings
  allowlist.

## Implementation

1. Add a pure wheel-preference policy for keys, migration, protocol lookup and
   the settings-row summary. Cover it with focused Hypium tests.
2. Add a settings leaf route and a reusable five-row editor with draft state,
   cancel, reset-to-normal and save actions.
3. Replace the inline normal/reverse chips in Display & Interaction with an
   action row that opens the editor and summarizes the reversed protocols.
4. Route RDP, RustDesk and VNC through their own AppStorage values in
   `RemoteDesktop`; reset wheel accumulators when the active protocol's value
   changes. Keep the RDP control center, RustDesk top bar and VNC input editor
   synchronized with the same protocol-specific key.
5. Apply Moonlight direction after source normalization for both physical-axis
   and virtual-trackpad scroll requests.
6. Apply SSH direction inside the xterm document before xterm consumes a wheel
   event so scrollback, alternate-buffer translation and negotiated mouse
   tracking retain xterm's protocol semantics. SFTP list scrolling is excluded.
7. Update route, cloud-locality and wiring tests and register all new tests in
   both unit-test entry lists.

## Validation

- Focused policy tests through `default@OhosTestCompileArkTS`.
- `git diff --check` and Light open-source compliance.
- Mandatory `default@OhosTestCompileArkTS` and signed `assembleHap` gates.
- Independent sub-agent review against this plan and the user request; fix and
  re-run gates for any finding.
- Device acceptance: toggle one protocol at a time and verify the other four
  remain unchanged. Exercise RDP/RustDesk/VNC mouse, physical touchpad and
  virtual touchpad; Moonlight physical/virtual paths; SSH scrollback,
  alternate-buffer and mouse tracking; confirm SFTP lists remain local.
