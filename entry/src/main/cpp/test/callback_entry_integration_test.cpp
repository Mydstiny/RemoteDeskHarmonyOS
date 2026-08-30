#include "test_runner.h"

#include "audio/audio_capturer.h"
#include "audio/audio_player.h"
#include "render/hw_decoder.h"
#include "render/video_perf_counters.h"
#include "rdp/freerdp_adapter.h"
#include "rustdesk/rustdesk_bridge.h"
#include "vnc/vnc_adapter.h"

#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <mutex>
#include <memory>
#include <thread>
#include <vector>

#if defined(RDP_NATIVE_CALLBACK_TESTING)
extern "C" bool RdpTestProductionDisconnectRegistryRoundTrip(
    int sessionId, uint64_t requestId);
extern "C" int RdpTestSynchronousDisconnectReceiptState(bool fail);
#endif

namespace {

using namespace std::chrono_literals;

struct SharedCallbackBarrier final {
    std::mutex mutex;
    std::condition_variable cv;
    bool entered = false;
    bool release = false;
};

void ActivateOwner(const Render::DecoderSessionIdentity& owner) {
    auto& registry = Render::SharedSessionSinkOwnerLease();
    const auto active = registry.snapshot();
    if (active.valid()) {
        auto transition = registry.acquireExclusive();
        RDP_ASSERT(transition.beginDeactivate(active));
    }
    RDP_ASSERT(registry.activate(owner));
}

void DeactivateOwner(const Render::DecoderSessionIdentity& owner) {
    auto& registry = Render::SharedSessionSinkOwnerLease();
    if (registry.accepts(owner)) {
        RDP_ASSERT(registry.deactivateIfActive(owner));
    }
}

void DeactivateOwnerNoThrow(const Render::DecoderSessionIdentity& owner) noexcept {
    try {
        auto& registry = Render::SharedSessionSinkOwnerLease();
        if (registry.accepts(owner)) {
            (void)registry.deactivateIfActive(owner);
        }
    } catch (...) {
        // Teardown guards must never replace the original test failure.
    }
}

class OwnerCleanupGuard final {
public:
    explicit OwnerCleanupGuard(const Render::DecoderSessionIdentity& owner)
        : owner_(owner) {}

    ~OwnerCleanupGuard() noexcept {
        if (active_) {
            DeactivateOwnerNoThrow(owner_);
        }
    }

    void dismiss() noexcept { active_ = false; }

private:
    Render::DecoderSessionIdentity owner_;
    bool active_ = true;
};

class VncDeferredOwnerCleanupGuard final {
public:
    explicit VncDeferredOwnerCleanupGuard(std::shared_ptr<VncRfbEngine> engine)
        : engine_(std::move(engine)) {}

    ~VncDeferredOwnerCleanupGuard() noexcept {
        if (!deferred_ && engine_ != nullptr) {
            try {
                VncRfbEngine::deferStopAndJoin(engine_);
            } catch (...) {
                // The engine remains shared-owned if the reaper cannot enqueue.
            }
        }
    }

    void dismiss() noexcept { deferred_ = true; }

private:
    std::shared_ptr<VncRfbEngine> engine_;
    bool deferred_ = false;
};

} // namespace

void RunRustDeskPreparedTicketTransitionBarriers();

RDP_TEST_CASE(ohaudio_pull_production_entry_rejects_pause_then_destroy) {
    RDP_ASSERT(RdpTestDetail::verifyFailureSinkTokenIsolation());
    const Render::DecoderSessionIdentity owner {8101, 1, 810101};
    ActivateOwner(owner);

    int64_t handle = 0;
    auto player = AudioPlayerNapi::RegisterCallbackTestPlayer(owner, handle);
    RDP_ASSERT(player != nullptr);
    RDP_ASSERT(handle > 0);
    auto writes = std::make_shared<std::atomic<int>>(0);
    player->SetWriteCallbackForTesting([writes](void*, int32_t) {
        writes->fetch_add(1, std::memory_order_relaxed);
    });

    auto contextOwner = player->CallbackContextForTesting();
    auto* context = contextOwner.get();
    RDP_ASSERT(context != nullptr);
    auto barrier = std::make_shared<SharedCallbackBarrier>();
    context->setBeforeAcquireHook([barrier]() {
        std::unique_lock<std::mutex> lock(barrier->mutex);
        barrier->entered = true;
        barrier->cv.notify_all();
        barrier->cv.wait(lock, [&]() { return barrier->release; });
    });

    std::array<uint8_t, 8> pcm {};
    auto result = std::make_shared<std::atomic<int>>(
        static_cast<int>(AUDIO_DATA_CALLBACK_RESULT_VALID));
    RdpTestThreadScope callbackScope(barrier, [barrier]() {
        {
            std::lock_guard<std::mutex> lock(barrier->mutex);
            barrier->release = true;
        }
        barrier->cv.notify_all();
    });
    callbackScope.start([contextOwner, context, pcm, result]() mutable {
        (void)contextOwner;
        result->store(static_cast<int>(AudioPlayer::InvokeWriteCallbackForTesting(
            context, pcm.data(), static_cast<int32_t>(pcm.size()))),
            std::memory_order_release);
    });
    bool callbackEnteredInTime = false;
    {
        std::unique_lock<std::mutex> lock(barrier->mutex);
        callbackEnteredInTime = barrier->cv.wait_for(lock, 1s, [&]() {
            return barrier->entered;
        });
    }

    // The callback has received stable userData but has not entered the
    // admission gate. Destroy must finish without waiting for a raw object
    // callback and the resumed callback must perform zero sink writes.
    AudioPlayerNapi::DestroyCallbackTestPlayer(handle, owner);
    {
        std::lock_guard<std::mutex> lock(barrier->mutex);
        barrier->release = true;
    }
    barrier->cv.notify_all();
    RDP_ASSERT(callbackEnteredInTime);
    callbackScope.cancelAndJoin();

    RDP_ASSERT_EQ(result->load(std::memory_order_acquire),
                  static_cast<int>(AUDIO_DATA_CALLBACK_RESULT_INVALID));
    RDP_ASSERT_EQ(writes->load(), 0);
    // The same production case also covers a closeAndWait timeout: the
    // synthetic platform resource must remain live until the held admission
    // lease is released, then retire exactly once.
    const Render::DecoderSessionIdentity timeoutOwner {81011, 1, 8101101};
    DeactivateOwner(owner);
    ActivateOwner(timeoutOwner);
    int64_t timeoutHandle = 0;
    auto timeoutPlayer = AudioPlayerNapi::RegisterCallbackTestPlayer(
        timeoutOwner, timeoutHandle);
    RDP_ASSERT(timeoutPlayer != nullptr);
    timeoutPlayer->MarkPlatformResourceLiveForTesting();
    RDP_ASSERT(timeoutPlayer->HoldCallbackAdmissionForTesting());
    const auto timeoutStart = std::chrono::steady_clock::now();
    AudioPlayerNapi::DestroyCallbackTestPlayer(timeoutHandle, timeoutOwner);
    const auto timeoutElapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - timeoutStart);
    RDP_ASSERT(timeoutElapsed <= 700ms);
    RDP_ASSERT_EQ(timeoutPlayer->PlatformResourceDestroyCountForTesting(), 0);
    timeoutPlayer->ReleaseCallbackAdmissionForTesting();
    const auto timeoutDeadline = std::chrono::steady_clock::now() + 1s;
    while (timeoutPlayer->PlatformResourceDestroyCountForTesting() == 0 &&
           std::chrono::steady_clock::now() < timeoutDeadline) {
        std::this_thread::yield();
    }
    RDP_ASSERT_EQ(timeoutPlayer->PlatformResourceDestroyCountForTesting(), 1);
    DeactivateOwner(timeoutOwner);
}

RDP_TEST_CASE(ohaudio_pull_production_entry_keeps_owner_generation_isolated) {
    const Render::DecoderSessionIdentity first {8102, 1, 810201};
    const Render::DecoderSessionIdentity second {8102, 2, 810202};
    ActivateOwner(first);

    int64_t handle = 0;
    auto player = AudioPlayerNapi::RegisterCallbackTestPlayer(first, handle);
    RDP_ASSERT(player != nullptr);
    std::atomic<int> writes {0};
    player->SetWriteCallbackForTesting([&](void*, int32_t) {
        writes.fetch_add(1, std::memory_order_relaxed);
    });
    auto oldContextOwner = player->CallbackContextForTesting();
    void* oldUserData = oldContextOwner.get();
    std::array<uint8_t, 4> pcm {};

    RDP_ASSERT(AudioPlayer::InvokeWriteCallbackForTesting(
                   oldUserData, pcm.data(), static_cast<int32_t>(pcm.size())) ==
               AUDIO_DATA_CALLBACK_RESULT_VALID);
    RDP_ASSERT_EQ(writes.load(), 1);

    DeactivateOwner(first);
    ActivateOwner(second);
    RDP_ASSERT(AudioPlayer::InvokeWriteCallbackForTesting(
                   oldUserData, pcm.data(), static_cast<int32_t>(pcm.size())) ==
               AUDIO_DATA_CALLBACK_RESULT_INVALID);
    RDP_ASSERT_EQ(writes.load(), 1);

    AudioPlayerNapi::DestroyCallbackTestPlayer(handle, first);
    DeactivateOwner(second);
}

RDP_TEST_CASE(ohaudio_capturer_production_entry_rejects_old_owner) {
    const Render::DecoderSessionIdentity first {8103, 1, 810301};
    const Render::DecoderSessionIdentity second {8103, 2, 810302};
    ActivateOwner(first);

    int64_t handle = 0;
    auto capturer = AudioCapturerNapi::RegisterCallbackTestCapturer(first, handle);
    RDP_ASSERT(capturer != nullptr);
    std::atomic<int> callbacks {0};
    capturer->SetCaptureCallback([&](const uint8_t*, size_t size) {
        if (size > 0) {
            callbacks.fetch_add(1, std::memory_order_relaxed);
        }
    });
    auto oldContextOwner = capturer->CallbackContextForTesting();
    void* oldUserData = oldContextOwner.get();
    std::array<uint8_t, 16> pcm {};
    AudioCapturer::InvokeReadCallbackForTesting(
        oldUserData, pcm.data(), static_cast<int32_t>(pcm.size()));
    RDP_ASSERT_EQ(callbacks.load(), 1);

    DeactivateOwner(first);
    ActivateOwner(second);
    AudioCapturer::InvokeReadCallbackForTesting(
        oldUserData, pcm.data(), static_cast<int32_t>(pcm.size()));
    RDP_ASSERT_EQ(callbacks.load(), 1);

    AudioCapturerNapi::DestroyCallbackTestCapturer(handle, first);
    // Keep this carrier case at one outer registration while also proving
    // that a timed-out admission defers the platform resource release.
    int64_t timeoutHandle = 0;
    auto timeoutCapturer = AudioCapturerNapi::RegisterCallbackTestCapturer(
        second, timeoutHandle);
    RDP_ASSERT(timeoutCapturer != nullptr);
    timeoutCapturer->MarkPlatformResourceLiveForTesting();
    RDP_ASSERT(timeoutCapturer->HoldCallbackAdmissionForTesting());
    const auto timeoutStart = std::chrono::steady_clock::now();
    AudioCapturerNapi::DestroyCallbackTestCapturer(timeoutHandle, second);
    const auto timeoutElapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - timeoutStart);
    RDP_ASSERT(timeoutElapsed <= 700ms);
    RDP_ASSERT_EQ(timeoutCapturer->PlatformResourceDestroyCountForTesting(), 0);
    timeoutCapturer->ReleaseCallbackAdmissionForTesting();
    const auto timeoutDeadline = std::chrono::steady_clock::now() + 1s;
    while (timeoutCapturer->PlatformResourceDestroyCountForTesting() == 0 &&
           std::chrono::steady_clock::now() < timeoutDeadline) {
        std::this_thread::yield();
    }
    RDP_ASSERT_EQ(timeoutCapturer->PlatformResourceDestroyCountForTesting(), 1);
    DeactivateOwner(second);
}

