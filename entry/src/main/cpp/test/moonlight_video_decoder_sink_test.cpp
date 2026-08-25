#include "moonlight/media/MoonlightVideoDecoderSink.h"
#include "test/test_runner.h"

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <vector>

namespace {

using namespace remotedesk::moonlight;
using namespace std::chrono_literals;

class DecoderPortGate final {
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

class FakeOwnedDecoderPort final : public MoonlightOwnedDecoderPort {
public:
    MoonlightDecoderPortStartStatus start(
        const MoonlightVideoDecoderBinding& binding) override {
        std::lock_guard<std::mutex> lock(mutex_);
        ++starts_;
        lastBinding_ = binding;
        return startStatus_;
    }

    MoonlightDecoderPortSubmitResult submit(
        const MoonlightVideoDecoderBinding& binding,
        std::shared_ptr<const MoonlightOwnedVideoAccessUnit> accessUnit) override {
        if (gate_ != nullptr) {
            gate_->enterAndWait();
        }
        if (throwOnSubmit_) {
            throw std::runtime_error("submit");
        }
        std::lock_guard<std::mutex> lock(mutex_);
        ++submits_;
        lastBinding_ = binding;
        submitted_.push_back(std::move(accessUnit));
        return {submitStatus_, bindingChanged_, reboundBinding_};
    }

    MoonlightDecoderPortSuspendStatus suspend(
        const MoonlightVideoDecoderBinding& binding,
        std::chrono::milliseconds) override {
        std::lock_guard<std::mutex> lock(mutex_);
        lastBinding_ = binding;
        return MoonlightDecoderPortSuspendStatus::Suspended;
    }

    MoonlightDecoderPortRebindStatus rebind(
        const MoonlightVideoDecoderBinding& current,
        const MoonlightVideoDecoderBinding& next) override {
        std::lock_guard<std::mutex> lock(mutex_);
        lastBinding_ = current;
        reboundBinding_ = next;
        return MoonlightDecoderPortRebindStatus::Rebound;
    }

    MoonlightDecoderPortStopStatus stop(
        const MoonlightVideoDecoderBinding& binding,
        std::chrono::milliseconds) override {
        std::lock_guard<std::mutex> lock(mutex_);
        ++stops_;
        lastBinding_ = binding;
        return stopStatus_;
    }

    MoonlightDecoderPresentationSnapshot snapshot(
        const MoonlightVideoDecoderBinding& binding) override {
        std::lock_guard<std::mutex> lock(mutex_);
        auto result = snapshot_;
        result.binding = binding;
        return result;
    }

    std::size_t starts() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return starts_;
    }

    std::size_t submits() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return submits_;
    }

    std::size_t stops() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return stops_;
    }

    std::shared_ptr<const MoonlightOwnedVideoAccessUnit> submitted(
        std::size_t index) const {
        std::lock_guard<std::mutex> lock(mutex_);
        return submitted_.at(index);
    }

    MoonlightVideoDecoderBinding lastBinding() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return lastBinding_;
    }

    void setPresentation(std::uint64_t renderedOutputs,
                         std::uint64_t nativeImages,
                         std::uint64_t rendererPresents,
                         std::uint64_t decoderGeneration,
                         std::uint64_t rendererGeneration) {
        std::lock_guard<std::mutex> lock(mutex_);
        snapshot_.matched = true;
        snapshot_.running = true;
        snapshot_.renderedOutputBuffers = renderedOutputs;
        snapshot_.nativeImageFrames = nativeImages;
        snapshot_.rendererPresentedFrames = rendererPresents;
        snapshot_.decoderGeneration = decoderGeneration;
        snapshot_.rendererGeneration = rendererGeneration;
    }

    MoonlightDecoderPortStartStatus startStatus_ =
        MoonlightDecoderPortStartStatus::Started;
    MoonlightDecoderPortSubmitStatus submitStatus_ =
        MoonlightDecoderPortSubmitStatus::Accepted;
    MoonlightDecoderPortStopStatus stopStatus_ =
        MoonlightDecoderPortStopStatus::Stopped;
    bool bindingChanged_ = false;
    MoonlightVideoDecoderBinding reboundBinding_ {};
    bool throwOnSubmit_ = false;
    DecoderPortGate* gate_ = nullptr;

