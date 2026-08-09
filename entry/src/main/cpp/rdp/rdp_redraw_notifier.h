/**
 * rdp_redraw_notifier.h - session-scoped redraw wake lifecycle
 */

#ifndef RDP_REDRAW_NOTIFIER_H
#define RDP_REDRAW_NOTIFIER_H

#include <cstddef>
#include <chrono>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <memory>
#include <utility>

/**
 * Bridges a renderer wake to one RDP session without retaining a raw adapter
 * callback after teardown. disableAndWaitWithin() is the bounded destruction
 * barrier for the callback target; late renderer wakes become no-ops.
 */
class RdpRedrawNotifier {
public:
    RdpRedrawNotifier() : state_(std::make_shared<State>()) {}

    void bind(std::function<void()> callback) {
        const auto state = state_;
        std::lock_guard<std::mutex> lock(state->mutex);
        state->callback = std::move(callback);
        state->enabled = static_cast<bool>(state->callback);
    }

    bool disableAndWaitWithin(std::chrono::milliseconds timeout) {
        const auto state = state_;
        std::unique_lock<std::mutex> lock(state->mutex);
        state->enabled = false;
        state->callback = nullptr;
        return state->cv.wait_for(lock, timeout,
                                  [&]() { return state->inFlight == 0; });
    }

    void disableAndWait() {
        (void)disableAndWaitWithin(std::chrono::milliseconds(500));
    }

    void notify() {
        // Keep the callback gate state alive independently of this facade.
        // A bounded teardown may release the facade while a renderer wake is
        // still unwinding; the callback itself must not dereference a freed
        // notifier just to decrement its in-flight count.
        const auto state = state_;
        std::function<void()> callback;
        {
            std::lock_guard<std::mutex> lock(state->mutex);
            if (!state->enabled || !state->callback) {
                return;
            }
            ++state->inFlight;
            callback = state->callback;
        }

        try {
            callback();
        } catch (...) {
            // A redraw wake is advisory. Never let a callback exception skip
            // the in-flight teardown accounting or escape into the renderer.
        }

        {
            std::lock_guard<std::mutex> lock(state->mutex);
            --state->inFlight;
            if (state->inFlight == 0) {
                state->cv.notify_all();
            }
        }
    }

private:
    struct State {
        std::mutex mutex;
        std::condition_variable cv;
        std::function<void()> callback;
        size_t inFlight = 0;
        bool enabled = false;
    };

    std::shared_ptr<State> state_;
};

#endif // RDP_REDRAW_NOTIFIER_H
