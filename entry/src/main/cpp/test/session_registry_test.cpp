#include "test_runner.h"
#include "extensions/session_registry.h"

#include <atomic>
#include <memory>
#include <thread>
#include <vector>

namespace {

struct ProbeSession {
    explicit ProbeSession(int value) : value(value) {}
    int value;
};

} // namespace

RDP_TEST_CASE(session_registry_reentrant_callback_can_erase_and_reinsert) {
    SessionRegistry<ProbeSession> registry;
    const int sessionId = 7;
    auto session = std::make_shared<ProbeSession>(42);
    registry.insertOrAssign(sessionId, session);

    // This models an adapter callback re-entering disconnect/erase. The
    // lookup keeps the context alive, while erase takes the registry mutex
    // independently; no recursive registry mutex is required.
    const auto callbackLookup = registry.find(sessionId);
    RDP_ASSERT(callbackLookup != registry.end());
    const auto callbackSession = callbackLookup->second;
    RDP_ASSERT(callbackSession != nullptr);
    RDP_ASSERT_EQ(callbackSession->value, 42);
    RDP_ASSERT(registry.eraseIf(sessionId, callbackSession));
    RDP_ASSERT(registry.find(sessionId) == registry.end());

    registry.insertOrAssign(sessionId, callbackSession);
    const auto snapshot = registry.snapshot();
    RDP_ASSERT_EQ(snapshot.size(), static_cast<size_t>(1));
    RDP_ASSERT(snapshot.front().second == callbackSession);
}

RDP_TEST_CASE(session_registry_event_erase_race_keeps_snapshots_safe) {
    SessionRegistry<ProbeSession> registry;
    constexpr int kWorkers = 4;
    constexpr int kIterations = 500;
    std::atomic<bool> start {false};
    std::atomic<int> failures {0};
    std::vector<std::thread> workers;
    workers.reserve(kWorkers);

    for (int worker = 0; worker < kWorkers; ++worker) {
        workers.emplace_back([&, worker]() {
            while (!start.load(std::memory_order_acquire)) {
                std::this_thread::yield();
            }
            for (int iteration = 0; iteration < kIterations; ++iteration) {
                const int sessionId = 100 + ((worker + iteration) % 3);
                auto session = std::make_shared<ProbeSession>(worker);
                registry.insertOrAssign(sessionId, session);
                const auto lookup = registry.find(sessionId);
                if (lookup != registry.end() && lookup->second == nullptr) {
                    failures.fetch_add(1, std::memory_order_relaxed);
                }
                (void)registry.eraseIf(sessionId, session);
                const auto copied = registry.snapshot();
                for (const auto& entry : copied) {
                    if (!entry.second) {
                        failures.fetch_add(1, std::memory_order_relaxed);
                    }
                }
            }
        });
    }
    start.store(true, std::memory_order_release);
    for (auto& worker : workers) {
        worker.join();
    }
    RDP_ASSERT_EQ(failures.load(std::memory_order_acquire), 0);
    registry.clear();
    RDP_ASSERT(registry.snapshot().empty());
}
