# Shared Queue

Updated: 2026-07-30 Asia/Shanghai

## Now

- VNC settings Sheet crash hotfix is locally complete at independently reviewed
  checkpoint `0455966`, based on `main@bfea42cb0`. All three VNC consumers of
  the shared Sheet scaffold now preserve their parent builder context through
  lexical closures, eliminating the API 23 `bind of undefined` crash without
  changing RDP, RustDesk or SSH. The VNC settings accordion now allocates
  `760vp` for all eleven action rows instead of clipping the final Gateway
  entry at `620vp`. ArkTS test compilation, signed `assembleHap`, generated
  code inspection, Light compliance and diff checks pass; independent review
  returned PASS with no P0/P1/P2/P3. No HAP was installed. Device validation
  remains for all settings routes, save/no-save footer behavior, host/Gateway
  flows, large text/breakpoints and other-protocol smoke tests. Do not push,
  open a PR or merge remote main.

- RustDesk multi-display single-canvas switching is locally complete at
  independently reviewed checkpoint `0d6c7fd0b`, based on
  `main@1615aff58`. Input release and old-move draining precede the official
  latest-wins switch transaction; input and geometry remain fenced until the
  exact target ACK and keyframe. Stale generations cannot publish an old
  display, invalid/offline current display chooses the first online catalog
  entry, timeout permits same-target retry, and the opaque Rust FFI handle is
  pinned across query/control calls and drained before teardown. Native host
  tests are `178/178`; focused Rust tests, both required Hvigor gates, signed
  HAP, Light and diff checks pass. The reviewer returned PASS with no remaining
  P0/P1/P2. Release remains NO-GO pending API 23 testing against a real
  multi-monitor peer for rapid switches, timeout/retry, unplug fallback,
  reconnect and held keyboard/mouse/touch release. No HAP install, remote push,
  PR or remote-main merge is part of this closure.

- RustDesk login/control-plane/relay-save v3 is locally complete at reviewed
  implementation checkpoint `d404178b1`, based on local `main@d0e6ffee2`.
  Structured transactional save/read-back, one setup owner, progressive
  disclosure, host-draft return, strict credential/profile separation,
  effective API-only fallback, split API/ID/Relay binding, projected-token
  revocation fencing, FORCE_RELAY/DIRECT_IP and redacted diagnostics are
  implemented. The same independent D-020 reviewer returned PASS with no
  remaining P0/P1. Rust is `151/151`, native is `171/171`; both required
  Hvigor gates, signed HAP, Light and diff checks pass. Candidate metadata is
  `1.0.10 / 1000010`; do not install over the connected device's
  `1.0.8 / 1000008` data without explicit recovery-aware authorization.
  Release remains NO-GO until official Server Pro adapter/issuer evidence,
  超享/third-party and OSS A/B, password/approval/Peer 2FA,
  P2P/relay/direct/network-change, API 23 lifecycle and multi-device cloud
  matrices are recorded. AUTO/NAT/P2P fallback and every unverified
  control-plane token remain fail-closed. Do not push, open a PR or merge
  remote main.

- VNC product-parity/Sheet remediation is locally complete. The reviewed branch
  tip `2797fd481` is fast-forward merged into local `main`; the final
  implementation fix is `d17976c10`.
  Sheet/action reachability, two-step host/Gateway flows, settings ownership,
  visible VNC controls, view-only explanation, isolated diagnostics, measured
  modifier-panel placement, Cursor `-239`, bounded ZRLE, KeyEvent-based VNC
  text input, connect-failure callback cleanup, desktop classic default
  hydration and production small-height Sheet adaptation are implemented.
  Native tests are `171 passed, 0 failed`; both required Hvigor gates, signed
  HAP, Light compliance and diff checks pass. The first independent D-020
  audit's four findings are fixed, and the same reviewer completed the
  remediation plus remaining renderer/isolation/zlib checks with an explicit
  PASS and no P0/P1/P2. The merged task branch is deleted during closure.
  Release remains NO-GO pending API 23 layout/input,
  real macOS/TigerVNC/UltraVNC-LibVNCServer interoperability, cross-protocol
  regression and cloud device/account matrices. `ohosTest` remains unavailable
  as unregistered task `00306054`. Do not push, open a PR or merge remote main.

