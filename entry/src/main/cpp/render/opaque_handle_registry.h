/**
 * opaque_handle_registry.h - monotonic public native handle registry
 *
 * Public NAPI handles are process-local tokens, never object addresses.  A
 * registry entry owns the native object and carries the session identity that
 * created it.  Operation leases keep the entry alive while the registry lock
 * is released, so destroy can wait for callbacks without calling into an
 * object while holding the registry mutex.
 */

#ifndef OPAQUE_HANDLE_REGISTRY_H
#define OPAQUE_HANDLE_REGISTRY_H

#include "render/video_perf_counters.h"

#include <atomic>
#include <cstdint>
#include <limits>
#include <memory>
#include <mutex>
#include <shared_mutex>
#include <unordered_map>

template<typename T>
class OpaqueHandleRegistry {
private:
    struct Entry {
        explicit Entry(std::shared_ptr<T> value,
                       const Render::DecoderSessionIdentity& identity)
            : object(std::move(value)), boundOwner(identity), generation(identity.generation),
              active(identity.valid()), detached(!identity.valid()) {}

        std::shared_ptr<T> object;
        Render::DecoderSessionIdentity boundOwner;
        uint64_t generation = 0;
        bool active = false;
        bool detached = true;
        bool destroying = false;
        mutable std::shared_mutex operationMutex;
    };

public:
    struct Metadata {
        bool found = false;
        bool active = false;
        bool detached = true;
        bool destroying = false;
        uint64_t generation = 0;
        Render::DecoderSessionIdentity boundOwner;
    };

    class Lease {
    public:
        Lease() = default;
        Lease(Lease&&) = default;
        Lease& operator=(Lease&&) = default;
        Lease(const Lease&) = delete;
        Lease& operator=(const Lease&) = delete;

        explicit operator bool() const {
            return object_ != nullptr && operationLock_.owns_lock();
        }

        T* get() const {
            return object_.get();
        }

        T* operator->() const {
            return object_.get();
        }

        // Keep the object alive across a transition without touching the
        // registry mutex again. Callers already holding this operation lease
        // must not call registry retain/acquire recursively: destroy takes
        // registryMutex before waiting for operationMutex.
        std::shared_ptr<T> shared() const {
            return object_;
        }

        const Render::DecoderSessionIdentity& owner() const {
            return owner_;
        }

        uint64_t generation() const {
            return generation_;
        }

    private:
        friend class OpaqueHandleRegistry<T>;

        Lease(std::shared_ptr<Entry> entry,
              std::shared_ptr<T> object,
              std::shared_lock<std::shared_mutex>&& operationLock,
              const Render::DecoderSessionIdentity& owner,
              uint64_t generation)
            : entry_(std::move(entry)), object_(std::move(object)),
              operationLock_(std::move(operationLock)), owner_(owner), generation_(generation) {}

        std::shared_ptr<Entry> entry_;
        std::shared_ptr<T> object_;
        std::shared_lock<std::shared_mutex> operationLock_;
        Render::DecoderSessionIdentity owner_;
        uint64_t generation_ = 0;
    };

    int64_t registerObject(const std::shared_ptr<T>& object,
                           const Render::DecoderSessionIdentity& owner = {}) {
        if (!object) {
            return 0;
        }
        auto entry = std::make_shared<Entry>(object, owner);
        std::lock_guard<std::mutex> lock(registryMutex_);
        for (;;) {
            const uint64_t raw = nextToken_.fetch_add(1, std::memory_order_relaxed);
            if (raw == 0 || raw > static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) {
                continue;
            }
            const int64_t token = static_cast<int64_t>(raw);
            if (entries_.find(token) == entries_.end()) {
                entries_.emplace(token, entry);
                return token;
            }
        }
    }

    bool bind(int64_t token, const Render::DecoderSessionIdentity& owner) {
        if (!owner.valid()) {
            return false;
        }
        std::lock_guard<std::mutex> lock(registryMutex_);
        auto entry = findLocked(token);
        if (!entry || entry->destroying ||
            (entry->boundOwner.valid() && entry->boundOwner != owner)) {
            return false;
        }
        entry->boundOwner = owner;
        entry->generation = owner.generation;
        entry->active = true;
        entry->detached = false;
        return true;
    }

    bool activate(int64_t token, const Render::DecoderSessionIdentity& owner) {
        return bind(token, owner);
    }

