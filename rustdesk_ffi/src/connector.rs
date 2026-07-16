// connector.rs — RustDesk 完整连接管线
//
// 端到端连接状态机:
//   Disconnected
//     → TCP to Rendezvous (port 21116)
//     → RegisterPeer → RegisterPeerResponse
//     → [RegisterPk] (if server requests public key)
//     → RequestRelay → RelayResponse (returns peer address)
//     → TCP to Peer
//     → KeyExchange (NaCl crypto_box key exchange)
//     → Encrypted channel established
//     → LoginRequest → LoginResponse
//     → Streaming (video/audio/input over encrypted channel)
//
// 所有通信在 rendezvous 阶段是明文，peer 阶段是加密的。

use crate::crypto::{self, KeyPair};
use crate::crypto_channel::CryptoChannel;
use crate::control_inbox::{CONTROL_BATCH_LIMIT, ControlInbox};
use crate::net;
use crate::protocol::message_proto::{
    AudioFormat, AudioFrame, Clipboard, ClipboardFormat, ControlKey, EncodedVideoFrames,
    FileAction, FileAction_oneof_union, FileEntry, FileResponse, FileResponse_oneof_union,
    FileTransferBlock, FileTransferDone, FileTransferReceiveRequest,
    FileTransferSendConfirmRequest, FileType, IdPk, KeyEvent, KeyEvent_oneof_union, KeyboardMode,
    Message, Message_oneof_union, Misc, Misc_oneof_union, MouseEvent, PublicKey, VideoFrame,
    VideoFrame_oneof_union,
};
use crate::protocol::rendezvous::RendezvousClient;
use crate::protocol::session::Session;
use crate::protocol::wire;
use protobuf::{Message as ProtoMessage, ProtobufEnum};

use std::io;
use std::io::ErrorKind;
use std::net::{SocketAddr, TcpStream};
use std::sync::Arc;
use std::time::{Duration, Instant};

const VIDEO_STARVATION_REFRESH_AFTER_MS: u128 = 2500;
const VIDEO_STARVATION_REFRESH_INTERVAL_MS: u128 = 2500;
const CONTROL_DIAGNOSTIC_INTERVAL: Duration = Duration::from_secs(5);
const SLOW_VIDEO_CALLBACK_WARN: Duration = Duration::from_millis(50);
const SLOW_VIDEO_ACK_WARN: Duration = Duration::from_millis(50);

fn should_emit_control_diagnostics(last_report: Instant, now: Instant) -> bool {
    now.duration_since(last_report) >= CONTROL_DIAGNOSTIC_INTERVAL
}

fn should_refresh_for_video_starvation(
    total_video: u64,
    window_video: u64,
    window_audio: u64,
    last_video_age_ms: Option<u128>,
    last_refresh_age_ms: Option<u128>,
) -> bool {
    if total_video <= 20 || window_video > 0 || window_audio == 0 {
        return false;
    }
    let Some(video_age_ms) = last_video_age_ms else {
        return false;
    };
    if video_age_ms < VIDEO_STARVATION_REFRESH_AFTER_MS {
        return false;
    }
    match last_refresh_age_ms {
        Some(refresh_age_ms) => refresh_age_ms >= VIDEO_STARVATION_REFRESH_INTERVAL_MS,
        None => true,
    }
}

/// 连接状态
#[derive(Debug, Clone, PartialEq)]
pub enum ConnState {
    Disconnected,
    RendezvousConnecting,
    RegisteringPeer,
    RegisteringPk,
    RequestingRelay,
    ConnectingToPeer,
    KeyExchanging,
    LoggingIn,
    Connected,
    Error(String),
}

/// 完整连接上下文
pub struct RustDeskConnector {
    state: ConnState,
    keypair: KeyPair,
    peer_pk: Option<[u8; 32]>,
    crypto_channel: Option<CryptoChannel>,
    session: Session,
    peer_addr: Option<SocketAddr>,
    /// streaming 消息统计 — 诊断对端停止发送前的行为
    pub stream_stats: String,
}

struct PendingFileUpload {
    id: i32,
    remote_dir: String,
    file_name: String,
    data: Vec<u8>,
    requested_at: Instant,
}

struct AwaitingFileDone {
    id: i32,
    file_name: String,
}

impl RustDeskConnector {
    pub fn new() -> Self {
        Self {
            state: ConnState::Disconnected,
            keypair: crypto::generate_keypair(),
            peer_pk: None,
            crypto_channel: None,
            session: Session::new(),
            peer_addr: None,
            stream_stats: String::new(),
        }
    }

