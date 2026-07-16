//! rustdesk_ffi — RustDesk Core FFI 接口
//!
//! 将 RustDesk 核心功能编译为 C 兼容动态库 (cdylib)，
//! 供 HarmonyOS NAPI 层通过 extern "C" 调用。
//!
//! 许可证: AGPL-3.0 (RustDesk)
//! 推荐使用独立进程通信 (Unix Domain Socket) 避免许可证传染。
//!
//! 交叉编译:
//!   rustup target add aarch64-unknown-linux-ohos
//!   cargo build --release --target aarch64-unknown-linux-ohos

use std::cell::RefCell;
use std::ffi::{c_char, c_void, CStr, CString};
use std::io;
use std::net::{Shutdown, TcpStream};
use std::os::raw::c_int;
use std::ptr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub mod connector;
pub mod crypto;
pub mod crypto_channel;
mod control_inbox;
mod net;
#[cfg(feature = "opus-audio")]
pub mod opus_ffi;
pub mod protocol;
pub mod terminal_core;

use protocol::message_proto::{
    AudioFormat, AudioFrame, EncodedVideoFrames, VideoFrame, VideoFrame_oneof_union,
};
use control_inbox::ControlInbox;

static LAST_ERROR: Mutex<String> = Mutex::new(String::new());
// 每次连接尝试都有单调递增 epoch；取消时递增 epoch，使等待批准的旧线程可退出，
// 同时避免新连接把旧线程的取消状态重置掉。
static CONNECT_EPOCH: AtomicU64 = AtomicU64::new(0);

pub(crate) fn begin_connect_epoch() -> u64 {
    CONNECT_EPOCH.fetch_add(1, Ordering::SeqCst).wrapping_add(1)
}

pub(crate) fn current_connect_epoch() -> u64 {
    CONNECT_EPOCH.load(Ordering::SeqCst)
}

pub(crate) fn connect_cancelled(epoch: u64) -> bool {
    CONNECT_EPOCH.load(Ordering::SeqCst) != epoch
}

fn set_last_error(message: impl Into<String>) {
    if let Ok(mut err) = LAST_ERROR.lock() {
        *err = message.into();
    }
}

fn clear_last_error() {
    set_last_error("");
}

fn ffi_string(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_string_lossy()
        .into_owned()
}

// ============================================================
// 性能 Profile 定义
// ============================================================

/// RustDesk 性能 profile 等级
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RustDeskProfile {
    Stable = 0,      // H264 30fps 1280px Low 质量 — 最稳定
    Balanced = 1,    // H264 45fps 1600px Balanced 质量 — 默认
    Performance = 2, // H264/H265 60fps 1920px Best 质量 — 高性能设备
    Custom = 3,      // 使用显式的 width/height/codec/fps 参数
}

/// Profile 分辨率/FPS/质量映射
pub struct ProfileParams {
    pub max_edge_px: i32,
    pub fps: u32,
    pub codec: i32,         // 0=auto, 4=H264, 5=H265
    pub image_quality: i32, // 0=Low, 1=Balanced, 2=Best
}

impl ProfileParams {
    pub fn from_profile(profile: RustDeskProfile) -> Self {
        match profile {
            RustDeskProfile::Stable => ProfileParams {
                max_edge_px: 1280,
                fps: 30,
                codec: 4,         // H264
                image_quality: 0, // Low
            },
            RustDeskProfile::Balanced => ProfileParams {
                max_edge_px: 1600,
                fps: 60,          // was 45 — revert to known-good 60fps
                codec: 4,         // H264
                image_quality: 1, // Balanced
            },
            RustDeskProfile::Performance => ProfileParams {
                max_edge_px: 1920,
                fps: 60,
                codec: 0,         // Auto (prefer H264, allow H265)
                image_quality: 2, // Best
            },
            RustDeskProfile::Custom => ProfileParams {
                max_edge_px: 1920,
                fps: 60,
                codec: 0,
                image_quality: 1,
            },
        }
    }
}

// ============================================================
// 数据结构 (C 兼容)
// ============================================================

