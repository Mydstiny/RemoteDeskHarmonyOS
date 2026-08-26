#include "moonlight/media/MoonlightVideoSurfaceLifecycle.h"
#include "test/test_runner.h"

#include <array>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <vector>

namespace {

using namespace remotedesk::moonlight;
using namespace std::chrono_literals;

class SurfacePortGate final {
public:
    void enterAndWait() {
        std::unique_lock<std::mutex> lock(mutex_);
        entered_ = true;
        cv_.notify_all();
        cv_.wait(lock, [&]() { return released_; });
    }

    bool waitEntered() {
        std::unique_lock<std::mutex> lock(mutex_);
        return cv_.wait_for(lock, 1s, [&]() { return entered_; });
    }

    void release() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            released_ = true;
        }
        cv_.notify_all();
    }

private:
    std::mutex mutex_;
    std::condition_variable cv_;
    bool entered_ = false;
    bool released_ = false;
};

class SurfaceFakeDecoderPort final : public MoonlightOwnedDecoderPort {
public:
    MoonlightDecoderPortStartStatus start(
        const MoonlightVideoDecoderBinding& binding) override {
        std::lock_guard<std::mutex> lock(mutex_);
        ++starts_;
        binding_ = binding;
        active_ = startStatus_ == MoonlightDecoderPortStartStatus::Started;
        suspended_ = false;
        return startStatus_;
    }

    MoonlightDecoderPortSubmitResult submit(
        const MoonlightVideoDecoderBinding& binding,
        std::shared_ptr<const MoonlightOwnedVideoAccessUnit> accessUnit) override {
        if (submitGate_ != nullptr) {
            submitGate_->enterAndWait();
        }
        std::lock_guard<std::mutex> lock(mutex_);
        ++submits_;
        lastSubmittedBytes_ = accessUnit == nullptr ? 0U : accessUnit->bytes.size();
        if (!active_ || suspended_ || binding != binding_) {
            return {MoonlightDecoderPortSubmitStatus::Stale, false, {}};
        }
        return {submitStatus_, false, binding_};
    }

    MoonlightDecoderPortSuspendStatus suspend(
        const MoonlightVideoDecoderBinding& binding,
        std::chrono::milliseconds) override {
        std::lock_guard<std::mutex> lock(mutex_);
        ++suspends_;
        if (!active_ || binding != binding_) {
            return MoonlightDecoderPortSuspendStatus::Stale;
        }
        if (suspendStatus_ == MoonlightDecoderPortSuspendStatus::Suspended) {
            suspended_ = true;
        }
        return suspendStatus_;
    }

    MoonlightDecoderPortRebindStatus rebind(
        const MoonlightVideoDecoderBinding& current,
        const MoonlightVideoDecoderBinding& next) override {
        std::lock_guard<std::mutex> lock(mutex_);
        ++rebinds_;
        if (!active_ || !suspended_ || current != binding_) {
            return MoonlightDecoderPortRebindStatus::Stale;
        }
        if (rebindStatus_ == MoonlightDecoderPortRebindStatus::Rebound) {
            binding_ = next;
            suspended_ = false;
        }
        return rebindStatus_;
    }

    MoonlightDecoderPortStopStatus stop(
        const MoonlightVideoDecoderBinding& binding,
        std::chrono::milliseconds) override {
        std::lock_guard<std::mutex> lock(mutex_);
        ++stops_;
        if (!active_ || binding != binding_) {
            return MoonlightDecoderPortStopStatus::Stale;
        }
        active_ = false;
        suspended_ = false;
        return stopStatus_;
    }

    MoonlightDecoderPresentationSnapshot snapshot(
        const MoonlightVideoDecoderBinding& binding) override {
        std::lock_guard<std::mutex> lock(mutex_);
        MoonlightDecoderPresentationSnapshot result;
        if (!active_ || suspended_ || binding != binding_) {
            return result;
        }
        result.matched = true;
        result.running = true;
        result.binding = binding_;
        result.decoderGeneration = binding_.decoderGeneration;
        result.rendererGeneration = binding_.rendererGeneration;
        result.renderedOutputBuffers = renderedOutputs_;
        result.nativeImageFrames = nativeImages_;
        result.rendererPresentedFrames = rendererPresents_;
        return result;
    }

