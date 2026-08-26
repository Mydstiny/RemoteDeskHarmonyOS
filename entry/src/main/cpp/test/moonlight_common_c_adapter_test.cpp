#include "moonlight/media/MoonlightCommonCAdapter.h"
#include "test/test_runner.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <thread>

namespace {

using namespace remotedesk::moonlight;
using namespace std::chrono_literals;

class AdapterGate final {
public:
    void enterAndWait() {
        std::unique_lock<std::mutex> lock(mutex_);
        entered_ = true;
        cv_.notify_all();
        cv_.wait(lock, [&]() { return released_; });
    }

    void enter() {
        std::lock_guard<std::mutex> lock(mutex_);
        entered_ = true;
        cv_.notify_all();
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

class FakeMediaPort final : public MoonlightCommonCMediaPort {
public:
    bool bindSession(const MoonlightSessionKey& key) noexcept override {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            boundKey_ = key;
        }
        ++binds_;
        return acceptBind_.load();
    }
    void releaseSession(const MoonlightSessionKey& key) noexcept override {
        videoLive_.store(false);
        audioLive_.store(false);
        {
            std::lock_guard<std::mutex> lock(mutex_);
            releasedKey_ = key;
        }
        ++releases_;
    }
    bool firstFrameReady() const noexcept override {
        return firstFrameReady_.load();
    }
    bool videoLive() const noexcept override { return videoLive_.load(); }
    bool audioLive() const noexcept override { return audioLive_.load(); }
    bool videoReady() const noexcept override { return videoReady_.load(); }
    bool audioReady(MoonlightStreamAudioLayout) const noexcept override {
        return audioReady_.load();
    }
    bool setupVideo(const MoonlightCommonCVideoSelection& selection) noexcept override {
        if (videoSetupGate_ != nullptr) {
            videoSetupGate_->enterAndWait();
        }
        std::lock_guard<std::mutex> lock(mutex_);
        videoSelection_ = selection;
        ++videoSetups_;
        return acceptVideo_.load();
    }
    void startVideo() noexcept override {
        videoLive_.store(true);
        ++videoStarts_;
    }
    void stopVideo() noexcept override {
        videoLive_.store(false);
        ++videoStops_;
    }
    void cleanupVideo() noexcept override {
        videoLive_.store(false);
        ++videoCleanups_;
    }
    MoonlightVideoSubmitResult submitVideoPayload(
        const MoonlightVideoDecodeUnitView& decodeUnit) noexcept override {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            videoPayloadKey_ = decodeUnit.key;
            videoPayloadProfile_ = decodeUnit.profile;
            videoPayloadFrameNumber_ = decodeUnit.frameNumber;
        }
        ++videoPayloads_;
        MoonlightVideoSubmitResult result;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            result.status = videoSubmitStatus_;
            result.requestIdr = videoSubmitRequestIdr_;
        }
        result.sinkCalled = true;
        result.ownedBytes = decodeUnit.fullLength;
        return result;
    }
    bool setupAudio(const MoonlightCommonCAudioSelection& selection) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        audioSelection_ = selection;
        ++audioSetups_;
        return acceptAudio_.load();
    }
    void startAudio() noexcept override {
        audioLive_.store(true);
        ++audioStarts_;
    }
    void stopAudio() noexcept override {
        audioLive_.store(false);
        ++audioStops_;
    }
    void cleanupAudio() noexcept override {
        audioLive_.store(false);
        ++audioCleanups_;
    }
    void submitAudioPayload(const std::uint8_t* bytes,
                            std::size_t byteCount) noexcept override {
        ++audioPayloads_;
        audioPayloadBytes_.fetch_add(byteCount);
        if (bytes == nullptr && byteCount == 0U) {
            ++audioPlcPayloads_;
        }
    }

    void setReady(bool video, bool audio) noexcept {
        videoReady_.store(video);
        audioReady_.store(audio);
    }
    void rejectBind() noexcept { acceptBind_.store(false); }
    void setFirstFrameReady(bool ready) noexcept { firstFrameReady_.store(ready); }
    void rejectVideo() noexcept { acceptVideo_.store(false); }
    void rejectAudio() noexcept { acceptAudio_.store(false); }
    void blockVideoSetup(AdapterGate& gate) noexcept { videoSetupGate_ = &gate; }
    void setVideoSubmitResult(MoonlightVideoSubmitStatus status,
                              bool requestIdr) noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        videoSubmitStatus_ = status;
        videoSubmitRequestIdr_ = requestIdr;
    }
    std::size_t videoSetups() const noexcept { return videoSetups_.load(); }
    std::size_t audioSetups() const noexcept { return audioSetups_.load(); }
    std::size_t videoStops() const noexcept { return videoStops_.load(); }
    std::size_t audioStops() const noexcept { return audioStops_.load(); }
    std::size_t videoCleanups() const noexcept { return videoCleanups_.load(); }
    std::size_t audioCleanups() const noexcept { return audioCleanups_.load(); }
    std::size_t videoPayloads() const noexcept { return videoPayloads_.load(); }
    MoonlightSessionKey videoPayloadKey() const noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        return videoPayloadKey_;
    }
    MoonlightStreamCodecProfile videoPayloadProfile() const noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        return videoPayloadProfile_;
    }
    std::int32_t videoPayloadFrameNumber() const noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        return videoPayloadFrameNumber_;
    }
    std::size_t audioPayloads() const noexcept { return audioPayloads_.load(); }
    std::size_t audioPayloadBytes() const noexcept { return audioPayloadBytes_.load(); }
    std::size_t audioPlcPayloads() const noexcept { return audioPlcPayloads_.load(); }
    std::size_t binds() const noexcept { return binds_.load(); }
    std::size_t releases() const noexcept { return releases_.load(); }
    MoonlightSessionKey boundKey() const noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        return boundKey_;
    }
    MoonlightSessionKey releasedKey() const noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        return releasedKey_;
    }

private:
    mutable std::mutex mutex_;
    std::atomic<bool> videoReady_ {true};
    std::atomic<bool> audioReady_ {true};
    std::atomic<bool> acceptVideo_ {true};
    std::atomic<bool> acceptAudio_ {true};
    std::atomic<bool> acceptBind_ {true};
    std::atomic<bool> firstFrameReady_ {false};
    std::atomic<bool> videoLive_ {false};
    std::atomic<bool> audioLive_ {false};
    std::atomic<std::size_t> binds_ {0U};
    std::atomic<std::size_t> releases_ {0U};
    std::atomic<std::size_t> videoSetups_ {0U};
    std::atomic<std::size_t> audioSetups_ {0U};
    std::atomic<std::size_t> videoStarts_ {0U};
    std::atomic<std::size_t> audioStarts_ {0U};
    std::atomic<std::size_t> videoStops_ {0U};
    std::atomic<std::size_t> audioStops_ {0U};
    std::atomic<std::size_t> videoCleanups_ {0U};
    std::atomic<std::size_t> audioCleanups_ {0U};
    std::atomic<std::size_t> videoPayloads_ {0U};
    std::atomic<std::size_t> audioPayloads_ {0U};
    std::atomic<std::size_t> audioPayloadBytes_ {0U};
    std::atomic<std::size_t> audioPlcPayloads_ {0U};
    std::optional<MoonlightCommonCVideoSelection> videoSelection_;
    std::optional<MoonlightCommonCAudioSelection> audioSelection_;
    MoonlightSessionKey videoPayloadKey_ {};
    MoonlightSessionKey boundKey_ {};
    MoonlightSessionKey releasedKey_ {};
    MoonlightStreamCodecProfile videoPayloadProfile_ {};
    std::int32_t videoPayloadFrameNumber_ = -1;
    MoonlightVideoSubmitStatus videoSubmitStatus_ =
        MoonlightVideoSubmitStatus::Accepted;
    bool videoSubmitRequestIdr_ = false;
    AdapterGate* videoSetupGate_ = nullptr;
};

MoonlightStreamCodecProfile h264Profile() {
    return {MoonlightStreamCodec::H264, MoonlightStreamBitDepth::Bit8,
            MoonlightStreamChroma::Yuv420};
}

MoonlightVideoDecodeUnitView testVideoPayload(
    std::uint8_t* bytes, std::size_t byteCount,
    MoonlightVideoFragmentView& fragment,
    std::int32_t frameNumber = 1) {
    fragment = {bytes, byteCount, MoonlightVideoBufferType::PictureData, nullptr};
    MoonlightVideoDecodeUnitView unit;
    unit.frameNumber = frameNumber;
    unit.frameType = MoonlightVideoFrameType::Predicted;
    unit.receiveTimeUs = 10U;
    unit.enqueueTimeUs = 20U;
    unit.presentationTimeUs = 30U;
    unit.fullLength = byteCount;
    unit.bufferList = &fragment;
    unit.colorSpace = 1U;
    return unit;
}

MoonlightStreamCodecProfile hevcMain8Profile() {
    return {MoonlightStreamCodec::Hevc, MoonlightStreamBitDepth::Bit8,
            MoonlightStreamChroma::Yuv420};
}

MoonlightStreamCodecProfile av1Main8Profile() {
    return {MoonlightStreamCodec::Av1, MoonlightStreamBitDepth::Bit8,
            MoonlightStreamChroma::Yuv420};
}

