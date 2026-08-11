# Moonlight official icon provenance

## Locked upstream source

- Repository: `https://github.com/moonlight-stream/moonlight-qt`
- Revision: `2e13ed9977bc31c73caf8428f08f58d793313ece`
- Repository tree: `bd12a9a7737cf25744e2141337601a2c9a49bc4d`
- Source file: `app/res/moonlight.svg`
- Source URL: `https://github.com/moonlight-stream/moonlight-qt/blob/2e13ed9977bc31c73caf8428f08f58d793313ece/app/res/moonlight.svg`
- Original SVG SHA-256: `6fd0ee4fe5b4aad5abaa5d5c9acb9f7d1bda0abadfe9d1582115de9b4ba16aa2`
- Source repository license: `GPL-3.0-only`
- REUSE file copyright: `Moonlight Game Streaming Project contributors`
- REUSE precedence: exact-path `override`; the project-wide AGPL annotation does
  not apply to this upstream-derived asset.

## Packaged deterministic transform

- Packaged file: `entry/src/main/resources/base/media/icon_moonlight.svg`
- Packaged SVG SHA-256: `4f5ef547e33767287e3438a6d1598a1bdef6e49df4678a5f7f214ec58c9e5886`
- The upstream `256 x 256` viewBox, outer radius `128`, inner radius `96`, and
  starburst path coordinates are preserved.
- The gray outer circle and white inner circle are represented as one
  even-odd ring with a transparent center. The ring and original starburst
  both use `currentColor`, allowing ArkUI `Image.fillColor()` to tint the
  glyph for light, dark, accent, and disabled states.
- The intrinsic display size is changed to `24 x 24`; no wordmark, new
  geometry, smoothing, tracing, or memory-based redraw is introduced.

The asset identifies the Moonlight protocol entry only. It does not assert
that this application is an official Moonlight client or that the Moonlight
project endorses it. Code-license compliance and trademark authorization are
separate release considerations. If the asset cannot be loaded, the UI falls
back to HarmonyOS `sys.symbol.gamecontroller_fill`.
