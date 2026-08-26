#include "moonlight/media/MoonlightVideoBridge.h"

#include <algorithm>
#include <condition_variable>
#include <cstring>
#include <limits>
#include <mutex>
#include <new>
#include <utility>

namespace remotedesk::moonlight {
namespace {

bool sameProfile(const MoonlightStreamCodecProfile& left,
                 const MoonlightStreamCodecProfile& right) noexcept {
    return left.codec == right.codec && left.bitDepth == right.bitDepth &&
        left.chroma == right.chroma;
}

bool validProfile(const MoonlightStreamCodecProfile& profile) noexcept {
    switch (profile.codec) {
        case MoonlightStreamCodec::H264:
            return profile.bitDepth == MoonlightStreamBitDepth::Bit8 &&
                (profile.chroma == MoonlightStreamChroma::Yuv420 ||
                 profile.chroma == MoonlightStreamChroma::Yuv444);
        case MoonlightStreamCodec::Hevc:
        case MoonlightStreamCodec::Av1:
            return (profile.bitDepth == MoonlightStreamBitDepth::Bit8 ||
                    profile.bitDepth == MoonlightStreamBitDepth::Bit10) &&
                (profile.chroma == MoonlightStreamChroma::Yuv420 ||
                 profile.chroma == MoonlightStreamChroma::Yuv444);
    }
    return false;
}

bool validLimits(const MoonlightVideoLimits& limits) noexcept {
    return limits.maximumFragments != 0U &&
        limits.maximumFragmentBytes != 0U &&
        limits.maximumAccessUnitBytes != 0U &&
        limits.maximumCodecConfigurationBytes != 0U &&
        limits.maximumFragmentBytes <= limits.maximumAccessUnitBytes &&
        limits.maximumCodecConfigurationBytes <= limits.maximumAccessUnitBytes;
}

bool validBufferType(MoonlightVideoBufferType type) noexcept {
    switch (type) {
        case MoonlightVideoBufferType::PictureData:
        case MoonlightVideoBufferType::SequenceParameterSet:
        case MoonlightVideoBufferType::PictureParameterSet:
        case MoonlightVideoBufferType::VideoParameterSet:
            return true;
    }
    return false;
}

bool validFrameType(MoonlightVideoFrameType type) noexcept {
    return type == MoonlightVideoFrameType::Predicted ||
        type == MoonlightVideoFrameType::IdR;
}

class UnavailableVideoSink final : public MoonlightVideoDecoderSink {
public:
    bool available(const MoonlightStreamCodecProfile&) override { return false; }
    MoonlightVideoSinkStatus submit(
        std::shared_ptr<const MoonlightOwnedVideoAccessUnit>) override {
        return MoonlightVideoSinkStatus::Unsupported;
    }
};

struct BuiltAccessUnit final {
    std::shared_ptr<MoonlightOwnedVideoAccessUnit> accessUnit;
    std::vector<std::uint8_t> vps;
    std::vector<std::uint8_t> sps;
    std::vector<std::uint8_t> pps;
};

bool validCodecShape(const MoonlightStreamCodecProfile& profile,
                     MoonlightVideoFrameType frameType,
                     const std::vector<const MoonlightVideoFragmentView*>& fragments) noexcept {
    if (fragments.empty()) {
        return false;
    }
    const auto pictureOnlyFrom = [&](std::size_t start) {
        return start < fragments.size() &&
            std::all_of(fragments.begin() + static_cast<std::ptrdiff_t>(start),
                        fragments.end(), [](const auto* fragment) {
                return fragment->type == MoonlightVideoBufferType::PictureData;
            });
    };
    if (frameType == MoonlightVideoFrameType::Predicted) {
        return pictureOnlyFrom(0U);
    }
    switch (profile.codec) {
        case MoonlightStreamCodec::H264:
            return fragments.size() >= 3U &&
                fragments[0]->type == MoonlightVideoBufferType::SequenceParameterSet &&
                fragments[1]->type == MoonlightVideoBufferType::PictureParameterSet &&
                pictureOnlyFrom(2U);
        case MoonlightStreamCodec::Hevc:
            return fragments.size() >= 4U &&
                fragments[0]->type == MoonlightVideoBufferType::VideoParameterSet &&
                fragments[1]->type == MoonlightVideoBufferType::SequenceParameterSet &&
                fragments[2]->type == MoonlightVideoBufferType::PictureParameterSet &&
                pictureOnlyFrom(3U);
        case MoonlightStreamCodec::Av1:
            return pictureOnlyFrom(0U);
    }
    return false;
}

bool buildOwnedAccessUnit(const MoonlightVideoDecodeUnitView& view,
                          const MoonlightVideoLimits& limits,
                          BuiltAccessUnit& output) {
    if (!view.key.valid() || !validProfile(view.profile) ||
        !validFrameType(view.frameType) || view.frameNumber < 0 ||
        view.fullLength == 0U || view.fullLength > limits.maximumAccessUnitBytes ||
        view.bufferList == nullptr || view.colorSpace > 2U ||
        view.receiveTimeUs > view.enqueueTimeUs) {
        return false;
    }

    std::vector<const MoonlightVideoFragmentView*> fragments;
    fragments.reserve(limits.maximumFragments);
    std::size_t totalLength = 0U;
    std::size_t totalConfigurationLength = 0U;
    const MoonlightVideoFragmentView* current = view.bufferList;
    while (current != nullptr) {
        if (fragments.size() == limits.maximumFragments ||
            std::find(fragments.begin(), fragments.end(), current) != fragments.end() ||
            current->data == nullptr || current->length == 0U ||
            current->length > limits.maximumFragmentBytes ||
            !validBufferType(current->type) ||
            current->length > limits.maximumAccessUnitBytes - totalLength) {
            return false;
        }
        if (current->type != MoonlightVideoBufferType::PictureData) {
            if (current->length > limits.maximumCodecConfigurationBytes -
                                      totalConfigurationLength) {
                return false;
            }
            totalConfigurationLength += current->length;
        }
        totalLength += current->length;
        fragments.push_back(current);
        current = current->next;
    }
    if (totalLength != view.fullLength ||
        !validCodecShape(view.profile, view.frameType, fragments)) {
        return false;
    }

    auto accessUnit = std::make_shared<MoonlightOwnedVideoAccessUnit>();
    accessUnit->key = view.key;
    accessUnit->profile = view.profile;
    accessUnit->frameNumber = view.frameNumber;
    accessUnit->frameType = view.frameType;
    accessUnit->hostProcessingLatencyDeciMs = view.hostProcessingLatencyDeciMs;
    accessUnit->receiveTimeUs = view.receiveTimeUs;
    accessUnit->enqueueTimeUs = view.enqueueTimeUs;
    accessUnit->presentationTimeUs = view.presentationTimeUs;
    accessUnit->rtpTimestamp = view.rtpTimestamp;
    accessUnit->hdrActive = view.hdrActive;
    accessUnit->colorSpace = view.colorSpace;
    accessUnit->bytes.resize(totalLength);
    accessUnit->fragments.reserve(fragments.size());

    std::size_t offset = 0U;
    for (const auto* fragment : fragments) {
        std::memcpy(accessUnit->bytes.data() + offset, fragment->data, fragment->length);
        accessUnit->fragments.push_back(
            {fragment->type, offset, fragment->length});
        auto* configuration = fragment->type == MoonlightVideoBufferType::VideoParameterSet
                                  ? &output.vps
                              : fragment->type == MoonlightVideoBufferType::SequenceParameterSet
                                  ? &output.sps
                              : fragment->type == MoonlightVideoBufferType::PictureParameterSet
                                  ? &output.pps
                                  : nullptr;
        if (configuration != nullptr) {
            configuration->assign(fragment->data, fragment->data + fragment->length);
        }
        offset += fragment->length;
    }
    output.accessUnit = std::move(accessUnit);
    return true;
}

} // namespace

struct MoonlightVideoBridge::Impl final {
    explicit Impl(std::shared_ptr<MoonlightVideoDecoderSink> value,
                  MoonlightVideoLimits configuredLimits)
        : sink(std::move(value)), limits(configuredLimits), limitsValid(validLimits(limits)) {}

