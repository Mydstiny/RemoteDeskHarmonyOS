// RustDesk Rendezvous 服务器交互。
//
// TCP rendezvous 在 RegisterPeer 前会先发送 RendezvousMessage::KeyExchange。
// 完成该握手后，后续 RegisterPeer/RegisterPk/RequestRelay 都通过同一
// BytesCodec 帧承载 secretbox 加密 payload。

use super::rendezvous_proto::{
    ConnType, KeyExchange, NatType, PunchHoleRequest, RegisterPeer, RegisterPeerResponse,
    RegisterPk, RendezvousMessage, RendezvousMessage_oneof_union, RequestRelay,
};
use super::wire;
use crate::crypto;
use crate::net;
use protobuf::Message;
use rand::RngCore;
use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, TcpStream};
use std::time::Duration;
use std::time::{SystemTime, UNIX_EPOCH};

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
}

#[derive(Debug, Clone)]
pub struct PunchHoleInfo {
    pub relay_server: String,
    pub signed_pk: Vec<u8>,
    pub peer_addr: Option<SocketAddr>,
    pub relay_uuid: Option<String>,
}

fn validated_server_key(server_key: &str) -> io::Result<&str> {
    crypto::normalized_server_public_key(server_key).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid rendezvous server public key; expected Base64-encoded 32-byte key",
        )
    })
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
        }
    }

    pub fn connect(
        &mut self,
        host: &str,
        port: u16,
        server_key: &str,
        secure: bool,
    ) -> io::Result<()> {
        self.state = RdState::Connecting;

        let stream = net::connect_tcp_host(host, port, "rendezvous", Duration::from_secs(10))?;

        stream.set_read_timeout(Some(Duration::from_secs(30)))?;
        stream.set_write_timeout(Some(Duration::from_secs(10)))?;

        self.stream = Some(stream);
        if secure {
            self.secure_tcp(server_key)?;
        }
        Ok(())
    }

    pub fn request_punch_hole(
        &mut self,
        peer_id: &str,
        server_key: &str,
    ) -> io::Result<PunchHoleInfo> {
        self.ensure_connected()?;
        let licence_key = validated_server_key(server_key)?;
        let req_debug = format!(
            "peer_id={}, key_len={}, nat=SYMMETRIC, conn=DEFAULT_CONN, force_relay=true, version=harmonyos-rustdesk-ffi",
            peer_id,
            licence_key.len()
        );

        let mut req = PunchHoleRequest::new();
        req.set_id(peer_id.to_string());
        req.set_nat_type(NatType::SYMMETRIC);
        req.set_licence_key(licence_key.to_string());
        req.set_conn_type(ConnType::DEFAULT_CONN);
        req.set_version("harmonyos-rustdesk-ffi".to_string());
        req.set_force_relay(true);

        let mut msg = RendezvousMessage::new();
        msg.union = Some(RendezvousMessage_oneof_union::punch_hole_request(req));
        self.send_message(&msg)?;

        let response = self.read_next_non_keyexchange()?;
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
                if relay_server.is_empty() {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        format!("punch hole response missing relay server ({})", req_debug),
                    ));
                }
                Ok(PunchHoleInfo {
                    relay_server,
                    signed_pk: resp.get_pk().to_vec(),
                    peer_addr: Some(decode_socket_addr(resp.get_socket_addr())?),
                    relay_uuid: None,
                })
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
                Ok(PunchHoleInfo {
                    relay_server,
                    signed_pk: resp.get_pk().to_vec(),
                    peer_addr: None,
                    relay_uuid: Some(relay_uuid),
                })
            }
            other => Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("expected PunchHoleResponse, got: {:?}", other),
            )),
        }
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
    ) -> io::Result<SocketAddr> {
        self.ensure_connected()?;

        let mut req = RequestRelay::new();
        req.set_id(id.to_string());
        req.set_uuid(uuid.to_string());
        req.set_relay_server(relay_server.to_string());
        req.set_secure(true);

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
    ) -> io::Result<String> {
        self.ensure_connected()?;

        let uuid = new_relay_uuid();
        eprintln!(
            "[RustDesk-FFI] request relay id={} uuid={} relay_server={} secure={}",
            id, uuid, relay_server, secure
        );

        let mut req = RequestRelay::new();
        req.set_id(id.to_string());
        req.set_uuid(uuid.clone());
        req.set_relay_server(relay_server.to_string());
        req.set_secure(secure);

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
                    "[RustDesk-FFI] relay response uuid={} relay_server={} pk_len={} socket_addr_len={}",
                    approved_uuid,
                    resp.get_relay_server(),
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
        server_key: &str,
    ) -> io::Result<TcpStream> {
        let licence_key = validated_server_key(server_key)?;
        let mut stream = net::connect_tcp_endpoint(
            relay_server,
            21117,
            "relay",
            Duration::from_secs(10),
        )?;
        stream.set_read_timeout(Some(Duration::from_secs(30)))?;
        stream.set_write_timeout(Some(Duration::from_secs(10)))?;

        let mut req = RequestRelay::new();
        req.set_id(id.to_string());
        req.set_uuid(uuid.to_string());
        req.set_licence_key(licence_key.to_string());
        req.set_conn_type(ConnType::DEFAULT_CONN);

        let mut msg = RendezvousMessage::new();
        msg.union = Some(RendezvousMessage_oneof_union::request_relay(req));
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
        let stream = TcpStream::connect_timeout(&addr, Duration::from_secs(10))?;
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
        let stream = self
            .stream
            .as_mut()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotConnected, "TCP not connected"))?;
        wire::read_frame(stream)
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
    use super::*;
    use std::io::ErrorKind;
    use std::net::TcpListener;
    use std::thread;

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
    fn relay_connect_accepts_hostname_endpoint_with_explicit_port() {
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
            assert!(!payload.is_empty(), "relay request frame should not be empty");
        });

        let client = RendezvousClient::new();
        let relay_endpoint = format!("localhost:{}", port);
        let stream = client
            .create_relay("peer", "uuid", &relay_endpoint, "")
            .expect("relay hostname should resolve and connect");
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
