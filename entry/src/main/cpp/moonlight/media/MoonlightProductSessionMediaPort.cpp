#include "moonlight/media/MoonlightProductSessionMediaPort.h"

#include "moonlight/media/MoonlightProductMediaPort.h"
#include "render/hw_decoder.h"
#include "render/shared_session_context.h"

#include <mutex>
#include <utility>

namespace remotedesk::moonlight {
namespace {

Render::DecoderSessionIdentity sinkOwner(const MoonlightSessionKey& key) noexcept {
    return {key.sessionId, key.generation, key.ownerToken};
}

MoonlightVideoSubmitResult staleVideoResult() noexcept {
    MoonlightVideoSubmitResult result;
    result.status = MoonlightVideoSubmitStatus::Stale;
    return result;
}

} // namespace

struct MoonlightProductSessionMediaPort::Impl final {
    Impl(std::int64_t renderer, std::int32_t exactWidth,
         std::int32_t exactHeight) noexcept
        : rendererHandle(renderer), width(exactWidth), height(exactHeight) {}

    const std::int64_t rendererHandle;
    const std::int32_t width;
    const std::int32_t height;
    mutable std::mutex mutex;
    MoonlightSessionKey key {};
    bool ownerActive = false;
    std::shared_ptr<MoonlightProductMediaPort> delegate;
};

MoonlightProductSessionMediaPort::MoonlightProductSessionMediaPort(
    std::unique_ptr<Impl> impl) noexcept : impl_(std::move(impl)) {}

MoonlightProductSessionMediaPort::~MoonlightProductSessionMediaPort() {
    if (impl_ == nullptr) {
        return;
    }
    MoonlightSessionKey key;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        key = impl_->key;
    }
    releaseSession(key);
}

std::shared_ptr<MoonlightProductSessionMediaPort>
MoonlightProductSessionMediaPort::create(
    std::int64_t rendererHandle, std::int32_t width,
    std::int32_t height) noexcept {
    if (rendererHandle <= 0 || width <= 0 || height <= 0) {
        return nullptr;
    }
    try {
        return std::shared_ptr<MoonlightProductSessionMediaPort>(
            new MoonlightProductSessionMediaPort(
                std::make_unique<Impl>(rendererHandle, width, height)));
    } catch (...) {
        return nullptr;
    }
}

bool MoonlightProductSessionMediaPort::bindSession(
    const MoonlightSessionKey& key) noexcept {
    if (impl_ == nullptr || !key.valid()) {
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        if (impl_->ownerActive || impl_->delegate != nullptr || impl_->key.valid()) {
            return false;
        }
    }
    const auto owner = sinkOwner(key);
    if (!Render::ActivateSharedSessionSinks(owner)) {
        return false;
    }
    const auto created = DecoderNapi::CreateOwnedHardwareDecoder(
        impl_->width, impl_->height, static_cast<int>(CodecType::H264),
        impl_->rendererHandle, owner);
    if (!created.ok) {
        (void)Render::DeactivateSharedSessionSinks(owner);
        return false;
    }
    MoonlightVideoDecoderBinding binding;
    binding.key = key;
    binding.profile = {MoonlightStreamCodec::H264,
                       MoonlightStreamBitDepth::Bit8,
                       MoonlightStreamChroma::Yuv420};
    binding.width = impl_->width;
    binding.height = impl_->height;
    binding.display = created.display;
    binding.decoderHandle = created.decoderHandle;
    binding.rendererHandle = impl_->rendererHandle;
    binding.decoderGeneration = created.decoderGeneration;
    binding.displayGeneration = created.displayGeneration;
    binding.rendererGeneration = created.rendererGeneration;
    binding.ownsDecoderHandle = true;
    binding.runtimeProof = {created.decoderGeneration, true, true, true};
    auto delegate = MoonlightProductMediaPort::createProduction(key, binding);
    if (delegate == nullptr) {
        DecoderNapi::DestroyDecoderHandle(created.decoderHandle, owner);
        (void)Render::DeactivateSharedSessionSinks(owner);
        return false;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->key = key;
    impl_->ownerActive = true;
    impl_->delegate = std::move(delegate);
    return true;
}

void MoonlightProductSessionMediaPort::releaseSession(
    const MoonlightSessionKey& key) noexcept {
    if (impl_ == nullptr || !key.valid()) {
        return;
    }
    std::shared_ptr<MoonlightProductMediaPort> delegate;
    bool ownerActive = false;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        if (impl_->key != key) {
            return;
        }
        delegate = std::move(impl_->delegate);
        ownerActive = impl_->ownerActive;
        impl_->ownerActive = false;
        impl_->key = {};
    }
    delegate.reset();
    if (ownerActive) {
        (void)Render::DeactivateSharedSessionSinks(sinkOwner(key));
    }
}