- Cloud/data lifecycle root fix is completed and locally merged from
  `codex/cloud-data-lifecycle-root-fix` at implementation checkpoint
  `c88fc2968`. The signed upgrade-test candidate is `1.0.9 / 1000009`.
  D-020 remediation adds independent OS distributed-account verification,
  an awaitable login/account-switch cloud-first bootstrap, record-level journal
  reconciliation, a durable bounded cloud-download before-image, persisted
  ordinary/VNC selection re-enable barriers, authoritative remote empty-set
  acceptance and real RustDesk Pro Asset Store token revocation. The second
  review's remaining P1s are now closed locally: restore quarantine cannot
  publish bootstrap ready, newly enabled VNC scopes await cloud-first through
  promotion/barrier release with rollback, and RustDesk Pro token revocation
  preserves non-secret metadata as requiring reauthentication. The third
  review's final VNC P1 is also closed locally: an independently bound durable
  checkpoint now protects the authoritative VNC mirror/settings/journal/retry
  before-image; promotion, phase persistence, barrier release and checkpoint
  deletion commit atomically, the startup code has a fail-closed interruption
  recovery path, and no secret-scope upload is scheduled before the checkpoint
  and barrier are durably gone. The final review's P0 and two P1 findings are
  closed locally in `df2a6b4` and `88a6128`: checkpoint establishment, the
  entire VNC settings
  mutation and full-store recovery share one exclusive coordinator queue item
  and lease; the authoritative VNC checkpoint rebase/journal replay/ordinary
  checkpoint deletion share the cloud-first completion transaction; metadata
  uses strict present/absent/error reads and query errors block native-first,
  promotion, retry and post-commit success. Current ArkTS/test compilation,
  signed `assembleHap`, Light and diff checks pass. The final source review
  confirmed those production invariants and left one P1 implementation-test
  gap. `501565e` now drives the real coordinator queue, retry scheduler and
  lease fencing plus the production CloudStore completion/finalization and
  metadata entry points through narrow I/O fakes. It covers transaction
  ordering, pre-commit rollback, post-commit recovery and metadata-error
  blocking without claiming ArkTS runtime execution. The continuation review's
  two P1s are closed locally in `0ffaa1c`: the production VNC completion and
  finalization RDB entries are private again, while a stateless collaborator
  shared by those entries and startup recovery performs strict checkpoint and
  barrier reads. Tests now inject query errors through
  `CloudStore.readLocalMetadataState`, use the real signed checkpoint parser
  and route a committed authoritative checkpoint through the restart-recovery
  collaborator. The terminal continuation review's P1/P2 are closed locally
  in `0d6216e`: malformed `vncrecord` barrier values and non-object JSON now
  fail closed before promotion and after commit, while startup and in-process
  rollback share one production adapter that owns snapshot/selection restore,
  checkpoint deletion, barrier read-back and `recovery_required` marking.
  Table-driven semantic JSON cases and restore/delete/commit failures are in
  the default ArkTS test compilation. The final P2 startup-integration gap is
  closed locally in `0c0b3d4`: the test now calls the real
  `CloudStore.init` / `openScopeStore` startup gate on an isolated RDB-free
  instance, while the private production adapter and startup runner route
  bottom-level snapshot, VNC table, transaction and exact checkpoint-key I/O.
  Removing the startup call or misrouting restore/delete leaves the checkpoint
  or ready state wrong and fails the behavior assertions; no public
  singleton/RDB recovery mutator was added.
  The final independent D-020 incremental review passed at `c88fc2968` with no
  P0/P1/P2, so this branch is approved for local fast-forward merge and cleanup.
  Release remains NO-GO pending proof of Account Kit UnionID/distributed-account
  ID correspondence on API 23, real Huawei Cloud/two-device/A-B account/old
  APK/fault-injection/Document Provider/Asset Store evidence. Pure fault
  injection is not a
  substitute for real process-kill/reboot/low-storage evidence. If API 23 cannot prove the
  identity correspondence, cloud
  remains fail-closed. System BackupExtension, remote destructive crypto and
  legacy REST sync stay disabled. Do not start a sub-agent for this remediation.
  The connected device still has `1.0.8 / 1000008`; do not perform an
  in-place upgrade until the user explicitly authorizes testing against its
  existing app data and a recovery path is prepared.

