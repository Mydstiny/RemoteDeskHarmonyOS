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
use crate::control_inbox::{
    CONTROL_BATCH_LIMIT, ControlInbox, PERMISSION_AUDIO, PERMISSION_BLOCK_INPUT,
    PERMISSION_CLIPBOARD, PERMISSION_FILE, PERMISSION_KEYBOARD, PERMISSION_PRIVACY_MODE,
    PERMISSION_RECORDING, PERMISSION_RESTART,
};
use crate::cursor_state::{
    CursorCacheMissReason, CursorIdResult, CursorState, CursorStreamUpdate,
};
use crate::net;
use crate::protocol::message_proto::{
    AudioFormat, AudioFrame, CaptureDisplays, Clipboard, ClipboardFormat, ControlKey, DisplayInfo,
    DisplayResolution, EncodedVideoFrames, FileAction, FileAction_oneof_union, FileEntry,
    FileResponse, FileResponse_oneof_union, FileTransferBlock, FileTransferDone,
    FileTransferReceiveRequest, FileTransferSendConfirmRequest, FileType, IdPk, KeyEvent,
    KeyEvent_oneof_union, KeyboardMode, Message, Message_oneof_union, Misc, Misc_oneof_union,
    MouseEvent, PeerInfo, PermissionInfo_Permission, PointerDeviceEvent, PublicKey, Resolution,
    SupportedResolutions, SwitchDisplay, TouchEvent, TouchPanEnd, TouchPanStart, TouchPanUpdate,
    TouchScaleUpdate, VideoFrame, VideoFrame_oneof_union,
};
use crate::protocol::rendezvous::RendezvousClient;
use crate::protocol::rendezvous_proto::ConnType as RendezvousConnType;
use crate::protocol::session::{AuthEventCallback, Session, VIDEO_ACK_REQUIRED};
use crate::protocol::wire;
use protobuf::{Message as ProtoMessage, ProtobufEnum};

use std::ffi::{c_char, c_void, CString};
use std::io;
use std::io::ErrorKind;
use std::net::TcpStream;
use std::os::raw::c_int;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const VIDEO_STARVATION_REFRESH_AFTER_MS: u128 = 2500;
const VIDEO_STARVATION_REFRESH_INTERVAL_MS: u128 = 2500;
const CONTROL_DIAGNOSTIC_INTERVAL: Duration = Duration::from_secs(5);
const SLOW_VIDEO_CALLBACK_WARN: Duration = Duration::from_millis(50);
const SLOW_VIDEO_ACK_WARN: Duration = Duration::from_millis(50);
const VP9_CODEC_PREFERENCE: i32 = 2;
const BACKPRESSURE_FPS: [u32; 4] = [60, 45, 30, 15];
// Full-resolution software VP9 needs useful headroom for the short bursts
// observed from the macOS encoder. Avoid the old 30 -> 15 cliff: each native
// pressure level makes one bounded step. Other codec/resolution paths retain
// their existing targets.
const VP9_BACKPRESSURE_FPS: [u32; 4] = [30, 26, 22, 18];
const VP9_PRESSURE_RECOVERY_HOLD_WINDOWS: u32 = 12;
const VP9_HIGH_RESOLUTION_PIXEL_THRESHOLD: u64 = 4_000_000;
const VP9_HIGH_RESOLUTION_FPS: u32 = 30;

#[derive(Default, Debug)]
struct PhysicalModifierState {
    held_scancodes: Vec<u32>,
}

impl PhysicalModifierState {
    fn modifier_group_for_scancode(scancode: u32) -> Option<ControlKey> {
        match scancode {
            2045 | 2046 => Some(ControlKey::Alt),
            2047 | 2048 => Some(ControlKey::Shift),
            2072 | 2073 => Some(ControlKey::Control),
            2076 | 2077 => Some(ControlKey::Meta),
            _ => None,
        }
    }

    fn modifier_group_for_control_key(key: ControlKey) -> Option<ControlKey> {
        match key {
            ControlKey::Alt | ControlKey::RAlt => Some(ControlKey::Alt),
            ControlKey::Shift | ControlKey::RShift => Some(ControlKey::Shift),
            ControlKey::Control | ControlKey::RControl => Some(ControlKey::Control),
            ControlKey::Meta | ControlKey::RWin => Some(ControlKey::Meta),
            _ => None,
        }
    }

    fn update(&mut self, scancode: u32, pressed: bool) {
        if Self::modifier_group_for_scancode(scancode).is_none() {
            return;
        }
        if pressed {
            if !self.held_scancodes.contains(&scancode) {
                self.held_scancodes.push(scancode);
            }
        } else {
            self.held_scancodes.retain(|held| *held != scancode);
        }
    }

    fn active_groups(&self) -> Vec<ControlKey> {
        let candidates = [
            (ControlKey::Alt, [2045, 2046]),
            (ControlKey::Shift, [2047, 2048]),
            (ControlKey::Control, [2072, 2073]),
            (ControlKey::Meta, [2076, 2077]),
        ];
        candidates
            .into_iter()
            .filter_map(|(group, scancodes)| {
                self.held_scancodes
                    .iter()
                    .any(|held| scancodes.contains(held))
                    .then_some(group)
            })
            .collect()
    }

    fn apply_to_key(&self, key: &mut KeyEvent, current: Option<ControlKey>) {
        let current_group = current.and_then(Self::modifier_group_for_control_key);
        for group in self.active_groups() {
            if Some(group) != current_group {
                key.modifiers.push(group.into());
            }
        }
    }
}

fn is_vp9_stream(preferred_codec: i32, active_codec: i32) -> bool {
    preferred_codec == VP9_CODEC_PREFERENCE || active_codec == VP9_CODEC_PREFERENCE
}

fn resolution_aware_fps_ceiling(
    active_codec: i32,
    width: i32,
    height: i32,
    configured_fps: u32,
) -> u32 {
    if active_codec != VP9_CODEC_PREFERENCE || width <= 0 || height <= 0 {
        return configured_fps;
    }
    let pixels = (width as u64).saturating_mul(height as u64);
    if pixels >= VP9_HIGH_RESOLUTION_PIXEL_THRESHOLD {
        configured_fps.min(VP9_HIGH_RESOLUTION_FPS)
    } else {
        configured_fps
    }
}

fn uses_bounded_vp9_pressure_targets(active_codec: i32, width: i32, height: i32) -> bool {
    if active_codec != VP9_CODEC_PREFERENCE || width <= 0 || height <= 0 {
        return false;
    }
    (width as u64).saturating_mul(height as u64) >= VP9_HIGH_RESOLUTION_PIXEL_THRESHOLD
}

fn pressure_target_fps(
    _preferred_codec: i32,
    active_codec: i32,
    configured_fps: u32,
    pressure_level: u32,
    bounded_vp9_pressure: bool,
) -> u32 {
    let targets = if bounded_vp9_pressure && active_codec == VP9_CODEC_PREFERENCE {
        VP9_BACKPRESSURE_FPS
    } else {
        BACKPRESSURE_FPS
    };
    configured_fps.min(targets[pressure_level.min(3) as usize])
}

fn advance_applied_pressure_level(
    preferred_codec: i32,
    active_codec: i32,
    applied_level: u32,
    requested_level: u32,
    recovery_windows: u32,
    bounded_vp9_pressure: bool,
) -> (u32, u32) {
    let applied = applied_level.min(3);
    let requested = requested_level.min(3);
    if requested >= applied {
        return (requested, 0);
    }
    // High-resolution VP9 pressure already has one native/session hysteresis
    // owner. Apply its recovery signal immediately instead of adding another
    // per-level 12-second Rust hold on top.
    if bounded_vp9_pressure {
        return (requested, 0);
    }
    if !is_vp9_stream(preferred_codec, active_codec) {
        return (requested, 0);
    }

    let next_windows = recovery_windows.saturating_add(1);
    if next_windows < VP9_PRESSURE_RECOVERY_HOLD_WINDOWS {
        return (applied, next_windows);
    }
    (applied.saturating_sub(1).max(requested), 0)
}

fn pressure_change_requires_refresh(preferred_codec: i32, active_codec: i32) -> bool {
    !is_vp9_stream(preferred_codec, active_codec)
}

fn changed_pressure_target_fps(
    preferred_codec: i32,
    active_codec: i32,
    configured_fps: u32,
    current_stream_fps: u32,
    pressure_level: u32,
    bounded_vp9_pressure: bool,
) -> Option<u32> {
    let target = pressure_target_fps(
        preferred_codec,
        active_codec,
        configured_fps,
        pressure_level,
        bounded_vp9_pressure,
    );
    (target != current_stream_fps).then_some(target)
}

fn should_emit_control_diagnostics(last_report: Instant, now: Instant) -> bool {
    now.duration_since(last_report) >= CONTROL_DIAGNOSTIC_INTERVAL
}

