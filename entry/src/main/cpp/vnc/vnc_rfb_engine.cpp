/**
 * vnc_rfb_engine.cpp - bounded RFB 3.3/3.7/3.8 client implementation.
 *
 * Supported encodings are intentionally small and auditable: Raw, CopyRect,
 * DesktopSize and LastRect. Every rectangle and payload is checked before it
 * is allocated or copied. The engine never calls the shared video decoder.
 */
#include "vnc_rfb_engine.h"
#include "vnc_des.h"
#include "vnc_rfb_protocol.h"
#include "vnc_transport_policy.h"

#include "common/safe_log.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <limits>
#include <new>
#include <cstdlib>

namespace {

constexpr size_t kMaxReasonBytes = 64 * 1024;
constexpr size_t kMaxDesktopPixels = 16 * 1024 * 1024;
constexpr size_t kMaxRectanglePixels = 8 * 1024 * 1024;
constexpr size_t kMaxClipboardBytes = 1024 * 1024;
constexpr int kMaxFramebufferEdge = 8192;
constexpr int kMaxSecurityTypes = 64;
constexpr int kMaxEncodingTypes = 16;

uint64_t nowMs() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}

bool checkedPixelBytes(int width, int height, size_t bytesPerPixel, size_t& bytes) {
    if (width <= 0 || height <= 0 || bytesPerPixel == 0) return false;
    const size_t w = static_cast<size_t>(width);
    const size_t h = static_cast<size_t>(height);
    if (w > std::numeric_limits<size_t>::max() / h) return false;
    const size_t pixels = w * h;
    if (pixels > std::numeric_limits<size_t>::max() / bytesPerPixel) return false;
    bytes = pixels * bytesPerPixel;
    return true;
}

void appendU16(std::vector<uint8_t>& output, uint16_t value) {
    output.push_back(static_cast<uint8_t>((value >> 8) & 0xFF));
    output.push_back(static_cast<uint8_t>(value & 0xFF));
}

void appendU32(std::vector<uint8_t>& output, uint32_t value) {
    output.push_back(static_cast<uint8_t>((value >> 24) & 0xFF));
    output.push_back(static_cast<uint8_t>((value >> 16) & 0xFF));
    output.push_back(static_cast<uint8_t>((value >> 8) & 0xFF));
    output.push_back(static_cast<uint8_t>(value & 0xFF));
}

void appendI32(std::vector<uint8_t>& output, int32_t value) {
    appendU32(output, static_cast<uint32_t>(value));
}

void secureClear(std::string& value) {
    if (!value.empty()) {
        volatile char* data = value.data();
        for (size_t index = 0; index < value.size(); ++index) data[index] = '\0';
    }
    value.clear();
}

} // namespace

VncRfbEngine::VncRfbEngine(const ConnectionConfig& config, VideoFrameCallback frameCallback,
                           StateCallback stateCallback)
    : config_(config), frameCallback_(std::move(frameCallback)),
      stateCallback_(std::move(stateCallback)) {}

VncRfbEngine::~VncRfbEngine() {
    stop();
}

int VncRfbEngine::start() {
    if (worker_.joinable()) return -16;
    stopRequested_.store(false, std::memory_order_release);
    // Publish CONNECTING before creating the worker.  The ArkTS session
    // waiter polls getConnectionState immediately after NAPI connect returns;
    // exposing the default DISCONNECTED state during this scheduling window
    // makes it tear down a healthy VNC attempt before TCP can begin.
    state_.store(ConnectionState::CONNECTING, std::memory_order_release);
    try {
        worker_ = std::thread(&VncRfbEngine::run, this);
    } catch (const std::exception&) {
        clearSensitiveConfig();
        return -12;
    }
    return 0;
}

void VncRfbEngine::stop() {
    stopRequested_.store(true, std::memory_order_release);
    transport_.close();
    if (worker_.joinable() && worker_.get_id() != std::this_thread::get_id()) {
        worker_.join();
    }
    if (!worker_.joinable()) clearSensitiveConfig();
    setState(ConnectionState::DISCONNECTED, "VNC 已断开");
}

ConnectionState VncRfbEngine::state() const {
    return state_.load(std::memory_order_acquire);
}