bool MoonlightProductSessionMediaPort::firstFrameReady() const noexcept {
    std::shared_ptr<MoonlightProductMediaPort> delegate;
    {
        if (impl_ == nullptr) { return false; }
        std::lock_guard<std::mutex> lock(impl_->mutex);
        delegate = impl_->delegate;
    }
    return delegate != nullptr && delegate->firstFrameReady();
}

#define MOONLIGHT_DELEGATE_BOOL(method, fallback, ...) \
    std::shared_ptr<MoonlightProductMediaPort> delegate; \
    { \
        if (impl_ == nullptr) { return fallback; } \
        std::lock_guard<std::mutex> lock(impl_->mutex); \
        delegate = impl_->delegate; \
    } \
    return delegate != nullptr ? delegate->method(__VA_ARGS__) : fallback

bool MoonlightProductSessionMediaPort::videoReady() const noexcept {
    MOONLIGHT_DELEGATE_BOOL(videoReady, false);
}
bool MoonlightProductSessionMediaPort::audioReady(
    MoonlightStreamAudioLayout layout) const noexcept {
    MOONLIGHT_DELEGATE_BOOL(audioReady, false, layout);
}
bool MoonlightProductSessionMediaPort::setupVideo(
    const MoonlightCommonCVideoSelection& selection) noexcept {
    MOONLIGHT_DELEGATE_BOOL(setupVideo, false, selection);
}
bool MoonlightProductSessionMediaPort::setupAudio(
    const MoonlightCommonCAudioSelection& selection) noexcept {
    MOONLIGHT_DELEGATE_BOOL(setupAudio, false, selection);
}

#undef MOONLIGHT_DELEGATE_BOOL

#define MOONLIGHT_DELEGATE_VOID(method, ...) \
    std::shared_ptr<MoonlightProductMediaPort> delegate; \
    { \
        if (impl_ == nullptr) { return; } \
        std::lock_guard<std::mutex> lock(impl_->mutex); \
        delegate = impl_->delegate; \
    } \
    if (delegate != nullptr) { delegate->method(__VA_ARGS__); }

void MoonlightProductSessionMediaPort::startVideo() noexcept {
    MOONLIGHT_DELEGATE_VOID(startVideo);
}
void MoonlightProductSessionMediaPort::stopVideo() noexcept {
    MOONLIGHT_DELEGATE_VOID(stopVideo);
}
void MoonlightProductSessionMediaPort::cleanupVideo() noexcept {
    MOONLIGHT_DELEGATE_VOID(cleanupVideo);
}
void MoonlightProductSessionMediaPort::startAudio() noexcept {
    MOONLIGHT_DELEGATE_VOID(startAudio);
}
void MoonlightProductSessionMediaPort::stopAudio() noexcept {
    MOONLIGHT_DELEGATE_VOID(stopAudio);
}
void MoonlightProductSessionMediaPort::cleanupAudio() noexcept {
    MOONLIGHT_DELEGATE_VOID(cleanupAudio);
}
void MoonlightProductSessionMediaPort::submitAudioPayload(
    const std::uint8_t* bytes, std::size_t byteCount) noexcept {
    MOONLIGHT_DELEGATE_VOID(submitAudioPayload, bytes, byteCount);
}

#undef MOONLIGHT_DELEGATE_VOID

MoonlightVideoSubmitResult MoonlightProductSessionMediaPort::submitVideoPayload(
    const MoonlightVideoDecodeUnitView& decodeUnit) noexcept {
    std::shared_ptr<MoonlightProductMediaPort> delegate;
    {
        if (impl_ == nullptr) { return staleVideoResult(); }
        std::lock_guard<std::mutex> lock(impl_->mutex);
        delegate = impl_->delegate;
    }
    return delegate == nullptr ? staleVideoResult()
                               : delegate->submitVideoPayload(decodeUnit);
}

} // namespace remotedesk::moonlight
