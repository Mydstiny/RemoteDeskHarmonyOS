#include "moonlight/media/MoonlightAudioBridge.h"

#include <algorithm>
#include <array>
#include <condition_variable>
#include <cstring>
#include <limits>
#include <mutex>
#include <utility>

namespace remotedesk::moonlight {
namespace {

void secureWipe(void* pointer, std::size_t size) noexcept {
    auto* bytes = static_cast<volatile std::uint8_t*>(pointer);
    while (bytes != nullptr && size > 0U) {
        *bytes++ = 0U;
        --size;
    }
}

template <typename T, std::size_t Size>
bool allZero(const std::array<T, Size>& values) noexcept {
    const auto* bytes = reinterpret_cast<const std::uint8_t*>(values.data());
    return std::all_of(bytes, bytes + sizeof(values),
                       [](std::uint8_t value) { return value == 0U; });
}

void saturatingIncrement(std::uint64_t& value) noexcept {
    if (value != std::numeric_limits<std::uint64_t>::max()) {
        ++value;
    }
}

bool exactStereoSelection(const MoonlightCommonCAudioSelection& selection) noexcept {
    const auto& opus = selection.opus;
    return selection.layout == MoonlightStreamAudioLayout::Stereo &&
        opus.sampleRate == 48000 && opus.channelCount == 2 &&
        opus.streams == 1 && opus.coupledStreams == 1 &&
        opus.samplesPerFrame >= 120 && opus.samplesPerFrame <= 5760 &&
        (opus.samplesPerFrame % 120) == 0 &&
        opus.mapping[0] == 0U && opus.mapping[1] == 1U &&
        std::all_of(opus.mapping.begin() + 2, opus.mapping.end(),
                    [](std::uint8_t value) { return value == 0U; });
}

bool sameSelection(const MoonlightCommonCAudioSelection& left,
                   const MoonlightCommonCAudioSelection& right) noexcept {
    return left.layout == right.layout &&
        left.opus.sampleRate == right.opus.sampleRate &&
        left.opus.channelCount == right.opus.channelCount &&
        left.opus.streams == right.opus.streams &&
        left.opus.coupledStreams == right.opus.coupledStreams &&
        left.opus.samplesPerFrame == right.opus.samplesPerFrame &&
        left.opus.mapping == right.opus.mapping;
}

} // namespace

struct MoonlightAudioBridge::Impl final {
    Impl(std::shared_ptr<MoonlightAudioDecoderPort> decoderValue,
         std::shared_ptr<MoonlightAudioPcmSink> sinkValue) noexcept
        : decoder(std::move(decoderValue)), sink(std::move(sinkValue)) {}

    void wipeScratchLocked() noexcept {
        secureWipe(packetScratch.data(), sizeof(packetScratch));
        secureWipe(decodedScratch.data(), sizeof(decodedScratch));
        secureWipe(pcmScratch.data(), sizeof(pcmScratch));
        retainedPacketBytes = 0U;
        retainedPcmBytes = 0U;
    }

    void resetSessionLocked() noexcept {
        secureWipe(&selection, sizeof(selection));
        identity = {};
        lastOperationGeneration = 0U;
        acceptedPackets = 0U;
        acceptedPlcFrames = 0U;
        rejectedPackets = 0U;
        admissionOpen = false;
        inFlight = false;
        wipeScratchLocked();
    }

