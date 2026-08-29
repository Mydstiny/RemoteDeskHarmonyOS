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
use std::sync::{Arc, Condvar, LazyLock, Mutex};
use std::time::{Duration, Instant};
use std::collections::{HashMap, HashSet, VecDeque};

pub mod connector;
pub mod crypto;
pub mod crypto_channel;
mod control_inbox;
mod cursor_state;
mod net;
mod safe_diagnostics;
#[cfg(feature = "opus-audio")]
pub mod opus_ffi;
pub mod protocol;
pub mod terminal_core;

use protocol::message_proto::{
    AudioFormat, AudioFrame, EncodedVideoFrames, VideoFrame, VideoFrame_oneof_union,
};
use protocol::rendezvous::RendezvousClient;
use protocol::session::AuthEventCallback;
use control_inbox::ControlInbox;
use cursor_state::CursorStreamUpdate;
use std::sync::mpsc::Sender;

static LAST_ERROR: Mutex<String> = Mutex::new(String::new());
static RUSTDESK_MOUSE_ENQUEUE_COUNT: AtomicU64 = AtomicU64::new(0);
// 每个连接尝试都有独立 epoch。取消一个 session 只标记它自己的 epoch，
// 不会让另一个 RustDesk 连接的 2FA/批准等待线程退出。
static CONNECT_EPOCH: AtomicU64 = AtomicU64::new(0);
static CANCELLED_EPOCHS: LazyLock<Mutex<HashSet<u64>>> =
    LazyLock::new(|| Mutex::new(HashSet::new()));
static ACTIVE_CONNECT_EPOCHS: LazyLock<Mutex<HashMap<u64, Vec<u64>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
static PENDING_2FA: LazyLock<Mutex<HashMap<u64, PendingTwoFactor>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

struct PendingTwoFactor {
    epoch: u64,
    session_id: u64,
    sender: Sender<String>,
}

pub(crate) fn begin_connect_epoch(session_id: u64) -> u64 {
    let epoch = CONNECT_EPOCH.fetch_add(1, Ordering::SeqCst).wrapping_add(1);
    if let Ok(mut active) = ACTIVE_CONNECT_EPOCHS.lock() {
        active.entry(session_id).or_default().push(epoch);
    }
    epoch
}

pub(crate) fn current_connect_epoch() -> u64 {
    CONNECT_EPOCH.load(Ordering::SeqCst)
}

pub(crate) fn connect_cancelled(epoch: u64) -> bool {
    CANCELLED_EPOCHS.lock().map(|cancelled| cancelled.contains(&epoch)).unwrap_or(true)
}

pub(crate) fn register_pending_2fa(epoch: u64, session_id: u64, sender: Sender<String>) -> io::Result<()> {
    let mut pending = PENDING_2FA
        .lock()
        .map_err(|_| io::Error::new(io::ErrorKind::Other, "2FA pending state lock poisoned"))?;
    let key = if session_id == 0 { epoch } else { session_id };
    pending.insert(key, PendingTwoFactor { epoch, session_id, sender });
    Ok(())
}

pub(crate) fn clear_pending_2fa(epoch: u64, session_id: u64) {
    if let Ok(mut pending) = PENDING_2FA.lock() {
        pending.retain(|_, value| {
            !(value.epoch == epoch && (session_id == 0 || value.session_id == session_id))
        });
    }
}

fn finish_connect_epoch(epoch: u64, session_id: u64) {
    if let Ok(mut active) = ACTIVE_CONNECT_EPOCHS.lock() {
        let remove_session = if let Some(epochs) = active.get_mut(&session_id) {
            epochs.retain(|active_epoch| *active_epoch != epoch);
            epochs.is_empty()
        } else {
            false
        };
        if remove_session {
            active.remove(&session_id);
        }
    }
    if let Ok(mut cancelled) = CANCELLED_EPOCHS.lock() { cancelled.remove(&epoch); }
}

fn cancel_connect_epoch(epoch: u64) {
    if let Ok(mut cancelled) = CANCELLED_EPOCHS.lock() { cancelled.insert(epoch); }
}

pub(crate) fn cancel_pending_connect_for_session(session_id: u64) {
    let epochs: Vec<u64> = if let Ok(active) = ACTIVE_CONNECT_EPOCHS.lock() {
        if session_id == 0 {
            active.values().flat_map(|values| values.iter().copied()).collect()
        } else {
            active.get(&session_id).cloned().unwrap_or_default()
        }
    } else { Vec::new() };
    for epoch in epochs { cancel_connect_epoch(epoch); }
    if let Ok(mut pending) = PENDING_2FA.lock() {
        if session_id == 0 {
            pending.clear();
        } else {
            pending.retain(|_, value| value.session_id != session_id);
        }
    }
}

fn structured_error(
    stage: &str,
    code: &str,
    detail: impl Into<String>,
    attempt: u64,
) -> String {
    let detail = detail.into().replace('|', "/").replace('\n', " ").replace('\r', " ");
    format!(
        "RDERR|stage={}|code={}|attempt={}|detail={}",
        stage, code, attempt, detail
    )
}

fn pipeline_error_classification(
    base_code: &'static str,
    error: &io::Error,
) -> (&'static str, &'static str) {
    let value = error.to_string().to_lowercase();
    if value.contains("please login")
        || value.contains("not logged in")
        || value.contains("login session has expired")
        || value.contains("you have not logged in")
    {
        return (
            "control_plane_login_required",
            "control plane rejected the relay session as unauthenticated",
        );
    }
    if value.contains("wrong password")
        || value.contains("invalid password")
        || value.contains("password is wrong")
    {
        return ("peer_password_rejected", "remote device rejected the device password");
    }
    if value.contains("approval timed out")
        || value.contains("remote approval timed out")
    {
        return ("approval_unavailable", "remote approval was not completed");
    }
    if value.contains("no password access") {
        return (
            "peer_password_required",
            "remote device uses click-approval mode; a device password alone is not accepted, switch to the request-approval flow",
        );
    }
    if value.contains("id does not exist")
        || value.contains("peer not found")
        || value.contains("peer is offline")
        || value.contains("remote desktop is offline")
    {
        return ("peer_unavailable", "remote peer is unavailable");
    }
    if value.contains("license mismatch")
        || value.contains("license overuse")
        || value.contains("key mismatch")
        || value.contains("relay refused")
    {
        return (
            "relay_credential_rejected",
            "relay rejected the configured connection credential",
        );
    }
    let detail = match error.kind() {
        io::ErrorKind::TimedOut => "connection stage timed out",
        io::ErrorKind::ConnectionRefused => "connection stage was refused",
        io::ErrorKind::PermissionDenied => "connection stage was denied",
        io::ErrorKind::NotFound
        | io::ErrorKind::AddrNotAvailable
        | io::ErrorKind::NetworkUnreachable => "connection endpoint is unavailable",
        io::ErrorKind::ConnectionReset
        | io::ErrorKind::ConnectionAborted
        | io::ErrorKind::BrokenPipe => "connection was interrupted",
        io::ErrorKind::InvalidInput => "connection configuration is invalid",
        io::ErrorKind::InvalidData => "server returned an invalid connection response",
        _ => "connection stage failed",
    };
    (base_code, detail)
}

fn pipeline_error_message(
    state: &connector::ConnState,
    error: &io::Error,
    direct_connection: bool,
    attempt: u64,
) -> String {
    let (stage, base_code) = match state {
        connector::ConnState::RendezvousConnecting => ("rendezvous", "rendezvous_failed"),
        connector::ConnState::RequestingRelay => ("relay", "relay_request_failed"),
        connector::ConnState::ConnectingToPeer if direct_connection =>
            ("peer_channel", "direct_peer_connect_failed"),
        connector::ConnState::ConnectingToPeer => ("relay", "relay_endpoint_failed"),
        connector::ConnState::KeyExchanging => ("peer_channel", "peer_channel_failed"),
        connector::ConnState::LoggingIn => ("peer_login", "peer_login_failed"),
        _ => ("unknown", "connect_failed")
    };
    let (code, detail) = pipeline_error_classification(base_code, error);
    structured_error(stage, code, detail, attempt)
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
    pub key: *const c_char,      // Rendezvous 公钥或共享准入 Key (可选)
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
    /// 0=legacy/auto, 1=Ed25519 server public key, 2=shared hbbs/hbbr -k text.
    /// Appended to preserve the established C ABI field order.
    pub key_mode: c_int,
    /// Server Pro control-plane session token. Transient only; never persist.
    /// Appended to preserve the established C ABI field order.
    pub token: *const c_char,
    /// Native session identity used to isolate pending Peer 2FA and cancel
    /// only the connection attempt that owns this config.
    /// Appended to preserve the established C ABI field order.
    pub connection_id: u64,
    /// Configured hbbr fallback port. The hbbs relay_server endpoint keeps an
    /// explicit port when one is advertised.
    /// Appended to preserve the established C ABI field order.
    pub relay_fallback_port: c_int,
}

/// Result of a non-authenticating RustDesk liveness probe.
/// state: 0=unknown, 1=online, 2=offline.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct RustDeskPresenceResult {
    pub state: c_int,
    pub latency_ms: c_int,
    pub error_code: c_int,
}

const DEFAULT_RELAY_PORT: u16 = 21117;

