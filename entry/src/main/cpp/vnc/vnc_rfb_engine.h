/**
 * vnc_rfb_engine.h - isolated RFB client engine for VNC sessions.
 */
#ifndef VNC_RFB_ENGINE_H
#define VNC_RFB_ENGINE_H

#include "extensions/protocol_adapter.h"
#include "vnc_cursor_protocol.h"
#include "vnc_rfb_protocol.h"
#include "vnc_transport.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

class VncRfbEngine : public std::enable_shared_from_this<VncRfbEngine> {
public:
    using StateCallback = std::function<void(ConnectionState, const std::string&)>;
    using CursorCallback =
        std::function<void(const VncCursorProtocol::DecodedCursor&)>;

    VncRfbEngine(const ConnectionConfig& config, VideoFrameCallback frameCallback,
                 StateCallback stateCallback, CursorCallback cursorCallback);
    ~VncRfbEngine();

    VncRfbEngine(const VncRfbEngine&) = delete;
    VncRfbEngine& operator=(const VncRfbEngine&) = delete;

    int start();
    void stop();
    // Request stop and join only when the worker reaches its done fence.
    // Returns false on the bounded timeout; the caller must retain ownership
    // and hand the engine to deferStopAndJoin rather than destroying it.
    bool stopWithin(std::chrono::milliseconds timeout);
    void requestStop();
    void waitForWorkerDone();
    void joinAfterWorkerDone();
    bool workerDoneForDeferredJoin() const;
    bool isWorkerThread() const;
    static void deferStopAndJoin(std::unique_ptr<VncRfbEngine> engine);
    static void deferStopAndJoin(std::shared_ptr<VncRfbEngine> engine);
    // The reaper is an app-scope owner. Draining never extends its supplied
    // budget; shutdown additionally closes the owner after the worker done
    // fence is observed. A false result retains the queue for a later call.
    static bool drainDeferredJoinsWithin(std::chrono::milliseconds timeout);
    static bool shutdownDeferredJoinsWithin(std::chrono::milliseconds timeout);
    static std::size_t deferredJoinRemaining();
    ConnectionState state() const;
    void sendKey(uint32_t keyCode, bool pressed);
    void sendMouse(int x, int y, MouseButton button, bool pressed);
    void sendMouseWheel(int x, int y, int delta);
    void sendText(const std::string& text);
    void sendClipboard(const uint8_t* data, uint32_t len);
    std::string clipboardText() const;
    bool clipboardReady() const;
    void requestFrameRefresh();

#if defined(RDP_NATIVE_CALLBACK_TESTING)
    // Initializes only test fixture bytes, then invokes production emitFrame.
    bool invokeFrameCallbackForTesting(const VideoFrame& frame);
    int startWorkerForTesting(std::function<void()> callback);
    void setStopObserverForTesting(std::function<void()> observer);
    static uint32_t keySymForHarmonyCodeForTesting(uint32_t keyCode);
#endif

private:
    void run();
    bool handshake(std::string& error);
    bool negotiateVersion(std::string& error);
    bool negotiateSecurity(std::string& error);
    bool authenticateVncPassword(std::string& error);
    bool sendClientInit(std::string& error);
    bool initializeServer(std::string& error);
    bool sendPixelFormatAndEncodings(std::string& error);
    bool sendFramebufferUpdateRequest(bool incremental, std::string& error);
    bool receiveLoop(std::string& error);
    bool receiveFramebufferUpdate(bool& requestPipelined, std::string& error);
    bool receiveRawRectangle(int x, int y, int width, int height, std::string& error);
    bool receiveCopyRectangle(int x, int y, int width, int height, std::string& error);
    bool receiveZrleRectangle(int x, int y, int width, int height,
                              bool pipelineNextRequest, bool& requestPipelined,
                              std::string& error);
    bool receiveCursorRectangle(int hotX, int hotY, int width, int height,
                                std::string& error);
    bool receiveDesktopSize(int width, int height, std::string& error);
    bool receiveServerCutText(std::string& error);
    bool readReason(std::string& reason, std::string& error);
    bool readU8(uint8_t& value, int timeoutMs, std::string& error);
    bool readU16(uint16_t& value, int timeoutMs, std::string& error);
    bool readU32(uint32_t& value, int timeoutMs, std::string& error);
    bool readI32(int32_t& value, int timeoutMs, std::string& error);
    bool readBytes(uint8_t* data, size_t size, int timeoutMs, std::string& error);
    bool writeBytes(const uint8_t* data, size_t size, std::string& error);
    bool writeU16(uint16_t value, std::string& error);
    bool writeU32(uint32_t value, std::string& error);
    bool writeI32(int32_t value, std::string& error);
    void emitFrame(int dirtyX, int dirtyY, int dirtyWidth, int dirtyHeight);
    bool validRectangle(int x, int y, int width, int height) const;
    bool resizeFramebuffer(int width, int height, std::string& error);
    uint32_t decodePixel(const uint8_t* data) const;
    static uint32_t keySymForHarmonyCode(uint32_t keyCode);
    static uint8_t reverseBits(uint8_t value);
    static bool isTimeout(const std::string& error);
    void setState(ConnectionState state, const std::string& message);
    void clearSensitiveConfig();

    ConnectionConfig config_;
    VideoFrameCallback frameCallback_;
    StateCallback stateCallback_;
    CursorCallback cursorCallback_;
    mutable std::mutex callbackMutex_;
    mutable std::mutex clipboardMutex_;
    std::string clipboardText_;
    std::atomic<bool> clipboardReady_ {false};
    std::atomic<ConnectionState> state_ {ConnectionState::DISCONNECTED};
    std::atomic<bool> stopRequested_ {false};
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    std::function<void()> stopObserver_;
#endif
    mutable std::mutex workerStateMutex_;
    std::condition_variable workerStateCv_;
    bool workerDone_ = true;
    std::thread worker_;
    VncTransport transport_;
    VncRfbProtocol::PixelFormat serverPixelFormat_;
    VncRfbProtocol::ZrleInflater zrleInflater_;
    std::vector<uint8_t> zrleCompressedBuffer_;
    std::vector<uint8_t> zrleDecodedBuffer_;
    std::vector<uint8_t> framebuffer_;
    int framebufferWidth_ = 0;
    int framebufferHeight_ = 0;
    int effectiveColorDepth_ = 0;
    int buttonMask_ = 0;
    mutable std::mutex inputMutex_;
    mutable std::mutex writeMutex_;
    mutable std::mutex framebufferRequestMutex_;
    bool negotiated33_ = false;
    int negotiatedMinor_ = 3;
    int ioTimeoutMs_ = 30000;
    int idleTimeoutMs_ = 5000;
    uint64_t diagServerMessages_ = 0;
    uint64_t diagFramebufferUpdates_ = 0;
    uint64_t diagFrames_ = 0;
    uint64_t diagTimeouts_ = 0;
    int effectiveEncoding_ = VncRfbProtocol::kRawEncoding;
    std::atomic<uint64_t> lastFramebufferRequestAtMs_ {0};
};

#endif // VNC_RFB_ENGINE_H
