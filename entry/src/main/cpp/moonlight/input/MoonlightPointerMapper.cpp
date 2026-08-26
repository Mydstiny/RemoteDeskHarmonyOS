#include "moonlight/input/MoonlightPointerMapper.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <mutex>
#include <utility>

namespace remotedesk::moonlight {
namespace {

constexpr std::uint16_t kMaximumPointerCoordinate =
    static_cast<std::uint16_t>(std::numeric_limits<std::int16_t>::max());
constexpr double kMaximumRelativeSensitivity = 100.0;

std::uint64_t saturatingIncrement(std::uint64_t value) noexcept {
    return value == std::numeric_limits<std::uint64_t>::max() ? value : value + 1U;
}

bool pointerSource(MoonlightInputSource source) noexcept {
    return source == MoonlightInputSource::Mouse ||
        source == MoonlightInputSource::Touchpad;
}

bool knownMode(MoonlightPointerMode mode) noexcept {
    switch (mode) {
        case MoonlightPointerMode::Absolute:
        case MoonlightPointerMode::Relative:
            return true;
    }
    return false;
}

bool buttonIndex(MoonlightPointerButton button, std::size_t& index) noexcept {
    switch (button) {
        case MoonlightPointerButton::Left:
            index = 0U;
            return true;
        case MoonlightPointerButton::Middle:
            index = 1U;
            return true;
        case MoonlightPointerButton::Right:
            index = 2U;
            return true;
        case MoonlightPointerButton::X1:
            index = 3U;
            return true;
        case MoonlightPointerButton::X2:
            index = 4U;
            return true;
    }
    return false;
}

bool safeSourceSequence(std::uint64_t sequence) noexcept {
    if (sequence == 0U) {
        return false;
    }
    constexpr std::uint64_t stride =
        static_cast<std::uint64_t>(kMoonlightPointerSequenceStride);
    constexpr std::uint64_t commands =
        static_cast<std::uint64_t>(kMoonlightMaximumPointerTransactionCommands);
    constexpr std::uint64_t maximum = std::numeric_limits<std::uint64_t>::max();
    return sequence <= ((maximum - commands) / stride) + 1U;
}

std::uint64_t commandSequence(std::uint64_t sourceSequence,
                              std::size_t commandIndex) noexcept {
    return ((sourceSequence - 1U) *
            static_cast<std::uint64_t>(kMoonlightPointerSequenceStride)) +
        static_cast<std::uint64_t>(commandIndex) + 1U;
}

void writeInt16(std::array<std::uint8_t, kMoonlightMaximumInputPayloadBytes>& payload,
                std::size_t offset,
                std::int16_t value) noexcept {
    const std::uint16_t bits = static_cast<std::uint16_t>(value);
    payload[offset] = static_cast<std::uint8_t>(bits & 0x00FFU);
    payload[offset + 1U] = static_cast<std::uint8_t>((bits >> 8U) & 0x00FFU);
}

void writeUint16(std::array<std::uint8_t, kMoonlightMaximumInputPayloadBytes>& payload,
                 std::size_t offset,
                 std::uint16_t value) noexcept {
    payload[offset] = static_cast<std::uint8_t>(value & 0x00FFU);
    payload[offset + 1U] = static_cast<std::uint8_t>((value >> 8U) & 0x00FFU);
}

std::int16_t readInt16(
    const std::array<std::uint8_t, kMoonlightMaximumInputPayloadBytes>& payload,
    std::size_t offset) noexcept {
    const std::uint16_t bits = static_cast<std::uint16_t>(payload[offset]) |
        static_cast<std::uint16_t>(static_cast<std::uint16_t>(payload[offset + 1U]) << 8U);
    if (bits <= static_cast<std::uint16_t>(std::numeric_limits<std::int16_t>::max())) {
        return static_cast<std::int16_t>(bits);
    }
    const std::int32_t magnitude = static_cast<std::int32_t>(
        std::numeric_limits<std::uint16_t>::max() - bits) + 1;
    return static_cast<std::int16_t>(-magnitude);
}

std::uint16_t readUint16(
    const std::array<std::uint8_t, kMoonlightMaximumInputPayloadBytes>& payload,
    std::size_t offset) noexcept {
    return static_cast<std::uint16_t>(payload[offset]) |
        static_cast<std::uint16_t>(static_cast<std::uint16_t>(payload[offset + 1U]) << 8U);
}

bool zeroTail(const MoonlightInputEvent& event) noexcept {
    for (std::size_t index = event.payloadSize; index < event.payload.size(); ++index) {
        if (event.payload[index] != 0U) {
            return false;
        }
    }
    return true;
}

bool validPointerEvent(const MoonlightInputEvent& event,
                       MoonlightInputCommandKind kind,
                       std::size_t payloadSize) noexcept {
    return event.identity.valid() && event.deviceId != 0U &&
        pointerSource(event.source) && event.sourceGeneration != 0U &&
        event.sourceSequence != 0U && event.monotonicTimestampUs != 0U &&
        event.kind == kind && event.commandVersion == 1U &&
        event.payloadSize == payloadSize && zeroTail(event);
}

bool validContent(const MoonlightPointerContentRect& content) noexcept {
    if (!std::isfinite(content.left) || !std::isfinite(content.top) ||
        !std::isfinite(content.width) || !std::isfinite(content.height) ||
        content.width <= 0.0 || content.height <= 0.0 ||
        content.referenceWidth < 2U || content.referenceHeight < 2U ||
        content.referenceWidth > kMaximumPointerCoordinate ||
        content.referenceHeight > kMaximumPointerCoordinate ||
        content.clockwiseQuarterTurns > 3U || content.geometryGeneration == 0U) {
        return false;
    }
    return std::isfinite(content.left + content.width) &&
        std::isfinite(content.top + content.height);
}

bool sameContent(const MoonlightPointerContentRect& left,
                 const MoonlightPointerContentRect& right) noexcept {
    return left.left == right.left && left.top == right.top &&
        left.width == right.width && left.height == right.height &&
        left.referenceWidth == right.referenceWidth &&
        left.referenceHeight == right.referenceHeight &&
        left.clockwiseQuarterTurns == right.clockwiseQuarterTurns &&
        left.geometryGeneration == right.geometryGeneration;
}

MoonlightPointerStatus pointerStatus(MoonlightInputDispatchStatus status) noexcept {
    switch (status) {
        case MoonlightInputDispatchStatus::Accepted:
            return MoonlightPointerStatus::Applied;
        case MoonlightInputDispatchStatus::InvalidRequest:
            return MoonlightPointerStatus::InvalidRequest;
        case MoonlightInputDispatchStatus::InvalidState:
            return MoonlightPointerStatus::InvalidState;
        case MoonlightInputDispatchStatus::StaleOwner:
            return MoonlightPointerStatus::StaleOwner;
        case MoonlightInputDispatchStatus::StaleEvent:
            return MoonlightPointerStatus::StaleEvent;
        case MoonlightInputDispatchStatus::Duplicate:
            return MoonlightPointerStatus::Duplicate;
        case MoonlightInputDispatchStatus::SourceCapacity:
            return MoonlightPointerStatus::SourceCapacity;
        case MoonlightInputDispatchStatus::Backpressure:
            return MoonlightPointerStatus::Backpressure;
        case MoonlightInputDispatchStatus::Unsupported:
            return MoonlightPointerStatus::PortUnsupported;
        case MoonlightInputDispatchStatus::PortFailure:
            return MoonlightPointerStatus::PortFailure;
    }
    return MoonlightPointerStatus::PortFailure;
}

struct ButtonState final {
    bool pressed = false;
    std::uint64_t deviceId = 0U;
    MoonlightInputSource source = MoonlightInputSource::Invalid;
    std::uint64_t pressOrder = 0U;
};

struct PointerState final {
    std::array<ButtonState, kMoonlightMaximumPointerButtons> buttons{};
    double residualX = 0.0;
    double residualY = 0.0;
    bool geometryConfigured = false;
    MoonlightPointerContentRect geometry{};
    std::uint64_t nextPressOrder = 1U;
};

std::size_t pressedButtonCount(const PointerState& state) noexcept {
    std::size_t count = 0U;
    for (const ButtonState& button : state.buttons) {
        count += button.pressed ? 1U : 0U;
    }
    return count;
}

struct PendingCommand final {
    MoonlightInputEvent event{};
    PointerState stateAfter{};
};

struct PendingTransaction final {
    bool active = false;
    bool partialRecorded = false;
    std::array<PendingCommand, kMoonlightMaximumPointerTransactionCommands> commands{};
    std::size_t count = 0U;
    std::size_t index = 0U;
    std::size_t accepted = 0U;
    MoonlightInputDispatchStatus lastDispatch = MoonlightInputDispatchStatus::Backpressure;
};

PendingCommand* appendCommand(PendingTransaction& transaction,
                              const MoonlightPointerEventContext& context,
                              const PointerState& stateAfter,
                              MoonlightInputCommandKind kind,
                              std::size_t payloadSize) noexcept {
    if (transaction.count >= transaction.commands.size() ||
        payloadSize > kMoonlightMaximumInputPayloadBytes) {
        return nullptr;
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
    command.event.kind = kind;
    command.event.commandVersion = 1U;
    command.event.payloadSize = payloadSize;
    command.stateAfter = stateAfter;
    ++transaction.count;
    return &command;
}

bool appendRelative(PendingTransaction& transaction,
                    const MoonlightPointerEventContext& context,
                    const PointerState& stateAfter,
                    std::int16_t deltaX,
                    std::int16_t deltaY) noexcept {
    PendingCommand* command = appendCommand(
        transaction, context, stateAfter,
        MoonlightInputCommandKind::RelativePointer,
        kMoonlightRelativePointerCommandBytes);
    if (command == nullptr) {
        return false;
    }
    writeInt16(command->event.payload, 0U, deltaX);
    writeInt16(command->event.payload, 2U, deltaY);
    return true;
}

bool appendAbsolute(PendingTransaction& transaction,
                    const MoonlightPointerEventContext& context,
                    const PointerState& stateAfter,
                    const MoonlightAbsolutePointerMapping& mapping) noexcept {
    PendingCommand* command = appendCommand(
        transaction, context, stateAfter,
        MoonlightInputCommandKind::AbsolutePointer,
        kMoonlightAbsolutePointerCommandBytes);
    if (command == nullptr) {
        return false;
    }
    writeInt16(command->event.payload, 0U, mapping.x);
    writeInt16(command->event.payload, 2U, mapping.y);
    writeUint16(command->event.payload, 4U, mapping.referenceWidth);
    writeUint16(command->event.payload, 6U, mapping.referenceHeight);
    return true;
}

bool appendButton(PendingTransaction& transaction,
                  const MoonlightPointerEventContext& context,
                  const PointerState& stateAfter,
                  MoonlightPointerButton button,
                  std::uint8_t action) noexcept {
    PendingCommand* command = appendCommand(
        transaction, context, stateAfter,
        MoonlightInputCommandKind::PointerButton,
        kMoonlightPointerButtonCommandBytes);
    if (command == nullptr) {
        return false;
    }
    command->event.payload[0] = action;
    command->event.payload[1] = static_cast<std::uint8_t>(button);
    return true;
}

bool appendScroll(PendingTransaction& transaction,
                  const MoonlightPointerEventContext& context,
                  const PointerState& stateAfter,
                  bool horizontal,
                  std::int16_t amount) noexcept {
    PendingCommand* command = appendCommand(
        transaction, context, stateAfter,
        horizontal ? MoonlightInputCommandKind::HorizontalScroll :
                     MoonlightInputCommandKind::VerticalScroll,
        kMoonlightPointerScrollCommandBytes);
    if (command == nullptr) {
        return false;
    }
    writeInt16(command->event.payload, 0U, amount);
    return true;
}

} // namespace

MoonlightPointerModeResolution resolveMoonlightPointerMode(
    const MoonlightPointerModeRequest& request,
    std::uint8_t availableCapabilities) noexcept {
    MoonlightPointerModeResolution result;
    result.mode = request.mode;
    if (!knownMode(request.mode) ||
        (request.requestedCapabilities &
         static_cast<std::uint8_t>(~kMoonlightPointerKnownCapabilities)) != 0U ||
        (request.requiredCapabilities &
         static_cast<std::uint8_t>(~kMoonlightPointerKnownCapabilities)) != 0U ||
        (availableCapabilities &
         static_cast<std::uint8_t>(~kMoonlightPointerKnownCapabilities)) != 0U ||
        (request.requiredCapabilities &
         static_cast<std::uint8_t>(~request.requestedCapabilities)) != 0U ||
        ((request.requestedCapabilities & kMoonlightPointerCapabilityConstraint) != 0U &&
         (request.requestedCapabilities & kMoonlightPointerCapabilityCapture) == 0U) ||
        ((request.requiredCapabilities & kMoonlightPointerCapabilityConstraint) != 0U &&
         (request.requiredCapabilities & kMoonlightPointerCapabilityCapture) == 0U) ||
        ((availableCapabilities & kMoonlightPointerCapabilityConstraint) != 0U &&
         (availableCapabilities & kMoonlightPointerCapabilityCapture) == 0U) ||
        (request.mode == MoonlightPointerMode::Absolute &&
         (request.requestedCapabilities != 0U || request.requiredCapabilities != 0U))) {
        return result;
    }

    result.enabledCapabilities = static_cast<std::uint8_t>(
        request.requestedCapabilities & availableCapabilities);
    result.missingCapabilities = static_cast<std::uint8_t>(
        request.requestedCapabilities &
        static_cast<std::uint8_t>(~availableCapabilities));
    if (result.missingCapabilities == 0U) {
        result.status = MoonlightPointerModeStatus::Ready;
    } else if (!request.allowFallback ||
               (result.missingCapabilities & request.requiredCapabilities) != 0U) {
        result.status = MoonlightPointerModeStatus::Unsupported;
        result.enabledCapabilities = 0U;
    } else {
        result.status = MoonlightPointerModeStatus::Degraded;
    }
    return result;
}

MoonlightNormalizedPointerMapping mapMoonlightNormalizedPointer(
    const MoonlightPointerContentRect& content,
    double pointX,
    double pointY) noexcept {
    MoonlightNormalizedPointerMapping result;
    if (!validContent(content) || !std::isfinite(pointX) || !std::isfinite(pointY)) {
        return result;
    }
    const double right = content.left + content.width;
    const double bottom = content.top + content.height;
    if (pointX < content.left || pointX > right ||
        pointY < content.top || pointY > bottom) {
        result.status = MoonlightPointerMapStatus::OutsideContent;
        return result;
    }

    const double displayedX = std::clamp(
        (pointX - content.left) / content.width, 0.0, 1.0);
    const double displayedY = std::clamp(
        (pointY - content.top) / content.height, 0.0, 1.0);
    double sourceX = displayedX;
    double sourceY = displayedY;
    switch (content.clockwiseQuarterTurns) {
        case 0U:
            break;
        case 1U:
            sourceX = displayedY;
            sourceY = 1.0 - displayedX;
            break;
        case 2U:
            sourceX = 1.0 - displayedX;
            sourceY = 1.0 - displayedY;
            break;
        case 3U:
            sourceX = 1.0 - displayedY;
            sourceY = displayedX;
            break;
        default:
            return result;
    }

    result.status = MoonlightPointerMapStatus::Mapped;
    result.x = sourceX;
    result.y = sourceY;
    return result;
}

MoonlightAbsolutePointerMapping mapMoonlightAbsolutePointer(
    const MoonlightPointerContentRect& content,
    double pointX,
    double pointY) noexcept {
    MoonlightAbsolutePointerMapping result;
    const MoonlightNormalizedPointerMapping normalized =
        mapMoonlightNormalizedPointer(content, pointX, pointY);
    result.status = normalized.status;
    if (normalized.status != MoonlightPointerMapStatus::Mapped) {
        return result;
    }
    result.x = static_cast<std::int16_t>(std::llround(
        normalized.x * static_cast<double>(content.referenceWidth - 1U)));
    result.y = static_cast<std::int16_t>(std::llround(
        normalized.y * static_cast<double>(content.referenceHeight - 1U)));
    result.referenceWidth = content.referenceWidth;
    result.referenceHeight = content.referenceHeight;
    return result;
}

bool decodeMoonlightRelativePointerCommand(
    const MoonlightInputEvent& event,
    MoonlightRelativePointerWireCommand& command) noexcept {
    if (!validPointerEvent(event, MoonlightInputCommandKind::RelativePointer,
                           kMoonlightRelativePointerCommandBytes)) {
        return false;
    }
    command.deltaX = readInt16(event.payload, 0U);
    command.deltaY = readInt16(event.payload, 2U);
    return command.deltaX != 0 || command.deltaY != 0;
}

bool decodeMoonlightAbsolutePointerCommand(
    const MoonlightInputEvent& event,
    MoonlightAbsolutePointerWireCommand& command) noexcept {
    if (!validPointerEvent(event, MoonlightInputCommandKind::AbsolutePointer,
                           kMoonlightAbsolutePointerCommandBytes)) {
        return false;
    }
    command.x = readInt16(event.payload, 0U);
    command.y = readInt16(event.payload, 2U);
    command.referenceWidth = readUint16(event.payload, 4U);
    command.referenceHeight = readUint16(event.payload, 6U);
    return command.x >= 0 && command.y >= 0 &&
        command.referenceWidth >= 2U && command.referenceHeight >= 2U &&
        command.referenceWidth <= kMaximumPointerCoordinate &&
        command.referenceHeight <= kMaximumPointerCoordinate &&
        static_cast<std::uint16_t>(command.x) < command.referenceWidth &&
        static_cast<std::uint16_t>(command.y) < command.referenceHeight;
}

bool decodeMoonlightPointerButtonCommand(
    const MoonlightInputEvent& event,
    MoonlightPointerButtonWireCommand& command) noexcept {
    if (!validPointerEvent(event, MoonlightInputCommandKind::PointerButton,
                           kMoonlightPointerButtonCommandBytes) ||
        (event.payload[0] != kMoonlightPointerActionPress &&
         event.payload[0] != kMoonlightPointerActionRelease)) {
        return false;
    }
    const auto button = static_cast<MoonlightPointerButton>(event.payload[1]);
    std::size_t index = 0U;
    if (!buttonIndex(button, index)) {
        return false;
    }
    command.action = event.payload[0];
    command.button = button;
    return true;
}

bool decodeMoonlightPointerScrollCommand(
    const MoonlightInputEvent& event,
    MoonlightPointerScrollWireCommand& command) noexcept {
    const bool horizontal = event.kind == MoonlightInputCommandKind::HorizontalScroll;
    const bool vertical = event.kind == MoonlightInputCommandKind::VerticalScroll;
    if ((!horizontal && !vertical) ||
        !validPointerEvent(event, event.kind, kMoonlightPointerScrollCommandBytes)) {
        return false;
    }
    command.horizontal = horizontal;
    command.amount = readInt16(event.payload, 0U);
    return command.amount != 0;
}

struct MoonlightPointerMapper::Impl final {
    Impl(std::shared_ptr<MoonlightInputBridge> valueBridge,
         const MoonlightInputIdentity& valueIdentity,
         MoonlightPointerLimits valueLimits) noexcept
        : bridge(std::move(valueBridge)), identity(valueIdentity), limits(valueLimits) {}