    void presentOneFrame() {
        std::lock_guard<std::mutex> lock(mutex_);
        ++renderedOutputs_;
        ++nativeImages_;
        ++rendererPresents_;
    }

    std::size_t starts() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return starts_;
    }

    std::size_t submits() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return submits_;
    }

    std::size_t suspends() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return suspends_;
    }

    std::size_t rebinds() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return rebinds_;
    }

    std::size_t stops() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return stops_;
    }

    std::size_t lastSubmittedBytes() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return lastSubmittedBytes_;
    }

    MoonlightDecoderPortStartStatus startStatus_ =
        MoonlightDecoderPortStartStatus::Started;
    MoonlightDecoderPortSubmitStatus submitStatus_ =
        MoonlightDecoderPortSubmitStatus::Accepted;
    MoonlightDecoderPortSuspendStatus suspendStatus_ =
        MoonlightDecoderPortSuspendStatus::Suspended;
    MoonlightDecoderPortRebindStatus rebindStatus_ =
        MoonlightDecoderPortRebindStatus::Rebound;
    MoonlightDecoderPortStopStatus stopStatus_ =
        MoonlightDecoderPortStopStatus::Stopped;
    SurfacePortGate* submitGate_ = nullptr;

private:
    mutable std::mutex mutex_;
    MoonlightVideoDecoderBinding binding_ {};
    bool active_ = false;
    bool suspended_ = false;
    std::size_t starts_ = 0U;
    std::size_t submits_ = 0U;
    std::size_t suspends_ = 0U;
    std::size_t rebinds_ = 0U;
    std::size_t stops_ = 0U;
    std::size_t lastSubmittedBytes_ = 0U;
    std::uint64_t renderedOutputs_ = 0U;
    std::uint64_t nativeImages_ = 0U;
    std::uint64_t rendererPresents_ = 0U;
};

MoonlightStreamCodecProfile h264SurfaceProfile() {
    return {MoonlightStreamCodec::H264, MoonlightStreamBitDepth::Bit8,
            MoonlightStreamChroma::Yuv420};
}

MoonlightVideoDecoderBinding surfaceDecoderBinding(
    const MoonlightSessionKey& key = {71U, 31U, 501U}) {
    MoonlightVideoDecoderBinding result;
    result.key = key;
    result.profile = h264SurfaceProfile();
    result.width = 1920;
    result.height = 1080;
    result.display = 0;
    result.decoderHandle = 101;
    result.rendererHandle = 201;
    result.decoderGeneration = 301U;
    result.displayGeneration = 401U;
    result.rendererGeneration = 501U;
    result.ownsDecoderHandle = true;
    result.runtimeProof.generation = 601U;
    result.runtimeProof.h264HardwareDecode = true;
    result.runtimeProof.nativeImageSurface = true;
    result.runtimeProof.rendererPresentationAck = true;
    return result;
}

MoonlightVideoSurfaceBinding surfaceBinding(
    const MoonlightVideoDecoderBinding& decoder,
    std::uint64_t operationGeneration,
    std::uint64_t surfaceGeneration,
    MoonlightVideoSurfaceTarget target = MoonlightVideoSurfaceTarget::Page) {
    MoonlightVideoSurfaceBinding result;
    result.decoder = decoder;
    result.operationGeneration = operationGeneration;
    result.surfaceGeneration = surfaceGeneration;
    result.target = target;
    result.surfaceWidth = target == MoonlightVideoSurfaceTarget::Page ? 2400 : 960;
    result.surfaceHeight = target == MoonlightVideoSurfaceTarget::Page ? 1080 : 540;
    return result;
}

MoonlightVideoSurfaceBinding nextSurfaceBinding(
    const MoonlightVideoSurfaceBinding& current,
    std::uint64_t operationGeneration,
    MoonlightVideoSurfaceTarget target) {
    auto next = current;
    next.operationGeneration = operationGeneration;
    ++next.surfaceGeneration;
    ++next.decoder.rendererHandle;
    ++next.decoder.rendererGeneration;
    ++next.decoder.runtimeProof.generation;
    next.target = target;
    next.surfaceWidth = target == MoonlightVideoSurfaceTarget::Page ? 2400 : 960;
    next.surfaceHeight = target == MoonlightVideoSurfaceTarget::Page ? 1080 : 540;
    return next;
}

