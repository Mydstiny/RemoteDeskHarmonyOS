# Shared Current State

Updated: 2026-07-31 Asia/Shanghai

## Current cloud store-name root fix (2026-07-31, local main)

- Root cause of `setDistributedTables` 14800000: OpenHarmony RDB cloud sync
  requires the local store id (StoreConfig.name without `.db`) to equal the
  AGC cloud schema `database.name`. 1.0.7/1.0.8 both opened `remotedesktop.db`
  (verified from the released HAP abc bytecode; no account-scope code in
  either), while the 1.0.9/1.0.10 account-scope physical store
  `remotedesktop_owner-<sha256>.db` has no matching AGC cloud database, so
  `CreateDistributedTable` fails and every registration attempt returns
  14800000 even for single-table probes.
- Fix on local `main` (commits `961b698`, `3c8aa76`, `88e0ff3`):
  - Verified huawei_account scopes now open the canonical cloud store
    `remotedesktop.db`; unverified accounts keep local-only hashed stores and
    device-local stays `remotedesktop_device_local.db`, all cloud transfer
    fail-closed (`bound` only).
  - `LegacySharedStoreMigrator` gained an account-scope source kind:
    ownership-checked row copy, tombstone deletions (deleted hosts cannot
    resurrect), crypto single-owner gate, localmetadata safety carryover
    (barriers/checkpoints/restore quarantine), and legacy unionID → ownerScope
    normalization; legacy self-migration is skipped when source==target.
  - Canonical store admission control falls back to the local hashed store
    when the canonical store belongs to a different account on the same OS
    user (privacy preserved, cloud stays off for that scope).
  - Diagnostic `probeCloudRegistrationSubsets` removed before release.
- Verification on `88e0ff3`: `default@OhosTestCompileArkTS` BUILD SUCCESSFUL,
  signed `assembleHap` BUILD SUCCESSFUL (both non-daemon), Light
  open-source-compliance PASS, `git diff --check` PASS. Policy tests updated
  for canonical/hashed store selection and account-scope migration policy.
- External blockers remain: real API 23 device re-test after install
  (hdc offline at closure), and AGC `vncrecord` table has no dedup primary key
  (user-confirmed; does not block registration, but conflict/dedup semantics
  on the cloud table should be fixed in AGC console).

## Current RustDesk login/relay-save closure (2026-07-31, merged to local main)

- Branch `codex/rustdesk-control-plane-v3` was fast-forward merged into local
  `main` (no remote fetch/push/PR). Final merge commit is `53afa3bea`; the
  task branch was deleted after the merge. Changes carried by this closure:
  - `14f4e08` account-scope: relay save/startup DDL no longer wrapped in an RDB
    transaction (real-device OpenHarmony RDB does not materialize tables inside
    `beginTransaction`, which caused ALTER `14800021`); every DDL/ALTER step is
    tracked by `schemaStep` so a failed migration reports the failing table;
    batch `setDistributedTables` failure is probed by subsets to separate
    `vncrecord`-specific from global/platform causes; a valid Huawei binding
    with unavailable distributed cloud stays locally usable instead of blocking
    login with a doomed startup pull; LoginPage awaits account-session
    readiness before silent-restore/first-launch/login/offline transitions.
  - `096de8b` Pro login HTTP 400 fallback: `/api/login` retries exactly once
    with the official minimal `username`/`password` body when the extended
    device-registration payload is rejected with 400. Other statuses and
    transport failures propagate unchanged; strict 2xx parsing is preserved;
    400 is labeled as a contract mismatch instead of a generic failure.
  - `8acb5b6` address-book legacy fallback: `/api/ab/personal` and
    `/api/ab/shared/profiles` now treat 400/405 the same as 404 (modern API
    not implemented) and fall back to legacy `/api/ab/get` / `/api/ab`;
    401/403 and transport failures stay authoritative.
  - `53afa3b` control-plane token projection: the trusted attestation registry
    was empty and no adapter ever issued a proof, so official-server-pro and
    third-party-control-plane connections deterministically fell back to
    api_only and withheld the token; hbbs/hbbr then rejected the relay request
    with `please login` even after successful `/api/login` + address-book sync.
    `resolveRustDeskConnectionContext` now projects the HTTP access token when
    either a trusted attestation matches or the binding-identity check passes
    (same API origin, valid rendezvous/relay endpoints, intact server key,
    matching token fingerprint/generation). OSS key-only/shared-key and
    third-party-api-only profiles still never project the HTTP token; a
    mismatched API origin fails closed (`capability_unverified`, token never
    sent). This aligns the app with the official RustDesk client, which reuses
    the `/api/login` access token as the control-plane token on the same
    deployment.
- Verification on the final main state (`b8308ced3`): `default@OhosTestCompileArkTS`
  and signed `assembleHap` both BUILD SUCCESSFUL (non-daemon, explicit exit 0);
  policy unit tests updated for the new projection semantics; native
  `rdp_native_tests` 178/178 (host binary); focused Rust `relay_connect` 2/2
  (sandbox-external); Light open-source compliance passed via the
  repository-local `.tools/bin/pwsh` runtime. Host cargo lib tests still cannot
  link on this Mac (no host `libopus`) and remain a recorded environment
  blocker, not a pass.
- The user-reported relay symptoms decompose into distinct layers:
  1. `/api/login` HTTP 400 on the hosted panel -> fixed by the minimal-body
     fallback in `096de8b` (deterministic, server-driven).
  2. Connection failing at `RequestingRelay` (`please login` / server refused)
     after a successful HTTP login/address-book sync -> root cause was the
     empty capability-attestation registry withholding the token from
     PunchHoleRequest/RequestRelay. Fixed in `53afa3b` via binding-identity
     gated projection. Real-endpoint A/B against the 超享 panel is still
     required to confirm the wire contract before release (NO-GO without it).
  3. OSS key mode: the form always defaulted to `server_public_key`; shared
     `-k` requires the explicit `shared_access_key` selection (OSS profiles
     never project the HTTP token by design).
- Independent D-020-style review of this closure was completed; remaining
  acceptance (real 超享 panel login+sync+connect, official Server Pro,
  password/approval/2FA, P2P/relay/direct, API 23 lifecycle, multi-device
  cloud matrix) is NO-GO until a real device/endpoint pass.

## Current cloud-account startup fix

- `main` includes a local fix for the production-reported `accountkit account mismatch` login block:
  AccountKit 登录不再在 `平台分布式身份无法独立验证` 时阻塞应用进入华为账号本地作用域；
  应用仍会打开该账号的本地数据库，并继续提供本地读写能力。
- 云端启动仅在 `cloudTransferAllowed(bind)` 为真时执行 `requestStartupPull`，
  否则保持 bootstrap ready 隔离，先以本地作用域运行，不上传/不下发云数据。
- 本地恢复流程将“未建立本地作用域”改为独立错误码 `account_scope_required`，
  停止将未登录前置状态误报为“备份属于其他华为账号”；只有在读取到真实
  `owner` 冲突时才返回 `owner_mismatch`。
- `default@OhosTestCompileArkTS`、`assembleHap`、`git diff --check` 通过；
  未完成 `Light` 合规执行（当前环境缺少 PowerShell 运行时）。
- 该修复未改变“未绑定/验证失败时的 cloud-first” fail-closed 约束；API 23
  真实证据仍是设备测试的 NO-GO 前置。

## Current VNC settings Sheet crash hotfix

- `codex/vnc-settings-sheet-crash-hotfix` is based on local
  `main@bfea42cb0`; its independently reviewed implementation checkpoint is
  `0455966`.
- The API 23 crash report identified `Cannot read property bind of undefined`
  at `VncSettingsSheet.ets:725`. All VNC settings entries shared the same
  failure: a parent `@Builder` method was passed directly through
  `@BuilderParam`, so ArkUI rebound `this` to `VncSheetScaffold` and the
  settings owner state/methods were unavailable at runtime.
- VNC settings, VNC host add and VNC Gateway add now pass lexical arrow
  closures into the shared scaffold. Generated ArkTS keeps those closures in
  both construction and params-generator paths, so the scaffold's later
  `.bind(this)` cannot replace the parent owner.
- The VNC settings accordion now derives a `760vp` maximum from its eleven
  `62vp` action rows, ten dividers and section chrome instead of clipping the
  final Gateway entry at `620vp`. The policy test covers the current row count,
  exact height and monotonic growth.
- Independent review returned PASS with no P0/P1/P2/P3. The mandatory
  `default@OhosTestCompileArkTS`, signed `assembleHap`, Light compliance,
  generated-code inspection and `git diff --check` pass.
- No HAP was installed and no device data was changed. Release evidence still
  requires API 23 clicks through all eleven VNC settings entries, save/no-save
  footer paths, VNC host/Gateway add flows, large text/breakpoint layout and
  RDP/RustDesk/SSH isolation smoke tests.

## Current RustDesk multimonitor switch result

- `codex/rustdesk-multimonitor-switch-hardening` is based on local
  `main@1615aff58`; its independently reviewed implementation checkpoint is
  `0d6c7fd0b`. After this documentation/build closure it is merged into local
  `main` and the task branch is deleted.
- Entity plan:
  `docs/superpowers/plans/2026-07-30-rustdesk-multimonitor-switch-hardening-quick-fix-plan.md`.