    ~Impl() { shutdown(); }

    MoonlightVideoStartResult start(const MoonlightSessionKey& requestedKey,
                                    const MoonlightStreamCodecProfile& requestedProfile) noexcept {
        try {
            if (!requestedKey.valid() || !validProfile(requestedProfile) ||
                !limitsValid || sink == nullptr) {
                return {MoonlightVideoStartStatus::InvalidRequest, {}};
            }
            {
                std::lock_guard<std::mutex> lock(mutex);
                if (active) {
                    return {MoonlightVideoStartStatus::Busy, key};
                }
                if (requestedKey.ownerToken <= ownerTokenHighWater) {
                    return {MoonlightVideoStartStatus::InvalidRequest, {}};
                }
            }
            bool available = false;
            try {
                available = sink->available(requestedProfile);
            } catch (...) {
                return {MoonlightVideoStartStatus::InternalFailure, {}};
            }
            if (!available) {
                return {MoonlightVideoStartStatus::RuntimeProofRequired, {}};
            }

            std::lock_guard<std::mutex> lock(mutex);
            if (active) {
                return {MoonlightVideoStartStatus::Busy, key};
            }
            if (requestedKey.ownerToken <= ownerTokenHighWater) {
                return {MoonlightVideoStartStatus::InvalidRequest, {}};
            }
            key = requestedKey;
            profile = requestedProfile;
            ownerTokenHighWater = requestedKey.ownerToken;
            active = true;
            admissionOpen = true;
            waitingForIdr = true;
            idrRequestPending = false;
            hasAcceptedIdr = false;
            configurationGeneration = 0U;
            vps.clear();
            sps.clear();
            pps.clear();
            acceptedFrames = droppedFrames = malformedFrames = 0U;
            staleFrames = backpressureFrames = 0U;
            lastAcceptedFrameNumber.reset();
            return {MoonlightVideoStartStatus::Started, key};
        } catch (...) {
            return {MoonlightVideoStartStatus::InternalFailure, {}};
        }
    }