private:
    mutable std::mutex mutex_;
    std::size_t starts_ = 0U;
    std::size_t submits_ = 0U;
    std::size_t stops_ = 0U;
    MoonlightVideoDecoderBinding lastBinding_ {};
    MoonlightDecoderPresentationSnapshot snapshot_ {};
    std::vector<std::shared_ptr<const MoonlightOwnedVideoAccessUnit>> submitted_;
};

MoonlightStreamCodecProfile h264() {
    return {MoonlightStreamCodec::H264, MoonlightStreamBitDepth::Bit8,
            MoonlightStreamChroma::Yuv420};
}

MoonlightVideoDecoderBinding binding(
    const MoonlightSessionKey& key = {31U, 21U, 201U}) {
    MoonlightVideoDecoderBinding result;
    result.key = key;
    result.profile = h264();
    result.width = 1920;
    result.height = 1080;
    result.display = 0;
    result.decoderHandle = 41;
    result.rendererHandle = 51;
    result.decoderGeneration = 61U;
    result.displayGeneration = 71U;
    result.rendererGeneration = 81U;
    result.ownsDecoderHandle = true;
    result.runtimeProof.generation = 91U;
    result.runtimeProof.h264HardwareDecode = true;
    result.runtimeProof.nativeImageSurface = true;
    result.runtimeProof.rendererPresentationAck = true;
    return result;
}

std::shared_ptr<MoonlightOwnedVideoAccessUnit> accessUnit(
    const MoonlightVideoDecoderBinding& active,
    std::int32_t frameNumber = 1,
    MoonlightVideoFrameType frameType = MoonlightVideoFrameType::IdR,
    std::uint64_t configurationGeneration = 1U,
    bool configurationChanged = true) {
    auto result = std::make_shared<MoonlightOwnedVideoAccessUnit>();
    result->key = active.key;
    result->profile = active.profile;
    result->frameNumber = frameNumber;
    result->frameType = frameType;
    result->presentationTimeUs = 12345U;
    result->codecConfigurationGeneration = configurationGeneration;
    result->codecConfigurationChanged = configurationChanged;
    result->bytes = {0x00U, 0x00U, 0x01U, 0x65U};
    result->fragments.push_back(
        {MoonlightVideoBufferType::PictureData, 0U, result->bytes.size()});
    return result;
}

RDP_TEST_CASE(moonlight_video_decoder_sink_rejects_invalid_or_unproven_binding_before_port) {
    auto port = std::make_shared<FakeOwnedDecoderPort>();
    auto sink = MoonlightOwnedVideoDecoderSink::createForTesting(port);
    RDP_ASSERT(sink != nullptr);

    auto request = binding();
    request.runtimeProof.rendererPresentationAck = false;
    RDP_ASSERT_EQ(sink->start(request).status,
                  MoonlightVideoDecoderStartStatus::RuntimeProofRequired);
    request = binding();
    request.width = 0;
    RDP_ASSERT_EQ(sink->start(request).status,
                  MoonlightVideoDecoderStartStatus::InvalidRequest);
    request = binding();
    request.profile.codec = MoonlightStreamCodec::Hevc;
    request.profile.bitDepth = MoonlightStreamBitDepth::Bit10;
    RDP_ASSERT_EQ(sink->start(request).status,
                  MoonlightVideoDecoderStartStatus::Unsupported);
    RDP_ASSERT_EQ(port->starts(), static_cast<std::size_t>(0U));
}

RDP_TEST_CASE(moonlight_video_decoder_sink_accepts_hardware_hevc_and_av1_profiles) {
    for (const auto codec : {MoonlightStreamCodec::Hevc,
                             MoonlightStreamCodec::Av1}) {
        auto port = std::make_shared<FakeOwnedDecoderPort>();
        auto sink = MoonlightOwnedVideoDecoderSink::createForTesting(port);
        auto request = binding();
        request.profile.codec = codec;
        RDP_ASSERT_EQ(sink->start(request).status,
                      MoonlightVideoDecoderStartStatus::Started);
        RDP_ASSERT_EQ(port->starts(), static_cast<std::size_t>(1U));
        RDP_ASSERT(port->lastBinding() == request);
    }
}

