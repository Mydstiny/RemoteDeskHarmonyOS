# RustDesk UDP/KCP dependency provenance

The RustDesk UDP peer transport uses the same high-level KCP implementation
and wire framing as the audited upstream RustDesk client snapshot. The Cargo
dependency is pinned by revision rather than a moving branch.

## Locked sources

- Upstream client audit snapshot: `rustdesk/rustdesk`
  `03a7fc5992069cc5bc9f7c36b872483dddf4f472`.
- That snapshot's `Cargo.lock` resolves `kcp-sys` to
  `32a6c09fc6223f54aea83981a6aa8995931d29be`.
- Local `rustdesk_ffi/Cargo.toml` pins that same `kcp-sys` revision explicitly;
  `rustdesk_ffi/Cargo.lock` is the build authority.
- The pinned `kcp-sys` revision contains the `skywind3000/kcp` gitlink
  `7f9805887b0909c52c825925f123e7a84da37167`.

Repositories:

- <https://github.com/rustdesk/rustdesk>
- <https://github.com/rustdesk-org/kcp-sys>
- <https://github.com/skywind3000/kcp>

## Integrity and license

- `kcp-sys` git tree: `6b1a953c80e3b58d848d040351b29ac4a2c91041`.
- Deterministic `git archive --format=tar` SHA-256 for that tree:
  `e96aacea7674a1655fc026c8dd4b4b4ebb3c899817fd4f542ef24f5950de398e`.
- bundled KCP git tree: `23cce4ca37e867c47164367eb5b7a72e24dcb6aa`.
- Deterministic KCP `git archive --format=tar` SHA-256:
  `15ccff9f93ab0ad5362c125c3e9922df1fceb0bf62359bdfca01d415651a6d0e`.
- Both upstream components declare the MIT license. Cargo dependency and
  transitive package licenses are emitted into `docs/compliance/SBOM.spdx.json`.

## Build boundary

The pinned crate compiles KCP C source and generates its C ABI with libclang.
On macOS, `scripts/macos_env.sh` supplies the host SDK include for native Cargo
tests. `scripts/build_rustdesk_ffi_ohos.sh` and the DevEco CMake edge override
that value with the OHOS generic and target-specific sysroot includes. Both
arm64-v8a and x86_64 remain required release-build ABIs.

This dependency pin does not enable the product capability. Advertising UDP
mapping or an IPv6 candidate remains fail-closed until the executable transport
and the controlled hbbs/hbbr plus peer device matrix are complete.