void VncRfbEngine::run() {
    setState(ConnectionState::CONNECTING, "VNC 正在连接");
    std::string error;
    if (config_.vncSecurityPolicy.empty()) config_.vncSecurityPolicy = "secure_only";
    if (config_.vncSecurityPolicy == "secure_only" && !config_.vncTls) {
        setState(ConnectionState::ERROR, "VNC 安全策略要求 TLS");
        clearSensitiveConfig();
        return;
    }
    if (!vncNativeTransportIsAvailable(config_.vncTransport)) {
        setState(ConnectionState::ERROR, "VNC transport 尚未通过网关协议契约，Native 入口已拒绝");
        clearSensitiveConfig();
        return;
    }
    if (config_.vncFirstFrameTimeoutMs > 0) ioTimeoutMs_ = std::max(1000, config_.vncFirstFrameTimeoutMs);

    VncTransportConfig transportConfig;
    transportConfig.transport = config_.vncTransport;
    transportConfig.host = config_.host;
    transportConfig.port = config_.port;
    transportConfig.tls = config_.vncTls;
    transportConfig.connectTimeoutMs = config_.vncConnectTimeoutMs;
    transportConfig.websocketPath = config_.vncGatewayPath.empty() ? "/vnc" : config_.vncGatewayPath;
    transportConfig.repeaterMode = config_.vncRepeaterMode;
    transportConfig.repeaterTarget = config_.vncRepeaterTarget;
    transportConfig.expectedCertificateFingerprintSha256 =
        config_.vncExpectedCertificateFingerprintSha256;
    if (config_.vncTransport == "ultravnc_repeater") {
        if (!config_.vncGatewayHost.empty()) transportConfig.host = config_.vncGatewayHost;
        if (config_.vncGatewayPort > 0) transportConfig.port = config_.vncGatewayPort;
    }
    if (!transport_.connect(transportConfig, error)) {
        if (stopRequested_.load(std::memory_order_acquire)) {
            setState(ConnectionState::DISCONNECTED, "VNC 连接已取消");
        } else {
            setState(ConnectionState::ERROR, "VNC transport 连接失败: " + error);
        }
        clearSensitiveConfig();
        return;
    }
    if (!handshake(error)) {
        transport_.close();
        if (stopRequested_.load(std::memory_order_acquire)) {
            setState(ConnectionState::DISCONNECTED, "VNC 连接已取消");
        } else {
            setState(ConnectionState::ERROR, "VNC RFB 握手失败: " + error);
        }
        clearSensitiveConfig();
        return;
    }
    // The password is only needed for VNC authentication.  Do not retain it
    // for the lifetime of an otherwise long-lived framebuffer session.
    secureClear(config_.password);
    setState(ConnectionState::CONNECTED, "VNC 已连接");
    if (!sendFramebufferUpdateRequest(false, error)) {
        setState(ConnectionState::ERROR, "VNC 首帧请求失败: " + error);
        transport_.close();
        clearSensitiveConfig();
        return;
    }
    if (!receiveLoop(error) && !stopRequested_.load(std::memory_order_acquire)) {
        setState(ConnectionState::ERROR, "VNC 会话已结束: " + error);
    }
    transport_.close();
    if (stopRequested_.load(std::memory_order_acquire)) {
        setState(ConnectionState::DISCONNECTED, "VNC 连接已取消");
    } else if (state() != ConnectionState::ERROR) {
        setState(ConnectionState::DISCONNECTED, "VNC 服务器已断开");
    }
    clearSensitiveConfig();
}

bool VncRfbEngine::handshake(std::string& error) {
    return negotiateVersion(error) && negotiateSecurity(error) && sendClientInit(error) &&
        initializeServer(error) &&
        sendPixelFormatAndEncodings(error);
}

bool VncRfbEngine::negotiateVersion(std::string& error) {
    std::array<uint8_t, 12> serverVersion = {0};
    if (!readBytes(serverVersion.data(), serverVersion.size(), config_.vncAuthTimeoutMs, error)) {
        return false;
    }
    const std::string version(reinterpret_cast<const char*>(serverVersion.data()), serverVersion.size());
    if (version.compare(0, 4, "RFB ") != 0 || version.compare(4, 3, "003") != 0 ||
        version[7] != '.' || version[11] != '\n') {
        error = "server banner is not an RFB version";
        return false;
    }
    for (size_t index = 8; index < 11; ++index) {
        if (!std::isdigit(static_cast<unsigned char>(version[index]))) {
            error = "server RFB version is malformed";
            return false;
        }
    }
    int minor = 0;
    try {
        minor = std::stoi(version.substr(8, 3));
    } catch (...) {
        error = "server RFB version is malformed";
        return false;
    }
    if (minor < 3) {
        error = "RFB versions older than 3.3 are not supported";
        return false;
    }
    negotiatedMinor_ = VncRfbProtocol::normalizeRfbMinor(minor);
    negotiated33_ = negotiatedMinor_ == 3;
    char response[13] = {0};
    std::snprintf(response, sizeof(response), "RFB 003.%03d\n", negotiatedMinor_);
    return writeBytes(reinterpret_cast<const uint8_t*>(response), 12, error);
}

