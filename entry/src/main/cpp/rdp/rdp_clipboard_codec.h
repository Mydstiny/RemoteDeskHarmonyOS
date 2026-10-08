#ifndef RDP_CLIPBOARD_CODEC_H
#define RDP_CLIPBOARD_CODEC_H

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace RdpClipboardCodec {
constexpr size_t kMaxUtf8Bytes = 65536;
constexpr size_t kMaxWireBytes = (kMaxUtf8Bytes + 1) * 2;

inline bool appendUtf8(uint32_t cp, std::string& out) {
    const size_t bytes = cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
    if (out.size() + bytes > kMaxUtf8Bytes) return false;
    if (bytes == 1) out.push_back(static_cast<char>(cp));
    else {
        if (bytes == 2) out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
        else if (bytes == 3) out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
        else out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
        if (bytes >= 4) out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
        if (bytes >= 3) out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    }
    return true;
}

// Reject malformed and over-budget payloads in their entirety. Never expose a
// truncated text value or replace an invalid surrogate with a different name.
inline bool decode(const uint8_t* data, size_t size, std::string& result) {
    if (!data || size < 2 || size > kMaxWireBytes || size % 2 != 0) return false;
    std::string text;
    for (size_t pos = 0; pos < size; pos += 2) {
        uint32_t cp = data[pos] | (uint32_t(data[pos + 1]) << 8);
        if (cp == 0) {
            // Only NUL padding may follow the terminator.
            for (size_t i = pos + 2; i < size; ++i) if (data[i] != 0) return false;
            result = std::move(text);
            return true;
        }
        if (cp >= 0xD800 && cp <= 0xDBFF) {
            if (pos + 3 >= size) return false;
            const uint32_t low = data[pos + 2] | (uint32_t(data[pos + 3]) << 8);
            if (low < 0xDC00 || low > 0xDFFF) return false;
            cp = 0x10000 + ((cp - 0xD800) << 10) + low - 0xDC00;
            pos += 2;
        } else if (cp >= 0xDC00 && cp <= 0xDFFF) return false;
        if (!appendUtf8(cp, text)) return false;
    }
    return false; // CF_UNICODETEXT requires a terminating UTF-16 NUL.
}

inline bool encode(const std::string& text, std::vector<uint8_t>& result) {
    if (text.size() > kMaxUtf8Bytes) return false;
    std::vector<uint8_t> bytes;
    auto word = [&bytes](uint32_t v) {
        bytes.push_back(static_cast<uint8_t>(v));
        bytes.push_back(static_cast<uint8_t>(v >> 8));
    };
    for (size_t i = 0; i < text.size();) {
        const uint8_t lead = static_cast<uint8_t>(text[i++]);
        uint32_t cp = lead;
        size_t count = 0;
        uint32_t minimum = 0;
        if (lead >= 0xC2 && lead <= 0xDF) { cp = lead & 0x1F; count = 1; minimum = 0x80; }
        else if (lead >= 0xE0 && lead <= 0xEF) { cp = lead & 0x0F; count = 2; minimum = 0x800; }
        else if (lead >= 0xF0 && lead <= 0xF4) { cp = lead & 0x07; count = 3; minimum = 0x10000; }
        else if (lead >= 0x80) return false;
        if (i + count > text.size()) return false;
        for (size_t j = 0; j < count; ++j) {
            const uint8_t next = static_cast<uint8_t>(text[i++]);
            if ((next & 0xC0) != 0x80) return false;
            cp = (cp << 6) | (next & 0x3F);
        }
        if (cp < minimum || cp == 0 || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return false;
        if (cp < 0x10000) word(cp);
        else { cp -= 0x10000; word(0xD800 | (cp >> 10)); word(0xDC00 | (cp & 0x3FF)); }
    }
    word(0);
    result = std::move(bytes);
    return true;
}
}
#endif
