/**
 * video_perf_counters_test.cpp - video telemetry counter tests
 */

#include "test_runner.h"
#include "render/opaque_handle_registry.h"
#include "render/video_perf_counters.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <limits>
#include <mutex>
#include <thread>
#include <vector>

using Render::VideoPerfCounters;
using Render::VideoPressureController;
using Render::VideoPressureLevel;

RDP_TEST_CASE(video_perf_counters_snapshot_resets_after_read) {
    VideoPerfCounters counters;
    counters.recordIngressFrame("rustdesk", 1600, 900, 12000, true);
    counters.recordDecodeResult(0, 2, 1, 0);
    counters.recordRenderCostUs(6000, 3000, 2000, 11000);

    Render::VideoPerfSnapshot good = counters.snapshotAndReset();

    RDP_ASSERT_EQ(good.ingressFrames, 1ULL);
    RDP_ASSERT_EQ(good.decodeOk, 1ULL);
    RDP_ASSERT_EQ(good.keyframes, 1ULL);
    RDP_ASSERT_EQ(good.bytesTotal, 12000ULL);
    RDP_ASSERT(Render::classifyVideoPressure(good) == VideoPressureLevel::Normal);

    Render::VideoPerfSnapshot empty = counters.snapshotAndReset();

    RDP_ASSERT_EQ(empty.ingressFrames, 0ULL);
    RDP_ASSERT_EQ(empty.decodeOk, 0ULL);
    RDP_ASSERT_EQ(empty.renderFrames, 0ULL);
}

RDP_TEST_CASE(video_perf_counters_classifies_severe_pressure) {
    Render::VideoPerfSnapshot bad {};
    bad.ingressFrames = 60;
    bad.decodeQueueMax = 14;
    bad.decodeDrops = 20;
    bad.renderTotalMaxUs = 42000;

    RDP_ASSERT(Render::classifyVideoPressure(bad) == VideoPressureLevel::Severe);
}

RDP_TEST_CASE(video_perf_counters_use_drop_delta_per_window) {
    VideoPerfCounters counters;

    counters.recordDecodeResult(-1, 12, 5, 2);
    Render::VideoPerfSnapshot first = counters.snapshotAndReset();
    RDP_ASSERT_EQ(first.decodeDrops, 0ULL);
    RDP_ASSERT_EQ(first.decodeDropsTotal, 7ULL);

    // The decoder still reports its cumulative total. A new healthy window
    // must not inherit the historical seven drops.
    counters.recordDecodeResult(0, 0, 5, 2);
    Render::VideoPerfSnapshot healthy = counters.snapshotAndReset();
    RDP_ASSERT_EQ(healthy.decodeDrops, 0ULL);
    RDP_ASSERT_EQ(healthy.decodeDropsTotal, 7ULL);

    counters.recordDecodeResult(0, 0, 7, 2);
    Render::VideoPerfSnapshot next = counters.snapshotAndReset();
    RDP_ASSERT_EQ(next.decodeDrops, 2ULL);
    RDP_ASSERT_EQ(next.decodeDropsTotal, 9ULL);
}

RDP_TEST_CASE(video_perf_counters_first_sample_is_baseline) {
    VideoPerfCounters counters;

    counters.recordDecodeResult(0, 0, 100, 20, 7);
    const Render::VideoPerfSnapshot baseline = counters.snapshotAndReset();
    RDP_ASSERT_EQ(baseline.decodeDrops, 0ULL);
    RDP_ASSERT_EQ(baseline.inputDropsDelta, 0ULL);
    RDP_ASSERT_EQ(baseline.waitKeyframeDropsDelta, 0ULL);
    RDP_ASSERT_EQ(baseline.decodeDropsTotal, 120ULL);
    RDP_ASSERT_EQ(baseline.dropCounterGeneration, 7ULL);

    counters.recordDecodeResult(0, 0, 103, 22, 7);
    const Render::VideoPerfSnapshot delta = counters.snapshotAndReset();
    RDP_ASSERT_EQ(delta.decodeDrops, 5ULL);
    RDP_ASSERT_EQ(delta.inputDropsDelta, 3ULL);
    RDP_ASSERT_EQ(delta.waitKeyframeDropsDelta, 2ULL);
    RDP_ASSERT_EQ(delta.decodeDropsTotal, 125ULL);
}

