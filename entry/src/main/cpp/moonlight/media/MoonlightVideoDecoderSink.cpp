#include "moonlight/media/MoonlightVideoDecoderSink.h"

#include <condition_variable>
#include <mutex>
#include <utility>

namespace remotedesk::moonlight {
namespace {

bool sameProfile(const MoonlightStreamCodecProfile& left,
                 const MoonlightStreamCodecProfile& right) noexcept {
    return left.codec == right.codec && left.bitDepth == right.bitDepth &&
        left.chroma == right.chroma;
}

bool supportedMvpProfile(const MoonlightStreamCodecProfile& profile) noexcept {
    return profile.codec == MoonlightStreamCodec::H264 &&
        profile.bitDepth == MoonlightStreamBitDepth::Bit8 &&
        profile.chroma == MoonlightStreamChroma::Yuv420;
}

bool validNonProfileBinding(const MoonlightVideoDecoderBinding& binding) noexcept {
    // Surface-backed Moonlight decoders do not select a RustDesk display. The
    // native decoder factory uses -1 as the deliberate "no display" sentinel.
    return binding.key.valid() && binding.width >= 320 && binding.width <= 7680 &&
        binding.height >= 240 && binding.height <= 4320 && binding.display >= -1 &&
        binding.decoderHandle > 0 && binding.rendererHandle > 0 &&
        binding.decoderGeneration != 0U && binding.displayGeneration != 0U &&
        binding.rendererGeneration != 0U && binding.ownsDecoderHandle;
}

MoonlightVideoSinkStatus mapSubmitStatus(
    MoonlightDecoderPortSubmitStatus status) noexcept {
    switch (status) {
        case MoonlightDecoderPortSubmitStatus::Accepted:
            return MoonlightVideoSinkStatus::Accepted;
        case MoonlightDecoderPortSubmitStatus::Backpressure:
            return MoonlightVideoSinkStatus::Backpressure;
        case MoonlightDecoderPortSubmitStatus::NeedIdr:
            return MoonlightVideoSinkStatus::NeedIdr;
        case MoonlightDecoderPortSubmitStatus::Stale:
            return MoonlightVideoSinkStatus::Stale;
        case MoonlightDecoderPortSubmitStatus::Unsupported:
            return MoonlightVideoSinkStatus::Unsupported;
        case MoonlightDecoderPortSubmitStatus::Failed:
            return MoonlightVideoSinkStatus::Failed;
    }
    return MoonlightVideoSinkStatus::Failed;
}

bool validDecoderGenerationRebind(
    const MoonlightVideoDecoderBinding& current,
    const MoonlightVideoDecoderBinding& next) noexcept {
    if (next.decoderGeneration <= current.decoderGeneration) {
        return false;
    }
    auto normalized = next;
    normalized.decoderGeneration = current.decoderGeneration;
    return normalized == current;
}

bool validSurfaceRebind(const MoonlightVideoDecoderBinding& current,
                        const MoonlightVideoDecoderBinding& next) noexcept {
    if (!validNonProfileBinding(next) || !supportedMvpProfile(next.profile) ||
        !next.runtimeProof.valid() || next.key != current.key ||
        !sameProfile(next.profile, current.profile) ||
        next.width != current.width || next.height != current.height ||
        next.display != current.display ||
        next.decoderHandle != current.decoderHandle ||
        next.decoderGeneration != current.decoderGeneration ||
        next.displayGeneration != current.displayGeneration ||
        next.ownsDecoderHandle != current.ownsDecoderHandle ||
        next.rendererGeneration <= current.rendererGeneration ||
        next.runtimeProof.generation <= current.runtimeProof.generation) {
        return false;
    }
    return true;
}

} // namespace

bool operator==(const MoonlightVideoDecoderBinding& left,
                const MoonlightVideoDecoderBinding& right) noexcept {
    return left.key == right.key && sameProfile(left.profile, right.profile) &&
        left.width == right.width && left.height == right.height &&
        left.display == right.display &&
        left.decoderHandle == right.decoderHandle &&
        left.rendererHandle == right.rendererHandle &&
        left.decoderGeneration == right.decoderGeneration &&
        left.displayGeneration == right.displayGeneration &&
        left.rendererGeneration == right.rendererGeneration &&
        left.ownsDecoderHandle == right.ownsDecoderHandle &&
        left.runtimeProof.generation == right.runtimeProof.generation &&
        left.runtimeProof.h264HardwareDecode ==
            right.runtimeProof.h264HardwareDecode &&
        left.runtimeProof.nativeImageSurface ==
            right.runtimeProof.nativeImageSurface &&
        left.runtimeProof.rendererPresentationAck ==
            right.runtimeProof.rendererPresentationAck;
}

bool operator!=(const MoonlightVideoDecoderBinding& left,
                const MoonlightVideoDecoderBinding& right) noexcept {
    return !(left == right);
}

struct MoonlightOwnedVideoDecoderSink::Impl final {
    explicit Impl(std::shared_ptr<MoonlightOwnedDecoderPort> value)
        : port(std::move(value)) {}

