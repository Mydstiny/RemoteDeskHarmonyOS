# Moonlight common-c provenance and isolated build receipt

## Source identity

The N1-01 source snapshot was fetched read-only from the repositories declared
by the pinned common-c `.gitmodules` file on 2026-08-10. The source was imported
with `git archive`; no Git metadata, generated object, or project modification
exists below the vendored root. The root `.gitattributes` marks this boundary
`-text`, preserving upstream bytes such as ENet's CRLF Visual Studio project
instead of silently normalizing them during commit or clean checkout. It also
scopes whitespace diagnostics away from this immutable upstream boundary; the
validator still checks every working-tree and Git-index byte against the lock.

| Component | Official repository | Exact revision | Git tree | Files | Content-manifest SHA-256 | License / SHA-256 |
|---|---|---|---|---:|---|---|
| moonlight-common-c | `https://github.com/moonlight-stream/moonlight-common-c` | `e41355ea01670fd4c830b384009d31dd0339a705` | `405b39fdc543dceb7644bdcda65e1bb4c7a28ab2` | 43 | `63074450596d46d1dc48e80f23f44d6ee909cee8b2a650a6c00fb8fdfefa3cc2` | GPL-3.0-only / `589ed823e9a84c56feb95ac58e7cf384626b9cbf4fda2a907bc36e103de1bad2` |
| Moonlight ENet fork | `https://github.com/cgutman/enet` | `aca87840b57f045a1f7f9299e4b1b9b8e2a5e2f1` | `0995d597d91e071eb1e673d93bee797246a00c76` | 38 | `500e83281fa8546c3ce25b1d1513956ee56035d03af9e2320e26804f1809d2a9` | MIT / `77f94e3be39938801163844b8bf9a4f12badcc0da136e9886e7da14a816d74d3` |
| nanors | `https://github.com/sleepybishop/nanors` | `b1e3c22ca0cdc0bb83e3cd6ed1a2fc77869ed99a` | `b06686f843269415217ebeb90c8975be297f0d30` | 36 | `6e35c00ffe6361ee5fb45fd4c4bc470f94d6ead3596778c633e007f8f3e9b2e0` | MIT / `3fdda5f011d8490331950398e86427d67dfae05e048681476c2c6b8c34bdd033` |

`UPSTREAM.lock.json` is the machine-readable authority. Its manifest digest is
SHA-256 over sorted lines in the form `sha256 *path`, with paths relative to
each component root. `scripts/verify_moonlight_vendor.py` checks all 117 source
files, rejects extra/missing files and Git metadata, and cross-checks the SPDX
SBOM, notice, source offer, license hashes, and artifact-hash inventory. It
also reconstructs all three official Git trees directly from source bytes and
file modes. For the common-c root it inserts the two locked `160000` gitlinks,
so the reconstructed tree binds the archived ENet/nanors commits to the exact
official common-c tree without network or nested repositories. In a Git
worktree the same gate additionally checks every staged/index byte; in a
published source archive it deliberately skips only that repository-specific
index check.

## Project adaptation boundary

The official source is unchanged. `entry/src/main/cpp/moonlight/vendor-build/`
is a project-owned, standalone CMake wrapper that:

- builds only static common-c and ENet targets for `arm64-v8a` or `x86_64`;
- reuses the repository's existing OpenSSL 3.4.1 API 23 archives;
- applies only `-Wno-unused-command-line-argument` to the isolated common-c and
  ENet targets because the OHOS Clang toolchain injects `--gcc-toolchain` and
  common-c promotes that benign diagnostic through `-Werror`;
- has no target, include path, or link edge to `rdpnapi`, NAPI, ArkUI, or any
  existing remote protocol.

`entry/src/main/cpp/moonlight/patches/` is empty except for its policy README.
Any future source patch requires a separate reviewable patch and full lock,
notice, SBOM, hash, build, and source-offer refresh.

## Reproducible verification

Run:

```sh
python3 scripts/verify_moonlight_vendor.py
scripts/build_moonlight_common_vendor.sh
# Windows or cross-platform PowerShell 7:
pwsh -NoProfile -File scripts/build_moonlight_common_vendor.ps1
```

The shell and PowerShell build scripts use HarmonyOS API 23 LLVM/Clang, create
a fresh temporary out-of-tree directory, check both static archives and
required common-c/FEC members, and compare output SHA-256 values with the
machine-readable dual-ABI receipts in `UPSTREAM.lock.json`. Release-mode open
source verification runs the PowerShell build gate; Light mode retains the
offline source/SBOM/tree checks without paying the native rebuild cost. Static
archives are evidence only; they are not copied into `libs/` or linked into the
HAP at N1-01.

At this revision common-c and ENet expose no upstream CMake test target.
nanors does expose `make check`; its unmodified temporary checkout completed
all 6 Perl test files and the two final RS16 batteries successfully on
2026-08-10. The product runtime, Sunshine interoperability, decoder, audio, and
input remain unclaimed and fail closed until their later gates.

## N1-01 API 23 dual-ABI receipt

The following hashes were reproduced by two fresh out-of-tree script runs with
HarmonyOS API 23 Clang 15.0.4 and the repository's OpenSSL 3.4.1 archives.
They are build receipts, not distributed inputs:

| ABI | `libmoonlight-common-c.a` SHA-256 | `libenet.a` SHA-256 | Result |
|---|---|---|---|
| arm64-v8a | `29de0219207d8b022e4d5ab091955c95b32a65d524241de7f5c28d055ab4af78` | `d2b501dd34bea4d9233037089ddf8c91c956edbe73ad56d4d7a6d2290375d1e0` | PASS |
| x86_64 | `67970f8f3ad4a652846165b4af1c942a0da311074a76f3e93af64ad327553666` | `7f79768b2368c59ee83378ccc97386ae26e4a72448d656cf0beff682ee9d51cf` | PASS |
