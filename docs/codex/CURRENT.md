# Shared Current State

- Task: pro-purchase-foundation.
- Branch: codex/pro-purchase-foundation; baseline main@8edc18786; reviewed code 6690cdbf.
- Phase: sandbox demo code independently reviewed; external integration and device acceptance pending.
- User authorized removal of 91 byte-identical untracked duplicate files and a new local branch. Originals retained.
- Price: CNY 19.99 launch / 28.88 regular, one-time non-consumable purchase; checkout uses AGC price.
- Delivered: settings bottom Pro entry, theme-aware scrollable bindSheet with fixed purchase footer and entrance animation; planned benefits clearly labeled; real sandbox-only product/checkout/order queries; feature catalog, access policy and verifier/entitlement integration seams.
- Existing features remain free. Demo does not grant Pro or acknowledge delivery without trusted verification. Production purchase disabled.
- Lifecycle: global single-flight admission; sandbox preflight followed by current-request check; complete/programmatic/system dismiss invalidate pending checkout.
- Verification: default@OhosTestCompileArkTS PASS (9 s 429 ms); signed assembleHap PASS (10 s 559 ms); 8 host policy/lifecycle checks PASS; staged Light compliance and diff check PASS.
- Commands: source scripts/macos_env.sh; hvigorw --mode module -p module=entry -p product=default default@OhosTestCompileArkTS --analyze=normal --parallel --incremental --no-daemon; same flags with assembleHap.
- First build found an explicit ArkTS result type missing; fixed before successful gates. Initial cache access required normal sandbox escalation.
- Review: /root/review_pro_demo found one P2 (checkout after sheet dismissal during sandbox check), then verified ac83ccec remediation with final PASS and no remaining actionable findings.
- Prior task state preserved in archive/2026-09/2026-09-06-pre-pro-current.md and matching state JSON; device acceptance queue retained.
- Test package: entry/build/default/outputs/default/entry-default-signed.hap (development signed).
- Blockers: AGC SKU confirmed as RemoteDesktop_Pro_Test (non-consumable, saved draft); sandbox device configuration and trusted verification backend pending. No HDC target connected; no real-device visual or checkout success claimed.
- Next: configure sandbox SKU and debug device, test sheet/checkout/cancel/reopen/order query; integrate verified fulfillment, account lifecycle, persistent verified offline grants and refunds before production. Stay on this local branch while those items remain open.
- UI follow-up: remove extra Pro wrapper border/shadow, normalize preceding row gap to 10, add original monochrome gem icon using the shared 21-size icon slot; prefill exact user-provided sandbox SKU. Same reviewer passed 6690cdbf; both Hvigor gates PASS (10 s 495 ms / 11 s 292 ms), Light PASS; visual device acceptance pending.
- Skill delivery (2026-09-07): API 26 project skill completed at `b6f156878`; 19 files, 286 validated links, 51 public milestones and 187 indexed documents. Independent package/scenario review PASS; required compile BUILD SUCCESSFUL in 14 s 568 ms; signed assembleHap BUILD SUCCESSFUL in 14 s 22 ms; Light/diff checks PASS. [Report](archive/2026-09/2026-09-07-project-development-skill.md). Other active task work and device blockers remain separate. Metadata closure gates also returned exit 0: compile BUILD SUCCESSFUL in 20 s 912 ms; assembleHap BUILD SUCCESSFUL in 12 s 450 ms. This extra pair overlapped the video task build window; the prior exclusive pair remains the skill baseline.
