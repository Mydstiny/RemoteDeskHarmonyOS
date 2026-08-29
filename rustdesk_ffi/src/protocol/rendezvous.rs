// RustDesk Rendezvous 服务器交互。
//
// TCP rendezvous 在 RegisterPeer 前会先发送 RendezvousMessage::KeyExchange。
// 完成该握手后，后续 RegisterPeer/RegisterPk/RequestRelay 都通过同一
// BytesCodec 帧承载 secretbox 加密 payload。

use super::rendezvous_proto::{
    ConnType, KeyExchange, NatType, PunchHoleRequest, PunchHoleResponse, RegisterPeer,
    RegisterPeerResponse, RegisterPk, RendezvousMessage, RendezvousMessage_oneof_union,
    RequestRelay,
};
use super::wire;
use crate::crypto;
use crate::net;
use protobuf::Message;
use rand::RngCore;
use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, TcpStream};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, PartialEq)]
pub enum RdState {
    Disconnected,
    Connecting,
    Registered,
    RelayReady(SocketAddr),
    Error(String),
}

pub struct RendezvousClient {
    stream: Option<TcpStream>,
    state: RdState,
    secure_key: Option<[u8; 32]>,
    tx_seq: u64,
    rx_seq: u64,
    pending: Option<RendezvousMessage>,
    connect_epoch: Option<u64>,
}

#[derive(Debug, Clone)]
pub struct PunchHoleInfo {
    pub relay_server: String,
    pub signed_pk: Vec<u8>,
    pub peer_addr: Option<SocketAddr>,
    pub relay_uuid: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RendezvousConnectionStrategy {
    ForceRelay,
}

impl RendezvousConnectionStrategy {
    fn nat_type(self) -> NatType {
        match self {
            // This is an honest "unknown/conservative" value for the only
            // currently supported rendezvous strategy. It must not be reused
            // as an AUTO NAT result.
            Self::ForceRelay => NatType::SYMMETRIC,
        }
    }

    fn force_relay(self) -> bool {
        matches!(self, Self::ForceRelay)
    }

    fn diagnostic(self) -> &'static str {
        match self {
            Self::ForceRelay => "strategy=force_relay,nat=conservative_symmetric",
        }
    }
}

const HARMONY_RENDEZVOUS_VERSION: &str =
    concat!("harmonyos-rustdesk-ffi/", env!("CARGO_PKG_VERSION"));

fn validated_server_key(server_key: &str) -> io::Result<&str> {
    crypto::normalized_server_public_key(server_key).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid rendezvous server public key; expected Base64-encoded 32-byte key",
        )
    })
}

fn punch_hole_request_message(
    peer_id: &str,
    licence_key: &str,
    token: &str,
    strategy: RendezvousConnectionStrategy,
    conn_type: ConnType,
) -> RendezvousMessage {
    let mut req = PunchHoleRequest::new();
    req.set_id(peer_id.to_string());
    req.set_nat_type(strategy.nat_type());
    req.set_licence_key(licence_key.to_string());
    if !token.is_empty() {
        req.set_token(token.to_string());
    }
    req.set_conn_type(conn_type);
    req.set_version(HARMONY_RENDEZVOUS_VERSION.to_string());
    req.set_force_relay(strategy.force_relay());

    let mut msg = RendezvousMessage::new();
    msg.union = Some(RendezvousMessage_oneof_union::punch_hole_request(req));
    msg
}

fn request_relay_message(
    id: &str,
    uuid: &str,
    licence_key: &str,
    conn_type: ConnType,
) -> RendezvousMessage {
    let mut req = RequestRelay::new();
    req.set_id(id.to_string());
    req.set_uuid(uuid.to_string());
    req.set_licence_key(licence_key.to_string());
    req.set_conn_type(conn_type);

    let mut msg = RendezvousMessage::new();
    msg.union = Some(RendezvousMessage_oneof_union::request_relay(req));
    msg
}

impl RendezvousClient {
    pub fn new() -> Self {
        Self {
            stream: None,
            state: RdState::Disconnected,
            secure_key: None,
            tx_seq: 0,
            rx_seq: 0,
            pending: None,
            connect_epoch: None,
        }
    }

    pub fn new_with_connect_epoch(connect_epoch: u64) -> Self {
        let mut client = Self::new();
        client.connect_epoch = Some(connect_epoch);
        client
    }

    pub fn connect(
        &mut self,
        host: &str,
        port: u16,
        server_key: &str,
        secure: bool,
    ) -> io::Result<()> {
        self.connect_with_timeout(host, port, server_key, secure, Duration::from_secs(10))
    }

