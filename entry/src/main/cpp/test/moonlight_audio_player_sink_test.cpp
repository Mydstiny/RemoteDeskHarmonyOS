#include "moonlight/media/MoonlightAudioPlayerSink.h"
#include "test/test_runner.h"

#include <array>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace {

using namespace remotedesk::moonlight;

MoonlightAudioStreamIdentity playerIdentity(std::uint64_t ownerToken = 41U,
                                            std::uint64_t configurationGeneration = 7U) {
    return {{701U, 11U, ownerToken}, configurationGeneration};
}

Render::DecoderSessionIdentity decoderIdentity(const MoonlightAudioStreamIdentity& identity) {
    return {identity.key.sessionId, identity.key.generation, identity.key.ownerToken};
}

class FakeAudioPlayerPort final : public MoonlightAudioPlayerPort {
  public:
    bool ownerReady(const Render::DecoderSessionIdentity& owner) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        return ownerReady_ && owner == acceptedOwner_;
    }

    int submit(const Render::DecoderSessionIdentity& owner, const std::uint8_t* pcm,
               std::size_t pcmBytes, int sampleRate, int channels) noexcept override {
        std::unique_lock<std::mutex> lock(mutex_);
        submitEntered_ = true;
        cv_.notify_all();
        cv_.wait(lock, [&]() { return !blockSubmit_; });
        ++submitCount_;
        lastOwner_ = owner;
        sampleRate_ = sampleRate;
        channels_ = channels;
        pcm_.assign(pcm, pcm + pcmBytes);
        return submitResult_ == kReturnFullSize ? static_cast<int>(pcmBytes) : submitResult_;
    }

    bool suspendAndFlush(const Render::DecoderSessionIdentity& owner) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        ++suspendCount_;
        lastOwner_ = owner;
        return suspendResult_;
    }

    bool destroyAndFlush(const Render::DecoderSessionIdentity& owner) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        ++destroyCount_;
        lastOwner_ = owner;
        return destroyResult_;
    }

    void accept(const MoonlightAudioStreamIdentity& identity) {
        std::lock_guard<std::mutex> lock(mutex_);
        acceptedOwner_ = decoderIdentity(identity);
        ownerReady_ = true;
    }

    void setOwnerReady(bool ready) {
        std::lock_guard<std::mutex> lock(mutex_);
        ownerReady_ = ready;
    }

    void blockSubmit() {
        std::lock_guard<std::mutex> lock(mutex_);
        blockSubmit_ = true;
        submitEntered_ = false;
    }

    void waitForSubmit() {
        std::unique_lock<std::mutex> lock(mutex_);
        cv_.wait(lock, [&]() { return submitEntered_; });
    }

    void releaseSubmit() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            blockSubmit_ = false;
        }
        cv_.notify_all();
    }

    static constexpr int kReturnFullSize = -1000;
    int submitResult_ = kReturnFullSize;
    bool suspendResult_ = true;
    bool destroyResult_ = true;
    std::size_t submitCount_ = 0U;
    std::size_t suspendCount_ = 0U;
    std::size_t destroyCount_ = 0U;
    int sampleRate_ = 0;
    int channels_ = 0;
    std::vector<std::uint8_t> pcm_;
    Render::DecoderSessionIdentity lastOwner_{};

  private:
    std::mutex mutex_;
    std::condition_variable cv_;
    Render::DecoderSessionIdentity acceptedOwner_{};
    bool ownerReady_ = false;
    bool blockSubmit_ = false;
    bool submitEntered_ = false;
};

struct PlayerFixture final {
    PlayerFixture() {
        port->accept(identity);
        sink = MoonlightAudioPlayerSink::createForTesting(port);
        RDP_ASSERT(sink != nullptr);
        RDP_ASSERT_EQ(sink->activate(identity, 1U).status,
                      MoonlightAudioPlayerControlStatus::Applied);
    }

    MoonlightAudioStreamIdentity identity = playerIdentity();
    std::shared_ptr<FakeAudioPlayerPort> port = std::make_shared<FakeAudioPlayerPort>();
    std::shared_ptr<MoonlightAudioPlayerSink> sink;
};

