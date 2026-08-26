#include "moonlight/media/MoonlightProductMediaPort.h"

#include "moonlight/media/MoonlightAudioBridge.h"
#include "moonlight/media/MoonlightVideoBridge.h"
#include "moonlight/media/MoonlightVideoCodecSupport.h"

#include <chrono>
#include <cstdint>
#include <hilog/log.h>
#include <limits>
#include <mutex>
#include <utility>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0041
#define LOG_TAG "MOON_MEDIA"

namespace remotedesk::moonlight {
namespace {

constexpr auto kMediaStopTimeout = std::chrono::seconds(5);

enum class LaneState : std::uint8_t {
    Idle,
    Configured,
    Started,
    Suspended,
    Paused,
    Stopping,
    Stopped,
    Cleaned,
    Failed,
};

bool sameProfile(const MoonlightStreamCodecProfile& left,
                 const MoonlightStreamCodecProfile& right) noexcept {
    return left.codec == right.codec && left.bitDepth == right.bitDepth &&
        left.chroma == right.chroma;
}

bool supportedVideoProfile(
    const MoonlightStreamCodecProfile& profile) noexcept {
    return moonlightHardwareVideoProfileSupported(profile);
}

bool videoBindingReady(const MoonlightSessionKey& key,
                       const MoonlightVideoDecoderBinding& binding) noexcept {
    return key.valid() && binding.key == key &&
        supportedVideoProfile(binding.profile) && binding.width > 0 &&
        binding.height > 0 && binding.runtimeProof.valid();
}

bool audioLayoutReady(MoonlightStreamAudioLayout layout) noexcept {
    return layout == MoonlightStreamAudioLayout::Stereo;
}

bool videoStopAccepted(MoonlightVideoStopStatus status) noexcept {
    return status == MoonlightVideoStopStatus::Stopped ||
        status == MoonlightVideoStopStatus::AlreadyStopped;
}

bool decoderStopAccepted(MoonlightVideoDecoderStopStatus status) noexcept {
    return status == MoonlightVideoDecoderStopStatus::Stopped ||
        status == MoonlightVideoDecoderStopStatus::AlreadyStopped;
}

bool audioStopAccepted(MoonlightAudioStopStatus status) noexcept {
    return status == MoonlightAudioStopStatus::Stopped ||
        status == MoonlightAudioStopStatus::AlreadyStopped;
}

bool audioCleanupAccepted(MoonlightAudioCleanupStatus status) noexcept {
    return status == MoonlightAudioCleanupStatus::Cleaned ||
        status == MoonlightAudioCleanupStatus::AlreadyCleaned;
}

bool playerControlAccepted(MoonlightAudioPlayerControlStatus status) noexcept {
    return status == MoonlightAudioPlayerControlStatus::Applied ||
        status == MoonlightAudioPlayerControlStatus::AlreadyApplied;
}

MoonlightVideoSubmitResult staleVideoResult() noexcept {
    MoonlightVideoSubmitResult result;
    result.status = MoonlightVideoSubmitStatus::Stale;
    return result;
}

std::uint64_t saturatingAdd(std::uint64_t left,
                            std::uint64_t right) noexcept {
    return right > std::numeric_limits<std::uint64_t>::max() - left
        ? std::numeric_limits<std::uint64_t>::max()
        : left + right;
}

} // namespace

struct MoonlightProductMediaPort::Impl final {
    Impl(MoonlightSessionKey exactKey,
         MoonlightVideoDecoderBinding exactVideoBinding,
         std::shared_ptr<MoonlightOwnedVideoDecoderSink> exactVideoSink,
         std::unique_ptr<MoonlightVideoBridge> exactVideoBridge,
         std::shared_ptr<MoonlightAudioPlayerSink> exactAudioSink,
         std::unique_ptr<MoonlightAudioBridge> exactAudioBridge) noexcept
        : key(exactKey), videoBinding(std::move(exactVideoBinding)),
          videoSink(std::move(exactVideoSink)),
          videoBridge(std::move(exactVideoBridge)),
          audioSink(std::move(exactAudioSink)),
          audioBridge(std::move(exactAudioBridge)) {}

