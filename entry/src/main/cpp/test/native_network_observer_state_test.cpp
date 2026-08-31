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
    const auto baseline = state.observeAvailability(
        true, 41, true, [](bool, uint64_t) {});
    RDP_ASSERT(!baseline.generationAdvanced);

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
        snapshot = state.observeAvailability(
            false, 41, true, [&](bool available, uint64_t generation) {
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
    RDP_ASSERT(snapshot.generationAdvanced);
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
    const auto initial = state.observeAvailability(
        true, 91, true, [](bool, uint64_t) {});
    RDP_ASSERT(initial.targets.empty());
    RDP_ASSERT(!initial.generationAdvanced);
    RDP_ASSERT_EQ(initial.networkGeneration, static_cast<uint64_t>(7));

    RDP_ASSERT(state.installObserverIfAbsent(91));
    RDP_ASSERT(state.track(9, 90, std::make_shared<ObserverTestSession>(9)));
    RDP_ASSERT_EQ(state.releaseTransientConsumerAndTakeObserverIfIdle(), 0U);
    RDP_ASSERT_EQ(state.networkGeneration(), static_cast<uint64_t>(7));
    RDP_ASSERT_EQ(state.targetCount(), static_cast<size_t>(1));
    RDP_ASSERT_EQ(state.eraseExactAndTakeObserverIfIdle(9, 90), 91U);
}

RDP_TEST_CASE(native_network_observer_ignores_same_network_callback_burst) {
    remotedesk::net::NativeNetworkObserverState<ObserverTestSession> state(20);
    size_t publishCount = 0;
    const auto publish = [&](bool, uint64_t) { ++publishCount; };

    const auto initial = state.observeAvailability(true, 300, true, publish);
    const auto duplicate = state.observeAvailability(true, 300, true, publish);
    const auto identityRefinement = state.observeAvailability(
        true, 0, false, publish);

    RDP_ASSERT(!initial.generationAdvanced);
    RDP_ASSERT(!duplicate.generationAdvanced);
    RDP_ASSERT(!identityRefinement.generationAdvanced);
    RDP_ASSERT_EQ(publishCount, static_cast<size_t>(0));
    RDP_ASSERT_EQ(state.networkGeneration(), static_cast<uint64_t>(20));
}

RDP_TEST_CASE(native_network_observer_advances_only_for_real_identity_transition) {
    remotedesk::net::NativeNetworkObserverState<ObserverTestSession> state(30);
    size_t publishCount = 0;
    const auto publish = [&](bool available, uint64_t) {
        RDP_ASSERT(available);
        ++publishCount;
    };

    RDP_ASSERT(!state.observeAvailability(
        true, 400, true, publish).generationAdvanced);
    const auto replacement = state.observeAvailability(
        true, 401, true, publish);
    RDP_ASSERT(replacement.generationAdvanced);
    RDP_ASSERT_EQ(replacement.networkGeneration, static_cast<uint64_t>(31));
    RDP_ASSERT_EQ(replacement.networkId, 401);

    const auto staleLost = state.observeAvailability(
        false, 400, true, publish);
    RDP_ASSERT(!staleLost.generationAdvanced);
    RDP_ASSERT(staleLost.observedDefaultAvailable);

    const auto activeLost = state.observeAvailability(
        false, 401, true, publish);
    RDP_ASSERT(activeLost.generationAdvanced);
    RDP_ASSERT(!activeLost.observedDefaultAvailable);
    RDP_ASSERT_EQ(activeLost.networkGeneration, static_cast<uint64_t>(32));

    RDP_ASSERT(!state.observeAvailability(
        false, 0, false, publish).generationAdvanced);
    const auto restored = state.observeAvailability(
        true, 401, true, publish);
    RDP_ASSERT(restored.generationAdvanced);
    RDP_ASSERT_EQ(restored.networkGeneration, static_cast<uint64_t>(33));
    RDP_ASSERT_EQ(publishCount, static_cast<size_t>(3));
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
