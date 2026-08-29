# RemoteDesk Queue

Updated: 2026-08-29 Asia/Shanghai

## Now

1. Implement `docs/codex/plans/2026-08-29-per-protocol-pinch-zoom-and-pointer-follow.md`: five device-local protocol switches, one selection sheet, focal pinch plus same-stream canvas pan, and safe-zone/edge-zone pointer-follow for graphical protocols; retain SSH font-pinch and exclude SFTP.
2. Upgrade a preserved 1.1.3 install to 1.1.4 and verify the update popup appears once, contains only the 10 current 1.1.4 pages, starts with the 1.1.4 summary, contains no 1.1.3 page and ends with `welcome-1-1-4`; reopen it from Settings and verify a reused high legacy page index cannot restore pages 10–21 or flash a stale count.
3. Validate the per-protocol wheel editor and direction matrix on device: change one protocol without affecting the other four; exercise all-normal/all-reverse; cover RDP/RustDesk/VNC physical mouse, physical touchpad and virtual touchpad; Moonlight physical and virtual input; SSH scrollback, alternate buffer and mouse tracking; confirm SFTP is unaffected.
4. On a HarmonyOS PC viewer, validate the new RustDesk per-host flip popup against affected Windows peers: all three modes, absolute/relative mouse mapping, remote cursor, PIP/foreground restore, reconnect persistence and stale computer metadata resolving to a mobile peer.
5. On the fixed HAP now installed at `192.168.3.235:38451`, verify login survives the historical migration `401`, exact-owner hashed data remains visible, local CRUD survives restart/offline use, and canonical/cloud recovery does not resurrect stale rows.
6. On `.235`, complete the already-queued RustDesk/RDP/VNC/Moonlight sidebar keyboard-close, scrolling, drag/bounds, touch isolation and phone immersive-bar acceptance.
7. Decide whether `192.168.3.236:40123` may be destructively uninstalled for the debug HAP or requires a matching release-provisioned acceptance HAP; preserve its existing data until explicitly authorized.

## Next

1. Add real-RDB fault-injection coverage for empty-table clear, unsafe VNC/Moonlight rows and higher-version account sources.
2. Complete app-clone acceptance on release-provisioned phone and tablet without clearing existing data.
3. Run Android RustDesk portrait/landscape display, touch and settings-accordion acceptance for the prior increment.