struct SurfaceVideoFixture final {
    std::array<std::uint8_t, 4> sps {{0x00U, 0x00U, 0x01U, 0x67U}};
    std::array<std::uint8_t, 4> pps {{0x00U, 0x00U, 0x01U, 0x68U}};
    std::array<std::uint8_t, 4> idr {{0x00U, 0x00U, 0x01U, 0x65U}};
    std::array<std::uint8_t, 4> predicted {{0x00U, 0x00U, 0x01U, 0x41U}};
    MoonlightVideoFragmentView spsView {};
    MoonlightVideoFragmentView ppsView {};
    MoonlightVideoFragmentView idrView {};
    MoonlightVideoFragmentView predictedView {};

    SurfaceVideoFixture() {
        spsView = {sps.data(), sps.size(),
                   MoonlightVideoBufferType::SequenceParameterSet, &ppsView};
        ppsView = {pps.data(), pps.size(),
                   MoonlightVideoBufferType::PictureParameterSet, &idrView};
        idrView = {idr.data(), idr.size(),
                   MoonlightVideoBufferType::PictureData, nullptr};
        predictedView = {predicted.data(), predicted.size(),
                         MoonlightVideoBufferType::PictureData, nullptr};
    }

    MoonlightVideoDecodeUnitView unit(
        const MoonlightSessionKey& key, std::int32_t frameNumber,
        MoonlightVideoFrameType frameType) {
        MoonlightVideoDecodeUnitView result;
        result.key = key;
        result.profile = h264SurfaceProfile();
        result.frameNumber = frameNumber;
        result.frameType = frameType;
        result.receiveTimeUs = 1000U + static_cast<std::uint64_t>(frameNumber);
        result.enqueueTimeUs = result.receiveTimeUs + 1U;
        result.presentationTimeUs = result.enqueueTimeUs + 1U;
        result.rtpTimestamp = 90000U + static_cast<std::uint32_t>(frameNumber);
        result.bufferList = frameType == MoonlightVideoFrameType::IdR
            ? &spsView : &predictedView;
        result.fullLength = frameType == MoonlightVideoFrameType::IdR
            ? sps.size() + pps.size() + idr.size() : predicted.size();
        return result;
    }
};

std::unique_ptr<MoonlightVideoSurfaceLifecycle> beginLifecycle(
    const std::shared_ptr<SurfaceFakeDecoderPort>& port,
    const MoonlightSessionKey& key,
    std::uint64_t operationGeneration = 1U) {
    auto lifecycle = MoonlightVideoSurfaceLifecycle::createForTesting(port);
    RDP_ASSERT(lifecycle != nullptr);
    const auto begun = lifecycle->begin(
        {key, h264SurfaceProfile(), operationGeneration});
    RDP_ASSERT_EQ(begun.status, MoonlightVideoSurfaceTransitionStatus::Applied);
    RDP_ASSERT_EQ(begun.state, MoonlightVideoSurfaceState::AwaitingSurface);
    return lifecycle;
}

RDP_TEST_CASE(moonlight_video_surface_lifecycle_drops_before_copy_without_surface) {
    auto port = std::make_shared<SurfaceFakeDecoderPort>();
    const MoonlightSessionKey key {71U, 31U, 501U};
    auto lifecycle = beginLifecycle(port, key);

    MoonlightVideoFragmentView deliberatelyInvalid {
        nullptr, 16U * 1024U * 1024U,
        MoonlightVideoBufferType::PictureData, nullptr};
    MoonlightVideoDecodeUnitView unit;
    unit.key = key;
    unit.profile = h264SurfaceProfile();
    unit.frameNumber = 1;
    unit.frameType = MoonlightVideoFrameType::Predicted;
    unit.fullLength = deliberatelyInvalid.length;
    unit.bufferList = &deliberatelyInvalid;

    const auto first = lifecycle->submit(unit);
    const auto second = lifecycle->submit(unit);
    RDP_ASSERT_EQ(first.status, MoonlightVideoSubmitStatus::NoSurface);
    RDP_ASSERT_EQ(first.dropReason, MoonlightVideoDropReason::NoSurface);
    RDP_ASSERT(!first.sinkCalled);
    RDP_ASSERT(!first.requestIdr);
    RDP_ASSERT_EQ(first.ownedBytes, static_cast<std::size_t>(0U));
    RDP_ASSERT_EQ(second.status, MoonlightVideoSubmitStatus::NoSurface);
    RDP_ASSERT_EQ(port->submits(), static_cast<std::size_t>(0U));
    const auto snapshot = lifecycle->snapshot(key);
    RDP_ASSERT_EQ(snapshot.noSurfaceDroppedFrames, static_cast<std::uint64_t>(2U));
    RDP_ASSERT(snapshot.idrNeeded);
    RDP_ASSERT(!snapshot.idrRequestPending);
    RDP_ASSERT_EQ(snapshot.retainedAccessUnitBytes, static_cast<std::size_t>(0U));
}