    /// 完整连接流程 (阻塞)
    ///
    /// rendezvous_host: Rendezvous 服务器地址
    /// peer_id: 本端 peer ID
    /// password: 远程主机密码
    pub fn connect(
        &mut self,
        rendezvous_host: &str,
        rendezvous_port: u16,
        server_key: &str,
        peer_id: &str,
        password: &str,
        preferred_codec: i32,
        image_quality: i32,
        privacy_mode: bool,
        audio_enabled: bool,
        fps: u32,
        request_approval: bool,
    ) -> io::Result<()> {
        // === Phase 1: Rendezvous 握手 ===
        self.state = ConnState::RendezvousConnecting;
        let mut rd = RendezvousClient::new();
        // 客户端连接远端 ID 时不要 RegisterPeer；RegisterPeer 是被控端注册自己的 ID。
        // 普通密码连接没有 token，按 upstream 行为跳过 ID server secure_tcp，仅跳过服务端
        // 主动发来的 KeyExchange 后读取 PunchHoleResponse。
        rd.connect(rendezvous_host, rendezvous_port, server_key, false)?;

        self.state = ConnState::RequestingRelay;
        let punch = rd.request_punch_hole(peer_id, server_key)?;

        // === Phase 2: Peer TCP + 加密通道 ===
        eprintln!(
            "[RustDesk-FFI] punch response peer_addr={:?} relay_server={} relay_uuid={:?} signed_pk_len={}",
            punch.peer_addr,
            punch.relay_server,
            punch.relay_uuid,
            punch.signed_pk.len()
        );

        let mut peer_stream = if let Some(relay_uuid) = punch.relay_uuid {
            self.state = ConnState::ConnectingToPeer;
            eprintln!(
                "[RustDesk-FFI] using relay uuid from rendezvous uuid={} relay_server={}",
                relay_uuid, punch.relay_server
            );
            rd.create_relay(peer_id, &relay_uuid, &punch.relay_server, server_key)?
        } else if !punch.relay_server.trim().is_empty() {
            self.state = ConnState::RequestingRelay;
            let mut relay_rd = RendezvousClient::new();
            relay_rd.connect(rendezvous_host, rendezvous_port, server_key, false)?;
            let relay_uuid = relay_rd.request_relay_uuid(
                peer_id,
                &punch.relay_server,
                !punch.signed_pk.is_empty(),
            )?;
            self.state = ConnState::ConnectingToPeer;
            eprintln!(
                "[RustDesk-FFI] relay approved uuid={} relay_server={}",
                relay_uuid, punch.relay_server
            );
            relay_rd.create_relay(peer_id, &relay_uuid, &punch.relay_server, server_key)?
        } else if let Some(peer_addr) = punch.peer_addr {
            self.state = ConnState::ConnectingToPeer;
            self.peer_addr = Some(peer_addr);
            eprintln!(
                "[RustDesk-FFI] no relay server, connecting direct peer={}",
                peer_addr
            );
            rd.connect_to_peer(peer_addr)?
        } else {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "rendezvous response did not include peer address or relay uuid",
            ));
        };

        // KeyExchange: 发送自己的公钥，接收对端公钥
        self.state = ConnState::KeyExchanging;
        let channel_key =
            self.secure_peer_connection(&mut peer_stream, peer_id, &punch.signed_pk, server_key)?;

        // 建立加密通道
        let crypto = CryptoChannel::new(peer_stream, &channel_key, &channel_key);
        self.crypto_channel = Some(crypto);

        // === Phase 3: Login ===
        self.state = ConnState::LoggingIn;
        let crypto = self.crypto_channel.as_mut().unwrap();
        self.session.login_encrypted(
            crypto,
            peer_id,
            password,
            preferred_codec,
            image_quality,
            privacy_mode,
            audio_enabled,
            fps,
            request_approval,
        )?;

        self.state = ConnState::Connected;
        Ok(())
    }

    /// 直连模式: TCP 直连 peer (跳过 rendezvous)
    ///
    /// peer_host: 对端 IP 地址
    /// peer_port: 对端端口 (默认 21116)
    /// password: 远程主机密码
    ///
    /// 直连协议 (无 rendezvous 签名):
    ///   TCP → 读对端 PublicKey → 生成 session key → 发我方 PublicKey → CryptoChannel → Login
    pub fn connect_direct(
        &mut self,
        peer_host: &str,
        peer_port: u16,
        password: &str,
        preferred_codec: i32,
        image_quality: i32,
        privacy_mode: bool,
        audio_enabled: bool,
        fps: u32,
    ) -> io::Result<()> {
        // === Phase 1: TCP 直连 peer ===
        self.state = ConnState::ConnectingToPeer;
        eprintln!(
            "[RustDesk-FFI] direct connect to peer {}:{}",
            peer_host, peer_port
        );
        let mut stream = net::connect_tcp_host(
            peer_host,
            peer_port,
            "direct",
            Duration::from_secs(10),
        )?;
        stream.set_read_timeout(Some(Duration::from_secs(30)))?;
        stream.set_write_timeout(Some(Duration::from_secs(10)))?;

        // === Phase 2: 读对端 PublicKey (直连模式下对端发送原始公钥，非 SignedId) ===
        self.state = ConnState::KeyExchanging;
        let payload = wire::read_frame(&mut stream)?;
        let msg: Message = protobuf::parse_from_bytes(&payload)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;

        let their_pk_bytes = match msg.union {
            Some(Message_oneof_union::public_key(ref pk)) => {
                let asym = pk.get_asymmetric_value();
                if asym.len() != 32 {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        format!(
                            "direct peer public key length invalid: {} (expected 32)",
                            asym.len()
                        ),
                    ));
                }
                let mut pk = [0u8; 32];
                pk.copy_from_slice(asym);
                pk
            }
            Some(Message_oneof_union::signed_id(_)) => {
                // 对端发送了 SignedId — 这意味着它在等 rendezvous 流程
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "direct connection received SignedId (peer may not be in direct-accept mode)",
                ));
            }
            other => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("expected PublicKey from direct peer, got: {:?}", other),
                ));
            }
        };

        // === Phase 3: 生成 session key，加密后用我方 PublicKey 回复 ===
        let (our_pk, encrypted_key, session_key) =
            crypto::create_symmetric_key_msg(&their_pk_bytes).ok_or_else(|| {
                io::Error::new(io::ErrorKind::Other, "failed to create direct session key")
            })?;

        let mut pub_key_msg = PublicKey::new();
        pub_key_msg.set_asymmetric_value(our_pk.to_vec());
        pub_key_msg.set_symmetric_value(encrypted_key);
        let mut out = Message::new();
        out.union = Some(Message_oneof_union::public_key(pub_key_msg));
        let bytes = out
            .write_to_bytes()
            .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
        wire::write_frame(&mut stream, &bytes)?;

        self.peer_pk = Some(their_pk_bytes);

        // === Phase 4: CryptoChannel + Login ===
        let crypto = CryptoChannel::new(stream, &session_key, &session_key);
        self.crypto_channel = Some(crypto);

        self.state = ConnState::LoggingIn;
        let crypto = self.crypto_channel.as_mut().unwrap();
        self.session.login_encrypted(
            crypto,
            "", // peer_id: 直连不需要
            password,
            preferred_codec,
            image_quality,
            privacy_mode,
            audio_enabled,
            fps,
            false,
        )?;

        self.state = ConnState::Connected;
        eprintln!("[RustDesk-FFI] direct connection established");
        Ok(())
    }

    pub fn connect_file_transfer(
        &mut self,
        rendezvous_host: &str,
        rendezvous_port: u16,
        server_key: &str,
        peer_id: &str,
        password: &str,
        remote_dir: &str,
        request_approval: bool,
    ) -> io::Result<()> {
        crate::set_last_error(format!(
            "file-transfer connecting rendezvous host={} port={} peer={} dir={}",
            rendezvous_host, rendezvous_port, peer_id, remote_dir
        ));
        self.state = ConnState::RendezvousConnecting;
        let mut rd = RendezvousClient::new();
        rd.connect(rendezvous_host, rendezvous_port, server_key, false)?;

        crate::set_last_error(format!(
            "file-transfer requesting punch peer={} dir={}",
            peer_id, remote_dir
        ));
        self.state = ConnState::RequestingRelay;
        let punch = rd.request_punch_hole(peer_id, server_key)?;
        crate::set_last_error(format!(
            "file-transfer punch peer_addr={:?} relay_server={} relay_uuid={:?} signed_pk_len={}",
            punch.peer_addr,
            punch.relay_server,
            punch.relay_uuid,
            punch.signed_pk.len()
        ));
        eprintln!(
            "[RustDesk-FFI] file-transfer punch response peer_addr={:?} relay_server={} relay_uuid={:?} signed_pk_len={}",
            punch.peer_addr,
            punch.relay_server,
            punch.relay_uuid,
            punch.signed_pk.len()
        );

        let mut peer_stream = if let Some(relay_uuid) = punch.relay_uuid {
            crate::set_last_error(format!(
                "file-transfer connecting relay server={} uuid={}",
                punch.relay_server, relay_uuid
            ));
            self.state = ConnState::ConnectingToPeer;
            rd.create_relay(peer_id, &relay_uuid, &punch.relay_server, server_key)?
        } else if !punch.relay_server.trim().is_empty() {
            self.state = ConnState::RequestingRelay;
            let mut relay_rd = RendezvousClient::new();
            crate::set_last_error(format!(
                "file-transfer requesting relay uuid server={}",
                punch.relay_server
            ));
            relay_rd.connect(rendezvous_host, rendezvous_port, server_key, false)?;
            let relay_uuid = relay_rd.request_relay_uuid(
                peer_id,
                &punch.relay_server,
                !punch.signed_pk.is_empty(),
            )?;
            crate::set_last_error(format!(
                "file-transfer connecting relay server={} uuid={}",
                punch.relay_server, relay_uuid
            ));
            self.state = ConnState::ConnectingToPeer;
            relay_rd.create_relay(peer_id, &relay_uuid, &punch.relay_server, server_key)?
        } else if let Some(peer_addr) = punch.peer_addr {
            crate::set_last_error(format!("file-transfer connecting peer addr={}", peer_addr));
            self.state = ConnState::ConnectingToPeer;
            self.peer_addr = Some(peer_addr);
            rd.connect_to_peer(peer_addr)?
        } else {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "file-transfer rendezvous response did not include peer address or relay uuid",
            ));
        };

        crate::set_last_error("file-transfer key exchanging".to_string());
        self.state = ConnState::KeyExchanging;
        let channel_key =
            self.secure_peer_connection(&mut peer_stream, peer_id, &punch.signed_pk, server_key)?;
        let crypto = CryptoChannel::new(peer_stream, &channel_key, &channel_key);
        self.crypto_channel = Some(crypto);

        crate::set_last_error(format!("file-transfer logging in dir={}", remote_dir));
        self.state = ConnState::LoggingIn;
        let crypto = self.crypto_channel.as_mut().unwrap();
        self.session
            .login_file_transfer_encrypted(crypto, peer_id, password, remote_dir, request_approval)?;
        crate::set_last_error(format!("login_file_transfer ok dir={}", remote_dir));
        self.state = ConnState::Connected;
        Ok(())
    }

    pub fn upload_file_once(
        &mut self,
        remote_path: &str,
        data: Vec<u8>,
        timeout: Duration,
    ) -> io::Result<()> {
        if self.state != ConnState::Connected {
            return Err(io::Error::new(
                io::ErrorKind::NotConnected,
                "file-transfer connector is not connected",
            ));
        }
        let crypto = self.crypto_channel.as_mut().ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotConnected,
                "crypto channel is not available",
            )
        })?;

        crypto.set_read_timeout(Some(Duration::from_millis(250)))?;
        let upload = Self::request_file_upload(crypto, remote_path, data)?;
        let mut pending = vec![upload];
        let mut awaiting_done: Vec<AwaitingFileDone> = Vec::new();
        let started = Instant::now();
        let mut last_wait_report = 0u64;

        while (!pending.is_empty() || !awaiting_done.is_empty()) && started.elapsed() < timeout {
            match crypto.recv() {
                Ok(plaintext) => {
                    let msg: Message = protobuf::parse_from_bytes(&plaintext)
                        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
                    match msg.union {
                        Some(Message_oneof_union::file_response(ref resp)) => {
                            Self::handle_file_response(
                                crypto,
                                resp,
                                &mut pending,
                                &mut awaiting_done,
                            )?;
                        }
                        Some(Message_oneof_union::file_action(ref action)) => {
                            Self::handle_file_action(
                                crypto,
                                action,
                                &mut pending,
                                &mut awaiting_done,
                            )?;
                        }
                        Some(Message_oneof_union::misc(ref misc)) => {
                            eprintln!(
                                "[RustDesk-FFI] file-transfer misc={}",
                                Self::misc_kind(misc)
                            );
                        }
                        other => {
                            eprintln!(
                                "[RustDesk-FFI] file-transfer waiting confirm, ignored msg={}",
                                Self::message_kind(&other)
                            );
                        }
                    }
                }
                Err(err)
                    if err.kind() == ErrorKind::WouldBlock || err.kind() == ErrorKind::TimedOut =>
                {
                    Self::flush_stale_file_uploads(crypto, &mut pending, &mut awaiting_done)?;
                    let elapsed = started.elapsed().as_secs();
                    if elapsed > last_wait_report {
                        last_wait_report = elapsed;
                        if awaiting_done.is_empty() {
                            crate::set_last_error(format!(
                                "file-transfer waiting peer confirm path={} elapsed={}s pending={}",
                                remote_path,
                                elapsed,
                                pending.len()
                            ));
                        } else {
                            crate::set_last_error(format!(
                                "file-transfer waiting remote done path={} elapsed={}s pending={} awaiting_done={}",
                                remote_path,
                                elapsed,
                                pending.len(),
                                awaiting_done.len()
                            ));
                        }
                    }
                    continue;
                }
                Err(err) => return Err(err),
            }
        }
        crypto.set_read_timeout(None).ok();

        if pending.is_empty() && awaiting_done.is_empty() {
            crate::set_last_error(format!("file transfer done path={}", remote_path));
            Ok(())
        } else {
            Err(io::Error::new(
                io::ErrorKind::TimedOut,
                format!(
                    "file-transfer peer did not finish upload pending={} awaiting_done={}",
                    pending.len(),
                    awaiting_done.len()
                ),
            ))
        }
    }

    /// KeyExchange: 交换 Curve25519 公钥
    fn key_exchange(&mut self, stream: &mut TcpStream) -> io::Result<()> {
        // 发送自己的公钥 (32 bytes, raw)
        use std::io::{Read, Write};
        stream.write_all(&self.keypair.public_key)?;
        stream.flush()?;

        // 接收对端公钥
        let mut peer_pk = [0u8; 32];
        stream.read_exact(&mut peer_pk)?;
        self.peer_pk = Some(peer_pk);
        Ok(())
    }

    fn secure_peer_connection(
        &mut self,
        stream: &mut TcpStream,
        peer_id: &str,
        signed_id_pk: &[u8],
        server_key: &str,
    ) -> io::Result<[u8; 32]> {
        let sign_pk = self.decode_signed_peer_pk(peer_id, signed_id_pk, server_key)?;
        let payload = wire::read_frame(stream)?;
        let msg: Message = protobuf::parse_from_bytes(&payload)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;

        let signed_id = match msg.union {
            Some(Message_oneof_union::signed_id(si)) => si,
            other => {
                let _ = self.send_empty_message(stream);
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("expected peer SignedId, got: {:?}", other),
                ));
            }
        };

        let verified = crypto::verify_signed_message(&signed_id.id, &sign_pk).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "peer signed id verification failed",
            )
        })?;
        let id_pk: IdPk = protobuf::parse_from_bytes(&verified)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        if id_pk.get_id() != peer_id {
            let _ = self.send_empty_message(stream);
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "peer signed id does not match requested id",
            ));
        }
        if id_pk.get_pk().len() != 32 {
            let _ = self.send_empty_message(stream);
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "peer public key length is invalid",
            ));
        }

        let mut their_pk = [0u8; 32];
        their_pk.copy_from_slice(id_pk.get_pk());
        let (asymmetric_value, symmetric_value, key) = crypto::create_symmetric_key_msg(&their_pk)
            .ok_or_else(|| {
                io::Error::new(io::ErrorKind::Other, "failed to create peer symmetric key")
            })?;

        let mut public_key = PublicKey::new();
        public_key.set_asymmetric_value(asymmetric_value.to_vec());
        public_key.set_symmetric_value(symmetric_value);
        let mut out = Message::new();
        out.union = Some(Message_oneof_union::public_key(public_key));
        let bytes = out
            .write_to_bytes()
            .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
        wire::write_frame(stream, &bytes)?;

        self.peer_pk = Some(their_pk);
        Ok(key)
    }

    fn decode_signed_peer_pk(
        &self,
        peer_id: &str,
        signed_id_pk: &[u8],
        server_key: &str,
    ) -> io::Result<[u8; 32]> {
        if signed_id_pk.is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "rendezvous response missing signed peer public key",
            ));
        }
        let key = if server_key.trim().is_empty() {
            crypto::RUSTDESK_SERVER_PUBLIC_KEY
        } else {
            server_key.trim()
        };
        let rs_pk = crypto::decode_base64_key(key).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid rendezvous server public key",
            )
        })?;
        let verified = crypto::verify_signed_message(signed_id_pk, &rs_pk).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "rendezvous signed peer key verification failed",
            )
        })?;
        let id_pk: IdPk = protobuf::parse_from_bytes(&verified)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        if id_pk.get_id() != peer_id {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "rendezvous signed peer id does not match requested id",
            ));
        }
        if id_pk.get_pk().len() != 32 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "rendezvous peer public key length is invalid",
            ));
        }
        let mut pk = [0u8; 32];
        pk.copy_from_slice(id_pk.get_pk());
        Ok(pk)
    }

    fn send_empty_message(&self, stream: &mut TcpStream) -> io::Result<()> {
        let msg = Message::new();
        let bytes = msg
            .write_to_bytes()
            .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
        wire::write_frame(stream, &bytes)
    }

    /// 从 key exchange 派生加密通道密钥
    fn derive_channel_keys(&self) -> ([u8; 32], [u8; 32]) {
        let peer_pk = self.peer_pk.unwrap();
        let my_sk = self.keypair.secret_key;

        // tx_key = crypto_box session key (我→对端)
        let tx_shared = x25519_dalek::StaticSecret::from(my_sk)
            .diffie_hellman(&x25519_dalek::PublicKey::from(peer_pk));
        let mut tx_key = [0u8; 32];
        tx_key.copy_from_slice(tx_shared.as_bytes());

        // rx_key = 同样的 shared secret (对称)
        let mut rx_key = [0u8; 32];
        rx_key.copy_from_slice(tx_shared.as_bytes());

        (tx_key, rx_key)
    }

    /// 运行 streaming 循环 (阻塞)
    ///
    /// 持续接收加密消息，分发到回调。
    pub fn run_streaming<VF, AFF, AF, CF>(
        &mut self,
        preferred_codec: i32,
        image_quality: i32,
        privacy_mode: bool,
        audio_enabled: bool,
        fps: u32,
        controls: Arc<ControlInbox>,
        mut on_video: VF,
        mut on_audio_format: AFF,
        mut on_audio: AF,
        mut on_clipboard: CF,
    ) -> io::Result<()>
    where
        VF: FnMut(&VideoFrame),
        AFF: FnMut(&AudioFormat),
        AF: FnMut(&AudioFrame),
        CF: FnMut(&[u8]),
    {
        let remote_upload_dir = self.default_remote_upload_dir();
        let crypto = self
            .crypto_channel
            .as_mut()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotConnected, "no crypto channel"))?;
        crypto.set_read_timeout(Some(Duration::from_millis(20)))?;

        let mut stream_options_reasserted = false;
        let mut empty_reads: u32 = 0; // 连续空读计数
                                      // 消息类型统计 — 用于诊断对端停止发送前的行为
        let mut msg_stats: std::collections::HashMap<&'static str, u64> =
            std::collections::HashMap::new();
        let stream_started = Instant::now();
        let mut last_video_at: Option<Instant> = None;
        let mut video_count: u64 = 0;
        let mut audio_count: u64 = 0;
        let mut keyframe_count: u64 = 0;
        let mut encoded_subframe_total: u64 = 0;
        let mut cadence_gap_count: u64 = 0;
        let mut max_cadence_gap_ms: u64 = 0;
        let mut stream_options_sent_count: u64 = 0;
        let mut video_received_ack_count: u64 = 0;
        let mut test_delay_echo_count: u64 = 0;
        let mut window_started = Instant::now();
        let mut window_video: u64 = 0;
        let mut window_audio: u64 = 0;
        let mut last_video_starvation_refresh_at: Option<Instant> = None;
        let mut last_control_diagnostic_at = Instant::now();
        let mut last_successful_receive_at = Instant::now();
        let mut last_msg_kind = "none";
        let mut pending_file_uploads: Vec<PendingFileUpload> = Vec::new();
        let mut awaiting_file_done: Vec<AwaitingFileDone> = Vec::new();
        // T-131: Backpressure hysteresis state
        let mut consecutive_overload_windows: u32 = 0;
        let mut consecutive_clean_windows: u32 = 0;
        let mut current_backpressure_level: u32 = 0; // 0=normal, 1=mild, 2=moderate, 3=severe
        let mut requested_pressure_level: u32 = 0;
        let mut applied_pressure_level: u32 = 0;
        const DEGRADE_AFTER_OVERLOAD_WINDOWS: u32 = 5; // need 5s of overload before degrade
        const RECOVER_AFTER_CLEAN_WINDOWS: u32 = 30; // 30s of clean before recover
        const OVERLOAD_VIDEO_THRESHOLD: u64 = 3; // <3 fps sustained = genuine decoder overload
                                                 // Backpressure FPS/quality table: [normal, mild, moderate, severe]
        const BP_FPS: [u32; 4] = [60, 45, 30, 15];
        if let Err(err) = Session::send_stream_options(
            crypto,
            preferred_codec,
            image_quality,
            privacy_mode,
            audio_enabled,
            fps,
        ) {
            eprintln!(
                "[RustDesk-FFI] streaming: initial stream options failed: {}",
                err
            );
        } else {
            stream_options_sent_count += 1;
            stream_options_reasserted = true;
            eprintln!("[RustDesk-FFI] streaming: initial stream options reasserted");
        }

        'streaming: while self.state == ConnState::Connected {
            let diagnostic_now = Instant::now();
            if should_emit_control_diagnostics(last_control_diagnostic_at, diagnostic_now) {
                let snapshot = controls.snapshot();
                eprintln!(
                    "[RustDesk-FFI] control diag reliable_depth={} max_reliable_depth={} coalesced_mouse={} coalesced_refresh={} coalesced_pressure={} batch_limit_hits={} receive_gap_ms={}",
                    snapshot.reliable_depth,
                    snapshot.max_reliable_depth,
                    snapshot.coalesced_mouse_moves,
                    snapshot.coalesced_refreshes,
                    snapshot.coalesced_video_pressure,
                    snapshot.batch_limit_hits,
                    diagnostic_now.duration_since(last_successful_receive_at).as_millis(),
                );
                last_control_diagnostic_at = diagnostic_now;
            }

            if controls.shutdown_requested() {
                eprintln!("[RustDesk-FFI] streaming: shutdown requested, exiting loop");
                self.state = ConnState::Disconnected;
                break 'streaming;
            }

            for control in Self::next_control_batch(controls.as_ref()) {
                if controls.shutdown_requested() {
                    eprintln!("[RustDesk-FFI] streaming: shutdown requested, exiting loop");
                    self.state = ConnState::Disconnected;
                    break 'streaming;
                }

                match control {
                    crate::ControlMsg::Shutdown => {
                        eprintln!("[RustDesk-FFI] streaming: shutdown requested, exiting loop");
                        self.state = ConnState::Disconnected;
                        break 'streaming;
                    }
                    crate::ControlMsg::VideoPressure { level } => {
                        requested_pressure_level = level.min(3);
                    }
                    crate::ControlMsg::SendFile { remote_path, data } => {
                        let upload_path = Self::normalize_remote_upload_path(
                            &remote_path,
                            remote_upload_dir.as_deref(),
                        );
                        crate::set_last_error(format!(
                            "streaming: send file path={} size={}",
                            upload_path,
                            data.len()
                        ));
                        // 文件传输: 先发 receive，等远端 digest 后再发数据块。
                        eprintln!(
                            "[RustDesk-FFI] streaming: send file path={} original_path={} size={}",
                            upload_path,
                            remote_path,
                            data.len()
                        );
                        match Self::request_file_upload(crypto, &upload_path, data) {
                            Ok(upload) => pending_file_uploads.push(upload),
                            Err(e) => {
                                crate::set_last_error(format!(
                                    "streaming: file send error path={} err={}",
                                    upload_path, e
                                ));
                                eprintln!("[RustDesk-FFI] streaming: file send error: {}", e);
                            }
                        }
                    }
                    crate::ControlMsg::Clipboard { content } => {
                        // 剪贴板同步: 将内容发送到远程剪贴板
                        let mut cb = Clipboard::new();
                        cb.set_format(ClipboardFormat::Text);
                        cb.set_content(content);
                        let mut msg = Message::new();
                        msg.union = Some(Message_oneof_union::clipboard(cb));
                        if let Err(e) = Self::send_message_encrypted(crypto, &msg) {
                            eprintln!("[RustDesk-FFI] clipboard send error: {}", e);
                        }
                    }
                    msg => {
                        eprintln!(
                            "[RustDesk-FFI] streaming: control msg kind={}",
                            Self::control_msg_kind(&msg)
                        );
                        if let Err(e) = Self::send_control_message(crypto, msg) {
                            eprintln!("[RustDesk-FFI] streaming: control msg error: {}", e);
                        }
                    }
                }
            }

            Self::flush_stale_file_uploads(
                crypto,
                &mut pending_file_uploads,
                &mut awaiting_file_done,
            )?;

            let plaintext = match crypto.recv() {
                Ok(plaintext) => {
                    empty_reads = 0; // 重置空读计数
                    last_successful_receive_at = Instant::now();
                    plaintext
                }
                Err(err)
                    if err.kind() == ErrorKind::WouldBlock || err.kind() == ErrorKind::TimedOut =>
                {
                    empty_reads += 1;
                    // 每 2 秒 (100 * 20ms) 发送 refresh_video 保持对端活跃
                    if empty_reads % 100 == 0 {
                        eprintln!(
                            "[RustDesk-FFI] streaming: {}s no data, sending refresh_video",
                            empty_reads / 50
                        );
                        let _ = Session::send_refresh_video(crypto);
                    }
                    continue;
                }
                Err(err) => {
                    eprintln!(
                        "[RustDesk-FFI] streaming: recv error kind={:?} msg={}, exiting loop",
                        err.kind(),
                        err
                    );
                    return Err(err);
                }
            };
            let msg: Message = protobuf::parse_from_bytes(&plaintext).map_err(|e| {
                eprintln!(
                    "[RustDesk-FFI] streaming: protobuf parse error: {}, exiting loop",
                    e
                );
                io::Error::new(io::ErrorKind::InvalidData, e)
            })?;

            match msg.union {
                Some(Message_oneof_union::video_frame(ref vf)) => {
                    last_msg_kind = "video_frame";
                    *msg_stats.entry("video_frame").or_default() += 1;
                    video_count += 1;
                    window_video += 1;
                    // Track keyframes and subframe count
                    let vf_keyframe = Self::video_frame_has_keyframe(vf);
                    if vf_keyframe {
                        keyframe_count += 1;
                    }
                    let subframe_count = Self::video_frame_subframe_count(vf);
                    encoded_subframe_total += subframe_count;
                    let now = Instant::now();
                    if let Some(prev) = last_video_at {
                        let gap_ms = now.duration_since(prev).as_millis() as u64;
                        if gap_ms > 200 {
                            cadence_gap_count += 1;
                            if gap_ms > max_cadence_gap_ms {
                                max_cadence_gap_ms = gap_ms;
                            }
                            if cadence_gap_count <= 8 || cadence_gap_count % 30 == 0 {
                                eprintln!(
                                    "[RustDesk-FFI] video cadence gap={}ms elapsed={}ms video={} keyframe={} subframes={} codec={} window_video={} window_audio={}",
                                    gap_ms,
                                    now.duration_since(stream_started).as_millis(),
                                    video_count,
                                    keyframe_count,
                                    encoded_subframe_total,
                                    Self::video_frame_codec_name(vf),
                                    window_video,
                                    window_audio
                                );
                            }
                        }
                    }
                    last_video_at = Some(now);
                    let actual_codec = Self::video_frame_codec_preference(vf);
                    if !stream_options_reasserted
                        && preferred_codec != 0
                        && actual_codec != 0
                        && actual_codec != preferred_codec
                    {
                        stream_options_sent_count += 1;
                        let _ = Session::send_stream_options(
                            crypto,
                            preferred_codec,
                            image_quality,
                            privacy_mode,
                            audio_enabled,
                            fps,
                        );
                        stream_options_reasserted = true;
                    }
                    let video_callback_started = Instant::now();
                    on_video(vf);
                    let video_callback_elapsed = video_callback_started.elapsed();
                    if video_callback_elapsed >= SLOW_VIDEO_CALLBACK_WARN {
                        eprintln!(
                            "[RustDesk-FFI] video callback slow elapsed_ms={} video={} codec={}",
                            video_callback_elapsed.as_millis(),
                            video_count,
                            Self::video_frame_codec_name(vf),
                        );
                    }

                    let video_ack_started = Instant::now();
                    let video_ack_result = Session::send_video_received(crypto);
                    let video_ack_elapsed = video_ack_started.elapsed();
                    if video_ack_elapsed >= SLOW_VIDEO_ACK_WARN {
                        eprintln!(
                            "[RustDesk-FFI] video ack slow elapsed_ms={} video={}",
                            video_ack_elapsed.as_millis(),
                            video_count,
                        );
                    }
                    if let Err(err) = video_ack_result {
                        eprintln!(
                            "[RustDesk-FFI] streaming: video_received ack failed: {}",
                            err
                        );
                    } else {
                        video_received_ack_count += 1;
                        if video_received_ack_count <= 3 || video_received_ack_count % 120 == 0 {
                            eprintln!(
                                "[RustDesk-FFI] streaming: video_received ack #{} video={}",
                                video_received_ack_count, video_count
                            );
                        }
                    }
                }
                Some(Message_oneof_union::audio_frame(ref af)) => {
                    last_msg_kind = "audio_frame";
                    *msg_stats.entry("audio_frame").or_default() += 1;
                    audio_count += 1;
                    window_audio += 1;
                    on_audio(af);
                    if audio_count == 1 {
                        eprintln!("[RustDesk-FFI] audio detected — async worker active");
                    }
                }
                Some(Message_oneof_union::test_delay(test_delay)) => {
                    last_msg_kind = "test_delay";
                    test_delay_echo_count += 1;
                    let count = msg_stats.entry("test_delay").or_default();
                    *count += 1;
                    if test_delay_echo_count <= 3 || test_delay_echo_count % 60 == 0 {
                        eprintln!(
                            "[RustDesk-FFI] streaming: echoed test_delay #{} elapsed={}ms video={}",
                            *count,
                            Instant::now().duration_since(stream_started).as_millis(),
                            video_count
                        );
                    }

                    // 服务端依赖 TestDelay 往返来更新视频 QoS；流阶段也必须回包。
                    let mut out = Message::new();
                    out.union = Some(Message_oneof_union::test_delay(test_delay));
                    Self::send_message_encrypted(crypto, &out)?;
                }
                Some(Message_oneof_union::misc(ref misc)) => {
                    // 记录 misc 子类型
                    let misc_key = match &misc.union {
                        Some(Misc_oneof_union::audio_format(_)) => "misc/audio_format",
                        Some(Misc_oneof_union::option(_)) => "misc/option",
                        Some(Misc_oneof_union::close_reason(_)) => "misc/close_reason",
                        Some(Misc_oneof_union::refresh_video(_)) => "misc/refresh_video",
                        Some(Misc_oneof_union::video_received(_)) => "misc/video_received",
                        _ => "misc/other",
                    };
                    last_msg_kind = misc_key;
                    *msg_stats.entry(misc_key).or_default() += 1;
                    if let Some(Misc_oneof_union::audio_format(ref format)) = misc.union {
                        on_audio_format(format);
                    }
                }
                Some(Message_oneof_union::login_response(ref resp)) => {
                    last_msg_kind = "login_response";
                    *msg_stats.entry("login_response").or_default() += 1;
                    if resp.has_error() {
                        eprintln!(
                            "[RustDesk-FFI] streaming: login_response error from peer: {}, exiting loop",
                            resp.get_error()
                        );
                        break;
                    }
                }
                Some(Message_oneof_union::clipboard(ref clipboard)) => {
                    last_msg_kind = "clipboard";
                    *msg_stats.entry("clipboard").or_default() += 1;
                    if clipboard.get_format() == ClipboardFormat::Text {
                        on_clipboard(clipboard.get_content());
                    }
                }
                // switch_display / message_query 等其他类型由 _ arm 统一处理
                Some(Message_oneof_union::cursor_position(_)) => {
                    last_msg_kind = "cursor_position";
                    *msg_stats.entry("cursor_position").or_default() += 1;
                }
                Some(Message_oneof_union::cursor_data(_)) => {
                    last_msg_kind = "cursor_data";
                    *msg_stats.entry("cursor_data").or_default() += 1;
                }
                Some(Message_oneof_union::peer_info(_)) => {
                    last_msg_kind = "peer_info";
                    *msg_stats.entry("peer_info").or_default() += 1;
                }
                Some(Message_oneof_union::file_response(ref resp)) => {
                    last_msg_kind = Self::file_response_kind(resp);
                    *msg_stats.entry(last_msg_kind).or_default() += 1;
                    Self::handle_file_response(
                        crypto,
                        resp,
                        &mut pending_file_uploads,
                        &mut awaiting_file_done,
                    )?;
                }
                Some(Message_oneof_union::file_action(ref action)) => {
                    last_msg_kind = Self::file_action_kind(action);
                    *msg_stats.entry(last_msg_kind).or_default() += 1;
                    Self::handle_file_action(
                        crypto,
                        action,
                        &mut pending_file_uploads,
                        &mut awaiting_file_done,
                    )?;
                }
                _ => {
                    last_msg_kind = "other";
                    *msg_stats.entry("other").or_default() += 1;
                }
            }
            let now = Instant::now();
            if now.duration_since(window_started) >= Duration::from_secs(1) {
                if requested_pressure_level != applied_pressure_level {
                    applied_pressure_level = requested_pressure_level;
                    current_backpressure_level = applied_pressure_level;
                    consecutive_overload_windows = 0;
                    consecutive_clean_windows = 0;
                    let fps = BP_FPS[applied_pressure_level as usize];
                    eprintln!(
                        "[RustDesk-FFI] LOCAL PRESSURE level={} fps={} quality={} total_video={}",
                        applied_pressure_level, fps, image_quality, video_count
                    );
                    let _ = Session::send_runtime_options(
                        crypto,
                        preferred_codec,
                        image_quality,
                        privacy_mode,
                        audio_enabled,
                        Some(fps),
                    );
                    let _ = Session::send_refresh_video(crypto);
                }
                // T-131: Backpressure hysteresis — video-only overload detection
                // Audio frames are NOT a decoder overload signal; they're independent.
                // Overload = sustained very low video throughput (< 3 fps) for 5+ seconds.
                let is_overload = requested_pressure_level > 0
                    && window_video < OVERLOAD_VIDEO_THRESHOLD
                    && video_count > 20; // only after initial burst (avoid false trigger on connect)
                if is_overload {
                    consecutive_overload_windows += 1;
                    consecutive_clean_windows = 0;
                    if consecutive_overload_windows >= DEGRADE_AFTER_OVERLOAD_WINDOWS
                        && current_backpressure_level < 3
                    {
                        current_backpressure_level += 1;
                        consecutive_overload_windows = 0;
                        let fps = BP_FPS[current_backpressure_level as usize];
                        let quality = image_quality;
                        eprintln!(
                            "[RustDesk-FFI] BACKPRESSURE DEGRADE level={} fps={} quality={} window_video={} total_video={}",
                            current_backpressure_level, fps, quality, window_video, video_count
                        );
                        let _ = Session::send_runtime_options(
                            crypto,
                            preferred_codec,
                            quality,
                            privacy_mode,
                            audio_enabled,
                            Some(fps),
                        );
                        let _ = Session::send_refresh_video(crypto);
                    }
                } else {
                    consecutive_clean_windows += 1;
                    consecutive_overload_windows = 0;
                    if consecutive_clean_windows >= RECOVER_AFTER_CLEAN_WINDOWS
                        && current_backpressure_level > 0
                    {
                        current_backpressure_level -= 1;
                        consecutive_clean_windows = 0;
                        let fps = BP_FPS[current_backpressure_level as usize];
                        let quality = image_quality;
                        eprintln!(
                            "[RustDesk-FFI] BACKPRESSURE RECOVER level={} fps={} quality={} total_video={}",
                            current_backpressure_level, fps, quality, video_count
                        );
                        let _ = Session::send_runtime_options(
                            crypto,
                            preferred_codec,
                            quality,
                            privacy_mode,
                            audio_enabled,
                            Some(fps),
                        );
                    }
                }
                let last_video_age_ms =
                    last_video_at.map(|at| now.duration_since(at).as_millis());
                let last_refresh_age_ms = last_video_starvation_refresh_at
                    .map(|at| now.duration_since(at).as_millis());
                if should_refresh_for_video_starvation(
                    video_count,
                    window_video,
                    window_audio,
                    last_video_age_ms,
                    last_refresh_age_ms,
                ) {
                    eprintln!(
                        "[RustDesk-FFI] VIDEO STARVATION audio_alive video_window=0 audio_window={} total_video={} total_audio={} last_video_age={}ms -> refresh_video",
                        window_audio,
                        video_count,
                        audio_count,
                        last_video_age_ms.unwrap_or(0)
                    );
                    let _ = Session::send_refresh_video(crypto);
                    last_video_starvation_refresh_at = Some(now);
                }
                if video_count > 0 && (window_video < 5 || consecutive_overload_windows > 0) {
                    eprintln!(
                        "[RustDesk-FFI] stream window 1s video={} audio={} total_video={} total_audio={} empty_reads={} bp_level={} bp_overload={}",
                        window_video,
                        window_audio,
                        video_count,
                        audio_count,
                        empty_reads,
                        current_backpressure_level,
                        consecutive_overload_windows
                    );
                }
                window_started = now;
                window_video = 0;
                window_audio = 0;
            }
        }

        // 格式化消息统计 — 存储在 connector 中供 lib.rs 上报到 hilog
        let stats_str = msg_stats
            .iter()
            .map(|(k, v)| format!("{}={}", k, v))
            .collect::<Vec<_>>()
            .join(" ");
        self.stream_stats = format!(
            "empty_reads={} last_msg={} video={} keyframe={} subframes={} audio={} cadence_gaps={} max_gap_ms={} options_sent={} video_acks={} test_delay={} msgs=[{}]",
            empty_reads, last_msg_kind, video_count, keyframe_count, encoded_subframe_total,
            audio_count, cadence_gap_count, max_cadence_gap_ms, stream_options_sent_count,
            video_received_ack_count, test_delay_echo_count, stats_str
        );
        eprintln!(
            "[RustDesk-FFI] streaming: while loop exited, state={:?}, {}",
            self.state, self.stream_stats
        );
        self.state = ConnState::Disconnected;
        Ok(())
    }

    fn send_control_message(
        crypto: &mut CryptoChannel,
        control: crate::ControlMsg,
    ) -> io::Result<()> {
        match control {
            crate::ControlMsg::Shutdown => Ok(()),
            crate::ControlMsg::RefreshVideo => {
                crate::set_last_error("send refresh video");
                Session::send_refresh_video(crypto)
            }
            crate::ControlMsg::VideoPressure { .. } => Ok(()),
            crate::ControlMsg::KeyEvent { scancode, pressed } => {
                Self::send_key_event_encrypted(crypto, scancode, pressed)
            }
            crate::ControlMsg::MouseEvent {
                x,
                y,
                button,
                pressed,
            } => {
                let button_mask = match button {
                    0 => 0x01,
                    1 => 0x04,
                    2 => 0x02,
                    _ => 0x01,
                };
                let event_type = if pressed { 1 } else { 2 };
                Self::send_mouse_event_encrypted(crypto, x, y, (button_mask << 3) | event_type)
            }
            crate::ControlMsg::MouseMove { x, y } => {
                Self::send_mouse_event_encrypted(crypto, x, y, 0)
            }
            crate::ControlMsg::MouseWheel { x, y, delta } => {
                let _ = (x, y);
                crate::set_last_error(format!("send mouse wheel delta={}", delta));
                Self::send_mouse_event_encrypted(crypto, 0, delta, 3)
            }
            crate::ControlMsg::Text { text } => Self::send_text_event_encrypted(crypto, &text),
            crate::ControlMsg::SendFile { .. } => Err(io::Error::new(
                io::ErrorKind::Other,
                "SendFile handled by streaming loop",
            )),
            crate::ControlMsg::Clipboard { .. } => Err(io::Error::new(
                io::ErrorKind::Other,
                "Clipboard handled by streaming loop",
            )),
        }
    }

    fn control_msg_kind(control: &crate::ControlMsg) -> &'static str {
        match control {
            crate::ControlMsg::Shutdown => "shutdown",
            crate::ControlMsg::RefreshVideo => "refresh_video",
            crate::ControlMsg::VideoPressure { .. } => "video_pressure",
            crate::ControlMsg::KeyEvent { .. } => "key",
            crate::ControlMsg::MouseEvent { .. } => "mouse",
            crate::ControlMsg::MouseMove { .. } => "mouse_move",
            crate::ControlMsg::MouseWheel { .. } => "mouse_wheel",
            crate::ControlMsg::Text { .. } => "text",
            crate::ControlMsg::SendFile { .. } => "send_file",
            crate::ControlMsg::Clipboard { .. } => "clipboard",
        }
    }

    fn default_remote_upload_dir(&self) -> Option<String> {
        let info = self.session.peer_info()?;
        let platform = info.get_platform().to_ascii_lowercase();
        if !platform.contains("windows") {
            return None;
        }

        let mut user = info.get_username().trim().to_string();
        if let Some(idx) = user.rfind('\\') {
            user = user[idx + 1..].to_string();
        }
        if let Some(idx) = user.rfind('/') {
            user = user[idx + 1..].to_string();
        }

        if user.is_empty() || user.eq_ignore_ascii_case("system") {
            Some("C:\\Users\\Public\\Desktop".to_string())
        } else {
            Some(format!("C:\\Users\\{}\\Desktop", user))
        }
    }

    fn normalize_remote_upload_path(remote_path: &str, default_dir: Option<&str>) -> String {
        let Some(default_dir) = default_dir else {
            return remote_path.to_string();
        };
        let (dir, file_name) = Self::split_remote_file_path(remote_path);
        if file_name.is_empty() {
            return remote_path.to_string();
        }

        let normalized_dir = dir.replace('/', "\\");
        let lower_dir = normalized_dir.to_ascii_lowercase();
        let should_use_default = dir == "."
            || lower_dir == "c:\\users\\public\\desktop"
            || lower_dir.ends_with("\\desktop") && lower_dir.contains("\\users\\public\\");
        if should_use_default {
            format!(
                "{}\\{}",
                default_dir.trim_end_matches(['\\', '/']),
                file_name
            )
        } else {
            remote_path.to_string()
        }
    }

    /// 文件传输协议 — 请求上传文件到远程桌面。
    ///
    /// 在 streaming loop 上下文中调用。先发送 receive 请求，等远端回 digest 后
    /// 再确认并发送 block/done；旧端不回 digest 时由短超时兼容路径继续发送。
    ///
    /// RustDesk 协议里 `send` 表示远端读文件给客户端；客户端上传必须先发
    /// `receive`，让被控端创建写任务。
    fn request_file_upload(
        crypto: &mut CryptoChannel,
        remote_path: &str,
        data: Vec<u8>,
    ) -> io::Result<PendingFileUpload> {
        let transfer_id = (Self::unix_millis_now() & 0x7FFF_FFFF) as i32;
        let (remote_dir, file_name) = Self::split_remote_file_path(remote_path);
        if file_name.is_empty() {
            return Err(io::Error::new(
                ErrorKind::InvalidInput,
                "remote file name is empty",
            ));
        }

        {
            let mut entry = FileEntry::new();
            entry.set_entry_type(FileType::File);
            entry.set_name(file_name.to_string());
            entry.set_size(data.len() as u64);
            entry.set_modified_time(Self::unix_millis_now());

            let mut receive_req = FileTransferReceiveRequest::new();
            receive_req.set_id(transfer_id);
            receive_req.set_path(remote_dir.to_string());
            receive_req.mut_files().push(entry);
            receive_req.set_file_num(0);
            receive_req.set_total_size(data.len() as u64);

            let mut action = FileAction::new();
            action.union = Some(FileAction_oneof_union::receive(receive_req));
            let mut msg = Message::new();
            msg.union = Some(Message_oneof_union::file_action(action));
            Self::send_message_encrypted(crypto, &msg)?;
        }

        eprintln!(
            "[RustDesk-FFI] file upload requested: receive dir={} file={} size={} id={}",
            remote_dir,
            file_name,
            data.len(),
            transfer_id
        );
        crate::set_last_error(format!(
            "file upload requested dir={} file={} size={} id={}",
            remote_dir,
            file_name,
            data.len(),
            transfer_id
        ));

        Ok(PendingFileUpload {
            id: transfer_id,
            remote_dir: remote_dir.to_string(),
            file_name: file_name.to_string(),
            data,
            requested_at: Instant::now(),
        })
    }

    fn send_file_upload_data(
        crypto: &mut CryptoChannel,
        upload: &PendingFileUpload,
        reason: &str,
        start_blk: u32,
    ) -> io::Result<()> {
        const CHUNK_SIZE: usize = 65536;
        let total_chunks = (upload.data.len() + CHUNK_SIZE - 1) / CHUNK_SIZE;
        let start_chunk = (start_blk as usize).min(total_chunks);
        let mut sent_chunks = 0usize;
        for (blk_idx, chunk) in upload.data.chunks(CHUNK_SIZE).enumerate().skip(start_chunk) {
            let mut block = FileTransferBlock::new();
            block.set_id(upload.id);
            block.set_file_num(0);
            block.set_data(chunk.to_vec());
            block.set_compressed(false);
            block.set_blk_id(blk_idx as u32);

            let mut resp = FileResponse::new();
            resp.union = Some(FileResponse_oneof_union::block(block));
            let mut msg = Message::new();
            msg.union = Some(Message_oneof_union::file_response(resp));
            Self::send_message_encrypted(crypto, &msg)?;
            sent_chunks += 1;
        }

        {
            let mut done = FileTransferDone::new();
            done.set_id(upload.id);
            done.set_file_num(0);

            let mut resp = FileResponse::new();
            resp.union = Some(FileResponse_oneof_union::done(done));
            let mut msg = Message::new();
            msg.union = Some(Message_oneof_union::file_response(resp));
            Self::send_message_encrypted(crypto, &msg)?;
        }

        eprintln!(
            "[RustDesk-FFI] file upload data: reason={} dir={} file={} size={} chunks_sent={} chunks_total={} start_blk={} id={}",
            reason,
            upload.remote_dir,
            upload.file_name,
            upload.data.len(),
            sent_chunks,
            total_chunks,
            start_blk,
            upload.id
        );
        crate::set_last_error(format!(
            "file upload data reason={} file={} size={} chunks_sent={} chunks_total={} id={}",
            reason,
            upload.file_name,
            upload.data.len(),
            sent_chunks,
            total_chunks,
            upload.id
        ));
        Ok(())
    }

    fn flush_stale_file_uploads(
        crypto: &mut CryptoChannel,
        pending_uploads: &mut Vec<PendingFileUpload>,
        awaiting_done: &mut Vec<AwaitingFileDone>,
    ) -> io::Result<()> {
        const FILE_UPLOAD_DIGEST_WAIT_MS: u128 = 1500;
        let now = Instant::now();
        let mut i = 0;
        while i < pending_uploads.len() {
            if now
                .duration_since(pending_uploads[i].requested_at)
                .as_millis()
                >= FILE_UPLOAD_DIGEST_WAIT_MS
            {
                let upload = pending_uploads.remove(i);
                let id = upload.id;
                let file_name = upload.file_name.clone();
                Self::send_file_upload_data(crypto, &upload, "digest-timeout", 0)?;
                awaiting_done.push(AwaitingFileDone { id, file_name });
            } else {
                i += 1;
            }
        }
        Ok(())
    }

    fn split_remote_file_path(remote_path: &str) -> (&str, &str) {
        let slash = remote_path.rfind('/');
        let backslash = remote_path.rfind('\\');
        let split_at = match (slash, backslash) {
            (Some(a), Some(b)) => Some(a.max(b)),
            (Some(a), None) => Some(a),
            (None, Some(b)) => Some(b),
            (None, None) => None,
        };

        match split_at {
            Some(idx) => {
                let dir = &remote_path[..idx];
                let name = &remote_path[idx + 1..];
                (if dir.is_empty() { "." } else { dir }, name)
            }
            None => (".", remote_path),
        }
    }

    fn unix_millis_now() -> u64 {
        use std::time::{SystemTime, UNIX_EPOCH};
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64
    }

    fn file_response_kind(resp: &FileResponse) -> &'static str {
        match &resp.union {
            Some(FileResponse_oneof_union::dir(_)) => "file_response/dir",
            Some(FileResponse_oneof_union::block(_)) => "file_response/block",
            Some(FileResponse_oneof_union::error(_)) => "file_response/error",
            Some(FileResponse_oneof_union::done(_)) => "file_response/done",
            Some(FileResponse_oneof_union::digest(_)) => "file_response/digest",
            Some(FileResponse_oneof_union::empty_dirs(_)) => "file_response/empty_dirs",
            None => "file_response/empty",
        }
    }

    fn misc_kind(misc: &Misc) -> &'static str {
        match &misc.union {
            Some(Misc_oneof_union::audio_format(_)) => "misc/audio_format",
            Some(Misc_oneof_union::option(_)) => "misc/option",
            Some(Misc_oneof_union::close_reason(_)) => "misc/close_reason",
            Some(Misc_oneof_union::refresh_video(_)) => "misc/refresh_video",
            Some(Misc_oneof_union::video_received(_)) => "misc/video_received",
            Some(Misc_oneof_union::switch_display(_)) => "misc/switch_display",
            Some(Misc_oneof_union::chat_message(_)) => "misc/chat_message",
            _ => "misc/other",
        }
    }

    fn message_kind(union: &Option<Message_oneof_union>) -> &'static str {
        match union {
            Some(Message_oneof_union::video_frame(_)) => "video_frame",
            Some(Message_oneof_union::audio_frame(_)) => "audio_frame",
            Some(Message_oneof_union::test_delay(_)) => "test_delay",
            Some(Message_oneof_union::misc(_)) => "misc",
            Some(Message_oneof_union::login_response(_)) => "login_response",
            Some(Message_oneof_union::clipboard(_)) => "clipboard",
            Some(Message_oneof_union::cursor_position(_)) => "cursor_position",
            Some(Message_oneof_union::cursor_data(_)) => "cursor_data",
            Some(Message_oneof_union::peer_info(_)) => "peer_info",
            Some(Message_oneof_union::file_response(_)) => "file_response",
            Some(Message_oneof_union::file_action(_)) => "file_action",
            _ => "other",
        }
    }

    fn file_action_kind(action: &FileAction) -> &'static str {
        match &action.union {
            Some(FileAction_oneof_union::read_dir(_)) => "file_action/read_dir",
            Some(FileAction_oneof_union::send(_)) => "file_action/send",
            Some(FileAction_oneof_union::receive(_)) => "file_action/receive",
            Some(FileAction_oneof_union::create(_)) => "file_action/create",
            Some(FileAction_oneof_union::remove_dir(_)) => "file_action/remove_dir",
            Some(FileAction_oneof_union::remove_file(_)) => "file_action/remove_file",
            Some(FileAction_oneof_union::all_files(_)) => "file_action/all_files",
            Some(FileAction_oneof_union::cancel(_)) => "file_action/cancel",
            Some(FileAction_oneof_union::send_confirm(_)) => "file_action/send_confirm",
            Some(FileAction_oneof_union::rename(_)) => "file_action/rename",
            Some(FileAction_oneof_union::read_empty_dirs(_)) => "file_action/read_empty_dirs",
            None => "file_action/empty",
        }
    }

    fn handle_file_action(
        crypto: &mut CryptoChannel,
        action: &FileAction,
        pending_uploads: &mut Vec<PendingFileUpload>,
        awaiting_done: &mut Vec<AwaitingFileDone>,
    ) -> io::Result<()> {
        if let Some(FileAction_oneof_union::send_confirm(confirm)) = &action.union {
            crate::set_last_error(format!(
                "file upload send-confirm id={} file_num={} skip={} offset_blk={}",
                confirm.get_id(),
                confirm.get_file_num(),
                confirm.get_skip(),
                confirm.get_offset_blk()
            ));
            eprintln!(
                "[RustDesk-FFI] file upload send_confirm: id={} file_num={} skip={} offset_blk={}",
                confirm.get_id(),
                confirm.get_file_num(),
                confirm.get_skip(),
                confirm.get_offset_blk()
            );
            if let Some(pos) = pending_uploads
                .iter()
                .position(|upload| upload.id == confirm.get_id() && confirm.get_file_num() == 0)
            {
                let upload = pending_uploads.remove(pos);
                if confirm.get_skip() {
                    eprintln!(
                        "[RustDesk-FFI] file upload skipped by peer: dir={} file={} id={}",
                        upload.remote_dir, upload.file_name, upload.id
                    );
                    crate::set_last_error(format!(
                        "file transfer error path={} file={} err=skipped by peer",
                        upload.remote_dir, upload.file_name
                    ));
                    return Err(io::Error::new(
                        io::ErrorKind::PermissionDenied,
                        "file upload skipped by peer",
                    ));
                } else {
                    let id = upload.id;
                    let file_name = upload.file_name.clone();
                    Self::send_file_upload_data(
                        crypto,
                        &upload,
                        "send-confirm",
                        confirm.get_offset_blk(),
                    )?;
                    awaiting_done.push(AwaitingFileDone { id, file_name });
                }
            } else {
                eprintln!(
                    "[RustDesk-FFI] file upload send_confirm without pending upload: id={} file_num={}",
                    confirm.get_id(),
                    confirm.get_file_num()
                );
                crate::set_last_error(format!(
                    "file transfer error id={} file_num={} err=send-confirm without pending upload",
                    confirm.get_id(),
                    confirm.get_file_num()
                ));
            }
        }
        Ok(())
    }

    fn handle_file_response(
        crypto: &mut CryptoChannel,
        resp: &FileResponse,
        pending_uploads: &mut Vec<PendingFileUpload>,
        awaiting_done: &mut Vec<AwaitingFileDone>,
    ) -> io::Result<()> {
        match &resp.union {
            Some(FileResponse_oneof_union::error(err)) => {
                crate::set_last_error(format!(
                    "file transfer error id={} file_num={} err={}",
                    err.get_id(),
                    err.get_file_num(),
                    err.get_error()
                ));
                eprintln!(
                    "[RustDesk-FFI] file transfer error: id={} file_num={} error={}",
                    err.get_id(),
                    err.get_file_num(),
                    err.get_error()
                );
                return Err(io::Error::new(
                    io::ErrorKind::Other,
                    format!("remote file transfer error: {}", err.get_error()),
                ));
            }
            Some(FileResponse_oneof_union::done(done)) => {
                if let Some(pos) = awaiting_done
                    .iter()
                    .position(|upload| upload.id == done.get_id())
                {
                    let completed = awaiting_done.remove(pos);
                    crate::set_last_error(format!(
                        "file transfer done id={} file_num={} file={}",
                        done.get_id(),
                        done.get_file_num(),
                        completed.file_name
                    ));
                } else {
                    crate::set_last_error(format!(
                        "file transfer done id={} file_num={}",
                        done.get_id(),
                        done.get_file_num()
                    ));
                }
                eprintln!(
                    "[RustDesk-FFI] file transfer done: id={} file_num={}",
                    done.get_id(),
                    done.get_file_num()
                );
            }
            Some(FileResponse_oneof_union::digest(digest)) => {
                crate::set_last_error(format!(
                    "file transfer digest id={} file_num={} upload={} identical={} resume={} size={} transferred={}",
                    digest.get_id(),
                    digest.get_file_num(),
                    digest.get_is_upload(),
                    digest.get_is_identical(),
                    digest.get_is_resume(),
                    digest.get_file_size(),
                    digest.get_transferred_size()
                ));
                eprintln!(
                    "[RustDesk-FFI] file transfer digest: id={} file_num={} upload={} identical={} resume={} size={} transferred={}",
                    digest.get_id(),
                    digest.get_file_num(),
                    digest.get_is_upload(),
                    digest.get_is_identical(),
                    digest.get_is_resume(),
                    digest.get_file_size(),
                    digest.get_transferred_size()
                );
                if let Some(pos) = pending_uploads
                    .iter()
                    .position(|upload| upload.id == digest.get_id() && digest.get_file_num() == 0)
                {
                    let mut confirm = FileTransferSendConfirmRequest::new();
                    confirm.set_id(digest.get_id());
                    confirm.set_file_num(digest.get_file_num());
                    confirm.set_offset_blk(0);

                    let mut action = FileAction::new();
                    action.union = Some(FileAction_oneof_union::send_confirm(confirm));
                    let mut msg = Message::new();
                    msg.union = Some(Message_oneof_union::file_action(action));
                    Self::send_message_encrypted(crypto, &msg)?;
                    eprintln!(
                        "[RustDesk-FFI] file upload confirm: id={} file_num={} offset_blk=0",
                        digest.get_id(),
                        digest.get_file_num()
                    );
                    crate::set_last_error(format!(
                        "file upload confirm id={} file_num={} offset_blk=0",
                        digest.get_id(),
                        digest.get_file_num()
                    ));
                    let upload = pending_uploads.remove(pos);
                    let id = upload.id;
                    let file_name = upload.file_name.clone();
                    Self::send_file_upload_data(crypto, &upload, "digest-confirmed", 0)?;
                    awaiting_done.push(AwaitingFileDone { id, file_name });
                }
            }
            _ => {}
        }
        Ok(())
    }

    fn build_key_message(scancode: u32, pressed: bool) -> Option<Message> {
        let mut key = KeyEvent::new();
        key.set_mode(KeyboardMode::Legacy);
        if let Some(control_key) = Self::harmony_keycode_to_control_key(scancode) {
            if Self::is_modifier_control_key(control_key) {
                key.set_down(pressed);
            } else if pressed {
                key.set_press(true);
            } else {
                return None;
            }
            key.union = Some(KeyEvent_oneof_union::control_key(control_key));
        } else {
            if pressed {
                key.set_press(true);
            } else {
                return None;
            }
            let chr_code = Self::harmony_keycode_to_chr(scancode);
            key.union = Some(KeyEvent_oneof_union::chr(chr_code));
        }
        let mut msg = Message::new();
        msg.union = Some(Message_oneof_union::key_event(key));
        Some(msg)
    }

    pub(crate) fn next_control_batch(controls: &ControlInbox) -> Vec<crate::ControlMsg> {
        controls.take_batch(CONTROL_BATCH_LIMIT)
    }

    fn log_key_message(scancode: u32, pressed: bool) {
        let message = if let Some(control_key) = Self::harmony_keycode_to_control_key(scancode) {
            format!(
                "send control key scancode={} control_key={} pressed={}",
                scancode,
                control_key.value(),
                pressed
            )
        } else {
            format!(
                "send raw key scancode={} chr={} pressed={}",
                scancode,
                Self::harmony_keycode_to_chr(scancode),
                pressed
            )
        };
        crate::set_last_error(message.clone());
        eprintln!("[RustDesk-FFI] {}", message);
    }

    fn send_key_event_encrypted(
        crypto: &mut CryptoChannel,
        scancode: u32,
        pressed: bool,
    ) -> io::Result<()> {
        let Some(msg) = Self::build_key_message(scancode, pressed) else {
            return Ok(());
        };
        Self::log_key_message(scancode, pressed);
        Self::send_message_encrypted(crypto, &msg)
    }

    fn harmony_keycode_to_control_key(scancode: u32) -> Option<ControlKey> {
        match scancode {
            42 | 2055 => Some(ControlKey::Backspace),
            2071 => Some(ControlKey::Delete),
            2012 => Some(ControlKey::UpArrow),
            2013 => Some(ControlKey::DownArrow),
            2014 => Some(ControlKey::LeftArrow),
            2015 => Some(ControlKey::RightArrow),
            2049 => Some(ControlKey::Tab),
            2050 => Some(ControlKey::Space),
            2054 => Some(ControlKey::Return),
            2067 => Some(ControlKey::Apps),
            2068 => Some(ControlKey::PageUp),
            2069 => Some(ControlKey::PageDown),
            2070 => Some(ControlKey::Escape),
            2081 => Some(ControlKey::Home),
            2082 => Some(ControlKey::End),
            2079 => Some(ControlKey::Snapshot),
            2080 => Some(ControlKey::Pause),
            2083 => Some(ControlKey::Insert),
            2045 => Some(ControlKey::Alt),
            2046 => Some(ControlKey::RAlt),
            2047 => Some(ControlKey::Shift),
            2048 => Some(ControlKey::RShift),
            2072 => Some(ControlKey::Control),
            2073 => Some(ControlKey::RControl),
            2076 => Some(ControlKey::RWin),
            2077 => Some(ControlKey::RWin),
            2090 => Some(ControlKey::F1),
            2091 => Some(ControlKey::F2),
            2092 => Some(ControlKey::F3),
            2093 => Some(ControlKey::F4),
            2094 => Some(ControlKey::F5),
            2095 => Some(ControlKey::F6),
            2096 => Some(ControlKey::F7),
            2097 => Some(ControlKey::F8),
            2098 => Some(ControlKey::F9),
            2099 => Some(ControlKey::F10),
            2100 => Some(ControlKey::F11),
            2101 => Some(ControlKey::F12),
            2103 => Some(ControlKey::Numpad0),
            2104 => Some(ControlKey::Numpad1),
            2105 => Some(ControlKey::Numpad2),
            2106 => Some(ControlKey::Numpad3),
            2107 => Some(ControlKey::Numpad4),
            2108 => Some(ControlKey::Numpad5),
            2109 => Some(ControlKey::Numpad6),
            2110 => Some(ControlKey::Numpad7),
            2111 => Some(ControlKey::Numpad8),
            2112 => Some(ControlKey::Numpad9),
            2113 => Some(ControlKey::Divide),
            2114 => Some(ControlKey::Multiply),
            2115 => Some(ControlKey::Subtract),
            2116 => Some(ControlKey::Add),
            2117 => Some(ControlKey::Decimal),
            2119 => Some(ControlKey::NumpadEnter),
            2120 => Some(ControlKey::Equals),
            _ => None,
        }
    }

    fn harmony_keycode_to_chr(scancode: u32) -> u32 {
        match scancode {
            2017..=2042 => scancode - 2017 + 65,
            _ => scancode,
        }
    }

    fn is_modifier_control_key(key: ControlKey) -> bool {
        matches!(
            key,
            ControlKey::Alt
                | ControlKey::RAlt
                | ControlKey::Shift
                | ControlKey::RShift
                | ControlKey::Control
                | ControlKey::RControl
                | ControlKey::Meta
                | ControlKey::RWin
        )
    }

    fn build_text_message(text: &str) -> Option<Message> {
        if text.is_empty() {
            return None;
        }
        let mut key = KeyEvent::new();
        key.set_press(true);
        key.set_mode(KeyboardMode::Legacy);
        key.union = Some(KeyEvent_oneof_union::seq(text.to_string()));
        let mut msg = Message::new();
        msg.union = Some(Message_oneof_union::key_event(key));
        Some(msg)
    }

    fn send_text_event_encrypted(crypto: &mut CryptoChannel, text: &str) -> io::Result<()> {
        let Some(msg) = Self::build_text_message(text) else {
            return Ok(());
        };
        Self::send_message_encrypted(crypto, &msg)
    }

    fn send_mouse_event_encrypted(
        crypto: &mut CryptoChannel,
        x: i32,
        y: i32,
        mask: i32,
    ) -> io::Result<()> {
        let mut mouse = MouseEvent::new();
        mouse.set_x(x);
        mouse.set_y(y);
        mouse.set_mask(mask);
        let mut msg = Message::new();
        msg.union = Some(Message_oneof_union::mouse_event(mouse));
        Self::send_message_encrypted(crypto, &msg)
    }

    fn send_message_encrypted(crypto: &mut CryptoChannel, msg: &Message) -> io::Result<()> {
        let payload = msg
            .write_to_bytes()
            .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
        crypto.send(&payload)
    }

    fn video_frame_codec_preference(frame: &VideoFrame) -> i32 {
        match &frame.union {
            Some(VideoFrame_oneof_union::vp8s(_)) => 1,
            Some(VideoFrame_oneof_union::vp9s(_)) => 2,
            Some(VideoFrame_oneof_union::av1s(_)) => 3,
            Some(VideoFrame_oneof_union::h264s(_)) => 4,
            Some(VideoFrame_oneof_union::h265s(_)) => 5,
            _ => 0,
        }
    }

    fn video_frame_codec_name(frame: &VideoFrame) -> &'static str {
        match &frame.union {
            Some(VideoFrame_oneof_union::h264s(_)) => "H264",
            Some(VideoFrame_oneof_union::h265s(_)) => "H265",
            Some(VideoFrame_oneof_union::vp8s(_)) => "VP8",
            Some(VideoFrame_oneof_union::vp9s(_)) => "VP9",
            Some(VideoFrame_oneof_union::av1s(_)) => "AV1",
            _ => "unknown",
        }
    }

    fn video_frame_has_keyframe(frame: &VideoFrame) -> bool {
        let frames: Option<&EncodedVideoFrames> = match &frame.union {
            Some(VideoFrame_oneof_union::h264s(f)) => Some(f),
            Some(VideoFrame_oneof_union::h265s(f)) => Some(f),
            Some(VideoFrame_oneof_union::vp8s(f)) => Some(f),
            Some(VideoFrame_oneof_union::vp9s(f)) => Some(f),
            Some(VideoFrame_oneof_union::av1s(f)) => Some(f),
            _ => None,
        };
        frames.map_or(false, |f| f.get_frames().iter().any(|ef| ef.get_key()))
    }

    fn video_frame_subframe_count(frame: &VideoFrame) -> u64 {
        let frames: Option<&EncodedVideoFrames> = match &frame.union {
            Some(VideoFrame_oneof_union::h264s(f)) => Some(f),
            Some(VideoFrame_oneof_union::h265s(f)) => Some(f),
            Some(VideoFrame_oneof_union::vp8s(f)) => Some(f),
            Some(VideoFrame_oneof_union::vp9s(f)) => Some(f),
            Some(VideoFrame_oneof_union::av1s(f)) => Some(f),
            _ => None,
        };
        frames.map_or(0, |f| f.get_frames().len() as u64)
    }

    /// 发送输入事件 (通过加密通道)
    pub fn send_input(&mut self, msg_type: &str, payload: &[u8]) -> io::Result<()> {
        let crypto = self
            .crypto_channel
            .as_mut()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotConnected, "no crypto channel"))?;
        crypto.send(payload)
    }

    pub fn state(&self) -> &ConnState {
        &self.state
    }

    pub fn try_clone_stream(&self) -> io::Result<TcpStream> {
        let crypto = self
            .crypto_channel
            .as_ref()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotConnected, "no crypto channel"))?;
        crypto.stream().try_clone()
    }

    pub fn peer_display_size(&self) -> Option<(i32, i32)> {
        let info = self.session.peer_info()?;
        let displays = info.get_displays();
        if displays.is_empty() {
            return None;
        }

        let current = info.get_current_display();
        let by_index = if current >= 0 {
            displays.get(current as usize)
        } else {
            None
        };
        let display = by_index
            .or_else(|| {
                displays.iter().find(|display| {
                    display.get_online() && display.get_width() > 0 && display.get_height() > 0
                })
            })
            .or_else(|| {
                displays
                    .iter()
                    .find(|display| display.get_width() > 0 && display.get_height() > 0)
            })?;

        let width = display.get_width();
        let height = display.get_height();
        if width > 0 && height > 0 {
            Some((width, height))
        } else {
            None
        }
    }

    pub fn keypair(&self) -> &KeyPair {
        &self.keypair
    }
}

