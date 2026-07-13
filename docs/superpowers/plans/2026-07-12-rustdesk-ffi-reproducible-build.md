# RustDesk FFI Reproducible Build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every HarmonyOS native build consume a current, ABI-correct RustDesk FFI static library and fail with actionable diagnostics when a required local build input is absent.

**Architecture:** The two RustDesk protobuf definitions become project-owned FFI inputs rather than files hidden in an ignored upstream clone. CMake models each ABI's Rust static library as an output of Cargo, so Rust source or protocol changes rebuild before the C++ linker runs. A checked build script prepares Opus and both FFI ABIs; signing material remains local-only.

**Tech Stack:** CMake, Cargo/Rust 1.96, HarmonyOS NDK, libopus 1.5.2, PowerShell/Git Bash.

## Global Constraints

- Preserve RustDesk wire compatibility by retaining the exact `message.proto` and `rendezvous.proto` revisions currently used by the FFI.
- Build both `aarch64-unknown-linux-ohos` and `x86_64-unknown-linux-ohos` before signing a HAP.
- Never commit private signing material, passwords, or machine-specific certificate paths.
- Treat a missing local Opus archive as a configuration error with an exact recovery command.

---

### Task 1: Make FFI protocol input source-controlled

**Files:**
- Create: `rustdesk_ffi/protos/message.proto`
- Create: `rustdesk_ffi/protos/rendezvous.proto`
- Modify: `rustdesk_ffi/build.rs`

- [ ] Copy the exact currently validated RustDesk protocol definitions into `rustdesk_ffi/protos/`.
- [ ] Change `build.rs` to resolve protocol files from `CARGO_MANIFEST_DIR/protos` and emit Cargo rerun markers for both files.
- [ ] Run a Cargo build with a known ABI-specific `OPUS_LIB_DIR`; expect generated protobuf output and no vendor-clone path dependency.

### Task 2: Make native builds rebuild FFI outputs

**Files:**
- Modify: `entry/src/main/cpp/CMakeLists.txt`
- Create: `scripts/build_rustdesk_ffi_ohos.sh`
- Modify: `scripts/build_opus_ohos.sh`

- [ ] Add a CMake custom output/target for each selected OHOS ABI that invokes Cargo with `OPUS_LIB_DIR`, and make `rdpnapi` depend on it.
- [ ] Add preflight validation for the selected `libopus.a` and exact recovery instructions.
- [ ] Add a two-ABI script that downloads or reuses a checksum-verified Opus archive, builds Opus when needed, builds Cargo outputs, and checks exported FFI symbols.
- [ ] Touch a Rust FFI input, invoke the native build, and verify Cargo runs before native linking.

### Task 3: Keep signing local and validate packaging

**Files:**
- Modify: `.gitignore`
- Create: `build-profile.example.json5`
- Modify locally only: `build-profile.json5`

- [ ] Remove the local signing profile from Git tracking while retaining it on disk.
- [ ] Add a credential-free example and ignore the actual local profile.
- [ ] Correct the local certificate path without exposing any credential values.
- [ ] Run `assembleHap --no-daemon`; expect native compile/link, package, packing check, and signing to succeed.