    MoonlightPointerResult result(
        MoonlightPointerStatus status,
        MoonlightInputDispatchStatus dispatch = MoonlightInputDispatchStatus::InvalidRequest,
        std::size_t accepted = 0U,
        std::size_t remaining = 0U) const noexcept {
        return {status, dispatch, accepted, remaining};
    }

    MoonlightPointerResult invalidResult() noexcept {
        invalidRequests = saturatingIncrement(invalidRequests);
        return result(MoonlightPointerStatus::InvalidRequest);
    }

    MoonlightPointerResult contextResult(
        const MoonlightPointerEventContext& context) noexcept {
        if (!context.valid() || !pointerSource(context.source) ||
            !safeSourceSequence(context.sourceSequence)) {
            return invalidResult();
        }
        if (context.identity != identity) {
            return result(MoonlightPointerStatus::StaleOwner,
                          MoonlightInputDispatchStatus::StaleOwner);
        }
        return result(MoonlightPointerStatus::Applied,
                      MoonlightInputDispatchStatus::Accepted);
    }

    MoonlightPointerResult pendingResult() const noexcept {
        return result(MoonlightPointerStatus::Pending, pending.lastDispatch,
                      pending.accepted, pending.count - pending.index);
    }

    MoonlightPointerResult drivePending() noexcept {
        if (!pending.active || bridge == nullptr || pending.count == 0U ||
            pending.index >= pending.count) {
            return result(MoonlightPointerStatus::InvalidState,
                          MoonlightInputDispatchStatus::InvalidState);
        }
        while (pending.index < pending.count) {
            const MoonlightInputDispatchStatus dispatch =
                bridge->dispatch(pending.commands[pending.index].event);
            pending.lastDispatch = dispatch;
            if (dispatch != MoonlightInputDispatchStatus::Accepted) {
                if (pending.accepted != 0U && !pending.partialRecorded) {
                    partialTransactions = saturatingIncrement(partialTransactions);
                    pending.partialRecorded = true;
                }
                return result(pointerStatus(dispatch), dispatch, pending.accepted,
                              pending.count - pending.index);
            }
            state = pending.commands[pending.index].stateAfter;
            ++pending.index;
            ++pending.accepted;
        }
        const std::size_t accepted = pending.accepted;
        pending = {};
        appliedTransactions = saturatingIncrement(appliedTransactions);
        return result(MoonlightPointerStatus::Applied,
                      MoonlightInputDispatchStatus::Accepted, accepted, 0U);
    }

