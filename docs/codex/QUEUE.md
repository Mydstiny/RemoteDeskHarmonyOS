# Moonlight Complete Upgrade Queue

Updated: 2026-08-10 Asia/Shanghai

## Now

- N1-06: implement only the injected/dormant native pairing state machine using
  the existing N1-04 Host API and N1-05 identity lease. Cover official SHA-256
  generation-7+ pairing, explicitly bounded legacy SHA-1 compatibility policy,
  server-certificate candidate/trust handoff, challenge verification, signed
  secret, cancellation/timeout and best-effort unpair cleanup. Keep production
  NAPI/UI, trust/cloud persistence and feature truth off while the in-HAP secure
  identity backend remains unavailable.
- Keep `moonlightrecordv1` out of the distributed table list until D2-05/D2-06
  produce development, test and production AGC receipts.

## Next

- N1-07 app catalog/launch/resume/quit, then N1-08 typed NAPI/Host Service, only
  after N1-06 passes its dormant contract and the runtime identity blocker is
  separately resolved; no task may create parallel HTTP/TLS/secret ownership.
- D3 cloud deletion terminal execution and remote unpair become callable only
  after D2-07 and the N1 Host Control port respectively.
- U1-S1: unified UI, connection overlays, PIP/background/reconnect/teardown.

## Later

- Real Sunshine/device/network matrix, the one remaining `sol low` review, full
  regression, mandatory Hvigor/Light gates, PR and release rollout.
