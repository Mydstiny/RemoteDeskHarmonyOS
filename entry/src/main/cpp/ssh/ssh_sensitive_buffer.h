#pragma once

#include <cstddef>

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