    ~Impl() { shutdown(); }

    MoonlightVideoDecoderStartResult start(
        const MoonlightVideoDecoderBinding& requested) noexcept {
        std::lock_guard<std::mutex> lifecycleLock(lifecycleLane);
        if (!validNonProfileBinding(requested)) {
            return {MoonlightVideoDecoderStartStatus::InvalidRequest, {}};
        }
        if (!supportedMvpProfile(requested.profile)) {
            return {MoonlightVideoDecoderStartStatus::Unsupported, {}};
        }
        if (!requested.runtimeProof.valid()) {
            return {MoonlightVideoDecoderStartStatus::RuntimeProofRequired, {}};
        }
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (active) {
                return {MoonlightVideoDecoderStartStatus::Busy, binding.key};
            }
            if (requested.key.ownerToken <= ownerTokenHighWater || port == nullptr) {
                return {MoonlightVideoDecoderStartStatus::InvalidRequest, {}};
            }
        }

        MoonlightDecoderPortStartStatus portStatus =
            MoonlightDecoderPortStartStatus::Failed;
        try {
            portStatus = port->start(requested);
        } catch (...) {
            portStatus = MoonlightDecoderPortStartStatus::Failed;
        }
        if (portStatus != MoonlightDecoderPortStartStatus::Started) {
            switch (portStatus) {
                case MoonlightDecoderPortStartStatus::RuntimeProofRequired:
                    return {MoonlightVideoDecoderStartStatus::RuntimeProofRequired, {}};
                case MoonlightDecoderPortStartStatus::Unsupported:
                    return {MoonlightVideoDecoderStartStatus::Unsupported, {}};
                case MoonlightDecoderPortStartStatus::Stale:
                    return {MoonlightVideoDecoderStartStatus::Stale, {}};
                case MoonlightDecoderPortStartStatus::Busy:
                    return {MoonlightVideoDecoderStartStatus::Busy, {}};
                case MoonlightDecoderPortStartStatus::Failed:
                    return {MoonlightVideoDecoderStartStatus::PortFailure, {}};
                case MoonlightDecoderPortStartStatus::Started:
                    break;
            }
        }

        std::lock_guard<std::mutex> lock(mutex);
        binding = requested;
        ownerTokenHighWater = requested.key.ownerToken;
        active = true;
        admissionOpen = true;
        suspended = false;
        waitingForIdr = true;
        firstFrameReady = false;
        inFlightSubmissions = 0U;
        return {MoonlightVideoDecoderStartStatus::Started, requested.key};
    }

    bool available(const MoonlightStreamCodecProfile& requestedProfile) const noexcept {
        std::lock_guard<std::mutex> lock(mutex);
        return active && admissionOpen && sameProfile(binding.profile, requestedProfile);
    }

    MoonlightVideoSinkStatus submit(
        std::shared_ptr<const MoonlightOwnedVideoAccessUnit> accessUnit) noexcept {
        MoonlightVideoDecoderBinding exact;
        bool submittedIdr = false;
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (!active || suspended || !admissionOpen || accessUnit == nullptr ||
                accessUnit->key != binding.key ||
                !sameProfile(accessUnit->profile, binding.profile)) {
                return MoonlightVideoSinkStatus::Stale;
            }
            if (waitingForIdr &&
                accessUnit->frameType != MoonlightVideoFrameType::IdR) {
                return MoonlightVideoSinkStatus::NeedIdr;
            }
            submittedIdr =
                accessUnit->frameType == MoonlightVideoFrameType::IdR;
            exact = binding;
            ++inFlightSubmissions;
        }
        struct Guard final {
            Impl* owner;
            ~Guard() {
                std::lock_guard<std::mutex> lock(owner->mutex);
                if (owner->inFlightSubmissions != 0U) {
                    --owner->inFlightSubmissions;
                }
                owner->cv.notify_all();
            }
        } guard {this};

