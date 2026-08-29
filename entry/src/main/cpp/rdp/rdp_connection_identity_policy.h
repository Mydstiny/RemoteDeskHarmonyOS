#pragma once

#include <cstddef>
#include <string>

namespace RdpConnectionIdentityPolicy {

inline bool clientHostnameIsValid(const std::string& value) {
    if (value.empty()) { return true; }
    if (value.size() > 253) { return false; }
    std::size_t labelLength = 0;
    bool labelStartsWithHyphen = false;
    for (std::size_t index = 0; index < value.size(); ++index) {
        const unsigned char byte = static_cast<unsigned char>(value[index]);
        if (byte == '.') {
            if (labelLength == 0 || labelLength > 63 || labelStartsWithHyphen) { return false; }
            if (value[index - 1] == '-') { return false; }
            labelLength = 0;
            labelStartsWithHyphen = false;
            continue;
        }
        const bool asciiLetter = (byte >= 'A' && byte <= 'Z') ||
            (byte >= 'a' && byte <= 'z');
        if (!(asciiLetter || (byte >= '0' && byte <= '9') || byte == '-')) { return false; }
        if (labelLength == 0) { labelStartsWithHyphen = byte == '-'; }
        labelLength++;
    }
    return labelLength > 0 && labelLength <= 63 && !labelStartsWithHyphen && value.back() != '-';
}

} // namespace RdpConnectionIdentityPolicy