MoonlightCommonCOpusConfig opusForLayout(MoonlightStreamAudioLayout layout) {
    MoonlightCommonCOpusConfig opus;
    opus.sampleRate = 48000;
    opus.samplesPerFrame = 240;
    if (layout == MoonlightStreamAudioLayout::Surround51) {
        opus.channelCount = 6;
        opus.streams = 4;
        opus.coupledStreams = 2;
        opus.mapping = {0U, 4U, 1U, 5U, 2U, 3U, 0U, 0U};
    } else if (layout == MoonlightStreamAudioLayout::Surround71) {
        opus.channelCount = 8;
        opus.streams = 5;
        opus.coupledStreams = 3;
        opus.mapping = {0U, 6U, 1U, 7U, 2U, 3U, 4U, 5U};
    } else {
        opus.channelCount = 2;
        opus.streams = 1;
        opus.coupledStreams = 1;
        opus.mapping = {0U, 1U, 0U, 0U, 0U, 0U, 0U, 0U};
    }
    return opus;
}

MoonlightCommonCRequest makeRequest(
    std::uint64_t now, std::uint64_t sessionId = 700U,
    std::uint64_t generation = 9U, std::uint64_t accountOwnerToken = 101U,
    MoonlightStreamAudioLayout audioLayout = MoonlightStreamAudioLayout::Stereo,
    MoonlightStreamNetworkPath networkPath = MoonlightStreamNetworkPath::Local) {
    MoonlightCommonCRequest request;
    request.sessionId = sessionId;
    request.generation = generation;
    request.accountOwnerToken = accountOwnerToken;
    request.streamConfig.status = MoonlightStreamResultStatus::OfferReady;
    request.streamConfig.code = MoonlightStreamResultCode::None;
    request.streamConfig.identity.ownerToken = accountOwnerToken;
    request.streamConfig.identity.sessionGeneration = generation;
    request.streamConfig.identity.hostId = "host-700";
    request.streamConfig.identity.serverUuid = "server-uuid-700";
    request.streamConfig.identity.settingsRevision = 17U;
    request.streamConfig.identity.hostCapabilityGeneration = 31U;
    request.streamConfig.identity.platformProbeGeneration = 32U;
    request.streamConfig.identity.networkCapabilityGeneration = 33U;
    request.streamConfig.identity.displayCapabilityGeneration = 34U;

    MoonlightEffectiveStreamOffer offer;
    offer.dimensions = {1920, 1080};
    offer.fps = 60;
    offer.launchRefreshRate = 60;
    offer.clientRefreshRateX100 = 5994;
    offer.configuredBitrateKbps = 20000;
    offer.estimatedEncoderBitrateKbps = 16000;
    offer.packetSizeBytes = 1024;
    offer.networkPath = networkPath;
    offer.latencyMode = MoonlightStreamLatencyMode::LowLatency;
    offer.offeredCodecs = {
        {MoonlightStreamCodec::H264, MoonlightStreamBitDepth::Bit8,
         MoonlightStreamChroma::Yuv420, true, true, true},
        {MoonlightStreamCodec::Hevc, MoonlightStreamBitDepth::Bit8,
         MoonlightStreamChroma::Yuv420, false, true, true},
        {MoonlightStreamCodec::Av1, MoonlightStreamBitDepth::Bit8,
         MoonlightStreamChroma::Yuv420, false, true, true},
    };
    offer.hdr = false;
    offer.yuv444 = false;
    offer.colorSpace = MoonlightStreamColorSpace::Rec709;
    offer.colorRange = MoonlightStreamColorRange::Limited;
    offer.audioLayout = audioLayout;
    offer.playAudioOnHost = false;
    offer.highQualityAudioCandidate = false;
    offer.encryptionPolicy = MoonlightStreamEncryptionPolicy::Auto;
    offer.requiredEncryptionStreams = MoonlightStreamEncryptNone;
    offer.candidateEncryptionStreams =
        MoonlightStreamEncryptAudio | MoonlightStreamEncryptVideo;
    offer.remoteInputEncryptionRequired = true;
    request.streamConfig.offer = offer;

    MoonlightLaunchProjection launch;
    launch.dimensions = offer.dimensions;
    launch.fps = offer.fps;
    launch.audioLayout = audioLayout;
    request.streamConfig.launchProjection = launch;
    request.server.address = "192.0.2.44";
    request.server.appVersion = "7.1.431.-1";
    request.server.gfeVersion = "3.26.0.131";
    request.server.authenticated = true;
    request.server.hostCapabilityGeneration = 31U;
    request.server.codecProfiles = {
        h264Profile(), hevcMain8Profile(), av1Main8Profile()};
    std::array<std::uint8_t, 16U> key {};
    for (std::size_t index = 0U; index < key.size(); ++index) {
        key[index] = static_cast<std::uint8_t>(index + 1U);
    }
    request.launchLease = MoonlightRtspLaunchLease(
        key, 0x01020304, "rtsp://192.0.2.44:48010/session/700",
        accountOwnerToken, generation, "host-700", "server-uuid-700", 31U, 17U);
    request.deadlines.overallMonotonicMs = now + 10000U;
    request.deadlines.stageMonotonicMs.fill(now + 5000U);
    return request;
}

bool driveStagesWithNegotiation(
    MoonlightStreamAudioLayout layout = MoonlightStreamAudioLayout::Stereo,
    std::int32_t firstStage = 1) {
    for (std::int32_t stage = firstStage; stage <= 11; ++stage) {
        if (!MoonlightCommonCTestHarness::stageStarting(stage)) {
            return false;
        }
        if (stage == 9) {
            if (MoonlightCommonCTestHarness::videoSetup(
                    MoonlightCommonCTestHarness::videoFormatForProfile(h264Profile()),
                    1920, 1080, 60) != 0 ||
                !MoonlightCommonCTestHarness::videoStart()) {
                return false;
            }
        }
        if (stage == 10) {
            const auto wire = MoonlightCommonCTestHarness::wireSnapshot();
            if (!wire.has_value() ||
                MoonlightCommonCTestHarness::audioInit(
                    wire->audioConfiguration, opusForLayout(layout)) != 0 ||
                !MoonlightCommonCTestHarness::audioStart()) {
                return false;
            }
        }
        if (!MoonlightCommonCTestHarness::stageComplete(stage)) {
            return false;
        }
    }
    return MoonlightCommonCTestHarness::connectionStarted();
}

bool driveUntilVideoStartStage() {
    for (std::int32_t stage = 1; stage <= 8; ++stage) {
        if (!MoonlightCommonCTestHarness::stageStarting(stage) ||
            !MoonlightCommonCTestHarness::stageComplete(stage)) {
            return false;
        }
    }
    return MoonlightCommonCTestHarness::stageStarting(9);
}

bool driveUntilAudioStartStage() {
    if (!driveUntilVideoStartStage()) {
        return false;
    }
    if (MoonlightCommonCTestHarness::videoSetup(
            MoonlightCommonCTestHarness::videoFormatForProfile(h264Profile()),
            1920, 1080, 60) != 0 ||
        !MoonlightCommonCTestHarness::videoStart() ||
        !MoonlightCommonCTestHarness::stageComplete(9)) {
        return false;
    }
    return MoonlightCommonCTestHarness::stageStarting(10);
}

std::unique_ptr<MoonlightCommonCAdapter> makeAdapter(
    MoonlightSessionOwner& owner, MoonlightCommonCTestDriver driver,
    const std::shared_ptr<FakeMediaPort>& media,
    const std::shared_ptr<std::atomic<std::uint64_t>>& clock) {
    return MoonlightCommonCAdapter::createForTesting(
        owner, std::move(driver), media,
        [clock]() { return clock->load(); });
}

} // namespace

RDP_TEST_CASE(moonlight_common_c_adapter_rejects_invalid_and_unproven_runtime) {
    auto owner = MoonlightSessionOwner::createForTesting();
    auto media = std::make_shared<FakeMediaPort>();
    auto clock = std::make_shared<std::atomic<std::uint64_t>>(1000U);
    std::atomic<int> starts {0};
    MoonlightCommonCTestDriver driver {
        [&]() { ++starts; return 0; }, []() {}, []() {}};
    auto adapter = makeAdapter(*owner, std::move(driver), media, clock);
    RDP_ASSERT(adapter != nullptr);

    auto invalid = makeRequest(clock->load());
    invalid.sessionId = 0U;
    RDP_ASSERT_EQ(adapter->start(std::move(invalid)).status,
                  MoonlightCommonCStartStatus::InvalidRequest);
    media->setReady(false, false);
    const auto unproven = adapter->start(makeRequest(clock->load()));
    RDP_ASSERT_EQ(unproven.status, MoonlightCommonCStartStatus::Accepted);
    RDP_ASSERT(owner->waitForPhase(
        unproven.key, MoonlightSessionPhase::Failed, 1s));
    const auto snapshot = adapter->snapshot(unproven.key);
    RDP_ASSERT_EQ(snapshot.terminalCode,
                  MoonlightCommonCCode::RuntimeProofRequired);
    RDP_ASSERT_EQ(media->binds(), 1U);
    RDP_ASSERT_EQ(media->releases(), 1U);
    RDP_ASSERT(media->boundKey() == unproven.key);
    RDP_ASSERT(media->releasedKey() == unproven.key);
    RDP_ASSERT_EQ(starts.load(), 0);
}

RDP_TEST_CASE(moonlight_common_c_adapter_binds_exact_owner_and_projects_first_frame_truth) {
    auto owner = MoonlightSessionOwner::createForTesting();
    auto media = std::make_shared<FakeMediaPort>();
    auto clock = std::make_shared<std::atomic<std::uint64_t>>(1250U);
    AdapterGate runningGate;
    MoonlightCommonCTestDriver driver {
        [&]() {
            if (!driveStagesWithNegotiation()) { return -1; }
            runningGate.enterAndWait();
            return 0;
        },
        [&]() { runningGate.release(); },
        []() {}};
    auto adapter = makeAdapter(*owner, std::move(driver), media, clock);
    const auto accepted = adapter->start(makeRequest(clock->load()));
    RDP_ASSERT_EQ(accepted.status, MoonlightCommonCStartStatus::Accepted);
    RDP_ASSERT(runningGate.waitEntered());
    RDP_ASSERT_EQ(media->binds(), 1U);
    RDP_ASSERT(media->boundKey() == accepted.key);
    RDP_ASSERT(!adapter->snapshot(accepted.key).firstFrameReady);
    media->setFirstFrameReady(true);
    RDP_ASSERT(adapter->snapshot(accepted.key).firstFrameReady);
    RDP_ASSERT_EQ(adapter->stop(accepted.key, 1s), MoonlightStopStatus::Stopped);
    RDP_ASSERT_EQ(media->releases(), 1U);
    RDP_ASSERT(media->releasedKey() == accepted.key);
}

