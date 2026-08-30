#pragma once

#include <cstddef>

/** Reserve the complete destination before its first sensitive append.
 *
 * A later container reallocation would release an older allocation before the
 * scope guard can wipe it. Callers therefore reserve every remaining byte
 * while the destination still contains only non-sensitive data.
 */
template <typename Container>
inline bool sshReserveSensitiveAppend(
    Container& value, std::size_t appendSize) {
    if (appendSize > value.max_size() - value.size()) { return false; }
    const std::size_t finalSize = value.size() + appendSize;
    value.reserve(finalSize);
    return value.capacity() >= finalSize;
}

inline void sshSecureWipe(void* memory, std::size_t size) noexcept {
    volatile unsigned char* bytes = static_cast<volatile unsigned char*>(memory);
    for (std::size_t index = 0; index < size; ++index) {
        bytes[index] = 0;
    }
}

/** Wipes the current payload on every scope exit without retaining a pointer
 * that container growth could invalidate. The container remains valid and
 * keeps its size so tests and callers can verify the entire payload was zeroed.
 */
template <typename Container>
class SshSensitiveBufferGuard final {
public:
    explicit SshSensitiveBufferGuard(Container& value) noexcept : value_(value) {}
    ~SshSensitiveBufferGuard() noexcept {
        if (!value_.empty()) {
            sshSecureWipe(value_.data(), value_.size());
        }
    }

    SshSensitiveBufferGuard(const SshSensitiveBufferGuard&) = delete;
    SshSensitiveBufferGuard& operator=(const SshSensitiveBufferGuard&) = delete;

private:
    Container& value_;
};