bool VncRfbEngine::negotiateSecurity(std::string& error) {
    std::vector<uint8_t> offered;
    if (negotiated33_) {
        uint32_t type = 0;
        if (!readU32(type, config_.vncAuthTimeoutMs, error)) return false;
        if (type == 0) {
            std::string reason;
            readReason(reason, error);
            error = reason.empty() ? "VNC server rejected the connection" : reason;
            return false;
        }
        if (type > 255) {
            error = "RFB 3.3 security type is outside the supported range";
            return false;
        }
        offered.push_back(static_cast<uint8_t>(type));
    } else {
        uint8_t count = 0;
        if (!readU8(count, config_.vncAuthTimeoutMs, error)) return false;
        if (count > kMaxSecurityTypes) {
            error = "VNC server offered too many security types";
            return false;
        }
        offered.resize(count);
        if (count > 0 && !readBytes(offered.data(), offered.size(), config_.vncAuthTimeoutMs, error)) return false;
        if (count == 0) {
            std::string reason;
            if (!readReason(reason, error)) return false;
            error = reason.empty() ? "VNC server offered no security type" : reason;
            return false;
        }
    }
    const bool allowNone = config_.vncTls || config_.vncSecurityPolicy != "secure_only";
    bool hasPassword = false;
    bool hasNone = false;
    for (uint8_t type : offered) {
        if (type == 2) hasPassword = true;
        if (type == 1) hasNone = true;
    }
    uint8_t selected = 0;
    if (hasPassword && !config_.password.empty()) selected = 2;
    else if (hasNone && allowNone) selected = 1;
    if (selected == 0) {
        error = hasPassword ? "VNC password is required or the security policy rejected None"
                            : "VNC server offered no supported security type";
        return false;
    }
    // RFB 3.3 sends exactly one 32-bit security type and has no client
    // security-selection write-back.  RFB 3.7/3.8 instead sends a one-byte
    // list count and requires the selected one-byte type.
    if (!negotiated33_ && !writeBytes(&selected, 1, error)) {
        return false;
    }
    if (selected == 2 && !authenticateVncPassword(error)) return false;
    if (!VncRfbProtocol::securityResultExpected(negotiatedMinor_, selected)) {
        return true;
    }
    uint32_t result = 0;
    if (!readU32(result, config_.vncAuthTimeoutMs, error)) return false;
    if (result != 0) {
        std::string reason;
        if (readReason(reason, error) && !reason.empty()) error = reason;
        else error = "VNC security authentication failed";
        return false;
    }
    return true;
}

bool VncRfbEngine::authenticateVncPassword(std::string& error) {
    std::array<uint8_t, 16> challenge = {0};
    if (!readBytes(challenge.data(), challenge.size(), config_.vncAuthTimeoutMs, error)) return false;
    uint8_t key[8] = {0};
    for (size_t index = 0; index < std::min<size_t>(8, config_.password.size()); ++index) {
        key[index] = reverseBits(static_cast<uint8_t>(config_.password[index]));
    }
    std::array<uint8_t, 16> response = {0};
    for (size_t offset = 0; offset < challenge.size(); offset += 8) {
        vncDesEncryptBlock(key, challenge.data() + offset, response.data() + offset);
    }
    return writeBytes(response.data(), response.size(), error);
}

bool VncRfbEngine::sendClientInit(std::string& error) {
    const uint8_t sharedFlag = VncRfbProtocol::clientInitSharedFlag();
    return writeBytes(&sharedFlag, sizeof(sharedFlag), error);
}

bool VncRfbEngine::initializeServer(std::string& error) {
    uint16_t width = 0;
    uint16_t height = 0;
    if (!readU16(width, config_.vncFirstFrameTimeoutMs, error) ||
        !readU16(height, config_.vncFirstFrameTimeoutMs, error)) return false;
    if (width == 0 || height == 0 || width > kMaxFramebufferEdge || height > kMaxFramebufferEdge) {
        error = "VNC desktop size is outside the safe limit";
        return false;
    }
    std::array<uint8_t, 16> pixelFormat = {0};
    if (!readBytes(pixelFormat.data(), pixelFormat.size(), config_.vncFirstFrameTimeoutMs, error)) return false;
    serverPixelFormat_.bitsPerPixel = pixelFormat[0];
    serverPixelFormat_.depth = pixelFormat[1];
    serverPixelFormat_.bigEndian = pixelFormat[2] != 0;
    serverPixelFormat_.trueColor = pixelFormat[3] != 0;
    serverPixelFormat_.redMax = static_cast<uint16_t>((pixelFormat[4] << 8) | pixelFormat[5]);
    serverPixelFormat_.greenMax = static_cast<uint16_t>((pixelFormat[6] << 8) | pixelFormat[7]);
    serverPixelFormat_.blueMax = static_cast<uint16_t>((pixelFormat[8] << 8) | pixelFormat[9]);
    serverPixelFormat_.redShift = pixelFormat[10];
    serverPixelFormat_.greenShift = pixelFormat[11];
    serverPixelFormat_.blueShift = pixelFormat[12];
    if (!serverPixelFormat_.trueColor ||
        (serverPixelFormat_.bitsPerPixel != 8 && serverPixelFormat_.bitsPerPixel != 16 &&
         serverPixelFormat_.bitsPerPixel != 32) ||
        serverPixelFormat_.redMax == 0 || serverPixelFormat_.greenMax == 0 ||
        serverPixelFormat_.blueMax == 0) {
        error = "VNC server pixel format is unsupported";
        return false;
    }
    uint32_t nameLength = 0;
    if (!readU32(nameLength, config_.vncFirstFrameTimeoutMs, error)) return false;
    if (nameLength > kMaxReasonBytes) {
        error = "VNC desktop name is too long";
        return false;
    }
    std::vector<uint8_t> name(nameLength);
    if (nameLength > 0 && !readBytes(name.data(), name.size(), config_.vncFirstFrameTimeoutMs, error)) return false;
    return resizeFramebuffer(width, height, error);
}

