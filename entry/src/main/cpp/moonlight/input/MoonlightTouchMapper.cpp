#include "moonlight/input/MoonlightTouchMapper.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <mutex>
#include <utility>

namespace remotedesk::moonlight {
namespace {

static_assert(sizeof(float) == sizeof(std::uint32_t),
              "Moonlight touch wire contract requires IEEE-754 binary32");

std::uint64_t saturatingIncrement(std::uint64_t value) noexcept {
    return value == std::numeric_limits<std::uint64_t>::max() ? value : value + 1U;
}

bool knownMode(MoonlightTouchMode mode) noexcept {
    switch (mode) {
        case MoonlightTouchMode::Direct:
        case MoonlightTouchMode::Touchpad:
            return true;
    }
    return false;
}

bool knownPhase(MoonlightTouchPhase phase) noexcept {
    switch (phase) {
        case MoonlightTouchPhase::Down:
        case MoonlightTouchPhase::Move:
        case MoonlightTouchPhase::Up:
        case MoonlightTouchPhase::Cancel:
            return true;
    }
    return false;
}

bool safePointerSourceSequence(std::uint64_t sequence) noexcept {
    if (sequence == 0U) {
        return false;
    }
    constexpr std::uint64_t maximum = std::numeric_limits<std::uint64_t>::max();
    constexpr std::uint64_t stride =
        static_cast<std::uint64_t>(kMoonlightPointerSequenceStride);
    constexpr std::uint64_t commands =
        static_cast<std::uint64_t>(kMoonlightMaximumPointerTransactionCommands);
    return sequence <= ((maximum - commands) / stride) + 1U;
}

void writeUint16(std::array<std::uint8_t, kMoonlightMaximumInputPayloadBytes>& payload,
                 std::size_t offset,
                 std::uint16_t value) noexcept {
    payload[offset] = static_cast<std::uint8_t>(value & 0x00FFU);
    payload[offset + 1U] = static_cast<std::uint8_t>((value >> 8U) & 0x00FFU);
}

void writeUint32(std::array<std::uint8_t, kMoonlightMaximumInputPayloadBytes>& payload,
                 std::size_t offset,
                 std::uint32_t value) noexcept {
    for (std::size_t index = 0U; index < 4U; ++index) {
        payload[offset + index] = static_cast<std::uint8_t>(
            (value >> static_cast<unsigned int>(index * 8U)) & 0x000000FFU);
    }
}

std::uint16_t readUint16(
    const std::array<std::uint8_t, kMoonlightMaximumInputPayloadBytes>& payload,
    std::size_t offset) noexcept {
    return static_cast<std::uint16_t>(payload[offset]) |
        static_cast<std::uint16_t>(
            static_cast<std::uint16_t>(payload[offset + 1U]) << 8U);
}

std::uint32_t readUint32(
    const std::array<std::uint8_t, kMoonlightMaximumInputPayloadBytes>& payload,
    std::size_t offset) noexcept {
    std::uint32_t value = 0U;
    for (std::size_t index = 0U; index < 4U; ++index) {
        value |= static_cast<std::uint32_t>(payload[offset + index]) <<
            static_cast<unsigned int>(index * 8U);
    }
    return value;
}

void writeFloat(std::array<std::uint8_t, kMoonlightMaximumInputPayloadBytes>& payload,
                std::size_t offset,
                float value) noexcept {
    std::uint32_t bits = 0U;
    std::memcpy(&bits, &value, sizeof(bits));
    writeUint32(payload, offset, bits);
}

float readFloat(
    const std::array<std::uint8_t, kMoonlightMaximumInputPayloadBytes>& payload,
    std::size_t offset) noexcept {
    const std::uint32_t bits = readUint32(payload, offset);
    float value = 0.0F;
    std::memcpy(&value, &bits, sizeof(value));
    return value;
}

bool zeroTail(const MoonlightInputEvent& event) noexcept {
    for (std::size_t index = event.payloadSize; index < event.payload.size(); ++index) {
        if (event.payload[index] != 0U) {
            return false;
        }
    }
    return true;
}

bool validWireValue(float value) noexcept {
    return std::isfinite(value) && value >= 0.0F && value <= 1.0F;
}

bool validSample(const MoonlightTouchSample& sample) noexcept {
    return std::isfinite(sample.pointX) && std::isfinite(sample.pointY) &&
        validWireValue(sample.pressure) &&
        validWireValue(sample.contactAreaMajor) &&
        validWireValue(sample.contactAreaMinor) &&
        sample.contactAreaMajor >= sample.contactAreaMinor &&
        (sample.rotation == kMoonlightTouchRotationUnknown || sample.rotation < 360U);
}

bool validRegion(const MoonlightTouchExclusionRegion& region) noexcept {
    return std::isfinite(region.left) && std::isfinite(region.top) &&
        std::isfinite(region.width) && std::isfinite(region.height) &&
        region.width > 0.0 && region.height > 0.0 &&
        std::isfinite(region.left + region.width) &&
        std::isfinite(region.top + region.height);
}

bool validSurface(const MoonlightTouchSurface& surface) noexcept {
    if (surface.hitMapGeneration == 0U ||
        surface.exclusionCount > kMoonlightMaximumTouchExclusionRegions ||
        mapMoonlightNormalizedPointer(surface.content, surface.content.left,
                                       surface.content.top).status !=
            MoonlightPointerMapStatus::Mapped) {
        return false;
    }
    for (std::size_t index = 0U; index < surface.exclusionCount; ++index) {
        if (!validRegion(surface.exclusions[index])) {
            return false;
        }
    }
    return true;
}

bool sameSurface(const MoonlightTouchSurface& left,
                 const MoonlightTouchSurface& right) noexcept {
    const MoonlightPointerContentRect& a = left.content;
    const MoonlightPointerContentRect& b = right.content;
    if (a.left != b.left || a.top != b.top || a.width != b.width ||
        a.height != b.height || a.referenceWidth != b.referenceWidth ||
        a.referenceHeight != b.referenceHeight ||
        a.clockwiseQuarterTurns != b.clockwiseQuarterTurns ||
        a.geometryGeneration != b.geometryGeneration ||
        left.hitMapGeneration != right.hitMapGeneration ||
        left.exclusionCount != right.exclusionCount) {
        return false;
    }
    for (std::size_t index = 0U; index < left.exclusionCount; ++index) {
        const MoonlightTouchExclusionRegion& x = left.exclusions[index];
        const MoonlightTouchExclusionRegion& y = right.exclusions[index];
        if (x.left != y.left || x.top != y.top || x.width != y.width ||
            x.height != y.height) {
            return false;
        }
    }
    return true;
}

bool excluded(const MoonlightTouchSurface& surface,
              double pointX,
              double pointY) noexcept {
    for (std::size_t index = 0U; index < surface.exclusionCount; ++index) {
        const MoonlightTouchExclusionRegion& region = surface.exclusions[index];
        if (pointX >= region.left && pointX <= region.left + region.width &&
            pointY >= region.top && pointY <= region.top + region.height) {
            return true;
        }
    }
    return false;
}

double distance(double x1, double y1, double x2, double y2) noexcept {
    return std::hypot(x1 - x2, y1 - y2);
}

std::uint16_t sourceRotation(std::uint16_t rotation,
                             std::uint8_t quarterTurns) noexcept {
    if (rotation == kMoonlightTouchRotationUnknown) {
        return rotation;
    }
    const std::uint16_t offset = static_cast<std::uint16_t>(quarterTurns) * 90U;
    return static_cast<std::uint16_t>((rotation + 360U - offset) % 360U);
}

MoonlightTouchStatus touchStatus(MoonlightInputDispatchStatus status) noexcept {
    switch (status) {
        case MoonlightInputDispatchStatus::Accepted:
            return MoonlightTouchStatus::Applied;
        case MoonlightInputDispatchStatus::InvalidRequest:
            return MoonlightTouchStatus::InvalidRequest;
        case MoonlightInputDispatchStatus::InvalidState:
            return MoonlightTouchStatus::InvalidState;
        case MoonlightInputDispatchStatus::StaleOwner:
            return MoonlightTouchStatus::StaleOwner;
        case MoonlightInputDispatchStatus::StaleEvent:
            return MoonlightTouchStatus::StaleEvent;
        case MoonlightInputDispatchStatus::Duplicate:
            return MoonlightTouchStatus::Duplicate;
        case MoonlightInputDispatchStatus::SourceCapacity:
            return MoonlightTouchStatus::SourceCapacity;
        case MoonlightInputDispatchStatus::Backpressure:
            return MoonlightTouchStatus::Backpressure;
        case MoonlightInputDispatchStatus::Unsupported:
            return MoonlightTouchStatus::PortUnsupported;
        case MoonlightInputDispatchStatus::PortFailure:
            return MoonlightTouchStatus::PortFailure;
    }
    return MoonlightTouchStatus::PortFailure;
}

MoonlightTouchStatus pointerStatus(MoonlightPointerStatus status) noexcept {
    switch (status) {
        case MoonlightPointerStatus::Applied:
            return MoonlightTouchStatus::Applied;
        case MoonlightPointerStatus::AppliedLocally:
            return MoonlightTouchStatus::AppliedLocally;
        case MoonlightPointerStatus::AlreadyApplied:
            return MoonlightTouchStatus::AlreadyApplied;
        case MoonlightPointerStatus::OutsideContent:
            return MoonlightTouchStatus::OutsideContent;
        case MoonlightPointerStatus::InvalidRequest:
            return MoonlightTouchStatus::InvalidRequest;
        case MoonlightPointerStatus::InvalidState:
            return MoonlightTouchStatus::InvalidState;
        case MoonlightPointerStatus::StaleOwner:
            return MoonlightTouchStatus::StaleOwner;
        case MoonlightPointerStatus::StaleEvent:
            return MoonlightTouchStatus::StaleEvent;
        case MoonlightPointerStatus::StaleGeometry:
            return MoonlightTouchStatus::StaleGeometry;
        case MoonlightPointerStatus::Duplicate:
            return MoonlightTouchStatus::Duplicate;
        case MoonlightPointerStatus::NotPressed:
            return MoonlightTouchStatus::NotActive;
        case MoonlightPointerStatus::ButtonCapacity:
            return MoonlightTouchStatus::ContactCapacity;
        case MoonlightPointerStatus::OutOfRange:
            return MoonlightTouchStatus::OutOfRange;
        case MoonlightPointerStatus::SourceCapacity:
            return MoonlightTouchStatus::SourceCapacity;
        case MoonlightPointerStatus::Backpressure:
            return MoonlightTouchStatus::Backpressure;
        case MoonlightPointerStatus::PortUnsupported:
            return MoonlightTouchStatus::PortUnsupported;
        case MoonlightPointerStatus::PortFailure:
            return MoonlightTouchStatus::PortFailure;
        case MoonlightPointerStatus::Pending:
            return MoonlightTouchStatus::Pending;
    }
    return MoonlightTouchStatus::PortFailure;
}

MoonlightPointerEventContext pointerContext(
    const MoonlightTouchEventContext& context) noexcept {
    return {context.identity, context.deviceId, context.source,
            context.sourceGeneration, context.sourceSequence,
            context.monotonicTimestampUs};
}

enum class GestureKind : std::uint8_t {
    None = 0,
    SingleCandidate,
    Cursor,
    Drag,
    MultiCandidate,
    Scroll,
    ThreeCandidate,
};

constexpr std::size_t kMoonlightMaximumObservedTouchLanes = 16U;

struct ObservedTouchLane final {
    bool occupied = false;
    std::uint64_t deviceId = 0U;
    MoonlightInputSource source = MoonlightInputSource::Invalid;
    std::uint64_t sourceGeneration = 0U;
    std::uint64_t lastSequence = 0U;
    std::uint64_t lastTimestampUs = 0U;
};

struct DirectContact final {
    bool occupied = false;
    bool suppressed = false;
    std::uint64_t localId = 0U;
    std::uint64_t deviceId = 0U;
    std::uint64_t sourceGeneration = 0U;
    std::uint32_t wireId = 0U;
};

struct TouchpadContact final {
    bool occupied = false;
    bool suppressed = false;
    std::uint64_t localId = 0U;
    std::uint64_t deviceId = 0U;
    std::uint64_t sourceGeneration = 0U;
    std::uint64_t downTimestampUs = 0U;
    double startX = 0.0;
    double startY = 0.0;
    double lastX = 0.0;
    double lastY = 0.0;
    double maximumTravel = 0.0;
};

struct TouchState final {
    MoonlightTouchMode mode = MoonlightTouchMode::Touchpad;
    bool surfaceConfigured = false;
    MoonlightTouchSurface surface{};
    std::array<DirectContact, kMoonlightMaximumTouchContacts> direct{};
    std::array<TouchpadContact, kMoonlightMaximumTouchpadContacts> touchpad{};
    std::array<ObservedTouchLane, kMoonlightMaximumObservedTouchLanes> lanes{};
    std::uint32_t nextWireId = 1U;
    GestureKind gesture = GestureKind::None;
    std::size_t peakTouchpadContacts = 0U;
    std::uint64_t gestureStartTimestampUs = 0U;
    double gestureMaximumTravel = 0.0;
    bool centroidValid = false;
    double centroidX = 0.0;
    double centroidY = 0.0;
    bool dragButtonDown = false;
};

std::size_t directActiveCount(const TouchState& state) noexcept {
    std::size_t count = 0U;
    for (const DirectContact& contact : state.direct) {
        count += contact.occupied && !contact.suppressed ? 1U : 0U;
    }
    return count;
}

std::size_t directSuppressedCount(const TouchState& state) noexcept {
    std::size_t count = 0U;
    for (const DirectContact& contact : state.direct) {
        count += contact.occupied && contact.suppressed ? 1U : 0U;
    }
    return count;
}

std::size_t touchpadActiveCount(const TouchState& state) noexcept {
    std::size_t count = 0U;
    for (const TouchpadContact& contact : state.touchpad) {
        count += contact.occupied ? 1U : 0U;
    }
    return count;
}

std::size_t touchpadRemoteCount(const TouchState& state) noexcept {
    std::size_t count = 0U;
    for (const TouchpadContact& contact : state.touchpad) {
        count += contact.occupied && !contact.suppressed ? 1U : 0U;
    }
    return count;
}

bool anyContacts(const TouchState& state) noexcept {
    return directActiveCount(state) != 0U || directSuppressedCount(state) != 0U ||
        touchpadActiveCount(state) != 0U;
}

bool contactsForLane(const TouchState& state,
                     std::uint64_t deviceId,
                     MoonlightInputSource source,
                     std::uint64_t sourceGeneration) noexcept {
    if (source == MoonlightInputSource::Touchscreen) {
        for (const DirectContact& contact : state.direct) {
            if (contact.occupied && contact.deviceId == deviceId &&
                contact.sourceGeneration == sourceGeneration) {
                return true;
            }
        }
    } else if (source == MoonlightInputSource::Touchpad) {
        for (const TouchpadContact& contact : state.touchpad) {
            if (contact.occupied && contact.deviceId == deviceId &&
                contact.sourceGeneration == sourceGeneration) {
                return true;
            }
        }
    }
    return false;
}

DirectContact* findDirect(TouchState& state,
                          const MoonlightTouchEventContext& context,
                          std::uint64_t localId) noexcept {
    for (DirectContact& contact : state.direct) {
        if (contact.occupied && contact.localId == localId &&
            contact.deviceId == context.deviceId &&
            contact.sourceGeneration == context.sourceGeneration) {
            return &contact;
        }
    }
    return nullptr;
}

TouchpadContact* findTouchpad(TouchState& state,
                              const MoonlightTouchEventContext& context,
                              std::uint64_t localId) noexcept {
    for (TouchpadContact& contact : state.touchpad) {
        if (contact.occupied && contact.localId == localId &&
            contact.deviceId == context.deviceId &&
            contact.sourceGeneration == context.sourceGeneration) {
            return &contact;
        }
    }
    return nullptr;
}

bool wireIdInUse(const TouchState& state, std::uint32_t wireId) noexcept {
    for (const DirectContact& contact : state.direct) {
        if (contact.occupied && contact.wireId == wireId) {
            return true;
        }
    }
    return false;
}

std::uint32_t allocateWireId(TouchState& state) noexcept {
    for (std::size_t attempt = 0U; attempt <= state.direct.size(); ++attempt) {
        std::uint32_t candidate = state.nextWireId;
        state.nextWireId = state.nextWireId == std::numeric_limits<std::uint32_t>::max() ?
            1U : state.nextWireId + 1U;
        if (candidate == 0U) {
            candidate = 1U;
        }
        if (!wireIdInUse(state, candidate)) {
            return candidate;
        }
    }
    return 0U;
}

bool computeCentroid(const TouchState& state, double& x, double& y) noexcept {
    x = 0.0;
    y = 0.0;
    std::size_t count = 0U;
    for (const TouchpadContact& contact : state.touchpad) {
        if (contact.occupied && !contact.suppressed) {
            x += contact.lastX;
            y += contact.lastY;
            ++count;
        }
    }
    if (count == 0U) {
        return false;
    }
    x /= static_cast<double>(count);
    y /= static_cast<double>(count);
    return true;
}

void clearDirect(TouchState& state) noexcept {
    for (DirectContact& contact : state.direct) {
        contact = {};
    }
}

void clearTouchpadGesture(TouchState& state) noexcept {
    state.gesture = GestureKind::None;
    state.peakTouchpadContacts = 0U;
    state.gestureStartTimestampUs = 0U;
    state.gestureMaximumTravel = 0.0;
    state.centroidValid = false;
    state.centroidX = 0.0;
    state.centroidY = 0.0;
    state.dragButtonDown = false;
}

void clearTouchpad(TouchState& state) noexcept {
    for (TouchpadContact& contact : state.touchpad) {
        contact = {};
    }
    clearTouchpadGesture(state);
}

void resetGestureIfEmpty(TouchState& state) noexcept {
    if (touchpadActiveCount(state) == 0U) {
        clearTouchpad(state);
    }
}

MoonlightInputEvent touchEvent(const MoonlightTouchEventContext& context,
                               std::uint8_t eventType,
                               std::uint32_t pointerId,
                               const MoonlightNormalizedPointerMapping* mapping,
                               const MoonlightTouchSample* sample,
                               std::uint8_t quarterTurns) noexcept {
    MoonlightInputEvent event;
    event.identity = context.identity;
    event.deviceId = context.deviceId;
    event.source = context.source;
    event.sourceGeneration = context.sourceGeneration;
    event.sourceSequence = context.sourceSequence;
    event.monotonicTimestampUs = context.monotonicTimestampUs;
    event.kind = MoonlightInputCommandKind::Touch;
    event.commandVersion = 1U;
    event.payloadSize = kMoonlightTouchCommandBytes;
    event.payload[0] = eventType;
    event.payload[1] = 0U;
    writeUint16(event.payload, 2U,
                sample == nullptr ? kMoonlightTouchRotationUnknown :
                    sourceRotation(sample->rotation, quarterTurns));
    writeUint32(event.payload, 4U, pointerId);
    if (mapping != nullptr && sample != nullptr) {
        writeFloat(event.payload, 8U, static_cast<float>(mapping->x));
        writeFloat(event.payload, 12U, static_cast<float>(mapping->y));
        writeFloat(event.payload, 16U, sample->pressure);
        writeFloat(event.payload, 20U, sample->contactAreaMajor);
        writeFloat(event.payload, 24U, sample->contactAreaMinor);
    }
    return event;
}

} // namespace

MoonlightTouchModeResolution resolveMoonlightTouchMode(
    const MoonlightTouchModeRequest& request) noexcept {
    MoonlightTouchModeResolution result;
    if (!knownMode(request.requested)) {
        return result;
    }
    result.effective = request.requested;
    if (request.requested == MoonlightTouchMode::Touchpad) {
        result.status = MoonlightTouchModeStatus::Ready;
    } else if (request.directTouchAvailable) {
        result.status = MoonlightTouchModeStatus::Ready;
    } else if (request.allowTouchpadFallback) {
        result.status = MoonlightTouchModeStatus::Degraded;
        result.effective = MoonlightTouchMode::Touchpad;
    } else {
        result.status = MoonlightTouchModeStatus::Unsupported;
    }
    return result;
}

bool decodeMoonlightTouchCommand(const MoonlightInputEvent& event,
                                 MoonlightTouchWireCommand& command) noexcept {
    if (!event.identity.valid() || event.deviceId == 0U ||
        event.source != MoonlightInputSource::Touchscreen ||
        event.sourceGeneration == 0U || event.sourceSequence == 0U ||
        event.monotonicTimestampUs == 0U ||
        event.kind != MoonlightInputCommandKind::Touch ||
        event.commandVersion != 1U ||
        event.payloadSize != kMoonlightTouchCommandBytes ||
        event.payload[1] != 0U || !zeroTail(event)) {
        return false;
    }
    MoonlightTouchWireCommand decoded;
    decoded.eventType = event.payload[0];
    decoded.rotation = readUint16(event.payload, 2U);
    decoded.pointerId = readUint32(event.payload, 4U);
    decoded.x = readFloat(event.payload, 8U);
    decoded.y = readFloat(event.payload, 12U);
    decoded.pressureOrDistance = readFloat(event.payload, 16U);
    decoded.contactAreaMajor = readFloat(event.payload, 20U);
    decoded.contactAreaMinor = readFloat(event.payload, 24U);

    const bool stateEvent = decoded.eventType == kMoonlightTouchEventDown ||
        decoded.eventType == kMoonlightTouchEventMove ||
        decoded.eventType == kMoonlightTouchEventUp;
    const bool cancel = decoded.eventType == kMoonlightTouchEventCancel;
    const bool cancelAll = decoded.eventType == kMoonlightTouchEventCancelAll;
    if ((!stateEvent && !cancel && !cancelAll) ||
        (stateEvent && decoded.pointerId == 0U) ||
        (cancel && decoded.pointerId == 0U) ||
        (cancelAll && decoded.pointerId != 0U)) {
        return false;
    }
    if (stateEvent) {
        if (!validWireValue(decoded.x) || !validWireValue(decoded.y) ||
            !validWireValue(decoded.pressureOrDistance) ||
            !validWireValue(decoded.contactAreaMajor) ||
            !validWireValue(decoded.contactAreaMinor) ||
            decoded.contactAreaMajor < decoded.contactAreaMinor ||
            (decoded.rotation != kMoonlightTouchRotationUnknown &&
             decoded.rotation >= 360U)) {
            return false;
        }
    } else if (decoded.rotation != kMoonlightTouchRotationUnknown ||
               decoded.x != 0.0F || decoded.y != 0.0F ||
               decoded.pressureOrDistance != 0.0F ||
               decoded.contactAreaMajor != 0.0F ||
               decoded.contactAreaMinor != 0.0F) {
        return false;
    }
    command = decoded;
    return true;
}

struct MoonlightTouchMapper::Impl final {
    enum class PendingKind : std::uint8_t {
        None = 0,
        Direct,
        Pointer,
    };