- The single-canvas product boundary is retained while the controlled peer can
  expose multiple displays. A switch releases held keyboard, mouse and touch
  input, removes coalesced old-screen movement, blocks new input, sends the
  official latest-wins switch/capture/refresh transaction and adopts geometry
  only after the exact target ACK and target keyframe.
- Rapid selections retain only the latest generation. Stale display ACKs,
  frames and PeerInfo updates cannot restore an old target; invalid or offline
  current-display state falls back to the first online catalog display.
- Native display publication and matching frame delivery are serialized
  against the next generation. Capability polling, switching, input and
  teardown pin the opaque Rust FFI handle, so stream-ended or explicit
  disconnect cannot free it during an in-flight call.
- Timeout notification keeps input blocked but permits an explicit retry of
  the same target with a fresh generation. Disconnect and session replacement
  reset both native and ArkTS switch state.
- Independent review returned PASS at `0d6c7fd0b` with no remaining P0/P1/P2.
  Native host tests are `178 passed, 0 failed`; focused Rust display/control
  tests passed; `default@OhosTestCompileArkTS`, signed `assembleHap`, Light
  compliance and `git diff --check` pass.
- No HAP was installed and no real endpoint was controlled. Release remains
  NO-GO pending API 23 testing against a real multi-display RustDesk peer,
  including rapid switching, timeout/retry, monitor unplug/offline fallback,
  reconnect and keyboard/mouse/touch release behavior.

## Current RustDesk control-plane v3 result

- `codex/rustdesk-control-plane-v3` was based on the user-authorized local
  `main@d0e6ffee2`. The independently reviewed implementation checkpoint is
  `d404178b1`; after the documentation/build closure it is fast-forward merged
  into local `main` and the task branch is deleted.
- Entity plan:
  `docs/superpowers/plans/2026-07-29-rustdesk-control-plane-official-parity-complete-plan-v3.md`.
- RustDesk relay create/edit now has structured save stages and error codes,
  one production RDB transaction for relay/profile/journal, stable-ID
  read-back, idempotent attempts, draft preservation and retryable cloud status.
  Local commit success is not rolled back merely because cloud upload is
  pending or failed.
- The three relay-add surfaces converge on one RustDesk setup owner. The
  default path asks only for import or server address plus public key; ports,
  API, shared `-k` and control-plane profile are progressively disclosed.
  Fixed actions remain reachable with keyboard/safe-area adaptation, and a
  host-add draft returns once to the new relay without persisting its password.
- HTTP address-book login, official/third-party control-plane capability,
  shared `-k`, Ed25519 server public key and direct-IP are separate profiles
  and credentials. Profile selection, generic `/api/login` and successful
  address-book sync cannot mint rendezvous capability. The trusted issuer
  registry is intentionally empty, so unverified official/third-party
  profiles run as API-only and project no HTTP token into
  `PunchHoleRequest`/`RequestRelay`.
- A connection may bind API, ID and Relay to three different hosts. The HTTP
  API is bound to the account that obtained the token; owner, account, relay,
  token generation/fingerprint, both native endpoints and server identity are
  independently fingerprinted. Old local proofs and fabricated schema-v2
  proofs fail closed.
- `please login` and `login session expired` text never clears a valid HTTP
  account. Session invalidation requires an effective official profile, a
  token actually projected in that exact attempt, a structured
  `control_plane/pro_session_expired` error and matching
  owner/account/token-generation fencing. API-only fallback retains login and
  address-book state even if native returns that structured code.
- FORCE_RELAY and DIRECT_IP are explicit end-to-end strategies. AUTO, NAT
  probing and P2P-to-relay fallback remain fail-closed because the repository
  does not yet have sufficient server/wire/device evidence; no P2P success is
  fabricated.
- Diagnostics use static route IDs and irreversible short fingerprints.
  NetworkKit raw errors, URL/query/GUID/body, token, password, Key, full
  endpoint, account and peer/host identifiers do not enter task diagnostics.
- Independent D-020 review finished with PASS at `d404178b1`, with no remaining
  P0/P1. Native host tests are `171 passed, 0 failed`; Rust unit tests are
  `151 passed, 0 failed`; both mandatory Hvigor gates, signed HAP, Light
  compliance and `git diff --check` pass. `ohosTest` remains unavailable as
  unregistered task `00306054`.
- Candidate metadata is `1.0.10 / 1000010`. The connected API 23 device remains
  on `1.0.8 / 1000008`; no install or user-data mutation was performed.
- Local code is complete, but release remains NO-GO pending real official
  Server Pro, 超享/third-party, OSS hbbs/hbbr, password/approval/Peer 2FA,
  P2P/relay/direct, API 23 lifecycle and multi-device cloud matrices.

## Repository

- Repository: Mydstiny/RemoteDeskHarmonyOS
- Active task branch: none after the VNC settings Sheet hotfix local closure.
- VNC settings Sheet hotfix base: local `main@bfea42cb0`; independently
  reviewed implementation checkpoint: `0455966`.
- Scope: VNC-only BuilderParam owner preservation and complete settings
  accordion expansion.
- RustDesk multimonitor base: local `main@1615aff58`; independently reviewed
  implementation checkpoint: `0d6c7fd0b`.
- Scope: RustDesk display-switch input fencing, generation/ACK/keyframe
  confirmation, online fallback and FFI handle lifecycle safety.
- Entity plan:
  `docs/superpowers/plans/2026-07-30-rustdesk-multimonitor-switch-hardening-quick-fix-plan.md`.
- Cloud/data lifecycle D-020 and VNC V2 were already fast-forward merged into
  the local base; RustDesk control-plane v3 is also already merged. Their
  owners and accepted behavior were not rewritten.
- No remote push, PR or remote-main merge is authorized or performed.
- The merged task branch is deleted during this closure; unrelated SSH,
  Moonlight, RDP and RustDesk controlled-host plan files remain untouched in
  the working tree.

## Current VNC V2 result

- VNC settings, modern host add and Gateway add use a VNC-only Sheet scaffold
  with fixed header/footer, scroll-bounded body, large Sheet sizing and
  `RESIZE_ONLY` keyboard avoidance. Modern host and mode12 Gateway flows are
  two-step; existing RustDesk relay builders and other protocol Sheets are
  unchanged.
- The Sheet scaffold now measures its production viewport and switches through
  regular, compact and action-only densities. When the keyboard or a very short
  window cannot fit the full header, the fixed VNC footer remains the priority;
  no-footer directory Sheets keep their existing layout.
- The desktop `xl` classic FAB path hydrates VNC defaults through the existing
  VNC settings owner before opening the editor. Modern VNC and every non-VNC
  protocol retain their existing routing.
- The VNC session exposes a discoverable toolbar for keyboard, control mode,
  shortcuts, display, HUD, console and disconnect. View-only state is
  explained. VNC toolbar/HUD/position state is namespaced and does not consume
  RustDesk settings or entitlement state.
- Modifier/shortcut panel opening is generation-fenced through the control
  Sheet `onDisappear`. The panel completes one invisible measurement pass
  before placement and uses a viewport that accounts for VNC toolbar,
  keyboard and HUD; previously accepted per-orientation ratios remain intact.
- Native RFB now requests Cursor `-239`, validates dimensions/hotspot/pixel
  payload/mask, publishes the shape through the existing generation-safe
  cursor store and retains the local fallback.
- Native RFB now advertises bounded ZRLE `16` for auto/zrle, retains Raw and
  CopyRect fallback, keeps one inflater per connection, validates compressed
  and decompressed bounds, tile/palette/run/pixel arithmetic, and reports the
  effective source encoding to the VNC HUD. Tight and ContinuousUpdates remain
  disabled.
- Soft-keyboard text is strict UTF-8 converted to bounded RFB KeyEvent
  down/up pairs and no longer uses ClientCutText. Clipboard policy controls
  clipboard synchronization only; view-only still blocks all remote input.
- Session video callbacks weakly reference their `SessionContext`, and both
  synchronous and asynchronous connect-failure cleanup use the common callback
  teardown path before session ownership is released.
- Production links the API 23 system `libz.so`; host tests use `ZLIB::ZLIB`.
  License, NOTICE, provenance and SPDX SBOM are updated without claiming the
  host zlib version as the device runtime version.
- No cloud physical schema or payload field changed. `vncrecord` remains the
  sole VNC cloud table and runtime/effective capabilities remain device-local.

Implementation commits: `e3c3fd7b7`, `6fd0e4539`, `6e47c052c`,
`b742f7b12`, `90f51eed9`, `e1e23ebd6`, `d17976c10`.

## Completed VNC verification and release blockers

- Native host tests: `171 passed, 0 failed`.
- `default@OhosTestCompileArkTS`: passed after `d17976c10`.
- `assembleHap`: passed and signed after `d17976c10`.
- Light open-source compliance and `git diff --check`: passed.
- The independent D-020 audit found four actionable gaps: VNC text was
  incorrectly routed through ClientCutText, a synchronous failure callback
  cycle, missing desktop-classic VNC default hydration and an unwired
  extreme-height Sheet policy. All four are remediated in `d17976c10`.
  The same reviewer completed the remediation, RAW_BGRA lifecycle,
  non-VNC isolation and system-zlib ABI audit with an explicit PASS and no
  remaining P0/P1/P2. The local merge gate is satisfied.
