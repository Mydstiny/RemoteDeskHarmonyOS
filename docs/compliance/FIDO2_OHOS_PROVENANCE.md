# Debug USB FIDO library provenance

The capability probe uses actual libfido2 1.17.0 and libcbor 0.14.0, compiled
for OHOS `arm64-v8a` and `x86_64`. Exact source URLs, archive SHA-256 values,
patch order and patch SHA-256 are in `FIDO2_DEPENDENCIES.lock.json`.
The repository's pinned archives are build inputs only; Hvigor does not download
source or execute dependency installation scripts.

`scripts/build_fido2_ohos.py` validates archive and patch hashes, rejects unsafe
archive members and builds in a temporary directory. It resolves the installed
OHOS native SDK from an explicit argument, SDK environment or current CMake
cache. Both dependencies use C99, static PIC archives and disabled LTO. The
installed ABI manifests retain compiler/toolchain hashes, all source/patch
identities, generator hash, OpenSSL version/archive/header hashes, target system
zlib hash and every shipped header/library/notice hash. No host paths or private
build configuration are stored in the manifests or archives.

Example rebuild after configuring the local DevEco SDK:

```sh
python3 scripts/build_fido2_ohos.py all --native-sdk "$OHOS_NATIVE_HOME"
python3 scripts/verify_fido2_dependencies.py
```

The local libfido2 patch adds explicit dependency paths and a default-deny
custom-I/O backend. It leaves upstream defaults unchanged unless the new
options are selected. `USE_CUSTOM_IO=ON` uses an empty device manifest and an
open function that always fails. The probe supplies its four I/O functions
explicitly. HIDAPI, PCSC, NFC and Windows Hello are disabled; it never calls
the restricted USB DDK, uses a raw device FD, or opens a device path itself.
Only the ArkTS owner can authorize, inspect and claim the chosen USB interface.

libfido2 links against the existing per-ABI OpenSSL 3.4.1 archive and headers;
CBOR is the separately pinned libcbor archive. zlib is resolved from the target
SDK/system and is not redistributed by this dependency directory. The checked-in
manifests identify the exact cross-build inputs; host OpenSSL versions used by
tests must not be described as device library versions.

Production CMake includes the worker and links these archives only for
`CMAKE_BUILD_TYPE=Debug`. Release retains inert N-API exports, with availability
false, no worker and no libfido2/libcbor link inputs. ArkTS also requires a Debug
build, simulated Pro mode, eligible device/API, no account transition, an active
panel owner, explicit device selection, temporary USB grant and a validated
64-byte unnumbered FIDO HID interface. Claiming never forces detachment.

The probe emits only broadcast INIT and at most two GetInfo requests on the
allocated channel. The second GetInfo verifies a supported FIDO2 version with
the real CBOR parser. No registration, authentication, PIN, reset, credential
management or vendor command is allowed. I/O has native deadlines and request
budgets; cancellation wakes the native worker before library state is freed.

`scripts/tests/test_pro_fido_native.py` builds the same pinned/patched libraries
for a supported host, then runs the production C++ worker and N-API callbacks.
Its host USB replies cover framing, malformed responses, timeout, cancellation
and environment/generation isolation. `scripts/tests/test_pro_usb.cjs` exercises
the production ArkTS service with controlled USB callbacks. These checks do not
establish HarmonyOS USB device behavior, RDP WebAuthn interoperability, PIN UI,
Windows registration/authentication, or production entitlement acceptance.

libfido2's root BSD-2-Clause text and complete leading source copyright/permission
notices (including ISC and public-domain OpenBSD compatibility code) are retained
in each ABI `licenses/` directory. libcbor's full upstream MIT notice is retained
there too. The custom-I/O source is marked BSD-2-Clause. Debug package distribution
must include these notices and the corresponding sources described in
`SOURCE_OFFER.md`.
