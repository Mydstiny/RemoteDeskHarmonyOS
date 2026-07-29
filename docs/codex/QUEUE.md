# Shared Queue

Updated: 2026-07-28 Asia/Shanghai

## Now

- RustDesk Peer 2FA 和 TOTP 绑定实现已在本地 `main` 完成；真实 Peer/hbbr/API 23
  设备验收仍待执行。Logo 模式已加入个性化设置，真实 Logo 仅在白名单 issuer 上
  请求 Simple Icons CDN，离线自动回退首字母；不把 TOTP secret/account 放入 URL。

- RustDesk Android orientation/geometry/touch ownership implementation is complete on the user-authorized local `main` (`de441ac` review hardening). Validate on API 23 devices and a real RustDesk Android peer: mobile auto-rotation, portrait geometry, Surface recreation, virtual mouse/keyboard, touchpad scroll/right-click, default-off Canvas zoom, 0.4 s long-press canvas pan and remote TouchScale behavior. Keep the remote-phone system-rotation claim gated because this repository has no controlled Android endpoint or rotation-control acknowledgement.
- VNC hosts are now projected into the existing classic remote-host cards. Validate card visibility, classic edit/lock/delete/batch-delete, direct Mac VNC connection and regression smoke for RDP/RustDesk/SSH on an API 23 device. Keep VNC CRUD in `VncHostService`/`vncrecord`; never migrate the projection into `remotehosts`.
- VNC remember-password/optional-encryption quick fix is implemented on the user-authorized local `main` checkout. Keep the sole `vncrecord` table and its 19-field schema unchanged. Verify direct Mac VNC, Repeater mode12 and the single/new/two-device cloud-first matrix before release; do not push, open a PR or merge remote `main` in this task.
- RustDesk Pro session handoff is committed locally on `main` as `97f3b0085`; the wired-log RDP visual-commit follow-ups are committed as `9eb1d7722` and `9fc3d8fcb`. The narrow continuation quick fix is committed as `46e996e36`; install the newest signed HAP and complete real Pro endpoint and RDP device acceptance before release. Keep remote push/PR/remote-main merge out of this task unless explicitly requested.
- The official FreeRDP-aligned RDP refresh repair plan is materialized at `docs/superpowers/plans/2026-07-28-rdp-official-frame-commit-safe-repair-plan.md`. P1 GDI quick fix is implemented and isolated; P0 real-device acceptance is pending because `hdc` currently cannot connect. Keep renderer changes and any RDPGFX experiment separately gated and independently reversible.
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
