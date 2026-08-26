#ifndef REMOTEDESK_MOONLIGHT_AUDIO_BRIDGE_H
#define REMOTEDESK_MOONLIGHT_AUDIO_BRIDGE_H

#include "moonlight/media/MoonlightCommonCAdapter.h"

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <memory>

#if defined(__GNUC__) || defined(__clang__)
#define REMOTEDESK_MOONLIGHT_AUDIO_HIDDEN __attribute__((visibility("hidden")))
#else
#define REMOTEDESK_MOONLIGHT_AUDIO_HIDDEN
#endif

namespace remotedesk::moonlight {

constexpr std::size_t kMoonlightMaximumAudioPacketBytes = 1400U;
constexpr std::size_t kMoonlightMaximumAudioFrames = 5760U;
constexpr std::size_t kMoonlightStereoChannels = 2U;
constexpr std::size_t kMoonlightMaximumAudioPcmBytes =
    kMoonlightMaximumAudioFrames * kMoonlightStereoChannels * sizeof(std::int16_t);

struct REMOTEDESK_MOONLIGHT_AUDIO_HIDDEN MoonlightAudioStreamIdentity final {
    MoonlightSessionKey key {};
    std::uint64_t configurationGeneration = 0U;

    constexpr bool valid() const noexcept {
        return key.valid() && configurationGeneration != 0U;
    }
};

REMOTEDESK_MOONLIGHT_AUDIO_HIDDEN constexpr bool operator==(
    const MoonlightAudioStreamIdentity& left,
    const MoonlightAudioStreamIdentity& right) noexcept {
    return left.key == right.key &&
        left.configurationGeneration == right.configurationGeneration;
}

REMOTEDESK_MOONLIGHT_AUDIO_HIDDEN constexpr bool operator!=(
    const MoonlightAudioStreamIdentity& left,
    const MoonlightAudioStreamIdentity& right) noexcept {
    return !(left == right);
}

enum class MoonlightAudioDecoderConfigureStatus : std::uint8_t {
    Ready,
    Unsupported,
    Failed,
};

enum class MoonlightAudioDecodeStatus : std::uint8_t {
    Decoded,
    Malformed,
    Failed,
    InvalidFrameCount,
    Terminal,
};

struct REMOTEDESK_MOONLIGHT_AUDIO_HIDDEN MoonlightAudioDecodeResult final {
    MoonlightAudioDecodeStatus status = MoonlightAudioDecodeStatus::Failed;
    std::size_t decodedFrames = 0U;
};

class REMOTEDESK_MOONLIGHT_AUDIO_HIDDEN MoonlightAudioDecoderPort {
public:
    virtual ~MoonlightAudioDecoderPort() = default;
    virtual MoonlightAudioDecoderConfigureStatus configure(
        const MoonlightCommonCAudioSelection& selection) noexcept = 0;
    virtual MoonlightAudioDecodeResult decode(
        const std::uint8_t* packet, std::size_t packetBytes, bool plc,
        std::int16_t* pcm, std::size_t frameCapacity) noexcept = 0;
    virtual void destroy() noexcept = 0;
};

class REMOTEDESK_MOONLIGHT_AUDIO_HIDDEN MoonlightAudioPcmSink {
public:
    virtual ~MoonlightAudioPcmSink() = default;
    // The little-endian PCM view is borrowed only for this synchronous call.
    virtual bool submit(const MoonlightAudioStreamIdentity& identity,
                        const std::uint8_t* pcm, std::size_t pcmBytes,
                        std::size_t decodedFrames, bool plc) noexcept = 0;
};

enum class MoonlightAudioBridgeState : std::uint8_t {
    Idle,
    Configured,
    Started,
    Stopping,
    Stopped,
    Cleaned,
    Failed,
};

enum class MoonlightAudioConfigureStatus : std::uint8_t {
    Configured,
    Unsupported,
    InvalidRequest,
    Busy,
    Stale,
    AlreadyConfigured,
    DecoderFailure,
};

struct REMOTEDESK_MOONLIGHT_AUDIO_HIDDEN MoonlightAudioConfigureResult final {
    MoonlightAudioConfigureStatus status = MoonlightAudioConfigureStatus::InvalidRequest;
    MoonlightAudioStreamIdentity identity {};
};

enum class MoonlightAudioStartStatus : std::uint8_t {
    Started,
    InvalidState,
    Stale,
    AlreadyStarted,
};

struct REMOTEDESK_MOONLIGHT_AUDIO_HIDDEN MoonlightAudioStartResult final {
    MoonlightAudioStartStatus status = MoonlightAudioStartStatus::InvalidState;
    MoonlightAudioStreamIdentity identity {};
};

enum class MoonlightAudioSubmitStatus : std::uint8_t {
    Accepted,
    PlcAccepted,
    Backpressure,
    Malformed,
    Unsupported,
    Stale,
    InvalidState,
    SinkRejected,
    DecodeFailed,
    Terminal,
};

struct REMOTEDESK_MOONLIGHT_AUDIO_HIDDEN MoonlightAudioSubmitResult final {
    MoonlightAudioSubmitStatus status = MoonlightAudioSubmitStatus::InvalidState;
    MoonlightAudioStreamIdentity identity {};
    std::uint64_t operationGeneration = 0U;
    std::size_t inputBytes = 0U;
    std::size_t decodedFrames = 0U;
    std::size_t pcmBytes = 0U;
    bool plc = false;
    bool decoderCalled = false;
    bool sinkCalled = false;
};

enum class MoonlightAudioStopStatus : std::uint8_t {
    Stopped,
    AlreadyStopped,
    InvalidState,
    Stale,
    TimedOut,
};

struct REMOTEDESK_MOONLIGHT_AUDIO_HIDDEN MoonlightAudioStopResult final {
    MoonlightAudioStopStatus status = MoonlightAudioStopStatus::InvalidState;
    MoonlightAudioStreamIdentity identity {};
};

enum class MoonlightAudioCleanupStatus : std::uint8_t {
    Cleaned,
    AlreadyCleaned,
    InvalidState,
    Stale,
    TimedOut,
};

struct REMOTEDESK_MOONLIGHT_AUDIO_HIDDEN MoonlightAudioCleanupResult final {
    MoonlightAudioCleanupStatus status = MoonlightAudioCleanupStatus::InvalidState;
    MoonlightAudioStreamIdentity identity {};
};

struct REMOTEDESK_MOONLIGHT_AUDIO_HIDDEN MoonlightAudioBridgeSnapshot final {
    bool matched = false;
    MoonlightAudioStreamIdentity identity {};
    MoonlightAudioBridgeState state = MoonlightAudioBridgeState::Idle;
    std::uint64_t lastOperationGeneration = 0U;
    std::uint64_t acceptedPackets = 0U;
    std::uint64_t acceptedPlcFrames = 0U;
    std::uint64_t rejectedPackets = 0U;
    std::size_t inFlightSubmits = 0U;
    std::size_t retainedPacketBytes = 0U;
    std::size_t retainedPcmBytes = 0U;
    bool packetScratchZeroized = true;
    bool pcmScratchZeroized = true;
};

class REMOTEDESK_MOONLIGHT_AUDIO_HIDDEN MoonlightAudioBridge final {
private:
    struct Impl;
    explicit MoonlightAudioBridge(std::unique_ptr<Impl> impl) noexcept;

public:
    ~MoonlightAudioBridge();
    MoonlightAudioBridge(const MoonlightAudioBridge&) = delete;
    MoonlightAudioBridge& operator=(const MoonlightAudioBridge&) = delete;

