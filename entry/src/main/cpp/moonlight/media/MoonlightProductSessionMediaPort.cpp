#include "moonlight/media/MoonlightProductSessionMediaPort.h"

#include "moonlight/media/MoonlightProductMediaPort.h"
#include "moonlight/media/MoonlightVideoCodecSupport.h"
#include "render/gl_renderer.h"
#include "render/hw_decoder.h"
#include "render/shared_session_context.h"

#include <algorithm>
#include <limits>
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
         std::int32_t exactHeight, MoonlightStreamCodec videoCodec,
         bool playAudio) noexcept
        : rendererHandle(renderer), width(exactWidth), height(exactHeight),
          codec(videoCodec), audioPlaybackEnabled(playAudio) {}

    const std::int64_t rendererHandle;
    const std::int32_t width;
    const std::int32_t height;
    const MoonlightStreamCodec codec;
    const bool audioPlaybackEnabled;
    // Serializes the complete activate/create/publish transaction with release.
    // The state mutex alone cannot cover platform calls, but allowing two binds
    // to pass its initial empty-state check would publish competing sink owners.
    std::mutex bindLane;
    mutable std::mutex mutex;
    MoonlightSessionKey key {};
    bool ownerActive = false;
    bool discardAudioConfigured = false;
    bool discardAudioStarted = false;
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
    std::int32_t height, MoonlightStreamCodec codec,
    bool audioPlaybackEnabled) noexcept {
    if (rendererHandle <= 0 || width <= 0 || height <= 0 ||
        !moonlightHardwareVideoProfileSupported(
            moonlightHardwareVideoProfile(codec))) {
        return nullptr;
    }
    try {
        return std::shared_ptr<MoonlightProductSessionMediaPort>(
            new MoonlightProductSessionMediaPort(
                std::make_unique<Impl>(rendererHandle, width, height, codec,
                                       audioPlaybackEnabled)));
    } catch (...) {
        return nullptr;
    }
}

bool MoonlightProductSessionMediaPort::bindSession(
    const MoonlightSessionKey& key) noexcept {
    if (impl_ == nullptr || !key.valid()) {
        return false;
    }
    std::lock_guard<std::mutex> bind(impl_->bindLane);
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        if (impl_->key == key && impl_->ownerActive && impl_->delegate != nullptr) {
            return true;
        }
        if (impl_->ownerActive || impl_->delegate != nullptr || impl_->key.valid()) {
            return false;
        }
    }
    const auto owner = sinkOwner(key);
    if (!Render::ActivateSharedSessionSinks(owner)) {
        return false;
    }
    const auto created = DecoderNapi::CreateOwnedHardwareDecoder(
        impl_->width, impl_->height,
        static_cast<int>(moonlightHardwareCodecType(impl_->codec)),
        impl_->rendererHandle, owner);
    if (!created.ok) {
        (void)Render::DeactivateSharedSessionSinks(owner);
        return false;
    }
    MoonlightVideoDecoderBinding binding;
    binding.key = key;
    binding.profile = moonlightHardwareVideoProfile(impl_->codec);
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
    std::lock_guard<std::mutex> bind(impl_->bindLane);
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
        impl_->discardAudioConfigured = false;
        impl_->discardAudioStarted = false;
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
bool MoonlightProductSessionMediaPort::videoLive() const noexcept {
    MOONLIGHT_DELEGATE_BOOL(videoLive, false);
}
bool MoonlightProductSessionMediaPort::audioReady(
    MoonlightStreamAudioLayout layout) const noexcept {
    std::shared_ptr<MoonlightProductMediaPort> delegate;
    bool playback = true;
    {
        if (impl_ == nullptr) { return false; }
        std::lock_guard<std::mutex> lock(impl_->mutex);
        delegate = impl_->delegate;
        playback = impl_->audioPlaybackEnabled;
    }
    if (!playback) {
        return layout == MoonlightStreamAudioLayout::Disabled && delegate != nullptr;
    }
    return delegate != nullptr && delegate->audioReady(layout);
}
bool MoonlightProductSessionMediaPort::setupVideo(
    const MoonlightCommonCVideoSelection& selection) noexcept {
    MOONLIGHT_DELEGATE_BOOL(setupVideo, false, selection);
}
#undef MOONLIGHT_DELEGATE_BOOL

bool MoonlightProductSessionMediaPort::audioLive() const noexcept {
    std::shared_ptr<MoonlightProductMediaPort> delegate;
    {
        if (impl_ == nullptr) { return false; }
        std::lock_guard<std::mutex> lock(impl_->mutex);
        if (!impl_->audioPlaybackEnabled) {
            return impl_->ownerActive && impl_->discardAudioStarted;
        }
        delegate = impl_->delegate;
    }
    return delegate != nullptr && delegate->audioLive();
}

bool MoonlightProductSessionMediaPort::suspendSurface() noexcept {
    std::shared_ptr<MoonlightProductMediaPort> delegate;
    {
        if (impl_ == nullptr) { return false; }
        std::lock_guard<std::mutex> lock(impl_->mutex);
        delegate = impl_->delegate;
    }
    return delegate != nullptr && delegate->suspendVideo();
}