/// RustDesk 连接配置 (C 兼容)
#[repr(C)]
pub struct RustDeskConfig {
    pub host: *const c_char,     // 远程主机 IP 或域名
    pub port: c_int,             // 端口号 (默认 21116)
    pub key: *const c_char,      // Rendezvous 服务器公钥 (可选, 空字符串使用默认公钥)
    pub username: *const c_char, // 用户名 (可选)
    pub password: *const c_char, // 密码 (可选)
    pub width: c_int,            // 期望宽度 (0=auto from profile)
    pub height: c_int,           // 期望高度 (0=auto from profile)
    pub codec: c_int,            // 0=auto, 1=VP8, 2=VP9, 3=AV1, 4=H264, 5=H265
    pub image_quality: c_int,    // 0=Low, 1=Balanced, 2=Best
    pub privacy_mode: bool,
    pub audio_enabled: bool,      // 是否接收远端音频
    pub profile: RustDeskProfile, // 性能 profile (Stable/Balanced/Performance/Custom)
    pub fps: c_int,               // 期望 FPS (0=from profile)
    /// 直连模式: false=走 rendezvous 服务器 (默认), true=TCP 直连 peer (跳过 rendezvous)
    pub direct_connection: bool,
    pub auth_mode: c_int, // 0=设备密码, 1=请求被控端点击批准
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct ResolvedStreamParams {
    preferred_codec: i32,
    image_quality: i32,
    effective_fps: u32,
    req_width: i32,
    req_height: i32,
}

fn resolve_stream_params_for_config(config: &RustDeskConfig) -> ResolvedStreamParams {
    let profile_params = ProfileParams::from_profile(config.profile);
    let preferred_codec = if config.codec != 0 {
        config.codec
    } else {
        profile_params.codec
    };
    let mut image_quality = if config.image_quality >= 0 {
        config.image_quality
    } else {
        profile_params.image_quality
    };
    let mut effective_fps = if config.fps > 0 {
        config.fps as u32
    } else {
        profile_params.fps
    };

    if matches!(preferred_codec, 1 | 2 | 3) && config.fps <= 0 {
        effective_fps = effective_fps.min(45);
    }
    if matches!(config.profile, RustDeskProfile::Stable) && config.fps <= 0 {
        effective_fps = effective_fps.min(30);
    }
    if matches!(
        config.profile,
        RustDeskProfile::Stable | RustDeskProfile::Balanced
    ) {
        image_quality = image_quality.min(profile_params.image_quality);
    }

    ResolvedStreamParams {
        preferred_codec,
        image_quality,
        effective_fps,
        req_width: if config.width > 0 {
            config.width
        } else {
            profile_params.max_edge_px
        },
        req_height: if config.height > 0 {
            config.height
        } else {
            1080
        },
    }
}

/// 视频帧数据
#[repr(C)]
pub struct FfiVideoFrame {
    pub data: *const u8,
    pub size: usize,
    pub width: c_int,
    pub height: c_int,
    pub codec: c_int, // 0=H264, 1=H265, 2=VP8, 3=VP9
    pub timestamp: u64,
    pub is_key_frame: bool,
}

/// 音频数据
#[repr(C)]
pub struct FfiAudioData {
    pub data: *const u8,
    pub size: usize,
    pub sample_rate: c_int,
    pub channels: c_int,
    pub timestamp: u64,
}

/// 连接状态
#[repr(C)]
pub enum FfiConnectionState {
    Disconnected = 0,
    Connecting = 1,
    Connected = 2,
    Reconnecting = 3,
    Error = 4,
}

// ============================================================
// 回调类型
// ============================================================

/// 视频帧回调
pub type FrameCallback = extern "C" fn(frame: *const FfiVideoFrame, user_data: *mut c_void);

/// 音频数据回调
pub type AudioCallback = extern "C" fn(audio: *const FfiAudioData, user_data: *mut c_void);

/// 断开连接回调
pub type DisconnectCallback =
    extern "C" fn(state: FfiConnectionState, message: *const c_char, user_data: *mut c_void);

// ============================================================
// 内部类型: RustDesk 客户端句柄
// ============================================================

/// 线程间控制消息
pub(crate) enum ControlMsg {
    Shutdown,
    RefreshVideo,
    VideoPressure { level: u32 },
    KeyEvent {
        scancode: u32,
        pressed: bool,
    },
    MouseEvent {
        x: i32,
        y: i32,
        button: u32,
        pressed: bool,
    },
    MouseMove {
        x: i32,
        y: i32,
    },
    MouseWheel {
        x: i32,
        y: i32,
        delta: i32,
    },
    Text {
        text: String,
    },
    SendFile {
        remote_path: String,
        data: Vec<u8>,
    },
    Clipboard {
        content: Vec<u8>,
    },
}

/// 客户端上下文 — 通过 FFI 不透明指针传递
struct RustDeskClient {
    #[allow(dead_code)]
    peer_id: String,
    host: String,
    port: u16,
    server_key: String,
    password: String,
    request_approval: bool,
    controls: Arc<ControlInbox>,
    shutdown_stream: Option<TcpStream>,
    stream_handle: Option<std::thread::JoinHandle<io::Result<()>>>,
    transfer_status: Arc<Mutex<RustDeskTransferStatus>>,
    remote_clipboard: Arc<Mutex<Vec<u8>>>,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct RustDeskTransferStatus {
    pub state: u32,
    pub transfer_id: u64,
    pub transferred_bytes: u64,
    pub total_bytes: u64,
    pub diagnostic_code: u32,
}

impl Default for RustDeskTransferStatus {
    fn default() -> Self {
        Self { state: 0, transfer_id: 0, transferred_bytes: 0, total_bytes: 0, diagnostic_code: 0 }
    }
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

fn dispatch_encoded_frames(
    frames: &EncodedVideoFrames,
    codec: c_int,
    width: c_int,
    height: c_int,
    on_frame: FrameCallback,
    user_data: *mut c_void,
) {
    static FFI_FRAME_CB_COUNT: AtomicU64 = AtomicU64::new(0);
    static FFI_SUBFRAME_TOTAL: AtomicU64 = AtomicU64::new(0);
    for frame in frames.get_frames() {
        let data = frame.get_data();
        if data.is_empty() {
            continue;
        }
        let ffi_frame = FfiVideoFrame {
            data: data.as_ptr(),
            size: data.len(),
            width,
            height,
            codec,
            timestamp: frame.get_pts().max(0) as u64,
            is_key_frame: frame.get_key(),
        };
        on_frame(&ffi_frame, user_data);
        // Fast-path counters only (no format/IO in hot path)
        FFI_FRAME_CB_COUNT.fetch_add(1, Ordering::Relaxed);
        FFI_SUBFRAME_TOTAL.fetch_add(1, Ordering::Relaxed);
    }
}

fn dispatch_video_frame(
    frame: &VideoFrame,
    width: c_int,
    height: c_int,
    on_frame: Option<FrameCallback>,
    user_data: *mut c_void,
) {
    let Some(on_frame) = on_frame else {
        return;
    };

    match frame.union {
        Some(VideoFrame_oneof_union::h264s(ref frames)) => {
            dispatch_encoded_frames(frames, 0, width, height, on_frame, user_data);
        }
        Some(VideoFrame_oneof_union::h265s(ref frames)) => {
            dispatch_encoded_frames(frames, 1, width, height, on_frame, user_data);
        }
        Some(VideoFrame_oneof_union::vp8s(ref frames)) => {
            dispatch_encoded_frames(frames, 2, width, height, on_frame, user_data);
        }
        Some(VideoFrame_oneof_union::vp9s(ref frames)) => {
            dispatch_encoded_frames(frames, 3, width, height, on_frame, user_data);
        }
        Some(VideoFrame_oneof_union::av1s(ref frames)) => {
            dispatch_encoded_frames(frames, 4, width, height, on_frame, user_data);
        }
        Some(VideoFrame_oneof_union::rgb(_)) | Some(VideoFrame_oneof_union::yuv(_)) | None => {}
    }
}

/// Async audio worker — runs Opus decode + PCM callback on dedicated thread.
/// Streaming loop pushes raw Opus data via bounded channel; no blocking.
struct AudioWorker {
    #[cfg(feature = "opus-audio")]
    sender: Option<std::sync::mpsc::SyncSender<Vec<u8>>>,
    #[cfg(feature = "opus-audio")]
    handle: Option<std::thread::JoinHandle<()>>,
}

impl AudioWorker {
    /// Start audio worker thread. Returns None if startup fails.
    fn start(
        sample_rate: u32,
        channels: u32,
        on_audio: AudioCallback,
        user_data: *mut c_void,
    ) -> Option<Self> {
        #[cfg(not(feature = "opus-audio"))]
        {
            let _ = (sample_rate, channels, on_audio, user_data);
            eprintln!("[RustDesk-FFI] audio worker: opus-audio feature disabled");
            return None;
        }

        #[cfg(feature = "opus-audio")]
        {
        let mut decoder = match opus_ffi::OpusDecoderHandle::new(sample_rate, channels) {
            Ok(d) => d,
            Err(e) => {
                eprintln!("[RustDesk-FFI] audio worker: decoder init failed err={}", e);
                return None;
            }
        };
        // Bounded channel: buffer up to 16 Opus frames (~320ms at 50fps).
        let (tx, rx) = std::sync::mpsc::sync_channel::<Vec<u8>>(16);
        // Cast raw pointer to usize for Send safety across thread boundary
        let ud = user_data as usize;

        let handle = std::thread::spawn(move || {
            let mut decode_buf = vec![0.0_f32; (sample_rate * channels) as usize];
            let mut pcm_buf = Vec::<u8>::with_capacity(4096);

            for opus_data in rx {
                if opus_data.is_empty() {
                    continue;
                }
                match decoder.decode_float(&opus_data, &mut decode_buf, false) {
                    Ok(sample_count) => {
                        pcm_buf.clear();
                        pcm_buf.reserve(sample_count * 2);
                        for sample in decode_buf.iter().take(sample_count) {
                            let clamped = sample.clamp(-1.0, 1.0);
                            let pcm = (clamped * i16::MAX as f32) as i16;
                            pcm_buf.extend_from_slice(&pcm.to_le_bytes());
                        }
                        if !pcm_buf.is_empty() {
                            let ffi_audio = FfiAudioData {
                                data: pcm_buf.as_ptr(),
                                size: pcm_buf.len(),
                                sample_rate: sample_rate as c_int,
                                channels: channels as c_int,
                                timestamp: 0,
                            };
                            on_audio(&ffi_audio, ud as *mut c_void);
                        }
                    }
                    Err(_e) => {
                        // Decode errors are expected occasionally; skip silently
                    }
                }
            }
        });

        Some(Self {
            sender: Some(tx),
            handle: Some(handle),
        })
        }
    }

