# Feedback repair checkpoint — 2026-09-23

User authorized implementation after the read-only audit. Continue the existing
`codex/pro-purchase-foundation` branch; preserve its unrelated Pro, receipt and
native declaration changes. This checkpoint is not full five-issue acceptance.

## Implemented

1. Shortcut registration: bounded retry for missing supported system keys,
   owner/epoch isolation, actual active/failed/release-pending status, change
   notifications and a final failure toast. Periodic geometry reconciliation
   cannot bypass the retry budget. Existing durable preference publication and
   focus/modal input guards remain intact.
2. File receive: RDP descriptor wait now exceeds the native 15-second window.
   A completed private batch can retry publication before an OS write, at most
   three times with backoff. A possible OS write or changed source never causes
   a retry overwrite. Unknown native writers remain retained. Directories keep
   the cache/export outcome. RustDesk accepts delayed file-station drops through
   existing staging and explicit transfer; target directory is captured once.
   RDP keeps directory roots. RustDesk mixed directory drops are rejected as a
   whole with an explicit message rather than silently dropping directories.
3. Controls: RDP/Moonlight switches no longer discard changes using stale builder
   values. RustDesk/VNC/Moonlight toolbar keys include current presentation state.
   RustDesk local-cursor preference now changes the overlay/custom-pointer paths.
   Audio/privacy/codec choices explicitly say reconnect is required. Relative
   mouse is unavailable because there is no corresponding transport implementation.
4. Pad/phone: landscape sessions use sensor-based landscape, allowing both device
   directions; desktop and explicit phone-target policy boundaries are retained.
5. Relay cards: endpoint text resolves the current bound relay. Relay endpoint
   revisions invalidate flat and grouped host rendering; direct hosts and legacy
   fallback ports are preserved.

## Verification and review

- Host checks: 33 feedback session checks, 26 PC clipboard file checks, 13 RustDesk
  clipboard client checks and 42 video diagnostics checks passed. Host tests mock
  platform delivery; they are not device interoperability acceptance.
- Required Hvigor commands: `default@OhosTestCompileArkTS` and `assembleHap` with
  `--mode module -p module=entry -p product=default --analyze=normal --parallel
  --incremental --no-daemon`; earlier integrated run passed 30 s 788 ms and signed
  dual-ABI HAP 42 s 950 ms. Final checkpoint rerun is recorded in CURRENT.
- Light compliance and `git diff --check` passed before final checkpoint rerun.
- Independent review: `/root/audit_controls` closed shortcut retry-budget and
  observer findings. `/root/audit_shortcut` reviewed file and UI/relay changes;
  publication retry bounds, ambiguous-write protection, fixed drag target and
  directory regression findings were corrected with regressions. Final closure
  status belongs in CURRENT, not inferred from earlier checks.
- Removed an ineffective RustDesk native reset: authenticated reconnect already
  creates a fresh clipboard engine. Do not reset untagged requests on the same
  transport after timeout; a late response must not become another source.

## Still open

- Broad system combinations (for example Alt+Tab/Meta combinations) are not
  covered by the five-key inputConsumer API. RustDesk currently forwards only
  volume keys from that API. Need the reported exact keys/device version and
  platform capability/profile verification before extending capture. Do not
  equate registration recovery with complete system-shortcut blocking.
- PC hardware-decoder inversion has no fresh producer/applied matrix evidence;
  no speculative global flip was added. Existing schema-v5 capture and manual
  visual/control corrections remain. Need failing protocol/codec, normal versus
  inverted marker, and coherent renderer/decoder generations.
- HDC reported no connected targets. Real bidirectional files, file-station
  drag, repeated toggles, Pad reverse-landscape and PC hardware-decoder tests
  remain unrun. Peer capability, permissions and untagged RustDesk descriptor
  timeout can still prevent reception; this checkpoint is not proof that every
  reported one-way transfer has been eliminated.
- Relative mouse transport and live privacy/audio/codec negotiation are not
  implemented by this checkpoint. Their UI must not claim immediate activation.

Accept on a connected PC/Pad with both RDP and RustDesk: local-to-remote and
remote-to-local files (including zero-byte/Unicode/multiple files), clipboard
replacement during receive, rejection/retry, file-station delayed drag while
switching target folders, repeated controls, both landscape orientations before
and during connection, then reconnect and return from the remote desktop.