fn relay_fallback_port_from_config(value: c_int) -> u16 {
    if (1..=u16::MAX as c_int).contains(&value) {
        value as u16
    } else {
        DEFAULT_RELAY_PORT
    }
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
    let image_quality = if (0..=2).contains(&config.image_quality) {
        config.image_quality
    } else {
        profile_params.image_quality
    };
    let mut effective_fps = if config.fps > 0 {
        config.fps as u32
    } else {
        profile_params.fps
    };

    // VP8/AV1 retain the conservative default. VP9 is deliberately requested
    // at the profile's full rate; local device capability determines achieved
    // throughput instead of an artificial client-side 45 FPS ceiling.
    if matches!(preferred_codec, 1 | 3) && config.fps <= 0 {
        effective_fps = effective_fps.min(45);
    }
    if matches!(config.profile, RustDeskProfile::Stable) && config.fps <= 0 {
        effective_fps = effective_fps.min(30);
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

/// Legacy encoded video frame passed across the Rust/C++ boundary.
///
/// This layout is kept stable for callers of `rustdesk_connect`. The callback
/// only borrows `data` for the duration of the callback. Consumers must copy
/// the bytes before returning when they need asynchronous processing.
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

/// Versioned encoded video frame with RustDesk display routing metadata.
///
/// This is intentionally a separate C ABI type instead of an appended tail on
/// `FfiVideoFrame`: a V1 caller must never cause the producer or consumer to
/// read beyond the memory guaranteed by the V1 contract.
#[repr(C)]
pub struct FfiVideoFrameV2 {
    pub data: *const u8,
    pub size: usize,
    pub width: c_int,
    pub height: c_int,
    pub codec: c_int, // 0=H264, 1=H265, 2=VP8, 3=VP9
    pub timestamp: u64,
    pub is_key_frame: bool,
    pub display: c_int,
    pub abi_version: u32,
    pub struct_size: u32,
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

/// Remote cursor update. Pixel bytes are valid only for the callback duration.
#[repr(C)]
pub struct FfiCursorUpdate {
    pub kind: c_int, // 0=shape, 1=position, 2=visibility, 3=cache miss
    pub shape_id: u64,
    pub x: c_int,
    pub y: c_int,
    pub width: c_int,
    pub height: c_int,
    pub hot_x: c_int,
    pub hot_y: c_int,
    pub rgba: *const u8,
    pub rgba_len: usize,
    pub visible: bool,
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

/// Per-connection stream telemetry exposed to the HarmonyOS bridge.
///
/// This is deliberately a fixed-width, copyable snapshot. The UI reads it
/// through `rustdesk_get_stream_stats`; it never reaches into the streaming
/// thread or consumes the counters.
pub const RUSTDESK_STREAM_STATS_VERSION: u32 = 1;
pub const RUSTDESK_QUALITY_STATE_VERSION: u32 = 1;
pub const RUSTDESK_PERMISSION_STATE_VERSION: u32 = 1;
pub const RUSTDESK_DISPLAY_SNAPSHOT_VERSION: u32 = 1;
pub const RUSTDESK_DISPLAY_LIST_VERSION: u32 = 1;
pub const RUSTDESK_VIDEO_FRAME_ABI_VERSION: u32 = 2;
pub const RUSTDESK_MAX_DISPLAY_RESOLUTIONS: usize = 32;
pub const RUSTDESK_MAX_DISPLAYS: usize = 16;
pub const RUSTDESK_DISPLAY_NAME_BYTES: usize = 128;

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct RustDeskStreamStats {
    pub version: u32,
    pub state: u32,
    pub last_delay_ms: u32,
    pub target_bitrate_kbps: u32,
    pub video_messages: u64,
    pub video_frames: u64,
    pub keyframes: u64,
    pub encoded_bytes: u64,
    pub audio_frames: u64,
    pub cadence_gaps: u64,
    pub max_cadence_gap_ms: u64,
    pub test_delay_count: u64,
    pub actual_codec: i32,
    pub width: i32,
    pub height: i32,
    pub connection_path: i32, // 0=rendezvous/relay, 1=direct
}

impl Default for RustDeskStreamStats {
    fn default() -> Self {
        Self {
            version: RUSTDESK_STREAM_STATS_VERSION,
            state: 0,
            last_delay_ms: 0,
            target_bitrate_kbps: 0,
            video_messages: 0,
            video_frames: 0,
            keyframes: 0,
            encoded_bytes: 0,
            audio_frames: 0,
            cadence_gaps: 0,
            max_cadence_gap_ms: 0,
            test_delay_count: 0,
            actual_codec: -1,
            width: 0,
            height: 0,
            connection_path: 0,
        }
    }
}

/// Versioned image-quality state shared with the HarmonyOS bridge.
///
/// `raw_quality` is the latest user preference, `effective_quality` is the
/// validated local value, and `sent_quality` changes only after the streaming
/// writer successfully emits the corresponding RustDesk OptionMessage.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct RustDeskQualityState {
    pub version: u32,
    pub raw_quality: i32,
    pub effective_quality: i32,
    pub sent_quality: i32,
    pub profile: i32,
    pub fps: u32,
    pub requested_generation: u64,
    pub applied_generation: u64,
    pub update_status: u32, // 0=idle, 1=pending, 2=applied, 3=failed
    pub reserved: u32,
}

impl Default for RustDeskQualityState {
    fn default() -> Self {
        Self {
            version: RUSTDESK_QUALITY_STATE_VERSION,
            raw_quality: 1,
            effective_quality: 1,
            sent_quality: -1,
            profile: RustDeskProfile::Balanced as i32,
            fps: 0,
            requested_generation: 0,
            applied_generation: 0,
            update_status: 0,
            reserved: 0,
        }
    }
}

/// Permission state advertised by the remote peer. A bit absent from
/// `known_mask` means that the peer has not advertised that capability, so
/// callers should preserve the legacy optimistic behavior.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct RustDeskPermissionState {
    pub version: u32,
    pub known_mask: u32,
    pub enabled_mask: u32,
    pub reserved: u32,
}

/// One remote display as received from RustDesk `PeerInfo`/`SwitchDisplay`.
///
/// This is intentionally an owned Rust-side representation. The FFI list API
/// copies it into fixed-width snapshots so no Rust allocation is exposed to C++.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct RustDeskDisplayInfoState {
    pub display: i32,
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
    pub name: String,
    pub online: bool,
    pub cursor_embedded: bool,
    pub original_width: i32,
    pub original_height: i32,
    pub scale_milli: i32,
    pub resolutions: Vec<(i32, i32)>,
}

/// Mutable display catalog shared by the streaming worker and FFI callers.
/// RustDesk sends display geometry through `PeerInfo` and `Misc.switch_display`.
#[derive(Debug, Clone)]
pub(crate) struct RustDeskDisplayState {
    pub current_display: i32,
    pub desired_display: Option<i32>,
    pub switch_generation: u64,
    pub pending_switch_generation: Option<u64>,
    pub confirmed_switch_generation: u64,
    pub width: i32,
    pub height: i32,
    pub original_width: i32,
    pub original_height: i32,
    pub scale_milli: i32,
    pub geometry_epoch: u32,
    pub resolutions: Vec<(i32, i32)>,
    pub displays: Vec<RustDeskDisplayInfoState>,
}

impl Default for RustDeskDisplayState {
    fn default() -> Self {
        Self {
            current_display: 0,
            desired_display: None,
            switch_generation: 0,
            pending_switch_generation: None,
            confirmed_switch_generation: 0,
            width: 0,
            height: 0,
            original_width: 0,
            original_height: 0,
            scale_milli: 1000,
            geometry_epoch: 0,
            resolutions: Vec::new(),
            displays: Vec::new(),
        }
    }
}

#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct RustDeskDisplaySnapshot {
    pub version: u32,
    pub current_display: i32,
    pub width: i32,
    pub height: i32,
    pub original_width: i32,
    pub original_height: i32,
    pub scale_milli: i32,
    pub geometry_epoch: u32,
    pub resolution_count: u32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct RustDeskResolution {
    pub width: i32,
    pub height: i32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct RustDeskDisplayInfoSnapshot {
    pub display: i32,
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
    pub original_width: i32,
    pub original_height: i32,
    pub scale_milli: i32,
    pub online: u8,
    pub cursor_embedded: u8,
    pub reserved: [u8; 2],
    pub name_len: u32,
    pub name: [u8; RUSTDESK_DISPLAY_NAME_BYTES],
    pub resolution_offset: u32,
    pub resolution_count: u32,
}

impl Default for RustDeskDisplayInfoSnapshot {
    fn default() -> Self {
        Self {
            display: 0,
            x: 0,
            y: 0,
            width: 0,
            height: 0,
            original_width: 0,
            original_height: 0,
            scale_milli: 1000,
            online: 0,
            cursor_embedded: 0,
            reserved: [0; 2],
            name_len: 0,
            name: [0; RUSTDESK_DISPLAY_NAME_BYTES],
            resolution_offset: 0,
            resolution_count: 0,
        }
    }
}

// ============================================================
// 回调类型
// ============================================================

/// 视频帧回调
pub type FrameCallback = extern "C" fn(frame: *const FfiVideoFrame, user_data: *mut c_void);

/// V2 video frame callback with explicit display routing metadata.
pub type FrameCallbackV2 =
    extern "C" fn(frame: *const FfiVideoFrameV2, user_data: *mut c_void);

/// 音频数据回调
pub type AudioCallback = extern "C" fn(audio: *const FfiAudioData, user_data: *mut c_void);

/// Remote cursor callback.
pub type CursorCallback = extern "C" fn(cursor: *const FfiCursorUpdate, user_data: *mut c_void);

/// Initial remote display snapshot delivered before the V2 stream starts.
pub type DisplayCallback =
    extern "C" fn(snapshot: *const RustDeskDisplaySnapshot, user_data: *mut c_void);

/// Authenticated peer platform callback. Returning false aborts connection
/// publication before the streaming worker can deliver its first frame.
pub type PeerPlatformCallback =
    extern "C" fn(platform: *const c_char, user_data: *mut c_void) -> bool;

/// 断开连接回调
pub type DisconnectCallback =
    extern "C" fn(state: FfiConnectionState, message: *const c_char, user_data: *mut c_void);

#[derive(Clone, Copy)]
enum FrameCallbackKind {
    V1(FrameCallback),
    V2(FrameCallbackV2),
}

// This queue only decouples the socket/ACK loop from the native callback; the
// native decoder owns the actual presentation queue.  RustDesk can release a
// short burst after a delayed TCP read, so leave enough room for that burst
// without turning ordinary network jitter into a remote encoder restart.
const VIDEO_CALLBACK_QUEUE_CAPACITY: usize = 16;
// Full-resolution macOS VP9 can release close to one second of dependent
// frames in one TCP burst. The native software decoder already owns a 30-frame
// reference-safe recovery boundary, so let VP9 reach that owner instead of
// dropping at the smaller cross-codec callback boundary and needlessly asking
// the host to rebuild its encoder. Hardware codecs retain the 16-frame limit.
const VP9_VIDEO_CALLBACK_QUEUE_CAPACITY: usize = 30;
const FFI_VP9_CODEC: c_int = 3;

fn video_callback_queue_capacity(codec: c_int) -> usize {
    if codec == FFI_VP9_CODEC {
        VP9_VIDEO_CALLBACK_QUEUE_CAPACITY
    } else {
        VIDEO_CALLBACK_QUEUE_CAPACITY
    }
}

struct QueuedVideoFrame {
    data: Vec<u8>,
    width: c_int,
    height: c_int,
    codec: c_int,
    timestamp: u64,
    is_key_frame: bool,
    display: c_int,
}

struct VideoCallbackQueueState {
    frames: VecDeque<QueuedVideoFrame>,
    closed: bool,
    // Once a dependent frame is dropped, later deltas are no longer a safe
    // continuation of the decoder reference chain. Request one refresh and
    // suppress all further refreshes until the resulting keyframe arrives.
    awaiting_key_frame: bool,
}

enum VideoQueueOutcome {
    Queued {
        evicted: usize,
        request_refresh: bool,
    },
    Dropped {
        request_refresh: bool,
    },
    Disconnected,
}

/// Keep the network/ACK loop independent from native decode and render work.
/// The queue is intentionally small: a slow decoder must not turn into a
/// growing latency buffer. A new keyframe replaces stale queued work when the
/// queue is full; dependent frames are never allowed to evict it.
struct VideoCallbackQueue {
    state: Mutex<VideoCallbackQueueState>,
    wake: Condvar,
}

impl VideoCallbackQueue {
    fn new() -> Self {
        Self {
            state: Mutex::new(VideoCallbackQueueState {
                frames: VecDeque::with_capacity(VP9_VIDEO_CALLBACK_QUEUE_CAPACITY),
                closed: false,
                awaiting_key_frame: false,
            }),
            wake: Condvar::new(),
        }
    }

    fn enqueue(&self, frame: QueuedVideoFrame) -> VideoQueueOutcome {
        let Ok(mut state) = self.state.lock() else {
            return VideoQueueOutcome::Disconnected;
        };
        if state.closed {
            return VideoQueueOutcome::Disconnected;
        }

        let mut evicted = 0;
        if state.awaiting_key_frame {
            if !frame.is_key_frame {
                // The first overflow already requested a refresh. Repeating
                // RefreshVideo for every arriving delta makes the macOS host
                // tear down and recreate its VP9 encoder every few seconds.
                return VideoQueueOutcome::Dropped {
                    request_refresh: false,
                };
            }
            evicted = state.frames.len();
            state.frames.clear();
            state.awaiting_key_frame = false;
        } else if state.frames.len() >= video_callback_queue_capacity(frame.codec) {
            if frame.is_key_frame {
                // A fresh keyframe is a complete decoder restart point. Drop
                // all older deltas so recovery does not replay stale frames
                // ahead of the keyframe.
                evicted = state.frames.len();
                state.frames.clear();
            } else {
                // Preserve the already queued, ordered prefix. Dropping the
                // new dependent frame breaks the future reference chain, so
                // request exactly one keyframe and wait for it. In particular,
                // do not enqueue more dependent frames or issue one refresh
                // per frame while the keyframe is in flight.
                state.awaiting_key_frame = true;
                return VideoQueueOutcome::Dropped {
                    request_refresh: true,
                };
            }
        }

        state.frames.push_back(frame);
        drop(state);
        self.wake.notify_one();
        VideoQueueOutcome::Queued {
            evicted,
            request_refresh: false,
        }
    }

    fn pop(&self) -> Option<QueuedVideoFrame> {
        let mut state = self.state.lock().ok()?;
        loop {
            if let Some(frame) = state.frames.pop_front() {
                drop(state);
                self.wake.notify_all();
                return Some(frame);
            }
            if state.closed {
                return None;
            }
            state = self.wake.wait(state).ok()?;
        }
    }

    fn close(&self) {
        if let Ok(mut state) = self.state.lock() {
            state.closed = true;
        }
        self.wake.notify_all();
    }
}

struct VideoCallbackWorker {
    queue: Arc<VideoCallbackQueue>,
    handle: Option<std::thread::JoinHandle<()>>,
    controls: Arc<ControlInbox>,
    queued: u64,
    dropped: u64,
}

impl VideoCallbackWorker {
    fn start(
        on_frame: Option<FrameCallbackKind>,
        user_data: usize,
        controls: Arc<ControlInbox>,
    ) -> Self {
        let queue = Arc::new(VideoCallbackQueue::new());
        let Some(on_frame) = on_frame else {
            return Self {
                queue,
                handle: None,
                controls,
                queued: 0,
                dropped: 0,
            };
        };
        let worker_queue = Arc::clone(&queue);
        let handle = std::thread::spawn(move || {
            while let Some(frame) = worker_queue.pop() {
                dispatch_queued_video_frame(&frame, on_frame, user_data as *mut c_void);
            }
        });
        Self {
            queue,
            handle: Some(handle),
            controls,
            queued: 0,
            dropped: 0,
        }
    }

    fn enqueue(&mut self, frame: QueuedVideoFrame) {
        match self.queue.enqueue(frame) {
            VideoQueueOutcome::Queued {
                evicted,
                request_refresh,
            } => {
                self.queued += 1;
                self.dropped += evicted as u64;
                if request_refresh {
                    let _ = self.controls.enqueue(ControlMsg::RefreshVideo);
                }
            }
            VideoQueueOutcome::Dropped { request_refresh } => {
                self.dropped += 1;
                if request_refresh {
                    let _ = self.controls.enqueue(ControlMsg::RefreshVideo);
                }
                if self.dropped <= 5 || self.dropped % 60 == 0 {
                    eprintln!(
                        "[RustDesk-FFI] video callback queue full dropped={} queued={} -> refresh={}",
                        self.dropped,
                        self.queued,
                        request_refresh,
                    );
                }
            }
            VideoQueueOutcome::Disconnected => {
                self.dropped += 1;
            }
        }
    }

    fn stop(&mut self) {
        self.queue.close();
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
        if self.dropped > 0 {
            eprintln!(
                "[RustDesk-FFI] video callback worker stopped queued={} dropped={}",
                self.queued, self.dropped,
            );
        }
    }
}

// ============================================================
// 内部类型: RustDesk 客户端句柄
// ============================================================

/// 线程间控制消息
pub(crate) enum ControlMsg {
    Shutdown,
    RefreshVideo,
    VideoPressure { level: u32 },
    SetImageQuality { quality: i32, generation: u64 },
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
    /// Two-dimensional wheel delta from a physical touchpad. Unlike the
    /// legacy wheel message, x/y are both protocol wheel deltas.
    MouseWheel2D {
        x: i32,
        y: i32,
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
    ChangeDisplayResolution {
        display: i32,
        width: i32,
        height: i32,
    },
    SwitchDisplay {
        display: i32,
    },
    /// One latest-wins single-canvas switch transaction. The connector emits
    /// SwitchDisplay, CaptureDisplays(set=[display]) and
    /// RefreshVideoDisplay(display) without yielding to another control.
    DisplaySwitch {
        display: i32,
        generation: u64,
    },
    CaptureDisplays {
        add: Vec<i32>,
        sub: Vec<i32>,
        set: Vec<i32>,
    },
    RefreshVideoDisplay {
        display: i32,
    },
    TouchScale {
        scale: i32,
    },
    TouchPanStart {
        x: i32,
        y: i32,
    },
    TouchPanUpdate {
        x: i32,
        y: i32,
    },
    TouchPanEnd {
        x: i32,
        y: i32,
    },
}

/// 客户端上下文 — 通过 FFI 不透明指针传递
struct RustDeskClient {
    connection_id: u64,
    #[allow(dead_code)]
    peer_id: String,
    host: String,
    port: u16,
    relay_fallback_port: u16,
    server_key: String,
    shared_access_key: bool,
    api_token: String,
    password: String,
    request_approval: bool,
    direct_connection: bool,
    controls: Arc<ControlInbox>,
    shutdown_stream: Option<TcpStream>,
    stream_handle: Option<std::thread::JoinHandle<io::Result<()>>>,
    transfer_status: Arc<Mutex<RustDeskTransferStatus>>,
    transfer_error: Arc<Mutex<String>>,
    remote_clipboard: Arc<Mutex<Vec<u8>>>,
    stream_stats: Arc<Mutex<RustDeskStreamStats>>,
    quality_state: Arc<Mutex<RustDeskQualityState>>,
    display_state: Arc<Mutex<RustDeskDisplayState>>,
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

fn dispatch_queued_video_frame(
    frame: &QueuedVideoFrame,
    on_frame: FrameCallbackKind,
    user_data: *mut c_void,
) {
    static FFI_FRAME_CB_COUNT: AtomicU64 = AtomicU64::new(0);
    static FFI_SUBFRAME_TOTAL: AtomicU64 = AtomicU64::new(0);

    let callback_started = Instant::now();
    match on_frame {
        FrameCallbackKind::V1(callback) => {
            let ffi_frame = FfiVideoFrame {
                data: frame.data.as_ptr(),
                size: frame.data.len(),
                width: frame.width,
                height: frame.height,
                codec: frame.codec,
                timestamp: frame.timestamp,
                is_key_frame: frame.is_key_frame,
            };
            callback(&ffi_frame, user_data);
        }
        FrameCallbackKind::V2(callback) => {
            let ffi_frame = FfiVideoFrameV2 {
                data: frame.data.as_ptr(),
                size: frame.data.len(),
                width: frame.width,
                height: frame.height,
                codec: frame.codec,
                timestamp: frame.timestamp,
                is_key_frame: frame.is_key_frame,
                display: frame.display,
                abi_version: RUSTDESK_VIDEO_FRAME_ABI_VERSION,
                struct_size: std::mem::size_of::<FfiVideoFrameV2>() as u32,
            };
            callback(&ffi_frame, user_data);
        }
    }
    let callback_elapsed = callback_started.elapsed();
    if callback_elapsed >= Duration::from_millis(50) {
        eprintln!(
            "[RustDesk-FFI] native video callback slow elapsed_ms={} codec={} size={} keyframe={} display={}",
            callback_elapsed.as_millis(),
            frame.codec,
            frame.data.len(),
            frame.is_key_frame,
            frame.display,
        );
    }
    FFI_FRAME_CB_COUNT.fetch_add(1, Ordering::Relaxed);
    FFI_SUBFRAME_TOTAL.fetch_add(1, Ordering::Relaxed);
}

fn dispatch_encoded_frames(
    frames: &EncodedVideoFrames,
    codec: c_int,
    width: c_int,
    height: c_int,
    display: c_int,
    video_worker: &mut VideoCallbackWorker,
) {
    for frame in frames.get_frames() {
        let data = frame.get_data();
        if data.is_empty() {
            continue;
        }
        video_worker.enqueue(QueuedVideoFrame {
            data: data.to_vec(),
            width,
            height,
            codec,
            timestamp: frame.get_pts().max(0) as u64,
            is_key_frame: frame.get_key(),
            display,
        });
    }
}

fn dispatch_video_frame(
    frame: &VideoFrame,
    display_state: &Arc<Mutex<RustDeskDisplayState>>,
    video_worker: &mut VideoCallbackWorker,
) {
    let display = frame.get_display();
    let (width, height) = display_state
        .lock()
        .map(|state| {
            state
                .displays
                .iter()
                .find(|info| info.display == display)
                .map(|info| (info.width.max(1), info.height.max(1)))
                .unwrap_or((state.width.max(1), state.height.max(1)))
        })
        .unwrap_or((1, 1));

    match frame.union {
        Some(VideoFrame_oneof_union::h264s(ref frames)) => {
            dispatch_encoded_frames(frames, 0, width, height, display, video_worker);
        }
        Some(VideoFrame_oneof_union::h265s(ref frames)) => {
            dispatch_encoded_frames(frames, 1, width, height, display, video_worker);
        }
        Some(VideoFrame_oneof_union::vp8s(ref frames)) => {
            dispatch_encoded_frames(frames, 2, width, height, display, video_worker);
        }
        Some(VideoFrame_oneof_union::vp9s(ref frames)) => {
            dispatch_encoded_frames(frames, 3, width, height, display, video_worker);
        }
        Some(VideoFrame_oneof_union::av1s(ref frames)) => {
            dispatch_encoded_frames(frames, 4, width, height, display, video_worker);
        }
        Some(VideoFrame_oneof_union::rgb(_)) | Some(VideoFrame_oneof_union::yuv(_)) | None => {}
    }
}

fn dispatch_display_snapshot(
    display_state: &Arc<Mutex<RustDeskDisplayState>>,
    on_display: Option<DisplayCallback>,
    user_data: *mut c_void,
) {
    let Some(on_display) = on_display else {
        return;
    };
    let Ok(state) = display_state.lock() else {
        return;
    };
    let snapshot = RustDeskDisplaySnapshot {
        version: RUSTDESK_DISPLAY_SNAPSHOT_VERSION,
        current_display: state.current_display,
        width: state.width,
        height: state.height,
        original_width: state.original_width,
        original_height: state.original_height,
        scale_milli: state.scale_milli,
        geometry_epoch: state.geometry_epoch,
        resolution_count: state.resolutions.len().min(RUSTDESK_MAX_DISPLAY_RESOLUTIONS) as u32,
    };
    on_display(&snapshot, user_data);
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
    pending_frames: VecDeque<Vec<u8>>,
    frames_pushed: u64,
    frames_dropped: u64,
}

const MAX_PENDING_AUDIO_FRAMES: usize = 16;

impl AudioPipeline {
    fn new() -> Self {
        Self {
            worker: None,
            sample_rate: 48000,
            channels: 2,
            format_received: false,
            pending_frames: VecDeque::with_capacity(MAX_PENDING_AUDIO_FRAMES),
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
            // RustDesk can deliver audio_frame before misc.audio_format on a
            // cold stream. Replay the bounded pre-format queue in order once
            // the decoder has the real sample format.
            let pending = std::mem::take(&mut self.pending_frames);
            if let Some(ref worker) = self.worker {
                for frame in pending {
                    if worker.push(&frame) {
                        self.frames_pushed += 1;
                    } else {
                        self.frames_dropped += 1;
                    }
                }
            }
            eprintln!(
                "[RustDesk-FFI] audio pipeline {}Hz {}ch worker=started pending_replayed={}",
                sr, ch, self.frames_pushed
            );
        } else {
            // Keep the frames until a later format notification can start the
            // worker; this is still bounded by MAX_PENDING_AUDIO_FRAMES.
        }
    }

    fn push_frame(&mut self, audio: &AudioFrame) {
        let data = audio.get_data();
        if data.is_empty() {
            return;
        }
        let Some(ref worker) = self.worker else {
            if self.pending_frames.len() >= MAX_PENDING_AUDIO_FRAMES {
                self.pending_frames.pop_front();
                self.frames_dropped += 1;
                if self.frames_dropped <= 5 || self.frames_dropped % 100 == 0 {
                    eprintln!(
                        "[RustDesk-FFI] audio format pending: bounded queue dropped={} buffered={}",
                        self.frames_dropped,
                        self.pending_frames.len()
                    );
                }
            }
            self.pending_frames.push_back(data.to_vec());
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
        self.pending_frames.clear();
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

fn notify_peer_platform(
    on_peer_platform: Option<PeerPlatformCallback>,
    platform: &str,
    user_data: *mut c_void,
) -> bool {
    let Some(on_peer_platform) = on_peer_platform else {
        return true;
    };
    let safe_platform = platform.replace('\0', " ");
    let c_platform =
        CString::new(safe_platform).unwrap_or_else(|_| CString::new("").unwrap());
    on_peer_platform(c_platform.as_ptr(), user_data)
}

fn dispatch_cursor_update(
    update: CursorStreamUpdate,
    on_cursor: Option<CursorCallback>,
    user_data: *mut c_void,
) {
    let Some(on_cursor) = on_cursor else {
        return;
    };
    let mut ffi = FfiCursorUpdate {
        kind: 0,
        shape_id: 0,
        x: 0,
        y: 0,
        width: 0,
        height: 0,
        hot_x: 0,
        hot_y: 0,
        rgba: std::ptr::null(),
        rgba_len: 0,
        visible: false,
    };
    match update {
        CursorStreamUpdate::Shape(shape) => {
            ffi.kind = 0;
            ffi.shape_id = shape.id;
            ffi.width = shape.width;
            ffi.height = shape.height;
            ffi.hot_x = shape.hot_x;
            ffi.hot_y = shape.hot_y;
            ffi.rgba = shape.rgba.as_ptr();
            ffi.rgba_len = shape.rgba.len();
            ffi.visible = true;
            on_cursor(&ffi, user_data);
        }
        CursorStreamUpdate::Position { x, y } => {
            ffi.kind = 1;
            ffi.x = x;
            ffi.y = y;
            ffi.visible = true;
            on_cursor(&ffi, user_data);
        }
        CursorStreamUpdate::Visibility(visible) => {
            ffi.kind = 2;
            ffi.visible = visible;
            on_cursor(&ffi, user_data);
        }
        CursorStreamUpdate::CacheMiss { id, reason: _ } => {
            ffi.kind = 3;
            ffi.shape_id = id;
            // The cache miss is diagnostic-only.  The native store must keep
            // its last valid shape and visibility unchanged.
            ffi.visible = true;
            on_cursor(&ffi, user_data);
        }
    }
}

// ============================================================
// FFI 导出函数
// ============================================================

/// 创建 RustDesk 连接 (完整管线: Rendezvous → KeyExchange → Login)
///
/// 此函数阻塞直到登录完成 (通常 5-15s)。
/// 应在独立线程中调用。
/// 成功返回不透明句柄，失败返回 null。
fn rustdesk_connect_impl(
    cfg: *const RustDeskConfig,
    on_frame: Option<FrameCallbackKind>,
    on_audio: Option<AudioCallback>,
    on_cursor: Option<CursorCallback>,
    on_disconnect: Option<DisconnectCallback>,
    on_display: Option<DisplayCallback>,
    on_auth: Option<AuthEventCallback>,
    on_progress: Option<connector::ConnectProgressCallback>,
    on_peer_platform: Option<PeerPlatformCallback>,
    user_data: *mut c_void,
) -> *mut c_void {
    clear_last_error();
    if cfg.is_null() {
        set_last_error("config pointer is null");
        return std::ptr::null_mut();
    }

    let config = unsafe { &*cfg };
    let connection_id = config.connection_id;
    let connect_epoch = begin_connect_epoch(connection_id);
    let host = ffi_string(config.host);
    let port = if config.port > 0 {
        config.port as u16
    } else if config.direct_connection {
        // Direct mode targets the peer listener, not the ID/rendezvous server.
        21118u16
    } else {
        21116u16
    };
    let relay_fallback_port = relay_fallback_port_from_config(config.relay_fallback_port);
    // Direct IP access follows the RustDesk client path: the connected peer
    // address is the login username. The stored remote ID is still retained
    // by the host model for display/discovery, but must not be sent as the
    // direct login identity.
    let peer_id = if config.direct_connection {
        host.clone()
    } else {
        ffi_string(config.username)
    };
    let server_key = ffi_string(config.key);
    let shared_access_key = config.key_mode == 2;
    let api_token = if config.direct_connection {
        String::new()
    } else {
        ffi_string(config.token)
    };
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
        set_last_error(structured_error(
            "config", "rendezvous_host_missing", "rendezvous endpoint is missing", connection_id));
        finish_connect_epoch(connect_epoch, connection_id);
        return std::ptr::null_mut();
    }
    if peer_id.is_empty() {
        set_last_error(structured_error(
            "config", "peer_id_missing", "remote peer identity is missing", connection_id));
        finish_connect_epoch(connect_epoch, connection_id);
        return std::ptr::null_mut();
    }

    // Public-key mode retains strict identity verification.  Shared-access
    // mode is RustDesk's official hbbs/hbbr `-k` compatibility path: the text
    // is forwarded unchanged as licence_key and the connector explicitly
    // falls back to an unverified/plain peer negotiation when no signing key
    // is available.  Direct IP sessions do not use rendezvous at all.
    if !config.direct_connection
        && !shared_access_key
        && crypto::normalized_server_public_key(&server_key).is_none()
    {
        let message = if server_key.trim_start().starts_with("1:") {
            "rendezvous server public key is encrypted; unlock local data before connecting"
        } else {
            "invalid rendezvous server public key; expected Base64-encoded 32-byte key"
        };
        set_last_error(structured_error(
            "config", "server_key_invalid", message, connection_id));
        finish_connect_epoch(connect_epoch, connection_id);
        return std::ptr::null_mut();
    }

    // 运行完整连接管线
    let mut c = connector::RustDeskConnector::new_with_connection_id(connection_id, connect_epoch);
    c.set_auth_callback(on_auth, user_data);
    c.set_progress_callback(on_progress, user_data);
    let result = if config.direct_connection {
        // 直连模式: host=peer IP, port=peer port, 跳过 rendezvous
        eprintln!(
            "[RustDesk-FFI] direct_connection=true endpoint=provided port={}",
            port
        );
        c.connect_direct(
            &host,
            port,
            &peer_id,
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
            relay_fallback_port,
            &server_key,
            &api_token,
            &peer_id,
            &password,
            preferred_codec,
            image_quality,
            privacy_mode,
            audio_enabled,
            effective_fps,
            request_approval,
            shared_access_key,
        )
    };

    match result {
        Ok(()) => {
            finish_connect_epoch(connect_epoch, connection_id);
            // 登录成功 — 创建可合并的控制收件箱，用于后续控制。
            let controls = Arc::new(ControlInbox::default());
            let stream_controls = Arc::clone(&controls);
            let shutdown_stream = c.try_clone_stream().ok();
            let peer_platform = c.peer_platform();
            let peer_platform_label = if peer_platform.is_empty() {
                "unknown"
            } else {
                peer_platform.as_str()
            };
            eprintln!(
                "[RustDesk-FFI] authenticated peer platform={}",
                peer_platform_label
            );
            if !notify_peer_platform(on_peer_platform, &peer_platform, user_data) {
                set_last_error(structured_error(
                    "presentation",
                    "peer_platform_rejected",
                    "native presentation owner rejected authenticated peer platform",
                    connection_id,
                ));
                return std::ptr::null_mut();
            }
            let callback_user_data = user_data as usize;
            let remote_clipboard = Arc::new(Mutex::new(Vec::<u8>::new()));
            let stream_remote_clipboard = Arc::clone(&remote_clipboard);
            let display_state = Arc::new(Mutex::new(c.peer_display_state()));
            let (mut remote_width, mut remote_height) = display_state
                .lock()
                .map(|state| (state.width.max(1), state.height.max(1)))
                .unwrap_or((config.width.max(1), config.height.max(1)));
            if remote_width <= 1 || remote_height <= 1 {
                if let Ok(mut state) = display_state.lock() {
                    let fallback = c
                        .peer_display_size()
                        .unwrap_or((config.width.max(1), config.height.max(1)));
                    state.width = fallback.0.max(1);
                    state.height = fallback.1.max(1);
                    state.original_width = state.width;
                    state.original_height = state.height;
                    state.geometry_epoch = state.geometry_epoch.wrapping_add(1);
                    remote_width = state.width;
                    remote_height = state.height;
                }
            }
            let stream_stats = Arc::new(Mutex::new(RustDeskStreamStats {
                state: 2,
                width: remote_width,
                height: remote_height,
                connection_path: if config.direct_connection { 1 } else { 0 },
                ..RustDeskStreamStats::default()
            }));
            let quality_state = Arc::new(Mutex::new(RustDeskQualityState {
                raw_quality: config.image_quality,
                effective_quality: image_quality,
                sent_quality: -1,
                profile: config.profile as i32,
                fps: effective_fps,
                update_status: 1,
                ..RustDeskQualityState::default()
            }));
            let transfer_status = Arc::new(Mutex::new(RustDeskTransferStatus::default()));
            let transfer_error = Arc::new(Mutex::new(String::new()));
            let stream_stats_for_thread = Arc::clone(&stream_stats);
            let quality_state_for_thread = Arc::clone(&quality_state);
            let stream_display_state = Arc::clone(&display_state);
            let frame_display_state = Arc::clone(&display_state);
            let display_callback_state = Arc::clone(&display_state);
            eprintln!(
                "[RustDesk-FFI] remote display size={}x{} requested={}x{}",
                remote_width, remote_height, config.width, config.height
            );
            // The display callback runs before the streaming thread is
            // spawned, so the consumer can select the peer's current display
            // before the first interleaved video frame arrives.
            dispatch_display_snapshot(&display_state, on_display, callback_user_data as *mut c_void);

            let stream_handle = std::thread::spawn(move || {
                let callback_user_data = callback_user_data as *mut c_void;
                let audio_pipeline = RefCell::new(AudioPipeline::new());
                let mut video_worker = VideoCallbackWorker::start(
                    on_frame,
                    callback_user_data as usize,
                    Arc::clone(&stream_controls),
                );
                let result = c.run_streaming(
                    preferred_codec,
                    image_quality,
                    privacy_mode,
                    audio_enabled,
                    effective_fps,
                    stream_controls,
                    stream_stats_for_thread,
                    quality_state_for_thread,
                    stream_display_state,
                    |frame| {
                        dispatch_video_frame(
                            frame,
                            &frame_display_state,
                            &mut video_worker,
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
                    |cursor| {
                        dispatch_cursor_update(cursor, on_cursor, callback_user_data);
                    },
                    || {
                        dispatch_display_snapshot(
                            &display_callback_state,
                            on_display,
                            callback_user_data,
                        );
                    },
                );

                // Drain the bounded callback queue before the stream thread
                // reports disconnect. This preserves FIFO frame order and
                // keeps callback context lifetime valid through the final
                // native callback.
                video_worker.stop();
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
                connection_id,
                peer_id,
                host,
                port,
                relay_fallback_port,
                server_key,
                shared_access_key,
                api_token,
                password,
                request_approval,
                direct_connection: config.direct_connection,
                controls,
                shutdown_stream,
                stream_handle: Some(stream_handle),
                transfer_status,
                transfer_error,
                remote_clipboard,
                stream_stats,
                quality_state,
                display_state,
            });

            Box::into_raw(ctx) as *mut c_void
        }
        Err(err) => {
            let message = pipeline_error_message(
                &c.state(), &err, config.direct_connection, connection_id);
            set_last_error(message);
            finish_connect_epoch(connect_epoch, connection_id);
            std::ptr::null_mut()
        }
    }
}

/// Create a RustDesk connection using the stable legacy V1 frame callback.
#[no_mangle]
pub extern "C" fn rustdesk_connect(
    cfg: *const RustDeskConfig,
    on_frame: Option<FrameCallback>,
    on_audio: Option<AudioCallback>,
    on_cursor: Option<CursorCallback>,
    on_disconnect: Option<DisconnectCallback>,
    user_data: *mut c_void,
) -> *mut c_void {
    rustdesk_connect_impl(
        cfg,
        on_frame.map(FrameCallbackKind::V1),
        on_audio,
        on_cursor,
        on_disconnect,
        None,
        None,
        None,
        None,
        user_data,
    )
}

/// Create a RustDesk connection using the V2 frame/display callbacks.
#[no_mangle]
pub extern "C" fn rustdesk_connect_v2(
    cfg: *const RustDeskConfig,
    on_frame: Option<FrameCallbackV2>,
    on_audio: Option<AudioCallback>,
    on_cursor: Option<CursorCallback>,
    on_disconnect: Option<DisconnectCallback>,
    on_display: Option<DisplayCallback>,
    user_data: *mut c_void,
) -> *mut c_void {
    rustdesk_connect_impl(
        cfg,
        on_frame.map(FrameCallbackKind::V2),
        on_audio,
        on_cursor,
        on_disconnect,
        on_display,
        None,
        None,
        None,
        user_data,
    )
}

/// Create a RustDesk connection using V2 frame/display callbacks and auth events.
#[no_mangle]
pub extern "C" fn rustdesk_connect_v3(
    cfg: *const RustDeskConfig,
    on_frame: Option<FrameCallbackV2>,
    on_audio: Option<AudioCallback>,
    on_cursor: Option<CursorCallback>,
    on_disconnect: Option<DisconnectCallback>,
    on_display: Option<DisplayCallback>,
    on_auth: Option<AuthEventCallback>,
    user_data: *mut c_void,
) -> *mut c_void {
    rustdesk_connect_impl(
        cfg,
        on_frame.map(FrameCallbackKind::V2),
        on_audio,
        on_cursor,
        on_disconnect,
        on_display,
        on_auth,
        None,
        None,
        user_data,
    )
}

/// Create a RustDesk connection using V2 frame/display callbacks, auth events,
/// and per-handshake progress messages. This extends v3 without changing the
/// older entry points used by existing integrations.
#[no_mangle]
pub extern "C" fn rustdesk_connect_v4(
    cfg: *const RustDeskConfig,
    on_frame: Option<FrameCallbackV2>,
    on_audio: Option<AudioCallback>,
    on_cursor: Option<CursorCallback>,
    on_disconnect: Option<DisconnectCallback>,
    on_display: Option<DisplayCallback>,
    on_auth: Option<AuthEventCallback>,
    on_progress: Option<connector::ConnectProgressCallback>,
    user_data: *mut c_void,
) -> *mut c_void {
    rustdesk_connect_impl(
        cfg,
        on_frame.map(FrameCallbackKind::V2),
        on_audio,
        on_cursor,
        on_disconnect,
        on_display,
        on_auth,
        on_progress,
        None,
        user_data,
    )
}

/// Create a RustDesk connection with authenticated peer-platform publication.
/// The callback runs synchronously after login and before any stream worker or
/// display/frame callback can start, extending v4 without changing older ABIs.
#[no_mangle]
pub extern "C" fn rustdesk_connect_v5(
    cfg: *const RustDeskConfig,
    on_frame: Option<FrameCallbackV2>,
    on_audio: Option<AudioCallback>,
    on_cursor: Option<CursorCallback>,
    on_disconnect: Option<DisconnectCallback>,
    on_display: Option<DisplayCallback>,
    on_auth: Option<AuthEventCallback>,
    on_progress: Option<connector::ConnectProgressCallback>,
    on_peer_platform: Option<PeerPlatformCallback>,
    user_data: *mut c_void,
) -> *mut c_void {
    rustdesk_connect_impl(
        cfg,
        on_frame.map(FrameCallbackKind::V2),
        on_audio,
        on_cursor,
        on_disconnect,
        on_display,
        on_auth,
        on_progress,
        on_peer_platform,
        user_data,
    )
}

/// 取消尚未返回会话句柄的连接尝试（尤其是等待被控端批准的连接）。
#[no_mangle]
pub extern "C" fn rustdesk_cancel_pending_connect() {
    cancel_pending_connect_for_session(0);
}

fn valid_peer_2fa_code(value: &str) -> bool {
    matches!(value.len(), 6 | 8) && value.bytes().all(|byte| byte.is_ascii_digit())
}

fn submit_2fa_for_pending_session(session_id: Option<u64>, code: *const c_char) -> bool {
    let value = ffi_string(code);
    if !valid_peer_2fa_code(&value) {
        set_last_error("invalid RustDesk 2FA code format");
        return false;
    }
    let pending_entry = match PENDING_2FA.lock() {
        Ok(pending) => match session_id {
            Some(id) if id != 0 => pending.get(&id).map(|entry| (entry.epoch, entry.sender.clone())),
            _ => {
                let epoch = current_connect_epoch();
                pending.values()
                    .find(|entry| entry.epoch == epoch)
                    .map(|entry| (entry.epoch, entry.sender.clone()))
            }
        },
        Err(_) => {
            set_last_error("RustDesk 2FA pending state lock poisoned");
            return false;
        }
    };
    let Some((epoch, sender)) = pending_entry else {
        set_last_error("RustDesk 2FA is not pending");
        return false;
    };
    if connect_cancelled(epoch) {
        set_last_error("RustDesk 2FA connection attempt was cancelled");
        return false;
    }
    match sender.send(value) {
        Ok(()) => {
            set_last_error("RustDesk 2FA code submitted");
            true
        }
        Err(_) => {
            set_last_error("RustDesk 2FA submission channel closed");
            false
        }
    }
}

/// Submit one transient Peer TOTP code to the currently pending login.
/// Kept for callers that predate session-scoped FFI.
#[no_mangle]
pub extern "C" fn rustdesk_submit_2fa(code: *const c_char) -> bool {
    submit_2fa_for_pending_session(None, code)
}

/// Submit one transient Peer TOTP code to a specific native session.
#[no_mangle]
pub extern "C" fn rustdesk_submit_2fa_for_session(
    session_id: u64,
    code: *const c_char,
) -> bool {
    submit_2fa_for_pending_session(Some(session_id), code)
}

/// Cancel only the pending connection attempt(s) owned by one native session.
#[no_mangle]
pub extern "C" fn rustdesk_cancel_pending_connect_for_session(session_id: u64) {
    cancel_pending_connect_for_session(session_id);
}

fn copy_string_to_c_buffer(value: &str, buffer: *mut c_char, buffer_len: usize) -> usize {
    let bytes = value.as_bytes();
    if !buffer.is_null() && buffer_len > 0 {
        let copy_len = bytes.len().min(buffer_len - 1);
        unsafe {
            ptr::copy_nonoverlapping(bytes.as_ptr(), buffer as *mut u8, copy_len);
            *buffer.add(copy_len) = 0;
        }
    }
    bytes.len()
}

/// 复制最近一次连接错误到调用方缓冲区，返回完整错误长度。
#[no_mangle]
pub extern "C" fn rustdesk_last_error(buffer: *mut c_char, buffer_len: usize) -> usize {
    let message = LAST_ERROR
        .lock()
        .map(|err| err.clone())
        .unwrap_or_else(|_| "last error lock poisoned".to_string());
    copy_string_to_c_buffer(&message, buffer, buffer_len)
}

/// Probe a RustDesk peer without opening a desktop session.
///
/// Rendezvous responses are authoritative for relay/ID mode: a route response
/// means the peer is currently registered, while an explicit refusal means it
/// is offline or unknown to the server. Network and protocol failures remain
/// unknown so the homepage does not turn a broken client/server path into a
/// false offline result. Direct mode only checks the configured peer listener.
#[no_mangle]
pub extern "C" fn rustdesk_probe_presence(
    cfg: *const RustDeskConfig,
    out_result: *mut RustDeskPresenceResult,
) -> bool {
    if out_result.is_null() {
        return false;
    }
    let mut result = RustDeskPresenceResult {
        state: 0,
        latency_ms: -1,
        error_code: 3,
    };
    if cfg.is_null() {
        unsafe { *out_result = result; }
        return true;
    }

    let config = unsafe { &*cfg };
    let started = Instant::now();
    let host = ffi_string(config.host);
    let peer_id = ffi_string(config.username);
    let server_key = ffi_string(config.key);
    let api_token = ffi_string(config.token);
    let port = if config.port > 0 {
        config.port as u16
    } else if config.direct_connection {
        21118
    } else {
        21116
    };

    let probe = if host.trim().is_empty() || (!config.direct_connection && peer_id.trim().is_empty()) {
        Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "RustDesk presence endpoint or peer identity is missing",
        ))
    } else if config.direct_connection {
        net::connect_tcp_host(
            &host,
            port,
            "rustdesk_presence_direct",
            Duration::from_secs(3),
        )
        .map(|_| ())
    } else {
        let shared_access_key = config.key_mode == 2;
        let rendezvous_secure = !shared_access_key &&
            !server_key.trim().is_empty() && !api_token.trim().is_empty();
        let mut rendezvous = RendezvousClient::new();
        rendezvous
            .connect_with_timeout(
                &host,
                port,
                &server_key,
                rendezvous_secure,
                Duration::from_secs(3),
            )
            .and_then(|_| {
                rendezvous.request_force_relay(
                    &peer_id,
                    &server_key,
                    &api_token,
                    protocol::rendezvous_proto::ConnType::DEFAULT_CONN,
                )
            })
            .map(|_| ())
    };

    result.latency_ms = started
        .elapsed()
        .as_millis()
        .min(i32::MAX as u128) as c_int;
    match probe {
        Ok(()) => {
            result.state = 1;
            result.error_code = 0;
        }
        Err(error) if error.kind() == io::ErrorKind::ConnectionRefused => {
            result.state = 2;
            result.error_code = 1;
        }
        Err(error) if error.kind() == io::ErrorKind::TimedOut => {
            result.error_code = 2;
        }
        Err(error) if matches!(error.kind(), io::ErrorKind::InvalidInput | io::ErrorKind::InvalidData) => {
            result.error_code = 3;
        }
        Err(_) => {
            result.error_code = 4;
        }
    }
    unsafe { *out_result = result; }
    true
}

/// Copy a non-destructive stream telemetry snapshot for one FFI connection.
#[no_mangle]
pub extern "C" fn rustdesk_get_stream_stats(
    handle: *mut c_void,
    out_stats: *mut RustDeskStreamStats,
) -> bool {
    if handle.is_null() || out_stats.is_null() {
        return false;
    }
    let ctx = unsafe { &*(handle as *const RustDeskClient) };
    let Ok(stats) = ctx.stream_stats.lock() else {
        return false;
    };
    unsafe {
        ptr::write(out_stats, *stats);
    }
    true
}

/// Queue a live RustDesk image-quality update for the streaming writer.
#[no_mangle]
pub extern "C" fn rustdesk_set_image_quality(handle: *mut c_void, quality: c_int) -> bool {
    if handle.is_null() || !(0..=2).contains(&quality) {
        set_last_error("rustdesk_set_image_quality invalid arguments");
        return false;
    }
    let ctx = unsafe { &*(handle as *const RustDeskClient) };
    let generation = {
        let Ok(mut state) = ctx.quality_state.lock() else {
            set_last_error("rustdesk_set_image_quality state lock poisoned");
            return false;
        };
        state.requested_generation = state.requested_generation.wrapping_add(1).max(1);
        state.raw_quality = quality;
        state.effective_quality = quality;
        state.update_status = 1;
        state.requested_generation
    };
    if ctx.controls.enqueue(ControlMsg::SetImageQuality { quality, generation }) {
        true
    } else {
        if let Ok(mut state) = ctx.quality_state.lock() {
            if state.requested_generation == generation {
                state.update_status = 3;
            }
        }
        false
    }
}

/// Copy the latest quality preference/application state without consuming it.
#[no_mangle]
pub extern "C" fn rustdesk_get_quality_state(
    handle: *mut c_void,
    out_state: *mut RustDeskQualityState,
) -> bool {
    if handle.is_null() || out_state.is_null() {
        return false;
    }
    let ctx = unsafe { &*(handle as *const RustDeskClient) };
    let Ok(state) = ctx.quality_state.lock() else {
        return false;
    };
    unsafe { ptr::write(out_state, *state); }
    true
}

/// Copy the latest remote permission snapshot without consuming it.
#[no_mangle]
pub extern "C" fn rustdesk_get_permission_state(
    handle: *mut c_void,
    out_state: *mut RustDeskPermissionState,
) -> bool {
    if handle.is_null() || out_state.is_null() {
        return false;
    }
    let ctx = unsafe { &*(handle as *const RustDeskClient) };
    let permissions = ctx.controls.permission_snapshot();
    unsafe {
        ptr::write(
            out_state,
            RustDeskPermissionState {
                version: RUSTDESK_PERMISSION_STATE_VERSION,
                known_mask: permissions.known_mask,
                enabled_mask: permissions.enabled_mask,
                reserved: 0,
            },
        );
    }
    true
}

/// Copy current remote-display geometry and as many supported resolutions as fit.
#[no_mangle]
pub extern "C" fn rustdesk_get_display_snapshot(
    handle: *mut c_void,
    out_snapshot: *mut RustDeskDisplaySnapshot,
    out_resolutions: *mut RustDeskResolution,
    resolution_capacity: usize,
) -> bool {
    if handle.is_null() || out_snapshot.is_null() {
        return false;
    }
    let ctx = unsafe { &*(handle as *const RustDeskClient) };
    let Ok(state) = ctx.display_state.lock() else {
        return false;
    };
    let snapshot = RustDeskDisplaySnapshot {
        version: RUSTDESK_DISPLAY_SNAPSHOT_VERSION,
        current_display: state.current_display,
        width: state.width,
        height: state.height,
        original_width: state.original_width,
        original_height: state.original_height,
        scale_milli: state.scale_milli,
        geometry_epoch: state.geometry_epoch,
        resolution_count: state.resolutions.len().min(RUSTDESK_MAX_DISPLAY_RESOLUTIONS) as u32,
    };
    unsafe {
        ptr::write(out_snapshot, snapshot);
    }
    if !out_resolutions.is_null() && resolution_capacity > 0 {
        for (index, (width, height)) in state
            .resolutions
            .iter()
            .take(resolution_capacity.min(RUSTDESK_MAX_DISPLAY_RESOLUTIONS))
            .enumerate()
        {
            unsafe {
                ptr::write(out_resolutions.add(index), RustDeskResolution {
                    width: *width,
                    height: *height,
                });
            }
        }
    }
    true
}

fn copy_display_name(name: &str, target: &mut [u8; RUSTDESK_DISPLAY_NAME_BYTES]) -> u32 {
    let mut length = name.len().min(target.len());
    while length > 0 && !name.is_char_boundary(length) {
        length -= 1;
    }
    target[..length].copy_from_slice(&name.as_bytes()[..length]);
    length as u32
}

/// Copy the complete remote display catalog into fixed-width C snapshots.
///
/// The resolution array is flattened. Each display reports its offset and
/// count, so the caller can use one bounded allocation for all displays.
#[no_mangle]
pub extern "C" fn rustdesk_get_display_list(
    handle: *mut c_void,
    out_displays: *mut RustDeskDisplayInfoSnapshot,
    display_capacity: usize,
    out_resolutions: *mut RustDeskResolution,
    resolution_capacity: usize,
    out_display_count: *mut usize,
    out_resolution_count: *mut usize,
) -> bool {
    if handle.is_null() || out_display_count.is_null() || out_resolution_count.is_null() {
        return false;
    }
    let ctx = unsafe { &*(handle as *const RustDeskClient) };
    let Ok(state) = ctx.display_state.lock() else {
        return false;
    };

    let fallback;
    let displays = if state.displays.is_empty() {
        fallback = vec![RustDeskDisplayInfoState {
            display: state.current_display,
            width: state.width,
            height: state.height,
            original_width: state.original_width,
            original_height: state.original_height,
            scale_milli: state.scale_milli,
            resolutions: state.resolutions.clone(),
            ..RustDeskDisplayInfoState::default()
        }];
        fallback.as_slice()
    } else {
        state.displays.as_slice()
    };
    let displays = &displays[..displays.len().min(RUSTDESK_MAX_DISPLAYS)];
    let total_resolution_count: usize = displays
        .iter()
        .map(|display| display.resolutions.len().min(RUSTDESK_MAX_DISPLAY_RESOLUTIONS))
        .sum();

    unsafe {
        *out_display_count = displays.len();
        *out_resolution_count = total_resolution_count;
    }

    let mut resolution_offset = 0usize;
    for (index, display) in displays.iter().enumerate() {
        let resolutions = &display.resolutions[..display
            .resolutions
            .len()
            .min(RUSTDESK_MAX_DISPLAY_RESOLUTIONS)];
        if !out_displays.is_null() && index < display_capacity {
            let mut snapshot = RustDeskDisplayInfoSnapshot {
                display: display.display,
                x: display.x,
                y: display.y,
                width: display.width,
                height: display.height,
                original_width: display.original_width,
                original_height: display.original_height,
                scale_milli: display.scale_milli,
                online: display.online as u8,
                cursor_embedded: display.cursor_embedded as u8,
                resolution_offset: resolution_offset as u32,
                resolution_count: resolutions.len() as u32,
                ..RustDeskDisplayInfoSnapshot::default()
            };
            snapshot.name_len = copy_display_name(&display.name, &mut snapshot.name);
            unsafe {
                ptr::write(out_displays.add(index), snapshot);
            }
        }
        for (resolution_index, (width, height)) in resolutions.iter().enumerate() {
            let output_index = resolution_offset + resolution_index;
            if !out_resolutions.is_null() && output_index < resolution_capacity {
                unsafe {
                    ptr::write(
                        out_resolutions.add(output_index),
                        RustDeskResolution {
                            width: *width,
                            height: *height,
                        },
                    );
                }
            }
        }
        resolution_offset += resolutions.len();
    }
    true
}

#[no_mangle]
pub extern "C" fn rustdesk_switch_display(handle: *mut c_void, display: c_int) -> bool {
    if handle.is_null() || display < 0 || display as usize >= RUSTDESK_MAX_DISPLAYS {
        set_last_error("rustdesk_switch_display invalid display");
        return false;
    }
    let ctx = unsafe { &*(handle as *const RustDeskClient) };
    let generation = {
        let Ok(mut state) = ctx.display_state.lock() else {
            set_last_error("rustdesk_switch_display display state lock poisoned");
            return false;
        };
        state.switch_generation = state.switch_generation.wrapping_add(1).max(1);
        state.desired_display = Some(display);
        state.pending_switch_generation = Some(state.switch_generation);
        state.switch_generation
    };
    ctx.controls.enqueue(ControlMsg::DisplaySwitch {
        display,
        generation,
    })
}

#[no_mangle]
pub extern "C" fn rustdesk_capture_displays(
    handle: *mut c_void,
    set_displays: *const c_int,
    set_count: usize,
) -> bool {
    if handle.is_null() || set_count > RUSTDESK_MAX_DISPLAYS {
        return false;
    }
    if set_count > 0 && set_displays.is_null() {
        return false;
    }
    let set = if set_count == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(set_displays, set_count) }.to_vec()
    };
    if set
        .iter()
        .any(|display| *display < 0 || *display as usize >= RUSTDESK_MAX_DISPLAYS)
    {
        return false;
    }
    let ctx = unsafe { &*(handle as *const RustDeskClient) };
    ctx.controls.enqueue(ControlMsg::CaptureDisplays {
        add: Vec::new(),
        sub: Vec::new(),
        set,
    });
    true
}

#[no_mangle]
pub extern "C" fn rustdesk_refresh_video_display(handle: *mut c_void, display: c_int) -> bool {
    if handle.is_null() || display < 0 || display as usize >= RUSTDESK_MAX_DISPLAYS {
        return false;
    }
    let ctx = unsafe { &*(handle as *const RustDeskClient) };
    ctx.controls.enqueue(ControlMsg::RefreshVideoDisplay { display });
    true
}

#[no_mangle]
pub extern "C" fn rustdesk_change_display_resolution(
    handle: *mut c_void,
    display: c_int,
    width: c_int,
    height: c_int,
) -> bool {
    if handle.is_null()
        || display < 0
        || display as usize >= RUSTDESK_MAX_DISPLAYS
        || width <= 0
        || height <= 0
    {
        set_last_error("rustdesk_change_display_resolution invalid arguments");
        return false;
    }
    let ctx = unsafe { &*(handle as *const RustDeskClient) };
    ctx.controls.enqueue(ControlMsg::ChangeDisplayResolution { display, width, height });
    true
}

#[no_mangle]
pub extern "C" fn rustdesk_send_touch_scale(handle: *mut c_void, scale: c_int) -> bool {
    if handle.is_null() {
        return false;
    }
    let ctx = unsafe { &*(handle as *const RustDeskClient) };
    ctx.controls.enqueue(ControlMsg::TouchScale { scale })
}

#[no_mangle]
pub extern "C" fn rustdesk_send_touch_pan(
    handle: *mut c_void,
    phase: c_int,
    x: c_int,
    y: c_int,
) -> bool {
    if handle.is_null() {
        return false;
    }
    let message = match phase {
        0 => ControlMsg::TouchPanStart { x, y },
        1 => ControlMsg::TouchPanUpdate { x, y },
        2 => ControlMsg::TouchPanEnd { x, y },
        _ => return false,
    };
    let ctx = unsafe { &*(handle as *const RustDeskClient) };
    ctx.controls.enqueue(message)
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
    let queued = ctx.controls.enqueue(msg);
    let index = RUSTDESK_MOUSE_ENQUEUE_COUNT.fetch_add(1, Ordering::Relaxed) + 1;
    if button != u32::MAX || index <= 20 || index % 120 == 0 {
        eprintln!(
            "[RustDesk-FFI] input enqueue kind={} number={} x={} y={} button={} pressed={} queued={}",
            if button == u32::MAX { "mouse_move" } else { "mouse" },
            index,
            x,
            y,
            button,
            pressed,
            queued,
        );
    }
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

/// Send a two-dimensional physical-touchpad wheel event.
#[no_mangle]
pub extern "C" fn rustdesk_send_mouse_wheel_2d(handle: *mut c_void, x: i32, y: i32) -> bool {
    if handle.is_null() || (x == 0 && y == 0) {
        return false;
    }
    let ctx = unsafe { &*(handle as *const RustDeskClient) };
    ctx.controls.enqueue(ControlMsg::MouseWheel2D { x, y })
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
fn should_retry_file_transfer_compat_route(
    conn_type: protocol::rendezvous_proto::ConnType,
    state: &connector::ConnState,
) -> bool {
    conn_type == protocol::rendezvous_proto::ConnType::FILE_TRANSFER
        && matches!(
            state,
            connector::ConnState::RequestingRelay | connector::ConnState::ConnectingToPeer
        )
}

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
    if let Ok(mut error) = ctx.transfer_error.lock() {
        error.clear();
    }
    let host = ctx.host.clone();
    let port = ctx.port;
    let relay_fallback_port = ctx.relay_fallback_port;
    let server_key = ctx.server_key.clone();
    let shared_access_key = ctx.shared_access_key;
    let api_token = ctx.api_token.clone();
    let peer_id = ctx.peer_id.clone();
    let password = ctx.password.clone();
    let request_approval = ctx.request_approval;
    let direct_connection = ctx.direct_connection;
    let connection_id = ctx.connection_id;
    let remote_path_owned = path.clone();
    let remote_dir = split_remote_file_path(&path).0.to_string();
    let transfer_status = Arc::clone(&ctx.transfer_status);
    let transfer_error = Arc::clone(&ctx.transfer_error);

    std::thread::spawn(move || {
        let connect_epoch = begin_connect_epoch(connection_id);
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let mut connector = if direct_connection {
                let mut candidate = connector::RustDeskConnector::new_with_connection_id(
                    connection_id,
                    connect_epoch,
                );
                candidate.connect_file_transfer_direct(
                    &host,
                    port,
                    &password,
                    &remote_dir,
                )?;
                candidate
            } else {
                // Modern peers advertise FILE_TRANSFER at rendezvous. HarmonyOS
                // 1.0.7 used DEFAULT_CONN for the route and then identified the
                // dedicated file session in LoginRequest.file_transfer. Keep the
                // official modern route first, but retry a fresh connection with
                // the proven 1.0.7 route when an older/custom hbbs does not answer.
                let route_types = [
                    protocol::rendezvous_proto::ConnType::FILE_TRANSFER,
                    protocol::rendezvous_proto::ConnType::DEFAULT_CONN,
                ];
                let mut connected = None;
                let mut route_errors = Vec::new();
                let mut last_route_kind = std::io::ErrorKind::NotConnected;
                for conn_type in route_types {
                    let mut candidate = connector::RustDeskConnector::new_with_connection_id(
                        connection_id,
                        connect_epoch,
                    );
                    match candidate.connect_file_transfer(
                        &host,
                        port,
                        relay_fallback_port,
                        &server_key,
                        &api_token,
                        &peer_id,
                        &password,
                        &remote_dir,
                        request_approval,
                        shared_access_key,
                        conn_type,
                    ) {
                        Ok(()) => {
                            eprintln!(
                                "[RustDesk-FFI] file-transfer route connected conn_type={:?}",
                                conn_type
                            );
                            connected = Some(candidate);
                            break;
                        }
                        Err(err) => {
                            last_route_kind = err.kind();
                            let fallback = should_retry_file_transfer_compat_route(
                                conn_type,
                                candidate.state(),
                            );
                            eprintln!(
                                "[RustDesk-FFI] file-transfer route failed conn_type={:?} stage={:?} kind={:?} err={} fallback={}",
                                conn_type,
                                candidate.state(),
                                err.kind(),
                                err,
                                fallback
                            );
                            route_errors.push(format!("{:?}:{:?}:{}", conn_type, err.kind(), err));
                            // Compatibility mode is only a rendezvous/relay
                            // fallback. Never retry an authentication, peer-key,
                            // permission, or upload failure as DEFAULT_CONN.
                            if !fallback {
                                break;
                            }
                        }
                    }
                }
                connected.ok_or_else(|| {
                    std::io::Error::new(
                        last_route_kind,
                        format!(
                            "file-transfer route failed for modern and 1.0.7 compatibility modes [{}]",
                            route_errors.join(" | ")
                        ),
                    )
                })?
            };
            connector.upload_file_once(
                &remote_path_owned,
                file_data,
                Duration::from_secs(30),
            )
        }))
        .unwrap_or_else(|_| {
            Err(std::io::Error::new(
                std::io::ErrorKind::Other,
                "file-transfer worker panic",
            ))
        });
        finish_connect_epoch(connect_epoch, connection_id);

        match result {
            Ok(()) => {
                if let Ok(mut error) = transfer_error.lock() {
                    error.clear();
                }
                if let Ok(mut status) = transfer_status.lock() {
                    *status = RustDeskTransferStatus { state: 3, transfer_id,
                        transferred_bytes: len as u64, total_bytes: len as u64, diagnostic_code: 0 };
                }
            }
            Err(err) => {
                let message = format!(
                    "file-transfer failed transfer_id={} kind={:?} err={}",
                    transfer_id,
                    err.kind(),
                    err
                );
                set_last_error(message.clone());
                eprintln!("[RustDesk-FFI] {}", message);
                if let Ok(mut error) = transfer_error.lock() {
                    *error = message;
                }
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

/// Copy the failure owned by the current file-transfer worker. Unlike the
/// process-wide last-error string, this value cannot be overwritten by normal
/// mouse, keyboard, refresh, or video-control traffic on the desktop session.
#[no_mangle]
pub extern "C" fn rustdesk_get_transfer_error(
    handle: *mut c_void,
    buffer: *mut c_char,
    buffer_len: usize,
) -> usize {
    if handle.is_null() {
        return 0;
    }
    let ctx = unsafe { &*(handle as *const RustDeskClient) };
    let message = ctx
        .transfer_error
        .lock()
        .map(|error| error.clone())
        .unwrap_or_else(|_| "file-transfer error lock poisoned".to_string());
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
    use crate::protocol::message_proto::{EncodedVideoFrame, VideoFrame_oneof_union};
    use std::ffi::CString;

    fn test_client_with_display_state(display_state: RustDeskDisplayState) -> RustDeskClient {
        RustDeskClient {
            connection_id: 0,
            peer_id: String::new(),
            host: String::new(),
            port: 0,
            relay_fallback_port: DEFAULT_RELAY_PORT,
            server_key: String::new(),
            shared_access_key: false,
            api_token: String::new(),
            password: String::new(),
            request_approval: false,
            direct_connection: false,
            controls: Arc::new(ControlInbox::default()),
            shutdown_stream: None,
            stream_handle: None,
            transfer_status: Arc::new(Mutex::new(RustDeskTransferStatus::default())),
            transfer_error: Arc::new(Mutex::new(String::new())),
            remote_clipboard: Arc::new(Mutex::new(Vec::new())),
            stream_stats: Arc::new(Mutex::new(RustDeskStreamStats::default())),
            quality_state: Arc::new(Mutex::new(RustDeskQualityState::default())),
            display_state: Arc::new(Mutex::new(display_state)),
        }
    }

    #[test]
    fn peer_platform_callback_runs_before_stream_and_propagates_rejection() {
        struct CallbackProbe {
            platform: String,
            accept: bool,
        }

        extern "C" fn capture_platform(
            platform: *const c_char,
            user_data: *mut c_void,
        ) -> bool {
            let probe = unsafe { &mut *(user_data as *mut CallbackProbe) };
            probe.platform = unsafe { CStr::from_ptr(platform) }
                .to_string_lossy()
                .into_owned();
            probe.accept
        }

        let mut probe = CallbackProbe {
            platform: String::new(),
            accept: false,
        };
        let accepted = notify_peer_platform(
            Some(capture_platform),
            "Windows\0Desktop",
            &mut probe as *mut CallbackProbe as *mut c_void,
        );

        assert!(!accepted);
        assert_eq!(probe.platform, "Windows Desktop");
    }

    #[test]
    fn relay_fallback_port_uses_configured_value_and_rejects_invalid_native_input() {
        assert_eq!(relay_fallback_port_from_config(23017), 23017);
        assert_eq!(relay_fallback_port_from_config(0), DEFAULT_RELAY_PORT);
        assert_eq!(
            relay_fallback_port_from_config(u16::MAX as c_int + 1),
            DEFAULT_RELAY_PORT
        );
    }

    #[test]
    fn legacy_file_route_is_only_a_rendezvous_transport_fallback() {
        use crate::protocol::rendezvous_proto::ConnType;

        assert!(should_retry_file_transfer_compat_route(
            ConnType::FILE_TRANSFER,
            &connector::ConnState::RequestingRelay,
        ));
        assert!(should_retry_file_transfer_compat_route(
            ConnType::FILE_TRANSFER,
            &connector::ConnState::ConnectingToPeer,
        ));
        assert!(!should_retry_file_transfer_compat_route(
            ConnType::FILE_TRANSFER,
            &connector::ConnState::KeyExchanging,
        ));
        assert!(!should_retry_file_transfer_compat_route(
            ConnType::FILE_TRANSFER,
            &connector::ConnState::LoggingIn,
        ));
        assert!(!should_retry_file_transfer_compat_route(
            ConnType::DEFAULT_CONN,
            &connector::ConnState::RequestingRelay,
        ));
    }

    #[test]
    fn display_snapshot_copies_geometry_and_clamps_the_output_buffer() {
        let mut client = test_client_with_display_state(RustDeskDisplayState {
            current_display: 2,
            width: 1080,
            height: 1920,
            original_width: 1440,
            original_height: 2560,
            scale_milli: 1250,
            geometry_epoch: 7,
            resolutions: vec![(1080, 1920), (720, 1280), (540, 960)],
            displays: Vec::new(),
            ..RustDeskDisplayState::default()
        });
        let handle = &mut client as *mut RustDeskClient as *mut c_void;
        let mut snapshot = RustDeskDisplaySnapshot::default();
        let mut resolutions = [RustDeskResolution::default(); 2];

        assert!(rustdesk_get_display_snapshot(
            handle,
            &mut snapshot,
            resolutions.as_mut_ptr(),
            resolutions.len(),
        ));
        assert_eq!(snapshot.version, RUSTDESK_DISPLAY_SNAPSHOT_VERSION);
        assert_eq!(snapshot.current_display, 2);
        assert_eq!((snapshot.width, snapshot.height), (1080, 1920));
        assert_eq!((snapshot.original_width, snapshot.original_height), (1440, 2560));
        assert_eq!(snapshot.scale_milli, 1250);
        assert_eq!(snapshot.geometry_epoch, 7);
        assert_eq!(snapshot.resolution_count, 3);
        assert_eq!((resolutions[0].width, resolutions[0].height), (1080, 1920));
        assert_eq!((resolutions[1].width, resolutions[1].height), (720, 1280));
    }

    #[test]
    fn permission_snapshot_exposes_an_explicit_remote_view_only_state() {
        let mut client = test_client_with_display_state(RustDeskDisplayState::default());
        client
            .controls
            .update_permission(control_inbox::PERMISSION_KEYBOARD, false);
        let handle = &mut client as *mut RustDeskClient as *mut c_void;
        let mut snapshot = RustDeskPermissionState::default();

        assert!(rustdesk_get_permission_state(handle, &mut snapshot));
        assert_eq!(snapshot.version, RUSTDESK_PERMISSION_STATE_VERSION);
        assert_eq!(
            snapshot.known_mask & control_inbox::PERMISSION_KEYBOARD,
            control_inbox::PERMISSION_KEYBOARD
        );
        assert_eq!(snapshot.enabled_mask & control_inbox::PERMISSION_KEYBOARD, 0);
    }

    #[test]
    fn display_list_copies_catalog_names_and_flattened_resolutions() {
        let mut client = test_client_with_display_state(RustDeskDisplayState {
            current_display: 1,
            displays: vec![
                RustDeskDisplayInfoState {
                    display: 0,
                    x: 0,
                    width: 1920,
                    height: 1080,
                    name: "Primary".to_string(),
                    online: true,
                    resolutions: vec![(1920, 1080)],
                    ..RustDeskDisplayInfoState::default()
                },
                RustDeskDisplayInfoState {
                    display: 1,
                    x: 1920,
                    width: 2560,
                    height: 1440,
                    name: "Secondary".to_string(),
                    online: true,
                    resolutions: vec![(2560, 1440), (1920, 1080)],
                    ..RustDeskDisplayInfoState::default()
                },
            ],
            ..RustDeskDisplayState::default()
        });
        let handle = &mut client as *mut RustDeskClient as *mut c_void;
        let mut displays = [RustDeskDisplayInfoSnapshot::default(); 1];
        let mut resolutions = [RustDeskResolution::default(); 3];
        let mut display_count = 0usize;
        let mut resolution_count = 0usize;

        assert!(rustdesk_get_display_list(
            handle,
            displays.as_mut_ptr(),
            displays.len(),
            resolutions.as_mut_ptr(),
            resolutions.len(),
            &mut display_count,
            &mut resolution_count,
        ));
        assert_eq!(display_count, 2);
        assert_eq!(resolution_count, 3);
        assert_eq!(displays[0].display, 0);
        assert_eq!(displays[0].name_len as usize, "Primary".len());
        assert_eq!(&displays[0].name[..7], b"Primary");
        assert_eq!(displays[0].resolution_offset, 0);
        assert_eq!(displays[0].resolution_count, 1);
        assert_eq!((resolutions[1].width, resolutions[1].height), (2560, 1440));
        assert_eq!((resolutions[2].width, resolutions[2].height), (1920, 1080));
    }

    extern "C" fn collect_display_frame(frame: *const FfiVideoFrameV2, user_data: *mut c_void) {
        unsafe {
            let frames = &mut *(user_data as *mut Vec<(i32, i32, i32, u32)>);
            let frame = &*frame;
            frames.push((frame.display, frame.width, frame.height, frame.abi_version));
        }
    }

    extern "C" fn collect_legacy_frame(frame: *const FfiVideoFrame, user_data: *mut c_void) {
        unsafe {
            let frames = &mut *(user_data as *mut Vec<(i32, i32)>);
            let frame = &*frame;
            frames.push((frame.width, frame.height));
        }
    }

    #[test]
    fn video_frame_abis_keep_separate_stable_layouts() {
        assert_eq!(std::mem::size_of::<FfiVideoFrame>(), 48);
        assert_eq!(std::mem::size_of::<FfiVideoFrameV2>(), 56);
    }

    #[test]
    fn legacy_frame_callback_receives_only_the_v1_layout() {
        let display_state = Arc::new(Mutex::new(RustDeskDisplayState {
            width: 1920,
            height: 1080,
            displays: vec![RustDeskDisplayInfoState {
                display: 1,
                width: 2560,
                height: 1440,
                ..RustDeskDisplayInfoState::default()
            }],
            ..RustDeskDisplayState::default()
        }));
        let mut frame = VideoFrame::new();
        frame.set_display(1);
        let mut encoded = EncodedVideoFrames::new();
        let mut encoded_frame = EncodedVideoFrame::new();
        encoded_frame.set_data(vec![0x01]);
        encoded.mut_frames().push(encoded_frame);
        frame.union = Some(VideoFrame_oneof_union::h264s(encoded));
        let mut received = Vec::new();
        let mut video_worker = VideoCallbackWorker::start(
            Some(FrameCallbackKind::V1(collect_legacy_frame)),
            &mut received as *mut Vec<(i32, i32)> as usize,
            Arc::new(ControlInbox::default()),
        );

        dispatch_video_frame(
            &frame,
            &display_state,
            &mut video_worker,
        );
        video_worker.stop();

        assert_eq!(received, vec![(2560, 1440)]);
    }

    #[test]
    fn encoded_frames_preserve_display_and_use_matching_geometry() {
        let display_state = Arc::new(Mutex::new(RustDeskDisplayState {
            width: 1920,
            height: 1080,
            displays: vec![
                RustDeskDisplayInfoState {
                    display: 0,
                    width: 1920,
                    height: 1080,
                    ..RustDeskDisplayInfoState::default()
                },
                RustDeskDisplayInfoState {
                    display: 1,
                    width: 2560,
                    height: 1440,
                    ..RustDeskDisplayInfoState::default()
                },
            ],
            ..RustDeskDisplayState::default()
        }));
        let mut frame = VideoFrame::new();
        frame.set_display(1);
        let mut encoded = EncodedVideoFrames::new();
        let mut encoded_frame = EncodedVideoFrame::new();
        encoded_frame.set_data(vec![0x01, 0x02]);
        encoded_frame.set_key(true);
        encoded.mut_frames().push(encoded_frame);
        frame.union = Some(VideoFrame_oneof_union::h264s(encoded));
        let mut received = Vec::new();
        let mut video_worker = VideoCallbackWorker::start(
            Some(FrameCallbackKind::V2(collect_display_frame)),
            &mut received as *mut Vec<(i32, i32, i32, u32)> as usize,
            Arc::new(ControlInbox::default()),
        );

        dispatch_video_frame(
            &frame,
            &display_state,
            &mut video_worker,
        );
        video_worker.stop();

        assert_eq!(received, vec![(1, 2560, 1440, RUSTDESK_VIDEO_FRAME_ABI_VERSION)]);
    }

    #[test]
    fn video_callback_queue_keeps_new_keyframe_as_the_recovery_boundary() {
        let queue = VideoCallbackQueue::new();
        for timestamp in 0..VIDEO_CALLBACK_QUEUE_CAPACITY as u64 {
            let outcome = queue.enqueue(QueuedVideoFrame {
                data: vec![timestamp as u8],
                width: 1280,
                height: 720,
                codec: 0,
                timestamp,
                is_key_frame: false,
                display: 0,
            });
            assert!(matches!(outcome, VideoQueueOutcome::Queued { .. }));
        }

        let outcome = queue.enqueue(QueuedVideoFrame {
            data: vec![0xff],
            width: 1280,
            height: 720,
            codec: 0,
            timestamp: VIDEO_CALLBACK_QUEUE_CAPACITY as u64,
            is_key_frame: true,
            display: 0,
        });
        assert!(matches!(
            outcome,
            VideoQueueOutcome::Queued {
                evicted: VIDEO_CALLBACK_QUEUE_CAPACITY,
                request_refresh: false,
            }
        ));

        let state = queue.state.lock().expect("video queue state");
        assert_eq!(state.frames.len(), 1);
        assert!(state.frames.front().expect("keyframe").is_key_frame);
    }

    #[test]
    fn video_callback_queue_requests_only_one_refresh_until_keyframe_arrives() {
        let queue = VideoCallbackQueue::new();
        for timestamp in 0..VIDEO_CALLBACK_QUEUE_CAPACITY as u64 {
            let outcome = queue.enqueue(QueuedVideoFrame {
                data: vec![timestamp as u8],
                width: 1280,
                height: 720,
                codec: 0,
                timestamp,
                is_key_frame: true,
                display: 0,
            });
            assert!(matches!(outcome, VideoQueueOutcome::Queued { .. }));
        }

        let outcome = queue.enqueue(QueuedVideoFrame {
            data: vec![0xee],
            width: 1280,
            height: 720,
            codec: 0,
            timestamp: VIDEO_CALLBACK_QUEUE_CAPACITY as u64,
            is_key_frame: false,
            display: 0,
        });
        assert!(matches!(
            outcome,
            VideoQueueOutcome::Dropped {
                request_refresh: true,
            }
        ));

        let repeated_delta = queue.enqueue(QueuedVideoFrame {
            data: vec![0xef],
            width: 1280,
            height: 720,
            codec: 0,
            timestamp: VIDEO_CALLBACK_QUEUE_CAPACITY as u64 + 1,
            is_key_frame: false,
            display: 0,
        });
        assert!(matches!(
            repeated_delta,
            VideoQueueOutcome::Dropped {
                request_refresh: false,
            }
        ));

        let recovery_keyframe = queue.enqueue(QueuedVideoFrame {
            data: vec![0xff],
            width: 1280,
            height: 720,
            codec: 0,
            timestamp: VIDEO_CALLBACK_QUEUE_CAPACITY as u64 + 2,
            is_key_frame: true,
            display: 0,
        });
        assert!(matches!(
            recovery_keyframe,
            VideoQueueOutcome::Queued {
                evicted: VIDEO_CALLBACK_QUEUE_CAPACITY,
                request_refresh: false,
            }
        ));

        let state = queue.state.lock().expect("video queue state");
        assert_eq!(state.frames.len(), 1);
        assert!(state.frames.front().expect("recovery keyframe").is_key_frame);
        assert!(!state.awaiting_key_frame);
    }

    #[test]
    fn video_callback_queue_allows_vp9_burst_to_reach_native_recovery_boundary() {
        let queue = VideoCallbackQueue::new();
        for timestamp in 0..VP9_VIDEO_CALLBACK_QUEUE_CAPACITY as u64 {
            let outcome = queue.enqueue(QueuedVideoFrame {
                data: vec![timestamp as u8],
                width: 2940,
                height: 1912,
                codec: FFI_VP9_CODEC,
                timestamp,
                is_key_frame: false,
                display: 0,
            });
            assert!(matches!(outcome, VideoQueueOutcome::Queued { .. }));
        }

        let state = queue.state.lock().expect("video queue state");
        assert_eq!(state.frames.len(), VP9_VIDEO_CALLBACK_QUEUE_CAPACITY);
        assert!(!state.awaiting_key_frame);
        drop(state);

        let overflow = queue.enqueue(QueuedVideoFrame {
            data: vec![0xff],
            width: 2940,
            height: 1912,
            codec: FFI_VP9_CODEC,
            timestamp: VP9_VIDEO_CALLBACK_QUEUE_CAPACITY as u64,
            is_key_frame: false,
            display: 0,
        });
        assert!(matches!(
            overflow,
            VideoQueueOutcome::Dropped {
                request_refresh: true,
            }
        ));
    }

    #[test]
    fn display_control_ffi_enqueues_switch_capture_and_refresh() {
        let mut client = test_client_with_display_state(RustDeskDisplayState::default());
        let handle = &mut client as *mut RustDeskClient as *mut c_void;
        let selected = [1 as c_int, 2 as c_int];

        assert!(rustdesk_switch_display(handle, 1));
        assert!(rustdesk_capture_displays(handle, selected.as_ptr(), selected.len()));
        assert!(rustdesk_refresh_video_display(handle, 1));

        let controls = client.controls.take_batch(3);
        assert!(matches!(
            controls.as_slice(),
            [
                ControlMsg::DisplaySwitch {
                    display: 1,
                    generation: 1
                },
                ControlMsg::CaptureDisplays { add, sub, set },
                ControlMsg::RefreshVideoDisplay { display: 1 },
            ] if add.is_empty() && sub.is_empty() && set == &vec![1, 2]
        ));
    }

    #[test]
    fn display_and_touch_ffi_controls_enqueue_the_official_messages() {
        let mut client = test_client_with_display_state(RustDeskDisplayState::default());
        let handle = &mut client as *mut RustDeskClient as *mut c_void;

        assert!(!rustdesk_change_display_resolution(handle, -1, 1920, 1080));
        assert!(!rustdesk_change_display_resolution(
            handle,
            RUSTDESK_MAX_DISPLAYS as c_int,
            1920,
            1080
        ));
        assert!(!rustdesk_change_display_resolution(handle, 0, 0, 1080));
        assert!(!rustdesk_change_display_resolution(handle, 0, 1920, 0));
        assert!(rustdesk_change_display_resolution(handle, 1, 1080, 1920));
        assert!(rustdesk_send_touch_pan(handle, 0, 100, 200));
        assert!(rustdesk_send_touch_scale(handle, 1250));
        assert!(rustdesk_send_touch_pan(handle, 1, -10, 12));
        assert!(rustdesk_send_touch_pan(handle, 2, 90, 212));
        assert!(!rustdesk_send_touch_pan(handle, 3, 0, 0));

        let controls = client.controls.take_batch(8);
        assert!(matches!(controls.as_slice(), [
            ControlMsg::ChangeDisplayResolution { display: 1, width: 1080, height: 1920 },
            ControlMsg::TouchPanStart { x: 100, y: 200 },
            ControlMsg::TouchScale { scale: 1250 },
            ControlMsg::TouchPanUpdate { x: -10, y: 12 },
            ControlMsg::TouchPanEnd { x: 90, y: 212 },
        ]));
    }

    #[test]
    fn physical_touchpad_wheel_ffi_enqueues_two_axes() {
        let mut client = test_client_with_display_state(RustDeskDisplayState::default());
        let handle = &mut client as *mut RustDeskClient as *mut c_void;

        assert!(!rustdesk_send_mouse_wheel_2d(handle, 0, 0));
        assert!(rustdesk_send_mouse_wheel_2d(handle, 6, -4));
        assert!(rustdesk_send_mouse_wheel_2d(handle, -2, 1));

        let controls = client.controls.take_batch(8);
        assert!(matches!(
            controls.as_slice(),
            [ControlMsg::MouseWheel2D { x: 4, y: -3 }]
        ));
    }

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
            None,
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
            key_mode: 1,
            token: std::ptr::null(),
            connection_id: 0,
            relay_fallback_port: DEFAULT_RELAY_PORT as c_int,
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
            None,
            Some(dummy_disconnect),
            std::ptr::null_mut(),
        );
        assert!(handle.is_null(), "无效地址应返回 null");
    }

    #[test]
    fn test_rustdesk_connect_rejects_encrypted_server_key_before_network() {
        let host = CString::new("127.0.0.1").unwrap();
        let key = CString::new("1:encrypted-value").unwrap();
        let username = CString::new("test").unwrap();
        let password = CString::new("").unwrap();
        let cfg = RustDeskConfig {
            host: host.as_ptr(),
            port: 21116,
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
            key_mode: 1,
            token: std::ptr::null(),
            connection_id: 0,
            relay_fallback_port: DEFAULT_RELAY_PORT as c_int,
        };

        extern "C" fn dummy_frame(_frame: *const FfiVideoFrame, _data: *mut c_void) {}
        extern "C" fn dummy_audio(_audio: *const FfiAudioData, _data: *mut c_void) {}
        extern "C" fn dummy_disconnect(
            _state: FfiConnectionState,
            _msg: *const c_char,
            _data: *mut c_void,
        ) {
        }

        let handle = rustdesk_connect(
            &cfg,
            Some(dummy_frame),
            Some(dummy_audio),
            None,
            Some(dummy_disconnect),
            std::ptr::null_mut(),
        );
        assert!(handle.is_null(), "encrypted key must not reach rendezvous");
    }

    /// 测试 disconnect(null) 不崩溃
    #[test]
    fn test_rustdesk_disconnect_null() {
        rustdesk_disconnect(std::ptr::null_mut());
        // 不崩溃即为通过
    }

    #[test]
    fn submit_2fa_rejects_invalid_codes_without_a_pending_session() {
        let code = CString::new("12ab").unwrap();
        assert!(!rustdesk_submit_2fa(code.as_ptr()));
        assert!(rustdesk_last_error(std::ptr::null_mut(), 0) > 0);
    }

    #[test]
    fn pending_2fa_submission_isolated_by_native_session_id() {
        let first_session = u64::MAX - 1001;
        let second_session = u64::MAX - 1002;
        let first_epoch = u64::MAX - 2001;
        let second_epoch = u64::MAX - 2002;
        let (first_sender, first_receiver) = std::sync::mpsc::channel();
        let (second_sender, second_receiver) = std::sync::mpsc::channel();
        register_pending_2fa(first_epoch, first_session, first_sender).unwrap();
        register_pending_2fa(second_epoch, second_session, second_sender).unwrap();

        let first_code = CString::new("123456").unwrap();
        assert!(rustdesk_submit_2fa_for_session(first_session, first_code.as_ptr()));
        assert_eq!(first_receiver.try_recv().unwrap(), "123456");
        assert!(second_receiver.try_recv().is_err());

        let second_code = CString::new("654321").unwrap();
        assert!(rustdesk_submit_2fa_for_session(second_session, second_code.as_ptr()));
        assert_eq!(second_receiver.try_recv().unwrap(), "654321");
        clear_pending_2fa(first_epoch, first_session);
        clear_pending_2fa(second_epoch, second_session);
    }

    #[test]
    fn structured_pipeline_errors_preserve_stage_and_sanitize_detail() {
        let message = structured_error("relay", "relay_request_failed", "a|b\nnext", 42);
        assert_eq!(
            message,
            "RDERR|stage=relay|code=relay_request_failed|attempt=42|detail=a/b next"
        );
        let relay = pipeline_error_message(
            &connector::ConnState::RequestingRelay,
            &io::Error::new(io::ErrorKind::PermissionDenied, "relay denied"),
            false,
            43,
        );
        assert!(relay.starts_with(
            "RDERR|stage=relay|code=relay_request_failed|attempt=43|detail="));
        let direct = pipeline_error_message(
            &connector::ConnState::ConnectingToPeer,
            &io::Error::new(io::ErrorKind::ConnectionRefused, "peer refused"),
            true,
            44,
        );
        assert!(direct.starts_with(
            "RDERR|stage=peer_channel|code=direct_peer_connect_failed|attempt=44|detail="));
        let login = pipeline_error_message(
            &connector::ConnState::RequestingRelay,
            &io::Error::new(
                io::ErrorKind::PermissionDenied,
                "Connection failed, please login! peer_id=sensitive"),
            false,
            45,
        );
        assert!(login.contains("code=control_plane_login_required"));
        assert!(login.contains("attempt=45"));
        assert!(!login.contains("sensitive"));
    }

    #[test]
    fn peer_2fa_code_accepts_supported_totp_lengths_only() {
        assert!(valid_peer_2fa_code("123456"));
        assert!(valid_peer_2fa_code("12345678"));
        assert!(!valid_peer_2fa_code("12345"));
        assert!(!valid_peer_2fa_code("1234567"));
        assert!(!valid_peer_2fa_code("12345x"));
    }

    #[test]
    fn test_rustdesk_version() {
        let version_ptr = rustdesk_version();
        assert!(!version_ptr.is_null());
        let version = unsafe { CStr::from_ptr(version_ptr) }.to_string_lossy();
        assert!(version.contains("crypto"), "版本应包含 'crypto'");
    }

    #[test]
    fn stream_stats_has_stable_c_abi_layout() {
        assert_eq!(std::mem::size_of::<RustDeskStreamStats>(), 96);
        assert_eq!(std::mem::align_of::<RustDeskStreamStats>(), 8);
        assert_eq!(std::mem::size_of::<RustDeskStreamStats>() % 8, 0);
        assert_eq!(RustDeskStreamStats::default().version, RUSTDESK_STREAM_STATS_VERSION);
        assert_eq!(RustDeskStreamStats::default().actual_codec, -1);
    }

    #[test]
    fn stream_stats_default_is_an_empty_disconnected_snapshot() {
        let stats = RustDeskStreamStats::default();
        assert_eq!(stats.state, FfiConnectionState::Disconnected as u32);
        assert_eq!(stats.video_messages, 0);
        assert_eq!(stats.video_frames, 0);
        assert_eq!(stats.encoded_bytes, 0);
        assert_eq!(stats.connection_path, 0);
    }

    #[test]
    fn explicit_best_quality_overrides_balanced_profile_without_changing_fps() {
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
            key_mode: 1,
            token: std::ptr::null(),
            connection_id: 0,
            relay_fallback_port: DEFAULT_RELAY_PORT as c_int,
        };

        let params = resolve_stream_params_for_config(&cfg);

        assert_eq!(params.preferred_codec, 4);
        assert_eq!(params.image_quality, 2);
        assert_eq!(params.effective_fps, 60);
        assert_eq!(params.req_width, 742);
        assert_eq!(params.req_height, 1600);
    }

    #[test]
    fn live_image_quality_control_validates_and_tracks_pending_generation() {
        let mut client = test_client_with_display_state(RustDeskDisplayState::default());
        let handle = &mut client as *mut RustDeskClient as *mut c_void;

        assert!(!rustdesk_set_image_quality(handle, -1));
        assert!(!rustdesk_set_image_quality(handle, 3));
        assert!(rustdesk_set_image_quality(handle, 2));

        let controls = client.controls.take_batch(8);
        assert!(matches!(controls.as_slice(), [
            ControlMsg::SetImageQuality { quality: 2, generation: 1 }
        ]));
        let mut snapshot = RustDeskQualityState::default();
        assert!(rustdesk_get_quality_state(handle, &mut snapshot));
        assert_eq!(snapshot.raw_quality, 2);
        assert_eq!(snapshot.effective_quality, 2);
        assert_eq!(snapshot.sent_quality, -1);
        assert_eq!(snapshot.requested_generation, 1);
        assert_eq!(snapshot.applied_generation, 0);
        assert_eq!(snapshot.update_status, 1);
    }

    #[test]
    fn vp9_uses_profile_60fps_without_an_implicit_cap() {
        let cfg = RustDeskConfig {
            host: std::ptr::null(),
            port: 21116,
            key: std::ptr::null(),
            username: std::ptr::null(),
            password: std::ptr::null(),
            width: 1600,
            height: 1040,
            codec: 2,
            image_quality: 1,
            privacy_mode: false,
            audio_enabled: true,
            profile: RustDeskProfile::Balanced,
            fps: 0,
            direct_connection: false,
            auth_mode: 0,
            key_mode: 1,
            token: std::ptr::null(),
            connection_id: 0,
            relay_fallback_port: DEFAULT_RELAY_PORT as c_int,
        };

        assert_eq!(resolve_stream_params_for_config(&cfg).effective_fps, 60);
    }
}