    bool nextAudioOperationLocked(std::uint64_t& operation) noexcept {
        if (audioOperationGeneration ==
            std::numeric_limits<std::uint64_t>::max()) {
            audioState = LaneState::Failed;
            return false;
        }
        operation = ++audioOperationGeneration;
        return true;
    }

    bool stopVideoComponents() noexcept {
        bool stopBridge = false;
        bool stopSink = false;
        {
            std::lock_guard<std::mutex> lock(videoMutex);
            stopBridge = videoBridgeActive;
            stopSink = videoSinkActive;
            if (!stopBridge && !stopSink) {
                videoState = LaneState::Stopped;
                return true;
            }
            videoState = LaneState::Stopping;
        }

        bool bridgeStopped = !stopBridge;
        if (stopBridge) {
            bridgeStopped = videoStopAccepted(
                videoBridge->stop(key, kMediaStopTimeout));
            if (bridgeStopped) {
                std::lock_guard<std::mutex> lock(videoMutex);
                videoBridgeActive = false;
            }
        }

        bool sinkStopped = !stopSink;
        if (bridgeStopped && stopSink) {
            sinkStopped = decoderStopAccepted(
                videoSink->stop(key, kMediaStopTimeout));
            if (sinkStopped) {
                std::lock_guard<std::mutex> lock(videoMutex);
                videoSinkActive = false;
            }
        }

        std::lock_guard<std::mutex> lock(videoMutex);
        const bool stopped = !videoBridgeActive && !videoSinkActive;
        videoState = stopped ? LaneState::Stopped : LaneState::Failed;
        return stopped;
    }

    bool stopAudioComponents() noexcept {
        MoonlightAudioStreamIdentity exactIdentity;
        bool stopBridge = false;
        bool stopSink = false;
        std::uint64_t bridgeOperation = 0U;
        {
            std::lock_guard<std::mutex> lock(audioMutex);
            exactIdentity = audioIdentity;
            stopBridge = audioBridgeActive;
            stopSink = audioSinkActive;
            if (!stopBridge && !stopSink) {
                audioState = LaneState::Stopped;
                return true;
            }
            audioState = LaneState::Stopping;
            if (stopBridge &&
                !nextAudioOperationLocked(bridgeOperation)) {
                return false;
            }
        }

        bool bridgeStopped = !stopBridge;
        if (stopBridge) {
            bridgeStopped = audioStopAccepted(audioBridge->stop(
                exactIdentity, bridgeOperation, kMediaStopTimeout).status);
            if (bridgeStopped) {
                std::lock_guard<std::mutex> lock(audioMutex);
                audioBridgeActive = false;
            }
        }

        bool sinkStopped = !stopSink;
        if (bridgeStopped && stopSink) {
            std::uint64_t sinkOperation = 0U;
            {
                std::lock_guard<std::mutex> lock(audioMutex);
                if (!nextAudioOperationLocked(sinkOperation)) {
                    return false;
                }
            }
            sinkStopped = playerControlAccepted(
                audioSink->stop(exactIdentity, sinkOperation).status);
            if (sinkStopped) {
                std::lock_guard<std::mutex> lock(audioMutex);
                audioSinkActive = false;
            }
        }

        std::lock_guard<std::mutex> lock(audioMutex);
        const bool stopped = !audioBridgeActive && !audioSinkActive;
        audioState = stopped ? LaneState::Stopped : LaneState::Failed;
        return stopped;
    }

    const MoonlightSessionKey key;
    MoonlightVideoDecoderBinding videoBinding;
    const std::shared_ptr<MoonlightOwnedVideoDecoderSink> videoSink;
    const std::unique_ptr<MoonlightVideoBridge> videoBridge;
    const std::shared_ptr<MoonlightAudioPlayerSink> audioSink;
    const std::unique_ptr<MoonlightAudioBridge> audioBridge;

    mutable std::mutex videoMutex;
    std::mutex videoLifecycleLane;
    LaneState videoState = LaneState::Idle;
    LaneState videoStateBeforeSuspend = LaneState::Idle;
    bool videoSinkActive = false;
    bool videoBridgeActive = false;
    std::uint64_t acceptedVideoBytes = 0U;

