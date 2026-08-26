#include "moonlight/media/MoonlightVideoSurfaceLifecycle.h"
#include "moonlight/media/MoonlightVideoCodecSupport.h"

#include <mutex>
#include <utility>

namespace remotedesk::moonlight {
namespace {

enum class TransitionKind : std::uint8_t {
    None,
    Begin,
    Bind,
    Suspend,
    Resize,
    Stop,
};

bool sameProfile(const MoonlightStreamCodecProfile& left,
                 const MoonlightStreamCodecProfile& right) noexcept {
    return left.codec == right.codec && left.bitDepth == right.bitDepth &&
        left.chroma == right.chroma;
}

bool supportedProfile(const MoonlightStreamCodecProfile& profile) noexcept {
    return moonlightHardwareVideoProfileSupported(profile);
}

bool validTarget(MoonlightVideoSurfaceTarget target) noexcept {
    return target == MoonlightVideoSurfaceTarget::Page ||
        target == MoonlightVideoSurfaceTarget::Pip;
}

bool validReason(MoonlightVideoSurfaceSuspendReason reason) noexcept {
    switch (reason) {
        case MoonlightVideoSurfaceSuspendReason::PipTransfer:
        case MoonlightVideoSurfaceSuspendReason::SurfaceDestroyed:
        case MoonlightVideoSurfaceSuspendReason::ForegroundRestore:
        case MoonlightVideoSurfaceSuspendReason::Background:
        case MoonlightVideoSurfaceSuspendReason::LockScreen:
            return true;
    }
    return false;
}

bool validSurfaceSize(std::int32_t width, std::int32_t height) noexcept {
    return width > 0 && width <= 16384 && height > 0 && height <= 16384;
}

bool validInitialBinding(const MoonlightVideoSurfaceBinding& binding,
                         const MoonlightSessionKey& key,
                         const MoonlightStreamCodecProfile& profile) noexcept {
    return binding.decoder.key == key &&
        sameProfile(binding.decoder.profile, profile) &&
        binding.operationGeneration != 0U &&
        binding.surfaceGeneration != 0U && validTarget(binding.target) &&
        validSurfaceSize(binding.surfaceWidth, binding.surfaceHeight);
}

bool validRebind(const MoonlightVideoSurfaceBinding& current,
                 const MoonlightVideoSurfaceBinding& next) noexcept {
    const auto& oldDecoder = current.decoder;
    const auto& newDecoder = next.decoder;
    return validInitialBinding(next, oldDecoder.key, oldDecoder.profile) &&
        next.surfaceGeneration > current.surfaceGeneration &&
        newDecoder.key == oldDecoder.key &&
        sameProfile(newDecoder.profile, oldDecoder.profile) &&
        newDecoder.width == oldDecoder.width &&
        newDecoder.height == oldDecoder.height &&
        newDecoder.display == oldDecoder.display &&
        newDecoder.decoderHandle == oldDecoder.decoderHandle &&
        newDecoder.decoderGeneration == oldDecoder.decoderGeneration &&
        newDecoder.displayGeneration == oldDecoder.displayGeneration &&
        newDecoder.ownsDecoderHandle == oldDecoder.ownsDecoderHandle &&
        newDecoder.rendererGeneration > oldDecoder.rendererGeneration &&
        newDecoder.runtimeProof.generation >
            oldDecoder.runtimeProof.generation &&
        newDecoder.runtimeProof.valid();
}

MoonlightVideoSurfaceTransitionStatus mapStart(
    MoonlightVideoDecoderStartStatus status) noexcept {
    switch (status) {
        case MoonlightVideoDecoderStartStatus::Started:
            return MoonlightVideoSurfaceTransitionStatus::Applied;
        case MoonlightVideoDecoderStartStatus::InvalidRequest:
            return MoonlightVideoSurfaceTransitionStatus::InvalidRequest;
        case MoonlightVideoDecoderStartStatus::RuntimeProofRequired:
            return MoonlightVideoSurfaceTransitionStatus::RuntimeProofRequired;
        case MoonlightVideoDecoderStartStatus::Unsupported:
            return MoonlightVideoSurfaceTransitionStatus::Unsupported;
        case MoonlightVideoDecoderStartStatus::Stale:
            return MoonlightVideoSurfaceTransitionStatus::Stale;
        case MoonlightVideoDecoderStartStatus::Busy:
            return MoonlightVideoSurfaceTransitionStatus::Busy;
        case MoonlightVideoDecoderStartStatus::PortFailure:
            return MoonlightVideoSurfaceTransitionStatus::Failed;
    }
    return MoonlightVideoSurfaceTransitionStatus::Failed;
}

MoonlightVideoSurfaceTransitionStatus mapRebind(
    MoonlightVideoDecoderRebindStatus status) noexcept {
    switch (status) {
        case MoonlightVideoDecoderRebindStatus::Rebound:
            return MoonlightVideoSurfaceTransitionStatus::Applied;
        case MoonlightVideoDecoderRebindStatus::InvalidRequest:
            return MoonlightVideoSurfaceTransitionStatus::InvalidRequest;
        case MoonlightVideoDecoderRebindStatus::RuntimeProofRequired:
            return MoonlightVideoSurfaceTransitionStatus::RuntimeProofRequired;
        case MoonlightVideoDecoderRebindStatus::Unsupported:
            return MoonlightVideoSurfaceTransitionStatus::Unsupported;
        case MoonlightVideoDecoderRebindStatus::Stale:
            return MoonlightVideoSurfaceTransitionStatus::Stale;
        case MoonlightVideoDecoderRebindStatus::Busy:
            return MoonlightVideoSurfaceTransitionStatus::Busy;
        case MoonlightVideoDecoderRebindStatus::PortFailure:
            return MoonlightVideoSurfaceTransitionStatus::Failed;
    }
    return MoonlightVideoSurfaceTransitionStatus::Failed;
}

} // namespace

bool operator==(const MoonlightVideoSurfaceBinding& left,
                const MoonlightVideoSurfaceBinding& right) noexcept {
    return left.decoder == right.decoder &&
        left.operationGeneration == right.operationGeneration &&
        left.surfaceGeneration == right.surfaceGeneration &&
        left.target == right.target && left.surfaceWidth == right.surfaceWidth &&
        left.surfaceHeight == right.surfaceHeight;
}

bool operator!=(const MoonlightVideoSurfaceBinding& left,
                const MoonlightVideoSurfaceBinding& right) noexcept {
    return !(left == right);
}

struct MoonlightVideoSurfaceLifecycle::Impl final {
    Impl(std::shared_ptr<MoonlightOwnedVideoDecoderSink> decoderSink,
         std::unique_ptr<MoonlightVideoBridge> videoBridge)
        : sink(std::move(decoderSink)), bridge(std::move(videoBridge)) {}

