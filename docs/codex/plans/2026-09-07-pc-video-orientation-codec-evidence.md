# PC video orientation and codec evidence

## Authorized scope

Repair the RustDesk/Moonlight PC hardware presentation coordinate contract and
H.265 preference/diagnostic gaps. Preserve the PC toolbar's independent manual
visual and control flips, persisted host choices, and Phone/Pad presentation.
Continue the existing checkout/branch; do not stage unrelated Pro/SSH work.

## Evidence and limits

- The September 7 capture identifies build `0f182b5166bb`. It predates the
  `15632691b` preflight H.265 propagation fix already in this checkout.
- RustDesk received H.264 throughout. NativeImage raw/applied matrices remained
  FlipY while the renderer's manual Y changed on/off/on. No HEVC startup failure
  or Moonlight session is present in those captures.
- API 23 NativeImage V2 and OpenHarmony's surface matrix implementation include
  a vertical texture-origin conversion even for a producer without rotation.
- The shared quad uses top-left UVs. PC alone consumes V2. Normalize that input
  basis explicitly (column-major producer matrix multiplied on the right by
  the top-left-to-GL Y conversion), without changing manual/control transforms.
- Earlier simulator evidence required the opposite compensation for the same
  matrix class. This remains a real device limitation, not evidence to erase.
  Keep manual overrides and record both sampling coordinates and user-visible
  orientation observations. No matrix-only claim proves actual pixel direction.

## Implementation

1. Add an explicit top-left NativeImage presentation mode for PC RustDesk and
   Moonlight. Keep valid crop/orientation data; reject non-finite/non-affine
   matrices. Record raw, applied and final manual-composed sampling evidence.
2. Preserve the existing H.265 preflight fix. Expose versioned, fixed-width
   RustDesk evidence for the actual serialized codec preference/capability mask
   and successful/failed sends, separate from current UI preferences and frames.
3. Retain owner-scoped decoder startup stage/native error evidence across a
   failed initialization; expose received/decoded/presented stages, codec changes
   and existing error categories. Export through both protocol capture paths.
4. Extend the bounded, allowlisted JSONL schema. Include local device category,
   control/visual override evidence and an explicit orientation observation
   during capture. No frame pixels, credentials, endpoints or arbitrary errors.
5. Add focused policy/wire/diagnostic regressions, run both Hvigor gates and
   affected ABI checks, then checkpoint commit and independent review.

## Acceptance

The user explicitly requested rapid closure after gates and commit because real
devices are unavailable. Completion requires focused tests, both mandatory Hvigor
gates, affected ABI builds and Light compliance; real-device acceptance is not a
blocker. PC H.264/H.265, manual combinations and Phone/Pad remain unverified runtime
boundaries, to be investigated only if a later capture reports a problem. Logs must distinguish preference not
sent, peer choosing another codec, local decoder startup failure, and presentation
orientation. A client capture cannot prove an unreported server encoder failure;
that boundary must remain explicit. Current branch also contains unfinished Pro
work, so coordinate integration without merging unrelated unfinished changes.


## Export contract (schema 5)

- `runtime.video` carries numbers only, is copied before storage and is checked
  against an exact field whitelist on export. Last four decoder attempts per
  admitted session, 64 attempts process-wide; 8 KiB/event and existing 8 MiB
  capture / 12 MiB export bounds. Device manifest contains only category, API
  level and ABI category, never a device identifier.
- `currentCodecPreference` is the UI setting; `connectionCodecPreference` is the
  connection request. `sentCodecPreference` / `wireCodecPreference` reflect a
  successful direct write. `codecOptionStage`: 1 login write, 2 runtime direct
  write, 3 runtime queue admission. `queuedCodecPreference` and
  `runtimeOptionSubmissions` deliberately do not claim completion of a queued
  socket write or acknowledgement by the peer. Capability masks use frame codec
  bits: H264=0, H265=1, VP8=2, VP9=3, AV1=4. -1 means unknown.
- `firstFrameCodec` / `codecChanges` are RustDesk ingress observations.
  Moonlight keeps its launch codec distinct from `moonlightNegotiatedCodec` and
  `moonlightNegotiatedBitDepth`, read from common-c's admitted selection;
  `moonlightActiveStage` / `moonlightTerminalCode` preserve the adapter's enum
  evidence. No selected codec is fabricated before negotiation.
- Decoder stages: 1 create, 2 callback registration, 3 GL texture, 4 NativeImage,
  5 native window, 6 configure, 7 surface binding, 8 prepare, 9 start, 10 started,
  11 first output callback. Result 0 pending, 1 success, -1 failure. `platformCode`
  is the native return value where available; internal negative fallback values
  identify failures that expose no native code. Output dimensions/pixel format,
  async error count and last async code remain available after codec destruction.
- `finalSamplingCorners` are TL/TR/BL/BR after producer matrix and renderer
  rotation/manual flips. Requested visual flips/version and independent control
  flips are separate from the renderer's applied version, so an in-flight frame
  is distinguishable. Orientation observation 0 unknown, 1 normal, 2 upside down,
  3 horizontal mirror is explicit user input from the PC flip menu.
- A client log cannot identify an unreported remote encoder failure or determine
  pixel orientation without observation. Existing stored flip settings are
  preserved. No account/network/secret configuration is changed.