    bool deactivate(int64_t token, const Render::DecoderSessionIdentity& owner) {
        if (!owner.valid()) {
            return false;
        }
        std::lock_guard<std::mutex> lock(registryMutex_);
        auto entry = findLocked(token);
        if (!entry || entry->destroying || entry->boundOwner != owner) {
            return false;
        }
        entry->active = false;
        entry->detached = true;
        return true;
    }

    Lease acquire(int64_t token, const Render::DecoderSessionIdentity& owner) const {
        if (token <= 0 || !owner.valid()) {
            return Lease();
        }
        std::lock_guard<std::mutex> lock(registryMutex_);
        auto entry = findLocked(token);
        if (!entry || entry->destroying || !entry->active || entry->detached ||
            entry->boundOwner != owner || !entry->object) {
            return Lease();
        }
        // Destroy takes registryMutex first and then this operation lock. It
        // therefore cannot remove the entry between validation and lease
        // acquisition, and no external/object call occurs under registryMutex.
        std::shared_lock<std::shared_mutex> operationLock(entry->operationMutex);
        return Lease(entry, entry->object, std::move(operationLock), entry->boundOwner,
                     entry->generation);
    }

    /** Retain an entry for transition/destruction bookkeeping without calling it. */
    std::shared_ptr<T> retain(int64_t token) const {
        std::lock_guard<std::mutex> lock(registryMutex_);
        const auto entry = findLocked(token);
        return entry && !entry->destroying ? entry->object : nullptr;
    }

    Metadata snapshot(int64_t token) const {
        std::lock_guard<std::mutex> lock(registryMutex_);
        auto entry = findLocked(token);
        if (!entry) {
            return Metadata {};
        }
        return Metadata {true, entry->active, entry->detached, entry->destroying,
                         entry->generation, entry->boundOwner};
    }

    /** Find a decoder/renderer-owned token without exposing registry entries. */
    int64_t findTokenByOwner(const Render::DecoderSessionIdentity& owner) const {
        if (!owner.valid()) {
            return 0;
        }
        std::lock_guard<std::mutex> lock(registryMutex_);
        int64_t detachedCandidate = 0;
        for (const auto& item : entries_) {
            const int64_t token = item.first;
            const auto& entry = item.second;
            if (!entry || entry->destroying || entry->boundOwner != owner) {
                continue;
            }
            if (entry->active && !entry->detached) {
                return token;
            }
            if (detachedCandidate == 0) {
                detachedCandidate = token;
            }
        }
        return detachedCandidate;
    }

    /** Destroy by token identity; the token's immutable bound owner is the validation key. */
    std::shared_ptr<T> destroy(int64_t token) {
        return destroyInternal(token, nullptr);
    }

    /** Destroy only when the caller supplies the exact session/generation owner. */
    std::shared_ptr<T> destroy(int64_t token, const Render::DecoderSessionIdentity& owner) {
        if (!owner.valid()) {
            return nullptr;
        }
        return destroyInternal(token, &owner);
    }

private:
    std::shared_ptr<Entry> findLocked(int64_t token) const {
        if (token <= 0) {
            return nullptr;
        }
        const auto it = entries_.find(token);
        return it == entries_.end() ? nullptr : it->second;
    }

    std::shared_ptr<T> destroyInternal(
        int64_t token, const Render::DecoderSessionIdentity* expectedOwner) {
        std::shared_ptr<Entry> entry;
        {
            std::lock_guard<std::mutex> lock(registryMutex_);
            entry = findLocked(token);
            if (!entry || entry->destroying ||
                (expectedOwner != nullptr && entry->boundOwner != *expectedOwner)) {
                return nullptr;
            }
            entry->active = false;
            entry->detached = true;
            entry->destroying = true;
            entries_.erase(token);
        }

        // Wait for all callback leases, then move the strong object reference
        // out. The destructor/callback cleanup runs after every registry lock
        // and operation lock has been released.
        std::unique_lock<std::shared_mutex> operationLock(entry->operationMutex);
        std::shared_ptr<T> object = std::move(entry->object);
        operationLock.unlock();
        return object;
    }

    mutable std::mutex registryMutex_;
    std::atomic<uint64_t> nextToken_ {1};
    std::unordered_map<int64_t, std::shared_ptr<Entry>> entries_;
};

#endif // OPAQUE_HANDLE_REGISTRY_H
