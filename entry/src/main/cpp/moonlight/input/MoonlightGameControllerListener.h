#ifndef REMOTEDESK_MOONLIGHT_GAME_CONTROLLER_LISTENER_H
#define REMOTEDESK_MOONLIGHT_GAME_CONTROLLER_LISTENER_H

#include "moonlight/input/MoonlightControllerMapper.h"

#include <cstddef>
#include <cstdint>
#include <memory>

#if defined(__GNUC__) || defined(__clang__)
#define REMOTEDESK_MOONLIGHT_GAME_CONTROLLER_HIDDEN \
    __attribute__((visibility("hidden")))
#else
#define REMOTEDESK_MOONLIGHT_GAME_CONTROLLER_HIDDEN
#endif

namespace remotedesk::moonlight {

// GameControllerKit registers one callback per physical control. Preserve that
// semantic identity instead of inferring it from an SDK-provided display name.
enum class REMOTEDESK_MOONLIGHT_GAME_CONTROLLER_HIDDEN
MoonlightGameControllerButtonInput : std::uint8_t {
    FaceA = 0,
    FaceB,
    FaceX,
    FaceY,
    DpadUp,
    DpadDown,
    DpadLeft,
    DpadRight,
    LeftShoulder,
    RightShoulder,
    LeftTrigger,
    RightTrigger,
    LeftStick,
    RightStick,
    Menu,
    Home,
};

REMOTEDESK_MOONLIGHT_GAME_CONTROLLER_HIDDEN bool
applyMoonlightGameControllerButtonInput(
    MoonlightGameControllerButtonInput input, bool pressed,
    MoonlightControllerSample& sample) noexcept;

// The GameControllerKit callbacks are process-global and carry no user
// context. This listener is therefore deliberately single-owner and
// synchronous: it copies the SDK event into a bounded full-state sample and
// immediately hands it to the current Moonlight session owner. It never owns
// a worker thread or an unbounded event queue.
class REMOTEDESK_MOONLIGHT_GAME_CONTROLLER_HIDDEN
MoonlightGameControllerListener final {
  public:
    class REMOTEDESK_MOONLIGHT_GAME_CONTROLLER_HIDDEN Sink {
      public:
        virtual ~Sink() = default;
        virtual void onPhysicalControllerConnected(
            std::uint64_t deviceId, std::uint64_t sourceGeneration,
            std::uint64_t sourceSequence, std::uint64_t monotonicTimestampUs,
            const MoonlightControllerProfile& profile) noexcept = 0;
        virtual void onPhysicalControllerSample(
            std::uint64_t deviceId, std::uint64_t sourceGeneration,
            std::uint64_t sourceSequence, std::uint64_t monotonicTimestampUs,
            const MoonlightControllerSample& sample) noexcept = 0;
        virtual void onPhysicalControllerDisconnected(
            std::uint64_t deviceId, std::uint64_t sourceGeneration,
            std::uint64_t sourceSequence,
            std::uint64_t monotonicTimestampUs) noexcept = 0;
    };

    explicit MoonlightGameControllerListener(Sink& sink) noexcept;
    ~MoonlightGameControllerListener();

    MoonlightGameControllerListener(const MoonlightGameControllerListener&) = delete;
    MoonlightGameControllerListener& operator=(
        const MoonlightGameControllerListener&) = delete;

    bool start() noexcept;
    void stop() noexcept;

    bool started() const noexcept;
    std::size_t onlineDeviceCount() const noexcept;

    // The hash is intentionally exposed for host-side contract tests. The raw
    // SDK identifier never crosses the NAPI boundary or enters diagnostics.
    static std::uint64_t stableDeviceIdForTesting(const char* value) noexcept;

  public:
    // Kept public only so the platform callback translation unit can hold the
    // process-global SDK callback fence without exposing any implementation
    // fields to callers.
    struct Impl;

  private:
    // Called only by start() while lifecycleMutex owns the dynamic API.
    void replayOnlineDevices() noexcept;

    // A callback lease keeps Impl alive while a process-global SDK callback
    // unwinds, including when a sink destroys the listener from inside that
    // callback.
    std::shared_ptr<Impl> impl_;
};

} // namespace remotedesk::moonlight

#undef REMOTEDESK_MOONLIGHT_GAME_CONTROLLER_HIDDEN

#endif // REMOTEDESK_MOONLIGHT_GAME_CONTROLLER_LISTENER_H
