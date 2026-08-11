#include "moonlight/media/MoonlightMediaClockStats.h"

#include <algorithm>
#include <array>
#include <limits>
#include <mutex>
#include <utility>

namespace remotedesk::moonlight {
namespace {

std::uint64_t saturatingAdd(std::uint64_t left, std::uint64_t right) noexcept {
    const std::uint64_t maximum = std::numeric_limits<std::uint64_t>::max();
    return right > maximum - left ? maximum : left + right;
}

std::uint64_t saturatingIncrement(std::uint64_t value) noexcept {
    return value == std::numeric_limits<std::uint64_t>::max() ? value : value + 1U;
}

struct PercentileWindow final {
    explicit PercentileWindow(std::size_t requestedCapacity) noexcept
        : capacity(requestedCapacity) {}

    void add(std::uint64_t value) noexcept {
        if (count < capacity) {
            values[count] = value;
            ++count;
        } else {
            values[next] = value;
            next = (next + 1U) % capacity;
        }
        totalSamples = saturatingIncrement(totalSamples);
    }

    void clear() noexcept {
        values.fill(0U);
        count = 0U;
        next = 0U;
        totalSamples = 0U;
    }

    std::optional<MoonlightPercentileSummary> snapshot() const noexcept {
        if (count == 0U) {
            return std::nullopt;
        }
        std::array<std::uint64_t, kMoonlightMaximumPercentileWindow> sorted{};
        std::copy_n(values.begin(), count, sorted.begin());
        std::sort(sorted.begin(), sorted.begin() + static_cast<std::ptrdiff_t>(count));
        const auto nearestRankIndex = [this](std::size_t percentile) noexcept {
            const std::size_t rank = (percentile * count + 99U) / 100U;
            return rank == 0U ? 0U : rank - 1U;
        };
        return MoonlightPercentileSummary {
            totalSamples,
            count,
            sorted[nearestRankIndex(50U)],
            sorted[nearestRankIndex(95U)],
            sorted[count - 1U],
        };
    }

    std::array<std::uint64_t, kMoonlightMaximumPercentileWindow> values{};
    std::size_t capacity = 0U;
    std::size_t count = 0U;
    std::size_t next = 0U;
    std::uint64_t totalSamples = 0U;
};

bool countersDecreased(const MoonlightRtpCounters& current,
                       const MoonlightRtpCounters& previous) noexcept {
    return current.mediaPackets < previous.mediaPackets ||
        current.fecPackets < previous.fecPackets ||
        current.fecRecoveredPackets < previous.fecRecoveredPackets ||
        current.fecRecoveryFailureEvents < previous.fecRecoveryFailureEvents ||
        current.outOfSequencePackets < previous.outOfSequencePackets ||
        current.invalidPackets < previous.invalidPackets ||
        current.invalidFecPackets < previous.invalidFecPackets;
}

MoonlightRtpCounters counterDelta(const MoonlightRtpCounters& current,
                                  const MoonlightRtpCounters& previous) noexcept {
    return {
        current.mediaPackets - previous.mediaPackets,
        current.fecPackets - previous.fecPackets,
        current.fecRecoveredPackets - previous.fecRecoveredPackets,
        current.fecRecoveryFailureEvents - previous.fecRecoveryFailureEvents,
        current.outOfSequencePackets - previous.outOfSequencePackets,
        current.invalidPackets - previous.invalidPackets,
        current.invalidFecPackets - previous.invalidFecPackets,
    };
}

void addCounters(MoonlightRtpCounters& total, const MoonlightRtpCounters& delta) noexcept {
    total.mediaPackets = saturatingAdd(total.mediaPackets, delta.mediaPackets);
    total.fecPackets = saturatingAdd(total.fecPackets, delta.fecPackets);
    total.fecRecoveredPackets = saturatingAdd(
        total.fecRecoveredPackets, delta.fecRecoveredPackets);
    total.fecRecoveryFailureEvents = saturatingAdd(
        total.fecRecoveryFailureEvents, delta.fecRecoveryFailureEvents);
    total.outOfSequencePackets = saturatingAdd(
        total.outOfSequencePackets, delta.outOfSequencePackets);
    total.invalidPackets = saturatingAdd(total.invalidPackets, delta.invalidPackets);
    total.invalidFecPackets = saturatingAdd(
        total.invalidFecPackets, delta.invalidFecPackets);
}

MoonlightMediaClockControlResult controlResult(
    MoonlightMediaClockControlStatus status,
    const MoonlightMediaClockIdentity& identity,
    std::uint64_t operationGeneration) noexcept {
    return {status, identity, operationGeneration};
}

struct RtpState final {
    bool initialized = false;
    std::uint64_t sourceGeneration = 0U;
    std::uint64_t lastSequence = 0U;
    std::uint64_t lastObservedAtUs = 0U;
    std::uint64_t lastAcceptedAtUs = 0U;
    MoonlightRtpCounters baseline{};
    bool aggregatePresent = false;
    MoonlightRtpDeltaSnapshot aggregate{};