RDP_TEST_CASE(moonlight_common_c_adapter_rejects_zero_return_without_negotiation_proof) {
    auto owner = MoonlightSessionOwner::createForTesting();
    auto media = std::make_shared<FakeMediaPort>();
    auto clock = std::make_shared<std::atomic<std::uint64_t>>(1500U);
    MoonlightCommonCTestDriver driver {
        []() { return 0; }, []() {}, []() {}};
    auto adapter = makeAdapter(*owner, std::move(driver), media, clock);
    const auto accepted = adapter->start(makeRequest(clock->load()));
    RDP_ASSERT_EQ(accepted.status, MoonlightCommonCStartStatus::Accepted);
    RDP_ASSERT(owner->waitForPhase(
        accepted.key, MoonlightSessionPhase::Failed, 1s));
    const auto snapshot = adapter->snapshot(accepted.key);
    RDP_ASSERT(snapshot.protocolViolation);
    RDP_ASSERT_EQ(snapshot.terminalCode,
                  MoonlightCommonCCode::ProtocolViolation);
    RDP_ASSERT(snapshot.secretsCleared);
}

RDP_TEST_CASE(moonlight_common_c_adapter_maps_all_wire_fields_and_big_endian_iv) {
    auto owner = MoonlightSessionOwner::createForTesting();
    auto media = std::make_shared<FakeMediaPort>();
    auto clock = std::make_shared<std::atomic<std::uint64_t>>(2000U);
    AdapterGate startGate;
    std::mutex wireMutex;
    std::optional<MoonlightCommonCTestWireSnapshot> captured;
    MoonlightCommonCTestDriver driver {
        [&]() {
            {
                std::lock_guard<std::mutex> lock(wireMutex);
                captured = MoonlightCommonCTestHarness::wireSnapshot();
            }
            if (!MoonlightCommonCTestHarness::stageStarting(1)) {
                return -1;
            }
            startGate.enterAndWait();
            if (!MoonlightCommonCTestHarness::stageComplete(1)) {
                return -1;
            }
            return driveStagesWithNegotiation(
                       MoonlightStreamAudioLayout::Stereo, 2) ? 0 : -1;
        },
        [&]() { startGate.release(); },
        []() {}};
    auto adapter = makeAdapter(*owner, std::move(driver), media, clock);
    auto request = makeRequest(clock->load());
    std::array<std::uint8_t, 16U> remoteInputKey {};
    for (std::size_t index = 0U; index < remoteInputKey.size(); ++index) {
        remoteInputKey[index] = static_cast<std::uint8_t>(index + 1U);
    }
    request.launchLease = MoonlightRtspLaunchLease(
        remoteInputKey, 0x01020304,
        "rtspenc://192.0.2.44:48010/session/700", 101U, 9U,
        "host-700", "server-uuid-700", 31U, 17U);
    const auto accepted = adapter->start(std::move(request));
    RDP_ASSERT_EQ(accepted.status, MoonlightCommonCStartStatus::Accepted);
    RDP_ASSERT(startGate.waitEntered());
    {
        std::lock_guard<std::mutex> lock(wireMutex);
        RDP_ASSERT(captured.has_value() && captured->valid);
        RDP_ASSERT(captured->address == "192.0.2.44");
        RDP_ASSERT(captured->appVersion == "7.1.431.-1");
        RDP_ASSERT(captured->rtspSessionUrl ==
                   "rtspenc://192.0.2.44:48010/session/700");
        RDP_ASSERT_EQ(captured->width, 1920);
        RDP_ASSERT_EQ(captured->height, 1080);
        RDP_ASSERT_EQ(captured->fps, 60);
        RDP_ASSERT_EQ(captured->bitrate, 20000);
        RDP_ASSERT_EQ(captured->packetSize, 1024);
        RDP_ASSERT_EQ(captured->streamingRemotely, 0);
        RDP_ASSERT_EQ(captured->clientRefreshRateX100, 5994);
        RDP_ASSERT_EQ(captured->serverCodecModeSupport, 0x00010101);
        RDP_ASSERT_EQ(captured->supportedVideoFormats, 0x00001101);
        RDP_ASSERT_EQ(captured->encryptionFlags, 3);
        RDP_ASSERT_EQ(captured->remoteInputIv[0], static_cast<std::uint8_t>(1));
        RDP_ASSERT_EQ(captured->remoteInputIv[1], static_cast<std::uint8_t>(2));
        RDP_ASSERT_EQ(captured->remoteInputIv[2], static_cast<std::uint8_t>(3));
        RDP_ASSERT_EQ(captured->remoteInputIv[3], static_cast<std::uint8_t>(4));
        for (std::size_t index = 0U; index < 16U; ++index) {
            RDP_ASSERT_EQ(captured->remoteInputKey[index],
                          static_cast<std::uint8_t>(index + 1U));
        }
    }
    const auto negative = MoonlightCommonCTestHarness::remoteInputIv(-2);
    RDP_ASSERT_EQ(negative[0], static_cast<std::uint8_t>(0xff));
    RDP_ASSERT_EQ(negative[1], static_cast<std::uint8_t>(0xff));
    RDP_ASSERT_EQ(negative[2], static_cast<std::uint8_t>(0xff));
    RDP_ASSERT_EQ(negative[3], static_cast<std::uint8_t>(0xfe));
    const auto minimum = MoonlightCommonCTestHarness::remoteInputIv(
        std::numeric_limits<std::int32_t>::min());
    const auto maximum = MoonlightCommonCTestHarness::remoteInputIv(
        std::numeric_limits<std::int32_t>::max());
    RDP_ASSERT_EQ(minimum[0], static_cast<std::uint8_t>(0x80));
    RDP_ASSERT_EQ(maximum[0], static_cast<std::uint8_t>(0x7f));
    RDP_ASSERT_EQ(maximum[3], static_cast<std::uint8_t>(0xff));
    startGate.release();
    RDP_ASSERT(owner->waitForPhase(accepted.key, MoonlightSessionPhase::Running, 1s));
    RDP_ASSERT_EQ(adapter->stop(accepted.key, 1s), MoonlightStopStatus::Stopped);
    RDP_ASSERT(adapter->snapshot(accepted.key).secretsCleared);
}

RDP_TEST_CASE(moonlight_common_c_adapter_deferred_runtime_proof_uses_auto_path) {
    auto owner = MoonlightSessionOwner::createForTesting();
    auto media = std::make_shared<FakeMediaPort>();
    auto clock = std::make_shared<std::atomic<std::uint64_t>>(2500U);
    AdapterGate startGate;
    std::mutex wireMutex;
    std::optional<MoonlightCommonCTestWireSnapshot> captured;
    MoonlightCommonCTestDriver driver {
        [&]() {
            {
                std::lock_guard<std::mutex> lock(wireMutex);
                captured = MoonlightCommonCTestHarness::wireSnapshot();
            }
            startGate.enterAndWait();
            return driveStagesWithNegotiation() ? 0 : -1;
        },
        [&]() { startGate.release(); },
        []() {}};
    auto adapter = makeAdapter(*owner, std::move(driver), media, clock);
    auto request = makeRequest(
        clock->load(), 700U, 9U, 101U,
        MoonlightStreamAudioLayout::Stereo,
        MoonlightStreamNetworkPath::Unknown);
    request.deferRuntimeCapabilityProof = true;
    request.streamConfig.identity.platformProbeGeneration = 0U;
    request.streamConfig.identity.networkCapabilityGeneration = 0U;
    request.streamConfig.identity.displayCapabilityGeneration = 0U;
    request.streamConfig.offer->clientRefreshRateX100 = 0;

    const auto accepted = adapter->start(std::move(request));
    RDP_ASSERT_EQ(accepted.status, MoonlightCommonCStartStatus::Accepted);
    RDP_ASSERT(startGate.waitEntered());
    {
        std::lock_guard<std::mutex> lock(wireMutex);
        RDP_ASSERT(captured.has_value() && captured->valid);
        RDP_ASSERT_EQ(captured->streamingRemotely, 2);
        RDP_ASSERT_EQ(captured->packetSize, 1024);
        RDP_ASSERT_EQ(captured->clientRefreshRateX100, 0);
    }
    startGate.release();
    RDP_ASSERT(owner->waitForPhase(accepted.key, MoonlightSessionPhase::Running, 1s));
    RDP_ASSERT_EQ(adapter->stop(accepted.key, 1s), MoonlightStopStatus::Stopped);
}

RDP_TEST_CASE(moonlight_common_c_adapter_remote_input_secret_wipe_seam) {
    std::array<std::uint8_t, 16U> key {};
    std::array<std::uint8_t, 16U> iv {};
    key.fill(0xa5U);
    iv.fill(0x5aU);
    MoonlightCommonCTestHarness::clearRemoteInputSecrets(key, iv);
    RDP_ASSERT(std::all_of(key.begin(), key.end(), [](std::uint8_t byte) {
        return byte == 0U;
    }));
    RDP_ASSERT(std::all_of(iv.begin(), iv.end(), [](std::uint8_t byte) {
        return byte == 0U;
    }));
}

