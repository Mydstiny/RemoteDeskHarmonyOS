#include "test_runner.h"
#include "render/callback_admission_context.h"
#include "render/opaque_handle_registry.h"
#include "render/platform_lifecycle.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <thread>

namespace {

Render::DecoderSessionIdentity owner(uint64_t session, uint64_t generation,
                                     uint64_t token) {
    return Render::DecoderSessionIdentity {session, generation, token};
}

struct TestSink {
    explicit TestSink(int value) : value(value) {}
    int value;
};

} // namespace

RDP_TEST_CASE(ohaudio_pull_user_data_pause_then_destroy_has_no_write) {
    const auto s1 = owner(1, 1, 101);
    auto context = std::make_shared<Render::CallbackAdmissionContext>();
    RDP_ASSERT(context->bind(11, s1, s1.generation));
    auto* stableUserData = context.get();
    std::mutex stateMutex;
    std::condition_variable stateCv;
    bool userDataSeen = false;
    bool teardownFinished = false;
    std::atomic<int> sinkWrites {0};

    std::thread lateCallback([&]() {
        // This is the exact platform ordering: userData was delivered, but
        // the callback has not entered the admission gate yet.
        RDP_ASSERT(stableUserData != nullptr);
        {
            std::lock_guard<std::mutex> lock(stateMutex);
            userDataSeen = true;
        }
        stateCv.notify_all();
        std::unique_lock<std::mutex> lock(stateMutex);
        stateCv.wait(lock, [&]() { return teardownFinished; });
        lock.unlock();

        auto lease = stableUserData->tryAcquire();
        if (lease) {
            sinkWrites.fetch_add(1);
        }
    });

    {
        std::unique_lock<std::mutex> lock(stateMutex);
        RDP_ASSERT(stateCv.wait_for(lock, std::chrono::seconds(1),
                                    [&]() { return userDataSeen; }));
    }
    context->closeAndWait();
    {
        std::lock_guard<std::mutex> lock(stateMutex);
        teardownFinished = true;
    }
    stateCv.notify_all();
    lateCallback.join();
    RDP_ASSERT_EQ(sinkWrites.load(), 0);

    // The retired context remains a valid raw userData object and repeated
    // destroy/late-callback admission stays inert.
    context->closeAndWait();
    RDP_ASSERT(!context->tryAcquire());
}

RDP_TEST_CASE(codec_callback_admission_waits_for_inflight_before_destroy) {
    const auto s1 = owner(1, 4, 104);
    Render::CallbackAdmissionContext context;
    RDP_ASSERT(context.bind(14, s1, s1.generation));
    std::mutex stateMutex;
    std::condition_variable stateCv;
    bool entered = false;
    bool release = false;

    std::thread callback([&]() {
        auto lease = context.tryAcquire();
        RDP_ASSERT(lease);
        RDP_ASSERT_EQ(lease.snapshot().token, 14);
        RDP_ASSERT(lease.snapshot().owner == s1);
        {
            std::lock_guard<std::mutex> lock(stateMutex);
            entered = true;
        }
        stateCv.notify_all();
        std::unique_lock<std::mutex> lock(stateMutex);
        stateCv.wait(lock, [&]() { return release; });
    });
    {
        std::unique_lock<std::mutex> lock(stateMutex);
        RDP_ASSERT(stateCv.wait_for(lock, std::chrono::seconds(1),
                                    [&]() { return entered; }));
    }

    std::atomic<bool> teardownFinished {false};
    std::thread teardown([&]() {
        context.closeAndWait();
        teardownFinished.store(true);
    });
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    RDP_ASSERT(!teardownFinished.load());
    {
        std::lock_guard<std::mutex> lock(stateMutex);
        release = true;
    }
    stateCv.notify_all();
    callback.join();
    teardown.join();
    RDP_ASSERT(teardownFinished.load());
    RDP_ASSERT(!context.tryAcquire());
}

RDP_TEST_CASE(old_session_context_cannot_admit_after_reconnect) {
    const auto s1 = owner(1, 9, 109);
    const auto s2 = owner(2, 1, 201);
    auto oldContext = std::make_shared<Render::CallbackAdmissionContext>();
    RDP_ASSERT(oldContext->bind(19, s1, s1.generation));
    auto* oldUserData = oldContext.get();
    oldContext->closeAndWait();

    auto newContext = std::make_shared<Render::CallbackAdmissionContext>();
    RDP_ASSERT(newContext->bind(20, s2, s2.generation));
    auto oldLease = oldUserData->tryAcquire();
    RDP_ASSERT(!oldLease);
    auto newLease = newContext->tryAcquire();
    RDP_ASSERT(newLease);
    RDP_ASSERT(newLease.snapshot().owner == s2);
    RDP_ASSERT_EQ(newLease.snapshot().token, 20);
}