bool MoonlightProductSessionMediaPort::rebindSurface(
    std::int64_t rendererHandle) noexcept {
    std::shared_ptr<MoonlightProductMediaPort> delegate;
    MoonlightSessionKey key;
    {
        if (impl_ == nullptr || rendererHandle <= 0) { return false; }
        std::lock_guard<std::mutex> lock(impl_->mutex);
        delegate = impl_->delegate;
        key = impl_->key;
    }
    if (delegate == nullptr || !key.valid()) { return false; }
    const auto current = delegate->videoBindingSnapshot();
    if (current.key != key || !current.runtimeProof.valid() ||
        current.runtimeProof.generation ==
            std::numeric_limits<std::uint64_t>::max()) {
        return false;
    }
    const auto owner = sinkOwner(key);
    const auto rendererGeneration =
        RendererNapi::GetActiveRendererGeneration(rendererHandle, owner);
    if (rendererGeneration <= current.rendererGeneration ||
        RendererNapi::GetActiveRendererHandle(owner) != rendererHandle) {
        return false;
    }
    auto next = current;
    next.rendererHandle = rendererHandle;
    next.rendererGeneration = rendererGeneration;
    next.runtimeProof.generation = std::max(
        current.runtimeProof.generation + 1U, rendererGeneration);
    return delegate->rebindVideo(next);
}

bool MoonlightProductSessionMediaPort::pauseAudio() noexcept {
    std::shared_ptr<MoonlightProductMediaPort> delegate;
    {
        if (impl_ == nullptr) { return false; }
        std::lock_guard<std::mutex> lock(impl_->mutex);
        if (!impl_->audioPlaybackEnabled) { return true; }
        delegate = impl_->delegate;
    }
    return delegate != nullptr &&
        delegate->pauseAudio(MoonlightAudioPauseReason::Background);
}

bool MoonlightProductSessionMediaPort::resumeAudio() noexcept {
    std::shared_ptr<MoonlightProductMediaPort> delegate;
    {
        if (impl_ == nullptr) { return false; }
        std::lock_guard<std::mutex> lock(impl_->mutex);
        if (!impl_->audioPlaybackEnabled) { return true; }
        delegate = impl_->delegate;
    }
    return delegate != nullptr && delegate->resumeAudio();
}

MoonlightProductMediaDiagnostics
MoonlightProductSessionMediaPort::diagnostics() const noexcept {
    std::shared_ptr<MoonlightProductMediaPort> delegate;
    {
        if (impl_ == nullptr) { return {}; }
        std::lock_guard<std::mutex> lock(impl_->mutex);
        delegate = impl_->delegate;
    }
    return delegate == nullptr ? MoonlightProductMediaDiagnostics {}
                               : delegate->diagnostics();
}

bool MoonlightProductSessionMediaPort::setupAudio(
    const MoonlightCommonCAudioSelection& selection) noexcept {
    std::shared_ptr<MoonlightProductMediaPort> delegate;
    {
        if (impl_ == nullptr) { return false; }
        std::lock_guard<std::mutex> lock(impl_->mutex);
        if (!impl_->audioPlaybackEnabled) {
            if (!impl_->ownerActive || impl_->delegate == nullptr ||
                selection.layout != MoonlightStreamAudioLayout::Disabled ||
                impl_->discardAudioConfigured || impl_->discardAudioStarted) {
                return false;
            }
            impl_->discardAudioConfigured = true;
            return true;
        }
        delegate = impl_->delegate;
    }
    return delegate != nullptr && delegate->setupAudio(selection);
}

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
#undef MOONLIGHT_DELEGATE_VOID

void MoonlightProductSessionMediaPort::startAudio() noexcept {
    std::shared_ptr<MoonlightProductMediaPort> delegate;
    {
        if (impl_ == nullptr) { return; }
        std::lock_guard<std::mutex> lock(impl_->mutex);
        if (!impl_->audioPlaybackEnabled) {
            if (impl_->ownerActive && impl_->discardAudioConfigured) {
                impl_->discardAudioStarted = true;
            }
            return;
        }
        delegate = impl_->delegate;
    }
    if (delegate != nullptr) { delegate->startAudio(); }
}

void MoonlightProductSessionMediaPort::stopAudio() noexcept {
    std::shared_ptr<MoonlightProductMediaPort> delegate;
    {
        if (impl_ == nullptr) { return; }
        std::lock_guard<std::mutex> lock(impl_->mutex);
        if (!impl_->audioPlaybackEnabled) {
            impl_->discardAudioStarted = false;
            return;
        }
        delegate = impl_->delegate;
    }
    if (delegate != nullptr) { delegate->stopAudio(); }
}

void MoonlightProductSessionMediaPort::cleanupAudio() noexcept {
    std::shared_ptr<MoonlightProductMediaPort> delegate;
    {
        if (impl_ == nullptr) { return; }
        std::lock_guard<std::mutex> lock(impl_->mutex);
        if (!impl_->audioPlaybackEnabled) {
            impl_->discardAudioStarted = false;
            impl_->discardAudioConfigured = false;
            return;
        }
        delegate = impl_->delegate;
    }
    if (delegate != nullptr) { delegate->cleanupAudio(); }
}

void MoonlightProductSessionMediaPort::submitAudioPayload(
    const std::uint8_t* bytes, std::size_t byteCount) noexcept {
    std::shared_ptr<MoonlightProductMediaPort> delegate;
    {
        if (impl_ == nullptr) { return; }
        std::lock_guard<std::mutex> lock(impl_->mutex);
        if (!impl_->audioPlaybackEnabled) { return; }
        delegate = impl_->delegate;
    }
    if (delegate != nullptr) { delegate->submitAudioPayload(bytes, byteCount); }
}

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