    MoonlightVideoSurfaceTransitionResult result(
        MoonlightVideoSurfaceTransitionStatus status,
        bool requestIdr = false) const noexcept {
        std::lock_guard<std::mutex> lock(mutex);
        return {status, state, requestIdr};
    }

    MoonlightVideoSurfaceTransitionResult begin(
        const MoonlightVideoSurfaceBeginRequest& request) noexcept {
        std::lock_guard<std::mutex> lane(lifecycleLane);
        std::lock_guard<std::mutex> lock(mutex);
        if (!request.key.valid() || !supportedProfile(request.profile) ||
            request.operationGeneration == 0U ||
            request.operationGeneration <= operationHighWater ||
            request.key.ownerToken <= ownerTokenHighWater ||
            (key.valid() && state != MoonlightVideoSurfaceState::Stopped)) {
            return {MoonlightVideoSurfaceTransitionStatus::InvalidRequest, state, false};
        }
        key = request.key;
        profile = request.profile;
        ownerTokenHighWater = request.key.ownerToken;
        operationHighWater = request.operationGeneration;
        lastKind = TransitionKind::Begin;
        pendingKind = TransitionKind::None;
        pendingOperation = 0U;
        current = {};
        state = MoonlightVideoSurfaceState::AwaitingSurface;
        bridgeActive = false;
        sinkActive = false;
        idrNeeded = true;
        idrRequestPending = false;
        noSurfaceDroppedFrames = 0U;
        return {MoonlightVideoSurfaceTransitionStatus::Applied, state, false};
    }