RDP_TEST_CASE(moonlight_video_decoder_sink_accepts_surface_without_display_binding) {
    auto port = std::make_shared<FakeOwnedDecoderPort>();
    auto sink = MoonlightOwnedVideoDecoderSink::createForTesting(port);
    auto request = binding();
    request.display = -1;

    RDP_ASSERT_EQ(sink->start(request).status,
                  MoonlightVideoDecoderStartStatus::Started);
    RDP_ASSERT(port->lastBinding() == request);
}

RDP_TEST_CASE(moonlight_video_decoder_sink_maps_exact_binding_and_owned_access_unit) {
    auto port = std::make_shared<FakeOwnedDecoderPort>();
    auto sink = MoonlightOwnedVideoDecoderSink::createForTesting(port);
    const auto request = binding();
    RDP_ASSERT_EQ(sink->start(request).status,
                  MoonlightVideoDecoderStartStatus::Started);
    RDP_ASSERT(sink->available(h264()));
    RDP_ASSERT(port->lastBinding() == request);

    const auto unit = accessUnit(request);
    RDP_ASSERT_EQ(sink->submit(unit), MoonlightVideoSinkStatus::Accepted);
    RDP_ASSERT_EQ(port->submits(), static_cast<std::size_t>(1U));
    const auto submitted = port->submitted(0U);
    RDP_ASSERT(submitted == unit);
    RDP_ASSERT_EQ(submitted->codecConfigurationGeneration,
                  static_cast<std::uint64_t>(1U));
    RDP_ASSERT(submitted->codecConfigurationChanged);
    RDP_ASSERT_EQ(submitted->presentationTimeUs, static_cast<std::uint64_t>(12345U));
}

RDP_TEST_CASE(moonlight_video_decoder_sink_maps_port_truth_without_guessing_failure) {
    const struct Case {
        MoonlightDecoderPortSubmitStatus port;
        MoonlightVideoSinkStatus sink;
    } cases[] = {
        {MoonlightDecoderPortSubmitStatus::Accepted, MoonlightVideoSinkStatus::Accepted},
        {MoonlightDecoderPortSubmitStatus::AcceptedNeedsIdr,
         MoonlightVideoSinkStatus::AcceptedNeedsIdr},
        {MoonlightDecoderPortSubmitStatus::Backpressure, MoonlightVideoSinkStatus::Backpressure},
        {MoonlightDecoderPortSubmitStatus::NeedIdr, MoonlightVideoSinkStatus::NeedIdr},
        {MoonlightDecoderPortSubmitStatus::Stale, MoonlightVideoSinkStatus::Stale},
        {MoonlightDecoderPortSubmitStatus::Unsupported, MoonlightVideoSinkStatus::Unsupported},
        {MoonlightDecoderPortSubmitStatus::Failed, MoonlightVideoSinkStatus::Failed},
    };
    for (const auto& item : cases) {
        auto port = std::make_shared<FakeOwnedDecoderPort>();
        port->submitStatus_ = item.port;
        auto sink = MoonlightOwnedVideoDecoderSink::createForTesting(port);
        const auto request = binding({32U, 22U, 202U + static_cast<std::uint64_t>(item.port)});
        RDP_ASSERT_EQ(sink->start(request).status,
                      MoonlightVideoDecoderStartStatus::Started);
        RDP_ASSERT_EQ(sink->submit(accessUnit(request)), item.sink);
    }

    auto port = std::make_shared<FakeOwnedDecoderPort>();
    port->throwOnSubmit_ = true;
    auto sink = MoonlightOwnedVideoDecoderSink::createForTesting(port);
    const auto request = binding({33U, 23U, 220U});
    RDP_ASSERT_EQ(sink->start(request).status,
                  MoonlightVideoDecoderStartStatus::Started);
    RDP_ASSERT_EQ(sink->submit(accessUnit(request)), MoonlightVideoSinkStatus::Failed);
}

