# Adaptive SSH common-command editor

Status: implemented and current-run builds passed; exact incremental review pending.

- Request: quickly replace the fixed-size common-command editor surface with content-adaptive sizing.
- Scope: only SshProductivitySheet and its bindSheet/content parameters in SshTerminal. Keep save/cancel, selection, storage and terminal insertion behavior.
- Use native SheetSize.FIT_CONTENT (available since API 11, verified in the installed API 26 declaration). Remove the full-height root and weighted Scroll that forced the old 720vp/LARGE layout.
- During editing, show the existing form without the list/search/settings content below it; save/cancel restores the normal list. Cap body scrolling with the live terminal viewport and keyboard inset, and clamp centered width to the available workspace.
- Verification: existing 49 SSH host checks PASS; `default@OhosTestCompileArkTS` BUILD SUCCESSFUL in 23 s 596 ms and signed `assembleHap` BUILD SUCCESSFUL in 30 s 485 ms, both exit 0; Light/diff PASS. Commands used `source scripts/macos_env.sh` then `hvigorw --mode module -p module=entry -p product=default <task> --analyze=normal --parallel --incremental --no-daemon`. Exact incremental review remains pending. No new implementation-mirroring test is introduced for this layout-only change.
- Reviewer: reuse `/root/review_ssh_repair`; review only this increment, without reopening the completed authentication/storage repair.
- Device boundary: visual fit, Phone/Pad/PC rotation and keyboard behavior have not been accepted on a device in this task.
