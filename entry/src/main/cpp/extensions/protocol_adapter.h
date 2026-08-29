/**
 * protocol_adapter.h — 远程协议适配器接口
 *
 * 定义了与远程桌面协议交互的标准接口。
 * 添加新协议（VNC, SPICE 等）只需实现此接口并通过 ExtensionRegistry 注册。
 *
 * 协议对比：
 *   RDP (FreeRDP):  端口 3389, NLA 认证, GFX H.264/H.265
 *   RustDesk:        端口 21116, 密钥对+密码, VP8/VP9/H.264/H.265
 */

#ifndef PROTOCOL_ADAPTER_H
#define PROTOCOL_ADAPTER_H

#include <cstdint>
#include <functional>
#include <string>
#include <vector>
#include "input/remote_cursor_snapshot.h"
#include "transfer_runtime_status.h"
#include "rdp/rdp_gateway_policy.h"
#include "ssh/ssh_route_policy.h"

// ============================================================
// 枚举与常量
// ============================================================

/** 视频编码类型 */
enum class CodecType {
    AUTO = -1,
    H264 = 0,
    H265 = 1,
    VP8  = 2,
    VP9  = 3,
    AV1  = 4,
    /** VNC delivers a complete BGRA framebuffer, never an encoded video frame. */
    RAW_BGRA = 5
};

/** 鼠标按钮 */
enum class MouseButton {
    LEFT   = 0,
    MIDDLE = 1,
    RIGHT  = 2
};

struct RemoteKeyEvent {
    uint32_t keyCode = 0;
    bool pressed = false;
};

/** 连接状态 */
enum class ConnectionState {
    DISCONNECTED = 0,
    CONNECTING   = 1,
    CONNECTED    = 2,
    RECONNECTING = 3,
    ERROR        = 4,
    AUTHENTICATING = 5
};

/** RDP credential delegation mode. Keep this independent from SSH authMethod. */
enum class RdpAuthenticationMode {
    Password = 0,
    BlankPassword = 1,
    RestrictedAdmin = 2
};

/** Restricted Admin credential material is always a supplied NTLM hash. */
enum class RdpRestrictedAdminSecretSource {
    NtlmHash = 0
};

// ============================================================
// 数据结构
// ============================================================