- `ohosTest@OhosTestCompileArkTS` remains unavailable because task `00306054`
  is not registered; no device-test success is claimed.
- Release remains NO-GO until this exact HAP passes API 23 layout/input,
  macOS continuous-frame/Cursor/Retina ZRLE, TigerVNC and
  UltraVNC/LibVNCServer interoperability, other-protocol regression and the
  one-/two-device/account-switch cloud matrix.

## Completed cloud-data lifecycle baseline

- AccountKit initializes before account-dependent storage. Login/logout/account
  switch use an awaitable account transition with generation fencing and
  sensitive-cache/session draining. A Huawei-account scope now also requires a
  fresh `DISTRIBUTED_DATASYNC` permission check and
  `getOsAccountDistributedInfo()` proof. API 23 exposes no signed correspondence
  object, so only exact current Account Kit UnionID/distributed-account ID
  equality is accepted; every unavailable, denied, logged-out or mismatched
  result fails closed before distributed-table registration.
- Anonymous data and each Huawei owner use separate physical store identities. Only a verified bound account store can register distributed tables or transfer cloud data; service-layer CRUD injects and checks owner.
- Login and account-switch navigation now waits for the current account's first
  cloud-first bootstrap. The ready/mutation gate is not published until the
  authoritative pull and durable selection-reenable promotion complete. A
  `restored_not_uploaded` scope returns an explicit `restore_pending` failure:
  restored rows remain quarantined, no pull or automatic upload is attempted,
  and the account is not published as ready.
- Initial bootstrap reconciles pre-bootstrap intent at record level and retains
  its mutation journal. Manual download, initial bootstrap and selection
  re-enable share an account/store/generation-bound, SHA-256-verified and
  size-bounded persistent before-image; an interrupted process rolls it back
  on the next physical-store open.
- Cloud sync has a scoped durable lifecycle, one queue, cloud-first and durable
  selection re-enable barriers, per-table mutation journal/retry/conflict state,
  accepted/progress/overall watchdogs, `SYNC_FINISH` validation and stale/late
  callback fencing. Native-first cannot pass a pending selection barrier,
  including VNC promotion/retry paths. Newly enabled VNC logical scopes now
  await their dedicated cloud-first, record-level reconcile/promotion and
  barrier release before settings save reports success; disable-only changes
  do not trigger a pull, and failed row/selection changes restore the prior
  scope and exact prior barrier when rollback is proven. VNC re-enable now has
  its own owner/store/generation-bound, SHA-256-verified persistent checkpoint:
  after cloud-first it rebases to an authoritative before-image containing the
  exact cloud mirror, deterministic settings row, mutation journal/retry state,
  selector and barrier. Promotion, phase persistence, barrier release and
  checkpoint deletion share one RDB commit; upload is queued only after that
  commit. The entire VNC settings mutation, its checkpoint establishment,
  cloud-first, promotion/finalization and any full-store rollback now execute
  as one coordinator queue item under the same account/store/generation lease;
  ordinary, event and retry sync requests cannot overlap the restore and the
  next queue item waits for it to finish. A failed commit restores the
  before-image while upload stays blocked. The startup code has a durable
  recovery path for process interruption, but real kill/reboot/low-storage
  evidence remains an external release blocker. Incomplete restoration retains
  the checkpoint and pending barrier and enters a distinct
  `recovery_required` phase that an unrelated late cloud callback cannot
  release.
- Selection cloud-first completion now rebases the authoritative VNC
  checkpoint, replays only the captured local mutation journal and deletes the
  ordinary download checkpoint in one RDB transaction. A process stop before
  that commit leaves both old checkpoints; a stop after commit leaves only the
  authoritative VNC image. Pure fault-injection tests cover rebase-write
  failure, commit kill-points and the post-commit authoritative recovery image.
- Security metadata reads are strict `present` / `absent` / `error` results.
  A `querySync` exception is never treated as an absent checkpoint or barrier:
  it blocks native-first, promotion, automatic retry, bootstrap publication and
  post-commit upload success. Critical checkpoint, barrier, durable lifecycle
  and bootstrap writes also require a matching read-back before advancing.
- Implementation-level ArkTS coverage now instantiates the production
  `CloudSyncCoordinator` queue with a controlled clock and real request paths,
  proving that cloud events, retries and automatic uploads wait behind an
  exclusive VNC mutation/restore and that an invalidated lease fails closed.
  VNC authoritative-completion and finalization are private `CloudStore`
  entries; tests cannot invoke a lease-free production RDB mutator. Both
  private entries and startup recovery call one stateless lifecycle wiring
  module that owns no singleton or RDB handle. Its tests feed query exceptions
  through `CloudStore.readLocalMetadataState`, validate the real
  owner/store/generation/hash-bound checkpoint parser and barrier JSON parser,
  check one begin/commit boundary with rollback at every pre-commit fault, and
  simulate restart delivery of a committed authoritative checkpoint to the
  pending-recovery callback. Post-commit checkpoint or barrier query errors
  block upload instead of being treated as absence.
  Barrier JSON is also semantically strict: only an ordinary object with no
  `vncrecord` key is absent, while a present key must contain one of the three
  allowed phases. Invalid values and non-object JSON block pre-commit
  promotion and post-commit upload. Startup and in-process rollback now share
  the same production adapter for snapshot restoration, selector persistence,
  lifecycle settlement, barrier/checkpoint transaction and read-back.
  Fault-injection verifies successful checkpoint deletion and checkpoint
  retention plus `recovery_required` marking on restore/delete/commit failure.
  The final startup-wiring gap is closed in `0c0b3d4`: a detached, RDB-free
  verification store calls the real `CloudStore.init` / `openScopeStore`
  startup gate, which constructs the same private production adapter and
  `CloudStoreStartupRecoveryRunner`. Tests inject only bottom-level I/O and
  therefore fail if the startup call, snapshot restoration, VNC table routing
  or exact checkpoint deletion is removed or miswired. The capability cannot
  obtain or mutate the production singleton's RDB, and no lease-free
  CloudStore recovery mutator was exposed.
- Final independent D-020 review at `c88fc2968` confirmed the real isolated
  `CloudStore.init` / `openScopeStore` startup path, private production
  adapter, readiness/checkpoint failure behavior and external NO-GO ledger;
  the cloud/data lifecycle branch is approved for local fast-forward merge.
- A zero-row cloud-first result is accepted only after the independently bound
  account, distributed-table registration, current lease and exact table's
  successful terminal progress jointly prove an authoritative result. This
  allows a legitimate remote delete-all without treating an unproven empty
  response as authoritative.
- Native-first and cloud-first sensitive transfers validate encryption shape. Empty sensitive tables cannot become a remote wipe while encryption is inactive; plaintext or malformed nested secrets block the operation.
- Portable backup v3 is account-scoped and redacted, distinguishes absent/empty/rows, supports legacy seven-table partial merge, preserves newer missing fields, validates hashes/owners/VNC rows and retains `restored_not_uploaded` until explicit cloud upload. System BackupExtension remains disabled with `allowToBackupRestore=false`.
- Crypto enable/migrate/disable/reset use an exclusive account lease, queue quiescence, durable lifecycle state, one RDB transaction, selection pause and journal replay. Remote destructive crypto lifecycle and old REST sync remain feature-gated off.
- AccountKit and RustDesk Pro credentials use the Asset Store Kit boundary.
  RustDesk Pro scope transitions now remove outgoing token aliases before
  rebinding and drain token memory even when removal fails. Non-secret
  server/account/device metadata remains durable as `requires_login`, so a
  failed scope transition can reload the outgoing configuration without
  restoring the deleted token. Tokens remain excluded from Preferences, cloud
  and logs. RDP/SSH/VNC trust and plaintext consent are device-local and are
  removed from cloud/portable-backup projections.
- Legacy shared RDB migration uses owner proof, receipt, journal and redacted quarantine. Legacy relay JSON migrates transactionally. Legacy VNC rows only enter the local overlay; owner, reset epoch or payload failures are quarantined without deleting the source. The public no-lease full-table clear path was removed.

Implementation commits: `6a9d430b1`, `4cdc5b1df`, `d2f365c32`, `d51214577`,
`50ce7b36e`, `1d0f03848`, `d5ccaa73f`, `623cdd378`, `8fb395c41`,
`beebc662e`, `89f4b7574`, `f5adf90e7`, `8164dd5`, `2914363`,
`382fdaaa8`, `df2a6b4`, `88a6128`, `501565e`, `0ffaa1c`,
`0d6216e`, `0c0b3d4`.

## Cloud baseline verification

- The cloud-lifecycle checkpoint used `1.0.9 / 1000009`; the current RustDesk
  v3 candidate supersedes it with `1.0.10 / 1000010`, and application
  metadata, release notes, user guide and SBOM agree.
- `default@OhosTestCompileArkTS`: passed in the current session for
  `0c0b3d4`; existing dependency/deprecation warnings remain.
- `assembleHap`: `BUILD SUCCESSFUL` in the current session; signed HAP
  generated.