RDP_TEST_CASE(moonlight_common_c_adapter_validates_server_generation_url_and_profiles) {
    auto owner = MoonlightSessionOwner::createForTesting();
    auto media = std::make_shared<FakeMediaPort>();
    auto clock = std::make_shared<std::atomic<std::uint64_t>>(3000U);
    std::atomic<int> starts {0};
    MoonlightCommonCTestDriver driver {
        [&]() { ++starts; return -1; }, []() {}, []() {}};
    auto adapter = makeAdapter(*owner, std::move(driver), media, clock);

    auto generation = makeRequest(clock->load());
    generation.server.hostCapabilityGeneration++;
    RDP_ASSERT_EQ(adapter->start(std::move(generation)).status,
                  MoonlightCommonCStartStatus::InvalidRequest);
    auto url = makeRequest(clock->load());
    url.launchLease = MoonlightRtspLaunchLease(
        {}, 1, "http://192.0.2.44:48010/secret", 101U, 9U,
        "host-700", "server-uuid-700", 31U, 17U);
    RDP_ASSERT_EQ(adapter->start(std::move(url)).status,
                  MoonlightCommonCStartStatus::InvalidRequest);
    auto userInfo = makeRequest(clock->load());
    userInfo.launchLease = MoonlightRtspLaunchLease(
        {}, 1, "rtsp://user@192.0.2.44:48010/session", 101U, 9U,
        "host-700", "server-uuid-700", 31U, 17U);
    RDP_ASSERT_EQ(adapter->start(std::move(userInfo)).status,
                  MoonlightCommonCStartStatus::InvalidRequest);
    auto fragment = makeRequest(clock->load());
    fragment.launchLease = MoonlightRtspLaunchLease(
        {}, 1, "rtsp://192.0.2.44:48010/session#secret", 101U, 9U,
        "host-700", "server-uuid-700", 31U, 17U);
    RDP_ASSERT_EQ(adapter->start(std::move(fragment)).status,
                  MoonlightCommonCStartStatus::InvalidRequest);
    auto unsupported = makeRequest(clock->load());
    unsupported.server.codecProfiles = {h264Profile()};
    RDP_ASSERT_EQ(adapter->start(std::move(unsupported)).status,
                  MoonlightCommonCStartStatus::InvalidRequest);
    RDP_ASSERT_EQ(starts.load(), 0);
}

RDP_TEST_CASE(moonlight_common_c_adapter_profile_masks_match_locked_common_c) {
    const std::array<std::pair<MoonlightStreamCodecProfile, std::int32_t>, 10U>
        vectors {{
            {{MoonlightStreamCodec::H264, MoonlightStreamBitDepth::Bit8,
              MoonlightStreamChroma::Yuv420}, 0x0001},
            {{MoonlightStreamCodec::H264, MoonlightStreamBitDepth::Bit8,
              MoonlightStreamChroma::Yuv444}, 0x0004},
            {{MoonlightStreamCodec::Hevc, MoonlightStreamBitDepth::Bit8,
              MoonlightStreamChroma::Yuv420}, 0x0100},
            {{MoonlightStreamCodec::Hevc, MoonlightStreamBitDepth::Bit10,
              MoonlightStreamChroma::Yuv420}, 0x0200},
            {{MoonlightStreamCodec::Hevc, MoonlightStreamBitDepth::Bit8,
              MoonlightStreamChroma::Yuv444}, 0x0400},
            {{MoonlightStreamCodec::Hevc, MoonlightStreamBitDepth::Bit10,
              MoonlightStreamChroma::Yuv444}, 0x0800},
            {{MoonlightStreamCodec::Av1, MoonlightStreamBitDepth::Bit8,
              MoonlightStreamChroma::Yuv420}, 0x1000},
            {{MoonlightStreamCodec::Av1, MoonlightStreamBitDepth::Bit10,
              MoonlightStreamChroma::Yuv420}, 0x2000},
            {{MoonlightStreamCodec::Av1, MoonlightStreamBitDepth::Bit8,
              MoonlightStreamChroma::Yuv444}, 0x4000},
            {{MoonlightStreamCodec::Av1, MoonlightStreamBitDepth::Bit10,
              MoonlightStreamChroma::Yuv444}, 0x8000},
        }};
    for (const auto& vector : vectors) {
        RDP_ASSERT_EQ(
            MoonlightCommonCTestHarness::videoFormatForProfile(vector.first),
            vector.second);
    }
    RDP_ASSERT_EQ(MoonlightCommonCTestHarness::videoFormatForProfile(
                      {MoonlightStreamCodec::H264,
                       MoonlightStreamBitDepth::Bit10,
                       MoonlightStreamChroma::Yuv420}),
                  0);

    std::array<std::uint8_t, 16U> key {};
    key[0] = 0x5aU;
    MoonlightRtspLaunchLease source(
        key, -1, "rtsp://192.0.2.44:48010/move", 1U, 2U,
        "host", "server", 3U, 4U);
    MoonlightRtspLaunchLease moved(std::move(source));
    RDP_ASSERT(moved.valid());
}

RDP_TEST_CASE(moonlight_common_c_adapter_malformed_boundary_corpus_fails_before_driver) {
    auto owner = MoonlightSessionOwner::createForTesting();
    auto media = std::make_shared<FakeMediaPort>();
    auto clock = std::make_shared<std::atomic<std::uint64_t>>(3500U);
    std::atomic<int> starts {0};
    MoonlightCommonCTestDriver driver {
        [&]() { ++starts; return -1; }, []() {}, []() {}};
    auto adapter = makeAdapter(*owner, std::move(driver), media, clock);
    auto reject = [&](auto mutate) {
        auto request = makeRequest(clock->load());
        mutate(request);
        RDP_ASSERT_EQ(adapter->start(std::move(request)).status,
                      MoonlightCommonCStartStatus::InvalidRequest);
    };

    reject([](auto& request) { request.streamConfig.identity.platformProbeGeneration = 0U; });
    reject([](auto& request) {
        request.deferRuntimeCapabilityProof = true;
        request.streamConfig.offer->networkPath = MoonlightStreamNetworkPath::Unknown;
        request.streamConfig.offer->clientRefreshRateX100 = 0;
    });
    reject([](auto& request) { request.streamConfig.offer->dimensions.width = 1919; });
    reject([](auto& request) { request.streamConfig.offer->dimensions.height = 9000; });
    reject([](auto& request) { request.streamConfig.offer->fps = 241; });
    reject([](auto& request) { request.streamConfig.offer->launchRefreshRate = 59; });
    reject([](auto& request) { request.streamConfig.offer->clientRefreshRateX100 = 24001; });
    reject([](auto& request) { request.streamConfig.offer->configuredBitrateKbps = 999; });
    reject([](auto& request) { request.streamConfig.offer->estimatedEncoderBitrateKbps = 20001; });
    reject([](auto& request) { request.streamConfig.offer->packetSizeBytes = 1025; });
    reject([](auto& request) {
        request.streamConfig.offer->networkPath =
            static_cast<MoonlightStreamNetworkPath>(99);
    });
    reject([](auto& request) {
        request.streamConfig.offer->latencyMode =
            static_cast<MoonlightStreamLatencyMode>(99);
    });
    reject([](auto& request) {
        request.streamConfig.offer->audioLayout =
            static_cast<MoonlightStreamAudioLayout>(99);
    });
    reject([](auto& request) {
        request.streamConfig.offer->colorSpace =
            static_cast<MoonlightStreamColorSpace>(99);
    });
    reject([](auto& request) {
        request.streamConfig.offer->encryptionPolicy =
            static_cast<MoonlightStreamEncryptionPolicy>(99);
    });
    reject([](auto& request) {
        request.streamConfig.offer->candidateEncryptionStreams = 0x80000000U;
    });
    reject([](auto& request) {
        request.streamConfig.offer->requiredEncryptionStreams =
            MoonlightStreamEncryptVideo;
    });
    reject([](auto& request) {
        request.streamConfig.offer->selectedCodec =
            request.streamConfig.offer->offeredCodecs.front();
    });
    reject([](auto& request) {
        request.streamConfig.offer->offeredCodecs[1].preferred = true;
    });
    reject([](auto& request) {
        request.streamConfig.offer->offeredCodecs[1].bitDepth =
            MoonlightStreamBitDepth::Bit10;
    });
    reject([](auto& request) {
        request.server.codecProfiles.push_back(request.server.codecProfiles.front());
    });
    reject([](auto& request) {
        request.streamConfig.launchProjection->dimensions.width += 2;
    });
    reject([](auto& request) {
        request.deadlines.stageMonotonicMs[3] =
            request.deadlines.overallMonotonicMs + 1U;
    });
    reject([](auto& request) { request.server.address = "host\\alias"; });
    reject([](auto& request) { request.server.gfeVersion = "3.bad.0"; });
    reject([](auto& request) { request.server.appVersion = "7.1.431.-"; });
    reject([](auto& request) { request.server.appVersion = "7.1.431.--1"; });
    RDP_ASSERT_EQ(starts.load(), 0);
}

