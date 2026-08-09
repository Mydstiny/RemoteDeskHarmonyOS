#include "test_runner.h"
#include "extensions/disconnect_request_registry.h"

#include <atomic>
#include <thread>
#include <vector>

RDP_TEST_CASE(disconnect_request_registry_reentrant_snapshot_and_erase) {
    DisconnectRequestRegistry registry;
    registry.insertOrAssign(9, 101);
    RDP_ASSERT_EQ(registry.find(9), static_cast<std::uint64_t>(101));
    const auto snapshot = registry.snapshot();
    RDP_ASSERT_EQ(snapshot.size(), static_cast<size_t>(1));
    RDP_ASSERT(registry.eraseIf(snapshot.front().first, snapshot.front().second));
    RDP_ASSERT_EQ(registry.find(9), static_cast<std::uint64_t>(0));
}

RDP_TEST_CASE(disconnect_request_registry_connect_disconnect_event_race) {
    DisconnectRequestRegistry registry;
    std::atomic<bool> start {false};
    std::atomic<int> invalidSnapshots {0};
    std::vector<std::thread> workers;
    for (int worker = 0; worker < 4; ++worker) {
        workers.emplace_back([&, worker]() {
            while (!start.load(std::memory_order_acquire)) {
                std::this_thread::yield();
            }
            for (int iteration = 0; iteration < 500; ++iteration) {
                const int sessionId = 50 + ((worker + iteration) % 4);
                const std::uint64_t requestId = static_cast<std::uint64_t>(
                    1000 + worker * 500 + iteration);
                registry.insertOrAssign(sessionId, requestId);
                const auto snapshot = registry.snapshot();
                for (const auto& entry : snapshot) {
                    if (entry.first <= 0 || entry.second == 0) {
                        invalidSnapshots.fetch_add(1, std::memory_order_relaxed);
                    }
                }
                (void)registry.eraseIf(sessionId, requestId);
            }
        });
    }
    start.store(true, std::memory_order_release);
    for (auto& worker : workers) {
        worker.join();
    }
    RDP_ASSERT_EQ(invalidSnapshots.load(std::memory_order_acquire), 0);
    registry.clear();
    RDP_ASSERT_EQ(registry.size(), static_cast<size_t>(0));
}