    pub fn connect_with_timeout(
        &mut self,
        host: &str,
        port: u16,
        server_key: &str,
        secure: bool,
        timeout: Duration,
    ) -> io::Result<()> {
        self.state = RdState::Connecting;

        let stream = match self.connect_epoch {
            Some(epoch) => {
                net::connect_tcp_host_cancellable(host, port, "rendezvous", timeout, epoch)?
            }
            None => net::connect_tcp_host(host, port, "rendezvous", timeout)?,
        };

        stream.set_read_timeout(Some(timeout))?;
        stream.set_write_timeout(Some(timeout))?;

        self.stream = Some(stream);
        if secure {
            self.secure_tcp(server_key)?;
        }
        Ok(())
    }

    pub fn request_force_relay(
        &mut self,
        peer_id: &str,
        licence_key: &str,
        token: &str,
        conn_type: ConnType,
    ) -> io::Result<PunchHoleInfo> {
        self.ensure_connected()?;
        let strategy = RendezvousConnectionStrategy::ForceRelay;
        let req_debug = format!(
            "{},conn={:?},force_relay=true,token={},key={},version={}",
            strategy.diagnostic(),
            conn_type,
            if token.is_empty() {
                "absent"
            } else {
                "present"
            },
            if licence_key.is_empty() {
                "absent"
            } else {
                "present"
            },
            HARMONY_RENDEZVOUS_VERSION
        );

        // hbbs `-k` compares this protobuf string verbatim.  It may be a
        // normal signing public key or an arbitrary administrator supplied
        // shared access value; verification is handled separately by the
        // connector when a public key is actually available.
        let msg = punch_hole_request_message(peer_id, licence_key, token, strategy, conn_type);
        // A PunchHoleRequest is one rendezvous transaction over a reliable
        // TCP stream.  The server can interleave coordination messages for a
        // controlled-peer role before the controller's PunchHoleResponse, but
        // resending the request at that point starts a second transaction and
        // some hbbs versions never answer either one.  Send exactly once and
        // keep consuming the bounded set of unrelated messages instead.
        self.send_message(&msg)?;
        let mut last_unexpected = "none";
        for attempt in 1u64..=3 {
            if let Some(stream) = self.stream.as_ref() {
                stream.set_read_timeout(Some(Duration::from_secs(3)))?;
            }

            let response = match self.read_next_non_keyexchange() {
                Ok(response) => response,
                Err(err)
                    if err.kind() == io::ErrorKind::TimedOut
                        || err.kind() == io::ErrorKind::WouldBlock =>
                {
                    last_unexpected = "timeout";
                    eprintln!(
                        "[RustDesk-FFI] rendezvous route read_attempt={} timed_out=true request_resent=false",
                        attempt
                    );
                    continue;
                }
                Err(err) => return Err(err),
            };
            match response.union {
                Some(RendezvousMessage_oneof_union::punch_hole_response(resp)) => {
                    if resp.get_socket_addr().is_empty() {
                        let other = resp.get_other_failure();
                        let reason = if other.is_empty() {
                            format!("punch hole refused: {:?}", resp.get_failure())
                        } else {
                            other.to_string()
                        };
                        return Err(io::Error::new(
                            io::ErrorKind::ConnectionRefused,
                            format!("{} ({})", reason, req_debug),
                        ));
                    }
                    let relay_server = resp.get_relay_server().to_string();
                    // OSS hbbs may ignore force_relay and answer a direct peer
                    // address in socket_addr without a relay_server. That is a
                    // valid punch response, not an error: the caller connects the
                    // returned address directly (official client behavior).
                    let peer_addr: SocketAddr = decode_socket_addr(resp.get_socket_addr())?;
                    return Ok(PunchHoleInfo {
                        relay_server,
                        signed_pk: resp.get_pk().to_vec(),
                        peer_addr: Some(peer_addr),
                        relay_uuid: None,
                    });
                }
                Some(RendezvousMessage_oneof_union::relay_response(resp)) => {
                    if !resp.get_refuse_reason().is_empty() {
                        return Err(io::Error::new(
                            io::ErrorKind::ConnectionRefused,
                            format!("{} ({})", resp.get_refuse_reason(), req_debug),
                        ));
                    }
                    let relay_server = resp.get_relay_server().to_string();
                    let relay_uuid = resp.get_uuid().to_string();
                    if relay_server.is_empty() || relay_uuid.is_empty() {
                        return Err(io::Error::new(
                            io::ErrorKind::InvalidData,
                            format!("relay response missing server or uuid ({})", req_debug),
                        ));
                    }
                    return Ok(PunchHoleInfo {
                        relay_server,
                        signed_pk: resp.get_pk().to_vec(),
                        peer_addr: None,
                        relay_uuid: Some(relay_uuid),
                    });
                }
                Some(RendezvousMessage_oneof_union::punch_hole(_)) => {
                    // This is a server-side coordination message for the
                    // controlled-peer role, not the route response requested
                    // by this controller connection. Keep reading the same
                    // transaction instead of aborting or resending it.
                    last_unexpected = "punch_hole";
                }
                Some(_) => {
                    last_unexpected = "other";
                }
                None => {
                    last_unexpected = "empty";
                }
            }
            eprintln!(
                "[RustDesk-FFI] rendezvous route read_attempt={} unexpected={} keep_reading=true request_resent=false",
                attempt, last_unexpected
            );
        }
        Err(io::Error::new(
            io::ErrorKind::TimedOut,
            format!(
                "rendezvous route response unavailable after 3 attempts last={}",
                last_unexpected
            ),
        ))
    }