    /// Push raw Opus frame to worker. Non-blocking.
    /// Returns false if channel full (frame dropped).
    fn push(&self, opus_data: &[u8]) -> bool {
        #[cfg(not(feature = "opus-audio"))]
        {
            let _ = opus_data;
            return false;
        }

        #[cfg(feature = "opus-audio")]
        {
        if opus_data.is_empty() {
            return false;
        }
        match &self.sender {
            Some(tx) => tx.try_send(opus_data.to_vec()).is_ok(),
            None => false,
        }
        }
    }

    /// Stop worker and join thread.
    fn stop(&mut self) {
        #[cfg(feature = "opus-audio")]
        {
        self.sender = None; // drop sender → close channel → worker thread exits
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
        }
    }
}

/// Audio pipeline state (tracked in streaming loop).
/// Decode work happens in AudioWorker thread.
struct AudioPipeline {
    worker: Option<AudioWorker>,
    sample_rate: u32,
    channels: u32,
    format_received: bool,
    frames_pushed: u64,
    frames_dropped: u64,
}

impl AudioPipeline {
    fn new() -> Self {
        Self {
            worker: None,
            sample_rate: 48000,
            channels: 2,
            format_received: false,
            frames_pushed: 0,
            frames_dropped: 0,
        }
    }

    fn handle_format(
        &mut self,
        format: &AudioFormat,
        on_audio: AudioCallback,
        user_data: *mut c_void,
    ) {
        let sr = if format.sample_rate > 0 {
            format.sample_rate
        } else {
            48000
        };
        let ch = if format.channels > 0 {
            format.channels
        } else {
            2
        };
        self.sample_rate = sr;
        self.channels = ch;

        // Stop old worker, start new one with updated format
        if let Some(ref mut w) = self.worker {
            w.stop();
        }
        self.worker = AudioWorker::start(sr, ch, on_audio, user_data);
        self.format_received = self.worker.is_some();
        if self.format_received {
            eprintln!(
                "[RustDesk-FFI] audio pipeline {}Hz {}ch worker=started",
                sr, ch
            );
        }
    }

