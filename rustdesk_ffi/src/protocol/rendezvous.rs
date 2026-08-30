// RustDesk Rendezvous 服务器交互。
//
// TCP rendezvous 在 RegisterPeer 前会先发送 RendezvousMessage::KeyExchange。
// 完成该握手后，后续 RegisterPeer/RegisterPk/RequestRelay 都通过同一
// BytesCodec 帧承载 secretbox 加密 payload。

use super::rendezvous_proto::{
    ConnType, KeyExchange, NatType, PunchHoleRequest, PunchHoleResponse, PunchHoleResponse_Failure,
    RegisterPeer, RegisterPk, RendezvousMessage, RendezvousMessage_oneof_union, RequestRelay,
    TestNatRequest,
};
use super::wire;
use crate::crypto;
use crate::net;
use protobuf::Message;
use rand::RngCore;
use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, TcpStream, UdpSocket};
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
    pub peer_candidates: Vec<PeerCandidate>,
    pub relay_uuid: Option<String>,
    pub peer_nat_type: NatType,
    pub is_local: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PeerCandidateSource {
    SocketAddr,
    SocketAddrV6,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PeerCandidateTransport {
    Tcp,
    Udp,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PeerCandidate {
    pub address: SocketAddr,
    pub source: PeerCandidateSource,
    pub transport: PeerCandidateTransport,
}

#[derive(Debug, Clone)]
pub struct RendezvousRouteOptions {
    nat_type: NatType,
    force_relay: bool,
    udp_port: u16,
    socket_addr_v6: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TcpNatProbeResult {
    pub nat_type: NatType,
    pub first_mapped_port: u16,
    pub second_mapped_port: u16,
}

fn punch_hole_refusal_kind(
    failure: PunchHoleResponse_Failure,
    other_failure: &str,
    has_unknown_failure: bool,
) -> io::ErrorKind {
    if has_unknown_failure || !other_failure.is_empty() {
        return io::ErrorKind::Other;
    }
    match failure {
        PunchHoleResponse_Failure::ID_NOT_EXIST | PunchHoleResponse_Failure::OFFLINE => {
            io::ErrorKind::NotFound
        }
        PunchHoleResponse_Failure::LICENSE_MISMATCH
        | PunchHoleResponse_Failure::LICENSE_OVERUSE => io::ErrorKind::PermissionDenied,
    }
}

fn punch_hole_response_has_unknown_failure(response: &PunchHoleResponse) -> bool {
    response.get_unknown_fields().get(3).is_some()
}

/// A short-lived UDP mapping registration against hbbs. The socket remains
/// owned by this lease so the mapping cannot disappear between TestNatResponse
/// and PunchHoleRequest. Product code keeps UDP/KCP advertisement gated until
/// that data transport has completed its device matrix.
pub struct UdpNatLease {
    socket: UdpSocket,
    server_address: SocketAddr,
    mapped_port: u16,
}

impl UdpNatLease {
    pub fn mapped_port(&self) -> u16 {
        self.mapped_port
    }

    pub fn local_address(&self) -> io::Result<SocketAddr> {
        self.socket.local_addr()
    }

    /// Refresh the mapping with one bounded TestNat exchange. This is a client
    /// heartbeat only: it never answers packets and therefore cannot become a
    /// reflector or an unbounded background task.
    pub fn heartbeat(
        &mut self,
        serial: i32,
        timeout: Duration,
        cancel_epoch: Option<u64>,
    ) -> io::Result<u16> {
        self.mapped_port = exchange_udp_nat_mapping(
            &self.socket,
            self.server_address,
            serial,
            timeout,
            cancel_epoch,
        )?;
        Ok(self.mapped_port)
    }
}

impl RendezvousRouteOptions {
    pub fn force_relay() -> Self {
        Self {
            // This is an honest conservative value for forced relay. It must
            // never be reused as an AUTO NAT result.
            nat_type: NatType::SYMMETRIC,
            force_relay: true,
            udp_port: 0,
            socket_addr_v6: Vec::new(),
        }
    }

    pub fn automatic(nat_type: NatType, udp_port: u16, socket_addr_v6: Vec<u8>) -> Self {
        Self {
            nat_type,
            force_relay: false,
            udp_port,
            socket_addr_v6,
        }
    }

    fn diagnostic(&self) -> &'static str {
        if self.force_relay {
            "strategy=force_relay,nat=conservative_symmetric"
        } else {
            "strategy=auto,nat=measured"
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
    options: &RendezvousRouteOptions,
    conn_type: ConnType,
) -> RendezvousMessage {
    let mut req = PunchHoleRequest::new();
    req.set_id(peer_id.to_string());
    req.set_nat_type(options.nat_type);
    req.set_licence_key(licence_key.to_string());
    if !token.is_empty() {
        req.set_token(token.to_string());
    }
    req.set_conn_type(conn_type);
    req.set_version(HARMONY_RENDEZVOUS_VERSION.to_string());
    req.set_udp_port(options.udp_port as i32);
    req.set_force_relay(options.force_relay);
    if !options.socket_addr_v6.is_empty() {
        req.set_socket_addr_v6(options.socket_addr_v6.clone());
    }

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
        self.ensure_not_cancelled("rendezvous connect")?;
        let deadline = Instant::now() + timeout;

        let stream = match self.connect_epoch {
            Some(epoch) => {
                net::connect_tcp_host_cancellable(host, port, "rendezvous", timeout, epoch)?
            }
            None => net::connect_tcp_host(host, port, "rendezvous", timeout)?,
        };

        let remaining = remaining_timeout(deadline, "rendezvous handshake")?;
        stream.set_read_timeout(Some(remaining))?;
        stream.set_write_timeout(Some(remaining))?;

        self.stream = Some(stream);
        if secure {
            self.secure_tcp(server_key)?;
        }
        Ok(())
    }

    fn connect_bound_to_address_with_timeout(
        &mut self,
        address: SocketAddr,
        local_address: SocketAddr,
        timeout: Duration,
    ) -> io::Result<()> {
        self.state = RdState::Connecting;
        let stream = match self.connect_epoch {
            Some(epoch) => net::connect_tcp_socket_addresses_bound_cancellable(
                &[address],
                local_address,
                "rendezvous NAT probe",
                timeout,
                epoch,
            )?,
            None => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "bound NAT probe requires a cancellable connection epoch",
                ));
            }
        };
        stream.set_read_timeout(Some(timeout))?;
        stream.set_write_timeout(Some(timeout))?;
        self.stream = Some(stream);
        Ok(())
    }

    /// Run the official two-port TCP NAT classification. Both connections use
    /// the same local address; equal mapped ports are classified ASYMMETRIC,
    /// differing ports SYMMETRIC. The whole operation shares one deadline.
    pub fn probe_tcp_nat(
        host: &str,
        port: u16,
        serial: i32,
        connect_epoch: u64,
        timeout: Duration,
    ) -> io::Result<TcpNatProbeResult> {
        if port <= 1 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "rendezvous NAT probe requires a server port greater than one",
            ));
        }
        let deadline = Instant::now() + timeout;
        let mut first = RendezvousClient::new_with_connect_epoch(connect_epoch);
        first.connect_with_timeout(
            host,
            port,
            "",
            false,
            remaining_timeout(deadline, "first NAT probe connect")?,
        )?;
        let local_address = first.local_address()?;
        let mut second_server = first.peer_address()?;
        let first_mapped_port = first.test_nat_until(serial, deadline)? as u16;
        first.disconnect();

        let second_port = second_server.port().checked_sub(1).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "resolved rendezvous NAT probe port cannot be decremented",
            )
        })?;
        second_server.set_port(second_port);
        let mut second = RendezvousClient::new_with_connect_epoch(connect_epoch);
        second.connect_bound_to_address_with_timeout(
            second_server,
            local_address,
            remaining_timeout(deadline, "second NAT probe connect")?,
        )?;
        let second_mapped_port = second.test_nat_until(serial, deadline)? as u16;
        let nat_type = if first_mapped_port == second_mapped_port {
            NatType::ASYMMETRIC
        } else {
            NatType::SYMMETRIC
        };
        Ok(TcpNatProbeResult {
            nat_type,
            first_mapped_port,
            second_mapped_port,
        })
    }

    /// Register one bounded UDP mapping with the configured hbbs endpoint.
    /// The returned lease owns the socket and can issue explicit heartbeats.
    pub fn register_udp_mapping(
        server_address: SocketAddr,
        serial: i32,
        timeout: Duration,
        cancel_epoch: Option<u64>,
    ) -> io::Result<UdpNatLease> {
        let bind_address = match server_address {
            SocketAddr::V4(_) => SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0),
            SocketAddr::V6(_) => SocketAddr::new(IpAddr::V6(Ipv6Addr::UNSPECIFIED), 0),
        };
        let socket = UdpSocket::bind(bind_address)?;
        // Connecting a UDP socket fixes the resolver owner/source route and
        // turns local_addr() into the concrete address selected for hbbs. It
        // also prevents datagrams from unrelated endpoints entering the NAT
        // registration state machine.
        socket.connect(server_address)?;
        let mapped_port =
            exchange_udp_nat_mapping(&socket, server_address, serial, timeout, cancel_epoch)?;
        Ok(UdpNatLease {
            socket,
            server_address,
            mapped_port,
        })
    }

    pub fn request_force_relay(
        &mut self,
        peer_id: &str,
        licence_key: &str,
        token: &str,
        conn_type: ConnType,
    ) -> io::Result<PunchHoleInfo> {
        self.request_route(
            peer_id,
            licence_key,
            token,
            conn_type,
            RendezvousRouteOptions::force_relay(),
        )
    }

    pub fn request_route(
        &mut self,
        peer_id: &str,
        licence_key: &str,
        token: &str,
        conn_type: ConnType,
        options: RendezvousRouteOptions,
    ) -> io::Result<PunchHoleInfo> {
        self.request_route_with_timeout(
            peer_id,
            licence_key,
            token,
            conn_type,
            options,
            Duration::from_secs(9),
        )
    }

    pub fn request_route_with_timeout(
        &mut self,
        peer_id: &str,
        licence_key: &str,
        token: &str,
        conn_type: ConnType,
        options: RendezvousRouteOptions,
        timeout: Duration,
    ) -> io::Result<PunchHoleInfo> {
        self.ensure_connected()?;
        self.ensure_not_cancelled("rendezvous route")?;
        let deadline = Instant::now() + timeout;
        let req_debug = format!(
            "{},conn={:?},force_relay={},udp={},v6={},token={},key={},version={}",
            options.diagnostic(),
            conn_type,
            options.force_relay,
            if options.udp_port > 0 {
                "present"
            } else {
                "absent"
            },
            if options.socket_addr_v6.is_empty() {
                "absent"
            } else {
                "present"
            },
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
        let msg = punch_hole_request_message(peer_id, licence_key, token, &options, conn_type);
        // A PunchHoleRequest is one rendezvous transaction over a reliable
        // TCP stream.  The server can interleave coordination messages for a
        // controlled-peer role before the controller's PunchHoleResponse, but
        // resending the request at that point starts a second transaction and
        // some hbbs versions never answer either one.  Send exactly once and
        // keep consuming the bounded set of unrelated messages instead.
        self.set_io_timeout(remaining_timeout(deadline, "rendezvous route request")?)?;
        self.send_message(&msg)?;
        let mut last_unexpected = "none";
        for attempt in 1u64..=3 {
            self.ensure_not_cancelled("rendezvous route response")?;
            if let Some(stream) = self.stream.as_ref() {
                stream.set_read_timeout(Some(
                    remaining_timeout(deadline, "rendezvous route response")?
                        .min(Duration::from_secs(3)),
                ))?;
            }

            let response = match self.read_next_non_keyexchange_until(deadline) {
                Ok(response) => response,
                Err(err)
                    if err.kind() == io::ErrorKind::TimedOut
                        || err.kind() == io::ErrorKind::WouldBlock =>
                {
                    self.ensure_not_cancelled("rendezvous route response")?;
                    if deadline.saturating_duration_since(Instant::now()).is_zero() {
                        return Err(io::Error::new(
                            io::ErrorKind::TimedOut,
                            "rendezvous route exceeded the shared connection deadline",
                        ));
                    }
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
                    if resp.get_socket_addr().is_empty()
                        && resp.get_socket_addr_v6().is_empty()
                        && resp.get_relay_server().trim().is_empty()
                    {
                        let other = resp.get_other_failure();
                        let reason = if other.is_empty() {
                            format!("punch hole refused: {:?}", resp.get_failure())
                        } else {
                            other.to_string()
                        };
                        return Err(io::Error::new(
                            punch_hole_refusal_kind(
                                resp.get_failure(),
                                other,
                                punch_hole_response_has_unknown_failure(&resp),
                            ),
                            format!("{} ({})", reason, req_debug),
                        ));
                    }
                    let relay_server = resp.get_relay_server().to_string();
                    // OSS hbbs may ignore force_relay and answer a direct peer
                    // address in socket_addr without a relay_server. That is a
                    // valid punch response, not an error: the caller connects the
                    // returned address directly (official client behavior).
                    let peer_candidates = decode_peer_candidates(
                        resp.get_socket_addr(),
                        resp.get_socket_addr_v6(),
                        if resp.get_is_udp() {
                            PeerCandidateTransport::Udp
                        } else {
                            PeerCandidateTransport::Tcp
                        },
                    )?;
                    return Ok(PunchHoleInfo {
                        relay_server,
                        signed_pk: resp.get_pk().to_vec(),
                        peer_candidates,
                        relay_uuid: None,
                        peer_nat_type: resp.get_nat_type(),
                        is_local: resp.get_is_local(),
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
                    // Official clients never promote RelayResponse.socket_addr
                    // to a TCP direct candidate.  It is relay coordination
                    // metadata; only socket_addr_v6 participates in the
                    // separate UDP/KCP race (which remains product-gated here).
                    let peer_candidates = decode_peer_candidates(
                        &[],
                        resp.get_socket_addr_v6(),
                        PeerCandidateTransport::Udp,
                    )?;
                    return Ok(PunchHoleInfo {
                        relay_server,
                        signed_pk: resp.get_pk().to_vec(),
                        peer_candidates,
                        relay_uuid: Some(relay_uuid),
                        peer_nat_type: NatType::UNKNOWN_NAT,
                        is_local: false,
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

    pub fn test_nat(&mut self, serial: i32) -> io::Result<i32> {
        let deadline = self.current_read_deadline()?;
        self.test_nat_until(serial, deadline)
    }

    fn test_nat_until(&mut self, serial: i32, deadline: Instant) -> io::Result<i32> {
        self.ensure_connected()?;
        self.set_io_timeout(remaining_timeout(deadline, "NAT test request")?)?;
        let mut request = TestNatRequest::new();
        request.set_serial(serial);
        let mut message = RendezvousMessage::new();
        message.union = Some(RendezvousMessage_oneof_union::test_nat_request(request));
        self.send_message(&message)?;
        remaining_timeout(deadline, "NAT test response")?;

        let response = self.read_next_non_keyexchange_until(deadline)?;
        match response.union {
            Some(RendezvousMessage_oneof_union::test_nat_response(response))
                if response.get_port() > 0 && response.get_port() <= u16::MAX as i32 =>
            {
                Ok(response.get_port())
            }
            Some(RendezvousMessage_oneof_union::test_nat_response(_)) => Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "NAT test response returned an invalid mapped port",
            )),
            other => Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("expected TestNatResponse, got: {:?}", other),
            )),
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

    pub fn request_relay_uuid(
        &mut self,
        id: &str,
        relay_server: &str,
        secure: bool,
        token: &str,
    ) -> io::Result<String> {
        self.request_relay_uuid_with_timeout(
            id,
            relay_server,
            secure,
            token,
            Duration::from_secs(10),
        )
    }

    pub fn request_relay_uuid_with_timeout(
        &mut self,
        id: &str,
        relay_server: &str,
        secure: bool,
        token: &str,
        timeout: Duration,
    ) -> io::Result<String> {
        self.ensure_connected()?;
        self.ensure_not_cancelled("relay request")?;
        let deadline = Instant::now() + timeout;

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
        self.set_io_timeout(remaining_timeout(deadline, "relay request")?)?;
        self.send_message(&msg)?;

        let response = self.read_next_non_keyexchange_until(deadline)?;
        self.ensure_not_cancelled("relay response")?;
        match response.union {
            Some(RendezvousMessage_oneof_union::relay_response(resp)) => {
                if !resp.get_refuse_reason().is_empty() {
                    return Err(io::Error::new(
                        io::ErrorKind::ConnectionRefused,
                        "relay refused by rendezvous server",
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
        self.create_relay_with_timeout(
            id,
            uuid,
            relay_server,
            relay_fallback_port,
            server_key,
            conn_type,
            Duration::from_secs(10),
        )
    }

    pub fn create_relay_with_timeout(
        &self,
        id: &str,
        uuid: &str,
        relay_server: &str,
        relay_fallback_port: u16,
        server_key: &str,
        conn_type: ConnType,
        timeout: Duration,
    ) -> io::Result<TcpStream> {
        self.ensure_not_cancelled("relay connect")?;
        let deadline = Instant::now() + timeout;
        let mut stream = match self.connect_epoch {
            Some(epoch) => net::connect_tcp_endpoint_cancellable(
                relay_server,
                relay_fallback_port,
                "relay",
                timeout,
                epoch,
            )?,
            None => net::connect_tcp_endpoint(relay_server, relay_fallback_port, "relay", timeout)?,
        };
        stream.set_read_timeout(Some(Duration::from_secs(30)))?;
        stream.set_write_timeout(Some(
            remaining_timeout(deadline, "relay request write")?.min(Duration::from_secs(10)),
        ))?;

        // hbbr uses the same exact shared `-k` comparison as hbbs.
        let msg = request_relay_message(id, uuid, server_key, conn_type);
        let payload = msg
            .write_to_bytes()
            .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
        self.ensure_not_cancelled("relay request write")?;
        wire::write_frame(&mut stream, &payload)?;
        Ok(stream)
    }

    pub fn punch_hole(&mut self, _peer_id: &str) -> io::Result<()> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "PunchHole requires UDP; use request_relay instead",
        ))
    }

    pub fn connect_to_peer_candidates(
        &self,
        candidates: &[PeerCandidate],
        local_address: Option<SocketAddr>,
        timeout: Duration,
    ) -> io::Result<TcpStream> {
        let mut addresses = Vec::new();
        for candidate in candidates {
            if candidate.transport == PeerCandidateTransport::Tcp
                && !addresses.contains(&candidate.address)
            {
                addresses.push(candidate.address);
            }
        }
        if addresses.is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "rendezvous response has no supported TCP peer candidate",
            ));
        }
        let stream = match (self.connect_epoch, local_address) {
            (Some(epoch), Some(local_address)) => {
                net::connect_tcp_socket_addresses_bound_cancellable(
                    &addresses,
                    local_address,
                    "peer candidate",
                    timeout,
                    epoch,
                )?
            }
            (Some(epoch), None) => net::connect_tcp_socket_addresses_cancellable(
                &addresses,
                "peer candidate",
                timeout,
                epoch,
            )?,
            (None, _) => net::connect_tcp_socket_addresses(&addresses, "peer candidate", timeout)?,
        };
        stream.set_read_timeout(Some(Duration::from_secs(30)))?;
        stream.set_write_timeout(Some(Duration::from_secs(10)))?;
        Ok(stream)
    }

    pub fn local_address(&self) -> io::Result<SocketAddr> {
        self.stream
            .as_ref()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotConnected, "TCP not connected"))?
            .local_addr()
    }

    pub fn peer_address(&self) -> io::Result<SocketAddr> {
        self.stream
            .as_ref()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotConnected, "TCP not connected"))?
            .peer_addr()
    }

    fn set_io_timeout(&self, timeout: Duration) -> io::Result<()> {
        let stream = self
            .stream
            .as_ref()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotConnected, "TCP not connected"))?;
        stream.set_read_timeout(Some(timeout))?;
        stream.set_write_timeout(Some(timeout))?;
        Ok(())
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
        let deadline = self.current_read_deadline()?;
        self.read_raw_frame_until(deadline)
    }

    fn current_read_deadline(&self) -> io::Result<Instant> {
        let timeout = self
            .stream
            .as_ref()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotConnected, "TCP not connected"))?
            .read_timeout()?
            .unwrap_or(Duration::from_secs(30));
        Ok(Instant::now() + timeout)
    }

    fn read_raw_frame_until(&mut self, deadline: Instant) -> io::Result<Vec<u8>> {
        let connect_epoch = self.connect_epoch;
        let stream = self
            .stream
            .as_mut()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotConnected, "TCP not connected"))?;
        wire::read_frame_cancellable(stream, deadline, || {
            connect_epoch.is_some_and(crate::connect_cancelled)
        })
    }

    fn write_raw_message(&mut self, msg: &RendezvousMessage) -> io::Result<()> {
        self.ensure_not_cancelled("rendezvous write")?;
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
        self.ensure_not_cancelled("rendezvous request")?;
        let payload = msg
            .write_to_bytes()
            .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
        self.write_payload(&payload)
    }

    fn read_message(&mut self) -> io::Result<RendezvousMessage> {
        let deadline = self.current_read_deadline()?;
        self.read_message_until(deadline)
    }

    fn read_message_until(&mut self, deadline: Instant) -> io::Result<RendezvousMessage> {
        if let Some(msg) = self.pending.take() {
            return Ok(msg);
        }

        let payload = self.read_payload_until(deadline)?;
        protobuf::parse_from_bytes(&payload)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
    }

    fn read_next_non_keyexchange(&mut self) -> io::Result<RendezvousMessage> {
        let deadline = self.current_read_deadline()?;
        self.read_next_non_keyexchange_until(deadline)
    }

    fn read_next_non_keyexchange_until(
        &mut self,
        deadline: Instant,
    ) -> io::Result<RendezvousMessage> {
        for _ in 0..2 {
            let msg = self.read_message_until(deadline)?;
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
        let deadline = self.current_read_deadline()?;
        self.read_payload_until(deadline)
    }

    fn read_payload_until(&mut self, deadline: Instant) -> io::Result<Vec<u8>> {
        let payload = self.read_raw_frame_until(deadline)?;
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
        self.ensure_not_cancelled("rendezvous write")?;
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

    fn ensure_not_cancelled(&self, stage: &str) -> io::Result<()> {
        if self.connect_epoch.is_some_and(crate::connect_cancelled) {
            return Err(io::Error::new(
                io::ErrorKind::Interrupted,
                format!("{} cancelled", stage),
            ));
        }
        Ok(())
    }
}

fn remaining_timeout(deadline: Instant, stage: &str) -> io::Result<Duration> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        Err(io::Error::new(
            io::ErrorKind::TimedOut,
            format!("{} exceeded the shared connection deadline", stage),
        ))
    } else {
        Ok(remaining)
    }
}

