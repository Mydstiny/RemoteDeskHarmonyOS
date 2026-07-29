# Shared Current State

Updated: 2026-07-29 Asia/Shanghai

## Repository

- Repository: Mydstiny/RemoteDeskHarmonyOS
- Task branch: `main` (current-branch SSH implementation explicitly authorized by the user)
- Scope: RustDesk Pro session handoff/error classification and RDP first-frame/large-refresh visual commit optimization are the current implementation. The checkout also contains the previously completed isolated SSH/VNC work.
- The user explicitly authorized this implementation on local `main`; no remote push, PR or merge is in scope.

## Result

- RustDesk Pro API login tokens now travel only through the transient connection path into the RustDesk rendezvous `PunchHoleRequest` and `RequestRelay` messages; the existing relay/shared key remains a separate credential and the token is not persisted in host records, uploaded to cloud metadata or written to logs.
- Pro host connections now validate account, server/relay and address-book binding before prompting for remote-device password or approval. Native connection errors are classified as Pro-session, device-password, approval, relay, peer or network failures so a real device-authentication failure is not reported as account expiry.
- RDP keeps latest-value-wins dirty-rectangle presentation for small steady-state updates, while initial/full geometry and medium-to-broad refresh bands enter a visual commit fence: a 40 ms quiet period or 160 ms deadline commits the accumulated frame as one presentation, and a 750 ms continuation episode uses a 200 ms quiet period with a 600 ms deadline so sustained page refreshes do not fall back to strip-by-strip presentation. Small cursor/toolbar updates remain dirty-only.
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

## Verification

- Rust `cargo check` and `cargo check --tests`: passed for `rustdesk_ffi`.
- Focused native `rdp_native_tests`: `150 passed, 0 failed`.
- `default@OhosTestCompileArkTS`: passed after the RustDesk Pro/RDP implementation; existing repository/dependency warnings remain.
- Production `assembleHap`: `BUILD SUCCESSFUL` after the RustDesk Pro/RDP implementation.
- Native test target compiles the actual VNC transport and RFB engine plus the RDP damage/visual-commit tests and the VNC transport tests.
- `git diff --check` and `git diff --cached --check`: passed after the implementation and shared-state updates.
- Light open-source compliance gate: passed via the repository-local `.tools/bin/pwsh` runtime.
- Full Rust `cargo test` remains host-blocked at link time because the local host does not provide `libopus`; this is not reported as a passing test.
- `ohosTest@OhosTestCompileArkTS`: not runnable in this environment because the task is not registered (`00306054`); this is an environment/task-graph limitation, not a source compile failure.
- Read-only SSH review: passed with no P0/P1/P2 findings; the reviewer confirmed the accordion order, the data-security-only fingerprint entry and no cross-module cycle.

## External acceptance still required

- RustDesk Pro: test against the real compatible Server Pro versions, including password and request-approval connections through relay, application restart, expired-token re-login, mismatched account/server/relay records, and 401/403/404/500 responses. Confirm the user-visible message is tied to the actual failing layer.
- RDP: test first desktop entry, Windows login desktop loading, browser/file-manager full refresh, window dragging, video, scrolling and 1080p/2K/4K devices. Confirm no visible scan bands, while steady-state input latency and frame rate do not regress.
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
- The orientation policy distinguishes a pending RustDesk route from an idle page, so the system's initial portrait state cannot leak into the default landscape session. Existing two-finger gesture ownership and long-press canvas-pan behavior remain unchanged by this correction.
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