RDP_TEST_CASE(moonlight_video_surface_lifecycle_binds_and_requires_new_idr_once) {
    auto port = std::make_shared<SurfaceFakeDecoderPort>();
    const auto decoder = surfaceDecoderBinding({72U, 32U, 502U});
    auto lifecycle = beginLifecycle(port, decoder.key);
    const auto page = surfaceBinding(decoder, 2U, 1U);

    const auto bound = lifecycle->bind(page);
    RDP_ASSERT_EQ(bound.status, MoonlightVideoSurfaceTransitionStatus::Applied);
    RDP_ASSERT_EQ(bound.state, MoonlightVideoSurfaceState::Bound);
    RDP_ASSERT(bound.requestIdr);
    RDP_ASSERT_EQ(port->starts(), static_cast<std::size_t>(1U));

    SurfaceVideoFixture fixture;
    const auto predicted = lifecycle->submit(
        fixture.unit(decoder.key, 1, MoonlightVideoFrameType::Predicted));
    RDP_ASSERT_EQ(predicted.status, MoonlightVideoSubmitStatus::Dropped);
    RDP_ASSERT_EQ(predicted.dropReason, MoonlightVideoDropReason::WaitingForIdr);
    RDP_ASSERT(!predicted.requestIdr);
    const auto accepted = lifecycle->submit(
        fixture.unit(decoder.key, 2, MoonlightVideoFrameType::IdR));
    RDP_ASSERT_EQ(accepted.status, MoonlightVideoSubmitStatus::Accepted);
    RDP_ASSERT(!accepted.requestIdr);
    RDP_ASSERT_EQ(port->lastSubmittedBytes(), static_cast<std::size_t>(12U));

    port->presentOneFrame();
    const auto snapshot = lifecycle->snapshot(decoder.key);
    RDP_ASSERT(snapshot.firstFrameReady);
    RDP_ASSERT(!snapshot.idrNeeded);
    RDP_ASSERT(!snapshot.idrRequestPending);
}

