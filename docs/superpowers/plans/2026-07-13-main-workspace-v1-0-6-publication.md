# Main Workspace and Version 1.0.6 Publication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Standardize all future sessions on the main workspace and protected push workflow, align the project to 1.0.6, publish a complete README, and upload only an unsigned HAP to a GitHub draft pre-release.

**Architecture:** Repository instructions, shared exchange files, and Codex memory carry the same canonical workflow. Local pre-push and GitHub branch protection enforce it. Version metadata and documentation are changed in one PR; the artifact is built from merged public `main` and stored only in an unpublished draft pre-release.

**Tech Stack:** Git, GitHub CLI, PowerShell, HarmonyOS Hvigor, Markdown, SPDX 2.3.

## Global Constraints

- The only development workspace is `C:\Users\14288\DevEcoStudioProjects\RemoteDesktop`.
- Start each task from public `main`, then create a `codex/...` feature branch in the same workspace.
- Never use old worktrees/private history, `git push --all`, direct main pushes, or force-push.
- Current application version is `1.0.6` / `1000006`.
- Upload only `entry-default-unsigned.hap`; never upload `entry-default-signed.hap`.
- GitHub publication target is an unpublished draft pre-release `v1.0.6-unsigned.1` until Release mode passes.
- Preserve the three pre-existing untracked plan files and do not stage them.

---

### Task 1: Persist the canonical workspace and push workflow

**Files:**
- Modify: `AGENTS.md`
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\CODEWALK.md`
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\HANDOFF.md`
- Modify: `C:\Users\14288\DevEcoStudioProjects\Mission_transformation\TASKS.md`
- Create: `C:\Users\14288\.codex\projects\C--Users-14288\memory\open-source-git-workflow.md`
- Modify: `C:\Users\14288\.codex\projects\C--Users-14288\memory\MEMORY.md`
- Modify: `C:\Users\14288\.codex\projects\C--Users-14288\memory\remote-desktop-project-state.md`

- [ ] Add the absolute canonical workspace and exact branch/PR/push sequence to `AGENTS.md`.
- [ ] Add the same invariant to CODEWALK and current HANDOFF/TASKS entries.
- [ ] Create focused reusable memory and link it from MEMORY.md; update project state.
- [ ] Search all updated sources for the canonical path, `git push --all`, and `open-source-compliance`.

### Task 2: Align current version metadata

**Files:**
- Modify: `AppScope/app.json5`
- Modify: `entry/src/main/ets/pages/HostListPage.ets`
- Modify: `scripts/generate_sbom.ps1`
- Modify: `docs/compliance/SBOM.spdx.json`
- Modify: `docs/compliance/RELEASE_MANIFEST.example.json`

- [ ] Change the manifest to `versionName: "1.0.6"` and `versionCode: 1000006`.
- [ ] Change current user-facing backup, feedback, and About version strings to `1.0.6`.
- [ ] Change the project package version emitted by `generate_sbom.ps1` to `1.0.6` and regenerate the SPDX document.
- [ ] Update the release-manifest example to the unsigned draft naming without asserting missing approvals.
- [ ] Verify current-version files contain no stale application `1.0.5` strings while preserving historical fixtures and baselines.

### Task 3: Replace the GitHub README

**Files:**
- Modify: `README.md`

- [ ] Document the four protocols, product capabilities, supported platform, and honest maturity limits.
- [ ] Document architecture and repository layout.
- [ ] Document private local configuration, dependency/bootstrap, build, tests, and Light/Release compliance commands.
- [ ] Document the canonical workspace and protected feature-branch/PR workflow.
- [ ] Document license, source offer, security, contribution, and unsigned HAP limitations.
- [ ] Check every referenced repository path exists.

### Task 4: Verify and publish the source PR

**Files:**
- Verify all files changed by Tasks 1-3.

- [ ] Run `git diff --check` and inspect `git status --short`.
- [ ] Run `pwsh -File scripts/verify_open_source_release.ps1 -Mode Light` and require exit code 0.
- [ ] Run the production `assembleHap` command from CODEWALK and require `BUILD SUCCESSFUL`.
- [ ] Confirm the unsigned HAP exists and compute SHA-256; confirm the signed HAP is not staged.
- [ ] Stage only intended repository files, commit, and push the `codex/...` branch.
- [ ] Open a ready pull request, wait for strict `open-source-compliance`, merge it, then return the main workspace to `main` with `git pull --ff-only`.

### Task 5: Create the unsigned draft pre-release

**Files:**
- Upload: `entry/build/default/outputs/default/entry-default-unsigned.hap`

- [ ] Verify the merged `main` commit and rebuild the HAP if the artifact does not correspond to it.
- [ ] Calculate and record the unsigned HAP SHA-256 and byte size.
- [ ] Create an unpublished draft pre-release `v1.0.6-unsigned.1` targeting merged `main` with explicit unsigned/test-only warnings.
- [ ] Upload only `entry-default-unsigned.hap` and verify the draft asset list contains no signed HAP.
- [ ] Keep formal `v1.0.6` and all public tags blocked until Release mode succeeds.

### Task 6: Final handoff

**Files:**
- Modify: Mission_transformation `HANDOFF.md` and `TASKS.md`
- Modify: Codex `remote-desktop-project-state.md`

- [ ] Record final main commit, PR, Actions result, build result, artifact checksum, and draft release URL.
- [ ] Confirm the workspace is back on clean public `main` except the three preserved untracked user plan files.
