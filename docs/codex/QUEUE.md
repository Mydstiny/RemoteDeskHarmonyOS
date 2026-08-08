# SSH Full Upgrade Queue

Updated: 2026-08-08 Asia/Shanghai

## Now

- Close the final independent review for `fec26e2`; all SFTP transport/rename/cancel, cursor owner and VP9 policy findings have fixes and fresh build/Rust evidence.
- Commit compact state, accepted SFTP UI plans and diagnostic-plan updates without staging untracked `nwc`.
- Keep xterm.js as the visible terminal renderer; do not re-enable Native Drawing on API 23.

## Level A Follow-up

- Run second-host SSH switching with retained output, stale callback pressure and repeated detach/rebind.
- Complete physical keyboard, third-party IME, virtual keyboard/function-bar, rotation, split-window, PiP and background recovery coverage.
- Exercise durable SFTP against real endpoints: zero-byte, large file, recursive, cancel/retry, network loss, app restart, same-host copy and dual-SSH transfer.
- Verify authentication interruption during background SFTP, including host-key confirmation and multi-round MFA.

## Level B

- Bind each ProxyJump hop to independent host-key/auth/error context and validate one-to-three-hop OpenSSH chains.
- Finish local/remote/dynamic forwarding socket/channel integration behind the generation-owned runtime contract.
- Validate HTTP CONNECT, SOCKS5, raw `frp_tcp` and forwarding cleanup across reconnect/close.

## FRP Non-TCP

- Add a version-locked `FrpTransport` that owns token/visitor secret/version negotiation and exposes only an SSH byte stream.
- Keep Visitor/STCP/SUDP/XTCP unavailable until real frps/frpc interoperability passes; never downgrade them to direct/proxy/`frp_tcp`.

## Preserved Mixed-Protocol Follow-up

- RustDesk: run a real Windows session for steady FPS, input under motion and reconnect stability; retain the VP9 software pressure and high-resolution FPS ceiling regression coverage.
- RDP Gateway: validate dual certificate stages, negotiated transport evidence and rotation against a real Microsoft RD Gateway.
- VNC/RDP/RustDesk user changes remain preserved on this task branch and must not be reset or selectively discarded.

## Known Blockers

- `ohosTest@OhosTestCompileArkTS` is unregistered (`00306054`).
- Light compliance baseline reports `totp-reviewed-brand-assets` as `licenseDeclared=NOASSERTION`.
- Real ProxyJump, forwarding and FRP endpoint infrastructure is unavailable.
- Native SSH GPU surface is not an acceptance path after API 23 BufferQueue abort reproduction.
