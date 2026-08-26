#ifndef REMOTEDESK_MOONLIGHT_PRODUCT_SESSION_MEDIA_PORT_H
#define REMOTEDESK_MOONLIGHT_PRODUCT_SESSION_MEDIA_PORT_H

#include "moonlight/media/MoonlightProductMediaPort.h"

#include <cstdint>
#include <memory>

namespace remotedesk::moonlight {

// Late-binds the existing app renderer and hardware decoder only after the
// common-c adapter receives its exact MoonlightSessionOwner key.
class MoonlightProductSessionMediaPort final : public MoonlightCommonCMediaPort {
public:
    static std::shared_ptr<MoonlightProductSessionMediaPort> create(
        std::int64_t rendererHandle, std::int32_t width,
        std::int32_t height, MoonlightStreamCodec codec,
        bool audioPlaybackEnabled = true,
        bool desktopSurfaceCompatibility = false) noexcept;
    ~MoonlightProductSessionMediaPort() override;

    bool bindSession(const MoonlightSessionKey& key) noexcept override;
    void releaseSession(const MoonlightSessionKey& key) noexcept override;
    bool firstFrameReady() const noexcept override;
    bool videoLive() const noexcept override;
    bool audioLive() const noexcept override;
    bool suspendSurface() noexcept;
    bool rebindSurface(std::int64_t rendererHandle) noexcept;
    bool pauseAudio() noexcept;
    bool resumeAudio() noexcept;
    MoonlightProductMediaDiagnostics diagnostics() const noexcept;
    bool videoReady() const noexcept override;
    bool audioReady(MoonlightStreamAudioLayout layout) const noexcept override;
    bool setupVideo(const MoonlightCommonCVideoSelection& selection) noexcept override;
    void startVideo() noexcept override;
    void stopVideo() noexcept override;
    void cleanupVideo() noexcept override;
    MoonlightVideoSubmitResult submitVideoPayload(
        const MoonlightVideoDecodeUnitView& decodeUnit) noexcept override;
    bool setupAudio(const MoonlightCommonCAudioSelection& selection) noexcept override;
    void startAudio() noexcept override;
    void stopAudio() noexcept override;
    void cleanupAudio() noexcept override;
    void submitAudioPayload(const std::uint8_t* bytes,
                            std::size_t byteCount) noexcept override;

private:
    struct Impl;
    explicit MoonlightProductSessionMediaPort(std::unique_ptr<Impl> impl) noexcept;
    std::unique_ptr<Impl> impl_;
};

} // namespace remotedesk::moonlight

#endif // REMOTEDESK_MOONLIGHT_PRODUCT_SESSION_MEDIA_PORT_H
