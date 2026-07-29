# Shared Queue

Updated: 2026-07-29 Asia/Shanghai

## Now

- Cloud/data lifecycle root fix is active on
  `codex/cloud-data-lifecycle-root-fix` at implementation checkpoint
  `89f4b7574`. Local code and build gates are complete for account-scoped
  physical stores, verified account binding, durable cloud coordinator,
  fail-closed sensitive transfer, portable backup v3/legacy partial restore,
  exclusive crypto lifecycle, Asset Store credential boundaries and
  shared-store/relay/VNC migration quarantine. Release remains NO-GO pending
  real Huawei Cloud/two-device/A-B account/old APK/fault-injection/Document
  Provider evidence. System BackupExtension, remote destructive crypto and
  legacy REST sync stay disabled. D-020 independent review is also pending;
  do not start an agent unless the user explicitly lifts the current
  no-agent constraint.

- RustDesk OSS/第三方地址簿中继报错修复计划已合并到
  `docs/superpowers/plans/2026-07-29-rustdesk-relay-2fa-repair-upgrade-plan-v2.md`；首要实施项是
  分离地址簿 HTTP 登录与 relay control-plane，修正 exact phrase 的误判/误清 token，并完成
  token absent/present 与真实 Server Pro A/B。P0/P1 本地实现已完成，control-plane profile
  现为当前设备 `localmetadata`，不进入 relay 云行或便携备份；新设备和普通备份恢复默认
  key-only。当前本地代码 checkpoint 为 `972a3c0`。一次性 reviewer agent `019faca9-bf75-7e62-a251-541ce970c029` 因容量限制未产出
  报告，不能再次派发，独立审查仍是 blocker。`relayPort` 已从 ArkTS 贯通至 Rust FFI，hbbs 广告的
  显式 relay 端口优先、无端口 endpoint 才使用配置 hbbr fallback；focused Rust socket tests 2/2 已在
  沙箱外通过。本轮 `cargo check --tests`、双 ABI、ArkTS、签名 `assembleHap` 与 Light 合规门禁均已
  重跑并通过；`ohosTest` 仍为未注册任务 `00306054`。完整 `cargo test --lib` 仍因宿主机缺少
  host `libopus` 链接失败。真实 OSS/三方地址簿 A/B、Server Pro、hbbs/hbbr、
  Peer 2FA 和 API 23 验收保持开放。

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
  Light 合规和同一独立 reviewer 复查均通过。Keep ZRLE/Tight and remote-resolution controls disabled
  until their capability and interoperability gates pass. Remaining release
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