    MoonlightVideoSurfaceTransitionResult bind(
        const MoonlightVideoSurfaceBinding& requested) noexcept {
        std::lock_guard<std::mutex> lane(lifecycleLane);
        bool initial = false;
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (!key.valid() || requested.decoder.key != key) {
                return {MoonlightVideoSurfaceTransitionStatus::Stale, state, false};
            }
            if (state == MoonlightVideoSurfaceState::Bound &&
                requested.operationGeneration == operationHighWater) {
                return {requested == current
                            ? MoonlightVideoSurfaceTransitionStatus::AlreadyApplied
                            : MoonlightVideoSurfaceTransitionStatus::Stale,
                        state, false};
            }
            if (requested.operationGeneration <= operationHighWater) {
                return {MoonlightVideoSurfaceTransitionStatus::Stale, state, false};
            }
            initial = state == MoonlightVideoSurfaceState::AwaitingSurface;
            if (!initial && state != MoonlightVideoSurfaceState::SuspendedNoSurface) {
                return {MoonlightVideoSurfaceTransitionStatus::Busy, state, false};
            }
            if (!validInitialBinding(requested, key, profile) ||
                (!initial && !validRebind(current, requested))) {
                return {MoonlightVideoSurfaceTransitionStatus::InvalidRequest, state, false};
            }
            if (!initial) {
                state = MoonlightVideoSurfaceState::Rebinding;
                pendingKind = TransitionKind::Bind;
                pendingOperation = requested.operationGeneration;
            }
        }

        if (initial) {
            const auto sinkStarted = sink->start(requested.decoder);
            const auto startStatus = mapStart(sinkStarted.status);
            if (startStatus != MoonlightVideoSurfaceTransitionStatus::Applied) {
                return result(startStatus);
            }
            {
                std::lock_guard<std::mutex> lock(mutex);
                sinkActive = true;
            }
            const auto bridgeStarted = bridge->start(key, profile);
            if (bridgeStarted.status != MoonlightVideoStartStatus::Started) {
                (void)sink->stop(key, std::chrono::seconds(5));
                {
                    std::lock_guard<std::mutex> lock(mutex);
                    sinkActive = false;
                }
                return result(bridgeStarted.status == MoonlightVideoStartStatus::RuntimeProofRequired
                    ? MoonlightVideoSurfaceTransitionStatus::RuntimeProofRequired
                    : MoonlightVideoSurfaceTransitionStatus::Failed);
            }
            {
                std::lock_guard<std::mutex> lock(mutex);
                bridgeActive = true;
            }
        } else {
            const auto rebound = sink->rebind(requested.decoder);
            const auto reboundStatus = mapRebind(rebound);
            if (reboundStatus != MoonlightVideoSurfaceTransitionStatus::Applied) {
                std::lock_guard<std::mutex> lock(mutex);
                state = MoonlightVideoSurfaceState::SuspendedNoSurface;
                pendingKind = TransitionKind::None;
                pendingOperation = 0U;
                return {reboundStatus, state, false};
            }
        }

        std::lock_guard<std::mutex> lock(mutex);
        current = requested;
        operationHighWater = requested.operationGeneration;
        lastKind = TransitionKind::Bind;
        pendingKind = TransitionKind::None;
        pendingOperation = 0U;
        state = MoonlightVideoSurfaceState::Bound;
        idrNeeded = true;
        idrRequestPending = true;
        return {MoonlightVideoSurfaceTransitionStatus::Applied, state, true};
    }

    MoonlightVideoSubmitResult submit(
        const MoonlightVideoDecodeUnitView& decodeUnit) noexcept {
        bool requestAlreadyPending = false;
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (!key.valid() || decodeUnit.key != key ||
                !sameProfile(decodeUnit.profile, profile)) {
                return {MoonlightVideoSubmitStatus::Stale,
                        MoonlightVideoDropReason::None, false, false, 0U, 0U, 0U};
            }
            if (state != MoonlightVideoSurfaceState::Bound) {
                ++noSurfaceDroppedFrames;
                idrNeeded = true;
                idrRequestPending = false;
                return {MoonlightVideoSubmitStatus::NoSurface,
                        MoonlightVideoDropReason::NoSurface, false, false,
                        0U, 0U, 0U};
            }
            requestAlreadyPending = idrRequestPending;
        }