    mutable std::mutex mutex;
    std::condition_variable drained;
    std::shared_ptr<MoonlightAudioDecoderPort> decoder;
    std::shared_ptr<MoonlightAudioPcmSink> sink;
    MoonlightAudioStreamIdentity identity {};
    MoonlightAudioStreamIdentity lastCleanedIdentity {};
    MoonlightCommonCAudioSelection selection {};
    MoonlightAudioBridgeState state = MoonlightAudioBridgeState::Idle;
    std::uint64_t ownerTokenHighWater = 0U;
    std::uint64_t lastOperationGeneration = 0U;
    std::uint64_t lastCleanupOperationGeneration = 0U;
    std::uint64_t acceptedPackets = 0U;
    std::uint64_t acceptedPlcFrames = 0U;
    std::uint64_t rejectedPackets = 0U;
    bool admissionOpen = false;
    bool inFlight = false;
    std::size_t retainedPacketBytes = 0U;
    std::size_t retainedPcmBytes = 0U;
    std::array<std::uint8_t, kMoonlightMaximumAudioPacketBytes> packetScratch {};
    std::array<std::int16_t,
               kMoonlightMaximumAudioFrames * kMoonlightStereoChannels> decodedScratch {};
    std::array<std::uint8_t, kMoonlightMaximumAudioPcmBytes> pcmScratch {};
};

MoonlightAudioBridge::MoonlightAudioBridge(std::unique_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}

MoonlightAudioBridge::~MoonlightAudioBridge() {
    if (!impl_) {
        return;
    }
    std::unique_lock<std::mutex> lock(impl_->mutex);
    impl_->admissionOpen = false;
    impl_->drained.wait(lock, [&]() { return !impl_->inFlight; });
    if (impl_->state == MoonlightAudioBridgeState::Configured ||
        impl_->state == MoonlightAudioBridgeState::Started ||
        impl_->state == MoonlightAudioBridgeState::Stopping ||
        impl_->state == MoonlightAudioBridgeState::Failed) {
        impl_->decoder->destroy();
    }
    impl_->wipeScratchLocked();
    secureWipe(&impl_->selection, sizeof(impl_->selection));
    impl_->identity = {};
    impl_->state = MoonlightAudioBridgeState::Cleaned;
}

std::unique_ptr<MoonlightAudioBridge> MoonlightAudioBridge::createForTesting(
    std::shared_ptr<MoonlightAudioDecoderPort> decoder,
    std::shared_ptr<MoonlightAudioPcmSink> sink) noexcept {
    if (!decoder || !sink) {
        return nullptr;
    }
    try {
        return std::unique_ptr<MoonlightAudioBridge>(new MoonlightAudioBridge(
            std::make_unique<Impl>(std::move(decoder), std::move(sink))));
    } catch (...) {
        return nullptr;
    }
}

MoonlightAudioConfigureResult MoonlightAudioBridge::configure(
    const MoonlightAudioStreamIdentity& identity,
    const MoonlightCommonCAudioSelection& selection,
    std::uint64_t operationGeneration) noexcept {
    MoonlightAudioConfigureResult result;
    result.identity = identity;
    if (!impl_ || !identity.valid() || operationGeneration == 0U) {
        result.status = MoonlightAudioConfigureStatus::InvalidRequest;
        return result;
    }
    if (!exactStereoSelection(selection)) {
        result.status = MoonlightAudioConfigureStatus::Unsupported;
        return result;
    }

    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->state == MoonlightAudioBridgeState::Configured &&
        impl_->identity == identity && sameSelection(impl_->selection, selection) &&
        operationGeneration == impl_->lastOperationGeneration) {
        result.status = MoonlightAudioConfigureStatus::AlreadyConfigured;
        return result;
    }
    if (impl_->state != MoonlightAudioBridgeState::Idle &&
        impl_->state != MoonlightAudioBridgeState::Cleaned) {
        result.status = MoonlightAudioConfigureStatus::Busy;
        return result;
    }
    if (identity.key.ownerToken <= impl_->ownerTokenHighWater) {
        result.status = MoonlightAudioConfigureStatus::Stale;
        return result;
    }

    const auto decoderStatus = impl_->decoder->configure(selection);
    if (decoderStatus != MoonlightAudioDecoderConfigureStatus::Ready) {
        impl_->decoder->destroy();
        result.status = decoderStatus == MoonlightAudioDecoderConfigureStatus::Unsupported
            ? MoonlightAudioConfigureStatus::Unsupported
            : MoonlightAudioConfigureStatus::DecoderFailure;
        return result;
    }

