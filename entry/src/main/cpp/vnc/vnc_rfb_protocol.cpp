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