RDP_TEST_CASE(oh_avcodec_production_entries_reject_old_generation) {
    const Render::DecoderSessionIdentity first {8104, 1, 810401};
    const Render::DecoderSessionIdentity second {8104, 2, 810402};
    ActivateOwner(first);

    int64_t firstHandle = 0;
    auto firstDecoder = DecoderNapi::RegisterCallbackTestDecoder(first, firstHandle);
    RDP_ASSERT(firstDecoder != nullptr);
    std::atomic<int> errors {0};
    firstDecoder->SetErrorCallback([&](DecoderError, const std::string&) {
        errors.fetch_add(1, std::memory_order_relaxed);
    });
    auto oldContextOwner = firstDecoder->CallbackContextForTesting();
    void* oldUserData = oldContextOwner.get();
    HardwareDecoder::InvokeNeedInputCallbackForTesting(nullptr, 1, nullptr, oldUserData);
    HardwareDecoder::InvokeNewOutputCallbackForTesting(nullptr, 1, nullptr, oldUserData);
    HardwareDecoder::InvokeStreamChangedCallbackForTesting(nullptr, nullptr, oldUserData);
    HardwareDecoder::InvokeFrameAvailableCallbackForTesting(oldUserData);
    HardwareDecoder::InvokeErrorCallbackForTesting(nullptr, 0, oldUserData);
    RDP_ASSERT_EQ(errors.load(), 1);

    DeactivateOwner(first);
    ActivateOwner(second);
    int64_t secondHandle = 0;
    auto secondDecoder = DecoderNapi::RegisterCallbackTestDecoder(second, secondHandle);
    RDP_ASSERT(secondDecoder != nullptr);
    RDP_ASSERT(secondHandle != firstHandle);
    std::atomic<int> secondErrors {0};
    secondDecoder->SetErrorCallback([&](DecoderError, const std::string&) {
        secondErrors.fetch_add(1, std::memory_order_relaxed);
    });

    // The real OH_AVCodec/NativeImage callback entry is invoked with the old
    // stable userData after S1 teardown. It must stop before registry lookup
    // and cannot reach the S2 decoder.
    HardwareDecoder::InvokeNeedInputCallbackForTesting(nullptr, 2, nullptr, oldUserData);
    HardwareDecoder::InvokeNewOutputCallbackForTesting(nullptr, 2, nullptr, oldUserData);
    HardwareDecoder::InvokeStreamChangedCallbackForTesting(nullptr, nullptr, oldUserData);
    HardwareDecoder::InvokeFrameAvailableCallbackForTesting(oldUserData);
    HardwareDecoder::InvokeErrorCallbackForTesting(nullptr, 0, oldUserData);
    RDP_ASSERT_EQ(secondErrors.load(), 0);

    DecoderNapi::DestroyCallbackTestDecoder(firstHandle, first);
    DecoderNapi::DestroyCallbackTestDecoder(secondHandle, second);
    DeactivateOwner(second);
}

RDP_TEST_CASE(oh_avcodec_callbacks_are_retained_during_pipeline_transition) {
    const Render::DecoderSessionIdentity owner {81041, 1, 8104101};
    ActivateOwner(owner);
    DecoderNapi::SetActiveSessionId(owner);
    RDP_ASSERT(DecoderNapi::SetActiveDisplay(owner, 0));

    int64_t handle = 0;
    auto decoder = DecoderNapi::RegisterCallbackTestDecoder(owner, handle);
    RDP_ASSERT(decoder != nullptr);
    RDP_ASSERT(handle > 0);
    RDP_ASSERT(DecoderNapi::PublishCallbackTestDecoder(handle, owner));
    const auto telemetry =
        DecoderNapi::GetActivePresentationTelemetryForTesting(owner);
    RDP_ASSERT(telemetry.valid);
    RDP_ASSERT_EQ(telemetry.decoderHandle, handle);
    RDP_ASSERT(telemetry.decoderGeneration > 0U);
    RDP_ASSERT(telemetry.displayGeneration > 0U);
    RDP_ASSERT(DecoderNapi::SetCallbackTestPipelineState(handle, owner, false, true));

    auto contextOwner = decoder->CallbackContextForTesting();
    void* userData = contextOwner.get();
    // The platform may issue the first input-buffer and frame-available
    // callbacks before ConfigurePipeline publishes the new renderer. They
    // must still reach the current decoder; otherwise input buffers remain in
    // user ownership and the codec stalls permanently after recovery.
    HardwareDecoder::InvokeNeedInputCallbackForTesting(nullptr, 7, nullptr, userData);
    HardwareDecoder::InvokeFrameAvailableCallbackForTesting(userData);
    RDP_ASSERT_EQ(decoder->PendingInputBufferCountForTesting(), static_cast<size_t>(1));
    RDP_ASSERT_EQ(decoder->FrameAvailableCountForTesting(), static_cast<uint64_t>(1));

    const std::array<uint8_t, 4> bytes {{0x00U, 0x00U, 0x01U, 0x65U}};
    VideoFrame frame;
    frame.data = bytes.data();
    frame.size = bytes.size();
    frame.width = 1920;
    frame.height = 1080;
    frame.codec = CodecType::H264;
    frame.timestamp = 12345U;
    frame.isKeyFrame = true;
    frame.display = 0;

    RDP_ASSERT_EQ(DecoderNapi::DecodeOwnedNativeForTesting(
                      handle, telemetry.decoderGeneration,
                      telemetry.displayGeneration, owner, frame),
                  DecoderNapi::OwnedSubmitStatus::Backpressure);
    RDP_ASSERT_EQ(DecoderNapi::DecodeActiveNative(owner, frame),
                  DecoderNapi::kDecodeInactiveSession);

    RDP_ASSERT(DecoderNapi::SetCallbackTestPipelineState(handle, owner, true, false));
    RDP_ASSERT_EQ(DecoderNapi::DecodeOwnedNativeForTesting(
                      handle + 1, telemetry.decoderGeneration,
                      telemetry.displayGeneration, owner, frame),
                  DecoderNapi::OwnedSubmitStatus::Stale);
    RDP_ASSERT_EQ(DecoderNapi::DecodeOwnedNativeForTesting(
                      handle, telemetry.decoderGeneration + 1U,
                      telemetry.displayGeneration, owner, frame),
                  DecoderNapi::OwnedSubmitStatus::Stale);
    RDP_ASSERT_EQ(DecoderNapi::DecodeOwnedNativeForTesting(
                      handle, telemetry.decoderGeneration,
                      telemetry.displayGeneration + 1U, owner, frame),
                  DecoderNapi::OwnedSubmitStatus::Stale);
    // This synthetic decoder is intentionally not initialized. The exact
    // path must report a typed platform failure, never guess generic -1 as
    // accepted.
    RDP_ASSERT_EQ(DecoderNapi::DecodeOwnedNativeForTesting(
                      handle, telemetry.decoderGeneration,
                      telemetry.displayGeneration, owner, frame),
                  DecoderNapi::OwnedSubmitStatus::Failed);

    DecoderNapi::DestroyCallbackTestDecoder(handle, owner);
    DecoderNapi::ClearActiveSessionId(owner);
    DeactivateOwner(owner);
}

static void run_oh_avcodec_callback_body_lease_survives_destroy();

using AvCodecCallbackEntry = std::function<void(void*)>;

static void run_oh_avcodec_callback_wins_barrier(
    const Render::DecoderSessionIdentity& owner,
    const AvCodecCallbackEntry& invoke) {
    ActivateOwner(owner);
    int64_t handle = 0;
    auto decoder = DecoderNapi::RegisterCallbackTestDecoder(owner, handle);
    RDP_ASSERT(decoder != nullptr);
    RDP_ASSERT(handle > 0);
    decoder->MarkPlatformResourceLiveForTesting();
    auto contextOwner = decoder->CallbackContextForTesting();
    auto* context = contextOwner.get();
    RDP_ASSERT(context != nullptr);

    auto barrier = std::make_shared<SharedCallbackBarrier>();
    context->setAfterAcquireHook([barrier]() {
        std::unique_lock<std::mutex> lock(barrier->mutex);
        barrier->entered = true;
        barrier->cv.notify_all();
        barrier->cv.wait(lock, [&]() { return barrier->release; });
    });

    auto callbackFinished = std::make_shared<std::atomic<bool>>(false);
    RdpTestThreadScope threads(barrier, [barrier]() {
        {
            std::lock_guard<std::mutex> lock(barrier->mutex);
            barrier->release = true;
        }
        barrier->cv.notify_all();
    });
    threads.start([invoke, decoder, callbackFinished]() {
        invoke(decoder->CallbackUserDataForTesting());
        callbackFinished->store(true, std::memory_order_release);
    });
    bool bodyEnteredInTime = false;
    {
        std::unique_lock<std::mutex> lock(barrier->mutex);
        bodyEnteredInTime = barrier->cv.wait_for(lock, 1s, [&]() {
            return barrier->entered;
        });
    }

    auto destroyFinished = std::make_shared<std::atomic<bool>>(false);
    threads.start([handle, owner, decoder, destroyFinished]() {
        DecoderNapi::DestroyCallbackTestDecoder(handle, owner);
        (void)decoder;
        destroyFinished->store(true, std::memory_order_release);
    });
    std::this_thread::sleep_for(100ms);
    const bool destroyBlockedByBody =
        !destroyFinished->load(std::memory_order_acquire);
    {
        std::lock_guard<std::mutex> lock(barrier->mutex);
        barrier->release = true;
    }
    barrier->cv.notify_all();

    const auto deadline = std::chrono::steady_clock::now() + 1s;
    while ((!callbackFinished->load(std::memory_order_acquire) ||
             !destroyFinished->load(std::memory_order_acquire)) &&
           std::chrono::steady_clock::now() < deadline) {
        std::this_thread::yield();
    }
    const bool callbackDone = callbackFinished->load(std::memory_order_acquire);
    const bool destroyDone = destroyFinished->load(std::memory_order_acquire);
    threads.cancelAndJoin();
    context->setAfterAcquireHook(nullptr);
    RDP_ASSERT(bodyEnteredInTime);
    RDP_ASSERT(destroyBlockedByBody);
    RDP_ASSERT(callbackDone);
    RDP_ASSERT(destroyDone);
    RDP_ASSERT_EQ(decoder->PlatformResourceDestroyCountForTesting(), 1);
    DeactivateOwner(owner);
}

