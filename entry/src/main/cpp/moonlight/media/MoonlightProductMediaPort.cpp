#include "moonlight/media/MoonlightProductMediaPort.h"

#include "moonlight/media/MoonlightAudioBridge.h"
#include "moonlight/media/MoonlightVideoBridge.h"

#include <chrono>
#include <cstdint>
#include <limits>
#include <mutex>
#include <utility>

namespace remotedesk::moonlight {
namespace {

constexpr auto kMediaStopTimeout = std::chrono::seconds(5);

enum class LaneState : std::uint8_t {
    Idle,
    Configured,
    Started,
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
    return profile.codec == MoonlightStreamCodec::H264 &&
        profile.bitDepth == MoonlightStreamBitDepth::Bit8 &&
        profile.chroma == MoonlightStreamChroma::Yuv420;
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
    const MoonlightVideoDecoderBinding videoBinding;
    const std::shared_ptr<MoonlightOwnedVideoDecoderSink> videoSink;
    const std::unique_ptr<MoonlightVideoBridge> videoBridge;
    const std::shared_ptr<MoonlightAudioPlayerSink> audioSink;
    const std::unique_ptr<MoonlightAudioBridge> audioBridge;

    mutable std::mutex videoMutex;
    std::mutex videoLifecycleLane;
    LaneState videoState = LaneState::Idle;
    bool videoSinkActive = false;
    bool videoBridgeActive = false;

    mutable std::mutex audioMutex;
    std::mutex audioLifecycleLane;
    LaneState audioState = LaneState::Idle;
    MoonlightAudioStreamIdentity audioIdentity {};
    std::uint64_t audioConfigurationGeneration = 0U;
    std::uint64_t audioOperationGeneration = 0U;
    bool audioSinkActive = false;
    bool audioBridgeActive = false;
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

bool MoonlightProductMediaPort::setupVideo(
    const MoonlightCommonCVideoSelection& selection) noexcept {
    if (impl_ == nullptr ||
        !sameProfile(selection.profile, impl_->videoBinding.profile) ||
        selection.width != impl_->videoBinding.width ||
        selection.height != impl_->videoBinding.height ||
        selection.redrawRate <= 0) {
        return false;
    }
    std::lock_guard<std::mutex> lane(impl_->videoLifecycleLane);
    {
        std::lock_guard<std::mutex> lock(impl_->videoMutex);
        if (impl_->videoState != LaneState::Idle) {
            return false;
        }
    }

    const auto sinkStarted = impl_->videoSink->start(impl_->videoBinding);
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
        if (impl_->videoState != LaneState::Started ||
            decodeUnit.key != impl_->key ||
            !sameProfile(decodeUnit.profile, impl_->videoBinding.profile)) {
            return staleVideoResult();
        }
    }
    return impl_->videoBridge->submit(decodeUnit);
}

bool MoonlightProductMediaPort::setupAudio(
    const MoonlightCommonCAudioSelection& selection) noexcept {
    if (impl_ == nullptr || !audioLayoutReady(selection.layout)) {
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
            return false;
        }
        identity = {impl_->key, ++impl_->audioConfigurationGeneration};
        if (!impl_->nextAudioOperationLocked(configureOperation)) {
            return false;
        }
    }

    const auto configured = impl_->audioBridge->configure(
        identity, selection, configureOperation);
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
    if (submitted.status == MoonlightAudioSubmitStatus::Terminal) {
        std::lock_guard<std::mutex> lock(impl_->audioMutex);
        if (impl_->audioState == LaneState::Started) {
            impl_->audioState = LaneState::Failed;
        }
    }
}

} // namespace remotedesk::moonlight
