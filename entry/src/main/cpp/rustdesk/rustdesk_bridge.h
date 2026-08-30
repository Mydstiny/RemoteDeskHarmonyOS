/**
 * rustdesk_bridge.h — RustDesk 协议适配器
 *
 * 双模式架构:
 *   RD_MODE_IPC (默认, 生产): Unix Domain Socket → rustdesk_helper 进程
 *     - AGPL 隔离: 主进程不链接 RustDesk core
 *     - 密码/密钥仅通过 IPC 加密通道传输
 *   RD_MODE_EXPERIMENTAL (RUSTDESK_EXPERIMENTAL 宏, 仅 dev):
 *     - 手写 TCP 握手骨架 (明文密码风险, 仅用于协议研究)
 *
 * RustDesk 采用 AGPL-3.0 许可证，推荐独立进程通信避免许可证传染。
 */

#ifndef RUSTDESK_BRIDGE_H
#define RUSTDESK_BRIDGE_H

#include "extensions/protocol_adapter.h"
#include "rustdesk_connection_continuity_executor.h"
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <vector>

/** Non-destructive RustDesk stream diagnostics returned to the NAPI layer. */
struct RustDeskDiagnosticsStats {
    bool supported = false;
    uint64_t sessionId = 0;
    int latencyMs = -1;
    int targetBitrateKbps = 0;
    uint64_t videoMessages = 0;
    uint64_t receivedFrames = 0;
    uint64_t keyframes = 0;
    uint64_t receivedBytes = 0;
    uint64_t audioFrames = 0;
    uint64_t cadenceGaps = 0;
    uint64_t maxCadenceGapMs = 0;
    uint64_t testDelayCount = 0;
    int codec = -1;
    int width = 0;
    int height = 0;
    int connectionPath = 0; // 0=rendezvous/relay, 1=direct
    int requestedImageQuality = -1;
    int effectiveImageQuality = -1;
    int sentImageQuality = -1;
    int qualityProfile = -1;
    int qualityFps = 0;
    uint64_t qualityRequestedGeneration = 0;
    uint64_t qualityAppliedGeneration = 0;
    int qualityUpdateStatus = 0;
    std::string peerPlatform = "unknown";
    bool remoteInputPermissionKnown = false;
    bool remoteInputAllowed = true;
    bool remoteClipboardPermissionKnown = false;
    bool remoteClipboardAllowed = true;
    bool remoteFilePermissionKnown = false;
    bool remoteFileAllowed = true;
    uint64_t lastFrameAtMs = 0;
    uint64_t presentedFrames = 0;
    uint64_t presentationWindowSamples = 0;
    int64_t renderP50Us = 0;
    int64_t renderP95Us = 0;
    int64_t renderMaxUs = 0;
};

struct RustDeskDisplayResolution {
    int width = 0;
    int height = 0;
};

struct RustDeskDisplayInfo {
    int display = 0;
    int x = 0;
    int y = 0;
    int width = 0;
    int height = 0;
    int originalWidth = 0;
    int originalHeight = 0;
    int scaleMilli = 1000;
    bool online = false;
    bool cursorEmbedded = false;
    std::string name;
    std::vector<RustDeskDisplayResolution> resolutions;
};

struct RustDeskDisplayCapabilities {
    bool supported = false;
    int currentDisplay = 0;
    uint64_t switchGeneration = 0;
    uint64_t readySwitchGeneration = 0;
    int pendingDisplay = -1;
    int confirmedDisplay = -1;
    bool inputBlocked = false;
    int width = 0;
    int height = 0;
    int originalWidth = 0;
    int originalHeight = 0;
    int scaleMilli = 1000;
    uint32_t geometryEpoch = 0;
    std::vector<RustDeskDisplayResolution> resolutions;
    std::vector<RustDeskDisplayInfo> displays;
};

struct RustDeskDisplaySwitchRequest {
    bool accepted = false;
    uint64_t generation = 0;
};

using RustDeskDisplayStateCallback = std::function<void(int display)>;