RDP_TEST_CASE(video_perf_counters_handle_generation_reset_decrease_and_wrap) {
    VideoPerfCounters counters;

    counters.recordDecodeResult(0, 0, 10, 4, 1);
    (void)counters.snapshotAndReset();
    counters.recordDecodeResult(0, 0, 2, 1, 1);
    const Render::VideoPerfSnapshot reset = counters.snapshotAndReset();
    RDP_ASSERT_EQ(reset.decodeDrops, 0ULL);
    RDP_ASSERT_EQ(reset.dropCounterResets, 1ULL);
    RDP_ASSERT_EQ(reset.dropCounterGeneration, 2ULL);

    counters.recordDecodeResult(0, 0, 8, 3, 2);
    const Render::VideoPerfSnapshot recreated = counters.snapshotAndReset();
    RDP_ASSERT_EQ(recreated.decodeDrops, 0ULL);
    RDP_ASSERT_EQ(recreated.dropCounterGeneration, 2ULL);
    RDP_ASSERT_EQ(recreated.dropCounterResets, 1ULL);

    counters.recordDecodeResult(0, 0, std::numeric_limits<uint64_t>::max(), 0, 3);
    (void)counters.snapshotAndReset();
    counters.recordDecodeResult(0, 0, 0, 0, 3);
    const Render::VideoPerfSnapshot wrapped = counters.snapshotAndReset();
    RDP_ASSERT_EQ(wrapped.decodeDrops, 0ULL);
    RDP_ASSERT_EQ(wrapped.dropCounterResets, 1ULL);
    RDP_ASSERT_EQ(wrapped.dropCounterGeneration, 4ULL);

    counters.recordDecodeResult(0, 0, 1, std::numeric_limits<uint64_t>::max(), 4);
    (void)counters.snapshotAndReset();
    counters.recordDecodeResult(0, 0, 2, std::numeric_limits<uint64_t>::max(), 4);
    const Render::VideoPerfSnapshot saturated = counters.snapshotAndReset();
    RDP_ASSERT_EQ(saturated.decodeDrops, 1ULL);
    RDP_ASSERT_EQ(saturated.decodeDropsTotal, std::numeric_limits<uint64_t>::max());
}

RDP_TEST_CASE(video_perf_counters_reset_clears_same_window_delta) {
    VideoPerfCounters counters;

    counters.recordDecodeResult(0, 0, 0, 0, 41);
    counters.recordDecodeResult(-1, 12, 5, 2, 41);
    counters.recordDecodeResult(0, 0, 0, 0, 41);
    counters.recordDecodeResult(0, 0, 1, 0, 41);

    const Render::VideoPerfSnapshot snapshot = counters.snapshotAndReset();
    // 5 -> 0 is a reset in this same window. Only the post-reset 0 -> 1
    // sample belongs to the window; the earlier delta and decode error must
    // not survive the reset boundary.
    RDP_ASSERT_EQ(snapshot.inputDropsDelta, 1ULL);
    RDP_ASSERT_EQ(snapshot.waitKeyframeDropsDelta, 0ULL);
    RDP_ASSERT_EQ(snapshot.decodeDrops, 1ULL);
    RDP_ASSERT_EQ(snapshot.decodeErrors, 0ULL);
}

RDP_TEST_CASE(opaque_handle_registry_uses_monotonic_tokens_and_safe_leases) {
    OpaqueHandleRegistry<int> registry;
    const Render::DecoderSessionIdentity owner {41, 401, 4001};
    auto firstObject = std::make_shared<int>(7);
    const int64_t first = registry.registerObject(firstObject, owner);
    RDP_ASSERT(first > 0);
    RDP_ASSERT(first != reinterpret_cast<int64_t>(firstObject.get()));
    RDP_ASSERT(registry.activate(first, owner));

    auto lease = registry.acquire(first, owner);
    RDP_ASSERT(static_cast<bool>(lease));
    RDP_ASSERT_EQ(*lease.get(), 7);
    RDP_ASSERT(!registry.acquire(first, Render::DecoderSessionIdentity {42, 402, 4002}));

    lease = {};
    std::shared_ptr<int> destroyed = registry.destroy(first, owner);
    RDP_ASSERT(destroyed != nullptr);
    RDP_ASSERT(!registry.acquire(first, owner));
    RDP_ASSERT(registry.destroy(first, owner) == nullptr);

    auto secondObject = std::make_shared<int>(8);
    const int64_t second = registry.registerObject(secondObject, owner);
    RDP_ASSERT(second > first);
    RDP_ASSERT(registry.activate(second, owner));
    RDP_ASSERT(!registry.acquire(first, owner));
    RDP_ASSERT(registry.acquire(second, owner));
}

