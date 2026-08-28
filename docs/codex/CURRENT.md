# Shared Current State

## Active task

- Task: `remote-keyboard-sidebar-immersive-fix`
- Branch: `codex/system-clipboard-activation-fix`; user authorized work on the current branch.
- Increment: `01a87820e..92a6cc0d1`.
- Phase: implemented, locally verified, independently reviewed, and installed on one acceptance device; multi-protocol device acceptance remains active.
- Plan: `docs/codex/plans/2026-08-28-remote-keyboard-sidebar-immersive-fix.md`

## Result

- RustDesk, RDP, VNC and Moonlight use the same keyboard-surface close contract. The expanded keyboard action and collapsed side/top handle close an active virtual keyboard, modifier panel or shortcut panel.
- IME-compressed and very small windows keep a reachable collapsed handle. Sidebar/menu heights, anchor positions and scroll viewports clamp to the actual viewport rather than moving or clipping outside it.
- Four sidebar implementations reject vertical-dominant diagonal gestures at update/end; VNC also avoids committing those gestures as toolbar position drags.
- Sidebar/card hit regions block remote input while uncovered connection content remains interactive.
- RDP, RustDesk, VNC, Moonlight and SSH hide mobile status/navigation/indicator bars while connected, reassert on page/foreground/orientation transitions, and restore on exit. SSH updates each system bar independently so one unsupported call does not short-circuit the rest.

## Verification

- `default@OhosTestCompileArkTS`: PASS (`BUILD SUCCESSFUL in 21 s 310 ms`).
- `assembleHap`: PASS, signed (`BUILD SUCCESSFUL in 30 s 968 ms`).
- Signed HAP SHA-256: `099d15f50b4d5f7dd47405389a33f86199f3a99138e6154ee7bf6243e0a1f996`.
- `git diff --check`: PASS.
- Light open-source compliance: PASS.
- `ohosTest@OhosTestCompileArkTS`: unavailable (`00306054`, task is not registered); mandatory `default@OhosTestCompileArkTS` passed and focused policies are registered in `entry/src/test`.
- Independent review `/root/remote_ui_review`: PASS after two P1 and two P2 remediations; no remaining P0/P1/P2.

## Device delivery / blockers

- `192.168.3.235:38451`: latest signed HAP installed successfully with data-preserving `install -r`; ready for user acceptance.
- `192.168.3.236:40123`: install blocked by `9568286 install provision type not same` because the installed app is release-provisioned and the local HAP is debug-provisioned. Existing app/data were preserved; no destructive uninstall was performed.
- Next: exercise RustDesk/RDP/VNC/Moonlight keyboard-close, scrolling, sidebar drag/bounds and mobile immersive bars on `.235`; decide separately whether `.236` may be destructively uninstalled or must receive a matching release-provisioned HAP.
