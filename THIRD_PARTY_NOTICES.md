# Third-party notices

RemoteDeskHarmonyOS is an AGPL-3.0-or-later combined work. The following
components remain under their upstream licenses; consult the referenced
source and license files before redistribution.

| Component | Source / locked version | License | Local role |
|---|---|---|---|
| RustDesk protocol definitions | rustdesk/rustdesk commit `93d064a9b0eb58ab94db88ff727a877ef773c0d8`, hbb_common gitlink `387603f47cbb15c0d3dc3d67ae3396d3eb707daf`; trailing whitespace removed locally | AGPL-3.0 | `rustdesk_vendor/.../protos` code generation |
| FreeRDP / WinPR | `freerdp-ohos` branch, gitlink `dae8276ac7361b8d14f7b87d41163fe03dbb944e`; upstream FreeRDP | Apache-2.0 | RDP protocol/static libraries |
| OpenSSL | bundled build inputs/artifacts under `libs/openssl` | Apache-2.0 | TLS and cryptography |
| FFmpeg | bundled OHOS artifacts under `libs/ffmpeg-ohos` | LGPL-2.1-or-later; build options may activate GPL terms | media decode; verify build flags for every release |
| libssh2 | bundled source/artifacts; upstream COPYING retained | BSD-3-Clause | SSH/SFTP |
| Mbed TLS | bundled artifacts under `libs/mbedtls` | Apache-2.0 | cryptography support |
| Opus | built by `scripts/build_opus_ohos.sh` | BSD-3-Clause | RustDesk audio decode |
| Rust crates | versions locked in `rustdesk_ffi/Cargo.lock` | per-crate, recorded in SBOM | RustDesk bridge and terminal support |
| `@hw-agconnect/auth` | `entry/oh-package.json5` / lockfile | Huawei package terms | authentication/cloud integration |
| Hypium / Hamock | root package lock | OpenHarmony package terms | tests only |

Artifact hashes are generated in `docs/compliance/THIRD_PARTY_ARTIFACTS.sha256`.
A component with an unknown source, license, or hash is a release blocker.