// C 兼容连接配置 (与 rustdesk_ffi/src/lib.rs 中的 RustDeskConfig 内存布局一致)
// 必须保持与 Rust #[repr(C)] 完全对应
struct RustDeskFfiConfig {
    const char* host;       // 远程主机 IP 或域名
    int         port;       // 端口号 (默认 21116)
    const char* key;        // Rendezvous 公钥或共享准入 Key (可选)
    const char* username;   // 用户名 / peer ID
    const char* password;   // 密码
    int         width;      // 期望宽度 (0=auto from profile)
    int         height;     // 期望高度 (0=auto from profile)
    int         codec;      // 0=auto, 1=VP8, 2=VP9, 3=AV1, 4=H264, 5=H265
    int         imageQuality; // 0=Low, 1=Balanced, 2=Best
    bool        privacyMode;
    bool        audioEnabled;
    // T-121: Must match RustDeskConfig layout
    int         profile;    // 0=Stable, 1=Balanced, 2=Performance, 3=Custom
    int         fps;        // 期望 FPS (0=from profile)
    bool        direct_connection; // 直连模式: false=rendezvous (默认), true=TCP直连peer
    int         auth_mode;  // 0=设备密码, 1=请求被控端点击批准
    int         key_mode;   // 0=legacy/auto, 1=server public key, 2=shared access key
    const char* token;      // transient Server Pro control-plane session token
    uint64_t    connection_id; // native session identity for pending Peer 2FA
    // Configured hbbr fallback port. A hbbs-provided relay_server:port wins.
    int         relay_fallback_port;
};

// Versioned route policy. The legacy 104-byte config remains the leading
// field so older ABI entry points and the presence probe stay unchanged.
struct RustDeskFfiConfigV6 {
    RustDeskFfiConfig legacy;
    int      connection_strategy; // 0=force relay, 1=direct IP, 2=AUTO
    uint32_t nat_traversal_flags;  // product remains zero until device acceptance
    int      nat_probe_serial;
    uint32_t reserved;
};

// Versioned release capability boundary returned by the Rust core. Compiled
// code paths are not automatically product capabilities: both sides must
// explicitly agree before any route/network work starts.
struct RustDeskFfiTransportCapabilitiesV1 {
    uint32_t abiVersion;
    uint32_t structSize;
    uint32_t connectionStrategyMask;
    uint32_t peerCandidateTransportMask;
    uint32_t natTraversalFlags;
    uint32_t reserved[3];
};

/** Result of a non-authenticating RustDesk peer presence probe. */
struct RustDeskPresenceResult {
    int state = 0;      // 0=unknown, 1=online, 2=offline
    int latencyMs = -1;
    int errorCode = 0;
};

static_assert(offsetof(RustDeskFfiConfig, relay_fallback_port) == 96,
              "RustDeskConfig ABI tail offset changed; update Rust and C++ together");
static_assert(sizeof(RustDeskFfiConfig) == 104,
              "RustDeskConfig ABI size changed; update Rust and C++ together");
static_assert(offsetof(RustDeskFfiConfigV6, legacy) == 0,
              "RustDeskConfigV6 must preserve the legacy leading layout");
static_assert(offsetof(RustDeskFfiConfigV6, connection_strategy) == 104,
              "RustDeskConfigV6 policy offset changed; update Rust and C++ together");
static_assert(sizeof(RustDeskFfiConfigV6) == 120,
              "RustDeskConfigV6 ABI size changed; update Rust and C++ together");
static_assert(sizeof(RustDeskFfiTransportCapabilitiesV1) == 32,
              "RustDesk transport capability ABI size changed");
static_assert(alignof(RustDeskFfiTransportCapabilitiesV1) == 4,
              "RustDesk transport capability ABI alignment changed");
static_assert(offsetof(RustDeskFfiTransportCapabilitiesV1, connectionStrategyMask) == 8,
              "RustDesk transport capability strategy offset changed");
static_assert(offsetof(RustDeskFfiTransportCapabilitiesV1, reserved) == 20,
              "RustDesk transport capability reserved offset changed");