RDP_TEST_CASE(moonlight_video_surface_lifecycle_suspends_and_exactly_rebinds_pip) {
    auto port = std::make_shared<SurfaceFakeDecoderPort>();
    const auto decoder = surfaceDecoderBinding({73U, 33U, 503U});
    auto lifecycle = beginLifecycle(port, decoder.key);
    auto page = surfaceBinding(decoder, 2U, 1U);
    RDP_ASSERT_EQ(lifecycle->bind(page).status,
                  MoonlightVideoSurfaceTransitionStatus::Applied);
    SurfaceVideoFixture fixture;
    RDP_ASSERT_EQ(lifecycle->submit(
                      fixture.unit(decoder.key, 1, MoonlightVideoFrameType::IdR)).status,
                  MoonlightVideoSubmitStatus::Accepted);
    port->presentOneFrame();
    RDP_ASSERT(lifecycle->snapshot(decoder.key).firstFrameReady);

    const auto suspended = lifecycle->suspend(
        decoder.key, 3U, MoonlightVideoSurfaceSuspendReason::PipTransfer, 1s);
    RDP_ASSERT_EQ(suspended.status, MoonlightVideoSurfaceTransitionStatus::Applied);
    RDP_ASSERT_EQ(suspended.state,
                  MoonlightVideoSurfaceState::SuspendedNoSurface);
    RDP_ASSERT_EQ(port->suspends(), static_cast<std::size_t>(1U));
    RDP_ASSERT(!lifecycle->snapshot(decoder.key).firstFrameReady);

    MoonlightVideoFragmentView invalid {nullptr, 1024U,
        MoonlightVideoBufferType::PictureData, nullptr};
    auto noSurface = fixture.unit(decoder.key, 2,
                                  MoonlightVideoFrameType::Predicted);
    noSurface.bufferList = &invalid;
    noSurface.fullLength = invalid.length;
    RDP_ASSERT_EQ(lifecycle->submit(noSurface).status,
                  MoonlightVideoSubmitStatus::NoSurface);

    const auto pip = nextSurfaceBinding(
        page, 4U, MoonlightVideoSurfaceTarget::Pip);
    const auto rebound = lifecycle->bind(pip);
    RDP_ASSERT_EQ(rebound.status, MoonlightVideoSurfaceTransitionStatus::Applied);
    RDP_ASSERT(rebound.requestIdr);
    RDP_ASSERT_EQ(port->rebinds(), static_cast<std::size_t>(1U));
    RDP_ASSERT_EQ(lifecycle->snapshot(decoder.key).binding.rendererHandle,
                  pip.decoder.rendererHandle);
    RDP_ASSERT_EQ(lifecycle->submit(
                      fixture.unit(decoder.key, 3,
                                   MoonlightVideoFrameType::Predicted)).dropReason,
                  MoonlightVideoDropReason::WaitingForIdr);
    RDP_ASSERT_EQ(lifecycle->submit(
                      fixture.unit(decoder.key, 4,
                                   MoonlightVideoFrameType::IdR)).status,
                  MoonlightVideoSubmitStatus::Accepted);
}

RDP_TEST_CASE(moonlight_video_surface_lifecycle_rejects_stale_and_non_exact_rebind) {
    auto port = std::make_shared<SurfaceFakeDecoderPort>();
    const auto decoder = surfaceDecoderBinding({74U, 34U, 504U});
    auto lifecycle = beginLifecycle(port, decoder.key);
    const auto page = surfaceBinding(decoder, 2U, 4U);
    RDP_ASSERT_EQ(lifecycle->bind(page).status,
                  MoonlightVideoSurfaceTransitionStatus::Applied);
    RDP_ASSERT_EQ(lifecycle->suspend(
                      decoder.key, 3U,
                      MoonlightVideoSurfaceSuspendReason::SurfaceDestroyed, 1s).status,
                  MoonlightVideoSurfaceTransitionStatus::Applied);

    auto stale = nextSurfaceBinding(page, 2U, MoonlightVideoSurfaceTarget::Pip);
    RDP_ASSERT_EQ(lifecycle->bind(stale).status,
                  MoonlightVideoSurfaceTransitionStatus::Stale);
    auto sameRendererGeneration = nextSurfaceBinding(
        page, 4U, MoonlightVideoSurfaceTarget::Pip);
    sameRendererGeneration.decoder.rendererGeneration =
        page.decoder.rendererGeneration;
    RDP_ASSERT_EQ(lifecycle->bind(sameRendererGeneration).status,
                  MoonlightVideoSurfaceTransitionStatus::InvalidRequest);
    auto sameProofGeneration = nextSurfaceBinding(
        page, 4U, MoonlightVideoSurfaceTarget::Pip);
    sameProofGeneration.decoder.runtimeProof.generation =
        page.decoder.runtimeProof.generation;
    RDP_ASSERT_EQ(lifecycle->bind(sameProofGeneration).status,
                  MoonlightVideoSurfaceTransitionStatus::InvalidRequest);

    const auto pip = nextSurfaceBinding(
        page, 4U, MoonlightVideoSurfaceTarget::Pip);
    RDP_ASSERT_EQ(lifecycle->bind(pip).status,
                  MoonlightVideoSurfaceTransitionStatus::Applied);
    RDP_ASSERT_EQ(lifecycle->bind(pip).status,
                  MoonlightVideoSurfaceTransitionStatus::AlreadyApplied);
    auto conflicting = pip;
    ++conflicting.surfaceWidth;
    RDP_ASSERT_EQ(lifecycle->bind(conflicting).status,
                  MoonlightVideoSurfaceTransitionStatus::Stale);
}

