# Third-party notices

RemoteDeskHarmonyOS is an AGPL-3.0-or-later combined work. The following
components remain under their upstream licenses; consult the referenced
source and license files before redistribution.

| Component | Source / locked version | License | Local role |
|---|---|---|---|
| RustDesk protocol definitions | rustdesk/rustdesk commit `93d064a9b0eb58ab94db88ff727a877ef773c0d8`, hbb_common gitlink `387603f47cbb15c0d3dc3d67ae3396d3eb707daf`; trailing whitespace removed locally | AGPL-3.0 | `rustdesk_vendor/.../protos` code generation |
| FreeRDP / WinPR | `freerdp-ohos` branch, gitlink `dae8276ac7361b8d14f7b87d41163fe03dbb944e`; upstream FreeRDP | Apache-2.0 | RDP protocol/static libraries |
| OpenSSL | bundled build inputs/artifacts under `libs/openssl` | Apache-2.0 | TLS and cryptography |
| FFmpeg | 8.1.2 source archive and bundled OHOS artifacts; see `docs/compliance/FFMPEG_OHOS_PROVENANCE.md` | LGPL-2.1-or-later; GPL/non-free components disabled | VP8/VP9/AV1 software decode fallback |
| libssh2 | bundled source/artifacts; upstream COPYING retained | BSD-3-Clause | SSH/SFTP |
| Mbed TLS | bundled artifacts under `libs/mbedtls` | Apache-2.0 | cryptography support |
| Opus | built by `scripts/build_opus_ohos.sh` | BSD-3-Clause | RustDesk audio decode |
| zlib | platform/API 23 system library; see `docs/compliance/ZLIB_SYSTEM_PROVENANCE.md` | Zlib | VNC ZRLE and FreeRDP compression |
| Rust crates | versions locked in `rustdesk_ffi/Cargo.lock` | per-crate, recorded in SBOM | RustDesk bridge and terminal support |
| `@hw-agconnect/auth` | `entry/oh-package.json5` / lockfile | Huawei package terms | authentication/cloud integration |
| Hypium / Hamock | root package lock | OpenHarmony package terms | tests only |






















































<!-- TOTP_BRAND_NOTICE_BEGIN -->
| Simple Icons TOTP brand batch | `simple-icons@16.21.0`; https://github.com/simple-icons/simple-icons/tree/16.21.0 | CC0-1.0 | 251 local community glyphs under `entry/src/main/resources/rawfile/totp-brands/`; per-asset source, revision, SHA-256 and trademark guidance are authoritative in `entry/src/main/resources/rawfile/totp_brand_manifest.json`; these community glyphs are not asserted to be official logos. 67 exact login domains and 279 reviewed issuer aliases are recorded separately; unproven domains remain empty. |
| TOTP reviewed supplier/logo overrides | Reviewed local assets listed in `officialOverrides` within `totp_brand_manifest.json`; per-asset source, SHA-256 and trademark guidance are authoritative there | 31 reviewed override assets; catalog vectors are labeled separately from official assets; use is limited to supplier identification and remains subject to each brand's trademark rules. |
<!-- TOTP_BRAND_NOTICE_END -->

Artifact hashes are generated in `docs/compliance/THIRD_PARTY_ARTIFACTS.sha256`.
A component with an unknown source, license, or hash is a release blocker.
