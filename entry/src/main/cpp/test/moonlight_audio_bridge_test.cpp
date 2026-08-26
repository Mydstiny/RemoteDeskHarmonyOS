#include "moonlight/media/MoonlightAudioBridge.h"
#include "test/test_runner.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

using namespace remotedesk::moonlight;
using namespace std::chrono_literals;

class AudioGate final {
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

class FakeAudioDecoderPort final : public MoonlightAudioDecoderPort {
public:
    MoonlightAudioDecoderConfigureStatus configure(
        const MoonlightCommonCAudioSelection& selection) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        ++configureCount_;
        selection_ = selection;
        configured_ = configureStatus_ == MoonlightAudioDecoderConfigureStatus::Ready;
        return configureStatus_;
    }

    MoonlightAudioDecodeResult decode(
        const std::uint8_t* packet, std::size_t packetBytes, bool plc,
        std::int16_t* pcm, std::size_t frameCapacity) noexcept override {
        if (decodeGate_ != nullptr) {
            decodeGate_->enterAndWait();
        }
        std::lock_guard<std::mutex> lock(mutex_);
        ++decodeCount_;
        lastPacket_ = packet;
        lastPacketBytes_ = packetBytes;
        lastPlc_ = plc;
        if (!configured_) {
            return {MoonlightAudioDecodeStatus::Terminal, 0U};
        }
        if (decodeStatus_ != MoonlightAudioDecodeStatus::Decoded) {
            return {decodeStatus_, 0U};
        }
        if (frames_ > frameCapacity || pcm == nullptr ||
            samples_.size() < frames_ * 2U) {
            return {MoonlightAudioDecodeStatus::InvalidFrameCount, frames_};
        }
        for (std::size_t index = 0U; index < frames_ * 2U; ++index) {
            pcm[index] = samples_[index];
        }
        return {MoonlightAudioDecodeStatus::Decoded, frames_};
    }

    void destroy() noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        ++destroyCount_;
        configured_ = false;
        selection_ = {};
    }

    std::size_t configureCount() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return configureCount_;
    }
    std::size_t decodeCount() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return decodeCount_;
    }
    std::size_t destroyCount() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return destroyCount_;
    }
    const std::uint8_t* lastPacket() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return lastPacket_;
    }
    std::size_t lastPacketBytes() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return lastPacketBytes_;
    }
    bool lastPlc() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return lastPlc_;
    }

    MoonlightAudioDecoderConfigureStatus configureStatus_ =
        MoonlightAudioDecoderConfigureStatus::Ready;
    MoonlightAudioDecodeStatus decodeStatus_ = MoonlightAudioDecodeStatus::Decoded;
    std::size_t frames_ = 2U;
    std::vector<std::int16_t> samples_ {0, 32767, -32768, 0x1234};
    AudioGate* decodeGate_ = nullptr;

private:
    mutable std::mutex mutex_;
    MoonlightCommonCAudioSelection selection_ {};
    bool configured_ = false;
    std::size_t configureCount_ = 0U;
    std::size_t decodeCount_ = 0U;
    std::size_t destroyCount_ = 0U;
    const std::uint8_t* lastPacket_ = nullptr;
    std::size_t lastPacketBytes_ = 0U;
    bool lastPlc_ = false;
};

class RecordingAudioPcmSink final : public MoonlightAudioPcmSink {
public:
    bool submit(const MoonlightAudioStreamIdentity& identity,
                const std::uint8_t* pcm, std::size_t pcmBytes,
                std::size_t decodedFrames, bool plc) noexcept override {
        if (submitGate_ != nullptr) {
            submitGate_->enterAndWait();
        }
        std::lock_guard<std::mutex> lock(mutex_);
        ++submitCount_;
        identity_ = identity;
        frames_ = decodedFrames;
        plc_ = plc;
        pcm_.assign(pcm, pcm + pcmBytes);
        return accept_;
    }