static void run_oh_avcodec_destroy_wins_barrier(
    const Render::DecoderSessionIdentity& owner,
    const AvCodecCallbackEntry& invoke) {
    ActivateOwner(owner);
    int64_t handle = 0;
    auto decoder = DecoderNapi::RegisterCallbackTestDecoder(owner, handle);
    RDP_ASSERT(decoder != nullptr);
    RDP_ASSERT(handle > 0);
    decoder->MarkPlatformResourceLiveForTesting();
    auto contextOwner = decoder->CallbackContextForTesting();
    auto* context = contextOwner.get();
    RDP_ASSERT(context != nullptr);

    auto barrier = std::make_shared<SharedCallbackBarrier>();
    context->setBeforeAcquireHook([barrier]() {
        std::unique_lock<std::mutex> lock(barrier->mutex);
        barrier->entered = true;
        barrier->cv.notify_all();
        barrier->cv.wait(lock, [&]() { return barrier->release; });
    });

    auto callbackFinished = std::make_shared<std::atomic<bool>>(false);
    RdpTestThreadScope callbackScope(barrier, [barrier]() {
        {
            std::lock_guard<std::mutex> lock(barrier->mutex);
            barrier->release = true;
        }
        barrier->cv.notify_all();
    });
    callbackScope.start([invoke, decoder, callbackFinished]() {
        invoke(decoder->CallbackUserDataForTesting());
        callbackFinished->store(true, std::memory_order_release);
    });
    bool callbackPausedBeforeAcquire = false;
    {
        std::unique_lock<std::mutex> lock(barrier->mutex);
        callbackPausedBeforeAcquire = barrier->cv.wait_for(lock, 1s, [&]() {
            return barrier->entered;
        });
    }

    DecoderNapi::DestroyCallbackTestDecoder(handle, owner);
    const int destroyedBeforeRelease = decoder->PlatformResourceDestroyCountForTesting();
    {
        std::lock_guard<std::mutex> lock(barrier->mutex);
        barrier->release = true;
    }
    barrier->cv.notify_all();
    const auto deadline = std::chrono::steady_clock::now() + 1s;
    while (!callbackFinished->load(std::memory_order_acquire) &&
           std::chrono::steady_clock::now() < deadline) {
        std::this_thread::yield();
    }
    const bool callbackDone = callbackFinished->load(std::memory_order_acquire);
    callbackScope.cancelAndJoin();
    context->setBeforeAcquireHook(nullptr);
    RDP_ASSERT(callbackPausedBeforeAcquire);
    RDP_ASSERT(callbackDone);
    RDP_ASSERT_EQ(destroyedBeforeRelease, 1);
    RDP_ASSERT_EQ(decoder->PlatformResourceDestroyCountForTesting(), 1);
    DeactivateOwner(owner);
}

static void run_oh_avcodec_each_entry_barriers() {
    const std::array<AvCodecCallbackEntry, 4> entries {
        [](void* userData) {
            HardwareDecoder::InvokeErrorCallbackForTesting(nullptr, 0, userData);
        },
        [](void* userData) {
            HardwareDecoder::InvokeStreamChangedCallbackForTesting(
                nullptr, nullptr, userData);
        },
        [](void* userData) {
            HardwareDecoder::InvokeNeedInputCallbackForTesting(
                nullptr, 1, nullptr, userData);
        },
        [](void* userData) {
            HardwareDecoder::InvokeNewOutputCallbackForTesting(
                nullptr, 1, nullptr, userData);
        },
    };
    for (size_t index = 0; index < entries.size(); ++index) {
        const Render::DecoderSessionIdentity callbackWinsOwner {
            81053 + static_cast<uint64_t>(index), 1,
            8105301 + static_cast<uint64_t>(index)};
        run_oh_avcodec_callback_wins_barrier(callbackWinsOwner, entries[index]);
        const Render::DecoderSessionIdentity destroyWinsOwner {
            81057 + static_cast<uint64_t>(index), 1,
            8105701 + static_cast<uint64_t>(index)};
        run_oh_avcodec_destroy_wins_barrier(destroyWinsOwner, entries[index]);
    }
}

RDP_TEST_CASE(oh_avcodec_callback_barrier_destroy_is_bounded) {
    const Render::DecoderSessionIdentity owner {8105, 1, 810501};
    ActivateOwner(owner);

    int64_t handle = 0;
    auto decoder = DecoderNapi::RegisterCallbackTestDecoder(owner, handle);
    RDP_ASSERT(decoder != nullptr);
    auto contextOwner = decoder->CallbackContextForTesting();
    auto* context = contextOwner.get();
    RDP_ASSERT(context != nullptr);
    auto barrier = std::make_shared<SharedCallbackBarrier>();
    context->setBeforeAcquireHook([barrier]() {
        std::unique_lock<std::mutex> lock(barrier->mutex);
        barrier->entered = true;
        barrier->cv.notify_all();
        barrier->cv.wait(lock, [&]() { return barrier->release; });
    });

    // Keep one real admission lease outstanding so the production destroy
    // contract is observable: closeAndWait must not complete while a callback
    // is still admitted. The callback below is still the real OH_AVCodec
    // entry; this lease only makes the quiesce boundary deterministic.
    // Keep the lease inside the production-host DSO. The addon only crosses
    // a bool/void test boundary and never moves CallbackAdmissionContext::Lease
    // across the shared-library ABI.
    const bool heldAdmissionReady = decoder->HoldCallbackAdmissionForTesting();

    auto callbackFinished = std::make_shared<std::atomic<bool>>(false);
    auto destroyStarted = std::make_shared<std::atomic<bool>>(false);
    auto destroyFinished = std::make_shared<std::atomic<bool>>(false);
    RdpTestThreadScope threads(barrier, [barrier, decoder]() {
        {
            std::lock_guard<std::mutex> lock(barrier->mutex);
            barrier->release = true;
        }
        barrier->cv.notify_all();
        decoder->ReleaseCallbackAdmissionForTesting();
    });
    threads.start([contextOwner, context, callbackFinished, barrier]() {
        HardwareDecoder::InvokeFrameAvailableCallbackForTesting(context);
        (void)contextOwner;
        callbackFinished->store(true, std::memory_order_release);
        barrier->cv.notify_all();
    });
    bool callbackEnteredInTime = false;
    {
        std::unique_lock<std::mutex> lock(barrier->mutex);
        callbackEnteredInTime = barrier->cv.wait_for(
            lock, 1s, [&]() { return barrier->entered; });
    }

    // The old synchronous ordering called Destroy here and only released the
    // callback barrier below. That can never make progress when Destroy waits
    // for callback quiescence. Run the real destroy path independently so the
    // main test thread can perform the release without detaching or bypassing
    // closeAndWait.
    threads.start([handle, owner, destroyStarted, destroyFinished, barrier]() {
        destroyStarted->store(true, std::memory_order_release);
        barrier->cv.notify_all();
        DecoderNapi::DestroyCallbackTestDecoder(handle, owner);
        destroyFinished->store(true, std::memory_order_release);
        barrier->cv.notify_all();
    });

    bool destroyStartedInTime = false;
    bool destroyFinishedBeforeRelease = false;
    {
        std::unique_lock<std::mutex> lock(barrier->mutex);
        destroyStartedInTime = barrier->cv.wait_for(
            lock, 1s, [&]() { return destroyStarted->load(); });
        destroyFinishedBeforeRelease = barrier->cv.wait_for(
            lock, 100ms, [&]() { return destroyFinished->load(); });
    }

    {
        std::lock_guard<std::mutex> lock(barrier->mutex);
        barrier->release = true;
    }
    barrier->cv.notify_all();

    bool callbackFinishedInTime = false;
    {
        std::unique_lock<std::mutex> lock(barrier->mutex);
        callbackFinishedInTime = barrier->cv.wait_for(
            lock, 1s, [&]() { return callbackFinished->load(); });
    }
    // Release the deterministic admitted callback only after the real
    // callback has crossed its barrier. This makes the destroy completion
    // ordering explicit and keeps all joins bounded by prior waits.
    decoder->ReleaseCallbackAdmissionForTesting();

    bool destroyFinishedInTime = false;
    {
        std::unique_lock<std::mutex> lock(barrier->mutex);
        destroyFinishedInTime = barrier->cv.wait_for(
            lock, 1s, [&]() { return destroyFinished->load(); });
    }
    RDP_ASSERT(callbackFinishedInTime);
    RDP_ASSERT(destroyFinishedInTime);
    threads.cancelAndJoin();
    context->setBeforeAcquireHook(nullptr);

    RDP_ASSERT(heldAdmissionReady);
    RDP_ASSERT(callbackEnteredInTime);
    RDP_ASSERT(destroyStartedInTime);
    RDP_ASSERT(!destroyFinishedBeforeRelease);
    RDP_ASSERT(callbackFinishedInTime);
    RDP_ASSERT(destroyFinishedInTime);
    const Render::DecoderSessionIdentity timeoutOwner {81051, 1, 8105101};
    DeactivateOwner(owner);
    ActivateOwner(timeoutOwner);
    int64_t timeoutHandle = 0;
    auto timeoutDecoder = DecoderNapi::RegisterCallbackTestDecoder(
        timeoutOwner, timeoutHandle);
    RDP_ASSERT(timeoutDecoder != nullptr);
    timeoutDecoder->MarkPlatformResourceLiveForTesting();
    RDP_ASSERT(timeoutDecoder->HoldCallbackAdmissionForTesting());
    const auto timeoutStart = std::chrono::steady_clock::now();
    DecoderNapi::DestroyCallbackTestDecoder(timeoutHandle, timeoutOwner);
    const auto timeoutElapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - timeoutStart);
    RDP_ASSERT(timeoutElapsed <= 700ms);
    // The caller may time out the admission drain, but it must not touch any
    // codec/native-image platform object while the held callback lease can
    // still render through it.
    RDP_ASSERT_EQ(timeoutDecoder->PlatformResourceUnsetCountForTesting(), 0);
    RDP_ASSERT_EQ(timeoutDecoder->PlatformResourceStopCountForTesting(), 0);
    RDP_ASSERT_EQ(timeoutDecoder->PlatformResourceDestroyCountForTesting(), 0);
    timeoutDecoder->ReleaseCallbackAdmissionForTesting();
    const auto timeoutDeadline = std::chrono::steady_clock::now() + 1s;
    while (timeoutDecoder->PlatformResourceDestroyCountForTesting() == 0 &&
           std::chrono::steady_clock::now() < timeoutDeadline) {
        std::this_thread::yield();
    }
    RDP_ASSERT_EQ(timeoutDecoder->PlatformResourceUnsetCountForTesting(), 1);
    RDP_ASSERT_EQ(timeoutDecoder->PlatformResourceStopCountForTesting(), 1);
    RDP_ASSERT_EQ(timeoutDecoder->PlatformResourceDestroyCountForTesting(), 1);
    timeoutDecoder->Destroy();
    timeoutDecoder->Destroy();
    RDP_ASSERT_EQ(timeoutDecoder->PlatformResourceUnsetCountForTesting(), 1);
    RDP_ASSERT_EQ(timeoutDecoder->PlatformResourceStopCountForTesting(), 1);
    RDP_ASSERT_EQ(timeoutDecoder->PlatformResourceDestroyCountForTesting(), 1);
    DeactivateOwner(timeoutOwner);
    run_oh_avcodec_callback_body_lease_survives_destroy();
    run_oh_avcodec_each_entry_barriers();
}

