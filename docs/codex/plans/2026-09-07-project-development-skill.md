# Project development skill packaging

## Scope

The user requested a complete repository-maintained RemoteDeskHarmonyOS skill
covering architecture, protocol development, HarmonyOS constraints, historical
decisions and verification. Create `.agents/skills/remotedesk-harmonyos-dev`
with a short entrypoint, focused references, a public-history/source index and
a read-only reference auditor. Preserve original project sources and scripts.

The existing `codex/pro-purchase-foundation` task remains active. Continue its
checkout without a new branch or worktree. Existing Pro/API planning and shared
state edits belong to other work and must remain uncommitted by this increment.
This packaging does not implement Pro, change build targets or change application
code. The user confirmed API 26 as the current development baseline on 2026-09-07;
align skill, AGENTS and DECISIONS wording while retaining separately verified
API 23 compatibility and actual native toolchain information.

## Evidence and design

- Source snapshot: `0000d4ca4666d2717c06fd38d00eb05fe977fee5`.
- Public main snapshot: `8edc187868e94ed41634e8a6c4c4c072e3a48679`.
- Index all 51 public first-parent milestones and 187 tracked docs Markdown
  paths at that snapshot. A discovery index is not a claim of line-by-line
  technical review or recovery of undocumented/private development history.
- Route five protocol families, rendering/input/lifecycle, networking,
  account/cloud/backup/security, application purchase and HarmonyOS APIs.
- Distinguish RustDesk Server Pro from application Pro purchase; distinguish
  installed SDK, product target/compatibility and specific API availability.
- Resolve conflicting historical cloud-store statements against current
  `AccountScopePolicy` and `CloudStore`; do not change application behavior.
- Keep current task state in existing coordination files; skill references do
  not copy secrets, raw model memory, chat logs or private archive history.
- Include repository-original skill files in REUSE licensing coverage.

## Validation and delivery

1. Validate skill frontmatter/UI metadata, local links, cited commit ancestry
   and document snapshot coverage; verify auditor failure paths.
2. Independently exercise realistic read-only requests against the skill and
   source; review the final package and correct actionable findings.
3. Run fresh `default@OhosTestCompileArkTS` and signed `assembleHap` with
   `--no-daemon`, Light compliance and `git diff --check`.
4. Record exact evidence in a task-specific archive report and concise shared
   state additions, preserving pre-existing working-tree edits.
5. Commit only skill, its plan/report, REUSE, API baseline wording in AGENTS/
   DECISIONS and this increment's coordination additions. Retain the current branch while the original Pro task's external
   integration/device blockers remain open; packaging is not authorization to
   publish or merge unfinished business functionality.
