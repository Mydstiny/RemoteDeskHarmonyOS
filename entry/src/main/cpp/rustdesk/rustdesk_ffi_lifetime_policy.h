#ifndef RUSTDESK_FFI_LIFETIME_POLICY_H
#define RUSTDESK_FFI_LIFETIME_POLICY_H

#include <cstdint>
#include <memory>
#include <mutex>
#include <unordered_map>

namespace RustDeskFfiLifetime {

// A raw FFI user-data pointer may be read before the callback can increment
// the callback-active counter. The context is therefore retireable only after
// every possible Rust handle has returned from rustdesk_disconnect().
inline bool CanRetireCallbackContext(uint32_t handleJoinPending,
                                     uint32_t callbacksActive,
                                     bool displayHandlePresent,
                                     uint32_t deferredJoinCount,
                                     bool deferredHandlePresent) {
    return handleJoinPending == 0 && callbacksActive == 0 &&
        !displayHandlePresent && deferredJoinCount == 0 &&
        !deferredHandlePresent;
}

inline bool HasHandleJoinReservation(uint32_t handleJoinPending) {
    return handleJoinPending != 0;
}

// FFI callbacks receive a raw address that Rust may call after the native
// owner has started teardown. Lookup must happen without dereferencing that
// address; the returned shared_ptr then owns the callback context for the
// complete callback invocation.
template<typename Context>
class CallbackContextRegistry final {
public:
    bool publish(const std::shared_ptr<Context>& context) {
        if (!context) {
            return false;
        }
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            auto result = contexts_.emplace(context.get(), context);
            return result.second || result.first->second == context;
        } catch (...) {
            return false;
        }
    }

    std::shared_ptr<Context> acquire(void* userData) const {
        if (userData == nullptr) {
            return nullptr;
        }
        std::lock_guard<std::mutex> lock(mutex_);
        const auto it = contexts_.find(userData);
        return it == contexts_.end() ? nullptr : it->second;
    }

    bool retire(const std::shared_ptr<Context>& context) {
        if (!context) {
            return true;
        }
        std::lock_guard<std::mutex> lock(mutex_);
        const auto it = contexts_.find(context.get());
        if (it == contexts_.end()) {
            return true;
        }
        if (it->second != context) {
            return false;
        }
        contexts_.erase(it);
        return true;
    }

private:
    mutable std::mutex mutex_;
    std::unordered_map<void*, std::shared_ptr<Context>> contexts_;
};

} // namespace RustDeskFfiLifetime

#endif // RUSTDESK_FFI_LIFETIME_POLICY_H