    std::size_t submitCount() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return submitCount_;
    }
    std::vector<std::uint8_t> pcm() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return pcm_;
    }
    std::size_t frames() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return frames_;
    }
    bool plc() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return plc_;
    }

    bool accept_ = true;
    AudioGate* submitGate_ = nullptr;

private:
    mutable std::mutex mutex_;
    MoonlightAudioStreamIdentity identity_ {};
    std::vector<std::uint8_t> pcm_;
    std::size_t frames_ = 0U;
    std::size_t submitCount_ = 0U;
    bool plc_ = false;
};

MoonlightCommonCAudioSelection stereoSelection() {
    MoonlightCommonCAudioSelection selection;
    selection.layout = MoonlightStreamAudioLayout::Stereo;
    selection.opus.sampleRate = 48000;
    selection.opus.channelCount = 2;
    selection.opus.streams = 1;
    selection.opus.coupledStreams = 1;
    selection.opus.samplesPerFrame = 240;
    selection.opus.mapping = {0U, 1U, 0U, 0U, 0U, 0U, 0U, 0U};
    return selection;
}

MoonlightAudioStreamIdentity audioIdentity(
    std::uint64_t ownerToken = 701U,
    std::uint64_t configurationGeneration = 1U) {
    return {{501U + ownerToken, 11U, ownerToken}, configurationGeneration};
}

struct AudioFixture final {
    std::shared_ptr<FakeAudioDecoderPort> decoder =
        std::make_shared<FakeAudioDecoderPort>();
    std::shared_ptr<RecordingAudioPcmSink> sink =
        std::make_shared<RecordingAudioPcmSink>();
    std::unique_ptr<MoonlightAudioBridge> bridge =
        MoonlightAudioBridge::createForTesting(decoder, sink);
};

void startAudio(AudioFixture& fixture, const MoonlightAudioStreamIdentity& identity) {
    RDP_ASSERT(fixture.bridge != nullptr);
    RDP_ASSERT_EQ(fixture.bridge->configure(identity, stereoSelection(), 1U).status,
                  MoonlightAudioConfigureStatus::Configured);
    RDP_ASSERT_EQ(fixture.bridge->start(identity, 2U).status,
                  MoonlightAudioStartStatus::Started);
}

RDP_TEST_CASE(moonlight_audio_bridge_accepts_only_exact_stereo_family_one) {
    const auto identity = audioIdentity();

    AudioFixture valid;
    RDP_ASSERT_EQ(valid.bridge->configure(identity, stereoSelection(), 1U).status,
                  MoonlightAudioConfigureStatus::Configured);
    RDP_ASSERT_EQ(valid.decoder->configureCount(), static_cast<std::size_t>(1U));

    auto assertUnsupported = [&](const MoonlightCommonCAudioSelection& selection) {
        AudioFixture fixture;
        RDP_ASSERT_EQ(fixture.bridge->configure(identity, selection, 1U).status,
                      MoonlightAudioConfigureStatus::Unsupported);
        RDP_ASSERT_EQ(fixture.decoder->configureCount(), static_cast<std::size_t>(0U));
    };

    auto invalid = stereoSelection();
    invalid.opus.sampleRate = 44100;
    assertUnsupported(invalid);
    invalid = stereoSelection();
    invalid.opus.channelCount = 6;
    invalid.opus.streams = 4;
    invalid.opus.coupledStreams = 2;
    invalid.layout = MoonlightStreamAudioLayout::Surround51;
    assertUnsupported(invalid);
    invalid = stereoSelection();
    invalid.opus.channelCount = 8;
    invalid.opus.streams = 5;
    invalid.opus.coupledStreams = 3;
    invalid.layout = MoonlightStreamAudioLayout::Surround71;
    assertUnsupported(invalid);
    invalid = stereoSelection();
    invalid.opus.channelCount = 1;
    invalid.opus.coupledStreams = 0;
    invalid.opus.mapping[1] = 0U;
    assertUnsupported(invalid);
    invalid = stereoSelection();
    invalid.opus.mapping[0] = 1U;
    invalid.opus.mapping[1] = 0U;
    assertUnsupported(invalid);
    invalid = stereoSelection();
    invalid.opus.samplesPerFrame = 241;
    assertUnsupported(invalid);
}

