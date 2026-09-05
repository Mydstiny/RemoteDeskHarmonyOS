#pragma once

#include "ssh_sensitive_buffer.h"

#include <libssh2.h>

#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstring>
#include <mutex>
#include <new>
#include <unordered_map>

inline std::atomic<std::size_t>& sshTrackedLibssh2ContextCountStorage() noexcept {
    static std::atomic<std::size_t> count {0};
    return count;
}

inline std::size_t sshTrackedLibssh2ContextCount() noexcept {
    return sshTrackedLibssh2ContextCountStorage().load(
        std::memory_order_acquire);
}

/**
 * Owns the allocations made by one libssh2 session.
 *
 * libssh2 1.11.1 can leave key-exchange scratch allocations behind when an
 * EAGAIN path completes. Its allocator API has no session argument, so the
 * stable abstract pointer carries this owner for the complete session
 * lifetime. Once libssh2_session_free() succeeds, any allocation still owned
 * here is unreachable by libssh2 and can be wiped and released safely.
 */
class SshLibssh2AllocationContext final {
public:
    SshLibssh2AllocationContext() noexcept {
        sshTrackedLibssh2ContextCountStorage().fetch_add(
            1, std::memory_order_acq_rel);
    }
    ~SshLibssh2AllocationContext() noexcept {
        releaseOrphans();
        sshTrackedLibssh2ContextCountStorage().fetch_sub(
            1, std::memory_order_acq_rel);
    }

    SshLibssh2AllocationContext(const SshLibssh2AllocationContext&) = delete;
    SshLibssh2AllocationContext& operator=(
        const SshLibssh2AllocationContext&) = delete;

    void* allocate(std::size_t size) noexcept {
        void* allocation = sshAllocateTrackedSensitive(size);
        if (allocation == nullptr) { return nullptr; }
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!allocations_.emplace(allocation, size).second) {
                (void)sshFreeTrackedSensitive(allocation);
                return nullptr;
            }
        } catch (...) {
            (void)sshFreeTrackedSensitive(allocation);
            return nullptr;
        }
        return allocation;
    }

    bool release(void* pointer) noexcept {
        if (pointer == nullptr) { return false; }
        bool owned = false;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            owned = allocations_.erase(pointer) == 1;
        }
        if (!owned) {
            // The per-session map is the ownership authority. An unknown or
            // duplicate callback cannot release another session's pointer.
            return false;
        }
        return sshFreeTrackedSensitive(pointer);
    }

    void* reallocate(void* pointer, std::size_t size) noexcept {
        if (pointer == nullptr) { return allocate(size); }
        if (size == 0) {
            (void)release(pointer);
            return nullptr;
        }
        std::size_t previousSize = 0;
        void* replacement = nullptr;
        {
            // Keep ownership stable while copying; allocator callbacks for a
            // single libssh2 session are serialized by its owning operation.
            std::lock_guard<std::mutex> lock(mutex_);
            const auto allocation = allocations_.find(pointer);
            if (allocation == allocations_.end()) { return nullptr; }
            previousSize = allocation->second;
            replacement = sshAllocateTrackedSensitive(size);
            if (replacement == nullptr) { return nullptr; }
            try {
                if (!allocations_.emplace(replacement, size).second) {
                    (void)sshFreeTrackedSensitive(replacement);
                    return nullptr;
                }
            } catch (...) {
                (void)sshFreeTrackedSensitive(replacement);
                return nullptr;
            }
            std::memcpy(replacement, pointer, std::min(previousSize, size));
            allocations_.erase(pointer);
        }
        (void)sshFreeTrackedSensitive(pointer);
        return replacement;
    }

    void setApplicationContext(void* context) noexcept {
        applicationContext_.store(context, std::memory_order_release);
    }

    void* exchangeApplicationContext(void* context) noexcept {
        return applicationContext_.exchange(context, std::memory_order_acq_rel);
    }

    void* applicationContext() const noexcept {
        return applicationContext_.load(std::memory_order_acquire);
    }

    void releaseOrphans() noexcept {
        std::unordered_map<void*, std::size_t> orphans;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            allocations_.swap(orphans);
        }
        for (const auto& allocation : orphans) {
            (void)sshFreeTrackedSensitive(allocation.first);
        }
    }

    std::size_t pendingAllocationCount() const noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        return allocations_.size();
    }

    bool prepareDeferredSession(LIBSSH2_SESSION* session) noexcept {
        LIBSSH2_SESSION* expected = nullptr;
        return session != nullptr && deferredSession_.compare_exchange_strong(
            expected, session, std::memory_order_acq_rel,
            std::memory_order_acquire);
    }

    LIBSSH2_SESSION* takeDeferredSession() noexcept {
        return deferredSession_.exchange(nullptr, std::memory_order_acq_rel);
    }

    void setDeferredNext(SshLibssh2AllocationContext* next) noexcept {
        deferredNext_.store(next, std::memory_order_relaxed);
    }

    SshLibssh2AllocationContext* takeDeferredNext() noexcept {
        return deferredNext_.exchange(nullptr, std::memory_order_relaxed);
    }

