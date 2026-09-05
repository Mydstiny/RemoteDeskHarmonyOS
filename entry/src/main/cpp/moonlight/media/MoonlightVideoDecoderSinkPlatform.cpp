#include "moonlight/media/MoonlightVideoDecoderSink.h"
#include "moonlight/media/MoonlightVideoCodecSupport.h"

#include "render/gl_renderer.h"
#include "render/hw_decoder.h"

#include <mutex>
#include <utility>

namespace remotedesk::moonlight {
namespace {

DecoderSessionIdentity decoderOwner(const MoonlightSessionKey& key) noexcept {
    return {key.sessionId, key.generation, key.ownerToken};
}

bool mvpProfile(const MoonlightStreamCodecProfile& profile) noexcept {
    return moonlightHardwareVideoProfileSupported(profile);
}

bool sameProfile(const MoonlightStreamCodecProfile& left,
                 const MoonlightStreamCodecProfile& right) noexcept {
    return left.codec == right.codec && left.bitDepth == right.bitDepth &&
        left.chroma == right.chroma;
}

bool telemetryMatches(const DecoderPresentationTelemetrySnapshot& telemetry,
                      const MoonlightVideoDecoderBinding& binding) noexcept {
    return telemetry.valid && telemetry.ready && telemetry.hardware &&
        telemetry.owner == decoderOwner(binding.key) &&
        telemetry.codec == static_cast<int>(
            moonlightHardwareCodecType(binding.profile.codec)) &&
        telemetry.width == binding.width && telemetry.height == binding.height &&
        telemetry.decoderHandle == binding.decoderHandle &&
        telemetry.rendererHandle == binding.rendererHandle &&
        telemetry.decoderGeneration == binding.decoderGeneration &&
        telemetry.displayGeneration == binding.displayGeneration &&
        telemetry.display == binding.display &&
        telemetry.rendererGeneration == binding.rendererGeneration;
}

bool telemetryMatchesStableBinding(
    const DecoderPresentationTelemetrySnapshot& telemetry,
    const MoonlightVideoDecoderBinding& binding) noexcept {
    return telemetry.valid && telemetry.ready && telemetry.hardware &&
        telemetry.owner == decoderOwner(binding.key) &&
        telemetry.codec == static_cast<int>(
            moonlightHardwareCodecType(binding.profile.codec)) &&
        telemetry.width == binding.width && telemetry.height == binding.height &&
        telemetry.decoderHandle == binding.decoderHandle &&
        telemetry.rendererHandle == binding.rendererHandle &&
        telemetry.displayGeneration == binding.displayGeneration &&
        telemetry.display == binding.display &&
        telemetry.rendererGeneration == binding.rendererGeneration;
}

bool telemetryBelongsToPresentationOwner(
    const DecoderPresentationTelemetrySnapshot& telemetry,
    const MoonlightVideoDecoderBinding& binding) noexcept {
    // Display metadata and decoder/renderer generations can advance while the
    // same phone Surface is being resized or the exact owned pipeline is being
    // recovered. They remain strict gates for mutation/rebind operations, but
    // they are not ownership identities for already-observed presentation.
    // GetActivePresentationTelemetry() has already proven the live shared sink
    // lease, active decoder and renderer generations, and attached pipeline.
    // Keep the immutable session owner plus both opaque handles exact here so
    // another protocol, launch, decoder, or renderer can never satisfy this
    // evidence path.
    return telemetry.valid && telemetry.ready && telemetry.hardware &&
        telemetry.owner == decoderOwner(binding.key) &&
        telemetry.codec == static_cast<int>(
            moonlightHardwareCodecType(binding.profile.codec)) &&
        telemetry.width == binding.width && telemetry.height == binding.height &&
        telemetry.decoderHandle == binding.decoderHandle &&
        telemetry.rendererHandle == binding.rendererHandle;
}

MoonlightDecoderPortSubmitStatus mapOwnedSubmit(
    DecoderNapi::OwnedSubmitStatus status) noexcept {
    switch (status) {
        case DecoderNapi::OwnedSubmitStatus::Accepted:
            return MoonlightDecoderPortSubmitStatus::Accepted;
        case DecoderNapi::OwnedSubmitStatus::AcceptedNeedsKeyframe:
            return MoonlightDecoderPortSubmitStatus::AcceptedNeedsIdr;
        case DecoderNapi::OwnedSubmitStatus::Backpressure:
            return MoonlightDecoderPortSubmitStatus::Backpressure;
        case DecoderNapi::OwnedSubmitStatus::NeedKeyframe:
            return MoonlightDecoderPortSubmitStatus::NeedIdr;
        case DecoderNapi::OwnedSubmitStatus::Stale:
            return MoonlightDecoderPortSubmitStatus::Stale;
        case DecoderNapi::OwnedSubmitStatus::Failed:
            return MoonlightDecoderPortSubmitStatus::Failed;
    }
    return MoonlightDecoderPortSubmitStatus::Failed;
}

class MoonlightHardwareDecoderPort final : public MoonlightOwnedDecoderPort {
public:
    MoonlightDecoderPortStartStatus start(
        const MoonlightVideoDecoderBinding& requested) override {
        if (!requested.runtimeProof.valid()) {
            return MoonlightDecoderPortStartStatus::RuntimeProofRequired;
        }
        if (!mvpProfile(requested.profile)) {
            return MoonlightDecoderPortStartStatus::Unsupported;
        }
        if (!requested.key.valid() || requested.decoderHandle <= 0 ||
            requested.rendererHandle <= 0 || !requested.ownsDecoderHandle) {
            return MoonlightDecoderPortStartStatus::Failed;
        }
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (active_) {
                return MoonlightDecoderPortStartStatus::Busy;
            }
            if (requested.key.ownerToken <= ownerTokenHighWater_) {
                return MoonlightDecoderPortStartStatus::Stale;
            }
        }

