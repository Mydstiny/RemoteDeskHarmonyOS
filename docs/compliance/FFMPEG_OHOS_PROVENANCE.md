# FFmpeg OHOS provenance

- Upstream: `https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz`
- Version: `8.1.2`
- Source SHA-256: `464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c`
- License scope: LGPL-2.1-or-later; GPL and non-free components are not enabled.
- Toolchain: HarmonyOS NEXT API 23 LLVM/Clang, targeting `aarch64-linux-ohos` and `x86_64-linux-ohos`.
- Build entry point: `scripts/build_ffmpeg_softdec_ohos.sh`

The bundled build disables programs, documentation, networking, devices,
filters, formats, swresample, autodetection and all codecs by default. It then
enables only libavcodec, libavutil, libswscale, and the VP8, VP9 and AV1
decoders/parsers. The artifacts are static PIC libraries.

For ARM64, assembly, inline assembly and NEON are enabled. AArch64 Advanced
SIMD is part of the target architecture and is used to restore FFmpeg's VP9
optimized decode path. For x86_64, assembly is disabled so the static archive
can be safely linked into OHOS's shared NAPI library; x86_64 remains an
emulator/scalar fallback ABI. Both targets use `-O3` and the HarmonyOS sysroot.

Artifact hashes are recorded in `docs/compliance/THIRD_PARTY_ARTIFACTS.sha256`
after every rebuild. Any source version, configure flag, enabled component or
toolchain change requires a fresh license review and dual-ABI rebuild.
