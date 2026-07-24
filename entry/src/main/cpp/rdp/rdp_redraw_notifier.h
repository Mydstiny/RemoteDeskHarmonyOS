/**
 * rdp_redraw_notifier.h - session-scoped redraw wake lifecycle
 */

#ifndef RDP_REDRAW_NOTIFIER_H
#define RDP_REDRAW_NOTIFIER_H

#include <cstddef>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <utility>

/**
 * Bridges a renderer wake to one RDP session without retaining a raw adapter
 * callback after teardown. disableAndWait() is the destruction barrier for the
 * callback target; late renderer wakes become no-ops.
 */
class RdpRedrawNotifier {
public:
    void bind(std::function<void()> callback) {
        std::lock_guard<std::mutex> lock(mutex_);
        callback_ = std::move(callback);
        enabled_ = static_cast<bool>(callback_);
    }

    void disableAndWait() {
        std::unique_lock<std::mutex> lock(mutex_);
        enabled_ = false;
        callback_ = nullptr;
        cv_.wait(lock, [this]() { return inFlight_ == 0; });
    }

    void notify() {
        std::function<void()> callback;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!enabled_ || !callback_) {
                return;
            }
            ++inFlight_;
            callback = callback_;
        }

        try {
            callback();
        } catch (...) {
            // A redraw wake is advisory. Never let a callback exception skip
            // the in-flight teardown accounting or escape into the renderer.
        }

        {
            std::lock_guard<std::mutex> lock(mutex_);
            --inFlight_;
            if (inFlight_ == 0) {
                cv_.notify_all();
            }
        }
    }

private:
    std::mutex mutex_;
    std::condition_variable cv_;
    std::function<void()> callback_;
    size_t inFlight_ = 0;
    bool enabled_ = false;
};

#endif // RDP_REDRAW_NOTIFIER_H
