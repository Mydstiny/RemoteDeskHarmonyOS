/**
 * test_runner.h — 轻量原生单元测试框架
 *
 * 用法:
 *   RDP_TEST_CASE(frame_stats_basic) {
 *       Perf::FrameStats stats;
 *       stats.recordFrame(0);
 *       stats.recordFrame(16666); // ~60fps interval
 *       RDP_ASSERT(stats.frameCount.load() == 2);
 *   }
 *
 * 编译: cmake -DRDP_BUILD_TESTS=ON
 * 运行: 独立 test binary → hdc shell /data/local/tmp/rdp_test
 */

#ifndef TEST_RUNNER_H
#define TEST_RUNNER_H

#include <cstdio>
#include <cstdlib>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <exception>
#include <mutex>
#include <memory>
#include <vector>
#include <string>
#include <functional>
#include <thread>
#include <utility>
#include <deque>
#include <unordered_map>

struct RdpTestCaseResult {
    std::string name;
    bool passed = false;
    std::string failure;
};

#if defined(RDP_OHOS_TEST_NATIVE_CALLBACK_ENTRY) || defined(RDP_NATIVE_CALLBACK_TESTING)
#define RDP_CALLBACK_TEST_HARNESS 1
#endif

#if defined(RDP_CALLBACK_TEST_HARNESS)
namespace RdpTestDetail {

struct FailureState final {
    explicit FailureState(uint64_t caseToken) : token(caseToken) {}

    std::mutex mutex;
    std::thread::id ownerThread;
    const uint64_t token;
    bool failed = false;
    bool closed = false;
    size_t lateFailures = 0;
    std::string firstLateFailure;
    std::string firstFailure;
};

// A worker/callback captures this immutable binding at creation time.  The
// token is deliberately duplicated outside FailureState so a stale binding
// cannot be silently retargeted by changing a registry's active entry.
struct FailureSinkBinding final {
    explicit FailureSinkBinding(std::shared_ptr<FailureState> value)
        : state(std::move(value)), token(state == nullptr ? 0 : state->token) {}

    bool valid() const {
        return state != nullptr && token != 0 && state->token == token;
    }

    const std::shared_ptr<FailureState> state;
    const uint64_t token;
};

struct AssertionFailure final {};

class FailureSinkRegistry final {
public:
    bool begin(const std::shared_ptr<FailureState>& state) {
        if (state == nullptr || state->token == 0) {
            return false;
        }
        {
            std::lock_guard<std::mutex> stateLock(state->mutex);
            if (state->closed) {
                return false;
            }
        }
        std::lock_guard<std::mutex> lock(mutex_);
        return active_.emplace(state->token, state).second;
    }

    void end(const std::shared_ptr<FailureState>& state) {
        if (state == nullptr) {
            return;
        }
        {
            std::lock_guard<std::mutex> stateLock(state->mutex);
            state->closed = true;
        }
        std::lock_guard<std::mutex> lock(mutex_);
        const auto it = active_.find(state->token);
        if (it != active_.end() && it->second.lock() == state) {
            active_.erase(it);
        }
    }

    void recordOrphan(const char* file, int line, const char* expression) {
        std::lock_guard<std::mutex> lock(mutex_);
        ++orphanFailures_;
        if (firstOrphanFailure_.empty()) {
            firstOrphanFailure_ = std::string(file) + ":" + std::to_string(line) + ": " +
                                  expression;
        }
    }

    size_t orphanFailureCount() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return orphanFailures_;
    }

    std::string firstOrphanFailure() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return firstOrphanFailure_;
    }

private:
    mutable std::mutex mutex_;
    std::unordered_map<uint64_t, std::weak_ptr<FailureState>> active_;
    size_t orphanFailures_ = 0;
    std::string firstOrphanFailure_;
};

inline FailureSinkRegistry& failureSinkRegistry() {
    // A deferred test worker can outlive the test runner's stack during
    // process teardown. Keep the registry itself alive for that worker, while
    // each worker still owns its immutable case state below.
    static FailureSinkRegistry* registry = new FailureSinkRegistry();
    return *registry;
}

