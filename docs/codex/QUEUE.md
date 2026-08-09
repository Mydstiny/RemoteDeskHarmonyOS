# Moonlight Complete Upgrade Queue

Updated: 2026-08-10 Asia/Shanghai

## Now

- N1-08: implement only an independent typed async Moonlight NAPI and ArkTS
  Host Service. Preserve exact native request/generation/owner cancellation and
  bind every ArkTS completion/cache commit to the full account lease. Production
  identity/transport/trust/commit remains unavailable before network; do not
  enable FAB/UI/cloud/media/input or any runtime feature truth.
- Keep `moonlightrecordv1` out of the distributed table list until D2-05/D2-06
  produce development, test and production AGC receipts.

## Next

- N2-01 typed requested/effective stream config only after N1-08 passes its
  fail-closed bridge contract; runtime wiring remains independently blocked by
  HAP identity/transport receipts. No task may create parallel HTTP/TLS/secret
  ownership.
- D3 cloud deletion terminal execution and remote unpair become callable only
  after D2-07 and the N1 Host Control port respectively.
- U1-S1: unified UI, connection overlays, PIP/background/reconnect/teardown.

## Later

- Real Sunshine/device/network matrix, the one remaining `sol low` review, full
  regression, mandatory Hvigor/Light gates, PR and release rollout.
