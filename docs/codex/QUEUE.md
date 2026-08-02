# Shared Queue

This file contains only actionable work. Completed history is preserved in
`docs/codex/archive/2026-08/` and later monthly archives.

Updated: 2026-08-02 Asia/Shanghai

## Now

- Fix the VNC renderer startup owner ordering using reservation, owner bind, and activation; keep owner/Surface/EGL/GL failures distinct.
- Restore `hdc` connectivity and capture the current VNC `hilog`; do not convert static source evidence into device evidence.
- Continue the existing RustDesk repair task on `codex/rustdesk-complete-repair`; preserve the current reviewer task ID and blocked status.

## Next

- After the active task is closed, implement the VNC V3 TLS trust Sheet and settings consistency plan in its own task branch.
- Complete API 23 direct VNC, Repeater, cross-protocol, and cloud/account matrices before release claims.
- Register or repair the `ohosTest` task before claiming ArkTS device-test execution.
- Create a dedicated workflow task only after this active branch is merged or explicitly archived; use it to evolve the state/receipt schema without mixing product changes.

## Later

- Define and deploy the versioned WebSocket gateway, public relay, and SSH tunnel contracts before enabling their fail-closed gates.
- Add real-device lifecycle evidence for surface recreation, background/foreground, network interruption, repeated connect/disconnect, and stale callbacks.
- Expand VNC crypto, cross-table substitution, and conflict UX coverage.

## Queue Rules

- Keep one active `codex/<task>` branch and never mix user-owned changes into a process or product commit.
- Remove completed items from this file; preserve durable history in the monthly archive.
- A single table or protocol blocker must not block unrelated protocols.
