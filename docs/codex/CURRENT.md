# Shared Current State

Updated: 2026-07-28 Asia/Shanghai

## Repository

- Repository: Mydstiny/RemoteDeskHarmonyOS
- Task branch: `main` (current-branch SSH implementation explicitly authorized by the user)
- Scope: SSH independent settings accordion and terminal appearance migration; the checkout also contains the previously completed isolated VNC implementation.
- The worktree also contains user-owned RustDesk/RDP pinch, remote-cursor and TouchpadPointerCurve test changes; they remain untouched.

## Result

- SSH settings now has one dedicated accordion immediately after Windows RDP and RustDesk, and before 数据安全. Terminal foreground color and font size were removed from 个性化 and are now owned by `SshSettingsService` through namespaced keys with legacy aliases.
- SSH settings exposes terminal appearance, preview/default reset, SSH host and key-vault shortcuts. SSH host fingerprint management was deliberately not migrated: 数据安全 and the existing per-host preflight remain the only trust-management path.
- SSH settings continue to use existing `usersettings`, `RemoteHost`, `SshKey` and `KeyVaultService` owners; no SSH cloud table or sensitive global setting was added. RDP, RustDesk and VNC owners were not changed.
- VNC now has its own settings page, model, host/gateway/secret/trust services and connection projection. It does not use RDP, RustDesk or SSH/SFTP data owners.
- The only new cloud table is `vncrecord`; `recordtype` carries `settings`, `host`, `gateway`, `secret` and `trust`. `vnclocalrecords` is device-local only.
- VNC secrets use the context-bound AES-GCM v2 envelope. Secrets are opt-in for sync and require an unlocked crypto state plus explicit VNC selection.
- `cryptoparams.vnc_reset_epoch` increments on crypto reset. New VNC rows bind to the current epoch; old rows, stale backups and stale rewrites fail closed.
- Native VNC supports RFB 3.3/3.7/3.8, VNC DES password, Raw/CopyRect/DesktopSize, BGRA, keyboard/mouse/clipboard and UltraVNC Repeater viewer mode12. The mode12 path validates `RFB 000.000\n` and sends the official fixed 250-byte `ID:<target>` field; mode2 remains a server-side repeater listener contract and is rejected by this viewer client.
- Cloud reads validate every VNC row, including the typed JSON payload, before projection; preserve unknown wire values for rejection; bind runtime merges to `userId + id`; and hide unselected or crypto-locked cloud secrets. Scope deselection never writes a reverse cloud tombstone; user deletion still uses an ordinary tombstone. Raw crypto migration follows the same selected projection.
- VNC settings saves apply and validate the new logical scopes before writing the settings row; a failed row write restores the previous scopes, so turning off settings sync cannot upload the row that disables it.
- Startup uses a durable cloud-bootstrap marker and a serialized cloud-first barrier. A new device cannot publish local defaults before its first authoritative pull; startup mutations are deferred and cloud events/foreground pulls share the same queue.
- The ordinary cloud-sync selector exposes the physical `vncrecord` table, while VNC logical scopes remain enforced by `VncCloudSyncSelectionStore`; manual ordinary upload/download cannot bypass that boundary.
- Host-list settings now has an independent top-level VNC accordion and the FAB exposes the same isolated VNC add flow in both modern and classic modes. Saving can persist a VNC owner and optionally route to `RemoteDesktop` for connection.
- The global “关闭加密” path now fails closed while any live VNC ciphertext exists in the local, current cloud, or legacy compatibility mirror; VNC passwords/tokens are never downgraded to plaintext or stranded by clearing the DEK.
- WebSocket gateway, public relay, SSH tunnel and reverse/listen remain explicitly unavailable until their server contracts are deployed and verified.

## Verification

- `default@OhosTestCompileArkTS`: passed after the Preferences type-guard patch; existing repository/dependency warnings remain.
- Production `assembleHap`: `BUILD SUCCESSFUL` after the Preferences type-guard patch.
- Native test target: `144 passed, 0 failed`; the target compiles the actual VNC transport and RFB engine plus tests ClientInit, RFB dialect/security-result rules, Repeater fixed-width/banner/short-read/invalid-target and role-boundary checks.
- `git diff --check` and `git diff --cached --check`: passed after the implementation and shared-state updates.
- Light open-source compliance gate: passed via the repository-local `.tools/bin/pwsh` runtime.
- `ohosTest@OhosTestCompileArkTS`: not runnable in this environment because the task is not registered (`00306054`); this is an environment/task-graph limitation, not a source compile failure.
- Read-only SSH review: passed with no P0/P1/P2 findings; the reviewer confirmed the accordion order, the data-security-only fingerprint entry and no cross-module cycle.

## External acceptance still required

- User creates exactly one Huawei cloud table `vncrecord` with the 19 fields in the entity plan.
- Two API 23 devices using one Huawei account validate scope selection, secret opt-in, trust re-confirmation, user-deletion tombstones, reset epoch and offline recovery. Scope deselection must leave the shared row unchanged.
- Real VNC server validates direct TCP; a real UltraVNC Repeater validates viewer mode12 pairing, input, disconnect and reconnect. Mode2 requires a separate VNC server-side listener component and is not an enabled HarmonyOS viewer path.
- WebSocket/public relay/SSH tunnel remain gated until endpoint, authentication, trust and lifecycle contracts exist.
- SSH settings still require API 23 PC/phone/tablet UI smoke validation, including accordion order, appearance persistence and trust-entry location; no real host fingerprint is auto-trusted by this change.

## Local-only boundary

- User-owned TouchpadPointerCurve test changes and the other untracked plans remain preserved and are not part of the SSH implementation commit. The SSH plan records the fixed RDP -> RustDesk -> SSH -> 数据安全 order and the no-fingerprint-migration boundary.
- SDKs, signing profiles, device data, private addresses, credentials, raw logs and screenshots remain outside the shared records.

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
