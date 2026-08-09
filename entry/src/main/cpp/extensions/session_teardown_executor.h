/**
 * session_teardown_executor.h - serialized background teardown execution
 */

#ifndef SESSION_TEARDOWN_EXECUTOR_H
#define SESSION_TEARDOWN_EXECUTOR_H

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>

namespace SessionTeardown {

class ExecutorDeferredOwner;

enum class State : std::uint8_t {
    Unknown = 0,
    Queued,
    Running,
    Complete,
    Failed,
};

class Executor {
public:
    using Task = std::function<void()>;
    struct Impl;

    Executor();
    ~Executor();

    Executor(const Executor&) = delete;
    Executor& operator=(const Executor&) = delete;

    std::uint64_t enqueue(Task task);
    State state(std::uint64_t requestId) const;
    bool waitFor(std::uint64_t requestId, std::chrono::milliseconds timeout);
    // Stops accepting work and waits only up to the supplied total budget.
    // A false result leaves this Executor as the explicit owner; callers may
    // release the blocked task and call shutdownWithin again.
    bool shutdownWithin(std::chrono::milliseconds timeout);
    std::size_t remainingCount() const;
    void shutdown();

private:
    friend class ExecutorDeferredOwner;
    std::shared_ptr<Impl> impl_;
};

bool drainDeferredWithin(std::chrono::milliseconds timeout);
bool shutdownDeferredWithin(std::chrono::milliseconds timeout);
std::size_t deferredRemaining();

} // namespace SessionTeardown

#endif // SESSION_TEARDOWN_EXECUTOR_H