fn should_refresh_for_video_starvation(
    total_video: u64,
    window_video: u64,
    last_video_age_ms: Option<u128>,
    last_refresh_age_ms: Option<u128>,
) -> bool {
    if total_video == 0 || window_video > 0 {
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

fn permission_mask(permission: PermissionInfo_Permission) -> u32 {
    match permission {
        PermissionInfo_Permission::Keyboard => PERMISSION_KEYBOARD,
        PermissionInfo_Permission::Clipboard => PERMISSION_CLIPBOARD,
        PermissionInfo_Permission::Audio => PERMISSION_AUDIO,
        PermissionInfo_Permission::File => PERMISSION_FILE,
        PermissionInfo_Permission::Restart => PERMISSION_RESTART,
        PermissionInfo_Permission::Recording => PERMISSION_RECORDING,
        PermissionInfo_Permission::BlockInput => PERMISSION_BLOCK_INPUT,
        PermissionInfo_Permission::PrivacyMode => PERMISSION_PRIVACY_MODE,
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

/// Progress emitted while the synchronous RustDesk handshake is running.
/// The FFI entry point executes this work on a native worker thread, so the
/// callback is deliberately small and carries only a short, owned C string
/// valid for the duration of the call.
pub type ConnectProgressCallback =
    extern "C" fn(stage: c_int, message: *const c_char, user_data: *mut c_void);

/// RustDesk `-k` is an access credential, not necessarily the server signing
/// public key.  Keeping both values separate lets an administrator use an
/// arbitrary shared value without pretending that it verifies identities.
struct RendezvousCredentials<'a> {
    access_key: &'a str,
    server_public_key: Option<&'a str>,
}

impl<'a> RendezvousCredentials<'a> {
    fn new(access_key: &'a str, shared_access_key: bool) -> Self {
        Self {
            access_key,
            server_public_key: if shared_access_key { None } else { Some(access_key) },
        }
    }
}

/// 完整连接上下文
pub struct RustDeskConnector {
    state: ConnState,
    keypair: KeyPair,
    peer_pk: Option<[u8; 32]>,
    crypto_channel: Option<CryptoChannel>,
    session: Session,
    progress_callback: Option<(ConnectProgressCallback, usize)>,
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

fn file_upload_sender_complete(pending_uploads: usize) -> bool {
    pending_uploads == 0
}

/// Keep the wire keyboard mode tied to the negotiated peer capabilities instead
/// of inferring it again for every key.  Map mode is required for physical
/// keyboard input to reach Windows/macOS IMEs as real keys.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RemoteKeyboardTransport {
    Legacy,
    MacosMap,
    WindowsMap,
}

impl RustDeskConnector {
    pub fn new() -> Self {
        let connect_epoch = crate::current_connect_epoch();
        Self::new_with_connection_id(0, connect_epoch)
    }

    pub fn new_with_connection_id(connection_id: u64, connect_epoch: u64) -> Self {
        Self {
            state: ConnState::Disconnected,
            keypair: crypto::generate_keypair(),
            peer_pk: None,
            crypto_channel: None,
            session: Session::new_with_connection_id(connection_id, connect_epoch),
            progress_callback: None,
            stream_stats: String::new(),
        }
    }

    pub fn set_progress_callback(
        &mut self,
        callback: Option<ConnectProgressCallback>,
        user_data: *mut std::ffi::c_void,
    ) {
        self.progress_callback = callback.map(|cb| (cb, user_data as usize));
    }

    fn set_connect_state(&mut self, state: ConnState) {
        let (stage, message) = match &state {
            ConnState::RendezvousConnecting => (0, "RustDesk: 正在连接协调服务器"),
            ConnState::RegisteringPeer => (0, "RustDesk: 正在登记远端身份"),
            ConnState::RegisteringPk => (0, "RustDesk: 正在交换服务器密钥"),
            ConnState::RequestingRelay => (1, "RustDesk: 正在请求中继路径"),
            ConnState::ConnectingToPeer => (2, "RustDesk: 正在连接远端设备"),
            ConnState::KeyExchanging => (3, "RustDesk: 正在建立加密通道"),
            ConnState::LoggingIn => (4, "RustDesk: 正在验证设备凭据"),
            ConnState::Connected => (5, "RustDesk: 认证完成，正在等待首帧"),
            ConnState::Disconnected | ConnState::Error(_) => (-1, ""),
        };
        self.state = state;
        if stage < 0 {
            return;
        }
        if let Some((callback, user_data)) = self.progress_callback {
            let c_message = CString::new(message).unwrap_or_else(|_| CString::new("").unwrap());
            callback(stage, c_message.as_ptr(), user_data as *mut std::ffi::c_void);
        }
    }

    pub fn set_auth_callback(
        &mut self,
        callback: Option<AuthEventCallback>,
        user_data: *mut std::ffi::c_void,
    ) {
        self.session.set_auth_callback(callback, user_data);
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
        relay_fallback_port: u16,
        server_key: &str,
        api_token: &str,
        peer_id: &str,
        password: &str,
        preferred_codec: i32,
        image_quality: i32,
        privacy_mode: bool,
        audio_enabled: bool,
        fps: u32,
        request_approval: bool,
        shared_access_key: bool,
    ) -> io::Result<()> {
        let credentials = RendezvousCredentials::new(server_key, shared_access_key);
        let rendezvous_secure = !shared_access_key && !server_key.trim().is_empty() &&
            !api_token.trim().is_empty();
        // === Phase 1: Rendezvous 握手 ===
        self.set_connect_state(ConnState::RendezvousConnecting);
        let mut rd = RendezvousClient::new();
        // 客户端连接远端 ID 时不要 RegisterPeer；RegisterPeer 是被控端注册自己的 ID。
        // Server Pro 的控制端会话 token 必须进入 PunchHoleRequest/RequestRelay。
        // 只有同时拥有真实公钥和 token 时才启用 upstream 的 rendezvous secure_tcp。
        rd.connect(rendezvous_host, rendezvous_port, server_key, rendezvous_secure)?;

        self.set_connect_state(ConnState::RequestingRelay);
        let punch = rd.request_force_relay(
            peer_id,
            credentials.access_key,
            api_token,
            RendezvousConnType::DEFAULT_CONN,
        )?;

        // === Phase 2: Peer TCP + 加密通道 ===
        eprintln!(
            "[RustDesk-FFI] force-relay response peer_endpoint={} relay_endpoint={} relay_ticket={} signed_pk_len={}",
            if punch.peer_addr.is_some() { "present" } else { "absent" },
            if punch.relay_server.is_empty() { "absent" } else { "present" },
            if punch.relay_uuid.is_some() { "present" } else { "absent" },
            punch.signed_pk.len()
        );

        let mut peer_stream = if let Some(relay_uuid) = punch.relay_uuid {
            self.set_connect_state(ConnState::ConnectingToPeer);
            eprintln!(
                "[RustDesk-FFI] force-relay ticket accepted relay_endpoint=present"
            );
            rd.create_relay(
                peer_id,
                &relay_uuid,
                &punch.relay_server,
                relay_fallback_port,
                credentials.access_key,
                RendezvousConnType::DEFAULT_CONN,
            )?
        } else if !punch.relay_server.trim().is_empty() {
            self.set_connect_state(ConnState::RequestingRelay);
            let mut relay_rd = RendezvousClient::new();
            relay_rd.connect(rendezvous_host, rendezvous_port, server_key, rendezvous_secure)?;
            let relay_uuid = relay_rd.request_relay_uuid(
                peer_id,
                &punch.relay_server,
                !punch.signed_pk.is_empty(),
                api_token,
            )?;
            self.set_connect_state(ConnState::ConnectingToPeer);
            eprintln!(
                "[RustDesk-FFI] force-relay request approved relay_endpoint=present"
            );
            relay_rd.create_relay(
                peer_id,
                &relay_uuid,
                &punch.relay_server,
                relay_fallback_port,
                credentials.access_key,
                RendezvousConnType::DEFAULT_CONN,
            )?
        } else if let Some(peer_addr) = punch.peer_addr {
            // OSS hbbs answered a direct peer address and no relay endpoint.
            // Connect it directly instead of failing the whole pipeline.
            self.set_connect_state(ConnState::ConnectingToPeer);
            eprintln!(
                "[RustDesk-FFI] punch response direct peer endpoint present"
            );
            rd.connect_to_peer(peer_addr)?
        } else {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "force-relay response did not include a relay endpoint",
            ));
        };

        // KeyExchange: 发送自己的公钥，接收对端公钥
        self.set_connect_state(ConnState::KeyExchanging);
        let channel_key = self.secure_peer_connection(
            &mut peer_stream,
            peer_id,
            &punch.signed_pk,
            credentials.server_public_key,
        )?;

        // An arbitrary hbbs/hbbr -k value authenticates only access.  This is
        // the official client compatibility fallback when no signing public
        // key is available: send the empty setup message then keep the peer
        // channel plain instead of fabricating a successful verification.
        let crypto = if let Some(key) = channel_key {
            CryptoChannel::new(peer_stream, &key, &key)
        } else {
            CryptoChannel::new_plain(peer_stream)
        };
        self.crypto_channel = Some(crypto);

        // === Phase 3: Login ===
        self.set_connect_state(ConnState::LoggingIn);
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

        self.set_connect_state(ConnState::Connected);
        Ok(())
    }

    /// 直连模式: TCP 直连 peer (跳过 rendezvous)
    ///
    /// peer_host: 对端 IP 地址
    /// peer_port: 对端 peer TCP 端口 (默认 21118)
    /// peer_id: 配置中的远程 ID（直连登录时由 peer_host 作为 LoginRequest.username）
    /// password: 远程主机密码
    ///
    /// 直连协议 (RustDesk 官方 LAN/direct listener):
    ///   TCP → 明文 Hash challenge → 明文 LoginRequest/LoginResponse → streaming
    ///
    /// 直连监听器不会走 rendezvous 的 SignedId/PublicKey 加密协商。之前把首包
    /// 当成 PublicKey 会在真实 RustDesk 被控端收到 Hash 后立即失败，因此这里
    /// 复用同一个帧通道和登录/流处理，只关闭 peer 加密层。
    pub fn connect_direct(
        &mut self,
        peer_host: &str,
        peer_port: u16,
        _peer_id: &str,
        password: &str,
        preferred_codec: i32,
        image_quality: i32,
        privacy_mode: bool,
        audio_enabled: bool,
        fps: u32,
    ) -> io::Result<()> {
        // === Phase 1: TCP 直连 peer ===
        self.set_connect_state(ConnState::ConnectingToPeer);
        eprintln!(
            "[RustDesk-FFI] direct connect endpoint=provided port={}",
            peer_port
        );
        let stream = net::connect_tcp_host(
            peer_host,
            peer_port,
            "direct",
            Duration::from_secs(10),
        )?;
        stream.set_read_timeout(Some(Duration::from_secs(30)))?;
        stream.set_write_timeout(Some(Duration::from_secs(10)))?;

        // === Phase 2: plain peer channel + login ===
        // The first frame is the Hash challenge sent by Connection::on_open;
        // Session::login_encrypted only describes the existing API name and
        // works with either encrypted or plain CryptoChannel frames.
        self.set_connect_state(ConnState::LoggingIn);
        let crypto = CryptoChannel::new_plain(stream);
        self.crypto_channel = Some(crypto);

        let crypto = self.crypto_channel.as_mut().unwrap();
        // RustDesk 官方 Direct IP 路径把用户输入的直连地址作为 peer
        // 标识发送给被控端；把地址簿里的远程 ID 放在这里会被真实
        // 被控端判定为错误的 direct login username。
        self.session.login_encrypted(
            crypto,
            peer_host,
            password,
            preferred_codec,
            image_quality,
            privacy_mode,
            audio_enabled,
            fps,
            false,
        )?;

        self.set_connect_state(ConnState::Connected);
        eprintln!("[RustDesk-FFI] direct plain connection established");
        Ok(())
    }

    /// Open the dedicated RustDesk file-transfer session against a peer's
    /// direct-IP listener. Direct sessions do not have a rendezvous server:
    /// the listener starts with the plain Hash/LoginRequest exchange and the
    /// LoginRequest.file_transfer field selects file-transfer mode.
    pub fn connect_file_transfer_direct(
        &mut self,
        peer_host: &str,
        peer_port: u16,
        password: &str,
        remote_dir: &str,
    ) -> io::Result<()> {
        crate::set_last_error(format!(
            "file-transfer direct connecting port={}",
            peer_port
        ));
        self.set_connect_state(ConnState::ConnectingToPeer);
        let peer_stream = net::connect_tcp_host(
            peer_host,
            peer_port,
            "direct file transfer",
            Duration::from_secs(10),
        )?;
        peer_stream.set_read_timeout(Some(Duration::from_secs(30)))?;
        peer_stream.set_write_timeout(Some(Duration::from_secs(10)))?;

        self.crypto_channel = Some(CryptoChannel::new_plain(peer_stream));
        crate::set_last_error("file-transfer direct peer login".to_string());
        self.set_connect_state(ConnState::LoggingIn);
        let crypto = self.crypto_channel.as_mut().ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotConnected,
                "direct file-transfer channel is unavailable",
            )
        })?;
        // RustDesk's direct listener expects its address as LoginRequest.username,
        // matching the main direct desktop connection.
        self.session
            .login_file_transfer_encrypted(crypto, peer_host, password, remote_dir, false)?;
        crate::set_last_error("file-transfer direct peer login complete".to_string());
        self.set_connect_state(ConnState::Connected);
        eprintln!("[RustDesk-FFI] direct file-transfer session established");
        Ok(())
    }

    pub fn connect_file_transfer(
        &mut self,
        rendezvous_host: &str,
        rendezvous_port: u16,
        relay_fallback_port: u16,
        server_key: &str,
        api_token: &str,
        peer_id: &str,
        password: &str,
        remote_dir: &str,
        request_approval: bool,
        shared_access_key: bool,
        rendezvous_conn_type: RendezvousConnType,
    ) -> io::Result<()> {
        let credentials = RendezvousCredentials::new(server_key, shared_access_key);
        let rendezvous_secure = !shared_access_key && !server_key.trim().is_empty() &&
            !api_token.trim().is_empty();
        crate::set_last_error(format!(
            "file-transfer rendezvous connecting port={} strategy=force_relay conn_type={:?}",
            rendezvous_port, rendezvous_conn_type
        ));
        self.set_connect_state(ConnState::RendezvousConnecting);
        let mut rd = RendezvousClient::new();
        rd.connect(rendezvous_host, rendezvous_port, server_key, rendezvous_secure)?;

        crate::set_last_error("file-transfer requesting force relay".to_string());
        self.set_connect_state(ConnState::RequestingRelay);
        let punch = rd.request_force_relay(
            peer_id,
            credentials.access_key,
            api_token,
            rendezvous_conn_type,
        )?;
        crate::set_last_error(format!(
            "file-transfer force-relay response relay_endpoint={} relay_ticket={} signed_pk_len={}",
            if punch.relay_server.is_empty() { "absent" } else { "present" },
            if punch.relay_uuid.is_some() { "present" } else { "absent" },
            punch.signed_pk.len()
        ));
        eprintln!(
            "[RustDesk-FFI] file-transfer force-relay response relay_endpoint={} relay_ticket={} signed_pk_len={}",
            if punch.relay_server.is_empty() { "absent" } else { "present" },
            if punch.relay_uuid.is_some() { "present" } else { "absent" },
            punch.signed_pk.len()
        );

        let mut peer_stream = if let Some(relay_uuid) = punch.relay_uuid {
            crate::set_last_error("file-transfer connecting approved relay".to_string());
            self.set_connect_state(ConnState::ConnectingToPeer);
            rd.create_relay(
                peer_id,
                &relay_uuid,
                &punch.relay_server,
                relay_fallback_port,
                credentials.access_key,
                rendezvous_conn_type,
            )?
        } else if !punch.relay_server.trim().is_empty() {
            self.set_connect_state(ConnState::RequestingRelay);
            let mut relay_rd = RendezvousClient::new();
            crate::set_last_error("file-transfer requesting relay ticket".to_string());
            relay_rd.connect(rendezvous_host, rendezvous_port, server_key, rendezvous_secure)?;
            let relay_uuid = relay_rd.request_relay_uuid(
                peer_id,
                &punch.relay_server,
                !punch.signed_pk.is_empty(),
                api_token,
            )?;
            crate::set_last_error("file-transfer connecting approved relay".to_string());
            self.set_connect_state(ConnState::ConnectingToPeer);
            relay_rd.create_relay(
                peer_id,
                &relay_uuid,
                &punch.relay_server,
                relay_fallback_port,
                credentials.access_key,
                rendezvous_conn_type,
            )?
        } else if let Some(peer_addr) = punch.peer_addr {
            self.set_connect_state(ConnState::ConnectingToPeer);
            eprintln!(
                "[RustDesk-FFI] file-transfer punch response direct peer endpoint present"
            );
            rd.connect_to_peer(peer_addr)?
        } else {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "file-transfer force-relay response did not include a relay endpoint",
            ));
        };

        crate::set_last_error("file-transfer key exchanging".to_string());
        self.set_connect_state(ConnState::KeyExchanging);
        let channel_key = self.secure_peer_connection(
            &mut peer_stream,
            peer_id,
            &punch.signed_pk,
            credentials.server_public_key,
        )?;
        let crypto = if let Some(key) = channel_key {
            CryptoChannel::new(peer_stream, &key, &key)
        } else {
            CryptoChannel::new_plain(peer_stream)
        };
        self.crypto_channel = Some(crypto);

        crate::set_last_error("file-transfer peer login".to_string());
        self.set_connect_state(ConnState::LoggingIn);
        let crypto = self.crypto_channel.as_mut().unwrap();
        self.session
            .login_file_transfer_encrypted(crypto, peer_id, password, remote_dir, request_approval)?;
        crate::set_last_error("file-transfer peer login complete".to_string());
        self.set_connect_state(ConnState::Connected);
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
        let path_id = crate::safe_diagnostics::sensitive_id(remote_path);

        // RustDesk's upload protocol is sender-complete once the final
        // FileResponse::Done frame has been written. The receiver consumes
        // that frame and reports completion to its own connection manager; it
        // does not echo another Done frame back to the sender. Waiting for
        // `awaiting_done` to become empty therefore turns every otherwise
        // successful upload into a 30-second timeout.
        while !file_upload_sender_complete(pending.len()) && started.elapsed() < timeout {
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
                        crate::set_last_error(format!(
                            "file-transfer waiting peer confirm path_id={} elapsed={}s pending={}",
                            path_id,
                            elapsed,
                            pending.len()
                        ));
                    }
                    continue;
                }
                Err(err) => return Err(err),
            }
        }
        crypto.set_read_timeout(None).ok();

        if file_upload_sender_complete(pending.len()) {
            crate::set_last_error(format!(
                "file transfer sent path_id={} final_done_frames={}",
                path_id,
                awaiting_done.len()
            ));
            Ok(())
        } else {
            Err(io::Error::new(
                io::ErrorKind::TimedOut,
                format!(
                    "file-transfer peer did not confirm upload pending={}",
                    pending.len()
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
        server_public_key: Option<&str>,
    ) -> io::Result<Option<[u8; 32]>> {
        let Some(sign_pk) = self.decode_signed_peer_pk(peer_id, signed_id_pk, server_public_key)? else {
            self.send_empty_message(stream)?;
            return Ok(None);
        };
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
        Ok(Some(key))
    }

    fn decode_signed_peer_pk(
        &self,
        peer_id: &str,
        signed_id_pk: &[u8],
        server_public_key: Option<&str>,
    ) -> io::Result<Option<[u8; 32]>> {
        let Some(server_key) = server_public_key else {
            return Ok(None);
        };
        if signed_id_pk.is_empty() {
            return Ok(None);
        }
        let supplied_key = crypto::normalized_server_public_key(server_key).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid rendezvous server public key; expected Base64-encoded 32-byte key",
            )
        })?;
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
        Ok(Some(pk))
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

    fn pump_control_messages(
        crypto: &mut CryptoChannel,
        controls: &ControlInbox,
        remote_upload_dir: Option<&str>,
        pending_file_uploads: &mut Vec<PendingFileUpload>,
        requested_pressure_level: &mut u32,
        physical_modifiers: &mut PhysicalModifierState,
        remote_keyboard_transport: RemoteKeyboardTransport,
        stream_started: Instant,
        sent_control_total: &mut u64,
        sent_mouse_moves: &mut u64,
        sent_mouse_buttons: &mut u64,
        control_send_errors: &mut u64,
    ) -> io::Result<()> {
        crypto.check_streaming_writer()?;
        if controls.shutdown_requested() {
            return Err(io::Error::new(
                ErrorKind::Interrupted,
                "control shutdown requested",
            ));
        }

        for control in Self::next_control_batch(controls) {
            if controls.shutdown_requested() {
                return Err(io::Error::new(
                    ErrorKind::Interrupted,
                    "control shutdown requested",
                ));
            }

            match control {
                crate::ControlMsg::Shutdown => {
                    return Err(io::Error::new(
                        ErrorKind::Interrupted,
                        "control shutdown requested",
                    ));
                }
                crate::ControlMsg::VideoPressure { level } => {
                    *requested_pressure_level = level.min(3);
                }
                crate::ControlMsg::SendFile { remote_path, data } => {
                    let upload_path = Self::normalize_remote_upload_path(
                        &remote_path,
                        remote_upload_dir,
                    );
                    let upload_path_id = crate::safe_diagnostics::sensitive_id(&upload_path);
                    let original_path_id = crate::safe_diagnostics::sensitive_id(&remote_path);
                    crate::set_last_error(format!(
                        "streaming: send file path_id={} size={}",
                        upload_path_id,
                        data.len()
                    ));
                    eprintln!(
                        "[RustDesk-FFI] streaming: send file path_id={} original_path_id={} size={}",
                        upload_path_id,
                        original_path_id,
                        data.len()
                    );
                    match Self::request_file_upload(crypto, &upload_path, data) {
                        Ok(upload) => pending_file_uploads.push(upload),
                        Err(e) => {
                            crate::set_last_error(format!(
                                "streaming: file send error path_id={} err={}",
                                upload_path_id, e
                            ));
                            eprintln!("[RustDesk-FFI] streaming: file send error: {}", e);
                        }
                    }
                }
                crate::ControlMsg::Clipboard { content } => {
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
                    let kind = Self::control_msg_kind(&msg);
                    let pointer = match &msg {
                        crate::ControlMsg::MouseEvent { x, y, .. }
                        | crate::ControlMsg::MouseMove { x, y }
                        | crate::ControlMsg::MouseWheel { x, y, .. }
                        | crate::ControlMsg::MouseWheel2D { x, y } => Some((*x, *y)),
                        _ => None,
                    };
                    *sent_control_total += 1;
                    let control_number = *sent_control_total;
                    if kind == "mouse_move" {
                        *sent_mouse_moves += 1;
                    } else if kind == "mouse" {
                        *sent_mouse_buttons += 1;
                    }
                    let pointer_sample = match kind {
                        "mouse_move" => *sent_mouse_moves <= 20 || *sent_mouse_moves % 120 == 0,
                        "mouse" => *sent_mouse_buttons <= 20 || *sent_mouse_buttons % 120 == 0,
                        _ => false,
                    };
                    let send_started = Instant::now();
                    let send_result = Self::send_control_message(
                        crypto,
                        msg,
                        physical_modifiers,
                        remote_keyboard_transport,
                    );
                    let send_elapsed = send_started.elapsed();
                    if pointer_sample || send_elapsed >= Duration::from_millis(20) {
                        let (x, y) = pointer.unwrap_or((0, 0));
                        eprintln!(
                            "[RustDesk-FFI] control send kind={} number={} x={} y={} dequeue_elapsed_ms={} send_elapsed_ms={} result={}",
                            kind,
                            control_number,
                            x,
                            y,
                            Instant::now().duration_since(stream_started).as_millis(),
                            send_elapsed.as_millis(),
                            if send_result.is_ok() { "ok" } else { "error" },
                        );
                    }
                    if let Err(e) = send_result {
                        *control_send_errors += 1;
                        eprintln!(
                            "[RustDesk-FFI] streaming: control msg error kind={:?} msg={}",
                            e.kind(),
                            e
                        );
                        return Err(e);
                    }
                }
            }
        }
        Ok(())
    }

    /// 运行 streaming 循环 (阻塞)
    ///
    /// 持续接收加密消息，分发到回调。
    pub fn run_streaming<VF, AFF, AF, CF, CU, DS>(
        &mut self,
        preferred_codec: i32,
        image_quality: i32,
        privacy_mode: bool,
        audio_enabled: bool,
        fps: u32,
        controls: Arc<ControlInbox>,
        stream_stats: Arc<Mutex<crate::RustDeskStreamStats>>,
        display_state: Arc<Mutex<crate::RustDeskDisplayState>>,
        mut on_video: VF,
        mut on_audio_format: AFF,
        mut on_audio: AF,
        mut on_clipboard: CF,
        mut on_cursor: CU,
        mut on_display_state: DS,
    ) -> io::Result<()>
    where
        VF: FnMut(&VideoFrame),
        AFF: FnMut(&AudioFormat),
        AF: FnMut(&AudioFrame),
        CF: FnMut(&[u8]),
        CU: FnMut(CursorStreamUpdate),
        DS: FnMut(),
    {
        let remote_keyboard_transport = self
            .session
            .peer_info()
            .map(|info| {
                Self::keyboard_transport_for_peer(info.get_platform(), info.get_version())
            })
            .unwrap_or(RemoteKeyboardTransport::Legacy);
        eprintln!(
            "[RustDesk-FFI] keyboard transport={:?}",
            remote_keyboard_transport
        );
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
        let mut last_cursor_position_at: Option<Instant> = None;
        let mut sent_control_total: u64 = 0;
        let mut sent_mouse_moves: u64 = 0;
        let mut sent_mouse_buttons: u64 = 0;
        let mut control_send_errors: u64 = 0;
        let mut last_msg_kind = "none";
        let mut cursor_state = CursorState::new();
        let mut physical_modifiers = PhysicalModifierState::default();
        let mut pending_file_uploads: Vec<PendingFileUpload> = Vec::new();
        let mut awaiting_file_done: Vec<AwaitingFileDone> = Vec::new();
        // T-131: Backpressure hysteresis state
        let mut consecutive_overload_windows: u32 = 0;
        let mut consecutive_clean_windows: u32 = 0;
        let mut current_backpressure_level: u32 = 0; // 0=normal, 1=mild, 2=moderate, 3=severe
        let mut requested_pressure_level: u32 = 0;
        let mut applied_pressure_level: u32 = 0;
        let mut vp9_pressure_recovery_windows: u32 = 0;
        let mut active_video_codec: i32 = 0;
        let mut bounded_vp9_pressure = false;
        let mut stream_fps_ceiling = fps;
        let mut stream_options_fps = fps;
        const DEGRADE_AFTER_OVERLOAD_WINDOWS: u32 = 5; // need 5s of overload before degrade
        const RECOVER_AFTER_CLEAN_WINDOWS: u32 = 30; // 30s of clean before recover
        const OVERLOAD_VIDEO_THRESHOLD: u64 = 3; // <3 fps sustained = genuine decoder overload
        if let Err(err) = Session::send_stream_options(
            crypto,
            preferred_codec,
            image_quality,
            privacy_mode,
            audio_enabled,
            fps,
        ) {
            eprintln!(
                "[RustDesk-FFI] streaming: initial stream options failed: {}, exiting",
                err
            );
            return Err(err);
        } else {
            stream_options_sent_count += 1;
            stream_options_reasserted = true;
            eprintln!("[RustDesk-FFI] streaming: initial stream options reasserted");
        }
        crypto.start_streaming_writer()?;
        eprintln!(
            "[RustDesk-FFI] streaming: single writer started after handshake video_ack_required={}",
            VIDEO_ACK_REQUIRED
        );

        'streaming: while self.state == ConnState::Connected {
            let diagnostic_now = Instant::now();
            if should_emit_control_diagnostics(last_control_diagnostic_at, diagnostic_now) {
                let snapshot = controls.snapshot();
                let cursor_position_count = msg_stats.get("cursor_position").copied().unwrap_or(0);
                let cursor_gap_ms = last_cursor_position_at
                    .map(|last| diagnostic_now.duration_since(last).as_millis())
                    .unwrap_or(0);
                eprintln!(
                    "[RustDesk-FFI] control diag reliable_depth={} max_reliable_depth={} coalesced_mouse={} coalesced_refresh={} coalesced_pressure={} coalesced_touch_scale={} coalesced_touch_pan={} touch_active={} touch_update_pending={} touch_barrier_wait={} batch_limit_hits={} receive_gap_ms={} sent_total={} sent_mouse_moves={} sent_mouse_buttons={} send_errors={} cursor_positions={} cursor_gap_ms={}",
                    snapshot.reliable_depth,
                    snapshot.max_reliable_depth,
                    snapshot.coalesced_mouse_moves,
                    snapshot.coalesced_refreshes,
                    snapshot.coalesced_video_pressure,
                    snapshot.coalesced_touch_scales,
                    snapshot.coalesced_touch_pan_updates,
                    snapshot.touch_active,
                    snapshot.touch_update_pending,
                    snapshot.touch_barrier_wait,
                    snapshot.batch_limit_hits,
                    diagnostic_now.duration_since(last_successful_receive_at).as_millis(),
                    sent_control_total,
                    sent_mouse_moves,
                    sent_mouse_buttons,
                    control_send_errors,
                    cursor_position_count,
                    cursor_gap_ms,
                );
                last_control_diagnostic_at = diagnostic_now;
            }

            if let Err(err) = Self::pump_control_messages(
                crypto,
                controls.as_ref(),
                remote_upload_dir.as_deref(),
                &mut pending_file_uploads,
                &mut requested_pressure_level,
                &mut physical_modifiers,
                remote_keyboard_transport,
                stream_started,
                &mut sent_control_total,
                &mut sent_mouse_moves,
                &mut sent_mouse_buttons,
                &mut control_send_errors,
            ) {
                if err.kind() == ErrorKind::Interrupted {
                    eprintln!("[RustDesk-FFI] streaming: shutdown requested, exiting loop");
                    self.state = ConnState::Disconnected;
                    break 'streaming;
                }
                return Err(err);
            }

            Self::flush_stale_file_uploads(
                crypto,
                &mut pending_file_uploads,
                &mut awaiting_file_done,
            )?;

            let plaintext = match crypto.recv_with_pump(|crypto| {
                Self::pump_control_messages(
                    crypto,
                    controls.as_ref(),
                    remote_upload_dir.as_deref(),
                    &mut pending_file_uploads,
                    &mut requested_pressure_level,
                    &mut physical_modifiers,
                    remote_keyboard_transport,
                    stream_started,
                    &mut sent_control_total,
                    &mut sent_mouse_moves,
                    &mut sent_mouse_buttons,
                    &mut control_send_errors,
                )
            }) {
                Ok(plaintext) => {
                    empty_reads = 0; // 重置空读计数
                    last_successful_receive_at = Instant::now();
                    plaintext
                }
                Err(err) if err.kind() == ErrorKind::Interrupted => {
                    eprintln!("[RustDesk-FFI] streaming: shutdown requested, exiting loop");
                    self.state = ConnState::Disconnected;
                    break 'streaming;
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
                        if let Err(err) = Session::send_refresh_video(crypto) {
                            eprintln!(
                                "[RustDesk-FFI] streaming: refresh_video failed: {}, exiting",
                                err
                            );
                            return Err(err);
                        }
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
                    let encoded_bytes = Self::video_frame_bytes(vf);
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
                            if let Ok(mut stats) = stream_stats.lock() {
                                stats.cadence_gaps = cadence_gap_count;
                                stats.max_cadence_gap_ms = max_cadence_gap_ms;
                            }
                        }
                    }
                    last_video_at = Some(now);
                    let actual_codec = Self::video_frame_codec_preference(vf);
                    let ffi_codec = Self::video_frame_ffi_codec(vf);
                    active_video_codec = actual_codec;
                    let (source_width, source_height) = display_state
                        .lock()
                        .map(|state| (state.width, state.height))
                        .unwrap_or((0, 0));
                    bounded_vp9_pressure = uses_bounded_vp9_pressure_targets(
                        active_video_codec,
                        source_width,
                        source_height,
                    );
                    let next_stream_fps_ceiling = resolution_aware_fps_ceiling(
                        active_video_codec,
                        source_width,
                        source_height,
                        fps,
                    );
                    if next_stream_fps_ceiling != stream_fps_ceiling {
                        stream_fps_ceiling = next_stream_fps_ceiling;
                        let target_fps = pressure_target_fps(
                            preferred_codec,
                            active_video_codec,
                            stream_fps_ceiling,
                            applied_pressure_level,
                            bounded_vp9_pressure,
                        );
                        eprintln!(
                            "[RustDesk-FFI] resolution fps ceiling codec={} size={}x{} configured={} ceiling={} target={}",
                            Self::video_frame_codec_name(vf),
                            source_width,
                            source_height,
                            fps,
                            stream_fps_ceiling,
                            target_fps,
                        );
                        if target_fps != stream_options_fps {
                            Session::send_runtime_options(
                                crypto,
                                preferred_codec,
                                image_quality,
                                privacy_mode,
                                audio_enabled,
                                Some(target_fps),
                            )?;
                            if pressure_change_requires_refresh(
                                preferred_codec,
                                active_video_codec,
                            ) {
                                Session::send_refresh_video(crypto)?;
                            }
                            stream_options_fps = target_fps;
                            stream_options_sent_count += 1;
                        }
                    }
                    if let Ok(mut stats) = stream_stats.lock() {
                        stats.video_messages = video_count;
                        stats.video_frames = encoded_subframe_total;
                        stats.keyframes = keyframe_count;
                        stats.encoded_bytes = stats.encoded_bytes.saturating_add(encoded_bytes);
                        // Keep the snapshot codec numbering identical to
                        // FfiVideoFrame: H264=0, H265=1, VP8=2, VP9=3, AV1=4.
                        // `actual_codec` above intentionally retains the
                        // protocol/profile numbering used by pressure control.
                        stats.actual_codec = ffi_codec;
                        stats.cadence_gaps = cadence_gap_count;
                        stats.max_cadence_gap_ms = max_cadence_gap_ms;
                    }
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

                    if VIDEO_ACK_REQUIRED {
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
                                "[RustDesk-FFI] streaming: video_received ack failed: {}, exiting",
                                err
                            );
                            return Err(err);
                        }
                        video_received_ack_count += 1;
                    }
                }
                Some(Message_oneof_union::audio_frame(ref af)) => {
                    last_msg_kind = "audio_frame";
                    *msg_stats.entry("audio_frame").or_default() += 1;
                    audio_count += 1;
                    window_audio += 1;
                    if let Ok(mut stats) = stream_stats.lock() {
                        stats.audio_frames = audio_count;
                    }
                    on_audio(af);
                    if audio_count == 1 {
                        eprintln!("[RustDesk-FFI] audio detected — async worker active");
                    }
                }
                Some(Message_oneof_union::test_delay(test_delay)) => {
                    last_msg_kind = "test_delay";
                    test_delay_echo_count += 1;
                    let last_delay_ms = test_delay.get_last_delay();
                    let target_bitrate_kbps = test_delay.get_target_bitrate();
                    if let Ok(mut stats) = stream_stats.lock() {
                        stats.last_delay_ms = last_delay_ms;
                        stats.target_bitrate_kbps = target_bitrate_kbps;
                        stats.test_delay_count = test_delay_echo_count;
                    }
                    let count = msg_stats.entry("test_delay").or_default();
                    *count += 1;
                    eprintln!(
                        "[RustDesk-FFI] streaming: test_delay #{} elapsed_ms={} last_delay_ms={} target_bitrate_kbps={} video={}",
                        *count,
                        Instant::now().duration_since(stream_started).as_millis(),
                        last_delay_ms,
                        target_bitrate_kbps,
                        video_count
                    );

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
                        Some(Misc_oneof_union::switch_display(_)) => "misc/switch_display",
                        Some(Misc_oneof_union::capture_displays(_)) => "misc/capture_displays",
                        Some(Misc_oneof_union::refresh_video_display(_)) => {
                            "misc/refresh_video_display"
                        }
                        Some(Misc_oneof_union::permission_info(_)) => "misc/permission_info",
                        Some(Misc_oneof_union::follow_current_display(_)) => {
                            "misc/follow_current_display"
                        }
                        _ => "misc/other",
                    };
                    last_msg_kind = misc_key;
                    *msg_stats.entry(misc_key).or_default() += 1;
                    if let Some(Misc_oneof_union::audio_format(ref format)) = misc.union {
                        on_audio_format(format);
                    }
                    if let Some(Misc_oneof_union::switch_display(ref display)) = misc.union {
                        Self::apply_switch_display_geometry(&display_state, display, &stream_stats);
                        on_display_state();
                    }
                    if let Some(Misc_oneof_union::permission_info(ref permission)) = misc.union {
                        let permission_kind = permission.get_permission();
                        let enabled = permission.get_enabled();
                        controls.update_permission(permission_mask(permission_kind), enabled);
                        eprintln!(
                            "[RustDesk-FFI] remote permission {:?} enabled={}",
                            permission_kind, enabled
                        );
                    }
                    if let Some(Misc_oneof_union::follow_current_display(display)) = misc.union {
                        Self::apply_follow_current_display(
                            &display_state,
                            display,
                            &stream_stats,
                        );
                        on_display_state();
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
                Some(Message_oneof_union::cursor_position(position)) => {
                    last_msg_kind = "cursor_position";
                    *msg_stats.entry("cursor_position").or_default() += 1;
                    last_cursor_position_at = Some(Instant::now());
                    if cursor_state.apply_position(position.get_x(), position.get_y()) {
                        on_cursor(CursorStreamUpdate::Position {
                            x: position.get_x(),
                            y: position.get_y(),
                        });
                    }
                }
                Some(Message_oneof_union::cursor_data(data)) => {
                    last_msg_kind = "cursor_data";
                    *msg_stats.entry("cursor_data").or_default() += 1;
                    let cursor_id = data.get_id();
                    let cursor_width = data.get_width();
                    let cursor_height = data.get_height();
                    let cursor_hot_x = data.get_hotx();
                    let cursor_hot_y = data.get_hoty();
                    if cursor_state.apply_data(data) {
                        if let Some(shape) = cursor_state.current_shape().cloned() {
                            on_cursor(CursorStreamUpdate::Shape(shape));
                            on_cursor(CursorStreamUpdate::Visibility(true));
                        } else {
                            eprintln!(
                                "[RustDesk-FFI] cursor data cached id={} size={}x{} hot={},{} waiting_for_cursor_id",
                                cursor_id,
                                cursor_width,
                                cursor_height,
                                cursor_hot_x,
                                cursor_hot_y,
                            );
                        }
                    } else {
                        eprintln!(
                            "[RustDesk-FFI] cursor data rejected id={} size={}x{} hot={},{}",
                            cursor_id,
                            cursor_width,
                            cursor_height,
                            cursor_hot_x,
                            cursor_hot_y,
                        );
                    }
                }
                Some(Message_oneof_union::cursor_id(id)) => {
                    last_msg_kind = "cursor_id";
                    *msg_stats.entry("cursor_id").or_default() += 1;
                    match cursor_state.apply_id(id) {
                        CursorIdResult::Selected(shape) => {
                            on_cursor(CursorStreamUpdate::Shape(shape));
                            on_cursor(CursorStreamUpdate::Visibility(true));
                        }
                        CursorIdResult::CacheMiss { id, reason } => {
                            eprintln!(
                                "[RustDesk-FFI] cursor id pending id={} cache_miss=true reason={:?} preserve_previous=true",
                                id,
                                reason,
                            );
                            if reason == CursorCacheMissReason::BudgetEvicted {
                                eprintln!(
                                    "[RustDesk-FFI] cursor cache exhausted id={} recovery=protocol_data_required",
                                    id,
                                );
                            }
                            // Keep the current shape and visibility.  The
                            // next CursorData for this id will select and
                            // publish the real bitmap.
                            on_cursor(CursorStreamUpdate::CacheMiss { id, reason });
                        }
                    }
                }
                Some(Message_oneof_union::peer_info(ref info)) => {
                    last_msg_kind = "peer_info";
                    *msg_stats.entry("peer_info").or_default() += 1;
                    self.session.update_peer_info(info.clone());
                    Self::apply_peer_info_geometry(&display_state, info, &stream_stats);
                    on_display_state();
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
                let (next_applied_pressure_level, next_recovery_windows) =
                    advance_applied_pressure_level(
                        preferred_codec,
                        active_video_codec,
                        applied_pressure_level,
                        requested_pressure_level,
                        vp9_pressure_recovery_windows,
                        bounded_vp9_pressure,
                    );
                vp9_pressure_recovery_windows = next_recovery_windows;
                if next_applied_pressure_level != applied_pressure_level {
                    applied_pressure_level = next_applied_pressure_level;
                    current_backpressure_level = applied_pressure_level;
                    consecutive_overload_windows = 0;
                    consecutive_clean_windows = 0;
                    let target_fps = pressure_target_fps(
                        preferred_codec,
                        active_video_codec,
                        stream_fps_ceiling,
                        applied_pressure_level,
                        bounded_vp9_pressure,
                    );
                    eprintln!(
                        "[RustDesk-FFI] LOCAL PRESSURE level={} fps={} quality={} total_video={} options_changed={}",
                        applied_pressure_level,
                        target_fps,
                        image_quality,
                        video_count,
                        target_fps != stream_options_fps,
                    );
                    if let Some(target_fps) = changed_pressure_target_fps(
                        preferred_codec,
                        active_video_codec,
                        stream_fps_ceiling,
                        stream_options_fps,
                        applied_pressure_level,
                        bounded_vp9_pressure,
                    ) {
                        Session::send_runtime_options(
                            crypto,
                            preferred_codec,
                            image_quality,
                            privacy_mode,
                            audio_enabled,
                            Some(target_fps),
                        )?;
                        if pressure_change_requires_refresh(preferred_codec, active_video_codec) {
                            Session::send_refresh_video(crypto)?;
                        }
                        stream_options_fps = target_fps;
                        stream_options_sent_count += 1;
                    }
                }
                // T-131: Backpressure hysteresis — video-only overload detection
                // Audio frames are NOT a decoder overload signal; they're independent.
                // Overload = sustained very low video throughput (< 3 fps) for 5+ seconds.
                // Native/session telemetry is the sole hysteresis owner for the
                // bounded high-resolution VP9 path. Preserve this legacy fallback
                // exactly for all other codec/resolution combinations.
                let use_legacy_backpressure = !bounded_vp9_pressure;
                let is_overload = use_legacy_backpressure
                    && requested_pressure_level > 0
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
                        let target_fps = pressure_target_fps(
                            preferred_codec,
                            active_video_codec,
                            stream_fps_ceiling,
                            current_backpressure_level,
                            bounded_vp9_pressure,
                        );
                        let quality = image_quality;
                        eprintln!(
                            "[RustDesk-FFI] BACKPRESSURE DEGRADE level={} fps={} quality={} window_video={} total_video={}",
                            current_backpressure_level, target_fps, quality, window_video, video_count
                        );
                        if let Some(target_fps) = changed_pressure_target_fps(
                            preferred_codec,
                            active_video_codec,
                            stream_fps_ceiling,
                            stream_options_fps,
                            current_backpressure_level,
                            bounded_vp9_pressure,
                        ) {
                            Session::send_runtime_options(
                                crypto,
                                preferred_codec,
                                quality,
                                privacy_mode,
                                audio_enabled,
                                Some(target_fps),
                            )?;
                            if pressure_change_requires_refresh(preferred_codec, active_video_codec)
                            {
                                Session::send_refresh_video(crypto)?;
                            }
                            stream_options_fps = target_fps;
                            stream_options_sent_count += 1;
                        }
                    }
                } else if use_legacy_backpressure {
                    consecutive_clean_windows += 1;
                    consecutive_overload_windows = 0;
                    if consecutive_clean_windows >= RECOVER_AFTER_CLEAN_WINDOWS
                        && current_backpressure_level > 0
                    {
                        current_backpressure_level -= 1;
                        consecutive_clean_windows = 0;
                        let target_fps = pressure_target_fps(
                            preferred_codec,
                            active_video_codec,
                            stream_fps_ceiling,
                            current_backpressure_level,
                            bounded_vp9_pressure,
                        );
                        let quality = image_quality;
                        eprintln!(
                            "[RustDesk-FFI] BACKPRESSURE RECOVER level={} fps={} quality={} total_video={}",
                            current_backpressure_level, target_fps, quality, video_count
                        );
                        if let Some(target_fps) = changed_pressure_target_fps(
                            preferred_codec,
                            active_video_codec,
                            stream_fps_ceiling,
                            stream_options_fps,
                            current_backpressure_level,
                            bounded_vp9_pressure,
                        ) {
                            Session::send_runtime_options(
                                crypto,
                                preferred_codec,
                                quality,
                                privacy_mode,
                                audio_enabled,
                                Some(target_fps),
                            )?;
                            stream_options_fps = target_fps;
                            stream_options_sent_count += 1;
                        }
                    }
                }
                let last_video_age_ms =
                    last_video_at.map(|at| now.duration_since(at).as_millis());
                let last_refresh_age_ms = last_video_starvation_refresh_at
                    .map(|at| now.duration_since(at).as_millis());
                if should_refresh_for_video_starvation(
                    video_count,
                    window_video,
                    last_video_age_ms,
                    last_refresh_age_ms,
                ) {
                    eprintln!(
                        "[RustDesk-FFI] VIDEO STARVATION video_window=0 audio_window={} total_video={} total_audio={} last_video_age={}ms -> refresh_video",
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
        if let Ok(mut stats) = stream_stats.lock() {
            stats.state = 0;
        }
        Ok(())
    }

    fn build_display_resolution_message(display: i32, width: i32, height: i32) -> Message {
        let mut resolution = Resolution::new();
        resolution.set_width(width);
        resolution.set_height(height);
        let mut change = DisplayResolution::new();
        change.set_display(display);
        change.set_resolution(resolution);
        let mut misc = Misc::new();
        misc.union = Some(Misc_oneof_union::change_display_resolution(change));
        let mut message = Message::new();
        message.union = Some(Message_oneof_union::misc(misc));
        message
    }

    fn build_switch_display_message(display: i32) -> Message {
        let mut switch_display = SwitchDisplay::new();
        switch_display.set_display(display);
        let mut misc = Misc::new();
        misc.union = Some(Misc_oneof_union::switch_display(switch_display));
        let mut message = Message::new();
        message.union = Some(Message_oneof_union::misc(misc));
        message
    }

    fn build_capture_displays_message(add: Vec<i32>, sub: Vec<i32>, set: Vec<i32>) -> Message {
        let mut capture = CaptureDisplays::new();
        capture.set_add(add);
        capture.set_sub(sub);
        capture.set_set(set);
        let mut misc = Misc::new();
        misc.union = Some(Misc_oneof_union::capture_displays(capture));
        let mut message = Message::new();
        message.union = Some(Message_oneof_union::misc(misc));
        message
    }

    fn build_refresh_video_display_message(display: i32) -> Message {
        let mut misc = Misc::new();
        misc.set_refresh_video_display(display);
        let mut message = Message::new();
        message.union = Some(Message_oneof_union::misc(misc));
        message
    }

    fn build_touch_scale_message(scale: i32) -> Message {
        let mut update = TouchScaleUpdate::new();
        update.set_scale(scale);
        let mut touch = TouchEvent::new();
        touch.set_scale_update(update);
        Self::build_touch_event_message(touch)
    }

    fn build_touch_pan_start_message(x: i32, y: i32) -> Message {
        let mut pan = TouchPanStart::new();
        pan.set_x(x);
        pan.set_y(y);
        let mut touch = TouchEvent::new();
        touch.set_pan_start(pan);
        Self::build_touch_event_message(touch)
    }

    fn build_touch_pan_update_message(x: i32, y: i32) -> Message {
        let mut pan = TouchPanUpdate::new();
        pan.set_x(x);
        pan.set_y(y);
        let mut touch = TouchEvent::new();
        touch.set_pan_update(pan);
        Self::build_touch_event_message(touch)
    }

    fn build_touch_pan_end_message(x: i32, y: i32) -> Message {
        let mut pan = TouchPanEnd::new();
        pan.set_x(x);
        pan.set_y(y);
        let mut touch = TouchEvent::new();
        touch.set_pan_end(pan);
        Self::build_touch_event_message(touch)
    }

    fn build_touch_event_message(touch: TouchEvent) -> Message {
        let mut pointer = PointerDeviceEvent::new();
        pointer.set_touch_event(touch);
        let mut message = Message::new();
        message.union = Some(Message_oneof_union::pointer_device_event(pointer));
        message
    }

    fn send_control_message(
        crypto: &mut CryptoChannel,
        control: crate::ControlMsg,
        physical_modifiers: &mut PhysicalModifierState,
        remote_keyboard_transport: RemoteKeyboardTransport,
    ) -> io::Result<()> {
        match control {
            crate::ControlMsg::Shutdown => Ok(()),
            crate::ControlMsg::RefreshVideo => {
                crate::set_last_error("send refresh video");
                Session::send_refresh_video(crypto)
            }
            crate::ControlMsg::SwitchDisplay { display } => {
                let message = Self::build_switch_display_message(display);
                Self::send_message_encrypted(crypto, &message)
            }
            crate::ControlMsg::DisplaySwitch {
                display,
                generation,
            } => {
                let switch = Self::build_switch_display_message(display);
                Self::send_message_encrypted(crypto, &switch)?;
                let capture =
                    Self::build_capture_displays_message(Vec::new(), Vec::new(), vec![display]);
                Self::send_message_encrypted(crypto, &capture)?;
                let refresh = Self::build_refresh_video_display_message(display);
                let result = Self::send_message_encrypted(crypto, &refresh);
                if result.is_ok() {
                    eprintln!(
                        "[RustDesk-FFI] display switch sent generation={} target={}",
                        generation, display
                    );
                }
                result
            }
            crate::ControlMsg::CaptureDisplays { add, sub, set } => {
                let message = Self::build_capture_displays_message(add, sub, set);
                Self::send_message_encrypted(crypto, &message)
            }
            crate::ControlMsg::RefreshVideoDisplay { display } => {
                let message = Self::build_refresh_video_display_message(display);
                Self::send_message_encrypted(crypto, &message)
            }
            crate::ControlMsg::VideoPressure { .. } => Ok(()),
            crate::ControlMsg::KeyEvent { scancode, pressed } => {
                Self::send_key_event_encrypted(
                    crypto,
                    scancode,
                    pressed,
                    physical_modifiers,
                    remote_keyboard_transport,
                )
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
                let messages = Self::build_mouse_button_messages(
                    x,
                    y,
                    button_mask,
                    pressed,
                    physical_modifiers,
                );
                for message in messages {
                    Self::send_message_encrypted(crypto, &message)?;
                }
                Ok(())
            }
            crate::ControlMsg::MouseMove { x, y } => {
                Self::send_mouse_event_encrypted(crypto, x, y, 0, physical_modifiers)
            }
            crate::ControlMsg::MouseWheel { x, y, delta } => {
                let _ = (x, y);
                crate::set_last_error(format!("send mouse wheel delta={}", delta));
                Self::send_mouse_event_encrypted(crypto, 0, delta, 3, physical_modifiers)
            }
            crate::ControlMsg::MouseWheel2D { x, y } => {
                crate::set_last_error(format!("send mouse wheel 2d x={} y={}", x, y));
                Self::send_mouse_event_encrypted(crypto, x, y, 3, physical_modifiers)
            }
            crate::ControlMsg::Text { text } => Self::send_text_event_encrypted(crypto, &text),
            crate::ControlMsg::ChangeDisplayResolution { display, width, height } => {
                let message = Self::build_display_resolution_message(display, width, height);
                Self::send_message_encrypted(crypto, &message)
            }
            crate::ControlMsg::TouchScale { scale } => {
                let message = Self::build_touch_scale_message(scale);
                Self::send_message_encrypted(crypto, &message)
            }
            crate::ControlMsg::TouchPanStart { x, y } => {
                let message = Self::build_touch_pan_start_message(x, y);
                Self::send_message_encrypted(crypto, &message)
            }
            crate::ControlMsg::TouchPanUpdate { x, y } => {
                let message = Self::build_touch_pan_update_message(x, y);
                Self::send_message_encrypted(crypto, &message)
            }
            crate::ControlMsg::TouchPanEnd { x, y } => {
                let message = Self::build_touch_pan_end_message(x, y);
                Self::send_message_encrypted(crypto, &message)
            }
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
            crate::ControlMsg::SwitchDisplay { .. } => "switch_display",
            crate::ControlMsg::DisplaySwitch { .. } => "display_switch",
            crate::ControlMsg::CaptureDisplays { .. } => "capture_displays",
            crate::ControlMsg::RefreshVideoDisplay { .. } => "refresh_video_display",
            crate::ControlMsg::VideoPressure { .. } => "video_pressure",
            crate::ControlMsg::KeyEvent { .. } => "key",
            crate::ControlMsg::MouseEvent { .. } => "mouse",
            crate::ControlMsg::MouseMove { .. } => "mouse_move",
            crate::ControlMsg::MouseWheel { .. } => "mouse_wheel",
            crate::ControlMsg::MouseWheel2D { .. } => "mouse_wheel_2d",
            crate::ControlMsg::Text { .. } => "text",
            crate::ControlMsg::SendFile { .. } => "send_file",
            crate::ControlMsg::Clipboard { .. } => "clipboard",
            crate::ControlMsg::ChangeDisplayResolution { .. } => "change_display_resolution",
            crate::ControlMsg::TouchScale { .. } => "touch_scale",
            crate::ControlMsg::TouchPanStart { .. } => "touch_pan_start",
            crate::ControlMsg::TouchPanUpdate { .. } => "touch_pan_update",
            crate::ControlMsg::TouchPanEnd { .. } => "touch_pan_end",
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

        let remote_dir_id = crate::safe_diagnostics::sensitive_id(remote_dir);
        let file_id = crate::safe_diagnostics::sensitive_id(file_name);
        eprintln!(
            "[RustDesk-FFI] file upload requested: dir_id={} file_id={} size={} id={}",
            remote_dir_id,
            file_id,
            data.len(),
            transfer_id
        );
        crate::set_last_error(format!(
            "file upload requested dir_id={} file_id={} size={} id={}",
            remote_dir_id,
            file_id,
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

        let remote_dir_id =
            crate::safe_diagnostics::sensitive_id(&upload.remote_dir);
        let file_id =
            crate::safe_diagnostics::sensitive_id(&upload.file_name);
        eprintln!(
            "[RustDesk-FFI] file upload data: reason={} dir_id={} file_id={} size={} chunks_sent={} chunks_total={} start_blk={} id={}",
            reason,
            remote_dir_id,
            file_id,
            upload.data.len(),
            sent_chunks,
            total_chunks,
            start_blk,
            upload.id
        );
        crate::set_last_error(format!(
            "file upload data reason={} file_id={} size={} chunks_sent={} chunks_total={} id={}",
            reason,
            file_id,
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
            Some(Message_oneof_union::cursor_id(_)) => "cursor_id",
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
                    let dir_id = crate::safe_diagnostics::sensitive_id(
                        &upload.remote_dir);
                    let file_id = crate::safe_diagnostics::sensitive_id(
                        &upload.file_name);
                    eprintln!(
                        "[RustDesk-FFI] file upload skipped by peer: dir_id={} file_id={} id={}",
                        dir_id, file_id, upload.id
                    );
                    crate::set_last_error(format!(
                        "file transfer error dir_id={} file_id={} err=skipped by peer",
                        dir_id, file_id
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
                let error_id =
                    crate::safe_diagnostics::sensitive_id(err.get_error());
                crate::set_last_error(format!(
                    "file transfer error id={} file_num={} error_id={}",
                    err.get_id(),
                    err.get_file_num(),
                    error_id
                ));
                eprintln!(
                    "[RustDesk-FFI] file transfer error: id={} file_num={} error_id={}",
                    err.get_id(),
                    err.get_file_num(),
                    error_id
                );
                return Err(io::Error::new(
                    io::ErrorKind::Other,
                    "remote file transfer rejected the upload",
                ));
            }
            Some(FileResponse_oneof_union::done(done)) => {
                if let Some(pos) = awaiting_done
                    .iter()
                    .position(|upload| upload.id == done.get_id())
                {
                    let completed = awaiting_done.remove(pos);
                    crate::set_last_error(format!(
                        "file transfer done id={} file_num={} file_id={}",
                        done.get_id(),
                        done.get_file_num(),
                        crate::safe_diagnostics::sensitive_id(&completed.file_name)
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

    fn build_key_message(
        scancode: u32,
        pressed: bool,
        physical_modifiers: &mut PhysicalModifierState,
    ) -> Option<Message> {
        let mut key = KeyEvent::new();
        key.set_mode(KeyboardMode::Legacy);
        physical_modifiers.update(scancode, pressed);
        let control_key = Self::harmony_keycode_to_control_key(scancode);
        if let Some(control_key) = control_key {
            key.set_down(pressed);
            key.union = Some(KeyEvent_oneof_union::control_key(control_key));
        } else {
            key.set_down(pressed);
            let chr_code = Self::harmony_keycode_to_chr(scancode);
            key.union = Some(KeyEvent_oneof_union::chr(chr_code));
        }
        physical_modifiers.apply_to_key(&mut key, control_key);
        let mut msg = Message::new();
        msg.union = Some(Message_oneof_union::key_event(key));
        Some(msg)
    }

    /// RustDesk Map mode carries a platform-native physical keycode in `chr`.
    /// It deliberately has no legacy modifier list: the remote receives the
    /// matching modifier key down/up events as it would from a local keyboard.
    fn build_map_key_message(keycode: u32, pressed: bool) -> Message {
        let mut key = KeyEvent::new();
        key.set_mode(KeyboardMode::Map);
        key.set_down(pressed);
        key.union = Some(KeyEvent_oneof_union::chr(keycode));
        let mut msg = Message::new();
        msg.union = Some(Message_oneof_union::key_event(key));
        msg
    }

    const MACOS_CAPS_LOCK_RAW_SCANCODE: u32 = 0x10039;
    const EXPLICIT_MACOS_MAP_FLAG: u32 = 0x20000;

    /// RustDesk's official client defaults to Map mode for supported desktop peers.
    /// macOS must receive physical virtual-key events for its active input source to
    /// compose text. Legacy `chr` events are handled by the server with
    /// `Enigo::key_sequence`, which inserts characters directly and bypasses the IME.
    fn build_macos_map_message(keycode: u32, pressed: bool) -> Message {
        Self::build_map_key_message(keycode, pressed)
    }

    fn explicit_macos_harmony_keycode(scancode: u32) -> Option<u32> {
        (scancode & Self::EXPLICIT_MACOS_MAP_FLAG != 0)
            .then_some(scancode & !Self::EXPLICIT_MACOS_MAP_FLAG)
    }

    fn build_explicit_macos_map_message(
        scancode: u32,
        pressed: bool,
        physical_modifiers: &mut PhysicalModifierState,
    ) -> Option<(Message, u32, u32)> {
        let harmony_keycode = Self::explicit_macos_harmony_keycode(scancode)?;
        let macos_keycode = Self::harmony_keycode_to_macos_keycode(harmony_keycode)?;
        physical_modifiers.update(harmony_keycode, pressed);
        Some((
            Self::build_macos_map_message(macos_keycode, pressed),
            harmony_keycode,
            macos_keycode,
        ))
    }

    /// Windows peers interpret Map-mode `chr` as a Windows Set-1 scan code.
    /// That path reaches the remote keyboard layout and IME instead of Windows'
    /// Unicode text injection path used by Legacy mode.
    fn build_windows_map_message(scancode: u32, pressed: bool) -> Message {
        Self::build_map_key_message(scancode, pressed)
    }

    /// HarmonyOS keyCode -> macOS ANSI virtual keycode (Carbon `kVK_*`).
    /// Values are physical positions, not characters, so the remote macOS input
    /// source receives and composes the keystrokes exactly like a local keyboard.
    fn harmony_keycode_to_macos_keycode(scancode: u32) -> Option<u32> {
        Some(match scancode {
            // Number row.
            2000 => 0x1D, 2001 => 0x12, 2002 => 0x13, 2003 => 0x14, 2004 => 0x15,
            2005 => 0x17, 2006 => 0x16, 2007 => 0x1A, 2008 => 0x1C, 2009 => 0x19,
            // Letters A-Z.
            2017 => 0x00, 2018 => 0x0B, 2019 => 0x08, 2020 => 0x02, 2021 => 0x0E,
            2022 => 0x03, 2023 => 0x05, 2024 => 0x04, 2025 => 0x22, 2026 => 0x26,
            2027 => 0x28, 2028 => 0x25, 2029 => 0x2E, 2030 => 0x2D, 2031 => 0x1F,
            2032 => 0x23, 2033 => 0x0C, 2034 => 0x0F, 2035 => 0x01, 2036 => 0x11,
            2037 => 0x20, 2038 => 0x09, 2039 => 0x0D, 2040 => 0x07, 2041 => 0x10,
            2042 => 0x06,
            // Punctuation and editing keys.
            2043 => 0x2B, 2044 => 0x2F, 2056 => 0x32, 2057 => 0x1B, 2058 => 0x18,
            2059 => 0x21, 2060 => 0x1E, 2061 => 0x2A, 2062 => 0x29, 2063 => 0x27,
            2064 => 0x2C, 2049 => 0x30, 2050 => 0x31, 2054 => 0x24,
            42 | 2055 => 0x33, 2070 => 0x35, 2071 => 0x75,
            // Modifiers. ArkTS swaps Ctrl/Meta for the selected macOS layout before FFI.
            2045 => 0x3A, 2046 => 0x3D, 2047 => 0x38, 2048 => 0x3C,
            2072 => 0x3B, 2073 => 0x3E, 2074 => 0x39, 2076 => 0x37, 2077 => 0x36,
            // Navigation and function keys.
            2012 => 0x7E, 2013 => 0x7D, 2014 => 0x7B, 2015 => 0x7C,
            2068 => 0x74, 2069 => 0x79, 2081 => 0x73, 2082 => 0x77,
            2090 => 0x7A, 2091 => 0x78, 2092 => 0x63, 2093 => 0x76,
            2094 => 0x60, 2095 => 0x61, 2096 => 0x62, 2097 => 0x64,
            2098 => 0x65, 2099 => 0x6D, 2100 => 0x67, 2101 => 0x6F,
            // Carbon defines physical virtual-key codes through F20. macOS
            // has no stable CGKeyCode constants for F21-F24, so the UI only
            // offers those four keys for Windows targets.
            2816 => 0x69, 2817 => 0x6B, 2818 => 0x71, 2819 => 0x6A,
            2820 => 0x40, 2821 => 0x4F, 2822 => 0x50, 2823 => 0x5A,
            _ => return None,
        })
    }

    /// HarmonyOS keyCode -> Windows Set-1 scan code, including the E0 prefix for
    /// extended keys. This is position based; shifted characters reuse the
    /// underlying physical key and let the remote Windows layout/IME decide text.
    fn harmony_keycode_to_windows_scancode(scancode: u32) -> Option<u32> {
        const NUMBER_ROW: [u32; 10] = [0x0B, 0x02, 0x03, 0x04, 0x05,
            0x06, 0x07, 0x08, 0x09, 0x0A];
        const LETTERS_A_TO_Z: [u32; 26] = [0x1E, 0x30, 0x2E, 0x20, 0x12, 0x21,
            0x22, 0x23, 0x17, 0x24, 0x25, 0x26, 0x32, 0x31, 0x18, 0x19,
            0x10, 0x13, 0x1F, 0x14, 0x16, 0x2F, 0x11, 0x2D, 0x15, 0x2C];
        const F1_TO_F12: [u32; 12] = [0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40,
            0x41, 0x42, 0x43, 0x44, 0x57, 0x58];

        if (2000..=2009).contains(&scancode) {
            return Some(NUMBER_ROW[(scancode - 2000) as usize]);
        }
        if (2017..=2042).contains(&scancode) {
            return Some(LETTERS_A_TO_Z[(scancode - 2017) as usize]);
        }
        if (2090..=2101).contains(&scancode) {
            return Some(F1_TO_F12[(scancode - 2090) as usize]);
        }
        // HarmonyOS reports F13-F24 in a separate continuous range.
        if (2816..=2827).contains(&scancode) {
            return Some(0x64 + scancode - 2816);
        }

        Some(match scancode {
            // Compatibility with desktop-style ASCII key events.
            48..=57 => NUMBER_ROW[(scancode - 48) as usize],
            65..=90 => LETTERS_A_TO_Z[(scancode - 65) as usize],

            42 | 2055 => 0x0E,       // Backspace
            2012 => 0xE048,          // Up
            2013 => 0xE050,          // Down
            2014 => 0xE04B,          // Left
            2015 => 0xE04D,          // Right
            2045 => 0x38,            // Left Alt
            2046 => 0xE038,          // Right Alt / AltGr
            2047 => 0x2A,            // Left Shift
            2048 => 0x36,            // Right Shift
            2049 => 0x0F,            // Tab
            2050 => 0x39,            // Space
            2054 => 0x1C,            // Enter
            2067 => 0xE05D,          // Apps/Menu
            2068 => 0xE049,          // Page Up
            2069 => 0xE051,          // Page Down
            2070 => 0x01,            // Escape
            2071 => 0xE053,          // Delete
            2072 => 0x1D,            // Left Ctrl
            2073 => 0xE01D,          // Right Ctrl
            2074 => 0x3A,            // Caps Lock
            2075 => 0x46,            // Scroll Lock
            2076 => 0xE05B,          // Left Win
            2077 => 0xE05C,          // Right Win
            2079 => 0xE037,          // Print Screen / SysRq
            // Pause/Break is not a normal scan-code down/up sequence on Windows.
            // It intentionally falls back to RustDesk's ControlKey::Pause path.
            2081 => 0xE047,          // Home
            2082 => 0xE04F,          // End
            2083 => 0xE052,          // Insert
            2102 => 0x45,            // Num Lock
            2103 => 0x52,            // Numpad 0
            2104 => 0x4F,            // Numpad 1
            2105 => 0x50,            // Numpad 2
            2106 => 0x51,            // Numpad 3
            2107 => 0x4B,            // Numpad 4
            2108 => 0x4C,            // Numpad 5
            2109 => 0x4D,            // Numpad 6
            2110 => 0x47,            // Numpad 7
            2111 => 0x48,            // Numpad 8
            2112 => 0x49,            // Numpad 9
            2113 => 0xE035,          // Numpad divide
            2114 => 0x37,            // Numpad multiply
            2115 => 0x4A,            // Numpad subtract
            2116 => 0x4E,            // Numpad add
            2117 => 0x53,            // Numpad decimal
            2119 => 0xE01C,          // Numpad enter
            2120 => 0x0D,            // Numpad equals

            2043 | 188 => 0x33,      // Comma
            2044 | 190 => 0x34,      // Period
            2056 | 192 => 0x29,      // Backtick
            2057 | 189 => 0x0C,      // Minus
            2058 | 187 => 0x0D,      // Equals
            2059 | 219 => 0x1A,      // Left bracket
            2060 | 221 => 0x1B,      // Right bracket
            2061 | 220 => 0x2B,      // Backslash
            2062 | 186 => 0x27,      // Semicolon
            2063 | 222 => 0x28,      // Apostrophe
            2064 | 191 => 0x35,      // Slash
            2065 => 0x03,            // @ shares the physical 2 key
            2066 => 0x0D,            // + shares the physical equals key
            _ => return None,
        })
    }

    fn parse_version_component(component: Option<&str>) -> u32 {
        component
            .unwrap_or_default()
            .chars()
            .take_while(|ch| ch.is_ascii_digit())
            .collect::<String>()
            .parse::<u32>()
            .unwrap_or(0)
    }

    fn peer_supports_map_mode(version: &str) -> bool {
        let normalized = version.trim_start_matches(|ch: char| ch == 'v' || ch == 'V');
        let mut components = normalized.split('.');
        let actual = (
            Self::parse_version_component(components.next()),
            Self::parse_version_component(components.next()),
            Self::parse_version_component(components.next()),
        );
        actual >= (1, 2, 0)
    }

    fn keyboard_transport_for_peer(platform: &str, version: &str) -> RemoteKeyboardTransport {
        let platform = platform.to_ascii_lowercase();
        if platform.contains("mac") {
            // Preserve the verified macOS physical-key/IME path. Existing macOS
            // connections already use Map mode and need no compatibility downgrade.
            return RemoteKeyboardTransport::MacosMap;
        }
        if platform.contains("windows") && Self::peer_supports_map_mode(version) {
            return RemoteKeyboardTransport::WindowsMap;
        }
        RemoteKeyboardTransport::Legacy
    }

    fn should_use_macos_caps_lock_map(
        scancode: u32,
        remote_keyboard_transport: RemoteKeyboardTransport,
    ) -> bool {
        scancode == Self::MACOS_CAPS_LOCK_RAW_SCANCODE ||
            (remote_keyboard_transport == RemoteKeyboardTransport::MacosMap && scancode == 2074)
    }

    pub(crate) fn next_control_batch(controls: &ControlInbox) -> Vec<crate::ControlMsg> {
        controls.take_batch(CONTROL_BATCH_LIMIT)
    }

    fn log_key_message(
        scancode: u32,
        pressed: bool,
        physical_modifiers: &PhysicalModifierState,
    ) {
        let modifiers = format!("{:?}", physical_modifiers.active_groups());
        let message = if let Some(control_key) = Self::harmony_keycode_to_control_key(scancode) {
            format!(
                "send control key scancode={} control_key={} pressed={} modifiers={}",
                scancode,
                control_key.value(),
                pressed,
                modifiers,
            )
        } else {
            format!(
                "send raw key scancode={} chr={} pressed={} modifiers={}",
                scancode,
                Self::harmony_keycode_to_chr(scancode),
                pressed,
                modifiers,
            )
        };
        crate::set_last_error(message.clone());
        eprintln!("[RustDesk-FFI] {}", message);
    }

    fn send_key_event_encrypted(
        crypto: &mut CryptoChannel,
        scancode: u32,
        pressed: bool,
        physical_modifiers: &mut PhysicalModifierState,
        remote_keyboard_transport: RemoteKeyboardTransport,
    ) -> io::Result<()> {
        if let Some((msg, harmony_keycode, macos_keycode)) =
            Self::build_explicit_macos_map_message(scancode, pressed, physical_modifiers)
        {
            let status = format!(
                "send explicit macos physical scancode={} pressed={} mode=map keycode=0x{:X}",
                harmony_keycode, pressed, macos_keycode,
            );
            crate::set_last_error(status.clone());
            eprintln!("[RustDesk-FFI] {}", status);
            return Self::send_message_encrypted(crypto, &msg);
        }
        // An explicitly marked but currently unsupported key falls back using
        // its original Harmony code, never the private marker value.
        let scancode = Self::explicit_macos_harmony_keycode(scancode).unwrap_or(scancode);
        if Self::should_use_macos_caps_lock_map(scancode, remote_keyboard_transport) {
            let msg = Self::build_macos_map_message(0x39, pressed);
            let status = format!(
                "send macos caps lock pressed={} mode=map keycode=0x39",
                pressed,
            );
            crate::set_last_error(status.clone());
            eprintln!("[RustDesk-FFI] {}", status);
            return Self::send_message_encrypted(crypto, &msg);
        }
        if remote_keyboard_transport == RemoteKeyboardTransport::WindowsMap {
            // Physical modifiers are still tracked so a later unsupported-key
            // Legacy fallback cannot lose an already-held Ctrl/Alt/Shift/Win.
            physical_modifiers.update(scancode, pressed);
            if scancode == 2080 {
                // Windows Pause/Break is an E1 sequence, not the NumLock scan
                // code. RustDesk's control-key implementation emits its native
                // Pause key, so retain that one exceptional non-text event.
                let Some(msg) = Self::build_key_message(scancode, pressed, physical_modifiers)
                else {
                    return Ok(());
                };
                Self::log_key_message(scancode, pressed, physical_modifiers);
                return Self::send_message_encrypted(crypto, &msg);
            }
            if let Some(keycode) = Self::harmony_keycode_to_windows_scancode(scancode) {
                let msg = Self::build_windows_map_message(keycode, pressed);
                let status = format!(
                    "send windows physical scancode={} pressed={} mode=map keycode=0x{:X}",
                    scancode, pressed, keycode,
                );
                crate::set_last_error(status.clone());
                eprintln!("[RustDesk-FFI] {}", status);
                return Self::send_message_encrypted(crypto, &msg);
            }
            eprintln!(
                "[RustDesk-FFI] windows map missing scancode={}, falling back to legacy",
                scancode
            );
        }
        if remote_keyboard_transport == RemoteKeyboardTransport::MacosMap {
            if let Some(keycode) = Self::harmony_keycode_to_macos_keycode(scancode) {
                physical_modifiers.update(scancode, pressed);
                let msg = Self::build_macos_map_message(keycode, pressed);
                let status = format!(
                    "send macos physical scancode={} pressed={} mode=map keycode=0x{:X}",
                    scancode, pressed, keycode,
                );
                crate::set_last_error(status.clone());
                eprintln!("[RustDesk-FFI] {}", status);
                return Self::send_message_encrypted(crypto, &msg);
            }
        }
        let Some(msg) = Self::build_key_message(scancode, pressed, physical_modifiers) else {
            return Ok(());
        };
        Self::log_key_message(scancode, pressed, physical_modifiers);
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
            2074 => Some(ControlKey::CapsLock),
            2075 => Some(ControlKey::Scroll),
            2076 => Some(ControlKey::Meta),
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
            2102 => Some(ControlKey::NumLock),
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
            2000..=2009 => scancode - 2000 + b'0' as u32,
            // RustDesk Legacy mode carries the physical letter key as a lowercase
            // layout character. Shift/Caps/Meta are expressed through modifiers.
            // macOS Enigo's fallback key map only accepts lowercase a-z; sending
            // uppercase ASCII here turns Command+C/V into an invalid virtual key.
            2017..=2042 => scancode - 2017 + b'a' as u32,
            2043 => b',' as u32,
            2044 => b'.' as u32,
            2056 => b'`' as u32,
            2057 => b'-' as u32,
            2058 => b'=' as u32,
            2059 => b'[' as u32,
            2060 => b']' as u32,
            2061 => b'\\' as u32,
            2062 => b';' as u32,
            2063 => b'\'' as u32,
            2064 => b'/' as u32,
            2065 => b'@' as u32,
            2066 => b'+' as u32,
            _ => scancode,
        }
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

    fn build_mouse_message(
        x: i32,
        y: i32,
        mask: i32,
        physical_modifiers: &PhysicalModifierState,
    ) -> Message {
        let mut mouse = MouseEvent::new();
        mouse.set_x(x);
        mouse.set_y(y);
        mouse.set_mask(mask);
        for modifier in physical_modifiers.active_groups() {
            mouse.modifiers.push(modifier.into());
        }
        let mut msg = Message::new();
        msg.union = Some(Message_oneof_union::mouse_event(mouse));
        msg
    }

    /// RustDesk's macOS server applies a button to the current cursor position
    /// and ignores coordinates carried by DOWN/UP. Match the official client:
    /// anchor the cursor immediately before DOWN, then send button messages at
    /// (0, 0). UP must not inject another MOVE while the button is held because
    /// macOS interprets that sequence as a drag, even when the coordinates are
    /// unchanged.
    fn build_mouse_button_messages(
        x: i32,
        y: i32,
        button_mask: i32,
        pressed: bool,
        physical_modifiers: &PhysicalModifierState,
    ) -> Vec<Message> {
        let event_type = if pressed { 1 } else { 2 };
        let mut messages = Vec::with_capacity(if pressed { 2 } else { 1 });
        if pressed {
            messages.push(Self::build_mouse_message(
                x,
                y,
                0,
                physical_modifiers,
            ));
        }
        messages.push(Self::build_mouse_message(
            0,
            0,
            (button_mask << 3) | event_type,
            physical_modifiers,
        ));
        messages
    }

    fn send_mouse_event_encrypted(
        crypto: &mut CryptoChannel,
        x: i32,
        y: i32,
        mask: i32,
        physical_modifiers: &PhysicalModifierState,
    ) -> io::Result<()> {
        let msg = Self::build_mouse_message(x, y, mask, physical_modifiers);
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

    fn video_frame_ffi_codec(frame: &VideoFrame) -> i32 {
        match &frame.union {
            Some(VideoFrame_oneof_union::h264s(_)) => 0,
            Some(VideoFrame_oneof_union::h265s(_)) => 1,
            Some(VideoFrame_oneof_union::vp8s(_)) => 2,
            Some(VideoFrame_oneof_union::vp9s(_)) => 3,
            Some(VideoFrame_oneof_union::av1s(_)) => 4,
            _ => -1,
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

    fn video_frame_bytes(frame: &VideoFrame) -> u64 {
        let frames: Option<&EncodedVideoFrames> = match &frame.union {
            Some(VideoFrame_oneof_union::h264s(f)) => Some(f),
            Some(VideoFrame_oneof_union::h265s(f)) => Some(f),
            Some(VideoFrame_oneof_union::vp8s(f)) => Some(f),
            Some(VideoFrame_oneof_union::vp9s(f)) => Some(f),
            Some(VideoFrame_oneof_union::av1s(f)) => Some(f),
            _ => None,
        };
        frames.map_or(0, |f| {
            f.get_frames()
                .iter()
                .map(|encoded| encoded.get_data().len() as u64)
                .sum()
        })
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

    fn collect_resolutions(supported: &SupportedResolutions) -> Vec<(i32, i32)> {
        supported
            .get_resolutions()
            .iter()
            .filter_map(|resolution| {
                let width = resolution.get_width();
                let height = resolution.get_height();
                if width > 0 && height > 0 { Some((width, height)) } else { None }
            })
            .take(crate::RUSTDESK_MAX_DISPLAY_RESOLUTIONS)
            .collect()
    }

    fn display_info_state(index: usize, display: &DisplayInfo) -> crate::RustDeskDisplayInfoState {
        let original = display.get_original_resolution();
        let scale = display.get_scale();
        crate::RustDeskDisplayInfoState {
            display: index as i32,
            x: display.get_x(),
            y: display.get_y(),
            width: display.get_width().max(0),
            height: display.get_height().max(0),
            name: display.get_name().to_string(),
            online: display.get_online(),
            cursor_embedded: display.get_cursor_embedded(),
            original_width: original.get_width().max(0),
            original_height: original.get_height().max(0),
            scale_milli: if scale.is_finite() && scale > 0.0 {
                (scale * 1000.0).round() as i32
            } else {
                1000
            },
            resolutions: Vec::new(),
        }
    }

    fn populate_display_state(
        state: &mut crate::RustDeskDisplayState,
        info: &PeerInfo,
    ) -> bool {
        let previous_displays = state.displays.clone();
        let previous_geometry = (
            state.current_display,
            state.width,
            state.height,
            state.original_width,
            state.original_height,
            state.scale_milli,
            state.resolutions.clone(),
        );
        let mut displays: Vec<crate::RustDeskDisplayInfoState> = info
            .get_displays()
            .iter()
            .take(crate::RUSTDESK_MAX_DISPLAYS)
            .enumerate()
            .map(|(index, display)| Self::display_info_state(index, display))
            .collect();

        // PeerInfo exposes one resolution list for the current display. Keep
        // lists learned from SwitchDisplay for the other entries.
        for display in &mut displays {
            if let Some(previous) = previous_displays
                .iter()
                .find(|previous| previous.display == display.display)
            {
                display.resolutions = previous.resolutions.clone();
            }
        }

        let peer_current = info.get_current_display();
        let current_resolutions = Self::collect_resolutions(info.get_resolutions());
        if let Some(display) = displays
            .iter_mut()
            .find(|display| display.display == peer_current)
        {
            if !current_resolutions.is_empty() {
                display.resolutions = current_resolutions;
            }
        }
        let desired_online = state.desired_display.filter(|desired| {
            displays
                .iter()
                .any(|display| display.display == *desired && display.online)
        });
        if desired_online.is_none()
            && state.desired_display.is_some()
            && state.pending_switch_generation.is_none()
        {
            // Once a confirmed target leaves the online catalog, the peer's
            // first online monitor becomes authoritative again. A still
            // pending local target remains fenced until the user retries.
            state.desired_display = None;
        }
        let current_index = desired_online
            .or_else(|| {
                displays
                    .iter()
                    .find(|display| display.display == peer_current && display.online)
                    .map(|display| display.display)
            })
            .or_else(|| {
                displays
                    .iter()
                    .find(|display| display.online)
                    .map(|display| display.display)
            })
            .or_else(|| displays.first().map(|display| display.display))
            .unwrap_or(0);

        state.current_display = current_index;
        state.displays = displays;
        if let Some(display) = state
            .displays
            .iter()
            .find(|display| display.display == current_index)
        {
            state.width = display.width;
            state.height = display.height;
            state.original_width = display.original_width;
            state.original_height = display.original_height;
            state.scale_milli = display.scale_milli;
            state.resolutions = display.resolutions.clone();
        } else {
            // A peer-info refresh without display entries must not leave the
            // previous monitor's geometry or resolution list visible.
            state.current_display = 0;
            state.width = 0;
            state.height = 0;
            state.original_width = 0;
            state.original_height = 0;
            state.scale_milli = 1000;
            state.resolutions.clear();
        }

        previous_geometry
            != (
                state.current_display,
                state.width,
                state.height,
                state.original_width,
                state.original_height,
                state.scale_milli,
                state.resolutions.clone(),
            )
            || previous_displays != state.displays
    }

    fn apply_peer_info_geometry(
        display_state: &Arc<Mutex<crate::RustDeskDisplayState>>,
        info: &PeerInfo,
        stream_stats: &Arc<Mutex<crate::RustDeskStreamStats>>,
    ) {
        let Ok(mut state) = display_state.lock() else {
            return;
        };
        let changed = Self::populate_display_state(&mut state, info);
        if changed || state.geometry_epoch == 0 {
            state.geometry_epoch = state.geometry_epoch.wrapping_add(1).max(1);
        }
        if let Ok(mut stats) = stream_stats.lock() {
            stats.width = state.width;
            stats.height = state.height;
        }
        eprintln!(
            "[RustDesk-FFI] peer display catalog displays={} current={} size={}x{} epoch={}",
            state.displays.len(),
            state.current_display,
            state.width,
            state.height,
            state.geometry_epoch
        );
    }

    pub fn peer_display_state(&self) -> crate::RustDeskDisplayState {
        let mut state = crate::RustDeskDisplayState::default();
        if let Some(info) = self.session.peer_info() {
            Self::populate_display_state(&mut state, info);
            state.geometry_epoch = 1;
        }
        state
    }

    fn sync_active_display(state: &mut crate::RustDeskDisplayState, display: i32) -> bool {
        let Some(info) = state
            .displays
            .iter()
            .find(|info| info.display == display)
            .cloned()
        else {
            return false;
        };
        let changed = state.current_display != display
            || state.width != info.width
            || state.height != info.height
            || state.original_width != info.original_width
            || state.original_height != info.original_height
            || state.scale_milli != info.scale_milli
            || state.resolutions != info.resolutions;
        state.current_display = display;
        state.width = info.width;
        state.height = info.height;
        state.original_width = info.original_width;
        state.original_height = info.original_height;
        state.scale_milli = info.scale_milli;
        state.resolutions = info.resolutions;
        changed
    }

    fn apply_switch_display_geometry(
        display_state: &Arc<Mutex<crate::RustDeskDisplayState>>,
        display: &SwitchDisplay,
        stream_stats: &Arc<Mutex<crate::RustDeskStreamStats>>,
    ) {
        let display_index = display.get_display();
        if display_index < 0 || display_index as usize >= crate::RUSTDESK_MAX_DISPLAYS {
            return;
        }
        let Ok(mut state) = display_state.lock() else {
            return;
        };
        if let Some(desired) = state.desired_display {
            if display_index != desired {
                eprintln!(
                    "[RustDesk-FFI] stale display geometry ignored received={} desired={}",
                    display_index, desired
                );
                return;
            }
        }
        let resolutions = Self::collect_resolutions(display.get_resolutions());
        let legacy_scale_milli = state.scale_milli;
        let legacy_current_display = state.current_display;
        if let Some(target) = state
            .displays
            .iter_mut()
            .find(|info| info.display == display_index)
        {
            target.x = display.get_x();
            target.y = display.get_y();
            if display.get_width() > 0 {
                target.width = display.get_width();
            }
            if display.get_height() > 0 {
                target.height = display.get_height();
            }
            target.cursor_embedded = display.get_cursor_embedded();
            target.online = true;
            if display.has_original_resolution() {
                target.original_width = display.get_original_resolution().get_width().max(0);
                target.original_height = display.get_original_resolution().get_height().max(0);
            }
            if !resolutions.is_empty() {
                target.resolutions = resolutions;
            }
        } else {
            state.displays.push(crate::RustDeskDisplayInfoState {
                display: display_index,
                x: display.get_x(),
                y: display.get_y(),
                width: display.get_width().max(0),
                height: display.get_height().max(0),
                online: true,
                cursor_embedded: display.get_cursor_embedded(),
                original_width: display.get_original_resolution().get_width().max(0),
                original_height: display.get_original_resolution().get_height().max(0),
                scale_milli: if display_index == legacy_current_display {
                    legacy_scale_milli
                } else {
                    1000
                },
                resolutions,
                ..crate::RustDeskDisplayInfoState::default()
            });
        }
        let changed = Self::sync_active_display(&mut state, display_index);
        if let Some(generation) = state.pending_switch_generation.take() {
            state.confirmed_switch_generation = generation;
        }
        if changed {
            state.geometry_epoch = state.geometry_epoch.wrapping_add(1).max(1);
        }
        if let Ok(mut stats) = stream_stats.lock() {
            stats.width = state.width;
            stats.height = state.height;
        }
        eprintln!(
            "[RustDesk-FFI] display geometry epoch={} display={} size={}x{}",
            state.geometry_epoch, state.current_display, state.width, state.height
        );
    }

    fn apply_follow_current_display(
        display_state: &Arc<Mutex<crate::RustDeskDisplayState>>,
        display: i32,
        stream_stats: &Arc<Mutex<crate::RustDeskStreamStats>>,
    ) {
        let Ok(mut state) = display_state.lock() else {
            return;
        };
        if display < 0 || display as usize >= crate::RUSTDESK_MAX_DISPLAYS {
            return;
        }
        if let Some(desired) = state.desired_display {
            if display != desired {
                eprintln!(
                    "[RustDesk-FFI] stale follow-current-display ignored received={} desired={}",
                    display, desired
                );
                return;
            }
        }
        if state.displays.is_empty() {
            // Legacy peers can report a current-display change without a
            // catalog. Preserve the last known geometry while following the
            // new display index.
            if state.current_display != display {
                state.current_display = display;
                state.geometry_epoch = state.geometry_epoch.wrapping_add(1).max(1);
            }
            if let Some(generation) = state.pending_switch_generation.take() {
                state.confirmed_switch_generation = generation;
            }
            if let Ok(mut stats) = stream_stats.lock() {
                stats.width = state.width;
                stats.height = state.height;
            }
            return;
        }
        if !state
            .displays
            .iter()
            .any(|candidate| candidate.display == display)
        {
            return;
        }
        let changed = Self::sync_active_display(&mut state, display);
        if let Some(generation) = state.pending_switch_generation.take() {
            state.confirmed_switch_generation = generation;
        }
        if changed {
            state.geometry_epoch = state.geometry_epoch.wrapping_add(1).max(1);
            if let Ok(mut stats) = stream_stats.lock() {
                stats.width = state.width;
                stats.height = state.height;
            }
        }
    }

    pub fn keypair(&self) -> &KeyPair {
        &self.keypair
    }
}

#[cfg(test)]
mod tests {
    use super::{
        advance_applied_pressure_level, changed_pressure_target_fps,
        pressure_change_requires_refresh, pressure_target_fps, resolution_aware_fps_ceiling,
        should_refresh_for_video_starvation, ControlKey, KeyEvent_oneof_union,
        Message_oneof_union, PhysicalModifierState, RemoteKeyboardTransport,
        RendezvousCredentials, RustDeskConnector, VP9_PRESSURE_RECOVERY_HOLD_WINDOWS,
        uses_bounded_vp9_pressure_targets,
    };
    use crate::protocol::message_proto::{
        DisplayInfo, Hash, LoginResponse, Message, Misc_oneof_union, PeerInfo,
        PointerDeviceEvent_oneof_union, Resolution, SupportedResolutions, SwitchDisplay,
        TouchEvent_oneof_union,
    };
    use crate::{RustDeskDisplayInfoState, RustDeskDisplayState};
    use crate::protocol::message_proto::KeyboardMode;
    use crate::protocol::wire;
    use protobuf::Message as ProtoMessage;
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};
    use std::thread;

    fn resolution(width: i32, height: i32) -> Resolution {
        let mut value = Resolution::new();
        value.set_width(width);
        value.set_height(height);
        value
    }

    #[test]
    fn shared_access_credentials_keep_text_and_select_unverified_fallback() {
        let raw = " =tenant-key:42/abc=\n";
        let credentials = RendezvousCredentials::new(raw, true);
        assert_eq!(credentials.access_key, raw);
        assert!(credentials.server_public_key.is_none());

        let connector = RustDeskConnector::new();
        let result = connector
            .decode_signed_peer_pk("peer-123", &[1, 2, 3], credentials.server_public_key)
            .expect("shared compatibility path must not try to verify a server key");
        assert!(result.is_none());
    }

    #[test]
    fn display_and_touch_control_messages_match_the_official_protobuf_variants() {
        let resolution_message = RustDeskConnector::build_display_resolution_message(2, 1080, 1920);
        match resolution_message.union {
            Some(Message_oneof_union::misc(misc)) => match misc.union {
                Some(Misc_oneof_union::change_display_resolution(change)) => {
                    assert_eq!(change.get_display(), 2);
                    assert_eq!(change.get_resolution().get_width(), 1080);
                    assert_eq!(change.get_resolution().get_height(), 1920);
                }
                _ => panic!("display change must use Misc.change_display_resolution"),
            },
            _ => panic!("display change must use a Misc message"),
        }

        let scale_message = RustDeskConnector::build_touch_scale_message(1250);
        match scale_message.union {
            Some(Message_oneof_union::pointer_device_event(pointer)) => match pointer.union {
                Some(PointerDeviceEvent_oneof_union::touch_event(touch)) => match touch.union {
                    Some(TouchEvent_oneof_union::scale_update(update)) => assert_eq!(update.get_scale(), 1250),
                    _ => panic!("touch scale must use TouchEvent.scale_update"),
                },
                _ => panic!("touch scale must use PointerDeviceEvent.touch_event"),
            },
            _ => panic!("touch scale must use a pointer device event"),
        }

        let pan_start = RustDeskConnector::build_touch_pan_start_message(100, 200);
        let pan_update = RustDeskConnector::build_touch_pan_update_message(-10, 12);
        let pan_end = RustDeskConnector::build_touch_pan_end_message(90, 212);
        for (message, expected) in [(pan_start, 0), (pan_update, 1), (pan_end, 2)] {
            match message.union {
                Some(Message_oneof_union::pointer_device_event(pointer)) => match pointer.union {
                    Some(PointerDeviceEvent_oneof_union::touch_event(touch)) => match (expected, touch.union) {
                        (0, Some(TouchEvent_oneof_union::pan_start(pan))) => {
                            assert_eq!((pan.get_x(), pan.get_y()), (100, 200));
                        }
                        (1, Some(TouchEvent_oneof_union::pan_update(pan))) => {
                            assert_eq!((pan.get_x(), pan.get_y()), (-10, 12));
                        }
                        (2, Some(TouchEvent_oneof_union::pan_end(pan))) => {
                            assert_eq!((pan.get_x(), pan.get_y()), (90, 212));
                        }
                        _ => panic!("touch pan phase must use its matching TouchEvent variant"),
                    },
                    _ => panic!("touch pan must use PointerDeviceEvent.touch_event"),
                },
                _ => panic!("touch pan must use a pointer device event"),
            }
        }

        let switch_message = RustDeskConnector::build_switch_display_message(1);
        match switch_message.union {
            Some(Message_oneof_union::misc(misc)) => match misc.union {
                Some(Misc_oneof_union::switch_display(switch_display)) => {
                    assert_eq!(switch_display.get_display(), 1);
                }
                _ => panic!("display switch must use Misc.switch_display"),
            },
            _ => panic!("display switch must use a Misc message"),
        }

        let capture_message = RustDeskConnector::build_capture_displays_message(
            vec![2],
            vec![0],
            vec![1, 2],
        );
        match capture_message.union {
            Some(Message_oneof_union::misc(misc)) => match misc.union {
                Some(Misc_oneof_union::capture_displays(capture)) => {
                    assert_eq!(capture.get_add(), &[2]);
                    assert_eq!(capture.get_sub(), &[0]);
                    assert_eq!(capture.get_set(), &[1, 2]);
                }
                _ => panic!("display capture must use Misc.capture_displays"),
            },
            _ => panic!("display capture must use a Misc message"),
        }

        let refresh_message = RustDeskConnector::build_refresh_video_display_message(2);
        match refresh_message.union {
            Some(Message_oneof_union::misc(misc)) => match misc.union {
                Some(Misc_oneof_union::refresh_video_display(display)) => {
                    assert_eq!(display, 2);
                }
                _ => panic!("display refresh must use Misc.refresh_video_display"),
            },
            _ => panic!("display refresh must use a Misc message"),
        }
    }

    #[test]
    fn peer_info_builds_a_bounded_multimonitor_catalog() {
        let mut peer = PeerInfo::new();
        peer.set_current_display(1);

        let mut primary = DisplayInfo::new();
        primary.set_x(0);
        primary.set_y(0);
        primary.set_width(1920);
        primary.set_height(1080);
        primary.set_name("Primary".to_string());
        primary.set_online(true);
        primary.set_scale(1.0);

        let mut secondary = DisplayInfo::new();
        secondary.set_x(1920);
        secondary.set_y(0);
        secondary.set_width(2560);
        secondary.set_height(1440);
        secondary.set_name("Secondary".to_string());
        secondary.set_online(true);
        secondary.set_scale(1.25);

        peer.mut_displays().push(primary);
        peer.mut_displays().push(secondary);
        peer.mut_resolutions()
            .mut_resolutions()
            .push(resolution(2560, 1440));

        let mut state = RustDeskDisplayState::default();
        assert!(RustDeskConnector::populate_display_state(&mut state, &peer));
        assert_eq!(state.displays.len(), 2);
        assert_eq!(state.current_display, 1);
        assert_eq!(state.displays[0].name, "Primary");
        assert_eq!((state.displays[1].x, state.displays[1].y), (1920, 0));
        assert_eq!((state.width, state.height), (2560, 1440));
        assert_eq!(state.scale_milli, 1250);
        assert_eq!(state.resolutions, vec![(2560, 1440)]);
    }

    #[test]
    fn invalid_peer_current_display_prefers_the_first_online_monitor() {
        let mut peer = PeerInfo::new();
        peer.set_current_display(7);

        let mut offline = DisplayInfo::new();
        offline.set_width(1920);
        offline.set_height(1080);
        offline.set_online(false);
        let mut online = DisplayInfo::new();
        online.set_x(1920);
        online.set_width(2560);
        online.set_height(1440);
        online.set_online(true);
        peer.mut_displays().push(offline);
        peer.mut_displays().push(online);

        let mut state = RustDeskDisplayState::default();
        assert!(RustDeskConnector::populate_display_state(&mut state, &peer));
        assert_eq!(state.current_display, 1);
        assert_eq!((state.width, state.height), (2560, 1440));
    }

    #[test]
    fn offline_confirmed_target_releases_to_the_first_online_monitor() {
        let mut peer = PeerInfo::new();
        peer.set_current_display(2);

        let mut online = DisplayInfo::new();
        online.set_width(1920);
        online.set_height(1080);
        online.set_online(true);
        let mut offline = DisplayInfo::new();
        offline.set_width(2560);
        offline.set_height(1440);
        offline.set_online(false);
        peer.mut_displays().push(online);
        peer.mut_displays().push(offline);

        let mut state = RustDeskDisplayState {
            desired_display: Some(1),
            switch_generation: 3,
            confirmed_switch_generation: 3,
            ..RustDeskDisplayState::default()
        };
        assert!(RustDeskConnector::populate_display_state(&mut state, &peer));
        assert_eq!(state.current_display, 0);
        assert_eq!(state.desired_display, None);
        assert_eq!((state.width, state.height), (1920, 1080));
    }

    #[test]
    fn empty_peer_info_clears_stale_display_geometry() {
        let mut state = RustDeskDisplayState {
            current_display: 1,
            width: 2560,
            height: 1440,
            original_width: 2560,
            original_height: 1440,
            scale_milli: 1250,
            resolutions: vec![(2560, 1440)],
            displays: vec![RustDeskDisplayInfoState {
                display: 1,
                width: 2560,
                height: 1440,
                ..RustDeskDisplayInfoState::default()
            }],
            ..RustDeskDisplayState::default()
        };

        assert!(RustDeskConnector::populate_display_state(&mut state, &PeerInfo::new()));
        assert_eq!(state.current_display, 0);
        assert_eq!((state.width, state.height), (0, 0));
        assert_eq!((state.original_width, state.original_height), (0, 0));
        assert_eq!(state.scale_milli, 1000);
        assert!(state.resolutions.is_empty());
        assert!(state.displays.is_empty());
    }

    #[test]
    fn legacy_follow_display_preserves_geometry_without_a_catalog() {
        let display_state = Arc::new(Mutex::new(RustDeskDisplayState {
            current_display: 0,
            width: 1920,
            height: 1080,
            geometry_epoch: 3,
            displays: Vec::new(),
            ..RustDeskDisplayState::default()
        }));
        let stream_stats = Arc::new(Mutex::new(crate::RustDeskStreamStats::default()));

        RustDeskConnector::apply_follow_current_display(&display_state, 2, &stream_stats);

        let state = display_state.lock().expect("display state lock");
        assert_eq!(state.current_display, 2);
        assert_eq!((state.width, state.height), (1920, 1080));
        assert_eq!(state.geometry_epoch, 4);
        let stats = stream_stats.lock().expect("stream stats lock");
        assert_eq!((stats.width, stats.height), (1920, 1080));
    }

    #[test]
    fn switch_display_updates_only_the_selected_catalog_entry() {
        let display_state = Arc::new(Mutex::new(RustDeskDisplayState {
            current_display: 0,
            width: 1920,
            height: 1080,
            original_width: 1920,
            original_height: 1080,
            scale_milli: 1000,
            geometry_epoch: 1,
            resolutions: vec![(1920, 1080)],
            displays: vec![
                RustDeskDisplayInfoState {
                    display: 0,
                    width: 1920,
                    height: 1080,
                    name: "Primary".to_string(),
                    resolutions: vec![(1920, 1080)],
                    ..RustDeskDisplayInfoState::default()
                },
                RustDeskDisplayInfoState {
                    display: 1,
                    width: 2560,
                    height: 1440,
                    name: "Secondary".to_string(),
                    resolutions: vec![(2560, 1440)],
                    ..RustDeskDisplayInfoState::default()
                },
            ],
            ..RustDeskDisplayState::default()
        }));
        let stream_stats = Arc::new(Mutex::new(crate::RustDeskStreamStats::default()));
        let mut supported = SupportedResolutions::new();
        supported.mut_resolutions().push(resolution(1920, 1200));
        let mut switch = SwitchDisplay::new();
        switch.set_display(1);
        switch.set_x(1920);
        switch.set_y(0);
        switch.set_width(1920);
        switch.set_height(1200);
        switch.set_resolutions(supported);

        RustDeskConnector::apply_switch_display_geometry(&display_state, &switch, &stream_stats);

        let state = display_state.lock().expect("display state lock");
        assert_eq!((state.current_display, state.width, state.height), (1, 1920, 1200));
        assert_eq!((state.displays[0].width, state.displays[0].height), (1920, 1080));
        assert_eq!(state.displays[1].resolutions, vec![(1920, 1200)]);
        assert_eq!(state.displays[1].name, "Secondary");
    }

    #[test]
    fn switch_display_updates_android_rotation_geometry_and_frame_stats() {
        let display_state = Arc::new(Mutex::new(crate::RustDeskDisplayState {
            current_display: 0,
            width: 1920,
            height: 1080,
            original_width: 1920,
            original_height: 1080,
            scale_milli: 1250,
            geometry_epoch: 4,
            resolutions: vec![(1920, 1080)],
            displays: Vec::new(),
            ..RustDeskDisplayState::default()
        }));
        let stream_stats = Arc::new(Mutex::new(crate::RustDeskStreamStats::default()));
        let mut supported = SupportedResolutions::new();
        supported.mut_resolutions().push(resolution(1080, 1920));
        supported.mut_resolutions().push(resolution(720, 1280));
        let mut rotation = SwitchDisplay::new();
        rotation.set_display(0);
        rotation.set_width(1080);
        rotation.set_height(1920);
        rotation.set_original_resolution(resolution(1440, 2560));
        rotation.set_resolutions(supported);

        RustDeskConnector::apply_switch_display_geometry(&display_state, &rotation, &stream_stats);

        let state = display_state.lock().expect("display state lock");
        assert_eq!((state.width, state.height), (1080, 1920));
        assert_eq!((state.original_width, state.original_height), (1440, 2560));
        assert_eq!(state.scale_milli, 1250);
        assert_eq!(state.geometry_epoch, 5);
        assert_eq!(state.resolutions, vec![(1080, 1920), (720, 1280)]);
        drop(state);
        let stats = stream_stats.lock().expect("stream stats lock");
        assert_eq!((stats.width, stats.height), (1080, 1920));
    }

    #[test]
    fn rapid_display_switch_ignores_stale_geometry_ack() {
        let display_state = Arc::new(Mutex::new(RustDeskDisplayState {
            current_display: 0,
            desired_display: Some(2),
            switch_generation: 2,
            pending_switch_generation: Some(2),
            width: 1920,
            height: 1080,
            displays: vec![
                RustDeskDisplayInfoState {
                    display: 0,
                    width: 1920,
                    height: 1080,
                    online: true,
                    ..RustDeskDisplayInfoState::default()
                },
                RustDeskDisplayInfoState {
                    display: 1,
                    width: 1600,
                    height: 900,
                    online: true,
                    ..RustDeskDisplayInfoState::default()
                },
                RustDeskDisplayInfoState {
                    display: 2,
                    width: 2560,
                    height: 1440,
                    online: true,
                    ..RustDeskDisplayInfoState::default()
                },
            ],
            ..RustDeskDisplayState::default()
        }));
        let stream_stats = Arc::new(Mutex::new(crate::RustDeskStreamStats::default()));
        let mut stale = SwitchDisplay::new();
        stale.set_display(1);
        stale.set_width(1680);
        stale.set_height(1050);
        RustDeskConnector::apply_switch_display_geometry(&display_state, &stale, &stream_stats);

        {
            let state = display_state.lock().expect("display state lock");
            assert_eq!(state.current_display, 0);
            assert_eq!(state.pending_switch_generation, Some(2));
            assert_eq!(state.confirmed_switch_generation, 0);
        }

        let mut latest = SwitchDisplay::new();
        latest.set_display(2);
        latest.set_width(2560);
        latest.set_height(1440);
        RustDeskConnector::apply_switch_display_geometry(&display_state, &latest, &stream_stats);
        let state = display_state.lock().expect("display state lock");
        assert_eq!(state.current_display, 2);
        assert_eq!(state.pending_switch_generation, None);
        assert_eq!(state.confirmed_switch_generation, 2);
    }

    #[test]
    fn rapid_display_switch_ignores_stale_follow_current_ack() {
        let display_state = Arc::new(Mutex::new(RustDeskDisplayState {
            current_display: 0,
            desired_display: Some(2),
            switch_generation: 2,
            pending_switch_generation: Some(2),
            width: 1920,
            height: 1080,
            displays: vec![
                RustDeskDisplayInfoState {
                    display: 0,
                    width: 1920,
                    height: 1080,
                    online: true,
                    ..RustDeskDisplayInfoState::default()
                },
                RustDeskDisplayInfoState {
                    display: 1,
                    width: 1600,
                    height: 900,
                    online: true,
                    ..RustDeskDisplayInfoState::default()
                },
                RustDeskDisplayInfoState {
                    display: 2,
                    width: 2560,
                    height: 1440,
                    online: true,
                    ..RustDeskDisplayInfoState::default()
                },
            ],
            ..RustDeskDisplayState::default()
        }));
        let stream_stats = Arc::new(Mutex::new(crate::RustDeskStreamStats::default()));

        RustDeskConnector::apply_follow_current_display(&display_state, 1, &stream_stats);
        {
            let state = display_state.lock().expect("display state lock");
            assert_eq!(state.current_display, 0);
            assert_eq!(state.pending_switch_generation, Some(2));
        }

        RustDeskConnector::apply_follow_current_display(&display_state, 2, &stream_stats);
        let state = display_state.lock().expect("display state lock");
        assert_eq!(state.current_display, 2);
        assert_eq!(state.pending_switch_generation, None);
        assert_eq!(state.confirmed_switch_generation, 2);
    }

    #[test]
    fn video_starvation_refreshes_silent_stream_after_initial_frames() {
        assert!(should_refresh_for_video_starvation(
            2,
            0,
            Some(3_000),
            None,
        ));
    }

    #[test]
    fn video_starvation_does_not_refresh_too_often() {
        assert!(!should_refresh_for_video_starvation(
            120,
            0,
            Some(3_000),
            Some(1_000),
        ));
    }

    #[test]
    fn video_starvation_ignores_normal_video_windows() {
        assert!(!should_refresh_for_video_starvation(
            120,
            1,
            Some(3_000),
            None,
        ));
    }

    #[test]
    fn video_starvation_waits_for_the_first_video_frame() {
        assert!(!should_refresh_for_video_starvation(
            0,
            0,
            None,
            None,
        ));
    }

    #[test]
    fn bounded_vp9_pressure_uses_gradual_targets() {
        assert_eq!(pressure_target_fps(2, 2, 30, 0, true), 30);
        assert_eq!(pressure_target_fps(2, 2, 30, 1, true), 26);
        assert_eq!(pressure_target_fps(4, 2, 30, 2, true), 22);
        assert_eq!(pressure_target_fps(4, 2, 30, 3, true), 18);
    }

    #[test]
    fn high_resolution_vp9_uses_a_stable_thirty_fps_ceiling() {
        assert_eq!(resolution_aware_fps_ceiling(2, 2940, 1912, 60), 30);
        assert_eq!(resolution_aware_fps_ceiling(2, 3840, 2160, 25), 25);
        assert_eq!(resolution_aware_fps_ceiling(2, 2560, 1440, 60), 60);
        assert_eq!(resolution_aware_fps_ceiling(4, 2940, 1912, 60), 60);
        assert_eq!(resolution_aware_fps_ceiling(2, 0, 1912, 60), 60);
        assert!(uses_bounded_vp9_pressure_targets(2, 2940, 1912));
        assert!(!uses_bounded_vp9_pressure_targets(2, 2560, 1440));
        assert!(!uses_bounded_vp9_pressure_targets(4, 2940, 1912));
    }

    #[test]
    fn file_upload_completion_does_not_require_a_remote_done_echo() {
        assert!(!super::file_upload_sender_complete(1));
        assert!(super::file_upload_sender_complete(0));
    }

    #[test]
    fn non_vp9_pressure_never_raises_the_configured_target() {
        assert_eq!(pressure_target_fps(4, 4, 30, 0, false), 30);
        assert_eq!(pressure_target_fps(4, 4, 60, 2, false), 30);
        assert_eq!(pressure_target_fps(4, 4, 60, 3, false), 15);
        assert_eq!(pressure_target_fps(2, 2, 30, 1, false), 30);
    }

    #[test]
    fn unchanged_pressure_fps_does_not_reapply_stream_options() {
        assert_eq!(changed_pressure_target_fps(2, 2, 30, 30, 3, true), Some(18));
        assert_eq!(changed_pressure_target_fps(2, 2, 30, 18, 3, true), None);
        assert_eq!(changed_pressure_target_fps(4, 4, 30, 30, 1, false), None);
        assert_eq!(changed_pressure_target_fps(4, 4, 60, 60, 2, false), Some(30));
        assert_eq!(changed_pressure_target_fps(4, 4, 60, 15, 0, false), Some(60));
    }

    #[test]
    fn pressure_recovery_has_only_one_hysteresis_owner() {
        assert_eq!(advance_applied_pressure_level(4, 2, 0, 2, 0, true), (2, 0));
        assert_eq!(advance_applied_pressure_level(4, 2, 3, 0, 7, true), (0, 0));

        let mut level = 2;
        let mut windows = 0;
        for _ in 1..VP9_PRESSURE_RECOVERY_HOLD_WINDOWS {
            (level, windows) = advance_applied_pressure_level(4, 2, level, 0, windows, false);
            assert_eq!(level, 2);
        }
        (level, windows) = advance_applied_pressure_level(4, 2, level, 0, windows, false);
        assert_eq!((level, windows), (1, 0));
    }

    #[test]
    fn pressure_recovery_and_refresh_policy_preserve_hardware_behavior() {
        assert_eq!(advance_applied_pressure_level(4, 4, 2, 0, 8, false), (0, 0));
        assert!(pressure_change_requires_refresh(4, 4));
        assert!(!pressure_change_requires_refresh(2, 0));
        assert!(!pressure_change_requires_refresh(4, 2));
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

        let mut modifiers = PhysicalModifierState::default();
        let left_down = RustDeskConnector::build_key_message(2014, true, &mut modifiers).unwrap();
        match left_down.union {
            Some(Message_oneof_union::key_event(key)) => match key.union {
                Some(KeyEvent_oneof_union::control_key(key)) => {
                    assert_eq!(key, ControlKey::LeftArrow);
                }
                _ => panic!("left down must be a control key"),
            },
            _ => panic!("left down must be a key event"),
        }
        let left_up = RustDeskConnector::build_key_message(2014, false, &mut modifiers).unwrap();
        match left_up.union {
            Some(Message_oneof_union::key_event(key)) => assert!(!key.down),
            _ => panic!("left up must be a key event"),
        }
    }

    #[test]
    fn legacy_hotkeys_embed_held_modifier_on_every_key_event() {
        let mut modifiers = PhysicalModifierState::default();
        RustDeskConnector::build_key_message(2076, true, &mut modifiers).unwrap();
        let c_down = RustDeskConnector::build_key_message(2019, true, &mut modifiers).unwrap();
        match c_down.union {
            Some(Message_oneof_union::key_event(key)) => {
                assert!(key.down);
                assert!(key.modifiers.iter().any(|modifier| *modifier == ControlKey::Meta));
            }
            _ => panic!("command-c down must be a key event"),
        }
        let c_up = RustDeskConnector::build_key_message(2019, false, &mut modifiers).unwrap();
        match c_up.union {
            Some(Message_oneof_union::key_event(key)) => {
                assert!(!key.down);
                assert!(key.modifiers.iter().any(|modifier| *modifier == ControlKey::Meta));
            }
            _ => panic!("command-c up must be a key event"),
        }
        RustDeskConnector::build_key_message(2076, false, &mut modifiers).unwrap();
        assert!(modifiers.active_groups().is_empty());
    }

    #[test]
    fn mouse_button_messages_match_official_macos_focus_semantics() {
        let mut modifiers = PhysicalModifierState::default();
        modifiers.update(2076, true);

        let down = RustDeskConnector::build_mouse_button_messages(
            2184,
            1806,
            0x01,
            true,
            &modifiers,
        );
        assert_eq!(down.len(), 2);
        let down_move = match &down[0].union {
            Some(Message_oneof_union::mouse_event(mouse)) => mouse,
            _ => panic!("mouse down must begin with a move"),
        };
        assert_eq!((down_move.x, down_move.y, down_move.mask), (2184, 1806, 0));
        assert!(down_move
            .modifiers
            .iter()
            .any(|modifier| *modifier == ControlKey::Meta));

        let down_button = match &down[1].union {
            Some(Message_oneof_union::mouse_event(mouse)) => mouse,
            _ => panic!("mouse down must end with a button event"),
        };
        assert_eq!((down_button.x, down_button.y, down_button.mask), (0, 0, 9));
        assert!(down_button
            .modifiers
            .iter()
            .any(|modifier| *modifier == ControlKey::Meta));

        let up = RustDeskConnector::build_mouse_button_messages(
            2184,
            1806,
            0x01,
            false,
            &modifiers,
        );
        assert_eq!(up.len(), 1);
        let up_button = match &up[0].union {
            Some(Message_oneof_union::mouse_event(mouse)) => mouse,
            _ => panic!("mouse up must contain only a button event"),
        };
        assert_eq!((up_button.x, up_button.y, up_button.mask), (0, 0, 10));
    }

    #[test]
    fn legacy_letter_keycodes_use_lowercase_layout_characters() {
        assert_eq!(RustDeskConnector::harmony_keycode_to_chr(2017), b'a' as u32);
        assert_eq!(RustDeskConnector::harmony_keycode_to_chr(2019), b'c' as u32);
        assert_eq!(RustDeskConnector::harmony_keycode_to_chr(2038), b'v' as u32);
        assert_eq!(RustDeskConnector::harmony_keycode_to_chr(2042), b'z' as u32);
    }

    #[test]
    fn supported_windows_peers_use_map_transport_for_physical_keys() {
        assert_eq!(
            RustDeskConnector::keyboard_transport_for_peer("Windows", "1.2.0"),
            RemoteKeyboardTransport::WindowsMap
        );
        assert_eq!(
            RustDeskConnector::keyboard_transport_for_peer("windows", "1.10.0"),
            RemoteKeyboardTransport::WindowsMap
        );
        assert_eq!(
            RustDeskConnector::keyboard_transport_for_peer("Windows", "1.1.9"),
            RemoteKeyboardTransport::Legacy
        );
        assert_eq!(
            RustDeskConnector::keyboard_transport_for_peer("Windows", "unknown"),
            RemoteKeyboardTransport::Legacy
        );
        assert_eq!(
            RustDeskConnector::keyboard_transport_for_peer("Mac OS", "1.1.0"),
            RemoteKeyboardTransport::MacosMap
        );
    }

    #[test]
    fn windows_map_uses_physical_scan_codes_instead_of_unicode_characters() {
        for (harmony_keycode, expected_scancode) in [
            (2017, 0x1E), // A
            (2038, 0x2F), // V
            (2001, 0x02), // 1
            (2057, 0x0C), // minus
            (2072, 0x1D), // left Ctrl
            (2073, 0xE01D), // right Ctrl
            (2076, 0xE05B), // left Win
            (2119, 0xE01C), // numpad Enter
        ] {
            assert_eq!(
                RustDeskConnector::harmony_keycode_to_windows_scancode(harmony_keycode),
                Some(expected_scancode),
                "Harmony keycode {}",
                harmony_keycode
            );
        }

        for pressed in [true, false] {
            let message = RustDeskConnector::build_windows_map_message(0x1E, pressed);
            match message.union {
                Some(Message_oneof_union::key_event(key)) => {
                    assert_eq!(key.mode, KeyboardMode::Map);
                    assert_eq!(key.down, pressed);
                    assert!(matches!(key.union, Some(KeyEvent_oneof_union::chr(0x1E))));
                    assert!(key.modifiers.is_empty());
                }
                _ => panic!("Windows physical key must be a Map key event"),
            }
        }
    }

    #[test]
    fn windows_map_covers_extended_function_keys_and_keeps_pause_special() {
        assert_eq!(
            RustDeskConnector::harmony_keycode_to_windows_scancode(2816),
            Some(0x64)
        );
        assert_eq!(
            RustDeskConnector::harmony_keycode_to_windows_scancode(2827),
            Some(0x6F)
        );
        assert_eq!(
            RustDeskConnector::harmony_keycode_to_windows_scancode(2079),
            Some(0xE037)
        );
        assert_eq!(
            RustDeskConnector::harmony_keycode_to_windows_scancode(2080),
            None
        );
    }

    #[test]
    fn caps_lock_preserves_physical_hold_duration() {
        let mut modifiers = PhysicalModifierState::default();
        let down = RustDeskConnector::build_key_message(2074, true, &mut modifiers).unwrap();
        let up = RustDeskConnector::build_key_message(2074, false, &mut modifiers).unwrap();
        for (message, expected_down) in [(down, true), (up, false)] {
            match message.union {
                Some(Message_oneof_union::key_event(key)) => {
                    assert_eq!(key.down, expected_down);
                    match key.union {
                        Some(KeyEvent_oneof_union::control_key(control)) => {
                            assert_eq!(control, ControlKey::CapsLock)
                        }
                        _ => panic!("caps lock must remain a control key"),
                    }
                }
                _ => panic!("caps lock must be a key event"),
            }
        }
    }

    #[test]
    fn macos_caps_lock_uses_raw_map_keycode() {
        assert!(RustDeskConnector::should_use_macos_caps_lock_map(
            RustDeskConnector::MACOS_CAPS_LOCK_RAW_SCANCODE,
            RemoteKeyboardTransport::Legacy,
        ));
        assert!(RustDeskConnector::should_use_macos_caps_lock_map(
            2074,
            RemoteKeyboardTransport::MacosMap,
        ));
        assert!(!RustDeskConnector::should_use_macos_caps_lock_map(
            2074,
            RemoteKeyboardTransport::WindowsMap,
        ));
        for pressed in [true, false] {
            let message = RustDeskConnector::build_macos_map_message(0x39, pressed);
            match message.union {
                Some(Message_oneof_union::key_event(key)) => {
                    assert_eq!(key.down, pressed);
                    assert_eq!(key.mode, KeyboardMode::Map);
                    assert!(matches!(key.union, Some(KeyEvent_oneof_union::chr(0x39))));
                    assert!(key.modifiers.is_empty());
                }
                _ => panic!("macOS Caps Lock must remain a key event"),
            }
        }
    }

    #[test]
    fn explicit_macos_shortcut_keeps_command_and_letter_in_map_mode() {
        let mut modifiers = PhysicalModifierState::default();
        for (harmony_keycode, expected_macos_keycode) in [(2076, 0x37), (2019, 0x08)] {
            let marked = RustDeskConnector::EXPLICIT_MACOS_MAP_FLAG | harmony_keycode;
            let (message, decoded, mapped) =
                RustDeskConnector::build_explicit_macos_map_message(
                    marked, true, &mut modifiers,
                ).expect("marked macOS shortcut key must map");
            assert_eq!(decoded, harmony_keycode);
            assert_eq!(mapped, expected_macos_keycode);
            match message.union {
                Some(Message_oneof_union::key_event(key)) => {
                    assert!(key.down);
                    assert_eq!(key.mode, KeyboardMode::Map);
                    assert!(matches!(key.union,
                        Some(KeyEvent_oneof_union::chr(code)) if code == expected_macos_keycode));
                }
                _ => panic!("explicit macOS shortcut must remain a key event"),
            }
        }
        assert!(modifiers.active_groups().contains(&ControlKey::Meta));
    }

    #[test]
    fn macos_physical_letters_and_controls_use_carbon_virtual_keycodes() {
        assert_eq!(RustDeskConnector::harmony_keycode_to_macos_keycode(2017), Some(0x00));
        assert_eq!(RustDeskConnector::harmony_keycode_to_macos_keycode(2035), Some(0x01));
        assert_eq!(RustDeskConnector::harmony_keycode_to_macos_keycode(2020), Some(0x02));
        assert_eq!(RustDeskConnector::harmony_keycode_to_macos_keycode(2050), Some(0x31));
        assert_eq!(RustDeskConnector::harmony_keycode_to_macos_keycode(2072), Some(0x3B));
        assert_eq!(RustDeskConnector::harmony_keycode_to_macos_keycode(2076), Some(0x37));
        assert_eq!(RustDeskConnector::harmony_keycode_to_macos_keycode(2014), Some(0x7B));
        assert_eq!(RustDeskConnector::harmony_keycode_to_macos_keycode(2816), Some(0x69));
        assert_eq!(RustDeskConnector::harmony_keycode_to_macos_keycode(2823), Some(0x5A));
        assert_eq!(RustDeskConnector::harmony_keycode_to_macos_keycode(2824), None);
    }

    #[test]
    fn macos_map_message_keeps_physical_down_up_events() {
        for pressed in [true, false] {
            let message = RustDeskConnector::build_macos_map_message(0x00, pressed);
            match message.union {
                Some(Message_oneof_union::key_event(key)) => {
                    assert_eq!(key.down, pressed);
                    assert_eq!(key.mode, KeyboardMode::Map);
                    assert!(matches!(key.union, Some(KeyEvent_oneof_union::chr(0x00))));
                    assert!(key.modifiers.is_empty());
                }
                _ => panic!("macOS physical letter must be a key event"),
            }
        }
    }

    #[test]
    fn harmony_meta_keys_keep_left_and_right_identity() {
        assert_eq!(
            RustDeskConnector::harmony_keycode_to_control_key(2076),
            Some(ControlKey::Meta)
        );
        assert_eq!(
            RustDeskConnector::harmony_keycode_to_control_key(2077),
            Some(ControlKey::RWin)
        );
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
            .connect_direct("localhost", port, "", "", 0, 1, false, false, 30)
            .expect_err("fake peer should fail after TCP connect, not during endpoint parsing");
        assert_ne!(
            error.kind(),
            std::io::ErrorKind::InvalidInput,
            "hostname should be resolved before the direct protocol is read"
        );
        accept_thread.join().expect("accept thread panicked");
    }

    #[test]
    fn direct_login_uses_direct_address_and_plain_hash_challenge() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener bind failed");
        let port = listener
            .local_addr()
            .expect("listener address missing")
            .port();
        let accept_thread = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("direct connection missing");
            let mut hash = Hash::new();
            hash.set_salt("salt".to_string());
            hash.set_challenge("challenge".to_string());
            let mut challenge = Message::new();
            challenge.union = Some(Message_oneof_union::hash(hash));
            wire::write_frame(&mut stream, &challenge.write_to_bytes().unwrap()).unwrap();

            let login_payload = wire::read_frame(&mut stream).unwrap();
            let login: Message = protobuf::parse_from_bytes(&login_payload).unwrap();
            match login.union {
                Some(Message_oneof_union::login_request(request)) => {
                    assert_eq!(request.get_username(), "127.0.0.1");
                    assert_eq!(request.get_my_platform(), "OHOS");
                }
                other => panic!("expected plain LoginRequest, got: {:?}", other),
            }

            let mut response = LoginResponse::new();
            let mut response_message = Message::new();
            response_message.union = Some(Message_oneof_union::login_response(response));
            wire::write_frame(&mut stream, &response_message.write_to_bytes().unwrap()).unwrap();
            // Login completion sends runtime options and refresh_video as two
            // additional plain frames before the connector returns.
            wire::read_frame(&mut stream).unwrap();
            wire::read_frame(&mut stream).unwrap();
        });

        RustDeskConnector::new()
            .connect_direct("127.0.0.1", port, "peer-123", "", 0, 1, false, false, 30)
            .expect("official direct login should accept a plain Hash challenge");
        accept_thread.join().expect("accept thread panicked");
    }

    #[test]
    fn direct_file_transfer_uses_plain_login_with_file_transfer_mode() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener bind failed");
        let port = listener
            .local_addr()
            .expect("listener address missing")
            .port();
        let accept_thread = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("direct file connection missing");
            let mut hash = Hash::new();
            hash.set_salt("salt".to_string());
            hash.set_challenge("challenge".to_string());
            let mut challenge = Message::new();
            challenge.union = Some(Message_oneof_union::hash(hash));
            wire::write_frame(&mut stream, &challenge.write_to_bytes().unwrap()).unwrap();

            let login_payload = wire::read_frame(&mut stream).unwrap();
            let login: Message = protobuf::parse_from_bytes(&login_payload).unwrap();
            match login.union {
                Some(Message_oneof_union::login_request(request)) => {
                    assert_eq!(request.get_username(), "127.0.0.1");
                    assert!(request.has_file_transfer());
                    assert_eq!(
                        request.get_file_transfer().get_dir(),
                        r"C:\Users\Public\Documents"
                    );
                    assert!(!request.get_file_transfer().get_show_hidden());
                }
                other => panic!("expected file-transfer LoginRequest, got: {:?}", other),
            }

            let response = LoginResponse::new();
            let mut response_message = Message::new();
            response_message.union = Some(Message_oneof_union::login_response(response));
            wire::write_frame(&mut stream, &response_message.write_to_bytes().unwrap()).unwrap();
        });

        RustDeskConnector::new()
            .connect_file_transfer_direct(
                "127.0.0.1",
                port,
                "",
                r"C:\Users\Public\Documents",
            )
            .expect("direct file transfer should use the peer login protocol");
        accept_thread.join().expect("accept thread panicked");
    }
}