    struct Pending final {
        PendingKind kind = PendingKind::None;
        MoonlightInputEvent event{};
        TouchState stateAfter{};
        MoonlightTouchStatus successStatus = MoonlightTouchStatus::Applied;
        MoonlightTouchLocalAction localAction = MoonlightTouchLocalAction::None;
        MoonlightInputDispatchStatus lastDispatch =
            MoonlightInputDispatchStatus::Backpressure;
        std::size_t acceptedCommands = 0U;
        std::size_t pendingCommands = 0U;
        std::uint64_t cancelledCount = 0U;
    };

    Impl(std::shared_ptr<MoonlightInputBridge> valueBridge,
         std::shared_ptr<MoonlightPointerMapper> valuePointer,
         const MoonlightInputIdentity& valueIdentity,
         const MoonlightTouchLimits& valueLimits,
         bool valueDirectAvailable,
         MoonlightTouchMode initialMode) noexcept
        : bridge(std::move(valueBridge)), pointer(std::move(valuePointer)),
          identity(valueIdentity), limits(valueLimits),
          directAvailable(valueDirectAvailable) {
        state.mode = initialMode;
    }

    MoonlightTouchResult result(
        MoonlightTouchStatus status,
        MoonlightInputDispatchStatus dispatch = MoonlightInputDispatchStatus::InvalidRequest,
        MoonlightTouchLocalAction action = MoonlightTouchLocalAction::None,
        std::size_t accepted = 0U,
        std::size_t remaining = 0U) const noexcept {
        return {status, dispatch, action, accepted, remaining};
    }

