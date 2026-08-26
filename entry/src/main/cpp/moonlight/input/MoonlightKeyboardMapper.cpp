#include "moonlight/input/MoonlightKeyboardMapper.h"

#include <algorithm>
#include <limits>
#include <mutex>
#include <utility>

namespace remotedesk::moonlight {
namespace {

constexpr std::array<std::uint8_t, 4U> kModifierMasks{{0x01U, 0x02U, 0x04U, 0x08U}};
constexpr std::array<std::uint16_t, 4U> kLeftModifierKeys{{
    0x80A0U, 0x80A2U, 0x80A4U, 0x805BU,
}};
constexpr std::array<std::uint16_t, 4U> kRightModifierKeys{{
    0x80A1U, 0x80A3U, 0x80A5U, 0x805CU,
}};

std::uint64_t saturatingIncrement(std::uint64_t value) noexcept {
    return value == std::numeric_limits<std::uint64_t>::max() ? value : value + 1U;
}

MoonlightKeyboardMapping ordinaryMapping(std::uint16_t virtualKey) noexcept {
    return {true, static_cast<std::uint16_t>(kMoonlightKeyboardKeyPrefix | virtualKey),
            false, false, MoonlightKeyboardModifier::Shift};
}

MoonlightKeyboardMapping modifierMapping(std::uint16_t virtualKey,
                                         MoonlightKeyboardModifier modifier,
                                         bool rightSide) noexcept {
    return {true, static_cast<std::uint16_t>(kMoonlightKeyboardKeyPrefix | virtualKey),
            true, rightSide, modifier};
}

bool modifierIndex(MoonlightKeyboardModifier modifier, std::size_t& index) noexcept {
    switch (modifier) {
        case MoonlightKeyboardModifier::Shift:
            index = 0U;
            return true;
        case MoonlightKeyboardModifier::Control:
            index = 1U;
            return true;
        case MoonlightKeyboardModifier::Alt:
            index = 2U;
            return true;
        case MoonlightKeyboardModifier::Meta:
            index = 3U;
            return true;
    }
    return false;
}

bool knownLatch(MoonlightKeyboardLatch latch) noexcept {
    switch (latch) {
        case MoonlightKeyboardLatch::Off:
        case MoonlightKeyboardLatch::Once:
        case MoonlightKeyboardLatch::Locked:
            return true;
    }
    return false;
}

bool keyboardSource(MoonlightInputSource source) noexcept {
    return source == MoonlightInputSource::PhysicalKeyboard ||
        source == MoonlightInputSource::OnScreenKeyboard;
}

bool safeSourceSequence(std::uint64_t sequence) noexcept {
    if (sequence == 0U) {
        return false;
    }
    constexpr std::uint64_t stride =
        static_cast<std::uint64_t>(kMoonlightKeyboardSequenceStride);
    constexpr std::uint64_t commands =
        static_cast<std::uint64_t>(kMoonlightMaximumKeyboardTransactionCommands);
    constexpr std::uint64_t maximum = std::numeric_limits<std::uint64_t>::max();
    return sequence <= ((maximum - commands) / stride) + 1U;
}

std::uint64_t commandSequence(std::uint64_t sourceSequence,
                              std::size_t commandIndex) noexcept {
    return ((sourceSequence - 1U) *
            static_cast<std::uint64_t>(kMoonlightKeyboardSequenceStride)) +
        static_cast<std::uint64_t>(commandIndex) + 1U;
}

MoonlightKeyboardStatus keyboardStatus(MoonlightInputDispatchStatus status) noexcept {
    switch (status) {
        case MoonlightInputDispatchStatus::Accepted:
            return MoonlightKeyboardStatus::Applied;
        case MoonlightInputDispatchStatus::InvalidRequest:
            return MoonlightKeyboardStatus::InvalidRequest;
        case MoonlightInputDispatchStatus::InvalidState:
            return MoonlightKeyboardStatus::InvalidState;
        case MoonlightInputDispatchStatus::StaleOwner:
            return MoonlightKeyboardStatus::StaleOwner;
        case MoonlightInputDispatchStatus::StaleEvent:
            return MoonlightKeyboardStatus::StaleEvent;
        case MoonlightInputDispatchStatus::Duplicate:
            return MoonlightKeyboardStatus::Duplicate;
        case MoonlightInputDispatchStatus::SourceCapacity:
            return MoonlightKeyboardStatus::SourceCapacity;
        case MoonlightInputDispatchStatus::Backpressure:
            return MoonlightKeyboardStatus::Backpressure;
        case MoonlightInputDispatchStatus::Unsupported:
            return MoonlightKeyboardStatus::PortUnsupported;
        case MoonlightInputDispatchStatus::PortFailure:
            return MoonlightKeyboardStatus::PortFailure;
    }
    return MoonlightKeyboardStatus::PortFailure;
}

struct PressedKey final {
    bool occupied = false;
    std::uint16_t protocolKeyCode = 0U;
    std::uint64_t deviceId = 0U;
    std::uint8_t flags = 0U;
    std::uint64_t pressOrder = 0U;
};

struct ModifierState final {
    bool physicalLeftDown = false;
    bool physicalRightDown = false;
    bool remoteLeftDown = false;
    bool remoteRightDown = false;
    std::uint64_t physicalLeftDeviceId = 0U;
    std::uint64_t physicalRightDeviceId = 0U;
    std::uint8_t leftFlags = 0U;
    std::uint8_t rightFlags = 0U;
    MoonlightKeyboardLatch latch = MoonlightKeyboardLatch::Off;
};

struct KeyboardState final {
    std::array<PressedKey, kMoonlightMaximumPressedNonModifierKeys> pressed{};
    std::array<ModifierState, 4U> modifiers{};
    std::uint64_t nextPressOrder = 1U;
};

std::uint8_t remoteModifierMask(const KeyboardState& state) noexcept {
    std::uint8_t mask = 0U;
    for (std::size_t index = 0U; index < state.modifiers.size(); ++index) {
        if (state.modifiers[index].remoteLeftDown ||
            state.modifiers[index].remoteRightDown) {
            mask = static_cast<std::uint8_t>(mask | kModifierMasks[index]);
        }
    }
    return mask;
}

std::size_t pressedKeyCount(const KeyboardState& state) noexcept {
    std::size_t count = 0U;
    for (const PressedKey& key : state.pressed) {
        count += key.occupied ? 1U : 0U;
    }
    return count;
}

PressedKey* findPressedKey(KeyboardState& state, std::uint16_t protocolKeyCode) noexcept {
    for (PressedKey& key : state.pressed) {
        if (key.occupied && key.protocolKeyCode == protocolKeyCode) {
            return &key;
        }
    }
    return nullptr;
}

PressedKey* freePressedKey(KeyboardState& state, std::size_t limit) noexcept {
    for (std::size_t index = 0U; index < limit; ++index) {
        if (!state.pressed[index].occupied) {
            return &state.pressed[index];
        }
    }
    return nullptr;
}

bool anyLocalOrRemoteState(const KeyboardState& state) noexcept {
    if (pressedKeyCount(state) != 0U) {
        return true;
    }
    for (const ModifierState& modifier : state.modifiers) {
        if (modifier.physicalLeftDown || modifier.physicalRightDown ||
            modifier.remoteLeftDown || modifier.remoteRightDown ||
            modifier.latch != MoonlightKeyboardLatch::Off) {
            return true;
        }
    }
    return false;
}

bool textInputAllowed(const KeyboardState& state) noexcept {
    if (pressedKeyCount(state) != 0U || remoteModifierMask(state) != 0U) {
        return false;
    }
    for (const ModifierState& modifier : state.modifiers) {
        if (modifier.latch != MoonlightKeyboardLatch::Off) {
            return false;
        }
    }
    return true;
}

struct PendingCommand final {
    MoonlightInputEvent event{};
    KeyboardState stateAfter{};
};

struct PendingTransaction final {
    bool active = false;
    bool partialRecorded = false;
    std::array<PendingCommand, kMoonlightMaximumKeyboardTransactionCommands> commands{};
    std::size_t count = 0U;
    std::size_t index = 0U;
    std::size_t accepted = 0U;
};

bool appendKeyboardCommand(PendingTransaction& transaction,
                           const MoonlightKeyboardEventContext& context,
                           const KeyboardState& stateAfter,
                           std::uint16_t protocolKeyCode,
                           std::uint8_t action,
                           std::uint8_t modifiers,
                           std::uint8_t flags) noexcept {
    if (transaction.count >= transaction.commands.size()) {
        return false;
    }
    PendingCommand& command = transaction.commands[transaction.count];
    command = {};
    command.event.identity = context.identity;
    command.event.deviceId = context.deviceId;
    command.event.source = context.source;
    command.event.sourceGeneration = context.sourceGeneration;
    command.event.sourceSequence = commandSequence(context.sourceSequence,
                                                    transaction.count);
    command.event.monotonicTimestampUs = context.monotonicTimestampUs;
    command.event.kind = MoonlightInputCommandKind::Keyboard;
    command.event.commandVersion = 1U;
    command.event.payloadSize = kMoonlightKeyboardCommandBytes;
    command.event.payload[0] = action;
    command.event.payload[1] = static_cast<std::uint8_t>(protocolKeyCode & 0x00FFU);
    command.event.payload[2] = static_cast<std::uint8_t>((protocolKeyCode >> 8U) & 0x00FFU);
    command.event.payload[3] = modifiers;
    command.event.payload[4] = flags;
    command.stateAfter = stateAfter;
    ++transaction.count;
    return true;
}

bool appendTextCommand(PendingTransaction& transaction,
                       const MoonlightKeyboardEventContext& context,
                       const KeyboardState& stateAfter,
                       const std::uint8_t* text,
                       std::size_t size) noexcept {
    if (transaction.count >= transaction.commands.size()) {
        return false;
    }
    PendingCommand& command = transaction.commands[transaction.count];
    command = {};
    command.event.identity = context.identity;
    command.event.deviceId = context.deviceId;
    command.event.source = context.source;
    command.event.sourceGeneration = context.sourceGeneration;
    command.event.sourceSequence = commandSequence(context.sourceSequence,
                                                    transaction.count);
    command.event.monotonicTimestampUs = context.monotonicTimestampUs;
    command.event.kind = MoonlightInputCommandKind::Text;
    command.event.commandVersion = 1U;
    command.event.payloadSize = size;
    std::copy_n(text, size, command.event.payload.begin());
    command.stateAfter = stateAfter;
    ++transaction.count;
    return true;
}

} // namespace

MoonlightKeyboardMapping mapHarmonyKeyCodeToMoonlight(
    std::uint32_t harmonyKeyCode) noexcept {
    if (harmonyKeyCode >= 48U && harmonyKeyCode <= 57U) {
        return ordinaryMapping(static_cast<std::uint16_t>(harmonyKeyCode));
    }
    if (harmonyKeyCode >= 65U && harmonyKeyCode <= 90U) {
        return ordinaryMapping(static_cast<std::uint16_t>(harmonyKeyCode));
    }
    if (harmonyKeyCode >= 2000U && harmonyKeyCode <= 2009U) {
        return ordinaryMapping(static_cast<std::uint16_t>(
            0x30U + (harmonyKeyCode - 2000U)));
    }
    if (harmonyKeyCode >= 2017U && harmonyKeyCode <= 2042U) {
        return ordinaryMapping(static_cast<std::uint16_t>(
            0x41U + (harmonyKeyCode - 2017U)));
    }
    if (harmonyKeyCode >= 2090U && harmonyKeyCode <= 2101U) {
        return ordinaryMapping(static_cast<std::uint16_t>(
            0x70U + (harmonyKeyCode - 2090U)));
    }
    if (harmonyKeyCode >= 2816U && harmonyKeyCode <= 2827U) {
        return ordinaryMapping(static_cast<std::uint16_t>(
            0x7CU + (harmonyKeyCode - 2816U)));
    }
    if (harmonyKeyCode >= 2103U && harmonyKeyCode <= 2112U) {
        return ordinaryMapping(static_cast<std::uint16_t>(
            0x60U + (harmonyKeyCode - 2103U)));
    }

    switch (harmonyKeyCode) {
        case 2012U: return ordinaryMapping(0x26U);
        case 2013U: return ordinaryMapping(0x28U);
        case 2014U: return ordinaryMapping(0x25U);
        case 2015U: return ordinaryMapping(0x27U);
        case 2045U: return modifierMapping(0xA4U, MoonlightKeyboardModifier::Alt, false);
        case 2046U: return modifierMapping(0xA5U, MoonlightKeyboardModifier::Alt, true);
        case 2047U: return modifierMapping(0xA0U, MoonlightKeyboardModifier::Shift, false);
        case 2048U: return modifierMapping(0xA1U, MoonlightKeyboardModifier::Shift, true);
        case 2049U: return ordinaryMapping(0x09U);
        case 2050U: return ordinaryMapping(0x20U);
        case 2054U: return ordinaryMapping(0x0DU);
        case 2055U: return ordinaryMapping(0x08U);
        case 2067U: return ordinaryMapping(0x5DU);
        case 2068U: return ordinaryMapping(0x21U);
        case 2069U: return ordinaryMapping(0x22U);
        case 2070U: return ordinaryMapping(0x1BU);
        case 2071U: return ordinaryMapping(0x2EU);
        case 2072U: return modifierMapping(0xA2U, MoonlightKeyboardModifier::Control, false);
        case 2073U: return modifierMapping(0xA3U, MoonlightKeyboardModifier::Control, true);
        case 2074U: return ordinaryMapping(0x14U);
        case 2075U: return ordinaryMapping(0x91U);
        case 2076U: return modifierMapping(0x5BU, MoonlightKeyboardModifier::Meta, false);
        case 2077U: return modifierMapping(0x5CU, MoonlightKeyboardModifier::Meta, true);
        case 2079U: return ordinaryMapping(0x2CU);
        case 2080U: return ordinaryMapping(0x13U);
        case 2081U: return ordinaryMapping(0x24U);
        case 2082U: return ordinaryMapping(0x23U);
        case 2083U: return ordinaryMapping(0x2DU);
        case 2102U: return ordinaryMapping(0x90U);
        case 2113U: return ordinaryMapping(0x6FU);
        case 2114U: return ordinaryMapping(0x6AU);
        case 2115U: return ordinaryMapping(0x6DU);
        case 2116U: return ordinaryMapping(0x6BU);
        case 2117U: return ordinaryMapping(0x6EU);
        case 2119U: return ordinaryMapping(0x0DU);
        case 2120U: return ordinaryMapping(0xBBU);
        case 2043U:
        case 188U: return ordinaryMapping(0xBCU);
        case 2044U:
        case 190U: return ordinaryMapping(0xBEU);
        case 2056U:
        case 192U: return ordinaryMapping(0xC0U);
        case 2057U:
        case 189U: return ordinaryMapping(0xBDU);
        case 2058U:
        case 2066U:
        case 187U: return ordinaryMapping(0xBBU);
        case 2059U:
        case 219U: return ordinaryMapping(0xDBU);
        case 2060U:
        case 221U: return ordinaryMapping(0xDDU);
        case 2061U:
        case 220U: return ordinaryMapping(0xDCU);
        case 2062U:
        case 186U: return ordinaryMapping(0xBAU);
        case 2063U:
        case 222U: return ordinaryMapping(0xDEU);
        case 2064U:
        case 191U: return ordinaryMapping(0xBFU);
        case 2065U: return ordinaryMapping(0x32U);
        default: return {};
    }
}

bool decodeMoonlightKeyboardCommand(const MoonlightInputEvent& event,
                                    MoonlightKeyboardWireCommand& command) noexcept {
    if (!event.identity.valid() || event.deviceId == 0U ||
        !keyboardSource(event.source) || event.sourceGeneration == 0U ||
        event.sourceSequence == 0U || event.monotonicTimestampUs == 0U ||
        event.kind != MoonlightInputCommandKind::Keyboard ||
        event.commandVersion != 1U ||
        event.payloadSize != kMoonlightKeyboardCommandBytes ||
        (event.payload[0] != kMoonlightKeyboardActionDown &&
         event.payload[0] != kMoonlightKeyboardActionUp) ||
        event.payload[2] != 0x80U || (event.payload[3] & 0xF0U) != 0U ||
        (event.payload[4] & static_cast<std::uint8_t>(~kMoonlightKeyboardFlagNonNormalized)) !=
            0U) {
        return false;
    }
    for (std::size_t index = event.payloadSize; index < event.payload.size(); ++index) {
        if (event.payload[index] != 0U) {
            return false;
        }
    }
    command.protocolKeyCode = static_cast<std::uint16_t>(
        static_cast<std::uint16_t>(event.payload[1]) |
        (static_cast<std::uint16_t>(event.payload[2]) << 8U));
    command.action = event.payload[0];
    command.modifiers = event.payload[3];
    command.flags = event.payload[4];
    return true;
}

bool validateMoonlightUtf8Text(const std::uint8_t* text,
                               std::size_t size,
                               std::size_t maximumBytes) noexcept {
    if (text == nullptr || size == 0U || maximumBytes == 0U ||
        maximumBytes > kMoonlightMaximumInputPayloadBytes || size > maximumBytes) {
        return false;
    }
    std::size_t index = 0U;
    while (index < size) {
        const std::uint8_t lead = text[index];
        if (lead == 0U) {
            return false;
        }
        if (lead <= 0x7FU) {
            ++index;
            continue;
        }

        std::size_t continuationCount = 0U;
        std::uint32_t codePoint = 0U;
        std::uint32_t minimum = 0U;
        if (lead >= 0xC2U && lead <= 0xDFU) {
            continuationCount = 1U;
            codePoint = static_cast<std::uint32_t>(lead & 0x1FU);
            minimum = 0x80U;
        } else if (lead >= 0xE0U && lead <= 0xEFU) {
            continuationCount = 2U;
            codePoint = static_cast<std::uint32_t>(lead & 0x0FU);
            minimum = 0x800U;
        } else if (lead >= 0xF0U && lead <= 0xF4U) {
            continuationCount = 3U;
            codePoint = static_cast<std::uint32_t>(lead & 0x07U);
            minimum = 0x10000U;
        } else {
            return false;
        }
        if (continuationCount > size - index - 1U) {
            return false;
        }
        for (std::size_t offset = 1U; offset <= continuationCount; ++offset) {
            const std::uint8_t continuation = text[index + offset];
            if ((continuation & 0xC0U) != 0x80U) {
                return false;
            }
            codePoint = (codePoint << 6U) |
                static_cast<std::uint32_t>(continuation & 0x3FU);
        }
        if (codePoint < minimum || codePoint > 0x10FFFFU ||
            (codePoint >= 0xD800U && codePoint <= 0xDFFFU)) {
            return false;
        }
        index += continuationCount + 1U;
    }
    return true;
}

struct MoonlightKeyboardMapper::Impl final {
    Impl(std::shared_ptr<MoonlightInputBridge> valueBridge,
         const MoonlightInputIdentity& valueIdentity,
         MoonlightKeyboardLimits valueLimits) noexcept
        : bridge(std::move(valueBridge)), identity(valueIdentity), limits(valueLimits) {}