    mutable std::mutex audioMutex;
    std::mutex audioLifecycleLane;
    LaneState audioState = LaneState::Idle;
    MoonlightAudioStreamIdentity audioIdentity {};
    std::uint64_t audioConfigurationGeneration = 0U;
    std::uint64_t audioOperationGeneration = 0U;
    bool audioSinkActive = false;
    bool audioBridgeActive = false;
    std::uint64_t acceptedAudioBytes = 0U;
};

MoonlightProductMediaPort::MoonlightProductMediaPort(
    std::unique_ptr<Impl> impl) noexcept : impl_(std::move(impl)) {}

MoonlightProductMediaPort::~MoonlightProductMediaPort() {
    cleanupVideo();
    cleanupAudio();
}

std::shared_ptr<MoonlightProductMediaPort>
MoonlightProductMediaPort::create(
    const MoonlightSessionKey& key,
    const MoonlightVideoDecoderBinding& videoBinding,
    std::shared_ptr<MoonlightOwnedDecoderPort> videoDecoderPort,
    std::shared_ptr<MoonlightAudioDecoderPort> audioDecoderPort,
    std::shared_ptr<MoonlightAudioPlayerSink> audioPlayerSink) noexcept {
    if (!videoBindingReady(key, videoBinding) ||
        videoDecoderPort == nullptr || audioDecoderPort == nullptr ||
        audioPlayerSink == nullptr) {
        return nullptr;
    }
    try {
        auto ownedVideoSink =
            MoonlightOwnedVideoDecoderSink::create(std::move(videoDecoderPort));
        if (ownedVideoSink == nullptr) {
            return nullptr;
        }
        std::shared_ptr<MoonlightOwnedVideoDecoderSink> videoSink(
            std::move(ownedVideoSink));
        auto videoBridge = MoonlightVideoBridge::create(videoSink);
        if (videoBridge == nullptr) {
            return nullptr;
        }
        // This existing factory is the generic injected decoder/sink seam; it
        // creates no renderer or queue despite its historical name.
        auto audioBridge = MoonlightAudioBridge::createForTesting(
            std::move(audioDecoderPort), audioPlayerSink);
        if (audioBridge == nullptr) {
            return nullptr;
        }
        auto impl = std::make_unique<Impl>(
            key, videoBinding, std::move(videoSink), std::move(videoBridge),
            std::move(audioPlayerSink), std::move(audioBridge));
        return std::shared_ptr<MoonlightProductMediaPort>(
            new MoonlightProductMediaPort(std::move(impl)));
    } catch (...) {
        return nullptr;
    }
}

std::shared_ptr<MoonlightProductMediaPort>
MoonlightProductMediaPort::createProduction(
    const MoonlightSessionKey& key,
    const MoonlightVideoDecoderBinding& videoBinding) noexcept {
    try {
        return create(key, videoBinding, createMoonlightHardwareDecoderPort(),
                      createMoonlightOpusDecoderPort(),
                      MoonlightAudioPlayerSink::createProduction());
    } catch (...) {
        return nullptr;
    }
}

bool MoonlightProductMediaPort::videoReady() const noexcept {
    if (impl_ == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> lock(impl_->videoMutex);
    return impl_->videoState == LaneState::Idle &&
        videoBindingReady(impl_->key, impl_->videoBinding);
}

bool MoonlightProductMediaPort::audioReady(
    MoonlightStreamAudioLayout layout) const noexcept {
    if (impl_ == nullptr || !audioLayoutReady(layout)) {
        return false;
    }
    std::lock_guard<std::mutex> lock(impl_->audioMutex);
    return impl_->audioState == LaneState::Idle;
}

bool MoonlightProductMediaPort::firstFrameReady() const noexcept {
    if (impl_ == nullptr) {
        return false;
    }
    try {
        return impl_->videoSink->snapshot(impl_->key).firstFrameReady;
    } catch (...) {
        return false;
    }
}

bool MoonlightProductMediaPort::videoLive() const noexcept {
    if (impl_ == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> lock(impl_->videoMutex);
    return impl_->videoState == LaneState::Started &&
        impl_->videoSinkActive && impl_->videoBridgeActive;
}

bool MoonlightProductMediaPort::audioLive() const noexcept {
    if (impl_ == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> lock(impl_->audioMutex);
    return impl_->audioState == LaneState::Started &&
        impl_->audioSinkActive && impl_->audioBridgeActive;
}

MoonlightProductMediaDiagnostics
MoonlightProductMediaPort::diagnostics() const noexcept {
    MoonlightProductMediaDiagnostics result;
    if (impl_ == nullptr) {
        return result;
    }
    try {
        const auto video = impl_->videoBridge->snapshot(impl_->key);
        const auto decoder = impl_->videoSink->snapshot(impl_->key);
        MoonlightAudioStreamIdentity audioIdentity;
        {
            std::lock_guard<std::mutex> lock(impl_->videoMutex);
            result.acceptedVideoBytes = impl_->acceptedVideoBytes;
        }
        {
            std::lock_guard<std::mutex> lock(impl_->audioMutex);
            audioIdentity = impl_->audioIdentity;
            result.acceptedAudioBytes = impl_->acceptedAudioBytes;
        }
        result.matched = video.matched && decoder.matched;
        result.acceptedVideoFrames = video.acceptedFrames;
        result.droppedVideoFrames = saturatingAdd(
            saturatingAdd(video.droppedFrames, video.malformedFrames),
            saturatingAdd(video.staleFrames, video.backpressureFrames));
        result.renderedOutputBuffers = decoder.renderedOutputBuffers;
        result.nativeImageFrames = decoder.nativeImageFrames;
        result.rendererPresentedFrames = decoder.rendererPresentedFrames;
        result.decoderQueueDepth = decoder.decoderQueueDepth;
        result.decoderInputDroppedFrames = decoder.decoderInputDroppedFrames;
        result.decoderWaitKeyframeDrops = decoder.decoderWaitKeyframeDrops;
        result.decoderInputTruncated = decoder.decoderInputTruncated;
        result.decoderRenderOutputFailures = decoder.decoderRenderOutputFailures;
        result.decoderSurfaceUpdateFailures = decoder.decoderSurfaceUpdateFailures;
        result.decoderSurfaceCoalescedNotifications =
            decoder.decoderSurfaceCoalescedNotifications;
        result.decoderCodecLatencyMs = decoder.decoderCodecLatencyMs;
        result.decoderCodecLatencyMaxMs = decoder.decoderCodecLatencyMaxMs;
        result.decoderLowLatencyEnabled = decoder.decoderLowLatencyEnabled;
        if (audioIdentity.valid()) {
            const auto audio = impl_->audioBridge->snapshot(audioIdentity);
            result.acceptedAudioPackets = saturatingAdd(
                audio.acceptedPackets, audio.acceptedPlcFrames);
            result.rejectedAudioPackets = audio.rejectedPackets;
        }
        return result;
    } catch (...) {
        return {};
    }
}

bool MoonlightProductMediaPort::suspendVideo() noexcept {
    if (impl_ == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> lane(impl_->videoLifecycleLane);
    LaneState previous = LaneState::Idle;
    {
        std::lock_guard<std::mutex> lock(impl_->videoMutex);
        if (impl_->videoState == LaneState::Suspended) {
            return true;
        }
        if ((impl_->videoState != LaneState::Configured &&
             impl_->videoState != LaneState::Started) ||
            !impl_->videoSinkActive || !impl_->videoBridgeActive) {
            return false;
        }
        previous = impl_->videoState;
    }
    const auto suspended = impl_->videoSink->suspend(
        impl_->key, kMediaStopTimeout);
    if (suspended != MoonlightVideoDecoderSuspendStatus::Suspended &&
        suspended != MoonlightVideoDecoderSuspendStatus::AlreadySuspended) {
        return false;
    }
    std::lock_guard<std::mutex> lock(impl_->videoMutex);
    if ((impl_->videoState != previous &&
         impl_->videoState != LaneState::Suspended) ||
        !impl_->videoSinkActive || !impl_->videoBridgeActive) {
        return false;
    }
    impl_->videoStateBeforeSuspend = previous;
    impl_->videoState = LaneState::Suspended;
    return true;
}

bool MoonlightProductMediaPort::rebindVideo(
    const MoonlightVideoDecoderBinding& binding) noexcept {
    if (impl_ == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> lane(impl_->videoLifecycleLane);
    LaneState restored = LaneState::Idle;
    {
        std::lock_guard<std::mutex> lock(impl_->videoMutex);
        if (impl_->videoState != LaneState::Suspended ||
            !impl_->videoSinkActive || !impl_->videoBridgeActive) {
            return false;
        }
        restored = impl_->videoStateBeforeSuspend;
        if (restored != LaneState::Configured &&
            restored != LaneState::Started) {
            return false;
        }
    }
    const auto rebound = impl_->videoSink->rebind(binding);
    if (rebound != MoonlightVideoDecoderRebindStatus::Rebound) {
        return false;
    }
    std::lock_guard<std::mutex> lock(impl_->videoMutex);
    if (impl_->videoState != LaneState::Suspended ||
        !impl_->videoSinkActive || !impl_->videoBridgeActive) {
        return false;
    }
    impl_->videoBinding = binding;
    impl_->videoState = restored;
    return true;
}

MoonlightVideoDecoderBinding
MoonlightProductMediaPort::videoBindingSnapshot() const noexcept {
    if (impl_ == nullptr) {
        return {};
    }
    // Decoder recovery can advance decoderGeneration without rebuilding the
    // product composition. The sink snapshot is therefore authoritative.
    const auto source = impl_->videoSink->snapshot(impl_->key);
    if (source.matched) {
        return source.binding;
    }
    std::lock_guard<std::mutex> lock(impl_->videoMutex);
    return impl_->videoBinding;
}

bool MoonlightProductMediaPort::pauseAudio(
    MoonlightAudioPauseReason reason) noexcept {
    if (impl_ == nullptr || reason == MoonlightAudioPauseReason::None) {
        return false;
    }
    std::lock_guard<std::mutex> lane(impl_->audioLifecycleLane);
    MoonlightAudioStreamIdentity identity;
    std::uint64_t operation = 0U;
    {
        std::lock_guard<std::mutex> lock(impl_->audioMutex);
        if (impl_->audioState == LaneState::Paused) {
            return true;
        }
        if (impl_->audioState != LaneState::Started ||
            !impl_->audioSinkActive ||
            !impl_->nextAudioOperationLocked(operation)) {
            return false;
        }
        identity = impl_->audioIdentity;
    }
    const auto paused = impl_->audioSink->pause(identity, operation, reason);
    if (!playerControlAccepted(paused.status)) {
        return false;
    }
    std::lock_guard<std::mutex> lock(impl_->audioMutex);
    if (impl_->audioState != LaneState::Started) {
        return false;
    }
    impl_->audioState = LaneState::Paused;
    return true;
}

bool MoonlightProductMediaPort::resumeAudio() noexcept {
    if (impl_ == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> lane(impl_->audioLifecycleLane);
    MoonlightAudioStreamIdentity identity;
    std::uint64_t operation = 0U;
    {
        std::lock_guard<std::mutex> lock(impl_->audioMutex);
        if (impl_->audioState == LaneState::Started) {
            return true;
        }
        if (impl_->audioState != LaneState::Paused ||
            !impl_->audioSinkActive ||
            !impl_->nextAudioOperationLocked(operation)) {
            return false;
        }
        identity = impl_->audioIdentity;
    }
    const auto resumed = impl_->audioSink->resume(identity, operation);
    if (!playerControlAccepted(resumed.status)) {
        return false;
    }
    std::lock_guard<std::mutex> lock(impl_->audioMutex);
    if (impl_->audioState != LaneState::Paused) {
        return false;
    }
    impl_->audioState = LaneState::Started;
    return true;
}

bool MoonlightProductMediaPort::setupVideo(
    const MoonlightCommonCVideoSelection& selection) noexcept {
    if (impl_ == nullptr ||
        !sameProfile(selection.profile, impl_->videoBinding.profile) ||
        selection.width != impl_->videoBinding.width ||
        selection.height != impl_->videoBinding.height ||
        selection.redrawRate <= 0) {
        OH_LOG_ERROR(LOG_APP, "[Moonlight] media setup gate rejected profile/size/rate");
        return false;
    }
    OH_LOG_ERROR(LOG_APP,
                 "[Moonlight] media binding key=%{public}llu/%{public}llu/%{public}llu display=%{public}lld decoder=%{public}lld renderer=%{public}lld gens=%{public}llu/%{public}llu/%{public}llu owns=%{public}d proof=%{public}llu",
                 static_cast<unsigned long long>(impl_->videoBinding.key.sessionId),
                 static_cast<unsigned long long>(impl_->videoBinding.key.generation),
                 static_cast<unsigned long long>(impl_->videoBinding.key.ownerToken),
                 static_cast<long long>(impl_->videoBinding.display),
                 static_cast<long long>(impl_->videoBinding.decoderHandle),
                 static_cast<long long>(impl_->videoBinding.rendererHandle),
                 static_cast<unsigned long long>(impl_->videoBinding.decoderGeneration),
                 static_cast<unsigned long long>(impl_->videoBinding.displayGeneration),
                 static_cast<unsigned long long>(impl_->videoBinding.rendererGeneration),
                 impl_->videoBinding.ownsDecoderHandle ? 1 : 0,
                 static_cast<unsigned long long>(impl_->videoBinding.runtimeProof.generation));
    std::lock_guard<std::mutex> lane(impl_->videoLifecycleLane);
    {
        std::lock_guard<std::mutex> lock(impl_->videoMutex);
        if (impl_->videoState != LaneState::Idle) {
            OH_LOG_ERROR(LOG_APP, "[Moonlight] media setup state not idle=%{public}d",
                         static_cast<int>(impl_->videoState));
            return false;
        }
    }

    const auto sinkStarted = impl_->videoSink->start(impl_->videoBinding);
    OH_LOG_ERROR(LOG_APP, "[Moonlight] media decoder sink start status=%{public}d",
                 static_cast<int>(sinkStarted.status));
    if (sinkStarted.status != MoonlightVideoDecoderStartStatus::Started) {
        std::lock_guard<std::mutex> lock(impl_->videoMutex);
        impl_->videoState = LaneState::Failed;
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(impl_->videoMutex);
        impl_->videoSinkActive = true;
    }

    const auto bridgeStarted = impl_->videoBridge->start(
        impl_->key, selection.profile);
    OH_LOG_ERROR(LOG_APP, "[Moonlight] media bridge start status=%{public}d",
                 static_cast<int>(bridgeStarted.status));
    if (bridgeStarted.status != MoonlightVideoStartStatus::Started) {
        const bool rolledBack = decoderStopAccepted(
            impl_->videoSink->stop(impl_->key, kMediaStopTimeout));
        std::lock_guard<std::mutex> lock(impl_->videoMutex);
        impl_->videoSinkActive = !rolledBack;
        impl_->videoState = LaneState::Failed;
        return false;
    }

    std::lock_guard<std::mutex> lock(impl_->videoMutex);
    impl_->videoBridgeActive = true;
    impl_->videoState = LaneState::Configured;
    return true;
}

void MoonlightProductMediaPort::startVideo() noexcept {
    if (impl_ == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> lane(impl_->videoLifecycleLane);
    std::lock_guard<std::mutex> lock(impl_->videoMutex);
    if (impl_->videoState == LaneState::Configured &&
        impl_->videoSinkActive && impl_->videoBridgeActive) {
        impl_->videoState = LaneState::Started;
    }
}

void MoonlightProductMediaPort::stopVideo() noexcept {
    if (impl_ == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> lane(impl_->videoLifecycleLane);
    (void)impl_->stopVideoComponents();
}

void MoonlightProductMediaPort::cleanupVideo() noexcept {
    if (impl_ == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> lane(impl_->videoLifecycleLane);
    {
        std::lock_guard<std::mutex> lock(impl_->videoMutex);
        if (impl_->videoState == LaneState::Cleaned ||
            impl_->videoState == LaneState::Idle) {
            impl_->videoState = LaneState::Cleaned;
            return;
        }
    }
    if (impl_->stopVideoComponents()) {
        std::lock_guard<std::mutex> lock(impl_->videoMutex);
        impl_->videoState = LaneState::Cleaned;
    }
}

MoonlightVideoSubmitResult MoonlightProductMediaPort::submitVideoPayload(
    const MoonlightVideoDecodeUnitView& decodeUnit) noexcept {
    if (impl_ == nullptr) {
        return staleVideoResult();
    }
    {
        std::lock_guard<std::mutex> lock(impl_->videoMutex);
        if (impl_->videoState == LaneState::Suspended &&
            decodeUnit.key == impl_->key &&
            sameProfile(decodeUnit.profile, impl_->videoBinding.profile)) {
            MoonlightVideoSubmitResult result;
            result.status = MoonlightVideoSubmitStatus::NoSurface;
            result.dropReason = MoonlightVideoDropReason::NoSurface;
            return result;
        }
        if (impl_->videoState != LaneState::Started ||
            decodeUnit.key != impl_->key ||
            !sameProfile(decodeUnit.profile, impl_->videoBinding.profile)) {
            return staleVideoResult();
        }
    }
    const auto submitted = impl_->videoBridge->submit(decodeUnit);
    if (submitted.status == MoonlightVideoSubmitStatus::Accepted) {
        std::lock_guard<std::mutex> lock(impl_->videoMutex);
        impl_->acceptedVideoBytes = saturatingAdd(
            impl_->acceptedVideoBytes,
            static_cast<std::uint64_t>(submitted.ownedBytes));
    }
    return submitted;
}

bool MoonlightProductMediaPort::setupAudio(
    const MoonlightCommonCAudioSelection& selection) noexcept {
    if (impl_ == nullptr || !audioLayoutReady(selection.layout)) {
        OH_LOG_ERROR(LOG_APP, "[Moonlight] media audio setup gate rejected layout=%{public}d",
                     static_cast<int>(selection.layout));
        return false;
    }
    std::lock_guard<std::mutex> lane(impl_->audioLifecycleLane);
    MoonlightAudioStreamIdentity identity;
    std::uint64_t configureOperation = 0U;
    {
        std::lock_guard<std::mutex> lock(impl_->audioMutex);
        if (impl_->audioState != LaneState::Idle ||
            impl_->audioConfigurationGeneration ==
                std::numeric_limits<std::uint64_t>::max()) {
            OH_LOG_ERROR(LOG_APP, "[Moonlight] media audio state rejected state=%{public}d gen=%{public}llu",
                         static_cast<int>(impl_->audioState),
                         static_cast<unsigned long long>(impl_->audioConfigurationGeneration));
            return false;
        }
        identity = {impl_->key, ++impl_->audioConfigurationGeneration};
        if (!impl_->nextAudioOperationLocked(configureOperation)) {
            return false;
        }
    }

    const auto configured = impl_->audioBridge->configure(
        identity, selection, configureOperation);
    OH_LOG_ERROR(LOG_APP,
                 "[Moonlight] media audio bridge configure status=%{public}d op=%{public}llu id=%{public}llu/%{public}llu/%{public}llu",
                 static_cast<int>(configured.status),
                 static_cast<unsigned long long>(configureOperation),
                 static_cast<unsigned long long>(identity.key.sessionId),
                 static_cast<unsigned long long>(identity.key.generation),
                 static_cast<unsigned long long>(identity.key.ownerToken));
    if (configured.status != MoonlightAudioConfigureStatus::Configured) {
        std::lock_guard<std::mutex> lock(impl_->audioMutex);
        impl_->audioState = LaneState::Failed;
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(impl_->audioMutex);
        impl_->audioIdentity = identity;
        impl_->audioBridgeActive = true;
    }

    std::uint64_t activateOperation = 0U;
    {
        std::lock_guard<std::mutex> lock(impl_->audioMutex);
        if (!impl_->nextAudioOperationLocked(activateOperation)) {
            return false;
        }
    }
    const auto activated = impl_->audioSink->activate(
        identity, activateOperation);
    OH_LOG_ERROR(LOG_APP,
                 "[Moonlight] media audio sink activate status=%{public}d op=%{public}llu",
                 static_cast<int>(activated.status),
                 static_cast<unsigned long long>(activateOperation));
    if (!playerControlAccepted(activated.status)) {
        (void)impl_->stopAudioComponents();
        std::lock_guard<std::mutex> lock(impl_->audioMutex);
        impl_->audioState = LaneState::Failed;
        return false;
    }

    std::lock_guard<std::mutex> lock(impl_->audioMutex);
    impl_->audioSinkActive = true;
    impl_->audioState = LaneState::Configured;
    return true;
}

void MoonlightProductMediaPort::startAudio() noexcept {
    if (impl_ == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> lane(impl_->audioLifecycleLane);
    MoonlightAudioStreamIdentity identity;
    std::uint64_t operation = 0U;
    {
        std::lock_guard<std::mutex> lock(impl_->audioMutex);
        if (impl_->audioState != LaneState::Configured ||
            !impl_->nextAudioOperationLocked(operation)) {
            return;
        }
        identity = impl_->audioIdentity;
    }
    const auto started = impl_->audioBridge->start(identity, operation);
    OH_LOG_ERROR(LOG_APP,
                 "[Moonlight] media audio bridge start status=%{public}d op=%{public}llu",
                 static_cast<int>(started.status),
                 static_cast<unsigned long long>(operation));
    std::lock_guard<std::mutex> lock(impl_->audioMutex);
    impl_->audioState = started.status == MoonlightAudioStartStatus::Started
        ? LaneState::Started : LaneState::Failed;
}

void MoonlightProductMediaPort::stopAudio() noexcept {
    if (impl_ == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> lane(impl_->audioLifecycleLane);
    (void)impl_->stopAudioComponents();
}

void MoonlightProductMediaPort::cleanupAudio() noexcept {
    if (impl_ == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> lane(impl_->audioLifecycleLane);
    {
        std::lock_guard<std::mutex> lock(impl_->audioMutex);
        if (impl_->audioState == LaneState::Cleaned ||
            impl_->audioState == LaneState::Idle) {
            impl_->audioState = LaneState::Cleaned;
            return;
        }
    }
    if (!impl_->stopAudioComponents()) {
        return;
    }

    MoonlightAudioStreamIdentity identity;
    std::uint64_t bridgeOperation = 0U;
    std::uint64_t sinkOperation = 0U;
    {
        std::lock_guard<std::mutex> lock(impl_->audioMutex);
        identity = impl_->audioIdentity;
        if (!impl_->nextAudioOperationLocked(bridgeOperation) ||
            !impl_->nextAudioOperationLocked(sinkOperation)) {
            return;
        }
    }
    const bool bridgeCleaned = audioCleanupAccepted(
        impl_->audioBridge->cleanup(
            identity, bridgeOperation, kMediaStopTimeout).status);
    const bool sinkCleaned = bridgeCleaned && playerControlAccepted(
        impl_->audioSink->cleanup(identity, sinkOperation).status);

    std::lock_guard<std::mutex> lock(impl_->audioMutex);
    if (bridgeCleaned && sinkCleaned) {
        impl_->audioIdentity = {};
        impl_->audioState = LaneState::Cleaned;
    } else {
        impl_->audioState = LaneState::Failed;
    }
}

void MoonlightProductMediaPort::submitAudioPayload(
    const std::uint8_t* bytes, std::size_t byteCount) noexcept {
    if (impl_ == nullptr) {
        return;
    }
    MoonlightAudioStreamIdentity identity;
    std::uint64_t operation = 0U;
    {
        std::lock_guard<std::mutex> lock(impl_->audioMutex);
        if (impl_->audioState != LaneState::Started ||
            !impl_->nextAudioOperationLocked(operation)) {
            return;
        }
        identity = impl_->audioIdentity;
    }
    const auto submitted = impl_->audioBridge->submit(
        identity, operation, bytes, byteCount);
    if (submitted.status == MoonlightAudioSubmitStatus::Accepted ||
        submitted.status == MoonlightAudioSubmitStatus::PlcAccepted) {
        std::lock_guard<std::mutex> lock(impl_->audioMutex);
        impl_->acceptedAudioBytes = saturatingAdd(
            impl_->acceptedAudioBytes,
            static_cast<std::uint64_t>(submitted.inputBytes));
    }
    if (submitted.status == MoonlightAudioSubmitStatus::Terminal) {
        std::lock_guard<std::mutex> lock(impl_->audioMutex);
        if (impl_->audioState == LaneState::Started) {
            impl_->audioState = LaneState::Failed;
        }
    }
}

} // namespace remotedesk::moonlight