RDP_TEST_CASE(opaque_handle_registry_destroy_waits_for_callback_lease) {
    OpaqueHandleRegistry<int> registry;
    const Render::DecoderSessionIdentity owner {51, 501, 5001};
    const int64_t token = registry.registerObject(std::make_shared<int>(9), owner);
    RDP_ASSERT(registry.activate(token, owner));

    std::atomic<bool> entered {false};
    std::atomic<bool> release {false};
    std::thread callback([&]() {
        auto callbackLease = registry.acquire(token, owner);
        RDP_ASSERT(static_cast<bool>(callbackLease));
        entered.store(true, std::memory_order_release);
        while (!release.load(std::memory_order_acquire)) {
            std::this_thread::yield();
        }
    });
    while (!entered.load(std::memory_order_acquire)) {
        std::this_thread::yield();
    }

    std::atomic<bool> destroyed {false};
    std::thread teardown([&]() {
        destroyed.store(registry.destroy(token, owner) != nullptr, std::memory_order_release);
    });
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    RDP_ASSERT(!destroyed.load(std::memory_order_acquire));
    release.store(true, std::memory_order_release);
    callback.join();
    teardown.join();
    RDP_ASSERT(destroyed.load(std::memory_order_acquire));
    RDP_ASSERT(!registry.acquire(token, owner));
}

RDP_TEST_CASE(video_perf_counters_snapshot_is_consistent_under_concurrency) {
    VideoPerfCounters counters;
    std::atomic<bool> running {true};
    std::thread producer([&counters, &running]() {
        for (uint64_t i = 0; i < 2000; ++i) {
            counters.recordIngressFrame("rustdesk", 640, 360, 1024, (i % 60) == 0);
            counters.recordDecodeResult(i % 17 == 0 ? -1 : 0, i % 13, i, i / 4, 9);
        }
        running.store(false, std::memory_order_release);
    });
    uint64_t observedSamples = 0;
    while (running.load(std::memory_order_acquire)) {
        const Render::VideoPerfSnapshot snapshot = counters.snapshot();
        RDP_ASSERT(snapshot.decodeErrors <= snapshot.decodeSamples);
        RDP_ASSERT(snapshot.decodeDrops <= std::numeric_limits<uint64_t>::max());
        observedSamples += snapshot.decodeSamples;
    }
    producer.join();
    const Render::VideoPerfSnapshot finalSnapshot = counters.snapshotAndReset();
    RDP_ASSERT(finalSnapshot.decodeSamples > 0);
    RDP_ASSERT(observedSamples > 0);
}

RDP_TEST_CASE(video_perf_pressure_recovery_ignores_historical_drops) {
    using Clock = std::chrono::steady_clock;
    VideoPerfCounters counters;
    VideoPressureController controller(1, 1);
    const Clock::time_point start = Clock::time_point {};

    counters.recordDecodeResult(-1, 12, 10, 0);
    RDP_ASSERT(controller.observeAt(counters.snapshotAndReset(), start).level ==
               VideoPressureLevel::Severe);

    // Three clean windows recover severe -> moderate -> mild -> normal. The
    // cumulative decoder drop counter remains at ten throughout.
    const VideoPressureLevel expected[] = {
        VideoPressureLevel::Moderate,
        VideoPressureLevel::Mild,
        VideoPressureLevel::Normal,
    };
    for (int i = 0; i < 3; ++i) {
        counters.recordDecodeResult(0, 0, 10, 0);
        Render::VideoPerfSnapshot healthy = counters.snapshotAndReset();
        RDP_ASSERT_EQ(healthy.decodeDrops, 0ULL);
        RDP_ASSERT(Render::classifyVideoPressure(healthy) == VideoPressureLevel::Normal);
        RDP_ASSERT(controller.observeAt(
            healthy, start + std::chrono::seconds(i + 1)).level == expected[i]);
    }
    RDP_ASSERT(controller.level() == VideoPressureLevel::Normal);
}