    MoonlightKeyboardResult result(MoonlightKeyboardStatus status,
                                   MoonlightInputDispatchStatus dispatch =
                                       MoonlightInputDispatchStatus::InvalidRequest,
                                   std::size_t accepted = 0U,
                                   std::size_t remaining = 0U) const noexcept {
        return {status, dispatch, accepted, remaining};
    }

    MoonlightKeyboardResult invalidResult() noexcept {
        invalidRequests = saturatingIncrement(invalidRequests);
        return result(MoonlightKeyboardStatus::InvalidRequest);
    }

    MoonlightKeyboardResult contextResult(const MoonlightKeyboardEventContext& context,
                                          MoonlightInputSource required) noexcept {
        if (!context.valid() || context.source != required ||
            !safeSourceSequence(context.sourceSequence)) {
            return invalidResult();
        }
        if (context.identity != identity) {
            return result(MoonlightKeyboardStatus::StaleOwner,
                          MoonlightInputDispatchStatus::StaleOwner);
        }
        return result(MoonlightKeyboardStatus::Applied,
                      MoonlightInputDispatchStatus::Accepted);
    }

    MoonlightKeyboardResult keyboardContextResult(
        const MoonlightKeyboardEventContext& context) noexcept {
        if (!context.valid() || !keyboardSource(context.source) ||
            !safeSourceSequence(context.sourceSequence)) {
            return invalidResult();
        }
        if (context.identity != identity) {
            return result(MoonlightKeyboardStatus::StaleOwner,
                          MoonlightInputDispatchStatus::StaleOwner);
        }
        return result(MoonlightKeyboardStatus::Applied,
                      MoonlightInputDispatchStatus::Accepted);
    }