/** 连接配置 — 建立远程连接所需的全部参数 */
struct ConnectionConfig {
    std::string host;            // 远程主机 IP 或域名
    int         port;            // 端口号 (RDP: 3389, RustDesk: 21116)
    std::string username;        // 登录用户名
    std::string password;        // 登录密码
    std::string domain;          // 域 (RDP NLA 认证用, 可选)
    int         width;           // 桌面宽度
    int         height;          // 桌面高度
    CodecType   codec;           // 首选视频编码
    std::string customHostname;  // 🆕 自定义主机名 (RDP /client-hostname:)
    std::string gatewayHost;     // 🆕 RDP 网关地址
    int         gatewayPort;     // 🆕 RDP 网关端口 (默认 443)
    // RDP route is explicit. An empty endpoint mode is a legacy handoff and
    // is resolved to Microsoft RD Gateway only when gatewayHost is present.
    std::string rdpEndpointMode;
    std::string rdpGatewayTransport;
    std::string rdpGatewayServerName;
    bool        multiMonitor;    // 🆕 多显示器模式
    int         monitorCount;    // 🆕 显示器数量
    int         colorDepth;      // 🆕 色深 (BPP)
    int         rdpDesktopScaleFactor = 100;
    int         rdpDeviceScaleFactor = 100;
    int         rdpDesktopPhysicalWidthMm = 0;
    int         rdpDesktopPhysicalHeightMm = 0;
    int         rdpDesktopOrientation = 0;
    int         rdpAuthIdentityMode; // RDP: 0=MicrosoftAccount\email, 1=domain+email, 2=bare email
    RdpAuthenticationMode rdpAuthMode; // RDP: password | blank_password | restricted_admin
    RdpRestrictedAdminSecretSource rdpRestrictedAdminSecretSource;
    std::string rdpRestrictedAdminHash; // RDP: transient NTLM hash, never persisted/logged
    std::string authMethod;       // 🆕 SSH 认证方式: "password" | "publickey" | "kbd-interactive"
    std::string privateKeyPem;    // 🆕 SSH 私钥 PEM (临时明文, 仅 publickey 认证)
    std::string privateKeyPassphrase; // 🆕 SSH 私钥口令 (可选)
    std::vector<std::string> sshKeyboardInteractiveResponses; // SSH keyboard-interactive/MFA responses
    std::string sshLocale;             // optional bounded LANG request for the target shell
    std::string sshProxyType;          // direct | http_connect | socks5 | frp_* | ssh_jump
    std::string sshProxyHost;          // proxy, FRP mapped, or jump endpoint
    int         sshProxyPort;
    std::string sshProxyUsername;      // optional proxy username
    std::string sshProxyPassword;      // transient proxy password
    // ProxyJump authentication is a separate SSH identity. Never fall back
    // to the target username, password, key, or keyboard-interactive answers.
    std::string sshProxyAuthMethod;     // password | publickey | kbd-interactive
    std::string sshProxyPrivateKeyPem;  // transient bastion key material
    std::string sshProxyPrivateKeyPassphrase;
    std::vector<std::string> sshProxyKeyboardInteractiveResponses;
    // The explicit route is durable metadata; hop secrets below are transient
    // handoff material and are cleared at every adapter/session teardown.
    SshRoute sshRoute;
    std::vector<SshJumpHopHandoff> sshJumpHopHandoffs;
    bool sshRouteExplicit = false;
    std::string expectedHostKeyRawBase64;       // 🆕 SSH 预期主机密钥 raw blob base64 (二次校验)
    std::string expectedHostKeyFingerprintSha256; // 🆕 SSH 预期主机指纹 SHA256
    // Opt-in only: let the SSH owner pause after KEX and ask ArkUI to persist
    // an unknown/changed key before any authentication material is sent.
    bool        sshHostKeyPromptEnabled;
    std::string sshTrustHostId;                 // durable RemoteHost/profile owner id
    // ProxyJump 的跳板机与目标机是两个独立的 SSH endpoint，必须分别绑定 key。
    std::string sshJumpHostKeyRawBase64;
    std::string sshJumpHostKeyFingerprintSha256;
    int         rdImageQuality;    // RustDesk: 0=速度, 1=平衡, 2=画质
    bool        rdDirectIp;        // RustDesk: 直连 IP 模式
    std::string rdConnectionStrategy; // force_relay | direct_ip | auto (auto currently fail-closed)
    int         rdDirectPort;      // RustDesk: 直连端口
    bool        rdLanDiscovery;    // RustDesk: LAN 发现
    bool        rdPrivacyMode;     // RustDesk: 隐私模式
    bool        rdAudioEnabled;     // RustDesk/RDP: 远端音频
    bool        rdClipboardEnabled; // RDP: 剪贴板重定向
    std::string rdDriveName;        // RDP: Windows 侧共享盘名称
    std::string rdDrivePath;        // RDP: 本地重定向盘路径
    std::string expectedRdpCertificateFingerprintSha256; // RDP: 用户已确认的服务器证书 SHA256
    std::string expectedRdpGatewayCertificateFingerprintSha256; // RDP Gateway: 独立证书 SHA256
    bool        rdpAllowUntrustedRoot; // RDP: 当前连接允许无法回溯根证书
    bool        rdpAllowHostMismatch;  // RDP: 当前连接允许证书名称不匹配
    bool        rdpCertificateAllowUnpinnedOnce; // RDP: 用户已明确允许本次未知证书
    bool        rdpAllowStandardSecurityOnce; // RDP: 用户已明确允许本次 Standard Security
    bool        rdpTlsWithoutNla; // RDP: explicit direct TLS compatibility mode; not a host field
    bool        rdpCertificateAllowTimeAnomalyOnce; // RDP: 用户已明确允许本次时间异常
    bool        rdpGatewayAllowUntrustedRoot;
    bool        rdpGatewayAllowHostMismatch;
    bool        rdpGatewayCertificateAllowUnpinnedOnce;
    bool        rdpGatewayCertificateAllowTimeAnomalyOnce;
    int         rdPasswordMode;    // RustDesk: 0=一次性, 1=永久
    int         rdAuthMode;        // RustDesk: 0=设备密码, 1=请求被控端点击批准
    int         rdPasswordLength;  // RustDesk: 临时密码长度
    std::string rdRelayId;         // RustDesk: 绑定中继 ID
    std::string rdAccountId;       // RustDesk: 绑定 API 账户 ID
    std::string rdServerKey;       // RustDesk: Rendezvous 公钥或共享准入 Key
    int         rdServerKeyMode;   // 0=legacy/auto, 1=server public key, 2=shared access key
    // Configured hbbr fallback port. It is used only when hbbs returns a
    // relay_server without an explicit port.
    int         rdRelayPort;
    // Transient Server Pro control-plane session token. Never persist or log.
    std::string rdAccessToken;