RDP_TEST_CASE(video_pressure_default_recovers_within_ten_seconds) {
    using Clock = std::chrono::steady_clock;
    VideoPerfCounters counters;
    VideoPressureController controller;
    const Clock::time_point start = Clock::time_point {};

    for (int second = 0; second < 5; ++second) {
        counters.recordDecodeResult(-1, 12, 10, 0, 1);
        const Render::VideoPressureDecision decision = controller.observeAt(
            counters.snapshotAndReset(), start + std::chrono::seconds(second));
        if (second == 4) {
            RDP_ASSERT_EQ(decision.level, VideoPressureLevel::Severe);
        }
    }

    // The default clean debounce is three windows per level. Severe therefore
    // returns to normal in nine clean seconds, within the ten-second bound.
    for (int second = 5; second < 14; ++second) {
        counters.recordDecodeResult(0, 0, 10, 0, 1);
        const Render::VideoPressureDecision decision = controller.observeAt(
            counters.snapshotAndReset(), start + std::chrono::seconds(second));
        if (second == 13) {
            RDP_ASSERT_EQ(decision.level, VideoPressureLevel::Normal);
        }
    }
    RDP_ASSERT(controller.level() == VideoPressureLevel::Normal);
}

RDP_TEST_CASE(video_pressure_can_escalate_a_software_burst_without_changing_default_hardware_gate) {
    using Clock = std::chrono::steady_clock;
    const Clock::time_point start = Clock::time_point {};
    Render::VideoPerfSnapshot burst {};
    burst.decodeSamples = 30;
    burst.decodeQueueMax = 17;

    VideoPressureController hardwareController;
    const Render::VideoPressureDecision hardwareDecision =
        hardwareController.observeAt(burst, start);
    RDP_ASSERT(hardwareDecision.level == VideoPressureLevel::Normal);
    RDP_ASSERT(!hardwareDecision.changed);

    VideoPressureController softwareController;
    const Render::VideoPressureDecision softwareDecision =
        softwareController.observeAt(burst, start, true);
    RDP_ASSERT(softwareDecision.level == VideoPressureLevel::Severe);
    RDP_ASSERT(softwareDecision.changed);

    Render::VideoPerfSnapshot healthy {};
    healthy.decodeSamples = 1;
    for (int second = 1; second <= 2; ++second) {
        const Render::VideoPressureDecision recovering = softwareController.observeAt(
            healthy, start + std::chrono::seconds(second), true);
        RDP_ASSERT(recovering.level == VideoPressureLevel::Severe);
    }
    RDP_ASSERT(softwareController.observeAt(
        healthy, start + std::chrono::seconds(3), true).level ==
        VideoPressureLevel::Moderate);
}

RDP_TEST_CASE(video_perf_counters_are_session_scoped) {
    VideoPerfCounters firstSession;
    VideoPerfCounters secondSession;
    VideoPressureController firstPressure(1, 1);
    VideoPressureController secondPressure(1, 1);

    firstSession.recordDecodeResult(-1, 12, 10, 0);
    secondSession.recordDecodeResult(0, 0, 0, 0);

    const Render::VideoPerfSnapshot first = firstSession.snapshotAndReset();
    const Render::VideoPerfSnapshot second = secondSession.snapshotAndReset();
    RDP_ASSERT_EQ(first.decodeDrops, 0ULL);
    RDP_ASSERT_EQ(second.decodeDrops, 0ULL);
    RDP_ASSERT_EQ(second.decodeQueueMax, 0ULL);
    RDP_ASSERT(firstPressure.observe(first) == VideoPressureLevel::Severe);
    RDP_ASSERT(secondPressure.observe(second) == VideoPressureLevel::Normal);
    RDP_ASSERT(firstPressure.level() == VideoPressureLevel::Severe);

    secondSession.recordDecodeResult(0, 12, 0, 0);
    RDP_ASSERT_EQ(firstSession.snapshotAndReset().decodeQueueMax, 0ULL);
    RDP_ASSERT_EQ(secondSession.snapshotAndReset().decodeQueueMax, 12ULL);
}