std::array<std::uint8_t, 8U> pcmFixture() {
    return {0x00U, 0x00U, 0xffU, 0x7fU, 0x00U, 0x80U, 0x34U, 0x12U};
}

class FixedDecoderPort final : public MoonlightAudioDecoderPort {
  public:
    MoonlightAudioDecoderConfigureStatus
    configure(const MoonlightCommonCAudioSelection&) noexcept override {
        return MoonlightAudioDecoderConfigureStatus::Ready;
    }
    MoonlightAudioDecodeResult decode(const std::uint8_t*, std::size_t, bool, std::int16_t* pcm,
                                      std::size_t frameCapacity) noexcept override {
        if (pcm == nullptr || frameCapacity < 2U) {
            return {MoonlightAudioDecodeStatus::InvalidFrameCount, 0U};
        }
        pcm[0] = 0;
        pcm[1] = 32767;
        pcm[2] = -32768;
        pcm[3] = 0x1234;
        return {MoonlightAudioDecodeStatus::Decoded, 2U};
    }
    void destroy() noexcept override {}
};

MoonlightCommonCAudioSelection stereoPlayerSelection() {
    MoonlightCommonCAudioSelection selection;
    selection.layout = MoonlightStreamAudioLayout::Stereo;
    selection.opus.sampleRate = 48000;
    selection.opus.channelCount = 2;
    selection.opus.streams = 1;
    selection.opus.coupledStreams = 1;
    selection.opus.samplesPerFrame = 960;
    selection.opus.mapping[0] = 0U;
    selection.opus.mapping[1] = 1U;
    return selection;
}

RDP_TEST_CASE(moonlight_audio_player_sink_forwards_exact_owner_and_stereo_format) {
    PlayerFixture fixture;
    const auto pcm = pcmFixture();
    RDP_ASSERT(fixture.sink->submit(fixture.identity, pcm.data(), pcm.size(), 2U, false));
    RDP_ASSERT_EQ(fixture.port->submitCount_, static_cast<std::size_t>(1U));
    RDP_ASSERT(fixture.port->lastOwner_ == decoderIdentity(fixture.identity));
    RDP_ASSERT_EQ(fixture.port->sampleRate_, 48000);
    RDP_ASSERT_EQ(fixture.port->channels_, 2);
    RDP_ASSERT(fixture.port->pcm_ == std::vector<std::uint8_t>(pcm.begin(), pcm.end()));
    const auto snapshot = fixture.sink->snapshot(fixture.identity);
    RDP_ASSERT_EQ(snapshot.acceptedChunks, static_cast<std::uint64_t>(1U));
    RDP_ASSERT_EQ(snapshot.acceptedBytes, static_cast<std::uint64_t>(pcm.size()));
}

RDP_TEST_CASE(moonlight_audio_player_sink_rejects_stale_owner_and_bad_pcm_bounds) {
    PlayerFixture fixture;
    const auto pcm = pcmFixture();
    auto stale = fixture.identity;
    ++stale.key.generation;
    RDP_ASSERT(!fixture.sink->submit(stale, pcm.data(), pcm.size(), 2U, false));
    RDP_ASSERT(!fixture.sink->submit(fixture.identity, nullptr, pcm.size(), 2U, false));
    RDP_ASSERT(!fixture.sink->submit(fixture.identity, pcm.data(), pcm.size() - 1U, 2U, false));
    RDP_ASSERT(!fixture.sink->submit(fixture.identity, pcm.data(), pcm.size(), 0U, false));
    RDP_ASSERT_EQ(fixture.port->submitCount_, static_cast<std::size_t>(0U));
    RDP_ASSERT_EQ(fixture.sink->snapshot(fixture.identity).rejectedChunks,
                  static_cast<std::uint64_t>(4U));
}

