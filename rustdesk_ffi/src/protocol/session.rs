// session.rs — RustDesk 远程会话管理
//
// 会话流程:
//   1. 通过 Rendezvous 建立 P2P/中继连接
//   2. 发送 LoginRequest (Message wrapper) → 接收 LoginResponse
//   3. 成功后进入视频/音频流模式
//   4. 主循环: 接收 Message → 分发 video_frame/audio_frame 等

use super::message_proto::{
    AudioFrame, FileTransfer, ImageQuality, KeyEvent, LoginRequest, LoginResponse,
    LoginResponse_oneof_union, Message, Message_oneof_union, Misc, Misc_oneof_union, MouseEvent,
    OptionMessage, OptionMessage_BoolOption, PeerInfo, SupportedDecoding,
    SupportedDecoding_PreferCodec, VideoFrame,
};
use super::wire;
use protobuf::Message as ProtoMessage;
use sha2::{Digest, Sha256};
use std::io;
use std::net::TcpStream;
use std::time::{Duration, Instant};

/// 会话状态
#[derive(Debug, Clone, PartialEq)]
pub enum SessionState {
    Disconnected,
    LoggingIn,
    WaitingRemoteApproval,
    Connected,
    Error(String),
}

/// 会话上下文
pub struct Session {
    state: SessionState,
    peer_info: Option<PeerInfo>,
    connect_epoch: u64,
}

impl Session {
    pub fn new() -> Self {
        Self {
            state: SessionState::Disconnected,
            peer_info: None,
            connect_epoch: crate::current_connect_epoch(),
        }
    }

    /// 发送 LoginRequest 通过加密通道 (替代原始 TCP login)
    pub fn login_encrypted(
        &mut self,
        channel: &mut crate::crypto_channel::CryptoChannel,
        peer_id: &str,
        password: &str,
        preferred_codec: i32,
        image_quality: i32,
        privacy_mode: bool,
        audio_enabled: bool,
        fps: u32,
        request_approval: bool,
    ) -> io::Result<()> {
        self.login_encrypted_inner(
            channel,
            peer_id,
            password,
            preferred_codec,
            image_quality,
            privacy_mode,
            audio_enabled,
            fps,
            request_approval,
            None,
        )?;
        eprintln!("[RustDesk-FFI] login_encrypted response ok, sending stream options");
        Self::send_stream_options(
            channel,
            preferred_codec,
            image_quality,
            privacy_mode,
            audio_enabled,
            fps,
        )
    }

    pub fn login_file_transfer_encrypted(
        &mut self,
        channel: &mut crate::crypto_channel::CryptoChannel,
        peer_id: &str,
        password: &str,
        remote_dir: &str,
        request_approval: bool,
    ) -> io::Result<()> {
        self.login_encrypted_inner(
            channel,
            peer_id,
            password,
            0,
            1,
            false,
            false,
            30,
            request_approval,
            Some(remote_dir),
        )?;
        eprintln!(
            "[RustDesk-FFI] login_file_transfer_encrypted response ok dir={}",
            remote_dir
        );
        Ok(())
    }