- 华为账号登录误报修复（`accountkit` 与平台独立身份不一致提示）完成本地闭环：
  登录后不再因平台独立身份不可验证直接阻断本地入口；先打开该账号本地作用域，
  仅在 `cloudTransferAllowed` 为真时执行 `requestStartupPull` 和云侧 selection
  重放。若后续 cloud-first 失败，继续保持本地隔离与 ready 挂起。
  本地恢复若未进入账号作用域将返回独立提示 `account_scope_required`，
  不再把这类状态误报为“备份属于其他华为账号”。

- The older RustDesk relay/2FA checkpoint in
  `docs/superpowers/plans/2026-07-29-rustdesk-relay-2fa-repair-upgrade-plan-v2.md`
  is superseded for login/control-plane/save status by the v3 plan and
  `d404178b1`. Do not reuse its obsolete reviewer blocker or host-libopus test
  status; its real endpoint and device acceptance items remain open.

- RustDesk Peer 2FA 和 TOTP 绑定实现已在本地 `main` 完成；真实 Peer/hbbr/API 23
  设备验收仍待执行。Logo 模式已加入个性化设置，真实 Logo 仅在白名单 issuer 上
  请求 Simple Icons CDN，离线自动回退首字母；不把 TOTP secret/account 放入 URL。

- RustDesk Android orientation/geometry/touch ownership implementation is complete on the user-authorized local `main`; the follow-up correction applies default `LANDSCAPE` before RustDesk authentication/Surface startup and reserves `AUTO_ROTATION` for an explicit phone-target opt-in. Canvas zoom remains default-off and retained-texture redraw remains in place. RDP now has a bounded 45% per-axis free-pan reserve only after enlargement beyond Fit; RustDesk/VNC local bounds and RustDesk remote TouchPan are unchanged. Validate on API 23 hardware: RDP 1080p/2K/4K pinch smoothness, four-direction held pan at 110%/125%/150%/200%, cursor/mouse mapping at all bounds, early scroll/right-click, RustDesk raw and overlay-only TouchPan/pinch, virtual mouse/keyboard and orientation/Surface recreation. Keep the remote-phone system-rotation claim gated because this repository has no controlled Android endpoint or rotation-control acknowledgement.
- VNC hosts are now projected into the existing classic remote-host cards. Validate card visibility, classic edit/lock/delete/batch-delete, direct Mac VNC connection and regression smoke for RDP/RustDesk/SSH on an API 23 device. Keep VNC CRUD in `VncHostService`/`vncrecord`; never migrate the projection into `remotehosts`.
- Settings `连接实况窗` now renders the RDP/RustDesk/SSH/VNC protocol icons through the official `SymbolGlyph` path and includes a separate VNC host count. Validate zero/nonzero counts and refresh after VNC save/delete on an API 23 device; implementation is committed locally as `e495633df`.
- VNC remember-password/optional-encryption quick fix is implemented on the user-authorized local `main` checkout. Keep the sole `vncrecord` table and its 19-field schema unchanged. Verify direct Mac VNC, Repeater mode12 and the single/new/two-device cloud-first matrix before release; do not push, open a PR or merge remote `main` in this task.
- VNC continuous-frame/input P0 is committed as `6277705c9` and must not be
  re-reviewed after context compaction. The follow-up implementation adds
  isolated display/quality/input/performance settings, real RAW 8/16/32-bit
  negotiation, bounded framebuffer request rates, serialized RFB writes, a
  VNC performance HUD, visible local cursor fallback and measured
  orientation-specific modifier-panel placement. Native tests are
  `159 passed, 0 failed`; `default@OhosTestCompileArkTS`、signed `assembleHap`、
  Light 合规和同一独立 reviewer 复查均通过。This checkpoint's old
  “keep ZRLE disabled” boundary is superseded by the V2 bounded ZRLE
  implementation at `90f51eed9`; Tight and remote-resolution controls remain
  disabled. Remaining release
  evidence is the exact signed HAP on API 23 against a real Mac plus
  RDP/RustDesk/SSH/SFTP regression; `ohosTest` remains blocked by unregistered
  task `00306054`.