RDP_TEST_CASE(moonlight_audio_player_sink_focus_pause_flushes_and_resume_rebuffers) {
    PlayerFixture fixture;
    const auto pcm = pcmFixture();
    RDP_ASSERT_EQ(
        fixture.sink->pause(fixture.identity, 1U, MoonlightAudioPauseReason::FocusLost).status,
        MoonlightAudioPlayerControlStatus::Stale);
    RDP_ASSERT_EQ(
        fixture.sink->pause(fixture.identity, 2U, MoonlightAudioPauseReason::FocusLost).status,
        MoonlightAudioPlayerControlStatus::Applied);
    RDP_ASSERT_EQ(fixture.port->suspendCount_, static_cast<std::size_t>(1U));
    RDP_ASSERT(!fixture.sink->submit(fixture.identity, pcm.data(), pcm.size(), 2U, false));
    RDP_ASSERT_EQ(fixture.sink->resume(fixture.identity, 3U).status,
                  MoonlightAudioPlayerControlStatus::Applied);
    RDP_ASSERT(fixture.sink->submit(fixture.identity, pcm.data(), pcm.size(), 2U, false));
}

RDP_TEST_CASE(moonlight_audio_player_sink_repeat_background_pause_is_idempotent) {
    PlayerFixture fixture;
    RDP_ASSERT_EQ(
        fixture.sink->pause(fixture.identity, 2U, MoonlightAudioPauseReason::Background).status,
        MoonlightAudioPlayerControlStatus::Applied);
    RDP_ASSERT_EQ(
        fixture.sink->pause(fixture.identity, 3U, MoonlightAudioPauseReason::Background).status,
        MoonlightAudioPlayerControlStatus::AlreadyApplied);
    RDP_ASSERT_EQ(fixture.port->suspendCount_, static_cast<std::size_t>(1U));
}

RDP_TEST_CASE(moonlight_audio_player_sink_accepts_muted_drop_and_recovers_write_failure) {
    PlayerFixture fixture;
    const auto pcm = pcmFixture();
    fixture.port->submitResult_ = 0;
    RDP_ASSERT(fixture.sink->submit(fixture.identity, pcm.data(), pcm.size(), 2U, false));
    fixture.port->submitResult_ = -3;
    RDP_ASSERT(!fixture.sink->submit(fixture.identity, pcm.data(), pcm.size(), 2U, false));
    fixture.port->submitResult_ = FakeAudioPlayerPort::kReturnFullSize;
    RDP_ASSERT(fixture.sink->submit(fixture.identity, pcm.data(), pcm.size(), 2U, true));
    const auto snapshot = fixture.sink->snapshot(fixture.identity);
    RDP_ASSERT_EQ(snapshot.acceptedChunks, static_cast<std::uint64_t>(2U));
    RDP_ASSERT_EQ(snapshot.rejectedChunks, static_cast<std::uint64_t>(1U));
}

RDP_TEST_CASE(moonlight_audio_player_sink_stop_is_exact_and_rejects_late_audio) {
    PlayerFixture fixture;
    const auto pcm = pcmFixture();
    auto stale = fixture.identity;
    ++stale.key.ownerToken;
    RDP_ASSERT_EQ(fixture.sink->stop(stale, 2U).status, MoonlightAudioPlayerControlStatus::Stale);
    RDP_ASSERT_EQ(fixture.port->destroyCount_, static_cast<std::size_t>(0U));
    RDP_ASSERT_EQ(fixture.sink->stop(fixture.identity, 2U).status,
                  MoonlightAudioPlayerControlStatus::Applied);
    RDP_ASSERT(!fixture.sink->submit(fixture.identity, pcm.data(), pcm.size(), 2U, false));
    RDP_ASSERT_EQ(fixture.sink->stop(fixture.identity, 3U).status,
                  MoonlightAudioPlayerControlStatus::AlreadyApplied);
    RDP_ASSERT_EQ(fixture.port->destroyCount_, static_cast<std::size_t>(1U));
}