RDP_TEST_CASE(video_pressure_uses_time_windows_and_disconnect_tick) {
    using Clock = std::chrono::steady_clock;
    const Clock::time_point start = Clock::time_point {};
    VideoPressureController controller(1, 1, std::chrono::seconds(1), std::chrono::seconds(2));
    Render::VideoPerfSnapshot bad {};
    bad.decodeSamples = 1;
    bad.decodeQueueMax = 12;
    const Render::VideoPressureDecision overloaded = controller.observeAt(bad, start);
    RDP_ASSERT(overloaded.windowComplete);
    RDP_ASSERT(overloaded.changed);
    RDP_ASSERT(overloaded.level == VideoPressureLevel::Severe);
    RDP_ASSERT(!controller.windowDue(start + std::chrono::milliseconds(500)));
    RDP_ASSERT(controller.windowDue(start + std::chrono::seconds(1)));

    const Render::VideoPressureDecision timedOut =
        controller.tick(start + std::chrono::seconds(3));
    RDP_ASSERT(timedOut.timedOut);
    RDP_ASSERT(controller.timedOut());

    Render::VideoPerfSnapshot healthy {};
    healthy.decodeSamples = 1;
    RDP_ASSERT(controller.observeAt(healthy, start + std::chrono::seconds(4)).level ==
               VideoPressureLevel::Moderate);
    RDP_ASSERT(controller.observeAt(healthy, start + std::chrono::seconds(5)).level ==
               VideoPressureLevel::Mild);
    RDP_ASSERT(controller.observeAt(healthy, start + std::chrono::seconds(6)).level ==
               VideoPressureLevel::Normal);
}

RDP_TEST_CASE(video_pressure_idle_timeout_does_not_create_decoder_pressure) {
    using Clock = std::chrono::steady_clock;
    const Clock::time_point start = Clock::time_point {};
    VideoPressureController controller(1, 1, std::chrono::seconds(1), std::chrono::seconds(2));

    Render::VideoPerfSnapshot healthy {};
    healthy.ingressFrames = 1;
    healthy.decodeSamples = 1;
    RDP_ASSERT(controller.observeAt(healthy, start).level == VideoPressureLevel::Normal);

    const Render::VideoPressureDecision idle = controller.tick(start + std::chrono::seconds(3));
    RDP_ASSERT(idle.timedOut);
    RDP_ASSERT(!idle.changed);
    RDP_ASSERT(idle.level == VideoPressureLevel::Normal);

    Render::VideoPerfSnapshot empty {};
    const Render::VideoPressureDecision stillIdle =
        controller.observeAt(empty, start + std::chrono::seconds(4));
    RDP_ASSERT(stillIdle.timedOut);
    RDP_ASSERT(!stillIdle.changed);
    RDP_ASSERT(stillIdle.level == VideoPressureLevel::Normal);
}

RDP_TEST_CASE(video_pressure_ingress_without_decode_still_escalates_after_timeout) {
    using Clock = std::chrono::steady_clock;
    const Clock::time_point start = Clock::time_point {};
    VideoPressureController controller(1, 1, std::chrono::seconds(1), std::chrono::seconds(2));

    Render::VideoPerfSnapshot healthy {};
    healthy.ingressFrames = 1;
    healthy.decodeSamples = 1;
    RDP_ASSERT(controller.observeAt(healthy, start).level == VideoPressureLevel::Normal);

    Render::VideoPerfSnapshot stalled {};
    stalled.ingressFrames = 1;
    const Render::VideoPressureDecision decision =
        controller.observeAt(stalled, start + std::chrono::seconds(3));
    RDP_ASSERT(decision.timedOut);
    RDP_ASSERT(decision.changed);
    RDP_ASSERT(decision.level == VideoPressureLevel::Severe);
}

RDP_TEST_CASE(video_session_owner_gate_rejects_teardown_reconnect_and_cross_session_callbacks) {
    Render::VideoSessionOwnerGate gate;
    const Render::DecoderSessionIdentity first {11, 101, 1001};
    const Render::DecoderSessionIdentity staleGeneration {11, 102, 1001};
    const Render::DecoderSessionIdentity second {12, 103, 1002};

    RDP_ASSERT(gate.activate(first));
    RDP_ASSERT(gate.accepts(first));
    RDP_ASSERT(!gate.accepts(staleGeneration));
    RDP_ASSERT(!gate.accepts(second));
    RDP_ASSERT(!gate.deactivateIfActive(staleGeneration));

    RDP_ASSERT(gate.activate(second));
    RDP_ASSERT(!gate.accepts(first));
    RDP_ASSERT(!gate.deactivateIfActive(first));
    RDP_ASSERT(gate.accepts(second));
    RDP_ASSERT(gate.deactivateIfActive(second));
    RDP_ASSERT(!gate.accepts(second));
}

