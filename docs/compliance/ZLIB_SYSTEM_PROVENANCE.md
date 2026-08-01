# zlib system-library provenance

The VNC ZRLE decoder links to the zlib shared library supplied by the target
HarmonyOS/OpenHarmony API 23 native sysroot. The repository does not vendor,
modify, or redistribute a separate zlib binary for this path.

Production CMake links `libz.so`; host-side native protocol tests resolve
`ZLIB::ZLIB` from the host toolchain. Consequently, the exact runtime version
is controlled by the selected SDK and target system image rather than by a
repository lockfile. A host-test version must not be reported as the device
runtime version.

Release evidence must record:

- the DevEco/HarmonyOS SDK and standalone native SDK versions;
- the target ABI and API level;
- the resolved target sysroot `libz.so` identity or digest;
- the connected device build/version used for interoperability testing.

The applicable license is retained at `LICENSES/Zlib.txt`. If a future build
vendors or statically bundles zlib, that artifact requires a separately pinned
source version, SHA-256 record, SBOM update, and rebuild review before release.
