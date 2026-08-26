#ifndef REMOTEDESK_MOONLIGHT_KEYBOARD_MAPPER_H
#define REMOTEDESK_MOONLIGHT_KEYBOARD_MAPPER_H

#include "moonlight/input/MoonlightInputBridge.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>

#if defined(__GNUC__) || defined(__clang__)
#define REMOTEDESK_MOONLIGHT_KEYBOARD_HIDDEN __attribute__((visibility("hidden")))
#else
#define REMOTEDESK_MOONLIGHT_KEYBOARD_HIDDEN
#endif

namespace remotedesk::moonlight {

constexpr std::uint16_t kMoonlightKeyboardKeyPrefix = 0x8000U;
constexpr std::uint8_t kMoonlightKeyboardActionDown = 0x03U;
constexpr std::uint8_t kMoonlightKeyboardActionUp = 0x04U;
constexpr std::uint8_t kMoonlightKeyboardFlagNonNormalized = 0x01U;
constexpr std::size_t kMoonlightKeyboardCommandBytes = 5U;
// One high-level operation can release eight ordinary keys plus both sides
// of all four modifiers. A 32-sequence lane keeps adjacent operations apart.
constexpr std::size_t kMoonlightKeyboardSequenceStride = 32U;
constexpr std::size_t kMoonlightMaximumPressedNonModifierKeys = 8U;
constexpr std::size_t kMoonlightMaximumKeyboardTransactionCommands = 16U;

enum class MoonlightKeyboardModifier : std::uint8_t {
    Shift = 0,
    Control,
    Alt,
    Meta,
};

enum class MoonlightKeyboardLatch : std::uint8_t {
    Off = 0,
    Once,
    Locked,
};

enum class MoonlightKeyboardStatus : std::uint8_t {
    Applied = 0,
    AppliedLocally,
    AlreadyApplied,
    LocalEscape,
    InvalidRequest,
    InvalidState,
    StaleOwner,
    StaleEvent,
    Duplicate,
    NotPressed,
    UnsupportedKey,
    KeyCapacity,
    SourceCapacity,
    Backpressure,
    PortUnsupported,
    PortFailure,
    Pending,
};

struct REMOTEDESK_MOONLIGHT_KEYBOARD_HIDDEN MoonlightKeyboardMapping final {
    bool supported = false;
    std::uint16_t protocolKeyCode = 0U;
    bool modifier = false;
    bool rightSide = false;
    MoonlightKeyboardModifier modifierKind = MoonlightKeyboardModifier::Shift;
};

struct REMOTEDESK_MOONLIGHT_KEYBOARD_HIDDEN MoonlightKeyboardEventContext final {
    MoonlightInputIdentity identity{};
    std::uint64_t deviceId = 0U;
    MoonlightInputSource source = MoonlightInputSource::Invalid;
    std::uint64_t sourceGeneration = 0U;
    std::uint64_t sourceSequence = 0U;
    std::uint64_t monotonicTimestampUs = 0U;

