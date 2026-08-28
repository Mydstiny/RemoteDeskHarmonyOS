# RemoteDesk Queue

Updated: 2026-08-28 Asia/Shanghai

## Now

1. Upgrade a preserved 1.1.3 install to 1.1.4 and verify the update popup appears once, contains 22 pages, starts with the 1.1.4 summary, retains all 1.1.3 pages and ends with `welcome-1-1-4`; reopen it from Settings.
2. Validate the per-protocol wheel editor and direction matrix on device: change one protocol without affecting the other four; exercise all-normal/all-reverse; cover RDP/RustDesk/VNC physical mouse, physical touchpad and virtual touchpad; Moonlight physical and virtual input; SSH scrollback, alternate buffer and mouse tracking; confirm SFTP is unaffected.
3. On a HarmonyOS PC viewer, validate the new RustDesk per-host flip popup against affected Windows peers: all three modes, absolute/relative mouse mapping, remote cursor, PIP/foreground restore, reconnect persistence and stale computer metadata resolving to a mobile peer.
4. On the fixed HAP now installed at `192.168.3.235:38451`, verify login survives the historical migration `401`, exact-owner hashed data remains visible, local CRUD survives restart/offline use, and canonical/cloud recovery does not resurrect stale rows.
5. On `.235`, complete the already-queued RustDesk/RDP/VNC/Moonlight sidebar keyboard-close, scrolling, drag/bounds, touch isolation and phone immersive-bar acceptance.
6. Decide whether `192.168.3.236:40123` may be destructively uninstalled for the debug HAP or requires a matching release-provisioned acceptance HAP; preserve its existing data until explicitly authorized.

## Next

1. Add real-RDB fault-injection coverage for empty-table clear, unsafe VNC/Moonlight rows and higher-version account sources.
2. Complete app-clone acceptance on release-provisioned phone and tablet without clearing existing data.
3. Run Android RustDesk portrait/landscape display, touch and settings-accordion acceptance for the prior increment.
