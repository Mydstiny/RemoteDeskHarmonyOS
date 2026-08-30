# FreeRDP OHOS provenance

The application gitlink is the publicly reachable `freerdp-ohos` base
`dae8276ac7361b8d14f7b87d41163fe03dbb944e`, based on upstream
`https://github.com/FreeRDP/FreeRDP`. The effective OHOS source is that base plus
the four ordered patches under `patches/freerdp-ohos/`. Applying the series
must produce Git tree `54cc9b12e3040bba73773a5439d4f8023d46ac7a`; this is the same
source tree formerly represented only by the unpublished local commit
`4d645c86e1fdcc6159b2b3a4c4f652e46985f8ba`. Public base reachability was
verified against the configured repository on 2026-08-30.

The revision adds bounded dual-stack connection handling to the primary RDP
route, redirected target addresses, and RD Gateway transports. Hostname
identity used for TLS, HTTP Host and SPN stays separate from the numeric or
scoped IPv6 peer used for the socket connection. Resolution is bounded by a
process-wide worker cap; candidates are de-duplicated, family-interleaved and
raced under one absolute DNS-plus-connect deadline with cancellation. Losing
sockets are closed and the winning socket is restored to blocking mode.

The checked-in static libraries are produced for `arm64-v8a` and `x86_64` by
`scripts/build_freerdp_ohos.sh all`. The script locks the public base revision,
requires a clean submodule, reconstructs the ordered patch series in its
isolated work directory, and rejects any patched-tree mismatch before CMake is
started. The verified tree is exported without repository metadata so the
static-library revision marker remains the established deterministic `n/a`.
The build then uses deterministic archive ordering, rejects conflict copies
and machine-specific paths, checks the generated
`FreeRDP_GatewayConnectHostname` setting, and verifies required display, drive
and RDPDR symbols. ThinLTO/IPO is disabled because OHOS Clang otherwise embeds
absolute module identifiers despite prefix-map flags.
The build also rejects WinPR archives that reference `pthread_cancel`, which
is not available in the OpenHarmony target libc.

The artifacts recorded here were verified on 2026-08-30 by two clean builds
from different `/private/tmp` roots. Their complete prebuilt trees were
byte-identical. Exact archive hashes are maintained in
`docs/compliance/THIRD_PARTY_ARTIFACTS.sha256`; changing the source revision,
channel set, toolchain or archive contents requires refreshing that inventory
and passing `scripts/tests/test_freerdp_provenance.ps1`.
