# Shared Current State

## Active Task

- Task: `privacy-permission-disclosure`
- Base: `main@d840e662a`
- Branch: `codex/privacy-permission-disclosure`
- Phase: locally complete, independently reviewed and ready to publish.

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
- The first independent review found overbroad claims about encryption and
  device-local personalization. The policy now states the actual conditional
  encryption behavior and the old-version cloud compatibility snapshots.
- Refusal/withdrawal impact is now identical in the public policy, in-app
  summary and AppGallery submission wording; stale VNC mock wording was removed.
- Independent remediation review of `0026e4252`: PASS with no P0/P1/P2/P3
  findings; receipt `privacy-permission-disclosure-pass-2026-08-09`.

## Scope

- Canonical and public privacy policy wording.
- In-app privacy summary and complete-policy URL.
- Existing GitHub Pages packaging workflow.
- AppGallery permission checklist and release guide terminology.

## Verification

- Baseline: clean `main@d840e662a`, equal to `origin/main` on 2026-08-09.
- Post-review-remediation `default@OhosTestCompileArkTS`: PASS, exit 0 on
  2026-08-09.
- Post-review-remediation `assembleHap`: PASS, exit 0,
  `BUILD SUCCESSFUL in 10 s 206 ms`.
- JSON, workflow YAML, Pages artifact simulation, literal permission and Huawei
  Cloud Space terminology checks: PASS.
- `git diff --check`: PASS.
- Manual shell equivalent of the Light compliance checks, including required
  tracked artifacts, protocol hashes, SPDX metadata and secret patterns: PASS.
- Exact `verify_open_source_release.ps1 -Mode Light`: PASS through the
  repository-provided PowerShell resolver.

## Next

1. Publish the branch and deploy Pages when authorized.
2. Confirm the public privacy URL, then use it and the exact
   permission-purpose wording in AppGallery.

## Blockers

- None for local implementation. The public page and AppGallery declaration do
  not change until the branch is published and the AppGallery form is updated.