RDP_TEST_CASE(moonlight_audio_player_sink_cleanup_requires_stop_and_higher_owner_reuse) {
    PlayerFixture fixture;
    RDP_ASSERT_EQ(fixture.sink->cleanup(fixture.identity, 2U).status,
                  MoonlightAudioPlayerControlStatus::InvalidState);
    RDP_ASSERT_EQ(fixture.sink->stop(fixture.identity, 2U).status,
                  MoonlightAudioPlayerControlStatus::Applied);
    RDP_ASSERT_EQ(fixture.sink->cleanup(fixture.identity, 3U).status,
                  MoonlightAudioPlayerControlStatus::Applied);
    RDP_ASSERT_EQ(fixture.sink->cleanup(fixture.identity, 3U).status,
                  MoonlightAudioPlayerControlStatus::AlreadyApplied);
    auto sameTokenWrongIdentity = fixture.identity;
    ++sameTokenWrongIdentity.key.sessionId;
    RDP_ASSERT_EQ(fixture.sink->cleanup(sameTokenWrongIdentity, 4U).status,
                  MoonlightAudioPlayerControlStatus::Stale);
    RDP_ASSERT_EQ(fixture.sink->activate(fixture.identity, 4U).status,
                  MoonlightAudioPlayerControlStatus::Stale);
    const auto next = playerIdentity(fixture.identity.key.ownerToken + 1U, 8U);
    fixture.port->accept(next);
    RDP_ASSERT_EQ(fixture.sink->activate(next, 1U).status,
                  MoonlightAudioPlayerControlStatus::Applied);
}

RDP_TEST_CASE(moonlight_audio_player_sink_owner_loss_cannot_cross_session_write) {
    PlayerFixture fixture;
    const auto pcm = pcmFixture();
    fixture.port->setOwnerReady(false);
    RDP_ASSERT(!fixture.sink->submit(fixture.identity, pcm.data(), pcm.size(), 2U, false));
    RDP_ASSERT_EQ(fixture.port->submitCount_, static_cast<std::size_t>(0U));
}

RDP_TEST_CASE(moonlight_audio_player_sink_stop_drains_inflight_dispatch) {
    PlayerFixture fixture;
    const auto pcm = pcmFixture();
    fixture.port->blockSubmit();
    bool submitted = false;
    MoonlightAudioPlayerControlResult stopped;
    std::thread submitter([&]() {
        submitted = fixture.sink->submit(fixture.identity, pcm.data(), pcm.size(), 2U, false);
    });
    fixture.port->waitForSubmit();
    std::thread stopper([&]() { stopped = fixture.sink->stop(fixture.identity, 2U); });
    fixture.port->releaseSubmit();
    submitter.join();
    stopper.join();
    RDP_ASSERT(submitted);
    RDP_ASSERT_EQ(stopped.status, MoonlightAudioPlayerControlStatus::Applied);
    RDP_ASSERT_EQ(fixture.port->destroyCount_, static_cast<std::size_t>(1U));
}

RDP_TEST_CASE(moonlight_audio_player_sink_is_the_n2_06_bridge_handoff) {
    const auto identity = playerIdentity();
    auto port = std::make_shared<FakeAudioPlayerPort>();
    port->accept(identity);
    auto sink = MoonlightAudioPlayerSink::createForTesting(port);
    RDP_ASSERT(sink != nullptr);
    RDP_ASSERT_EQ(sink->activate(identity, 1U).status, MoonlightAudioPlayerControlStatus::Applied);
    auto bridge =
        MoonlightAudioBridge::createForTesting(std::make_shared<FixedDecoderPort>(), sink);
    RDP_ASSERT(bridge != nullptr);
    RDP_ASSERT_EQ(bridge->configure(identity, stereoPlayerSelection(), 1U).status,
                  MoonlightAudioConfigureStatus::Configured);
    RDP_ASSERT_EQ(bridge->start(identity, 2U).status, MoonlightAudioStartStatus::Started);
    const std::uint8_t packet[1]{0x01U};
    RDP_ASSERT_EQ(bridge->submit(identity, 3U, packet, sizeof(packet)).status,
                  MoonlightAudioSubmitStatus::Accepted);
    RDP_ASSERT_EQ(port->submitCount_, static_cast<std::size_t>(1U));
    RDP_ASSERT_EQ(port->sampleRate_, 48000);
    RDP_ASSERT_EQ(port->channels_, 2);
}

} // namespace
