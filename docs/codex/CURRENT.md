# Shared Current State

## Active Task

- Task: `moonlight-complete-upgrade`
- Base: `main@aeb0cdac5`; branch: `codex/moonlight-complete-upgrade`
- Code checkpoint: `2c37b0edf` (`feat(moonlight): finish local ui shell`); docs closeout follows on the same branch.
- Phase: U1-06～U1-12 local-only UI shell checkpoint complete; S1 runtime wiring and N2-09 external evidence remain pending.
- Authoritative plan: `docs/superpowers/plans/2026-07-28-moonlight-harmonyos-complete-upgrade-plan.md`
- Live ledger: `docs/codex/plans/2026-08-09-moonlight-implementation-ledger.md`
- The only uncommitted file is the user-owned `entry/src/main/ets/services/CloudStore.ets` cloud-sync change; it is intentionally excluded from this task and must remain untouched.

## Product decisions

- Moonlight remains local-host-only. Do not register, upload, or instantiate `moonlightrecordv1`; do not add Moonlight cloud selection, transfer, or secret recovery.
- RustDesk is the sole Moonlight UI reference. VNC is only an isolation/regression boundary, never a visual or interaction scaffold.
- The homepage is the canonical host-management entry. Moonlight settings has nine protocol sections; it does not duplicate host management, common display, PIP, or other shared host settings.
- The Moonlight FAB and PC sidebar slot remain disabled: last position, 0.58 parent opacity, one “即将支持”, no route and no background work.
- The icon is the pinned official Moonlight Qt geometry converted to a deterministic monochrome tintable asset, with system-symbol fallback; it is not an official endorsement.
- Real controller input remains S1-05A: HarmonyOS native listener → narrow typed NAPI → N3-08 → N3-05 → N3-01 → official common-c. ArkTS never encodes or directly sends controller wire data.

## UI shell checkpoint (`2c37b0edf`)

- Added local-only `MoonlightHostDetailPage`, `MoonlightAppCatalogPage`, `MoonlightSettingsPage` and `MoonlightStreamPage`; routes are registered in `main_pages.json`.
- Added RustDesk-aligned `MoonlightLaunchSheet`, connect-stage overlay, session toolbar, control center, controller overlay, diagnostics HUD and brand icon components. They are UI contracts only; real transport/media/Host Control remains fail closed.
- The existing add Sheet’s native `onDisappear` handoff now opens the catalog by stable local host ID. Catalog/detail/settings reload local records/cache with generation-fenced view refresh.
- Moonlight settings is a single-entry, nine-section surface. Common display/PIP settings were removed from Moonlight, and the redundant “主机管理” row was removed because host management belongs on the homepage.
- Desktop has a separate grey Moonlight sidebar slot even when other host cards are grouped. The FAB flow still passes `moonlightProtocolAvailable: false`.

## Verification

- Exact `default@OhosTestCompileArkTS ... --no-daemon`: BUILD SUCCESSFUL.
- Exact `assembleHap ... --no-daemon`: BUILD SUCCESSFUL; signed HAP:
  `entry/build/default/outputs/default/entry-default-signed.hap`.
- Fresh sandbox-external HDC install/start succeeded on PC `127.0.0.1:5555` and phone `127.0.0.1:5557` after the final build.
- Fresh PC full-screen evidence: `/private/tmp/moonlight-final-20260811-pc-full.jpeg` and `.json` — RDP page remains intact; Moonlight is a grey separate sidebar slot with “即将支持”.
- Fresh phone settings evidence: `/private/tmp/moonlight-final-20260811-phone-settings.jpeg` and `.json` — Moonlight subtitle is `串流画面、音频、控制与本地安全设置`; no “主机管理” item is present.
- Fresh UI-tree checks found one Moonlight slot and one “即将支持” on PC, and the expected Moonlight settings card with no host-management row on phone. No old screenshot is used as evidence.
- Moonlight focused tests are compile-registered (162 tests/21 describe groups plus 8 shared handoff cases); `ohosTest` remains unregistered (`00306054`), so no device Hypium PASS is claimed.
- Static isolation check: no RustDesk/SSH/RDP/VNC business source, native source, `CloudSyncPolicy`, or cloud table registration was changed by the Moonlight UI checkpoint. The user-owned CloudStore diff is outside scope.

## Next / blockers

- Next implementation boundary: S1-01/S1-02 session registry/coordinator, then S1-05A native GameController ingress and N2-09 real Sunshine/ARM64 matrix. Keep every product capability false until its runtime receipt exists.
- Remaining acceptance is not a release claim: real AppSpawn secure identity, Sunshine transport/media/first frame, OHAudio/Surface lifecycle, physical controller, on-device Hypium, and long-run performance are unproven.
- `ohosTest@OhosTestCompileArkTS` is still blocked by unregistered task `00306054`.