    MoonlightTouchResult invalidResult() noexcept {
        invalidRequests = saturatingIncrement(invalidRequests);
        return result(MoonlightTouchStatus::InvalidRequest);
    }

    MoonlightTouchResult contextResult(
        const MoonlightTouchEventContext& context) noexcept {
        if (!context.valid() ||
            (state.mode == MoonlightTouchMode::Direct &&
             context.source != MoonlightInputSource::Touchscreen) ||
            (state.mode == MoonlightTouchMode::Touchpad &&
             context.source != MoonlightInputSource::Touchpad) ||
            (state.mode == MoonlightTouchMode::Touchpad &&
             !safePointerSourceSequence(context.sourceSequence))) {
            return invalidResult();
        }
        if (context.identity != identity) {
            return result(MoonlightTouchStatus::StaleOwner,
                          MoonlightInputDispatchStatus::StaleOwner);
        }
        return result(MoonlightTouchStatus::Applied,
                      MoonlightInputDispatchStatus::Accepted);
    }

    MoonlightTouchResult pendingResult() const noexcept {
        return result(MoonlightTouchStatus::Pending, pending.lastDispatch,
                      pending.localAction, pending.acceptedCommands,
                      pending.pendingCommands);
    }

    MoonlightTouchResult driveDirectPending() noexcept {
        if (pending.kind != PendingKind::Direct || bridge == nullptr) {
            return result(MoonlightTouchStatus::InvalidState,
                          MoonlightInputDispatchStatus::InvalidState);
        }
        const MoonlightInputDispatchStatus dispatch = bridge->dispatch(pending.event);
        pending.lastDispatch = dispatch;
        if (dispatch != MoonlightInputDispatchStatus::Accepted) {
            pending.pendingCommands = 1U;
            return result(touchStatus(dispatch), dispatch, pending.localAction,
                          0U, 1U);
        }
        const MoonlightTouchStatus successStatus = pending.successStatus;
        const MoonlightTouchLocalAction action = pending.localAction;
        const std::uint64_t cancelled = pending.cancelledCount;
        state = pending.stateAfter;
        pending = {};
        appliedTransactions = saturatingIncrement(appliedTransactions);
        for (std::uint64_t index = 0U; index < cancelled; ++index) {
            cancelledContacts = saturatingIncrement(cancelledContacts);
        }
        return result(successStatus, MoonlightInputDispatchStatus::Accepted,
                      action, 1U, 0U);
    }

