/**
 * vnc_adapter.h — VNC 协议适配器
 *
 * VNC/RFB 适配器。RFB 引擎、transport 和 raw framebuffer 均属于 VNC
 * namespace，不进入 RDP/RustDesk 的 decoder 或 settings。
 *
 * 当前支持：RFB 3.3/3.7/3.8、None/VNC password、bounded ZRLE、Raw、
 * CopyRect、Cursor、DesktopSize、UltraVNC pairing、TLS transport、键鼠和
 * 文本剪贴板。
 * WebSocket/generic relay code remains contract-gated and is not enabled by
 * the native entry point until a versioned server protocol is deployed.
 */

#ifndef VNC_ADAPTER_H
#define VNC_ADAPTER_H

#include "extensions/protocol_adapter.h"
#include "vnc_rfb_engine.h"
#include <mutex>
#include <memory>

class VncAdapter : public ProtocolAdapter {
public:
    VncAdapter();
    ~VncAdapter() override;

    std::string protocolName() override;
    int         defaultPort() override;
    std::string protocolVersion() override;
    int         connect(const ConnectionConfig& cfg) override;
    void        disconnect() override;
    ConnectionState getState() override;
    void        setSessionIdentity(uint64_t sessionId) override;
    RemoteCursorSnapshot getRemoteCursorSnapshot(bool includePixels) override;
    void        sendKey(uint32_t scancode, bool pressed) override;
    void        sendMouse(int x, int y, MouseButton button, bool pressed) override;
    void        sendMouseWheel(int x, int y, int delta) override;
    void        sendText(const std::string& text) override;
    bool        supportsCodec(CodecType codec) override;
    std::vector<CodecType> supportedCodecs() override;
    void        setVideoCallback(VideoFrameCallback callback) override;
    void        setAudioCallback(AudioDataCallback callback) override;
    void        setConnectionStateCallback(ConnectionStateCallback callback) override;
    void        sendClipboardData(const uint8_t* data, uint32_t len) override;
    void        requestFrameRefresh() override;
    std::string getClipboardText() override;
    bool        isClipboardReceiveReady() override;
    bool        supportsNatTraversal() override;
    bool        supportsFileTransfer() override;

private:
    void disconnectLocked();

    struct Impl;
    std::unique_ptr<Impl> impl_;
    // Serializes replacement/destruction of the engine with start().  The
    // engine is stored before start() so a concurrent disconnect can never
    // miss a just-created worker.
    std::mutex lifecycleMutex_;
};

void registerVncAdapter();

#endif // VNC_ADAPTER_H
