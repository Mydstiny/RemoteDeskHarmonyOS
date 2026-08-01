#ifndef RUSTDESK_FFI_HANDLE_GATE_H
#define RUSTDESK_FFI_HANDLE_GATE_H

#include <mutex>
#include <shared_mutex>
#include <utility>

/**
 * Pins the opaque RustDesk FFI client while a native call is in flight.
 *
 * Every FFI call owns a shared Lease. Teardown takes the exclusive side,
 * detaches the pointer, and only then releases the Rust allocation. This
 * prevents capability polling, input, or a display switch from dereferencing
 * a RustDeskClient after rustdesk_disconnect() has consumed it.
 */
class RustDeskFfiHandleGate {
public:
    class Lease {
    public:
        Lease(Lease&&) = default;
        Lease& operator=(Lease&&) = default;
        Lease(const Lease&) = delete;
        Lease& operator=(const Lease&) = delete;

        void* get() const {
            return handle_;
        }

        explicit operator bool() const {
            return handle_ != nullptr;
        }

    private:
        friend class RustDeskFfiHandleGate;

        Lease(std::shared_lock<std::shared_mutex>&& lock, void* handle)
            : lock_(std::move(lock)), handle_(handle) {}

        std::shared_lock<std::shared_mutex> lock_;
        void* handle_ = nullptr;
    };

    Lease acquire() const {
        std::shared_lock<std::shared_mutex> lock(mutex_);
        void* handle = handle_;
        return Lease(std::move(lock), handle);
    }

    bool attach(void* handle) {
        if (handle == nullptr) {
            return false;
        }
        std::unique_lock<std::shared_mutex> lock(mutex_);
        if (handle_ != nullptr) {
            return false;
        }
        handle_ = handle;
        return true;
    }

    void* detach() {
        std::unique_lock<std::shared_mutex> lock(mutex_);
        return std::exchange(handle_, nullptr);
    }

    void* detachIf(void* expected) {
        std::unique_lock<std::shared_mutex> lock(mutex_);
        if (handle_ != expected) {
            return nullptr;
        }
        return std::exchange(handle_, nullptr);
    }

    bool owns(void* expected) const {
        std::shared_lock<std::shared_mutex> lock(mutex_);
        return expected != nullptr && handle_ == expected;
    }

    bool hasHandle() const {
        std::shared_lock<std::shared_mutex> lock(mutex_);
        return handle_ != nullptr;
    }

private:
    mutable std::shared_mutex mutex_;
    void* handle_ = nullptr;
};

#endif // RUSTDESK_FFI_HANDLE_GATE_H