RDP_TEST_CASE(moonlight_video_decoder_sink_first_frame_requires_all_exact_generation_evidence) {
    auto port = std::make_shared<FakeOwnedDecoderPort>();
    auto sink = MoonlightOwnedVideoDecoderSink::createForTesting(port);
    const auto request = binding({34U, 24U, 221U});
    RDP_ASSERT_EQ(sink->start(request).status,
                  MoonlightVideoDecoderStartStatus::Started);
    RDP_ASSERT(!sink->snapshot(request.key).firstFrameReady);

    port->setPresentation(1U, 0U, 0U, request.decoderGeneration,
                          request.rendererGeneration);
    RDP_ASSERT(!sink->snapshot(request.key).firstFrameReady);
    port->setPresentation(1U, 1U, 0U, request.decoderGeneration,
                          request.rendererGeneration);
    RDP_ASSERT(!sink->snapshot(request.key).firstFrameReady);
    port->setPresentation(1U, 1U, 1U, request.decoderGeneration + 1U,
                          request.rendererGeneration);
    RDP_ASSERT(!sink->snapshot(request.key).firstFrameReady);
    port->setPresentation(1U, 1U, 1U, request.decoderGeneration,
                          request.rendererGeneration + 1U);
    RDP_ASSERT(!sink->snapshot(request.key).firstFrameReady);
    port->setPresentation(1U, 1U, 1U, request.decoderGeneration,
                          request.rendererGeneration);
    const auto ready = sink->snapshot(request.key);
    RDP_ASSERT(ready.matched);
    RDP_ASSERT(ready.running);
    RDP_ASSERT(ready.firstFrameReady);

    port->setPresentation(0U, 0U, 0U, request.decoderGeneration,
                          request.rendererGeneration);
    RDP_ASSERT(sink->snapshot(request.key).firstFrameReady);
}

RDP_TEST_CASE(moonlight_video_decoder_sink_adopts_only_exact_new_decoder_generation) {
    auto port = std::make_shared<FakeOwnedDecoderPort>();
    auto sink = MoonlightOwnedVideoDecoderSink::createForTesting(port);
    const auto request = binding({37U, 27U, 224U});
    RDP_ASSERT_EQ(sink->start(request).status,
                  MoonlightVideoDecoderStartStatus::Started);

    auto rebound = request;
    rebound.decoderGeneration += 1U;
    port->bindingChanged_ = true;
    port->reboundBinding_ = rebound;
    RDP_ASSERT_EQ(sink->submit(accessUnit(request, 2,
                                          MoonlightVideoFrameType::IdR, 2U, true)),
                  MoonlightVideoSinkStatus::Accepted);
    const auto changed = sink->snapshot(request.key);
    RDP_ASSERT_EQ(changed.binding.decoderGeneration, rebound.decoderGeneration);
    RDP_ASSERT(!changed.firstFrameReady);

    port->bindingChanged_ = false;
    port->setPresentation(1U, 1U, 1U, rebound.decoderGeneration,
                          rebound.rendererGeneration);
    RDP_ASSERT(sink->snapshot(request.key).firstFrameReady);
    RDP_ASSERT_EQ(sink->submit(accessUnit(rebound, 3,
                                          MoonlightVideoFrameType::Predicted, 2U, false)),
                  MoonlightVideoSinkStatus::Accepted);
    RDP_ASSERT(port->lastBinding() == rebound);
    RDP_ASSERT_EQ(sink->stop(request.key, 1s),
                  MoonlightVideoDecoderStopStatus::Stopped);
    RDP_ASSERT(port->lastBinding() == rebound);
}

RDP_TEST_CASE(moonlight_decoder_generation_handoff_adopts_recovery_idr_generation) {
    RDP_ASSERT_EQ(classifyMoonlightDecoderGenerationHandoff(
                      true, 41U, 42U, false),
                  MoonlightDecoderGenerationHandoff::Advanced);
    RDP_ASSERT_EQ(classifyMoonlightDecoderGenerationHandoff(
                      true, 41U, 41U, false),
                  MoonlightDecoderGenerationHandoff::Unchanged);
    RDP_ASSERT_EQ(classifyMoonlightDecoderGenerationHandoff(
                      true, 41U, 41U, true),
                  MoonlightDecoderGenerationHandoff::Stale);
    RDP_ASSERT_EQ(classifyMoonlightDecoderGenerationHandoff(
                      true, 41U, 40U, false),
                  MoonlightDecoderGenerationHandoff::Stale);
    RDP_ASSERT_EQ(classifyMoonlightDecoderGenerationHandoff(
                      false, 41U, 42U, false),
                  MoonlightDecoderGenerationHandoff::Stale);
}