    pub fn register_peer(&mut self, peer_id: &str) -> io::Result<bool> {
        self.ensure_connected()?;

        let mut reg = RegisterPeer::new();
        reg.set_id(peer_id.to_string());
        reg.set_serial(0);

        let mut msg = RendezvousMessage::new();
        msg.union = Some(RendezvousMessage_oneof_union::register_peer(reg));
        self.send_message(&msg)?;

        let response = self.read_message()?;
        match response.union {
            Some(RendezvousMessage_oneof_union::register_peer_response(resp)) => {
                let request_pk = resp.get_request_pk();
                self.state = RdState::Registered;
                Ok(request_pk)
            }
            other => {
                self.state = RdState::Error(format!("unexpected response: {:?}", other));
                Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("unexpected RendezvousMessage variant: {:?}", other),
                ))
            }
        }
    }

    pub fn register_pk(&mut self, id: &str, uuid: &[u8], pk: &[u8]) -> io::Result<()> {
        self.ensure_connected()?;

        let mut reg = RegisterPk::new();
        reg.set_id(id.to_string());
        reg.set_uuid(uuid.to_vec());
        reg.set_pk(pk.to_vec());

        let mut msg = RendezvousMessage::new();
        msg.union = Some(RendezvousMessage_oneof_union::register_pk(reg));
        self.send_message(&msg)?;

        let response = self.read_message()?;
        match response.union {
            Some(RendezvousMessage_oneof_union::register_pk_response(_)) => Ok(()),
            other => Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("expected RegisterPkResponse, got: {:?}", other),
            )),
        }
    }

    pub fn request_relay(
        &mut self,
        id: &str,
        uuid: &str,
        relay_server: &str,
        token: &str,
    ) -> io::Result<SocketAddr> {
        self.ensure_connected()?;

        let mut req = RequestRelay::new();
        req.set_id(id.to_string());
        req.set_uuid(uuid.to_string());
        req.set_relay_server(relay_server.to_string());
        req.set_secure(true);
        if !token.is_empty() {
            req.set_token(token.to_string());
        }

        let mut msg = RendezvousMessage::new();
        msg.union = Some(RendezvousMessage_oneof_union::request_relay(req));
        self.send_message(&msg)?;

        let response = self.read_message()?;
        match response.union {
            Some(RendezvousMessage_oneof_union::relay_response(resp)) => {
                if !resp.get_refuse_reason().is_empty() {
                    return Err(io::Error::new(
                        io::ErrorKind::ConnectionRefused,
                        resp.get_refuse_reason().to_string(),
                    ));
                }

                let addr_bytes = resp.get_socket_addr();
                if addr_bytes.len() >= 6 {
                    let ip = std::net::Ipv4Addr::new(
                        addr_bytes[0],
                        addr_bytes[1],
                        addr_bytes[2],
                        addr_bytes[3],
                    );
                    let port = u16::from_le_bytes([addr_bytes[4], addr_bytes[5]]);
                    let addr = SocketAddr::new(std::net::IpAddr::V4(ip), port);
                    self.state = RdState::RelayReady(addr);
                    Ok(addr)
                } else {
                    Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "invalid socket_addr in relay response",
                    ))
                }
            }
            other => Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("expected RelayResponse, got: {:?}", other),
            )),
        }
    }

    pub fn request_relay_uuid(
        &mut self,
        id: &str,
        relay_server: &str,
        secure: bool,
        token: &str,
    ) -> io::Result<String> {
        self.ensure_connected()?;

        let uuid = new_relay_uuid();
        eprintln!(
            "[RustDesk-FFI] request relay strategy=force_relay secure={} token={} key=handled-separately",
            secure,
            if token.is_empty() { "absent" } else { "present" }
        );

        let mut req = RequestRelay::new();
        req.set_id(id.to_string());
        req.set_uuid(uuid.clone());
        req.set_relay_server(relay_server.to_string());
        req.set_secure(secure);
        if !token.is_empty() {
            req.set_token(token.to_string());
        }

        let mut msg = RendezvousMessage::new();
        msg.union = Some(RendezvousMessage_oneof_union::request_relay(req));
        self.send_message(&msg)?;

        let response = self.read_next_non_keyexchange()?;
        match response.union {
            Some(RendezvousMessage_oneof_union::relay_response(resp)) => {
                if !resp.get_refuse_reason().is_empty() {
                    return Err(io::Error::new(
                        io::ErrorKind::ConnectionRefused,
                        resp.get_refuse_reason().to_string(),
                    ));
                }

                let response_uuid = resp.get_uuid();
                let approved_uuid = if response_uuid.is_empty() {
                    uuid
                } else {
                    response_uuid.to_string()
                };
                eprintln!(
                    "[RustDesk-FFI] relay response accepted relay_endpoint={} pk_len={} socket_addr_len={}",
                    if resp.get_relay_server().is_empty() { "absent" } else { "present" },
                    resp.get_pk().len(),
                    resp.get_socket_addr().len()
                );
                Ok(approved_uuid)
            }
            other => Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("expected RelayResponse, got: {:?}", other),
            )),
        }
    }

    pub fn create_relay(
        &self,
        id: &str,
        uuid: &str,
        relay_server: &str,
        relay_fallback_port: u16,
        server_key: &str,
        conn_type: ConnType,
    ) -> io::Result<TcpStream> {
        let mut stream = match self.connect_epoch {
            Some(epoch) => net::connect_tcp_endpoint_cancellable(
                relay_server,
                relay_fallback_port,
                "relay",
                Duration::from_secs(10),
                epoch,
            )?,
            None => net::connect_tcp_endpoint(
                relay_server,
                relay_fallback_port,
                "relay",
                Duration::from_secs(10),
            )?,
        };
        stream.set_read_timeout(Some(Duration::from_secs(30)))?;
        stream.set_write_timeout(Some(Duration::from_secs(10)))?;

        // hbbr uses the same exact shared `-k` comparison as hbbs.
        let msg = request_relay_message(id, uuid, server_key, conn_type);
        let payload = msg
            .write_to_bytes()
            .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
        wire::write_frame(&mut stream, &payload)?;
        Ok(stream)
    }

    pub fn punch_hole(&mut self, _peer_id: &str) -> io::Result<()> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "PunchHole requires UDP; use request_relay instead",
        ))
    }

    pub fn connect_to_peer(&self, addr: SocketAddr) -> io::Result<TcpStream> {
        let stream = match self.connect_epoch {
            Some(epoch) => net::connect_tcp_socket_address_cancellable(
                &addr,
                "peer candidate",
                Duration::from_secs(10),
                epoch,
            )?,
            None => TcpStream::connect_timeout(&addr, Duration::from_secs(10))?,
        };
        stream.set_read_timeout(Some(Duration::from_secs(30)))?;
        stream.set_write_timeout(Some(Duration::from_secs(10)))?;
        Ok(stream)
    }

    pub fn stream_mut(&mut self) -> Option<&mut TcpStream> {
        self.stream.as_mut()
    }

    pub fn state(&self) -> &RdState {
        &self.state
    }

    pub fn disconnect(&mut self) {
        self.stream.take();
        self.secure_key = None;
        self.pending = None;
        self.state = RdState::Disconnected;
    }

    fn secure_tcp(&mut self, server_key: &str) -> io::Result<()> {
        let payload = self.read_raw_frame()?;
        let response: RendezvousMessage = protobuf::parse_from_bytes(&payload)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;

        match response.union {
            Some(RendezvousMessage_oneof_union::key_exchange(ex)) => {
                self.reply_key_exchange(ex, server_key)?;
                Ok(())
            }
            other => {
                let mut pending = RendezvousMessage::new();
                pending.union = other;
                self.pending = Some(pending);
                Ok(())
            }
        }
    }

    fn reply_key_exchange(&mut self, ex: KeyExchange, server_key: &str) -> io::Result<()> {
        if ex.keys.len() != 1 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid rendezvous key exchange message",
            ));
        }

        let supplied_key = validated_server_key(server_key)?;
        let key = if supplied_key.is_empty() {
            crypto::RUSTDESK_SERVER_PUBLIC_KEY
        } else {
            supplied_key
        };
        let rs_pk = crypto::decode_base64_key(key).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid rendezvous server public key",
            )
        })?;
        let their_pk = crypto::verify_signed_message(&ex.keys[0], &rs_pk).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "rendezvous key exchange signature mismatch",
            )
        })?;
        if their_pk.len() != 32 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid rendezvous ephemeral public key length",
            ));
        }

        let mut their_pk_buf = [0u8; 32];
        their_pk_buf.copy_from_slice(&their_pk);
        let (our_pk, encrypted_key, key) = crypto::create_symmetric_key_msg(&their_pk_buf)
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::Other,
                    "failed to create rendezvous symmetric key",
                )
            })?;

        let mut reply = RendezvousMessage::new();
        let mut key_exchange = KeyExchange::new();
        key_exchange.keys.push(our_pk.to_vec());
        key_exchange.keys.push(encrypted_key);
        reply.union = Some(RendezvousMessage_oneof_union::key_exchange(key_exchange));
        self.write_raw_message(&reply)?;

        self.secure_key = Some(key);
        self.tx_seq = 0;
        self.rx_seq = 0;
        Ok(())
    }

    fn ensure_connected(&self) -> io::Result<()> {
        if self.stream.is_some() {
            Ok(())
        } else {
            Err(io::Error::new(
                io::ErrorKind::NotConnected,
                "TCP not connected",
            ))
        }
    }

    fn read_raw_frame(&mut self) -> io::Result<Vec<u8>> {
        let connect_epoch = self.connect_epoch;
        let stream = self
            .stream
            .as_mut()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotConnected, "TCP not connected"))?;
        let Some(connect_epoch) = connect_epoch else {
            return wire::read_frame(stream);
        };
        let timeout = stream.read_timeout()?.unwrap_or(Duration::from_secs(30));
        wire::read_frame_cancellable(stream, Instant::now() + timeout, || {
            crate::connect_cancelled(connect_epoch)
        })
    }

    fn write_raw_message(&mut self, msg: &RendezvousMessage) -> io::Result<()> {
        let payload = msg
            .write_to_bytes()
            .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
        let stream = self
            .stream
            .as_mut()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotConnected, "TCP not connected"))?;
        wire::write_frame(stream, &payload)
    }

    fn send_message(&mut self, msg: &RendezvousMessage) -> io::Result<()> {
        let payload = msg
            .write_to_bytes()
            .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
        self.write_payload(&payload)
    }

    fn read_message(&mut self) -> io::Result<RendezvousMessage> {
        if let Some(msg) = self.pending.take() {
            return Ok(msg);
        }

        let payload = self.read_payload()?;
        protobuf::parse_from_bytes(&payload)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
    }

    fn read_next_non_keyexchange(&mut self) -> io::Result<RendezvousMessage> {
        for _ in 0..2 {
            let msg = self.read_message()?;
            match msg.union {
                Some(RendezvousMessage_oneof_union::key_exchange(_)) => {
                    continue;
                }
                _ => return Ok(msg),
            }
        }
        Err(io::Error::new(
            io::ErrorKind::TimedOut,
            "only received rendezvous key exchange messages",
        ))
    }

    fn read_payload(&mut self) -> io::Result<Vec<u8>> {
        let payload = self.read_raw_frame()?;
        match self.secure_key {
            Some(key) => {
                self.rx_seq = self.rx_seq.wrapping_add(1);
                let nonce = crypto::secretbox_nonce(self.rx_seq);
                crypto::secretbox_decrypt(&payload, &nonce, &key).ok_or_else(|| {
                    io::Error::new(
                        io::ErrorKind::InvalidData,
                        "rendezvous secure tcp decrypt failed",
                    )
                })
            }
            None => Ok(payload),
        }
    }

    fn write_payload(&mut self, payload: &[u8]) -> io::Result<()> {
        let out = match self.secure_key {
            Some(key) => {
                self.tx_seq = self.tx_seq.wrapping_add(1);
                let nonce = crypto::secretbox_nonce(self.tx_seq);
                crypto::secretbox_encrypt(payload, &nonce, &key).ok_or_else(|| {
                    io::Error::new(io::ErrorKind::Other, "rendezvous secure tcp encrypt failed")
                })?
            }
            None => payload.to_vec(),
        };

        let stream = self
            .stream
            .as_mut()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotConnected, "TCP not connected"))?;
        wire::write_frame(stream, &out)
    }
}

