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
#include "render/video_perf_counters.h"
#include "vnc_network_recovery_policy.h"
#include "vnc_rfb_engine.h"
#include <atomic>
#include <chrono>
#include <functional>
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
    void        onNetworkChanged(bool available,
                                 uint64_t networkGeneration) override;
    void        setSessionIdentity(uint64_t sessionId) override;
    void        setSessionOwner(const Render::DecoderSessionIdentity& owner);
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
#ifdef RDP_NATIVE_CALLBACK_TESTING
    // Calls the same production frame dispatch used by VncRfbEngine. This is
    // test-only and is not exposed through NAPI.
    void        InvokeVideoCallbackForTesting(const VideoFrame& frame);
    bool        InvokeEngineVideoCallbackForTesting(
        const VideoFrame& frame, const Render::DecoderSessionIdentity& capturedOwner);
    bool        InvokeLateFrameAfterCallbackStateInvalidationForTesting(
        const VideoFrame& frame, const Render::DecoderSessionIdentity& capturedOwner);
    bool        StartSelfStoppingEngineForTesting();
    void        SetEngineStartHookForTesting(std::function<int(VncRfbEngine&)> hook);
    void        SetBeforeNetworkRetirementWaitHookForTesting(
        std::function<void()> hook);
    void        SetAfterNetworkDetachHookForTesting(
        std::function<void()> hook);
    bool        WaitForNetworkRecoveryActiveForTesting(
        std::chrono::milliseconds timeout);
    bool        WaitForNetworkRecoveryIdleForTesting(
        std::chrono::milliseconds timeout);
    size_t      PendingNetworkRecoveryJobsForTesting();
    size_t      MaxPendingNetworkRecoveryJobsForTesting();
    size_t      PendingStateCallbacksForTesting();
    size_t      MaxPendingStateCallbacksForTesting();
    void        SetBeforeStateCarrierOperationLockHookForTesting(
        std::function<void()> hook);
    bool        WaitForStateCallbacksIdleForTesting(
        std::chrono::milliseconds timeout);
    bool        IsNetworkRecoveryWorkerThreadForTesting() const;
    bool        RetainsReconnectCredentialMaterialForTesting();
    void        InvokeProtocolCursorCallbackForTesting(
        const VncCursorProtocol::DecodedCursor& cursor);
    void        UpdatePredictedCursorPositionForTesting(int x, int y);
#endif
    void        sendClipboardData(const uint8_t* data, uint32_t len) override;
    void        requestFrameRefresh() override;
    std::string getClipboardText() override;
    bool        isClipboardReceiveReady() override;
    bool        supportsNatTraversal() override;
    bool        supportsFileTransfer() override;

private:
    struct StartingSlot;
    struct NetworkRecoveryJob;
    int connectInternal(const ConnectionConfig& cfg, uint64_t expectedToken,
                        uint64_t expectedNetworkGeneration);
    void disconnectInternal(bool publishDisconnected);
    std::shared_ptr<VncRfbEngine> detachEngineLocked(
        ConnectionStateCallback* callback,
        ConnectionState detachedState = ConnectionState::DISCONNECTED);
    std::shared_ptr<VncRfbEngine> detachStartingEngineLocked();
    bool acceptsStartingSlot(const std::shared_ptr<StartingSlot>& slot);
    bool enqueueNetworkRecovery(NetworkRecoveryJob& job);
    bool waitForNetworkRetirementWithin(std::chrono::milliseconds timeout);
    bool isNetworkRecoveryWorkerThread() const;
    bool retireEnginesBeforeReplacement(
        std::shared_ptr<VncRfbEngine>& engine,
        std::shared_ptr<VncRfbEngine>& startingEngine);
    void runNetworkRecoveryWorker();
    void stopNetworkRecoveryWorker();
    void publishNetworkStateIfCurrent(
        uint64_t token, ConnectionState state, const std::string& message,
        bool requireAvailable = false);
    void failNetworkRecoveryIfCurrent(uint64_t token,
                                      const std::string& message);
    void dispatchVideoFrame(const VideoFrame& frame,
                            const Render::DecoderSessionIdentity& capturedOwner);

    struct Impl;
    std::unique_ptr<Impl> impl_;
    // Monotonic lifecycle fence for the two-phase install/start transition.
    // VncRfbEngine::start() runs outside lifecycleMutex_; a disconnect or a
    // newer connect invalidates the local engine before it can be installed.
    std::mutex lifecycleMutex_;
    std::atomic<uint64_t> connectionSerial_ {0};
};

void registerVncAdapter();

#endif // VNC_ADAPTER_H