RDP_TEST_CASE(moonlight_video_surface_lifecycle_resize_preserves_binding_and_first_frame) {
    auto port = std::make_shared<SurfaceFakeDecoderPort>();
    const auto decoder = surfaceDecoderBinding({75U, 35U, 505U});
    auto lifecycle = beginLifecycle(port, decoder.key);
    const auto page = surfaceBinding(decoder, 2U, 7U);
    RDP_ASSERT_EQ(lifecycle->bind(page).status,
                  MoonlightVideoSurfaceTransitionStatus::Applied);
    SurfaceVideoFixture fixture;
    RDP_ASSERT_EQ(lifecycle->submit(
                      fixture.unit(decoder.key, 1, MoonlightVideoFrameType::IdR)).status,
                  MoonlightVideoSubmitStatus::Accepted);
    port->presentOneFrame();
    RDP_ASSERT(lifecycle->snapshot(decoder.key).firstFrameReady);

    const auto resized = lifecycle->resize(
        decoder.key, 3U, page.surfaceGeneration, 2200, 1200);
    RDP_ASSERT_EQ(resized.status, MoonlightVideoSurfaceTransitionStatus::Applied);
    RDP_ASSERT(lifecycle->snapshot(decoder.key).firstFrameReady);
    RDP_ASSERT_EQ(lifecycle->snapshot(decoder.key).surfaceWidth, 2200);
    RDP_ASSERT_EQ(lifecycle->resize(
                      decoder.key, 3U, page.surfaceGeneration, 2200, 1200).status,
                  MoonlightVideoSurfaceTransitionStatus::AlreadyApplied);
    RDP_ASSERT_EQ(lifecycle->resize(
                      decoder.key, 4U, page.surfaceGeneration + 1U,
                      2200, 1200).status,
                  MoonlightVideoSurfaceTransitionStatus::Stale);
}

RDP_TEST_CASE(moonlight_video_surface_lifecycle_survives_twenty_page_pip_cycles) {
    auto port = std::make_shared<SurfaceFakeDecoderPort>();
    const auto decoder = surfaceDecoderBinding({76U, 36U, 506U});
    auto lifecycle = beginLifecycle(port, decoder.key);
    auto current = surfaceBinding(decoder, 2U, 1U);
    RDP_ASSERT_EQ(lifecycle->bind(current).status,
                  MoonlightVideoSurfaceTransitionStatus::Applied);
    SurfaceVideoFixture fixture;
    std::int32_t frameNumber = 1;
    RDP_ASSERT_EQ(lifecycle->submit(
                      fixture.unit(decoder.key, frameNumber++,
                                   MoonlightVideoFrameType::IdR)).status,
                  MoonlightVideoSubmitStatus::Accepted);

    std::uint64_t operation = 3U;
    for (std::uint64_t cycle = 0U; cycle < 20U; ++cycle) {
        RDP_ASSERT_EQ(lifecycle->suspend(
                          decoder.key, operation++,
                          cycle % 2U == 0U
                              ? MoonlightVideoSurfaceSuspendReason::PipTransfer
                              : MoonlightVideoSurfaceSuspendReason::ForegroundRestore,
                          1s).status,
                      MoonlightVideoSurfaceTransitionStatus::Applied);
        current = nextSurfaceBinding(
            current, operation++,
            cycle % 2U == 0U ? MoonlightVideoSurfaceTarget::Pip
                             : MoonlightVideoSurfaceTarget::Page);
        const auto rebound = lifecycle->bind(current);
        RDP_ASSERT_EQ(rebound.status,
                      MoonlightVideoSurfaceTransitionStatus::Applied);
        RDP_ASSERT(rebound.requestIdr);
        RDP_ASSERT_EQ(lifecycle->submit(
                          fixture.unit(decoder.key, frameNumber++,
                                       MoonlightVideoFrameType::IdR)).status,
                      MoonlightVideoSubmitStatus::Accepted);
    }
    RDP_ASSERT_EQ(port->suspends(), static_cast<std::size_t>(20U));
    RDP_ASSERT_EQ(port->rebinds(), static_cast<std::size_t>(20U));
    RDP_ASSERT_EQ(lifecycle->snapshot(decoder.key).surfaceGeneration,
                  static_cast<std::uint64_t>(21U));
}