    // VNC-only transient connection fields. These values are assembled from
    // the isolated VNC data domain and are never persisted in RemoteHost.
    std::string vncTransport;       // direct_tcp | ultravnc_repeater | websocket_gateway | public_relay | ssh_tunnel
    std::string vncGatewayHost;
    int         vncGatewayPort;
    std::string vncServerName;      // VNC TLS SNI; resolved with the endpoint owner
    std::string vncGatewayPath;
    std::string vncRepeaterMode;    // mode2 | mode12
    std::string vncRepeaterTarget;
    bool        vncTls;
    bool        vncViewOnly;
    bool        vncClipboardEnabled;
    std::string vncSecurityPolicy;  // secure_only | trusted_network | allow_plaintext
    int         vncConnectTimeoutMs;
    int         vncAuthTimeoutMs;
    int         vncFirstFrameTimeoutMs;
    std::string vncImageQualityPreset; // speed | balanced | quality
    std::string vncPreferredEncoding;  // auto | zrle | raw; unsupported values fail back to auto
    std::string vncColorDepth;         // auto | 32 | 16 | 8
    int         vncFrameRateLimit;     // 0 | 15 | 30 | 60
    std::string vncExpectedCertificateFingerprintSha256;

    ConnectionConfig()
        : port(3389), width(1920), height(1080), codec(CodecType::H264),
          gatewayPort(443),
          // Empty is the legacy/unset value. The RDP route resolver owns the
          // migration: no gateway means direct RDP, while a legacy gateway
          // field becomes an explicit Microsoft RD Gateway route.
          rdpEndpointMode(), rdpGatewayTransport("auto"),
          multiMonitor(false), monitorCount(1),
          colorDepth(32), rdpAuthIdentityMode(0), rdpAuthMode(RdpAuthenticationMode::Password),
          rdpRestrictedAdminSecretSource(RdpRestrictedAdminSecretSource::NtlmHash), authMethod("password"),
          sshProxyPort(0), sshHostKeyPromptEnabled(false),
          rdImageQuality(1), rdDirectIp(false), rdConnectionStrategy(), rdDirectPort(21118),
          rdLanDiscovery(true), rdPrivacyMode(false), rdAudioEnabled(true), rdClipboardEnabled(true),
          rdDriveName("RemoteDesktop"), rdpAllowUntrustedRoot(false), rdpAllowHostMismatch(false),
          rdpCertificateAllowUnpinnedOnce(false), rdpAllowStandardSecurityOnce(false),
          rdpTlsWithoutNla(false),
          rdpCertificateAllowTimeAnomalyOnce(false),
          rdpGatewayAllowUntrustedRoot(false), rdpGatewayAllowHostMismatch(false),
          rdpGatewayCertificateAllowUnpinnedOnce(false),
          rdpGatewayCertificateAllowTimeAnomalyOnce(false),
          rdPasswordMode(0), rdAuthMode(0), rdPasswordLength(6), rdServerKeyMode(0),
          rdRelayPort(21117),
          vncTransport("direct_tcp"), vncGatewayPort(5901), vncGatewayPath("/vnc"),
          vncRepeaterMode("mode12"), vncTls(false), vncViewOnly(false),
          vncClipboardEnabled(false), vncSecurityPolicy("secure_only"),
          vncConnectTimeoutMs(10000), vncAuthTimeoutMs(15000),
          vncFirstFrameTimeoutMs(15000), vncImageQualityPreset("balanced"),
          vncPreferredEncoding("auto"), vncColorDepth("auto"),
          vncFrameRateLimit(30) {}
};