bool VncRfbEngine::sendPixelFormatAndEncodings(std::string& error) {
    // SetPixelFormat message type 0 has three padding bytes before the 16-byte format.
    std::vector<uint8_t> setFormat = {0, 0, 0, 0, 32, 24, 0, 1,
                                      0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0};
    if (!writeBytes(setFormat.data(), setFormat.size(), error)) return false;
    serverPixelFormat_.bitsPerPixel = 32;
    serverPixelFormat_.depth = 24;
    serverPixelFormat_.bigEndian = false;
    serverPixelFormat_.trueColor = true;
    serverPixelFormat_.redMax = 255;
    serverPixelFormat_.greenMax = 255;
    serverPixelFormat_.blueMax = 255;
    serverPixelFormat_.redShift = 16;
    serverPixelFormat_.greenShift = 8;
    serverPixelFormat_.blueShift = 0;

    std::vector<uint8_t> encodings;
    encodings.reserve(4 + kMaxEncodingTypes * 4);
    encodings.push_back(2);
    encodings.push_back(0);
    appendU16(encodings, 4);
    appendI32(encodings, 0);       // Raw
    appendI32(encodings, 1);       // CopyRect
    appendI32(encodings, -223);    // DesktopSize
    appendI32(encodings, -224);    // LastRect
    return writeBytes(encodings.data(), encodings.size(), error);
}

bool VncRfbEngine::sendFramebufferUpdateRequest(bool incremental, std::string& error) {
    const std::vector<uint8_t> request = VncRfbProtocol::buildFramebufferUpdateRequest(
        incremental,
        static_cast<uint16_t>(framebufferWidth_),
        static_cast<uint16_t>(framebufferHeight_));
    return writeBytes(request.data(), request.size(), error);
}

bool VncRfbEngine::receiveLoop(std::string& error) {
    bool firstMessage = true;
    while (!stopRequested_.load(std::memory_order_acquire)) {
        uint8_t type = 0;
        const int timeout = firstMessage ? config_.vncFirstFrameTimeoutMs : ioTimeoutMs_;
        if (!readU8(type, timeout, error)) {
            if (isTimeout(error)) {
                error.clear();
                if (!sendFramebufferUpdateRequest(true, error)) return false;
                continue;
            }
            return false;
        }
        firstMessage = false;
        if (type == 0) {
            if (!receiveFramebufferUpdate(error)) return false;
            if (!sendFramebufferUpdateRequest(true, error)) return false;
        } else if (type == 2) {
            // Bell: no payload.
        } else if (type == 3) {
            if (!receiveServerCutText(error)) return false;
        } else {
            error = "unsupported VNC server message type";
            return false;
        }
    }
    return true;
}

bool VncRfbEngine::receiveFramebufferUpdate(std::string& error) {
    uint8_t padding[1] = {0};
    uint16_t count = 0;
    if (!readBytes(padding, sizeof(padding), ioTimeoutMs_, error) ||
        !readU16(count, ioTimeoutMs_, error)) return false;
    if (count > 4096) {
        error = "VNC update contains too many rectangles";
        return false;
    }
    for (uint16_t index = 0; index < count; ++index) {
        uint16_t x = 0, y = 0, width = 0, height = 0;
        int32_t encoding = 0;
        if (!readU16(x, ioTimeoutMs_, error) || !readU16(y, ioTimeoutMs_, error) ||
            !readU16(width, ioTimeoutMs_, error) || !readU16(height, ioTimeoutMs_, error) ||
            !readI32(encoding, ioTimeoutMs_, error)) return false;
        if (encoding == 0) {
            if (!receiveRawRectangle(x, y, width, height, error)) return false;
        } else if (encoding == 1) {
            if (!receiveCopyRectangle(x, y, width, height, error)) return false;
        } else if (encoding == -223) {
            if (!receiveDesktopSize(width, height, error)) return false;
        } else if (encoding == -224) {
            break;
        } else {
            error = "VNC server selected an unsupported framebuffer encoding";
            return false;
        }
    }
    return true;
}