    MoonlightPointerResult dispatchTransaction(PendingTransaction& transaction) noexcept {
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
    MoonlightPointerLimits limits{};
    PointerState state{};
    PendingTransaction pending{};
    std::uint64_t appliedTransactions = 0U;
    std::uint64_t localOnlyUpdates = 0U;
    std::uint64_t outsideContentEvents = 0U;
    std::uint64_t partialTransactions = 0U;
    std::uint64_t invalidRequests = 0U;
    std::uint64_t staleGeometryEvents = 0U;
    std::uint64_t duplicateEvents = 0U;
};

MoonlightPointerMapper::MoonlightPointerMapper(std::unique_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}

MoonlightPointerMapper::~MoonlightPointerMapper() {
    if (impl_ == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->pending = {};
    impl_->state = {};
    impl_->identity = {};
}

std::shared_ptr<MoonlightPointerMapper> MoonlightPointerMapper::create(
    std::shared_ptr<MoonlightInputBridge> bridge,
    const MoonlightInputIdentity& identity,
    MoonlightPointerLimits limits) noexcept {
    if (bridge == nullptr || !identity.valid() ||
        limits.maximumPressedButtons == 0U ||
        limits.maximumPressedButtons > kMoonlightMaximumPointerButtons ||
        !std::isfinite(limits.relativeSensitivity) ||
        limits.relativeSensitivity <= 0.0 ||
        limits.relativeSensitivity > kMaximumRelativeSensitivity) {
        return nullptr;
    }
    const MoonlightInputSnapshot bridgeSnapshot = bridge->snapshot(identity);
    if (!bridgeSnapshot.matched || bridgeSnapshot.state != MoonlightInputState::Active) {
        return nullptr;
    }
    try {
        return std::shared_ptr<MoonlightPointerMapper>(new MoonlightPointerMapper(
            std::make_unique<Impl>(std::move(bridge), identity, limits)));
    } catch (...) {
        return nullptr;
    }
}

MoonlightPointerResult MoonlightPointerMapper::relativeMotion(
    const MoonlightPointerEventContext& context,
    double deltaX,
    double deltaY) noexcept {
    if (impl_ == nullptr) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const MoonlightPointerResult contextStatus = impl_->contextResult(context);
    if (contextStatus.status != MoonlightPointerStatus::Applied) {
        return contextStatus;
    }
    if (impl_->pending.active) {
        return impl_->pendingResult();
    }
    if (!std::isfinite(deltaX) || !std::isfinite(deltaY)) {
        return impl_->invalidResult();
    }
    if (deltaX == 0.0 && deltaY == 0.0) {
        return impl_->result(MoonlightPointerStatus::AlreadyApplied,
                             MoonlightInputDispatchStatus::Accepted);
    }

    const double totalX = impl_->state.residualX +
        deltaX * impl_->limits.relativeSensitivity;
    const double totalY = impl_->state.residualY +
        deltaY * impl_->limits.relativeSensitivity;
    if (!std::isfinite(totalX) || !std::isfinite(totalY)) {
        return impl_->result(MoonlightPointerStatus::OutOfRange);
    }
    const double integralX = std::trunc(totalX);
    const double integralY = std::trunc(totalY);
    if (integralX < static_cast<double>(std::numeric_limits<std::int16_t>::min()) ||
        integralX > static_cast<double>(std::numeric_limits<std::int16_t>::max()) ||
        integralY < static_cast<double>(std::numeric_limits<std::int16_t>::min()) ||
        integralY > static_cast<double>(std::numeric_limits<std::int16_t>::max())) {
        return impl_->result(MoonlightPointerStatus::OutOfRange);
    }

    PointerState candidate = impl_->state;
    candidate.residualX = totalX - integralX;
    candidate.residualY = totalY - integralY;
    const auto wireX = static_cast<std::int16_t>(integralX);
    const auto wireY = static_cast<std::int16_t>(integralY);
    if (wireX == 0 && wireY == 0) {
        impl_->state = candidate;
        impl_->localOnlyUpdates = saturatingIncrement(impl_->localOnlyUpdates);
        return impl_->result(MoonlightPointerStatus::AppliedLocally,
                             MoonlightInputDispatchStatus::Accepted);
    }

    PendingTransaction transaction;
    if (!appendRelative(transaction, context, candidate, wireX, wireY)) {
        return impl_->invalidResult();
    }
    return impl_->dispatchTransaction(transaction);
}

MoonlightPointerResult MoonlightPointerMapper::absolutePosition(
    const MoonlightPointerEventContext& context,
    const MoonlightPointerContentRect& content,
    double pointX,
    double pointY) noexcept {
    if (impl_ == nullptr) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const MoonlightPointerResult contextStatus = impl_->contextResult(context);
    if (contextStatus.status != MoonlightPointerStatus::Applied) {
        return contextStatus;
    }
    if (impl_->pending.active) {
        return impl_->pendingResult();
    }
    const MoonlightAbsolutePointerMapping mapping =
        mapMoonlightAbsolutePointer(content, pointX, pointY);
    if (mapping.status == MoonlightPointerMapStatus::InvalidRequest) {
        return impl_->invalidResult();
    }
    if (impl_->state.geometryConfigured) {
        if (content.geometryGeneration < impl_->state.geometry.geometryGeneration) {
            impl_->staleGeometryEvents = saturatingIncrement(impl_->staleGeometryEvents);
            return impl_->result(MoonlightPointerStatus::StaleGeometry,
                                 MoonlightInputDispatchStatus::StaleEvent);
        }
        if (content.geometryGeneration == impl_->state.geometry.geometryGeneration &&
            !sameContent(content, impl_->state.geometry)) {
            return impl_->invalidResult();
        }
    }

    PointerState candidate = impl_->state;
    candidate.geometryConfigured = true;
    candidate.geometry = content;
    if (mapping.status == MoonlightPointerMapStatus::OutsideContent) {
        impl_->state = candidate;
        impl_->outsideContentEvents = saturatingIncrement(impl_->outsideContentEvents);
        impl_->localOnlyUpdates = saturatingIncrement(impl_->localOnlyUpdates);
        return impl_->result(MoonlightPointerStatus::OutsideContent,
                             MoonlightInputDispatchStatus::Accepted);
    }

    PendingTransaction transaction;
    if (!appendAbsolute(transaction, context, candidate, mapping)) {
        return impl_->invalidResult();
    }
    return impl_->dispatchTransaction(transaction);
}

MoonlightPointerResult MoonlightPointerMapper::button(
    const MoonlightPointerEventContext& context,
    MoonlightPointerButton button,
    bool pressed) noexcept {
    if (impl_ == nullptr) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const MoonlightPointerResult contextStatus = impl_->contextResult(context);
    if (contextStatus.status != MoonlightPointerStatus::Applied) {
        return contextStatus;
    }
    std::size_t index = 0U;
    if (!buttonIndex(button, index)) {
        return impl_->invalidResult();
    }
    if (impl_->pending.active) {
        return impl_->pendingResult();
    }

    PointerState candidate = impl_->state;
    ButtonState& state = candidate.buttons[index];
    if (pressed) {
        if (state.pressed) {
            impl_->duplicateEvents = saturatingIncrement(impl_->duplicateEvents);
            return impl_->result(MoonlightPointerStatus::Duplicate,
                                 MoonlightInputDispatchStatus::Duplicate);
        }
        if (pressedButtonCount(candidate) >= impl_->limits.maximumPressedButtons) {
            return impl_->result(MoonlightPointerStatus::ButtonCapacity);
        }
        state.pressed = true;
        state.deviceId = context.deviceId;
        state.source = context.source;
        state.pressOrder = candidate.nextPressOrder;
        candidate.nextPressOrder = saturatingIncrement(candidate.nextPressOrder);
    } else {
        if (!state.pressed || state.deviceId != context.deviceId ||
            state.source != context.source) {
            return impl_->result(MoonlightPointerStatus::NotPressed);
        }
        state = {};
        if (pressedButtonCount(candidate) == 0U) {
            candidate.nextPressOrder = 1U;
        }
    }

    PendingTransaction transaction;
    if (!appendButton(transaction, context, candidate, button,
                      pressed ? kMoonlightPointerActionPress :
                                kMoonlightPointerActionRelease)) {
        return impl_->invalidResult();
    }
    return impl_->dispatchTransaction(transaction);
}

MoonlightPointerResult MoonlightPointerMapper::absoluteButton(
    const MoonlightPointerEventContext& context,
    const MoonlightPointerContentRect& content,
    double pointX,
    double pointY,
    MoonlightPointerButton button,
    bool pressed) noexcept {
    if (impl_ == nullptr) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const MoonlightPointerResult contextStatus = impl_->contextResult(context);
    if (contextStatus.status != MoonlightPointerStatus::Applied) {
        return contextStatus;
    }
    std::size_t buttonSlot = 0U;
    if (!buttonIndex(button, buttonSlot)) {
        return impl_->invalidResult();
    }
    if (impl_->pending.active) {
        return impl_->pendingResult();
    }

    const MoonlightAbsolutePointerMapping mapping =
        mapMoonlightAbsolutePointer(content, pointX, pointY);
    if (mapping.status == MoonlightPointerMapStatus::InvalidRequest) {
        return impl_->invalidResult();
    }
    if (impl_->state.geometryConfigured) {
        if (content.geometryGeneration < impl_->state.geometry.geometryGeneration) {
            impl_->staleGeometryEvents = saturatingIncrement(impl_->staleGeometryEvents);
            return impl_->result(MoonlightPointerStatus::StaleGeometry,
                                 MoonlightInputDispatchStatus::StaleEvent);
        }
        if (content.geometryGeneration == impl_->state.geometry.geometryGeneration &&
            !sameContent(content, impl_->state.geometry)) {
            return impl_->invalidResult();
        }
    }

    PointerState positioned = impl_->state;
    positioned.geometryConfigured = true;
    positioned.geometry = content;
    ButtonState& current = positioned.buttons[buttonSlot];
    if (pressed && mapping.status == MoonlightPointerMapStatus::OutsideContent) {
        impl_->state = positioned;
        impl_->outsideContentEvents = saturatingIncrement(impl_->outsideContentEvents);
        impl_->localOnlyUpdates = saturatingIncrement(impl_->localOnlyUpdates);
        return impl_->result(MoonlightPointerStatus::OutsideContent,
                             MoonlightInputDispatchStatus::Accepted);
    }
    if (pressed) {
        if (current.pressed) {
            impl_->duplicateEvents = saturatingIncrement(impl_->duplicateEvents);
            return impl_->result(MoonlightPointerStatus::Duplicate,
                                 MoonlightInputDispatchStatus::Duplicate);
        }
        if (pressedButtonCount(positioned) >= impl_->limits.maximumPressedButtons) {
            return impl_->result(MoonlightPointerStatus::ButtonCapacity);
        }
    } else if (!current.pressed || current.deviceId != context.deviceId ||
               current.source != context.source) {
        return impl_->result(MoonlightPointerStatus::NotPressed);
    }

    PendingTransaction transaction;
    if (mapping.status == MoonlightPointerMapStatus::Mapped &&
        !appendAbsolute(transaction, context, positioned, mapping)) {
        return impl_->invalidResult();
    }

    PointerState candidate = positioned;
    ButtonState& next = candidate.buttons[buttonSlot];
    if (pressed) {
        next.pressed = true;
        next.deviceId = context.deviceId;
        next.source = context.source;
        next.pressOrder = candidate.nextPressOrder;
        candidate.nextPressOrder = saturatingIncrement(candidate.nextPressOrder);
    } else {
        next = {};
        if (pressedButtonCount(candidate) == 0U) {
            candidate.nextPressOrder = 1U;
        }
    }
    if (!appendButton(transaction, context, candidate, button,
                      pressed ? kMoonlightPointerActionPress :
                                kMoonlightPointerActionRelease)) {
        return impl_->invalidResult();
    }
    return impl_->dispatchTransaction(transaction);
}

MoonlightPointerResult MoonlightPointerMapper::scroll(
    const MoonlightPointerEventContext& context,
    bool horizontal,
    std::int32_t highResolutionAmount) noexcept {
    if (impl_ == nullptr) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const MoonlightPointerResult contextStatus = impl_->contextResult(context);
    if (contextStatus.status != MoonlightPointerStatus::Applied) {
        return contextStatus;
    }
    if (impl_->pending.active) {
        return impl_->pendingResult();
    }
    if (highResolutionAmount == 0) {
        return impl_->result(MoonlightPointerStatus::AlreadyApplied,
                             MoonlightInputDispatchStatus::Accepted);
    }
    if (highResolutionAmount < std::numeric_limits<std::int16_t>::min() ||
        highResolutionAmount > std::numeric_limits<std::int16_t>::max()) {
        return impl_->result(MoonlightPointerStatus::OutOfRange);
    }
    PendingTransaction transaction;
    if (!appendScroll(transaction, context, impl_->state, horizontal,
                      static_cast<std::int16_t>(highResolutionAmount))) {
        return impl_->invalidResult();
    }
    return impl_->dispatchTransaction(transaction);
}

MoonlightPointerResult MoonlightPointerMapper::click(
    const MoonlightPointerEventContext& context,
    MoonlightPointerButton button) noexcept {
    if (impl_ == nullptr) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const MoonlightPointerResult contextStatus = impl_->contextResult(context);
    if (contextStatus.status != MoonlightPointerStatus::Applied) {
        return contextStatus;
    }
    std::size_t buttonSlot = 0U;
    if (!buttonIndex(button, buttonSlot)) {
        return impl_->invalidResult();
    }
    if (impl_->pending.active) {
        return impl_->pendingResult();
    }
    if (impl_->state.buttons[buttonSlot].pressed) {
        impl_->duplicateEvents = saturatingIncrement(impl_->duplicateEvents);
        return impl_->result(MoonlightPointerStatus::Duplicate,
                             MoonlightInputDispatchStatus::Duplicate);
    }
    if (pressedButtonCount(impl_->state) >= impl_->limits.maximumPressedButtons) {
        return impl_->result(MoonlightPointerStatus::ButtonCapacity);
    }

    PointerState pressed = impl_->state;
    ButtonState& pressedButton = pressed.buttons[buttonSlot];
    pressedButton.pressed = true;
    pressedButton.deviceId = context.deviceId;
    pressedButton.source = context.source;
    pressedButton.pressOrder = pressed.nextPressOrder;
    pressed.nextPressOrder = saturatingIncrement(pressed.nextPressOrder);

    PendingTransaction transaction;
    if (!appendButton(transaction, context, pressed, button,
                      kMoonlightPointerActionPress)) {
        return impl_->invalidResult();
    }
    PointerState released = pressed;
    released.buttons[buttonSlot] = {};
    if (pressedButtonCount(released) == 0U) {
        released.nextPressOrder = 1U;
    }
    if (!appendButton(transaction, context, released, button,
                      kMoonlightPointerActionRelease)) {
        return impl_->invalidResult();
    }
    return impl_->dispatchTransaction(transaction);
}

MoonlightPointerResult MoonlightPointerMapper::scroll2D(
    const MoonlightPointerEventContext& context,
    std::int32_t horizontalAmount,
    std::int32_t verticalAmount) noexcept {
    if (impl_ == nullptr) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const MoonlightPointerResult contextStatus = impl_->contextResult(context);
    if (contextStatus.status != MoonlightPointerStatus::Applied) {
        return contextStatus;
    }
    if (impl_->pending.active) {
        return impl_->pendingResult();
    }
    if (horizontalAmount == 0 && verticalAmount == 0) {
        return impl_->result(MoonlightPointerStatus::AlreadyApplied,
                             MoonlightInputDispatchStatus::Accepted);
    }
    if (horizontalAmount < std::numeric_limits<std::int16_t>::min() ||
        horizontalAmount > std::numeric_limits<std::int16_t>::max() ||
        verticalAmount < std::numeric_limits<std::int16_t>::min() ||
        verticalAmount > std::numeric_limits<std::int16_t>::max()) {
        return impl_->result(MoonlightPointerStatus::OutOfRange);
    }

    PendingTransaction transaction;
    if (horizontalAmount != 0 &&
        !appendScroll(transaction, context, impl_->state, true,
                      static_cast<std::int16_t>(horizontalAmount))) {
        return impl_->invalidResult();
    }
    if (verticalAmount != 0 &&
        !appendScroll(transaction, context, impl_->state, false,
                      static_cast<std::int16_t>(verticalAmount))) {
        return impl_->invalidResult();
    }
    return impl_->dispatchTransaction(transaction);
}

MoonlightPointerResult MoonlightPointerMapper::releaseAll(
    const MoonlightPointerEventContext& context) noexcept {
    if (impl_ == nullptr) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const MoonlightPointerResult contextStatus = impl_->contextResult(context);
    if (contextStatus.status != MoonlightPointerStatus::Applied) {
        return contextStatus;
    }
    if (impl_->pending.active) {
        return impl_->pendingResult();
    }
    if (pressedButtonCount(impl_->state) == 0U) {
        return impl_->result(MoonlightPointerStatus::AlreadyApplied,
                             MoonlightInputDispatchStatus::Accepted);
    }

    PointerState candidate = impl_->state;
    PendingTransaction transaction;
    while (pressedButtonCount(candidate) != 0U) {
        ButtonState* latest = nullptr;
        std::size_t latestIndex = 0U;
        for (std::size_t index = 0U; index < candidate.buttons.size(); ++index) {
            ButtonState& button = candidate.buttons[index];
            if (button.pressed &&
                (latest == nullptr || button.pressOrder > latest->pressOrder)) {
                latest = &button;
                latestIndex = index;
            }
        }
        if (latest == nullptr) {
            break;
        }
        *latest = {};
        const auto button = static_cast<MoonlightPointerButton>(latestIndex + 1U);
        if (!appendButton(transaction, context, candidate, button,
                          kMoonlightPointerActionRelease)) {
            return impl_->invalidResult();
        }
    }
    candidate.nextPressOrder = 1U;
    if (transaction.count == 0U) {
        return impl_->invalidResult();
    }
    for (std::size_t index = 0U; index < transaction.count; ++index) {
        transaction.commands[index].event.lifecycleRelease = true;
    }
    transaction.commands[transaction.count - 1U].stateAfter = candidate;
    return impl_->dispatchTransaction(transaction);
}

MoonlightPointerResult MoonlightPointerMapper::resumePending() noexcept {
    if (impl_ == nullptr) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    return impl_->drivePending();
}

bool MoonlightPointerMapper::cancelPendingIfUnsent(
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

bool MoonlightPointerMapper::discardLocalState(
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
    impl_->localOnlyUpdates = saturatingIncrement(impl_->localOnlyUpdates);
    return true;
}

MoonlightPointerSnapshot MoonlightPointerMapper::snapshot(
    const MoonlightInputIdentity& identity) const noexcept {
    MoonlightPointerSnapshot result;
    if (impl_ == nullptr) {
        return result;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (identity != impl_->identity) {
        return result;
    }
    result.matched = true;
    result.identity = impl_->identity;
    result.pressedButtons = pressedButtonCount(impl_->state);
    result.residualX = impl_->state.residualX;
    result.residualY = impl_->state.residualY;
    result.geometryGeneration = impl_->state.geometryConfigured ?
        impl_->state.geometry.geometryGeneration : 0U;
    result.pending = impl_->pending.active;
    result.pendingCommands = impl_->pending.active ?
        impl_->pending.count - impl_->pending.index : 0U;
    result.acceptedPendingCommands = impl_->pending.active ? impl_->pending.accepted : 0U;
    result.appliedTransactions = impl_->appliedTransactions;
    result.localOnlyUpdates = impl_->localOnlyUpdates;
    result.outsideContentEvents = impl_->outsideContentEvents;
    result.partialTransactions = impl_->partialTransactions;
    result.invalidRequests = impl_->invalidRequests;
    result.staleGeometryEvents = impl_->staleGeometryEvents;
    result.duplicateEvents = impl_->duplicateEvents;
    return result;
}

} // namespace remotedesk::moonlight