RDP_TEST_CASE(moonlight_video_decoder_sink_fails_closed_on_non_exact_rebind) {
    auto port = std::make_shared<FakeOwnedDecoderPort>();
    auto sink = MoonlightOwnedVideoDecoderSink::createForTesting(port);
    const auto request = binding({38U, 28U, 225U});
    RDP_ASSERT_EQ(sink->start(request).status,
                  MoonlightVideoDecoderStartStatus::Started);
    port->bindingChanged_ = true;
    port->reboundBinding_ = request;
    port->reboundBinding_.rendererGeneration += 1U;
    RDP_ASSERT_EQ(sink->submit(accessUnit(request)), MoonlightVideoSinkStatus::Stale);
    RDP_ASSERT(!sink->available(h264()));
}

RDP_TEST_CASE(moonlight_video_decoder_sink_survives_twenty_exact_start_stop_cycles) {
    auto port = std::make_shared<FakeOwnedDecoderPort>();
    auto sink = MoonlightOwnedVideoDecoderSink::createForTesting(port);
    for (std::uint64_t cycle = 0U; cycle < 20U; ++cycle) {
        const auto request = binding({39U, 29U + cycle, 300U + cycle});
        RDP_ASSERT_EQ(sink->start(request).status,
                      MoonlightVideoDecoderStartStatus::Started);
        RDP_ASSERT_EQ(sink->submit(accessUnit(request)),
                      MoonlightVideoSinkStatus::Accepted);
        RDP_ASSERT_EQ(sink->stop(request.key, 1s),
                      MoonlightVideoDecoderStopStatus::Stopped);
    }
    RDP_ASSERT_EQ(port->starts(), static_cast<std::size_t>(20U));
    RDP_ASSERT_EQ(port->stops(), static_cast<std::size_t>(20U));
}

RDP_TEST_CASE(moonlight_video_decoder_sink_teardown_closes_admission_and_drains_blocked_submit) {
    auto port = std::make_shared<FakeOwnedDecoderPort>();
    DecoderPortGate gate;
    port->gate_ = &gate;
    auto sink = MoonlightOwnedVideoDecoderSink::createForTesting(port);
    const auto request = binding({35U, 25U, 222U});
    RDP_ASSERT_EQ(sink->start(request).status,
                  MoonlightVideoDecoderStartStatus::Started);

    auto result = std::make_shared<MoonlightVideoSinkStatus>(
        MoonlightVideoSinkStatus::Failed);
    RdpTestThreadScope submitter([&]() { gate.release(); });
    submitter.start([&, result]() {
        *result = sink->submit(accessUnit(request));
    });
    RDP_ASSERT(gate.waitEntered());
    RDP_ASSERT_EQ(sink->stop(request.key, 1ms),
                  MoonlightVideoDecoderStopStatus::TimedOut);
    RDP_ASSERT(!sink->available(h264()));
    gate.release();
    submitter.cancelAndJoin();
    RDP_ASSERT_EQ(*result, MoonlightVideoSinkStatus::Stale);
    RDP_ASSERT_EQ(sink->stop(request.key, 1s),
                  MoonlightVideoDecoderStopStatus::Stopped);
    RDP_ASSERT_EQ(port->stops(), static_cast<std::size_t>(1U));
    RDP_ASSERT(!sink->snapshot(request.key).firstFrameReady);
}

RDP_TEST_CASE(moonlight_video_decoder_sink_rejects_busy_stale_and_reused_owner_token) {
    auto port = std::make_shared<FakeOwnedDecoderPort>();
    auto sink = MoonlightOwnedVideoDecoderSink::createForTesting(port);
    const auto first = binding({36U, 26U, 223U});
    RDP_ASSERT_EQ(sink->start(first).status,
                  MoonlightVideoDecoderStartStatus::Started);
    RDP_ASSERT_EQ(sink->start(binding({36U, 27U, 224U})).status,
                  MoonlightVideoDecoderStartStatus::Busy);
    RDP_ASSERT_EQ(sink->submit(accessUnit(binding({36U, 27U, 224U}))),
                  MoonlightVideoSinkStatus::Stale);
    RDP_ASSERT_EQ(sink->stop(first.key, 1s),
                  MoonlightVideoDecoderStopStatus::Stopped);
    RDP_ASSERT_EQ(sink->start(binding({36U, 27U, 223U})).status,
                  MoonlightVideoDecoderStartStatus::InvalidRequest);
}

} // namespace
