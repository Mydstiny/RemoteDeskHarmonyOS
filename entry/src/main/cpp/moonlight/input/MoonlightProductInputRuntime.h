#ifndef REMOTEDESK_MOONLIGHT_PRODUCT_INPUT_RUNTIME_H
#define REMOTEDESK_MOONLIGHT_PRODUCT_INPUT_RUNTIME_H

#include "moonlight/core/MoonlightSessionOwner.h"
#include "moonlight/input/MoonlightInputFlushPolicy.h"
#include "moonlight/input/MoonlightPointerMapper.h"
#include "moonlight/input/MoonlightTouchMapper.h"

#include <cstddef>
#include <cstdint>

namespace remotedesk::moonlight {

enum class MoonlightProductPointerAction : std::uint8_t {
    Relative = 1,
    Absolute = 2,
    Button = 3,
    Scroll = 4,
    AbsoluteButton = 5,
};

enum class MoonlightProductVirtualControllerElement : std::uint8_t {
    Invalid = 0,
    FaceA,
    FaceB,
    FaceX,
    FaceY,
    Dpad,
    LeftStick,
    RightStick,
    LeftTrigger,
    RightTrigger,
    LeftShoulder,
    RightShoulder,
    LeftStickClick,
    RightStickClick,
    Menu,
    Back,
    Special,
};

enum class MoonlightProductVirtualControllerPhase : std::uint8_t {
    Invalid = 0,
    Begin,
    Change,
    End,
    Cancel,
};

struct MoonlightProductVirtualControllerRequest final {
    MoonlightProductVirtualControllerElement element =
        MoonlightProductVirtualControllerElement::Invalid;
    MoonlightProductVirtualControllerPhase phase =
        MoonlightProductVirtualControllerPhase::Invalid;
    std::uint64_t pointerId = 0U;
    double primary = 0.0;
    double secondary = 0.0;
};

struct MoonlightProductPointerRequest final {
    MoonlightProductPointerAction action = MoonlightProductPointerAction::Relative;
    double x = 0.0;
    double y = 0.0;
    double contentLeft = 0.0;
    double contentTop = 0.0;
    double contentWidth = 0.0;
    double contentHeight = 0.0;
    std::uint16_t referenceWidth = 0U;
    std::uint16_t referenceHeight = 0U;
    std::uint64_t geometryGeneration = 0U;
    MoonlightPointerButton button = MoonlightPointerButton::Left;
    bool pressed = false;
    bool horizontal = false;
    std::int32_t scrollAmount = 0;
};

struct MoonlightProductTouchRequest final {
    std::uint64_t contactId = 0U;
    MoonlightTouchPhase phase = MoonlightTouchPhase::Down;
    MoonlightTouchSample sample{};
    MoonlightTouchSurface surface{};
};

struct MoonlightProductInputSnapshot final {
    bool matched = false;
    bool inputReady = false;
    bool controllerReady = false;
    bool physicalControllerReady = false;
    bool inputMayBeStuck = false;
    bool recoveryResetFailed = false;
    std::uint64_t inputGeneration = 0U;
    std::uint64_t acceptedEvents = 0U;
    std::uint64_t rejectedEvents = 0U;
};

// Terminal input teardown has two independent truths. Local cleanup is enough
// to retire process-owned mapper/listener state, but only remoteNeutral proves
// that the corresponding Sunshine input state was released successfully.
struct MoonlightProductInputStopResult final {
    bool localCleanupComplete = false;
    bool remoteNeutral = false;
};

constexpr bool moonlightProductRemoteInputReleaseProven(
    MoonlightInputFlushStatus status, bool remoteReleaseComplete,
    bool boundaryApplied) noexcept {
    return status == MoonlightInputFlushStatus::Applied &&
        remoteReleaseComplete && boundaryApplied;
}

class MoonlightProductInputRuntime final {
  public:
    static MoonlightProductInputRuntime& process() noexcept;

    bool activate(const MoonlightSessionKey& key,
                  bool resetRemoteInputBeforeAdmission = false) noexcept;
    MoonlightProductInputStopResult stop(
        const MoonlightSessionKey& key) noexcept;
    MoonlightProductInputSnapshot snapshot(const MoonlightSessionKey& key) noexcept;

    bool sendKey(const MoonlightSessionKey& key, std::uint32_t harmonyKeyCode,
                 bool pressed, bool normalizedToUsLayout) noexcept;
    bool sendText(const MoonlightSessionKey& key, const std::uint8_t* text,
                  std::size_t size) noexcept;
    bool sendPointer(const MoonlightSessionKey& key,
                     const MoonlightProductPointerRequest& request) noexcept;
    bool sendTouch(const MoonlightSessionKey& key,
                   const MoonlightProductTouchRequest& request) noexcept;
    bool setSuspended(const MoonlightSessionKey& key,
                      MoonlightInputFlushTrigger trigger,
                      bool suspended) noexcept;
    bool setTouchMode(const MoonlightSessionKey& key, bool direct) noexcept;
    bool setVirtualControllerMode(const MoonlightSessionKey& key,
                                  bool enabled, bool editing) noexcept;
    bool sendVirtualController(
        const MoonlightSessionKey& key,
        const MoonlightProductVirtualControllerRequest& request) noexcept;

  private:
    MoonlightProductInputRuntime() = default;
    struct State;
    State& state() noexcept;
};

} // namespace remotedesk::moonlight

#endif // REMOTEDESK_MOONLIGHT_PRODUCT_INPUT_RUNTIME_H
