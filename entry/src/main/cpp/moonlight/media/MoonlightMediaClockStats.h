#ifndef REMOTEDESK_MOONLIGHT_MEDIA_CLOCK_STATS_H
#define REMOTEDESK_MOONLIGHT_MEDIA_CLOCK_STATS_H

#include "moonlight/core/MoonlightSessionOwner.h"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>

#if defined(__GNUC__) || defined(__clang__)
#define REMOTEDESK_MOONLIGHT_MEDIA_STATS_HIDDEN __attribute__((visibility("hidden")))
#else
#define REMOTEDESK_MOONLIGHT_MEDIA_STATS_HIDDEN
#endif

namespace remotedesk::moonlight {

constexpr std::size_t kMoonlightMaximumPercentileWindow = 256U;

struct REMOTEDESK_MOONLIGHT_MEDIA_STATS_HIDDEN MoonlightMediaClockIdentity final {
    MoonlightSessionKey key{};
    std::uint64_t windowGeneration = 0U;

    constexpr bool valid() const noexcept {
        return key.valid() && windowGeneration != 0U;
    }
};

REMOTEDESK_MOONLIGHT_MEDIA_STATS_HIDDEN constexpr bool operator==(
    const MoonlightMediaClockIdentity& left,
    const MoonlightMediaClockIdentity& right) noexcept {
    return left.key == right.key && left.windowGeneration == right.windowGeneration;
}

REMOTEDESK_MOONLIGHT_MEDIA_STATS_HIDDEN constexpr bool operator!=(
    const MoonlightMediaClockIdentity& left,
    const MoonlightMediaClockIdentity& right) noexcept {
    return !(left == right);
}

enum class MoonlightMediaClockState : std::uint8_t {
    Idle,
    Active,
    Stopped,
    Cleaned,
};

enum class MoonlightMediaClockControlStatus : std::uint8_t {
    Applied,
    AlreadyApplied,
    InvalidRequest,
    InvalidState,
    Stale,
};

enum class MoonlightMediaSampleStatus : std::uint8_t {
    Accepted,
    BaselineEstablished,
    CounterReset,
    Throttled,
    InvalidRequest,
    InvalidState,
    Stale,
};

enum class MoonlightMediaRtpStream : std::uint8_t {
    Video,
    Audio,
};

struct REMOTEDESK_MOONLIGHT_MEDIA_STATS_HIDDEN MoonlightMediaStatsLimits final {
    std::size_t percentileWindow = 120U;
    std::uint32_t videoSampleStride = 6U;
    std::uint64_t minimumRtpSampleIntervalUs = 250000U;
    std::uint64_t minimumAudioQueueSampleIntervalUs = 100000U;
    std::uint64_t maximumStageDurationUs = 30000000U;
    std::uint32_t maximumAudioQueueDurationMs = 10000U;

