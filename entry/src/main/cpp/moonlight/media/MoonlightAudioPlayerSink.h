#ifndef REMOTEDESK_MOONLIGHT_AUDIO_PLAYER_SINK_H
#define REMOTEDESK_MOONLIGHT_AUDIO_PLAYER_SINK_H

#include "moonlight/media/MoonlightAudioBridge.h"
#include "render/video_perf_counters.h"

#include <cstddef>
#include <cstdint>
#include <memory>

#if defined(__GNUC__) || defined(__clang__)
#define REMOTEDESK_MOONLIGHT_AUDIO_PLAYER_HIDDEN __attribute__((visibility("hidden")))
#else
#define REMOTEDESK_MOONLIGHT_AUDIO_PLAYER_HIDDEN
#endif

namespace remotedesk::moonlight {

enum class MoonlightAudioPlayerState : std::uint8_t {
    Idle,
    Active,
    Paused,
    Stopped,
    Cleaned,
};

enum class MoonlightAudioPauseReason : std::uint8_t {
    None,
    User,
    FocusLost,
    Background,
};

enum class MoonlightAudioPlayerControlStatus : std::uint8_t {
    Applied,
    AlreadyApplied,
    InvalidRequest,
    InvalidState,
    Stale,
    PortFailure,
};

struct REMOTEDESK_MOONLIGHT_AUDIO_PLAYER_HIDDEN MoonlightAudioPlayerControlResult final {
    MoonlightAudioPlayerControlStatus status = MoonlightAudioPlayerControlStatus::InvalidRequest;
    MoonlightAudioStreamIdentity identity{};
    std::uint64_t operationGeneration = 0U;
};

struct REMOTEDESK_MOONLIGHT_AUDIO_PLAYER_HIDDEN MoonlightAudioPlayerSnapshot final {
    bool matched = false;
    MoonlightAudioStreamIdentity identity{};
    MoonlightAudioPlayerState state = MoonlightAudioPlayerState::Idle;
    MoonlightAudioPauseReason pauseReason = MoonlightAudioPauseReason::None;
    std::uint64_t lastOperationGeneration = 0U;
    std::uint64_t acceptedChunks = 0U;
    std::uint64_t acceptedBytes = 0U;
    std::uint64_t rejectedChunks = 0U;
    bool ownerReady = false;
};

class REMOTEDESK_MOONLIGHT_AUDIO_PLAYER_HIDDEN MoonlightAudioPlayerPort {
  public:
    virtual ~MoonlightAudioPlayerPort() = default;
    virtual bool ownerReady(const Render::DecoderSessionIdentity& owner) noexcept = 0;
    virtual int submit(const Render::DecoderSessionIdentity& owner, const std::uint8_t* pcm,
                       std::size_t pcmBytes, int sampleRate, int channels) noexcept = 0;
    virtual bool suspendAndFlush(const Render::DecoderSessionIdentity& owner) noexcept = 0;
    virtual bool destroyAndFlush(const Render::DecoderSessionIdentity& owner) noexcept = 0;
};

// Exact-owner N2-07 handoff into the existing AudioPlayer registry and queue.
// This object owns no OHAudio renderer, registry, queue, worker or session.
class REMOTEDESK_MOONLIGHT_AUDIO_PLAYER_HIDDEN MoonlightAudioPlayerSink final
    : public MoonlightAudioPcmSink {
  private:
    struct Impl;
    explicit MoonlightAudioPlayerSink(std::unique_ptr<Impl> impl) noexcept;

  public:
    ~MoonlightAudioPlayerSink() override;
    MoonlightAudioPlayerSink(const MoonlightAudioPlayerSink&) = delete;
    MoonlightAudioPlayerSink& operator=(const MoonlightAudioPlayerSink&) = delete;

    static std::shared_ptr<MoonlightAudioPlayerSink>
    createForTesting(std::shared_ptr<MoonlightAudioPlayerPort> port) noexcept;
    static std::shared_ptr<MoonlightAudioPlayerSink> createProduction() noexcept;

    MoonlightAudioPlayerControlResult activate(const MoonlightAudioStreamIdentity& identity,
                                               std::uint64_t operationGeneration) noexcept;
    MoonlightAudioPlayerControlResult pause(const MoonlightAudioStreamIdentity& identity,
                                            std::uint64_t operationGeneration,
                                            MoonlightAudioPauseReason reason) noexcept;
    MoonlightAudioPlayerControlResult resume(const MoonlightAudioStreamIdentity& identity,
                                             std::uint64_t operationGeneration) noexcept;
    MoonlightAudioPlayerControlResult stop(const MoonlightAudioStreamIdentity& identity,
                                           std::uint64_t operationGeneration) noexcept;
    MoonlightAudioPlayerControlResult cleanup(const MoonlightAudioStreamIdentity& identity,
                                              std::uint64_t operationGeneration) noexcept;

    bool submit(const MoonlightAudioStreamIdentity& identity, const std::uint8_t* pcm,
                std::size_t pcmBytes, std::size_t decodedFrames, bool plc) noexcept override;

    MoonlightAudioPlayerSnapshot
    snapshot(const MoonlightAudioStreamIdentity& identity) const noexcept;

  private:
    std::unique_ptr<Impl> impl_;
};

} // namespace remotedesk::moonlight

#endif // REMOTEDESK_MOONLIGHT_AUDIO_PLAYER_SINK_H