fn ensure_connect_epoch_active(cancel_epoch: Option<u64>, stage: &str) -> io::Result<()> {
    if cancel_epoch.is_some_and(crate::connect_cancelled) {
        return Err(io::Error::new(
            io::ErrorKind::Interrupted,
            format!("{} cancelled", stage),
        ));
    }
    Ok(())
}

fn exchange_udp_nat_mapping(
    socket: &UdpSocket,
    server_address: SocketAddr,
    serial: i32,
    timeout: Duration,
    cancel_epoch: Option<u64>,
) -> io::Result<u16> {
    const MAX_PACKETS: usize = 8;
    const MAX_DATAGRAM_SIZE: usize = 1500;
    let deadline = Instant::now() + timeout;
    let mut request = TestNatRequest::new();
    request.set_serial(serial);
    let mut message = RendezvousMessage::new();
    message.union = Some(RendezvousMessage_oneof_union::test_nat_request(request));
    let payload = message
        .write_to_bytes()
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    if socket.peer_addr()? != server_address {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "UDP NAT socket is not connected to the configured rendezvous endpoint",
        ));
    }

    let mut sent = 0usize;
    for _ in 0..2 {
        ensure_connect_epoch_active(cancel_epoch, "UDP NAT mapping registration")?;
        socket.send(&payload)?;
        sent += 1;
    }

    let mut interval = Duration::from_millis(20);
    let mut receive_buffer = [0u8; MAX_DATAGRAM_SIZE];
    loop {
        ensure_connect_epoch_active(cancel_epoch, "UDP NAT mapping registration")?;
        let remaining = remaining_timeout(deadline, "UDP NAT mapping registration")?;
        socket.set_read_timeout(Some(remaining.min(interval)))?;
        match socket.recv(&mut receive_buffer) {
            Ok(length) => {
                let response = RendezvousMessage::parse_from_bytes(&receive_buffer[..length])
                    .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
                if let Some(RendezvousMessage_oneof_union::test_nat_response(response)) =
                    response.union
                {
                    if (1..=u16::MAX as i32).contains(&response.get_port()) {
                        return Ok(response.get_port() as u16);
                    }
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "UDP NAT test returned an invalid mapped port",
                    ));
                }
            }
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) => {}
            Err(error) => return Err(error),
        }
        if sent < MAX_PACKETS {
            ensure_connect_epoch_active(cancel_epoch, "UDP NAT mapping registration")?;
            socket.send(&payload)?;
            sent += 1;
        }
        interval = (interval + interval / 2).min(Duration::from_millis(200));
    }
}

