# Shared Current State

## Active task

- Task: `secret-visibility-policy`
- Branch/base: `codex/secret-visibility-policy` from synchronized `main@f3b41e5a6`.
- Phase: tenth-review remediation verified on `91a8b0e8`; checkpoint commit pending.
- Plan: `docs/codex/plans/2026-08-28-secret-visibility-policy.md`

## Objective

- Add a device-local Data Security Sheet for choosing which editable password classes do not reveal saved values.
- Preserve an existing hidden secret on an empty edit, replace it only with a
  newly entered value, and keep deletion explicit.
- Bring VNC host passwords under the shared policy without changing protocol,
  encryption, cloud-sync, backup or connection behavior.

## Baseline

- Clean synchronized `main@f3b41e5a6`, equal to `origin/main` when started.

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
  forgotten VNC password can be handed to the current connection only;
  aborted, backgrounded or destroyed add flows clear every transient handoff.
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
- The standard RustDesk connection Sheet now follows the same local visibility
  policy as Pro: hidden saved passwords never enter its editable `@State`, and
  approval success clears the old unattended password and marker.
- Pro address-book reconciliation preserves crypto-locked secret markers,
  never mistakes redacted plaintext for an absent password, and never replaces
  a configured local password with a server response.
- SSH trust, passphrase and key-install mutations retain runtime markers.
  Switching to an installed key clears the obsolete password, while locked
  trust-only updates preserve the encrypted private-key passphrase extension.
- Stored-password projections are now distinguished from user-entered drafts.
  Background and foreground `DataCrypto` lock transitions scrub projected
  plaintext from standard/Pro RustDesk, classic RDP/RustDesk/SSH editors, RDP
  credentials and both VNC edit flows; unlock restoration always re-applies
  the current local policy; background/non-active windows cannot initially
  project or restore plaintext, including after an async authentication gate.
- Both SSH public-key deployment entry points now keep only sanitized host
  projections or minimal display views in responsive state, including clearing
  proxy passwords/passphrases. The independent KeyVault Sheet passes only key
  and host IDs, refetches live secrets after the lock gate, rejects crypto-locked
  access, and supports both KeyVault and legacy inline authentication keys.
- The device-local presentation store now publishes process-local changes.
  Editors and settings Sheets subscribe for their visible lifecycle, so another
  window immediately clears hidden projections; per-kind writes read the latest
  policy first, preventing stale Sheets from reopening another kind. Nothing is
  synchronized to cloud or backup.
- Unlock/policy restoration now requires the opening snapshot, live record and
  editor endpoint/user/auth/mode/key binding to agree. Deleted or rebound
  records clear their projection and block the stale panel until reopened.
- SSH key installation records full host/target-key operation identities across
  async verification, then refetches both before committing; concurrent change,
  deletion or crypto relock leaves local authentication untouched.
- Legacy SSH proxy password/passphrase ciphertext now has runtime presence
  markers and survives permitted trust-only writes while the crypto vault is
  locked. Canonical proxy rebinding clears both the legacy values and markers.
- Switching an SSH host to a newly installed KeyVault key replaces `sshKeyId`
  and clears obsolete inline key data, passphrase and configured markers.
- RustDesk approval is blocked while a saved password is crypto-redacted; a
  persistence race after connection triggers immediate session cleanup rather
  than leaving the old unattended password behind.
- HostList change detection now includes runtime secret markers, and the
  RustDesk trust manager consumes those markers when plaintext is redacted.
- Classified `secretPresentationPolicyV1` as device-local and added focused
  policy, mutation, route and cloud-sync classification tests.

## Verification (current worktree)

- `default@OhosTestCompileArkTS`: PASS (`BUILD SUCCESSFUL in 11 s 126 ms`).
- `assembleHap`: PASS, signed (`BUILD SUCCESSFUL in 17 s 853 ms`).
- Light open-source compliance: PASS.
- `git diff --check`: PASS.
- The focused Hypium tests are registered in `List.test.ets` and compile in the
  required ArkTS gate. The optional `ohosTest@OhosTestCompileArkTS` task is not
  registered in this project (`00306054`), so no device test execution is
  claimed.

## Next

1. Commit this checkpoint and ask the same reviewer to confirm all thirty-five findings are closed.
2. Rerun final gates and close the branch through PR/main after a clean verdict.

## Blockers

- Device/Hypium acceptance was not run; `ohosTest@OhosTestCompileArkTS` is not registered (`00306054`).