inline std::atomic<uint64_t>& nextFailureToken() {
    static std::atomic<uint64_t> next {1};
    return next;
}

inline std::shared_ptr<FailureState> makeFailureState() {
    return std::make_shared<FailureState>(
        nextFailureToken().fetch_add(1, std::memory_order_relaxed));
}

inline thread_local std::shared_ptr<const FailureSinkBinding> boundFailureSink;

class ScopedFailureSink final {
public:
    explicit ScopedFailureSink(std::shared_ptr<FailureState> state)
        : ScopedFailureSink(state == nullptr
                                ? nullptr
                                : std::make_shared<FailureSinkBinding>(std::move(state))) {}

    explicit ScopedFailureSink(std::shared_ptr<const FailureSinkBinding> binding)
        : previous_(std::move(boundFailureSink)), binding_(std::move(binding)) {
        boundFailureSink = binding_;
    }

    ~ScopedFailureSink() {
        boundFailureSink = std::move(previous_);
    }

    ScopedFailureSink(const ScopedFailureSink&) = delete;
    ScopedFailureSink& operator=(const ScopedFailureSink&) = delete;

private:
    std::shared_ptr<const FailureSinkBinding> previous_;
    std::shared_ptr<const FailureSinkBinding> binding_;
};

inline std::shared_ptr<FailureState> boundFailureState() {
    // The lookup is thread-local only.  It is never resolved through a
    // mutable process-global "current case"; late work keeps its original
    // binding and therefore can only report against its closed state.
    const auto binding = boundFailureSink;
    if (binding == nullptr || !binding->valid()) {
        return nullptr;
    }
    return binding->state;
}

inline void recordFailure(const char* file, int line, const char* expression,
                          const char* detail = nullptr,
                          bool failFastOnOwnerThread = true) {
    const auto state = boundFailureState();
    if (!state) {
        failureSinkRegistry().recordOrphan(file, line, expression);
        std::fprintf(stderr, "  FAIL outside test case: %s:%d: %s\n",
                     file, line, expression);
        return;
    }

    bool throwFailure = false;
    bool lateFailure = false;
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        lateFailure = state->closed;
        if (lateFailure) {
            ++state->lateFailures;
            if (state->firstLateFailure.empty()) {
                state->firstLateFailure = std::string(file) + ":" +
                                          std::to_string(line) + ": " + expression;
            }
        }
        if (!lateFailure && !state->failed) {
            state->failed = true;
            state->firstFailure = std::string(file) + ":" + std::to_string(line) + ": " +
                                  expression;
            if (detail != nullptr && detail[0] != '\0') {
                state->firstFailure += " (";
                state->firstFailure += detail;
                state->firstFailure += ")";
            }
        }
        throwFailure = failFastOnOwnerThread && !lateFailure &&
            std::this_thread::get_id() == state->ownerThread;
    }

    std::fprintf(stderr, "  %s case=%llu: %s:%d: %s%s%s\n",
                 lateFailure ? "LATE FAIL (orphan)" : "FAIL",
                 static_cast<unsigned long long>(state->token), file, line, expression,
                 detail == nullptr ? "" : " (",
                 detail == nullptr ? "" : detail);
    if (detail != nullptr) {
        std::fprintf(stderr, ")");
    }
    std::fprintf(stderr, "\n");

    // Owner-thread preconditions fail fast. Concurrent timing assertions use
    // the RDP_EXPECT macro below so the test can release its barriers first.
    if (throwFailure) {
        throw AssertionFailure {};
    }
}

inline void recordEqualityFailure(const char* file, int line, const char* left,
                                  const char* right, long long leftValue,
                                  long long rightValue,
                                  bool failFastOnOwnerThread = true) {
    char detail[128] = {};
    std::snprintf(detail, sizeof(detail), "%s != %s (%lld != %lld)", left, right,
                  leftValue, rightValue);
    recordFailure(file, line, detail, nullptr, failFastOnOwnerThread);
}

inline void recordUnexpectedException(const char* name) {
    recordFailure("test_runner", 0, name, "unexpected exception", false);
}

inline bool failed(FailureState& state, std::string& message) {
    std::lock_guard<std::mutex> lock(state.mutex);
    message = state.firstFailure;
    return state.failed;
}

} // namespace RdpTestDetail

