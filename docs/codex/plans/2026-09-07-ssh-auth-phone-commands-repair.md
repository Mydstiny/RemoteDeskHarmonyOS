# SSH authentication, phone layout and command storage repair

Status: resumed by the user's explicit instruction on 2026-09-07. Phone menu correction and 49 host checks pass; current-run mandatory Hvigor gates and Light passed; committed-code review and device acceptance remain pending.

## User correction and resume

- The user rejected moving phone toolbar actions out of the More menu because phone space is limited. The resumed change restores one More menu in the session header and removes the duplicate tab-strip action entry, in portrait and landscape and regardless of the workbench rollout flag.
- The paused checkpoint is `15f27269e`. The user subsequently authorized resuming while the other task edits code without building. Keep independent source/index scopes and coordinate a stable source window for mandatory compilation; the waiting heartbeat is paused.

## Scope

- Complete one real SSH native login from a host-list Sheet before routing to SshTerminal. Keep canonical direct/proxy/ProxyJump routes, key material resolution, explicit host-key trust and multi-round interactive authentication.
- Transfer the connected session with a one-shot account/host/username/route/session/generation receipt. Cancel or expire only its owned native session; never silently repeat login when adoption fails.
- Preserve existing PC independent-window handoff. Show handoff errors and a return action instead of an endless spinner.
- Keep phone tabs in a dedicated row above the session toolbar in both orientations, count the top safe inset once, and retain actions inside the compact More menu. Preserve Pad/PC layout and the concurrently committed Pro SFTP hooks.
- Let unconfigured app encryption use an explicitly versioned local plaintext command document, still isolated by account. Keep configured-but-locked data unavailable; migrate plaintext to ciphertext when encryption becomes ready without erasing the old value on failed writes.

## Verification

- Host runner: `SSH_TYPESCRIPT_PATH=<DevEco TypeScript module> node scripts/tests/test_ssh_repair.cjs`.
- Resumed-run 49 host checks PASS: command CRUD/restart/account isolation/crypto upgrade and failed writes; phone layout and consolidated-menu policy; successful-vs-cancelled Sheet dismissal; retained-session recovery; delayed auth, cancel/late success, multi-round MFA, HTTP proxy and three ordered jump inputs; handoff expiry and scope/route/username/generation changes.
- Initial pre-pause compilation found ArkTS interface callback literal / typed-route literal / throw issues. Corrected; resumed-run `default@OhosTestCompileArkTS` exited 0, `BUILD SUCCESSFUL in 17 s 681 ms`; signed `assembleHap` exited 0, `BUILD SUCCESSFUL in 22 s 636 ms`. Both used `--mode module -p module=entry -p product=default --analyze=normal --parallel --incremental --no-daemon` after `source scripts/macos_env.sh`.
- Additional `ohosTest@OhosTestCompileArkTS` attempt exited 1: `00306054`, task not found. The mandatory default test compile succeeded; no `entry/src/ohosTest` file changed in this repair.
- Current resumed-run Light compliance PASS and `git diff --check` PASS before final review.
- An HDC phone is reachable. This repair has not yet been installed or accepted on it; no SSH endpoint credentials or runtime matrix are claimed.

## Review and integration

- Reviewer: `/root/review_ssh_repair` (reuse this reviewer for final commit).
- Pre-commit review found success dismissal cancelling its token, missing phone-landscape overflow, invisible PC handoff errors and unbounded MFA instructions; all four corrected and rechecked. Final commit review pending.
- Continue `codex/pro-purchase-foundation` while parallel Pro and video evidence work remains active. Preserve unrelated staged files and HostListPage Pro hunks.
- Own files: SshConnectionPreflightSheet, SshConnectionPreflight, SshAuthenticatedHandoff, SshHostKeyTrustWriter, SshProductivityStore/Sheet, SshTabChromePolicy, SSH hunks in HostListPage/SshTerminal/ExtensionLoader, focused tests and this plan.

## Device acceptance

1. From host list: first/changed fingerprint, encrypted key, password, ProxyJump and multi-round MFA. Cancelling any round or backgrounding must leave no newly opened terminal/window.
2. Successful login enters terminal once with initial output retained. Failed/expired handoff reports a recoverable error without automatic reauthentication.
3. Phone portrait and landscape: tab row/toolbar/safe area, overflow/common-command entry, software keyboard and SFTP.
4. Encryption never configured: create/edit/insert/delete commands and restart; enable/unlock/lock encryption and switch accounts without losing or mixing commands.
