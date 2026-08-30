# RustDesk desktop flip controls

## Objective

Add a PC-only RustDesk top-bar flip icon. Clicking it opens a compact popup with
exactly five actions: flip image vertically, flip image horizontally, flip the
control layer vertically, flip the control layer horizontally, and reset. The
four axes compose independently and persist per host for later sessions.

## Scope

- Reuse the existing top-bar icon button and popup visual system.
- Replace the old 180-degree rotation workaround with independent visual/control
  X/Y mirrors in both the OES and RAW renderer paths. Migrate old `image_only`
  and `image_and_controls` values to their equivalent two-axis masks.
- Apply the same independent axes to absolute pointer projection, relative
  pointer deltas, control-cursor projection, PIP renderer transfer and canvas
  pan focus preservation.
- Keep the NativeImage producer policy platform-invariant and restricted to
  identity/vertical-origin transforms. Current device evidence proves the same
  Windows label and `flip_y` class can be correct on one HarmonyOS PC graphics
  stack and inverted on another, so selecting identity by remote OS would
  regress the already-correct simulator/device path.
- Restore the mode on connection, renderer rebind and PIP transfer.
- Store the mode in device-local host personalization and portable local backup;
  do not classify it as a cloud-base host mutation.
- Exclude Phone/Pad viewers and runtime RustDesk phone peers. Authenticated peer
  platform wins over stale host metadata, and transient reconnect `unknown`
  diagnostics retain the last authenticated platform within the same session.
- Add focused tests for mode normalization, mapping, layout isolation,
  persistence, backup and peer-platform transitions.

## Official RustDesk evidence

- Upstream issue `#14988` reports a viewer-side 180-degree inversion on a
  texture-rendering path while the reverse viewing direction remains correct.
- Upstream discussion `#14990` records the exact failure of a forced 180-degree
  workaround: vertical orientation becomes correct while left and right are
  mirrored. Therefore 180-degree rotation is not an adequate single-axis fix.
- RustDesk exposes `use-texture-render` as a desktop rendering-path control and
  recommends disabling it when rendering problems occur. A full equivalent in
  this app requires a proven software path for all negotiated codecs; the
  current fallback supports VP8/VP9/AV1 but not H.264/H.265, so silently forcing
  it would break common sessions. The safe current delivery keeps the bounded
  producer policy and adds explicit per-host manual axes without changing
  Phone/Pad or already-correct macOS paths.

## Verification

- `default@OhosTestCompileArkTS`
- signed `assembleHap`
- `git diff --check`
- Light open-source compliance
- independent read-only review
- HarmonyOS PC real-device acceptance remains a delivery follow-up