        auto submitted = bridge->submit(decodeUnit);
        std::lock_guard<std::mutex> lock(mutex);
        if (requestAlreadyPending &&
            submitted.status == MoonlightVideoSubmitStatus::NeedIdr) {
            submitted.status = MoonlightVideoSubmitStatus::Dropped;
            submitted.dropReason = MoonlightVideoDropReason::WaitingForIdr;
            submitted.requestIdr = false;
        }
        if (submitted.requestIdr) {
            if (idrRequestPending) {
                submitted.requestIdr = false;
            } else {
                idrRequestPending = true;
            }
            idrNeeded = true;
        }
        if (submitted.status == MoonlightVideoSubmitStatus::Accepted &&
            decodeUnit.frameType == MoonlightVideoFrameType::IdR &&
            state == MoonlightVideoSurfaceState::Bound) {
            idrNeeded = false;
            idrRequestPending = false;
        }
        return submitted;
    }

    MoonlightVideoSurfaceTransitionResult suspend(
        const MoonlightSessionKey& requestedKey,
        std::uint64_t operation,
        MoonlightVideoSurfaceSuspendReason reason,
        std::chrono::milliseconds timeout) noexcept {
        std::lock_guard<std::mutex> lane(lifecycleLane);
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (!requestedKey.valid() || requestedKey != key || !validReason(reason)) {
                return {MoonlightVideoSurfaceTransitionStatus::Stale, state, false};
            }
            if (state == MoonlightVideoSurfaceState::SuspendedNoSurface &&
                operation == operationHighWater && lastKind == TransitionKind::Suspend &&
                reason == lastSuspendReason) {
                return {MoonlightVideoSurfaceTransitionStatus::AlreadyApplied, state, false};
            }
            const bool retry = state == MoonlightVideoSurfaceState::Suspending &&
                pendingKind == TransitionKind::Suspend &&
                pendingOperation == operation && pendingSuspendReason == reason;
            if (!retry && (state != MoonlightVideoSurfaceState::Bound ||
                           operation <= operationHighWater)) {
                return {operation <= operationHighWater
                            ? MoonlightVideoSurfaceTransitionStatus::Stale
                            : MoonlightVideoSurfaceTransitionStatus::Busy,
                        state, false};
            }
            if (!retry) {
                state = MoonlightVideoSurfaceState::Suspending;
                pendingKind = TransitionKind::Suspend;
                pendingOperation = operation;
                pendingSuspendReason = reason;
                idrNeeded = true;
                idrRequestPending = false;
            }
        }

        const auto suspended = sink->suspend(requestedKey, timeout);
        if (suspended == MoonlightVideoDecoderSuspendStatus::TimedOut) {
            return result(MoonlightVideoSurfaceTransitionStatus::TimedOut);
        }
        if (suspended != MoonlightVideoDecoderSuspendStatus::Suspended &&
            suspended != MoonlightVideoDecoderSuspendStatus::AlreadySuspended) {
            return result(suspended == MoonlightVideoDecoderSuspendStatus::Stale
                ? MoonlightVideoSurfaceTransitionStatus::Stale
                : MoonlightVideoSurfaceTransitionStatus::Failed);
        }
        std::lock_guard<std::mutex> lock(mutex);
        operationHighWater = operation;
        lastKind = TransitionKind::Suspend;
        lastSuspendReason = reason;
        pendingKind = TransitionKind::None;
        pendingOperation = 0U;
        state = MoonlightVideoSurfaceState::SuspendedNoSurface;
        return {MoonlightVideoSurfaceTransitionStatus::Applied, state, false};
    }

    MoonlightVideoSurfaceTransitionResult resize(
        const MoonlightSessionKey& requestedKey,
        std::uint64_t operation,
        std::uint64_t surfaceGeneration,
        std::int32_t width,
        std::int32_t height) noexcept {
        std::lock_guard<std::mutex> lane(lifecycleLane);
        std::lock_guard<std::mutex> lock(mutex);
        if (!requestedKey.valid() || requestedKey != key ||
            !validSurfaceSize(width, height)) {
            return {MoonlightVideoSurfaceTransitionStatus::InvalidRequest, state, false};
        }
        if (state == MoonlightVideoSurfaceState::Bound &&
            operation == operationHighWater && lastKind == TransitionKind::Resize &&
            surfaceGeneration == current.surfaceGeneration &&
            width == current.surfaceWidth && height == current.surfaceHeight) {
            return {MoonlightVideoSurfaceTransitionStatus::AlreadyApplied, state, false};
        }
        if (state != MoonlightVideoSurfaceState::Bound ||
            operation <= operationHighWater ||
            surfaceGeneration != current.surfaceGeneration) {
            return {MoonlightVideoSurfaceTransitionStatus::Stale, state, false};
        }
        current.operationGeneration = operation;
        current.surfaceWidth = width;
        current.surfaceHeight = height;
        operationHighWater = operation;
        lastKind = TransitionKind::Resize;
        return {MoonlightVideoSurfaceTransitionStatus::Applied, state, false};
    }

    MoonlightVideoSurfaceTransitionResult stop(
        const MoonlightSessionKey& requestedKey,
        std::uint64_t operation,
        std::chrono::milliseconds timeout) noexcept {
        std::lock_guard<std::mutex> lane(lifecycleLane);
        bool shouldStopBridge = false;
        bool shouldStopSink = false;
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (!requestedKey.valid() || requestedKey != key) {
                return {MoonlightVideoSurfaceTransitionStatus::Stale, state, false};
            }
            if (state == MoonlightVideoSurfaceState::Stopped &&
                operation == operationHighWater && lastKind == TransitionKind::Stop) {
                return {MoonlightVideoSurfaceTransitionStatus::AlreadyApplied, state, false};
            }
            const bool retry = state == MoonlightVideoSurfaceState::Stopping &&
                pendingKind == TransitionKind::Stop && pendingOperation == operation;
            if (!retry && (state == MoonlightVideoSurfaceState::Stopped ||
                           operation <= operationHighWater)) {
                return {MoonlightVideoSurfaceTransitionStatus::Stale, state, false};
            }
            if (!retry) {
                state = MoonlightVideoSurfaceState::Stopping;
                pendingKind = TransitionKind::Stop;
                pendingOperation = operation;
                idrNeeded = false;
                idrRequestPending = false;
            }
            shouldStopBridge = bridgeActive;
            shouldStopSink = sinkActive;
        }

        if (shouldStopBridge) {
            const auto stopped = bridge->stop(requestedKey, timeout);
            if (stopped == MoonlightVideoStopStatus::TimedOut) {
                return result(MoonlightVideoSurfaceTransitionStatus::TimedOut);
            }
            if (stopped != MoonlightVideoStopStatus::Stopped &&
                stopped != MoonlightVideoStopStatus::AlreadyStopped) {
                return result(MoonlightVideoSurfaceTransitionStatus::Stale);
            }
            {
                std::lock_guard<std::mutex> lock(mutex);
                bridgeActive = false;
            }
        }
        if (shouldStopSink) {
            const auto stopped = sink->stop(requestedKey, timeout);
            if (stopped == MoonlightVideoDecoderStopStatus::TimedOut) {
                return result(MoonlightVideoSurfaceTransitionStatus::TimedOut);
            }
            if (stopped != MoonlightVideoDecoderStopStatus::Stopped &&
                stopped != MoonlightVideoDecoderStopStatus::AlreadyStopped) {
                return result(stopped == MoonlightVideoDecoderStopStatus::Stale
                    ? MoonlightVideoSurfaceTransitionStatus::Stale
                    : MoonlightVideoSurfaceTransitionStatus::Failed);
            }
            {
                std::lock_guard<std::mutex> lock(mutex);
                sinkActive = false;
            }
        }

        std::lock_guard<std::mutex> lock(mutex);
        operationHighWater = operation;
        lastKind = TransitionKind::Stop;
        pendingKind = TransitionKind::None;
        pendingOperation = 0U;
        state = MoonlightVideoSurfaceState::Stopped;
        return {MoonlightVideoSurfaceTransitionStatus::Applied, state, false};
    }

    MoonlightVideoSurfaceSnapshot snapshot(
        const MoonlightSessionKey& requestedKey) const noexcept {
        MoonlightVideoSurfaceSnapshot result;
        bool inspectDecoder = false;
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (requestedKey != key) {
                return result;
            }
            result.matched = key.valid();
            result.key = key;
            result.state = state;
            result.binding = current.decoder;
            result.target = current.target;
            result.operationGeneration = operationHighWater;
            result.surfaceGeneration = current.surfaceGeneration;
            result.surfaceWidth = current.surfaceWidth;
            result.surfaceHeight = current.surfaceHeight;
            result.idrNeeded = idrNeeded;
            result.idrRequestPending = idrRequestPending;
            result.noSurfaceDroppedFrames = noSurfaceDroppedFrames;
            result.retainedAccessUnitBytes = 0U;
            inspectDecoder = sinkActive;
        }
        if (inspectDecoder) {
            result.firstFrameReady = sink->snapshot(requestedKey).firstFrameReady;
        }
        return result;
    }

    const std::shared_ptr<MoonlightOwnedVideoDecoderSink> sink;
    const std::unique_ptr<MoonlightVideoBridge> bridge;
    mutable std::mutex mutex;
    std::mutex lifecycleLane;
    MoonlightSessionKey key {};
    MoonlightStreamCodecProfile profile {};
    MoonlightVideoSurfaceBinding current {};
    MoonlightVideoSurfaceState state = MoonlightVideoSurfaceState::Stopped;
    std::uint64_t ownerTokenHighWater = 0U;
    std::uint64_t operationHighWater = 0U;
    TransitionKind lastKind = TransitionKind::None;
    TransitionKind pendingKind = TransitionKind::None;
    std::uint64_t pendingOperation = 0U;
    MoonlightVideoSurfaceSuspendReason lastSuspendReason =
        MoonlightVideoSurfaceSuspendReason::SurfaceDestroyed;
    MoonlightVideoSurfaceSuspendReason pendingSuspendReason =
        MoonlightVideoSurfaceSuspendReason::SurfaceDestroyed;
    bool bridgeActive = false;
    bool sinkActive = false;
    bool idrNeeded = false;
    bool idrRequestPending = false;
    std::uint64_t noSurfaceDroppedFrames = 0U;
};