    fn push_frame(&mut self, audio: &AudioFrame) {
        let data = audio.get_data();
        if data.is_empty() {
            return;
        }
        let Some(ref worker) = self.worker else {
            if self.frames_dropped == 0 {
                eprintln!("[RustDesk-FFI] audio push: no worker yet, dropping frame");
            }
            self.frames_dropped += 1;
            return;
        };
        if worker.push(data) {
            self.frames_pushed += 1;
        } else {
            self.frames_dropped += 1;
            if self.frames_dropped <= 5 || self.frames_dropped % 100 == 0 {
                eprintln!(
                    "[RustDesk-FFI] audio worker channel full: dropped={} pushed={}",
                    self.frames_dropped, self.frames_pushed
                );
            }
        }
        // Minimal logging — audio is background, don't spam eprintln
    }

    fn stop(&mut self) {
        if let Some(ref mut w) = self.worker {
            w.stop();
        }
        self.worker = None;
    }
}

fn notify_disconnect(
    on_disconnect: Option<DisconnectCallback>,
    state: FfiConnectionState,
    message: &str,
    user_data: *mut c_void,
) {
    let Some(on_disconnect) = on_disconnect else {
        return;
    };
    let safe_message = message.replace('\0', " ");
    let c_message = CString::new(safe_message).unwrap_or_else(|_| CString::new("").unwrap());
    on_disconnect(state, c_message.as_ptr(), user_data);
}

// ============================================================
// FFI 导出函数
// ============================================================

/// 创建 RustDesk 连接 (完整管线: Rendezvous → KeyExchange → Login)
///
/// 此函数阻塞直到登录完成 (通常 5-15s)。
/// 应在独立线程中调用。
/// 成功返回不透明句柄，失败返回 null。
#[no_mangle]
pub extern "C" fn rustdesk_connect(
    cfg: *const RustDeskConfig,
    on_frame: Option<FrameCallback>,
    on_audio: Option<AudioCallback>,
    on_disconnect: Option<DisconnectCallback>,
    user_data: *mut c_void,
) -> *mut c_void {
    clear_last_error();
    let _connect_epoch = begin_connect_epoch();
    if cfg.is_null() {
        set_last_error("config pointer is null");
        return std::ptr::null_mut();
    }

    let config = unsafe { &*cfg };
    let host = ffi_string(config.host);
    let port = if config.port > 0 {
        config.port as u16
    } else {
        21116u16
    };
    let peer_id = ffi_string(config.username);
    let server_key = ffi_string(config.key);
    let password = ffi_string(config.password);
    let request_approval = config.auth_mode == 1 && !config.direct_connection;
    let privacy_mode = config.privacy_mode;
    let audio_enabled = config.audio_enabled;

    let stream_params = resolve_stream_params_for_config(config);
    let preferred_codec = stream_params.preferred_codec;
    let image_quality = stream_params.image_quality;
    let effective_fps = stream_params.effective_fps;
    let req_width = stream_params.req_width;
    let req_height = stream_params.req_height;
    eprintln!(
        "[RustDesk-FFI] config profile={:?} codec={} raw_quality={} quality={} raw_fps={} fps={} audio={} res={}x{}",
        config.profile,
        preferred_codec,
        config.image_quality,
        image_quality,
        config.fps,
        effective_fps,
        if audio_enabled { "on" } else { "off" },
        req_width,
        req_height
    );

    if host.is_empty() {
        set_last_error("rendezvous host is empty");
        return std::ptr::null_mut();
    }
    if peer_id.is_empty() {
        set_last_error("peer id is empty");
        return std::ptr::null_mut();
    }

    // 运行完整连接管线
    let mut c = connector::RustDeskConnector::new();
    let result = if config.direct_connection {
        // 直连模式: host=peer IP, port=peer port, 跳过 rendezvous
        eprintln!(
            "[RustDesk-FFI] direct_connection=true, connecting to peer {}:{}",
            host, port
        );
        c.connect_direct(
            &host,
            port,
            &password,
            preferred_codec,
            image_quality,
            privacy_mode,
            audio_enabled,
            effective_fps,
        )
    } else {
        c.connect(
            &host,
            port,
            &server_key,
            &peer_id,
            &password,
            preferred_codec,
            image_quality,
            privacy_mode,
            audio_enabled,
            effective_fps,
            request_approval,
        )
    };

    match result {
        Ok(()) => {
            // 登录成功 — 创建可合并的控制收件箱，用于后续控制。
            let controls = Arc::new(ControlInbox::default());
            let stream_controls = Arc::clone(&controls);
            let shutdown_stream = c.try_clone_stream().ok();
            let callback_user_data = user_data as usize;
            let remote_clipboard = Arc::new(Mutex::new(Vec::<u8>::new()));
            let stream_remote_clipboard = Arc::clone(&remote_clipboard);
            let (remote_width, remote_height) = c
                .peer_display_size()
                .unwrap_or((config.width.max(1), config.height.max(1)));
            eprintln!(
                "[RustDesk-FFI] remote display size={}x{} requested={}x{}",
                remote_width, remote_height, config.width, config.height
            );

            let stream_handle = std::thread::spawn(move || {
                let callback_user_data = callback_user_data as *mut c_void;
                let audio_pipeline = RefCell::new(AudioPipeline::new());
                let result = c.run_streaming(
                    preferred_codec,
                    image_quality,
                    privacy_mode,
                    audio_enabled,
                    effective_fps,
                    stream_controls,
                    |frame| {
                        dispatch_video_frame(
                            frame,
                            remote_width,
                            remote_height,
                            on_frame,
                            callback_user_data,
                        )
                    },
                    |format| {
                        if audio_enabled {
                            if let Some(on_audio_cb) = on_audio {
                                audio_pipeline.borrow_mut().handle_format(
                                    format,
                                    on_audio_cb,
                                    callback_user_data,
                                );
                            }
                        }
                    },
                    |audio| {
                        if audio_enabled {
                            audio_pipeline.borrow_mut().push_frame(audio);
                        }
                    },
                    |content| {
                        if let Ok(mut clipboard) = stream_remote_clipboard.lock() {
                            clipboard.clear();
                            clipboard.extend_from_slice(&content[..content.len().min(65536)]);
                        }
                    },
                );

                // Stop audio worker
                audio_pipeline.borrow_mut().stop();

                match &result {
                    Ok(()) => {
                        let msg = format!("streaming stopped — {}", c.stream_stats);
                        set_last_error(msg.clone());
                        notify_disconnect(
                            on_disconnect,
                            FfiConnectionState::Disconnected,
                            &msg,
                            callback_user_data,
                        );
                    }
                    Err(err) => {
                        let msg = format!("streaming failed: {}", err);
                        set_last_error(msg.clone());
                        notify_disconnect(
                            on_disconnect,
                            FfiConnectionState::Error,
                            &msg,
                            callback_user_data,
                        );
                    }
                }

                result
            });

            let ctx = Box::new(RustDeskClient {
                peer_id,
                host,
                port,
                server_key,
                password,
                request_approval,
                controls,
                shutdown_stream,
                stream_handle: Some(stream_handle),
                transfer_status: Arc::new(Mutex::new(RustDeskTransferStatus::default())),
                remote_clipboard,
            });

            Box::into_raw(ctx) as *mut c_void
        }
        Err(err) => {
            set_last_error(format!(
                "connect pipeline failed: state={:?}, error={}",
                c.state(),
                err
            ));
            std::ptr::null_mut()
        }
    }
}

/// 取消尚未返回会话句柄的连接尝试（尤其是等待被控端批准的连接）。
#[no_mangle]
pub extern "C" fn rustdesk_cancel_pending_connect() {
    CONNECT_EPOCH.fetch_add(1, Ordering::SeqCst);
}

/// 复制最近一次连接错误到调用方缓冲区，返回完整错误长度。
#[no_mangle]
pub extern "C" fn rustdesk_last_error(buffer: *mut c_char, buffer_len: usize) -> usize {
    let message = LAST_ERROR
        .lock()
        .map(|err| err.clone())
        .unwrap_or_else(|_| "last error lock poisoned".to_string());
    let bytes = message.as_bytes();
    if !buffer.is_null() && buffer_len > 0 {
        let copy_len = bytes.len().min(buffer_len - 1);
        unsafe {
            ptr::copy_nonoverlapping(bytes.as_ptr(), buffer as *mut u8, copy_len);
            *buffer.add(copy_len) = 0;
        }
    }
    bytes.len()
}

/// 断开 RustDesk 连接并释放资源
#[no_mangle]
pub extern "C" fn rustdesk_disconnect(handle: *mut c_void) {
    if handle.is_null() {
        return;
    }

    unsafe {
        let mut ctx = Box::from_raw(handle as *mut RustDeskClient);
        ctx.controls.request_shutdown();
        if let Some(stream) = ctx.shutdown_stream.take() {
            let _ = stream.shutdown(Shutdown::Both);
        }
        if let Some(h) = ctx.stream_handle.take() {
            let _ = h.join();
        }
        // Drop ctx → 释放所有资源
    }
}

/// 请求远端立即刷新视频帧
#[no_mangle]
pub extern "C" fn rustdesk_request_frame_refresh(handle: *mut c_void) -> bool {
    if handle.is_null() {
        set_last_error("rustdesk_request_frame_refresh null handle");
        return false;
    }
    let ctx = unsafe { &*(handle as *const RustDeskClient) };
    ctx.controls.enqueue(ControlMsg::RefreshVideo);
    set_last_error("rustdesk_request_frame_refresh enqueued");
    true
}

#[no_mangle]
pub extern "C" fn rustdesk_report_video_pressure(handle: *mut c_void, level: c_int) -> bool {
    if handle.is_null() {
        set_last_error("rustdesk_report_video_pressure null handle");
        return false;
    }
    let clamped = level.clamp(0, 3) as u32;
    let ctx = unsafe { &*(handle as *const RustDeskClient) };
    ctx.controls.enqueue(ControlMsg::VideoPressure { level: clamped });
    true
}

/// 发送键盘事件
#[no_mangle]
pub extern "C" fn rustdesk_send_key(handle: *mut c_void, scancode: u32, pressed: bool) {
    if handle.is_null() {
        return;
    }
    let ctx = unsafe { &*(handle as *const RustDeskClient) };
    ctx.controls.enqueue(ControlMsg::KeyEvent { scancode, pressed });
    set_last_error(format!(
        "rustdesk_send_key enqueue scancode={} pressed={}",
        scancode, pressed
    ));
}

/// 发送鼠标事件
#[no_mangle]
pub extern "C" fn rustdesk_send_mouse(
    handle: *mut c_void,
    x: i32,
    y: i32,
    button: u32,
    pressed: bool,
) {
    if handle.is_null() {
        return;
    }
    let ctx = unsafe { &*(handle as *const RustDeskClient) };
    let msg = if button == u32::MAX {
        ControlMsg::MouseMove { x, y }
    } else {
        ControlMsg::MouseEvent {
            x,
            y,
            button,
            pressed,
        }
    };
    ctx.controls.enqueue(msg);
}

/// 发送鼠标滚轮事件
#[no_mangle]
pub extern "C" fn rustdesk_send_mouse_wheel(handle: *mut c_void, x: i32, y: i32, delta: i32) {
    if handle.is_null() {
        return;
    }
    let ctx = unsafe { &*(handle as *const RustDeskClient) };
    ctx.controls.enqueue(ControlMsg::MouseWheel { x, y, delta });
}

/// 发送文本
#[no_mangle]
pub extern "C" fn rustdesk_send_text(handle: *mut c_void, text: *const c_char) {
    if handle.is_null() || text.is_null() {
        return;
    }
    let ctx = unsafe { &*(handle as *const RustDeskClient) };
    let text = unsafe { CStr::from_ptr(text) }
        .to_string_lossy()
        .into_owned();
    let len = text.len();
    ctx.controls.enqueue(ControlMsg::Text { text });
    let msg = format!("rustdesk_send_text enqueue len={}", len);
    set_last_error(msg.clone());
    eprintln!("[RustDesk-FFI] {}", msg);
}

/// 发送文件到远程桌面
///
/// remote_path: 目标路径 (如 `C:\Users\Public\Documents\RemoteDesktop\readme.txt`)
/// data: 文件字节
/// len: 数据长度
#[no_mangle]
pub extern "C" fn rustdesk_send_file(
    handle: *mut c_void,
    transfer_id: u64,
    remote_path: *const c_char,
    data: *const u8,
    len: u32,
) -> i32 {
    if handle.is_null() || remote_path.is_null() || data.is_null() || len == 0 {
        return -1;
    }
    let ctx = unsafe { &*(handle as *const RustDeskClient) };
    let path = unsafe { CStr::from_ptr(remote_path) }
        .to_string_lossy()
        .into_owned();
    let file_data = unsafe { std::slice::from_raw_parts(data, len as usize) }.to_vec();
    if let Ok(mut status) = ctx.transfer_status.lock() {
        *status = RustDeskTransferStatus { state: 2, transfer_id, transferred_bytes: 0,
            total_bytes: len as u64, diagnostic_code: 0 };
    }
    let host = ctx.host.clone();
    let port = ctx.port;
    let server_key = ctx.server_key.clone();
    let peer_id = ctx.peer_id.clone();
    let password = ctx.password.clone();
    let request_approval = ctx.request_approval;
    let remote_path_owned = path.clone();
    let remote_dir = split_remote_file_path(&path).0.to_string();
    let transfer_status = Arc::clone(&ctx.transfer_status);

    std::thread::spawn(move || {
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let mut connector = connector::RustDeskConnector::new();
            connector
                .connect_file_transfer(&host, port, &server_key, &peer_id, &password, &remote_dir,
                    request_approval)
                .and_then(|_| {
                    connector.upload_file_once(
                        &remote_path_owned,
                        file_data,
                        Duration::from_secs(30),
                    )
                })
        }))
        .unwrap_or_else(|_| {
            Err(std::io::Error::new(
                std::io::ErrorKind::Other,
                "file-transfer worker panic",
            ))
        });

