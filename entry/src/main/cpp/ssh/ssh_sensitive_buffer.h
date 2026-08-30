#pragma once

#include <algorithm>
#include <cstddef>
#include <cstring>
#include <cstdlib>
#include <mutex>
#include <string>
#include <unordered_map>

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

inline void sshWipeSensitiveString(std::string& value) noexcept {
    if (!value.empty()) {
        sshSecureWipe(value.data(), value.size());
    }
}

template <typename StringContainer>
inline void sshWipeSensitiveStrings(StringContainer& values) noexcept {
    for (auto& value : values) {
        sshWipeSensitiveString(value);
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

/** Wipes every string payload before a collection releases its allocations. */
template <typename StringContainer>
class SshSensitiveStringCollectionGuard final {
public:
    explicit SshSensitiveStringCollectionGuard(
        StringContainer& values) noexcept : values_(values) {}
    ~SshSensitiveStringCollectionGuard() noexcept {
        sshWipeSensitiveStrings(values_);
    }

    SshSensitiveStringCollectionGuard(
        const SshSensitiveStringCollectionGuard&) = delete;
    SshSensitiveStringCollectionGuard& operator=(
        const SshSensitiveStringCollectionGuard&) = delete;

private:
    StringContainer& values_;
};

/**
 * Tracks allocations that can contain SSH authentication material. Production
 * libssh2 sessions register every allocator result, rather than only callback
 * response buffers, because libssh2 copies keyboard-interactive answers into
 * an internal SSH_MSG_USERAUTH_INFO_RESPONSE packet before transport send.
 * Pointer and length metadata are non-secret and shared across sessions.
 */
class SshSensitiveAllocationRegistry final {
public:
    bool track(void* pointer, std::size_t size) noexcept {
        if (pointer == nullptr || size == 0) { return false; }
        std::lock_guard<std::mutex> lock(mutex_);
        try {
            return allocations_.emplace(pointer, size).second;
        } catch (...) {
            return false;
        }
    }

    bool tracked(void* pointer) const noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        return allocations_.find(pointer) != allocations_.end();
    }

    bool sizeOf(void* pointer, std::size_t& size) const noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto allocation = allocations_.find(pointer);
        if (allocation == allocations_.end()) { return false; }
        size = allocation->second;
        return true;
    }

    bool wipeAndForget(void* pointer) noexcept {
        std::size_t size = 0;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            const auto allocation = allocations_.find(pointer);
            if (allocation == allocations_.end()) { return false; }
            size = allocation->second;
            allocations_.erase(allocation);
        }
        sshSecureWipe(pointer, size);
        return true;
    }

    std::size_t pendingCount() const noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        return allocations_.size();
    }

private:
    mutable std::mutex mutex_;
    std::unordered_map<void*, std::size_t> allocations_;
};

inline SshSensitiveAllocationRegistry& sshSensitiveAllocationRegistry() {
    static SshSensitiveAllocationRegistry registry;
    return registry;
}

inline void* sshAllocateTrackedSensitive(std::size_t size) noexcept {
    if (size == 0) { return nullptr; }
    void* allocation = std::malloc(size);
    if (allocation == nullptr) { return nullptr; }
    if (!sshSensitiveAllocationRegistry().track(allocation, size)) {
        sshSecureWipe(allocation, size);
        std::free(allocation);
        return nullptr;
    }
    return allocation;
}

inline void sshFreeTrackedSensitive(void* pointer) noexcept {
    if (pointer == nullptr) { return; }
    (void)sshSensitiveAllocationRegistry().wipeAndForget(pointer);
    std::free(pointer);
}

/** Reallocates without allowing the C allocator to release an un-wiped copy. */
inline void* sshReallocateTrackedSensitive(
    void* pointer, std::size_t size) noexcept {
    if (pointer == nullptr) {
        return sshAllocateTrackedSensitive(size);
    }
    if (size == 0) {
        sshFreeTrackedSensitive(pointer);
        return nullptr;
    }

    std::size_t previousSize = 0;
    if (!sshSensitiveAllocationRegistry().sizeOf(pointer, previousSize)) {
        // Production libssh2 allocations must all be registered. Preserve the
        // original pointer and fail closed if that ownership contract breaks.
        return nullptr;
    }
    void* replacement = sshAllocateTrackedSensitive(size);
    if (replacement == nullptr) { return nullptr; }
    std::memcpy(replacement, pointer, std::min(previousSize, size));
    sshFreeTrackedSensitive(pointer);
    return replacement;
}