#[cfg(test)]
mod tests {
    use super::{
        should_refresh_for_video_starvation, ControlKey, KeyEvent_oneof_union, Message_oneof_union,
        RustDeskConnector,
    };
    use std::net::TcpListener;
    use std::thread;

    #[test]
    fn video_starvation_refreshes_when_audio_is_alive() {
        assert!(should_refresh_for_video_starvation(
            120,
            0,
            45,
            Some(3_000),
            None,
        ));
    }

    #[test]
    fn video_starvation_does_not_refresh_too_often() {
        assert!(!should_refresh_for_video_starvation(
            120,
            0,
            45,
            Some(3_000),
            Some(1_000),
        ));
    }

    #[test]
    fn video_starvation_ignores_normal_video_windows() {
        assert!(!should_refresh_for_video_starvation(
            120,
            1,
            45,
            Some(3_000),
            None,
        ));
    }

    #[test]
    fn ime_message_builders_keep_unicode_and_cursor_semantics() {
        let text = RustDeskConnector::build_text_message("\u{4e2d}\u{6587}\u{1f600}").unwrap();
        match text.union {
            Some(Message_oneof_union::key_event(key)) => match key.union {
                Some(KeyEvent_oneof_union::seq(seq)) => {
                    assert_eq!(seq, "\u{4e2d}\u{6587}\u{1f600}")
                }
                _ => panic!("text input must remain one seq key event"),
            },
            _ => panic!("text input must be a key event"),
        }

        let left_down = RustDeskConnector::build_key_message(2014, true).unwrap();
        match left_down.union {
            Some(Message_oneof_union::key_event(key)) => match key.union {
                Some(KeyEvent_oneof_union::control_key(key)) => {
                    assert_eq!(key, ControlKey::LeftArrow);
                }
                _ => panic!("left down must be a control key"),
            },
            _ => panic!("left down must be a key event"),
        }
        assert!(RustDeskConnector::build_key_message(2014, false).is_none());
    }