bool VncRfbEngine::receiveRawRectangle(int x, int y, int width, int height, std::string& error) {
    if (!validRectangle(x, y, width, height)) {
        error = "VNC Raw rectangle is outside the framebuffer";
        return false;
    }
    const size_t bytesPerPixel = serverPixelFormat_.bitsPerPixel / 8;
    size_t rawBytes = 0;
    size_t pixels = 0;
    if (!checkedPixelBytes(width, height, bytesPerPixel, rawBytes) ||
        !checkedPixelBytes(width, height, 1, pixels) || pixels > kMaxRectanglePixels) {
        error = "VNC Raw rectangle exceeds the safe limit";
        return false;
    }
    std::vector<uint8_t> raw(rawBytes);
    if (!readBytes(raw.data(), raw.size(), ioTimeoutMs_, error)) return false;
    for (int row = 0; row < height; ++row) {
        for (int column = 0; column < width; ++column) {
            const size_t source = (static_cast<size_t>(row) * width + column) * bytesPerPixel;
            const uint32_t pixel = decodePixel(raw.data() + source);
            const size_t destination = (static_cast<size_t>(y + row) * framebufferWidth_ + x + column) * 4;
            framebuffer_[destination] = static_cast<uint8_t>(pixel & 0xFF);
            framebuffer_[destination + 1] = static_cast<uint8_t>((pixel >> 8) & 0xFF);
            framebuffer_[destination + 2] = static_cast<uint8_t>((pixel >> 16) & 0xFF);
            framebuffer_[destination + 3] = 0xFF;
        }
    }
    emitFrame(x, y, width, height);
    return true;
}

bool VncRfbEngine::receiveCopyRectangle(int x, int y, int width, int height, std::string& error) {
    if (!validRectangle(x, y, width, height)) {
        error = "VNC CopyRect destination is outside the framebuffer";
        return false;
    }
    uint16_t sourceX = 0, sourceY = 0;
    if (!readU16(sourceX, ioTimeoutMs_, error) || !readU16(sourceY, ioTimeoutMs_, error) ||
        !validRectangle(sourceX, sourceY, width, height)) {
        error = "VNC CopyRect source is outside the framebuffer";
        return false;
    }
    size_t copyBytes = 0;
    if (!checkedPixelBytes(width, height, 4, copyBytes) || copyBytes > kMaxRectanglePixels * 4) {
        error = "VNC CopyRect exceeds the safe limit";
        return false;
    }
    std::vector<uint8_t> copy(copyBytes);
    for (int row = 0; row < height; ++row) {
        const size_t source = (static_cast<size_t>(sourceY + row) * framebufferWidth_ + sourceX) * 4;
        std::memcpy(copy.data() + static_cast<size_t>(row) * width * 4,
                    framebuffer_.data() + source, static_cast<size_t>(width) * 4);
    }
    for (int row = 0; row < height; ++row) {
        const size_t destination = (static_cast<size_t>(y + row) * framebufferWidth_ + x) * 4;
        std::memcpy(framebuffer_.data() + destination,
                    copy.data() + static_cast<size_t>(row) * width * 4,
                    static_cast<size_t>(width) * 4);
    }
    emitFrame(x, y, width, height);
    return true;
}

bool VncRfbEngine::receiveDesktopSize(int width, int height, std::string& error) {
    if (!resizeFramebuffer(width, height, error)) return false;
    emitFrame(-1, -1, width, height);
    return true;
}

bool VncRfbEngine::receiveServerCutText(std::string& error) {
    uint8_t padding[3] = {0};
    uint32_t length = 0;
    if (!readBytes(padding, sizeof(padding), ioTimeoutMs_, error) ||
        !readU32(length, ioTimeoutMs_, error)) return false;
    if (length > kMaxClipboardBytes) {
        error = "VNC clipboard payload exceeds the safe limit";
        return false;
    }
    std::string text(length, '\0');
    if (length > 0 && !readBytes(reinterpret_cast<uint8_t*>(text.data()), text.size(), ioTimeoutMs_, error)) {
        return false;
    }
    if (config_.vncClipboardEnabled) {
        std::lock_guard<std::mutex> lock(clipboardMutex_);
        clipboardText_ = std::move(text);
        clipboardReady_.store(true, std::memory_order_release);
    }
    return true;
}