- `git diff --check` and staged diff checks: passed.
- Light open-source compliance: passed in the current session.
- Data-lifecycle policy/matrix and implementation-wiring tests, including the
  real coordinator queue/retry callback, CloudStore completion/finalization
  entry points, authoritative checkpoint kill-points and metadata tri-state
  fault injection, are included in the default ArkTS test compilation.
- `ohosTest@OhosTestCompileArkTS` remains unavailable because the task is not registered (`00306054`); no test execution success is claimed.
- A connected device was inspected read-only and currently has `1.0.8 / 1000008`. The `1.0.9` HAP was not installed because replacing an app that may contain real user data requires explicit authorization and a recoverable test procedure.

## Cloud external acceptance

- Release remains NO-GO until a real API 23 device proves whether current
  Account Kit UnionID and OS distributed-account ID have a trustworthy exact
  correspondence. If they use different namespaces, cloud remains intentionally
  blocked until an official stronger binding is available; no fallback to a
  cached or self-asserted identity is permitted.
- Release also remains NO-GO until real Huawei Cloud schema/permissions,
  authoritative empty/partial/denied tables, two API 23 devices, A/B accounts,
  offline conflict/tombstone, selection re-enable and late-callback behavior
  are recorded.
- Obtain upgrade fixtures from actually released APKs, including old shared RDB, RDP username/password shadow, legacy relay JSON, SSH/TOTP and old VNC tables; run process-kill/reboot/low-storage/fault-injection at each migration/backup/crypto stage.
- Validate portable backup with real Documents Providers and owner mismatch/corruption/truncation. System migration remains disabled unless a real BackupExtension import pipeline and two-device/replace-device evidence are added.
- Validate Asset Store Kit behavior and actual RustDesk Pro token alias removal
  on API 23 hardware across lock, logout, account switch, restart,
  uninstall/reinstall and restore.
- The final remaining P2 required the startup recovery test to bind the actual
  CloudStore initialization call and production adapter. It is addressed
  locally in `0c0b3d4`; no approval of this follow-up is claimed until the main
  agent performs the requested targeted review.

## Preserved user changes

- Unrelated user-owned SSH, Moonlight, RustDesk and RDP plan edits remain
  unstaged and were not included in the VNC commits.

## Previous implementation archive

- RustDesk Pro API login tokens now travel only through the transient connection path into the RustDesk rendezvous `PunchHoleRequest` and `RequestRelay` messages; the existing relay/shared key remains a separate credential and the token is not persisted in host records, uploaded to cloud metadata or written to logs.
- Pro host connections now validate account, server/relay and address-book binding before prompting for remote-device password or approval. Native connection errors are classified as Pro-session, device-password, approval, relay, peer or network failures so a real device-authentication failure is not reported as account expiry.
- RustDesk relay `relayPort` now flows from ArkTS through NAPI/C++ into the Rust FFI for both screen and file-transfer relay connections. A hbbs-advertised `relay_server:port` remains authoritative; the configured hbbr port is used only when that endpoint has no explicit port, with 21117 as the validated fallback.
- RDP keeps latest-value-wins dirty-rectangle presentation for small steady-state updates, while initial/full geometry and medium-to-broad refresh bands enter a visual commit fence: a 40 ms quiet period or 160 ms deadline commits the accumulated frame as one presentation, and a 750 ms continuation episode uses a 200 ms quiet period with a 600 ms deadline so sustained page refreshes do not fall back to strip-by-strip presentation. Small cursor/toolbar updates remain dirty-only.
- RDP canvas transform redraws now present the already-uploaded retained texture at a latest-value-wins 60 Hz ceiling. Transform updates no longer request a FreeRDP full snapshot, retained-frame copy or `glTexSubImage2D`; a due real source frame still takes priority and ordinary damage presentation remains unchanged.
- Canvas zoom remains off by default. When enabled outside keyboard/mouse mode, early two-finger movement remains touchpad scroll, a stationary two-finger release remains right-click, and a two-finger hold of about 0.4 seconds followed by movement pans only a locally overflowing canvas. RustDesk remote-app TouchScale stays an explicit opt-in and uses the same hold gesture for remote TouchPan without requiring local overflow.
- RustDesk raw TouchEvent, transparent-overlay gesture fallback and terminal drain now share one remote touch lifecycle: held pan sends one TouchPan start followed by deltas and one end; overlay-only remote pinch also enters the pinch lifecycle so it cannot leave the peer touch sequence active.
- SSH settings now has one dedicated accordion immediately after Windows RDP and RustDesk, and before 数据安全. Terminal foreground color and font size were removed from 个性化 and are now owned by `SshSettingsService` through namespaced keys with legacy aliases.
- SSH settings exposes terminal appearance, preview/default reset, SSH host and key-vault shortcuts. SSH host fingerprint management was deliberately not migrated: 数据安全 and the existing per-host preflight remain the only trust-management path.
- SSH settings continue to use existing `usersettings`, `RemoteHost`, `SshKey` and `KeyVaultService` owners; no SSH cloud table or sensitive global setting was added. RDP, RustDesk and VNC owners were not changed.
- VNC now has its own settings page, model, host/gateway/secret/trust services and connection projection. It does not use RDP, RustDesk or SSH/SFTP data owners.
- The only new cloud table is `vncrecord`; `recordtype` carries `settings`, `host`, `gateway`, `secret` and `trust`. `vnclocalrecords` is device-local only.
- VNC remembered secrets use the context-bound AES-GCM v2 envelope when app encryption is unlocked. When app encryption is disabled, an explicit user confirmation may store a bounded `plain-v1` envelope; one-time credentials are never persisted. Secret sync remains opt-in and isolated to VNC's logical scope.
- `cryptoparams.vnc_reset_epoch` increments on crypto reset. New VNC rows bind to the current epoch; old rows, stale backups and stale rewrites fail closed.
- Native VNC supports RFB 3.3/3.7/3.8, VNC DES password, Raw/CopyRect/DesktopSize, BGRA, keyboard/mouse/clipboard and UltraVNC Repeater viewer mode12. The mode12 path validates `RFB 000.000\n` and sends the official fixed 250-byte `ID:<target>` field; mode2 remains a server-side repeater listener contract and is rejected by this viewer client.
- Cloud reads validate every VNC row, including the typed JSON payload, before projection; preserve unknown wire values for rejection; bind runtime merges to `userId + id`; and hide unselected or crypto-locked cloud secrets. Scope deselection never writes a reverse cloud tombstone; user deletion still uses an ordinary tombstone. Raw crypto migration follows the same selected projection.
- VNC settings saves apply and validate the new logical scopes before writing the settings row; a failed row write restores the previous scopes, so turning off settings sync cannot upload the row that disables it.
- Startup uses a durable cloud-bootstrap marker and a serialized cloud-first barrier. A new device cannot publish local defaults before its first authoritative pull; startup mutations are deferred and cloud events/foreground pulls share the same queue.
- The ordinary cloud-sync selector exposes the physical `vncrecord` table, while VNC logical scopes remain enforced by `VncCloudSyncSelectionStore`; manual ordinary upload/download cannot bypass that boundary.
- Host-list settings now has an independent top-level VNC accordion and the FAB exposes the same isolated VNC add flow in both modern and classic modes. Saving can persist a VNC owner and optionally route to `RemoteDesktop` for connection.
- The global “关闭加密” path now transactionally converts active VNC `encrypted_v2` rows in the local/current/legacy mirrors to explicitly confirmed `plain-v1` envelopes before clearing the DEK; a failed decrypt aborts the transition. VNC passwords/tokens are never silently downgraded or stranded.
- WebSocket gateway, public relay, SSH tunnel and reverse/listen remain explicitly unavailable until their server contracts are deployed and verified.
- VNC session runtime now aggregates complete framebuffer updates before presentation, keeps incremental refresh requests alive, presents initial and dirty BGRA frames through the active surface generation, and routes keyboard/mouse/touch/virtual-key/three-finger controls through the isolated VNC session policy. `getSessionDiagnostics` exposes VNC RAW BGRA frame age, presented-frame count and `presentationRejected`; the HUD shows 送显拒绝 so a first-frame-only failure can be distinguished from a server-side update stall.
- Modifier and shortcut panels persist user-dragged positions as ratios. Resize/orientation recomputes positions from the saved ratios without rewriting them during clamp; fallback geometry remains unready until a real surface size arrives, preventing click drift and cumulative repositioning.

## Verification

