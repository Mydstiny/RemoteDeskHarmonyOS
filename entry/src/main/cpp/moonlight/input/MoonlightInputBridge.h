#ifndef REMOTEDESK_MOONLIGHT_INPUT_BRIDGE_H
#define REMOTEDESK_MOONLIGHT_INPUT_BRIDGE_H

#include "moonlight/core/MoonlightSessionOwner.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>

#if defined(__GNUC__) || defined(__clang__)
#define REMOTEDESK_MOONLIGHT_INPUT_HIDDEN __attribute__((visibility("hidden")))
#else
#define REMOTEDESK_MOONLIGHT_INPUT_HIDDEN
#endif

namespace Render {
class SessionSinkOwnerLease;
}

namespace remotedesk::moonlight {

constexpr std::size_t kMoonlightMaximumInputPayloadBytes = 64U;
constexpr std::size_t kMoonlightMaximumInputSourceLanes = 32U;

struct REMOTEDESK_MOONLIGHT_INPUT_HIDDEN MoonlightInputIdentity final {
    MoonlightSessionKey key{};
    std::uint64_t inputGeneration = 0U;

    constexpr bool valid() const noexcept {
        return key.valid() && inputGeneration != 0U;
    }
};

REMOTEDESK_MOONLIGHT_INPUT_HIDDEN constexpr bool operator==(
    const MoonlightInputIdentity& left,
    const MoonlightInputIdentity& right) noexcept {
    return left.key == right.key && left.inputGeneration == right.inputGeneration;
}

REMOTEDESK_MOONLIGHT_INPUT_HIDDEN constexpr bool operator!=(
    const MoonlightInputIdentity& left,
    const MoonlightInputIdentity& right) noexcept {
    return !(left == right);
}

enum class MoonlightInputSource : std::uint8_t {
    Invalid = 0,
    PhysicalKeyboard,
    OnScreenKeyboard,
    Mouse,
    Touchscreen,
    Touchpad,
    GameController,
    VirtualController,
};

enum class MoonlightInputCommandKind : std::uint8_t {
    Invalid = 0,
    Keyboard,
    Text,
    RelativePointer,
    AbsolutePointer,
    PointerButton,
    VerticalScroll,
    HorizontalScroll,
    Touch,
    Controller,
};

// N3-01 owns only routing metadata and a bounded project-owned command body.
// N3-02 through N3-05 define the exact body formats and common-c projection.
// Ports must consume this value synchronously and must not retain secret/text
// payload bytes after returning.
struct REMOTEDESK_MOONLIGHT_INPUT_HIDDEN MoonlightInputEvent final {
    MoonlightInputIdentity identity{};
    std::uint64_t deviceId = 0U;
    MoonlightInputSource source = MoonlightInputSource::Invalid;
    std::uint64_t sourceGeneration = 0U;
    std::uint64_t sourceSequence = 0U;
    std::uint64_t monotonicTimestampUs = 0U;
    MoonlightInputCommandKind kind = MoonlightInputCommandKind::Invalid;
    // Only mapper-generated release/cancel/neutral commands set this bit.
    // It lets the exact owner bridge reject ordinary input after beginFlush()
    // while still draining the already-observed local state.
    bool lifecycleRelease = false;
    std::uint16_t commandVersion = 0U;
    std::size_t payloadSize = 0U;
    std::array<std::uint8_t, kMoonlightMaximumInputPayloadBytes> payload{};
};

enum class MoonlightInputPortStatus : std::uint8_t {
    Accepted = 0,
    Backpressure,
    Unsupported,
    Failed,
};

enum class MoonlightInputDispatchStatus : std::uint8_t {
    Accepted = 0,
    InvalidRequest,
    InvalidState,
    StaleOwner,
    StaleEvent,
    Duplicate,
    SourceCapacity,
    Backpressure,
    Unsupported,
    PortFailure,
};

enum class MoonlightInputState : std::uint8_t {
    Idle = 0,
    Active,
    Suspended,
    ReleasePending,
    Stopped,
    Cleaned,
};

enum class MoonlightInputSuspendReason : std::uint8_t {
    None = 0,
    FocusLost,
    Stop,
};

enum class MoonlightInputControlStatus : std::uint8_t {
    Applied = 0,
    AlreadyApplied,
    InvalidRequest,
    InvalidState,
    Stale,
    OwnerUnavailable,
    PortFailure,
};

struct REMOTEDESK_MOONLIGHT_INPUT_HIDDEN MoonlightInputLimits final {
    std::size_t sourceLaneCapacity = 16U;
    std::size_t maximumPayloadBytes = kMoonlightMaximumInputPayloadBytes;
};

struct REMOTEDESK_MOONLIGHT_INPUT_HIDDEN MoonlightInputFlushRequest final {
    MoonlightInputIdentity identity{};
    MoonlightInputSuspendReason reason = MoonlightInputSuspendReason::None;
    std::uint64_t operationGeneration = 0U;
    std::uint64_t monotonicTimestampUs = 0U;
};

// Fresh-session crash recovery reset. It contains no prior input values: the
// product port emits a fixed all-up/cancel/neutral sweep while ordinary input
// admission is still closed by the product runtime.
struct REMOTEDESK_MOONLIGHT_INPUT_HIDDEN MoonlightInputRecoveryResetRequest final {
    MoonlightInputIdentity identity{};
    std::uint64_t operationGeneration = 0U;
    std::uint64_t monotonicTimestampUs = 0U;
    std::uint16_t activeGamepadMask = 0U;
    std::uint8_t controllerSlots = 0U;