RDP_TEST_CASE(two_callback_contexts_keep_session_generations_isolated) {
    const auto s1 = owner(11, 3, 303);
    const auto s2 = owner(22, 7, 707);
    Render::CallbackAdmissionContext context1;
    Render::CallbackAdmissionContext context2;
    RDP_ASSERT(context1.bind(31, s1, s1.generation));
    RDP_ASSERT(context2.bind(32, s2, s2.generation));
    auto lease1 = context1.tryAcquire();
    auto lease2 = context2.tryAcquire();
    RDP_ASSERT(lease1 && lease2);
    RDP_ASSERT(lease1.snapshot().owner == s1);
    RDP_ASSERT(lease2.snapshot().owner == s2);
    RDP_ASSERT(lease1.snapshot().owner != lease2.snapshot().owner);
    RDP_ASSERT_EQ(lease1.snapshot().generation, s1.generation);
    RDP_ASSERT_EQ(lease2.snapshot().generation, s2.generation);
}

RDP_TEST_CASE(public_registry_tokens_reject_old_generation_and_address_reuse) {
    OpaqueHandleRegistry<TestSink> registry;
    const auto s1 = owner(1, 1, 1);
    const auto s2 = owner(2, 1, 2);
    const int64_t oldToken = registry.registerObject(
        std::make_shared<TestSink>(1), s1);
    RDP_ASSERT(oldToken > 0);
    auto oldLease = registry.acquire(oldToken, s1);
    RDP_ASSERT(oldLease);
    RDP_ASSERT(!registry.acquire(oldToken, s2));
    oldLease = {};
    RDP_ASSERT(registry.destroy(oldToken, s1));

    // The object may be allocator-reused, but the public token is not.
    const int64_t newToken = registry.registerObject(
        std::make_shared<TestSink>(2), s2);
    RDP_ASSERT(newToken > oldToken);
    RDP_ASSERT(!registry.acquire(oldToken, s1));
    RDP_ASSERT(!registry.bind(oldToken, s2));
    auto newLease = registry.acquire(newToken, s2);
    RDP_ASSERT(newLease);
    RDP_ASSERT_EQ(newLease->value, 2);
}

RDP_TEST_CASE(platform_lifecycle_destroy_invalidates_paused_init) {
    Render::PlatformLifecycle lifecycle;
    const auto init = lifecycle.beginInit();
    RDP_ASSERT(init.valid);

    std::atomic<bool> destroyRequested {false};
    std::thread destroy([&]() {
        const auto destroyToken = lifecycle.beginDestroy();
        destroyRequested.store(destroyToken.valid, std::memory_order_release);
        if (destroyToken.valid && !destroyToken.deferredToInitOwner) {
            lifecycle.finishDestroy(destroyToken);
        }
    });
    for (int i = 0; i < 1000 && !lifecycle.destroyRequested(); ++i) {
        std::this_thread::yield();
    }
    RDP_ASSERT(lifecycle.destroyRequested());

    const auto completion = lifecycle.completeInit(init, true);
    RDP_ASSERT(completion == Render::PlatformLifecycle::InitCompletion::DestroyRequested);
    destroy.join();
    RDP_ASSERT(destroyRequested.load(std::memory_order_acquire));
    RDP_ASSERT(lifecycle.state() == Render::PlatformLifecycle::State::DESTROYED);
}

RDP_TEST_CASE(platform_lifecycle_nested_destroy_defers_to_init_owner) {
    Render::PlatformLifecycle lifecycle;
    const auto init = lifecycle.beginInit();
    RDP_ASSERT(init.valid);

    // A platform callback may synchronously request teardown while Init owns
    // the transition. It must mark cancellation without waiting on itself.
    const auto destroy = lifecycle.beginDestroy();
    RDP_ASSERT(destroy.valid);
    RDP_ASSERT(destroy.deferredToInitOwner);
    const auto completion = lifecycle.completeInit(init, true);
    RDP_ASSERT(completion ==
        Render::PlatformLifecycle::InitCompletion::DestroyDeferredToInitOwner);
    RDP_ASSERT(lifecycle.finishDestroy(destroy));
    RDP_ASSERT(lifecycle.state() == Render::PlatformLifecycle::State::DESTROYED);
}

RDP_TEST_CASE(platform_lifecycle_failed_init_can_retry_but_destroy_is_terminal) {
    Render::PlatformLifecycle lifecycle;
    const auto failedInit = lifecycle.beginInit();
    RDP_ASSERT(failedInit.valid);
    RDP_ASSERT(lifecycle.completeInit(failedInit, false) ==
        Render::PlatformLifecycle::InitCompletion::Failed);

    const auto retry = lifecycle.beginInit();
    RDP_ASSERT(retry.valid);
    RDP_ASSERT(lifecycle.completeInit(retry, true) ==
        Render::PlatformLifecycle::InitCompletion::Published);

    const auto destroy = lifecycle.beginDestroy();
    RDP_ASSERT(destroy.valid);
    RDP_ASSERT(!destroy.deferredToInitOwner);
    RDP_ASSERT(lifecycle.finishDestroy(destroy));
    RDP_ASSERT(!lifecycle.beginInit().valid);
    RDP_ASSERT(!lifecycle.beginDestroy().valid);
}