fn decode_socket_addr(bytes: &[u8]) -> io::Result<SocketAddr> {
    if bytes.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "empty encoded socket address",
        ));
    }
    if bytes.len() > 16 {
        if bytes.len() != 18 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid encoded IPv6 socket address",
            ));
        }
        let mut port_bytes = [0u8; 2];
        port_bytes.copy_from_slice(&bytes[16..18]);
        let mut ip_bytes = [0u8; 16];
        ip_bytes.copy_from_slice(&bytes[..16]);
        return Ok(SocketAddr::new(
            IpAddr::V6(Ipv6Addr::from(ip_bytes)),
            u16::from_le_bytes(port_bytes),
        ));
    }

    let mut padded = [0u8; 16];
    padded[..bytes.len()].copy_from_slice(bytes);
    let number = u128::from_le_bytes(padded);
    let tm = (number >> 17) & (u32::MAX as u128);
    let ip_num = ((number >> 49).wrapping_sub(tm)) as u32;
    let ip = ip_num.to_le_bytes();
    let port = ((number & 0xFF_FFFF).wrapping_sub(tm & 0xFFFF)) as u16;
    Ok(SocketAddr::V4(SocketAddrV4::new(
        Ipv4Addr::new(ip[0], ip[1], ip[2], ip[3]),
        port,
    )))
}