- RustDesk Pro session handoff is committed locally on `main` as `97f3b0085`; the wired-log RDP visual-commit follow-ups are committed as `9eb1d7722` and `9fc3d8fcb`. The narrow continuation quick fix is committed as `46e996e36`; install the newest signed HAP and complete real Pro endpoint and RDP device acceptance before release. Keep remote push/PR/remote-main merge out of this task unless explicitly requested.
- The official FreeRDP-aligned RDP refresh repair plan is materialized at `docs/superpowers/plans/2026-07-28-rdp-official-frame-commit-safe-repair-plan.md`. The retained-transform canvas repair is also complete and isolated; P0 real-device acceptance remains pending. `hdc` now detects targets, but no HAP has been installed or run in this task. Keep renderer changes and any RDPGFX experiment separately gated and independently reversible.
- Local VNC UX implementation is committed as `e6e6fe04c`; the follow-up relay/VNC UX corrections are committed as `d54c025` and `108d0f0`. Keep remote push/PR/remote-main merge out of this task until the user explicitly requests it.
- Validate the SSH settings accordion on API 23 PC/phone/tablet: confirm the order is Windows RDP -> RustDesk -> SSH 终端 -> 数据安全, appearance persistence works, and SSH host fingerprints remain managed only in 数据安全.
- Create the single Huawei cloud table `vncrecord` from the entity plan; do not create `vnchosts`, `vncgateways`, `vncsecrets`, `vncsettings` or `vnctrusts` as physical tables. The app's new-device bootstrap barrier and physical-table selector are implemented; deployment remains an external AGC task.
- Run the two-device API 23 VNC matrix: settings/host/gateway scope selection, secret opt-in, trust re-confirmation, user-deletion tombstones, reset epoch and offline recovery; confirm scope deselection leaves shared cloud rows unchanged.
- Validate direct VNC TCP and UltraVNC Repeater viewer mode12 against real endpoints; keep mode2 as a separate server-side listener requirement, not a viewer connection claim.

## Later

- Execute the entity VNC Phase 2 plan for WebSocket Gateway and SSH
  direct-tcpip only after the v1 server contract, endpoint, authentication,
  trust, fixture and real VNC interoperability evidence exist. Keep the
  mobile client gates fail-closed until then; use the single `vncrecord`
  table and do not mix the work into RustDesk or SSH terminal owners.
- Define and deploy versioned WebSocket gateway, public relay and SSH tunnel contracts before enabling their existing fail-closed gates.
- Extend SSH settings only when the corresponding input, connection, SFTP or advanced native behavior is implemented and tested; do not expose placeholder controls or migrate host fingerprint ownership.
- Add real-device lifecycle evidence for surface recreation, background/foreground, network interruption, repeated connect/disconnect and stale callback generations.
- Expand VNC-specific crypto/cross-table substitution and conflict UX coverage before release.

## Queue rules

- Only one daily codex/<task> branch may be active in the shared workspace.
- A new device must sync merged main, read CURRENT.md, QUEUE.md, DECISIONS.md and HANDOFF.md, and confirm a clean working tree before creating a task branch.
- User-owned changes are never auto-stashed, deleted, reset or mixed into a documentation commit.
- Completed implementation items are summarized in CURRENT.md; this file is not a session transcript.
- The VNC code must remain isolated from the existing RDP, RustDesk and SSH/SFTP owners. A cloud sync failure or feature gate must not stop those protocols.
- The SSH settings accordion must remain directly below RDP and RustDesk; SSH host fingerprints remain owned by 数据安全 until a separate known_hosts migration review.
