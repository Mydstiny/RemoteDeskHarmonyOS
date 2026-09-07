# SSH authentication, phone layout and command storage repair

Status: paused by the user; incomplete checkpoint only. Resume after the parallel tasks finish. Final Hvigor gates, final independent review and device acceptance remain pending.

## Pause and required correction

- The user rejected moving phone toolbar actions out of the More menu because phone space is limited. Preserve the compact More menu when work resumes; the current checkpoint still contains the rejected layout and is not accepted.
- Stop code changes and builds now, commit only this task's current changes, and wait for the other active tasks to finish before continuing.

## Scope

- Complete one real SSH native login from a host-list Sheet before routing to SshTerminal. Keep canonical direct/proxy/ProxyJump routes, key material resolution, explicit host-key trust and multi-round interactive authentication.
- Transfer the connected session with a one-shot account/host/username/route/session/generation receipt. Cancel or expire only its owned native session; never silently repeat login when adoption fails.
- Preserve existing PC independent-window handoff. Show handoff errors and a return action instead of an endless spinner.
- Reassess the phone tab row/toolbar/safe-area issue while retaining actions inside the compact More menu. The checkpoint's direct-action layout must be corrected when work resumes.
- Let unconfigured app encryption use an explicitly versioned local plaintext command document, still isolated by account. Keep configured-but-locked data unavailable; migrate plaintext to ciphertext when encryption becomes ready without erasing the old value on failed writes.

## Verification

- Host runner: `SSH_TYPESCRIPT_PATH=<DevEco TypeScript module> node scripts/tests/test_ssh_repair.cjs`.
- 49 host checks PASS: command CRUD/restart/account isolation/crypto upgrade and failed writes; phone layout policy; successful-vs-cancelled Sheet dismissal; retained-session recovery; delayed auth, cancel/late success, multi-round MFA, HTTP proxy and three ordered jump inputs; handoff expiry and scope/route/username/generation changes.
- Initial current-run Hvigor compilation found ArkTS interface callback literal / typed-route literal / throw issues. Corrected; final gates pending.
- Light compliance PASS and `git diff --check` PASS before final review.
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