    constexpr bool valid() const noexcept {
        return identity.valid() && operationGeneration != 0U &&
            monotonicTimestampUs != 0U && controllerSlots <= 16U &&
            (controllerSlots != 0U || activeGamepadMask == 0U) &&
            (controllerSlots == 16U ||
             activeGamepadMask < (static_cast<std::uint32_t>(1U) << controllerSlots));
    }
};

struct REMOTEDESK_MOONLIGHT_INPUT_HIDDEN MoonlightInputControlResult final {
    MoonlightInputControlStatus status = MoonlightInputControlStatus::InvalidRequest;
    MoonlightInputIdentity identity{};
    std::uint64_t operationGeneration = 0U;
};

struct REMOTEDESK_MOONLIGHT_INPUT_HIDDEN MoonlightInputSnapshot final {
    bool matched = false;
    MoonlightInputIdentity identity{};
    MoonlightInputState state = MoonlightInputState::Idle;
    MoonlightInputSuspendReason suspendReason = MoonlightInputSuspendReason::None;
    std::uint64_t lastOperationGeneration = 0U;
    std::uint64_t lastBoundaryTimestampUs = 0U;
    std::size_t sourceLanes = 0U;
    std::uint64_t acceptedEvents = 0U;
    std::uint64_t duplicateEvents = 0U;
    std::uint64_t staleEvents = 0U;
    std::uint64_t invalidEvents = 0U;
    std::uint64_t ownerRejectedEvents = 0U;
    std::uint64_t backpressureEvents = 0U;
    std::uint64_t unsupportedEvents = 0U;
    std::uint64_t portFailures = 0U;
    std::uint64_t neutralFlushes = 0U;
    std::uint64_t neutralFlushFailures = 0U;
    std::uint64_t recoveryResets = 0U;
    std::uint64_t recoveryResetBackpressure = 0U;
    std::uint64_t recoveryResetFailures = 0U;
};

// The gate executes a stack-owned operation synchronously while both the
// exact Moonlight callback lease and the shared cross-protocol owner lease are
// held. It must invoke execute() exactly once when returning true and never
// retain the operation reference.
class REMOTEDESK_MOONLIGHT_INPUT_HIDDEN MoonlightInputOwnedOperation {
  public:
    virtual ~MoonlightInputOwnedOperation() = default;
    virtual bool terminalRelease() const noexcept { return false; }
    virtual void execute() noexcept = 0;
};

class REMOTEDESK_MOONLIGHT_INPUT_HIDDEN MoonlightInputOwnerGate {
  public:
    virtual ~MoonlightInputOwnerGate() = default;
    virtual bool withOwner(const MoonlightInputIdentity& identity,
                           MoonlightInputOwnedOperation& operation) noexcept = 0;
};

class REMOTEDESK_MOONLIGHT_INPUT_HIDDEN MoonlightInputPort {
  public:
    virtual ~MoonlightInputPort() = default;
    virtual MoonlightInputPortStatus send(const MoonlightInputEvent& event) noexcept = 0;
    virtual bool flushNeutral(const MoonlightInputFlushRequest& request) noexcept = 0;
    virtual MoonlightInputPortStatus resetRemoteState(
        const MoonlightInputRecoveryResetRequest&) noexcept {
        return MoonlightInputPortStatus::Unsupported;
    }
};

REMOTEDESK_MOONLIGHT_INPUT_HIDDEN std::shared_ptr<MoonlightInputOwnerGate>
createMoonlightInputOwnerGate(MoonlightSessionOwner& sessionOwner,
                              Render::SessionSinkOwnerLease& sharedOwner) noexcept;

REMOTEDESK_MOONLIGHT_INPUT_HIDDEN std::shared_ptr<MoonlightInputOwnerGate>
createProcessMoonlightInputOwnerGate() noexcept;

class REMOTEDESK_MOONLIGHT_INPUT_HIDDEN MoonlightInputBridge final {
  private:
    struct Impl;
    explicit MoonlightInputBridge(std::unique_ptr<Impl> impl) noexcept;