- Current relay repair gates: Rust `cargo check --tests`, focused relay socket tests (2/2), and `bash scripts/build_rustdesk_ffi_ohos.sh all` for `arm64-v8a` and `x86_64` all passed.
- Focused Rust relay socket tests: `cargo test --manifest-path rustdesk_ffi/Cargo.toml --no-default-features relay_connect` passed 2/2 outside the sandbox. They cover advertised explicit-port precedence and configured fallback-port use when the endpoint has no port.
- Focused native `rdp_native_tests`: `157 passed, 0 failed`.
- `default@OhosTestCompileArkTS`: passed for the current relay repair; existing repository/dependency warnings remain.
- Production `assembleHap`: `BUILD SUCCESSFUL` for the current relay repair and completed signing.
- Current VNC runtime tree also passed `default@OhosTestCompileArkTS` and signed production `assembleHap`; signed artifact: `entry/build/default/outputs/default/entry-default-signed.hap`.
- Native test target compiles the actual VNC transport and RFB engine plus the RDP damage/visual-commit tests and the VNC transport tests.
- `git diff --check` and `git diff --cached --check`: passed after the implementation and shared-state updates.
- Light open-source compliance gate: passed for the current relay repair via the repository-local `.tools/bin/pwsh` runtime.
- Full Rust `cargo test` remains host-blocked at link time because the local host does not provide `libopus`; this is not reported as a passing test.
- `ohosTest@OhosTestCompileArkTS`: not runnable in this environment because the task is not registered (`00306054`); this is an environment/task-graph limitation, not a source compile failure.
- Read-only SSH review: passed with no P0/P1/P2 findings; the reviewer confirmed the accordion order, the data-security-only fingerprint entry and no cross-module cycle.
- RDP/canvas repair: `default@OhosTestCompileArkTS` and signed `assembleHap` passed after each code checkpoint, including `69c6308`; the final HAP is `entry/build/default/outputs/default/entry-default-signed.hap`. An independent read-only reviewer found and verified fixes for raw remote held-pan routing and overlay-only remote pinch termination; final review found no P0/P1/P2.

## External acceptance still required

- RustDesk Pro: test against the real compatible Server Pro versions, including password and request-approval connections through relay, application restart, expired-token re-login, mismatched account/server/relay records, and 401/403/404/500 responses. Confirm the user-visible message is tied to the actual failing layer.
- RustDesk relay: validate real hbbs/hbbr advertised hosts, explicit ports, omitted ports with a configured non-21117 fallback, relay key modes and both screen/file-transfer paths. This remains distinct from the OSS/third-party-panel token absent/present A/B.
- RDP: test first desktop entry, Windows login desktop loading, browser/file-manager full refresh, window dragging, video, scrolling and 1080p/2K/4K devices. During canvas pinch/pan, confirm retained redraw metrics report transform presentation without a source full snapshot and that mouse/keyboard latency remains stable.
- Canvas/RustDesk touch: on API 23 hardware validate default-off zoom; local pinch then lift/re-touch/hold about 0.4 seconds/drag; early two-finger scroll; stationary two-finger right-click; RustDesk remote-app held TouchPan and normal pinch in both raw-touch and overlay-only fallback paths. `hdc` currently detects device targets, but this HAP was not installed or run because no installation authorization was given.
- User creates exactly one Huawei cloud table `vncrecord` with the 19 fields in the entity plan.
- Two API 23 devices using one Huawei account validate scope selection, secret opt-in, trust re-confirmation, user-deletion tombstones, reset epoch and offline recovery. Scope deselection must leave the shared row unchanged.
- Real VNC server validates direct TCP; a real UltraVNC Repeater validates viewer mode12 pairing, input, disconnect and reconnect. Mode2 requires a separate VNC server-side listener component and is not an enabled HarmonyOS viewer path.
- WebSocket/public relay/SSH tunnel remain gated until endpoint, authentication, trust and lifecycle contracts exist.
- SSH settings still require API 23 PC/phone/tablet UI smoke validation, including accordion order, appearance persistence and trust-entry location; no real host fingerprint is auto-trusted by this change.

## Local-only boundary

- User-owned or unrelated VNC/SSH plan changes remain preserved and are not part of the RustDesk Pro/RDP implementation commit. The SSH plan records the fixed RDP -> RustDesk -> SSH -> 数据安全 order and the no-fingerprint-migration boundary.
- SDKs, signing profiles, device data, private addresses, credentials, raw logs and screenshots remain outside the shared records.

## RustDesk Peer 2FA implementation checkpoint (2026-07-29)

- 在用户授权的本地 `main` 上完成 RustDesk Peer `2FA Required` / `Wrong 2FA Code`
  状态、官方 `Auth2FA` 消息重试、取消/epoch 清理及 v3 FFI auth callback；中继本身
  不执行 TOTP，认证发生在 Peer 登录阶段。
- 普通连接和 RustDesk Pro preflight 均支持 pending、手动 code、重试、超时和取消。
  显式主机绑定只保存 `rustdeskTotpEntryId` 和自动提交开关；自动提交前走已有系统
  生物认证，native 只收到一次性数字 code，不收到 secret。
- TOTP 卡片新增发行方 Logo/首字母模式切换。真实 Logo 由白名单 issuer slug 映射到
  Simple Icons CDN；unknown/offline 自动使用高对比度本地首字母；偏好键为
  `totpLogoMode`，纳入现有 `usersettings` 白名单，不增加云表。
- 本地验证：Rust 145/145、arm64-v8a 与 x86_64 FFI release 构建、ArkTS 编译、
  `assembleHap` 均通过；`ohosTest` 仍因任务未注册 `00306054` 不可运行，真实 Peer/
  hbbr/API 23 设备验收保持开放。
- 本次没有使用独立 reviewer agent；已完成自审，按 D-020 的独立复核要求仍需在
  交付前补齐。没有 push、PR 或远端 main 合并。

## RustDesk Android orientation and touch ledger (2026-07-29)

- The user-authorized RustDesk control-side implementation is complete on local `main`; no task branch, remote push, PR or merge was used. Commits are `73943e6d7`, `f15d5f8a7`, `bbc570169`, `4657e5c92`, `a4ae8d3e0` and review hardening `de441ac`.
- Mobile foreground RustDesk sessions now request explicit `LANDSCAPE` by default before authentication/Surface startup and after connection. Only an explicit per-host opt-in for a phone target requests `AUTO_ROTATION`; desktop-class layouts, PIP and non-RustDesk sessions keep their existing window behavior. The repository has no remote Android system-rotation command or controlled-side source, so the change does not claim to rotate the remote phone itself.
- The orientation policy distinguishes a pending RustDesk route from an idle page, so the system's initial portrait state cannot leak into the default landscape session. The orientation correction itself does not alter gesture policy; a later isolated RDP/canvas checkpoint strengthened the two-finger ownership and remote TouchPan lifecycle recorded below.
- RustDesk portrait geometry is no longer converted to a landscape request by the local adaptive-size path. Existing peer/display geometry and `geometryEpoch` changes reset pinch/touch ownership, touchpad anchors and renderer viewport mapping so cursor, virtual mouse and input do not continue in the old coordinate space.
- Two-finger input has one owner per sequence. Canvas zoom is off by default and legacy defaults migrate off once; when enabled, pinch zooms, a two-finger hold of about 0.4 seconds followed by movement pans an overflowing canvas, early movement remains touchpad scroll, and a stationary release remains right-click. The settings description documents this interaction.
- The remote-app TouchScale toggle remains explicit opt-in. Native enqueue is not treated as peer acceptance because this checkout has no controlled Android endpoint capability acknowledgement. Direct Touch remains mouse-compatible emulation rather than raw multi-touch injection.

### RustDesk verification and acceptance boundary

- `default@OhosTestCompileArkTS`: passed after the implementation and review hardening.
- `assembleHap`: passed with `BUILD SUCCESSFUL` after the implementation and review hardening.
- `git diff --check`: passed.
- `ohosTest@OhosTestCompileArkTS`: unavailable because the project task is not registered (`00306054`); no test success is claimed.
- 2026-07-29 orientation correction: the pending-session landscape/auto-rotation cases were added to `RemoteOrientationPolicy.test.ets`; both production gates passed again after the change.
- Real API 23 device and RustDesk Android endpoint acceptance remains open for portrait/landscape rotation, Surface recreation, virtual mouse/keyboard, touchpad scroll/right-click, Canvas pinch/long-press-pan and remote TouchScale consumption. RDP/VNC/SSH regression smoke is also required before release.

## RDP canvas transform + two-finger input repair ledger (2026-07-29)

- Scope commits: `33fa8e21f fix(rdp): redraw retained texture for canvas transforms`, `66d67b622 fix(input): make two-finger canvas pan reliable`, `cc3403119 fix(input): reserve held two-finger pan`, `cf96bd5fd fix(rdp): report retained transform metrics`, `f0ab5439b fix(input): route held pan to rustdesk`, and `69c6308 fix(rustdesk): end overlay touch scale`.
- `GLRenderer::SetCanvasTransform()` now requests a coalesced retained redraw through `RdpFramePump` rather than a source refresh. The worker draws the active raw texture and swaps; it does not enter the GDI retained-frame snapshot/copy/upload path. The source scheduler and upload-gate samples exclude retained transforms, and a due source frame wins the scheduling race.
- The ArkTS policy uses the active touch-point map as the authoritative count, caches gesture density instead of calling synchronous display lookup on every move, and has both a two-finger `LongPressGesture` fallback and raw 400 ms hold state. An armed hold cannot be stolen by parallel Pinch.
- Local canvas pan requires the zoom setting. RDP now keeps a bounded 45% per-axis free-pan reserve after the canvas is enlarged beyond Fit, so an aspect-ratio mismatch cannot leave only one axis movable and the drag does not stop after a short 12% travel; real overflow remains authoritative when it is larger. Fit/shrunk canvases stay centered. RustDesk and VNC retain strict local content bounds, while RustDesk remote-app TouchScale keeps its separate remote `TouchPan start/delta/end` owner. Keyboard/mouse mode remains excluded from canvas two-finger gestures.
- The RDP free-pan capability is rebuilt through both the ArkUI viewport and native renderer-snapshot cache paths. Predicted/native viewport formulas continue to include `panX/panY`, and the coordinate-policy tests cover a negative viewport round trip so the virtual/physical mouse mapping remains aligned after horizontal movement.
- Local evidence: focused native `rdp_native_tests` previously passed `157/157`; the current production ArkTS test compile and signed `assembleHap` both passed after the free-pan implementation and review fix; Light compliance and `git diff --check` passed. `ohosTest@OhosTestCompileArkTS` remains unavailable because task `00306054` is not registered, so no ArkTS test execution is claimed.
- Independent read-only review first found that a native viewport read could drop the new RDP capability. Both cache construction paths were unified, Fit/shrink/overflow/symmetric-bound and negative-viewport mapping tests were added, and the reviewer then passed the final diff with no remaining P0/P1/P2. No HAP was installed and no device state was changed.
- Remaining release evidence is physical API 23 validation of RDP 1080p/2K/4K zoom smoothness, horizontal/vertical held pan at 110%/125%/150%/200%, retained-transform metrics and cursor/mouse accuracy near all four pan bounds; then RustDesk remote-app raw/overlay TouchScale plus held pan. Also smoke-test local touchpad scroll/right-click, virtual mouse, keyboard and RDP/VNC/SSH isolation.

