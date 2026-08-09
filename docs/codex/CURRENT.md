# Shared Current State

## Active Task

- Task: `privacy-permission-disclosure`
- Base: `main@d840e662a`
- Branch: `codex/privacy-permission-disclosure`
- Phase: verification and checkpoint review.

## Context

- AppGallery reported that the package declares the `user_grant` permission
  `ohos.permission.DISTRIBUTED_DATASYNC`, while the submitted privacy policy does
  not declare it explicitly.
- The signed 1.1.0 App package was verified successfully and must retain this
  permission for Huawei Cloud Space synchronization.
- The canonical, public and in-app policies now explicitly disclose the exact
  permission, trigger, purpose and refusal impact.
- The in-app complete-policy link now targets the dedicated `/privacy/` page,
  which the existing GitHub Pages workflow packages alongside the feedback page.
- Runtime permission declarations, cloud synchronization code and signing
  material were not changed.

## Scope

- Canonical and public privacy policy wording.
- In-app privacy summary and complete-policy URL.
- Existing GitHub Pages packaging workflow.
- AppGallery permission checklist and release guide terminology.

## Verification

- Baseline: clean `main@d840e662a`, equal to `origin/main` on 2026-08-09.
- Final-state `default@OhosTestCompileArkTS`: PASS, exit 0 on 2026-08-09.
- Final-state `assembleHap`: PASS, exit 0, `BUILD SUCCESSFUL in 15 s 326 ms`.
- JSON, workflow YAML, Pages artifact simulation, literal permission and Huawei
  Cloud Space terminology checks: PASS.
- `git diff --check`: PASS.
- Manual shell equivalent of the Light compliance checks, including required
  tracked artifacts, protocol hashes, SPDX metadata and secret patterns: PASS.
- Exact `verify_open_source_release.ps1 -Mode Light`: BLOCKED because this Mac
  currently has no PowerShell 7 (`pwsh`).

## Next

1. Create a checkpoint commit and independently review the declared scope.
2. Install/provide PowerShell 7 and run the exact Light compliance gate before push.
3. Publish the branch, deploy Pages, then use the public privacy URL and exact
   permission-purpose wording in AppGallery.

## Blockers

- PowerShell 7 (`pwsh`) is unavailable, so the required exact Light compliance
  script cannot run locally yet; this blocks finish-check/push, not local review.
