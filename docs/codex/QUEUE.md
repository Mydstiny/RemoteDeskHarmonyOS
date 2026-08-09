# Privacy Permission Disclosure Queue

Updated: 2026-08-09 Asia/Shanghai

## Now

- Checkpoint and independently review the completed permission-disclosure scope.
- Preserve the guardrail that no cloud-sync runtime or package permission was changed.

## Next

- Provide PowerShell 7 and run the exact Light compliance gate.
- Push/merge only after that gate passes, wait for Pages deployment, then update the
  AppGallery privacy URL and permission declaration before resubmission.

## Later

- Add an automated package-versus-policy permission consistency check if future
  releases introduce more `user_grant` permissions.