MoonlightVideoSurfaceLifecycle::MoonlightVideoSurfaceLifecycle(
    std::unique_ptr<Impl> impl) : impl_(std::move(impl)) {}

MoonlightVideoSurfaceLifecycle::~MoonlightVideoSurfaceLifecycle() = default;

std::unique_ptr<MoonlightVideoSurfaceLifecycle>
MoonlightVideoSurfaceLifecycle::create(
    std::shared_ptr<MoonlightOwnedDecoderPort> port) {
    auto ownedSink = MoonlightOwnedVideoDecoderSink::create(std::move(port));
    if (ownedSink == nullptr) {
        return nullptr;
    }
    std::shared_ptr<MoonlightOwnedVideoDecoderSink> sink(std::move(ownedSink));
    auto bridge = MoonlightVideoBridge::create(sink);
    if (bridge == nullptr) {
        return nullptr;
    }
    return std::unique_ptr<MoonlightVideoSurfaceLifecycle>(
        new MoonlightVideoSurfaceLifecycle(
            std::make_unique<Impl>(std::move(sink), std::move(bridge))));
}

#if defined(RDP_NATIVE_CALLBACK_TESTING)
std::unique_ptr<MoonlightVideoSurfaceLifecycle>
MoonlightVideoSurfaceLifecycle::createForTesting(
    std::shared_ptr<MoonlightOwnedDecoderPort> port) {
    return create(std::move(port));
}
#endif

