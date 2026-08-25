#include "moonlight/media/MoonlightVideoBridge.h"
#include "test/test_runner.h"

#include <array>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <vector>

namespace {

using namespace remotedesk::moonlight;
using namespace std::chrono_literals;

class VideoGate final {
public:
    void enterAndWait() {
        std::unique_lock<std::mutex> lock(mutex_);
        entered_ = true;
        cv_.notify_all();
        cv_.wait(lock, [&]() { return released_; });
    }

    bool waitEntered(std::chrono::milliseconds timeout = 1s) {
        std::unique_lock<std::mutex> lock(mutex_);
        return cv_.wait_for(lock, timeout, [&]() { return entered_; });
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

class RecordingVideoSink final : public MoonlightVideoDecoderSink {
public:
    bool available(const MoonlightStreamCodecProfile&) override {
        if (throwOnAvailable_) {
            throw std::runtime_error("availability");
        }
        return available_;
    }

    MoonlightVideoSinkStatus submit(
        std::shared_ptr<const MoonlightOwnedVideoAccessUnit> accessUnit) override {
        if (gate_ != nullptr) {
            gate_->enterAndWait();
        }
        if (throwOnSubmit_) {
            throw std::runtime_error("submit");
        }
        std::lock_guard<std::mutex> lock(mutex_);
        submitted_.push_back(std::move(accessUnit));
        return status_;
    }

    void setStatus(MoonlightVideoSinkStatus value) {
        std::lock_guard<std::mutex> lock(mutex_);
        status_ = value;
    }

    std::size_t submitCount() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return submitted_.size();
    }

    std::shared_ptr<const MoonlightOwnedVideoAccessUnit> submitted(
        std::size_t index) const {
        std::lock_guard<std::mutex> lock(mutex_);
        return submitted_.at(index);
    }

    bool available_ = true;
    bool throwOnAvailable_ = false;
    bool throwOnSubmit_ = false;
    VideoGate* gate_ = nullptr;

private:
    mutable std::mutex mutex_;
    MoonlightVideoSinkStatus status_ = MoonlightVideoSinkStatus::Accepted;
    std::vector<std::shared_ptr<const MoonlightOwnedVideoAccessUnit>> submitted_;
};

MoonlightStreamCodecProfile h264() {
    return {MoonlightStreamCodec::H264, MoonlightStreamBitDepth::Bit8,
            MoonlightStreamChroma::Yuv420};
}

MoonlightStreamCodecProfile hevc() {
    return {MoonlightStreamCodec::Hevc, MoonlightStreamBitDepth::Bit10,
            MoonlightStreamChroma::Yuv420};
}

MoonlightStreamCodecProfile av1() {
    return {MoonlightStreamCodec::Av1, MoonlightStreamBitDepth::Bit8,
            MoonlightStreamChroma::Yuv420};
}

struct FragmentSource final {
    MoonlightVideoBufferType type;
    std::vector<std::uint8_t>* bytes;
};

MoonlightVideoDecodeUnitView makeUnit(
    const MoonlightSessionKey& key,
    const MoonlightStreamCodecProfile& profile,
    MoonlightVideoFrameType frameType,
    std::int32_t frameNumber,
    std::initializer_list<FragmentSource> sources,
    std::array<MoonlightVideoFragmentView, 8U>& fragments) {
    RDP_ASSERT(sources.size() <= fragments.size());
    std::size_t index = 0U;
    std::size_t fullLength = 0U;
    for (const auto& source : sources) {
        RDP_ASSERT(source.bytes != nullptr);
        fragments[index] = {
            source.bytes->data(), source.bytes->size(), source.type, nullptr};
        fullLength += source.bytes->size();
        ++index;
    }
    for (std::size_t link = 1U; link < index; ++link) {
        fragments[link - 1U].next = &fragments[link];
    }

    MoonlightVideoDecodeUnitView unit;
    unit.key = key;
    unit.profile = profile;
    unit.frameNumber = frameNumber;
    unit.frameType = frameType;
    unit.hostProcessingLatencyDeciMs = 17U;
    unit.receiveTimeUs = 10U;
    unit.enqueueTimeUs = 20U;
    unit.presentationTimeUs = 30U;
    unit.rtpTimestamp = 9000U + static_cast<std::uint32_t>(frameNumber);
    unit.fullLength = fullLength;
    unit.bufferList = index == 0U ? nullptr : &fragments[0];
    unit.hdrActive = profile.bitDepth == MoonlightStreamBitDepth::Bit10;
    unit.colorSpace = unit.hdrActive ? 2U : 1U;
    return unit;
}

struct H264Fixture final {
    std::vector<std::uint8_t> sps {0x00U, 0x00U, 0x01U, 0x67U};
    std::vector<std::uint8_t> pps {0x00U, 0x00U, 0x01U, 0x68U};
    std::vector<std::uint8_t> picture {0x00U, 0x00U, 0x01U, 0x65U, 0xaaU};
    std::array<MoonlightVideoFragmentView, 8U> fragments {};

