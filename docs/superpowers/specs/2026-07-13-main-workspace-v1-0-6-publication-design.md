# Main Workspace, Version 1.0.6, and Unsigned Publication Design

## Goal

Make `C:\Users\14288\DevEcoStudioProjects\RemoteDesktop` the only authorized development workspace, make every future Codex session follow the protected open-source push workflow, align the public project to application version `1.0.6` / `1000006`, replace the minimal GitHub README with a complete project guide, and upload only the unsigned HAP as a private GitHub draft pre-release asset.

## Git and session architecture

Every task starts from the clean public `main` in the main workspace and creates a `codex/...` feature branch there. Sessions must never resume development from old worktrees or branches containing the private pre-publication history. Local `.githooks/pre-push` checks the exact pushed commit, and protected GitHub `main` requires the strict `open-source-compliance` check through a pull request.

The rule is stored in three layers: repository-local `AGENTS.md`, the shared Mission_transformation exchange files, and Codex project memory. Local and remote gates remain the enforcement layer if a session overlooks written guidance.

## Version alignment

The application manifest, user-visible version strings, SBOM generator, and generated SBOM identify the project as `1.0.6` / `1000006`. Historical test fixtures, old specifications, and the audited `1.0.5` baseline directory remain unchanged because they describe prior evidence rather than the current application version.

## README structure

The README describes supported protocols and verified product capabilities, HarmonyOS/API requirements, architecture, repository layout, local configuration, complete build commands, tests, open-source compliance, the required contribution/push workflow, security reporting, and unsigned-build installation limitations. It must not claim that pending device/release gates have passed.

## Unsigned artifact publication

Build from the merged public `main`, calculate the unsigned HAP SHA-256, and upload only `entry-default-unsigned.hap` to a GitHub draft pre-release named `v1.0.6-unsigned.1`. The release notes state that the asset is unsigned, test-only, not AppGallery-installable as a production release, and corresponds to an exact public source commit. The signed HAP must never be uploaded.

The draft remains unpublished and creates no public release tag while `credentialsRotated`, `deviceMatrixVerified`, or the private release build profile gate is missing. Formal `v1.0.6` publication remains blocked until Release mode passes.

## Verification

Run version consistency searches, `git diff --check`, the Light compliance gate, version/SBOM assertions, and a fresh production `assembleHap`. Verify the artifact name and checksum, inspect the staged diff, push only the feature branch, merge only after required GitHub checks pass, then rebuild or verify the unsigned HAP from merged `main` before uploading it to the draft release.
