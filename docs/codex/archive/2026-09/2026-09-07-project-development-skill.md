# RemoteDeskHarmonyOS development skill delivery

## Scope and evidence

- User requested a complete project skill and then confirmed API 26 as the
  current development baseline. API 23 is historical/compatibility evidence;
  target/compatible settings and native toolchain selection remain separate.
- Delivered package: `.agents/skills/remotedesk-harmonyos-dev`, 19 files,
  including the entrypoint, UI metadata, focused references, historical catalog
  and a read-only Python auditor. No application behavior or build target was
  changed by this task.
- Plan: `docs/codex/plans/2026-09-07-project-development-skill.md`.
- Source snapshot: `0000d4ca4666d2717c06fd38d00eb05fe977fee5`; public main
  snapshot: `8edc187868e94ed41634e8a6c4c4c072e3a48679`.
- Coverage: five protocols; architecture; rendering/input/lifecycle;
  networking; cloud/account/backup/security; purchase; API 26 and retained
  compatibility; validation and history. The catalog indexes 187 tracked
  Markdown documents and all 51 public first-parent milestones at the source
  snapshot. It does not claim line-by-line audit of every document or recovery
  of undocumented/private development history.
- Current task facts remain in CURRENT/STATE/QUEUE. Other concurrent Pro,
  SSH, video and planning changes are excluded from this delivery.

## Independent review

- `/root/skill_source_review` independently checked current cloud-store policy,
  the two distinct Pro domains, SDK roles, complete package, reference auditor,
  REUSE coverage and API 26 correction. Final package and subsequent API 26
  increment: PASS, no P0/P1/P2/P3 actionable findings.
- `/root/skill_forward_test` performed three read-only scenarios: RDP fullscreen
  pointer displacement, RustDesk H.265 evidence and Pro checkout after dismissal.
  All found actual code chains and appropriate verification boundaries.
- Forward testing identified stale baseline wording during concurrent Pro
  runtime development. Remediation requires diffing the stated baseline,
  checking untracked runtime files, and separately verifying runtime wiring,
  trusted backend, purchase initiation and entitlement account generations.
- Final refinements added exact HUD/transform/negotiation entrypoints, accurate
  relative-link semantics and the distinction between blocking an unstarted
  checkout and cancelling an already-started system purchase.
- Independent negative auditor checks rejected missing/escaping links and
  omitted/duplicate catalog entries. Root checks also rejected a non-project
  directory and a non-hash Git selector. No negative test changed source files.
- These are skill structure/routing/evidence reviews, not product or device
  acceptance. Auditor executed on macOS; Windows execution was not performed.

## Validation

- Skill-creator `quick_validate.py`: PASS. Its PyYAML dependency was isolated
  in temporary validation storage; it is not a skill runtime dependency.
- `audit_skill.py --repo .`: PASS, 286 local links, 64 cited commit IDs,
  51 public milestones and 187 indexed documents.
- Light compliance: PASS after the API 26 increment; staged and working-tree
  `git diff --check`: PASS.
- Fresh final Hvigor pair: PASS, exit 0 for both commands. Compile BUILD SUCCESSFUL in 14 s 568 ms; signed assembleHap BUILD SUCCESSFUL in 14 s 22 ms.
- Metadata closure gates also returned exit 0: compile BUILD SUCCESSFUL in 20 s 912 ms;
  assembleHap BUILD SUCCESSFUL in 12 s 450 ms. This extra pair overlapped the video
  task build window during handoff. The prior exclusive pair above remains
  the skill baseline; product acceptance belongs to each owning task.
- Earlier successful runs in this task: compile 5 s 502 ms and 28 s 622 ms;
  signed assembleHap 22 s 523 ms. Later shared-worktree failures included SSH
  ArkTS typing diagnostics and generated resource-name conflict 11211117.
- Environment recovery: normal escalation resolved initial existing-cache
  EPERM; 12 byte-identical untracked generated resource JSON duplicates were
  moved into the project's ignored build quarantine, with originals retained.
  No application source, user document or dependency cache was deleted.
- Final commands: source `scripts/macos_env.sh`; run Hvigor with `--mode module
  -p module=entry -p product=default`, task `default@OhosTestCompileArkTS` then
  `assembleHap`, and `--analyze=normal --parallel --incremental --no-daemon`.

## Delivery boundary

Implementation commit: `b6f15687830adc85725fe9fb6ef30b7cacf0b61e`. Review receipt: `project-skill-api26-b6f156878-2026-09-07`.
Final gates ran after the API 26/content refinements and after the Pro task
released its shared build window. The build exercised the shared checkout; it
is not an independent acceptance of concurrent Pro/SSH/video source changes.
The active Pro branch remains local while its own integration/device work is
open. This skill does not publish or merge the other unfinished functionality.
Shared queue retains its existing business/device follow-ups; no skill work
item is silently promoted into Pro or protocol acceptance.
