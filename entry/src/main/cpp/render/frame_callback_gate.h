/**
 * frame_callback_gate.h — thread-safe software-decoder frame callback gate.
 *
 * Clearing a callback is a lifecycle barrier: it prevents new invocations and
 * waits for an invocation that already captured the callback to finish.
 */

#ifndef FRAME_CALLBACK_GATE_H
#define FRAME_CALLBACK_GATE_H

#include <condition_variable>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <mutex>
#include <memory>
#include <utility>

using SoftwareDecoderFrameCallback = std::function<int(const uint8_t* data, size_t size,
                                                       int width, int height, int stride)>;

class SoftwareDecoderFrameCallbackGate {
public:
    SoftwareDecoderFrameCallbackGate() : state_(std::make_shared<State>()) {}

    bool Set(SoftwareDecoderFrameCallback callback) {
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

    int Invoke(const uint8_t* data, size_t size, int width, int height, int stride) {
        const std::shared_ptr<State> state = state_;
        SoftwareDecoderFrameCallback callback;
        {
            std::lock_guard<std::mutex> lock(state->mutex);
            if (!state->callback) {
                return 0;
            }
            callback = state->callback;
            ++state->inFlight;
        }

        int result = 0;
        try {
            result = callback(data, size, width, height, stride);
        } catch (...) {
            FinishInvocation(state);
            // Frame callbacks run on the software decoder worker. Do not let
            // a renderer-side exception escape the worker and terminate the
            // process; the caller will turn this into a render failure.
            return -1;
        }
        FinishInvocation(state);
        return result;
    }

private:
    struct State {
        std::mutex mutex;
        std::condition_variable callbackCv;
        SoftwareDecoderFrameCallback callback;
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

#endif // FRAME_CALLBACK_GATE_H