RDP_TEST_CASE(moonlight_audio_bridge_copies_packet_and_emits_exact_s16le_pcm) {
    AudioFixture fixture;
    const auto identity = audioIdentity();
    startAudio(fixture, identity);
    std::array<std::uint8_t, 4U> packet {0xf8U, 0xffU, 0xfeU, 0x01U};
    const auto result = fixture.bridge->submit(
        identity, 3U, packet.data(), packet.size());
    RDP_ASSERT_EQ(result.status, MoonlightAudioSubmitStatus::Accepted);
    RDP_ASSERT_EQ(result.inputBytes, packet.size());
    RDP_ASSERT_EQ(result.decodedFrames, static_cast<std::size_t>(2U));
    RDP_ASSERT_EQ(result.pcmBytes, static_cast<std::size_t>(8U));
    RDP_ASSERT(result.decoderCalled);
    RDP_ASSERT(result.sinkCalled);
    RDP_ASSERT(fixture.decoder->lastPacket() != packet.data());
    RDP_ASSERT_EQ(fixture.decoder->lastPacketBytes(), packet.size());
    const std::vector<std::uint8_t> expected {
        0x00U, 0x00U, 0xffU, 0x7fU, 0x00U, 0x80U, 0x34U, 0x12U};
    RDP_ASSERT(fixture.sink->pcm() == expected);
    RDP_ASSERT_EQ(fixture.sink->frames(), static_cast<std::size_t>(2U));
    const auto snapshot = fixture.bridge->snapshot(identity);
    RDP_ASSERT(snapshot.matched);
    RDP_ASSERT_EQ(snapshot.acceptedPackets, static_cast<std::uint64_t>(1U));
    RDP_ASSERT_EQ(snapshot.retainedPacketBytes, static_cast<std::size_t>(0U));
    RDP_ASSERT_EQ(snapshot.retainedPcmBytes, static_cast<std::size_t>(0U));
    RDP_ASSERT(snapshot.packetScratchZeroized);
    RDP_ASSERT(snapshot.pcmScratchZeroized);
}

RDP_TEST_CASE(moonlight_audio_bridge_real_opus_silence_fixture_decodes_to_golden_pcm) {
    auto sink = std::make_shared<RecordingAudioPcmSink>();
    auto bridge = MoonlightAudioBridge::createWithPlatformDecoderForTesting(sink);
    RDP_ASSERT(bridge != nullptr);
    const char* hostVersion = MoonlightAudioBridge::platformDecoderVersionForTesting();
    RDP_ASSERT(hostVersion != nullptr);
    RDP_ASSERT(std::string(hostVersion).find("libopus ") == 0U);
    auto selection = stereoSelection();
    selection.opus.samplesPerFrame = 960;
    const auto identity = audioIdentity();
    RDP_ASSERT_EQ(bridge->configure(identity, selection, 1U).status,
                  MoonlightAudioConfigureStatus::Configured);
    RDP_ASSERT_EQ(bridge->start(identity, 2U).status,
                  MoonlightAudioStartStatus::Started);
    // RFC 6716's canonical 20 ms Opus silence packet. Product resolution is
    // pinned 1.5.2; this host run reports its own linked version separately.
    const std::array<std::uint8_t, 3U> packet {0xf8U, 0xffU, 0xfeU};
    const auto result = bridge->submit(identity, 3U, packet.data(), packet.size());
    RDP_ASSERT_EQ(result.status, MoonlightAudioSubmitStatus::Accepted);
    RDP_ASSERT_EQ(result.decodedFrames, static_cast<std::size_t>(960U));
    RDP_ASSERT_EQ(result.pcmBytes, static_cast<std::size_t>(3840U));
    const auto pcm = sink->pcm();
    RDP_ASSERT_EQ(pcm.size(), static_cast<std::size_t>(3840U));
    RDP_ASSERT(std::all_of(pcm.begin(), pcm.end(),
                           [](std::uint8_t value) { return value == 0U; }));

    const std::uint8_t malformedPacket[1] {0xffU};
    RDP_ASSERT_EQ(bridge->submit(
                      identity, 4U, malformedPacket, sizeof(malformedPacket)).status,
                  MoonlightAudioSubmitStatus::Malformed);
    RDP_ASSERT_EQ(bridge->submit(
                      identity, 5U, packet.data(), packet.size()).status,
                  MoonlightAudioSubmitStatus::Accepted);
}