    constexpr bool valid() const noexcept {
        return identity.valid() && deviceId != 0U && sourceGeneration != 0U &&
            sourceSequence != 0U && monotonicTimestampUs != 0U;
    }
};

struct REMOTEDESK_MOONLIGHT_KEYBOARD_HIDDEN MoonlightKeyboardWireCommand final {
    std::uint16_t protocolKeyCode = 0U;
    std::uint8_t action = 0U;
    std::uint8_t modifiers = 0U;
    std::uint8_t flags = 0U;
};

struct REMOTEDESK_MOONLIGHT_KEYBOARD_HIDDEN MoonlightKeyboardLimits final {
    std::size_t maximumPressedNonModifierKeys = kMoonlightMaximumPressedNonModifierKeys;
    std::size_t maximumTextBytes = kMoonlightMaximumInputPayloadBytes;
};

struct REMOTEDESK_MOONLIGHT_KEYBOARD_HIDDEN MoonlightKeyboardResult final {
    MoonlightKeyboardStatus status = MoonlightKeyboardStatus::InvalidRequest;
    MoonlightInputDispatchStatus dispatchStatus = MoonlightInputDispatchStatus::InvalidRequest;
    std::size_t acceptedCommands = 0U;
    std::size_t pendingCommands = 0U;
};

struct REMOTEDESK_MOONLIGHT_KEYBOARD_HIDDEN MoonlightKeyboardSnapshot final {
    bool matched = false;
    MoonlightInputIdentity identity{};
    std::size_t pressedNonModifierKeys = 0U;
    std::uint8_t remoteModifierMask = 0U;
    std::array<MoonlightKeyboardLatch, 4U> latches{};
    bool pending = false;
    std::size_t pendingCommands = 0U;
    std::size_t acceptedPendingCommands = 0U;
    std::uint64_t localEscapeEvents = 0U;
    std::uint64_t appliedTransactions = 0U;
    std::uint64_t partialTransactions = 0U;
    std::uint64_t invalidRequests = 0U;
    std::uint64_t unsupportedKeys = 0U;
    std::uint64_t duplicateEvents = 0U;
};

REMOTEDESK_MOONLIGHT_KEYBOARD_HIDDEN MoonlightKeyboardMapping
mapHarmonyKeyCodeToMoonlight(std::uint32_t harmonyKeyCode) noexcept;

REMOTEDESK_MOONLIGHT_KEYBOARD_HIDDEN bool decodeMoonlightKeyboardCommand(
    const MoonlightInputEvent& event,
    MoonlightKeyboardWireCommand& command) noexcept;

REMOTEDESK_MOONLIGHT_KEYBOARD_HIDDEN bool validateMoonlightUtf8Text(
    const std::uint8_t* text,
    std::size_t size,
    std::size_t maximumBytes = kMoonlightMaximumInputPayloadBytes) noexcept;

class REMOTEDESK_MOONLIGHT_KEYBOARD_HIDDEN MoonlightKeyboardMapper final {
  private:
    struct Impl;
    explicit MoonlightKeyboardMapper(std::unique_ptr<Impl> impl) noexcept;

  public:
    ~MoonlightKeyboardMapper();
    MoonlightKeyboardMapper(const MoonlightKeyboardMapper&) = delete;
    MoonlightKeyboardMapper& operator=(const MoonlightKeyboardMapper&) = delete;

    static std::shared_ptr<MoonlightKeyboardMapper> create(
        std::shared_ptr<MoonlightInputBridge> bridge,
        const MoonlightInputIdentity& identity,
        MoonlightKeyboardLimits limits = {}) noexcept;

    // Physical keys, including Escape and Meta/Win, are remote input. Local
    // session exit remains owned by the system Back gesture and toolbar.
    MoonlightKeyboardResult physicalKey(const MoonlightKeyboardEventContext& context,
                                         std::uint32_t harmonyKeyCode,
                                         bool pressed,
                                         bool normalizedToUsLayout) noexcept;
    MoonlightKeyboardResult virtualKeyTap(const MoonlightKeyboardEventContext& context,
                                           std::uint32_t harmonyKeyCode) noexcept;
    MoonlightKeyboardResult setModifierLatch(
        const MoonlightKeyboardEventContext& context,
        MoonlightKeyboardModifier modifier,
        MoonlightKeyboardLatch latch) noexcept;
    MoonlightKeyboardResult commitText(const MoonlightKeyboardEventContext& context,
                                        const std::uint8_t* text,
                                        std::size_t size) noexcept;
    MoonlightKeyboardResult releaseAll(const MoonlightKeyboardEventContext& context) noexcept;

    // A transaction that reached backpressure or a port failure keeps the
    // exact next event. resumePending() retries that event without allocating,
    // reordering, or replaying the already accepted prefix.
    MoonlightKeyboardResult resumePending() noexcept;
    bool cancelPendingIfUnsent(const MoonlightInputIdentity& identity) noexcept;
    // Terminal-only fallback after the remote release path can no longer
    // complete. Clears pending commands and all pressed/latch state locally.
    bool discardLocalState(const MoonlightInputIdentity& identity) noexcept;
    MoonlightKeyboardSnapshot snapshot(const MoonlightInputIdentity& identity) const noexcept;

  private:
    std::unique_ptr<Impl> impl_;
};

} // namespace remotedesk::moonlight

#undef REMOTEDESK_MOONLIGHT_KEYBOARD_HIDDEN

#endif // REMOTEDESK_MOONLIGHT_KEYBOARD_MAPPER_H
