/**
 * session_teardown_executor.h - serialized background teardown execution
 */

#ifndef SESSION_TEARDOWN_EXECUTOR_H
#define SESSION_TEARDOWN_EXECUTOR_H

#include <chrono>
#include <cstdint>
#include <functional>
#include <memory>

namespace SessionTeardown {

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

    Executor();
    ~Executor();

    Executor(const Executor&) = delete;
    Executor& operator=(const Executor&) = delete;

    std::uint64_t enqueue(Task task);
    State state(std::uint64_t requestId) const;
    bool waitFor(std::uint64_t requestId, std::chrono::milliseconds timeout);
    void shutdown();

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace SessionTeardown

#endif // SESSION_TEARDOWN_EXECUTOR_H