static void run_oh_avcodec_callback_body_lease_survives_destroy() {
    const Render::DecoderSessionIdentity owner {81052, 1, 8105201};
    ActivateOwner(owner);
    int64_t handle = 0;
    auto decoder = DecoderNapi::RegisterCallbackTestDecoder(owner, handle);
    RDP_ASSERT(decoder != nullptr);
    auto contextOwner = decoder->CallbackContextForTesting();
    auto* context = contextOwner.get();
    RDP_ASSERT(context != nullptr);

    auto barrier = std::make_shared<SharedCallbackBarrier>();
    context->setAfterAcquireHook([barrier]() {
        std::unique_lock<std::mutex> lock(barrier->mutex);
        barrier->entered = true;
        barrier->cv.notify_all();
        barrier->cv.wait(lock, [&]() { return barrier->release; });
    });

    auto callbackFinished = std::make_shared<std::atomic<bool>>(false);
    RdpTestThreadScope threads(barrier, [barrier]() {
        {
            std::lock_guard<std::mutex> lock(barrier->mutex);
            barrier->release = true;
        }
        barrier->cv.notify_all();
    });
    threads.start([contextOwner, decoder, callbackFinished]() {
        // This is the real static OH_AVCodec entry.  The production callback
        // must keep its complete CallbackLeaseBundle through this hook and
        // through the final callback body operation.
        HardwareDecoder::InvokeStreamChangedCallbackForTesting(
            nullptr, nullptr, decoder->CallbackUserDataForTesting());
        (void)contextOwner;
        callbackFinished->store(true, std::memory_order_release);
    });
    {
        std::unique_lock<std::mutex> lock(barrier->mutex);
        RDP_ASSERT(barrier->cv.wait_for(lock, 1s, [&]() {
            return barrier->entered;
        }));
    }

    auto destroyFinished = std::make_shared<std::atomic<bool>>(false);
    threads.start([handle, owner, destroyFinished]() {
        DecoderNapi::DestroyCallbackTestDecoder(handle, owner);
        destroyFinished->store(true, std::memory_order_release);
    });
    std::this_thread::sleep_for(100ms);
    RDP_ASSERT(!destroyFinished->load(std::memory_order_acquire));
    {
        std::lock_guard<std::mutex> lock(barrier->mutex);
        barrier->release = true;
    }
    barrier->cv.notify_all();

    const auto deadline = std::chrono::steady_clock::now() + 1s;
    while ((!callbackFinished->load(std::memory_order_acquire) ||
             !destroyFinished->load(std::memory_order_acquire)) &&
           std::chrono::steady_clock::now() < deadline) {
        std::this_thread::yield();
    }
    RDP_ASSERT(callbackFinished->load(std::memory_order_acquire));
    RDP_ASSERT(destroyFinished->load(std::memory_order_acquire));
    threads.cancelAndJoin();
    context->setAfterAcquireHook(nullptr);
    DeactivateOwner(owner);
}

RDP_TEST_CASE(rustdesk_production_ffi_callback_rejects_stale_generation) {
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    // This call crosses the test-only carrier into the production
    // g_disconnectRequests object used by NapiDisconnect, rather than testing
    // a second registry implementation in isolation.
    RDP_ASSERT(RdpTestProductionDisconnectRegistryRoundTrip(8108, 810801));
    RDP_ASSERT_EQ(RdpTestSynchronousDisconnectReceiptState(false), 3);
    RDP_ASSERT_EQ(RdpTestSynchronousDisconnectReceiptState(true), 4);
#endif
    Render::DecoderSessionIdentity first {8108, 0, 810801};
    Render::DecoderSessionIdentity second {8108, 0, 810802};
    auto bridgeOwner = std::make_shared<RustDeskBridge>(RustDeskMode::FFI);
    auto& bridge = *bridgeOwner;
    bridge.setSessionIdentity(first.sessionId);
    const uint64_t firstGeneration = bridge.sessionGeneration();
    first.generation = firstGeneration;
    bridge.setSessionOwnerToken(first.ownerToken);
    ActivateOwner(first);

    auto firstFrames = std::make_shared<std::atomic<int>>(0);
    bridge.setVideoCallback([firstFrames](const VideoFrame& frame) {
        RDP_ASSERT(frame.data != nullptr);
        RDP_ASSERT_EQ(frame.size, 4);
        firstFrames->fetch_add(1, std::memory_order_relaxed);
    });
    const std::array<uint8_t, 4> encoded {{1, 2, 3, 4}};
    RDP_ASSERT(bridge.InvokeVideoCallbackForTesting(
        encoded.data(), encoded.size(), 640, 480, 3, 10, true, 0,
        firstGeneration, first.ownerToken));
    RDP_ASSERT_EQ(firstFrames->load(), 1);

    DeactivateOwner(first);
    bridge.setSessionIdentity(second.sessionId);
    const uint64_t secondGeneration = bridge.sessionGeneration();
    second.generation = secondGeneration;
    bridge.setSessionOwnerToken(second.ownerToken);
    ActivateOwner(second);

    // This is the same production static FFI entry with the retired S1
    // context identity. It must not reach the S2 callback.
    RDP_ASSERT(!bridge.InvokeVideoCallbackForTesting(
        encoded.data(), encoded.size(), 640, 480, 3, 11, true, 0,
        firstGeneration, first.ownerToken));
    RDP_ASSERT_EQ(firstFrames->load(), 1);

    auto secondFrames = std::make_shared<std::atomic<int>>(0);
    bridge.setVideoCallback([secondFrames](const VideoFrame&) {
        secondFrames->fetch_add(1, std::memory_order_relaxed);
    });
    RDP_ASSERT(bridge.InvokeVideoCallbackForTesting(
        encoded.data(), encoded.size(), 640, 480, 3, 12, true, 0,
        secondGeneration, second.ownerToken));
    RDP_ASSERT_EQ(secondFrames->load(), 1);

    // This is the production transport callback entry. Its first event is
    // admitted and quiesces the old stream. The visible-state callback
    // synchronously disconnects to prove the executor is not holding the
    // admission mutex across an external callback; the disconnect invalidates
    // the action epoch before any retry can be queued.
    auto reentrantDisconnect = std::make_shared<std::atomic<bool>>(false);
    bridge.setConnectionStateCallback([reentrantDisconnect, bridgeOwner](
        ConnectionState, const std::string&) {
        if (!reentrantDisconnect->exchange(true, std::memory_order_acq_rel)) {
            bridgeOwner->disconnect();
        }
    });
    RDP_ASSERT(bridge.InvokeTransportCallbackForTesting(
        1, "networkdown", 7, false, secondGeneration, second.ownerToken));
    RDP_ASSERT(reentrantDisconnect->load(std::memory_order_acquire));
    RDP_ASSERT(!bridge.InvokeTransportCallbackForTesting(
        1, "networkdown", 7, false, secondGeneration, second.ownerToken));

    // Recreate S2's transport generation and race the real frame callback
    // against explicit disconnect. The callback lease is held through the
    // sink dispatch, so teardown may quiesce but cannot publish stale first
    // frame state until the callback releases that lease.
    DeactivateOwner(second);
    bridge.setSessionIdentity(second.sessionId);
    second.generation = bridge.sessionGeneration();
    bridge.setSessionOwnerToken(second.ownerToken);
    ActivateOwner(second);

    auto barrier = std::make_shared<SharedCallbackBarrier>();
    bridge.setVideoCallback([barrier](const VideoFrame&) {
        std::unique_lock<std::mutex> lock(barrier->mutex);
        barrier->entered = true;
        barrier->cv.notify_all();
        barrier->cv.wait(lock, [&]() { return barrier->release; });
    });

    auto frameFinished = std::make_shared<std::atomic<bool>>(false);
    RdpTestThreadScope threads(barrier, [barrier, bridgeOwner]() {
        {
            std::lock_guard<std::mutex> lock(barrier->mutex);
            barrier->release = true;
        }
        barrier->cv.notify_all();
        bridgeOwner->disconnect();
    });
    threads.start([barrier, bridgeOwner, encoded, second, frameFinished]() {
        (void)barrier;
        (void)bridgeOwner->InvokeVideoCallbackForTesting(
            encoded.data(), encoded.size(), 640, 480, 3, 21, true, 0,
            second.generation, second.ownerToken);
        frameFinished->store(true, std::memory_order_release);
    });
    {
        std::unique_lock<std::mutex> lock(barrier->mutex);
        RDP_ASSERT(barrier->cv.wait_for(lock, 1s, [&]() {
            return barrier->entered;
        }));
    }

    auto disconnectFinished = std::make_shared<std::atomic<bool>>(false);
    threads.start([bridgeOwner, disconnectFinished]() {
        bridgeOwner->disconnect();
        disconnectFinished->store(true, std::memory_order_release);
    });
    const auto quiesceDeadline = std::chrono::steady_clock::now() + 1s;
    bool quiesceObserved = false;
    while (!bridgeOwner->continuityQuiesceSnapshot().deferredDestroyRequested) {
        if (std::chrono::steady_clock::now() >= quiesceDeadline) {
            break;
        }
        std::this_thread::yield();
    }
    quiesceObserved = bridgeOwner->continuityQuiesceSnapshot().deferredDestroyRequested;
    {
        std::lock_guard<std::mutex> lock(barrier->mutex);
        barrier->release = true;
    }
    barrier->cv.notify_all();
    const auto frameDeadline = std::chrono::steady_clock::now() + 1s;
    while (!frameFinished->load(std::memory_order_acquire) &&
           std::chrono::steady_clock::now() < frameDeadline) {
        std::this_thread::yield();
    }
    RDP_ASSERT(frameFinished->load(std::memory_order_acquire));
    RDP_ASSERT(disconnectFinished->load(std::memory_order_acquire));
    threads.cancelAndJoin();
    RDP_ASSERT(quiesceObserved);
    const auto snapshot = bridge.continuityQuiesceSnapshot();
    RDP_ASSERT(!snapshot.inputForward);
    RDP_ASSERT(!snapshot.decoderAdmission);
    RDP_ASSERT(disconnectFinished->load(std::memory_order_acquire));
    DeactivateOwner(second);

    // Frame-first ordering: claim the first frame before disconnect. The
    // frame commit may reopen the new generation, and the subsequent
    // disconnect must then close it normally.
    Render::DecoderSessionIdentity frameFirst {8120, 0, 812001};
    bridge.setSessionIdentity(frameFirst.sessionId);
    frameFirst.generation = bridge.sessionGeneration();
    bridge.setSessionOwnerToken(frameFirst.ownerToken);
    ActivateOwner(frameFirst);
    bridge.ArmFirstGenerationFrameForTesting();
    RDP_ASSERT(bridge.InvokeVideoCallbackForTesting(
        encoded.data(), encoded.size(), 640, 480, 3, 31, true, 0,
        frameFirst.generation, frameFirst.ownerToken));
    RDP_ASSERT(bridge.continuityQuiesceSnapshot().inputForward);
    bridge.disconnect();
    RDP_ASSERT(!bridge.continuityQuiesceSnapshot().inputForward);
    DeactivateOwner(frameFirst);

    // Claim-first barrier: the production callback has already committed the
    // first-frame token, but is paused before the external executor callback.
    // Disconnect wins only if its admission transition is ordered after that
    // commit; it must still close the generation and never let the paused
    // callback reopen input after release.
    Render::DecoderSessionIdentity claimOwner {8122, 0, 812201};
    bridge.setSessionIdentity(claimOwner.sessionId);
    claimOwner.generation = bridge.sessionGeneration();
    bridge.setSessionOwnerToken(claimOwner.ownerToken);
    ActivateOwner(claimOwner);
    auto claimBarrier = std::make_shared<SharedCallbackBarrier>();
    bridge.setVideoCallback([](const VideoFrame&) {});
    bridge.SetFirstFrameClaimHookForTesting([claimBarrier]() {
        std::unique_lock<std::mutex> lock(claimBarrier->mutex);
        claimBarrier->entered = true;
        claimBarrier->cv.notify_all();
        claimBarrier->cv.wait(lock, [&]() { return claimBarrier->release; });
    });
    auto claimFrameFinished = std::make_shared<std::atomic<bool>>(false);
    RdpTestThreadScope claimThreads(claimBarrier, [claimBarrier, bridgeOwner]() {
        {
            std::lock_guard<std::mutex> lock(claimBarrier->mutex);
            claimBarrier->release = true;
        }
        claimBarrier->cv.notify_all();
        bridgeOwner->disconnect();
    });
    claimThreads.start([bridgeOwner, encoded, claimOwner, claimFrameFinished]() {
        (void)bridgeOwner->InvokeVideoCallbackForTesting(
            encoded.data(), encoded.size(), 640, 480, 3, 32, true, 0,
            claimOwner.generation, claimOwner.ownerToken);
        claimFrameFinished->store(true, std::memory_order_release);
    });
    {
        std::unique_lock<std::mutex> lock(claimBarrier->mutex);
        RDP_ASSERT(claimBarrier->cv.wait_for(lock, 1s, [&]() {
            return claimBarrier->entered;
        }));
    }
    bridge.disconnect();
    {
        std::lock_guard<std::mutex> lock(claimBarrier->mutex);
        claimBarrier->release = true;
    }
    claimBarrier->cv.notify_all();
    const auto claimDeadline = std::chrono::steady_clock::now() + 1s;
    while (!claimFrameFinished->load(std::memory_order_acquire) &&
           std::chrono::steady_clock::now() < claimDeadline) {
        std::this_thread::yield();
    }
    RDP_ASSERT(claimFrameFinished->load(std::memory_order_acquire));
    claimThreads.cancelAndJoin();
    bridge.SetFirstFrameClaimHookForTesting(nullptr);
    RDP_ASSERT(!bridge.continuityQuiesceSnapshot().inputForward);
    DeactivateOwner(claimOwner);

    // Attempt ticket ordering: stop the real executor immediately after it
    // dequeues a production action, disconnect, then release the worker. The
    // stale ticket must fail closed before startAttempt/connect and must not
    // publish RECONNECTING_ATTEMPT.
    Render::DecoderSessionIdentity attemptOwner {8121, 0, 812101};
    bridge.setSessionIdentity(attemptOwner.sessionId);
    attemptOwner.generation = bridge.sessionGeneration();
    bridge.setSessionOwnerToken(attemptOwner.ownerToken);
    ActivateOwner(attemptOwner);
    std::mutex attemptMutex;
    std::condition_variable attemptCv;
    bool attemptDequeued = false;
    bool releaseAttempt = false;
    bool attemptFinished = false;
    std::atomic<int> attemptVisible {0};
    bridge.setConnectionStateCallback([&](ConnectionState, const std::string& message) {
        if (message.find("RECONNECTING_ATTEMPT") != std::string::npos) {
            attemptVisible.fetch_add(1, std::memory_order_relaxed);
        }
    });
    bridge.SetAttemptDequeuedHookForTesting([&]() {
        std::unique_lock<std::mutex> lock(attemptMutex);
        attemptDequeued = true;
        attemptCv.notify_all();
        attemptCv.wait(lock, [&]() { return releaseAttempt; });
        attemptFinished = true;
        attemptCv.notify_all();
    });
    const uint32_t connectCallsBefore = bridge.continuityConnectCallCountForTesting();
    RDP_ASSERT(bridge.InvokeTransportCallbackForTesting(
        1, "reset", 8, false, attemptOwner.generation, attemptOwner.ownerToken));
    {
        std::unique_lock<std::mutex> lock(attemptMutex);
        RDP_ASSERT(attemptCv.wait_for(lock, 1s, [&]() { return attemptDequeued; }));
    }
    bridge.disconnect();
    {
        std::lock_guard<std::mutex> lock(attemptMutex);
        releaseAttempt = true;
    }
    attemptCv.notify_all();
    {
        std::unique_lock<std::mutex> lock(attemptMutex);
        RDP_ASSERT(attemptCv.wait_for(lock, 1s, [&]() { return attemptFinished; }));
    }
    bridge.SetAttemptDequeuedHookForTesting(nullptr);
    RDP_ASSERT_EQ(bridge.continuityConnectCallCountForTesting(), connectCallsBefore);
    RDP_ASSERT_EQ(attemptVisible.load(std::memory_order_acquire), 0);
    DeactivateOwner(attemptOwner);
    RunRustDeskPreparedTicketTransitionBarriers();
}