bool VncRfbEngine::readReason(std::string& reason, std::string& error) {
    uint32_t length = 0;
    if (!readU32(length, config_.vncAuthTimeoutMs, error)) return false;
    if (length > kMaxReasonBytes) {
        error = "VNC failure reason is too long";
        return false;
    }
    reason.assign(length, '\0');
    if (length > 0 && !readBytes(reinterpret_cast<uint8_t*>(reason.data()), reason.size(),
                                  config_.vncAuthTimeoutMs, error)) return false;
    return true;
}

bool VncRfbEngine::readU8(uint8_t& value, int timeoutMs, std::string& error) {
    return readBytes(&value, 1, timeoutMs, error);
}

bool VncRfbEngine::readU16(uint16_t& value, int timeoutMs, std::string& error) {
    uint8_t bytes[2] = {0};
    if (!readBytes(bytes, sizeof(bytes), timeoutMs, error)) return false;
    value = static_cast<uint16_t>((bytes[0] << 8) | bytes[1]);
    return true;
}

bool VncRfbEngine::readU32(uint32_t& value, int timeoutMs, std::string& error) {
    uint8_t bytes[4] = {0};
    if (!readBytes(bytes, sizeof(bytes), timeoutMs, error)) return false;
    value = (static_cast<uint32_t>(bytes[0]) << 24) |
            (static_cast<uint32_t>(bytes[1]) << 16) |
            (static_cast<uint32_t>(bytes[2]) << 8) | bytes[3];
    return true;
}

bool VncRfbEngine::readI32(int32_t& value, int timeoutMs, std::string& error) {
    uint32_t raw = 0;
    if (!readU32(raw, timeoutMs, error)) return false;
    value = static_cast<int32_t>(raw);
    return true;
}

bool VncRfbEngine::readBytes(uint8_t* data, size_t size, int timeoutMs, std::string& error) {
    return transport_.readExact(data, size, timeoutMs, error);
}

bool VncRfbEngine::writeBytes(const uint8_t* data, size_t size, std::string& error) {
    return transport_.writeAll(data, size, error);
}

bool VncRfbEngine::writeU16(uint16_t value, std::string& error) {
    const uint8_t bytes[2] = {static_cast<uint8_t>(value >> 8), static_cast<uint8_t>(value)};
    return writeBytes(bytes, sizeof(bytes), error);
}

bool VncRfbEngine::writeU32(uint32_t value, std::string& error) {
    const uint8_t bytes[4] = {static_cast<uint8_t>(value >> 24), static_cast<uint8_t>(value >> 16),
                              static_cast<uint8_t>(value >> 8), static_cast<uint8_t>(value)};
    return writeBytes(bytes, sizeof(bytes), error);
}

bool VncRfbEngine::writeI32(int32_t value, std::string& error) {
    return writeU32(static_cast<uint32_t>(value), error);
}

void VncRfbEngine::emitFrame(int dirtyX, int dirtyY, int dirtyWidth, int dirtyHeight) {
    VideoFrameCallback callback;
    {
        std::lock_guard<std::mutex> lock(callbackMutex_);
        callback = frameCallback_;
    }
    if (!callback || framebuffer_.empty()) return;
    VideoFrame frame;
    frame.data = framebuffer_.data();
    frame.size = framebuffer_.size();
    frame.width = framebufferWidth_;
    frame.height = framebufferHeight_;
    frame.codec = CodecType::RAW_BGRA;
    frame.timestamp = nowMs();
    frame.isKeyFrame = dirtyX < 0;
    frame.display = 0;
    frame.stride = framebufferWidth_ * 4;
    frame.dirtyX = dirtyX;
    frame.dirtyY = dirtyY;
    frame.dirtyWidth = dirtyWidth;
    frame.dirtyHeight = dirtyHeight;
    callback(frame);
}

bool VncRfbEngine::validRectangle(int x, int y, int width, int height) const {
    if (x < 0 || y < 0 || width <= 0 || height <= 0) return false;
    if (x > framebufferWidth_ || y > framebufferHeight_) return false;
    return width <= framebufferWidth_ - x && height <= framebufferHeight_ - y;
}

bool VncRfbEngine::resizeFramebuffer(int width, int height, std::string& error) {
    size_t bytes = 0;
    if (width <= 0 || height <= 0 || width > kMaxFramebufferEdge || height > kMaxFramebufferEdge ||
        static_cast<size_t>(width) * static_cast<size_t>(height) > kMaxDesktopPixels ||
        !checkedPixelBytes(width, height, 4, bytes)) {
        error = "VNC DesktopSize exceeds the safe limit";
        return false;
    }
    try {
        framebuffer_.assign(bytes, 0);
    } catch (const std::bad_alloc&) {
        error = "VNC framebuffer allocation failed";
        return false;
    }
    framebufferWidth_ = width;
    framebufferHeight_ = height;
    return true;
}