        const DecoderSessionIdentity owner = decoderOwner(requested.key);
        if (!DecoderNapi::IsActiveSessionOwner(owner) ||
            RendererNapi::GetActiveRendererHandle(owner) !=
                requested.rendererHandle ||
            RendererNapi::GetActiveRendererGeneration(
                requested.rendererHandle, owner) != requested.rendererGeneration) {
            return MoonlightDecoderPortStartStatus::Stale;
        }
        const DecoderPresentationTelemetrySnapshot telemetry =
            DecoderNapi::GetActivePresentationTelemetry(owner);
        if (!telemetryMatches(telemetry, requested)) {
            return MoonlightDecoderPortStartStatus::Stale;
        }

        std::lock_guard<std::mutex> lock(mutex_);
        if (active_) {
            return MoonlightDecoderPortStartStatus::Busy;
        }
        binding_ = requested;
        ownerTokenHighWater_ = requested.key.ownerToken;
        configurationGeneration_ = 0U;
        active_ = true;
        suspended_ = false;
        return MoonlightDecoderPortStartStatus::Started;
    }

    MoonlightDecoderPortSubmitResult submit(
        const MoonlightVideoDecoderBinding& requested,
        std::shared_ptr<const MoonlightOwnedVideoAccessUnit> accessUnit) override {
        std::uint64_t currentConfiguration = 0U;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!active_ || requested != binding_ || accessUnit == nullptr ||
                suspended_ ||
                accessUnit->key != binding_.key ||
                !sameProfile(accessUnit->profile, binding_.profile)) {
                return {MoonlightDecoderPortSubmitStatus::Stale, false, {}};
            }
            currentConfiguration = configurationGeneration_;
        }
        if (accessUnit->bytes.empty() ||
            accessUnit->codecConfigurationGeneration == 0U) {
            return {MoonlightDecoderPortSubmitStatus::Failed, false, {}};
        }
        if (accessUnit->codecConfigurationChanged) {
            if (accessUnit->frameType != MoonlightVideoFrameType::IdR ||
                accessUnit->codecConfigurationGeneration !=
                    currentConfiguration + 1U) {
                return {MoonlightDecoderPortSubmitStatus::Failed, false, {}};
            }
            if (currentConfiguration != 0U &&
                !DecoderNapi::RequestDecoderRecovery(
                    requested.decoderHandle, decoderOwner(requested.key))) {
                return {MoonlightDecoderPortSubmitStatus::Stale, false, {}};
            }
        } else if (currentConfiguration == 0U ||
                   accessUnit->codecConfigurationGeneration !=
                       currentConfiguration) {
            return {MoonlightDecoderPortSubmitStatus::NeedIdr, false, {}};
        }

