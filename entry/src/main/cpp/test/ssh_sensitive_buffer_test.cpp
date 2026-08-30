#include "ssh/ssh_sensitive_buffer.h"
#include "test_runner.h"

#include <algorithm>
#include <cstdint>
#include <string>
#include <vector>

namespace {

bool returnThroughStringGuard(std::string& value) {
    SshSensitiveBufferGuard<std::string> guard(value);
    return false;
}

bool returnThroughByteGuard(std::vector<std::uint8_t>& value) {
    SshSensitiveBufferGuard<std::vector<std::uint8_t>> guard(value);
    return false;
}

} // namespace

RDP_TEST_CASE(ssh_sensitive_string_guard_wipes_early_return_payload) {
    std::string value = "user:proxy-password";
    const std::size_t originalSize = value.size();
    RDP_ASSERT(!returnThroughStringGuard(value));
    RDP_ASSERT(value.size() == originalSize);
    RDP_ASSERT(std::all_of(value.begin(), value.end(), [](char byte) {
        return byte == '\0';
    }));
}

RDP_TEST_CASE(ssh_sensitive_byte_guard_wipes_early_return_payload) {
    std::vector<std::uint8_t> value {1, 4, 'u', 's', 'e', 'r', 8,
                                     'p', 'a', 's', 's', 'w', 'o', 'r', 'd'};
    const std::size_t originalSize = value.size();
    RDP_ASSERT(!returnThroughByteGuard(value));
    RDP_ASSERT(value.size() == originalSize);
    RDP_ASSERT(std::all_of(value.begin(), value.end(), [](std::uint8_t byte) {
        return byte == 0;
    }));
}