    MoonlightTouchResult dispatchDirect(
        const MoonlightInputEvent& event,
        const TouchState& candidate,
        MoonlightTouchStatus successStatus = MoonlightTouchStatus::Applied,
        std::uint64_t cancelled = 0U) noexcept {
        pending = {};
        pending.kind = PendingKind::Direct;
        pending.event = event;
        pending.stateAfter = candidate;
        pending.successStatus = successStatus;
        pending.pendingCommands = 1U;
        pending.cancelledCount = cancelled;
        return driveDirectPending();
    }

    MoonlightTouchResult finishPointer(
        const MoonlightPointerResult& pointerResult,
        const TouchState& candidate,
        MoonlightTouchStatus successStatus = MoonlightTouchStatus::Applied,
        MoonlightTouchLocalAction action = MoonlightTouchLocalAction::None,
        std::uint64_t cancelled = 0U) noexcept {
        const MoonlightTouchStatus mapped = pointerStatus(pointerResult.status);
        if (pointerResult.status == MoonlightPointerStatus::Applied ||
            pointerResult.status == MoonlightPointerStatus::AppliedLocally ||
            pointerResult.status == MoonlightPointerStatus::AlreadyApplied) {
            state = candidate;
            appliedTransactions = saturatingIncrement(appliedTransactions);
            for (std::uint64_t index = 0U; index < cancelled; ++index) {
                cancelledContacts = saturatingIncrement(cancelledContacts);
            }
            return result(successStatus, pointerResult.dispatchStatus, action,
                          pointerResult.acceptedCommands, 0U);
        }
        const MoonlightPointerSnapshot pointerSnapshot = pointer->snapshot(identity);
        if (pointerSnapshot.pending) {
            pending = {};
            pending.kind = PendingKind::Pointer;
            pending.stateAfter = candidate;
            pending.successStatus = successStatus;
            pending.localAction = action;
            pending.lastDispatch = pointerResult.dispatchStatus;
            pending.acceptedCommands = pointerResult.acceptedCommands;
            pending.pendingCommands = pointerResult.pendingCommands;
            pending.cancelledCount = cancelled;
        }
        return result(mapped, pointerResult.dispatchStatus, action,
                      pointerResult.acceptedCommands,
                      pointerResult.pendingCommands);
    }

    MoonlightTouchResult resumePointerPending() noexcept {
        if (pending.kind != PendingKind::Pointer || pointer == nullptr) {
            return result(MoonlightTouchStatus::InvalidState,
                          MoonlightInputDispatchStatus::InvalidState);
        }
        const MoonlightPointerResult pointerResult = pointer->resumePending();
        if (pointerResult.status != MoonlightPointerStatus::Applied &&
            pointerResult.status != MoonlightPointerStatus::AppliedLocally &&
            pointerResult.status != MoonlightPointerStatus::AlreadyApplied) {
            pending.lastDispatch = pointerResult.dispatchStatus;
            pending.acceptedCommands = pointerResult.acceptedCommands;
            pending.pendingCommands = pointerResult.pendingCommands;
            return result(pointerStatus(pointerResult.status),
                          pointerResult.dispatchStatus, pending.localAction,
                          pointerResult.acceptedCommands,
                          pointerResult.pendingCommands);
        }
        const TouchState candidate = pending.stateAfter;
        const MoonlightTouchStatus successStatus = pending.successStatus;
        const MoonlightTouchLocalAction action = pending.localAction;
        const std::uint64_t cancelled = pending.cancelledCount;
        pending = {};
        state = candidate;
        appliedTransactions = saturatingIncrement(appliedTransactions);
        for (std::uint64_t index = 0U; index < cancelled; ++index) {
            cancelledContacts = saturatingIncrement(cancelledContacts);
        }
        return result(successStatus, MoonlightInputDispatchStatus::Accepted,
                      action, pointerResult.acceptedCommands, 0U);
    }

    MoonlightTouchResult updateSurface(const MoonlightTouchSurface& surface,
                                       TouchState& candidate) noexcept {
        if (!validSurface(surface)) {
            return invalidResult();
        }
        if (!state.surfaceConfigured) {
            candidate.surfaceConfigured = true;
            candidate.surface = surface;
            return result(MoonlightTouchStatus::AppliedLocally,
                          MoonlightInputDispatchStatus::Accepted);
        }
        if (surface.content.geometryGeneration <
                state.surface.content.geometryGeneration ||
            surface.hitMapGeneration < state.surface.hitMapGeneration) {
            staleGeometryEvents = saturatingIncrement(staleGeometryEvents);
            return result(MoonlightTouchStatus::StaleGeometry,
                          MoonlightInputDispatchStatus::StaleEvent);
        }
        const bool sameGenerations =
            surface.content.geometryGeneration ==
                state.surface.content.geometryGeneration &&
            surface.hitMapGeneration == state.surface.hitMapGeneration;
        if (sameGenerations && !sameSurface(surface, state.surface)) {
            return invalidResult();
        }
        if (!sameGenerations && anyContacts(state)) {
            return result(MoonlightTouchStatus::FlushRequired,
                          MoonlightInputDispatchStatus::InvalidState);
        }
        candidate.surfaceConfigured = true;
        candidate.surface = surface;
        return result(MoonlightTouchStatus::AppliedLocally,
                      MoonlightInputDispatchStatus::Accepted);
    }