        VideoFrame frame;
        frame.data = accessUnit->bytes.data();
        frame.size = accessUnit->bytes.size();
        frame.width = requested.width;
        frame.height = requested.height;
        frame.codec = moonlightHardwareCodecType(requested.profile.codec);
        frame.timestamp = accessUnit->presentationTimeUs;
        frame.isKeyFrame =
            accessUnit->frameType == MoonlightVideoFrameType::IdR;
        frame.display = requested.display;
        const auto submitted = DecoderNapi::DecodeOwnedNative(
            requested.decoderHandle, requested.decoderGeneration,
            requested.displayGeneration, decoderOwner(requested.key), frame);
        const auto result = mapOwnedSubmit(submitted);
        MoonlightVideoDecoderBinding acceptedBinding = requested;
        bool bindingChanged = false;
        if (result == MoonlightDecoderPortSubmitStatus::Accepted &&
            frame.isKeyFrame) {
            const DecoderPresentationTelemetrySnapshot telemetry =
                DecoderNapi::GetActivePresentationTelemetry(
                    decoderOwner(requested.key));
            const auto handoff = classifyMoonlightDecoderGenerationHandoff(
                telemetryMatchesStableBinding(telemetry, requested),
                requested.decoderGeneration, telemetry.decoderGeneration,
                accessUnit->codecConfigurationChanged &&
                    currentConfiguration != 0U);
            if (handoff == MoonlightDecoderGenerationHandoff::Stale) {
                return {
                    MoonlightDecoderPortSubmitStatus::Stale, false, {}};
            }
            if (handoff == MoonlightDecoderGenerationHandoff::Advanced) {
                acceptedBinding.decoderGeneration = telemetry.decoderGeneration;
                bindingChanged = true;
            }
        }
        if (result == MoonlightDecoderPortSubmitStatus::Accepted &&
            (accessUnit->codecConfigurationChanged || bindingChanged)) {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!active_ || binding_ != requested) {
                return {MoonlightDecoderPortSubmitStatus::Stale, false, {}};
            }
            if (accessUnit->codecConfigurationChanged) {
                configurationGeneration_ =
                    accessUnit->codecConfigurationGeneration;
            }
            binding_ = acceptedBinding;
        }
        return {result, bindingChanged, acceptedBinding};
    }

    MoonlightDecoderPortSuspendStatus suspend(
        const MoonlightVideoDecoderBinding& requested,
        std::chrono::milliseconds) override {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!active_ || binding_ != requested) {
                return MoonlightDecoderPortSuspendStatus::Stale;
            }
            if (suspended_) {
                return MoonlightDecoderPortSuspendStatus::AlreadySuspended;
            }
        }
        if (!DecoderNapi::DetachVideoPipeline(
                requested.decoderHandle, decoderOwner(requested.key))) {
            return MoonlightDecoderPortSuspendStatus::Failed;
        }
        std::lock_guard<std::mutex> lock(mutex_);
        if (!active_ || binding_ != requested) {
            return MoonlightDecoderPortSuspendStatus::Stale;
        }
        suspended_ = true;
        return MoonlightDecoderPortSuspendStatus::Suspended;
    }

    MoonlightDecoderPortRebindStatus rebind(
        const MoonlightVideoDecoderBinding& current,
        const MoonlightVideoDecoderBinding& next) override {
        if (!next.runtimeProof.valid()) {
            return MoonlightDecoderPortRebindStatus::RuntimeProofRequired;
        }
        if (!mvpProfile(next.profile)) {
            return MoonlightDecoderPortRebindStatus::Unsupported;
        }
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!active_ || !suspended_ || binding_ != current) {
                return MoonlightDecoderPortRebindStatus::Stale;
            }
        }

        const DecoderSessionIdentity owner = decoderOwner(next.key);
        if (!DecoderNapi::IsActiveSessionOwner(owner) ||
            RendererNapi::GetActiveRendererHandle(owner) != next.rendererHandle ||
            RendererNapi::GetActiveRendererGeneration(
                next.rendererHandle, owner) != next.rendererGeneration) {
            return MoonlightDecoderPortRebindStatus::Stale;
        }
        if (!DecoderNapi::RebindOwnedVideoPipeline(
                next.decoderHandle, next.decoderGeneration,
                next.rendererHandle, next.rendererGeneration, owner)) {
            return MoonlightDecoderPortRebindStatus::Failed;
        }
        const auto telemetry = DecoderNapi::GetActivePresentationTelemetry(owner);
        if (!telemetryMatches(telemetry, next)) {
            (void)DecoderNapi::DetachVideoPipeline(next.decoderHandle, owner);
            return MoonlightDecoderPortRebindStatus::Stale;
        }

        std::lock_guard<std::mutex> lock(mutex_);
        if (!active_ || !suspended_ || binding_ != current) {
            (void)DecoderNapi::DetachVideoPipeline(next.decoderHandle, owner);
            return MoonlightDecoderPortRebindStatus::Stale;
        }
        binding_ = next;
        suspended_ = false;
        return MoonlightDecoderPortRebindStatus::Rebound;
    }

    MoonlightDecoderPortStopStatus stop(
        const MoonlightVideoDecoderBinding& requested,
        std::chrono::milliseconds) override {
        bool wasSuspended = false;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!active_) {
                return binding_.key == requested.key
                    ? MoonlightDecoderPortStopStatus::AlreadyStopped
                    : MoonlightDecoderPortStopStatus::Stale;
            }
            if (binding_ != requested) {
                return MoonlightDecoderPortStopStatus::Stale;
            }
            wasSuspended = suspended_;
            active_ = false;
            suspended_ = false;
        }

        const DecoderSessionIdentity owner = decoderOwner(requested.key);
        if (!wasSuspended) {
            (void)DecoderNapi::DetachVideoPipeline(requested.decoderHandle, owner);
        }
        DecoderNapi::DestroyDecoderHandle(requested.decoderHandle, owner);
        std::lock_guard<std::mutex> lock(mutex_);
        configurationGeneration_ = 0U;
        // Ownership was explicitly transferred in the binding. Even when the
        // active renderer was already replaced, exact-owner destroy either
        // retires the handle now or transfers it to the existing deferred
        // owner; no Moonlight-private cleanup lane is needed.
        return MoonlightDecoderPortStopStatus::Stopped;
    }

    MoonlightDecoderPresentationSnapshot snapshot(
        const MoonlightVideoDecoderBinding& requested) override {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!active_ || suspended_ || binding_ != requested) {
                return {};
            }
        }
        const DecoderPresentationTelemetrySnapshot telemetry =
            DecoderNapi::GetActivePresentationTelemetry(
                decoderOwner(requested.key));
        MoonlightDecoderPresentationSnapshot result;
        if (!telemetryBelongsToPresentationOwner(telemetry, requested)) {
            return result;
        }
        result.matched = true;
        result.running = true;
        result.binding = requested;
        result.decoderGeneration = telemetry.decoderGeneration;
        result.rendererGeneration = telemetry.rendererGeneration;
        result.renderedOutputBuffers = telemetry.renderedOutputBuffers;
        result.nativeImageFrames = telemetry.nativeImageFrames;
        result.rendererPresentedFrames = telemetry.rendererPresentedFrames;
        result.decoderQueueDepth = telemetry.queueDepth;
        result.decoderInputDroppedFrames = telemetry.inputDroppedFrames;
        result.decoderWaitKeyframeDrops = telemetry.waitKeyframeDrops;
        result.decoderInputTruncated = telemetry.inputTruncated;
        result.decoderRenderOutputFailures = telemetry.renderOutputFailures;
        result.decoderSurfaceUpdateFailures = telemetry.updateSurfaceFailures;
        result.decoderSurfaceCoalescedNotifications =
            telemetry.coalescedSurfaceNotifications;
        result.decoderCodecLatencyMs = telemetry.codecLatencyMs;
        result.decoderCodecLatencyMaxMs = telemetry.codecLatencyMaxMs;
        result.decoderLowLatencyEnabled = telemetry.lowLatencyEnabled;
        result.presentation.decoderGeneration = telemetry.decoderGeneration;
        result.presentation.rendererGeneration = telemetry.rendererGeneration;
        result.presentation.desktopSurfaceCompatibility =
            telemetry.desktopSurfaceCompatibility;
        result.presentation.nativeImagePresentation =
            Render::NativeImagePresentationModeName(telemetry.presentationMode);
        result.presentation.producerTransform =
            Render::NativeImageTransformClassName(
                telemetry.producerTransformClass);
        result.presentation.appliedTransform =
            Render::NativeImageTransformClassName(
                telemetry.appliedTransformClass);
        result.presentation.producerTransformSampled =
            telemetry.producerTransformSampled;
        result.presentation.producerTransformReadResult =
            telemetry.producerTransformReadResult;
        result.presentation.producerTransformSamples =
            telemetry.producerTransformSamples;
        result.presentation.producerTransformChanges =
            telemetry.producerTransformChanges;
        result.presentation.producerTransformReadFailures =
            telemetry.producerTransformReadFailures;
        result.presentation.producerTransformClassMask =
            telemetry.producerTransformClassMask;
        result.presentation.producerTransformMatrix =
            telemetry.producerTransformMatrix;
        result.presentation.appliedTextureTransform =
            telemetry.appliedTextureTransform;
        result.presentation.rendererTransformValid =
            telemetry.rendererTransformValid;
        result.presentation.rendererTransformVersion =
            telemetry.rendererTransformVersion;
        result.presentation.rendererRotationQuarterTurns =
            telemetry.rendererRotationQuarterTurns;
        result.presentation.rendererFlipX = telemetry.rendererFlipX;
        result.presentation.rendererFlipY = telemetry.rendererFlipY;
        return result;
    }

private:
    std::mutex mutex_;
    MoonlightVideoDecoderBinding binding_ {};
    std::uint64_t ownerTokenHighWater_ = 0U;
    std::uint64_t configurationGeneration_ = 0U;
    bool active_ = false;
    bool suspended_ = false;
};

} // namespace

std::shared_ptr<MoonlightOwnedDecoderPort>
createMoonlightHardwareDecoderPort() {
    return std::make_shared<MoonlightHardwareDecoderPort>();
}

} // namespace remotedesk::moonlight