    impl_->identity = identity;
    impl_->lastCleanedIdentity = {};
    impl_->selection = selection;
    impl_->state = MoonlightAudioBridgeState::Configured;
    impl_->ownerTokenHighWater = identity.key.ownerToken;
    impl_->lastOperationGeneration = operationGeneration;
    impl_->lastCleanupOperationGeneration = 0U;
    impl_->acceptedPackets = 0U;
    impl_->acceptedPlcFrames = 0U;
    impl_->rejectedPackets = 0U;
    impl_->admissionOpen = false;
    impl_->inFlight = false;
    impl_->wipeScratchLocked();
    result.status = MoonlightAudioConfigureStatus::Configured;
    return result;
}

MoonlightAudioStartResult MoonlightAudioBridge::start(
    const MoonlightAudioStreamIdentity& identity,
    std::uint64_t operationGeneration) noexcept {
    MoonlightAudioStartResult result;
    result.identity = identity;
    if (!impl_ || !identity.valid() || operationGeneration == 0U) {
        return result;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->identity != identity) {
        result.status = MoonlightAudioStartStatus::Stale;
        return result;
    }
    if (impl_->state == MoonlightAudioBridgeState::Started &&
        operationGeneration == impl_->lastOperationGeneration) {
        result.status = MoonlightAudioStartStatus::AlreadyStarted;
        return result;
    }
    if (operationGeneration <= impl_->lastOperationGeneration) {
        result.status = MoonlightAudioStartStatus::Stale;
        return result;
    }
    if (impl_->state != MoonlightAudioBridgeState::Configured) {
        result.status = MoonlightAudioStartStatus::InvalidState;
        return result;
    }
    impl_->state = MoonlightAudioBridgeState::Started;
    impl_->admissionOpen = true;
    impl_->lastOperationGeneration = operationGeneration;
    result.status = MoonlightAudioStartStatus::Started;
    return result;
}