    MoonlightTouchResult prepareObservedContext(
        const MoonlightTouchEventContext& context,
        bool allowGenerationFlush,
        TouchState& candidate) noexcept {
        ObservedTouchLane* lane = nullptr;
        ObservedTouchLane* empty = nullptr;
        for (ObservedTouchLane& current : candidate.lanes) {
            if (!current.occupied) {
                if (empty == nullptr) {
                    empty = &current;
                }
                continue;
            }
            if (current.deviceId == context.deviceId &&
                current.source == context.source) {
                lane = &current;
                break;
            }
        }
        if (lane == nullptr) {
            if (empty == nullptr) {
                return result(MoonlightTouchStatus::SourceCapacity,
                              MoonlightInputDispatchStatus::SourceCapacity);
            }
            lane = empty;
            lane->occupied = true;
            lane->deviceId = context.deviceId;
            lane->source = context.source;
            lane->sourceGeneration = context.sourceGeneration;
        } else if (context.sourceGeneration < lane->sourceGeneration) {
            return result(MoonlightTouchStatus::StaleEvent,
                          MoonlightInputDispatchStatus::StaleEvent);
        } else if (context.sourceGeneration > lane->sourceGeneration) {
            if (!allowGenerationFlush &&
                contactsForLane(state, context.deviceId, context.source,
                                lane->sourceGeneration)) {
                return result(MoonlightTouchStatus::FlushRequired,
                              MoonlightInputDispatchStatus::InvalidState);
            }
            lane->sourceGeneration = context.sourceGeneration;
            lane->lastSequence = 0U;
            lane->lastTimestampUs = 0U;
        }
        if (context.sourceSequence == lane->lastSequence) {
            return result(MoonlightTouchStatus::Duplicate,
                          MoonlightInputDispatchStatus::Duplicate);
        }
        if (context.sourceSequence < lane->lastSequence ||
            context.monotonicTimestampUs <= lane->lastTimestampUs) {
            return result(MoonlightTouchStatus::StaleEvent,
                          MoonlightInputDispatchStatus::StaleEvent);
        }
        lane->lastSequence = context.sourceSequence;
        lane->lastTimestampUs = context.monotonicTimestampUs;
        return result(MoonlightTouchStatus::AppliedLocally,
                      MoonlightInputDispatchStatus::Accepted);
    }

    MoonlightTouchResult directProcess(const MoonlightTouchEventContext& context,
                                       const MoonlightTouchSurface& surface,
                                       std::uint64_t localContactId,
                                       MoonlightTouchPhase phase,
                                       const MoonlightTouchSample& sample,
                                       TouchState candidate) noexcept {
        if (!directAvailable) {
            return result(MoonlightTouchStatus::Unsupported,
                          MoonlightInputDispatchStatus::Unsupported);
        }
        DirectContact* current = findDirect(candidate, context, localContactId);
        if (phase == MoonlightTouchPhase::Cancel) {
            if (current == nullptr) {
                return result(MoonlightTouchStatus::NotActive);
            }
            if (current->suppressed) {
                *current = {};
                state = candidate;
                localOnlyUpdates = saturatingIncrement(localOnlyUpdates);
                return result(MoonlightTouchStatus::AppliedLocally,
                              MoonlightInputDispatchStatus::Accepted);
            }
            const std::uint32_t wireId = current->wireId;
            *current = {};
            return dispatchDirect(
                touchEvent(context, kMoonlightTouchEventCancel, wireId,
                           nullptr, nullptr, 0U), candidate,
                MoonlightTouchStatus::Applied, 1U);
        }
        if (!validSample(sample)) {
            return invalidResult();
        }
        const MoonlightTouchResult surfaceResult = updateSurface(surface, candidate);
        if (surfaceResult.status != MoonlightTouchStatus::AppliedLocally) {
            return surfaceResult;
        }
        current = findDirect(candidate, context, localContactId);
        if (phase == MoonlightTouchPhase::Down) {
            if (current != nullptr) {
                return result(MoonlightTouchStatus::Duplicate,
                              MoonlightInputDispatchStatus::Duplicate);
            }
            DirectContact* slot = nullptr;
            std::size_t occupied = 0U;
            for (DirectContact& contact : candidate.direct) {
                if (contact.occupied) {
                    ++occupied;
                } else if (slot == nullptr) {
                    slot = &contact;
                }
            }
            if (slot == nullptr || occupied >= limits.maximumDirectContacts) {
                return result(MoonlightTouchStatus::ContactCapacity);
            }
            slot->occupied = true;
            slot->localId = localContactId;
            slot->deviceId = context.deviceId;
            slot->sourceGeneration = context.sourceGeneration;
            const MoonlightNormalizedPointerMapping mapping =
                mapMoonlightNormalizedPointer(surface.content,
                                               sample.pointX, sample.pointY);
            if (excluded(surface, sample.pointX, sample.pointY) ||
                mapping.status == MoonlightPointerMapStatus::OutsideContent) {
                slot->suppressed = true;
                state = candidate;
                localOnlyUpdates = saturatingIncrement(localOnlyUpdates);
                if (excluded(surface, sample.pointX, sample.pointY)) {
                    overlayConsumedEvents = saturatingIncrement(overlayConsumedEvents);
                    return result(MoonlightTouchStatus::OverlayConsumed,
                                  MoonlightInputDispatchStatus::Accepted);
                }
                outsideContentEvents = saturatingIncrement(outsideContentEvents);
                return result(MoonlightTouchStatus::OutsideContent,
                              MoonlightInputDispatchStatus::Accepted);
            }
            if (mapping.status != MoonlightPointerMapStatus::Mapped) {
                return invalidResult();
            }
            slot->wireId = allocateWireId(candidate);
            if (slot->wireId == 0U) {
                return result(MoonlightTouchStatus::ContactCapacity);
            }
            return dispatchDirect(
                touchEvent(context, kMoonlightTouchEventDown, slot->wireId,
                           &mapping, &sample,
                           surface.content.clockwiseQuarterTurns), candidate);
        }
        if (current == nullptr) {
            return result(MoonlightTouchStatus::NotActive);
        }
        if (current->suppressed) {
            if (phase == MoonlightTouchPhase::Up) {
                *current = {};
                state = candidate;
                localOnlyUpdates = saturatingIncrement(localOnlyUpdates);
                return result(MoonlightTouchStatus::AppliedLocally,
                              MoonlightInputDispatchStatus::Accepted);
            }
            overlayConsumedEvents = saturatingIncrement(overlayConsumedEvents);
            return result(MoonlightTouchStatus::OverlayConsumed,
                          MoonlightInputDispatchStatus::Accepted);
        }

        const MoonlightNormalizedPointerMapping mapping =
            mapMoonlightNormalizedPointer(surface.content,
                                           sample.pointX, sample.pointY);
        const bool inOverlay = excluded(surface, sample.pointX, sample.pointY);
        if (inOverlay || mapping.status == MoonlightPointerMapStatus::OutsideContent) {
            const std::uint32_t wireId = current->wireId;
            if (phase == MoonlightTouchPhase::Move) {
                current->suppressed = true;
                current->wireId = 0U;
            } else {
                *current = {};
            }
            if (inOverlay) {
                overlayConsumedEvents = saturatingIncrement(overlayConsumedEvents);
            } else {
                outsideContentEvents = saturatingIncrement(outsideContentEvents);
            }
            return dispatchDirect(
                touchEvent(context, kMoonlightTouchEventCancel, wireId,
                           nullptr, nullptr, 0U), candidate,
                inOverlay ? MoonlightTouchStatus::OverlayConsumed :
                            MoonlightTouchStatus::OutsideContent,
                1U);
        }
        if (mapping.status != MoonlightPointerMapStatus::Mapped) {
            return invalidResult();
        }
        const std::uint32_t wireId = current->wireId;
        const std::uint8_t eventType = phase == MoonlightTouchPhase::Move ?
            kMoonlightTouchEventMove : kMoonlightTouchEventUp;
        if (phase == MoonlightTouchPhase::Up) {
            *current = {};
        }
        return dispatchDirect(
            touchEvent(context, eventType, wireId, &mapping, &sample,
                       surface.content.clockwiseQuarterTurns), candidate);
    }