    bool armIdrLocked() noexcept {
        waitingForIdr = true;
        hasAcceptedIdr = false;
        if (idrRequestPending) {
            return false;
        }
        idrRequestPending = true;
        return true;
    }

    bool armRefreshLocked() noexcept {
        // A transient sink-pressure drop does not invalidate the decoder
        // lifecycle itself. Ask the host for a clean refresh point without
        // closing admission for the P-frames that can still keep the picture
        // moving until that IDR arrives.
        if (idrRequestPending) {
            return false;
        }
        idrRequestPending = true;
        return true;
    }

    MoonlightVideoSubmitResult malformedResult() noexcept {
        std::lock_guard<std::mutex> lock(mutex);
        ++malformedFrames;
        return {MoonlightVideoSubmitStatus::Malformed,
                MoonlightVideoDropReason::None, false, false, 0U, 0U,
                configurationGeneration};
    }

    MoonlightVideoSubmitResult pressureResult() noexcept {
        std::lock_guard<std::mutex> lock(mutex);
        ++backpressureFrames;
        const bool request = armIdrLocked();
        return {MoonlightVideoSubmitStatus::Backpressure,
                MoonlightVideoDropReason::None, false, request, 0U, 0U,
                configurationGeneration};
    }

    MoonlightVideoSubmitResult submit(
        const MoonlightVideoDecodeUnitView& decodeUnit) noexcept {
        std::lock_guard<std::mutex> lane(submissionLane);
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (!active || decodeUnit.key != key ||
                !sameProfile(decodeUnit.profile, profile)) {
                ++staleFrames;
                return {MoonlightVideoSubmitStatus::Stale,
                        MoonlightVideoDropReason::None, false, false, 0U, 0U,
                        configurationGeneration};
            }
            if (!admissionOpen) {
                ++droppedFrames;
                return {MoonlightVideoSubmitStatus::Dropped,
                        MoonlightVideoDropReason::Teardown, false, false, 0U, 0U,
                        configurationGeneration};
            }
            ++inFlightSubmissions;
        }