MoonlightAudioSubmitResult MoonlightAudioBridge::submit(
    const MoonlightAudioStreamIdentity& identity,
    std::uint64_t operationGeneration,
    const std::uint8_t* packet,
    std::size_t packetBytes) noexcept {
    MoonlightAudioSubmitResult result;
    result.identity = identity;
    result.operationGeneration = operationGeneration;
    result.inputBytes = packetBytes;
    result.plc = packet == nullptr && packetBytes == 0U;
    if (!impl_ || !identity.valid() || operationGeneration == 0U) {
        return result;
    }
    const bool packetShapeValid = result.plc ||
        (packet != nullptr && packetBytes > 0U &&
         packetBytes <= kMoonlightMaximumAudioPacketBytes);
    if (!packetShapeValid) {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        if (impl_->identity == identity) {
            saturatingIncrement(impl_->rejectedPackets);
        }
        result.status = MoonlightAudioSubmitStatus::Malformed;
        return result;
    }

    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        if (impl_->identity != identity) {
            result.status = MoonlightAudioSubmitStatus::Stale;
            return result;
        }
        if (operationGeneration <= impl_->lastOperationGeneration) {
            result.status = MoonlightAudioSubmitStatus::Stale;
            return result;
        }
        if (impl_->state != MoonlightAudioBridgeState::Started ||
            !impl_->admissionOpen) {
            result.status = MoonlightAudioSubmitStatus::InvalidState;
            return result;
        }
        if (impl_->inFlight) {
            result.status = MoonlightAudioSubmitStatus::Backpressure;
            return result;
        }
        impl_->wipeScratchLocked();
        if (!result.plc) {
            std::memcpy(impl_->packetScratch.data(), packet, packetBytes);
        }
        impl_->retainedPacketBytes = packetBytes;
        impl_->inFlight = true;
        impl_->lastOperationGeneration = operationGeneration;
    }

    const auto decodeResult = impl_->decoder->decode(
        result.plc ? nullptr : impl_->packetScratch.data(), packetBytes, result.plc,
        impl_->decodedScratch.data(),
        static_cast<std::size_t>(impl_->selection.opus.samplesPerFrame));
    result.decoderCalled = true;
    result.decodedFrames = decodeResult.decodedFrames;

    bool terminalFailure = false;
    if (decodeResult.status == MoonlightAudioDecodeStatus::Decoded &&
        decodeResult.decodedFrames > 0U &&
        decodeResult.decodedFrames <=
            static_cast<std::size_t>(impl_->selection.opus.samplesPerFrame)) {
        result.pcmBytes = decodeResult.decodedFrames * kMoonlightStereoChannels *
            sizeof(std::int16_t);
        for (std::size_t index = 0U;
             index < decodeResult.decodedFrames * kMoonlightStereoChannels; ++index) {
            const auto sample = static_cast<std::uint16_t>(impl_->decodedScratch[index]);
            impl_->pcmScratch[index * 2U] = static_cast<std::uint8_t>(sample & 0xffU);
            impl_->pcmScratch[index * 2U + 1U] =
                static_cast<std::uint8_t>((sample >> 8U) & 0xffU);
        }
        {
            std::lock_guard<std::mutex> lock(impl_->mutex);
            impl_->retainedPcmBytes = result.pcmBytes;
        }
        result.sinkCalled = true;
        const bool accepted = impl_->sink->submit(
            identity, impl_->pcmScratch.data(), result.pcmBytes,
            decodeResult.decodedFrames, result.plc);
        result.status = accepted
            ? (result.plc ? MoonlightAudioSubmitStatus::PlcAccepted
                          : MoonlightAudioSubmitStatus::Accepted)
            : MoonlightAudioSubmitStatus::SinkRejected;
    } else {
        switch (decodeResult.status) {
            case MoonlightAudioDecodeStatus::Malformed:
                result.status = MoonlightAudioSubmitStatus::Malformed;
                break;
            case MoonlightAudioDecodeStatus::Terminal:
                result.status = MoonlightAudioSubmitStatus::Terminal;
                terminalFailure = true;
                break;
            case MoonlightAudioDecodeStatus::Decoded:
            case MoonlightAudioDecodeStatus::Failed:
            case MoonlightAudioDecodeStatus::InvalidFrameCount:
                result.status = MoonlightAudioSubmitStatus::DecodeFailed;
                break;
        }
    }

    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        if (result.status == MoonlightAudioSubmitStatus::Accepted) {
            saturatingIncrement(impl_->acceptedPackets);
        } else if (result.status == MoonlightAudioSubmitStatus::PlcAccepted) {
            saturatingIncrement(impl_->acceptedPlcFrames);
        } else {
            saturatingIncrement(impl_->rejectedPackets);
        }
        if (terminalFailure && impl_->state == MoonlightAudioBridgeState::Started) {
            impl_->state = MoonlightAudioBridgeState::Failed;
            impl_->admissionOpen = false;
        }
        impl_->wipeScratchLocked();
        impl_->inFlight = false;
    }
    impl_->drained.notify_all();
    return result;
}

MoonlightAudioStopResult MoonlightAudioBridge::stop(
    const MoonlightAudioStreamIdentity& identity,
    std::uint64_t operationGeneration,
    std::chrono::milliseconds timeout) noexcept {
    MoonlightAudioStopResult result;
    result.identity = identity;
    if (!impl_ || !identity.valid() || operationGeneration == 0U || timeout.count() < 0) {
        return result;
    }
    std::unique_lock<std::mutex> lock(impl_->mutex);
    if (impl_->identity != identity) {
        result.status = MoonlightAudioStopStatus::Stale;
        return result;
    }
    if (impl_->state == MoonlightAudioBridgeState::Stopped) {
        result.status = operationGeneration == impl_->lastOperationGeneration
            ? MoonlightAudioStopStatus::AlreadyStopped
            : MoonlightAudioStopStatus::Stale;
        return result;
    }
    if (impl_->state == MoonlightAudioBridgeState::Stopping) {
        if (operationGeneration != impl_->lastOperationGeneration) {
            result.status = MoonlightAudioStopStatus::Stale;
            return result;
        }
    } else {
        if (operationGeneration <= impl_->lastOperationGeneration) {
            result.status = MoonlightAudioStopStatus::Stale;
            return result;
        }
        if (impl_->state != MoonlightAudioBridgeState::Started &&
            impl_->state != MoonlightAudioBridgeState::Configured &&
            impl_->state != MoonlightAudioBridgeState::Failed) {
            result.status = MoonlightAudioStopStatus::InvalidState;
            return result;
        }
        impl_->state = MoonlightAudioBridgeState::Stopping;
        impl_->admissionOpen = false;
        impl_->lastOperationGeneration = operationGeneration;
    }
    if (!impl_->drained.wait_for(lock, timeout, [&]() { return !impl_->inFlight; })) {
        result.status = MoonlightAudioStopStatus::TimedOut;
        return result;
    }
    impl_->decoder->destroy();
    impl_->wipeScratchLocked();
    impl_->state = MoonlightAudioBridgeState::Stopped;
    result.status = MoonlightAudioStopStatus::Stopped;
    return result;
}