uint32_t VncRfbEngine::decodePixel(const uint8_t* data) const {
    if (data == nullptr) return 0;
    const size_t bytes = serverPixelFormat_.bitsPerPixel / 8;
    uint32_t value = 0;
    if (serverPixelFormat_.bigEndian) {
        for (size_t index = 0; index < bytes; ++index) value = (value << 8) | data[index];
    } else {
        for (size_t index = 0; index < bytes; ++index) {
            value |= static_cast<uint32_t>(data[index]) << (index * 8);
        }
    }
    const uint32_t red = (value >> serverPixelFormat_.redShift) & serverPixelFormat_.redMax;
    const uint32_t green = (value >> serverPixelFormat_.greenShift) & serverPixelFormat_.greenMax;
    const uint32_t blue = (value >> serverPixelFormat_.blueShift) & serverPixelFormat_.blueMax;
    const uint32_t r = red * 255 / serverPixelFormat_.redMax;
    const uint32_t g = green * 255 / serverPixelFormat_.greenMax;
    const uint32_t b = blue * 255 / serverPixelFormat_.blueMax;
    return b | (g << 8) | (r << 16) | 0xFF000000;
}

void VncRfbEngine::sendKey(uint32_t keyCode, bool pressed) {
    if (config_.vncViewOnly || state() != ConnectionState::CONNECTED) return;
    const uint32_t keySym = keySymForHarmonyCode(keyCode);
    if (keySym == 0) return;
    const uint8_t packet[8] = {4, static_cast<uint8_t>(pressed ? 1 : 0), 0, 0,
                               static_cast<uint8_t>(keySym >> 24), static_cast<uint8_t>(keySym >> 16),
                               static_cast<uint8_t>(keySym >> 8), static_cast<uint8_t>(keySym)};
    std::string error;
    writeBytes(packet, sizeof(packet), error);
}

void VncRfbEngine::sendMouse(int x, int y, MouseButton button, bool pressed) {
    if (config_.vncViewOnly || state() != ConnectionState::CONNECTED) return;
    std::lock_guard<std::mutex> lock(inputMutex_);
    x = std::max(0, std::min(x, std::max(0, framebufferWidth_ - 1)));
    y = std::max(0, std::min(y, std::max(0, framebufferHeight_ - 1)));
    if (static_cast<int>(button) >= 0) {
        const int bit = static_cast<int>(button) == 0 ? 1 :
                        (static_cast<int>(button) == 1 ? 2 :
                         (static_cast<int>(button) == 2 ? 4 : 0));
        if (bit == 0) return;
        if (pressed) buttonMask_ |= bit;
        else buttonMask_ &= ~bit;
    }
    const uint8_t packet[6] = {5, static_cast<uint8_t>(buttonMask_),
                               static_cast<uint8_t>(x >> 8), static_cast<uint8_t>(x),
                               static_cast<uint8_t>(y >> 8), static_cast<uint8_t>(y)};
    std::string error;
    writeBytes(packet, sizeof(packet), error);
}

void VncRfbEngine::sendMouseWheel(int x, int y, int delta) {
    if (config_.vncViewOnly || state() != ConnectionState::CONNECTED || delta == 0) return;
    const int steps = std::min(32, std::max(1, std::abs(delta)));
    const int bit = delta > 0 ? 8 : 16;
    std::lock_guard<std::mutex> lock(inputMutex_);
    x = std::max(0, std::min(x, std::max(0, framebufferWidth_ - 1)));
    y = std::max(0, std::min(y, std::max(0, framebufferHeight_ - 1)));
    for (int index = 0; index < steps; ++index) {
        const uint8_t down[6] = {5, static_cast<uint8_t>(buttonMask_ | bit),
                                 static_cast<uint8_t>(x >> 8), static_cast<uint8_t>(x),
                                 static_cast<uint8_t>(y >> 8), static_cast<uint8_t>(y)};
        const uint8_t up[6] = {5, static_cast<uint8_t>(buttonMask_),
                               static_cast<uint8_t>(x >> 8), static_cast<uint8_t>(x),
                               static_cast<uint8_t>(y >> 8), static_cast<uint8_t>(y)};
        std::string error;
        if (!writeBytes(down, sizeof(down), error) || !writeBytes(up, sizeof(up), error)) return;
    }
}

void VncRfbEngine::sendText(const std::string& text) {
    if (config_.vncViewOnly || !config_.vncClipboardEnabled || state() != ConnectionState::CONNECTED ||
        text.size() > kMaxClipboardBytes) return;
    std::vector<uint8_t> packet;
    packet.reserve(8 + text.size());
    packet.push_back(6);
    packet.push_back(0);
    packet.push_back(0);
    packet.push_back(0);
    appendU32(packet, static_cast<uint32_t>(text.size()));
    packet.insert(packet.end(), text.begin(), text.end());
    std::string error;
    writeBytes(packet.data(), packet.size(), error);
}