RDP_TEST_CASE(video_session_owner_gate_is_safe_for_concurrent_stale_callbacks) {
    Render::VideoSessionOwnerGate gate;
    const Render::DecoderSessionIdentity current {21, 201, 2001};
    const Render::DecoderSessionIdentity stale {20, 199, 1999};
    RDP_ASSERT(gate.activate(current));

    std::atomic<uint64_t> staleAccepted {0};
    std::vector<std::thread> readers;
    for (int i = 0; i < 8; ++i) {
        readers.emplace_back([&gate, &stale, &staleAccepted]() {
            for (int attempt = 0; attempt < 1000; ++attempt) {
                if (gate.accepts(stale)) {
                    staleAccepted.fetch_add(1, std::memory_order_relaxed);
                }
            }
        });
    }
    for (std::thread& reader : readers) {
        reader.join();
    }
    RDP_ASSERT_EQ(staleAccepted.load(std::memory_order_acquire), 0ULL);
    RDP_ASSERT(gate.accepts(current));
}

RDP_TEST_CASE(video_shared_owner_lease_barriers_cross_protocol_sink_and_stale_teardown) {
    Render::SessionSinkOwnerLease& registry = Render::SharedSessionSinkOwnerLease();
    const Render::DecoderSessionIdentity existing = registry.snapshot();
    if (existing.valid()) {
        RDP_ASSERT(registry.deactivateIfActive(existing));
    }

    const Render::DecoderSessionIdentity first {31, 301, 3001};
    const Render::DecoderSessionIdentity second {32, 302, 3002};
    RDP_ASSERT(registry.activate(first));

    std::atomic<bool> sinkEntered {false};
    std::atomic<bool> releaseSink {false};
    std::atomic<uint64_t> firstSinkWrites {0};
    std::thread firstSink([&]() {
        auto lease = registry.acquire(first);
        RDP_ASSERT(static_cast<bool>(lease));
        sinkEntered.store(true, std::memory_order_release);
        while (!releaseSink.load(std::memory_order_acquire)) {
            std::this_thread::yield();
        }
        // This stands for the renderer/player/pressure write. The shared
        // lease keeps it bound to first while the next session waits.
        firstSinkWrites.fetch_add(1, std::memory_order_release);
    });
    while (!sinkEntered.load(std::memory_order_acquire)) {
        std::this_thread::yield();
    }

    std::atomic<bool> secondActivated {false};
    std::thread activateSecond([&]() {
        secondActivated.store(registry.activate(second), std::memory_order_release);
    });
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    RDP_ASSERT(!secondActivated.load(std::memory_order_acquire));
    releaseSink.store(true, std::memory_order_release);
    firstSink.join();
    activateSecond.join();

    RDP_ASSERT_EQ(firstSinkWrites.load(std::memory_order_acquire), 1ULL);
    RDP_ASSERT(secondActivated.load(std::memory_order_acquire));
    RDP_ASSERT(!registry.acquire(first));
    RDP_ASSERT(registry.acquire(second));
    RDP_ASSERT(!registry.deactivateIfActive(first));
    RDP_ASSERT(registry.snapshot() == second);
    RDP_ASSERT(registry.deactivateIfActive(second));
}