RDP_TEST_CASE(moonlight_common_c_adapter_stage_machine_negotiates_but_never_claims_first_frame) {
    auto owner = MoonlightSessionOwner::createForTesting();
    auto media = std::make_shared<FakeMediaPort>();
    auto clock = std::make_shared<std::atomic<std::uint64_t>>(4000U);
    std::atomic<bool> driven {false};
    std::atomic<bool> qualityAccepted {false};
    std::atomic<bool> hdrAccepted {false};
    MoonlightCommonCTestDriver driver {
        [&]() {
            driven.store(driveStagesWithNegotiation());
            if (driven.load()) {
                qualityAccepted.store(MoonlightCommonCTestHarness::connectionStatus(0));
                hdrAccepted.store(MoonlightCommonCTestHarness::hdrMode(false));
            }
            return driven.load() && qualityAccepted.load() && hdrAccepted.load()
                       ? 0 : -1;
        },
        []() {},
        [&]() {
            (void)MoonlightCommonCTestHarness::videoStop();
            (void)MoonlightCommonCTestHarness::audioStop();
            (void)MoonlightCommonCTestHarness::videoCleanup();
            (void)MoonlightCommonCTestHarness::audioCleanup();
        }};
    auto adapter = makeAdapter(*owner, std::move(driver), media, clock);
    const auto accepted = adapter->start(makeRequest(clock->load()));
    RDP_ASSERT(owner->waitForPhase(accepted.key, MoonlightSessionPhase::Running, 1s));
    RDP_ASSERT(driven.load());
    RDP_ASSERT(qualityAccepted.load());
    RDP_ASSERT(hdrAccepted.load());
    const auto ownerSnapshot = owner->snapshot(accepted.key);
    RDP_ASSERT(ownerSnapshot.startInterruptible);
    const auto snapshot = adapter->snapshot(accepted.key);
    RDP_ASSERT(snapshot.transportReady);
    RDP_ASSERT(!snapshot.firstFrameReady);
    RDP_ASSERT(snapshot.video.has_value());
    RDP_ASSERT(snapshot.audio.has_value());
    RDP_ASSERT_EQ(snapshot.lastCompletedStage,
                  MoonlightCommonCStage::InputStreamStart);
    auto events = adapter->drainEvents(accepted.key);
    RDP_ASSERT(!events.empty());
    RDP_ASSERT_EQ(events.front().type, MoonlightCommonCEventType::Starting);
    std::size_t negotiated = 0U;
    std::size_t transport = 0U;
    std::size_t quality = 0U;
    std::size_t hdr = 0U;
    std::uint64_t prior = 0U;
    for (const auto& event : events) {
        RDP_ASSERT(event.sequence > prior);
        prior = event.sequence;
        if (event.type == MoonlightCommonCEventType::Negotiated) { ++negotiated; }
        if (event.type == MoonlightCommonCEventType::TransportReady) { ++transport; }
        if (event.type == MoonlightCommonCEventType::ConnectionQuality) { ++quality; }
        if (event.type == MoonlightCommonCEventType::HdrMode) { ++hdr; }
    }
    RDP_ASSERT_EQ(negotiated, static_cast<std::size_t>(1));
    RDP_ASSERT_EQ(transport, static_cast<std::size_t>(1));
    RDP_ASSERT_EQ(quality, static_cast<std::size_t>(1));
    RDP_ASSERT_EQ(hdr, static_cast<std::size_t>(1));
    RDP_ASSERT_EQ(adapter->stop(accepted.key, 1s), MoonlightStopStatus::Stopped);
    RDP_ASSERT_EQ(media->videoStops(), static_cast<std::size_t>(1));
    RDP_ASSERT_EQ(media->audioStops(), static_cast<std::size_t>(1));
    RDP_ASSERT_EQ(media->videoCleanups(), static_cast<std::size_t>(1));
    RDP_ASSERT_EQ(media->audioCleanups(), static_cast<std::size_t>(1));
    RDP_ASSERT_EQ(adapter->stop(accepted.key, 1s),
                  MoonlightStopStatus::AlreadyTerminal);
}

RDP_TEST_CASE(moonlight_common_c_adapter_rejects_unknown_reverse_and_duplicate_stages) {
    for (const std::int32_t invalidStage : {0, 2, 12}) {
        auto owner = MoonlightSessionOwner::createForTesting();
        auto media = std::make_shared<FakeMediaPort>();
        auto clock = std::make_shared<std::atomic<std::uint64_t>>(5000U);
        std::atomic<bool> callbackAccepted {true};
        MoonlightCommonCTestDriver driver {
            [&]() {
                callbackAccepted.store(
                    MoonlightCommonCTestHarness::stageStarting(invalidStage));
                return -44;
            }, []() {}, []() {}};
        auto adapter = makeAdapter(*owner, std::move(driver), media, clock);
        const auto accepted = adapter->start(
            makeRequest(clock->load(), 710U + static_cast<std::uint64_t>(invalidStage + 1)));
        RDP_ASSERT(owner->waitForPhase(accepted.key, MoonlightSessionPhase::Stopped, 1s));
        RDP_ASSERT(!callbackAccepted.load());
        const auto snapshot = adapter->snapshot(accepted.key);
        RDP_ASSERT(snapshot.protocolViolation);
        RDP_ASSERT_EQ(snapshot.terminalCode, MoonlightCommonCCode::ProtocolViolation);
    }
    for (int scenario = 0; scenario < 3; ++scenario) {
        auto owner = MoonlightSessionOwner::createForTesting();
        auto media = std::make_shared<FakeMediaPort>();
        auto clock = std::make_shared<std::atomic<std::uint64_t>>(
            5500U + static_cast<std::uint64_t>(scenario));
        std::atomic<bool> malformedAccepted {true};
        MoonlightCommonCTestDriver driver {
            [&]() {
                if (scenario == 0) {
                    malformedAccepted.store(
                        MoonlightCommonCTestHarness::stageComplete(1));
                } else if (scenario == 1) {
                    const bool prefix = MoonlightCommonCTestHarness::stageStarting(1);
                    malformedAccepted.store(!prefix ||
                        MoonlightCommonCTestHarness::stageStarting(1));
                } else {
                    const bool prefix = MoonlightCommonCTestHarness::stageStarting(1) &&
                        MoonlightCommonCTestHarness::stageComplete(1);
                    malformedAccepted.store(!prefix ||
                        MoonlightCommonCTestHarness::stageComplete(1));
                }
                return -1;
            }, []() {}, []() {}};
        auto adapter = makeAdapter(*owner, std::move(driver), media, clock);
        const auto accepted = adapter->start(makeRequest(
            clock->load(), 715U + static_cast<std::uint64_t>(scenario)));
        RDP_ASSERT(owner->waitForPhase(
            accepted.key, MoonlightSessionPhase::Stopped, 1s));
        RDP_ASSERT(!malformedAccepted.load());
        const auto snapshot = adapter->snapshot(accepted.key);
        RDP_ASSERT(snapshot.protocolViolation);
        RDP_ASSERT_EQ(snapshot.terminalCode,
                      MoonlightCommonCCode::ProtocolViolation);
    }
}

RDP_TEST_CASE(moonlight_common_c_adapter_cancel_before_first_stage_closes_lost_cancel_window) {
    auto owner = MoonlightSessionOwner::createForTesting();
    auto media = std::make_shared<FakeMediaPort>();
    auto clock = std::make_shared<std::atomic<std::uint64_t>>(6000U);
    AdapterGate beforeStage;
    std::atomic<int> interrupts {0};
    MoonlightCommonCTestDriver driver {
        [&]() {
            beforeStage.enterAndWait();
            (void)MoonlightCommonCTestHarness::stageStarting(1);
            return -1;
        },
        [&]() { ++interrupts; beforeStage.release(); },
        []() {}};
    auto adapter = makeAdapter(*owner, std::move(driver), media, clock);
    const auto accepted = adapter->start(makeRequest(clock->load()));
    RDP_ASSERT(beforeStage.waitEntered());
    RDP_ASSERT_EQ(adapter->requestStop(accepted.key),
                  MoonlightStopStatus::StopRequested);
    RDP_ASSERT_EQ(interrupts.load(), 0);
    beforeStage.release();
    RDP_ASSERT(owner->waitForPhase(accepted.key, MoonlightSessionPhase::Stopped, 1s));
    RDP_ASSERT_EQ(interrupts.load(), 1);
    const auto snapshot = adapter->snapshot(accepted.key);
    RDP_ASSERT_EQ(snapshot.terminalCode, MoonlightCommonCCode::Cancelled);
    RDP_ASSERT(snapshot.secretsCleared);
}

RDP_TEST_CASE(moonlight_common_c_adapter_cancel_during_each_stage_interrupts_exactly_once) {
    for (std::int32_t targetStage = 1; targetStage <= 11; ++targetStage) {
        auto owner = MoonlightSessionOwner::createForTesting();
        auto media = std::make_shared<FakeMediaPort>();
        auto clock = std::make_shared<std::atomic<std::uint64_t>>(
            7000U + static_cast<std::uint64_t>(targetStage));
        AdapterGate stageGate;
        std::atomic<int> interrupts {0};
        std::atomic<bool> prefixValid {true};
        MoonlightCommonCTestDriver driver {
            [&]() {
                for (std::int32_t stage = 1; stage <= targetStage; ++stage) {
                    if (!MoonlightCommonCTestHarness::stageStarting(stage)) {
                        prefixValid.store(false);
                        return -1;
                    }
                    if (stage == targetStage) {
                        stageGate.enterAndWait();
                        return -1;
                    }
                    if (stage == 9 &&
                        (MoonlightCommonCTestHarness::videoSetup(
                             MoonlightCommonCTestHarness::videoFormatForProfile(
                                 h264Profile()), 1920, 1080, 60) != 0 ||
                         !MoonlightCommonCTestHarness::videoStart())) {
                        prefixValid.store(false);
                        return -1;
                    }
                    if (stage == 10) {
                        const auto wire = MoonlightCommonCTestHarness::wireSnapshot();
                        if (!wire.has_value() ||
                            MoonlightCommonCTestHarness::audioInit(
                                wire->audioConfiguration,
                                opusForLayout(MoonlightStreamAudioLayout::Stereo)) != 0 ||
                            !MoonlightCommonCTestHarness::audioStart()) {
                            prefixValid.store(false);
                            return -1;
                        }
                    }
                    if (!MoonlightCommonCTestHarness::stageComplete(stage)) {
                        prefixValid.store(false);
                        return -1;
                    }
                }
                return -1;
            },
            [&]() { ++interrupts; stageGate.release(); },
            []() {}};
        auto adapter = makeAdapter(*owner, std::move(driver), media, clock);
        const auto accepted = adapter->start(makeRequest(
            clock->load(), 730U + static_cast<std::uint64_t>(targetStage)));
        RDP_ASSERT_EQ(accepted.status, MoonlightCommonCStartStatus::Accepted);
        RDP_ASSERT(stageGate.waitEntered());
        RDP_ASSERT_EQ(adapter->requestStop(accepted.key),
                      MoonlightStopStatus::StopRequested);
        RDP_ASSERT(owner->waitForPhase(
            accepted.key, MoonlightSessionPhase::Stopped, 1s));
        RDP_ASSERT(prefixValid.load());
        RDP_ASSERT_EQ(interrupts.load(), 1);
    }
}