    MoonlightVideoDecodeUnitView idr(const MoonlightSessionKey& key,
                                     std::int32_t frameNumber = 1) {
        return makeUnit(key, h264(), MoonlightVideoFrameType::IdR, frameNumber,
                        {{MoonlightVideoBufferType::SequenceParameterSet, &sps},
                         {MoonlightVideoBufferType::PictureParameterSet, &pps},
                         {MoonlightVideoBufferType::PictureData, &picture}},
                        fragments);
    }

    MoonlightVideoDecodeUnitView predicted(const MoonlightSessionKey& key,
                                           std::int32_t frameNumber) {
        return makeUnit(key, h264(), MoonlightVideoFrameType::Predicted, frameNumber,
                        {{MoonlightVideoBufferType::PictureData, &picture}}, fragments);
    }
};

RDP_TEST_CASE(moonlight_video_bridge_copies_all_metadata_fragments_and_h264_config) {
    auto sink = std::make_shared<RecordingVideoSink>();
    auto bridge = MoonlightVideoBridge::createForTesting(sink);
    const MoonlightSessionKey key {9U, 3U, 101U};
    RDP_ASSERT(bridge != nullptr);
    RDP_ASSERT_EQ(bridge->start(key, h264()).status,
                  MoonlightVideoStartStatus::Started);

    H264Fixture fixture;
    auto unit = fixture.idr(key);
    const auto result = bridge->submit(unit);
    RDP_ASSERT_EQ(result.status, MoonlightVideoSubmitStatus::Accepted);
    RDP_ASSERT(result.sinkCalled);
    RDP_ASSERT_EQ(result.ownedBytes, unit.fullLength);
    RDP_ASSERT_EQ(result.fragmentCount, static_cast<std::size_t>(3U));
    RDP_ASSERT_EQ(result.configurationGeneration, static_cast<std::uint64_t>(1U));
    RDP_ASSERT_EQ(sink->submitCount(), static_cast<std::size_t>(1U));

    const auto owned = sink->submitted(0U);
    RDP_ASSERT(owned->key == key);
    RDP_ASSERT_EQ(owned->frameNumber, unit.frameNumber);
    RDP_ASSERT_EQ(owned->hostProcessingLatencyDeciMs,
                  unit.hostProcessingLatencyDeciMs);
    RDP_ASSERT_EQ(owned->receiveTimeUs, unit.receiveTimeUs);
    RDP_ASSERT_EQ(owned->enqueueTimeUs, unit.enqueueTimeUs);
    RDP_ASSERT_EQ(owned->presentationTimeUs, unit.presentationTimeUs);
    RDP_ASSERT_EQ(owned->rtpTimestamp, unit.rtpTimestamp);
    RDP_ASSERT_EQ(owned->hdrActive, unit.hdrActive);
    RDP_ASSERT_EQ(owned->colorSpace, unit.colorSpace);
    RDP_ASSERT_EQ(owned->codecConfigurationGeneration,
                  static_cast<std::uint64_t>(1U));
    RDP_ASSERT(owned->codecConfigurationChanged);
    RDP_ASSERT_EQ(owned->fragments[0].offset, static_cast<std::size_t>(0U));
    RDP_ASSERT_EQ(owned->fragments[1].offset, fixture.sps.size());
    RDP_ASSERT_EQ(owned->fragments[2].offset,
                  fixture.sps.size() + fixture.pps.size());

    fixture.sps.assign(fixture.sps.size(), 0xffU);
    fixture.picture.assign(fixture.picture.size(), 0xeeU);
    RDP_ASSERT_EQ(owned->bytes[3], static_cast<std::uint8_t>(0x67U));
    RDP_ASSERT_EQ(owned->bytes.back(), static_cast<std::uint8_t>(0xaaU));
    const auto config = bridge->configuration(key);
    RDP_ASSERT(config.has_value());
    RDP_ASSERT_EQ(config->sps[3], static_cast<std::uint8_t>(0x67U));
    RDP_ASSERT_EQ(config->pps[3], static_cast<std::uint8_t>(0x68U));
    RDP_ASSERT(config->vps.empty());
    RDP_ASSERT_EQ(bridge->snapshot(key).firstFrameReady, false);
}

RDP_TEST_CASE(moonlight_video_bridge_accepts_locked_hevc_and_av1_fragment_shapes) {
    const MoonlightSessionKey hevcKey {10U, 4U, 102U};
    auto hevcSink = std::make_shared<RecordingVideoSink>();
    auto hevcBridge = MoonlightVideoBridge::createForTesting(hevcSink);
    RDP_ASSERT_EQ(hevcBridge->start(hevcKey, hevc()).status,
                  MoonlightVideoStartStatus::Started);
    std::vector<std::uint8_t> vps {0x40U};
    std::vector<std::uint8_t> sps {0x42U};
    std::vector<std::uint8_t> pps {0x44U};
    std::vector<std::uint8_t> picture {0x26U, 0x01U};
    std::array<MoonlightVideoFragmentView, 8U> hevcFragments {};
    auto hevcUnit = makeUnit(
        hevcKey, hevc(), MoonlightVideoFrameType::IdR, 1,
        {{MoonlightVideoBufferType::VideoParameterSet, &vps},
         {MoonlightVideoBufferType::SequenceParameterSet, &sps},
         {MoonlightVideoBufferType::PictureParameterSet, &pps},
         {MoonlightVideoBufferType::PictureData, &picture}},
        hevcFragments);
    RDP_ASSERT_EQ(hevcBridge->submit(hevcUnit).status,
                  MoonlightVideoSubmitStatus::Accepted);
    const auto hevcConfig = hevcBridge->configuration(hevcKey);
    RDP_ASSERT(hevcConfig.has_value());
    RDP_ASSERT(hevcConfig->vps == vps);
    RDP_ASSERT(hevcConfig->sps == sps);
    RDP_ASSERT(hevcConfig->pps == pps);

    const MoonlightSessionKey av1Key {10U, 5U, 103U};
    auto av1Sink = std::make_shared<RecordingVideoSink>();
    auto av1Bridge = MoonlightVideoBridge::createForTesting(av1Sink);
    RDP_ASSERT_EQ(av1Bridge->start(av1Key, av1()).status,
                  MoonlightVideoStartStatus::Started);
    std::array<MoonlightVideoFragmentView, 8U> av1Fragments {};
    auto av1Unit = makeUnit(
        av1Key, av1(), MoonlightVideoFrameType::IdR, 1,
        {{MoonlightVideoBufferType::PictureData, &picture}}, av1Fragments);
    RDP_ASSERT_EQ(av1Bridge->submit(av1Unit).status,
                  MoonlightVideoSubmitStatus::Accepted);
    RDP_ASSERT_EQ(av1Bridge->configuration(av1Key)->generation,
                  static_cast<std::uint64_t>(1U));
}

RDP_TEST_CASE(moonlight_video_bridge_rejects_malformed_boundary_corpus_before_sink) {
    MoonlightVideoLimits limits;
    limits.maximumFragments = 4U;
    limits.maximumFragmentBytes = 8U;
    limits.maximumAccessUnitBytes = 16U;
    limits.maximumCodecConfigurationBytes = 8U;
    auto sink = std::make_shared<RecordingVideoSink>();
    auto bridge = MoonlightVideoBridge::createForTesting(sink, limits);
    const MoonlightSessionKey key {11U, 6U, 104U};
    RDP_ASSERT_EQ(bridge->start(key, h264()).status,
                  MoonlightVideoStartStatus::Started);

    const auto expectMalformed = [&](MoonlightVideoDecodeUnitView unit) {
        const auto result = bridge->submit(unit);
        RDP_ASSERT_EQ(result.status, MoonlightVideoSubmitStatus::Malformed);
        RDP_ASSERT(!result.sinkCalled);
        RDP_ASSERT(!result.requestIdr);
    };

    H264Fixture fixture;
    auto valid = fixture.idr(key);
    auto malformed = valid;
    malformed.fullLength = 0U;
    expectMalformed(malformed);
    malformed = valid;
    malformed.fullLength += 1U;
    expectMalformed(malformed);
    malformed = valid;
    malformed.frameNumber = -1;
    expectMalformed(malformed);
    malformed = valid;
    malformed.frameType = static_cast<MoonlightVideoFrameType>(9U);
    expectMalformed(malformed);
    malformed = valid;
    malformed.colorSpace = 3U;
    expectMalformed(malformed);
    malformed = valid;
    malformed.receiveTimeUs = malformed.enqueueTimeUs + 1U;
    expectMalformed(malformed);
    malformed = valid;
    malformed.bufferList = nullptr;
    expectMalformed(malformed);
    malformed = valid;
    fixture.fragments[0].type = static_cast<MoonlightVideoBufferType>(9U);
    expectMalformed(malformed);

    valid = fixture.idr(key);
    fixture.fragments[2].next = &fixture.fragments[0];
    expectMalformed(valid);
    valid = fixture.idr(key);
    fixture.fragments[2].data = nullptr;
    expectMalformed(valid);
    valid = fixture.idr(key);
    fixture.fragments[2].length = 9U;
    valid.fullLength = fixture.sps.size() + fixture.pps.size() + 9U;
    expectMalformed(valid);

    std::vector<std::uint8_t> oversizedConfig(5U, 0x01U);
    std::array<MoonlightVideoFragmentView, 8U> configFragments {};
    auto configUnit = makeUnit(
        key, h264(), MoonlightVideoFrameType::IdR, 1,
        {{MoonlightVideoBufferType::SequenceParameterSet, &oversizedConfig},
         {MoonlightVideoBufferType::PictureParameterSet, &oversizedConfig},
         {MoonlightVideoBufferType::PictureData, &fixture.picture}}, configFragments);
    expectMalformed(configUnit);

    std::array<MoonlightVideoFragmentView, 8U> wrongShapeFragments {};
    auto wrongShape = makeUnit(
        key, h264(), MoonlightVideoFrameType::IdR, 1,
        {{MoonlightVideoBufferType::PictureData, &fixture.picture}},
        wrongShapeFragments);
    expectMalformed(wrongShape);
    RDP_ASSERT_EQ(sink->submitCount(), static_cast<std::size_t>(0U));
    RDP_ASSERT_EQ(bridge->snapshot(key).malformedFrames,
                  static_cast<std::uint64_t>(13U));
}

RDP_TEST_CASE(moonlight_video_bridge_idr_gate_coalesces_and_recovers_exactly) {
    auto sink = std::make_shared<RecordingVideoSink>();
    auto bridge = MoonlightVideoBridge::createForTesting(sink);
    const MoonlightSessionKey key {12U, 7U, 105U};
    RDP_ASSERT_EQ(bridge->start(key, h264()).status,
                  MoonlightVideoStartStatus::Started);
    H264Fixture fixture;

    auto firstP = fixture.predicted(key, 1);
    const auto firstDrop = bridge->submit(firstP);
    RDP_ASSERT_EQ(firstDrop.status, MoonlightVideoSubmitStatus::NeedIdr);
    RDP_ASSERT_EQ(firstDrop.dropReason, MoonlightVideoDropReason::WaitingForIdr);
    RDP_ASSERT(firstDrop.requestIdr);
    auto secondP = fixture.predicted(key, 2);
    const auto secondDrop = bridge->submit(secondP);
    RDP_ASSERT_EQ(secondDrop.status, MoonlightVideoSubmitStatus::Dropped);
    RDP_ASSERT(!secondDrop.requestIdr);
    RDP_ASSERT_EQ(sink->submitCount(), static_cast<std::size_t>(0U));

    auto idr = fixture.idr(key, 3);
    RDP_ASSERT_EQ(bridge->submit(idr).status, MoonlightVideoSubmitStatus::Accepted);
    auto acceptedP = fixture.predicted(key, 4);
    RDP_ASSERT_EQ(bridge->submit(acceptedP).status,
                  MoonlightVideoSubmitStatus::Accepted);

    sink->setStatus(MoonlightVideoSinkStatus::Backpressure);
    auto pressuredP = fixture.predicted(key, 5);
    const auto pressure = bridge->submit(pressuredP);
    RDP_ASSERT_EQ(pressure.status, MoonlightVideoSubmitStatus::Backpressure);
    RDP_ASSERT(pressure.requestIdr);
    auto gatedP = fixture.predicted(key, 6);
    const auto gated = bridge->submit(gatedP);
    RDP_ASSERT_EQ(gated.status, MoonlightVideoSubmitStatus::Backpressure);
    RDP_ASSERT_EQ(gated.dropReason, MoonlightVideoDropReason::None);
    RDP_ASSERT(!gated.requestIdr);

    sink->setStatus(MoonlightVideoSinkStatus::Accepted);
    auto recoveryIdr = fixture.idr(key, 7);
    RDP_ASSERT_EQ(bridge->submit(recoveryIdr).status,
                  MoonlightVideoSubmitStatus::Accepted);
    const auto snapshot = bridge->snapshot(key);
    RDP_ASSERT(!snapshot.waitingForIdr);
    RDP_ASSERT(!snapshot.idrRequestPending);
    RDP_ASSERT_EQ(snapshot.acceptedFrames, static_cast<std::uint64_t>(3U));
    RDP_ASSERT_EQ(snapshot.backpressureFrames, static_cast<std::uint64_t>(2U));
}

RDP_TEST_CASE(moonlight_video_bridge_accepts_soft_pressure_frame_and_requests_refresh) {
    auto sink = std::make_shared<RecordingVideoSink>();
    auto bridge = MoonlightVideoBridge::createForTesting(sink);
    const MoonlightSessionKey key {12U, 8U, 106U};
    RDP_ASSERT_EQ(bridge->start(key, h264()).status,
                  MoonlightVideoStartStatus::Started);
    H264Fixture fixture;

    RDP_ASSERT_EQ(bridge->submit(fixture.idr(key, 1)).status,
                  MoonlightVideoSubmitStatus::Accepted);
    sink->setStatus(MoonlightVideoSinkStatus::AcceptedNeedsIdr);
    const auto pressured = bridge->submit(fixture.predicted(key, 2));
    RDP_ASSERT_EQ(pressured.status, MoonlightVideoSubmitStatus::Accepted);
    RDP_ASSERT(pressured.requestIdr);

    sink->setStatus(MoonlightVideoSinkStatus::Accepted);
    const auto later = bridge->submit(fixture.predicted(key, 3));
    RDP_ASSERT_EQ(later.status, MoonlightVideoSubmitStatus::Accepted);
    RDP_ASSERT(!later.requestIdr);
    const auto snapshot = bridge->snapshot(key);
    RDP_ASSERT(!snapshot.waitingForIdr);
    RDP_ASSERT(snapshot.idrRequestPending);
    RDP_ASSERT_EQ(snapshot.acceptedFrames, static_cast<std::uint64_t>(3U));
}

RDP_TEST_CASE(moonlight_video_bridge_configuration_generation_changes_only_on_new_accepted_idr) {
    auto sink = std::make_shared<RecordingVideoSink>();
    auto bridge = MoonlightVideoBridge::createForTesting(sink);
    const MoonlightSessionKey key {13U, 8U, 106U};
    RDP_ASSERT_EQ(bridge->start(key, h264()).status,
                  MoonlightVideoStartStatus::Started);
    H264Fixture fixture;
    auto first = fixture.idr(key, 1);
    RDP_ASSERT_EQ(bridge->submit(first).configurationGeneration,
                  static_cast<std::uint64_t>(1U));
    auto same = fixture.idr(key, 2);
    RDP_ASSERT_EQ(bridge->submit(same).configurationGeneration,
                  static_cast<std::uint64_t>(1U));
    RDP_ASSERT_EQ(sink->submitted(1U)->codecConfigurationGeneration,
                  static_cast<std::uint64_t>(1U));
    RDP_ASSERT(!sink->submitted(1U)->codecConfigurationChanged);

    sink->setStatus(MoonlightVideoSinkStatus::NeedIdr);
    fixture.sps[3] = 0x69U;
    auto rejected = fixture.idr(key, 3);
    const auto rejectedResult = bridge->submit(rejected);
    RDP_ASSERT_EQ(rejectedResult.status, MoonlightVideoSubmitStatus::NeedIdr);
    RDP_ASSERT_EQ(rejectedResult.configurationGeneration,
                  static_cast<std::uint64_t>(1U));
    RDP_ASSERT(!bridge->configuration(key).has_value());

    sink->setStatus(MoonlightVideoSinkStatus::Accepted);
    auto changed = fixture.idr(key, 4);
    const auto changedResult = bridge->submit(changed);
    RDP_ASSERT_EQ(changedResult.configurationGeneration,
                  static_cast<std::uint64_t>(2U));
    RDP_ASSERT_EQ(sink->submitted(3U)->codecConfigurationGeneration,
                  static_cast<std::uint64_t>(2U));
    RDP_ASSERT(sink->submitted(3U)->codecConfigurationChanged);
    RDP_ASSERT_EQ(bridge->configuration(key)->sps[3], static_cast<std::uint8_t>(0x69U));
}

RDP_TEST_CASE(moonlight_video_bridge_rejects_duplicate_reverse_stale_and_sink_failures) {
    auto sink = std::make_shared<RecordingVideoSink>();
    auto bridge = MoonlightVideoBridge::createForTesting(sink);
    const MoonlightSessionKey key {14U, 9U, 107U};
    RDP_ASSERT_EQ(bridge->start(key, h264()).status,
                  MoonlightVideoStartStatus::Started);
    H264Fixture fixture;
    auto idr = fixture.idr(key, 4);
    RDP_ASSERT_EQ(bridge->submit(idr).status, MoonlightVideoSubmitStatus::Accepted);
    auto duplicate = fixture.predicted(key, 4);
    RDP_ASSERT_EQ(bridge->submit(duplicate).dropReason,
                  MoonlightVideoDropReason::DuplicateOrReordered);
    auto reverse = fixture.predicted(key, 3);
    RDP_ASSERT_EQ(bridge->submit(reverse).dropReason,
                  MoonlightVideoDropReason::DuplicateOrReordered);

    auto stale = fixture.predicted({14U, 10U, 108U}, 5);
    RDP_ASSERT_EQ(bridge->submit(stale).status, MoonlightVideoSubmitStatus::Stale);
    stale = fixture.predicted(key, 5);
    stale.profile = hevc();
    RDP_ASSERT_EQ(bridge->submit(stale).status, MoonlightVideoSubmitStatus::Stale);

    sink->setStatus(MoonlightVideoSinkStatus::Stale);
    auto staleSink = fixture.predicted(key, 5);
    RDP_ASSERT_EQ(bridge->submit(staleSink).status,
                  MoonlightVideoSubmitStatus::Stale);
    sink->setStatus(MoonlightVideoSinkStatus::Unsupported);
    auto unsupported = fixture.predicted(key, 6);
    RDP_ASSERT_EQ(bridge->submit(unsupported).status,
                  MoonlightVideoSubmitStatus::Unsupported);
    sink->setStatus(MoonlightVideoSinkStatus::Failed);
    auto failed = fixture.predicted(key, 7);
    RDP_ASSERT_EQ(bridge->submit(failed).status,
                  MoonlightVideoSubmitStatus::SinkFailure);
    sink->throwOnSubmit_ = true;
    auto exceptional = fixture.predicted(key, 8);
    RDP_ASSERT_EQ(bridge->submit(exceptional).status,
                  MoonlightVideoSubmitStatus::SinkFailure);
}

RDP_TEST_CASE(moonlight_video_bridge_start_stop_owner_highwater_and_runtime_proof_are_exact) {
    const MoonlightSessionKey key {15U, 10U, 109U};
    RDP_ASSERT_EQ(MoonlightVideoBridge::process().start(key, h264()).status,
                  MoonlightVideoStartStatus::RuntimeProofRequired);

    auto unavailableSink = std::make_shared<RecordingVideoSink>();
    unavailableSink->available_ = false;
    auto unavailable = MoonlightVideoBridge::createForTesting(unavailableSink);
    RDP_ASSERT_EQ(unavailable->start(key, h264()).status,
                  MoonlightVideoStartStatus::RuntimeProofRequired);

    auto throwingSink = std::make_shared<RecordingVideoSink>();
    throwingSink->throwOnAvailable_ = true;
    auto throwing = MoonlightVideoBridge::createForTesting(throwingSink);
    RDP_ASSERT_EQ(throwing->start(key, h264()).status,
                  MoonlightVideoStartStatus::InternalFailure);

    auto sink = std::make_shared<RecordingVideoSink>();
    auto bridge = MoonlightVideoBridge::createForTesting(sink);
    RDP_ASSERT_EQ(bridge->start({}, h264()).status,
                  MoonlightVideoStartStatus::InvalidRequest);
    auto invalidProfile = h264();
    invalidProfile.bitDepth = static_cast<MoonlightStreamBitDepth>(9U);
    RDP_ASSERT_EQ(bridge->start(key, invalidProfile).status,
                  MoonlightVideoStartStatus::InvalidRequest);
    RDP_ASSERT_EQ(bridge->start(key, h264()).status,
                  MoonlightVideoStartStatus::Started);
    RDP_ASSERT_EQ(bridge->start({15U, 11U, 110U}, h264()).status,
                  MoonlightVideoStartStatus::Busy);
    RDP_ASSERT_EQ(bridge->stop({15U, 11U, 110U}), MoonlightVideoStopStatus::Stale);
    RDP_ASSERT_EQ(bridge->stop(key), MoonlightVideoStopStatus::Stopped);
    RDP_ASSERT_EQ(bridge->stop(key), MoonlightVideoStopStatus::AlreadyStopped);
    RDP_ASSERT_EQ(bridge->start({15U, 11U, 109U}, h264()).status,
                  MoonlightVideoStartStatus::InvalidRequest);
    const MoonlightSessionKey next {15U, 11U, 110U};
    RDP_ASSERT_EQ(bridge->start(next, h264()).status,
                  MoonlightVideoStartStatus::Started);
    RDP_ASSERT_EQ(bridge->snapshot(next).firstFrameReady, false);

    MoonlightVideoLimits invalidLimits;
    invalidLimits.maximumFragments = 0U;
    RDP_ASSERT(MoonlightVideoBridge::createForTesting(sink, invalidLimits) == nullptr);
}

RDP_TEST_CASE(moonlight_video_bridge_stop_timeout_closes_admission_then_drains_exactly) {
    auto sink = std::make_shared<RecordingVideoSink>();
    VideoGate gate;
    sink->gate_ = &gate;
    auto bridge = MoonlightVideoBridge::createForTesting(sink);
    const MoonlightSessionKey key {16U, 12U, 111U};
    RDP_ASSERT_EQ(bridge->start(key, h264()).status,
                  MoonlightVideoStartStatus::Started);
    auto fixture = std::make_shared<H264Fixture>();
    auto unit = std::make_shared<MoonlightVideoDecodeUnitView>(fixture->idr(key));
    auto result = std::make_shared<MoonlightVideoSubmitResult>();
    RdpTestThreadScope submitter([&]() { gate.release(); });
    submitter.start([&, fixture, unit, result]() {
        *result = bridge->submit(*unit);
    });
    RDP_ASSERT(gate.waitEntered());
    RDP_ASSERT_EQ(bridge->stop(key, 1ms), MoonlightVideoStopStatus::TimedOut);
    const auto duringStop = bridge->snapshot(key);
    RDP_ASSERT(duringStop.running);
    RDP_ASSERT(!duringStop.admissionOpen);
    RDP_ASSERT_EQ(duringStop.inFlightSubmissions, static_cast<std::size_t>(1U));
    gate.release();
    submitter.cancelAndJoin();
    RDP_ASSERT_EQ(result->status, MoonlightVideoSubmitStatus::Dropped);
    RDP_ASSERT_EQ(result->dropReason, MoonlightVideoDropReason::Teardown);
    RDP_ASSERT_EQ(bridge->stop(key, 1s), MoonlightVideoStopStatus::Stopped);
    RDP_ASSERT(!bridge->configuration(key).has_value());
    RDP_ASSERT_EQ(bridge->snapshot(key).firstFrameReady, false);
}

} // namespace