        MoonlightDecoderPortSubmitResult portResult;
        try {
            portResult = port->submit(exact, std::move(accessUnit));
        } catch (...) {
            portResult = {};
        }
        std::lock_guard<std::mutex> lock(mutex);
        if (!active || !admissionOpen || exact != binding) {
            return MoonlightVideoSinkStatus::Stale;
        }
        if (portResult.bindingChanged) {
            if (portResult.status != MoonlightDecoderPortSubmitStatus::Accepted ||
                !validDecoderGenerationRebind(exact, portResult.binding)) {
                admissionOpen = false;
                return portResult.status ==
                        MoonlightDecoderPortSubmitStatus::Accepted
                    ? MoonlightVideoSinkStatus::Stale
                    : MoonlightVideoSinkStatus::Failed;
            }
            binding = portResult.binding;
            firstFrameReady = false;
        }
        if (portResult.status == MoonlightDecoderPortSubmitStatus::Accepted &&
            submittedIdr) {
            waitingForIdr = false;
        }
        return mapSubmitStatus(portResult.status);
    }

    MoonlightVideoDecoderSuspendStatus suspend(
        const MoonlightSessionKey& requestedKey,
        std::chrono::milliseconds timeout) noexcept {
        std::lock_guard<std::mutex> lifecycleLock(lifecycleLane);
        if (!requestedKey.valid()) {
            return MoonlightVideoDecoderSuspendStatus::Stale;
        }
        const auto boundedTimeout = timeout < std::chrono::milliseconds::zero()
            ? std::chrono::milliseconds::zero() : timeout;
        const auto deadline = std::chrono::steady_clock::now() + boundedTimeout;
        MoonlightVideoDecoderBinding exact;
        {
            std::unique_lock<std::mutex> lock(mutex);
            if (!active || binding.key != requestedKey) {
                return MoonlightVideoDecoderSuspendStatus::Stale;
            }
            if (suspended) {
                return MoonlightVideoDecoderSuspendStatus::AlreadySuspended;
            }
            admissionOpen = false;
            firstFrameReady = false;
            waitingForIdr = true;
            if (!cv.wait_until(lock, deadline,
                               [&]() { return inFlightSubmissions == 0U; })) {
                return MoonlightVideoDecoderSuspendStatus::TimedOut;
            }
            exact = binding;
        }

        MoonlightDecoderPortSuspendStatus portStatus =
            MoonlightDecoderPortSuspendStatus::Failed;
        try {
            const auto now = std::chrono::steady_clock::now();
            const auto remaining = now >= deadline
                ? std::chrono::milliseconds::zero()
                : std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now);
            portStatus = port->suspend(exact, remaining);
        } catch (...) {
            portStatus = MoonlightDecoderPortSuspendStatus::Failed;
        }
        if (portStatus == MoonlightDecoderPortSuspendStatus::TimedOut) {
            return MoonlightVideoDecoderSuspendStatus::TimedOut;
        }
        if (portStatus == MoonlightDecoderPortSuspendStatus::Stale) {
            return MoonlightVideoDecoderSuspendStatus::Stale;
        }
        if (portStatus == MoonlightDecoderPortSuspendStatus::Failed) {
            return MoonlightVideoDecoderSuspendStatus::PortFailure;
        }
        std::lock_guard<std::mutex> lock(mutex);
        if (!active || binding != exact) {
            return MoonlightVideoDecoderSuspendStatus::Stale;
        }
        suspended = true;
        admissionOpen = false;
        return portStatus == MoonlightDecoderPortSuspendStatus::AlreadySuspended
            ? MoonlightVideoDecoderSuspendStatus::AlreadySuspended
            : MoonlightVideoDecoderSuspendStatus::Suspended;
    }

    MoonlightVideoDecoderRebindStatus rebind(
        const MoonlightVideoDecoderBinding& requested) noexcept {
        std::lock_guard<std::mutex> lifecycleLock(lifecycleLane);
        MoonlightVideoDecoderBinding current;
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (!active || !suspended || binding.key != requested.key) {
                return MoonlightVideoDecoderRebindStatus::Stale;
            }
            current = binding;
        }
        if (!requested.runtimeProof.valid()) {
            return MoonlightVideoDecoderRebindStatus::RuntimeProofRequired;
        }
        if (!supportedMvpProfile(requested.profile)) {
            return MoonlightVideoDecoderRebindStatus::Unsupported;
        }
        if (!validSurfaceRebind(current, requested)) {
            return MoonlightVideoDecoderRebindStatus::InvalidRequest;
        }

        MoonlightDecoderPortRebindStatus portStatus =
            MoonlightDecoderPortRebindStatus::Failed;
        try {
            portStatus = port->rebind(current, requested);
        } catch (...) {
            portStatus = MoonlightDecoderPortRebindStatus::Failed;
        }
        switch (portStatus) {
            case MoonlightDecoderPortRebindStatus::RuntimeProofRequired:
                return MoonlightVideoDecoderRebindStatus::RuntimeProofRequired;
            case MoonlightDecoderPortRebindStatus::Unsupported:
                return MoonlightVideoDecoderRebindStatus::Unsupported;
            case MoonlightDecoderPortRebindStatus::Stale:
                return MoonlightVideoDecoderRebindStatus::Stale;
            case MoonlightDecoderPortRebindStatus::Busy:
                return MoonlightVideoDecoderRebindStatus::Busy;
            case MoonlightDecoderPortRebindStatus::Failed:
                return MoonlightVideoDecoderRebindStatus::PortFailure;
            case MoonlightDecoderPortRebindStatus::Rebound:
                break;
        }
        std::lock_guard<std::mutex> lock(mutex);
        if (!active || !suspended || binding != current) {
            return MoonlightVideoDecoderRebindStatus::Stale;
        }
        binding = requested;
        suspended = false;
        admissionOpen = true;
        waitingForIdr = true;
        firstFrameReady = false;
        return MoonlightVideoDecoderRebindStatus::Rebound;
    }

    MoonlightVideoDecoderStopStatus stop(
        const MoonlightSessionKey& requestedKey,
        std::chrono::milliseconds timeout) noexcept {
        std::lock_guard<std::mutex> lifecycleLock(lifecycleLane);
        if (!requestedKey.valid()) {
            return MoonlightVideoDecoderStopStatus::Stale;
        }
        const auto boundedTimeout = timeout < std::chrono::milliseconds::zero()
                                        ? std::chrono::milliseconds::zero()
                                        : timeout;
        const auto deadline = std::chrono::steady_clock::now() + boundedTimeout;
        MoonlightVideoDecoderBinding exact;
        {
            std::unique_lock<std::mutex> lock(mutex);
            if (!active) {
                return binding.key == requestedKey
                    ? MoonlightVideoDecoderStopStatus::AlreadyStopped
                    : MoonlightVideoDecoderStopStatus::Stale;
            }
            if (binding.key != requestedKey) {
                return MoonlightVideoDecoderStopStatus::Stale;
            }
            admissionOpen = false;
            if (!cv.wait_until(lock, deadline,
                               [&]() { return inFlightSubmissions == 0U; })) {
                return MoonlightVideoDecoderStopStatus::TimedOut;
            }
            exact = binding;
        }

        MoonlightDecoderPortStopStatus portStatus =
            MoonlightDecoderPortStopStatus::Failed;
        try {
            const auto now = std::chrono::steady_clock::now();
            const auto remaining = now >= deadline
                ? std::chrono::milliseconds::zero()
                : std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now);
            portStatus = port->stop(exact, remaining);
        } catch (...) {
            portStatus = MoonlightDecoderPortStopStatus::Failed;
        }
        if (portStatus == MoonlightDecoderPortStopStatus::TimedOut) {
            return MoonlightVideoDecoderStopStatus::TimedOut;
        }
        if (portStatus == MoonlightDecoderPortStopStatus::Stale) {
            return MoonlightVideoDecoderStopStatus::Stale;
        }
        if (portStatus == MoonlightDecoderPortStopStatus::Failed) {
            return MoonlightVideoDecoderStopStatus::PortFailure;
        }
        std::lock_guard<std::mutex> lock(mutex);
        if (binding != exact) {
            return MoonlightVideoDecoderStopStatus::Stale;
        }
        active = false;
        admissionOpen = false;
        suspended = false;
        waitingForIdr = false;
        firstFrameReady = false;
        return MoonlightVideoDecoderStopStatus::Stopped;
    }

    MoonlightVideoDecoderSnapshot snapshot(
        const MoonlightSessionKey& requestedKey) const noexcept {
        MoonlightVideoDecoderBinding exact;
        bool wasActive = false;
        bool wasOpen = false;
        std::size_t inFlight = 0U;
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (binding.key != requestedKey) {
                return {};
            }
            exact = binding;
            wasActive = active;
            wasOpen = admissionOpen && !suspended;
            inFlight = inFlightSubmissions;
        }

        MoonlightDecoderPresentationSnapshot evidence;
        if (wasActive && port != nullptr) {
            try {
                evidence = port->snapshot(exact);
            } catch (...) {
                evidence = {};
            }
        }

        std::lock_guard<std::mutex> lock(mutex);
        MoonlightVideoDecoderSnapshot result;
        if (binding != exact) {
            return result;
        }
        result.matched = exact.key.valid();
        result.running = active;
        result.admissionOpen = active && admissionOpen && !suspended;
        result.suspended = active && suspended;
        result.waitingForIdr = active && waitingForIdr;
        result.binding = exact;
        result.inFlightSubmissions = inFlight;
        result.renderedOutputBuffers = evidence.renderedOutputBuffers;
        result.nativeImageFrames = evidence.nativeImageFrames;
        result.rendererPresentedFrames = evidence.rendererPresentedFrames;
        const bool hasExactFirstFrameEvidence =
            active && admissionOpen && !suspended && wasActive && wasOpen &&
            evidence.matched && evidence.running && evidence.binding == exact &&
            evidence.decoderGeneration == exact.decoderGeneration &&
            evidence.rendererGeneration == exact.rendererGeneration &&
            evidence.renderedOutputBuffers != 0U &&
            evidence.nativeImageFrames != 0U &&
            evidence.rendererPresentedFrames != 0U;
        if (hasExactFirstFrameEvidence) {
            firstFrameReady = true;
        }
        result.firstFrameReady =
            active && admissionOpen && !suspended && firstFrameReady;
        return result;
    }

    void shutdown() noexcept {
        MoonlightVideoDecoderBinding exact;
        {
            std::unique_lock<std::mutex> lock(mutex);
            admissionOpen = false;
            cv.wait(lock, [&]() { return inFlightSubmissions == 0U; });
            if (!active) {
                return;
            }
            exact = binding;
        }
        try {
            (void)port->stop(exact, std::chrono::seconds(5));
        } catch (...) {
        }
        std::lock_guard<std::mutex> lock(mutex);
        active = false;
        suspended = false;
        waitingForIdr = false;
        firstFrameReady = false;
    }

    const std::shared_ptr<MoonlightOwnedDecoderPort> port;
    mutable std::mutex mutex;
    std::mutex lifecycleLane;
    std::condition_variable cv;
    MoonlightVideoDecoderBinding binding {};
    std::uint64_t ownerTokenHighWater = 0U;
    bool active = false;
    bool admissionOpen = false;
    bool suspended = false;
    bool waitingForIdr = false;
    mutable bool firstFrameReady = false;
    std::size_t inFlightSubmissions = 0U;
};