RDP_TEST_CASE(moonlight_audio_bridge_freezes_plc_and_packet_bounds) {
    AudioFixture fixture;
    const auto identity = audioIdentity();
    startAudio(fixture, identity);

    const auto plc = fixture.bridge->submit(identity, 3U, nullptr, 0U);
    RDP_ASSERT_EQ(plc.status, MoonlightAudioSubmitStatus::PlcAccepted);
    RDP_ASSERT(plc.plc);
    RDP_ASSERT(fixture.decoder->lastPlc());
    RDP_ASSERT(fixture.sink->plc());

    std::array<std::uint8_t, 1401U> packet {};
    RDP_ASSERT_EQ(fixture.bridge->submit(identity, 4U, packet.data(), 0U).status,
                  MoonlightAudioSubmitStatus::Malformed);
    RDP_ASSERT_EQ(fixture.bridge->submit(identity, 4U, nullptr, 1U).status,
                  MoonlightAudioSubmitStatus::Malformed);
    RDP_ASSERT_EQ(fixture.bridge->submit(
                      identity, 4U, packet.data(), packet.size()).status,
                  MoonlightAudioSubmitStatus::Malformed);
    RDP_ASSERT_EQ(fixture.bridge->submit(
                      identity, 4U, packet.data(), 1U).status,
                  MoonlightAudioSubmitStatus::Accepted);
    RDP_ASSERT_EQ(fixture.bridge->submit(
                      identity, 5U, packet.data(), 1400U).status,
                  MoonlightAudioSubmitStatus::Accepted);
}

RDP_TEST_CASE(moonlight_audio_bridge_keeps_decode_and_sink_failures_typed_and_recoverable) {
    AudioFixture fixture;
    const auto identity = audioIdentity();
    startAudio(fixture, identity);
    const std::uint8_t packet[2] {0x01U, 0x02U};

    fixture.decoder->decodeStatus_ = MoonlightAudioDecodeStatus::Malformed;
    RDP_ASSERT_EQ(fixture.bridge->submit(identity, 3U, packet, sizeof(packet)).status,
                  MoonlightAudioSubmitStatus::Malformed);
    fixture.decoder->decodeStatus_ = MoonlightAudioDecodeStatus::Decoded;
    fixture.sink->accept_ = false;
    RDP_ASSERT_EQ(fixture.bridge->submit(identity, 4U, packet, sizeof(packet)).status,
                  MoonlightAudioSubmitStatus::SinkRejected);
    fixture.sink->accept_ = true;
    RDP_ASSERT_EQ(fixture.bridge->submit(identity, 5U, packet, sizeof(packet)).status,
                  MoonlightAudioSubmitStatus::Accepted);

    fixture.decoder->frames_ = 0U;
    fixture.decoder->samples_.clear();
    RDP_ASSERT_EQ(fixture.bridge->submit(identity, 6U, packet, sizeof(packet)).status,
                  MoonlightAudioSubmitStatus::DecodeFailed);
    fixture.decoder->frames_ = 241U;
    fixture.decoder->samples_.resize(482U);
    RDP_ASSERT_EQ(fixture.bridge->submit(identity, 7U, packet, sizeof(packet)).status,
                  MoonlightAudioSubmitStatus::DecodeFailed);
}

