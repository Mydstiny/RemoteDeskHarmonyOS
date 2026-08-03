# Shared Current State

This file is the compact startup resume card. Historical checkpoints remain in
`docs/codex/archive/2026-08/`; read them only when the active state links them.

## Active Task

- Task: `rustdesk-complete-repair` (active branch retained; RustDesk/VNC background, PIP, and audio continuity)
- Branch: `codex/rustdesk-complete-repair`
- Checkpoint: `28f8608f6`, based on `main@34946adbc`; branch is ahead by 84 and not behind.
- Phase: background continuity closure. RustDesk classifies transient transport failures, reconnects after network recovery with a presented-first-frame gate, and fences stale callbacks; VNC uses the shared active-session registry, PIP renderer transfer, raw framebuffer refresh, and foreground rebind.
- Worktree: repair commits are present and the worktree is clean. No duplicate reviewer task was started; preserve unrelated user changes.
## Stage A Result

- Frozen VNC endpoint/trust owner, certificate preflight, probe lifecycle,
  host defaults, shared-wheel authority, and one-shot pin policies.
- Stage A review: `PASS` at `73334a260` by independent review session
  `019fc333-6789-7633-bf6f-3fea1cb2ad4d`.
- Review scope is limited to VNC policy/test files declared in `STATE.json`;
  no RDP, RustDesk, SSH, renderer, or video-performance files.

## Stage B Result

- Review: `PASS` at code checkpoint `3167f610a` by independent task
  `019fc333-6789-7633-bf6f-3fea1cb2ad4d`.
- Verified async DNS, unified DNS/TCP/TLS deadline, TLS cancellation/error
  codes, bounded certificate metadata, worker-only teardown, N-API cleanup
  fencing, resolver exception boundaries, and trickle-handshake regression.
- Remaining evidence gaps are OHOS NAPI teardown, `ohosTest`, `hdc`, real
  direct/Repeater endpoints, and later Sheet/TrustService integration.
## Next

- Stage C first segment: pure certificate Sheet action/lifecycle policy and
  registered Hypium suites are implemented and independently PASS at
  `36a8cbe57` (receipt `vnc-v3-stage-c-sheet-policy-pass-36a8cbe5`).
- Stage C second segment: `RemoteDesktop` now wires the resolver, async probe,
  three generations, five-state certificate Sheet, password ordering, owner/
  endpoint-bound trust, and one-shot pin handoff. The prior review findings for
  Gateway trust persistence, Sheet close/routing, account generation binding,
  sensitive cleanup, and legacy trust writes are fixed at checkpoint
  `0d12ca1aa`. The follow-up endpoint hardening at `0e662e94a` binds TLS mode
  into the endpoint fingerprint, rejects trust rows from another physical
  store, and registers the resolver suite in both test runners. The latest
  `7d26f3716` checkpoint downgrades stale-store list views and makes legacy
  trust queries endpoint-bound, with Repeater TLS binding coverage.
- The existing reviewer task `019fc333-6789-7633-bf6f-3fea1cb2ad4d` passed the
  `fc9daa13f` manager segment; reuse it and do not start FreeRDP before VNC V3 closes.
- Stage D checkpoints cover endpoint-bound manager lookup, multi-target recheck,
  v1 migration read-back/rollback, endpoint invalidation, and backup/cloud marker
  separation; all remain VNC-only.
- Stage D follow-up checkpoint `8f45bbf37` invalidates device-local VNC confirmation
  markers after committed host/Gateway endpoint changes or deletion, keeps old
  trust rows as unconfirmed candidates, and makes backup/cloud manifests explicit
  that VNC candidates may be carried only in full mode while local markers never
  cross the device boundary. New policy tests are registered in both suites.
- Checkpoint `bb2352fcc` closes the follow-up review findings: Preferences marker
  writes now return explicit outcomes, invalidation uses a journal/marker/journal-
  clear commit contract, stale journals fail closed on restart, store-bound marker
  removal is explicit, and full-backup restore tests keep local markers device-local.
- Checkpoint `1a21488a7` preserves the recovery sentinel until marker clearing is
  confirmed, and adds adapter-backed marker-write, journal-remove, retry, and
  restart fail-closed tests.
- Checkpoint `f16b673e2` continues marker clearing when the recovery journal's
  first write fails, then derives health from the durable marker/journal end
  state and tests clean restart recovery.