    MoonlightKeyboardResult pendingResult() const noexcept {
        return result(MoonlightKeyboardStatus::Pending,
                      MoonlightInputDispatchStatus::Backpressure,
                      pending.accepted, pending.count - pending.index);
    }

    MoonlightKeyboardResult drivePending() noexcept {
        if (!pending.active || bridge == nullptr || pending.count == 0U ||
            pending.index >= pending.count) {
            return result(MoonlightKeyboardStatus::InvalidState,
                          MoonlightInputDispatchStatus::InvalidState);
        }
        while (pending.index < pending.count) {
            const MoonlightInputDispatchStatus dispatch =
                bridge->dispatch(pending.commands[pending.index].event);
            if (dispatch != MoonlightInputDispatchStatus::Accepted) {
                if (pending.accepted != 0U && !pending.partialRecorded) {
                    partialTransactions = saturatingIncrement(partialTransactions);
                    pending.partialRecorded = true;
                }
                return result(keyboardStatus(dispatch), dispatch, pending.accepted,
                              pending.count - pending.index);
            }
            state = pending.commands[pending.index].stateAfter;
            ++pending.index;
            ++pending.accepted;
        }
        const std::size_t accepted = pending.accepted;
        pending = {};
        appliedTransactions = saturatingIncrement(appliedTransactions);
        return result(MoonlightKeyboardStatus::Applied,
                      MoonlightInputDispatchStatus::Accepted, accepted, 0U);
    }