MoonlightVideoSurfaceTransitionResult MoonlightVideoSurfaceLifecycle::begin(
    const MoonlightVideoSurfaceBeginRequest& request) noexcept {
    return impl_->begin(request);
}

MoonlightVideoSurfaceTransitionResult MoonlightVideoSurfaceLifecycle::bind(
    const MoonlightVideoSurfaceBinding& binding) noexcept {
    return impl_->bind(binding);
}

MoonlightVideoSubmitResult MoonlightVideoSurfaceLifecycle::submit(
    const MoonlightVideoDecodeUnitView& decodeUnit) noexcept {
    return impl_->submit(decodeUnit);
}

MoonlightVideoSurfaceTransitionResult MoonlightVideoSurfaceLifecycle::suspend(
    const MoonlightSessionKey& key,
    std::uint64_t operationGeneration,
    MoonlightVideoSurfaceSuspendReason reason,
    std::chrono::milliseconds timeout) noexcept {
    return impl_->suspend(key, operationGeneration, reason, timeout);
}

MoonlightVideoSurfaceTransitionResult MoonlightVideoSurfaceLifecycle::resize(
    const MoonlightSessionKey& key,
    std::uint64_t operationGeneration,
    std::uint64_t surfaceGeneration,
    std::int32_t width,
    std::int32_t height) noexcept {
    return impl_->resize(
        key, operationGeneration, surfaceGeneration, width, height);
}

MoonlightVideoSurfaceTransitionResult MoonlightVideoSurfaceLifecycle::stop(
    const MoonlightSessionKey& key,
    std::uint64_t operationGeneration,
    std::chrono::milliseconds timeout) noexcept {
    return impl_->stop(key, operationGeneration, timeout);
}

MoonlightVideoSurfaceSnapshot MoonlightVideoSurfaceLifecycle::snapshot(
    const MoonlightSessionKey& key) const noexcept {
    return impl_->snapshot(key);
}

} // namespace remotedesk::moonlight