private:
    mutable std::mutex mutex_;
    std::unordered_map<void*, std::size_t> allocations_;
    std::atomic<void*> applicationContext_ {nullptr};
    std::atomic<LIBSSH2_SESSION*> deferredSession_ {nullptr};
    std::atomic<SshLibssh2AllocationContext*> deferredNext_ {nullptr};
};

inline SshLibssh2AllocationContext* sshLibssh2AllocationContext(
    void** abstract) noexcept {
    return abstract == nullptr
        ? nullptr
        : static_cast<SshLibssh2AllocationContext*>(*abstract);
}

inline void* sshLibssh2ApplicationContext(void** abstract) noexcept {
    SshLibssh2AllocationContext* context =
        sshLibssh2AllocationContext(abstract);
    return context == nullptr ? nullptr : context->applicationContext();
}

inline bool sshSetLibssh2ApplicationContext(
    LIBSSH2_SESSION* session, void* applicationContext) noexcept {
    if (session == nullptr) { return false; }
    SshLibssh2AllocationContext* context = sshLibssh2AllocationContext(
        libssh2_session_abstract(session));
    if (context == nullptr) { return false; }
    context->setApplicationContext(applicationContext);
    return true;
}

/** Temporarily binds an application callback object without replacing the
 * allocator context stored permanently in session->abstract. */
class SshLibssh2ApplicationContextBinding final {
public:
    SshLibssh2ApplicationContextBinding(
        LIBSSH2_SESSION* session, void* applicationContext) noexcept {
        if (session == nullptr) { return; }
        context_ = sshLibssh2AllocationContext(
            libssh2_session_abstract(session));
        if (context_ == nullptr) { return; }
        previous_ = context_->exchangeApplicationContext(applicationContext);
        valid_ = true;
    }

    ~SshLibssh2ApplicationContextBinding() noexcept {
        if (valid_) { context_->setApplicationContext(previous_); }
    }

    SshLibssh2ApplicationContextBinding(
        const SshLibssh2ApplicationContextBinding&) = delete;
    SshLibssh2ApplicationContextBinding& operator=(
        const SshLibssh2ApplicationContextBinding&) = delete;

    bool valid() const noexcept { return valid_; }

private:
    SshLibssh2AllocationContext* context_ = nullptr;
    void* previous_ = nullptr;
    bool valid_ = false;
};

/** Track and wipe every allocation made by a production libssh2 session. */
inline void* sshLibssh2TrackedAlloc(std::size_t size, void** abstract) noexcept {
    SshLibssh2AllocationContext* context =
        sshLibssh2AllocationContext(abstract);
    return context == nullptr ? nullptr : context->allocate(size);
}

inline void sshLibssh2TrackedFree(void* pointer, void** abstract) noexcept {
    SshLibssh2AllocationContext* context =
        sshLibssh2AllocationContext(abstract);
    if (context == nullptr) { return; }
    (void)context->release(pointer);
}

inline void* sshLibssh2TrackedRealloc(
    void* pointer, std::size_t size, void** abstract) noexcept {
    SshLibssh2AllocationContext* context =
        sshLibssh2AllocationContext(abstract);
    return context == nullptr ? nullptr : context->reallocate(pointer, size);
}

/** Allocates callback-owned material through the exact session allocator. */
inline void* sshAllocateLibssh2CallbackSensitive(
    std::size_t size, void** abstract) noexcept {
    return sshLibssh2TrackedAlloc(size, abstract);
}

inline void sshReapDeferredTrackedLibssh2Sessions() noexcept;

template <typename Initializer>
inline LIBSSH2_SESSION* sshCreateTrackedLibssh2SessionWith(
    Initializer&& initializer) noexcept {
    auto* context = new (std::nothrow) SshLibssh2AllocationContext();
    if (context == nullptr) { return nullptr; }
    LIBSSH2_SESSION* session = nullptr;
    try {
        session = initializer(context);
    } catch (...) {
        session = nullptr;
    }
    if (session == nullptr) {
        delete context;
    }
    return session;
}

inline LIBSSH2_SESSION* sshCreateTrackedLibssh2Session() noexcept {
    sshReapDeferredTrackedLibssh2Sessions();
    return sshCreateTrackedLibssh2SessionWith(
        [](SshLibssh2AllocationContext* context) {
            return libssh2_session_init_ex(
                &sshLibssh2TrackedAlloc,
                &sshLibssh2TrackedFree,
                &sshLibssh2TrackedRealloc,
                context);
        });
}