    MoonlightKeyboardResult dispatchTransaction(PendingTransaction& transaction) noexcept {
        if (transaction.count == 0U) {
            return invalidResult();
        }
        transaction.active = true;
        pending = transaction;
        transaction = {};
        return drivePending();
    }

    mutable std::mutex mutex;
    std::shared_ptr<MoonlightInputBridge> bridge;
    MoonlightInputIdentity identity{};
    MoonlightKeyboardLimits limits{};
    KeyboardState state{};
    PendingTransaction pending{};
    std::uint64_t localEscapeEvents = 0U;
    std::uint64_t appliedTransactions = 0U;
    std::uint64_t partialTransactions = 0U;
    std::uint64_t invalidRequests = 0U;
    std::uint64_t unsupportedKeys = 0U;
    std::uint64_t duplicateEvents = 0U;
};

MoonlightKeyboardMapper::MoonlightKeyboardMapper(std::unique_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}

MoonlightKeyboardMapper::~MoonlightKeyboardMapper() {
    if (impl_ == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->pending = {};
    impl_->state = {};
    impl_->identity = {};
}

std::shared_ptr<MoonlightKeyboardMapper> MoonlightKeyboardMapper::create(
    std::shared_ptr<MoonlightInputBridge> bridge,
    const MoonlightInputIdentity& identity,
    MoonlightKeyboardLimits limits) noexcept {
    if (bridge == nullptr || !identity.valid() ||
        limits.maximumPressedNonModifierKeys == 0U ||
        limits.maximumPressedNonModifierKeys > kMoonlightMaximumPressedNonModifierKeys ||
        limits.maximumTextBytes == 0U ||
        limits.maximumTextBytes > kMoonlightMaximumInputPayloadBytes) {
        return nullptr;
    }
    const MoonlightInputSnapshot bridgeSnapshot = bridge->snapshot(identity);
    if (!bridgeSnapshot.matched || bridgeSnapshot.state != MoonlightInputState::Active) {
        return nullptr;
    }
    try {
        return std::shared_ptr<MoonlightKeyboardMapper>(new MoonlightKeyboardMapper(
            std::make_unique<Impl>(std::move(bridge), identity, limits)));
    } catch (...) {
        return nullptr;
    }
}

MoonlightKeyboardResult MoonlightKeyboardMapper::physicalKey(
    const MoonlightKeyboardEventContext& context,
    std::uint32_t harmonyKeyCode,
    bool pressed,
    bool normalizedToUsLayout) noexcept {
    if (impl_ == nullptr) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const MoonlightKeyboardResult contextStatus =
        impl_->contextResult(context, MoonlightInputSource::PhysicalKeyboard);
    if (contextStatus.status != MoonlightKeyboardStatus::Applied) {
        return contextStatus;
    }
    if (impl_->pending.active) {
        return impl_->pendingResult();
    }

    const MoonlightKeyboardMapping mapping = mapHarmonyKeyCodeToMoonlight(harmonyKeyCode);
    if (!mapping.supported) {
        impl_->unsupportedKeys = saturatingIncrement(impl_->unsupportedKeys);
        return impl_->result(MoonlightKeyboardStatus::UnsupportedKey);
    }
    const std::uint8_t flags = normalizedToUsLayout ? 0U :
        kMoonlightKeyboardFlagNonNormalized;
    KeyboardState candidate = impl_->state;
    PendingTransaction transaction;
    if (!mapping.modifier) {
        PressedKey* existing = findPressedKey(candidate, mapping.protocolKeyCode);
        if (pressed) {
            if (existing != nullptr) {
                impl_->duplicateEvents = saturatingIncrement(impl_->duplicateEvents);
                return impl_->result(MoonlightKeyboardStatus::Duplicate);
            }
            PressedKey* slot = freePressedKey(candidate,
                                              impl_->limits.maximumPressedNonModifierKeys);
            if (slot == nullptr) {
                return impl_->result(MoonlightKeyboardStatus::KeyCapacity);
            }
            slot->occupied = true;
            slot->protocolKeyCode = mapping.protocolKeyCode;
            slot->deviceId = context.deviceId;
            slot->flags = flags;
            slot->pressOrder = candidate.nextPressOrder;
            candidate.nextPressOrder = saturatingIncrement(candidate.nextPressOrder);
            (void)appendKeyboardCommand(transaction, context, candidate,
                                        mapping.protocolKeyCode,
                                        kMoonlightKeyboardActionDown,
                                        remoteModifierMask(candidate), flags);
        } else {
            if (existing == nullptr || existing->deviceId != context.deviceId) {
                return impl_->result(MoonlightKeyboardStatus::NotPressed);
            }
            const std::uint8_t storedFlags = existing->flags;
            *existing = {};
            (void)appendKeyboardCommand(transaction, context, candidate,
                                        mapping.protocolKeyCode,
                                        kMoonlightKeyboardActionUp,
                                        remoteModifierMask(candidate), storedFlags);
        }
        return impl_->dispatchTransaction(transaction);
    }

    std::size_t index = 0U;
    if (!modifierIndex(mapping.modifierKind, index)) {
        return impl_->invalidResult();
    }
    ModifierState& modifier = candidate.modifiers[index];
    bool& physicalDown = mapping.rightSide ? modifier.physicalRightDown :
        modifier.physicalLeftDown;
    std::uint64_t& physicalDeviceId = mapping.rightSide ?
        modifier.physicalRightDeviceId : modifier.physicalLeftDeviceId;
    bool& remoteDown = mapping.rightSide ? modifier.remoteRightDown :
        modifier.remoteLeftDown;
    std::uint8_t& storedFlags = mapping.rightSide ? modifier.rightFlags : modifier.leftFlags;
    if (pressed) {
        if (physicalDown) {
            impl_->duplicateEvents = saturatingIncrement(impl_->duplicateEvents);
            return impl_->result(MoonlightKeyboardStatus::Duplicate);
        }
        physicalDown = true;
        physicalDeviceId = context.deviceId;
        if (remoteDown) {
            impl_->state = candidate;
            return impl_->result(MoonlightKeyboardStatus::AppliedLocally,
                                 MoonlightInputDispatchStatus::Accepted);
        }
        remoteDown = true;
        storedFlags = flags;
        (void)appendKeyboardCommand(transaction, context, candidate,
                                    mapping.protocolKeyCode,
                                    kMoonlightKeyboardActionDown,
                                    remoteModifierMask(candidate), flags);
    } else {
        if (!physicalDown || physicalDeviceId != context.deviceId) {
            return impl_->result(MoonlightKeyboardStatus::NotPressed);
        }
        physicalDown = false;
        physicalDeviceId = 0U;
        const bool retainedByLatch = !mapping.rightSide &&
            modifier.latch != MoonlightKeyboardLatch::Off;
        if (!remoteDown || retainedByLatch) {
            impl_->state = candidate;
            return impl_->result(MoonlightKeyboardStatus::AppliedLocally,
                                 MoonlightInputDispatchStatus::Accepted);
        }
        remoteDown = false;
        (void)appendKeyboardCommand(transaction, context, candidate,
                                    mapping.protocolKeyCode,
                                    kMoonlightKeyboardActionUp,
                                    remoteModifierMask(candidate), storedFlags);
    }
    return impl_->dispatchTransaction(transaction);
}

MoonlightKeyboardResult MoonlightKeyboardMapper::virtualKeyTap(
    const MoonlightKeyboardEventContext& context,
    std::uint32_t harmonyKeyCode) noexcept {
    if (impl_ == nullptr) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const MoonlightKeyboardResult contextStatus =
        impl_->contextResult(context, MoonlightInputSource::OnScreenKeyboard);
    if (contextStatus.status != MoonlightKeyboardStatus::Applied) {
        return contextStatus;
    }
    if (impl_->pending.active) {
        return impl_->pendingResult();
    }
    const MoonlightKeyboardMapping mapping = mapHarmonyKeyCodeToMoonlight(harmonyKeyCode);
    if (!mapping.supported) {
        impl_->unsupportedKeys = saturatingIncrement(impl_->unsupportedKeys);
        return impl_->result(MoonlightKeyboardStatus::UnsupportedKey);
    }
    if (mapping.modifier) {
        return impl_->invalidResult();
    }
    if (findPressedKey(impl_->state, mapping.protocolKeyCode) != nullptr) {
        impl_->duplicateEvents = saturatingIncrement(impl_->duplicateEvents);
        return impl_->result(MoonlightKeyboardStatus::Duplicate);
    }

    KeyboardState candidate = impl_->state;
    PendingTransaction transaction;
    for (std::size_t index = 0U; index < candidate.modifiers.size(); ++index) {
        ModifierState& modifier = candidate.modifiers[index];
        if (modifier.latch != MoonlightKeyboardLatch::Off && !modifier.remoteLeftDown) {
            modifier.remoteLeftDown = true;
            modifier.leftFlags = kMoonlightKeyboardFlagNonNormalized;
            (void)appendKeyboardCommand(transaction, context, candidate,
                                        kLeftModifierKeys[index],
                                        kMoonlightKeyboardActionDown,
                                        remoteModifierMask(candidate),
                                        modifier.leftFlags);
        }
    }
    (void)appendKeyboardCommand(transaction, context, candidate,
                                mapping.protocolKeyCode,
                                kMoonlightKeyboardActionDown,
                                remoteModifierMask(candidate),
                                kMoonlightKeyboardFlagNonNormalized);
    (void)appendKeyboardCommand(transaction, context, candidate,
                                mapping.protocolKeyCode,
                                kMoonlightKeyboardActionUp,
                                remoteModifierMask(candidate),
                                kMoonlightKeyboardFlagNonNormalized);
    for (std::size_t reverse = candidate.modifiers.size(); reverse > 0U; --reverse) {
        const std::size_t index = reverse - 1U;
        ModifierState& modifier = candidate.modifiers[index];
        if (modifier.latch != MoonlightKeyboardLatch::Once) {
            continue;
        }
        modifier.latch = MoonlightKeyboardLatch::Off;
        if (!modifier.physicalLeftDown && modifier.remoteLeftDown) {
            const std::uint8_t releaseFlags = modifier.leftFlags;
            modifier.remoteLeftDown = false;
            (void)appendKeyboardCommand(transaction, context, candidate,
                                        kLeftModifierKeys[index],
                                        kMoonlightKeyboardActionUp,
                                        remoteModifierMask(candidate), releaseFlags);
        }
    }
    transaction.commands[transaction.count - 1U].stateAfter = candidate;
    return impl_->dispatchTransaction(transaction);
}

MoonlightKeyboardResult MoonlightKeyboardMapper::setModifierLatch(
    const MoonlightKeyboardEventContext& context,
    MoonlightKeyboardModifier modifierKind,
    MoonlightKeyboardLatch latch) noexcept {
    if (impl_ == nullptr) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const MoonlightKeyboardResult contextStatus =
        impl_->contextResult(context, MoonlightInputSource::OnScreenKeyboard);
    if (contextStatus.status != MoonlightKeyboardStatus::Applied) {
        return contextStatus;
    }
    std::size_t index = 0U;
    if (!modifierIndex(modifierKind, index) || !knownLatch(latch)) {
        return impl_->invalidResult();
    }
    if (impl_->pending.active) {
        return impl_->pendingResult();
    }
    if (impl_->state.modifiers[index].latch == latch) {
        return impl_->result(MoonlightKeyboardStatus::AlreadyApplied,
                             MoonlightInputDispatchStatus::Accepted);
    }

    KeyboardState candidate = impl_->state;
    ModifierState& modifier = candidate.modifiers[index];
    modifier.latch = latch;
    PendingTransaction transaction;
    if (latch == MoonlightKeyboardLatch::Locked && !modifier.remoteLeftDown) {
        modifier.remoteLeftDown = true;
        modifier.leftFlags = kMoonlightKeyboardFlagNonNormalized;
        (void)appendKeyboardCommand(transaction, context, candidate,
                                    kLeftModifierKeys[index],
                                    kMoonlightKeyboardActionDown,
                                    remoteModifierMask(candidate), modifier.leftFlags);
    } else if (latch == MoonlightKeyboardLatch::Off &&
               modifier.remoteLeftDown && !modifier.physicalLeftDown) {
        const std::uint8_t releaseFlags = modifier.leftFlags;
        modifier.remoteLeftDown = false;
        (void)appendKeyboardCommand(transaction, context, candidate,
                                    kLeftModifierKeys[index],
                                    kMoonlightKeyboardActionUp,
                                    remoteModifierMask(candidate), releaseFlags);
    }
    if (transaction.count == 0U) {
        impl_->state = candidate;
        return impl_->result(MoonlightKeyboardStatus::AppliedLocally,
                             MoonlightInputDispatchStatus::Accepted);
    }
    return impl_->dispatchTransaction(transaction);
}

MoonlightKeyboardResult MoonlightKeyboardMapper::commitText(
    const MoonlightKeyboardEventContext& context,
    const std::uint8_t* text,
    std::size_t size) noexcept {
    if (impl_ == nullptr) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const MoonlightKeyboardResult contextStatus =
        impl_->contextResult(context, MoonlightInputSource::OnScreenKeyboard);
    if (contextStatus.status != MoonlightKeyboardStatus::Applied) {
        return contextStatus;
    }
    if (impl_->pending.active) {
        return impl_->pendingResult();
    }
    if (!validateMoonlightUtf8Text(text, size, impl_->limits.maximumTextBytes)) {
        return impl_->invalidResult();
    }
    if (!textInputAllowed(impl_->state)) {
        return impl_->result(MoonlightKeyboardStatus::InvalidState,
                             MoonlightInputDispatchStatus::InvalidState);
    }
    PendingTransaction transaction;
    (void)appendTextCommand(transaction, context, impl_->state, text, size);
    return impl_->dispatchTransaction(transaction);
}

MoonlightKeyboardResult MoonlightKeyboardMapper::releaseAll(
    const MoonlightKeyboardEventContext& context) noexcept {
    if (impl_ == nullptr) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const MoonlightKeyboardResult contextStatus = impl_->keyboardContextResult(context);
    if (contextStatus.status != MoonlightKeyboardStatus::Applied) {
        return contextStatus;
    }
    if (impl_->pending.active) {
        return impl_->pendingResult();
    }
    if (!anyLocalOrRemoteState(impl_->state)) {
        return impl_->result(MoonlightKeyboardStatus::AlreadyApplied,
                             MoonlightInputDispatchStatus::Accepted);
    }

    KeyboardState candidate = impl_->state;
    PendingTransaction transaction;
    while (pressedKeyCount(candidate) != 0U) {
        PressedKey* latest = nullptr;
        for (PressedKey& key : candidate.pressed) {
            if (key.occupied && (latest == nullptr || key.pressOrder > latest->pressOrder)) {
                latest = &key;
            }
        }
        if (latest == nullptr) {
            break;
        }
        const std::uint16_t keyCode = latest->protocolKeyCode;
        const std::uint8_t flags = latest->flags;
        *latest = {};
        (void)appendKeyboardCommand(transaction, context, candidate, keyCode,
                                    kMoonlightKeyboardActionUp,
                                    remoteModifierMask(candidate), flags);
    }

    for (ModifierState& modifier : candidate.modifiers) {
        modifier.latch = MoonlightKeyboardLatch::Off;
    }
    for (std::size_t reverse = candidate.modifiers.size(); reverse > 0U; --reverse) {
        const std::size_t index = reverse - 1U;
        ModifierState& modifier = candidate.modifiers[index];
        modifier.physicalRightDown = false;
        modifier.physicalRightDeviceId = 0U;
        if (modifier.remoteRightDown) {
            const std::uint8_t flags = modifier.rightFlags;
            modifier.remoteRightDown = false;
            (void)appendKeyboardCommand(transaction, context, candidate,
                                        kRightModifierKeys[index],
                                        kMoonlightKeyboardActionUp,
                                        remoteModifierMask(candidate), flags);
        }
        modifier.physicalLeftDown = false;
        modifier.physicalLeftDeviceId = 0U;
        if (modifier.remoteLeftDown) {
            const std::uint8_t flags = modifier.leftFlags;
            modifier.remoteLeftDown = false;
            (void)appendKeyboardCommand(transaction, context, candidate,
                                        kLeftModifierKeys[index],
                                        kMoonlightKeyboardActionUp,
                                        remoteModifierMask(candidate), flags);
        }
    }
    candidate.nextPressOrder = 1U;
    if (transaction.count == 0U) {
        impl_->state = candidate;
        return impl_->result(MoonlightKeyboardStatus::AppliedLocally,
                             MoonlightInputDispatchStatus::Accepted);
    }
    for (std::size_t index = 0U; index < transaction.count; ++index) {
        transaction.commands[index].event.lifecycleRelease = true;
    }
    transaction.commands[transaction.count - 1U].stateAfter = candidate;
    return impl_->dispatchTransaction(transaction);
}

MoonlightKeyboardResult MoonlightKeyboardMapper::resumePending() noexcept {
    if (impl_ == nullptr) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    return impl_->drivePending();
}

bool MoonlightKeyboardMapper::cancelPendingIfUnsent(
    const MoonlightInputIdentity& identity) noexcept {
    if (impl_ == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (identity != impl_->identity || !impl_->pending.active ||
        impl_->pending.accepted != 0U) {
        return false;
    }
    impl_->pending = {};
    return true;
}

bool MoonlightKeyboardMapper::discardLocalState(
    const MoonlightInputIdentity& identity) noexcept {
    if (impl_ == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (identity != impl_->identity) {
        return false;
    }
    impl_->pending = {};
    impl_->state = {};
    return true;
}

MoonlightKeyboardSnapshot MoonlightKeyboardMapper::snapshot(
    const MoonlightInputIdentity& identity) const noexcept {
    MoonlightKeyboardSnapshot result;
    if (impl_ == nullptr) {
        return result;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (identity != impl_->identity) {
        return result;
    }
    result.matched = true;
    result.identity = impl_->identity;
    result.pressedNonModifierKeys = pressedKeyCount(impl_->state);
    result.remoteModifierMask = remoteModifierMask(impl_->state);
    for (std::size_t index = 0U; index < result.latches.size(); ++index) {
        result.latches[index] = impl_->state.modifiers[index].latch;
    }
    result.pending = impl_->pending.active;
    result.pendingCommands = impl_->pending.active ?
        impl_->pending.count - impl_->pending.index : 0U;
    result.acceptedPendingCommands = impl_->pending.active ? impl_->pending.accepted : 0U;
    result.localEscapeEvents = impl_->localEscapeEvents;
    result.appliedTransactions = impl_->appliedTransactions;
    result.partialTransactions = impl_->partialTransactions;
    result.invalidRequests = impl_->invalidRequests;
    result.unsupportedKeys = impl_->unsupportedKeys;
    result.duplicateEvents = impl_->duplicateEvents;
    return result;
}

} // namespace remotedesk::moonlight