/** 视频帧数据 — 从协议后端传递到渲染管线 */
struct VideoFrame {
    const uint8_t* data;        // 编码后的帧数据
    size_t         size;        // 数据大小 (bytes)
    int            width;       // 帧宽度
    int            height;      // 帧高度
    CodecType      codec;       // 编码类型
    uint64_t       timestamp;   // 时间戳 (ms)
    bool           isKeyFrame;  // 是否为关键帧
    int            display;     // RustDesk 远端显示器编号; legacy/other protocols use 0
    int            stride;      // RAW_BGRA row stride; encoded frames use 0
    int            dirtyX;      // RAW_BGRA dirty rectangle; negative means full frame
    int            dirtyY;
    int            dirtyWidth;
    int            dirtyHeight;
    int            colorDepth;  // RAW_BGRA source's negotiated VNC color depth; otherwise 0
    int            sourceEncoding; // RFB encoding for RAW_BGRA; otherwise -1

    VideoFrame()
        : data(nullptr), size(0), width(0), height(0),
          codec(CodecType::H264), timestamp(0), isKeyFrame(false), display(0), stride(0),
          dirtyX(-1), dirtyY(-1), dirtyWidth(0), dirtyHeight(0), colorDepth(0),
          sourceEncoding(-1) {}
};

/** 音频数据块 — 从协议后端传递到音频管线 */
struct AudioData {
    const uint8_t* data;        // PCM 音频数据
    size_t         size;        // 数据大小 (bytes)
    int            sampleRate;  // 采样率 (Hz)
    int            channels;    // 声道数
    uint64_t       timestamp;   // 时间戳 (ms)

    AudioData()
        : data(nullptr), size(0), sampleRate(48000),
          channels(2), timestamp(0) {}
};

/** RDP 证书预检结果 */
struct RdpCertificateInfo {
    bool ok = false;
    std::string host;
    int port = 3389;
    std::string serverName;
    std::string commonName;
    std::string subject;
    std::string issuer;
    std::string fingerprintSha256;
    int64_t notBeforeMs = 0;
    int64_t notAfterMs = 0;
    int flags = 0;
    bool rootTrusted = false;
    bool hostMismatch = false;
    int errorCode = 0;
    std::string errorMessage;
    std::string preflightStatus = "unavailable";
    std::vector<std::string> riskFlags;
};

/** RDP 原生渲染统计, 用于 ArkTS 侧识别已连接但未出画面的异常 */
struct RdpRenderStats {
    int paintCount = 0;
    int renderedPaintCount = 0;
    int64_t firstPaintMs = 0;
    int64_t lastPaintMs = 0;
    // Ages are sampled from the native monotonic clock at query time. A
    // negative value means that this session has not produced the event yet.
    int64_t lastRemoteUpdateAgeMs = -1;
    int64_t eventLoopAgeMs = -1;
    int64_t eventLoopBlockMaxUs = 0;
    int64_t lastInputPostAgeMs = -1;
    uint64_t eventLoopTicks = 0;
    uint64_t networkCheckCount = 0;
    uint64_t networkCheckFailures = 0;
    uint64_t inputPostFailures = 0;
    int lastRenderResult = 0;
    int skippedPaintCount = 0;
    int slowRenderCount = 0;
    int64_t minRenderIntervalUs = 0;
    int64_t lastRenderCostUs = 0;
    uint64_t lastRenderBytes = 0;
    uint64_t pumpSubmitted = 0;
    uint64_t pumpRendered = 0;
    uint64_t pumpReplaced = 0;
    uint64_t pumpRejected = 0;
    uint64_t invalidEvents = 0;
    uint64_t invalidPixels = 0;
    uint64_t copiedBytes = 0;
    uint64_t presentationRejected = 0;
    uint64_t surfaceDetachedRejections = 0;
    uint64_t generationRejections = 0;
    uint64_t presentationWindowSamples = 0;
    int64_t callbackP50Us = 0;
    int64_t callbackP95Us = 0;
    int64_t callbackMaxUs = 0;
    int64_t copyP50Us = 0;
    int64_t copyP95Us = 0;
    int64_t copyMaxUs = 0;
    int64_t queueP50Us = 0;
    int64_t queueP95Us = 0;
    int64_t queueMaxUs = 0;
    int64_t uploadP50Us = 0;
    int64_t uploadP95Us = 0;
    int64_t uploadMaxUs = 0;
    int64_t drawP50Us = 0;
    int64_t drawP95Us = 0;
    int64_t drawMaxUs = 0;
    int64_t swapP50Us = 0;
    int64_t swapP95Us = 0;
    int64_t swapMaxUs = 0;
    int64_t workerP50Us = 0;
    int64_t workerP95Us = 0;
    int64_t workerMaxUs = 0;
    int glUploadGateDecision = 0;
    uint64_t glUploadEvaluatedSamples = 0;
    int64_t glUploadSwapP95Us = 0;
    int glUploadSharePermille = 0;
    int desktopWidth = 0;
    int desktopHeight = 0;
    uint64_t graphicsEpoch = 0;
    uint64_t desktopResizeCount = 0;
    uint64_t desktopResizeFailures = 0;
    bool gfxChannelConnected = false;
    bool displayControlReady = false;
    bool displayControlDisabled = false;
    int displayRequestedWidth = 0;
    int displayRequestedHeight = 0;
    int displayEffectiveWidth = 0;
    int displayEffectiveHeight = 0;
    int displayScaleFactor = 100;
    uint64_t displayRequestCount = 0;
    uint64_t displayFailureCount = 0;
    std::string displayLastResult;
    int inputQueueDepth = 0;
    int inputQueueMax = 0;
    int64_t inputTextUnits = 0;
    int64_t inputDroppedMouseMoves = 0;
    int64_t inputNonDisposableOverflow = 0;
    std::string graphicsMode;
};

