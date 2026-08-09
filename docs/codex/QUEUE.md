# Moonlight Complete Upgrade Queue

Updated: 2026-08-10 Asia/Shanghai

## Now

- N1-05: implement and test the owner-scoped secure identity bridge: deterministic
  non-secret alias metadata, RSA-2048/self-signed client certificate compatibility,
  HUKS/Asset Store capability decision, encrypted-at-rest fallback only,
  shortest-lived OpenSSL lease, locked-memory zeroization and exact inventory/
  deletion/account-barrier behavior. Keep pairing, NAPI/UI, cloud identity and
  feature truth off; no plaintext private-key fallback is allowed.
- Keep `moonlightrecordv1` out of the distributed table list until D2-05/D2-06
  produce development, test and production AGC receipts.

## Next

- N1-06 onward: pairing, callable host control, media and input after each prior
  gate; N1-06 must consume N1-04 requests and N1-05 identity leases rather than
  creating parallel HTTP/TLS/secret ownership.
- D3 cloud deletion terminal execution and remote unpair become callable only
  after D2-07 and the N1 Host Control port respectively.
- U1-S1: unified UI, connection overlays, PIP/background/reconnect/teardown.

## Later

- Real Sunshine/device/network matrix, the one remaining `sol low` review, full
  regression, mandatory Hvigor/Light gates, PR and release rollout.