enum class RustDeskMode {
    IPC = 0,           // IPC 转发 → rustdesk_helper
    EXPERIMENTAL = 1,  // 手写协议 (仅开发/研究)
    FFI = 2            // Rust FFI 直连 → librustdesk_ffi.a (真实 protobuf 协议)
};

/**
 * RustDeskBridge — RustDesk 协议适配器
 */
class RustDeskBridge : public ProtocolAdapter {
public:
    // The real-core lifetime helpers need the incomplete type while keeping
    // its storage private to the bridge.
    struct Impl;

    // Kept as a source-compatible boundary for the session registry. The
    // relay rollback does not implement transport continuity, but callers
    // must still be able to bind and validate the current session identity.
    using ContinuityGenerationCallback =
        std::function<bool(uint64_t sessionId, uint64_t generation, uint64_t ownerToken)>;

    explicit RustDeskBridge(RustDeskMode mode = RustDeskMode::IPC);
    ~RustDeskBridge() override;

    // ---- 协议元信息 ----
    std::string protocolName() override;
    int         defaultPort() override;
    std::string protocolVersion() override;

    // ---- 连接管理 ----
    int             connect(const ConnectionConfig& cfg) override;
    void            disconnect() override;
    ConnectionState getState() override;
    void            setSessionIdentity(uint64_t sessionId) override;
    void            setSessionOwnerToken(uint64_t ownerToken);
    void            setContinuityGenerationCallback(ContinuityGenerationCallback callback);
    void            onNetworkChanged(bool available, uint64_t networkGeneration) override;
    uint64_t        sessionGeneration() const;
    bool            submitTwoFactorCode(const std::string& code);
    RustDeskDiagnosticsStats getDiagnostics() const;
    RemoteCursorSnapshot getRemoteCursorSnapshot(bool includePixels) override;
    void            requestFrameRefresh() override;
    void            reportVideoPressure(int level) override;
    bool            setImageQuality(int quality);
    bool            reportVideoPressureForSession(uint64_t sessionId,
                                                  uint64_t generation,
                                                  uint64_t ownerToken,
                                                  int level);

    // ---- 输入事件 ----
    void sendKey(uint32_t scancode, bool pressed) override;
    bool sendKeyEvents(const std::vector<RemoteKeyEvent>& events) override;
    void sendMouse(int x, int y, MouseButton button, bool pressed) override;
    void sendMouseWheel(int x, int y, int delta) override;
    bool sendTouchpadWheel(int x, int y);
    void sendText(const std::string& text) override;
    void setDisplayStateCallback(RustDeskDisplayStateCallback callback);
    RustDeskDisplayCapabilities getDisplayCapabilities() const;
    RustDeskDisplaySwitchRequest beginDisplaySwitch(int display);
    bool switchDisplay(int display);
    bool captureDisplays(const std::vector<int>& displays);
    bool refreshVideoDisplay(int display);
    bool changeDisplayResolution(int display, int width, int height);
    bool sendTouchScale(int scale);
    bool sendTouchPan(int phase, int x, int y);
    int  sendFileData(const std::string& remotePath, const uint8_t* data, uint32_t len) override;
    SessionTransferStatus getSessionTransferStatus() override;
    void sendClipboardData(const uint8_t* data, uint32_t len) override;
    std::string getClipboardText() override;
    bool isClipboardReceiveReady() override;
    RustDeskContinuityQuiesceSnapshot continuityQuiesceSnapshot() const;

    // ---- 编码能力 ----
    bool supportsCodec(CodecType codec) override;
    std::vector<CodecType> supportedCodecs() override;

