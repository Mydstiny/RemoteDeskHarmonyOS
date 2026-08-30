#pragma once

#include "ssh_sensitive_buffer.h"

#include <libssh2.h>

/**
 * libssh2 copies keyboard-interactive answers into internal transport packets.
 * Track every session allocation so callback buffers, packet copies and any
 * realloc predecessor are wiped before their storage is released.
 */
inline void* sshLibssh2TrackedAlloc(std::size_t size, void**) noexcept {
    return sshAllocateTrackedSensitive(size);
}

inline void sshLibssh2TrackedFree(void* pointer, void**) noexcept {
    sshFreeTrackedSensitive(pointer);
}

inline void* sshLibssh2TrackedRealloc(
    void* pointer, std::size_t size, void**) noexcept {
    return sshReallocateTrackedSensitive(pointer, size);
}

inline LIBSSH2_SESSION* sshCreateTrackedLibssh2Session() noexcept {
    return libssh2_session_init_ex(
        &sshLibssh2TrackedAlloc,
        &sshLibssh2TrackedFree,
        &sshLibssh2TrackedRealloc,
        nullptr);
}