class RdpTestThreadScope final {
public:
    explicit RdpTestThreadScope(std::function<void()> cancel)
        : RdpTestThreadScope(std::make_shared<int>(0), std::move(cancel)) {}

    RdpTestThreadScope(std::shared_ptr<void> lifetime, std::function<void()> cancel)
        : cancel_(std::move(cancel)),
          caseState_(RdpTestDetail::boundFailureState()),
          lifetime_(std::move(lifetime)) {}

    ~RdpTestThreadScope() {
        cancelAndJoin();
    }

    RdpTestThreadScope(const RdpTestThreadScope&) = delete;
    RdpTestThreadScope& operator=(const RdpTestThreadScope&) = delete;

    // Every worker receives an immutable case state. It cannot resolve a
    // later case through a mutable global registry.
    void start(std::function<void()> body) {
        startForState(caseState_, lifetime_, std::move(body));
    }

    void startForState(const std::shared_ptr<RdpTestDetail::FailureState>& state,
                       std::function<void()> body) {
        startForState(state, lifetime_, std::move(body));
    }

    void startForState(const std::shared_ptr<RdpTestDetail::FailureState>& state,
                       std::shared_ptr<void> lifetime,
                       std::function<void()> body) {
        if (state == nullptr || lifetime == nullptr) {
            RdpTestDetail::recordFailure(
                "test_runner", 0, "worker requires shared case lifetime", nullptr, false);
            return;
        }
        auto record = std::make_shared<ThreadRecord>();
        record->failureState = state;
        record->failureBinding =
            std::make_shared<RdpTestDetail::FailureSinkBinding>(state);
        record->caseToken = state->token;
        record->lifetime = std::move(lifetime);
        // Publish the record before starting its thread. If vector growth or
        // thread creation fails, the record owns no joinable thread and can
        // safely follow the ordinary test failure path.
        records_.push_back(record);
        try {
            record->thread = std::thread([record, body = std::move(body)]() mutable {
                // The worker owns the exact case state it was created for. It
                // may outlive the test case, but it can never bind a later case.
                try {
                    RdpTestDetail::ScopedFailureSink sink(record->failureBinding);
                    try {
                        body();
                    } catch (const RdpTestDetail::AssertionFailure&) {
                        try {
                            RdpTestDetail::recordFailure(
                                "test_runner", 0, "worker assertion", nullptr, false);
                        } catch (...) {
                        }
                    } catch (...) {
                        try {
                            RdpTestDetail::recordFailure(
                                "test_runner", 0, "worker exception", nullptr, false);
                        } catch (...) {
                        }
                    }
                } catch (...) {
                    // Failure reporting itself must not escape the worker. The
                    // completion fence below is the ownership handoff used by
                    // the deferred reaper.
                }
                record->markDone();
            });
        } catch (...) {
            record->markDone();
            RdpTestDetail::recordFailure(
                "test_runner", 0, "worker thread start failed", nullptr, false);
        }
    }