/**
 * Frees a tracked session and then wipes allocator-owned upstream orphans.
 * EAGAIN keeps the context alive because libssh2 still owns the session.
 */
using SshLibssh2SessionFreeFunction = int (*)(LIBSSH2_SESSION*);

inline int sshFinishTrackedLibssh2SessionFree(
    LIBSSH2_SESSION*& session,
    SshLibssh2AllocationContext* context, int result) noexcept {
    if (result != 0) { return result; }
    session = nullptr;
    delete context;
    return result;
}

inline int sshFreeTrackedLibssh2SessionWith(
    LIBSSH2_SESSION*& session,
    SshLibssh2SessionFreeFunction freeSession) noexcept {
    if (session == nullptr) { return 0; }
    SshLibssh2AllocationContext* context = sshLibssh2AllocationContext(
        libssh2_session_abstract(session));
    if (context == nullptr || freeSession == nullptr) {
        return LIBSSH2_ERROR_INVAL;
    }
    const int result = freeSession(session);
    return sshFinishTrackedLibssh2SessionFree(session, context, result);
}

inline int sshFreeTrackedLibssh2Session(
    LIBSSH2_SESSION*& session) noexcept {
    if (session == nullptr) { return 0; }
    SshLibssh2AllocationContext* context = sshLibssh2AllocationContext(
        libssh2_session_abstract(session));
    if (context == nullptr) { return LIBSSH2_ERROR_INVAL; }
    const int result = libssh2_session_free(session);
    return sshFinishTrackedLibssh2SessionFree(session, context, result);
}

inline std::atomic<SshLibssh2AllocationContext*>&
sshDeferredTrackedLibssh2SessionHead() noexcept {
    static std::atomic<SshLibssh2AllocationContext*> head {nullptr};
    return head;
}

inline std::atomic<std::size_t>&
sshDeferredTrackedLibssh2SessionCountStorage() noexcept {
    static std::atomic<std::size_t> count {0};
    return count;
}

inline std::size_t sshDeferredTrackedLibssh2SessionCount() noexcept {
    return sshDeferredTrackedLibssh2SessionCountStorage().load(
        std::memory_order_acquire);
}

#ifdef RDP_NATIVE_CALLBACK_TESTING
inline std::atomic<bool>&
sshDeferredTrackedLibssh2AutoReapStorage() noexcept {
    static std::atomic<bool> enabled {true};
    return enabled;
}

inline bool sshSetDeferredTrackedLibssh2AutoReapForTesting(
    bool enabled) noexcept {
    return sshDeferredTrackedLibssh2AutoReapStorage().exchange(
        enabled, std::memory_order_acq_rel);
}
#endif

inline bool sshDeferredTrackedLibssh2AutoReapEnabled() noexcept {
#ifdef RDP_NATIVE_CALLBACK_TESTING
    return sshDeferredTrackedLibssh2AutoReapStorage().load(
        std::memory_order_acquire);
#else
    return true;
#endif
}

/** Notify the bounded, joinable process-local deferred-session reaper. */
void sshScheduleDeferredTrackedLibssh2Reaper() noexcept;

#ifdef RDP_NATIVE_CALLBACK_TESTING
bool sshWaitForDeferredTrackedLibssh2ReaperIdleForTesting(
    std::chrono::milliseconds timeout) noexcept;

inline std::atomic<std::size_t>&
sshLibssh2RetiredTransportInvocationCountStorage() noexcept {
    static std::atomic<std::size_t> count {0};
    return count;
}

inline void sshResetLibssh2RetiredTransportInvocationsForTesting() noexcept {
    sshLibssh2RetiredTransportInvocationCountStorage().store(
        0, std::memory_order_release);
}

inline std::size_t sshLibssh2RetiredTransportInvocationsForTesting() noexcept {
    return sshLibssh2RetiredTransportInvocationCountStorage().load(
        std::memory_order_acquire);
}
#endif

inline LIBSSH2_SEND_FUNC(sshLibssh2RetiredSend) {
    (void)socket;
    (void)buffer;
    (void)length;
    (void)flags;
    (void)abstract;
#ifdef RDP_NATIVE_CALLBACK_TESTING
    sshLibssh2RetiredTransportInvocationCountStorage().fetch_add(
        1, std::memory_order_acq_rel);
#endif
    return -1;
}

