# Moonlight Complete Upgrade Queue

Updated: 2026-08-10 Asia/Shanghai

## Now

- N2-02: implement only one hidden `MoonlightCommonCAdapter` around the existing
  `MoonlightSessionOwner`: exact offer→official struct mapping, process-global
  callback routing slot, stage/deadline/termination state machine, negotiated
  codec/audio truth and RI key/IV/RTSP cleanse. No NAPI, ArkTS/UI/cloud, media
  payload or input wiring; negotiated/transport-ready is not first-frame.
- Keep `moonlightrecordv1` out of the distributed table list until D2-05/D2-06
  produce development, test and production AGC receipts.

## Next

- N2-03 video decode-unit bridge only after N2-02 passes callback ownership and
  teardown isolation; it may assemble `DECODE_UNIT/LENTRY` payloads but must not
  yet change UI/release truth or bypass the existing generation-aware decoder.
- D3 cloud deletion terminal execution and remote unpair become callable only
  after D2-07 and the N1 Host Control port respectively.
- U1-S1: unified UI, connection overlays, PIP/background/reconnect/teardown.

## Later

- Real Sunshine/device/network matrix, the one remaining `sol low` review, full
  regression, mandatory Hvigor/Light gates, PR and release rollout.