    void establish(const MoonlightRtpCounterSample& sample) noexcept {
        initialized = true;
        sourceGeneration = sample.sourceGeneration;
        lastAcceptedAtUs = sample.sampledAtUs;
        baseline = sample.counters;
        aggregatePresent = false;
        aggregate = {};
    }

    void clear() noexcept {
        *this = {};
    }
};

struct AudioCounterState final {
    bool sourceInitialized = false;
    std::uint64_t sourceGeneration = 0U;
    std::uint64_t lastSequence = 0U;
    std::uint64_t lastObservedAtUs = 0U;
    std::uint64_t lastAcceptedAtUs = 0U;
    std::optional<std::uint64_t> underrunBaseline;
    std::optional<std::uint64_t> droppedBytesBaseline;
    bool aggregatePresent = false;
    MoonlightAudioCounterDeltaSnapshot aggregate{};

    void clearAggregate() noexcept {
        aggregatePresent = false;
        aggregate = {};
    }

    void clear() noexcept {
        *this = {};
    }
};

bool validOptionalTimestamp(const std::optional<std::uint64_t>& value) noexcept {
    return !value.has_value() || *value != 0U;
}

} // namespace

struct MoonlightMediaClockStats::Impl final {
    explicit Impl(MoonlightMediaStatsLimits requestedLimits) noexcept
        : limits(requestedLimits),
          networkAssembly(requestedLimits.percentileWindow),
          decodeQueue(requestedLimits.percentileWindow),
          decode(requestedLimits.percentileWindow),
          render(requestedLimits.percentileWindow),
          endToEnd(requestedLimits.percentileWindow),
          hostProcessing(requestedLimits.percentileWindow),
          audioQueueDuration(requestedLimits.percentileWindow) {}

    void clearMetrics() noexcept {
        observedVideoFrames = 0U;
        sampledVideoFrames = 0U;
        audioQueueSamples = 0U;
        throttledSamples = 0U;
        invalidSamples = 0U;
        staleSamples = 0U;
        rtpCounterResets = 0U;
        audioCounterResets = 0U;
        lastVideoSequence = 0U;
        lastVideoObservedAtUs = 0U;
        networkAssembly.clear();
        decodeQueue.clear();
        decode.clear();
        render.clear();
        endToEnd.clear();
        hostProcessing.clear();
        audioQueueDuration.clear();
        videoRtp.clear();
        audioRtp.clear();
        audioCounters.clear();
    }