    fn login_encrypted_inner(
        &mut self,
        channel: &mut crate::crypto_channel::CryptoChannel,
        peer_id: &str,
        password: &str,
        preferred_codec: i32,
        image_quality: i32,
        privacy_mode: bool,
        audio_enabled: bool,
        fps: u32,
        request_approval: bool,
        file_transfer_dir: Option<&str>,
    ) -> io::Result<()> {
        self.state = SessionState::LoggingIn;

        let challenge_payload = channel.recv().map_err(|e| {
            io::Error::new(
                e.kind(),
                format!("login hash read failed before LoginRequest: {e}"),
            )
        })?;
        let challenge_msg: Message = protobuf::parse_from_bytes(&challenge_payload)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        let hash = match challenge_msg.union {
            Some(Message_oneof_union::hash(hash)) => hash,
            Some(Message_oneof_union::login_response(resp)) => {
                return self.handle_login_response(resp);
            }
            other => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("expected login Hash before LoginRequest, got: {:?}", other),
                ));
            }
        };

        Self::send_login_request(
            channel,
            peer_id,
            password,
            &hash,
            preferred_codec,
            image_quality,
            privacy_mode,
            audio_enabled,
            fps,
            file_transfer_dir,
            request_approval,
        )?;

        self.wait_login_response(
            channel,
            peer_id,
            password,
            preferred_codec,
            image_quality,
            privacy_mode,
            audio_enabled,
            fps,
            file_transfer_dir,
            request_approval,
            &hash,
        )?;
        Ok(())
    }

    fn send_login_request(
        channel: &mut crate::crypto_channel::CryptoChannel,
        peer_id: &str,
        password: &str,
        hash: &super::message_proto::Hash,
        preferred_codec: i32,
        image_quality: i32,
        privacy_mode: bool,
        audio_enabled: bool,
        fps: u32,
        file_transfer_dir: Option<&str>,
        request_approval: bool,
    ) -> io::Result<()> {
        let hashed_password = if request_approval || password.is_empty() {
            Vec::new()
        } else {
            let mut hasher = Sha256::new();
            hasher.update(password.as_bytes());
            hasher.update(hash.get_salt().as_bytes());
            let first = hasher.finalize();

            let mut hasher = Sha256::new();
            hasher.update(&first[..]);
            hasher.update(hash.get_challenge().as_bytes());
            hasher.finalize()[..].to_vec()
        };

        let mut login = LoginRequest::new();
        login.set_username(peer_id.to_string());
        login.set_password(hashed_password);
        login.set_my_id(Self::local_client_id(peer_id));
        login.set_my_name("HarmonyOS-RemoteDesktop".to_string());
        login.set_session_id(0);
        login.set_version("2.0.0".to_string());
        login.set_my_platform("OHOS".to_string());
        if let Some(dir) = file_transfer_dir {
            let mut ft = FileTransfer::new();
            ft.set_dir(dir.to_string());
            ft.set_show_hidden(false);
            login.set_file_transfer(ft);
        }

        let mut opt = OptionMessage::new();
        opt.set_image_quality(Self::image_quality_from_pref(image_quality));
        opt.set_supported_decoding(Self::supported_decoding(preferred_codec));
        opt.set_custom_fps(fps as i32);
        opt.set_disable_audio(if audio_enabled {
            OptionMessage_BoolOption::No
        } else {
            OptionMessage_BoolOption::Yes
        });
        opt.set_privacy_mode(if privacy_mode {
            OptionMessage_BoolOption::Yes
        } else {
            OptionMessage_BoolOption::NotSet
        });
        login.option = protobuf::SingularPtrField::some(opt);

        let mut msg = Message::new();
        msg.union = Some(Message_oneof_union::login_request(login));
        let payload = msg
            .write_to_bytes()
            .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
        channel.send(&payload)
    }

    fn image_quality_from_pref(image_quality: i32) -> ImageQuality {
        match image_quality {
            0 => ImageQuality::Low,
            2 => ImageQuality::Best,
            _ => ImageQuality::Balanced,
        }
    }

    fn image_quality_name(image_quality: i32) -> &'static str {
        match image_quality {
            0 => "Low",
            2 => "Best",
            _ => "Balanced",
        }
    }

    fn supported_decoding(preferred_codec: i32) -> SupportedDecoding {
        let mut decoding = SupportedDecoding::new();
        match preferred_codec {
            1 => {
                decoding.set_ability_vp8(1);
                decoding.set_prefer(SupportedDecoding_PreferCodec::VP8);
            }
            2 => {
                decoding.set_ability_vp9(1);
                decoding.set_prefer(SupportedDecoding_PreferCodec::VP9);
            }
            3 => {
                decoding.set_ability_av1(1);
                decoding.set_prefer(SupportedDecoding_PreferCodec::AV1);
            }
            5 => {
                decoding.set_ability_vp8(1);
                decoding.set_ability_vp9(1);
                decoding.set_ability_h265(1);
                decoding.set_prefer(SupportedDecoding_PreferCodec::H265);
            }
            4 => {
                // H264 优先，同时公告 VP8/VP9 回退 — 对齐 upstream 行为。
                // 仅公告 H264 时若对端编码器异常则无退路，会停止发送。
                decoding.set_ability_vp8(1);
                decoding.set_ability_vp9(1);
                decoding.set_ability_h264(1);
                decoding.set_prefer(SupportedDecoding_PreferCodec::H264);
            }
            _ => {
                decoding.set_ability_vp8(1);
                decoding.set_ability_vp9(1);
                decoding.set_ability_av1(1);
                decoding.set_ability_h264(1);
                decoding.set_ability_h265(1);
                decoding.set_prefer(SupportedDecoding_PreferCodec::H264);
            }
        }
        decoding
    }

    fn codec_name(preferred_codec: i32) -> &'static str {
        match preferred_codec {
            1 => "VP8",
            2 => "VP9",
            3 => "AV1",
            4 => "H264",
            5 => "H265",
            _ => "auto",
        }
    }

    fn default_fps_for_codec(preferred_codec: i32) -> u32 {
        match preferred_codec {
            1 | 2 | 3 => 45,
            _ => 60,
        }
    }

    pub fn send_stream_options(
        channel: &mut crate::crypto_channel::CryptoChannel,
        preferred_codec: i32,
        image_quality: i32,
        privacy_mode: bool,
        audio_enabled: bool,
        fps: u32,
    ) -> io::Result<()> {
        eprintln!(
            "[RustDesk-FFI] send_stream_options begin codec={} quality={}({}) fps={} privacy={} audio={}",
            Self::codec_name(preferred_codec),
            image_quality,
            Self::image_quality_name(image_quality),
            fps,
            privacy_mode,
            audio_enabled
        );
        if let Err(err) = Self::send_runtime_options(
            channel,
            preferred_codec,
            image_quality,
            privacy_mode,
            audio_enabled,
            Some(fps),
        ) {
            eprintln!(
                "[RustDesk-FFI] send_stream_options runtime options failed: {}",
                err
            );
            return Err(err);
        }
        eprintln!("[RustDesk-FFI] send_stream_options runtime options ok");
        if let Err(err) = Self::send_refresh_video(channel) {
            eprintln!(
                "[RustDesk-FFI] send_stream_options refresh_video failed: {}",
                err
            );
            return Err(err);
        }
        eprintln!("[RustDesk-FFI] send_stream_options refresh_video ok");
        Ok(())
    }

    pub fn send_runtime_options(
        channel: &mut crate::crypto_channel::CryptoChannel,
        preferred_codec: i32,
        image_quality: i32,
        privacy_mode: bool,
        audio_enabled: bool,
        fps: Option<u32>,
    ) -> io::Result<()> {
        let custom_fps = fps.unwrap_or_else(|| Self::default_fps_for_codec(preferred_codec));
        let mut opt = OptionMessage::new();
        opt.set_image_quality(Self::image_quality_from_pref(image_quality));
        opt.set_supported_decoding(Self::supported_decoding(preferred_codec));
        opt.set_custom_fps(custom_fps as i32);
        opt.set_disable_audio(if audio_enabled {
            OptionMessage_BoolOption::No
        } else {
            OptionMessage_BoolOption::Yes
        });
        opt.set_privacy_mode(if privacy_mode {
            OptionMessage_BoolOption::Yes
        } else {
            OptionMessage_BoolOption::NotSet
        });

        let mut misc = Misc::new();
        misc.union = Some(Misc_oneof_union::option(opt));

        let mut msg = Message::new();
        msg.union = Some(Message_oneof_union::misc(misc));

        let payload = msg
            .write_to_bytes()
            .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
        channel.send(&payload)?;
        eprintln!(
            "[RustDesk-FFI] sent runtime OptionMessage supported_decoding={} quality={}({}) fps={} audio={}",
            Self::codec_name(preferred_codec),
            image_quality,
            Self::image_quality_name(image_quality),
            custom_fps,
            if audio_enabled { "on" } else { "off" }
        );
        Ok(())
    }

    pub fn send_refresh_video(
        channel: &mut crate::crypto_channel::CryptoChannel,
    ) -> io::Result<()> {
        let mut misc = Misc::new();
        // 同时使用新旧字段 + video_received ack — 覆盖各种 RustDesk 版本
        misc.set_refresh_video(true);
        misc.set_video_received(true); // 告知对端我们还在接收，不要停止
        misc.set_refresh_video_display(0); // 新字段 (1.2.4+), display=0=主显示器

        let mut msg = Message::new();
        msg.union = Some(Message_oneof_union::misc(misc));

        let payload = msg
            .write_to_bytes()
            .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
        channel.send(&payload)?;
        eprintln!("[RustDesk-FFI] sent refresh_video + video_received + refresh_video_display(0)");
        Ok(())
    }

    pub fn send_video_received(
        channel: &mut crate::crypto_channel::CryptoChannel,
    ) -> io::Result<()> {
        let mut misc = Misc::new();
        misc.set_video_received(true);

        let mut msg = Message::new();
        msg.union = Some(Message_oneof_union::misc(misc));

        let payload = msg
            .write_to_bytes()
            .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
        channel.send(&payload)?;
        Ok(())
    }

    fn wait_login_response(
        &mut self,
        channel: &mut crate::crypto_channel::CryptoChannel,
        peer_id: &str,
        password: &str,
        preferred_codec: i32,
        image_quality: i32,
        privacy_mode: bool,
        audio_enabled: bool,
        fps: u32,
        file_transfer_dir: Option<&str>,
        request_approval: bool,
        initial_hash: &super::message_proto::Hash,
    ) -> io::Result<()> {
        const APPROVAL_TIMEOUT: Duration = Duration::from_secs(90);
        const PASSWORD_TIMEOUT: Duration = Duration::from_secs(30);
        const NO_PASSWORD_ACCESS: &str = "No Password Access";
        let deadline = Instant::now()
            + if request_approval {
                APPROVAL_TIMEOUT
            } else {
                PASSWORD_TIMEOUT
            };
        let mut last_challenge = Self::challenge_fingerprint(initial_hash);
        let mut last_variant = "none".to_string();

        // 官方在等待被控端批准时保持加密通道，期间允许 TestDelay 保活。
        channel.set_read_timeout(Some(Duration::from_millis(250)))?;
        let result = loop {
            if crate::connect_cancelled(self.connect_epoch) {
                self.state = SessionState::Error("connection cancelled".to_string());
                break Err(io::Error::new(
                    io::ErrorKind::Interrupted,
                    "connection cancelled",
                ));
            }
            if Instant::now() >= deadline {
                self.state = SessionState::Error(if request_approval {
                    "remote approval timed out after 90s".to_string()
                } else {
                    "login response timed out after 30s".to_string()
                });
                break Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    if request_approval {
                        "remote approval timed out after 90s"
                    } else {
                        "login response timed out after 30s"
                    },
                ));
            }

            let response_payload = match channel.recv() {
                Ok(payload) => payload,
                Err(err)
                    if err.kind() == io::ErrorKind::WouldBlock
                        || err.kind() == io::ErrorKind::TimedOut =>
                {
                    continue;
                }
                Err(err) => {
                    break Err(io::Error::new(
                        err.kind(),
                        format!("login response read failed after encrypted LoginRequest: {err}"),
                    ));
                }
            };
            let response: Message = match protobuf::parse_from_bytes(&response_payload) {
                Ok(message) => message,
                Err(err) => {
                    break Err(io::Error::new(io::ErrorKind::InvalidData, err));
                }
            };

            match response.union {
                Some(Message_oneof_union::login_response(resp)) => {
                    if resp.has_error() {
                        let err = resp.get_error().to_string();
                        if request_approval && err == NO_PASSWORD_ACCESS {
                            self.state = SessionState::WaitingRemoteApproval;
                            last_variant = "no_password_access".to_string();
                            continue;
                        }
                        self.state = SessionState::Error(err.clone());
                        break Err(io::Error::new(io::ErrorKind::PermissionDenied, err));
                    }
                    if let Some(LoginResponse_oneof_union::peer_info(info)) = resp.union {
                        self.peer_info = Some(info);
                    }
                    self.state = SessionState::Connected;
                    break Ok(());
                }
                Some(Message_oneof_union::hash(hash)) if request_approval => {
                    let fingerprint = Self::challenge_fingerprint(&hash);
                    if fingerprint == last_challenge {
                        last_variant = "duplicate_hash".to_string();
                        continue;
                    }
                    last_challenge = fingerprint;
                    self.state = SessionState::WaitingRemoteApproval;
                    Self::send_login_request(
                        channel,
                        peer_id,
                        password,
                        &hash,
                        preferred_codec,
                        image_quality,
                        privacy_mode,
                        audio_enabled,
                        fps,
                        file_transfer_dir,
                        true,
                    )?;
                    self.state = SessionState::LoggingIn;
                }
                Some(Message_oneof_union::test_delay(test_delay)) => {
                    last_variant = "test_delay".to_string();
                    let mut msg = Message::new();
                    msg.union = Some(Message_oneof_union::test_delay(test_delay));
                    let payload = msg
                        .write_to_bytes()
                        .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
                    channel.send(&payload)?;
                }
                Some(Message_oneof_union::peer_info(info)) => {
                    last_variant = "peer_info".to_string();
                    self.peer_info = Some(info);
                }
                other => {
                    last_variant = Self::message_variant_name(&other).to_string();
                }
            }
        };
        channel.set_read_timeout(None).ok();
        if result.is_err() && last_variant == "no_password_access" && request_approval {
            eprintln!("[RustDesk-FFI] waiting for remote approval ended with error");
        }
        result
    }

    fn challenge_fingerprint(hash: &super::message_proto::Hash) -> [u8; 32] {
        let mut digest = Sha256::new();
        digest.update(hash.get_salt().as_bytes());
        digest.update([0]);
        digest.update(hash.get_challenge().as_bytes());
        digest.finalize().into()
    }

    fn message_variant_name(union: &Option<Message_oneof_union>) -> &'static str {
        match union {
            Some(Message_oneof_union::signed_id(_)) => "signed_id",
            Some(Message_oneof_union::public_key(_)) => "public_key",
            Some(Message_oneof_union::test_delay(_)) => "test_delay",
            Some(Message_oneof_union::video_frame(_)) => "video_frame",
            Some(Message_oneof_union::login_request(_)) => "login_request",
            Some(Message_oneof_union::login_response(_)) => "login_response",
            Some(Message_oneof_union::hash(_)) => "hash",
            Some(Message_oneof_union::mouse_event(_)) => "mouse_event",
            Some(Message_oneof_union::audio_frame(_)) => "audio_frame",
            Some(Message_oneof_union::cursor_data(_)) => "cursor_data",
            Some(Message_oneof_union::cursor_position(_)) => "cursor_position",
            Some(Message_oneof_union::cursor_id(_)) => "cursor_id",
            Some(Message_oneof_union::key_event(_)) => "key_event",
            Some(Message_oneof_union::clipboard(_)) => "clipboard",
            Some(Message_oneof_union::file_action(_)) => "file_action",
            Some(Message_oneof_union::file_response(_)) => "file_response",
            Some(Message_oneof_union::misc(_)) => "misc",
            Some(Message_oneof_union::cliprdr(_)) => "cliprdr",
            Some(Message_oneof_union::message_box(_)) => "message_box",
            Some(Message_oneof_union::switch_sides_response(_)) => "switch_sides_response",
            Some(Message_oneof_union::voice_call_request(_)) => "voice_call_request",
            Some(Message_oneof_union::voice_call_response(_)) => "voice_call_response",
            Some(Message_oneof_union::peer_info(_)) => "peer_info",
            Some(Message_oneof_union::pointer_device_event(_)) => "pointer_device_event",
            Some(Message_oneof_union::auth_2fa(_)) => "auth_2fa",
            Some(Message_oneof_union::multi_clipboards(_)) => "multi_clipboards",
            Some(Message_oneof_union::screenshot_request(_)) => "screenshot_request",
            Some(Message_oneof_union::screenshot_response(_)) => "screenshot_response",
            Some(Message_oneof_union::terminal_action(_)) => "terminal_action",
            Some(Message_oneof_union::terminal_response(_)) => "terminal_response",
            None => "none",
        }
    }

    fn handle_login_response(&mut self, resp: LoginResponse) -> io::Result<()> {
        if resp.has_error() {
            let err = resp.get_error().to_string();
            self.state = SessionState::Error(err.clone());
            return Err(io::Error::new(io::ErrorKind::PermissionDenied, err));
        }
        if let Some(LoginResponse_oneof_union::peer_info(info)) = resp.union {
            self.peer_info = Some(info);
        }
        self.state = SessionState::Connected;
        Ok(())
    }

    fn local_client_id(peer_id: &str) -> String {
        let mut hasher = Sha256::new();
        hasher.update(b"harmonyos-remotedesktop:");
        hasher.update(peer_id.as_bytes());
        let digest = hasher.finalize();
        let mut value = u32::from_le_bytes([digest[0], digest[1], digest[2], digest[3]]);
        value = value % 900_000_000 + 100_000_000;
        value.to_string()
    }

    /// 发送 LoginRequest 并等待 LoginResponse (明文 TCP)
    ///
    /// stream: 已连接的 TCP stream (来自 Rendezvous 直连或中继)
    /// my_id: 本端 peer ID
    /// password: 远程主机密码 (可为空)
    pub fn login(&mut self, stream: &mut TcpStream, my_id: &str, password: &str) -> io::Result<()> {
        self.state = SessionState::LoggingIn;

        // 1. 构造 LoginRequest
        let mut login = LoginRequest::new();
        login.set_username(my_id.to_string());
        login.set_password(password.as_bytes().to_vec());
        login.set_my_id(my_id.to_string());
        login.set_my_name("HarmonyOS-RemoteDesktop".to_string());
        login.set_session_id(0); // 服务端会分配
        login.set_version("2.0.0".to_string());
        login.set_my_platform("OHOS".to_string());

        // OptionMessage: 图像质量等
        let mut opt = OptionMessage::new();
        opt.set_image_quality(ImageQuality::Balanced);
        login.option = protobuf::SingularPtrField::some(opt);

        // 2. 包装到 Message
        let mut msg = Message::new();
        msg.union = Some(Message_oneof_union::login_request(login));

        // 3. 序列化 → wire 帧 → 发送
        let payload = msg
            .write_to_bytes()
            .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
        wire::write_frame(stream, &payload)?;

        // 4. 接收响应
        let response_payload = wire::read_frame(stream)?;
        let response: Message = protobuf::parse_from_bytes(&response_payload)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;

        // 5. 解析 LoginResponse
        match response.union {
            Some(Message_oneof_union::login_response(resp)) => {
                if resp.has_error() {
                    let err = resp.get_error().to_string();
                    self.state = SessionState::Error(err.clone());
                    return Err(io::Error::new(io::ErrorKind::PermissionDenied, err));
                }

                // 提取 PeerInfo
                if let Some(LoginResponse_oneof_union::peer_info(info)) = resp.union {
                    self.peer_info = Some(info);
                }

                self.state = SessionState::Connected;
                Ok(())
            }
            other => {
                self.state = SessionState::Error(format!("unexpected login response: {:?}", other));
                Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "unexpected login response variant",
                ))
            }
        }
    }

    /// 主循环: 持续接收消息并分发到回调
    ///
    /// 阻塞直到连接关闭或出错。
    /// on_video_frame: 收到视频帧时调用
    /// on_audio_frame: 收到音频帧时调用
    pub fn run_loop<VF, AF>(
        &mut self,
        stream: &mut TcpStream,
        mut on_video_frame: VF,
        mut on_audio_frame: AF,
    ) -> io::Result<()>
    where
        VF: FnMut(&VideoFrame),
        AF: FnMut(&AudioFrame),
    {
        while self.state == SessionState::Connected {
            let payload = wire::read_frame(stream)?;
            let msg: Message = protobuf::parse_from_bytes(&payload)
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;

            match msg.union {
                Some(Message_oneof_union::video_frame(ref vf)) => {
                    on_video_frame(vf);
                }
                Some(Message_oneof_union::audio_frame(ref af)) => {
                    on_audio_frame(af);
                }
                Some(Message_oneof_union::peer_info(ref info)) => {
                    self.peer_info = Some(info.clone());
                }
                Some(Message_oneof_union::login_response(ref resp)) => {
                    // 服务端可能重新发送 login response
                    if resp.has_error() {
                        // 连接被远端终止
                        break;
                    }
                }
                _ => {
                    // 忽略其他消息类型 (clipboard, cursor, etc.)
                }
            }
        }

        self.state = SessionState::Disconnected;
        Ok(())
    }

    /// 发送按键事件
    /// scancode 通过 chr oneof 发送 (Unicode 码点)
    pub fn send_key_event(
        &self,
        stream: &mut TcpStream,
        _scancode: u32,
        down: bool,
    ) -> io::Result<()> {
        let mut key = KeyEvent::new();
        key.set_down(down);

        let mut msg = Message::new();
        msg.union = Some(Message_oneof_union::key_event(key));

        let payload = msg
            .write_to_bytes()
            .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
        wire::write_frame(stream, &payload)
    }

    /// 发送鼠标事件
    /// mask: 鼠标按键掩码 (bit 0=left, 1=right, 2=middle)
    pub fn send_mouse_event(
        &self,
        stream: &mut TcpStream,
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

        let payload = msg
            .write_to_bytes()
            .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
        wire::write_frame(stream, &payload)
    }

    /// 获取会话状态
    pub fn state(&self) -> &SessionState {
        &self.state
    }

    /// 获取远端信息
    pub fn peer_info(&self) -> Option<&PeerInfo> {
        self.peer_info.as_ref()
    }
}