    #[test]
    fn ime_text_cursor_text_keeps_fifo_order() {
        let inbox = crate::control_inbox::ControlInbox::default();
        inbox.enqueue(crate::ControlMsg::Text {
            text: "\u{4e2d}\u{6587}\u{1f600}".to_string(),
        });
        inbox.enqueue(crate::ControlMsg::KeyEvent {
            scancode: 2014,
            pressed: true,
        });
        inbox.enqueue(crate::ControlMsg::KeyEvent {
            scancode: 2014,
            pressed: false,
        });
        inbox.enqueue(crate::ControlMsg::Text {
            text: "X".to_string(),
        });
        let mut batch = RustDeskConnector::next_control_batch(&inbox).into_iter();

        assert_eq!(
            RustDeskConnector::control_msg_kind(&batch.next().unwrap()),
            "text"
        );
        assert_eq!(
            RustDeskConnector::control_msg_kind(&batch.next().unwrap()),
            "key"
        );
        assert_eq!(
            RustDeskConnector::control_msg_kind(&batch.next().unwrap()),
            "key"
        );
        assert_eq!(
            RustDeskConnector::control_msg_kind(&batch.next().unwrap()),
            "text"
        );
    }

    #[test]
    fn control_batch_is_limited_before_the_next_receive_turn() {
        let inbox = crate::control_inbox::ControlInbox::default();
        for scancode in 0..9 {
            inbox.enqueue(crate::ControlMsg::KeyEvent {
                scancode,
                pressed: true,
            });
        }

        assert_eq!(
            RustDeskConnector::next_control_batch(&inbox).len(),
            crate::control_inbox::CONTROL_BATCH_LIMIT
        );
        assert_eq!(inbox.snapshot().reliable_depth, 1);
    }

    #[test]
    fn control_diagnostics_emit_every_five_seconds() {
        let start = std::time::Instant::now();
        assert!(!super::should_emit_control_diagnostics(
            start,
            start + std::time::Duration::from_secs(4)
        ));
        assert!(super::should_emit_control_diagnostics(
            start,
            start + std::time::Duration::from_secs(5)
        ));
    }

    #[test]
    fn direct_connect_resolves_hostname_before_peer_handshake() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener bind failed");
        let port = listener
            .local_addr()
            .expect("listener address missing")
            .port();
        let accept_thread = thread::spawn(move || {
            let _ = listener
                .accept()
                .expect("direct hostname connection was not accepted");
        });

        let error = RustDeskConnector::new()
            .connect_direct("localhost", port, "", 0, 1, false, false, 30)
            .expect_err("fake peer should fail after TCP connect, not during endpoint parsing");
        assert_ne!(
            error.kind(),
            std::io::ErrorKind::InvalidInput,
            "hostname should be resolved before the direct protocol is read"
        );
        accept_thread.join().expect("accept thread panicked");
    }
}
