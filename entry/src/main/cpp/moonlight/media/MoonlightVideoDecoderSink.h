#ifndef REMOTEDESK_MOONLIGHT_VIDEO_DECODER_SINK_H
#define REMOTEDESK_MOONLIGHT_VIDEO_DECODER_SINK_H

#include "moonlight/media/MoonlightVideoBridge.h"

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <memory>

#if defined(__GNUC__) || defined(__clang__)
#define REMOTEDESK_MOONLIGHT_DECODER_HIDDEN __attribute__((visibility("hidden")))
#else
#define REMOTEDESK_MOONLIGHT_DECODER_HIDDEN
#endif

namespace remotedesk::moonlight {

struct REMOTEDESK_MOONLIGHT_DECODER_HIDDEN MoonlightVideoDecoderRuntimeProof final {
    std::uint64_t generation = 0U;
    bool h264HardwareDecode = false;
    bool nativeImageSurface = false;
    bool rendererPresentationAck = false;

    bool valid() const noexcept {
        return generation != 0U && h264HardwareDecode && nativeImageSurface &&
            rendererPresentationAck;
    }
};

struct REMOTEDESK_MOONLIGHT_DECODER_HIDDEN MoonlightVideoDecoderBinding final {
    MoonlightSessionKey key {};
    MoonlightStreamCodecProfile profile {};
    std::int32_t width = 0;
    std::int32_t height = 0;
    std::int32_t display = -1;
    std::int64_t decoderHandle = 0;
    std::int64_t rendererHandle = 0;
    std::uint64_t decoderGeneration = 0U;
    std::uint64_t displayGeneration = 0U;
    std::uint64_t rendererGeneration = 0U;
    bool ownsDecoderHandle = false;
    MoonlightVideoDecoderRuntimeProof runtimeProof {};
};

REMOTEDESK_MOONLIGHT_DECODER_HIDDEN bool operator==(
    const MoonlightVideoDecoderBinding& left,
    const MoonlightVideoDecoderBinding& right) noexcept;
REMOTEDESK_MOONLIGHT_DECODER_HIDDEN bool operator!=(
    const MoonlightVideoDecoderBinding& left,
    const MoonlightVideoDecoderBinding& right) noexcept;

enum class MoonlightDecoderPortStartStatus : std::uint8_t {
    Started,
    RuntimeProofRequired,
    Unsupported,
    Stale,
    Busy,
    Failed,
};

enum class MoonlightDecoderPortSubmitStatus : std::uint8_t {
    Accepted,
    AcceptedNeedsIdr,
    Backpressure,
    NeedIdr,
    Stale,
    Unsupported,
    Failed,
};

enum class MoonlightDecoderPortSuspendStatus : std::uint8_t {
    Suspended,
    AlreadySuspended,
    Stale,
    TimedOut,
    Failed,
};

enum class MoonlightDecoderPortRebindStatus : std::uint8_t {
    Rebound,
    RuntimeProofRequired,
    Unsupported,
    Stale,
    Busy,
    Failed,
};

struct REMOTEDESK_MOONLIGHT_DECODER_HIDDEN MoonlightDecoderPortSubmitResult final {
    MoonlightDecoderPortSubmitStatus status =
        MoonlightDecoderPortSubmitStatus::Failed;
    // A successful codec recreation keeps the registry handle and session
    // owner but allocates a new decoder callback generation. The port must
    // return that exact binding atomically with Accepted; no caller may infer
    // a generation from a generic success code.
    bool bindingChanged = false;
    MoonlightVideoDecoderBinding binding {};
};

enum class MoonlightDecoderGenerationHandoff : std::uint8_t {
    Unchanged,
    Advanced,
    Stale,
};

/**
 * Classifies the decoder generation observed after an accepted IDR.
 *
 * A recovery rebuild keeps the registry handle and owner but advances the
 * callback generation.  The caller must adopt that exact generation before
 * admitting the next predicted frame.  Codec-configuration recovery requires
 * an advance; a regular IDR may legitimately retain the current generation.
 */
constexpr MoonlightDecoderGenerationHandoff
classifyMoonlightDecoderGenerationHandoff(
    bool stableTelemetry, std::uint64_t requestedGeneration,
    std::uint64_t observedGeneration, bool advanceRequired) noexcept {
    if (!stableTelemetry || requestedGeneration == 0U ||
        observedGeneration < requestedGeneration ||
        (advanceRequired && observedGeneration == requestedGeneration)) {
        return MoonlightDecoderGenerationHandoff::Stale;
    }
    return observedGeneration > requestedGeneration
        ? MoonlightDecoderGenerationHandoff::Advanced
        : MoonlightDecoderGenerationHandoff::Unchanged;
}

enum class MoonlightDecoderPortStopStatus : std::uint8_t {
    Stopped,
    AlreadyStopped,
    Stale,
    TimedOut,
    Failed,
};

struct REMOTEDESK_MOONLIGHT_DECODER_HIDDEN MoonlightDecoderPresentationSnapshot final {
    bool matched = false;
    bool running = false;
    MoonlightVideoDecoderBinding binding {};
    std::uint64_t decoderGeneration = 0U;
    std::uint64_t rendererGeneration = 0U;
    std::uint64_t renderedOutputBuffers = 0U;
    std::uint64_t nativeImageFrames = 0U;
    std::uint64_t rendererPresentedFrames = 0U;
    std::size_t decoderQueueDepth = 0U;
    std::uint64_t decoderInputDroppedFrames = 0U;
    std::uint64_t decoderWaitKeyframeDrops = 0U;
    std::uint64_t decoderInputTruncated = 0U;
    std::uint64_t decoderRenderOutputFailures = 0U;
    std::uint64_t decoderSurfaceUpdateFailures = 0U;
    std::uint64_t decoderSurfaceCoalescedNotifications = 0U;
    std::int64_t decoderCodecLatencyMs = 0;
    std::int64_t decoderCodecLatencyMaxMs = 0;
    bool decoderLowLatencyEnabled = false;
};

class REMOTEDESK_MOONLIGHT_DECODER_HIDDEN MoonlightOwnedDecoderPort {
public:
    virtual ~MoonlightOwnedDecoderPort() = default;
    virtual MoonlightDecoderPortStartStatus start(
        const MoonlightVideoDecoderBinding& binding) = 0;
    // The implementation must copy accessUnit bytes before this call returns
    // if it retains encoded data beyond the synchronous boundary.
    virtual MoonlightDecoderPortSubmitResult submit(
        const MoonlightVideoDecoderBinding& binding,
        std::shared_ptr<const MoonlightOwnedVideoAccessUnit> accessUnit) = 0;
    virtual MoonlightDecoderPortSuspendStatus suspend(
        const MoonlightVideoDecoderBinding& binding,
        std::chrono::milliseconds timeout) = 0;
    virtual MoonlightDecoderPortRebindStatus rebind(
        const MoonlightVideoDecoderBinding& current,
        const MoonlightVideoDecoderBinding& next) = 0;
    virtual MoonlightDecoderPortStopStatus stop(
        const MoonlightVideoDecoderBinding& binding,
        std::chrono::milliseconds timeout) = 0;
    virtual MoonlightDecoderPresentationSnapshot snapshot(
        const MoonlightVideoDecoderBinding& binding) = 0;
};

enum class MoonlightVideoDecoderStartStatus : std::uint8_t {
    Started,
    InvalidRequest,
    RuntimeProofRequired,
    Unsupported,
    Stale,
    Busy,
    PortFailure,
};

struct REMOTEDESK_MOONLIGHT_DECODER_HIDDEN MoonlightVideoDecoderStartResult final {
    MoonlightVideoDecoderStartStatus status =
        MoonlightVideoDecoderStartStatus::InvalidRequest;
    MoonlightSessionKey key {};
};

enum class MoonlightVideoDecoderStopStatus : std::uint8_t {
    Stopped,
    AlreadyStopped,
    Stale,
    TimedOut,
    PortFailure,
};

enum class MoonlightVideoDecoderSuspendStatus : std::uint8_t {
    Suspended,
    AlreadySuspended,
    Stale,
    TimedOut,
    PortFailure,
};

enum class MoonlightVideoDecoderRebindStatus : std::uint8_t {
    Rebound,
    InvalidRequest,
    RuntimeProofRequired,
    Unsupported,
    Stale,
    Busy,
    PortFailure,
};

struct REMOTEDESK_MOONLIGHT_DECODER_HIDDEN MoonlightVideoDecoderSnapshot final {
    bool matched = false;
    bool running = false;
    bool admissionOpen = false;
    bool suspended = false;
    bool waitingForIdr = false;
    bool firstFrameReady = false;
    MoonlightVideoDecoderBinding binding {};
    std::size_t inFlightSubmissions = 0U;
    std::uint64_t renderedOutputBuffers = 0U;
    std::uint64_t nativeImageFrames = 0U;
    std::uint64_t rendererPresentedFrames = 0U;
    std::size_t decoderQueueDepth = 0U;
    std::uint64_t decoderInputDroppedFrames = 0U;
    std::uint64_t decoderWaitKeyframeDrops = 0U;
    std::uint64_t decoderInputTruncated = 0U;
    std::uint64_t decoderRenderOutputFailures = 0U;
    std::uint64_t decoderSurfaceUpdateFailures = 0U;
    std::uint64_t decoderSurfaceCoalescedNotifications = 0U;
    std::int64_t decoderCodecLatencyMs = 0;
    std::int64_t decoderCodecLatencyMaxMs = 0;
    bool decoderLowLatencyEnabled = false;
};

class REMOTEDESK_MOONLIGHT_DECODER_HIDDEN MoonlightOwnedVideoDecoderSink final
    : public MoonlightVideoDecoderSink {
private:
    struct Impl;

public:
    static std::unique_ptr<MoonlightOwnedVideoDecoderSink> create(
        std::shared_ptr<MoonlightOwnedDecoderPort> port);
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    static std::unique_ptr<MoonlightOwnedVideoDecoderSink> createForTesting(
        std::shared_ptr<MoonlightOwnedDecoderPort> port);
#endif

    ~MoonlightOwnedVideoDecoderSink() override;
    MoonlightOwnedVideoDecoderSink(const MoonlightOwnedVideoDecoderSink&) = delete;
    MoonlightOwnedVideoDecoderSink& operator=(
        const MoonlightOwnedVideoDecoderSink&) = delete;

    MoonlightVideoDecoderStartResult start(
        const MoonlightVideoDecoderBinding& binding) noexcept;
    bool available(const MoonlightStreamCodecProfile& profile) override;
    MoonlightVideoSinkStatus submit(
        std::shared_ptr<const MoonlightOwnedVideoAccessUnit> accessUnit) override;
    MoonlightVideoDecoderSuspendStatus suspend(
        const MoonlightSessionKey& key,
        std::chrono::milliseconds timeout = std::chrono::seconds(5)) noexcept;
    MoonlightVideoDecoderRebindStatus rebind(
        const MoonlightVideoDecoderBinding& binding) noexcept;
    MoonlightVideoDecoderStopStatus stop(
        const MoonlightSessionKey& key,
        std::chrono::milliseconds timeout = std::chrono::seconds(5)) noexcept;
    MoonlightVideoDecoderSnapshot snapshot(
        const MoonlightSessionKey& key) const noexcept;

private:
    explicit MoonlightOwnedVideoDecoderSink(std::unique_ptr<Impl> impl);
    std::unique_ptr<Impl> impl_;
};

// Product implementation is compiled only for the OHOS target. It never
// creates or selects an owner; start() succeeds only for an already-active,
// exact-generation decoder/renderer binding and explicit runtime proof.
REMOTEDESK_MOONLIGHT_DECODER_HIDDEN
std::shared_ptr<MoonlightOwnedDecoderPort> createMoonlightHardwareDecoderPort();

} // namespace remotedesk::moonlight

#undef REMOTEDESK_MOONLIGHT_DECODER_HIDDEN

#endif // REMOTEDESK_MOONLIGHT_VIDEO_DECODER_SINK_H