    bool cancelAndJoin() {
        if (cancelled_) {
            return allJoined_;
        }
        cancelled_ = true;
        allJoined_ = true;
        if (cancel_) {
            // Cancellation hooks may synchronously enter a native disconnect
            // path. Run them as another owned worker so the caller's budget
            // applies to cancellation too; the same deferred owner retains
            // the callback captures after a timeout.
            auto cancelBody = std::move(cancel_);
            cancel_ = nullptr;
            startForState(caseState_, lifetime_, std::move(cancelBody));
        }

        const auto deadline = std::chrono::steady_clock::now() + joinBudget_;
        for (const auto& record : records_) {
            if (record == nullptr || !record->thread.joinable()) {
                continue;
            }
            bool done = false;
            {
                std::unique_lock<std::mutex> lock(record->mutex);
                done = record->doneCv.wait_until(lock, deadline, [&]() {
                    return record->done;
                });
            }
            // The caller never joins directly. If the worker has not reached
            // its completion fence, transfer the shared record to the
            // process-scoped reaper and return after the bounded fence. The
            // reaper is the sole joiner and owns the worker's body captures
            // until the join completes.
            if (!done) {
                if (!DeferredThreadOwner::enqueue(record)) {
                    // Allocation failure in the process-scoped owner must not
                    // return a joinable thread to vector destruction. This is
                    // an exceptional emergency path; the worker is still
                    // joined exactly once before the record can be released.
                    if (record->thread.joinable()) {
                        record->thread.join();
                    }
                    RdpTestDetail::recordFailure(
                        "test_runner", 0, "worker deferred enqueue failed", nullptr, false);
                }
                RdpTestDetail::recordFailure(
                    "test_runner", 0,
                    "worker done fence timeout",
                    nullptr, false);
                allJoined_ = false;
                continue;
            }
            if (!DeferredThreadOwner::enqueueAndWait(record, deadline)) {
                if (record->thread.joinable()) {
                    record->thread.join();
                }
                RdpTestDetail::recordFailure(
                    "test_runner", 0, "worker join fence timeout", nullptr, false);
                allJoined_ = false;
            }
        }
        return allJoined_;
    }

private:
    struct ThreadRecord final {
        std::mutex mutex;
        std::condition_variable doneCv;
        bool done = false;
        std::shared_ptr<RdpTestDetail::FailureState> failureState;
        std::shared_ptr<const RdpTestDetail::FailureSinkBinding> failureBinding;
        uint64_t caseToken = 0;
        std::thread thread;
        std::shared_ptr<void> lifetime;
        std::atomic<bool> joinRequested {false};
        std::mutex joinedMutex;
        std::condition_variable joinedCv;
        bool joined = false;

        void markDone() noexcept {
            try {
                {
                    std::lock_guard<std::mutex> lock(mutex);
                    done = true;
                }
                doneCv.notify_all();
            } catch (...) {
                // A std::thread must never be destroyed while joinable. The
                // reaper retains this record even if diagnostic notification
                // fails, and the normal join path remains the owner of it.
            }
        }
    };

    class DeferredThreadOwner final {
    public:
        static bool enqueue(const std::shared_ptr<ThreadRecord>& record) noexcept {
            if (record == nullptr || record->joinRequested.load(std::memory_order_acquire)) {
                return record != nullptr;
            }
            try {
                owner().enqueueRecord(record);
                record->joinRequested.store(true, std::memory_order_release);
                return true;
            } catch (...) {
                // The caller reports the failure while the scope still owns
                // the record.  No exception may escape teardown and no
                // joinable std::thread may be destroyed by the reaper path.
                return false;
            }
        }

        static bool enqueueAndWait(const std::shared_ptr<ThreadRecord>& record,
                                   std::chrono::steady_clock::time_point deadline) {
            if (!enqueue(record)) {
                if (record->thread.joinable()) {
                    record->thread.join();
                }
                return false;
            }
            std::unique_lock<std::mutex> lock(record->joinedMutex);
            return record->joinedCv.wait_until(lock, deadline, [&]() {
                return record->joined;
            });
        }

    private:
        DeferredThreadOwner() : worker_([this]() { run(); }) {}

        static DeferredThreadOwner& owner() {
            // The owner is process-scoped and intentionally never destroyed:
            // a timeout may leave its joiner alive until a later done fence.
            static DeferredThreadOwner* instance = new DeferredThreadOwner();
            return *instance;
        }

        void enqueueRecord(const std::shared_ptr<ThreadRecord>& record) {
            {
                std::lock_guard<std::mutex> lock(mutex_);
                pending_.push_back(record);
            }
            cv_.notify_one();
        }

        void run() {
            for (;;) {
                std::shared_ptr<ThreadRecord> record;
                {
                    std::unique_lock<std::mutex> lock(mutex_);
                    cv_.wait(lock, [&]() { return !pending_.empty(); });
                    record = std::move(pending_.front());
                    pending_.pop_front();
                }
                bool done = false;
                {
                    std::lock_guard<std::mutex> lock(record->mutex);
                    done = record->done;
                }
                if (!done) {
                    {
                        std::lock_guard<std::mutex> lock(mutex_);
                        pending_.push_back(std::move(record));
                    }
                    cv_.notify_all();
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
                    continue;
                }
                // `done` is set by the worker's completion guard after its
                // body and exception handling have finished. This is the
                // only place that joins a deferred worker; the caller waits
                // only on the bounded joined fence.
                if (record->thread.joinable()) {
                    record->thread.join();
                }
                {
                    std::lock_guard<std::mutex> joinedLock(record->joinedMutex);
                    record->joined = true;
                }
                record->joinedCv.notify_all();
            }
        }

