#include "moonlight/media/MoonlightMediaClockStats.h"
#include "test/test_runner.h"

#include <limits>
#include <thread>
#include <vector>

namespace {

using namespace remotedesk::moonlight;

MoonlightMediaClockIdentity mediaIdentity(std::uint64_t ownerToken = 51U,
                                          std::uint64_t windowGeneration = 3U) {
    return {{801U, 13U, ownerToken}, windowGeneration};
}

std::unique_ptr<MoonlightMediaClockStats> activeStats(
    const MoonlightMediaClockIdentity& identity,
    MoonlightMediaStatsLimits limits = {}) {
    auto stats = MoonlightMediaClockStats::create(limits);
    RDP_ASSERT(stats != nullptr);
    RDP_ASSERT_EQ(stats->start(identity, 1U).status,
                  MoonlightMediaClockControlStatus::Applied);
    return stats;
}

MoonlightVideoTimingSample timing(std::uint64_t sequence, std::uint64_t base,
                                  std::uint64_t networkUs = 10U,
                                  std::uint64_t decodeQueueUs = 20U,
                                  std::uint64_t decodeUs = 30U,
                                  std::uint64_t renderUs = 40U) {
    MoonlightVideoTimingSample sample;
    sample.sampleSequence = sequence;
    sample.observedAtUs = base + networkUs + decodeQueueUs + decodeUs + renderUs;
    sample.receiveTimeUs = base;
    sample.enqueueTimeUs = base + networkUs;
    sample.decoderAcceptedTimeUs = *sample.enqueueTimeUs + decodeQueueUs;
    sample.decoderOutputTimeUs = *sample.decoderAcceptedTimeUs + decodeUs;
    sample.presentedTimeUs = *sample.decoderOutputTimeUs + renderUs;
    return sample;
}

MoonlightRtpCounterSample rtp(std::uint64_t sequence, std::uint64_t sampledAtUs,
                              std::uint64_t sourceGeneration,
                              MoonlightRtpCounters counters) {
    return {sequence, sampledAtUs, sourceGeneration, counters};
}

RDP_TEST_CASE(moonlight_media_clock_rejects_invalid_limits_and_fences_lifecycle) {
    MoonlightMediaStatsLimits bad;
    bad.percentileWindow = 0U;
    RDP_ASSERT(MoonlightMediaClockStats::create(bad) == nullptr);

    auto stats = MoonlightMediaClockStats::create();
    RDP_ASSERT(stats != nullptr);
    const auto identity = mediaIdentity();
    RDP_ASSERT_EQ(stats->start({}, 1U).status,
                  MoonlightMediaClockControlStatus::InvalidRequest);
    RDP_ASSERT_EQ(stats->start(identity, 0U).status,
                  MoonlightMediaClockControlStatus::InvalidRequest);
    RDP_ASSERT_EQ(stats->start(identity, 1U).status,
                  MoonlightMediaClockControlStatus::Applied);
    RDP_ASSERT_EQ(stats->start(identity, 1U).status,
                  MoonlightMediaClockControlStatus::AlreadyApplied);
    auto stale = identity;
    ++stale.key.generation;
    RDP_ASSERT_EQ(stats->stop(stale, 2U).status,
                  MoonlightMediaClockControlStatus::Stale);
    RDP_ASSERT_EQ(stats->stop(identity, 2U).status,
                  MoonlightMediaClockControlStatus::Applied);
    RDP_ASSERT_EQ(stats->cleanup(identity, 3U).status,
                  MoonlightMediaClockControlStatus::Applied);
    auto nextWindow = identity;
    ++nextWindow.windowGeneration;
    RDP_ASSERT_EQ(stats->start(nextWindow, 3U).status,
                  MoonlightMediaClockControlStatus::Stale);
}

RDP_TEST_CASE(moonlight_media_clock_keeps_absent_distinct_from_measured_zero) {
    MoonlightMediaStatsLimits limits;
    limits.videoSampleStride = 1U;
    const auto identity = mediaIdentity();
    auto stats = activeStats(identity, limits);
    auto sample = timing(1U, 1000U, 0U, 0U, 0U, 0U);
    RDP_ASSERT_EQ(stats->recordVideoTiming(identity, sample),
                  MoonlightMediaSampleStatus::Accepted);
    const auto snapshot = stats->snapshot(identity);
    RDP_ASSERT(snapshot.matched);
    RDP_ASSERT(snapshot.networkAssemblyUs.has_value());
    RDP_ASSERT_EQ(snapshot.networkAssemblyUs->p50, static_cast<std::uint64_t>(0U));
    RDP_ASSERT(snapshot.decodeQueueUs.has_value());
    RDP_ASSERT(snapshot.decodeUs.has_value());
    RDP_ASSERT(snapshot.renderUs.has_value());
    RDP_ASSERT(snapshot.endToEndUs.has_value());
    RDP_ASSERT(!snapshot.hostProcessingUs.has_value());
    RDP_ASSERT(!snapshot.audioQueueDurationUs.has_value());
    RDP_ASSERT(!snapshot.videoRtp.has_value());
}

RDP_TEST_CASE(moonlight_media_clock_partial_receipts_leave_unobserved_stages_absent) {
    MoonlightMediaStatsLimits limits;
    limits.videoSampleStride = 1U;
    const auto identity = mediaIdentity();
    auto stats = activeStats(identity, limits);
    MoonlightVideoTimingSample sample;
    sample.sampleSequence = 1U;
    sample.observedAtUs = 120U;
    sample.receiveTimeUs = 100U;
    sample.enqueueTimeUs = 120U;
    sample.hostProcessingLatencyDeciMs = 15U;
    RDP_ASSERT_EQ(stats->recordVideoTiming(identity, sample),
                  MoonlightMediaSampleStatus::Accepted);
    const auto snapshot = stats->snapshot(identity);
    RDP_ASSERT_EQ(snapshot.networkAssemblyUs->p50, static_cast<std::uint64_t>(20U));
    RDP_ASSERT_EQ(snapshot.hostProcessingUs->p50, static_cast<std::uint64_t>(1500U));
    RDP_ASSERT(!snapshot.decodeQueueUs.has_value());
    RDP_ASSERT(!snapshot.decodeUs.has_value());
    RDP_ASSERT(!snapshot.renderUs.has_value());
    RDP_ASSERT(!snapshot.endToEndUs.has_value());
}

RDP_TEST_CASE(moonlight_media_clock_rejects_bad_order_duration_and_replay) {
    MoonlightMediaStatsLimits limits;
    limits.videoSampleStride = 1U;
    limits.maximumStageDurationUs = 100U;
    const auto identity = mediaIdentity();
    auto stats = activeStats(identity, limits);
    auto badOrder = timing(1U, 1000U);
    badOrder.decoderOutputTimeUs = *badOrder.decoderAcceptedTimeUs - 1U;
    RDP_ASSERT_EQ(stats->recordVideoTiming(identity, badOrder),
                  MoonlightMediaSampleStatus::InvalidRequest);
    auto tooLong = timing(2U, 1000U, 101U, 0U, 0U, 0U);
    RDP_ASSERT_EQ(stats->recordVideoTiming(identity, tooLong),
                  MoonlightMediaSampleStatus::InvalidRequest);
    RDP_ASSERT_EQ(stats->recordVideoTiming(identity, timing(3U, 1000U)),
                  MoonlightMediaSampleStatus::Accepted);
    RDP_ASSERT_EQ(stats->recordVideoTiming(identity, timing(3U, 2000U)),
                  MoonlightMediaSampleStatus::Stale);
    const auto snapshot = stats->snapshot(identity);
    RDP_ASSERT_EQ(snapshot.invalidSamples, static_cast<std::uint64_t>(2U));
    RDP_ASSERT_EQ(snapshot.staleSamples, static_cast<std::uint64_t>(1U));
}

RDP_TEST_CASE(moonlight_media_clock_uses_stride_and_bounded_nearest_rank_percentiles) {
    MoonlightMediaStatsLimits limits;
    limits.percentileWindow = 4U;
    limits.videoSampleStride = 2U;
    const auto identity = mediaIdentity();
    auto stats = activeStats(identity, limits);
    for (std::uint64_t index = 1U; index <= 9U; ++index) {
        const auto status = stats->recordVideoTiming(
            identity, timing(index, index * 1000U, index * 10U, 0U, 0U, 0U));
        RDP_ASSERT_EQ(status, (index % 2U) == 1U
                                  ? MoonlightMediaSampleStatus::Accepted
                                  : MoonlightMediaSampleStatus::Throttled);
    }
    const auto snapshot = stats->snapshot(identity);
    RDP_ASSERT_EQ(snapshot.observedVideoFrames, static_cast<std::uint64_t>(9U));
    RDP_ASSERT_EQ(snapshot.sampledVideoFrames, static_cast<std::uint64_t>(5U));
    RDP_ASSERT_EQ(snapshot.throttledSamples, static_cast<std::uint64_t>(4U));
    RDP_ASSERT_EQ(snapshot.networkAssemblyUs->totalSamples, static_cast<std::uint64_t>(5U));
    RDP_ASSERT_EQ(snapshot.networkAssemblyUs->windowSamples, static_cast<std::size_t>(4U));
    RDP_ASSERT_EQ(snapshot.networkAssemblyUs->p50, static_cast<std::uint64_t>(50U));
    RDP_ASSERT_EQ(snapshot.networkAssemblyUs->p95, static_cast<std::uint64_t>(90U));
    RDP_ASSERT_EQ(snapshot.networkAssemblyUs->maximum, static_cast<std::uint64_t>(90U));
}

RDP_TEST_CASE(moonlight_media_clock_rtp_baseline_preserves_present_zero_deltas) {
    MoonlightMediaStatsLimits limits;
    limits.minimumRtpSampleIntervalUs = 100U;
    const auto identity = mediaIdentity();
    auto stats = activeStats(identity, limits);
    const MoonlightRtpCounters counters {10U, 2U, 1U, 0U, 3U, 4U, 5U};
    RDP_ASSERT_EQ(stats->recordRtpCounters(
                      identity, static_cast<MoonlightMediaRtpStream>(255U),
                      rtp(1U, 100U, 7U, counters)),
                  MoonlightMediaSampleStatus::InvalidRequest);
    RDP_ASSERT_EQ(stats->recordRtpCounters(identity, MoonlightMediaRtpStream::Video,
                                           rtp(1U, 100U, 7U, counters)),
                  MoonlightMediaSampleStatus::BaselineEstablished);
    RDP_ASSERT(!stats->snapshot(identity).videoRtp.has_value());
    RDP_ASSERT_EQ(stats->recordRtpCounters(identity, MoonlightMediaRtpStream::Video,
                                           rtp(2U, 200U, 7U, counters)),
                  MoonlightMediaSampleStatus::Accepted);
    const auto snapshot = stats->snapshot(identity);
    RDP_ASSERT(snapshot.videoRtp.has_value());
    RDP_ASSERT_EQ(snapshot.videoRtp->intervals, static_cast<std::uint64_t>(1U));
    RDP_ASSERT_EQ(snapshot.videoRtp->delta.mediaPackets, static_cast<std::uint64_t>(0U));
    RDP_ASSERT(!snapshot.audioRtp.has_value());
}

RDP_TEST_CASE(moonlight_media_clock_rtp_aggregates_exact_fields_and_resets_safely) {
    MoonlightMediaStatsLimits limits;
    limits.minimumRtpSampleIntervalUs = 10U;
    const auto identity = mediaIdentity();
    auto stats = activeStats(identity, limits);
    const MoonlightRtpCounters first {10U, 20U, 30U, 40U, 50U, 60U, 70U};
    const MoonlightRtpCounters second {11U, 22U, 33U, 44U, 55U, 66U, 77U};
    RDP_ASSERT_EQ(stats->recordRtpCounters(identity, MoonlightMediaRtpStream::Audio,
                                           rtp(1U, 10U, 1U, first)),
                  MoonlightMediaSampleStatus::BaselineEstablished);
    RDP_ASSERT_EQ(stats->recordRtpCounters(identity, MoonlightMediaRtpStream::Audio,
                                           rtp(2U, 20U, 1U, second)),
                  MoonlightMediaSampleStatus::Accepted);
    auto snapshot = stats->snapshot(identity);
    RDP_ASSERT_EQ(snapshot.audioRtp->delta.mediaPackets, static_cast<std::uint64_t>(1U));
    RDP_ASSERT_EQ(snapshot.audioRtp->delta.fecPackets, static_cast<std::uint64_t>(2U));
    RDP_ASSERT_EQ(snapshot.audioRtp->delta.fecRecoveredPackets, static_cast<std::uint64_t>(3U));
    RDP_ASSERT_EQ(snapshot.audioRtp->delta.fecRecoveryFailureEvents,
                  static_cast<std::uint64_t>(4U));
    RDP_ASSERT_EQ(snapshot.audioRtp->delta.outOfSequencePackets,
                  static_cast<std::uint64_t>(5U));
    RDP_ASSERT_EQ(snapshot.audioRtp->delta.invalidPackets, static_cast<std::uint64_t>(6U));
    RDP_ASSERT_EQ(snapshot.audioRtp->delta.invalidFecPackets, static_cast<std::uint64_t>(7U));

    RDP_ASSERT_EQ(stats->recordRtpCounters(identity, MoonlightMediaRtpStream::Audio,
                                           rtp(3U, 30U, 2U, first)),
                  MoonlightMediaSampleStatus::CounterReset);
    snapshot = stats->snapshot(identity);
    RDP_ASSERT(!snapshot.audioRtp.has_value());
    RDP_ASSERT_EQ(snapshot.rtpCounterResets, static_cast<std::uint64_t>(1U));
    RDP_ASSERT_EQ(stats->recordRtpCounters(identity, MoonlightMediaRtpStream::Audio,
                                           rtp(4U, 40U, 2U, first)),
                  MoonlightMediaSampleStatus::Accepted);
    RDP_ASSERT(stats->snapshot(identity).audioRtp.has_value());
}

RDP_TEST_CASE(moonlight_media_clock_throttles_rtp_without_advancing_baseline) {
    MoonlightMediaStatsLimits limits;
    limits.minimumRtpSampleIntervalUs = 100U;
    const auto identity = mediaIdentity();
    auto stats = activeStats(identity, limits);
    RDP_ASSERT_EQ(stats->recordRtpCounters(identity, MoonlightMediaRtpStream::Video,
                                           rtp(1U, 100U, 1U, {1U})),
                  MoonlightMediaSampleStatus::BaselineEstablished);
    RDP_ASSERT_EQ(stats->recordRtpCounters(identity, MoonlightMediaRtpStream::Video,
                                           rtp(2U, 150U, 1U, {100U})),
                  MoonlightMediaSampleStatus::Throttled);
    RDP_ASSERT_EQ(stats->recordRtpCounters(identity, MoonlightMediaRtpStream::Video,
                                           rtp(3U, 200U, 1U, {2U})),
                  MoonlightMediaSampleStatus::Accepted);
    const auto snapshot = stats->snapshot(identity);
    RDP_ASSERT_EQ(snapshot.videoRtp->delta.mediaPackets, static_cast<std::uint64_t>(1U));
    RDP_ASSERT_EQ(snapshot.throttledSamples, static_cast<std::uint64_t>(1U));
}

RDP_TEST_CASE(moonlight_media_clock_audio_queue_tracks_zero_percentiles_and_counter_deltas) {
    MoonlightMediaStatsLimits limits;
    limits.minimumAudioQueueSampleIntervalUs = 100U;
    const auto identity = mediaIdentity();
    auto stats = activeStats(identity, limits);
    MoonlightAudioQueueSample first {1U, 100U, 8U, 0U, 10U, 100U};
    RDP_ASSERT_EQ(stats->recordAudioQueue(identity, first),
                  MoonlightMediaSampleStatus::BaselineEstablished);
    MoonlightAudioQueueSample throttled {2U, 150U, 8U, 999U, 999U, 999U};
    RDP_ASSERT_EQ(stats->recordAudioQueue(identity, throttled),
                  MoonlightMediaSampleStatus::Throttled);
    MoonlightAudioQueueSample second {3U, 200U, 8U, 10U, 12U, 130U};
    RDP_ASSERT_EQ(stats->recordAudioQueue(identity, second),
                  MoonlightMediaSampleStatus::Accepted);
    const auto snapshot = stats->snapshot(identity);
    RDP_ASSERT_EQ(snapshot.audioQueueSamples, static_cast<std::uint64_t>(2U));
    RDP_ASSERT_EQ(snapshot.audioQueueDurationUs->p50, static_cast<std::uint64_t>(0U));
    RDP_ASSERT_EQ(snapshot.audioQueueDurationUs->p95, static_cast<std::uint64_t>(10000U));
    RDP_ASSERT_EQ(snapshot.audioCounters->underruns, static_cast<std::uint64_t>(2U));
    RDP_ASSERT_EQ(snapshot.audioCounters->droppedBytes, static_cast<std::uint64_t>(30U));
}

RDP_TEST_CASE(moonlight_media_clock_audio_counter_reset_does_not_create_huge_delta) {
    MoonlightMediaStatsLimits limits;
    limits.minimumAudioQueueSampleIntervalUs = 1U;
    const auto identity = mediaIdentity();
    auto stats = activeStats(identity, limits);
    RDP_ASSERT_EQ(stats->recordAudioQueue(identity, {1U, 1U, 1U, 5U, 100U, 200U}),
                  MoonlightMediaSampleStatus::BaselineEstablished);
    RDP_ASSERT_EQ(stats->recordAudioQueue(identity, {2U, 2U, 1U, {}, 10U, 20U}),
                  MoonlightMediaSampleStatus::CounterReset);
    auto snapshot = stats->snapshot(identity);
    RDP_ASSERT(!snapshot.audioCounters.has_value());
    RDP_ASSERT(!snapshot.audioQueueDurationUs.has_value());
    RDP_ASSERT_EQ(snapshot.audioQueueSamples, static_cast<std::uint64_t>(0U));
    RDP_ASSERT_EQ(snapshot.audioCounterResets, static_cast<std::uint64_t>(1U));
    RDP_ASSERT_EQ(stats->recordAudioQueue(identity, {3U, 3U, 1U, {}, 10U, 20U}),
                  MoonlightMediaSampleStatus::Accepted);
    snapshot = stats->snapshot(identity);
    RDP_ASSERT_EQ(snapshot.audioCounters->underruns, static_cast<std::uint64_t>(0U));
    RDP_ASSERT_EQ(snapshot.audioCounters->droppedBytes, static_cast<std::uint64_t>(0U));
}

RDP_TEST_CASE(moonlight_media_clock_saturates_counter_aggregation) {
    MoonlightMediaStatsLimits limits;
    limits.minimumRtpSampleIntervalUs = 1U;
    const auto identity = mediaIdentity();
    auto stats = activeStats(identity, limits);
    const std::uint64_t maximum = std::numeric_limits<std::uint64_t>::max();
    RDP_ASSERT_EQ(stats->recordRtpCounters(identity, MoonlightMediaRtpStream::Video,
                                           rtp(1U, 1U, 1U, {})),
                  MoonlightMediaSampleStatus::BaselineEstablished);
    RDP_ASSERT_EQ(stats->recordRtpCounters(identity, MoonlightMediaRtpStream::Video,
                                           rtp(2U, 2U, 1U, {maximum})),
                  MoonlightMediaSampleStatus::Accepted);
    RDP_ASSERT_EQ(stats->snapshot(identity).videoRtp->delta.mediaPackets, maximum);
}

RDP_TEST_CASE(moonlight_media_clock_stop_rejects_late_samples_and_allows_new_window) {
    MoonlightMediaStatsLimits limits;
    limits.videoSampleStride = 1U;
    const auto identity = mediaIdentity();
    auto stats = activeStats(identity, limits);
    RDP_ASSERT_EQ(stats->recordVideoTiming(identity, timing(1U, 1000U)),
                  MoonlightMediaSampleStatus::Accepted);
    RDP_ASSERT_EQ(stats->stop(identity, 2U).status,
                  MoonlightMediaClockControlStatus::Applied);
    RDP_ASSERT_EQ(stats->recordVideoTiming(identity, timing(2U, 2000U)),
                  MoonlightMediaSampleStatus::InvalidState);
    RDP_ASSERT_EQ(stats->cleanup(identity, 3U).status,
                  MoonlightMediaClockControlStatus::Applied);
    auto next = identity;
    ++next.windowGeneration;
    RDP_ASSERT_EQ(stats->start(next, 4U).status,
                  MoonlightMediaClockControlStatus::Applied);
    const auto snapshot = stats->snapshot(next);
    RDP_ASSERT(snapshot.matched);
    RDP_ASSERT_EQ(snapshot.observedVideoFrames, static_cast<std::uint64_t>(0U));
    RDP_ASSERT(!snapshot.networkAssemblyUs.has_value());
}

RDP_TEST_CASE(moonlight_media_clock_concurrent_samples_are_bounded_and_owner_scoped) {
    MoonlightMediaStatsLimits limits;
    limits.videoSampleStride = 1U;
    limits.minimumRtpSampleIntervalUs = 0U;
    const auto identity = mediaIdentity();
    auto stats = activeStats(identity, limits);
    auto stale = identity;
    ++stale.key.ownerToken;
    std::vector<std::thread> workers;
    for (std::uint64_t index = 1U; index <= 8U; ++index) {
        workers.emplace_back([&, index]() {
            const auto candidate = (index % 2U) == 0U ? stale : identity;
            (void)stats->recordVideoTiming(candidate, timing(index, index * 1000U));
        });
    }
    for (auto& worker : workers) {
        worker.join();
    }
    const auto snapshot = stats->snapshot(identity);
    RDP_ASSERT(snapshot.matched);
    RDP_ASSERT(snapshot.sampledVideoFrames <= 4U);
    RDP_ASSERT(snapshot.staleSamples >= 4U);
    RDP_ASSERT(snapshot.networkAssemblyUs->windowSamples <= limits.percentileWindow);
}

} // namespace