fn decode_peer_candidates(
    socket_addr: &[u8],
    socket_addr_v6: &[u8],
    socket_addr_transport: PeerCandidateTransport,
) -> io::Result<Vec<PeerCandidate>> {
    let mut candidates = Vec::with_capacity(2);
    if !socket_addr_v6.is_empty() {
        let address = decode_socket_addr(socket_addr_v6)?;
        if !address.is_ipv6() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "socket_addr_v6 did not contain an IPv6 address",
            ));
        }
        validate_peer_candidate(address)?;
        candidates.push(PeerCandidate {
            address,
            source: PeerCandidateSource::SocketAddrV6,
            // Upstream binds socket_addr_v6 to its IPv6 UDP/KCP candidate.
            transport: PeerCandidateTransport::Udp,
        });
    }
    if !socket_addr.is_empty() {
        let address = decode_socket_addr(socket_addr)?;
        validate_peer_candidate(address)?;
        let candidate = PeerCandidate {
            address,
            source: PeerCandidateSource::SocketAddr,
            transport: socket_addr_transport,
        };
        if !candidates.iter().any(|existing| existing == &candidate) {
            candidates.push(candidate);
        }
    }
    Ok(candidates)
}

fn validate_peer_candidate(address: SocketAddr) -> io::Result<()> {
    if address.port() == 0 || address.ip().is_unspecified() || address.ip().is_multicast() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "rendezvous response contains an unusable peer address",
        ));
    }
    if let IpAddr::V6(address) = address.ip() {
        if address.to_ipv4_mapped().is_some() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "rendezvous IPv6 candidate must not contain an IPv4-mapped address",
            ));
        }
        if address.is_unicast_link_local() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "rendezvous IPv6 candidate is link-local without a scope",
            ));
        }
    }
    Ok(())
}

