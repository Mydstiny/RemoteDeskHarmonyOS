# FreeRDP OHOS provenance

The application gitlink is
`fc914f5eb3c9def5f757469650f5b4cb2ae72cec`, a local OHOS adaptation based on
upstream `https://github.com/FreeRDP/FreeRDP`. Its target publication location
is this repository's `freerdp-ohos` branch, as configured in `.gitmodules`.
This exact revision is not yet recorded as remotely reachable. The checked-in
artifacts therefore remain review-only until it is published; clean-clone
verification, merge to `main`, and release use remain blocked until then.

The revision adds bounded dual-stack connection handling to the primary RDP
route, redirected target addresses, and RD Gateway transports. Hostname
identity used for TLS, HTTP Host and SPN stays separate from the numeric or
scoped IPv6 peer used for the socket connection. Resolution is bounded by a
process-wide worker cap; candidates are de-duplicated, family-interleaved and
raced under one absolute DNS-plus-connect deadline with cancellation. Losing
sockets are closed and the winning socket is restored to blocking mode.

The checked-in static libraries are produced for `arm64-v8a` and `x86_64` by
`scripts/build_freerdp_ohos.sh all`. The script locks the source revision,
requires a clean submodule, builds in an isolated directory, uses deterministic
archive ordering, rejects conflict copies and machine-specific paths, checks
the generated `FreeRDP_GatewayConnectHostname` setting, and verifies required
display, drive and RDPDR symbols. ThinLTO/IPO is disabled because OHOS Clang
otherwise embeds absolute module identifiers despite prefix-map flags.

The artifacts recorded here were verified on 2026-08-30 by two clean builds
from different `/private/tmp` roots. Their complete prebuilt trees were
byte-identical. Exact archive hashes are maintained in
`docs/compliance/THIRD_PARTY_ARTIFACTS.sha256`; changing the source revision,
channel set, toolchain or archive contents requires refreshing that inventory
and passing `scripts/tests/test_freerdp_provenance.ps1`.