fn new_relay_uuid() -> String {
    let mut bytes = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut bytes);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or_default()
        .to_le_bytes();
    for (byte, salt) in bytes.iter_mut().zip(nanos.iter()) {
        *byte ^= *salt;
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0],
        bytes[1],
        bytes[2],
        bytes[3],
        bytes[4],
        bytes[5],
        bytes[6],
        bytes[7],
        bytes[8],
        bytes[9],
        bytes[10],
        bytes[11],
        bytes[12],
        bytes[13],
        bytes[14],
        bytes[15]
    )
}

impl Drop for RendezvousClient {
    fn drop(&mut self) {
        self.disconnect();
    }
}

#[cfg(test)]
mod tests {
    use super::super::rendezvous_proto::{PunchHole, RelayResponse};
    use super::*;
    use std::io::ErrorKind;
    use std::net::TcpListener;
    use std::thread;

    fn encode_test_ipv4(addr: SocketAddrV4) -> Vec<u8> {
        // AddrMangle with a deterministic zero time component. Production
        // decoding accepts the full 16-byte little-endian representation.
        let ip = u32::from_le_bytes(addr.ip().octets()) as u128;
        ((ip << 49) | addr.port() as u128).to_le_bytes().to_vec()
    }

    #[test]
    fn arbitrary_shared_access_key_is_preserved_in_punch_and_relay_messages() {
        let key = " =tenant-key:42/abc=\n";
        let token = "pro-session-token";
        let punch = punch_hole_request_message(
            "peer-123",
            key,
            token,
            RendezvousConnectionStrategy::ForceRelay,
            ConnType::DEFAULT_CONN,
        );
        let punch_bytes = punch.write_to_bytes().expect("serialize punch request");
        let parsed_punch: RendezvousMessage =
            protobuf::parse_from_bytes(&punch_bytes).expect("parse punch request");
        match parsed_punch.union {
            Some(RendezvousMessage_oneof_union::punch_hole_request(req)) => {
                assert_eq!(req.get_licence_key(), key);
                assert_eq!(req.get_token(), token);
                assert_eq!(req.get_nat_type(), NatType::SYMMETRIC);
                assert!(req.get_force_relay());
                assert_eq!(req.get_conn_type(), ConnType::DEFAULT_CONN);
                assert_eq!(req.get_version(), HARMONY_RENDEZVOUS_VERSION);
            }
            other => panic!("expected PunchHoleRequest, got: {:?}", other),
        }

        let relay = request_relay_message("peer-123", "uuid-123", key, ConnType::DEFAULT_CONN);
        let relay_bytes = relay.write_to_bytes().expect("serialize relay request");
        let parsed_relay: RendezvousMessage =
            protobuf::parse_from_bytes(&relay_bytes).expect("parse relay request");
        match parsed_relay.union {
            Some(RendezvousMessage_oneof_union::request_relay(req)) => {
                assert_eq!(req.get_licence_key(), key);
            }
            other => panic!("expected RequestRelay, got: {:?}", other),
        }
    }

