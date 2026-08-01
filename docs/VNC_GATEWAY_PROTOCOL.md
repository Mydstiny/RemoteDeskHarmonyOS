# VNC Gateway Protocol (draft)

Status: draft, not enabled in the client.

This document defines the minimum server-side contract required before the
client can enable `websocket_gateway` or `public_relay`. It is not an
implementation claim and is not a substitute for a deployed, versioned
endpoint or an interoperability fixture.

## Scope

The gateway transports an already negotiated RFB byte stream. It must not
interpret RFB passwords, framebuffer messages or clipboard contents. The VNC
client remains the only RFB peer; the gateway authenticates the viewer and
selects the target.

`direct_tcp` and `ultravnc_repeater` are separate transports. They do not use
this WebSocket contract.

## UltraVNC Repeater role boundary

The client implements the official UltraVNC Viewer-side mode12 contract. After
the TCP/TLS connection, it must read exactly the 12-byte repeater banner
`RFB 000.000\n`, then send exactly 250 bytes containing `ID:<target>` followed
by NUL padding. The field has no newline terminator. The paired VNC server's
normal RFB banner follows that exchange.

UltraVNC mode2 is the repeater's server-side listener: a VNC Server connects
to the repeater and sends the same fixed 250-byte display/proxy field. This
HarmonyOS component is a VNC Viewer and therefore rejects mode2 at the UI and
native transport boundaries. Supporting mode2 later requires a separate
server/listener component and its own interoperability fixture; it is not a
viewer-side alternative to mode12. The byte contract is based on the
[official UltraVNC repeater sources](https://github.com/ultravnc/UltraVNC/tree/main/repeater).

## Endpoint and TLS

- Production endpoint: `wss://<gateway-host>/<path>`.
- `ws://` is permitted only when the user explicitly selects a trusted-LAN
  security policy and the server is on the same trusted network.
- The client pins the TLS certificate fingerprint after an interactive first
  connection. A cloud-restored fingerprint is a candidate only; it is never
  accepted without local confirmation.
- Credentials and tokens are never placed in the URL query, path, logs or
  close reason.

## WebSocket subprotocol

The HTTP upgrade must negotiate:

```text
Sec-WebSocket-Protocol: remotedesk-vnc-v1
```

The server must reject missing or unknown subprotocols with HTTP 426. The
server sends unmasked frames; the client sends masked frames. Only binary data
frames are accepted for the protocol channel. Text frames and unsupported
reserved bits are protocol errors.

## Versioned gateway hello

The first client binary message is UTF-8 JSON, not RFB:

```json
{
  "type": "gateway_hello",
  "version": 1,
  "client": "remotedesk-harmonyos",
  "requestId": "opaque-client-request-id",
  "targetId": "opaque-target-reference",
  "capabilities": ["rfb-byte-stream", "ping-pong"]
}
```

The request ID is non-secret and is used only for diagnostics. `targetId` is a
route reference, not a password. If a deployment requires a secret target
token, it must be supplied in the encrypted VNC `secret` owner and included by
the gateway adapter only in the authenticated hello field defined by the
deployment; it must never be copied into the gateway payload or URL.

The server replies with one binary JSON message:

```json
{
  "type": "gateway_hello_ack",
  "version": 1,
  "requestId": "opaque-client-request-id",
  "status": "ready",
  "sessionId": "opaque-server-session-id",
  "idleTimeoutMs": 60000
}
```

`status` is one of `ready`, `auth_required`, `target_not_found`,
`target_busy`, `unsupported_version` or `rejected`. The client must not send
RFB bytes before `ready`.

## Authentication

If a deployment uses a gateway access token, the agreed mechanism must be
explicitly versioned by the endpoint contract. The token is read from the
VNC `secret` owner only for the connection attempt, sent over TLS, then
cleared from client memory. It must not be logged or echoed in an error.

The server must bind the authenticated account to the selected target,
enforce an expiry and maximum concurrent sessions, and return a stable error
code for expired or unauthorized credentials.

## RFB stream and control frames

After `gateway_hello_ack(status=ready)`, every binary message is either:

- `rfb_data`: opaque RFB bytes;
- `ping`: a control JSON message with a nonce;
- `pong`: the response to a ping;
- `close`: a versioned close JSON message.

The deployment must define an unambiguous envelope for these messages (length
prefix or JSON header plus binary payload). A raw RFB byte stream without the
hello/ack boundary is not this protocol.

The gateway enforces a maximum frame size, cumulative receive quota, idle
timeout, bounded send queue and cancellation path. Backpressure must close
the session with `backpressure_limit` rather than allocate unbounded memory.

## Close codes

The server uses these stable codes: `normal`, `unauthorized`, `expired`,
`target_not_found`, `target_busy`, `protocol_version`, `tls_required`,
`backpressure_limit`, `idle_timeout`, `server_shutdown` and `internal_error`.
The client maps them to VNC diagnostics without exposing tokens or RFB data.

## Enablement gate

The client must keep `websocket_gateway`, `public_relay` and `ssh_tunnel`
unavailable until all of the following exist:

1. A deployed endpoint and server implementation;
2. A versioned authentication and target-selection contract approved by the
   service owner;
3. Scripted byte fixtures for handshake, fragmentation, ping/pong,
   backpressure, close and reconnect;
4. TLS/pinning and token-redaction tests; and
5. A real interoperability test with an RFB server behind the gateway.

Until then, the client reports an explicit contract-draft error and does not
fall back to ordinary WebSocket-to-RFB bytes.