        struct InFlightGuard final {
            Impl* owner;
            ~InFlightGuard() {
                std::lock_guard<std::mutex> lock(owner->mutex);
                if (owner->inFlightSubmissions != 0U) {
                    --owner->inFlightSubmissions;
                }
                owner->cv.notify_all();
            }
        } guard {this};

        BuiltAccessUnit built;
        try {
            if (!buildOwnedAccessUnit(decodeUnit, limits, built)) {
                return malformedResult();
            }
        } catch (const std::bad_alloc&) {
            return pressureResult();
        } catch (...) {
            return malformedResult();
        }

        {
            std::lock_guard<std::mutex> lock(mutex);
            if (!admissionOpen) {
                ++droppedFrames;
                return {MoonlightVideoSubmitStatus::Dropped,
                        MoonlightVideoDropReason::Teardown, false, false,
                        built.accessUnit->bytes.size(), built.accessUnit->fragments.size(),
                        configurationGeneration};
            }
            if (lastAcceptedFrameNumber.has_value() &&
                decodeUnit.frameNumber <= *lastAcceptedFrameNumber) {
                ++droppedFrames;
                return {MoonlightVideoSubmitStatus::Dropped,
                        MoonlightVideoDropReason::DuplicateOrReordered, false, false,
                        built.accessUnit->bytes.size(), built.accessUnit->fragments.size(),
                        configurationGeneration};
            }
            if (decodeUnit.frameType == MoonlightVideoFrameType::Predicted &&
                !hasAcceptedIdr) {
                ++droppedFrames;
                const bool request = armIdrLocked();
                return {request ? MoonlightVideoSubmitStatus::NeedIdr
                                : MoonlightVideoSubmitStatus::Dropped,
                        MoonlightVideoDropReason::WaitingForIdr, false, request,
                        built.accessUnit->bytes.size(), built.accessUnit->fragments.size(),
                        configurationGeneration};
            }
            if (decodeUnit.frameType == MoonlightVideoFrameType::IdR) {
                built.accessUnit->codecConfigurationChanged =
                    configurationGeneration == 0U || vps != built.vps ||
                    sps != built.sps || pps != built.pps;
                built.accessUnit->codecConfigurationGeneration =
                    built.accessUnit->codecConfigurationChanged
                        ? configurationGeneration + 1U
                        : configurationGeneration;
            } else {
                built.accessUnit->codecConfigurationGeneration =
                    configurationGeneration;
            }
        }

        MoonlightVideoSinkStatus sinkStatus = MoonlightVideoSinkStatus::Failed;
        try {
            sinkStatus = sink->submit(built.accessUnit);
        } catch (...) {
            sinkStatus = MoonlightVideoSinkStatus::Failed;
        }