RDP_TEST_CASE(moonlight_audio_bridge_lifecycle_is_ordered_and_exactly_idempotent) {
    AudioFixture fixture;
    const auto identity = audioIdentity();
    const std::uint8_t packet[1] {0x01U};
    RDP_ASSERT_EQ(fixture.bridge->configure(identity, stereoSelection(), 1U).status,
                  MoonlightAudioConfigureStatus::Configured);
    RDP_ASSERT_EQ(fixture.bridge->configure(identity, stereoSelection(), 1U).status,
                  MoonlightAudioConfigureStatus::AlreadyConfigured);
    RDP_ASSERT_EQ(fixture.bridge->start(identity, 1U).status,
                  MoonlightAudioStartStatus::Stale);
    RDP_ASSERT_EQ(fixture.bridge->submit(identity, 2U, packet, sizeof(packet)).status,
                  MoonlightAudioSubmitStatus::InvalidState);
    RDP_ASSERT_EQ(fixture.bridge->start(identity, 2U).status,
                  MoonlightAudioStartStatus::Started);
    RDP_ASSERT_EQ(fixture.bridge->start(identity, 2U).status,
                  MoonlightAudioStartStatus::AlreadyStarted);
    RDP_ASSERT_EQ(fixture.bridge->configure(identity, stereoSelection(), 3U).status,
                  MoonlightAudioConfigureStatus::Busy);
    RDP_ASSERT_EQ(fixture.bridge->cleanup(identity, 3U, 1ms).status,
                  MoonlightAudioCleanupStatus::InvalidState);
    RDP_ASSERT_EQ(fixture.bridge->stop(identity, 3U, 1s).status,
                  MoonlightAudioStopStatus::Stopped);
    RDP_ASSERT_EQ(fixture.bridge->cleanup(identity, 3U, 1ms).status,
                  MoonlightAudioCleanupStatus::Stale);
    RDP_ASSERT_EQ(fixture.bridge->cleanup(identity, 4U, 1s).status,
                  MoonlightAudioCleanupStatus::Cleaned);
}

RDP_TEST_CASE(moonlight_audio_bridge_rejects_stale_identity_and_operation_without_side_effects) {
    AudioFixture fixture;
    const auto identity = audioIdentity();
    startAudio(fixture, identity);
    auto stale = identity;
    ++stale.key.generation;
    const std::uint8_t packet[1] {0x01U};
    RDP_ASSERT_EQ(fixture.bridge->submit(stale, 3U, packet, sizeof(packet)).status,
                  MoonlightAudioSubmitStatus::Stale);
    RDP_ASSERT_EQ(fixture.bridge->submit(identity, 2U, packet, sizeof(packet)).status,
                  MoonlightAudioSubmitStatus::Stale);
    RDP_ASSERT_EQ(fixture.decoder->decodeCount(), static_cast<std::size_t>(0U));
    RDP_ASSERT_EQ(fixture.bridge->stop(stale, 3U, 1ms).status,
                  MoonlightAudioStopStatus::Stale);
    RDP_ASSERT_EQ(fixture.bridge->snapshot(identity).state,
                  MoonlightAudioBridgeState::Started);
}

RDP_TEST_CASE(moonlight_audio_bridge_backpressure_and_blocked_decode_stop_are_retriable) {
    AudioFixture fixture;
    const auto identity = audioIdentity();
    startAudio(fixture, identity);
    AudioGate gate;
    fixture.decoder->decodeGate_ = &gate;
    const std::uint8_t packet[1] {0x01U};
    MoonlightAudioSubmitResult first;
    RdpTestThreadScope worker([&]() { gate.release(); });
    worker.start([&]() {
        first = fixture.bridge->submit(identity, 3U, packet, sizeof(packet));
    });
    RDP_ASSERT(gate.waitEntered());
    RDP_ASSERT_EQ(fixture.bridge->submit(identity, 4U, packet, sizeof(packet)).status,
                  MoonlightAudioSubmitStatus::Backpressure);
    RDP_ASSERT_EQ(fixture.bridge->stop(identity, 5U, 1ms).status,
                  MoonlightAudioStopStatus::TimedOut);
    gate.release();
    RDP_ASSERT(worker.cancelAndJoin());
    RDP_ASSERT_EQ(first.status, MoonlightAudioSubmitStatus::Accepted);
    RDP_ASSERT_EQ(fixture.bridge->stop(identity, 5U, 1s).status,
                  MoonlightAudioStopStatus::Stopped);
    RDP_ASSERT_EQ(fixture.decoder->destroyCount(), static_cast<std::size_t>(1U));
}

