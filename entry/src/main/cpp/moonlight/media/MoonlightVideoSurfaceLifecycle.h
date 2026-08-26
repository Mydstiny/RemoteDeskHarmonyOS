#ifndef REMOTEDESK_MOONLIGHT_VIDEO_SURFACE_LIFECYCLE_H
#define REMOTEDESK_MOONLIGHT_VIDEO_SURFACE_LIFECYCLE_H

#include "moonlight/media/MoonlightVideoDecoderSink.h"

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <memory>

#if defined(__GNUC__) || defined(__clang__)
#define REMOTEDESK_MOONLIGHT_SURFACE_HIDDEN __attribute__((visibility("hidden")))
#else
#define REMOTEDESK_MOONLIGHT_SURFACE_HIDDEN
#endif

namespace remotedesk::moonlight {

enum class MoonlightVideoSurfaceState : std::uint8_t {
    AwaitingSurface,
    Bound,
    Suspending,
    SuspendedNoSurface,
    Rebinding,
    Stopping,
    Stopped,
};

enum class MoonlightVideoSurfaceTarget : std::uint8_t {
    Page,
    Pip,
};

enum class MoonlightVideoSurfaceSuspendReason : std::uint8_t {
    PipTransfer,
    SurfaceDestroyed,
    ForegroundRestore,
    Background,
    LockScreen,
};

enum class MoonlightVideoSurfaceTransitionStatus : std::uint8_t {
    Applied,
    AlreadyApplied,
    InvalidRequest,
    RuntimeProofRequired,
    Unsupported,
    Stale,
    Busy,
    TimedOut,
    Failed,
};

struct REMOTEDESK_MOONLIGHT_SURFACE_HIDDEN MoonlightVideoSurfaceBeginRequest final {
    MoonlightSessionKey key {};
    MoonlightStreamCodecProfile profile {};
    std::uint64_t operationGeneration = 0U;
};

struct REMOTEDESK_MOONLIGHT_SURFACE_HIDDEN MoonlightVideoSurfaceBinding final {
    MoonlightVideoDecoderBinding decoder {};
    std::uint64_t operationGeneration = 0U;
    std::uint64_t surfaceGeneration = 0U;
    MoonlightVideoSurfaceTarget target = MoonlightVideoSurfaceTarget::Page;
    std::int32_t surfaceWidth = 0;
    std::int32_t surfaceHeight = 0;
};

REMOTEDESK_MOONLIGHT_SURFACE_HIDDEN bool operator==(
    const MoonlightVideoSurfaceBinding& left,
    const MoonlightVideoSurfaceBinding& right) noexcept;
REMOTEDESK_MOONLIGHT_SURFACE_HIDDEN bool operator!=(
    const MoonlightVideoSurfaceBinding& left,
    const MoonlightVideoSurfaceBinding& right) noexcept;

struct REMOTEDESK_MOONLIGHT_SURFACE_HIDDEN MoonlightVideoSurfaceTransitionResult final {
    MoonlightVideoSurfaceTransitionStatus status =
        MoonlightVideoSurfaceTransitionStatus::InvalidRequest;
    MoonlightVideoSurfaceState state = MoonlightVideoSurfaceState::Stopped;
    bool requestIdr = false;
};

struct REMOTEDESK_MOONLIGHT_SURFACE_HIDDEN MoonlightVideoSurfaceSnapshot final {
    bool matched = false;
    MoonlightSessionKey key {};
    MoonlightVideoSurfaceState state = MoonlightVideoSurfaceState::Stopped;
    MoonlightVideoDecoderBinding binding {};
    MoonlightVideoSurfaceTarget target = MoonlightVideoSurfaceTarget::Page;
    std::uint64_t operationGeneration = 0U;
    std::uint64_t surfaceGeneration = 0U;
    std::int32_t surfaceWidth = 0;
    std::int32_t surfaceHeight = 0;
    bool firstFrameReady = false;
    bool idrNeeded = false;
    bool idrRequestPending = false;
    std::uint64_t noSurfaceDroppedFrames = 0U;
    // The lifecycle gate is before MoonlightVideoBridge::submit(), so it can
    // truthfully retain zero encoded AU bytes while no Surface exists.
    std::size_t retainedAccessUnitBytes = 0U;
};

class REMOTEDESK_MOONLIGHT_SURFACE_HIDDEN MoonlightVideoSurfaceLifecycle final {
private:
    struct Impl;

public:
    static std::unique_ptr<MoonlightVideoSurfaceLifecycle> create(
        std::shared_ptr<MoonlightOwnedDecoderPort> port);
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    static std::unique_ptr<MoonlightVideoSurfaceLifecycle> createForTesting(
        std::shared_ptr<MoonlightOwnedDecoderPort> port);
#endif

    ~MoonlightVideoSurfaceLifecycle();
    MoonlightVideoSurfaceLifecycle(const MoonlightVideoSurfaceLifecycle&) = delete;
    MoonlightVideoSurfaceLifecycle& operator=(
        const MoonlightVideoSurfaceLifecycle&) = delete;

    MoonlightVideoSurfaceTransitionResult begin(
        const MoonlightVideoSurfaceBeginRequest& request) noexcept;
    MoonlightVideoSurfaceTransitionResult bind(
        const MoonlightVideoSurfaceBinding& binding) noexcept;
    MoonlightVideoSubmitResult submit(
        const MoonlightVideoDecodeUnitView& decodeUnit) noexcept;
    MoonlightVideoSurfaceTransitionResult suspend(
        const MoonlightSessionKey& key,
        std::uint64_t operationGeneration,
        MoonlightVideoSurfaceSuspendReason reason,
        std::chrono::milliseconds timeout = std::chrono::seconds(5)) noexcept;
    MoonlightVideoSurfaceTransitionResult resize(
        const MoonlightSessionKey& key,
        std::uint64_t operationGeneration,
        std::uint64_t surfaceGeneration,
        std::int32_t width,
        std::int32_t height) noexcept;
    MoonlightVideoSurfaceTransitionResult stop(
        const MoonlightSessionKey& key,
        std::uint64_t operationGeneration,
        std::chrono::milliseconds timeout = std::chrono::seconds(5)) noexcept;
    MoonlightVideoSurfaceSnapshot snapshot(
        const MoonlightSessionKey& key) const noexcept;

private:
    explicit MoonlightVideoSurfaceLifecycle(std::unique_ptr<Impl> impl);
    std::unique_ptr<Impl> impl_;
};

} // namespace remotedesk::moonlight

#undef REMOTEDESK_MOONLIGHT_SURFACE_HIDDEN

#endif // REMOTEDESK_MOONLIGHT_VIDEO_SURFACE_LIFECYCLE_H
