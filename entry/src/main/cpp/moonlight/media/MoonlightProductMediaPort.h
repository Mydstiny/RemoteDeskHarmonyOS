#ifndef REMOTEDESK_MOONLIGHT_PRODUCT_MEDIA_PORT_H
#define REMOTEDESK_MOONLIGHT_PRODUCT_MEDIA_PORT_H

#include "moonlight/media/MoonlightAudioPlayerSink.h"
#include "moonlight/media/MoonlightCommonCAdapter.h"
#include "moonlight/media/MoonlightVideoDecoderSink.h"

#include <cstddef>
#include <cstdint>
#include <memory>

#if defined(__GNUC__) || defined(__clang__)
#define REMOTEDESK_MOONLIGHT_PRODUCT_MEDIA_HIDDEN \
    __attribute__((visibility("hidden")))
#else
#define REMOTEDESK_MOONLIGHT_PRODUCT_MEDIA_HIDDEN
#endif

namespace remotedesk::moonlight {

struct REMOTEDESK_MOONLIGHT_PRODUCT_MEDIA_HIDDEN
MoonlightProductMediaDiagnostics final {
    bool matched = false;
    std::uint64_t acceptedVideoFrames = 0U;
    std::uint64_t droppedVideoFrames = 0U;
    std::uint64_t acceptedVideoBytes = 0U;
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
    std::uint64_t acceptedAudioPackets = 0U;
    std::uint64_t rejectedAudioPackets = 0U;
    std::uint64_t acceptedAudioBytes = 0U;
};

// Single-session common-c media composition. The caller supplies the exact
// decoder/renderer binding and the already-owned platform ports; this class
// never creates a second decoder owner, audio renderer, queue, or worker.
class REMOTEDESK_MOONLIGHT_PRODUCT_MEDIA_HIDDEN MoonlightProductMediaPort final
    : public MoonlightCommonCMediaPort {
private:
    struct Impl;

public:
    static std::shared_ptr<MoonlightProductMediaPort> create(
        const MoonlightSessionKey& key,
        const MoonlightVideoDecoderBinding& videoBinding,
        std::shared_ptr<MoonlightOwnedDecoderPort> videoDecoderPort,
        std::shared_ptr<MoonlightAudioDecoderPort> audioDecoderPort,
        std::shared_ptr<MoonlightAudioPlayerSink> audioPlayerSink) noexcept;

    static std::shared_ptr<MoonlightProductMediaPort> createProduction(
        const MoonlightSessionKey& key,
        const MoonlightVideoDecoderBinding& videoBinding) noexcept;

    ~MoonlightProductMediaPort() override;
    MoonlightProductMediaPort(const MoonlightProductMediaPort&) = delete;
    MoonlightProductMediaPort& operator=(
        const MoonlightProductMediaPort&) = delete;

    bool videoReady() const noexcept override;
    bool audioReady(MoonlightStreamAudioLayout layout) const noexcept override;
    bool firstFrameReady() const noexcept override;
    bool videoLive() const noexcept override;
    bool audioLive() const noexcept override;
    // Temporary local lifecycle controls. They preserve the one common-c
    // connection and exact decoder/audio owners; no second media lane is
    // created while ArkUI replaces a Surface or background policy mutes audio.
    bool suspendVideo() noexcept;
    bool rebindVideo(
        const MoonlightVideoDecoderBinding& binding) noexcept;
    MoonlightVideoDecoderBinding videoBindingSnapshot() const noexcept;
    bool pauseAudio(MoonlightAudioPauseReason reason) noexcept;
    bool resumeAudio() noexcept;
    MoonlightProductMediaDiagnostics diagnostics() const noexcept;
    bool setupVideo(
        const MoonlightCommonCVideoSelection& selection) noexcept override;
    void startVideo() noexcept override;
    void stopVideo() noexcept override;
    void cleanupVideo() noexcept override;
    MoonlightVideoSubmitResult submitVideoPayload(
        const MoonlightVideoDecodeUnitView& decodeUnit) noexcept override;
    bool setupAudio(
        const MoonlightCommonCAudioSelection& selection) noexcept override;
    void startAudio() noexcept override;
    void stopAudio() noexcept override;
    void cleanupAudio() noexcept override;
    void submitAudioPayload(const std::uint8_t* bytes,
                            std::size_t byteCount) noexcept override;

private:
    explicit MoonlightProductMediaPort(std::unique_ptr<Impl> impl) noexcept;
    std::unique_ptr<Impl> impl_;
};

} // namespace remotedesk::moonlight

#undef REMOTEDESK_MOONLIGHT_PRODUCT_MEDIA_HIDDEN

#endif // REMOTEDESK_MOONLIGHT_PRODUCT_MEDIA_PORT_H
