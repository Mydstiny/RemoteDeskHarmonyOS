#include "ssh/ssh_forward_target_connector.h"
#include "test_runner.h"

#include <atomic>
#include <cerrno>
#include <chrono>
#include <thread>

RDP_TEST_CASE(ssh_remote_forward_blackhole_does_not_block_owner_progress) {
    using namespace std::chrono_literals;

    std::atomic<bool> workerStarted{false};
    SshForwardTargetConnectTask task;
    const auto start = std::chrono::steady_clock::now();
    RDP_ASSERT(task.startForTest(
        [&workerStarted](const std::shared_ptr<std::atomic<bool>>& cancellation) {
            workerStarted.store(true, std::memory_order_release);
            while (!cancellation->load(std::memory_order_acquire)) {
                std::this_thread::sleep_for(5ms);
            }
            return SshForwardTargetConnectResult{-1, ECANCELED};
        }));
    RDP_ASSERT(std::chrono::steady_clock::now() - start < 100ms);

    // This loop stands in for terminal, keepalive, and relay slices owned by
    // the reactor. A blackholed target remains pending while owner work keeps
    // advancing instead of waiting for the target deadline.
    std::size_t ownerSlices = 0;
    const auto progressDeadline = std::chrono::steady_clock::now() + 100ms;
    while (std::chrono::steady_clock::now() < progressDeadline) {
        ++ownerSlices;
        std::this_thread::sleep_for(2ms);
    }
    RDP_ASSERT(workerStarted.load(std::memory_order_acquire));
    RDP_ASSERT(ownerSlices >= 20U);
    RDP_ASSERT(task.pending());
    RDP_ASSERT(!task.ready());

    const auto cancelStart = std::chrono::steady_clock::now();
    task.cancelAndClose();
    RDP_ASSERT(std::chrono::steady_clock::now() - cancelStart < 250ms);
    RDP_ASSERT(!task.pending());
}