    MoonlightTouchResult touchpadProcess(const MoonlightTouchEventContext& context,
                                         const MoonlightTouchSurface& surface,
                                         std::uint64_t localContactId,
                                         MoonlightTouchPhase phase,
                                         const MoonlightTouchSample& sample,
                                         TouchState candidate) noexcept {
        if (phase == MoonlightTouchPhase::Cancel) {
            // The observed lane is committed together with the cancellation.
            TouchpadContact* contact = findTouchpad(candidate, context, localContactId);
            if (contact == nullptr) {
                return result(MoonlightTouchStatus::NotActive);
            }
            const bool release = candidate.dragButtonDown;
            clearTouchpad(candidate);
            if (!release) {
                state = candidate;
                localOnlyUpdates = saturatingIncrement(localOnlyUpdates);
                cancelledContacts = saturatingIncrement(cancelledContacts);
                return result(MoonlightTouchStatus::AppliedLocally,
                              MoonlightInputDispatchStatus::Accepted);
            }
            return finishPointer(pointer->releaseAll(pointerContext(context)), candidate,
                                 MoonlightTouchStatus::Applied,
                                 MoonlightTouchLocalAction::None, 1U);
        }
        if (!std::isfinite(sample.pointX) || !std::isfinite(sample.pointY)) {
            return invalidResult();
        }
        const MoonlightTouchResult surfaceResult = updateSurface(surface, candidate);
        if (surfaceResult.status != MoonlightTouchStatus::AppliedLocally) {
            return surfaceResult;
        }
        TouchpadContact* current = findTouchpad(candidate, context, localContactId);
        if (phase == MoonlightTouchPhase::Down) {
            if (current != nullptr) {
                return result(MoonlightTouchStatus::Duplicate,
                              MoonlightInputDispatchStatus::Duplicate);
            }
            TouchpadContact* slot = nullptr;
            std::size_t occupied = 0U;
            for (TouchpadContact& contact : candidate.touchpad) {
                if (contact.occupied) {
                    ++occupied;
                } else if (slot == nullptr) {
                    slot = &contact;
                }
            }
            if (slot == nullptr || occupied >= limits.maximumTouchpadContacts) {
                return result(MoonlightTouchStatus::ContactCapacity);
            }
            slot->occupied = true;
            slot->suppressed = excluded(surface, sample.pointX, sample.pointY);
            slot->localId = localContactId;
            slot->deviceId = context.deviceId;
            slot->sourceGeneration = context.sourceGeneration;
            slot->downTimestampUs = context.monotonicTimestampUs;
            slot->startX = slot->lastX = sample.pointX;
            slot->startY = slot->lastY = sample.pointY;
            if (slot->suppressed) {
                state = candidate;
                overlayConsumedEvents = saturatingIncrement(overlayConsumedEvents);
                localOnlyUpdates = saturatingIncrement(localOnlyUpdates);
                return result(MoonlightTouchStatus::OverlayConsumed,
                              MoonlightInputDispatchStatus::Accepted);
            }

            const std::size_t active = touchpadRemoteCount(candidate);
            const bool releaseDrag = candidate.dragButtonDown && active > 1U;
            if (active == 1U) {
                candidate.gesture = GestureKind::SingleCandidate;
                candidate.peakTouchpadContacts = 1U;
                candidate.gestureStartTimestampUs = context.monotonicTimestampUs;
                candidate.gestureMaximumTravel = 0.0;
                candidate.centroidValid = computeCentroid(
                    candidate, candidate.centroidX, candidate.centroidY);
            } else if (active == 2U) {
                candidate.gesture = GestureKind::MultiCandidate;
                candidate.peakTouchpadContacts = 2U;
                candidate.centroidValid = computeCentroid(
                    candidate, candidate.centroidX, candidate.centroidY);
                candidate.dragButtonDown = false;
            } else {
                candidate.gesture = GestureKind::ThreeCandidate;
                candidate.peakTouchpadContacts = 3U;
                candidate.centroidValid = false;
                candidate.dragButtonDown = false;
            }
            if (releaseDrag) {
                return finishPointer(
                    pointer->releaseAll(pointerContext(context)), candidate);
            }
            state = candidate;
            localOnlyUpdates = saturatingIncrement(localOnlyUpdates);
            return result(MoonlightTouchStatus::AppliedLocally,
                          MoonlightInputDispatchStatus::Accepted);
        }
        if (current == nullptr) {
            return result(MoonlightTouchStatus::NotActive);
        }
        if (current->suppressed) {
            if (phase == MoonlightTouchPhase::Up) {
                *current = {};
                resetGestureIfEmpty(candidate);
                state = candidate;
                localOnlyUpdates = saturatingIncrement(localOnlyUpdates);
                return result(MoonlightTouchStatus::AppliedLocally,
                              MoonlightInputDispatchStatus::Accepted);
            }
            overlayConsumedEvents = saturatingIncrement(overlayConsumedEvents);
            return result(MoonlightTouchStatus::OverlayConsumed,
                          MoonlightInputDispatchStatus::Accepted);
        }
        if (excluded(surface, sample.pointX, sample.pointY)) {
            const bool release = candidate.dragButtonDown;
            for (TouchpadContact& contact : candidate.touchpad) {
                if (contact.occupied) {
                    contact.suppressed = true;
                }
            }
            candidate.gesture = GestureKind::None;
            candidate.centroidValid = false;
            candidate.dragButtonDown = false;
            overlayConsumedEvents = saturatingIncrement(overlayConsumedEvents);
            if (release) {
                return finishPointer(
                    pointer->releaseAll(pointerContext(context)), candidate,
                    MoonlightTouchStatus::OverlayConsumed,
                    MoonlightTouchLocalAction::None, 1U);
            }
            state = candidate;
            localOnlyUpdates = saturatingIncrement(localOnlyUpdates);
            return result(MoonlightTouchStatus::OverlayConsumed,
                          MoonlightInputDispatchStatus::Accepted);
        }

        const double previousX = current->lastX;
        const double previousY = current->lastY;
        current->lastX = sample.pointX;
        current->lastY = sample.pointY;
        current->maximumTravel = std::max(
            current->maximumTravel,
            distance(current->startX, current->startY,
                     sample.pointX, sample.pointY));
        candidate.gestureMaximumTravel = std::max(
            candidate.gestureMaximumTravel, current->maximumTravel);
        const std::size_t activeBeforeUp = touchpadRemoteCount(candidate);

        if (phase == MoonlightTouchPhase::Move) {
            if (activeBeforeUp == 1U) {
                const std::uint64_t elapsed = context.monotonicTimestampUs >=
                        current->downTimestampUs ?
                    context.monotonicTimestampUs - current->downTimestampUs : 0U;
                if (candidate.gesture == GestureKind::SingleCandidate &&
                    elapsed >= limits.touchpad.longPressDurationUs &&
                    current->maximumTravel <=
                        limits.touchpad.longPressTravelPixels) {
                    candidate.gesture = GestureKind::Drag;
                    candidate.dragButtonDown = true;
                    return finishPointer(pointer->button(
                        pointerContext(context), MoonlightPointerButton::Left, true),
                        candidate);
                }
                const double deltaX = sample.pointX - previousX;
                const double deltaY = sample.pointY - previousY;
                if (candidate.gesture == GestureKind::SingleCandidate &&
                    current->maximumTravel <=
                        limits.touchpad.motionDeadZonePixels) {
                    state = candidate;
                    localOnlyUpdates = saturatingIncrement(localOnlyUpdates);
                    return result(MoonlightTouchStatus::AppliedLocally,
                                  MoonlightInputDispatchStatus::Accepted);
                }
                if (candidate.gesture == GestureKind::SingleCandidate) {
                    candidate.gesture = GestureKind::Cursor;
                }
                if (candidate.gesture == GestureKind::Cursor ||
                    candidate.gesture == GestureKind::Drag) {
                    return finishPointer(pointer->relativeMotion(
                        pointerContext(context), deltaX, deltaY), candidate);
                }
            } else if (activeBeforeUp == 2U) {
                double nextX = 0.0;
                double nextY = 0.0;
                if (!computeCentroid(candidate, nextX, nextY)) {
                    return invalidResult();
                }
                if (!candidate.centroidValid) {
                    candidate.centroidValid = true;
                    candidate.centroidX = nextX;
                    candidate.centroidY = nextY;
                    state = candidate;
                    localOnlyUpdates = saturatingIncrement(localOnlyUpdates);
                    return result(MoonlightTouchStatus::AppliedLocally,
                                  MoonlightInputDispatchStatus::Accepted);
                }
                const double deltaX = (nextX - candidate.centroidX) *
                    limits.touchpad.scrollScale;
                const double deltaY = (nextY - candidate.centroidY) *
                    limits.touchpad.scrollScale;
                candidate.centroidX = nextX;
                candidate.centroidY = nextY;
                if (candidate.gesture == GestureKind::MultiCandidate &&
                    std::hypot(deltaX, deltaY) <=
                        limits.touchpad.motionDeadZonePixels) {
                    state = candidate;
                    localOnlyUpdates = saturatingIncrement(localOnlyUpdates);
                    return result(MoonlightTouchStatus::AppliedLocally,
                                  MoonlightInputDispatchStatus::Accepted);
                }
                candidate.gesture = GestureKind::Scroll;
                const double roundedX = std::round(deltaX);
                const double roundedY = std::round(deltaY);
                if (roundedX < static_cast<double>(std::numeric_limits<std::int16_t>::min()) ||
                    roundedX > static_cast<double>(std::numeric_limits<std::int16_t>::max()) ||
                    roundedY < static_cast<double>(std::numeric_limits<std::int16_t>::min()) ||
                    roundedY > static_cast<double>(std::numeric_limits<std::int16_t>::max())) {
                    return result(MoonlightTouchStatus::OutOfRange);
                }
                return finishPointer(pointer->scroll2D(
                    pointerContext(context), static_cast<std::int32_t>(roundedX),
                    static_cast<std::int32_t>(roundedY)), candidate);
            }
            state = candidate;
            localOnlyUpdates = saturatingIncrement(localOnlyUpdates);
            return result(MoonlightTouchStatus::AppliedLocally,
                          MoonlightInputDispatchStatus::Accepted);
        }

        // Up completes a gesture only after the final participating contact.
        *current = {};
        const std::size_t remaining = touchpadRemoteCount(candidate);
        if (remaining != 0U) {
            state = candidate;
            localOnlyUpdates = saturatingIncrement(localOnlyUpdates);
            return result(MoonlightTouchStatus::AppliedLocally,
                          MoonlightInputDispatchStatus::Accepted);
        }
        const std::uint64_t elapsed = context.monotonicTimestampUs >=
                candidate.gestureStartTimestampUs ?
            context.monotonicTimestampUs - candidate.gestureStartTimestampUs : 0U;
        const GestureKind completedGesture = candidate.gesture;
        const std::size_t peak = candidate.peakTouchpadContacts;
        const bool tap = elapsed <= limits.touchpad.tapMaximumDurationUs &&
            candidate.gestureMaximumTravel <= limits.touchpad.tapTravelPixels;
        const bool releaseDrag = candidate.dragButtonDown;
        clearTouchpadGesture(candidate);
        if (releaseDrag || completedGesture == GestureKind::Drag) {
            return finishPointer(pointer->releaseAll(pointerContext(context)), candidate);
        }
        if (tap && peak == 1U && completedGesture == GestureKind::SingleCandidate) {
            return finishPointer(pointer->click(
                pointerContext(context), MoonlightPointerButton::Left), candidate);
        }
        if (tap && peak == 2U && completedGesture == GestureKind::MultiCandidate) {
            return finishPointer(pointer->click(
                pointerContext(context), MoonlightPointerButton::Right), candidate);
        }
        if (tap && peak == 3U && completedGesture == GestureKind::ThreeCandidate) {
            state = candidate;
            localOnlyUpdates = saturatingIncrement(localOnlyUpdates);
            return result(MoonlightTouchStatus::AppliedLocally,
                          MoonlightInputDispatchStatus::Accepted,
                          MoonlightTouchLocalAction::ToggleToolbar);
        }
        state = candidate;
        localOnlyUpdates = saturatingIncrement(localOnlyUpdates);
        return result(MoonlightTouchStatus::AppliedLocally,
                      MoonlightInputDispatchStatus::Accepted);
    }

