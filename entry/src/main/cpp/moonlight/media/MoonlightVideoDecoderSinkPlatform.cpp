#include "moonlight/media/MoonlightVideoDecoderSink.h"

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
    return profile.codec == MoonlightStreamCodec::H264 &&
        profile.bitDepth == MoonlightStreamBitDepth::Bit8 &&
        profile.chroma == MoonlightStreamChroma::Yuv420;
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
        telemetry.codec == static_cast<int>(CodecType::H264) &&
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
        telemetry.codec == static_cast<int>(CodecType::H264) &&
        telemetry.width == binding.width && telemetry.height == binding.height &&
        telemetry.decoderHandle == binding.decoderHandle &&
        telemetry.rendererHandle == binding.rendererHandle &&
        telemetry.displayGeneration == binding.displayGeneration &&
        telemetry.display == binding.display &&
        telemetry.rendererGeneration == binding.rendererGeneration;
}

MoonlightDecoderPortSubmitStatus mapOwnedSubmit(
    DecoderNapi::OwnedSubmitStatus status) noexcept {
    switch (status) {
        case DecoderNapi::OwnedSubmitStatus::Accepted:
            return MoonlightDecoderPortSubmitStatus::Accepted;
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
        return MoonlightDecoderPortStartStatus::Started;
    }

    MoonlightDecoderPortSubmitResult submit(
        const MoonlightVideoDecoderBinding& requested,
        std::shared_ptr<const MoonlightOwnedVideoAccessUnit> accessUnit) override {
        std::uint64_t currentConfiguration = 0U;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!active_ || requested != binding_ || accessUnit == nullptr ||
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
        frame.codec = CodecType::H264;
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
            accessUnit->codecConfigurationChanged && currentConfiguration != 0U) {
            const DecoderPresentationTelemetrySnapshot telemetry =
                DecoderNapi::GetActivePresentationTelemetry(
                    decoderOwner(requested.key));
            if (!telemetryMatchesStableBinding(telemetry, requested) ||
                telemetry.decoderGeneration <= requested.decoderGeneration) {
                return {MoonlightDecoderPortSubmitStatus::Stale, false, {}};
            }
            acceptedBinding.decoderGeneration = telemetry.decoderGeneration;
            bindingChanged = true;
        }
        if (result == MoonlightDecoderPortSubmitStatus::Accepted &&
            accessUnit->codecConfigurationChanged) {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!active_ || binding_ != requested) {
                return {MoonlightDecoderPortSubmitStatus::Stale, false, {}};
            }
            configurationGeneration_ =
                accessUnit->codecConfigurationGeneration;
            binding_ = acceptedBinding;
        }
        return {result, bindingChanged, acceptedBinding};
    }

    MoonlightDecoderPortStopStatus stop(
        const MoonlightVideoDecoderBinding& requested,
        std::chrono::milliseconds) override {
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
            active_ = false;
        }

        const DecoderSessionIdentity owner = decoderOwner(requested.key);
        (void)DecoderNapi::DetachVideoPipeline(requested.decoderHandle, owner);
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
            if (!active_ || binding_ != requested) {
                return {};
            }
        }
        const DecoderPresentationTelemetrySnapshot telemetry =
            DecoderNapi::GetActivePresentationTelemetry(
                decoderOwner(requested.key));
        MoonlightDecoderPresentationSnapshot result;
        if (!telemetryMatches(telemetry, requested)) {
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
        return result;
    }

private:
    std::mutex mutex_;
    MoonlightVideoDecoderBinding binding_ {};
    std::uint64_t ownerTokenHighWater_ = 0U;
    std::uint64_t configurationGeneration_ = 0U;
    bool active_ = false;
};

} // namespace

std::shared_ptr<MoonlightOwnedDecoderPort>
createMoonlightHardwareDecoderPort() {
    return std::make_shared<MoonlightHardwareDecoderPort>();
}

} // namespace remotedesk::moonlight
