#include "extensions/native_network_observer_state.h"
#include "test_runner.h"

#include <atomic>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <thread>

namespace {

struct ObserverTestSession final {
    explicit ObserverTestSession(int value) : id(value) {}
    int id = 0;
};

} // namespace

RDP_TEST_CASE(native_network_observer_serializes_fence_before_late_target) {
    remotedesk::net::NativeNetworkObserverState<ObserverTestSession> state(1);
    RDP_ASSERT(state.track(10, 100, std::make_shared<ObserverTestSession>(10)));

    std::mutex barrierMutex;
    std::condition_variable barrier;
    bool fencePublished = false;
    bool releasePublisher = false;
    std::atomic<bool> publishedAvailable {true};
    std::atomic<uint64_t> publishedGeneration {0};
    std::atomic<bool> lateTargetTracked {false};
    remotedesk::net::NativeNetworkObserverState<ObserverTestSession>::DispatchSnapshot
        snapshot;

    std::thread publisher([&]() {
        snapshot = state.publishAvailability(false, [&](bool available, uint64_t generation) {
            publishedAvailable.store(available, std::memory_order_release);
            publishedGeneration.store(generation, std::memory_order_release);
            {
                std::lock_guard<std::mutex> lock(barrierMutex);
                fencePublished = true;
            }
            barrier.notify_all();
            std::unique_lock<std::mutex> lock(barrierMutex);
            barrier.wait(lock, [&]() { return releasePublisher; });
        });
    });
    {
        std::unique_lock<std::mutex> lock(barrierMutex);
        barrier.wait(lock, [&]() { return fencePublished; });
    }

    std::thread tracker([&]() {
        const bool tracked = state.track(
            20, 200, std::make_shared<ObserverTestSession>(20));
        lateTargetTracked.store(tracked, std::memory_order_release);
    });
    RDP_ASSERT(!lateTargetTracked.load(std::memory_order_acquire));

    {
        std::lock_guard<std::mutex> lock(barrierMutex);
        releasePublisher = true;
    }
    barrier.notify_all();
    publisher.join();
    tracker.join();

    RDP_ASSERT_EQ(snapshot.networkGeneration, static_cast<uint64_t>(2));
    RDP_ASSERT(!snapshot.observedDefaultAvailable);
    RDP_ASSERT(snapshot.routeAttemptAllowed);
    RDP_ASSERT(publishedAvailable.load(std::memory_order_acquire));
    RDP_ASSERT_EQ(
        publishedGeneration.load(std::memory_order_acquire),
        static_cast<uint64_t>(2));
    RDP_ASSERT_EQ(snapshot.targets.size(), static_cast<size_t>(1));
    RDP_ASSERT_EQ(snapshot.targets.front().first, 10);
    RDP_ASSERT(lateTargetTracked.load(std::memory_order_acquire));
    RDP_ASSERT_EQ(state.networkGeneration(), static_cast<uint64_t>(2));
    RDP_ASSERT_EQ(state.targetCount(), static_cast<size_t>(2));
}

RDP_TEST_CASE(native_network_observer_synchronous_initial_callback_precedes_track) {
    remotedesk::net::NativeNetworkObserverState<ObserverTestSession> state(7);
    state.addTransientConsumer();
    const auto initial = state.publishAvailability(true, [](bool, uint64_t) {});
    RDP_ASSERT(initial.targets.empty());
    RDP_ASSERT_EQ(initial.networkGeneration, static_cast<uint64_t>(8));

    RDP_ASSERT(state.installObserverIfAbsent(91));
    RDP_ASSERT(state.track(9, 90, std::make_shared<ObserverTestSession>(9)));
    RDP_ASSERT_EQ(state.releaseTransientConsumerAndTakeObserverIfIdle(), 0U);
    RDP_ASSERT_EQ(state.networkGeneration(), static_cast<uint64_t>(8));
    RDP_ASSERT_EQ(state.targetCount(), static_cast<size_t>(1));
    RDP_ASSERT_EQ(state.eraseExactAndTakeObserverIfIdle(9, 90), 91U);
}

RDP_TEST_CASE(native_network_observer_exact_teardown_waits_for_last_consumer) {
    remotedesk::net::NativeNetworkObserverState<ObserverTestSession> state;
    RDP_ASSERT(state.installObserverIfAbsent(77));
    RDP_ASSERT(!state.installObserverIfAbsent(88));
    state.addTransientConsumer();
    state.addTransientConsumer();
    RDP_ASSERT(state.track(7, 70, std::make_shared<ObserverTestSession>(7)));

    RDP_ASSERT_EQ(state.releaseTransientConsumerAndTakeObserverIfIdle(), 0U);
    RDP_ASSERT_EQ(state.releaseTransientConsumerAndTakeObserverIfIdle(), 0U);
    RDP_ASSERT_EQ(state.transientConsumerCount(), static_cast<size_t>(0));
    RDP_ASSERT_EQ(state.eraseExactAndTakeObserverIfIdle(7, 69), 0U);
    RDP_ASSERT_EQ(state.targetCount(), static_cast<size_t>(1));
    RDP_ASSERT_EQ(state.eraseExactAndTakeObserverIfIdle(7, 70), 77U);
    RDP_ASSERT_EQ(state.targetCount(), static_cast<size_t>(0));
    RDP_ASSERT(!state.hasObserver());
}
