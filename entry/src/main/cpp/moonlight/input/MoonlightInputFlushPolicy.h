#ifndef REMOTEDESK_MOONLIGHT_INPUT_FLUSH_POLICY_H
#define REMOTEDESK_MOONLIGHT_INPUT_FLUSH_POLICY_H

#include "moonlight/input/MoonlightControllerMapper.h"
#include "moonlight/input/MoonlightKeyboardMapper.h"
#include "moonlight/input/MoonlightPointerMapper.h"
#include "moonlight/input/MoonlightTouchMapper.h"

#include <cstdint>
#include <memory>

#if defined(__GNUC__) || defined(__clang__)
#define REMOTEDESK_MOONLIGHT_FLUSH_HIDDEN __attribute__((visibility("hidden")))
#else
#define REMOTEDESK_MOONLIGHT_FLUSH_HIDDEN
#endif

namespace remotedesk::moonlight {

enum class MoonlightInputFlushTrigger : std::uint8_t {
    Invalid = 0,
    OverlayOpened,
    ControlModeChanged,
    DisplayRotated,
    FocusLost,
    PipEntered,
    Backgrounded,
    ScreenLocked,
    SurfaceDetached,
    ReconnectStarted,
    SessionStop,
    InputGenerationChanged,
    ControllerDisconnected,
};

enum class MoonlightInputFlushDisposition : std::uint8_t {
    Invalid = 0,
    Suspend,
    Stop,
};

enum class MoonlightInputFlushStage : std::uint8_t {
    None = 0,
    Touch,
    Pointer,
    Keyboard,
    Controller,
    Boundary,
    Complete,
};

enum class MoonlightInputFlushState : std::uint8_t {
    Active = 0,
    Flushing,
    BoundaryPending,
    Suspended,
    Stopped,
};

enum class MoonlightInputFlushStatus : std::uint8_t {
    Applied = 0,
    AppliedLocally,
    AlreadyApplied,
    InvalidRequest,
    InvalidState,
    StaleOwner,
    StaleOperation,
    Pending,
    ComponentFailure,
    BoundaryFailure,
};

// Every context identifies the old input generation being made neutral. The
// per-source sequences are supplied by the single future product input owner;
// this policy never invents or rewrites mapper sequence numbers.
struct REMOTEDESK_MOONLIGHT_FLUSH_HIDDEN MoonlightInputFlushContext final {
    MoonlightInputIdentity identity{};
    std::uint64_t operationGeneration = 0U;
    std::uint64_t monotonicTimestampUs = 0U;
    MoonlightTouchEventContext touch{};
    MoonlightPointerEventContext pointer{};
    MoonlightKeyboardEventContext keyboard{};
    bool controllerContextPresent = false;
    MoonlightControllerEventContext controller{};
};

struct REMOTEDESK_MOONLIGHT_FLUSH_HIDDEN MoonlightInputFlushResult final {
    MoonlightInputFlushStatus status = MoonlightInputFlushStatus::InvalidRequest;
    MoonlightInputFlushStage stage = MoonlightInputFlushStage::None;
    MoonlightInputDispatchStatus dispatchStatus =
        MoonlightInputDispatchStatus::InvalidRequest;
    bool localReleased = false;
    bool boundaryApplied = false;
    bool retryable = false;
    // True only when every stateful component either had no remote state to
    // release or its exact release command was accepted. A terminal fallback
    // may discard local mapper state and still apply the final boundary; that
    // must never be reported as proof that Sunshine is neutral.
    bool remoteReleaseComplete = false;
};

struct REMOTEDESK_MOONLIGHT_FLUSH_HIDDEN MoonlightInputFlushSnapshot final {
    bool matched = false;
    MoonlightInputIdentity identity{};
    MoonlightInputFlushState state = MoonlightInputFlushState::Active;
    MoonlightInputFlushStage stage = MoonlightInputFlushStage::None;
    MoonlightInputFlushTrigger lastTrigger = MoonlightInputFlushTrigger::Invalid;
    MoonlightInputFlushDisposition lastDisposition =
        MoonlightInputFlushDisposition::Invalid;
    std::uint64_t lastOperationGeneration = 0U;
    std::uint64_t lastTimestampUs = 0U;
    std::uint64_t completedFlushes = 0U;
    std::uint64_t localOnlyStops = 0U;
    std::uint64_t pendingRetries = 0U;
    std::uint64_t boundaryFailures = 0U;
    std::uint64_t rejectedRequests = 0U;
    bool admissionOpen = true;
    bool localReleased = false;
    bool boundaryApplied = false;
    bool remoteReleaseComplete = false;
};

REMOTEDESK_MOONLIGHT_FLUSH_HIDDEN MoonlightInputFlushDisposition
moonlightInputFlushDisposition(MoonlightInputFlushTrigger trigger) noexcept;

class REMOTEDESK_MOONLIGHT_FLUSH_HIDDEN MoonlightInputFlushPolicy final {
  private:
    struct Impl;
    explicit MoonlightInputFlushPolicy(std::unique_ptr<Impl> impl) noexcept;

  public:
    ~MoonlightInputFlushPolicy();
    MoonlightInputFlushPolicy(const MoonlightInputFlushPolicy&) = delete;
    MoonlightInputFlushPolicy& operator=(const MoonlightInputFlushPolicy&) = delete;

    static std::shared_ptr<MoonlightInputFlushPolicy> create(
        std::shared_ptr<MoonlightInputBridge> bridge,
        std::shared_ptr<MoonlightKeyboardMapper> keyboard,
        std::shared_ptr<MoonlightPointerMapper> pointer,
        std::shared_ptr<MoonlightTouchMapper> touch,
        const MoonlightInputIdentity& identity,
        std::shared_ptr<MoonlightControllerMapper> controller = nullptr) noexcept;

    MoonlightInputFlushResult flush(
        MoonlightInputFlushTrigger trigger,
        const MoonlightInputFlushContext& context) noexcept;

    // A failed suspend boundary is retried only with a strictly newer owner
    // operation generation. Mapper release events are never replayed.
    MoonlightInputFlushResult retryBoundary(
        const MoonlightInputIdentity& identity,
        std::uint64_t operationGeneration,
        std::uint64_t monotonicTimestampUs) noexcept;

    MoonlightInputFlushResult resume(
        const MoonlightInputIdentity& identity,
        std::uint64_t operationGeneration) noexcept;

    MoonlightInputFlushSnapshot snapshot(
        const MoonlightInputIdentity& identity) const noexcept;

  private:
    std::unique_ptr<Impl> impl_;
};

} // namespace remotedesk::moonlight

#undef REMOTEDESK_MOONLIGHT_FLUSH_HIDDEN

#endif // REMOTEDESK_MOONLIGHT_INPUT_FLUSH_POLICY_H