        match result {
            Ok(()) => {
                if let Ok(mut status) = transfer_status.lock() {
                    *status = RustDeskTransferStatus { state: 3, transfer_id,
                        transferred_bytes: len as u64, total_bytes: len as u64, diagnostic_code: 0 };
                }
            }
            Err(_) => {
                if let Ok(mut status) = transfer_status.lock() {
                    *status = RustDeskTransferStatus { state: 4, transfer_id,
                        transferred_bytes: 0, total_bytes: len as u64, diagnostic_code: 1 };
                }
            }
        }
    });
    0
}

#[no_mangle]
pub extern "C" fn rustdesk_get_transfer_status(handle: *mut c_void,
    out_status: *mut RustDeskTransferStatus) -> bool {
    if handle.is_null() || out_status.is_null() { return false; }
    let ctx = unsafe { &*(handle as *const RustDeskClient) };
    let status = match ctx.transfer_status.lock() { Ok(value) => *value, Err(_) => return false };
    unsafe { *out_status = status; }
    true
}

/// 发送剪贴板内容到远程
#[no_mangle]
pub extern "C" fn rustdesk_send_clipboard(handle: *mut c_void, data: *const u8, len: u32) {
    if handle.is_null() || data.is_null() || len == 0 {
        return;
    }
    let ctx = unsafe { &*(handle as *const RustDeskClient) };
    let content = unsafe { std::slice::from_raw_parts(data, len as usize) }.to_vec();
    ctx.controls.enqueue(ControlMsg::Clipboard { content });
}