## RustDesk Pro + RDP visual commit ledger (2026-07-28)

- RustDesk Pro root fix: the API `accessToken` was previously sufficient for address-book HTTP calls but was absent from the RustDesk rendezvous control messages. The implementation now preserves the existing FFI ABI by appending a transient token field, carries it through ArkTS -> NAPI -> C++ -> Rust, and sends it only in the rendezvous secure/punch/relay control requests. Direct connections do not require this token.
- Implementation commit: `97f3b0085 fix(remote): restore Pro session handoff and RDP frame commits`.
- RustDesk Pro safety boundaries: connection preflight verifies the Pro account and relay binding; only a classified Pro-session failure clears the local session. Password, approval, relay, peer and network failures retain their own user-facing diagnosis. Token values and device passwords are excluded from logs.
- RDP visual boundary: broad full-width/full-height refresh bands start the accumulator fence before the old union-area threshold; `rdp_visual_commit_policy.h` applies a deterministic 40 ms quiet period with a 160 ms maximum wait. Deferred snapshots are requeued without `SwapBuffers`; explicit full snapshots and steady-state small dirty updates retain their prior behavior.
- Coordinate contract: the GL upload path retains the existing top-left `dirtyY` mapping because the current quad maps texture `v=0` to the visual top; the contract is documented and covered by the focused native build rather than changing coordinates speculatively.
- Code-level implementation is complete and ready for real endpoint acceptance. No credentials, server data or remote operations were used during local validation.

## RDP wired-log follow-up ledger (2026-07-28)

- The wired `hdc` reproduction showed that TLS/RDP transport and GL swap timing were healthy, while presentation windows replaced most submissions (`submitted=53 presented=5 replaced=49` and `submitted=61 presented=3 replaced=57`). This confirms that the visible scan was caused by refresh updates escaping the visual commit boundary, not by the wired network.
- `9eb1d7722 fix(rdp): keep refresh bursts behind visual commit fence` widens broad-refresh detection to full-width one-row bands and retains the last broad-frame commit for a 120 ms continuation window. A strip arriving in that tail reopens the full-frame fence; small steady-state dirty rectangles keep the existing path.
- The snapshot state is cleared only after a successful full-frame copy, so an allocation failure does not lose the pending visual fence. No RDP frame-pump, renderer, RustDesk or other protocol module was changed by this follow-up.
- Follow-up verification: focused native tests `147 passed, 0 failed`; `default@OhosTestCompileArkTS` passed; `assembleHap` returned `BUILD SUCCESSFUL`; Light open-source compliance passed; `git diff --check` passed.
- The newly built HAP was not installed automatically. Real-device acceptance with this HAP remains required for first desktop entry, browser/file-manager large refresh, scrolling and video scenarios.

## RDP sustained-refresh repair ledger (2026-07-28)

- The second wired `hdc` capture was from app version `1.0.8`. It showed medium refresh bands such as `832x64`, `1024x128`, `1408x128` and `1088x192` on a `1920x1080` desktop, so the prior 75%-width/full-width classifier did not consistently recognize one page repaint as a visual burst.
- The same windows repeatedly copied full-frame-sized buffers (`copied` grew by multiples of `1920*1080*4`) and replaced most queued snapshots, for example `submitted=61 presented=10 replaced=50` and `submitted=31 presented=8 replaced=23`. EGL/GL presented successfully with no surface rejection or detach; this is a presentation-boundary problem, not a wired `hdc` or GL-surface failure.
- `9fc3d8fcb fix(rdp): coalesce sustained refresh bursts` expands the burst classifier to medium horizontal/vertical bands and 25%-area updates, keeps the visual fence across a 750 ms continuation episode, waits up to 200 ms for quiet during that episode with a 600 ms cap, and leaves small cursor/toolbar updates on the dirty path instead of prolonging the fence.
- The frame-pump metrics now distinguish `full`, `dirty` and `deferred` presentations in `RDP-PRESENT` logs. This is intended to verify that a reproduced page refresh is held as deferred/full-frame work rather than leaking repeated dirty-strip presents.
- Verification for this repair: `149 passed, 0 failed`; `default@OhosTestCompileArkTS` passed; `assembleHap` returned `BUILD SUCCESSFUL`; Light open-source compliance passed; `git diff --check` passed. The signed artifact is `entry/build/default/outputs/default/entry-default-signed.hap`.
- The new HAP was not installed automatically. Real-device acceptance with this exact artifact remains required; only after installation can we confirm whether the visible scan is gone and whether steady-state latency/frame rate remain unchanged.

## RDP official frame-commit repair plan (2026-07-28)

- Entity plan: `docs/superpowers/plans/2026-07-28-rdp-official-frame-commit-safe-repair-plan.md`.
- P1 quick fix is implemented in `46e996e36 fix(rdp): fence narrow refresh continuations safely`. The plan's allowlist and non-touch boundaries remain in force; only the RDP damage accumulator and its native tests changed.
- The initial full resync no longer starts a narrow-strip continuation tail by itself. Narrow strips are promoted only after a detected broad/medium refresh burst or an already committed burst continuation, while ordinary first-frame cursor/toolbar updates remain dirty-only.
- Current verification for this checkpoint: native `150 passed, 0 failed`; `default@OhosTestCompileArkTS` passed; production `assembleHap` passed; Light open-source compliance passed; `git diff --check` passed. Signed HAP: `entry/build/default/outputs/default/entry-default-signed.hap`.
- Independent read-only review completed with no P0 or isolation violation. Its P1 false-positive/test-coverage findings were addressed before commit.
- P0 real-device acceptance remains open because `hdc` currently returns `Connect server failed`; no claim is made that the scan is eliminated until this exact HAP is installed and the first-entry/browser/file-manager refresh scenarios are repeated.
- P2 renderer alignment and P3 RDPGFX/H264 remain unstarted and off by default. RustDesk Pro, SSH/SFTP, VNC, RDP connection/authentication, input, audio and other RDP channels were not changed by this checkpoint.

## RDP narrow continuation quick-fix ledger (2026-07-28)

- `rdp_damage_accumulator.cpp` now keeps the existing broad/medium refresh fence and recognizes meaningful horizontal/vertical continuation strips only when a real visual burst is active or was just committed. The first full resync does not create that continuation state.
- Continuation thresholds are 8% minimum length, 2px minimum thickness and 12% maximum thickness in the corresponding direction; 1px cursor updates and square/ordinary local updates stay on the dirty path. The test also verifies the initial-full-frame dirty-only boundary.
- No renderer, frame-pump, FreeRDP feature negotiation, GFX/H264, connection/authentication, RustDesk, SSH/SFTP or VNC file changed.
- The signed artifact was rebuilt at `entry/build/default/outputs/default/entry-default-signed.hap`. Device installation and visual acceptance are pending the `hdc` connection service.

## VNC UX implementation review ledger (2026-07-28)

This is a durable checkpoint for context compaction and later sessions. Do not
repeat the completed review below unless the listed files change again.

### Reviewed and accepted in the current working tree

- `HostListPage.ets`: VNC is a separate protocol accordion after SSH; its leaf
  routes use the existing single settings-sheet host, dirty-dismiss guard and
  `onDisappear` cleanup. VNC host save-and-connect and Gateway navigation wait
  for sheet dismissal. Modern/classic FAB and protocol picker share the VNC
  flow. RustDesk/RDP/SSH sheet and owner paths were left separate.
- `VncSettingsSheet.ets` and `VncSettingsPage.ets`: connection, timeout,
  display, security, trust, cloud scope, host and Gateway concerns are split;
  host editing reuses the four-step flow; Gateway management routes to the
  third-page directory; fingerprints and connection targets are redacted in
  summaries.
- `VncAddFlow.ets`: endpoint/security/display/review steps, direct TCP versus
  Repeater mode12 field separation, no username capability claim, explicit
  mode2/unavailable messaging, and stable-ID handoff after `onDisappear`.