    // ---- 回调注册 ----
    void setVideoCallback(VideoFrameCallback callback) override;
    void setAudioCallback(AudioDataCallback callback) override;
    void setConnectionStateCallback(ConnectionStateCallback callback) override;

#ifdef RDP_NATIVE_CALLBACK_TESTING
    bool InvokeVideoCallbackForTesting(const uint8_t* data, size_t size,
                                       int width, int height, int codec,
                                       uint64_t timestamp, bool isKeyFrame,
                                       int display, uint64_t generation,
                                       uint64_t ownerToken);
    bool InvokeTransportCallbackForTesting(int state, const char* errorClass,
                                           uint64_t networkGeneration,
                                           bool userInitiated, uint64_t generation,
                                           uint64_t ownerToken);
    bool InvokeProgressCallbackForTesting(int stage, const char* message,
                                          uint64_t generation,
                                          uint64_t ownerToken);
    void SetAttemptDequeuedHookForTesting(std::function<void()> hook);
    void SetNetworkActionReadyHookForTesting(std::function<void(uint64_t)> hook);
    void SetFirstFrameClaimHookForTesting(std::function<void()> hook);
    void SetFfiStateCommitHookForTesting(std::function<void()> hook);
    void SetContinuityAttemptStageHookForTesting(std::function<void(int)> hook);
    void SetContinuityConnectResultHookForTesting(
        std::function<int(uint64_t, uint64_t)> hook);
    void SetDisplaySwitchFfiHookForTesting(
        std::function<bool(void*, int)> hook);
    void SetDisplayCapabilitiesFfiHookForTesting(
        std::function<bool(void*, RustDeskDisplayCapabilities&)> hook);
    void SetDisplayCapabilitiesBeforeSnapshotHookForTesting(
        std::function<void()> hook);
    void SetTwoFactorFfiHookForTesting(
        std::function<bool(uint64_t, const std::string&)> hook);
    bool AttachFfiOutboundHandleForTesting(void* handle);
    bool RetireFfiOutboundHandleForTesting(void* expectedHandle);
    void SetContinuityConfigForTesting(const ConnectionConfig& config);
    uint32_t continuityConnectCallCountForTesting() const;
    std::size_t continuityRemainingCountForTesting() const;
    bool continuityNetworkAvailableForTesting() const;
    void ArmFirstGenerationFrameForTesting();
    bool QueueDeferredCancelledSessionRetirementForTesting(uint64_t sessionId);
    void CompleteDeferredCancelledSessionRetirementForTesting();
    std::size_t pendingCancelledSessionRetirementsForTesting() const;
#endif

    // ---- 扩展功能 ----
    bool supportsNatTraversal() override;
    bool supportsFileTransfer() override;

private:
    std::shared_ptr<Impl> impl_;
    RustDeskMode mode_;

    std::optional<RustDeskConnectionContinuityExecutor::PreparedAttemptTicket>
        prepareContinuityAttempt(
            const RustDeskConnectionContinuityExecutor::AttemptTicket& source);
    bool startContinuityAttempt(
        const RustDeskConnectionContinuityExecutor::PreparedAttemptTicket& ticket);
    int connectInternal(
        const ConnectionConfig& cfg,
        const RustDeskConnectionContinuityExecutor::PreparedAttemptTicket* continuityTicket);
    void applyContinuityFastQuiesce(
        const RustDeskConnectionContinuityExecutor::ActionAdmission& admission = {});
    void onContinuityMaintenance(uint64_t nowMs);
    void disconnectImpl(bool cancelContinuity);

#ifdef RUSTDESK_USE_REAL_CORE
    static void onFfiFrame(const void* frame, void* userData);
    static void onFfiAudio(const void* audio, void* userData);
    static void onFfiCursor(const void* cursor, void* userData);
    static void onFfiDisplay(const void* snapshot, void* userData);
    static void onFfiAuth(int state, const char* message, void* userData);
    static void onFfiProgress(int stage, const char* message, void* userData);
    static bool onFfiPeerPlatform(const char* platform, void* userData);
    static void onFfiDisconnect(int state, const char* message, void* userData) noexcept;
#endif

#ifdef RUSTDESK_EXPERIMENTAL
    int connectExperimental(const ConnectionConfig& cfg);
#endif
};

/** 在扩展系统中注册 RustDesk 适配器 (默认 IPC 模式) */
void registerRustDeskBridge();

#endif // RUSTDESK_BRIDGE_H