struct RdpDisplayLayoutRequest {
    int width = 0;
    int height = 0;
    int physicalWidthMm = 0;
    int physicalHeightMm = 0;
    int orientation = 0;
    int desktopScaleFactor = 100;
    int deviceScaleFactor = 100;
};

struct RdpDisplayLayoutResult {
    bool accepted = false;
    std::string code;
    std::string message;
};

/** SFTP 远端文件条目 */
struct SftpFileEntry {
    std::string name;
    std::string path;
    bool isDirectory;
    bool isSymbolicLink;
    bool isSpecialFile;
    // -1 means the server did not provide a size. Keep this signed all the
    // way through N-API so an unavailable identity cannot become a valid
    // zero-byte file.
    int64_t size;
    int64_t mode;
    int64_t uid;
    int64_t gid;
    int64_t atime;
    // -1 means the server did not provide an mtime. Keep this signed all the
    // way through N-API so an unavailable identity cannot become UINT64_MAX.
    int64_t mtime;

    SftpFileEntry()
        : isDirectory(false), isSymbolicLink(false), isSpecialFile(false), size(-1),
          mode(-1), uid(-1), gid(-1), atime(-1), mtime(-1) {}
};

// ============================================================
// 回调类型
// ============================================================

/** 视频帧回调 — 当协议后端接收到新帧时调用 */
using VideoFrameCallback = std::function<void(const VideoFrame& frame)>;

/** 音频数据回调 — 当协议后端接收到新音频数据时调用 */
using AudioDataCallback = std::function<void(const AudioData& audio)>;

/** 连接状态变更回调 */
using ConnectionStateCallback = std::function<void(ConnectionState state,
                                                     const std::string& message)>;

// ============================================================
// ProtocolAdapter 接口
// ============================================================

/**
 * ProtocolAdapter — 远程桌面协议适配器接口
 *
 * 所有远程协议（RDP, RustDesk, VNC, SPICE...）必须实现此接口。
 * 通过 ExtensionSystem::instance().protocols 注册。
 */
class ProtocolAdapter {
public:
    virtual ~ProtocolAdapter() = default;

    // ---- 协议元信息 ----

    /** 协议名称 (如 "RDP", "RustDesk") */
    virtual std::string protocolName() = 0;

    /** 协议默认端口号 (如 3389, 21116) */
    virtual int defaultPort() = 0;

    /** 协议版本号 */
    virtual std::string protocolVersion() { return "1.0.0"; }

    // ---- 连接管理 ----

    /**
     * 建立远程连接
     * @param cfg  连接配置
     * @return 0=成功, 负数=错误码
     */
    virtual int connect(const ConnectionConfig& cfg) = 0;

