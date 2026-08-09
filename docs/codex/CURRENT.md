# Shared Current State

## Active Task

- Task: `host-local-personalization`
- Base: `main@2feb12e0d`
- Branch: `codex/host-local-personalization`
- Phase: implementation and field validation complete; checkpoint commit and independent review pending.

## Completed

- Classified synchronized host identity separately from device-local display, input, quality and usage preferences.
- Added versioned local personalization overlays while retaining every legacy cloud column and decoder.
- Preserved legacy cloud personalization on unrelated host updates; new hosts remain readable by 1.0.7/1.0.8 clients.
- Routed RustDesk Server Pro reconciliation through the same cloud-base comparison, preventing status refreshes from dirtying all `remotehosts` rows.
- Kept VNC device-specific settings local and removed the obsolete VNC-specific cloud gate/entry.
- Made manual upload settle successful tables independently and continue the VNC leg when another table fails.
- Added per-table terminal statistics and precise Huawei cloud progress-code diagnostics.
- Made portable backup export omit historical orphan extension rows without deleting or weakening validation of local data.
- Added ownership, coordinator wiring, backup policy and legacy-upgrade regressions.

## Compatibility Guardrails

- Existing distributed-table names, columns and registration remain unchanged.
- Missing, malformed or future-version local overrides fall back to legacy values and never gate login or cloud initialization.
- Cloud-first reads and old-client writes cannot overwrite an established local override on another device.
- Existing 1.0.7/1.0.8 rows upgrade in place; no destructive migration or mandatory cloud rewrite was introduced.

## Verification

- `git diff --check`: PASS.
- `default@OhosTestCompileArkTS`: PASS on 2026-08-09 after the final code changes.
- `assembleHap`: PASS (`BUILD SUCCESSFUL in 27 s 644 ms`) on 2026-08-09 after the final code changes.
- `python3 scripts/verify_legacy_upgrade.py`: PASS for `1.0.7@d2bc6c9982` and initial `1.0.8@a3d47c464a`; all fixture rows preserved, personalization upgrade PASS, schema version 4.
- Phone `192.168.3.235:38451`: signed HAP installed; user-confirmed full cloud overwrite upload succeeded on 2026-08-09.
- Phone backup: full backup passed snapshot/staging validation and entered the system save picker; picker was canceled intentionally, with no public file left behind.
- Huawei Cloud Space schema was inspected read-only: `remotehosts` matches the projected String/Integer columns and contains no Asset field.

## Next

1. Create the requested checkpoint commit.
2. Run the required independent review against the committed scope and address any findings.
3. Complete Pad/PC and second-device personalization-isolation acceptance before release/PR closure.

## Blockers

- None for the checkpoint commit.
