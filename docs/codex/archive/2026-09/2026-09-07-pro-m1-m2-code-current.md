# Shared Current State

- Task: pro-purchase-foundation; branch codex/pro-purchase-foundation; baseline main@8edc18786.
- Phase: Pro M1/M2 code implemented, committed separately and independently reviewed; device acceptance and production fulfillment pending.
- Stage commits: M1 `eaca0300dbb75c1785348b1bdabda4961e873c3a`; M2 `2db4ef2d79ceb6771b97e14b0edd56a12334e038`. Every subsequent completed stage must have its own commit for correction/revert boundaries.
- M1: stable feature catalog, pro.lifetime matching, release/API/device/protocol/capability/permission decisions, typed verification outcomes, immutable in-memory grants, account/environment/request isolation and sticky expiry/clock-rollback rejection.
- M2: shared runtime, synchronous account-transition isolation, overlapping transitions, immediate subscriptions and timed refresh, no-placeholder UI binding, real/free/pro Debug views, clear simulated labels and Release branch pruning.
- Existing core connection/input/display/files/security stay free. Unmarked new features default free. All Pro benefit previews remain planned; no shipped paid benefit or production authorization is claimed.
- Purchase demo: settings bottom entry and scrollable bindSheet retained. CNY19.99 launch/CNY28.88 regular, one-time non-consumable; AGC checkout price remains authoritative. SKU RemoteDesktop_Pro_Test is sandbox-only. Production checkout and fulfillment remain disabled.
- Validation: 16 host policy/runtime checks PASS; default@OhosTestCompileArkTS BUILD SUCCESSFUL in 56 s 813 ms; signed Debug assembleHap BUILD SUCCESSFUL in 44 s 105 ms; Light and git diff --check PASS.
- Commands: source scripts/macos_env.sh; hvigorw --mode module -p module=entry -p product=default default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon; same flags with assembleHap.
- Release: additional -p buildMode=release assembleHap BUILD SUCCESSFUL in 2 min 10 s 755 ms. Actual HAP checked by scripts/tests/check_pro_release.py: setter is a no-op and snapshot/decision contain no simulation override; actual entitlement policy remains.
- Debug actual-HAP cross-check PASS: three-state setter, simulation labels and local entitlement overlay are retained. This contrasts with the independently audited Release pruning.
- Release modules.abc SHA256: 4eee962092bec62f7fe2ccf902fd46dd066dc9c6a5a0929227a8a41d1f4121a7. Debug/Release HAPs retained locally for follow-up.
- Final metadata closure gates: default@OhosTestCompileArkTS BUILD SUCCESSFUL in 11 s 13 ms; signed assembleHap BUILD SUCCESSFUL in 17 s 96 ms; Light/diff/state validation PASS. Pro code remained unchanged after its independent review.
- Optional test-target probe: ohosTest@OhosTestCompileArkTS returned 00306054 task not found, matching the existing registration limitation. This phase did not change entry/src/ohosTest; both required default gates above passed.
- Review: /root/review_pro_plan independently passed the exact M1/M2 commits after two P2 fixes (transition-start isolation and clock rollback). Reviewer reran all 16 host checks and actual Release HAP inspection, finding no remaining actionable code defect. This does not review concurrent SSH/video/AI changes or certify device/backend acceptance.
- Aggregate review remains REVIEW_REQUIRED for the shared active task; the phase-specific PASS receipt records exact commits and must not suppress review of concurrent code in shared files.
- Device: one connected phone reports API26. Release HAP installed retaining data and launched; the phone is in an active SSH session, so Pro sheet/state/focus/dark-mode/multiwindow tests were not driven. API23/Pad/PC acceptance remains pending.
- Blockers: trusted server verifier, persistent verified offline cache, delivery/refund flow and real paid benefits are not implemented; no production sale. Device UI matrix remains unverified.
- Next: validate Debug three-state UI when the device is available, implement a real B3/M3 Pro feature, and progress the independent free U0/U1 UI work. Stay on the current branch while open work remains; no aggregate merge or branch completion claimed.
- Plans: [M1/M2](plans/2026-09-07-pro-m1-m2-implementation.md), [product roadmap](plans/2026-09-06-pro-product-roadmap.md), [free API26 UI](plans/2026-09-07-api26-base-ui-upgrade.md).
- Base UI: first SDK/Theme/page inventory is recorded; ComposeTitleBarV2/ComposeListItemV2 are candidates, not adopted. API23 target/compatible retained. No public UI code changed; U0 performance baseline and U1 compatibility sample are pending. This work never requires Pro/login/backend.
- Prior planning/demo snapshots: [preimplementation state](archive/2026-09/2026-09-07-pro-preimplementation-current.md). The transient Pro constructor/import compile failures recorded by other tasks have been fixed and superseded by the successful current gates above.