        std::mutex mutex_;
        std::condition_variable cv_;
        std::deque<std::shared_ptr<ThreadRecord>> pending_;
        std::thread worker_;
    };

    std::function<void()> cancel_;
    std::shared_ptr<RdpTestDetail::FailureState> caseState_;
    std::shared_ptr<void> lifetime_;
    std::vector<std::shared_ptr<ThreadRecord>> records_;
    bool cancelled_ = false;
    bool allJoined_ = true;
    static constexpr std::chrono::milliseconds joinBudget_ {1500};
};

namespace RdpTestDetail {

inline bool verifyFailureSinkTokenIsolation() {
    auto oldState = makeFailureState();
    auto nextState = makeFailureState();
    if (!failureSinkRegistry().begin(oldState)) {
        return false;
    }
    failureSinkRegistry().end(oldState);
    if (failureSinkRegistry().begin(oldState)) {
        failureSinkRegistry().end(oldState);
        return false;
    }
    if (!failureSinkRegistry().begin(nextState)) {
        return false;
    }

    auto release = std::make_shared<std::atomic<bool>>(false);
    RdpTestThreadScope workerScope(release, [release]() {
        release->store(true, std::memory_order_release);
    });
    workerScope.startForState(oldState, [release]() {
        while (!release->load(std::memory_order_acquire)) {
            std::this_thread::yield();
        }
        recordFailure("test_runner", 0, "late callback token probe", nullptr, false);
    });
    workerScope.cancelAndJoin();

    bool oldRecorded = false;
    bool nextUntouched = false;
    {
        std::lock_guard<std::mutex> oldLock(oldState->mutex);
        oldRecorded = oldState->closed && oldState->lateFailures == 1 &&
                      !oldState->failed;
    }
    {
        std::lock_guard<std::mutex> nextLock(nextState->mutex);
        nextUntouched = !nextState->failed;
    }
    failureSinkRegistry().end(nextState);
    return oldRecorded && nextUntouched;
}

} // namespace RdpTestDetail
#endif

// ---- 测试注册 ----
struct TestCase {
    const char* name;
    std::function<void()> func;
};

inline std::vector<TestCase>& testRegistry() {
    static std::vector<TestCase> registry;
    return registry;
}

#define RDP_TEST_CASE(name) \
    static void rdp_test_##name(); \
    static struct RdpTestReg_##name { \
        RdpTestReg_##name() { \
            testRegistry().push_back({#name, rdp_test_##name}); \
        } \
    } rdp_test_reg_##name; \
    static void rdp_test_##name()

