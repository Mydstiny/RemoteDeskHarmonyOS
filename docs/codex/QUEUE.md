# Moonlight Complete Upgrade Queue

Updated: 2026-08-10 Asia/Shanghai

## Now

- N1-03: implement and test the native `MoonlightSessionOwner`: one process-wide
  common-c operation lane, exact session/generation/owner token, cancellation,
  callback/worker leases and fail-closed stop/drain. Keep NAPI and UI off.
- Keep `moonlightrecordv1` out of the distributed table list until D2-05/D2-06
  produce development, test and production AGC receipts.

## Next

- N1-04 onward: host control, secure identity, pairing, media and input after
  each prior gate.
- D3 cloud deletion terminal execution and remote unpair become callable only
  after D2-07 and the N1 Host Control port respectively.
- U1-S1: unified UI, connection overlays, PIP/background/reconnect/teardown.

## Later

- Real Sunshine/device/network matrix, the one remaining `sol low` review, full
  regression, mandatory Hvigor/Light gates, PR and release rollout.
