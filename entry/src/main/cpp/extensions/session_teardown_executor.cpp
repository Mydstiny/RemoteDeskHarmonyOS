/**
 * session_teardown_executor.cpp - serialized background teardown execution
 */

#include "session_teardown_executor.h"

#include <atomic>
#include <condition_variable>
#include <deque>
#include <cstdlib>
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
    bool workerActive = false;
    bool workerDone = false;
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
                        workerDone = true;
                        stateCv.notify_all();
                        return;
                    }
                    continue;
                }
                item = std::move(queue.front());
                queue.pop_front();
                workerActive = true;
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
                workerActive = false;
            }
            stateCv.notify_all();
        }
    }
};

class ExecutorDeferredOwner {
public:
    ExecutorDeferredOwner() : worker_([this]() { run(); }) {}

    void enqueue(std::shared_ptr<Executor::Impl> impl) {
        if (!impl) return;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            pending_.push_back(std::move(impl));
        }
        cv_.notify_one();
    }

    bool drainWithin(std::chrono::milliseconds timeout) {
        std::unique_lock<std::mutex> lock(mutex_);
        return cv_.wait_for(lock, timeout, [this]() {
            return pending_.empty() && active_ == 0;
        });
    }

    std::size_t remaining() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return pending_.size() + active_;
    }

    bool shutdownWithin(std::chrono::milliseconds timeout) {
        const auto deadline = std::chrono::steady_clock::now() + timeout;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            stopping_ = true;
        }
        cv_.notify_all();
        std::unique_lock<std::mutex> lock(mutex_);
        if (!cv_.wait_until(lock, deadline, [this]() { return workerDone_; })) {
            return false;
        }
        lock.unlock();
        worker_.join();
        return true;
    }

private:
    void run() {
        for (;;) {
            std::shared_ptr<Executor::Impl> impl;
            {
                std::unique_lock<std::mutex> lock(mutex_);
                cv_.wait(lock, [this]() { return stopping_ || !pending_.empty(); });
                if (pending_.empty() && stopping_) {
                    workerDone_ = true;
                    cv_.notify_all();
                    return;
                }
                impl = std::move(pending_.front());
                pending_.pop_front();
                ++active_;
            }
            // Check each terminal fence independently. A stalled executor
            // must not hold the queue head in front of completed sessions.
            bool done = false;
            {
                std::lock_guard<std::mutex> lock(impl->mutex);
                done = impl->workerDone;
            }
            if (!done) {
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    pending_.push_back(std::move(impl));
                    --active_;
                }
                cv_.notify_all();
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
                continue;
            }
            impl->worker.join();
            {
                std::lock_guard<std::mutex> lock(mutex_);
                --active_;
                cv_.notify_all();
            }
        }
    }

    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::deque<std::shared_ptr<Executor::Impl>> pending_;
    bool stopping_ = false;
    bool workerDone_ = false;
    std::size_t active_ = 0;
    // Keep the thread last: C++ initializes members in declaration order, and
    // run() may observe every state member as soon as worker_ starts.
    std::thread worker_;
};

std::mutex g_executorOwnerMutex;
ExecutorDeferredOwner* g_executorOwner = nullptr;

ExecutorDeferredOwner& executorOwner() {
    std::lock_guard<std::mutex> lock(g_executorOwnerMutex);
    if (!g_executorOwner) g_executorOwner = new ExecutorDeferredOwner();
    return *g_executorOwner;
}

void deferExecutor(std::shared_ptr<Executor::Impl> impl) {
    executorOwner().enqueue(std::move(impl));
}

Executor::Executor() : impl_(std::make_shared<Impl>()) {}

Executor::~Executor() {
    if (impl_ && !shutdownWithin(std::chrono::milliseconds(500))) {
        deferExecutor(std::move(impl_));
    }
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

bool Executor::shutdownWithin(std::chrono::milliseconds timeout) {
    if (!impl_) return true;
    std::lock_guard<std::mutex> shutdownLock(impl_->shutdownMutex);
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        impl_->accepting = false;
        impl_->stopping = true;
    }
    impl_->workCv.notify_all();
    if (!impl_->worker.joinable()) {
        return true;
    }
    if (impl_->worker.get_id() == std::this_thread::get_id()) {
        return false;
    }
    std::unique_lock<std::mutex> lock(impl_->mutex);
    if (!impl_->stateCv.wait_for(lock, timeout, [this]() {
            return impl_->workerDone;
        })) {
        return false;
    }
    lock.unlock();
    impl_->worker.join();
    return true;
}

std::size_t Executor::remainingCount() const {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    return impl_->queue.size() + (impl_->workerActive ? 1U : 0U);
}

void Executor::shutdown() {
    if (!shutdownWithin(std::chrono::milliseconds(500))) {
        deferExecutor(std::move(impl_));
    }
}

bool drainDeferredWithin(std::chrono::milliseconds timeout) {
    std::lock_guard<std::mutex> lock(g_executorOwnerMutex);
    return g_executorOwner == nullptr || g_executorOwner->drainWithin(timeout);
}

bool shutdownDeferredWithin(std::chrono::milliseconds timeout) {
    ExecutorDeferredOwner* owner = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_executorOwnerMutex);
        owner = g_executorOwner;
    }
    if (!owner) return true;
    const bool done = owner->shutdownWithin(timeout);
    if (done) {
        std::lock_guard<std::mutex> lock(g_executorOwnerMutex);
        if (g_executorOwner == owner) {
            g_executorOwner = nullptr;
            // The worker is joined, but a concurrent caller may still hold the
            // raw owner reference obtained before shutdown. Retain this
            // retired owner until process exit instead of deleting it after
            // releasing the lookup lock.
        }
    }
    return done;
}

std::size_t deferredRemaining() {
    std::lock_guard<std::mutex> lock(g_executorOwnerMutex);
    return g_executorOwner == nullptr ? 0 : g_executorOwner->remaining();
}

} // namespace SessionTeardown