RDP_TEST_CASE(moonlight_common_c_adapter_maps_failure_for_each_exact_stage) {
    for (std::int32_t targetStage = 1; targetStage <= 11; ++targetStage) {
        auto owner = MoonlightSessionOwner::createForTesting();
        auto media = std::make_shared<FakeMediaPort>();
        auto clock = std::make_shared<std::atomic<std::uint64_t>>(
            7600U + static_cast<std::uint64_t>(targetStage));
        std::atomic<bool> failureAccepted {false};
        MoonlightCommonCTestDriver driver {
            [&]() {
                for (std::int32_t stage = 1; stage <= targetStage; ++stage) {
                    if (!MoonlightCommonCTestHarness::stageStarting(stage)) {
                        return -1;
                    }
                    if (stage == targetStage) {
                        failureAccepted.store(MoonlightCommonCTestHarness::stageFailed(
                            stage, -2000000));
                        return -1;
                    }
                    if (stage == 9 &&
                        (MoonlightCommonCTestHarness::videoSetup(
                             MoonlightCommonCTestHarness::videoFormatForProfile(
                                 h264Profile()), 1920, 1080, 60) != 0 ||
                         !MoonlightCommonCTestHarness::videoStart())) {
                        return -1;
                    }
                    if (stage == 10) {
                        const auto wire = MoonlightCommonCTestHarness::wireSnapshot();
                        if (!wire.has_value() ||
                            MoonlightCommonCTestHarness::audioInit(
                                wire->audioConfiguration,
                                opusForLayout(MoonlightStreamAudioLayout::Stereo)) != 0 ||
                            !MoonlightCommonCTestHarness::audioStart()) {
                            return -1;
                        }
                    }
                    if (!MoonlightCommonCTestHarness::stageComplete(stage)) {
                        return -1;
                    }
                }
                return -1;
            }, []() {}, []() {}};
        auto adapter = makeAdapter(*owner, std::move(driver), media, clock);
        const auto accepted = adapter->start(makeRequest(
            clock->load(), 760U + static_cast<std::uint64_t>(targetStage)));
        RDP_ASSERT(owner->waitForPhase(
            accepted.key, MoonlightSessionPhase::Stopped, 1s));
        RDP_ASSERT(failureAccepted.load());
        const auto snapshot = adapter->snapshot(accepted.key);
        RDP_ASSERT_EQ(snapshot.terminalCode, MoonlightCommonCCode::StageFailed);
        const auto events = adapter->drainEvents(accepted.key);
        RDP_ASSERT(!events.empty());
        RDP_ASSERT_EQ(events.back().stage,
                      static_cast<MoonlightCommonCStage>(targetStage));
        RDP_ASSERT_EQ(events.back().boundedRawError, -1000000);
    }
}

RDP_TEST_CASE(moonlight_common_c_adapter_video_and_audio_negotiation_fail_closed) {
    {
        auto owner = MoonlightSessionOwner::createForTesting();
        auto media = std::make_shared<FakeMediaPort>();
        auto clock = std::make_shared<std::atomic<std::uint64_t>>(8000U);
        std::atomic<int> setupResult {0};
        MoonlightCommonCTestDriver driver {
            [&]() {
                if (!driveUntilVideoStartStage()) {
                    return -1;
                }
                const auto h264 = MoonlightCommonCTestHarness::videoFormatForProfile(
                    h264Profile());
                setupResult.store(MoonlightCommonCTestHarness::videoSetup(
                    h264 | (h264 << 1), 1920, 1080, 60));
                return -1;
            }, []() {}, []() {}};
        auto adapter = makeAdapter(*owner, std::move(driver), media, clock);
        const auto accepted = adapter->start(makeRequest(clock->load()));
        RDP_ASSERT(owner->waitForPhase(accepted.key, MoonlightSessionPhase::Stopped, 1s));
        RDP_ASSERT(setupResult.load() != 0);
        RDP_ASSERT_EQ(adapter->snapshot(accepted.key).terminalCode,
                      MoonlightCommonCCode::VideoNegotiationRejected);
    }
    {
        auto owner = MoonlightSessionOwner::createForTesting();
        auto media = std::make_shared<FakeMediaPort>();
        auto clock = std::make_shared<std::atomic<std::uint64_t>>(8100U);
        std::atomic<int> initResult {0};
        MoonlightCommonCTestDriver driver {
            [&]() {
                if (!driveUntilAudioStartStage()) {
                    return -1;
                }
                const auto wire = MoonlightCommonCTestHarness::wireSnapshot();
                if (!wire.has_value()) {
                    initResult.store(-1);
                    return -1;
                }
                auto opus = opusForLayout(MoonlightStreamAudioLayout::Stereo);
                opus.mapping[1] = 0U;
                initResult.store(MoonlightCommonCTestHarness::audioInit(
                    wire->audioConfiguration, opus));
                return -1;
            }, []() {}, []() {}};
        auto adapter = makeAdapter(*owner, std::move(driver), media, clock);
        const auto accepted = adapter->start(makeRequest(clock->load()));
        RDP_ASSERT(owner->waitForPhase(accepted.key, MoonlightSessionPhase::Stopped, 1s));
        RDP_ASSERT(initResult.load() != 0);
        RDP_ASSERT_EQ(adapter->snapshot(accepted.key).terminalCode,
                      MoonlightCommonCCode::AudioNegotiationRejected);
    }
    {
        auto owner = MoonlightSessionOwner::createForTesting();
        auto media = std::make_shared<FakeMediaPort>();
        media->rejectVideo();
        auto clock = std::make_shared<std::atomic<std::uint64_t>>(8200U);
        std::atomic<int> setupResult {0};
        MoonlightCommonCTestDriver driver {
            [&]() {
                if (!driveUntilVideoStartStage()) {
                    return -1;
                }
                setupResult.store(MoonlightCommonCTestHarness::videoSetup(
                    MoonlightCommonCTestHarness::videoFormatForProfile(h264Profile()),
                    1920, 1080, 60));
                return -1;
            }, []() {}, []() {}};
        auto adapter = makeAdapter(*owner, std::move(driver), media, clock);
        const auto accepted = adapter->start(makeRequest(clock->load(), 718U));
        RDP_ASSERT(owner->waitForPhase(
            accepted.key, MoonlightSessionPhase::Stopped, 1s));
        RDP_ASSERT(setupResult.load() != 0);
        RDP_ASSERT_EQ(adapter->snapshot(accepted.key).terminalCode,
                      MoonlightCommonCCode::MediaPortRejected);
    }
    {
        auto owner = MoonlightSessionOwner::createForTesting();
        auto media = std::make_shared<FakeMediaPort>();
        media->rejectAudio();
        auto clock = std::make_shared<std::atomic<std::uint64_t>>(8300U);
        std::atomic<int> initResult {0};
        MoonlightCommonCTestDriver driver {
            [&]() {
                if (!driveUntilAudioStartStage()) {
                    return -1;
                }
                const auto wire = MoonlightCommonCTestHarness::wireSnapshot();
                if (!wire.has_value()) {
                    return -1;
                }
                initResult.store(MoonlightCommonCTestHarness::audioInit(
                    wire->audioConfiguration,
                    opusForLayout(MoonlightStreamAudioLayout::Stereo)));
                return -1;
            }, []() {}, []() {}};
        auto adapter = makeAdapter(*owner, std::move(driver), media, clock);
        const auto accepted = adapter->start(makeRequest(clock->load(), 719U));
        RDP_ASSERT(owner->waitForPhase(
            accepted.key, MoonlightSessionPhase::Stopped, 1s));
        RDP_ASSERT(initResult.load() != 0);
        RDP_ASSERT_EQ(adapter->snapshot(accepted.key).terminalCode,
                      MoonlightCommonCCode::MediaPortRejected);
    }
}

RDP_TEST_CASE(moonlight_common_c_adapter_accepts_exact_opus_shapes_for_all_layouts) {
    for (const auto layout : {MoonlightStreamAudioLayout::Stereo,
                              MoonlightStreamAudioLayout::Surround51,
                              MoonlightStreamAudioLayout::Surround71}) {
        auto owner = MoonlightSessionOwner::createForTesting();
        auto media = std::make_shared<FakeMediaPort>();
        auto clock = std::make_shared<std::atomic<std::uint64_t>>(9000U);
        std::atomic<bool> acceptedShape {false};
        MoonlightCommonCTestDriver driver {
            [&]() {
                if (!driveUntilAudioStartStage()) {
                    return -1;
                }
                const auto wire = MoonlightCommonCTestHarness::wireSnapshot();
                if (!wire.has_value()) {
                    return -1;
                }
                acceptedShape.store(MoonlightCommonCTestHarness::audioInit(
                    wire->audioConfiguration, opusForLayout(layout)) == 0);
                return -1;
            }, []() {}, []() {}};
        auto adapter = makeAdapter(*owner, std::move(driver), media, clock);
        const auto result = adapter->start(makeRequest(
            clock->load(), 720U + static_cast<std::uint64_t>(layout), 9U, 101U, layout));
        RDP_ASSERT(owner->waitForPhase(result.key, MoonlightSessionPhase::Failed, 1s));
        RDP_ASSERT(acceptedShape.load());
        RDP_ASSERT_EQ(media->audioSetups(), static_cast<std::size_t>(1));
    }
}