void RunRustDeskPreparedTicketTransitionBarriers() {
    const auto makeConfig = []() {
        ConnectionConfig config;
        config.host = "continuity-test-peer";
        config.port = 21118;
        config.rdDirectIp = true;
        config.rdConnectionStrategy = "direct_ip";
        return config;
    };

    // A valid prepared ticket is consumed by the real RustDeskBridge
    // transport callback path. The test hook stands in for the external
    // socket only after the prepared ticket has passed the final fence.
    {
        RustDeskBridge bridge(RustDeskMode::FFI);
        bridge.setSessionIdentity(8123);
        Render::DecoderSessionIdentity owner {8123, bridge.sessionGeneration(), 812301};
        bridge.setSessionOwnerToken(owner.ownerToken);
        bridge.SetContinuityConfigForTesting(makeConfig());
        ActivateOwner(owner);
        std::atomic<int> visibleSuccess {0};
        bridge.setConnectionStateCallback([&](ConnectionState, const std::string& message) {
            if (message.find("CONNECTED_WAITING_FOR_FIRST_FRAME") != std::string::npos) {
                visibleSuccess.fetch_add(1, std::memory_order_relaxed);
            }
        });
        bridge.SetContinuityConnectResultHookForTesting(
            [&](uint64_t generation, uint64_t attemptToken) {
                RDP_ASSERT_EQ(generation, owner.generation);
                RDP_ASSERT(attemptToken != 0);
                return 0;
            });
        const uint32_t before = bridge.continuityConnectCallCountForTesting();
        RDP_ASSERT(bridge.InvokeTransportCallbackForTesting(
            1, "reset", 90, false, owner.generation, owner.ownerToken));
        const auto deadline = std::chrono::steady_clock::now() + 1s;
        while (bridge.continuityConnectCallCountForTesting() == before &&
               std::chrono::steady_clock::now() < deadline) {
            std::this_thread::yield();
        }
        RDP_ASSERT_EQ(bridge.continuityConnectCallCountForTesting(), before + 1);
        RDP_ASSERT_EQ(visibleSuccess.load(std::memory_order_acquire), 1);
        RDP_ASSERT_EQ(bridge.sessionGeneration(), owner.generation);
        bridge.SetContinuityConnectResultHookForTesting(nullptr);
        bridge.disconnect();
        DeactivateOwner(owner);
    }

    // Disconnect at each source/prepared/network boundary must invalidate the
    // source and prepared ticket before the bridge increments its connect
    // count. Each case uses a fresh bridge to keep the generation transition
    // independent and deterministic.
    for (const int disconnectStage : {0, 1, 2, 3}) {
        RustDeskBridge bridge(RustDeskMode::FFI);
        bridge.setSessionIdentity(static_cast<uint64_t>(8130 + disconnectStage));
        Render::DecoderSessionIdentity owner {
            static_cast<uint64_t>(8130 + disconnectStage),
            bridge.sessionGeneration(),
            static_cast<uint64_t>(813001 + disconnectStage),
        };
        bridge.setSessionOwnerToken(owner.ownerToken);
        bridge.SetContinuityConfigForTesting(makeConfig());
        ActivateOwner(owner);
        std::mutex hookMutex;
        std::condition_variable hookCv;
        bool hookEntered = false;
        bool hookReturned = false;
        bridge.SetContinuityAttemptStageHookForTesting([&](int stage) {
            if (stage != disconnectStage) {
                return;
            }
            {
                std::lock_guard<std::mutex> lock(hookMutex);
                hookEntered = true;
            }
            hookCv.notify_all();
            bridge.disconnect();
            {
                std::lock_guard<std::mutex> lock(hookMutex);
                hookReturned = true;
            }
            hookCv.notify_all();
        });
        bridge.SetContinuityConnectResultHookForTesting(
            [](uint64_t, uint64_t) { return 0; });
        const uint32_t before = bridge.continuityConnectCallCountForTesting();
        RDP_ASSERT(bridge.InvokeTransportCallbackForTesting(
            1, "reset", static_cast<uint64_t>(100 + disconnectStage),
            false, owner.generation, owner.ownerToken));
        {
            std::unique_lock<std::mutex> lock(hookMutex);
            RDP_ASSERT(hookCv.wait_for(lock, 1s, [&]() { return hookEntered; }));
            RDP_ASSERT(hookCv.wait_for(lock, 1s, [&]() { return hookReturned; }));
        }
        bridge.SetContinuityAttemptStageHookForTesting(nullptr);
        const uint32_t expectedCalls = disconnectStage == 3 ? before + 1 : before;
        RDP_ASSERT_EQ(bridge.continuityConnectCallCountForTesting(), expectedCalls);
        bridge.SetContinuityConnectResultHookForTesting(nullptr);
        DeactivateOwner(owner);
    }
}

