# Shared Current State

Updated: 2026-07-28 Asia/Shanghai

## Repository

- Repository: Mydstiny/RemoteDeskHarmonyOS
- Task branch: `codex/real-remote-cursor-shape`
- Scope: isolated VNC settings, real host-add flow, RFB/UltraVNC transport, one-table cloud sync and VNC crypto/reset hardening.
- The worktree also contains user-owned RustDesk/RDP pinch, remote-cursor and SSH changes; they remain untouched.

## Result

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

- `default@OhosTestCompileArkTS`: passed after the VNC protocol/cloud changes; existing repository/dependency warnings remain.
- Production `assembleHap`: `BUILD SUCCESSFUL` after compiling the VNC protocol helper into the native product.
- Native test target: `144 passed, 0 failed`; the target compiles the actual VNC transport and RFB engine plus tests ClientInit, RFB dialect/security-result rules, Repeater fixed-width/banner/short-read/invalid-target and role-boundary checks.
- `git diff --check`: passed after the implementation and shared-state updates.
- Light open-source compliance gate: passed.
- `ohosTest@OhosTestCompileArkTS`: not runnable in this environment because the task is not registered (`00306054`); this is an environment/task-graph limitation, not a source compile failure.

## External acceptance still required

- User creates exactly one Huawei cloud table `vncrecord` with the 19 fields in the entity plan.
- Two API 23 devices using one Huawei account validate scope selection, secret opt-in, trust re-confirmation, user-deletion tombstones, reset epoch and offline recovery. Scope deselection must leave the shared row unchanged.
- Real VNC server validates direct TCP; a real UltraVNC Repeater validates viewer mode12 pairing, input, disconnect and reconnect. Mode2 requires a separate VNC server-side listener component and is not an enabled HarmonyOS viewer path.
- WebSocket/public relay/SSH tunnel remain gated until endpoint, authentication, trust and lifecycle contracts exist.

## Local-only boundary

- User-owned untracked plans remain preserved and are not part of this repair. The tracked VNC entity plan is kept aligned with the deployed physical table name `vncrecord`.
- SDKs, signing profiles, device data, private addresses, credentials, raw logs and screenshots remain outside the shared records.