inline LIBSSH2_RECV_FUNC(sshLibssh2RetiredRecv) {
    (void)socket;
    (void)buffer;
    (void)length;
    (void)flags;
    (void)abstract;
#ifdef RDP_NATIVE_CALLBACK_TESTING
    sshLibssh2RetiredTransportInvocationCountStorage().fetch_add(
        1, std::memory_order_acq_rel);
#endif
    return -1;
}

/** Transfers a failed final release into an allocation-free intrusive queue. */
inline bool sshQuarantineTrackedLibssh2SessionWithScheduling(
    LIBSSH2_SESSION*& session, bool scheduleReaper) noexcept {
    if (session == nullptr) { return true; }
    SshLibssh2AllocationContext* context = sshLibssh2AllocationContext(
        libssh2_session_abstract(session));
    if (context == nullptr || !context->prepareDeferredSession(session)) {
        return false;
    }
    // The transport descriptor may be closed and reused before a later reap.
    // Replace both I/O callbacks while the exact session is still owned so a
    // delayed local cleanup can never touch that reused descriptor.
    (void)libssh2_session_callback_set2(
        session, LIBSSH2_CALLBACK_SEND,
        reinterpret_cast<libssh2_cb_generic*>(&sshLibssh2RetiredSend));
    (void)libssh2_session_callback_set2(
        session, LIBSSH2_CALLBACK_RECV,
        reinterpret_cast<libssh2_cb_generic*>(&sshLibssh2RetiredRecv));
    context->setApplicationContext(nullptr);
    sshDeferredTrackedLibssh2SessionCountStorage().fetch_add(
        1, std::memory_order_acq_rel);
    SshLibssh2AllocationContext* head =
        sshDeferredTrackedLibssh2SessionHead().load(std::memory_order_acquire);
    do {
        context->setDeferredNext(head);
    } while (!sshDeferredTrackedLibssh2SessionHead().compare_exchange_weak(
        head, context, std::memory_order_release, std::memory_order_acquire));
    session = nullptr;
    if (scheduleReaper && sshDeferredTrackedLibssh2AutoReapEnabled()) {
        sshScheduleDeferredTrackedLibssh2Reaper();
    }
    return true;
}

inline bool sshQuarantineTrackedLibssh2Session(
    LIBSSH2_SESSION*& session) noexcept {
    return sshQuarantineTrackedLibssh2SessionWithScheduling(session, true);
}

/**
 * Retries each quarantined session once. A worker pass suppresses recursive
 * scheduling; an external pass may request one new bounded retry burst.
 */
inline void sshReapDeferredTrackedLibssh2SessionsPass(
    bool scheduleIfPending) noexcept {
    SshLibssh2AllocationContext* context =
        sshDeferredTrackedLibssh2SessionHead().exchange(
            nullptr, std::memory_order_acq_rel);
    while (context != nullptr) {
        SshLibssh2AllocationContext* next = context->takeDeferredNext();
        LIBSSH2_SESSION* session = context->takeDeferredSession();
        sshDeferredTrackedLibssh2SessionCountStorage().fetch_sub(
            1, std::memory_order_acq_rel);
        if (session != nullptr) {
            libssh2_session_set_blocking(session, 1);
            (void)sshFreeTrackedLibssh2Session(session);
            if (session != nullptr) {
                (void)sshQuarantineTrackedLibssh2SessionWithScheduling(
                    session, false);
            }
        }
        context = next;
    }
    if (scheduleIfPending &&
        sshDeferredTrackedLibssh2SessionCount() != 0 &&
        sshDeferredTrackedLibssh2AutoReapEnabled()) {
        sshScheduleDeferredTrackedLibssh2Reaper();
    }
}

inline void sshReapDeferredTrackedLibssh2Sessions() noexcept {
    sshReapDeferredTrackedLibssh2SessionsPass(true);
}

/** Final owner handoff: release now or retain the live session for reaping. */
inline int sshRetireTrackedLibssh2Session(
    LIBSSH2_SESSION*& session) noexcept {
    sshReapDeferredTrackedLibssh2Sessions();
    if (session == nullptr) { return 0; }
    libssh2_session_set_blocking(session, 1);
    const int result = sshFreeTrackedLibssh2Session(session);
    if (session != nullptr) {
        (void)sshQuarantineTrackedLibssh2Session(session);
    }
    return result;
}

inline int sshRetireTrackedLibssh2SessionWith(
    LIBSSH2_SESSION*& session,
    SshLibssh2SessionFreeFunction freeSession) noexcept {
    sshReapDeferredTrackedLibssh2Sessions();
    if (session == nullptr) { return 0; }
    libssh2_session_set_blocking(session, 1);
    const int result =
        sshFreeTrackedLibssh2SessionWith(session, freeSession);
    if (session != nullptr) {
        (void)sshQuarantineTrackedLibssh2Session(session);
    }
    return result;
}