    /** 断开连接 */
    virtual void disconnect() = 0;

    /** 获取当前连接状态 */
    virtual ConnectionState getState() = 0;

    /** Inject the loader-owned identity before starting a new connection. */
    virtual void setSessionIdentity(uint64_t /*sessionId*/) {}

    /** Return the latest protocol-native cursor state. */
    virtual RemoteCursorSnapshot getRemoteCursorSnapshot(bool /*includePixels*/) { return {}; }

    // ---- 输入事件 ----

    /**
     * 发送键盘事件
     * @param scancode  键盘扫描码
     * @param pressed   true=按下, false=释放
     */
    virtual void sendKey(uint32_t scancode, bool pressed) = 0;

    /**
     * Submit one logical keyboard transaction. Adapters with replaceable
     * transport handles override this to pin one native handle for every
     * event; other adapters inherit the ordered implementation.
     */
    virtual bool sendKeyEvents(const std::vector<RemoteKeyEvent>& events) {
        if (events.empty()) {
            return false;
        }
        for (const auto& event : events) {
            sendKey(event.keyCode, event.pressed);
        }
        return true;
    }

    /**
     * 发送鼠标事件
     * @param x        X 坐标
     * @param y        Y 坐标
     * @param button   鼠标按钮
     * @param pressed  true=按下, false=释放
     */
    virtual void sendMouse(int x, int y, MouseButton button, bool pressed) = 0;

    /**
     * 发送鼠标滚轮事件
     * @param delta  滚轮增量 (正=向上, 负=向下)
     */
    virtual void sendMouseWheel(int x, int y, int delta) = 0;

    /**
     * 发送文本 (剪贴板同步 / 文本粘贴)
     * @param text  UTF-8 编码文本
     */
    virtual void sendText(const std::string& text) = 0;

    // ---- 编码能力 ----

    /** 查询是否支持指定视频编码 */
    virtual bool supportsCodec(CodecType codec) = 0;

    /** 获取支持的编码列表 */
    virtual std::vector<CodecType> supportedCodecs() = 0;

    // ---- 回调注册 ----

    /** 设置视频帧回调 */
    virtual void setVideoCallback(VideoFrameCallback callback) = 0;

    /** 设置音频数据回调 */
    virtual void setAudioCallback(AudioDataCallback callback) = 0;

    /** 设置连接状态变更回调 */
    virtual void setConnectionStateCallback(ConnectionStateCallback callback) = 0;

    // ---- 扩展功能 ----

    /** 设置剪贴板文本（从本地同步到远程） */
    virtual void setClipboardText(const std::string& /*text*/) {}

    /** 设置本地文件剪贴板（稳定的应用沙箱绝对路径） */
    virtual bool setClipboardFiles(const std::vector<std::string>& /*paths*/) { return false; }

    /** 获取剪贴板文本（从远程同步到本地） */
    virtual std::string getClipboardText() { return ""; }
    virtual bool isClipboardReceiveReady() { return false; }

    /**
     * 在已建立会话中切换剪贴板处理。实现不得尝试动态创建协议通道；
     * 返回 false 表示当前协议/会话不支持该运行时切换。
     */
    virtual bool setSessionClipboardEnabled(bool /*enabled*/) { return false; }

    /** 是否支持 NAT 穿透 */
    virtual bool supportsNatTraversal() { return false; }

    /** 请求关键帧/画面刷新 (后台恢复前台时触发) */
    virtual void requestFrameRefresh() {}
    virtual void reportVideoPressure(int level) { (void)level; }

    /** RDP 证书预检。非 RDP 协议返回 ok=false。 */
    virtual RdpCertificateInfo probeRdpCertificate(const std::string& host, int port,
                                                   const std::string& serverName) {
        RdpCertificateInfo info;
        info.host = host;
        info.port = port;
        (void)serverName;
        info.errorCode = -1;
        info.errorMessage = "RDP certificate probing is not supported by this protocol";
        return info;
    }

