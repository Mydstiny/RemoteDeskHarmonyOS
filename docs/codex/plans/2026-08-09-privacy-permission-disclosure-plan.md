# Privacy Permission Disclosure Plan

Date: 2026-08-09 Asia/Shanghai

## Objective

Resolve the AppGallery privacy consistency finding for
`ohos.permission.DISTRIBUTED_DATASYNC` without removing or weakening the Huawei
Cloud Space synchronization permission.

## Scope

1. Add an explicit permission name, purpose, trigger and refusal impact to the
   canonical privacy policy.
2. Align the in-app privacy summary with the canonical policy and point its
   complete-policy link at a real public privacy page; align the system permission
   prompt reason with the same trigger and purpose.
3. Publish a privacy-only static page through the existing GitHub Pages workflow.
4. Update the AppGallery release guide and permission checklist to use the actual
   Huawei Cloud Space service terminology and current permission set.

## Guardrails

- Do not change runtime permission declarations, cloud synchronization code,
  signing material or the generated release package.
- Keep `DISTRIBUTED_DATASYNC`; cloud synchronization depends on it.
- State clearly that refusing the permission disables cloud synchronization but
  does not prevent local use.
- Do not claim that device-local personalization is uploaded.

## Verification

- Confirm the literal permission appears in the canonical Markdown, public HTML,
  in-app summary and release checklist.
- Validate public HTML structure and Pages workflow paths.
- Run `git diff --check`, the Light compliance gate, `default@OhosTestCompileArkTS`
  and `assembleHap`.
