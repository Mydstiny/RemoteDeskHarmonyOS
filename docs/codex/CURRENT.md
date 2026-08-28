# Shared Current State

## Active task

- Task: `secret-visibility-policy`
- Branch/base: `codex/secret-visibility-policy` from synchronized `main@f3b41e5a6`.
- Phase: third review remediation verified; follow-up review pending.
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
- Secret preservation is bound to the original account/endpoint identity, so a
  blank hidden field cannot reuse a credential after its host, user, mode or
  key binding changes.
- Added runtime-only secret-presence markers so crypto-locked records remain
  identifiable as configured without exposing or serializing plaintext.
- Existing SSH private-key bodies are no longer loaded into ordinary page
  state; replacement uses a password input and explicitly preserves the old key
  only while its vault/path binding is unchanged.
- VNC now uses the shared policy while retaining its dedicated secret service,
  plaintext-consent checks, local personalization and rollback behavior. A
  forgotten VNC password can still be handed to the current connection only,
  without being persisted.
- VNC secret mutations are now explicit (`keep` / `replace` / `clear`) and are
  bound to transport, target, port, Gateway, repeater mode, TLS and security
  policy. Editing an endpoint cannot reuse or hand off its old password, and a
  visible password that is deliberately cleared removes the saved secret.
- RustDesk password preservation also binds the one-time/permanent password
  mode in both the classic editor and Pro preflight draft lifecycle.
- Runtime-only configured markers now survive HostSync/UI snapshot cloning
  while remaining absent from model JSON, cloud rows and portable backup.
- Clearing or rebinding a secret now resets its runtime configured marker;
  marker-only changes participate in HostSync comparison and use the full
  sensitive-write/unlock path instead of being mistaken for personalization.
- RustDesk Pro drafts now carry an explicit stored-password-preservation bit.
  A password invalidated by changing one-time/permanent mode stays invalid
  after background restore, even if the user switches back to the old mode.
- RustDesk Pro approval no longer retains the previously stored unattended
  password after an approved session.
- Classified `secretPresentationPolicyV1` as device-local and added focused
  policy, mutation, route and cloud-sync classification tests.

## Verification (current worktree)

- `default@OhosTestCompileArkTS`: PASS (`BUILD SUCCESSFUL in 20 s 406 ms`).
- `assembleHap`: PASS, signed (`BUILD SUCCESSFUL in 28 s 281 ms`).
- Light open-source compliance: PASS.
- `git diff --check`: PASS.
- The focused Hypium tests are registered in `List.test.ets` and compile in the
  required ArkTS gate. The optional `ohosTest@OhosTestCompileArkTS` task is not
  registered in this project (`00306054`), so no device test execution is
  claimed.

## Next

1. Commit the verified third remediation with only this task's files.
2. Ask the same independent reviewer to confirm all eleven findings are closed.
3. Rerun final gates and close the branch through PR/main where possible.

## Blockers

- Device/Hypium runtime acceptance has not been executed in this session.
- `ohosTest@OhosTestCompileArkTS` is unavailable because the task is not
  registered (`00306054`); the required `default@OhosTestCompileArkTS` gate did
  pass.