MoonlightAudioCleanupResult MoonlightAudioBridge::cleanup(
    const MoonlightAudioStreamIdentity& identity,
    std::uint64_t operationGeneration,
    std::chrono::milliseconds timeout) noexcept {
    MoonlightAudioCleanupResult result;
    result.identity = identity;
    if (!impl_ || !identity.valid() || operationGeneration == 0U || timeout.count() < 0) {
        return result;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->state == MoonlightAudioBridgeState::Cleaned &&
        impl_->lastCleanedIdentity == identity &&
        impl_->lastCleanupOperationGeneration == operationGeneration) {
        result.status = MoonlightAudioCleanupStatus::AlreadyCleaned;
        return result;
    }
    if (impl_->identity != identity) {
        result.status = MoonlightAudioCleanupStatus::Stale;
        return result;
    }
    if (impl_->state == MoonlightAudioBridgeState::Stopping || impl_->inFlight) {
        result.status = MoonlightAudioCleanupStatus::TimedOut;
        return result;
    }
    if (impl_->state != MoonlightAudioBridgeState::Stopped) {
        result.status = MoonlightAudioCleanupStatus::InvalidState;
        return result;
    }
    if (operationGeneration <= impl_->lastOperationGeneration) {
        result.status = MoonlightAudioCleanupStatus::Stale;
        return result;
    }
    impl_->lastCleanedIdentity = identity;
    impl_->lastCleanupOperationGeneration = operationGeneration;
    impl_->resetSessionLocked();
    impl_->state = MoonlightAudioBridgeState::Cleaned;
    result.status = MoonlightAudioCleanupStatus::Cleaned;
    return result;
}

MoonlightAudioBridgeSnapshot MoonlightAudioBridge::snapshot(
    const MoonlightAudioStreamIdentity& identity) const noexcept {
    MoonlightAudioBridgeSnapshot result;
    if (!impl_) {
        return result;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    result.matched = impl_->identity == identity &&
        impl_->state != MoonlightAudioBridgeState::Cleaned;
    result.identity = result.matched ? impl_->identity : MoonlightAudioStreamIdentity {};
    result.state = impl_->state;
    result.lastOperationGeneration = result.matched
        ? impl_->lastOperationGeneration : 0U;
    result.acceptedPackets = result.matched ? impl_->acceptedPackets : 0U;
    result.acceptedPlcFrames = result.matched ? impl_->acceptedPlcFrames : 0U;
    result.rejectedPackets = result.matched ? impl_->rejectedPackets : 0U;
    result.inFlightSubmits = impl_->inFlight ? 1U : 0U;
    result.retainedPacketBytes = impl_->retainedPacketBytes;
    result.retainedPcmBytes = impl_->retainedPcmBytes;
    if (!impl_->inFlight) {
        result.packetScratchZeroized = allZero(impl_->packetScratch);
        result.pcmScratchZeroized = allZero(impl_->decodedScratch) &&
            allZero(impl_->pcmScratch);
    } else {
        result.packetScratchZeroized = false;
        result.pcmScratchZeroized = false;
    }
    return result;
}

} // namespace remotedesk::moonlight