        std::lock_guard<std::mutex> lock(mutex);
        MoonlightVideoSubmitResult result;
        result.sinkCalled = true;
        result.ownedBytes = built.accessUnit->bytes.size();
        result.fragmentCount = built.accessUnit->fragments.size();
        if (!admissionOpen) {
            ++droppedFrames;
            result.status = MoonlightVideoSubmitStatus::Dropped;
            result.dropReason = MoonlightVideoDropReason::Teardown;
        } else if (sinkStatus == MoonlightVideoSinkStatus::Accepted) {
            result.status = MoonlightVideoSubmitStatus::Accepted;
            ++acceptedFrames;
            lastAcceptedFrameNumber = decodeUnit.frameNumber;
            if (decodeUnit.frameType == MoonlightVideoFrameType::IdR) {
                if (built.accessUnit->codecConfigurationChanged) {
                    vps = std::move(built.vps);
                    sps = std::move(built.sps);
                    pps = std::move(built.pps);
                    configurationGeneration =
                        built.accessUnit->codecConfigurationGeneration;
                }
                hasAcceptedIdr = true;
                waitingForIdr = false;
                idrRequestPending = false;
            }
        } else if (sinkStatus ==
                   MoonlightVideoSinkStatus::AcceptedNeedsIdr) {
            result.status = MoonlightVideoSubmitStatus::Accepted;
            ++acceptedFrames;
            lastAcceptedFrameNumber = decodeUnit.frameNumber;
            result.requestIdr = armRefreshLocked();
        } else if (sinkStatus == MoonlightVideoSinkStatus::Backpressure) {
            result.status = MoonlightVideoSubmitStatus::Backpressure;
            ++backpressureFrames;
            result.requestIdr = armRefreshLocked();
        } else if (sinkStatus == MoonlightVideoSinkStatus::NeedIdr) {
            result.status = MoonlightVideoSubmitStatus::NeedIdr;
            ++droppedFrames;
            result.requestIdr = armIdrLocked();
        } else if (sinkStatus == MoonlightVideoSinkStatus::Stale) {
            result.status = MoonlightVideoSubmitStatus::Stale;
            ++staleFrames;
        } else if (sinkStatus == MoonlightVideoSinkStatus::Unsupported) {
            result.status = MoonlightVideoSubmitStatus::Unsupported;
        } else {
            result.status = MoonlightVideoSubmitStatus::SinkFailure;
        }
        result.configurationGeneration = configurationGeneration;
        return result;
    }

    MoonlightVideoStopStatus stop(const MoonlightSessionKey& requestedKey,
                                  std::chrono::milliseconds timeout) noexcept {
        if (!requestedKey.valid()) {
            return MoonlightVideoStopStatus::Stale;
        }
        try {
            std::unique_lock<std::mutex> lock(mutex);
            if (!active) {
                return key == requestedKey ? MoonlightVideoStopStatus::AlreadyStopped
                                           : MoonlightVideoStopStatus::Stale;
            }
            if (key != requestedKey) {
                return MoonlightVideoStopStatus::Stale;
            }
            admissionOpen = false;
            const auto boundedTimeout = timeout < std::chrono::milliseconds::zero()
                                            ? std::chrono::milliseconds::zero()
                                            : timeout;
            if (!cv.wait_for(lock, boundedTimeout,
                             [&]() { return inFlightSubmissions == 0U; })) {
                return MoonlightVideoStopStatus::TimedOut;
            }
            active = false;
            waitingForIdr = false;
            idrRequestPending = false;
            hasAcceptedIdr = false;
            configurationGeneration = 0U;
            vps.clear();
            sps.clear();
            pps.clear();
            return MoonlightVideoStopStatus::Stopped;
        } catch (...) {
            return MoonlightVideoStopStatus::TimedOut;
        }
    }

    MoonlightVideoSnapshot snapshot(const MoonlightSessionKey& requestedKey) const noexcept {
        std::lock_guard<std::mutex> lock(mutex);
        MoonlightVideoSnapshot result;
        if (requestedKey != key) {
            return result;
        }
        result.matched = key.valid();
        result.key = key;
        result.running = active;
        result.admissionOpen = active && admissionOpen;
        result.firstFrameReady = false;
        result.waitingForIdr = waitingForIdr;
        result.idrRequestPending = idrRequestPending;
        result.configurationGeneration = configurationGeneration;
        result.vpsBytes = vps.size();
        result.spsBytes = sps.size();
        result.ppsBytes = pps.size();
        result.inFlightSubmissions = inFlightSubmissions;
        result.acceptedFrames = acceptedFrames;
        result.droppedFrames = droppedFrames;
        result.malformedFrames = malformedFrames;
        result.staleFrames = staleFrames;
        result.backpressureFrames = backpressureFrames;
        result.lastAcceptedFrameNumber = lastAcceptedFrameNumber;
        return result;
    }

    std::optional<MoonlightVideoCodecConfiguration> configuration(
        const MoonlightSessionKey& requestedKey) const noexcept {
        try {
            std::lock_guard<std::mutex> lock(mutex);
            if (!active || requestedKey != key || !hasAcceptedIdr ||
                configurationGeneration == 0U) {
                return std::nullopt;
            }
            MoonlightVideoCodecConfiguration result;
            result.key = key;
            result.profile = profile;
            result.generation = configurationGeneration;
            result.vps = vps;
            result.sps = sps;
            result.pps = pps;
            return result;
        } catch (...) {
            return std::nullopt;
        }
    }

