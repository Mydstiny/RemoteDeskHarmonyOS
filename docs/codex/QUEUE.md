# Moonlight Complete Upgrade Queue

Updated: 2026-08-10 Asia/Shanghai

## Now

- N1-07: implement only an injected/dormant native Host Control orchestrator.
  Reuse N1-04 for authenticated catalog/asset, launch/resume and explicit quit;
  require precondition/action/postcondition truth, exact generation/cancel/
  deadline, maybe-sent no replay and move-only launch-material zeroization. Do
  not write ArkTS cache or add NAPI/UI/runtime feature truth while the in-HAP
  identity/transport backend remains unavailable.
- Keep `moonlightrecordv1` out of the distributed table list until D2-05/D2-06
  produce development, test and production AGC receipts.

## Next

- N1-08 typed NAPI/Host Service only after N1-07 passes its dormant contract;
  runtime wiring remains independently blocked by the HAP identity/transport
  receipt. No task may create parallel HTTP/TLS/secret ownership.
- D3 cloud deletion terminal execution and remote unpair become callable only
  after D2-07 and the N1 Host Control port respectively.
- U1-S1: unified UI, connection overlays, PIP/background/reconnect/teardown.

## Later

- Real Sunshine/device/network matrix, the one remaining `sol low` review, full
  regression, mandatory Hvigor/Light gates, PR and release rollout.
