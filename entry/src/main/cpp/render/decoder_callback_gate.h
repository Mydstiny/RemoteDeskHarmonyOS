/**
 * decoder_callback_gate.h - thread-safe decoder callback lifecycle barrier.
 */

#ifndef DECODER_CALLBACK_GATE_H
#define DECODER_CALLBACK_GATE_H

#include <cstddef>
#include <chrono>
#include <condition_variable>
#include <functional>
#include <memory>
#include <mutex>
#include <utility>

/**
 * Set(nullptr) prevents new invocations and waits for callbacks which already
 * copied the function to finish before decoder-owned resources are destroyed.
 */
template <typename Callback>
class DecoderCallbackGate {
public:
    DecoderCallbackGate() : state_(std::make_shared<State>()) {}

    bool Set(Callback callback) {
        const std::shared_ptr<State> state = state_;
        std::unique_lock<std::mutex> lock(state->mutex);
        state->callback = std::move(callback);
        if (!state->callback) {
            return state->callbackCv.wait_for(lock, std::chrono::milliseconds(500),
                [&]() { return state->inFlight == 0; });
        }
        return true;
    }

    bool ClearAndWait() {
        return Set(nullptr);
    }

    template <typename... Args>
    void Invoke(Args&&... args) {
        const std::shared_ptr<State> state = state_;
        Callback callback;
        {
            std::lock_guard<std::mutex> lock(state->mutex);
            if (!state->callback) {
                return;
            }
            callback = state->callback;
            ++state->inFlight;
        }

        try {
            callback(std::forward<Args>(args)...);
        } catch (...) {
            // Decoder callbacks run on codec/render threads. Never allow an
            // exception to escape and terminate the process.
        }
        FinishInvocation(state);
    }

private:
    struct State {
        std::mutex mutex;
        std::condition_variable callbackCv;
        Callback callback;
        size_t inFlight = 0;
    };

    void FinishInvocation(const std::shared_ptr<State>& state) {
        std::lock_guard<std::mutex> lock(state->mutex);
        --state->inFlight;
        if (state->inFlight == 0) {
            state->callbackCv.notify_all();
        }
    }

    std::shared_ptr<State> state_;
};

#endif // DECODER_CALLBACK_GATE_H