RDP_TEST_CASE(platform_lifecycle_stress_has_no_retired_transition_state) {
    Render::PlatformLifecycle lifecycle;
    for (int i = 0; i < 10000; ++i) {
        const auto init = lifecycle.beginInit();
        RDP_ASSERT(init.valid);
        RDP_ASSERT(lifecycle.completeInit(init, false) ==
            Render::PlatformLifecycle::InitCompletion::Failed);
    }
    RDP_ASSERT(lifecycle.state() == Render::PlatformLifecycle::State::FAILED);
    const auto destroy = lifecycle.beginDestroy();
    RDP_ASSERT(destroy.valid);
    RDP_ASSERT(lifecycle.finishDestroy(destroy));
    RDP_ASSERT(lifecycle.state() == Render::PlatformLifecycle::State::DESTROYED);
}

RDP_TEST_CASE(callback_context_create_destroy_has_bounded_live_high_water) {
    size_t peak = Render::CallbackAdmissionContext::liveCount();
    const auto session = owner(77, 1, 7701);
    for (int i = 0; i < 10000; ++i) {
        auto context = std::make_shared<Render::CallbackAdmissionContext>();
        RDP_ASSERT(context->bind(static_cast<int64_t>(i + 1), session,
                                 session.generation));
        context->closeAndWait();
        peak = std::max(peak, Render::CallbackAdmissionContext::liveCount());
    }
    RDP_ASSERT(peak <= 1);
    RDP_ASSERT_EQ(Render::CallbackAdmissionContext::liveCount(), 0);
}

RDP_TEST_CASE(session_activation_transaction_serializes_three_thread_commit) {
    Render::SessionActivationTransaction transaction;
    const auto s1 = owner(91, 1, 9101);
    const auto s2 = owner(91, 2, 9102);
    const auto s3 = owner(91, 3, 9103);
    Render::DecoderSessionIdentity rendererOwner;
    Render::DecoderSessionIdentity decoderOwner;
    Render::DecoderSessionIdentity audioOwner;
    std::mutex barrierMutex;
    std::condition_variable barrierCv;
    bool firstEntered = false;
    bool releaseFirst = false;
    std::atomic<bool> secondCommitted {false};
    std::atomic<bool> thirdCommitted {false};

    std::thread first([&]() {
        auto lease = transaction.acquire();
        RDP_ASSERT(lease);
        rendererOwner = s1;
        decoderOwner = s1;
        audioOwner = s1;
        {
            std::lock_guard<std::mutex> lock(barrierMutex);
            firstEntered = true;
        }
        barrierCv.notify_all();
        std::unique_lock<std::mutex> lock(barrierMutex);
        barrierCv.wait(lock, [&]() { return releaseFirst; });
        RDP_ASSERT(rendererOwner == s1 && decoderOwner == s1 && audioOwner == s1);
    });
    {
        std::unique_lock<std::mutex> lock(barrierMutex);
        RDP_ASSERT(barrierCv.wait_for(lock, std::chrono::seconds(1),
                                      [&]() { return firstEntered; }));
    }
    std::thread second([&]() {
        auto lease = transaction.acquire();
        rendererOwner = s2;
        decoderOwner = s2;
        audioOwner = s2;
        secondCommitted.store(rendererOwner == s2 && decoderOwner == s2 &&
                              audioOwner == s2, std::memory_order_release);
    });
    std::thread third([&]() {
        auto lease = transaction.acquire();
        rendererOwner = s3;
        decoderOwner = s3;
        audioOwner = s3;
        thirdCommitted.store(rendererOwner == s3 && decoderOwner == s3 &&
                             audioOwner == s3, std::memory_order_release);
    });
    for (int i = 0; i < 1000; ++i) {
        RDP_ASSERT(!secondCommitted.load(std::memory_order_acquire));
        RDP_ASSERT(!thirdCommitted.load(std::memory_order_acquire));
        std::this_thread::yield();
    }
    {
        std::lock_guard<std::mutex> lock(barrierMutex);
        releaseFirst = true;
    }
    barrierCv.notify_all();
    first.join();
    second.join();
    third.join();
    RDP_ASSERT(secondCommitted.load(std::memory_order_acquire));
    RDP_ASSERT(thirdCommitted.load(std::memory_order_acquire));
}