- `VncGatewayAddFlow.ets`, `RustDeskRelayPage.ets` and
  `RelayDirectoryPolicy.ets`: the third page is a read-only aggregate with
  RustDesk and VNC entries co-listed in one directory; each card identifies
  its owner with a host-card-style type badge instead of a protocol filter or
  switch. VNC add/edit/delete/test dispatches only to `VncGatewayService`;
  RustDesk continues to use its own service and table. The released RustDesk
  add route remains independent: the relay FAB still selects the existing
  modern/classic RustDesk flow, while VNC Gateway is opened from the VNC
  route and never enters the RustDesk picker.
  Unsupported WebSocket/public relay/SSH tunnel/mode2 paths remain
  fail-closed. No token is rendered in cards, logs or review summaries.
- `ProtocolIconPolicy.ets` and the touched protocol surfaces: protocol and
  relay identity icons come from the API 23 `SymbolGlyph` registry; no new
  protocol identity SVG was introduced.
- `VncModelPolicy.ets`, `VncHostService.ets`, `VncGatewayService.ets`,
  `VncRecordPolicy.ets` and `RemoteDesktop.ets`: VNC host/Gateway data stays
  in the isolated VNC owner; per-host clipboard and Repeater target handoff
  reach the native session; legacy host payloads without `clipboardEnabled`
  remain readable; unsupported Gateway configs cannot be persisted as enabled.

### Evidence already obtained for this exact working tree

- `default@OhosTestCompileArkTS`: passed.
- `assembleHap`: passed (`BUILD SUCCESSFUL`).
- `ohosTest@OhosTestCompileArkTS`: current environment blocker `00306054`
  (task not registered); no test success is claimed.
- `git diff --check`: passed before the remaining documentation/commit pass.

### Checkpoint result and remaining work

1. The scoped local-main implementation commit is
   `e6e6fe04c feat(vnc): complete settings relay and host flow`.
2. The final code/documentation gates for that commit passed: both Hvigor
   production gates, Light compliance and diff checks. The ohosTest task remains
   unavailable because of `00306054`.
3. The working tree intentionally keeps the user-owned RustDesk Android plan
   and the two unrelated untracked plans outside the commit.
4. Remaining work is external acceptance only: AGC deployment of `vncrecord`,
   API 23 device UI smoke, single/multi-device cloud matrix and real VNC/
   Repeater endpoint testing. Do not push, open a PR or merge remote `main` in
   this local-only task.

## Relay/VNC add UX correction ledger (2026-07-28)

- `d54c025 fix(ui): restore relay add flows and fit VNC sheets` removed the
  accidental relay-directory filter and restored the VNC sheet sizing. Its
  temporary RustDesk-only gateway picker was superseded by `108d0f0`.
- `108d0f0 fix(ui): restore VNC relay add entry` restores the complete relay
  add entry: the page FAB opens the existing gateway action sheet; selecting
  RustDesk continues through the released RustDesk type picker and legacy
  form, while selecting VNC opens the owner-isolated `VncGatewayAddFlow`.
  This is an add-action chooser, not a directory filter or protocol switch.
- `RustDeskRelayPage.ets` no longer presents 全部/RustDesk/VNC filter controls.
  RustDesk and VNC Gateway cards are always co-listed, with `RustDesk 中继` or
  `VNC Gateway` badges matching the home host-card Pro badge geometry.
- `VncAddFlow.ets` uses a textual `1/4` step header and natural content height;
  `VncGatewayAddFlow.ets` uses `1/3`. Neither flow has the circle progress
  strip, a fixed `height('100%')` root or an inner user scroll. Their parent
  `SheetSize.FIT_CONTENT` owns the adaptive sheet height, matching the other
  add flows and preventing the prior blank/collapsed Gateway sheet.
- Verification for this correction: `default@OhosTestCompileArkTS`,
  `assembleHap`, Light compliance and `git diff --check` passed. The
  `ohosTest` task remains unavailable because the environment reports
  `00306054` (task not registered).

## VNC transport Phase 2 plan checkpoint (2026-07-28)

- Entity plan: `docs/superpowers/plans/2026-07-28-vnc-phase2-websocket-ssh-tunnel-complete-upgrade-plan.md`.
- Scope: complete WebSocket Gateway v1 and SSH local `direct-tcpip` tunnel,
  while keeping public relay, reverse/listen, and Repeater mode2 fail-closed.
- The plan defines the server contract, native byte-stream boundary,
  `vncrecord` schema v2 projection, AES-GCM/AAD and multi-device cloud
  dependency rules, API 23 UI flow, security, tests, rollout and rollback.
- This checkpoint changed no source code. The current checkout also contains
  unrelated uncommitted RDP/RustDesk/HostList/native changes; they were not
  staged or modified.
- Current checkout verification: `default@OhosTestCompileArkTS` passed;
  Light open-source compliance passed. `assembleHap` reached package
  creation but failed at local `SignHap` with `00308018` and
  `Cannot read properties of undefined (reading 'content')`; this is a
  signing/toolchain blocker. The `ohosTest` task remains the known
  `00306054` environment blocker.

## VNC remember-password and optional-encryption quick-fix ledger (2026-07-28)

- Entity plan: `docs/superpowers/plans/2026-07-28-vnc-remember-password-optional-encryption-quick-fix-plan.md`.
- Local implementation is complete on the user-authorized `main` checkout. `VncAddFlow`, `VncSettingsPage` and the VNC connection authentication Sheet now expose an explicit remember-password choice. With remember disabled, host metadata is saved but the password stays in process memory for the current connection only; the add-and-connect path uses a one-shot user/host handoff and never writes a secret row.
- With remember enabled, unlocked app encryption writes the existing bound `encrypted_v2` envelope. Disabled app encryption allows a separately confirmed bounded `plain-v1` envelope; a configured-but-locked key still requires unlock for persistence, while one-time input remains available. Selecting “not remember” in the connection Sheet no longer deletes an existing saved credential.
- `VncSecretService` now reads/removes VNC secret owner rows through a raw, selection-independent view, so a deselected or locked secret can still be forgotten. Deletion writes a cloud tombstone only when an existing shared `vncrecord` row is present; scope changes never write reverse tombstones.
- Post-review consistency fixes now roll back a failed VNC logical-scope reconciliation to the previous durable selection; a VNC-only request continues its `vncrecord` transfer when optional `cryptoparams` sync fails; mixed-protocol requests remain crypto fail-closed; and a newly-created host/Gateway payload is physically discarded on companion-secret failure instead of leaving a user deletion tombstone.
- Global encryption disable converts active VNC `encrypted_v2` rows transactionally to the explicit plain envelope before removing the DEK; enabling encryption migrates plain envelopes back to AES-GCM v2. Plain consent remains device-local and is not treated as cloud authorization.
- The physical cloud contract is unchanged: one `vncrecord` table with the existing 19 fields; no VNC table or field was added. RDP, RustDesk and SSH/SFTP owners were not changed.
- Verification for the current implementation: `default@OhosTestCompileArkTS` passed, production `assembleHap` passed, `git diff --check` passed and the Light open-source compliance gate passed. `ohosTest` remains unavailable because the environment reports task-not-registered `00306054` and no device connection service `00308018`.
- External acceptance remains required: direct VNC against a Mac, UltraVNC Repeater mode12, and the single-device/new-device/two-device `vncrecord` cloud-first matrix. No remote push, PR or remote-main merge is part of this local task.

## VNC host-card integration ledger (2026-07-28)

- Implementation commit: `6385e8d fix(vnc): expose hosts in classic host cards`.
- VNC hosts now appear in the existing `HostListPage` classic host-card list through a transient `vnc:<recordId>` display projection. The projection is never persisted to `remotehosts`; VNC CRUD remains owned by `VncHostService` and `vncrecord`.
- The existing classic card surface is intentionally unchanged: the previous protocol image/card geometry is retained, including mobile swipe edit/lock/delete, desktop ellipsis actions, selection mode and connection entry. VNC actions dispatch to the VNC owner; the unsupported remote-host workgroup mutation is not shown for VNC.
- VNC lock state is stored as optional `locked`/`lockType` fields in the VNC host payload, with legacy payloads defaulting to unlocked. Editing through either the classic card editor or VNC settings preserves the lock state; lock updates preserve any remembered secret without materializing the password into UI state.
- VNC connection routing uses `vncHostId` and reloads the authoritative VNC view in `RemoteDesktop`; it does not route a VNC projection through `HostSyncService`. Batch deletion classifies selected items from the actual projection snapshot instead of trusting the `vnc:` prefix alone.
- The classic VNC editor uses the same compact host-editor pattern as the other protocols, adds only VNC-specific transport/security/display controls, never exposes a saved password, and allows its sheet to expand to 760vp while leaving the RDP/RustDesk/SSH 420vp budget unchanged.
- Verification for this checkpoint: `default@OhosTestCompileArkTS` passed; `assembleHap` passed with signing; `git diff --check` passed; Light open-source compliance passed. `ohosTest@OhosTestCompileArkTS` remains unavailable because the project task is not registered (`00306054`).
- Device acceptance remains required: save a direct VNC host, confirm it appears on the same remote-host page, exercise card edit/lock/unlock/delete and batch delete, and confirm a real Mac VNC connection. Also run the existing RDP/RustDesk/SSH card smoke checks.

