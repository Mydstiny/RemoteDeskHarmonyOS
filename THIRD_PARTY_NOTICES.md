# Third-party notices

RemoteDeskHarmonyOS is an AGPL-3.0-or-later combined work. The following
components remain under their upstream licenses; consult the referenced
source and license files before redistribution.

| Component | Source / locked version | License | Local role |
|---|---|---|---|
| RustDesk protocol definitions | rustdesk/rustdesk commit `93d064a9b0eb58ab94db88ff727a877ef773c0d8`, hbb_common gitlink `387603f47cbb15c0d3dc3d67ae3396d3eb707daf`; trailing whitespace removed locally | AGPL-3.0 | `rustdesk_vendor/.../protos` code generation |
| FreeRDP / WinPR | `freerdp-ohos` public-base gitlink `dae8276ac7361b8d14f7b87d41163fe03dbb944e` plus the ordered local patch series in `patches/freerdp-ohos/`; effective tree `54cc9b12e3040bba73773a5439d4f8023d46ac7a`; upstream FreeRDP | Apache-2.0 | RDP protocol/static libraries |
| OpenSSL | bundled build inputs/artifacts under `libs/openssl` | Apache-2.0 | TLS and cryptography |
| FFmpeg | 8.1.2 source archive and bundled OHOS artifacts; see `docs/compliance/FFMPEG_OHOS_PROVENANCE.md` | LGPL-2.1-or-later; GPL/non-free components disabled | VP8/VP9/AV1 software decode fallback |
| libssh2 | bundled source/artifacts; upstream COPYING retained | BSD-3-Clause | SSH/SFTP |
| Mbed TLS | bundled artifacts under `libs/mbedtls` | Apache-2.0 | cryptography support |
| Opus | built by `scripts/build_opus_ohos.sh` | BSD-3-Clause | RustDesk audio decode |
| zlib | platform/API 23 system library; see `docs/compliance/ZLIB_SYSTEM_PROVENANCE.md` | Zlib | VNC ZRLE and FreeRDP compression |
| Rust crates | versions locked in `rustdesk_ffi/Cargo.lock` | per-crate, recorded in SBOM | RustDesk bridge and terminal support |
| Alacritty terminal | `alacritty_terminal` `0.26.0`; crates.io registry; transitive crates are listed individually in the SBOM | Apache-2.0; per-crate licenses for transitives | Rust VT/ANSI terminal state machine |
| `@hw-agconnect/auth` | `entry/oh-package.json5` / lockfile | Huawei package terms | authentication/cloud integration |
| Hypium / Hamock | root package lock | OpenHarmony package terms | tests only |
<!-- MOONLIGHT_VENDOR_NOTICE_BEGIN -->
| moonlight-common-c | https://github.com/moonlight-stream/moonlight-common-c commit `e41355ea01670fd4c830b384009d31dd0339a705`; tree `405b39fdc543dceb7644bdcda65e1bb4c7a28ab2` | GPL-3.0-only | Moonlight streaming protocol core; vendored source only in N1-01; exact original source and license retained under `entry/src/main/cpp/moonlight/upstream/moonlight-common-c` |
| Moonlight ENet fork | https://github.com/cgutman/enet commit `aca87840b57f045a1f7f9299e4b1b9b8e2a5e2f1`; tree `0995d597d91e071eb1e673d93bee797246a00c76` | MIT | common-c pinned reliable UDP transport fork; exact original source and license retained under `entry/src/main/cpp/moonlight/upstream/moonlight-common-c/enet` |
| nanors | https://github.com/sleepybishop/nanors commit `b1e3c22ca0cdc0bb83e3cd6ed1a2fc77869ed99a`; tree `b06686f843269415217ebeb90c8975be297f0d30` | MIT | common-c pinned Reed-Solomon/FEC implementation; exact original source and license retained under `entry/src/main/cpp/moonlight/upstream/moonlight-common-c/nanors` |
<!-- MOONLIGHT_VENDOR_NOTICE_END -->

<!-- MOONLIGHT_ICON_NOTICE_BEGIN -->
| Moonlight Qt official icon | Copyright Moonlight Game Streaming Project contributors; https://github.com/moonlight-stream/moonlight-qt commit `2e13ed9977bc31c73caf8428f08f58d793313ece`; original `app/res/moonlight.svg` SHA-256 `6fd0ee4fe5b4aad5abaa5d5c9acb9f7d1bda0abadfe9d1582115de9b4ba16aa2` | GPL-3.0-only | Deterministic monochrome/tintable transform used only to identify the Moonlight protocol entry; exact geometry, local SHA-256, fallback, attribution and trademark boundary are recorded in `docs/compliance/MOONLIGHT_ICON_PROVENANCE.md` |
<!-- MOONLIGHT_ICON_NOTICE_END -->

<!-- TOTP_BRAND_NOTICE_BEGIN -->
| Simple Icons TOTP brand batch | `simple-icons@16.21.0`; https://github.com/simple-icons/simple-icons/tree/16.21.0 | CC0-1.0 | 251 local community glyphs under `entry/src/main/resources/rawfile/totp-brands/`; per-asset source, revision, SHA-256 and trademark guidance are authoritative in `entry/src/main/resources/rawfile/totp_brand_manifest.json`; these community glyphs are not asserted to be official logos. 67 exact login domains and 279 reviewed issuer aliases are recorded separately; unproven domains remain empty. |
| TOTP reviewed supplier/logo overrides | Reviewed local assets listed in `officialOverrides` within `totp_brand_manifest.json`; per-asset source, SHA-256 and trademark guidance are authoritative there | 29 reviewed override assets; catalog vectors are labeled separately from official assets; use is limited to supplier identification and remains subject to each brand's trademark rules. |
<!-- TOTP_BRAND_NOTICE_END -->

Artifact hashes are generated in `docs/compliance/THIRD_PARTY_ARTIFACTS.sha256`.
A component with an unknown source, license, or hash is a release blocker.