MoonlightOwnedVideoDecoderSink::MoonlightOwnedVideoDecoderSink(
    std::unique_ptr<Impl> impl) : impl_(std::move(impl)) {}

MoonlightOwnedVideoDecoderSink::~MoonlightOwnedVideoDecoderSink() = default;

#if defined(RDP_NATIVE_CALLBACK_TESTING)
std::unique_ptr<MoonlightOwnedVideoDecoderSink>
MoonlightOwnedVideoDecoderSink::createForTesting(
    std::shared_ptr<MoonlightOwnedDecoderPort> port) {
    return create(std::move(port));
}
#endif

std::unique_ptr<MoonlightOwnedVideoDecoderSink>
MoonlightOwnedVideoDecoderSink::create(
    std::shared_ptr<MoonlightOwnedDecoderPort> port) {
    if (port == nullptr) {
        return nullptr;
    }
    return std::unique_ptr<MoonlightOwnedVideoDecoderSink>(
        new MoonlightOwnedVideoDecoderSink(std::make_unique<Impl>(std::move(port))));
}

MoonlightVideoDecoderStartResult MoonlightOwnedVideoDecoderSink::start(
    const MoonlightVideoDecoderBinding& binding) noexcept {
    return impl_->start(binding);
}

bool MoonlightOwnedVideoDecoderSink::available(
    const MoonlightStreamCodecProfile& profile) {
    return impl_->available(profile);
}

MoonlightVideoSinkStatus MoonlightOwnedVideoDecoderSink::submit(
    std::shared_ptr<const MoonlightOwnedVideoAccessUnit> accessUnit) {
    return impl_->submit(std::move(accessUnit));
}

MoonlightVideoDecoderSuspendStatus MoonlightOwnedVideoDecoderSink::suspend(
    const MoonlightSessionKey& key,
    std::chrono::milliseconds timeout) noexcept {
    return impl_->suspend(key, timeout);
}

MoonlightVideoDecoderRebindStatus MoonlightOwnedVideoDecoderSink::rebind(
    const MoonlightVideoDecoderBinding& binding) noexcept {
    return impl_->rebind(binding);
}

MoonlightVideoDecoderStopStatus MoonlightOwnedVideoDecoderSink::stop(
    const MoonlightSessionKey& key,
    std::chrono::milliseconds timeout) noexcept {
    return impl_->stop(key, timeout);
}

MoonlightVideoDecoderSnapshot MoonlightOwnedVideoDecoderSink::snapshot(
    const MoonlightSessionKey& key) const noexcept {
    return impl_->snapshot(key);
}

} // namespace remotedesk::moonlight