    MoonlightTouchResult flush(const MoonlightTouchEventContext& context,
                               MoonlightTouchMode modeAfter,
                               TouchState candidate) noexcept {
        const bool modeChanged = state.mode != modeAfter;
        candidate.mode = modeAfter;
        if (state.mode == MoonlightTouchMode::Direct) {
            const std::size_t active = directActiveCount(candidate);
            const std::size_t suppressed = directSuppressedCount(candidate);
            clearDirect(candidate);
            if (active == 0U) {
                state = candidate;
                if (suppressed == 0U && !modeChanged) {
                    return result(MoonlightTouchStatus::AlreadyApplied,
                                  MoonlightInputDispatchStatus::Accepted);
                }
                localOnlyUpdates = saturatingIncrement(localOnlyUpdates);
                return result(MoonlightTouchStatus::AppliedLocally,
                              MoonlightInputDispatchStatus::Accepted);
            }
            MoonlightInputEvent event = touchEvent(
                context, kMoonlightTouchEventCancelAll, 0U,
                nullptr, nullptr, 0U);
            event.lifecycleRelease = true;
            return dispatchDirect(
                event, candidate,
                MoonlightTouchStatus::Applied,
                static_cast<std::uint64_t>(active));
        }
        const bool release = candidate.dragButtonDown;
        const std::size_t contacts = touchpadActiveCount(candidate);
        clearTouchpad(candidate);
        candidate.mode = modeAfter;
        if (release) {
            return finishPointer(pointer->releaseAll(pointerContext(context)), candidate,
                                 MoonlightTouchStatus::Applied,
                                 MoonlightTouchLocalAction::None,
                                 static_cast<std::uint64_t>(contacts));
        }
        state = candidate;
        if (contacts == 0U && !modeChanged) {
            return result(MoonlightTouchStatus::AlreadyApplied,
                          MoonlightInputDispatchStatus::Accepted);
        }
        localOnlyUpdates = saturatingIncrement(localOnlyUpdates);
        return result(MoonlightTouchStatus::AppliedLocally,
                      MoonlightInputDispatchStatus::Accepted);
    }