    /**
     * Gateway-aware RDP certificate preflight. The legacy three-argument
     * method above is intentionally retained for direct-RDP compatibility;
     * callers with a gateway must use this route contract.
     */
    virtual RdpPreflightResult probeRdpCertificateRoute(const RdpPreflightRequest& request) {
        RdpPreflightResult result;
        result.endpointMode = request.route.endpointMode;
        result.routeIdentity = RdpGatewayPolicy::routeIdentity(request.route);
        result.stage = "endpoint";
        result.errorCode = "E-RDP-ENDPOINT";
        result.errorMessage = "RDP route certificate preflight is not supported by this protocol";
        return result;
    }

    /** RDP 渲染统计。非 RDP 协议返回全 0。 */
    virtual RdpRenderStats getRdpRenderStats() { return RdpRenderStats(); }

    // ---- R5: 文件传输 ----
    /** 是否支持文件传输 */
    virtual bool supportsFileTransfer() { return false; }

    /** 发送文件到远程 */
    virtual int sendFile(const std::string& /*localPath*/, const std::string& /*remotePath*/) { return -1; }

    /** 发送原始文件数据到远程 (由 ArkTS 侧读取文件后传入) */
    virtual int sendFileData(const std::string& /*remotePath*/, const uint8_t* /*data*/, uint32_t /*len*/) { return -1; }

    /** 写入远端文件分块。truncate=true 时从头重建文件, offset 为远端文件偏移。 */
    virtual int writeRemoteFileChunk(const std::string& /*remotePath*/, const uint8_t* /*data*/,
                                     uint32_t /*len*/, uint64_t /*offset*/, bool /*truncate*/) { return -1; }

    /** 列出远端目录 */
    virtual int listRemoteDir(const std::string& /*remotePath*/, std::vector<SftpFileEntry>& /*entries*/) { return -1; }

    /** 下载远端文件到内存 */
    virtual int readRemoteFile(const std::string& /*remotePath*/, std::vector<uint8_t>& /*out*/) { return -1; }

    /** 按偏移下载远端文件分块到内存 */
    virtual int readRemoteFileChunk(const std::string& /*remotePath*/, uint64_t /*offset*/,
                                    uint32_t /*maxLen*/, std::vector<uint8_t>& /*out*/) { return -1; }

    /** Per-session facts for transfers that require native confirmation. */
    virtual SessionTransferStatus getSessionTransferStatus() { return SessionTransferStatus(); }

    /** 删除远端文件 */
    virtual int removeRemoteFile(const std::string& /*remotePath*/) { return -1; }

    /** 删除远端空目录 */
    virtual int removeRemoteDir(const std::string& /*remotePath*/) { return -1; }

    /** 创建远端目录 */
    virtual int makeRemoteDir(const std::string& /*remotePath*/) { return -1; }

    /** 重命名/移动远端路径 */
    virtual int renameRemotePath(const std::string& /*oldPath*/, const std::string& /*newPath*/) { return -1; }

    /** 发送剪贴板内容到远程 */
    virtual void sendClipboardData(const uint8_t* /*data*/, uint32_t /*len*/) {}

    /** 接收文件请求回调 */
    using FileReceiveRequest = std::function<void(const std::string& filename, uint64_t size, bool accept)>;
    virtual void setFileReceiveCallback(FileReceiveRequest /*cb*/) {}

    /** 文件传输进度回调 */
    using FileProgressCallback = std::function<void(const std::string& filename, uint64_t transferred, uint64_t total)>;
    virtual void setFileProgressCallback(FileProgressCallback /*cb*/) {}
};

// ============================================================
// ToolbarExtension 接口 (前向声明所需)
// ============================================================

/**
 * ToolbarExtension — 工具栏扩展接口
 *
 * 用于在远程桌面工具栏中动态添加功能按钮。
 * 通过 ExtensionSystem::instance().toolbar 注册。
 */
class ToolbarExtension {
public:
    virtual ~ToolbarExtension() = default;

    /** 扩展名称 (如 "lock", "screenshot", "file_transfer") */
    virtual std::string extensionName() = 0;

    /** 扩展显示标题 */
    virtual std::string displayTitle() = 0;

    /** 扩展图标资源名称 */
    virtual std::string iconName() = 0;

    /** 点击时触发 */
    virtual void onAction() = 0;

    /** 是否在当前状态下可用 */
    virtual bool isEnabled() { return true; }
};

#endif // PROTOCOL_ADAPTER_H