  public:
    ~MoonlightInputBridge();
    MoonlightInputBridge(const MoonlightInputBridge&) = delete;
    MoonlightInputBridge& operator=(const MoonlightInputBridge&) = delete;

    static std::shared_ptr<MoonlightInputBridge> create(
        std::shared_ptr<MoonlightInputOwnerGate> ownerGate,
        std::shared_ptr<MoonlightInputPort> port,
        MoonlightInputLimits limits = {}) noexcept;

    MoonlightInputControlResult activate(const MoonlightInputIdentity& identity,
                                          std::uint64_t operationGeneration) noexcept;
    // Retries are admitted with the same operation generation. The port owns
    // exact progress, so already-enqueued reliable releases are never replayed.
    MoonlightInputControlResult resetRemoteState(
        const MoonlightInputRecoveryResetRequest& request) noexcept;
    MoonlightInputDispatchStatus dispatch(const MoonlightInputEvent& event) noexcept;
    // Atomically closes ordinary input admission before mapper release starts.
    // ReleasePending accepts only lifecycleRelease events at or before the
    // declared boundary; focusLost()/stop() later applies the remote neutral.
    MoonlightInputControlResult beginFlush(
        const MoonlightInputFlushRequest& request) noexcept;
    MoonlightInputControlResult focusLost(const MoonlightInputIdentity& identity,
                                           std::uint64_t operationGeneration,
                                           std::uint64_t monotonicTimestampUs) noexcept;
    MoonlightInputControlResult resume(const MoonlightInputIdentity& identity,
                                        std::uint64_t operationGeneration) noexcept;
    MoonlightInputControlResult stop(const MoonlightInputIdentity& identity,
                                      std::uint64_t operationGeneration,
                                      std::uint64_t monotonicTimestampUs) noexcept;
    // Terminal teardown fallback. It never calls the remote port and is used
    // only after local mapper state has been discarded.
    MoonlightInputControlResult stopLocally(
        const MoonlightInputIdentity& identity,
        std::uint64_t operationGeneration,
        std::uint64_t monotonicTimestampUs) noexcept;
    MoonlightInputControlResult cleanup(const MoonlightInputIdentity& identity,
                                         std::uint64_t operationGeneration) noexcept;
    MoonlightInputSnapshot snapshot(const MoonlightInputIdentity& identity) const noexcept;

  private:
    std::unique_ptr<Impl> impl_;
};

} // namespace remotedesk::moonlight

#undef REMOTEDESK_MOONLIGHT_INPUT_HIDDEN

#endif // REMOTEDESK_MOONLIGHT_INPUT_BRIDGE_H