RDP_TEST_CASE(vnc_production_callback_dispatch_respects_callback_lifecycle) {
    VncAdapter adapter;
    adapter.setSessionIdentity(8109);
    const Render::DecoderSessionIdentity firstOwner {8109, 1, 810901};
    const Render::DecoderSessionIdentity secondOwner {8110, 2, 811002};
    OwnerCleanupGuard firstOwnerGuard(firstOwner);
    ActivateOwner(firstOwner);
    adapter.setSessionOwner(firstOwner);
    const std::array<uint8_t, 4> pixels {{0, 1, 2, 3}};
    VideoFrame frame;
    frame.data = pixels.data();
    frame.size = pixels.size();
    frame.width = 2;
    frame.height = 2;
    frame.codec = CodecType::RAW_BGRA;
    frame.stride = 4;

    std::atomic<int> firstFrames {0};
    adapter.setVideoCallback([&](const VideoFrame& received) {
        RDP_ASSERT_EQ(received.size, pixels.size());
        firstFrames.fetch_add(1, std::memory_order_relaxed);
    });
    RDP_ASSERT(adapter.InvokeEngineVideoCallbackForTesting(frame, firstOwner));
    RDP_ASSERT_EQ(firstFrames.load(), 1);

    adapter.setVideoCallback(nullptr);
    RDP_ASSERT(adapter.InvokeEngineVideoCallbackForTesting(frame, firstOwner));
    RDP_ASSERT_EQ(firstFrames.load(), 1);

    std::atomic<int> secondFrames {0};
    DeactivateOwner(firstOwner);
    OwnerCleanupGuard secondOwnerGuard(secondOwner);
    ActivateOwner(secondOwner);
    adapter.setSessionIdentity(8110);
    adapter.setSessionOwner(secondOwner);
    adapter.setVideoCallback([&](const VideoFrame&) {
        secondFrames.fetch_add(1, std::memory_order_relaxed);
    });
    // The captured S1 engine identity is stale after teardown/address reuse.
    RDP_ASSERT(adapter.InvokeEngineVideoCallbackForTesting(frame, firstOwner));
    RDP_ASSERT_EQ(firstFrames.load(), 1);
    RDP_ASSERT_EQ(secondFrames.load(), 0);
    RDP_ASSERT(adapter.InvokeEngineVideoCallbackForTesting(frame, secondOwner));
    RDP_ASSERT_EQ(secondFrames.load(), 1);
    adapter.setVideoCallback(nullptr);

    // Public connect StartingSlot barrier: inject the same production engine
    // frame callback before start() can publish an active sink. The callback
    // must be rejected and cancel the serial; connect then owns/stops the
    // starting engine without installing a stale renderer.
    std::atomic<int> startingFrames {0};
    adapter.setVideoCallback([&](const VideoFrame&) {
        startingFrames.fetch_add(1, std::memory_order_relaxed);
    });
    auto stopRequests = std::make_shared<std::atomic<int>>(0);
    adapter.SetEngineStartHookForTesting([&](VncRfbEngine& engine) {
        engine.setStopObserverForTesting([stopRequests]() {
            stopRequests->fetch_add(1, std::memory_order_relaxed);
        });
        RDP_ASSERT(!engine.invokeFrameCallbackForTesting(frame));
        return engine.start();
    });
    ConnectionConfig startConfig;
    startConfig.host = "127.0.0.1";
    startConfig.port = 1;
    const int startResult = adapter.connect(startConfig);
    RDP_ASSERT(startResult != 0);
    RDP_ASSERT_EQ(startingFrames.load(std::memory_order_acquire), 0);
    RDP_ASSERT_EQ(stopRequests->load(std::memory_order_acquire), 1);
    RDP_ASSERT(adapter.getState() == ConnectionState::DISCONNECTED ||
               adapter.getState() == ConnectionState::ERROR);
    adapter.SetEngineStartHookForTesting(nullptr);
    adapter.setVideoCallback(nullptr);
    RDP_ASSERT(adapter.StartSelfStoppingEngineForTesting());

    // The deferred owner must expose a bounded drain contract. A callback
    // that cannot finish within the first budget remains owned and is only
    // reclaimed after its done fence is released; no retry hot-loop or
    // destructor-time unbounded join is used by this test.
    auto reaperRelease = std::make_shared<std::atomic<bool>>(false);
    auto reaperEntered = std::make_shared<std::atomic<bool>>(false);
    auto reaperMutex = std::make_shared<std::mutex>();
    auto reaperCv = std::make_shared<std::condition_variable>();
    auto reaperEngine = std::make_shared<VncRfbEngine>(
        ConnectionConfig {}, nullptr, nullptr, nullptr);
    VncDeferredOwnerCleanupGuard reaperGuard(reaperEngine);
    RDP_ASSERT_EQ(reaperEngine->startWorkerForTesting(
        [reaperRelease, reaperEntered, reaperMutex, reaperCv]() {
            reaperEntered->store(true, std::memory_order_release);
            reaperCv->notify_all();
            std::unique_lock<std::mutex> lock(*reaperMutex);
            reaperCv->wait(lock, [&]() {
                return reaperRelease->load(std::memory_order_acquire);
            });
        }), 0);
    {
        std::unique_lock<std::mutex> lock(*reaperMutex);
        RDP_ASSERT(reaperCv->wait_for(lock, 1s, [&]() {
            return reaperEntered->load(std::memory_order_acquire);
        }));
    }
    VncRfbEngine::deferStopAndJoin(reaperEngine);
    reaperGuard.dismiss();
    RDP_ASSERT(!VncRfbEngine::drainDeferredJoinsWithin(20ms));
    RDP_ASSERT(VncRfbEngine::deferredJoinRemaining() >= 1);
    RDP_ASSERT(!VncRfbEngine::shutdownDeferredJoinsWithin(30ms));
    reaperRelease->store(true, std::memory_order_release);
    reaperCv->notify_all();
    RDP_ASSERT(VncRfbEngine::shutdownDeferredJoinsWithin(1s));
    RDP_ASSERT_EQ(VncRfbEngine::deferredJoinRemaining(), static_cast<size_t>(0));
    RDP_ASSERT(adapter.InvokeLateFrameAfterCallbackStateInvalidationForTesting(
        frame, secondOwner));
    DeactivateOwner(secondOwner);
    secondOwnerGuard.dismiss();
    firstOwnerGuard.dismiss();
}

RDP_TEST_CASE(vnc_protocol_hidden_cursor_survives_local_input_prediction) {
    VncAdapter adapter;
    adapter.setSessionIdentity(8111);

    VncCursorProtocol::DecodedCursor visible;
    visible.visible = true;
    visible.shapeId = 101;
    visible.width = 2;
    visible.height = 2;
    visible.hotX = 1;
    visible.hotY = 1;
    visible.rgba.assign(2 * 2 * 4, 0xFF);
    adapter.InvokeProtocolCursorCallbackForTesting(visible);
    const RemoteCursorSnapshot shown = adapter.getRemoteCursorSnapshot(true);
    RDP_ASSERT(shown.visible);
    RDP_ASSERT(shown.protocolShapeAvailable);
    RDP_ASSERT_EQ(shown.shapeId, 101);

    VncCursorProtocol::DecodedCursor hidden;
    hidden.visible = false;
    adapter.InvokeProtocolCursorCallbackForTesting(hidden);
    adapter.UpdatePredictedCursorPositionForTesting(320, 240);
    adapter.UpdatePredictedCursorPositionForTesting(320, 216);
    const RemoteCursorSnapshot afterMoveAndWheel =
        adapter.getRemoteCursorSnapshot(false);
    RDP_ASSERT(!afterMoveAndWheel.visible);
    RDP_ASSERT(afterMoveAndWheel.protocolShapeAvailable);
    RDP_ASSERT(afterMoveAndWheel.positionAvailable);
    RDP_ASSERT_EQ(afterMoveAndWheel.x, 320);
    RDP_ASSERT_EQ(afterMoveAndWheel.y, 216);
    RDP_ASSERT_EQ(afterMoveAndWheel.shapeRevision, shown.shapeRevision);

    visible.shapeId = 102;
    visible.hotX = 0;
    visible.hotY = 0;
    adapter.InvokeProtocolCursorCallbackForTesting(visible);
    const RemoteCursorSnapshot restored = adapter.getRemoteCursorSnapshot(false);
    RDP_ASSERT(restored.visible);
    RDP_ASSERT(restored.protocolShapeAvailable);
    RDP_ASSERT_EQ(restored.shapeId, 102);
    RDP_ASSERT_EQ(restored.shapeRevision, shown.shapeRevision + 1);
}

#if defined(USE_REAL_FREERDP)
extern "C" UINT freerdp_ohos_rdpsnd_play(const BYTE* data, size_t size,
                                          UINT32 sampleRate, UINT16 channels,
                                          UINT16 bitsPerSample);

class CallbackCarrierCleanupGuard final {
public:
    CallbackCarrierCleanupGuard(freerdp* instance, rdpContext* context)
        : instance_(instance), context_(context) {}

    ~CallbackCarrierCleanupGuard() noexcept {
        if (!active_) {
            return;
        }
        try {
            FreeRdpAdapter::UnregisterCallbackContextForTesting(context_);
        } catch (...) {
        }
        try {
            if (instance_ != nullptr) {
                (void)FreeRdpAdapter::RevokeCallbackSourcesForTesting(
                    instance_, context_);
            } else {
                (void)FreeRdpAdapter::RevokeCallbackSourcesForTesting(context_);
            }
        } catch (...) {
        }
        try {
            if (instance_ != nullptr) {
                (void)FreeRdpAdapter::ReleaseCallbackSourceQuarantineForTesting(
                    instance_, context_);
            } else {
                (void)FreeRdpAdapter::ReleaseCallbackSourceQuarantineForTesting(context_);
            }
        } catch (...) {
            // Each cleanup step is independent and must not throw during
            // assertion unwind or mask the original test failure.
        }
    }

    // Watch from construction.  The cleanup entry points are idempotent and
    // fail closed, so a registration expression that throws after a partial
    // install still unregisters/revokes/quarantines the raw carrier address.
    void arm() noexcept { active_ = true; }

    void dismiss() noexcept { active_ = false; }

private:
    freerdp* instance_ = nullptr;
    rdpContext* context_ = nullptr;
    bool active_ = true;
};

static void run_freerdp_cb_post_disconnect_waits_for_end_paint_lease();