    static std::unique_ptr<MoonlightAudioBridge> createForTesting(
        std::shared_ptr<MoonlightAudioDecoderPort> decoder,
        std::shared_ptr<MoonlightAudioPcmSink> sink) noexcept;
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    static std::unique_ptr<MoonlightAudioBridge> createWithPlatformDecoderForTesting(
        std::shared_ptr<MoonlightAudioPcmSink> sink) noexcept;
    static const char* platformDecoderVersionForTesting() noexcept;
#endif

    MoonlightAudioConfigureResult configure(
        const MoonlightAudioStreamIdentity& identity,
        const MoonlightCommonCAudioSelection& selection,
        std::uint64_t operationGeneration) noexcept;
    MoonlightAudioStartResult start(
        const MoonlightAudioStreamIdentity& identity,
        std::uint64_t operationGeneration) noexcept;
    MoonlightAudioSubmitResult submit(
        const MoonlightAudioStreamIdentity& identity,
        std::uint64_t operationGeneration,
        const std::uint8_t* packet,
        std::size_t packetBytes) noexcept;
    MoonlightAudioStopResult stop(
        const MoonlightAudioStreamIdentity& identity,
        std::uint64_t operationGeneration,
        std::chrono::milliseconds timeout) noexcept;
    MoonlightAudioCleanupResult cleanup(
        const MoonlightAudioStreamIdentity& identity,
        std::uint64_t operationGeneration,
        std::chrono::milliseconds timeout) noexcept;
    MoonlightAudioBridgeSnapshot snapshot(
        const MoonlightAudioStreamIdentity& identity) const noexcept;

    // Build-only OHOS probe. No product/NAPI caller references this symbol.
    static int productionLinkSmoke() noexcept;

private:
    std::unique_ptr<Impl> impl_;
};

// Product Opus decoder port. It reuses the single pinned libopus artifact and
// owns only the decoder state for one Moonlight audio configuration.
REMOTEDESK_MOONLIGHT_AUDIO_HIDDEN
std::shared_ptr<MoonlightAudioDecoderPort> createMoonlightOpusDecoderPort();

} // namespace remotedesk::moonlight

#endif // REMOTEDESK_MOONLIGHT_AUDIO_BRIDGE_H