    mutable std::mutex mutex;
    std::shared_ptr<MoonlightInputBridge> bridge;
    std::shared_ptr<MoonlightPointerMapper> pointer;
    MoonlightInputIdentity identity{};
    MoonlightTouchLimits limits{};
    bool directAvailable = false;
    TouchState state{};
    Pending pending{};
    std::uint64_t appliedTransactions = 0U;
    std::uint64_t localOnlyUpdates = 0U;
    std::uint64_t overlayConsumedEvents = 0U;
    std::uint64_t outsideContentEvents = 0U;
    std::uint64_t cancelledContacts = 0U;
    std::uint64_t invalidRequests = 0U;
    std::uint64_t staleGeometryEvents = 0U;
};

MoonlightTouchMapper::MoonlightTouchMapper(std::unique_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}

MoonlightTouchMapper::~MoonlightTouchMapper() {
    if (impl_ == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->pending = {};
    impl_->state = {};
    impl_->pointer.reset();
    impl_->bridge.reset();
}

std::shared_ptr<MoonlightTouchMapper> MoonlightTouchMapper::create(
    std::shared_ptr<MoonlightInputBridge> bridge,
    const MoonlightInputIdentity& identity,
    const MoonlightTouchModeRequest& modeRequest,
    MoonlightTouchLimits limits,
    MoonlightPointerLimits pointerLimits) noexcept {
    const MoonlightTouchModeResolution resolution =
        resolveMoonlightTouchMode(modeRequest);
    const MoonlightTouchpadSettings& settings = limits.touchpad;
    if (bridge == nullptr || !identity.valid() ||
        (resolution.status != MoonlightTouchModeStatus::Ready &&
         resolution.status != MoonlightTouchModeStatus::Degraded) ||
        limits.maximumDirectContacts == 0U ||
        limits.maximumDirectContacts > kMoonlightMaximumTouchContacts ||
        limits.maximumTouchpadContacts == 0U ||
        limits.maximumTouchpadContacts > kMoonlightMaximumTouchpadContacts ||
        !std::isfinite(settings.motionDeadZonePixels) ||
        !std::isfinite(settings.tapTravelPixels) ||
        !std::isfinite(settings.longPressTravelPixels) ||
        !std::isfinite(settings.scrollScale) ||
        settings.motionDeadZonePixels < 0.0 || settings.tapTravelPixels < 0.0 ||
        settings.longPressTravelPixels < 0.0 || settings.scrollScale <= 0.0 ||
        settings.tapMaximumDurationUs == 0U || settings.longPressDurationUs == 0U) {
        return nullptr;
    }
    std::shared_ptr<MoonlightPointerMapper> pointer =
        MoonlightPointerMapper::create(bridge, identity, pointerLimits);
    if (pointer == nullptr) {
        return nullptr;
    }
    try {
        return std::shared_ptr<MoonlightTouchMapper>(new MoonlightTouchMapper(
            std::make_unique<Impl>(std::move(bridge), std::move(pointer), identity,
                                   limits, modeRequest.directTouchAvailable,
                                   resolution.effective)));
    } catch (...) {
        return nullptr;
    }
}

MoonlightTouchResult MoonlightTouchMapper::process(
    const MoonlightTouchEventContext& context,
    const MoonlightTouchSurface& surface,
    std::uint64_t localContactId,
    MoonlightTouchPhase phase,
    const MoonlightTouchSample& sample) noexcept {
    if (impl_ == nullptr) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const MoonlightTouchResult contextStatus = impl_->contextResult(context);
    if (contextStatus.status != MoonlightTouchStatus::Applied) {
        return contextStatus;
    }
    if (impl_->pending.kind != Impl::PendingKind::None) {
        return impl_->pendingResult();
    }
    if (localContactId == 0U || !knownPhase(phase)) {
        return impl_->invalidResult();
    }
    TouchState candidate = impl_->state;
    const MoonlightTouchResult observed = impl_->prepareObservedContext(
        context, false, candidate);
    if (observed.status != MoonlightTouchStatus::AppliedLocally) {
        return observed;
    }
    if (impl_->state.mode == MoonlightTouchMode::Direct) {
        return impl_->directProcess(context, surface, localContactId, phase, sample,
                                    candidate);
    }
    return impl_->touchpadProcess(context, surface, localContactId, phase, sample,
                                  candidate);
}

MoonlightTouchResult MoonlightTouchMapper::cancelAll(
    const MoonlightTouchEventContext& context) noexcept {
    if (impl_ == nullptr) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const MoonlightTouchResult contextStatus = impl_->contextResult(context);
    if (contextStatus.status != MoonlightTouchStatus::Applied) {
        return contextStatus;
    }
    if (impl_->pending.kind != Impl::PendingKind::None) {
        return impl_->pendingResult();
    }
    TouchState candidate = impl_->state;
    const MoonlightTouchResult observed = impl_->prepareObservedContext(
        context, true, candidate);
    if (observed.status != MoonlightTouchStatus::AppliedLocally) {
        return observed;
    }
    return impl_->flush(context, impl_->state.mode, candidate);
}

MoonlightTouchResult MoonlightTouchMapper::switchMode(
    const MoonlightTouchEventContext& context,
    MoonlightTouchMode mode) noexcept {
    if (impl_ == nullptr) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const MoonlightTouchResult contextStatus = impl_->contextResult(context);
    if (contextStatus.status != MoonlightTouchStatus::Applied) {
        return contextStatus;
    }
    if (impl_->pending.kind != Impl::PendingKind::None) {
        return impl_->pendingResult();
    }
    if (!knownMode(mode) ||
        (mode == MoonlightTouchMode::Direct && !impl_->directAvailable)) {
        return mode == MoonlightTouchMode::Direct ?
            impl_->result(MoonlightTouchStatus::Unsupported,
                          MoonlightInputDispatchStatus::Unsupported) :
            impl_->invalidResult();
    }
    if (mode == impl_->state.mode) {
        return impl_->result(MoonlightTouchStatus::AlreadyApplied,
                             MoonlightInputDispatchStatus::Accepted);
    }
    TouchState candidate = impl_->state;
    const MoonlightTouchResult observed = impl_->prepareObservedContext(
        context, true, candidate);
    if (observed.status != MoonlightTouchStatus::AppliedLocally) {
        return observed;
    }
    return impl_->flush(context, mode, candidate);
}

MoonlightTouchResult MoonlightTouchMapper::resumePending() noexcept {
    if (impl_ == nullptr) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->pending.kind == Impl::PendingKind::Direct) {
        return impl_->driveDirectPending();
    }
    if (impl_->pending.kind == Impl::PendingKind::Pointer) {
        return impl_->resumePointerPending();
    }
    return impl_->result(MoonlightTouchStatus::InvalidState,
                         MoonlightInputDispatchStatus::InvalidState);
}

bool MoonlightTouchMapper::cancelPendingIfUnsent(
    const MoonlightInputIdentity& identity) noexcept {
    if (impl_ == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (identity != impl_->identity ||
        impl_->pending.kind == Impl::PendingKind::None) {
        return false;
    }
    if (impl_->pending.kind == Impl::PendingKind::Pointer &&
        !impl_->pointer->cancelPendingIfUnsent(identity)) {
        return false;
    }
    if (impl_->pending.kind == Impl::PendingKind::Direct &&
        impl_->pending.acceptedCommands != 0U) {
        return false;
    }
    impl_->pending = {};
    return true;
}

bool MoonlightTouchMapper::discardLocalState(
    const MoonlightInputIdentity& identity) noexcept {
    if (impl_ == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (identity != impl_->identity) {
        return false;
    }
    const MoonlightTouchMode mode = impl_->state.mode;
    impl_->pending = {};
    impl_->state = {};
    impl_->state.mode = mode;
    impl_->localOnlyUpdates = saturatingIncrement(impl_->localOnlyUpdates);
    return true;
}

MoonlightTouchSnapshot MoonlightTouchMapper::snapshot(
    const MoonlightInputIdentity& identity) const noexcept {
    MoonlightTouchSnapshot result;
    if (impl_ == nullptr) {
        return result;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (identity != impl_->identity) {
        return result;
    }
    result.matched = true;
    result.identity = impl_->identity;
    result.mode = impl_->state.mode;
    result.activeDirectContacts = directActiveCount(impl_->state);
    result.suppressedDirectContacts = directSuppressedCount(impl_->state);
    result.activeTouchpadContacts = touchpadActiveCount(impl_->state);
    result.touchpadDragButtonDown = impl_->state.dragButtonDown;
    result.geometryGeneration = impl_->state.surfaceConfigured ?
        impl_->state.surface.content.geometryGeneration : 0U;
    result.hitMapGeneration = impl_->state.surfaceConfigured ?
        impl_->state.surface.hitMapGeneration : 0U;
    result.pending = impl_->pending.kind != Impl::PendingKind::None;
    result.pendingCommands = result.pending ? impl_->pending.pendingCommands : 0U;
    result.appliedTransactions = impl_->appliedTransactions;
    result.localOnlyUpdates = impl_->localOnlyUpdates;
    result.overlayConsumedEvents = impl_->overlayConsumedEvents;
    result.outsideContentEvents = impl_->outsideContentEvents;
    result.cancelledContacts = impl_->cancelledContacts;
    result.invalidRequests = impl_->invalidRequests;
    result.staleGeometryEvents = impl_->staleGeometryEvents;
    return result;
}

} // namespace remotedesk::moonlight
