/**
 * vnc_rfb_engine.h - isolated RFB client engine for VNC sessions.
 */
#ifndef VNC_RFB_ENGINE_H
#define VNC_RFB_ENGINE_H

#include "extensions/protocol_adapter.h"
#include "vnc_transport.h"

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

class VncRfbEngine {
public:
    using StateCallback = std::function<void(ConnectionState, const std::string&)>;

    VncRfbEngine(const ConnectionConfig& config, VideoFrameCallback frameCallback,
                 StateCallback stateCallback);
    ~VncRfbEngine();

    VncRfbEngine(const VncRfbEngine&) = delete;
    VncRfbEngine& operator=(const VncRfbEngine&) = delete;

    int start();
    void stop();
    ConnectionState state() const;
    void sendKey(uint32_t keyCode, bool pressed);
    void sendMouse(int x, int y, MouseButton button, bool pressed);
    void sendMouseWheel(int x, int y, int delta);
    void sendText(const std::string& text);
    void sendClipboard(const uint8_t* data, uint32_t len);
    std::string clipboardText() const;
    bool clipboardReady() const;
    void requestFrameRefresh();

private:
    struct PixelFormat {
        uint8_t bitsPerPixel = 32;
        uint8_t depth = 24;
        bool bigEndian = false;
        bool trueColor = true;
        uint16_t redMax = 255;
        uint16_t greenMax = 255;
        uint16_t blueMax = 255;
        uint8_t redShift = 16;
        uint8_t greenShift = 8;
        uint8_t blueShift = 0;
    };

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
    bool receiveFramebufferUpdate(std::string& error);
    bool receiveRawRectangle(int x, int y, int width, int height, std::string& error);
    bool receiveCopyRectangle(int x, int y, int width, int height, std::string& error);
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
    mutable std::mutex callbackMutex_;
    mutable std::mutex clipboardMutex_;
    std::string clipboardText_;
    std::atomic<bool> clipboardReady_ {false};
    std::atomic<ConnectionState> state_ {ConnectionState::DISCONNECTED};
    std::atomic<bool> stopRequested_ {false};
    std::thread worker_;
    VncTransport transport_;
    PixelFormat serverPixelFormat_;
    std::vector<uint8_t> framebuffer_;
    int framebufferWidth_ = 0;
    int framebufferHeight_ = 0;
    int buttonMask_ = 0;
    mutable std::mutex inputMutex_;
    bool negotiated33_ = false;
    int negotiatedMinor_ = 3;
    int ioTimeoutMs_ = 30000;
};

#endif // VNC_RFB_ENGINE_H
