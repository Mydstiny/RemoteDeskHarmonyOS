/**
 * vnc_adapter.h — VNC 协议适配器
 *
 * 基于 LibVNCServer/LibVNCClient 的 VNC 扩展协议适配器。
 * VNC 是最古老的远程桌面协议之一，广泛用于树莓派、嵌入式设备。
 *
 * 特性限制:
 *   - 不支持 HDR、触控笔压感、游戏手柄
 *   - 基础剪贴板同步
 *   - Tight/ZRLE/Raw 编码
 */

#ifndef VNC_ADAPTER_H
#define VNC_ADAPTER_H

#include "extensions/protocol_adapter.h"
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
    void        sendKey(uint32_t scancode, bool pressed) override;
    void        sendMouse(int x, int y, MouseButton button, bool pressed) override;
    void        sendMouseWheel(int x, int y, int delta) override;
    void        sendText(const std::string& text) override;
    bool        supportsCodec(CodecType codec) override;
    std::vector<CodecType> supportedCodecs() override;
    void        setVideoCallback(VideoFrameCallback callback) override;
    void        setAudioCallback(AudioDataCallback callback) override;
    void        setConnectionStateCallback(ConnectionStateCallback callback) override;
    bool        supportsNatTraversal() override;
    bool        supportsFileTransfer() override;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

void registerVncAdapter();

#endif // VNC_ADAPTER_H