RDP_TEST_CASE(video_shared_owner_lease_two_phase_transition_has_no_partial_sink) {
    Render::SessionSinkOwnerLease& registry = Render::SharedSessionSinkOwnerLease();
    const Render::DecoderSessionIdentity existing = registry.snapshot();
    if (existing.valid()) {
        RDP_ASSERT(registry.deactivateIfActive(existing));
    }

    const Render::DecoderSessionIdentity first {61, 601, 6001};
    const Render::DecoderSessionIdentity second {62, 602, 6002};
    RDP_ASSERT(registry.activate(first));

    auto callbackLease = registry.acquire(first);
    RDP_ASSERT(static_cast<bool>(callbackLease));
    std::atomic<bool> teardownFinished {false};
    std::thread teardown([&]() {
        auto exclusive = registry.acquireExclusive();
        const bool began = exclusive.beginDeactivate(first);
        teardownFinished.store(began, std::memory_order_release);
    });
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    RDP_ASSERT(!teardownFinished.load(std::memory_order_acquire));
    callbackLease = Render::SessionSinkOwnerLease::Lease();
    teardown.join();
    RDP_ASSERT(teardownFinished.load(std::memory_order_acquire));
    RDP_ASSERT(!registry.accepts(first));

    {
        auto exclusive = registry.acquireExclusive();
        RDP_ASSERT(exclusive.beginActivate(second));
    }
    // The activation owner is visible to the transition code but is not a
    // valid sink until the second phase commits it.
    RDP_ASSERT(!registry.accepts(second));
    RDP_ASSERT(!registry.acquire(second));
    {
        auto exclusive = registry.acquireExclusive();
        RDP_ASSERT(exclusive.commit(second));
    }
    RDP_ASSERT(registry.accepts(second));
    RDP_ASSERT(registry.deactivateIfActive(second));
}

RDP_TEST_CASE(video_shared_owner_begin_activate_rejects_second_live_owner) {
    Render::SessionSinkOwnerLease registry;
    const Render::DecoderSessionIdentity first {63, 603, 6003};
    const Render::DecoderSessionIdentity second {64, 604, 6004};

    {
        auto exclusive = registry.acquireExclusive();
        RDP_ASSERT(exclusive.beginActivate(first));
        RDP_ASSERT(exclusive.commit(first));
    }
    {
        auto exclusive = registry.acquireExclusive();
        RDP_ASSERT(!exclusive.beginActivate(second));
        RDP_ASSERT(exclusive.accepts(first));
        RDP_ASSERT(!exclusive.accepts(second));
        RDP_ASSERT(exclusive.activeSnapshot() == first);
    }
    RDP_ASSERT(registry.snapshot() == first);
    RDP_ASSERT(registry.acquire(first));
    RDP_ASSERT(!registry.acquire(second));
}

RDP_TEST_CASE(rdp_callback_owner_lease_covers_source_damage_and_queue_submit) {
    Render::SessionSinkOwnerLease& registry = Render::SharedSessionSinkOwnerLease();
    const Render::DecoderSessionIdentity existing = registry.snapshot();
    if (existing.valid()) {
        RDP_ASSERT(registry.deactivateIfActive(existing));
    }

    const Render::DecoderSessionIdentity owner {71, 701, 7001};
    RDP_ASSERT(registry.activate(owner));
    std::atomic<bool> sourceRead {false};
    std::atomic<bool> damageStaged {false};
    std::atomic<bool> queueSubmitted {false};
    std::atomic<bool> releaseCallback {false};
    std::atomic<bool> teardownFinished {false};

    std::thread callback([&]() {
        auto lease = registry.acquire(owner);
        RDP_ASSERT(static_cast<bool>(lease));
        sourceRead.store(true, std::memory_order_release);
        damageStaged.store(true, std::memory_order_release);
        while (!releaseCallback.load(std::memory_order_acquire)) {
            std::this_thread::yield();
        }
        // cbEndPaint must not release the owner between these three stages.
        queueSubmitted.store(true, std::memory_order_release);
    });
    while (!damageStaged.load(std::memory_order_acquire)) {
        std::this_thread::yield();
    }

    std::thread teardown([&]() {
        auto exclusive = registry.acquireExclusive();
        teardownFinished.store(exclusive.beginDeactivate(owner), std::memory_order_release);
    });
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    RDP_ASSERT(!teardownFinished.load(std::memory_order_acquire));
    RDP_ASSERT(!queueSubmitted.load(std::memory_order_acquire));
    releaseCallback.store(true, std::memory_order_release);
    callback.join();
    teardown.join();
    RDP_ASSERT(sourceRead.load(std::memory_order_acquire));
    RDP_ASSERT(damageStaged.load(std::memory_order_acquire));
    RDP_ASSERT(queueSubmitted.load(std::memory_order_acquire));
    RDP_ASSERT(teardownFinished.load(std::memory_order_acquire));
    RDP_ASSERT(!registry.accepts(owner));
}