pub fn encode_socket_addr_v6(address: SocketAddr) -> io::Result<Vec<u8>> {
    let SocketAddr::V6(address) = address else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "socket_addr_v6 requires an IPv6 address",
        ));
    };
    if address.ip().to_ipv4_mapped().is_some() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "socket_addr_v6 must not encode an IPv4-mapped address",
        ));
    }
    validate_peer_candidate(SocketAddr::V6(address))?;
    if address.scope_id() != 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "socket_addr_v6 cannot encode an interface scope",
        ));
    }
    if address.ip().is_loopback() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "socket_addr_v6 cannot advertise a loopback address",
        ));
    }
    let mut encoded = Vec::with_capacity(18);
    encoded.extend_from_slice(&address.ip().octets());
    encoded.extend_from_slice(&address.port().to_le_bytes());
    Ok(encoded)
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
    use super::super::rendezvous_proto::{
        PunchHole, RegisterPeerResponse, RelayResponse, TestNatResponse,
    };
    use super::*;
    use std::io::ErrorKind;
    use std::net::TcpListener;
    use std::thread;

    #[test]
    fn punch_hole_refusal_preserves_offline_and_license_semantics() {
        assert_eq!(
            punch_hole_refusal_kind(PunchHoleResponse_Failure::ID_NOT_EXIST, "", false),
            ErrorKind::NotFound
        );
        assert_eq!(
            punch_hole_refusal_kind(PunchHoleResponse_Failure::OFFLINE, "", false),
            ErrorKind::NotFound
        );
        assert_eq!(
            punch_hole_refusal_kind(PunchHoleResponse_Failure::LICENSE_MISMATCH, "", false),
            ErrorKind::PermissionDenied
        );
        assert_eq!(
            punch_hole_refusal_kind(PunchHoleResponse_Failure::LICENSE_OVERUSE, "", false),
            ErrorKind::PermissionDenied
        );
        assert_eq!(
            punch_hole_refusal_kind(
                PunchHoleResponse_Failure::ID_NOT_EXIST,
                "token rejected by policy",
                false,
            ),
            ErrorKind::Other,
            "unstructured server text must never become authoritative offline evidence"
        );
        assert_eq!(
            punch_hole_refusal_kind(PunchHoleResponse_Failure::ID_NOT_EXIST, "", true),
            ErrorKind::Other,
            "a future enum value must not inherit proto3's ID_NOT_EXIST default"
        );
    }

    fn encode_test_ipv4(addr: SocketAddrV4) -> Vec<u8> {
        // AddrMangle with a deterministic zero time component. Production
        // decoding accepts the full 16-byte little-endian representation.
        let ip = u32::from_le_bytes(addr.ip().octets()) as u128;
        ((ip << 49) | addr.port() as u128).to_le_bytes().to_vec()
    }

    fn test_nat_response_message(port: u16) -> Vec<u8> {
        let mut response = TestNatResponse::new();
        response.set_port(port as i32);
        let mut message = RendezvousMessage::new();
        message.union = Some(RendezvousMessage_oneof_union::test_nat_response(response));
        message.write_to_bytes().expect("serialize NAT response")
    }

    #[test]
    fn arbitrary_shared_access_key_is_preserved_in_punch_and_relay_messages() {
        let key = " =tenant-key:42/abc=\n";
        let token = "pro-session-token";
        let punch = punch_hole_request_message(
            "peer-123",
            key,
            token,
            &RendezvousRouteOptions::force_relay(),
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
            &RendezvousRouteOptions::force_relay(),
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
    fn automatic_route_serializes_measured_nat_and_ipv6_udp_candidate() {
        let ipv6 = SocketAddr::new("2001:db8::5".parse().unwrap(), 41234);
        let encoded_ipv6 = encode_socket_addr_v6(ipv6).expect("encode IPv6 candidate");
        assert_eq!(
            encoded_ipv6,
            vec![
                0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x05, 0x12, 0xa1,
            ],
            "official AddrMangle IPv6 layout is 16 network-order octets plus LE u16 port"
        );
        let punch = punch_hole_request_message(
            "peer-123",
            "key",
            "token",
            &RendezvousRouteOptions::automatic(NatType::ASYMMETRIC, 41234, encoded_ipv6.clone()),
            ConnType::DEFAULT_CONN,
        );
        match punch.union {
            Some(RendezvousMessage_oneof_union::punch_hole_request(request)) => {
                assert_eq!(request.get_nat_type(), NatType::ASYMMETRIC);
                assert_eq!(request.get_udp_port(), 41234);
                assert_eq!(request.get_socket_addr_v6(), encoded_ipv6.as_slice());
                assert!(!request.get_force_relay());
            }
            other => panic!("expected PunchHoleRequest, got: {:?}", other),
        }
        assert_eq!(
            encode_socket_addr_v6("[::1]:41234".parse().unwrap())
                .expect_err("loopback must never be advertised")
                .kind(),
            io::ErrorKind::InvalidInput
        );
        assert_eq!(
            encode_socket_addr_v6("[::ffff:192.0.2.1]:41234".parse().unwrap())
                .expect_err("IPv4-mapped IPv6 must use the IPv4 codec")
                .kind(),
            io::ErrorKind::InvalidInput
        );
    }

    #[test]
    fn dual_stack_peer_candidates_preserve_source_and_transport() {
        let ipv4 = SocketAddrV4::new(Ipv4Addr::new(10, 0, 0, 5), 21118);
        let ipv6 = SocketAddr::new("2001:db8::5".parse().unwrap(), 21118);
        let candidates = decode_peer_candidates(
            &encode_test_ipv4(ipv4),
            &encode_socket_addr_v6(ipv6).unwrap(),
            PeerCandidateTransport::Tcp,
        )
        .expect("decode dual-stack candidates");
        assert_eq!(
            candidates,
            vec![
                PeerCandidate {
                    address: ipv6,
                    source: PeerCandidateSource::SocketAddrV6,
                    transport: PeerCandidateTransport::Udp,
                },
                PeerCandidate {
                    address: SocketAddr::V4(ipv4),
                    source: PeerCandidateSource::SocketAddr,
                    transport: PeerCandidateTransport::Tcp,
                },
            ]
        );
    }

    #[test]
    fn inbound_socket_addr_v6_rejects_ipv4_mapped_fixture() {
        let mapped_fixture = [
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xc0, 0x00,
            0x02, 0x01, 0x7e, 0x52,
        ];
        let error = decode_peer_candidates(&[], &mapped_fixture, PeerCandidateTransport::Tcp)
            .expect_err("socket_addr_v6 must not smuggle an IPv4-mapped address");
        assert_eq!(error.kind(), ErrorKind::InvalidData);
    }

    #[test]
    fn ipv4_control_address_does_not_block_ipv6_peer_candidate() {
        let listener = match TcpListener::bind("[::1]:0") {
            Ok(value) => value,
            Err(error)
                if matches!(
                    error.kind(),
                    ErrorKind::AddrNotAvailable | ErrorKind::PermissionDenied
                ) =>
            {
                return;
            }
            Err(error) => panic!("IPv6 fixture bind failed: {error}"),
        };
        let peer = listener.local_addr().expect("IPv6 fixture address");
        let accept = thread::spawn(move || listener.accept().expect("accept IPv6 peer"));
        let session_id = 90_031;
        let epoch = crate::begin_connect_epoch(session_id);
        let client = RendezvousClient::new_with_connect_epoch(epoch);
        let stream = client
            .connect_to_peer_candidates(
                &[PeerCandidate {
                    address: peer,
                    source: PeerCandidateSource::SocketAddrV6,
                    transport: PeerCandidateTransport::Tcp,
                }],
                Some("127.0.0.1:41003".parse().unwrap()),
                Duration::from_secs(2),
            )
            .expect("IPv4 hbbs address must not bind an IPv6 peer socket");
        assert!(stream.peer_addr().unwrap().is_ipv6());
        drop(stream);
        accept.join().expect("IPv6 accept thread");
        crate::finish_connect_epoch(epoch, session_id);
    }

    #[test]
    fn ipv6_control_address_does_not_block_ipv4_peer_candidate() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind IPv4 peer fixture");
        let peer = listener.local_addr().expect("IPv4 fixture address");
        let accept = thread::spawn(move || listener.accept().expect("accept IPv4 peer"));
        let session_id = 90_032;
        let epoch = crate::begin_connect_epoch(session_id);
        let client = RendezvousClient::new_with_connect_epoch(epoch);
        let stream = client
            .connect_to_peer_candidates(
                &[PeerCandidate {
                    address: peer,
                    source: PeerCandidateSource::SocketAddr,
                    transport: PeerCandidateTransport::Tcp,
                }],
                Some("[::1]:41004".parse().unwrap()),
                Duration::from_secs(2),
            )
            .expect("IPv6 hbbs address must not bind an IPv4 peer socket");
        assert!(stream.peer_addr().unwrap().is_ipv4());
        drop(stream);
        accept.join().expect("IPv4 accept thread");
        crate::finish_connect_epoch(epoch, session_id);
    }

    #[test]
    fn udp_nat_mapping_registration_is_bounded_and_refreshable() {
        let server = UdpSocket::bind("127.0.0.1:0").expect("bind UDP fixture");
        let address = server.local_addr().expect("UDP fixture address");
        let server_thread = thread::spawn(move || {
            let response = test_nat_response_message(40123);
            let mut buffer = [0u8; 1500];
            for _ in 0..2 {
                let (length, source) = server.recv_from(&mut buffer).expect("receive NAT request");
                let request = RendezvousMessage::parse_from_bytes(&buffer[..length])
                    .expect("parse NAT request");
                assert!(matches!(
                    request.union,
                    Some(RendezvousMessage_oneof_union::test_nat_request(_))
                ));
                server
                    .send_to(&response, source)
                    .expect("send NAT response");
            }
        });

        let mut lease =
            RendezvousClient::register_udp_mapping(address, 7, Duration::from_secs(1), None)
                .expect("register UDP mapping");
        assert_eq!(lease.mapped_port(), 40123);
        assert_eq!(
            lease
                .heartbeat(8, Duration::from_secs(1), None)
                .expect("refresh UDP mapping"),
            40123
        );
        server_thread.join().expect("UDP fixture thread");
    }

    #[test]
    fn cancelled_udp_nat_mapping_sends_no_datagram() {
        let server = UdpSocket::bind("127.0.0.1:0").expect("bind UDP fixture");
        server
            .set_read_timeout(Some(Duration::from_millis(100)))
            .expect("set UDP fixture timeout");
        let address = server.local_addr().expect("UDP fixture address");
        let session_id = 90_033;
        let epoch = crate::begin_connect_epoch(session_id);
        crate::cancel_connect_epoch(epoch);

        let error = match RendezvousClient::register_udp_mapping(
            address,
            7,
            Duration::from_secs(1),
            Some(epoch),
        ) {
            Err(error) => error,
            Ok(_) => panic!("cancelled mapping must fail before send"),
        };
        assert_eq!(error.kind(), io::ErrorKind::Interrupted);
        let mut byte = [0u8; 1];
        let receive_error = server
            .recv_from(&mut byte)
            .expect_err("cancelled mapping must not emit a datagram");
        assert!(matches!(
            receive_error.kind(),
            io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
        ));
        crate::finish_connect_epoch(epoch, session_id);
    }

    #[test]
    fn tcp_nat_probe_reuses_local_address_and_classifies_stable_mapping() {
        let (second_server, first_server) = (0..128)
            .find_map(|_| {
                let second = TcpListener::bind("127.0.0.1:0").ok()?;
                let second_port = second.local_addr().ok()?.port();
                if second_port == u16::MAX {
                    return None;
                }
                TcpListener::bind((Ipv4Addr::LOCALHOST, second_port + 1))
                    .ok()
                    .map(|first| (second, first))
            })
            .expect("allocate adjacent NAT fixture ports");
        let first_port = first_server.local_addr().unwrap().port();
        let serve = |listener: TcpListener, mapped_port: u16| {
            thread::spawn(move || {
                let (mut stream, _) = listener.accept().expect("accept NAT probe");
                let payload = wire::read_frame(&mut stream).expect("read NAT request");
                let request =
                    RendezvousMessage::parse_from_bytes(&payload).expect("parse NAT request");
                assert!(matches!(
                    request.union,
                    Some(RendezvousMessage_oneof_union::test_nat_request(_))
                ));
                wire::write_frame(&mut stream, &test_nat_response_message(mapped_port))
                    .expect("write NAT response");
            })
        };
        let first_thread = serve(first_server, 45678);
        let second_thread = serve(second_server, 45678);

        let epoch = crate::begin_connect_epoch(0);
        let result = RendezvousClient::probe_tcp_nat(
            "127.0.0.1",
            first_port,
            9,
            epoch,
            Duration::from_secs(3),
        )
        .expect("probe TCP NAT");
        crate::finish_connect_epoch(epoch, 0);
        assert_eq!(result.nat_type, NatType::ASYMMETRIC);
        assert_eq!(result.first_mapped_port, 45678);
        assert_eq!(result.second_mapped_port, 45678);
        first_thread.join().expect("first NAT fixture");
        second_thread.join().expect("second NAT fixture");
    }

    #[test]
    fn nat_request_and_response_share_one_absolute_deadline() {
        let mut key_exchange = KeyExchange::new();
        key_exchange.keys.push(vec![0u8; 32]);
        let mut intermediate = RendezvousMessage::new();
        intermediate.union = Some(RendezvousMessage_oneof_union::key_exchange(key_exchange));
        let intermediate_payload = intermediate
            .write_to_bytes()
            .expect("serialize NAT intermediate key exchange");
        let response_payload = test_nat_response_message(45678);

        let server = TcpListener::bind("127.0.0.1:0").expect("bind NAT deadline fixture");
        let port = server.local_addr().expect("NAT deadline address").port();
        let server_thread = thread::spawn(move || {
            let (mut stream, _) = server.accept().expect("accept NAT deadline probe");
            let _request = wire::read_frame(&mut stream).expect("read NAT request");
            thread::sleep(Duration::from_millis(180));
            wire::write_frame(&mut stream, &intermediate_payload)
                .expect("write NAT intermediate key exchange");
            thread::sleep(Duration::from_millis(180));
            let _ = wire::write_frame(&mut stream, &response_payload);
        });

        let mut rd = RendezvousClient::new();
        rd.connect("127.0.0.1", port, "", false)
            .expect("connect NAT deadline fixture");
        let started = Instant::now();
        let error = rd
            .test_nat_until(7, started + Duration::from_millis(250))
            .expect_err("late NAT response must not extend the request deadline");
        let elapsed = started.elapsed();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(
            elapsed < Duration::from_millis(400),
            "NAT request deadline restarted before response: {elapsed:?}"
        );
        server_thread.join().expect("NAT deadline fixture thread");
    }

    #[test]
    fn future_punch_failure_enum_is_not_reported_as_offline() {
        // RendezvousMessage.punch_hole_response (field 11) containing a
        // PunchHoleResponse.failure (field 3) value unknown to this client.
        // rust-protobuf keeps 99 in unknown_fields and leaves the typed enum
        // at proto3's zero default (ID_NOT_EXIST), so the production branch
        // must inspect the unknown field before classifying the refusal.
        let payload = vec![0x5a, 0x02, 0x18, 0x63];

        let server = TcpListener::bind("127.0.0.1:0").expect("bind future failure fixture");
        let port = server.local_addr().expect("future failure address").port();
        let server_thread = thread::spawn(move || {
            let (mut stream, _) = server.accept().expect("accept future failure probe");
            let _request = wire::read_frame(&mut stream).expect("read punch request");
            wire::write_frame(&mut stream, &payload).expect("write future failure response");
        });

        let mut rd = RendezvousClient::new();
        rd.connect("127.0.0.1", port, "", false)
            .expect("connect future failure fixture");
        let error = rd
            .request_force_relay("peer-123", "key", "", ConnType::DEFAULT_CONN)
            .expect_err("future failure enum must remain a non-authoritative refusal");
        assert_eq!(error.kind(), ErrorKind::Other);
        server_thread.join().expect("future failure fixture thread");
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
        assert_eq!(
            info.peer_candidates,
            vec![PeerCandidate {
                address: addr,
                source: PeerCandidateSource::SocketAddr,
                transport: PeerCandidateTransport::Tcp,
            }],
            "direct peer address expected"
        );
        server_thread.join().expect("server thread");
    }

    #[test]
    fn relay_response_never_promotes_legacy_socket_addr_to_tcp() {
        let legacy = SocketAddrV4::new(Ipv4Addr::new(10, 0, 0, 6), 21118);
        let ipv6 = SocketAddr::new("2001:db8::6".parse().unwrap(), 21118);
        let mut relay = RelayResponse::new();
        relay.set_relay_server("relay.example:21117".to_string());
        relay.set_uuid("relay-route".to_string());
        relay.set_socket_addr(encode_test_ipv4(legacy));
        relay.set_socket_addr_v6(encode_socket_addr_v6(ipv6).unwrap());
        let mut response = RendezvousMessage::new();
        response.union = Some(RendezvousMessage_oneof_union::relay_response(relay));
        let payload = response.write_to_bytes().expect("serialize relay response");

        let server = TcpListener::bind("127.0.0.1:0").expect("bind test server");
        let port = server.local_addr().expect("server addr").port();
        let server_thread = thread::spawn(move || {
            let (mut stream, _) = server.accept().expect("accept");
            let _request = wire::read_frame(&mut stream).expect("read route request");
            wire::write_frame(&mut stream, &payload).expect("write relay response");
        });

        let mut rd = RendezvousClient::new();
        rd.connect("127.0.0.1", port, "", false)
            .expect("connect rendezvous");
        let info = rd
            .request_force_relay("peer-123", "key", "", ConnType::DEFAULT_CONN)
            .expect("parse relay route");
        assert_eq!(
            info.peer_candidates,
            vec![PeerCandidate {
                address: ipv6,
                source: PeerCandidateSource::SocketAddrV6,
                transport: PeerCandidateTransport::Udp,
            }]
        );
        assert!(info
            .peer_candidates
            .iter()
            .all(|candidate| candidate.address != SocketAddr::V4(legacy)));
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
    fn skipped_key_exchange_cannot_restart_route_deadline() {
        let mut key_exchange = KeyExchange::new();
        key_exchange.keys.push(vec![0u8; 32]);
        let mut message = RendezvousMessage::new();
        message.union = Some(RendezvousMessage_oneof_union::key_exchange(key_exchange));
        let payload = message.write_to_bytes().expect("serialize key exchange");

        let server = TcpListener::bind("127.0.0.1:0").expect("bind test server");
        let port = server.local_addr().expect("server addr").port();
        let server_thread = thread::spawn(move || {
            let (mut stream, _) = server.accept().expect("accept");
            let _request = wire::read_frame(&mut stream).expect("read route request");
            thread::sleep(Duration::from_millis(300));
            wire::write_frame(&mut stream, &payload).expect("write late key exchange");
            thread::sleep(Duration::from_millis(500));
        });

        let mut rd = RendezvousClient::new();
        rd.connect("127.0.0.1", port, "", false)
            .expect("connect rendezvous");
        let started = Instant::now();
        let error = rd
            .request_route_with_timeout(
                "peer-123",
                "key",
                "",
                ConnType::DEFAULT_CONN,
                RendezvousRouteOptions::force_relay(),
                Duration::from_millis(400),
            )
            .expect_err("silence after KeyExchange must hit the original deadline");
        let elapsed = started.elapsed();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(
            elapsed < Duration::from_millis(550),
            "route deadline restarted after KeyExchange: {elapsed:?}"
        );
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
