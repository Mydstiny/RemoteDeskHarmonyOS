#include "moonlight/media/MoonlightAudioPlayerSink.h"

#include <limits>
#include <mutex>
#include <utility>

namespace remotedesk::moonlight {
namespace {

Render::DecoderSessionIdentity decoderOwner(const MoonlightAudioStreamIdentity& identity) noexcept {
    return {identity.key.sessionId, identity.key.generation, identity.key.ownerToken};
}

std::uint64_t saturatingAdd(std::uint64_t value, std::uint64_t increment) noexcept {
    const std::uint64_t maximum = std::numeric_limits<std::uint64_t>::max();
    return increment > maximum - value ? maximum : value + increment;
}

MoonlightAudioPlayerControlResult controlResult(MoonlightAudioPlayerControlStatus status,
                                                const MoonlightAudioStreamIdentity& identity,
                                                std::uint64_t operationGeneration) noexcept {
    return {status, identity, operationGeneration};
}

} // namespace

struct MoonlightAudioPlayerSink::Impl final {
    explicit Impl(std::shared_ptr<MoonlightAudioPlayerPort> valuePort) noexcept
        : port(std::move(valuePort)) {}

    mutable std::mutex mutex;
    std::shared_ptr<MoonlightAudioPlayerPort> port;
    MoonlightAudioStreamIdentity identity{};
    MoonlightAudioStreamIdentity lastCleanedIdentity{};
    MoonlightAudioPlayerState state = MoonlightAudioPlayerState::Idle;
    MoonlightAudioPauseReason pauseReason = MoonlightAudioPauseReason::None;
    std::uint64_t lastOperationGeneration = 0U;
    std::uint64_t ownerTokenHighWater = 0U;
    std::uint64_t acceptedChunks = 0U;
    std::uint64_t acceptedBytes = 0U;
    std::uint64_t rejectedChunks = 0U;
};

MoonlightAudioPlayerSink::MoonlightAudioPlayerSink(std::unique_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}

MoonlightAudioPlayerSink::~MoonlightAudioPlayerSink() {
    if (impl_ == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if ((impl_->state == MoonlightAudioPlayerState::Active ||
         impl_->state == MoonlightAudioPlayerState::Paused) &&
        impl_->identity.valid() && impl_->port != nullptr) {
        (void)impl_->port->destroyAndFlush(decoderOwner(impl_->identity));
    }
    impl_->identity = {};
    impl_->pauseReason = MoonlightAudioPauseReason::None;
    impl_->state = MoonlightAudioPlayerState::Cleaned;
}

std::shared_ptr<MoonlightAudioPlayerSink> MoonlightAudioPlayerSink::createForTesting(
    std::shared_ptr<MoonlightAudioPlayerPort> port) noexcept {
    if (port == nullptr) {
        return nullptr;
    }
    try {
        return std::shared_ptr<MoonlightAudioPlayerSink>(
            new MoonlightAudioPlayerSink(std::make_unique<Impl>(std::move(port))));
    } catch (...) {
        return nullptr;
    }
}

MoonlightAudioPlayerControlResult
MoonlightAudioPlayerSink::activate(const MoonlightAudioStreamIdentity& requested,
                                   std::uint64_t operationGeneration) noexcept {
    if (impl_ == nullptr || !requested.valid() || operationGeneration == 0U) {
        return controlResult(MoonlightAudioPlayerControlStatus::InvalidRequest, requested,
                             operationGeneration);
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->identity == requested && (impl_->state == MoonlightAudioPlayerState::Active ||
                                         impl_->state == MoonlightAudioPlayerState::Paused)) {
        if (operationGeneration < impl_->lastOperationGeneration) {
            return controlResult(MoonlightAudioPlayerControlStatus::Stale, requested,
                                 operationGeneration);
        }
        impl_->lastOperationGeneration = operationGeneration;
        return controlResult(MoonlightAudioPlayerControlStatus::AlreadyApplied, requested,
                             operationGeneration);
    }
    if (impl_->state == MoonlightAudioPlayerState::Active ||
        impl_->state == MoonlightAudioPlayerState::Paused ||
        impl_->state == MoonlightAudioPlayerState::Stopped) {
        return controlResult(MoonlightAudioPlayerControlStatus::InvalidState, requested,
                             operationGeneration);
    }
    if (requested.key.ownerToken <= impl_->ownerTokenHighWater) {
        return controlResult(MoonlightAudioPlayerControlStatus::Stale, requested,
                             operationGeneration);
    }
    const Render::DecoderSessionIdentity owner = decoderOwner(requested);
    if (impl_->port == nullptr || !impl_->port->ownerReady(owner)) {
        return controlResult(MoonlightAudioPlayerControlStatus::Stale, requested,
                             operationGeneration);
    }
    impl_->identity = requested;
    impl_->state = MoonlightAudioPlayerState::Active;
    impl_->pauseReason = MoonlightAudioPauseReason::None;
    impl_->lastOperationGeneration = operationGeneration;
    impl_->ownerTokenHighWater = requested.key.ownerToken;
    impl_->acceptedChunks = 0U;
    impl_->acceptedBytes = 0U;
    impl_->rejectedChunks = 0U;
    return controlResult(MoonlightAudioPlayerControlStatus::Applied, requested,
                         operationGeneration);
}

MoonlightAudioPlayerControlResult
MoonlightAudioPlayerSink::pause(const MoonlightAudioStreamIdentity& requested,
                                std::uint64_t operationGeneration,
                                MoonlightAudioPauseReason reason) noexcept {
    if (impl_ == nullptr || !requested.valid() || operationGeneration == 0U ||
        reason == MoonlightAudioPauseReason::None) {
        return controlResult(MoonlightAudioPlayerControlStatus::InvalidRequest, requested,
                             operationGeneration);
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->identity != requested || operationGeneration < impl_->lastOperationGeneration) {
        return controlResult(MoonlightAudioPlayerControlStatus::Stale, requested,
                             operationGeneration);
    }
    if (impl_->state == MoonlightAudioPlayerState::Paused) {
        impl_->lastOperationGeneration = operationGeneration;
        impl_->pauseReason = reason;
        return controlResult(MoonlightAudioPlayerControlStatus::AlreadyApplied, requested,
                             operationGeneration);
    }
    if (impl_->state != MoonlightAudioPlayerState::Active) {
        return controlResult(MoonlightAudioPlayerControlStatus::InvalidState, requested,
                             operationGeneration);
    }
    if (operationGeneration == impl_->lastOperationGeneration) {
        return controlResult(MoonlightAudioPlayerControlStatus::Stale, requested,
                             operationGeneration);
    }
    const Render::DecoderSessionIdentity owner = decoderOwner(requested);
    if (impl_->port == nullptr || !impl_->port->ownerReady(owner)) {
        return controlResult(MoonlightAudioPlayerControlStatus::Stale, requested,
                             operationGeneration);
    }
    if (!impl_->port->suspendAndFlush(owner)) {
        return controlResult(MoonlightAudioPlayerControlStatus::PortFailure, requested,
                             operationGeneration);
    }
    impl_->state = MoonlightAudioPlayerState::Paused;
    impl_->pauseReason = reason;
    impl_->lastOperationGeneration = operationGeneration;
    return controlResult(MoonlightAudioPlayerControlStatus::Applied, requested,
                         operationGeneration);
}

MoonlightAudioPlayerControlResult
MoonlightAudioPlayerSink::resume(const MoonlightAudioStreamIdentity& requested,
                                 std::uint64_t operationGeneration) noexcept {
    if (impl_ == nullptr || !requested.valid() || operationGeneration == 0U) {
        return controlResult(MoonlightAudioPlayerControlStatus::InvalidRequest, requested,
                             operationGeneration);
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->identity != requested || operationGeneration < impl_->lastOperationGeneration) {
        return controlResult(MoonlightAudioPlayerControlStatus::Stale, requested,
                             operationGeneration);
    }
    if (impl_->state == MoonlightAudioPlayerState::Active) {
        impl_->lastOperationGeneration = operationGeneration;
        return controlResult(MoonlightAudioPlayerControlStatus::AlreadyApplied, requested,
                             operationGeneration);
    }
    if (impl_->state != MoonlightAudioPlayerState::Paused) {
        return controlResult(MoonlightAudioPlayerControlStatus::InvalidState, requested,
                             operationGeneration);
    }
    if (operationGeneration == impl_->lastOperationGeneration) {
        return controlResult(MoonlightAudioPlayerControlStatus::Stale, requested,
                             operationGeneration);
    }
    if (impl_->port == nullptr || !impl_->port->ownerReady(decoderOwner(requested))) {
        return controlResult(MoonlightAudioPlayerControlStatus::Stale, requested,
                             operationGeneration);
    }
    // The shared player's suspend path already cleared its queue. Its next
    // Write restarts that same renderer only after the existing prebuffer is
    // ready; no second queue or resume worker is introduced here.
    impl_->state = MoonlightAudioPlayerState::Active;
    impl_->pauseReason = MoonlightAudioPauseReason::None;
    impl_->lastOperationGeneration = operationGeneration;
    return controlResult(MoonlightAudioPlayerControlStatus::Applied, requested,
                         operationGeneration);
}

MoonlightAudioPlayerControlResult
MoonlightAudioPlayerSink::stop(const MoonlightAudioStreamIdentity& requested,
                               std::uint64_t operationGeneration) noexcept {
    if (impl_ == nullptr || !requested.valid() || operationGeneration == 0U) {
        return controlResult(MoonlightAudioPlayerControlStatus::InvalidRequest, requested,
                             operationGeneration);
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->identity != requested || operationGeneration < impl_->lastOperationGeneration) {
        return controlResult(MoonlightAudioPlayerControlStatus::Stale, requested,
                             operationGeneration);
    }
    if (impl_->state == MoonlightAudioPlayerState::Stopped) {
        impl_->lastOperationGeneration = operationGeneration;
        return controlResult(MoonlightAudioPlayerControlStatus::AlreadyApplied, requested,
                             operationGeneration);
    }
    if (impl_->state != MoonlightAudioPlayerState::Active &&
        impl_->state != MoonlightAudioPlayerState::Paused) {
        return controlResult(MoonlightAudioPlayerControlStatus::InvalidState, requested,
                             operationGeneration);
    }
    if (operationGeneration == impl_->lastOperationGeneration) {
        return controlResult(MoonlightAudioPlayerControlStatus::Stale, requested,
                             operationGeneration);
    }
    if (impl_->port == nullptr || !impl_->port->destroyAndFlush(decoderOwner(requested))) {
        return controlResult(MoonlightAudioPlayerControlStatus::PortFailure, requested,
                             operationGeneration);
    }
    impl_->state = MoonlightAudioPlayerState::Stopped;
    impl_->pauseReason = MoonlightAudioPauseReason::None;
    impl_->lastOperationGeneration = operationGeneration;
    return controlResult(MoonlightAudioPlayerControlStatus::Applied, requested,
                         operationGeneration);
}

MoonlightAudioPlayerControlResult
MoonlightAudioPlayerSink::cleanup(const MoonlightAudioStreamIdentity& requested,
                                  std::uint64_t operationGeneration) noexcept {
    if (impl_ == nullptr || !requested.valid() || operationGeneration == 0U) {
        return controlResult(MoonlightAudioPlayerControlStatus::InvalidRequest, requested,
                             operationGeneration);
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->identity != requested) {
        if (impl_->state == MoonlightAudioPlayerState::Cleaned &&
            requested == impl_->lastCleanedIdentity) {
            if (operationGeneration < impl_->lastOperationGeneration) {
                return controlResult(MoonlightAudioPlayerControlStatus::Stale, requested,
                                     operationGeneration);
            }
            impl_->lastOperationGeneration = operationGeneration;
            return controlResult(MoonlightAudioPlayerControlStatus::AlreadyApplied, requested,
                                 operationGeneration);
        }
        return controlResult(MoonlightAudioPlayerControlStatus::Stale, requested,
                             operationGeneration);
    }
    if (operationGeneration < impl_->lastOperationGeneration) {
        return controlResult(MoonlightAudioPlayerControlStatus::Stale, requested,
                             operationGeneration);
    }
    if (impl_->state != MoonlightAudioPlayerState::Stopped) {
        return controlResult(MoonlightAudioPlayerControlStatus::InvalidState, requested,
                             operationGeneration);
    }
    if (operationGeneration == impl_->lastOperationGeneration) {
        return controlResult(MoonlightAudioPlayerControlStatus::Stale, requested,
                             operationGeneration);
    }
    impl_->lastCleanedIdentity = impl_->identity;
    impl_->identity = {};
    impl_->state = MoonlightAudioPlayerState::Cleaned;
    impl_->pauseReason = MoonlightAudioPauseReason::None;
    impl_->lastOperationGeneration = operationGeneration;
    return controlResult(MoonlightAudioPlayerControlStatus::Applied, requested,
                         operationGeneration);
}

bool MoonlightAudioPlayerSink::submit(const MoonlightAudioStreamIdentity& requested,
                                      const std::uint8_t* pcm, std::size_t pcmBytes,
                                      std::size_t decodedFrames, bool /*plc*/) noexcept {
    if (impl_ == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const bool validPcm =
        pcm != nullptr && decodedFrames > 0U && decodedFrames <= kMoonlightMaximumAudioFrames &&
        pcmBytes == decodedFrames * kMoonlightStereoChannels * sizeof(std::int16_t) &&
        pcmBytes <= kMoonlightMaximumAudioPcmBytes;
    if (impl_->identity != requested || impl_->state != MoonlightAudioPlayerState::Active ||
        !validPcm || impl_->port == nullptr) {
        impl_->rejectedChunks = saturatingAdd(impl_->rejectedChunks, 1U);
        return false;
    }
    const Render::DecoderSessionIdentity owner = decoderOwner(requested);
    if (!impl_->port->ownerReady(owner)) {
        impl_->rejectedChunks = saturatingAdd(impl_->rejectedChunks, 1U);
        return false;
    }
    const int dispatched = impl_->port->submit(owner, pcm, pcmBytes, 48000,
                                               static_cast<int>(kMoonlightStereoChannels));
    // Zero is the existing muted-drop result; a full write is queued. Partial
    // positive writes and negative errors are rejected but remain retriable.
    if (dispatched < 0 || (dispatched != 0 && static_cast<std::size_t>(dispatched) != pcmBytes)) {
        impl_->rejectedChunks = saturatingAdd(impl_->rejectedChunks, 1U);
        return false;
    }
    impl_->acceptedChunks = saturatingAdd(impl_->acceptedChunks, 1U);
    impl_->acceptedBytes =
        saturatingAdd(impl_->acceptedBytes, static_cast<std::uint64_t>(pcmBytes));
    return true;
}

MoonlightAudioPlayerSnapshot
MoonlightAudioPlayerSink::snapshot(const MoonlightAudioStreamIdentity& requested) const noexcept {
    MoonlightAudioPlayerSnapshot result;
    if (impl_ == nullptr) {
        return result;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    result.matched = impl_->identity == requested && requested.valid();
    result.identity = result.matched ? impl_->identity : MoonlightAudioStreamIdentity{};
    result.state = impl_->state;
    result.pauseReason = impl_->pauseReason;
    result.lastOperationGeneration = impl_->lastOperationGeneration;
    result.acceptedChunks = impl_->acceptedChunks;
    result.acceptedBytes = impl_->acceptedBytes;
    result.rejectedChunks = impl_->rejectedChunks;
    result.ownerReady = result.matched && impl_->port != nullptr &&
                        impl_->port->ownerReady(decoderOwner(impl_->identity));
    return result;
}

} // namespace remotedesk::moonlight