    mutable std::mutex mutex;
    MoonlightMediaStatsLimits limits{};
    MoonlightMediaClockIdentity identity{};
    MoonlightMediaClockIdentity lastCleanedIdentity{};
    MoonlightMediaClockIdentity highWaterIdentity{};
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
    std::uint64_t lastVideoSequence = 0U;
    std::uint64_t lastVideoObservedAtUs = 0U;
    PercentileWindow networkAssembly;
    PercentileWindow decodeQueue;
    PercentileWindow decode;
    PercentileWindow render;
    PercentileWindow endToEnd;
    PercentileWindow hostProcessing;
    PercentileWindow audioQueueDuration;
    RtpState videoRtp{};
    RtpState audioRtp{};
    AudioCounterState audioCounters{};
};

bool MoonlightMediaStatsLimits::valid() const noexcept {
    return percentileWindow != 0U && percentileWindow <= kMoonlightMaximumPercentileWindow &&
        videoSampleStride != 0U && maximumStageDurationUs != 0U &&
        maximumAudioQueueDurationMs != 0U;
}

MoonlightMediaClockStats::MoonlightMediaClockStats(std::unique_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}

MoonlightMediaClockStats::~MoonlightMediaClockStats() = default;

std::unique_ptr<MoonlightMediaClockStats> MoonlightMediaClockStats::create(
    MoonlightMediaStatsLimits limits) noexcept {
    if (!limits.valid()) {
        return nullptr;
    }
    try {
        return std::unique_ptr<MoonlightMediaClockStats>(
            new MoonlightMediaClockStats(std::make_unique<Impl>(limits)));
    } catch (...) {
        return nullptr;
    }
}

MoonlightMediaClockControlResult MoonlightMediaClockStats::start(
    const MoonlightMediaClockIdentity& requested,
    std::uint64_t operationGeneration) noexcept {
    if (impl_ == nullptr || !requested.valid() || operationGeneration == 0U) {
        return controlResult(MoonlightMediaClockControlStatus::InvalidRequest, requested,
                             operationGeneration);
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->state == MoonlightMediaClockState::Active && impl_->identity == requested) {
        if (operationGeneration < impl_->lastOperationGeneration) {
            return controlResult(MoonlightMediaClockControlStatus::Stale, requested,
                                 operationGeneration);
        }
        impl_->lastOperationGeneration = operationGeneration;
        return controlResult(MoonlightMediaClockControlStatus::AlreadyApplied, requested,
                             operationGeneration);
    }
    if (impl_->state != MoonlightMediaClockState::Idle &&
        impl_->state != MoonlightMediaClockState::Cleaned) {
        const bool staleOwner = impl_->highWaterIdentity.valid() &&
            requested.key.ownerToken <= impl_->highWaterIdentity.key.ownerToken;
        return controlResult(staleOwner ? MoonlightMediaClockControlStatus::Stale
                                        : MoonlightMediaClockControlStatus::InvalidState,
                             requested, operationGeneration);
    }
    if (impl_->highWaterIdentity.valid()) {
        const bool higherOwner =
            requested.key.ownerToken > impl_->highWaterIdentity.key.ownerToken;
        const bool nextWindow = requested.key == impl_->highWaterIdentity.key &&
            requested.windowGeneration > impl_->highWaterIdentity.windowGeneration;
        if (!higherOwner && !nextWindow) {
            return controlResult(MoonlightMediaClockControlStatus::Stale, requested,
                                 operationGeneration);
        }
        if (nextWindow && operationGeneration <= impl_->lastOperationGeneration) {
            return controlResult(MoonlightMediaClockControlStatus::Stale, requested,
                                 operationGeneration);
        }
    }
    impl_->clearMetrics();
    impl_->identity = requested;
    impl_->lastCleanedIdentity = {};
    impl_->highWaterIdentity = requested;
    impl_->state = MoonlightMediaClockState::Active;
    impl_->lastOperationGeneration = operationGeneration;
    return controlResult(MoonlightMediaClockControlStatus::Applied, requested,
                         operationGeneration);
}

MoonlightMediaSampleStatus MoonlightMediaClockStats::recordVideoTiming(
    const MoonlightMediaClockIdentity& requested,
    const MoonlightVideoTimingSample& sample) noexcept {
    if (impl_ == nullptr) {
        return MoonlightMediaSampleStatus::InvalidState;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->state != MoonlightMediaClockState::Active) {
        return MoonlightMediaSampleStatus::InvalidState;
    }
    if (impl_->identity != requested) {
        impl_->staleSamples = saturatingIncrement(impl_->staleSamples);
        return MoonlightMediaSampleStatus::Stale;
    }
    const bool validShape = sample.sampleSequence != 0U && sample.observedAtUs != 0U &&
        validOptionalTimestamp(sample.receiveTimeUs) &&
        validOptionalTimestamp(sample.enqueueTimeUs) &&
        validOptionalTimestamp(sample.decoderAcceptedTimeUs) &&
        validOptionalTimestamp(sample.decoderOutputTimeUs) &&
        validOptionalTimestamp(sample.presentedTimeUs) &&
        (!sample.hostProcessingLatencyDeciMs.has_value() ||
         *sample.hostProcessingLatencyDeciMs != 0U);
    if (!validShape) {
        impl_->invalidSamples = saturatingIncrement(impl_->invalidSamples);
        return MoonlightMediaSampleStatus::InvalidRequest;
    }

    const std::array<std::optional<std::uint64_t>, 5U> stages {
        sample.receiveTimeUs,
        sample.enqueueTimeUs,
        sample.decoderAcceptedTimeUs,
        sample.decoderOutputTimeUs,
        sample.presentedTimeUs,
    };
    bool hasMetric = sample.hostProcessingLatencyDeciMs.has_value();
    std::optional<std::uint64_t> previous;
    for (const auto& stage : stages) {
        if (!stage.has_value()) {
            continue;
        }
        if (previous.has_value() && *stage < *previous) {
            impl_->invalidSamples = saturatingIncrement(impl_->invalidSamples);
            return MoonlightMediaSampleStatus::InvalidRequest;
        }
        previous = stage;
    }
    if (previous.has_value() && sample.observedAtUs < *previous) {
        impl_->invalidSamples = saturatingIncrement(impl_->invalidSamples);
        return MoonlightMediaSampleStatus::InvalidRequest;
    }

    const auto validDuration = [this](const std::optional<std::uint64_t>& start,
                                      const std::optional<std::uint64_t>& end) noexcept {
        return !start.has_value() || !end.has_value() ||
            (*end - *start) <= impl_->limits.maximumStageDurationUs;
    };
    if (!validDuration(sample.receiveTimeUs, sample.enqueueTimeUs) ||
        !validDuration(sample.enqueueTimeUs, sample.decoderAcceptedTimeUs) ||
        !validDuration(sample.decoderAcceptedTimeUs, sample.decoderOutputTimeUs) ||
        !validDuration(sample.decoderOutputTimeUs, sample.presentedTimeUs) ||
        !validDuration(sample.receiveTimeUs, sample.presentedTimeUs)) {
        impl_->invalidSamples = saturatingIncrement(impl_->invalidSamples);
        return MoonlightMediaSampleStatus::InvalidRequest;
    }
    if (sample.hostProcessingLatencyDeciMs.has_value() &&
        static_cast<std::uint64_t>(*sample.hostProcessingLatencyDeciMs) * 100U >
            impl_->limits.maximumStageDurationUs) {
        impl_->invalidSamples = saturatingIncrement(impl_->invalidSamples);
        return MoonlightMediaSampleStatus::InvalidRequest;
    }
    for (std::size_t index = 1U; index < stages.size(); ++index) {
        hasMetric = hasMetric || (stages[index - 1U].has_value() && stages[index].has_value());
    }
    hasMetric = hasMetric ||
        (sample.receiveTimeUs.has_value() && sample.presentedTimeUs.has_value());
    if (!hasMetric) {
        impl_->invalidSamples = saturatingIncrement(impl_->invalidSamples);
        return MoonlightMediaSampleStatus::InvalidRequest;
    }
    if (sample.sampleSequence <= impl_->lastVideoSequence ||
        sample.observedAtUs < impl_->lastVideoObservedAtUs) {
        impl_->staleSamples = saturatingIncrement(impl_->staleSamples);
        return MoonlightMediaSampleStatus::Stale;
    }
    impl_->lastVideoSequence = sample.sampleSequence;
    impl_->lastVideoObservedAtUs = sample.observedAtUs;
    impl_->observedVideoFrames = saturatingIncrement(impl_->observedVideoFrames);
    if ((impl_->observedVideoFrames - 1U) % impl_->limits.videoSampleStride != 0U) {
        impl_->throttledSamples = saturatingIncrement(impl_->throttledSamples);
        return MoonlightMediaSampleStatus::Throttled;
    }

    if (sample.receiveTimeUs.has_value() && sample.enqueueTimeUs.has_value()) {
        impl_->networkAssembly.add(*sample.enqueueTimeUs - *sample.receiveTimeUs);
    }
    if (sample.enqueueTimeUs.has_value() && sample.decoderAcceptedTimeUs.has_value()) {
        impl_->decodeQueue.add(*sample.decoderAcceptedTimeUs - *sample.enqueueTimeUs);
    }
    if (sample.decoderAcceptedTimeUs.has_value() && sample.decoderOutputTimeUs.has_value()) {
        impl_->decode.add(*sample.decoderOutputTimeUs - *sample.decoderAcceptedTimeUs);
    }
    if (sample.decoderOutputTimeUs.has_value() && sample.presentedTimeUs.has_value()) {
        impl_->render.add(*sample.presentedTimeUs - *sample.decoderOutputTimeUs);
    }
    if (sample.receiveTimeUs.has_value() && sample.presentedTimeUs.has_value()) {
        impl_->endToEnd.add(*sample.presentedTimeUs - *sample.receiveTimeUs);
    }
    if (sample.hostProcessingLatencyDeciMs.has_value()) {
        impl_->hostProcessing.add(
            static_cast<std::uint64_t>(*sample.hostProcessingLatencyDeciMs) * 100U);
    }
    impl_->sampledVideoFrames = saturatingIncrement(impl_->sampledVideoFrames);
    return MoonlightMediaSampleStatus::Accepted;
}

MoonlightMediaSampleStatus MoonlightMediaClockStats::recordRtpCounters(
    const MoonlightMediaClockIdentity& requested,
    MoonlightMediaRtpStream stream,
    const MoonlightRtpCounterSample& sample) noexcept {
    if (impl_ == nullptr) {
        return MoonlightMediaSampleStatus::InvalidState;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->state != MoonlightMediaClockState::Active) {
        return MoonlightMediaSampleStatus::InvalidState;
    }
    if (impl_->identity != requested) {
        impl_->staleSamples = saturatingIncrement(impl_->staleSamples);
        return MoonlightMediaSampleStatus::Stale;
    }
    if ((stream != MoonlightMediaRtpStream::Video &&
         stream != MoonlightMediaRtpStream::Audio) ||
        sample.sampleSequence == 0U || sample.sampledAtUs == 0U ||
        sample.sourceGeneration == 0U) {
        impl_->invalidSamples = saturatingIncrement(impl_->invalidSamples);
        return MoonlightMediaSampleStatus::InvalidRequest;
    }
    RtpState& state = stream == MoonlightMediaRtpStream::Video
        ? impl_->videoRtp
        : impl_->audioRtp;
    if (sample.sampleSequence <= state.lastSequence ||
        sample.sampledAtUs < state.lastObservedAtUs) {
        impl_->staleSamples = saturatingIncrement(impl_->staleSamples);
        return MoonlightMediaSampleStatus::Stale;
    }
    state.lastSequence = sample.sampleSequence;
    state.lastObservedAtUs = sample.sampledAtUs;
    if (!state.initialized) {
        state.establish(sample);
        return MoonlightMediaSampleStatus::BaselineEstablished;
    }
    const bool reset = sample.sourceGeneration != state.sourceGeneration ||
        countersDecreased(sample.counters, state.baseline);
    if (reset) {
        state.establish(sample);
        impl_->rtpCounterResets = saturatingIncrement(impl_->rtpCounterResets);
        return MoonlightMediaSampleStatus::CounterReset;
    }
    if (sample.sampledAtUs - state.lastAcceptedAtUs <
        impl_->limits.minimumRtpSampleIntervalUs) {
        impl_->throttledSamples = saturatingIncrement(impl_->throttledSamples);
        return MoonlightMediaSampleStatus::Throttled;
    }
    const MoonlightRtpCounters delta = counterDelta(sample.counters, state.baseline);
    state.baseline = sample.counters;
    state.lastAcceptedAtUs = sample.sampledAtUs;
    state.aggregatePresent = true;
    state.aggregate.intervals = saturatingIncrement(state.aggregate.intervals);
    addCounters(state.aggregate.delta, delta);
    return MoonlightMediaSampleStatus::Accepted;
}

MoonlightMediaSampleStatus MoonlightMediaClockStats::recordAudioQueue(
    const MoonlightMediaClockIdentity& requested,
    const MoonlightAudioQueueSample& sample) noexcept {
    if (impl_ == nullptr) {
        return MoonlightMediaSampleStatus::InvalidState;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->state != MoonlightMediaClockState::Active) {
        return MoonlightMediaSampleStatus::InvalidState;
    }
    if (impl_->identity != requested) {
        impl_->staleSamples = saturatingIncrement(impl_->staleSamples);
        return MoonlightMediaSampleStatus::Stale;
    }
    if (sample.sampleSequence == 0U || sample.sampledAtUs == 0U ||
        sample.sourceGeneration == 0U ||
        (!sample.queuedDurationMs.has_value() && !sample.underrunCount.has_value() &&
         !sample.droppedBytes.has_value()) ||
        (sample.queuedDurationMs.has_value() &&
         *sample.queuedDurationMs > impl_->limits.maximumAudioQueueDurationMs)) {
        impl_->invalidSamples = saturatingIncrement(impl_->invalidSamples);
        return MoonlightMediaSampleStatus::InvalidRequest;
    }
    AudioCounterState& state = impl_->audioCounters;
    if (sample.sampleSequence <= state.lastSequence ||
        sample.sampledAtUs < state.lastObservedAtUs) {
        impl_->staleSamples = saturatingIncrement(impl_->staleSamples);
        return MoonlightMediaSampleStatus::Stale;
    }
    state.lastSequence = sample.sampleSequence;
    state.lastObservedAtUs = sample.sampledAtUs;

    const bool sourceReset = state.sourceInitialized &&
        sample.sourceGeneration != state.sourceGeneration;
    const bool counterDecrease =
        (sample.underrunCount.has_value() && state.underrunBaseline.has_value() &&
         *sample.underrunCount < *state.underrunBaseline) ||
        (sample.droppedBytes.has_value() && state.droppedBytesBaseline.has_value() &&
         *sample.droppedBytes < *state.droppedBytesBaseline);
    if (state.sourceInitialized && !sourceReset && !counterDecrease &&
        sample.sampledAtUs - state.lastAcceptedAtUs <
            impl_->limits.minimumAudioQueueSampleIntervalUs) {
        impl_->throttledSamples = saturatingIncrement(impl_->throttledSamples);
        return MoonlightMediaSampleStatus::Throttled;
    }

    const bool reset = sourceReset || counterDecrease;
    if (!state.sourceInitialized || reset) {
        state.sourceInitialized = true;
        state.sourceGeneration = sample.sourceGeneration;
        state.underrunBaseline = sample.underrunCount;
        state.droppedBytesBaseline = sample.droppedBytes;
        state.lastAcceptedAtUs = sample.sampledAtUs;
        state.clearAggregate();
        if (reset) {
            impl_->audioQueueDuration.clear();
            impl_->audioQueueSamples = 0U;
        }
        if (sample.queuedDurationMs.has_value()) {
            impl_->audioQueueDuration.add(
                static_cast<std::uint64_t>(*sample.queuedDurationMs) * 1000U);
            impl_->audioQueueSamples = saturatingIncrement(impl_->audioQueueSamples);
        }
        if (reset) {
            impl_->audioCounterResets = saturatingIncrement(impl_->audioCounterResets);
            return MoonlightMediaSampleStatus::CounterReset;
        }
        return sample.underrunCount.has_value() || sample.droppedBytes.has_value()
            ? MoonlightMediaSampleStatus::BaselineEstablished
            : MoonlightMediaSampleStatus::Accepted;
    }

    bool establishedNewBaseline = false;
    bool addedCounterDelta = false;
    std::uint64_t underrunDelta = 0U;
    std::uint64_t droppedBytesDelta = 0U;
    if (sample.underrunCount.has_value()) {
        if (state.underrunBaseline.has_value()) {
            underrunDelta = *sample.underrunCount - *state.underrunBaseline;
            addedCounterDelta = true;
        } else {
            establishedNewBaseline = true;
        }
        state.underrunBaseline = sample.underrunCount;
    }
    if (sample.droppedBytes.has_value()) {
        if (state.droppedBytesBaseline.has_value()) {
            droppedBytesDelta = *sample.droppedBytes - *state.droppedBytesBaseline;
            addedCounterDelta = true;
        } else {
            establishedNewBaseline = true;
        }
        state.droppedBytesBaseline = sample.droppedBytes;
    }
    if (addedCounterDelta) {
        state.aggregatePresent = true;
        state.aggregate.intervals = saturatingIncrement(state.aggregate.intervals);
        state.aggregate.underruns = saturatingAdd(
            state.aggregate.underruns, underrunDelta);
        state.aggregate.droppedBytes = saturatingAdd(
            state.aggregate.droppedBytes, droppedBytesDelta);
    }
    if (sample.queuedDurationMs.has_value()) {
        impl_->audioQueueDuration.add(
            static_cast<std::uint64_t>(*sample.queuedDurationMs) * 1000U);
        impl_->audioQueueSamples = saturatingIncrement(impl_->audioQueueSamples);
    }
    state.lastAcceptedAtUs = sample.sampledAtUs;
    if (establishedNewBaseline && !addedCounterDelta) {
        return MoonlightMediaSampleStatus::BaselineEstablished;
    }
    return MoonlightMediaSampleStatus::Accepted;
}

MoonlightMediaClockControlResult MoonlightMediaClockStats::stop(
    const MoonlightMediaClockIdentity& requested,
    std::uint64_t operationGeneration) noexcept {
    if (impl_ == nullptr || !requested.valid() || operationGeneration == 0U) {
        return controlResult(MoonlightMediaClockControlStatus::InvalidRequest, requested,
                             operationGeneration);
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->identity != requested || operationGeneration < impl_->lastOperationGeneration) {
        return controlResult(MoonlightMediaClockControlStatus::Stale, requested,
                             operationGeneration);
    }
    if (impl_->state == MoonlightMediaClockState::Stopped) {
        impl_->lastOperationGeneration = operationGeneration;
        return controlResult(MoonlightMediaClockControlStatus::AlreadyApplied, requested,
                             operationGeneration);
    }
    if (impl_->state != MoonlightMediaClockState::Active) {
        return controlResult(MoonlightMediaClockControlStatus::InvalidState, requested,
                             operationGeneration);
    }
    if (operationGeneration == impl_->lastOperationGeneration) {
        return controlResult(MoonlightMediaClockControlStatus::Stale, requested,
                             operationGeneration);
    }
    impl_->state = MoonlightMediaClockState::Stopped;
    impl_->lastOperationGeneration = operationGeneration;
    return controlResult(MoonlightMediaClockControlStatus::Applied, requested,
                         operationGeneration);
}

MoonlightMediaClockControlResult MoonlightMediaClockStats::cleanup(
    const MoonlightMediaClockIdentity& requested,
    std::uint64_t operationGeneration) noexcept {
    if (impl_ == nullptr || !requested.valid() || operationGeneration == 0U) {
        return controlResult(MoonlightMediaClockControlStatus::InvalidRequest, requested,
                             operationGeneration);
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->state == MoonlightMediaClockState::Cleaned &&
        impl_->lastCleanedIdentity == requested) {
        if (operationGeneration < impl_->lastOperationGeneration) {
            return controlResult(MoonlightMediaClockControlStatus::Stale, requested,
                                 operationGeneration);
        }
        impl_->lastOperationGeneration = operationGeneration;
        return controlResult(MoonlightMediaClockControlStatus::AlreadyApplied, requested,
                             operationGeneration);
    }
    if (impl_->identity != requested || operationGeneration <= impl_->lastOperationGeneration) {
        return controlResult(MoonlightMediaClockControlStatus::Stale, requested,
                             operationGeneration);
    }
    if (impl_->state != MoonlightMediaClockState::Stopped) {
        return controlResult(MoonlightMediaClockControlStatus::InvalidState, requested,
                             operationGeneration);
    }
    impl_->clearMetrics();
    impl_->lastCleanedIdentity = requested;
    impl_->identity = {};
    impl_->state = MoonlightMediaClockState::Cleaned;
    impl_->lastOperationGeneration = operationGeneration;
    return controlResult(MoonlightMediaClockControlStatus::Applied, requested,
                         operationGeneration);
}

MoonlightMediaClockSnapshot MoonlightMediaClockStats::snapshot(
    const MoonlightMediaClockIdentity& requested) const noexcept {
    MoonlightMediaClockSnapshot result;
    if (impl_ == nullptr) {
        return result;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const bool activeMatch = impl_->identity == requested && requested.valid();
    const bool cleanedMatch = impl_->state == MoonlightMediaClockState::Cleaned &&
        impl_->lastCleanedIdentity == requested && requested.valid();
    if (!activeMatch && !cleanedMatch) {
        return result;
    }
    result.matched = true;
    result.identity = requested;
    result.state = impl_->state;
    result.lastOperationGeneration = impl_->lastOperationGeneration;
    result.observedVideoFrames = impl_->observedVideoFrames;
    result.sampledVideoFrames = impl_->sampledVideoFrames;
    result.audioQueueSamples = impl_->audioQueueSamples;
    result.throttledSamples = impl_->throttledSamples;
    result.invalidSamples = impl_->invalidSamples;
    result.staleSamples = impl_->staleSamples;
    result.rtpCounterResets = impl_->rtpCounterResets;
    result.audioCounterResets = impl_->audioCounterResets;
    result.networkAssemblyUs = impl_->networkAssembly.snapshot();
    result.decodeQueueUs = impl_->decodeQueue.snapshot();
    result.decodeUs = impl_->decode.snapshot();
    result.renderUs = impl_->render.snapshot();
    result.endToEndUs = impl_->endToEnd.snapshot();
    result.hostProcessingUs = impl_->hostProcessing.snapshot();
    result.audioQueueDurationUs = impl_->audioQueueDuration.snapshot();
    if (impl_->videoRtp.aggregatePresent) {
        result.videoRtp = impl_->videoRtp.aggregate;
    }
    if (impl_->audioRtp.aggregatePresent) {
        result.audioRtp = impl_->audioRtp.aggregate;
    }
    if (impl_->audioCounters.aggregatePresent) {
        result.audioCounters = impl_->audioCounters.aggregate;
    }
    return result;
}

} // namespace remotedesk::moonlight
