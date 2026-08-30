#include "test_runner.h"
#include "ssh/ssh_operation_control.h"

#include <atomic>
#include <cassert>
#include <chrono>
#include <memory>
#include <thread>

RDP_TEST_CASE(ssh_operation_control_cancellation_is_level_triggered) {
    auto control = std::make_shared<SshOperationControl>(41);
    assert(control->cancel(SshOperationCancelReason::User));
    assert(!control->cancel(SshOperationCancelReason::Deadline));
    assert(control->cancelReason() == SshOperationCancelReason::User);

    std::atomic<int> callbacks {0};
    assert(control->bindTransportCancel([&callbacks]() {
        callbacks.fetch_add(1, std::memory_order_acq_rel);
    }));
    assert(callbacks.load(std::memory_order_acquire) == 1);
    control->finish();
    assert(!control->cancel(SshOperationCancelReason::Deadline));
    assert(!control->bindTransportCancel([]() {}));
}

RDP_TEST_CASE(ssh_operation_control_deadline_wakes_transport_once) {
    auto control = std::make_shared<SshOperationControl>(42);
    std::atomic<int> callbacks {0};
    assert(control->bindTransportCancel([&callbacks]() {
        callbacks.fetch_add(1, std::memory_order_acq_rel);
    }));

    std::thread watchdog([control]() {
        const bool finished = control->waitUntilFinishedOrCancelled(
            std::chrono::steady_clock::now() + std::chrono::milliseconds(20));
        assert(!finished);
        assert(control->cancel(SshOperationCancelReason::Deadline));
    });
    watchdog.join();
    assert(callbacks.load(std::memory_order_acquire) == 1);
    assert(control->cancelReason() == SshOperationCancelReason::Deadline);
    control->finish();
}

RDP_TEST_CASE(ssh_operation_control_network_change_is_level_triggered) {
    auto control = std::make_shared<SshOperationControl>(43);
    assert(control->cancel(SshOperationCancelReason::NetworkChanged));
    assert(control->cancelReason() == SshOperationCancelReason::NetworkChanged);

    std::atomic<int> callbacks {0};
    assert(control->bindTransportCancel([&callbacks]() {
        callbacks.fetch_add(1, std::memory_order_acq_rel);
    }));
    assert(callbacks.load(std::memory_order_acquire) == 1);
    control->finish();
}

RDP_TEST_CASE(ssh_operation_control_bind_cancel_race_delivers_once) {
    for (std::uint64_t iteration = 1; iteration <= 200; ++iteration) {
        auto control = std::make_shared<SshOperationControl>(10000 + iteration);
        std::atomic<int> callbacks {0};
        std::thread binder([control, &callbacks]() {
            assert(control->bindTransportCancel([&callbacks]() {
                callbacks.fetch_add(1, std::memory_order_acq_rel);
            }));
        });
        std::thread canceller([control]() {
            assert(control->cancel(SshOperationCancelReason::User));
        });
        binder.join();
        canceller.join();
        assert(callbacks.load(std::memory_order_acquire) == 1);
        control->finish();
    }
}

RDP_TEST_CASE(ssh_operation_registry_rejects_duplicates_and_stale_cleanup) {
    SshOperationRegistry registry;
    auto first = std::make_shared<SshOperationControl>(1001);
    auto duplicate = std::make_shared<SshOperationControl>(1001);
    assert(registry.insert(first));
    assert(!registry.insert(duplicate));
    assert(registry.size() == 1);
    assert(!registry.eraseIf(1001, duplicate));
    assert(registry.cancel(1001, SshOperationCancelReason::User));
    assert(!registry.cancel(1001, SshOperationCancelReason::Deadline));
    assert(registry.eraseIf(1001, first));
    assert(registry.size() == 0);
}