void VncRfbEngine::sendClipboard(const uint8_t* data, uint32_t len) {
    if (data == nullptr || len == 0 || len > kMaxClipboardBytes ||
        config_.vncViewOnly || !config_.vncClipboardEnabled ||
        state() != ConnectionState::CONNECTED) return;
    std::vector<uint8_t> packet;
    packet.reserve(8 + len);
    packet.push_back(6); // ClientCutText
    packet.push_back(0);
    packet.push_back(0);
    packet.push_back(0);
    appendU32(packet, len);
    packet.insert(packet.end(), data, data + len);
    std::string error;
    writeBytes(packet.data(), packet.size(), error);
}

std::string VncRfbEngine::clipboardText() const {
    std::lock_guard<std::mutex> lock(clipboardMutex_);
    return clipboardText_;
}

bool VncRfbEngine::clipboardReady() const {
    return clipboardReady_.load(std::memory_order_acquire);
}

void VncRfbEngine::requestFrameRefresh() {
    if (state() != ConnectionState::CONNECTED) return;
    std::string error;
    sendFramebufferUpdateRequest(false, error);
}

uint32_t VncRfbEngine::keySymForHarmonyCode(uint32_t keyCode) {
    // HarmonyOS KeyCode values used by RemoteDesktop.ets. The mapper lives in
    // native VNC code so RDP scancodes and RustDesk private codes never leak
    // into the VNC protocol.
    if (keyCode >= 2000 && keyCode <= 2009) return '0' + (keyCode - 2000);
    if (keyCode >= 2017 && keyCode <= 2042) return 'a' + (keyCode - 2017);
    if (keyCode >= 2090 && keyCode <= 2101) return 0xFFBE + (keyCode - 2090);
    switch (keyCode) {
        case 2045: return 0xFFE9; // Alt left
        case 2046: return 0xFFEA; // Alt right
        case 2047: return 0xFFE1; // Shift left
        case 2048: return 0xFFE2; // Shift right
        case 2049: return 0xFF09;
        case 2050: return 0x20;
        case 2054: return 0xFF0D;
        case 2055: return 0xFF08;
        case 2067: return 0xFF67;
        case 2068: return 0xFF55;
        case 2069: return 0xFF56;
        case 2070: return 0xFF1B;
        case 2071: return 0xFFFF;
        case 2072: return 0xFFE3;
        case 2073: return 0xFFE4;
        case 2074: return 0xFFE5;
        case 2075: return 0xFF14;
        case 2076: return 0xFFEB;
        case 2077: return 0xFFEC;
        case 2081: return 0xFF50;
        case 2082: return 0xFF57;
        case 2083: return 0xFF63;
        case 2102: return 0xFF7F;
        case 2012: return 0xFF52;
        case 2013: return 0xFF54;
        case 2014: return 0xFF51;
        case 2015: return 0xFF53;
        case 2043: return ',';
        case 2044: return '.';
        case 2056: return '`';
        case 2057: return '-';
        case 2058: return '=';
        case 2059: return '[';
        case 2060: return ']';
        case 2061: return '\\';
        case 2062: return ';';
        case 2063: return '\'';
        case 2064: return '/';
        case 2065: return '@';
        case 2066: return '+';
        case 0x10039: return 0xFFE5;
        default: return keyCode <= 0x10FFFF ? keyCode : 0;
    }
}

uint8_t VncRfbEngine::reverseBits(uint8_t value) {
    value = static_cast<uint8_t>(((value & 0xF0) >> 4) | ((value & 0x0F) << 4));
    value = static_cast<uint8_t>(((value & 0xCC) >> 2) | ((value & 0x33) << 2));
    return static_cast<uint8_t>(((value & 0xAA) >> 1) | ((value & 0x55) << 1));
}

bool VncRfbEngine::isTimeout(const std::string& error) {
    return error.find("timed out") != std::string::npos;
}

void VncRfbEngine::setState(ConnectionState state, const std::string& message) {
    state_.store(state, std::memory_order_release);
    StateCallback callback;
    {
        std::lock_guard<std::mutex> lock(callbackMutex_);
        callback = stateCallback_;
    }
    if (callback) callback(state, message);
}

void VncRfbEngine::clearSensitiveConfig() {
    secureClear(config_.password);
    secureClear(config_.privateKeyPem);
    secureClear(config_.privateKeyPassphrase);
    secureClear(config_.vncExpectedCertificateFingerprintSha256);
}