    void shutdown() noexcept {
        std::unique_lock<std::mutex> lock(mutex);
        admissionOpen = false;
        cv.wait(lock, [&]() { return inFlightSubmissions == 0U; });
        active = false;
        waitingForIdr = false;
        idrRequestPending = false;
        hasAcceptedIdr = false;
        configurationGeneration = 0U;
        vps.clear();
        sps.clear();
        pps.clear();
    }

    const std::shared_ptr<MoonlightVideoDecoderSink> sink;
    const MoonlightVideoLimits limits;
    const bool limitsValid;
    mutable std::mutex mutex;
    std::mutex submissionLane;
    std::condition_variable cv;
    MoonlightSessionKey key {};
    MoonlightStreamCodecProfile profile {};
    std::uint64_t ownerTokenHighWater = 0U;
    bool active = false;
    bool admissionOpen = false;
    bool waitingForIdr = false;
    bool idrRequestPending = false;
    bool hasAcceptedIdr = false;
    std::size_t inFlightSubmissions = 0U;
    std::uint64_t configurationGeneration = 0U;
    std::vector<std::uint8_t> vps;
    std::vector<std::uint8_t> sps;
    std::vector<std::uint8_t> pps;
    std::uint64_t acceptedFrames = 0U;
    std::uint64_t droppedFrames = 0U;
    std::uint64_t malformedFrames = 0U;
    std::uint64_t staleFrames = 0U;
    std::uint64_t backpressureFrames = 0U;
    std::optional<std::int32_t> lastAcceptedFrameNumber;
};

MoonlightVideoBridge::MoonlightVideoBridge(std::unique_ptr<Impl> impl)
    : impl_(std::move(impl)) {}

MoonlightVideoBridge::~MoonlightVideoBridge() = default;

MoonlightVideoBridge& MoonlightVideoBridge::process() {
    static MoonlightVideoBridge bridge(std::make_unique<Impl>(
        std::make_shared<UnavailableVideoSink>(), MoonlightVideoLimits {}));
    return bridge;
}

std::unique_ptr<MoonlightVideoBridge> MoonlightVideoBridge::create(
    std::shared_ptr<MoonlightVideoDecoderSink> sink,
    MoonlightVideoLimits limits) {
    if (sink == nullptr || !validLimits(limits)) {
        return nullptr;
    }
    return std::unique_ptr<MoonlightVideoBridge>(
        new MoonlightVideoBridge(std::make_unique<Impl>(std::move(sink), limits)));
}

#if defined(RDP_NATIVE_CALLBACK_TESTING)
std::unique_ptr<MoonlightVideoBridge> MoonlightVideoBridge::createForTesting(
    std::shared_ptr<MoonlightVideoDecoderSink> sink,
    MoonlightVideoLimits limits) {
    return create(std::move(sink), limits);
}
#endif

MoonlightVideoStartResult MoonlightVideoBridge::start(
    const MoonlightSessionKey& key,
    const MoonlightStreamCodecProfile& profile) noexcept {
    return impl_->start(key, profile);
}

MoonlightVideoSubmitResult MoonlightVideoBridge::submit(
    const MoonlightVideoDecodeUnitView& decodeUnit) noexcept {
    return impl_->submit(decodeUnit);
}

MoonlightVideoStopStatus MoonlightVideoBridge::stop(
    const MoonlightSessionKey& key,
    std::chrono::milliseconds timeout) noexcept {
    return impl_->stop(key, timeout);
}

MoonlightVideoSnapshot MoonlightVideoBridge::snapshot(
    const MoonlightSessionKey& key) const noexcept {
    return impl_->snapshot(key);
}

std::optional<MoonlightVideoCodecConfiguration>
MoonlightVideoBridge::configuration(const MoonlightSessionKey& key) const noexcept {
    return impl_->configuration(key);
}

} // namespace remotedesk::moonlight
