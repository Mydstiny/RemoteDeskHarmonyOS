/**
 * vnc_rfb_protocol.cpp - pure RFB/UltraVNC wire-contract helpers.
 */
#include "vnc_rfb_protocol.h"

#include <algorithm>
#include <cstring>

namespace {

bool isPrintableTargetByte(uint8_t value) {
    return value >= 0x21 && value <= 0x7e;
}

} // namespace

namespace VncRfbProtocol {

uint8_t clientInitSharedFlag() {
    return 1;
}

int normalizeRfbMinor(int advertisedMinor) {
    if (advertisedMinor == 7) return 7;
    if (advertisedMinor == 8) return 8;
    return 3;
}

bool securityResultExpected(int negotiatedMinor, uint8_t selectedSecurityType) {
    if (selectedSecurityType != 1) return true;
    return negotiatedMinor == 8;
}

std::vector<uint8_t> buildFramebufferUpdateRequest(bool incremental,
                                                   uint16_t width,
                                                   uint16_t height) {
    return {
        3,
        static_cast<uint8_t>(incremental ? 1 : 0),
        0,
        0,
        0,
        0,
        static_cast<uint8_t>(width >> 8),
        static_cast<uint8_t>(width),
        static_cast<uint8_t>(height >> 8),
        static_cast<uint8_t>(height),
    };
}

int effectiveTrueColorDepth(const std::string& requestedDepth,
                            const std::string& qualityPreset,
                            uint64_t desktopPixels) {
    if (requestedDepth == "8") return 8;
    if (requestedDepth == "16") return 16;
    if (requestedDepth == "32") return 32;
    if (qualityPreset == "quality") return 32;
    if (qualityPreset == "speed" || desktopPixels > 4ULL * 1024ULL * 1024ULL) {
        return 16;
    }
    return 32;
}

std::vector<uint8_t> buildSetPixelFormat(int colorDepth) {
    if (colorDepth == 8) {
        return {
            0, 0, 0, 0,
            8, 8, 0, 1,
            0, 7, 0, 7, 0, 3,
            5, 2, 0,
            0, 0, 0,
        };
    }
    if (colorDepth == 16) {
        return {
            0, 0, 0, 0,
            16, 16, 0, 1,
            0, 31, 0, 63, 0, 31,
            11, 5, 0,
            0, 0, 0,
        };
    }
    return {
        0, 0, 0, 0,
        32, 24, 0, 1,
        0, 255, 0, 255, 0, 255,
        16, 8, 0,
        0, 0, 0,
    };
}

int normalizeFrameRateLimit(int frameRateLimit) {
    return frameRateLimit == 0 || frameRateLimit == 15 || frameRateLimit == 60 ?
        frameRateLimit : 30;
}

uint64_t framebufferRequestIntervalMs(int frameRateLimit) {
    const int normalized = normalizeFrameRateLimit(frameRateLimit);
    return normalized <= 0 ? 0 :
        static_cast<uint64_t>((1000 + normalized - 1) / normalized);
}

bool isUltraVncRepeaterBanner(const uint8_t* data, size_t size) {
    static constexpr char kBanner[] = "RFB 000.000\n";
    return data != nullptr && size == kProtocolVersionBytes &&
        std::memcmp(data, kBanner, kProtocolVersionBytes) == 0;
}

bool buildRepeaterTargetField(const std::string& target,
                              std::array<uint8_t, kUltraVncRepeaterFieldBytes>& field,
                              std::string& error) {
    field.fill(0);
    if (target.empty()) {
        error = "UltraVNC Repeater target ID is empty";
        return false;
    }
    const size_t prefixBytes = 3;
    if (target.size() > kUltraVncRepeaterFieldBytes - prefixBytes) {
        error = "UltraVNC Repeater target ID is too long";
        return false;
    }
    for (unsigned char value : target) {
        if (!isPrintableTargetByte(value)) {
            error = "UltraVNC Repeater target ID contains a non-printable character";
            return false;
        }
    }
    field[0] = 'I';
    field[1] = 'D';
    field[2] = ':';
    std::copy(target.begin(), target.end(), field.begin() + prefixBytes);
    return true;
}

bool parseRepeaterTargetField(const uint8_t* data, size_t size, std::string& target,
                              std::string& error) {
    target.clear();
    if (data == nullptr || size != kUltraVncRepeaterFieldBytes) {
        error = "UltraVNC Repeater display field must be exactly 250 bytes";
        return false;
    }
    size_t end = 0;
    while (end < size && data[end] != 0) {
        ++end;
    }
    for (size_t index = end; index < size; ++index) {
        if (data[index] != 0) {
            error = "UltraVNC Repeater display field has non-zero bytes after padding";
            return false;
        }
    }
    if (end < 3 || data[0] != 'I' || data[1] != 'D' || data[2] != ':') {
        error = "UltraVNC Repeater display field must start with ID:";
        return false;
    }
    if (end == 3) {
        error = "UltraVNC Repeater target ID is empty";
        return false;
    }
    for (size_t index = 3; index < end; ++index) {
        if (!isPrintableTargetByte(data[index])) {
            error = "UltraVNC Repeater target ID contains a non-printable character";
            return false;
        }
    }
    target.assign(reinterpret_cast<const char*>(data + 3), end - 3);
    return true;
}

} // namespace VncRfbProtocol
