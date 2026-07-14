/**
 * session_teardown_executor.cpp - serialized background teardown execution
 */

#include "session_teardown_executor.h"

#include <atomic>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <utility>

namespace SessionTeardown {

namespace {

constexpr std::size_t kRetainedTerminalStates = 256;

bool IsTerminal(State state) {
    return state == State::Complete || state == State::Failed;
}

} // namespace

struct Executor::Impl {
    struct WorkItem {
        std::uint64_t requestId = 0;
        Task task;
    };

    mutable std::mutex mutex;
    std::mutex shutdownMutex;
    std::condition_variable workCv;
    std::condition_variable stateCv;
    std::deque<WorkItem> queue;
    std::unordered_map<std::uint64_t, State> states;
    std::deque<std::uint64_t> terminalOrder;
    std::atomic<std::uint64_t> nextRequestId {1};
    bool accepting = true;
    bool stopping = false;
    std::thread worker;

    Impl() : worker([this]() { run(); }) {}

    void run() {
        while (true) {
            WorkItem item;
            {
                std::unique_lock<std::mutex> lock(mutex);
                workCv.wait(lock, [this]() { return stopping || !queue.empty(); });
                if (queue.empty()) {
                    if (stopping) {
                        return;
                    }
                    continue;
                }
                item = std::move(queue.front());
                queue.pop_front();
                states[item.requestId] = State::Running;
                stateCv.notify_all();
            }

            State terminalState = State::Complete;
            try {
                item.task();
            } catch (...) {
                terminalState = State::Failed;
            }

            {
                std::lock_guard<std::mutex> lock(mutex);
                states[item.requestId] = terminalState;
                terminalOrder.push_back(item.requestId);
                while (terminalOrder.size() > kRetainedTerminalStates) {
                    const std::uint64_t expired = terminalOrder.front();
                    terminalOrder.pop_front();
                    auto it = states.find(expired);
                    if (it != states.end() && IsTerminal(it->second)) {
                        states.erase(it);
                    }
                }
            }
            stateCv.notify_all();
        }
    }
};

Executor::Executor() : impl_(std::make_unique<Impl>()) {}

Executor::~Executor() {
    shutdown();
}

std::uint64_t Executor::enqueue(Task task) {
    if (!task) {
        return 0;
    }
    const std::uint64_t requestId = impl_->nextRequestId.fetch_add(1, std::memory_order_relaxed);
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        if (!impl_->accepting) {
            return 0;
        }
        impl_->states[requestId] = State::Queued;
        impl_->queue.push_back({requestId, std::move(task)});
    }
    impl_->workCv.notify_one();
    return requestId;
}

State Executor::state(std::uint64_t requestId) const {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const auto it = impl_->states.find(requestId);
    return it == impl_->states.end() ? State::Unknown : it->second;
}

bool Executor::waitFor(std::uint64_t requestId, std::chrono::milliseconds timeout) {
    std::unique_lock<std::mutex> lock(impl_->mutex);
    const bool reachedTerminal = impl_->stateCv.wait_for(lock, timeout, [this, requestId]() {
        const auto it = impl_->states.find(requestId);
        return it != impl_->states.end() && IsTerminal(it->second);
    });
    return reachedTerminal;
}

void Executor::shutdown() {
    std::lock_guard<std::mutex> shutdownLock(impl_->shutdownMutex);
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        impl_->accepting = false;
        impl_->stopping = true;
    }
    impl_->workCv.notify_all();
    if (impl_->worker.joinable() && impl_->worker.get_id() != std::this_thread::get_id()) {
        impl_->worker.join();
    }
}

} // namespace SessionTeardown