- Checkpoint `590a5639c` applies the shared default resolver to modern VNC
  creation and clears default Gateway references when a Gateway is removed or
  disabled; invalid references still fail closed to direct TCP.
- Checkpoints `1b5eba5`–`68f5253` add current-account mode12 Gateway selectors
  to both settings surfaces, service validation, and retryable cleanup gating.
- Stage E final review: `PASS` at `68f5253a` by the existing independent
  reviewer; no P0/P1/P2 findings. Remaining gaps are live device/ohosTest
  evidence and runtime tests for service rejection/cleanup rollback.
- Stage F checkpoint `f4f4760` adds `VncGatewayHealthPolicy` with local-only
  `UNTESTED`/`TCP_REACHABLE`/TLS/banner/pairing/RFB stages, requires
  `deepCheckAttempted` before protocol claims, registers both test suites, and
  updates the Gateway TCP UI wording to state that a reachable port is not a
  verified protocol path. Native loopback fixtures cover fragmented mode12
  banner reads, exact 250-byte pairing, RFB handoff, and invalid-banner
  fail-closed behavior, and asserts invalid banners cause zero pairing bytes;
  no native deep-test API is fabricated.
- Checkpoint `c31607c` adds the native `probeVncGatewayDeepAsync`/
  `cancelVncGatewayDeep` contract, shared N-API cleanup fencing, strict
  mode12/target validation, TLS pin-required/changed/cancelled result mapping,
  RFB banner-only handoff, and a VNC Gateway management-page deep-test action
  bound to the live account/store endpoint resolver. It never sends credentials,
  ClientInit, or framebuffer data; the action can cancel an in-flight check.
- Checkpoint `ef4c33a` fences deep-check results by request/attempt generation,
  revalidates live endpoints, and preserves stable `E-VNC-CERT-*` errors.
- Checkpoint `5885588` gates VNC renderer startup on a ready current SurfaceId;
  transient loss resets the connect attempt and polls instead of using Pbuffer.
- Checkpoint `fa886f37d`/`763dc35d1` closes RustDesk first-frame, session-registry,
  background restore, and audio continuity gaps. Checkpoint `f03c9b4ca` extends
  the same lifecycle to VNC, including raw BGRA renderer/PIP transfer and a
  presented-frame gate before declaring restore complete.
- Checkpoint `28f8608f6` closes RustDesk transient network continuity: abort,
  reset, broken-pipe, timeout, and unreachable failures reconnect after network
  recovery; generation/owner/admission fencing prevents stale callbacks reviving old sessions.
- Keep every VNC caller fail-closed when the probe, Sheet lifecycle, owner
  binding, or expected-pin handoff is missing or stale.
## Verification
- `rdp_native_tests`: 251 passed, 0 failed with loopback fixtures on `f03c9b4ca`, 2026-08-03 (requires host-socket permission).
- RustDesk native/callback tests: 216 passed, 0 failed on `28f8608f6`, 2026-08-03.
- `default@OhosTestCompileArkTS`: passed after `28f8608f6` on 2026-08-03; host Cargo was exposed to CMake program search.
- `assembleHap`: passed after `28f8608f6` on 2026-08-03.
- `git diff --check`: passed after `28f8608f6` on 2026-08-03.
- `ohosTest@OhosTestCompileArkTS`: unavailable; task is not registered (`00306054`); new ArkTS tests have compile/build evidence only.
## Blockers
- `hdc list targets`/`hdc shell` remain unavailable (no target/current hilog
  evidence); real-device/endpoint evidence is not claimed.
- Stage B native probe has host fixtures for certificate, TLS, DNS, pin, RFB,
  timeout, and cancellation paths. NAPI teardown, Sheet lifecycle, TrustService
  migration, real Repeater, cloud, and device matrices remain unverified.
- Stage C/D/E UI, CloudStore, Preferences restart, Stage F deep-check, RustDesk
  audio, and RustDesk/VNC background/PIP lifecycle behavior remain
  static/build-tested only; no device evidence is claimed.

## Review Protocol
- Machine state: `docs/codex/STATE.json`; receipts: `docs/codex/REVIEW_RECEIPTS.jsonl`.
- `scripts/sync_workspace.sh status` records RESUME_REVIEW for the existing task owner; no duplicate audit was dispatched.