RDP_TEST_CASE(moonlight_audio_bridge_blocked_sink_is_drained_before_decoder_destroy) {
    AudioFixture fixture;
    const auto identity = audioIdentity();
    startAudio(fixture, identity);
    AudioGate gate;
    fixture.sink->submitGate_ = &gate;
    const std::uint8_t packet[1] {0x01U};
    RdpTestThreadScope worker([&]() { gate.release(); });
    worker.start([&]() {
        (void)fixture.bridge->submit(identity, 3U, packet, sizeof(packet));
    });
    RDP_ASSERT(gate.waitEntered());
    RDP_ASSERT_EQ(fixture.bridge->stop(identity, 4U, 1ms).status,
                  MoonlightAudioStopStatus::TimedOut);
    RDP_ASSERT_EQ(fixture.decoder->destroyCount(), static_cast<std::size_t>(0U));
    gate.release();
    RDP_ASSERT(worker.cancelAndJoin());
    RDP_ASSERT_EQ(fixture.bridge->stop(identity, 4U, 1s).status,
                  MoonlightAudioStopStatus::Stopped);
    RDP_ASSERT_EQ(fixture.decoder->destroyCount(), static_cast<std::size_t>(1U));
}

RDP_TEST_CASE(moonlight_audio_bridge_cleanup_is_exact_idempotent_zeroized_and_reusable) {
    AudioFixture fixture;
    const std::uint8_t packet[3] {0x11U, 0x22U, 0x33U};
    for (std::uint64_t cycle = 1U; cycle <= 20U; ++cycle) {
        const auto identity = audioIdentity(700U + cycle, cycle);
        RDP_ASSERT_EQ(fixture.bridge->configure(identity, stereoSelection(), 1U).status,
                      MoonlightAudioConfigureStatus::Configured);
        RDP_ASSERT_EQ(fixture.bridge->start(identity, 2U).status,
                      MoonlightAudioStartStatus::Started);
        RDP_ASSERT_EQ(fixture.bridge->submit(
                          identity, 3U, packet, sizeof(packet)).status,
                      MoonlightAudioSubmitStatus::Accepted);
        RDP_ASSERT_EQ(fixture.bridge->submit(identity, 4U, nullptr, 0U).status,
                      MoonlightAudioSubmitStatus::PlcAccepted);
        RDP_ASSERT_EQ(fixture.bridge->stop(identity, 5U, 1s).status,
                      MoonlightAudioStopStatus::Stopped);
        RDP_ASSERT_EQ(fixture.bridge->stop(identity, 5U, 1s).status,
                      MoonlightAudioStopStatus::AlreadyStopped);
        RDP_ASSERT_EQ(fixture.bridge->cleanup(identity, 6U, 1s).status,
                      MoonlightAudioCleanupStatus::Cleaned);
        RDP_ASSERT_EQ(fixture.bridge->cleanup(identity, 6U, 1s).status,
                      MoonlightAudioCleanupStatus::AlreadyCleaned);
        const auto snapshot = fixture.bridge->snapshot(identity);
        RDP_ASSERT(!snapshot.matched);
        RDP_ASSERT_EQ(snapshot.retainedPacketBytes, static_cast<std::size_t>(0U));
        RDP_ASSERT_EQ(snapshot.retainedPcmBytes, static_cast<std::size_t>(0U));
        RDP_ASSERT(snapshot.packetScratchZeroized);
        RDP_ASSERT(snapshot.pcmScratchZeroized);
    }
    RDP_ASSERT_EQ(fixture.decoder->configureCount(), static_cast<std::size_t>(20U));
    RDP_ASSERT_EQ(fixture.decoder->destroyCount(), static_cast<std::size_t>(20U));
}

} // namespace