    bool valid() const noexcept;
};

struct REMOTEDESK_MOONLIGHT_MEDIA_STATS_HIDDEN MoonlightVideoTimingSample final {
    std::uint64_t sampleSequence = 0U;
    std::uint64_t observedAtUs = 0U;
    std::optional<std::uint64_t> receiveTimeUs;
    std::optional<std::uint64_t> enqueueTimeUs;
    std::optional<std::uint64_t> decoderAcceptedTimeUs;
    std::optional<std::uint64_t> decoderOutputTimeUs;
    std::optional<std::uint64_t> presentedTimeUs;
    // common-c defines zero as absent, so callers must project it to nullopt.
    std::optional<std::uint16_t> hostProcessingLatencyDeciMs;
};

struct REMOTEDESK_MOONLIGHT_MEDIA_STATS_HIDDEN MoonlightRtpCounters final {
    std::uint64_t mediaPackets = 0U;
    std::uint64_t fecPackets = 0U;
    std::uint64_t fecRecoveredPackets = 0U;
    std::uint64_t fecRecoveryFailureEvents = 0U;
    std::uint64_t outOfSequencePackets = 0U;
    std::uint64_t invalidPackets = 0U;
    std::uint64_t invalidFecPackets = 0U;
};

struct REMOTEDESK_MOONLIGHT_MEDIA_STATS_HIDDEN MoonlightRtpCounterSample final {
    std::uint64_t sampleSequence = 0U;
    std::uint64_t sampledAtUs = 0U;
    std::uint64_t sourceGeneration = 0U;
    MoonlightRtpCounters counters{};
};

struct REMOTEDESK_MOONLIGHT_MEDIA_STATS_HIDDEN MoonlightAudioQueueSample final {
    std::uint64_t sampleSequence = 0U;
    std::uint64_t sampledAtUs = 0U;
    std::uint64_t sourceGeneration = 0U;
    std::optional<std::uint32_t> queuedDurationMs;
    std::optional<std::uint64_t> underrunCount;
    std::optional<std::uint64_t> droppedBytes;
};

struct REMOTEDESK_MOONLIGHT_MEDIA_STATS_HIDDEN MoonlightPercentileSummary final {
    std::uint64_t totalSamples = 0U;
    std::size_t windowSamples = 0U;
    std::uint64_t p50 = 0U;
    std::uint64_t p95 = 0U;
    std::uint64_t maximum = 0U;
};

struct REMOTEDESK_MOONLIGHT_MEDIA_STATS_HIDDEN MoonlightRtpDeltaSnapshot final {
    std::uint64_t intervals = 0U;
    MoonlightRtpCounters delta{};
};

struct REMOTEDESK_MOONLIGHT_MEDIA_STATS_HIDDEN MoonlightAudioCounterDeltaSnapshot final {
    std::uint64_t intervals = 0U;
    std::uint64_t underruns = 0U;
    std::uint64_t droppedBytes = 0U;
};

struct REMOTEDESK_MOONLIGHT_MEDIA_STATS_HIDDEN MoonlightMediaClockSnapshot final {
    bool matched = false;
    MoonlightMediaClockIdentity identity{};
    MoonlightMediaClockState state = MoonlightMediaClockState::Idle;
    std::uint64_t lastOperationGeneration = 0U;
    std::uint64_t observedVideoFrames = 0U;
    std::uint64_t sampledVideoFrames = 0U;
    std::uint64_t audioQueueSamples = 0U;
    std::uint64_t throttledSamples = 0U;
    std::uint64_t invalidSamples = 0U;
    std::uint64_t staleSamples = 0U;
    std::uint64_t rtpCounterResets = 0U;
    std::uint64_t audioCounterResets = 0U;
    std::optional<MoonlightPercentileSummary> networkAssemblyUs;
    std::optional<MoonlightPercentileSummary> decodeQueueUs;
    std::optional<MoonlightPercentileSummary> decodeUs;
    std::optional<MoonlightPercentileSummary> renderUs;
    std::optional<MoonlightPercentileSummary> endToEndUs;
    std::optional<MoonlightPercentileSummary> hostProcessingUs;
    std::optional<MoonlightPercentileSummary> audioQueueDurationUs;
    std::optional<MoonlightRtpDeltaSnapshot> videoRtp;
    std::optional<MoonlightRtpDeltaSnapshot> audioRtp;
    std::optional<MoonlightAudioCounterDeltaSnapshot> audioCounters;
};

struct REMOTEDESK_MOONLIGHT_MEDIA_STATS_HIDDEN MoonlightMediaClockControlResult final {
    MoonlightMediaClockControlStatus status =
        MoonlightMediaClockControlStatus::InvalidRequest;
    MoonlightMediaClockIdentity identity{};
    std::uint64_t operationGeneration = 0U;
};

class REMOTEDESK_MOONLIGHT_MEDIA_STATS_HIDDEN MoonlightMediaClockStats final {
  private:
    struct Impl;
    explicit MoonlightMediaClockStats(std::unique_ptr<Impl> impl) noexcept;

  public:
    ~MoonlightMediaClockStats();
    MoonlightMediaClockStats(const MoonlightMediaClockStats&) = delete;
    MoonlightMediaClockStats& operator=(const MoonlightMediaClockStats&) = delete;

    static std::unique_ptr<MoonlightMediaClockStats> create(
        MoonlightMediaStatsLimits limits = {}) noexcept;

    MoonlightMediaClockControlResult start(
        const MoonlightMediaClockIdentity& identity,
        std::uint64_t operationGeneration) noexcept;
    MoonlightMediaSampleStatus recordVideoTiming(
        const MoonlightMediaClockIdentity& identity,
        const MoonlightVideoTimingSample& sample) noexcept;
    MoonlightMediaSampleStatus recordRtpCounters(
        const MoonlightMediaClockIdentity& identity,
        MoonlightMediaRtpStream stream,
        const MoonlightRtpCounterSample& sample) noexcept;
    MoonlightMediaSampleStatus recordAudioQueue(
        const MoonlightMediaClockIdentity& identity,
        const MoonlightAudioQueueSample& sample) noexcept;
    MoonlightMediaClockControlResult stop(
        const MoonlightMediaClockIdentity& identity,
        std::uint64_t operationGeneration) noexcept;
    MoonlightMediaClockControlResult cleanup(
        const MoonlightMediaClockIdentity& identity,
        std::uint64_t operationGeneration) noexcept;
    MoonlightMediaClockSnapshot snapshot(
        const MoonlightMediaClockIdentity& identity) const noexcept;

  private:
    std::unique_ptr<Impl> impl_;
};

} // namespace remotedesk::moonlight

#undef REMOTEDESK_MOONLIGHT_MEDIA_STATS_HIDDEN

#endif // REMOTEDESK_MOONLIGHT_MEDIA_CLOCK_STATS_H
