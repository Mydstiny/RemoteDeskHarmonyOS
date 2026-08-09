# Moonlight Complete Upgrade Queue

Updated: 2026-08-10 Asia/Shanghai

## Now

- N2-01: implement only project-owned pure `MoonlightStreamConfig` requested/
  effective/capability/adjustment value types, deterministic capability
  intersection, same-source launch projection and focused native tests. Keep it
  in a private archive with no common-c wire include, NAPI, RTSP, media/input/UI
  wiring or runtime truth change; `offer_ready` is not `negotiated`.
- Keep `moonlightrecordv1` out of the distributed table list until D2-05/D2-06
  produce development, test and production AGC receipts.

## Next

- N2-02 single common-c adapter and RTSP/callback ownership only after N2-01
  passes its pure offer contract; runtime wiring remains independently blocked
  by HAP identity/transport receipts. No task may create parallel HTTP/TLS/
  secret/session ownership or call RTSP from N2-01.
- D3 cloud deletion terminal execution and remote unpair become callable only
  after D2-07 and the N1 Host Control port respectively.
- U1-S1: unified UI, connection overlays, PIP/background/reconnect/teardown.

## Later

- Real Sunshine/device/network matrix, the one remaining `sol low` review, full
  regression, mandatory Hvigor/Light gates, PR and release rollout.
