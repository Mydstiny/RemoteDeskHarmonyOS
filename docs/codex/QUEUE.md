# RemoteDesk Queue

Updated: 2026-08-29 Asia/Shanghai

## Now

1. Validate per-protocol pinch zoom, reset controls and display/interaction settings on real devices: RDP/RustDesk/VNC/Moonlight focal pinch, same-stream pure pan, Fit scroll/right-click, relative/physical pointer follow, rotation/PIP/reconnect/resize, live-disable reset, sidebar/control-center reset reachability and baseline preservation; verify SSH font pinch plus `更多 → 恢复终端字号`, all-on/all-off, per-protocol persistence/restart and SFTP isolation. Open `会话侧栏与顶栏` as a sheet, exercise four protocol switches, all-show/all-hide, cancel/save/restart and restoring hidden controls from settings; confirm Moonlight expands/collapses and opens all leaf settings like the other protocol sections. Then push, open the PR, pass required checks and merge `codex/per-protocol-pinch-zoom-plan`.
2. Run a Phone/Pad/PC visual sweep of all reachable bindSheets in dark and light mode, covering CENTER/BOTTOM layouts, Moonlight connect/control/controller/stop modes, SSH/SFTP and gated productivity/log/broadcast surfaces; dark roots must be `#1C1C1F` with no black/gray seams and light behavior must remain unchanged.
3. Upgrade a preserved 1.1.3 install to 1.1.4 and verify the update popup appears once, contains only the 10 current 1.1.4 pages, starts with the 1.1.4 summary, contains no 1.1.3 page and ends with `welcome-1-1-4`; reopen it from Settings and verify a reused high legacy page index cannot restore pages 10–21 or flash a stale count.
4. Validate the per-protocol wheel editor and direction matrix on device: change one protocol without affecting the other four; exercise all-normal/all-reverse; cover RDP/RustDesk/VNC physical mouse, physical touchpad and virtual touchpad; Moonlight physical and virtual input; SSH scrollback, alternate buffer and mouse tracking; confirm SFTP is unaffected.
5. On a HarmonyOS PC viewer, validate the new RustDesk per-host flip popup against affected Windows peers: all three modes, absolute/relative mouse mapping, remote cursor, PIP/foreground restore, reconnect persistence and stale computer metadata resolving to a mobile peer.
6. On the fixed HAP now installed at `192.168.3.235:38451`, verify login survives the historical migration `401`, exact-owner hashed data remains visible, local CRUD survives restart/offline use, and canonical/cloud recovery does not resurrect stale rows.
7. On `.235`, complete the already-queued RustDesk/RDP/VNC/Moonlight sidebar keyboard-close, scrolling, drag/bounds, touch isolation and phone immersive-bar acceptance.
8. Decide whether `192.168.3.236:40123` may be destructively uninstalled for the debug HAP or requires a matching release-provisioned acceptance HAP; preserve its existing data until explicitly authorized.
9. Complete RustDesk quality/multimonitor release acceptance: verify Low/Balanced/Best cold/live/reconnect behavior on direct and relay paths; run 1/2/3-screen ACK/keyframe rollback, DPI/rotation/hot-plug/PIP/background/reconnect/input mapping; on HarmonyOS PC stress the default-off read-only two-canvas preview for 30 minutes and repeated attach/promote/detach cycles against Windows/Linux/macOS peers.

## Next

1. Add real-RDB fault-injection coverage for empty-table clear, unsafe VNC/Moonlight rows and higher-version account sources.
2. Complete app-clone acceptance on release-provisioned phone and tablet without clearing existing data.
3. Run Android RustDesk portrait/landscape display, touch and settings-accordion acceptance for the prior increment.