## Settings connection statistics ledger (2026-07-29)

- Implementation commit: `e495633df fix(ui): restore settings protocol icons and VNC count`.
- The settings `连接实况窗` card now renders `protocolIcon()` resources through
  API 23 `SymbolGlyph`; media resources such as the lock and version icons keep
  the existing `Image` path. This restores the RDP, RustDesk, SSH and VNC
  protocol icons without changing host-card icon ownership.
- The card now has a dedicated `VNC 主机` row backed by `vncCount`. The
  `远程主机` total remains the combined host projection, so VNC is visible in
  both the total and its own protocol count without being double-counted in any
  source service.
- Verification for this checkpoint: `default@OhosTestCompileArkTS` passed,
  `assembleHap` passed with `BUILD SUCCESSFUL`, and staged `git diff --check`
  passed. The `ohosTest` task remains unavailable because it is not registered
  (`00306054`).
- External acceptance remains a settings UI smoke check on API 23 devices,
  including zero/nonzero VNC counts and refresh after VNC host save/delete.

## RustDesk OSS/第三方地址簿中继修复计划检查点（2026-07-29）

- 用户反馈的排查与 v2 实体计划已记录在
  `docs/superpowers/plans/2026-07-29-rustdesk-relay-2fa-repair-upgrade-plan-v2.md`。
  本检查点已按用户授权在本地 `main` 完成 P0/P1 业务实现，并保留其他模组的既有修改。
- 当前实际基线是用户授权的本地 `main`，HEAD 为 `6802a716c`，相对
  `origin/main` 领先 89 个提交；无活动 `codex/*` 分支。VNC 的该最新提交是用户在
  本轮期间加入的无关改动，RustDesk 任务没有修改或回退它。
- 排查结论：本地把 exact phrase
  `you have not logged in or your login session has expired` 仅按字符串归类为
  `pro_session_expired` 并清空有效 token；同时把 OSS/第三方地址簿 HTTP 登录成功
  错当作 Server Pro relay control-plane 能力。实现已加入 profile 分层、token
  absent/present 边界、结构化失败阶段、token fingerprint/generation 保护，并让
  Peer `Auth2FA` 走同一加密通道、按 session/epoch 隔离。
- control-plane profile 现在只按 relay ID 写入本机 `localmetadata`。`rustdeskrelays`
  的建表/迁移 SQL、云字段白名单和便携备份均不含该字段；新设备、云下载的新 relay 和
  普通本地备份恢复默认 `oss_key_only`，用户删除 relay 时同一事务清理 metadata。手动
  云下载失败回滚会恢复当前设备的 metadata 快照，不会误丢用户已确认的策略。
- 官方参照已固定到计划中的 RustDesk client 与 OSS server commit；官方 OSS
  hbbs/hbbr 只校验 licence/shared key，不包含 Server Pro HTTP session 逻辑。
  现场仍需提供第三方面板、hbbs/hbbr 版本及 relay 日志，完成真实 OSS 与 Server Pro A/B。
- 当前验证：metadata 持久化边界与 ArkTS 显式本地/云 JSON 构造修复后，`git diff --check`、
  `cargo check --manifest-path rustdesk_ffi/Cargo.toml --tests`、
  `bash scripts/build_rustdesk_ffi_ohos.sh all`（`arm64-v8a`、`x86_64`）、
  `default@OhosTestCompileArkTS` 和签名 `assembleHap` 均已重新执行并通过。已知
  `cargo test --lib` 宿主机仍会因缺少 host `libopus` 链接失败；
  `ohosTest@OhosTestCompileArkTS` 因任务未注册 `00306054` 不可运行。
- 当前审查：只读 reviewer 已派发一次，agent ID 为
  `019faca9-bf75-7e62-a251-541ce970c029`；不得因上下文压缩或重复检查再次派发。
  审查重点是 Rust/C++/NAPI ABI、session/epoch 2FA 隔离、token profile/失效边界、
  HostListPage/RemoteDesktop 一致性和 RDP/VNC/SSH 隔离。该 agent 因容量限制未产出报告；
  不得因上下文压缩重复派发，也不得把独立复核写成通过。独立审查和真实端点/API 23
  仍是开放 blocker。

## VNC 会话刷新与输入修复检查点（2026-07-29）

- 本轮只处理 VNC 会话运行时差异：RFB 按完整 `FramebufferUpdate` 聚合 Raw/CopyRect/
  DesktopSize 变化后再送显，并在首帧、每次更新和读超时后维持增量请求；不重新审查
  已通过的设置页、云同步、主机卡、Relay 或其他协议路径。
- Native raw BGRA 送显现在对新/变尺寸纹理先完成整帧初始化，dirty 上传从真实
  dirty 起始像素计算指针和行跨度；NAPI 通过通用 `getSessionDiagnostics` 暴露 VNC
  帧计数、首帧年龄、送显拒绝和 RAW BGRA 标签，便于区分服务端无更新、surface 未就绪
  与 GL 送显失败。
- VNC 独立读取 `controlMode`、`showDiagnostics`；虚拟键盘、组合键、实体键盘、鼠标、
  触控、三指控制面板和只读输入策略均经过 VNC 分流。修饰键胶囊、组合键面板和诊断
  HUD 只有达到 5vp 移动阈值才持久化位置，取消手势会清理临时偏移，避免点击漂移。
- 最终验证：native `rdp_native_tests` 为 `151 passed, 0 failed`；
  `default@OhosTestCompileArkTS` 通过；生产 `assembleHap` 通过并完成签名；
  Light 开源合规通过；`git diff --check` 通过。`ohosTest@OhosTestCompileArkTS` 仍被
  `00306054`（任务未注册）阻断，不能声称 ArkTS 设备测试通过。
- D-020 独立增量复核已完成并明确 PASS：`presentationRejected` 从 VNC counter
  到 NAPI、ArkTS 类型、空快照和 HUD 完整；面板比例保存、真实 surface 首次恢复、
  横竖屏/窗口 resize 重算与 clamp 完整，resize/clamp 不反写用户比例。复核未修改工作树，
  也没有重新审查已通过的 RFB、输入分流、设置页、云同步、主机卡或 Relay。
- 外部验收仍需安装当前签名 HAP，在真实 Mac VNC 服务上验证连续多帧/局部刷新、鼠标、
  虚拟键盘、组合键、实体键盘、三指控制面板、诊断 HUD 和重复连接；当前没有把设备
  验收写成通过，也没有 push、PR 或远端 `main` 合并。

## VNC macOS 画面、控制、设置与性能实施检查点（2026-07-29）

- 实体计划为
  `docs/superpowers/plans/2026-07-29-vnc-macos-display-input-settings-complete-repair-plan.md`。
  已提交 P0 `6277705c9` 不再重复复核；本检查点只覆盖其后的 P1/P2 增量。
- VNC 独立设置现拆为连接与安全、显示与画面、输入与光标、性能监视、剪贴板、云同步、
  Trust、主机和 Gateway 的 `bindSheet` 叶子项。新增设置经
  `VncSettingsService` 验证并进入现有 `vncrecord` settings JSON payload；唯一云表和
  19 个物理字段均不变。
- 会话端已应用 VNC 独立的 fit/100%/整数/自定义本地缩放、触控板速度、滚轮方向、
  左右键交换、圆点/官方 Symbol 箭头光标和性能看板。组合键面板改为按真实测量尺寸
  邻接展开、可视区夹取，并分别保存横竖屏位置。
- Native RAW 路径新增 8/16/32 位 true-color 像素格式和 15/30/60/不限刷新请求策略；
  输入、剪贴板和 framebuffer 请求共享串行写边界，避免 RFB TCP 消息交错。当前没有
  伪装启用 ZRLE/Tight，也没有把本地缩放描述成 Mac 远端分辨率切换。
- 新主机显式继承 VNC 全局显示设置，只有打开“此主机单独设置缩放”才覆盖；旧主机
  payload 保留原缩放语义。HostList 冷启动初始化同一个 `VncSettingsService`，FAB 与
  经典编辑器不再使用硬编码默认值。VNC auto 光标也不再读取共享 `virtualMouseStyle`。
- VNC HUD 现在分别报告服务器帧 age 与成功送显 age，并展示 dirty rect、请求/实际色深、
  直连/Repeater 路径、输入提交以及帧缓冲处理量；可明确区分服务器停更、首帧/Surface
  拒绝和送显链路停滞。组合键 companion 在软键盘挤压场景按最小重叠面积落位。
- 当前自动化证据：`rdp_native_tests` 为 `159 passed, 0 failed`；Light 开源合规和
  `git diff --check`、`default@OhosTestCompileArkTS` 和 signed `assembleHap` 通过。
  同一独立 reviewer 对上一轮 8 项发现逐项复查为 PASS；`ohosTest@OhosTestCompileArkTS`
  仍因任务未注册 `00306054` 不可执行。
- 真实 Mac/API 23 验收仍开放：连续动态画面、四角/中心鼠标、拖动/滚轮/键盘、三指
  控制台、横竖屏组合键位置、性能看板及 RDP/RustDesk/SSH/SFTP 回归。未执行远端
  push、PR 或远端 `main` 合并。
