# Shared Current State

## Active task

- Task: `secret-visibility-policy`
- Branch/base: `codex/secret-visibility-policy` from synchronized `main@f3b41e5a6`.
- Phase: implementation verified; checkpoint and independent review pending.
- Plan: `docs/codex/plans/2026-08-28-secret-visibility-policy.md`

## Objective

- Add a device-local Data Security Sheet for choosing which editable password
  classes do not reveal saved values in editors.
- Preserve an existing hidden secret on an empty edit, replace it only with a
  newly entered value, and keep deletion explicit.
- Bring VNC host passwords under the shared policy without changing protocol,
  encryption, cloud-sync, backup or connection behavior.

## Baseline

- Clean synchronized `main@f3b41e5a6`, equal to `origin/main` when started.
- Previous VNC cursor/wheel task is merged; its device acceptance, exact Hvigor
  gates and independent review passed.

## Implemented

- Added a versioned, device-local presentation policy for RDP host passwords,
  Windows credentials, RustDesk device passwords, SSH passwords/key
  passphrases and VNC host passwords.
- Added the Data Security `密码与秘密回显` Sheet with per-class switches,
  `全部隐藏` and compatibility-default actions. VNC remains hidden by default.
- Hidden editors now keep the old value on an empty draft and overwrite it only
  when a new non-empty value is entered; authentication/key binding changes do
  not accidentally carry an unrelated old secret forward.
- VNC now uses the shared policy while retaining its dedicated secret service,
  plaintext-consent checks, local personalization and rollback behavior.
- Classified `secretPresentationPolicyV1` as device-local and added focused
  policy, mutation, route and cloud-sync classification tests.

## Verification (current worktree)

- `default@OhosTestCompileArkTS`: PASS (`BUILD SUCCESSFUL in 34 s 902 ms`).
- `assembleHap`: PASS, signed (`BUILD SUCCESSFUL in 57 s 705 ms`).
- Light open-source compliance: PASS.
- `git diff --check`: PASS.
- The focused Hypium tests are registered in `List.test.ets` and compile in the
  required ArkTS gate. The optional `ohosTest@OhosTestCompileArkTS` task is not
  registered in this project (`00306054`), so no device test execution is
  claimed.

## Next

1. Create a checkpoint commit with only this task's files.
2. Obtain independent review, remediate findings and rerun the exact gates.
3. Close the branch through PR/main when repository and remote gates allow it.

## Blockers

- Device/Hypium runtime acceptance has not been executed in this session.
- `ohosTest@OhosTestCompileArkTS` is unavailable because the task is not
  registered (`00306054`); the required `default@OhosTestCompileArkTS` gate did
  pass.