RDP_TEST_CASE(moonlight_video_surface_lifecycle_suspend_timeout_closes_admission_then_retries) {
    auto port = std::make_shared<SurfaceFakeDecoderPort>();
    SurfacePortGate gate;
    port->submitGate_ = &gate;
    const auto decoder = surfaceDecoderBinding({77U, 37U, 507U});
    auto lifecycle = beginLifecycle(port, decoder.key);
    const auto page = surfaceBinding(decoder, 2U, 1U);
    RDP_ASSERT_EQ(lifecycle->bind(page).status,
                  MoonlightVideoSurfaceTransitionStatus::Applied);
    SurfaceVideoFixture fixture;

    auto submitResult = std::make_shared<MoonlightVideoSubmitResult>();
    RdpTestThreadScope submitter([&]() { gate.release(); });
    submitter.start([&]() {
        *submitResult = lifecycle->submit(
            fixture.unit(decoder.key, 1, MoonlightVideoFrameType::IdR));
    });
    RDP_ASSERT(gate.waitEntered());
    RDP_ASSERT_EQ(lifecycle->suspend(
                      decoder.key, 3U,
                      MoonlightVideoSurfaceSuspendReason::Background, 1ms).status,
                  MoonlightVideoSurfaceTransitionStatus::TimedOut);
    RDP_ASSERT_EQ(lifecycle->snapshot(decoder.key).state,
                  MoonlightVideoSurfaceState::Suspending);

    MoonlightVideoFragmentView invalid {nullptr, 2048U,
        MoonlightVideoBufferType::PictureData, nullptr};
    auto unit = fixture.unit(decoder.key, 2, MoonlightVideoFrameType::Predicted);
    unit.bufferList = &invalid;
    unit.fullLength = invalid.length;
    RDP_ASSERT_EQ(lifecycle->submit(unit).status,
                  MoonlightVideoSubmitStatus::NoSurface);
    gate.release();
    submitter.cancelAndJoin();
    RDP_ASSERT(submitResult->status != MoonlightVideoSubmitStatus::Accepted);
    RDP_ASSERT_EQ(lifecycle->suspend(
                      decoder.key, 3U,
                      MoonlightVideoSurfaceSuspendReason::Background, 1s).status,
                  MoonlightVideoSurfaceTransitionStatus::Applied);
}

RDP_TEST_CASE(moonlight_video_surface_lifecycle_stop_is_exact_idempotent_and_reusable) {
    auto port = std::make_shared<SurfaceFakeDecoderPort>();
    const auto first = surfaceDecoderBinding({78U, 38U, 508U});
    auto lifecycle = beginLifecycle(port, first.key);
    const auto page = surfaceBinding(first, 2U, 1U);
    RDP_ASSERT_EQ(lifecycle->bind(page).status,
                  MoonlightVideoSurfaceTransitionStatus::Applied);
    RDP_ASSERT_EQ(lifecycle->suspend(
                      first.key, 3U,
                      MoonlightVideoSurfaceSuspendReason::LockScreen, 1s).status,
                  MoonlightVideoSurfaceTransitionStatus::Applied);

    RDP_ASSERT_EQ(lifecycle->stop(
                      {79U, 39U, 509U}, 4U, 1s).status,
                  MoonlightVideoSurfaceTransitionStatus::Stale);
    RDP_ASSERT_EQ(lifecycle->stop(first.key, 4U, 1s).status,
                  MoonlightVideoSurfaceTransitionStatus::Applied);
    RDP_ASSERT_EQ(lifecycle->stop(first.key, 4U, 1s).status,
                  MoonlightVideoSurfaceTransitionStatus::AlreadyApplied);
    RDP_ASSERT_EQ(port->stops(), static_cast<std::size_t>(1U));

    const MoonlightSessionKey secondKey {78U, 39U, 509U};
    RDP_ASSERT_EQ(lifecycle->begin(
                      {secondKey, h264SurfaceProfile(), 5U}).status,
                  MoonlightVideoSurfaceTransitionStatus::Applied);
    RDP_ASSERT_EQ(lifecycle->snapshot(secondKey).state,
                  MoonlightVideoSurfaceState::AwaitingSurface);
}

} // namespace