// ---- 断言 ----
#if defined(RDP_CALLBACK_TEST_HARNESS)
#define RDP_ASSERT(cond) \
    do { if (!(cond)) { \
        RdpTestDetail::recordFailure(__FILE__, __LINE__, #cond); \
    } } while(0)

#define RDP_ASSERT_EQ(a, b) \
    do { \
        const auto rdp_assert_left = (a); \
        const auto rdp_assert_right = (b); \
        if (rdp_assert_left != rdp_assert_right) { \
            RdpTestDetail::recordEqualityFailure(__FILE__, __LINE__, #a, #b, \
                (long long)(rdp_assert_left), (long long)(rdp_assert_right)); \
        } \
    } while(0)

#define RDP_EXPECT(cond) \
    do { if (!(cond)) { \
        RdpTestDetail::recordFailure(__FILE__, __LINE__, #cond, nullptr, false); \
    } } while(0)

#define RDP_EXPECT_EQ(a, b) \
    do { \
        const auto rdp_expect_left = (a); \
        const auto rdp_expect_right = (b); \
        if (rdp_expect_left != rdp_expect_right) { \
            RdpTestDetail::recordEqualityFailure(__FILE__, __LINE__, #a, #b, \
                (long long)(rdp_expect_left), (long long)(rdp_expect_right), false); \
        } \
    } while(0)
#else
#define RDP_ASSERT(cond) \
    do { if (!(cond)) { \
        std::fprintf(stderr, "  FAIL: %s:%d: %s\n", __FILE__, __LINE__, #cond); \
        std::abort(); \
    } } while(0)

#define RDP_ASSERT_EQ(a, b) \
    do { if ((a) != (b)) { \
        std::fprintf(stderr, "  FAIL: %s:%d: %s == %s (%lld != %lld)\n", \
            __FILE__, __LINE__, #a, #b, (long long)(a), (long long)(b)); \
        std::abort(); \
    } } while(0)
#endif

// ---- 运行器 ----
inline int runAllTests(std::vector<RdpTestCaseResult>* results = nullptr) {
    (void)results;
#if defined(RDP_CALLBACK_TEST_HARNESS)
    static std::mutex runMutex;
    std::lock_guard<std::mutex> runLock(runMutex);
#endif
    auto& registry = testRegistry();
    int passed = 0, failed = 0;
#if defined(RDP_CALLBACK_TEST_HARNESS)
    const size_t orphanFailuresBefore =
        RdpTestDetail::failureSinkRegistry().orphanFailureCount();
#endif
    std::printf("Running %zu tests...\n", registry.size());
    for (auto& tc : registry) {
        std::printf("  %s ... ", tc.name);
#if defined(RDP_CALLBACK_TEST_HARNESS)
        auto failureState = RdpTestDetail::makeFailureState();
        failureState->ownerThread = std::this_thread::get_id();
        if (!RdpTestDetail::failureSinkRegistry().begin(failureState)) {
            RdpTestDetail::recordFailure(
                "test_runner", 0, "unique case token registration", nullptr, false);
        }
        RdpTestDetail::ScopedFailureSink caseSink(failureState);
#endif
        try {
            tc.func();
#if defined(RDP_CALLBACK_TEST_HARNESS)
            std::string failureMessage;
            const bool caseFailed = RdpTestDetail::failed(*failureState, failureMessage);
            RdpTestDetail::failureSinkRegistry().end(failureState);
            if (caseFailed) {
                std::printf("FAIL (%s)\n", failureMessage.c_str());
                ++failed;
                if (results != nullptr) {
                    results->push_back({tc.name, false, std::move(failureMessage)});
                }
                continue;
            }
#endif
            std::printf("OK\n");
            passed++;
#if defined(RDP_CALLBACK_TEST_HARNESS)
            if (results != nullptr) {
                results->push_back({tc.name, true, {}});
            }
#endif
        } catch (...) {
#if defined(RDP_CALLBACK_TEST_HARNESS)
            std::string existingFailure;
            if (!RdpTestDetail::failed(*failureState, existingFailure)) {
                RdpTestDetail::recordUnexpectedException(tc.name);
            }
            std::string failureMessage;
            (void)RdpTestDetail::failed(*failureState, failureMessage);
            RdpTestDetail::failureSinkRegistry().end(failureState);
            std::printf("FAIL (%s)\n", failureMessage.c_str());
            ++failed;
            if (results != nullptr) {
                results->push_back({tc.name, false, std::move(failureMessage)});
            }
#else
            std::printf("FAIL (exception)\n");
            failed++;
#endif
        }
    }
#if defined(RDP_CALLBACK_TEST_HARNESS)
    const size_t orphanFailuresAfter =
        RdpTestDetail::failureSinkRegistry().orphanFailureCount();
    if (orphanFailuresAfter != orphanFailuresBefore) {
        std::fprintf(stderr,
                     "ORPHAN callback failures=%zu first=%s\n",
                     orphanFailuresAfter - orphanFailuresBefore,
                     RdpTestDetail::failureSinkRegistry().firstOrphanFailure().c_str());
        ++failed;
    }
#endif
    std::printf("\n%d passed, %d failed, %zu total\n", passed, failed, registry.size());
    return failed;
}

#endif // TEST_RUNNER_H