RDP_TEST_CASE(freerdp_cb_end_paint_production_entry_holds_owner_lease) {
    const Render::DecoderSessionIdentity owner {8106, 1, 810601};
    const Render::DecoderSessionIdentity nextOwner {8106, 2, 810602};
    OwnerCleanupGuard ownerGuard(owner);
    ActivateOwner(owner);

    auto adapterOwner = std::make_shared<FreeRdpAdapter>();
    auto& adapter = *adapterOwner;
    adapter.setSessionOwner(owner);
    auto contextOwner = std::make_shared<FreeRdpContext>();
    auto& context = *contextOwner;
    context.adapter = &adapter;
    context.owner = owner;
    context.generation = 1;
    auto* rawContext = reinterpret_cast<rdpContext*>(&context);
    freerdp carrier {};
    carrier.context = rawContext;
    CallbackCarrierCleanupGuard carrierGuard(&carrier, rawContext);
    RDP_ASSERT(FreeRdpAdapter::RegisterCallbackContextForTesting(
        rawContext, &adapter, owner, context.generation));
    carrierGuard.arm();
    const uint64_t oldCallbackToken =
        FreeRdpAdapter::CallbackContextTokenForTesting(
            reinterpret_cast<rdpContext*>(&context));
    RDP_ASSERT(oldCallbackToken != 0);

    auto barrier = std::make_shared<SharedCallbackBarrier>();
    adapter.SetEndPaintBarrierForTesting([barrier]() {
        std::unique_lock<std::mutex> lock(barrier->mutex);
        barrier->entered = true;
        barrier->cv.notify_all();
        barrier->cv.wait(lock, [&]() { return barrier->release; });
    });

    auto callbackResult = std::make_shared<std::atomic<BOOL>>(FALSE);
    auto callbackFinished = std::make_shared<std::atomic<bool>>(false);
    RdpTestThreadScope threads(barrier, [barrier]() {
        {
            std::lock_guard<std::mutex> lock(barrier->mutex);
            barrier->release = true;
        }
        barrier->cv.notify_all();
    });
    threads.start([adapterOwner, contextOwner, callbackResult, callbackFinished]() {
        (void)adapterOwner;
        callbackResult->store(FreeRdpAdapter::InvokeEndPaintCallbackForTesting(
            reinterpret_cast<rdpContext*>(contextOwner.get())),
            std::memory_order_release);
        callbackFinished->store(true, std::memory_order_release);
    });
    {
        std::unique_lock<std::mutex> lock(barrier->mutex);
        RDP_ASSERT(barrier->cv.wait_for(lock, 1s, [&]() {
            return barrier->entered;
        }));
    }

    // Revoke the raw carrier while a real production static entry is still
    // inside its callback body.  The unregister thread must wait for the
    // admitted lease; a late raw ABI call after map removal must fail closed
    // without re-entering the EndPaint barrier.
    auto unregisterFinished = std::make_shared<std::atomic<bool>>(false);
    threads.start([contextOwner, unregisterFinished]() {
        FreeRdpAdapter::UnregisterCallbackContextForTesting(
            reinterpret_cast<rdpContext*>(contextOwner.get()));
        unregisterFinished->store(true, std::memory_order_release);
    });
    std::this_thread::sleep_for(20ms);
    RDP_ASSERT(!unregisterFinished->load(std::memory_order_acquire));
    RDP_ASSERT(!FreeRdpAdapter::InvokeEndPaintCallbackForTesting(
        reinterpret_cast<rdpContext*>(&context)));
    RDP_ASSERT(!FreeRdpAdapter::RegisterCallbackContextForTesting(
        reinterpret_cast<rdpContext*>(&context), &adapter, owner,
        context.generation));

    auto transitionFinished = std::make_shared<std::atomic<bool>>(false);
    threads.start([owner, transitionFinished]() {
        auto ownerTransition = Render::SharedSessionSinkOwnerLease().acquireExclusive();
        RDP_ASSERT(ownerTransition.beginDeactivate(owner));
        transitionFinished->store(true, std::memory_order_release);
    });
    std::this_thread::sleep_for(20ms);
    RDP_ASSERT(!transitionFinished->load(std::memory_order_acquire));
    {
        std::lock_guard<std::mutex> lock(barrier->mutex);
        barrier->release = true;
    }
    barrier->cv.notify_all();
    const auto callbackDeadline = std::chrono::steady_clock::now() + 1s;
    while (!callbackFinished->load(std::memory_order_acquire) &&
           std::chrono::steady_clock::now() < callbackDeadline) {
        std::this_thread::yield();
    }
    RDP_ASSERT(callbackFinished->load(std::memory_order_acquire));
    RDP_ASSERT(transitionFinished->load(std::memory_order_acquire));
    RDP_ASSERT(unregisterFinished->load(std::memory_order_acquire));
    threads.cancelAndJoin();
    // Production callback families (pubsub, pointer, resize, channel,
    // certificate and post-disconnect) all receive the retired carrier after
    // cleanup in this barrier.  Every static entry must reject before its
    // first platform-object dereference, not only EndPaint.
    RDP_ASSERT(FreeRdpAdapter::InvokeRetiredCallbackFamilyForTesting(
        reinterpret_cast<rdpContext*>(&context)));
    RDP_ASSERT(callbackResult->load(std::memory_order_acquire) == TRUE);
    RDP_ASSERT(transitionFinished->load(std::memory_order_acquire));

    // The real ABI carries only the raw address.  It is therefore quarantined
    // after S1 unregister and cannot be reused until the source is explicitly
    // confirmed quiesced.  This is the address-ABA barrier: a late S1 callback
    // is rejected before it can inspect or submit to S2.
    DeactivateOwner(owner);
    ownerGuard.dismiss();
    OwnerCleanupGuard nextOwnerGuard(nextOwner);
    ActivateOwner(nextOwner);
    adapter.setSessionOwner(nextOwner);
    context.owner = nextOwner;
    context.generation = nextOwner.generation;
    RDP_ASSERT(!FreeRdpAdapter::RegisterCallbackContextForTesting(
        reinterpret_cast<rdpContext*>(&context), &adapter,
        nextOwner, context.generation));
    RDP_ASSERT(!FreeRdpAdapter::ReleaseCallbackSourceQuarantineForTesting(
        reinterpret_cast<rdpContext*>(&context)));
    RDP_ASSERT(FreeRdpAdapter::RevokeCallbackSourcesForTesting(
        reinterpret_cast<rdpContext*>(&context)));
    RDP_ASSERT(FreeRdpAdapter::ReleaseCallbackSourceQuarantineForTesting(
        reinterpret_cast<rdpContext*>(&context)));
    RDP_ASSERT(FreeRdpAdapter::RegisterCallbackContextForTesting(
        reinterpret_cast<rdpContext*>(&context), &adapter,
        nextOwner, context.generation));
    const uint64_t nextCallbackToken =
        FreeRdpAdapter::CallbackContextTokenForTesting(
            reinterpret_cast<rdpContext*>(&context));
    RDP_ASSERT(nextCallbackToken != 0 && nextCallbackToken != oldCallbackToken);
    RDP_ASSERT(!FreeRdpAdapter::InvokeEndPaintCallbackForTestingWithToken(
        reinterpret_cast<rdpContext*>(&context), oldCallbackToken));
    RDP_ASSERT(FreeRdpAdapter::InvokeEndPaintCallbackForTesting(
        reinterpret_cast<rdpContext*>(&context)) == TRUE);
    FreeRdpAdapter::UnregisterCallbackContextForTesting(
        reinterpret_cast<rdpContext*>(&context));
    RDP_ASSERT(FreeRdpAdapter::RevokeCallbackSourcesForTesting(
        reinterpret_cast<rdpContext*>(&context)));
    RDP_ASSERT(FreeRdpAdapter::ReleaseCallbackSourceQuarantineForTesting(
        reinterpret_cast<rdpContext*>(&context)));

    // Reuse the same production callback case for a real freerdp carrier.
    // This keeps the ohosTest outer suite at its fixed nine registered cases
    // while checking every instance-owned source slot through production
    // revoke code.
    RDP_ASSERT(FreeRdpAdapter::RegisterCallbackContextForTesting(
        &carrier, reinterpret_cast<rdpContext*>(&context), &adapter,
        nextOwner, context.generation));
    RDP_ASSERT(FreeRdpAdapter::InstallCallbackSourcesForTesting(&carrier));
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    RDP_ASSERT(carrier.VerifyCertificate != nullptr);
#pragma clang diagnostic pop
    RDP_ASSERT(carrier.VerifyCertificateEx != nullptr);
    RDP_ASSERT(carrier.VerifyChangedCertificateEx != nullptr);
    RDP_ASSERT(carrier.VerifyX509Certificate != nullptr);
    RDP_ASSERT(carrier.LogonErrorInfo != nullptr);
    RDP_ASSERT(carrier.PostConnect != nullptr);
    RDP_ASSERT(carrier.PostDisconnect != nullptr);
    RDP_ASSERT(carrier.LoadChannels != nullptr);
    FreeRdpAdapter::UnregisterCallbackContextForTesting(
        reinterpret_cast<rdpContext*>(&context));
    RDP_ASSERT(!FreeRdpAdapter::ReleaseCallbackSourceQuarantineForTesting(
        &carrier, reinterpret_cast<rdpContext*>(&context)));
    RDP_ASSERT(FreeRdpAdapter::RevokeCallbackSourcesForTesting(
        &carrier, reinterpret_cast<rdpContext*>(&context)));
    RDP_ASSERT(carrier.VerifyCertificateEx == nullptr);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    RDP_ASSERT(carrier.VerifyCertificate == nullptr);
#pragma clang diagnostic pop
    RDP_ASSERT(carrier.VerifyChangedCertificateEx == nullptr);
    RDP_ASSERT(carrier.VerifyX509Certificate == nullptr);
    RDP_ASSERT(carrier.LogonErrorInfo == nullptr);
    RDP_ASSERT(carrier.PostConnect == nullptr);
    RDP_ASSERT(carrier.PostDisconnect == nullptr);
    RDP_ASSERT(carrier.LoadChannels == nullptr);
    RDP_ASSERT(carrier.PostFinalDisconnect == nullptr);
    RDP_ASSERT(FreeRdpAdapter::ReleaseCallbackSourceQuarantineForTesting(
        &carrier, reinterpret_cast<rdpContext*>(&context)));
    carrierGuard.dismiss();
    DeactivateOwner(nextOwner);
    nextOwnerGuard.dismiss();
}

