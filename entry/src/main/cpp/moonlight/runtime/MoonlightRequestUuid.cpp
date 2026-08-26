#include "moonlight/runtime/MoonlightRequestUuid.h"

#include <openssl/crypto.h>
#include <openssl/rand.h>

#include <cstddef>

namespace remotedesk::moonlight {
namespace {

constexpr char kHex[] = "0123456789abcdef";

} // namespace

bool formatMoonlightRequestUuidV4(
    const std::array<std::uint8_t, 16U>& entropy,
    std::string& output) noexcept {
    std::array<std::uint8_t, 16U> bytes = entropy;
    bytes[6] = static_cast<std::uint8_t>((bytes[6] & 0x0fU) | 0x40U);
    bytes[8] = static_cast<std::uint8_t>((bytes[8] & 0x3fU) | 0x80U);
    std::array<char, 36U> text {};
    std::size_t cursor = 0U;
    for (std::size_t index = 0U; index < bytes.size(); ++index) {
        if (index == 4U || index == 6U || index == 8U || index == 10U) {
            text[cursor++] = '-';
        }
        text[cursor++] = kHex[(bytes[index] >> 4U) & 0x0fU];
        text[cursor++] = kHex[bytes[index] & 0x0fU];
    }
    bool assigned = false;
    try {
        output.assign(text.data(), text.size());
        assigned = true;
    } catch (...) {
        output.clear();
    }
    OPENSSL_cleanse(bytes.data(), bytes.size());
    OPENSSL_cleanse(text.data(), text.size());
    return assigned;
}

std::string generateMoonlightRequestUuid() noexcept {
    std::array<std::uint8_t, 16U> entropy {};
    std::string result;
    if (RAND_bytes(entropy.data(), static_cast<int>(entropy.size())) == 1) {
        (void)formatMoonlightRequestUuidV4(entropy, result);
    }
    OPENSSL_cleanse(entropy.data(), entropy.size());
    return result;
}

} // namespace remotedesk::moonlight