RDP_TEST_CASE(moonlight_common_c_adapter_external_termination_drains_and_rejects_late_callback) {
    auto owner = MoonlightSessionOwner::createForTesting();
    auto media = std::make_shared<FakeMediaPort>();
    auto clock = std::make_shared<std::atomic<std::uint64_t>>(10000U);
    std::atomic<bool> driven {false};
    std::atomic<int> stops {0};
    MoonlightCommonCTestDriver driver {
        [&]() { driven.store(driveStagesWithNegotiation()); return driven.load() ? 0 : -1; },
        []() {},
        [&]() { ++stops; }};
    auto adapter = makeAdapter(*owner, std::move(driver), media, clock);
    const auto accepted = adapter->start(makeRequest(clock->load()));
    RDP_ASSERT(owner->waitForPhase(accepted.key, MoonlightSessionPhase::Running, 1s));
    std::atomic<bool> terminationAccepted {false};
    std::thread termination([&]() {
        terminationAccepted.store(
            MoonlightCommonCTestHarness::connectionTerminated(-101));
    });
    termination.join();
    RDP_ASSERT(owner->waitForPhase(accepted.key, MoonlightSessionPhase::Stopped, 1s));
    RDP_ASSERT(terminationAccepted.load());
    RDP_ASSERT_EQ(stops.load(), 1);
    const auto snapshot = adapter->snapshot(accepted.key);
    RDP_ASSERT_EQ(snapshot.terminalCode, MoonlightCommonCCode::ConnectionTerminated);
    RDP_ASSERT(snapshot.secretsCleared);
    const auto staleBefore = MoonlightCommonCTestHarness::staleCallbackCount();
    RDP_ASSERT(!MoonlightCommonCTestHarness::connectionTerminated(-1));
    RDP_ASSERT(MoonlightCommonCTestHarness::staleCallbackCount() > staleBefore);
}

RDP_TEST_CASE(moonlight_common_c_adapter_fake_clock_stage_deadline_only_requests_owner_stop) {
    auto owner = MoonlightSessionOwner::createForTesting();
    auto media = std::make_shared<FakeMediaPort>();
    auto clock = std::make_shared<std::atomic<std::uint64_t>>(11000U);
    AdapterGate stageGate;
    std::atomic<int> interrupts {0};
    MoonlightCommonCTestDriver driver {
        [&]() {
            (void)MoonlightCommonCTestHarness::stageStarting(1);
            stageGate.enterAndWait();
            return -1;
        },
        [&]() { ++interrupts; stageGate.release(); },
        []() {}};
    auto adapter = makeAdapter(*owner, std::move(driver), media, clock);
    auto request = makeRequest(clock->load());
    request.deadlines.overallMonotonicMs = 13000U;
    request.deadlines.stageMonotonicMs.fill(12000U);
    const auto accepted = adapter->start(std::move(request));
    RDP_ASSERT(stageGate.waitEntered());
    clock->store(12000U);
    adapter->notifyClockForTesting();
    RDP_ASSERT(owner->waitForPhase(accepted.key, MoonlightSessionPhase::Stopped, 1s));
    RDP_ASSERT_EQ(interrupts.load(), 1);
    RDP_ASSERT_EQ(adapter->snapshot(accepted.key).terminalCode,
                  MoonlightCommonCCode::DeadlineExceeded);
}

RDP_TEST_CASE(moonlight_common_c_adapter_startup_deadline_is_disarmed_after_connection) {
    auto owner = MoonlightSessionOwner::createForTesting();
    auto media = std::make_shared<FakeMediaPort>();
    auto clock = std::make_shared<std::atomic<std::uint64_t>>(14000U);
    std::atomic<bool> driven {false};
    std::atomic<int> interrupts {0};
    std::atomic<int> stops {0};
    MoonlightCommonCTestDriver driver {
        [&]() {
            driven.store(driveStagesWithNegotiation());
            return driven.load() ? 0 : -1;
        },
        [&]() { ++interrupts; },
        [&]() {
            ++stops;
            (void)MoonlightCommonCTestHarness::videoStop();
            (void)MoonlightCommonCTestHarness::audioStop();
            (void)MoonlightCommonCTestHarness::videoCleanup();
            (void)MoonlightCommonCTestHarness::audioCleanup();
        }};
    auto adapter = makeAdapter(*owner, std::move(driver), media, clock);
    auto request = makeRequest(clock->load());
    request.deadlines.overallMonotonicMs = 16000U;
    request.deadlines.stageMonotonicMs.fill(15000U);
    const auto accepted = adapter->start(std::move(request));
    RDP_ASSERT(owner->waitForPhase(accepted.key, MoonlightSessionPhase::Running, 1s));
    RDP_ASSERT(driven.load());

    clock->store(17000U);
    adapter->notifyClockForTesting();
    RDP_ASSERT(!owner->waitForPhase(
        accepted.key, MoonlightSessionPhase::Stopped, 100ms));
    RDP_ASSERT_EQ(interrupts.load(), 0);
    RDP_ASSERT_EQ(stops.load(), 0);
    RDP_ASSERT_EQ(adapter->stop(accepted.key, 1s), MoonlightStopStatus::Stopped);
    RDP_ASSERT_EQ(stops.load(), 1);
}

RDP_TEST_CASE(moonlight_common_c_adapter_finalization_waits_inflight_media_callback) {
    auto owner = MoonlightSessionOwner::createForTesting();
    auto media = std::make_shared<FakeMediaPort>();
    auto clock = std::make_shared<std::atomic<std::uint64_t>>(12500U);
    AdapterGate mediaGate;
    media->blockVideoSetup(mediaGate);
    std::atomic<int> setupResult {-99};
    std::atomic<int> interrupts {0};
    std::atomic<bool> driverSawCallback {false};
    RdpTestThreadScope callbackScope([&]() { mediaGate.release(); });
    MoonlightCommonCTestDriver driver {
        [&]() {
            if (!driveUntilVideoStartStage()) {
                return -1;
            }
            callbackScope.start([&]() {
                setupResult.store(MoonlightCommonCTestHarness::videoSetup(
                    MoonlightCommonCTestHarness::videoFormatForProfile(h264Profile()),
                    1920, 1080, 60));
            });
            driverSawCallback.store(mediaGate.waitEntered());
            return -1;
        },
        [&]() { ++interrupts; },
        []() {}};
    auto adapter = makeAdapter(*owner, std::move(driver), media, clock);
    const auto accepted = adapter->start(makeRequest(clock->load(), 775U));
    const bool entered = mediaGate.waitEntered();
    const auto stopStatus = accepted.key.valid()
                                ? adapter->requestStop(accepted.key)
                                : MoonlightStopStatus::InvalidKey;
    const auto blocked = adapter->snapshot(accepted.key);
    const auto finalizingDeadline = std::chrono::steady_clock::now() + 1s;
    while (!MoonlightCommonCTestHarness::finalizing() &&
           std::chrono::steady_clock::now() < finalizingDeadline) {
        std::this_thread::yield();
    }
    const bool finalizing = MoonlightCommonCTestHarness::finalizing();
    mediaGate.release();
    const bool callbackJoined = callbackScope.cancelAndJoin();
    const bool stopped = owner->waitForPhase(
        accepted.key, MoonlightSessionPhase::Stopped, 1s);
    RDP_ASSERT_EQ(accepted.status, MoonlightCommonCStartStatus::Accepted);
    RDP_ASSERT(entered);
    RDP_ASSERT(driverSawCallback.load());
    RDP_ASSERT_EQ(stopStatus, MoonlightStopStatus::StopRequested);
    RDP_ASSERT(blocked.matched);
    RDP_ASSERT(!blocked.terminal);
    RDP_ASSERT(!blocked.secretsCleared);
    RDP_ASSERT(finalizing);
    RDP_ASSERT(callbackJoined);
    RDP_ASSERT(stopped);
    RDP_ASSERT_EQ(interrupts.load(), 1);
    RDP_ASSERT(setupResult.load() != 0);
    RDP_ASSERT_EQ(media->videoSetups(), static_cast<std::size_t>(1));
    RDP_ASSERT_EQ(media->videoCleanups(), static_cast<std::size_t>(1));
    const auto terminal = adapter->snapshot(accepted.key);
    RDP_ASSERT(terminal.terminal);
    RDP_ASSERT(terminal.secretsCleared);
    RDP_ASSERT_EQ(terminal.terminalCode, MoonlightCommonCCode::Cancelled);
}

RDP_TEST_CASE(moonlight_common_c_adapter_events_are_bounded_and_upstream_log_is_payload_free) {
    auto owner = MoonlightSessionOwner::createForTesting();
    auto media = std::make_shared<FakeMediaPort>();
    auto clock = std::make_shared<std::atomic<std::uint64_t>>(14000U);
    std::atomic<int> notices {0};
    MoonlightCommonCTestDriver driver {
        [&]() {
            (void)MoonlightCommonCTestHarness::stageStarting(1);
            for (int index = 0; index < 100; ++index) {
                if (MoonlightCommonCTestHarness::logNotice()) { ++notices; }
            }
            return -1;
        }, []() {}, []() {}};
    auto adapter = makeAdapter(*owner, std::move(driver), media, clock);
    const auto accepted = adapter->start(makeRequest(clock->load()));
    RDP_ASSERT(owner->waitForPhase(accepted.key, MoonlightSessionPhase::Failed, 1s));
    const auto snapshot = adapter->snapshot(accepted.key);
    RDP_ASSERT_EQ(notices.load(), 100);
    RDP_ASSERT(snapshot.droppedEvents > 0U);
    const auto events = adapter->drainEvents(accepted.key);
    RDP_ASSERT(events.size() <= 64U);
    RDP_ASSERT(!events.empty());
    RDP_ASSERT_EQ(events.back().type, MoonlightCommonCEventType::Failed);
}

