# Shared Current State

## Active Task

- Task: `moonlight-complete-upgrade`
- Base: `main@aeb0cdac5`; branch: `codex/moonlight-complete-upgrade`
- Code checkpoint: `665df714` (`fix(moonlight): reconcile toolbar auto-hide lifecycle`); S1-04 is closed on top of `fae7c36dd` and `f7f39c0f`.
- Phase: U1-06～U1-12 local-only UI shell and S1-01～S1-04 dormant contracts are complete; S1-05A native controller ingress, runtime/media and N2-09 external evidence remain pending.
- Authoritative plan: `docs/superpowers/plans/2026-07-28-moonlight-harmonyos-complete-upgrade-plan.md`
- Live ledger: `docs/codex/plans/2026-08-09-moonlight-implementation-ledger.md`
- The only uncommitted file is the user-owned `entry/src/main/ets/services/CloudStore.ets`; it remains untouched, unstaged and outside this task.

## Product decisions

- Moonlight remains local-host-only. Do not register, upload or instantiate `moonlightrecordv1`; cloud selection, transfer and secret recovery remain parked.
- RustDesk is the sole Moonlight UI reference. Homepage host management is canonical; Moonlight settings has nine protocol sections and no duplicate host/common display/PIP management.
- The Moonlight FAB and PC sidebar slot remain disabled: grey/tintable icon, 0.58 parent opacity, one “即将支持”, no route and no background work.
- Real controller input remains S1-05A: HarmonyOS native listener → narrow typed NAPI → N3-08 → N3-05 → N3-01 → official common-c. ArkTS never encodes or directly sends controller wire data.

## S1-04 checkpoint

- `MoonlightSessionToolbar` now has RustDesk-aligned responsive layouts: phone/pad edge rail with bounded `Scroll`, desktop md/lg compact/full toolbar and desktop xl top toolbar.
- Non-xl layouts have an explicit collapse action; only xl exposes pin and the 5-second auto-hide policy. `menuOpen` and breakpoint changes are watched and reconcile timers; queued callbacks re-read the current policy before collapsing.
- `MoonlightStreamPage` passes Sheet ownership into the toolbar. Control center width/padding/row layout is breakpoint-aware and unavailable diagnostics remain fail closed.
- S1-04 remains a UI contract only: no transport, media, native input, OHAudio, Surface, cloud or release truth was opened.

## Verification

- Exact `default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon`: `BUILD SUCCESSFUL` after `665df714`.
- Exact `assembleHap --analyze=normal --parallel --incremental --no-daemon`: `BUILD SUCCESSFUL` after `665df714`.
- Signed HAP from the final current workspace build: `entry/build/default/outputs/default/entry-default-signed.hap`; SHA-256 `cb1086ccaf57ada2e7cc1d879e5df6d75ee1b249c2cfdc58d176f7e9545d1d99`. The user-owned `CloudStore.ets` diff is excluded from the Moonlight source scope.
- Sandbox-external HDC installed and started that current HAP on PC `127.0.0.1:5555` and phone `127.0.0.1:5557`.
- Only the latest final-HAP evidence captured and viewed in this closeout is recorded: `/private/tmp/moonlight-s104-final-cb1086-20260812-pc-root.jpeg`, `/private/tmp/moonlight-s104-final-cb1086-20260812-pc-max2.jpeg`, `/private/tmp/moonlight-s104-final-cb1086-20260812-pc-picker2.jpeg`, `/private/tmp/moonlight-s104-final-cb1086-20260812-pc-picker-click.jpeg`, `/private/tmp/moonlight-s104-final-cb1086-20260812-phone-root.jpeg`, `/private/tmp/moonlight-s104-final-cb1086-20260812-phone-picker2.jpeg`, and `/private/tmp/moonlight-s104-final-cb1086-20260812-phone-picker-click.jpeg`. PC sidebar, both pickers and disabled click behavior are correct; no old screenshot is used.
- Reused reviewer task `019fe966-d99a-7ce1-8b53-4ef725597053`: final PASS, P0/P1/P2 = 0; P3 = 1 accepted testability limitation because pure policy tests cannot instantiate ArkUI timers. Reviewer confirmed only Moonlight UI/policy/test files changed and no adjacent protocol/cloud/native/runtime impact.
- Focused Moonlight aggregate is documented as 165 compile-registered tests in 21 describe groups plus 8 shared host-add handoff cases. `ohosTest` remains unavailable because task `00306054` is not registered; no device Hypium PASS is claimed.
- `CloudStore.ets` remains the sole dirty user file and is not staged. `git diff --check` and static scope isolation are required again after this documentation closeout.

## Next / blockers

- Next implementation boundary: S1-05A native HarmonyOS GameController listener plus narrow typed NAPI; keep controller capability false until real-device receipts exist. Then continue runtime/media/Sunshine external work under N2-09 and S1-08.
- Remaining acceptance is not a release claim: AppSpawn secure identity, real Sunshine transport/media/first frame, OHAudio/Surface lifecycle, physical controller, on-device Hypium, network/thermal/long-run evidence remain unproven.
- Moonlight cloud sync is intentionally parked and the user’s cloud changes are outside this checkpoint.