RDP_TEST_CASE(freerdp_rdpsnd_production_entry_holds_owner_lease) {
    const Render::DecoderSessionIdentity owner {8107, 1, 810701};
    const Render::DecoderSessionIdentity nextOwner {8107, 2, 810702};
    ActivateOwner(owner);

    auto barrier = std::make_shared<SharedCallbackBarrier>();
    auto nestedAccepted = std::make_shared<std::atomic<bool>>(false);
    FreeRdpAdapter::SetRdpsndCallbackForTesting([barrier, nestedAccepted, owner](
        const AudioData& audio) {
        nestedAccepted->store(
            static_cast<bool>(Render::SharedSessionSinkOwnerLease().acquire(owner)),
            std::memory_order_release);
        RDP_ASSERT(audio.data != nullptr);
        std::unique_lock<std::mutex> lock(barrier->mutex);
        barrier->entered = true;
        barrier->cv.notify_all();
        barrier->cv.wait(lock, [&]() { return barrier->release; });
    }, owner);

    std::array<uint8_t, 16> pcm {};
    auto callbackResult = std::make_shared<std::atomic<UINT>>(0);
    auto callbackFinished = std::make_shared<std::atomic<bool>>(false);
    RdpTestThreadScope threads(barrier, [barrier]() {
        {
            std::lock_guard<std::mutex> lock(barrier->mutex);
            barrier->release = true;
        }
        barrier->cv.notify_all();
    });
    threads.start([pcm, callbackResult, callbackFinished]() mutable {
        callbackResult->store(
            freerdp_ohos_rdpsnd_play(pcm.data(), pcm.size(), 48000, 2, 16),
            std::memory_order_release);
        callbackFinished->store(true, std::memory_order_release);
    });
    {
        std::unique_lock<std::mutex> lock(barrier->mutex);
        RDP_ASSERT(barrier->cv.wait_for(lock, 1s, [&]() {
            return barrier->entered;
        }));
    }

    auto transitionFinished = std::make_shared<std::atomic<bool>>(false);
    threads.start([owner, transitionFinished]() {
        auto ownerTransition = Render::SharedSessionSinkOwnerLease().acquireExclusive();
        RDP_ASSERT(ownerTransition.beginDeactivate(owner));
        transitionFinished->store(true, std::memory_order_release);
    });
    std::this_thread::sleep_for(20ms);
    RDP_ASSERT(!transitionFinished->load(std::memory_order_acquire));
    {
        std::lock_guard<std::mutex> lock(barrier->mutex);
        barrier->release = true;
    }
    barrier->cv.notify_all();
    const auto callbackDeadline = std::chrono::steady_clock::now() + 1s;
    while (!callbackFinished->load(std::memory_order_acquire) &&
           std::chrono::steady_clock::now() < callbackDeadline) {
        std::this_thread::yield();
    }
    RDP_ASSERT(callbackFinished->load(std::memory_order_acquire));
    RDP_ASSERT(transitionFinished->load(std::memory_order_acquire));
    threads.cancelAndJoin();

    RDP_ASSERT(callbackResult->load(std::memory_order_acquire) == 0);
    RDP_ASSERT(nestedAccepted->load(std::memory_order_acquire));
    RDP_ASSERT(transitionFinished->load(std::memory_order_acquire));

    const uint64_t oldCallbackToken = FreeRdpAdapter::RdpsndCallbackTokenForTesting();
    RDP_ASSERT(oldCallbackToken != 0);
    DeactivateOwner(owner);
    ActivateOwner(nextOwner);
    std::atomic<int> nextCallbackCount {0};
    FreeRdpAdapter::SetRdpsndCallbackForTesting([&](const AudioData& audio) {
        RDP_ASSERT(audio.data != nullptr);
        nextCallbackCount.fetch_add(1, std::memory_order_relaxed);
    }, nextOwner);
    const uint64_t nextCallbackToken = FreeRdpAdapter::RdpsndCallbackTokenForTesting();
    RDP_ASSERT(nextCallbackToken != 0 && nextCallbackToken != oldCallbackToken);
    // The S1 callback is injected after the callback slot has been replaced;
    // its captured token cannot write the S2 player even though the test
    // intentionally reuses the same production entry.
    RDP_ASSERT_EQ(FreeRdpAdapter::InvokeRdpsndCallbackForTestingWithToken(
                      oldCallbackToken, pcm.data(), pcm.size(), 48000, 2, 16),
                  0);
    RDP_ASSERT_EQ(nextCallbackCount.load(), 0);
    RDP_ASSERT_EQ(freerdp_ohos_rdpsnd_play(
                      pcm.data(), pcm.size(), 48000, 2, 16),
                  0);
    RDP_ASSERT_EQ(nextCallbackCount.load(), 1);
    FreeRdpAdapter::ClearRdpsndCallbackForTesting(nextOwner);
    DeactivateOwner(nextOwner);

    // Every critical teardown role receives its own carrier before transport
    // admission. A blocked SDK disconnect must not head-of-line block the
    // sibling platform-retire carrier or the global non-blocking join owner.
    RDP_ASSERT(FreeRdpAdapter::VerifyTeardownCarrierIsolationForTesting());

    // The deferred owner is process-scoped. Destroying an unrelated idle
    // adapter while another session has deferred work must not stop that
    // global owner or reject the next session's reservation.
    auto crossSessionRelease =
        FreeRdpAdapter::QueueBlockedWorkerForTesting();
    RDP_ASSERT(crossSessionRelease != nullptr);
    {
        auto idleAdapter = std::make_shared<FreeRdpAdapter>();
        idleAdapter.reset();
    }
    auto postDestructionRelease =
        FreeRdpAdapter::QueueBlockedWorkerForTesting();
    RDP_ASSERT(postDestructionRelease != nullptr);
    crossSessionRelease->store(true, std::memory_order_release);
    postDestructionRelease->store(true, std::memory_order_release);
    RDP_ASSERT(FreeRdpAdapter::DrainDeferredWorkersWithinForTesting(1000));

    // Fill every production deferred-owner slot with workers that cannot
    // complete. The next admission must fail before it starts a thread; no
    // callback-boundary fallback may synchronously join or detach it.
    constexpr size_t kDeferredWorkerCapacity = 64;
    std::vector<std::shared_ptr<std::atomic<bool>>> blockedReleases;
    blockedReleases.reserve(kDeferredWorkerCapacity);
    for (size_t index = 0; index < kDeferredWorkerCapacity; ++index) {
        auto release = FreeRdpAdapter::QueueBlockedWorkerForTesting();
        RDP_ASSERT(release != nullptr);
        blockedReleases.push_back(std::move(release));
    }
    RDP_ASSERT(FreeRdpAdapter::QueueBlockedWorkerForTesting() == nullptr);
    RDP_ASSERT(!FreeRdpAdapter::DrainDeferredWorkersWithinForTesting(20));
    RDP_ASSERT_EQ(FreeRdpAdapter::DeferredWorkerRemainingForTesting(),
                  kDeferredWorkerCapacity);
    RDP_ASSERT(!FreeRdpAdapter::ShutdownDeferredWorkersWithinForTesting(50));
    for (const auto& release : blockedReleases) {
        release->store(true, std::memory_order_release);
    }
    RDP_ASSERT(FreeRdpAdapter::DrainDeferredWorkersWithinForTesting(1000));
    RDP_ASSERT_EQ(FreeRdpAdapter::DeferredWorkerRemainingForTesting(),
                  static_cast<size_t>(0));
    RDP_ASSERT(FreeRdpAdapter::ShutdownDeferredWorkersWithinForTesting(500));
    run_freerdp_cb_post_disconnect_waits_for_end_paint_lease();
}

static void run_freerdp_cb_post_disconnect_waits_for_end_paint_lease() {
    const Render::DecoderSessionIdentity owner {8108, 1, 810801};
    OwnerCleanupGuard ownerGuard(owner);
    ActivateOwner(owner);

    auto adapterOwner = std::make_shared<FreeRdpAdapter>();
    auto& adapter = *adapterOwner;
    adapter.setSessionOwner(owner);
    auto contextOwner = std::make_shared<FreeRdpContext>();
    auto& context = *contextOwner;
    context.adapter = &adapter;
    context.owner = owner;
    context.generation = 1;
    auto* rawContext = reinterpret_cast<rdpContext*>(&context);
    CallbackCarrierCleanupGuard contextGuard(nullptr, rawContext);
    RDP_ASSERT(FreeRdpAdapter::RegisterCallbackContextForTesting(
        rawContext, &adapter, owner, context.generation));
    contextGuard.arm();

    auto barrier = std::make_shared<SharedCallbackBarrier>();
    adapter.SetEndPaintBarrierForTesting([barrier]() {
        std::unique_lock<std::mutex> lock(barrier->mutex);
        barrier->entered = true;
        barrier->cv.notify_all();
        barrier->cv.wait(lock, [&]() { return barrier->release; });
    });

    auto paintFinished = std::make_shared<std::atomic<bool>>(false);
    RdpTestThreadScope threads(barrier, [barrier]() {
        {
            std::lock_guard<std::mutex> lock(barrier->mutex);
            barrier->release = true;
        }
        barrier->cv.notify_all();
    });
    threads.start([adapterOwner, contextOwner, rawContext, paintFinished]() {
        (void)adapterOwner;
        (void)FreeRdpAdapter::InvokeEndPaintCallbackForTesting(rawContext);
        (void)contextOwner;
        paintFinished->store(true, std::memory_order_release);
    });
    {
        std::unique_lock<std::mutex> lock(barrier->mutex);
        RDP_ASSERT(barrier->cv.wait_for(lock, 1s, [&]() {
            return barrier->entered;
        }));
    }

    auto postFinished = std::make_shared<std::atomic<bool>>(false);
    threads.start([adapterOwner, contextOwner, rawContext, postFinished]() {
        (void)adapterOwner;
        FreeRdpAdapter::InvokePostDisconnectCallbackForTesting(rawContext);
        (void)contextOwner;
        postFinished->store(true, std::memory_order_release);
    });
    std::this_thread::sleep_for(20ms);
    RDP_ASSERT(!postFinished->load(std::memory_order_acquire));
    {
        std::lock_guard<std::mutex> lock(barrier->mutex);
        barrier->release = true;
    }
    barrier->cv.notify_all();
    const auto deadline = std::chrono::steady_clock::now() + 1s;
    while ((!paintFinished->load(std::memory_order_acquire) ||
             !postFinished->load(std::memory_order_acquire)) &&
           std::chrono::steady_clock::now() < deadline) {
        std::this_thread::yield();
    }
    RDP_ASSERT(paintFinished->load(std::memory_order_acquire));
    RDP_ASSERT(postFinished->load(std::memory_order_acquire));
    const uint64_t shutdownTicket = adapter.ShutdownTicketSerialForTesting();
    RDP_ASSERT(shutdownTicket != 0);
    // A reentrant PostDisconnect must observe the same absolute ticket; it
    // cannot mint a fresh 500 ms budget after the first teardown started.
    FreeRdpAdapter::InvokePostDisconnectCallbackForTesting(rawContext);
    RDP_ASSERT_EQ(adapter.ShutdownTicketSerialForTesting(), shutdownTicket);
    threads.cancelAndJoin();
    FreeRdpAdapter::UnregisterCallbackContextForTesting(rawContext);
    RDP_ASSERT(FreeRdpAdapter::RevokeCallbackSourcesForTesting(rawContext));
    RDP_ASSERT(FreeRdpAdapter::ReleaseCallbackSourceQuarantineForTesting(rawContext));
    contextGuard.dismiss();
    DeactivateOwner(owner);
    ownerGuard.dismiss();
}
#endif

#if !defined(RDP_OHOS_TEST_NATIVE_CALLBACK_ENTRY)
int main() {
    return runAllTests();
}
#endif
