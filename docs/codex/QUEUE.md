# SSH Full Upgrade Queue

Updated: 2026-08-09 Asia/Shanghai

## Now

- Publish reviewed candidate `dec23b430` through branch push, ready PR, required `open-source-compliance`, merge and local `main` synchronization.
- Device-check 1.1.0 clean-install versus update inheritance, Phone/Pad/PC input defaults, SSH terminal symbol, VNC semantic option symbols, TOTP logo matching and Pad control docking.
- On a Phone, verify that the final RustDesk relay card scrolls fully above the FAB and that the collapsed add sheet is compact before expanding advanced configuration.
- On Phone and Pad, verify all 12 update pages, the 10-page first-install guide and the 10-page Settings usage tutorial for pagination, text fit, final actions and sheet sizing.
- From Settings → Tutorial, confirm the duplicate `新用户引导` entry is gone and repeatedly opening `本版本更新日志` does not change startup read state.
- Verify the collapsed RustDesk relay add/edit sheet is comfortably tall on Phone/Pad/PC, remains bounded in split-screen, and expands to the large layout only after advanced configuration opens.
- Provision and run the real HTTP CONNECT, SOCKS5, ProxyJump, external FRP TCP/Visitor and Remote/Dynamic forwarding traffic matrix. Local forwarding already passed real SSH banner/KEX traffic on the wireless Pad.
- Keep xterm.js as the visible terminal renderer; do not re-enable Native Drawing on API 23.

## Level A Follow-up

- Run second-host SSH switching with retained output, stale callback pressure and repeated detach/rebind.
- Complete physical keyboard, third-party IME, virtual keyboard/function-bar, rotation, split-window, PiP and background recovery coverage.
- Exercise durable SFTP against real endpoints: zero-byte, large file, recursive, cancel/retry, network loss, app restart, same-host copy and dual-SSH transfer.
- Verify authentication interruption during background SFTP, including host-key confirmation and multi-round MFA.

## Level B Acceptance

- Validate each ProxyJump hop's independent host-key/auth/error context on one-to-three-hop OpenSSH chains.
- Extend the accepted Local traffic path with limits/disconnect/reconnect/stale-generation pressure, and validate Remote/Dynamic listeners with real traffic.
- Validate HTTP CONNECT, SOCKS5 and external FRP TCP/Visitor endpoints; the App must remain a TCP client and never embed FRP control-plane behavior.

## FRP Non-TCP

- Add a version-locked `FrpTransport` that owns token/visitor secret/version negotiation and exposes only an SSH byte stream.
- Keep Visitor/STCP/SUDP/XTCP unavailable until real frps/frpc interoperability passes; never downgrade them to direct/proxy/`frp_tcp`.

## Preserved Mixed-Protocol Follow-up

- RustDesk: run a real Windows session for steady FPS, input under motion and reconnect stability; retain the VP9 software pressure and high-resolution FPS ceiling regression coverage.
- RDP Gateway: validate dual certificate stages, negotiated transport evidence and rotation against a real Microsoft RD Gateway.
- VNC/RDP/RustDesk user changes remain preserved on this task branch and must not be reset or selectively discarded.

## Known Blockers

- `ohosTest@OhosTestCompileArkTS` is unregistered (`00306054`).
- Real HTTP/SOCKS proxy, ProxyJump, Remote/Dynamic forwarding and external FRP endpoint infrastructure is unavailable; Local forwarding traffic is no longer blocked.
- Native SSH GPU surface is not an acceptance path after API 23 BufferQueue abort reproduction.
