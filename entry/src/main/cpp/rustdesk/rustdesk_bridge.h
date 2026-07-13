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
#include <memory>

// C 兼容连接配置 (与 rustdesk_ffi/src/lib.rs 中的 RustDeskConfig 内存布局一致)
// 必须保持与 Rust #[repr(C)] 完全对应
struct RustDeskFfiConfig {
    const char* host;       // 远程主机 IP 或域名
    int         port;       // 端口号 (默认 21116)
    const char* key;        // Rendezvous 服务器公钥 (可选)
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
};

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
    void            requestFrameRefresh() override;
    void            reportVideoPressure(int level) override;

    // ---- 输入事件 ----
    void sendKey(uint32_t scancode, bool pressed) override;
    void sendMouse(int x, int y, MouseButton button, bool pressed) override;
    void sendMouseWheel(int x, int y, int delta) override;
    void sendText(const std::string& text) override;
    int  sendFileData(const std::string& remotePath, const uint8_t* data, uint32_t len) override;
    SessionTransferStatus getSessionTransferStatus() override;
    void sendClipboardData(const uint8_t* data, uint32_t len);
    std::string getClipboardText() override;
    bool isClipboardReceiveReady() override;

    // ---- 编码能力 ----
    bool supportsCodec(CodecType codec) override;
    std::vector<CodecType> supportedCodecs() override;

    // ---- 回调注册 ----
    void setVideoCallback(VideoFrameCallback callback) override;
    void setAudioCallback(AudioDataCallback callback) override;
    void setConnectionStateCallback(ConnectionStateCallback callback) override;

    // ---- 扩展功能 ----
    bool supportsNatTraversal() override;
    bool supportsFileTransfer() override;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
    RustDeskMode mode_;

#ifdef RUSTDESK_USE_REAL_CORE
    static void onFfiFrame(const void* frame, void* userData);
    static void onFfiAudio(const void* audio, void* userData);
    static void onFfiDisconnect(int state, const char* message, void* userData);
#endif

#ifdef RUSTDESK_EXPERIMENTAL
    int connectExperimental(const ConnectionConfig& cfg);
#endif
};

/** 在扩展系统中注册 RustDesk 适配器 (默认 IPC 模式) */
void registerRustDeskBridge();

#endif // RUSTDESK_BRIDGE_H