RDP_TEST_CASE(moonlight_common_c_adapter_payload_callbacks_are_lease_guarded_and_port_owned) {
    auto owner = MoonlightSessionOwner::createForTesting();
    auto media = std::make_shared<FakeMediaPort>();
    auto clock = std::make_shared<std::atomic<std::uint64_t>>(15000U);
    std::atomic<bool> callbacksAccepted {false};
    MoonlightCommonCTestDriver driver {
        [&]() {
            if (!driveStagesWithNegotiation()) {
                return -1;
            }
            std::uint8_t videoBytes[2] {0x01U, 0x02U};
            MoonlightVideoFragmentView videoFragment;
            auto videoUnit = testVideoPayload(
                videoBytes, sizeof(videoBytes), videoFragment, 17);
            const std::uint8_t audio[4] {1U, 2U, 3U, 4U};
            callbacksAccepted.store(
                MoonlightCommonCTestHarness::videoPayload(videoUnit) == 0 &&
                MoonlightCommonCTestHarness::audioPayload(audio, sizeof(audio)));
            MoonlightCommonCTestHarness::audioPayloadRaw(nullptr, 0);
            MoonlightCommonCTestHarness::audioPayloadRaw(audio, 0);
            MoonlightCommonCTestHarness::audioPayloadRaw(nullptr, 1);
            std::array<std::uint8_t, 1401U> oversizedAudio {};
            MoonlightCommonCTestHarness::audioPayloadRaw(
                oversizedAudio.data(), static_cast<std::int32_t>(oversizedAudio.size()));
            return callbacksAccepted.load() ? 0 : -1;
        }, []() {},
        [&]() {
            (void)MoonlightCommonCTestHarness::videoStop();
            (void)MoonlightCommonCTestHarness::audioStop();
            (void)MoonlightCommonCTestHarness::videoCleanup();
            (void)MoonlightCommonCTestHarness::audioCleanup();
        }};
    auto adapter = makeAdapter(*owner, std::move(driver), media, clock);
    const auto accepted = adapter->start(makeRequest(clock->load()));
    RDP_ASSERT(owner->waitForPhase(accepted.key, MoonlightSessionPhase::Running, 1s));
    RDP_ASSERT(callbacksAccepted.load());
    RDP_ASSERT_EQ(media->videoPayloads(), static_cast<std::size_t>(1));
    RDP_ASSERT(media->videoPayloadKey() == accepted.key);
    const auto payloadProfile = media->videoPayloadProfile();
    RDP_ASSERT_EQ(payloadProfile.codec, h264Profile().codec);
    RDP_ASSERT_EQ(payloadProfile.bitDepth, h264Profile().bitDepth);
    RDP_ASSERT_EQ(payloadProfile.chroma, h264Profile().chroma);
    RDP_ASSERT_EQ(media->videoPayloadFrameNumber(), 17);
    RDP_ASSERT_EQ(media->audioPayloads(), static_cast<std::size_t>(2));
    RDP_ASSERT_EQ(media->audioPayloadBytes(), static_cast<std::size_t>(4));
    RDP_ASSERT_EQ(media->audioPlcPayloads(), static_cast<std::size_t>(1));
    RDP_ASSERT_EQ(adapter->stop(accepted.key, 1s), MoonlightStopStatus::Stopped);
    std::uint8_t staleBytes[1] {0x03U};
    MoonlightVideoFragmentView staleFragment;
    auto stale = testVideoPayload(staleBytes, sizeof(staleBytes), staleFragment);
    RDP_ASSERT(MoonlightCommonCTestHarness::videoPayload(stale) != 0);
}

RDP_TEST_CASE(moonlight_common_c_adapter_coalesces_idr_requests_until_accepted_idr) {
    auto owner = MoonlightSessionOwner::createForTesting();
    auto media = std::make_shared<FakeMediaPort>();
    auto clock = std::make_shared<std::atomic<std::uint64_t>>(15500U);
    std::array<std::atomic<int>, 4U> returns;
    for (auto& value : returns) {
        value.store(99);
    }
    MoonlightCommonCTestDriver driver {
        [&]() {
            if (!driveStagesWithNegotiation()) {
                return -1;
            }
            std::uint8_t bytes[1] {0x01U};
            MoonlightVideoFragmentView fragment;
            auto unit = testVideoPayload(bytes, sizeof(bytes), fragment, 1);
            media->setVideoSubmitResult(MoonlightVideoSubmitStatus::NeedIdr, true);
            returns[0].store(MoonlightCommonCTestHarness::videoPayload(unit));
            unit.frameNumber = 2;
            returns[1].store(MoonlightCommonCTestHarness::videoPayload(unit));

            media->setVideoSubmitResult(MoonlightVideoSubmitStatus::Accepted, false);
            unit.frameNumber = 3;
            unit.frameType = MoonlightVideoFrameType::IdR;
            returns[2].store(MoonlightCommonCTestHarness::videoPayload(unit));

            media->setVideoSubmitResult(MoonlightVideoSubmitStatus::Backpressure, true);
            unit.frameNumber = 4;
            unit.frameType = MoonlightVideoFrameType::Predicted;
            returns[3].store(MoonlightCommonCTestHarness::videoPayload(unit));
            return 0;
        }, []() {},
        []() {
            (void)MoonlightCommonCTestHarness::videoStop();
            (void)MoonlightCommonCTestHarness::audioStop();
            (void)MoonlightCommonCTestHarness::videoCleanup();
            (void)MoonlightCommonCTestHarness::audioCleanup();
        }};
    auto adapter = makeAdapter(*owner, std::move(driver), media, clock);
    const auto accepted = adapter->start(makeRequest(clock->load(), 776U));
    RDP_ASSERT(owner->waitForPhase(accepted.key, MoonlightSessionPhase::Running, 1s));
    RDP_ASSERT_EQ(returns[0].load(), -1);
    RDP_ASSERT_EQ(returns[1].load(), 0);
    RDP_ASSERT_EQ(returns[2].load(), 0);
    // Transient sink pressure requests an IDR out of band and keeps common-c
    // P-frame delivery open instead of entering its hard IDR wait.
    RDP_ASSERT_EQ(returns[3].load(), 0);
    RDP_ASSERT_EQ(media->videoPayloads(), static_cast<std::size_t>(4U));
    RDP_ASSERT_EQ(adapter->stop(accepted.key, 1s), MoonlightStopStatus::Stopped);
}

RDP_TEST_CASE(moonlight_common_c_adapter_contains_driver_exception_and_cleanses) {
    auto owner = MoonlightSessionOwner::createForTesting();
    auto media = std::make_shared<FakeMediaPort>();
    auto clock = std::make_shared<std::atomic<std::uint64_t>>(16000U);
    MoonlightCommonCTestDriver driver {
        []() -> int { throw std::runtime_error("start"); }, []() {}, []() {}};
    auto adapter = makeAdapter(*owner, std::move(driver), media, clock);
    const auto accepted = adapter->start(makeRequest(clock->load()));
    RDP_ASSERT(owner->waitForPhase(accepted.key, MoonlightSessionPhase::Failed, 1s));
    const auto snapshot = adapter->snapshot(accepted.key);
    RDP_ASSERT_EQ(snapshot.terminalCode, MoonlightCommonCCode::DriverException);
    RDP_ASSERT(snapshot.secretsCleared);
    RDP_ASSERT_EQ(owner->snapshot(accepted.key).driverFailure,
                  MoonlightDriverFailure::StartException);
}

RDP_TEST_CASE(moonlight_common_c_adapter_busy_stale_and_destructor_drain_are_exact) {
    auto owner = MoonlightSessionOwner::createForTesting();
    auto media = std::make_shared<FakeMediaPort>();
    auto clock = std::make_shared<std::atomic<std::uint64_t>>(17000U);
    AdapterGate startGate;
    std::atomic<int> interrupts {0};
    MoonlightCommonCTestDriver firstDriver {
        [&]() {
            if (!MoonlightCommonCTestHarness::stageStarting(1)) {
                return -1;
            }
            startGate.enterAndWait();
            return -1;
        },
        [&]() { ++interrupts; startGate.release(); },
        []() {}};
    auto first = makeAdapter(*owner, std::move(firstDriver), media, clock);
    const auto accepted = first->start(makeRequest(clock->load()));
    RDP_ASSERT(startGate.waitEntered());

    auto secondMedia = std::make_shared<FakeMediaPort>();
    std::atomic<int> secondStarts {0};
    MoonlightCommonCTestDriver secondDriver {
        [&]() { ++secondStarts; return 0; }, []() {}, []() {}};
    auto second = makeAdapter(*owner, std::move(secondDriver), secondMedia, clock);
    const auto busy = second->start(makeRequest(clock->load(), 900U, 10U));
    RDP_ASSERT_EQ(busy.status, MoonlightCommonCStartStatus::Busy);
    RDP_ASSERT_EQ(secondStarts.load(), 0);
    auto stale = accepted.key;
    ++stale.ownerToken;
    RDP_ASSERT_EQ(first->requestStop(stale), MoonlightStopStatus::StaleOwner);
    first.reset();
    RDP_ASSERT(owner->waitForPhase(accepted.key, MoonlightSessionPhase::Stopped, 1s));
    RDP_ASSERT_EQ(interrupts.load(), 1);
}