    #[test]
    fn file_transfer_connection_type_is_preserved_in_route_messages() {
        let punch = punch_hole_request_message(
            "peer-123",
            "key",
            "token",
            RendezvousConnectionStrategy::ForceRelay,
            ConnType::FILE_TRANSFER,
        );
        match punch.union {
            Some(RendezvousMessage_oneof_union::punch_hole_request(req)) => {
                assert_eq!(req.get_conn_type(), ConnType::FILE_TRANSFER);
            }
            other => panic!("expected PunchHoleRequest, got: {:?}", other),
        }

        let relay = request_relay_message("peer-123", "uuid-123", "key", ConnType::FILE_TRANSFER);
        match relay.union {
            Some(RendezvousMessage_oneof_union::request_relay(req)) => {
                assert_eq!(req.get_conn_type(), ConnType::FILE_TRANSFER);
            }
            other => panic!("expected RequestRelay, got: {:?}", other),
        }
    }

    #[test]
    fn punch_response_with_direct_peer_address_is_not_a_relay_error() {
        // OSS hbbs may ignore force_relay and answer with only a direct peer
        // address in socket_addr (no relay_server). The client must accept
        // that as a direct-connect punch response, not InvalidData.
        let addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(10, 0, 0, 5)), 21118);
        let encoded = encode_test_ipv4(SocketAddrV4::new(Ipv4Addr::new(10, 0, 0, 5), 21118));
        let mut resp = PunchHoleResponse::new();
        resp.set_socket_addr(encoded);
        let mut msg = RendezvousMessage::new();
        msg.union = Some(RendezvousMessage_oneof_union::punch_hole_response(resp));
        let payload = msg.write_to_bytes().expect("serialize punch response");

        let server = TcpListener::bind("127.0.0.1:0").expect("bind test server");
        let port = server.local_addr().expect("server addr").port();
        let server_thread = thread::spawn(move || {
            let (mut stream, _) = server.accept().expect("accept");
            let _hello = wire::read_frame(&mut stream).expect("read punch request");
            wire::write_frame(&mut stream, &payload).expect("write punch response");
        });

        let mut rd = RendezvousClient::new();
        rd.connect("127.0.0.1", port, "", false)
            .expect("connect rendezvous");
        let info = rd
            .request_force_relay("peer-123", "key", "", ConnType::DEFAULT_CONN)
            .expect("force relay");
        assert!(info.relay_server.is_empty(), "no relay server expected");
        assert_eq!(info.peer_addr, Some(addr), "direct peer address expected");
        server_thread.join().expect("server thread");
    }

    #[test]
    fn force_relay_keeps_reading_after_an_unrelated_punch_hole_message() {
        let mut punch = PunchHole::new();
        punch.set_relay_server("relay.example:21117".to_string());
        let mut unexpected = RendezvousMessage::new();
        unexpected.union = Some(RendezvousMessage_oneof_union::punch_hole(punch));
        let unexpected_payload = unexpected
            .write_to_bytes()
            .expect("serialize unrelated punch hole");

        let mut relay = RelayResponse::new();
        relay.set_relay_server("relay.example:21117".to_string());
        relay.set_uuid("file-transfer-route".to_string());
        let mut expected = RendezvousMessage::new();
        expected.union = Some(RendezvousMessage_oneof_union::relay_response(relay));
        let expected_payload = expected.write_to_bytes().expect("serialize relay response");

        let server = TcpListener::bind("127.0.0.1:0").expect("bind test server");
        let port = server.local_addr().expect("server addr").port();
        let server_thread = thread::spawn(move || {
            let (mut stream, _) = server.accept().expect("accept");
            let _first = wire::read_frame(&mut stream).expect("read first request");
            wire::write_frame(&mut stream, &unexpected_payload)
                .expect("write unrelated punch hole");
            wire::write_frame(&mut stream, &expected_payload).expect("write relay response");
        });

        let mut rd = RendezvousClient::new();
        rd.connect("127.0.0.1", port, "", false)
            .expect("connect rendezvous");
        let info = rd
            .request_force_relay("peer-123", "key", "", ConnType::FILE_TRANSFER)
            .expect("retry should obtain relay route");
        assert_eq!(info.relay_server, "relay.example:21117");
        assert_eq!(info.relay_uuid.as_deref(), Some("file-transfer-route"));
        server_thread.join().expect("server thread");
    }

    #[test]
    fn test_rendezvous_message_construction() {
        let mut reg = RegisterPeer::new();
        reg.set_id("test_peer_123".to_string());
        reg.set_serial(0);

        let mut msg = RendezvousMessage::new();
        msg.union = Some(RendezvousMessage_oneof_union::register_peer(reg));

        let payload = msg.write_to_bytes().expect("serialization failed");
        assert!(!payload.is_empty(), "payload should not be empty");

        let parsed: RendezvousMessage =
            protobuf::parse_from_bytes(&payload).expect("deserialization failed");

        match parsed.union {
            Some(RendezvousMessage_oneof_union::register_peer(ref rp)) => {
                assert_eq!(rp.get_id(), "test_peer_123");
                assert_eq!(rp.get_serial(), 0);
            }
            _ => panic!("wrong oneof variant"),
        }
    }

    #[test]
    fn test_register_peer_response_parsing() {
        let mut resp = RegisterPeerResponse::new();
        resp.set_request_pk(true);

        let mut msg = RendezvousMessage::new();
        msg.union = Some(RendezvousMessage_oneof_union::register_peer_response(resp));

        let payload = msg.write_to_bytes().expect("serialization failed");
        let parsed: RendezvousMessage =
            protobuf::parse_from_bytes(&payload).expect("deserialization failed");

        match parsed.union {
            Some(RendezvousMessage_oneof_union::register_peer_response(ref rpr)) => {
                assert!(rpr.get_request_pk());
            }
            _ => panic!("wrong oneof variant: {:?}", parsed.union),
        }
    }

    #[test]
    fn rendezvous_connect_accepts_hostname_endpoint() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener bind failed");
        let port = listener
            .local_addr()
            .expect("listener address missing")
            .port();
        let accept_thread = thread::spawn(move || {
            let _ = listener
                .accept()
                .expect("hostname connection was not accepted");
        });

        let mut client = RendezvousClient::new();
        client
            .connect("localhost", port, "", false)
            .expect("localhost should resolve and connect");
        accept_thread.join().expect("accept thread panicked");
    }

    #[test]
    fn relay_connect_uses_explicit_endpoint_port_before_configured_fallback() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener bind failed");
        let port = listener
            .local_addr()
            .expect("listener address missing")
            .port();
        let accept_thread = thread::spawn(move || {
            let (mut stream, _) = listener
                .accept()
                .expect("relay connection was not accepted");
            let payload = wire::read_frame(&mut stream).expect("relay request frame missing");
            assert!(
                !payload.is_empty(),
                "relay request frame should not be empty"
            );
        });

        let client = RendezvousClient::new();
        let relay_endpoint = format!("localhost:{}", port);
        let stream = client
            .create_relay(
                "peer",
                "uuid",
                &relay_endpoint,
                1,
                "",
                ConnType::DEFAULT_CONN,
            )
            .expect("relay hostname should resolve and connect");
        drop(stream);
        accept_thread.join().expect("accept thread panicked");
    }

    #[test]
    fn relay_connect_uses_configured_fallback_port_without_endpoint_port() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener bind failed");
        let port = listener
            .local_addr()
            .expect("listener address missing")
            .port();
        let accept_thread = thread::spawn(move || {
            let (mut stream, _) = listener
                .accept()
                .expect("relay connection was not accepted");
            let payload = wire::read_frame(&mut stream).expect("relay request frame missing");
            assert!(
                !payload.is_empty(),
                "relay request frame should not be empty"
            );
        });

        let client = RendezvousClient::new();
        let stream = client
            .create_relay(
                "peer",
                "uuid",
                "localhost",
                port,
                "",
                ConnType::DEFAULT_CONN,
            )
            .expect("configured relay fallback port should connect");
        drop(stream);
        accept_thread.join().expect("accept thread panicked");
    }

    #[test]
    fn rendezvous_rejects_url_schemes_before_socket_connect() {
        let mut client = RendezvousClient::new();
        let error = client
            .connect("https://localhost", 21116, "", false)
            .expect_err("URL scheme must not be accepted as a raw endpoint");
        assert_eq!(error.kind(), ErrorKind::InvalidInput);
        assert!(
            error.to_string().contains("scheme") || error.to_string().contains("endpoint"),
            "error should identify endpoint format: {}",
            error
        );
    }
}
