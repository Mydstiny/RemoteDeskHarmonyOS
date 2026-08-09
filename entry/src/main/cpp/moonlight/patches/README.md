# Moonlight project patches

N1-01 carries no source patch against moonlight-common-c, ENet or nanors. The
only HarmonyOS build accommodation is a target-scoped Clang diagnostic option
in `../vendor-build/CMakeLists.txt`; the upstream source snapshot remains
byte-for-byte unchanged.

If a later checkpoint needs a source change, add a numbered patch here, record
its upstream base revision and rationale in the Moonlight provenance document,
and apply it only from the project wrapper. Do not modify `../upstream/`
directly.