#[no_mangle]
pub extern "C" fn rustdesk_get_clipboard(handle: *mut c_void, buffer: *mut u8,
    buffer_len: usize) -> usize {
    if handle.is_null() { return 0; }
    let ctx = unsafe { &*(handle as *const RustDeskClient) };
    let clipboard = match ctx.remote_clipboard.lock() { Ok(value) => value, Err(_) => return 0 };
    let full_len = clipboard.len();
    if !buffer.is_null() && buffer_len > 0 {
        let copy_len = full_len.min(buffer_len);
        unsafe { std::ptr::copy_nonoverlapping(clipboard.as_ptr(), buffer, copy_len); }
    }
    full_len
}

/// 获取版本号
#[no_mangle]
pub extern "C" fn rustdesk_version() -> *const c_char {
    "2.1.0-crypto\0".as_ptr() as *const c_char
}

// ============================================================
// 单元测试 (cargo test)
// ============================================================

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    /// 测试空配置返回 null
    #[test]
    fn test_rustdesk_connect_null_config() {
        extern "C" fn dummy_frame(_frame: *const FfiVideoFrame, _data: *mut c_void) {}
        extern "C" fn dummy_audio(_audio: *const FfiAudioData, _data: *mut c_void) {}
        extern "C" fn dummy_disconnect(
            _state: FfiConnectionState,
            _msg: *const c_char,
            _data: *mut c_void,
        ) {
        }

        let handle = rustdesk_connect(
            std::ptr::null(),
            Some(dummy_frame),
            Some(dummy_audio),
            Some(dummy_disconnect),
            std::ptr::null_mut(),
        );
        assert!(handle.is_null(), "空配置应返回 null");
    }

    /// 测试连接到无效地址应返回 null (不会崩溃)
    #[test]
    fn test_rustdesk_connect_invalid_host() {
        let host = CString::new("127.255.255.254").unwrap(); // 无效地址
        let key = CString::new("").unwrap();
        let username = CString::new("test").unwrap();
        let password = CString::new("").unwrap();

        let cfg = RustDeskConfig {
            host: host.as_ptr(),
            port: 1, // 无效端口 — 立即失败
            key: key.as_ptr(),
            username: username.as_ptr(),
            password: password.as_ptr(),
            width: 1920,
            height: 1080,
            codec: 4,
            image_quality: 1,
            privacy_mode: false,
            audio_enabled: true,
            profile: RustDeskProfile::Balanced,
            fps: 0,
            direct_connection: false,
            auth_mode: 0,
        };

        extern "C" fn dummy_frame(_frame: *const FfiVideoFrame, _data: *mut c_void) {}
        extern "C" fn dummy_audio(_audio: *const FfiAudioData, _data: *mut c_void) {}
        extern "C" fn dummy_disconnect(
            _state: FfiConnectionState,
            _msg: *const c_char,
            _data: *mut c_void,
        ) {
        }

        // 无效连接应快速返回 null (不会阻塞很久)
        let handle = rustdesk_connect(
            &cfg,
            Some(dummy_frame),
            Some(dummy_audio),
            Some(dummy_disconnect),
            std::ptr::null_mut(),
        );
        assert!(handle.is_null(), "无效地址应返回 null");
    }

    /// 测试 disconnect(null) 不崩溃
    #[test]
    fn test_rustdesk_disconnect_null() {
        rustdesk_disconnect(std::ptr::null_mut());
        // 不崩溃即为通过
    }

    #[test]
    fn test_rustdesk_version() {
        let version_ptr = rustdesk_version();
        assert!(!version_ptr.is_null());
        let version = unsafe { CStr::from_ptr(version_ptr) }.to_string_lossy();
        assert!(version.contains("crypto"), "版本应包含 'crypto'");
    }

    #[test]
    fn balanced_profile_keeps_60fps_and_clamps_best_quality() {
        let cfg = RustDeskConfig {
            host: std::ptr::null(),
            port: 21116,
            key: std::ptr::null(),
            username: std::ptr::null(),
            password: std::ptr::null(),
            width: 742,
            height: 1600,
            codec: 0,
            image_quality: 2,
            privacy_mode: false,
            audio_enabled: true,
            profile: RustDeskProfile::Balanced,
            fps: 0,
            direct_connection: false,
            auth_mode: 0,
        };

        let params = resolve_stream_params_for_config(&cfg);

        assert_eq!(params.preferred_codec, 4);
        assert_eq!(params.image_quality, 1);
        assert_eq!(params.effective_fps, 60);
        assert_eq!(params.req_width, 742);
        assert_eq!(params.req_height, 1600);
    }
}
