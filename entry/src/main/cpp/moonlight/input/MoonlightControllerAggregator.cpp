#include "moonlight/input/MoonlightControllerAggregator.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <limits>
#include <mutex>
#include <new>
#include <optional>
#include <utility>

namespace remotedesk::moonlight {
namespace {

constexpr double kLayoutEpsilon = 1.0e-9;
constexpr double kFallbackGridStep = 0.02;

std::uint64_t saturatingIncrement(std::uint64_t value) noexcept {
    return value == std::numeric_limits<std::uint64_t>::max() ? value : value + 1U;
}

bool finite(double value) noexcept {
    return std::isfinite(value);
}

bool finiteRect(const MoonlightControllerNormalizedRect& rect) noexcept {
    return finite(rect.left) && finite(rect.top) && finite(rect.width) &&
        finite(rect.height);
}

bool canvasRect(const MoonlightControllerNormalizedRect& rect) noexcept {
    return finiteRect(rect) && rect.width > 0.0 && rect.height > 0.0 &&
        rect.left >= 0.0 && rect.top >= 0.0 &&
        rect.left + rect.width <= 1.0 + kLayoutEpsilon &&
        rect.top + rect.height <= 1.0 + kLayoutEpsilon;
}

bool intersects(const MoonlightControllerNormalizedRect& left,
                const MoonlightControllerNormalizedRect& right) noexcept {
    return left.left < right.left + right.width - kLayoutEpsilon &&
        right.left < left.left + left.width - kLayoutEpsilon &&
        left.top < right.top + right.height - kLayoutEpsilon &&
        right.top < left.top + left.height - kLayoutEpsilon;
}

bool knownElement(MoonlightVirtualControllerElementKind kind) noexcept {
    switch (kind) {
        case MoonlightVirtualControllerElementKind::FaceA:
        case MoonlightVirtualControllerElementKind::FaceB:
        case MoonlightVirtualControllerElementKind::FaceX:
        case MoonlightVirtualControllerElementKind::FaceY:
        case MoonlightVirtualControllerElementKind::DpadCluster:
        case MoonlightVirtualControllerElementKind::DpadUp:
        case MoonlightVirtualControllerElementKind::DpadDown:
        case MoonlightVirtualControllerElementKind::DpadLeft:
        case MoonlightVirtualControllerElementKind::DpadRight:
        case MoonlightVirtualControllerElementKind::LeftStick:
        case MoonlightVirtualControllerElementKind::RightStick:
        case MoonlightVirtualControllerElementKind::LeftTrigger:
        case MoonlightVirtualControllerElementKind::RightTrigger:
        case MoonlightVirtualControllerElementKind::LeftShoulder:
        case MoonlightVirtualControllerElementKind::RightShoulder:
        case MoonlightVirtualControllerElementKind::LeftStickClick:
        case MoonlightVirtualControllerElementKind::RightStickClick:
        case MoonlightVirtualControllerElementKind::Menu:
        case MoonlightVirtualControllerElementKind::Back:
        case MoonlightVirtualControllerElementKind::Special:
            return true;
        case MoonlightVirtualControllerElementKind::Invalid:
            return false;
    }
    return false;
}

bool stickSized(MoonlightVirtualControllerElementKind kind) noexcept {
    return kind == MoonlightVirtualControllerElementKind::DpadCluster ||
        kind == MoonlightVirtualControllerElementKind::LeftStick ||
        kind == MoonlightVirtualControllerElementKind::RightStick;
}

double minimumTarget(MoonlightVirtualControllerElementKind kind) noexcept {
    return stickSized(kind) ? kMoonlightMinimumControllerStickTarget :
        kMoonlightMinimumControllerTouchTarget;
}

bool validElementShape(const MoonlightVirtualControllerElement& element) noexcept {
    if (element.id == 0U || !knownElement(element.kind) ||
        !finiteRect(element.bounds)) {
        return false;
    }
    const double minimum = minimumTarget(element.kind);
    return element.bounds.width >= minimum &&
        element.bounds.height >= minimum &&
        element.bounds.width <= 0.45 && element.bounds.height <= 0.45;
}

bool validEnvironment(const MoonlightControllerLayoutEnvironment& environment,
                      MoonlightControllerNormalizedRect& content) noexcept {
    const auto& safe = environment.safeArea;
    if (!finite(safe.leftInset) || !finite(safe.topInset) ||
        !finite(safe.rightInset) || !finite(safe.bottomInset) ||
        safe.leftInset < 0.0 || safe.topInset < 0.0 ||
        safe.rightInset < 0.0 || safe.bottomInset < 0.0 ||
        safe.leftInset > 0.25 || safe.topInset > 0.25 ||
        safe.rightInset > 0.25 || safe.bottomInset > 0.25 ||
        environment.conflictZoneCount >
            kMoonlightMaximumControllerConflictZones) {
        return false;
    }
    content = {safe.leftInset, safe.topInset,
               1.0 - safe.leftInset - safe.rightInset,
               1.0 - safe.topInset - safe.bottomInset};
    if (content.width < 0.60 || content.height < 0.60) {
        return false;
    }
    double conflictArea = 0.0;
    for (std::size_t index = 0U; index < environment.conflictZoneCount;
         ++index) {
        const auto& zone = environment.conflictZones[index];
        if (!canvasRect(zone)) {
            return false;
        }
        conflictArea += zone.width * zone.height;
    }
    return conflictArea <= 0.35;
}

MoonlightControllerNormalizedRect clampToContent(
    const MoonlightControllerNormalizedRect& rect,
    const MoonlightControllerNormalizedRect& content) noexcept {
    MoonlightControllerNormalizedRect result = rect;
    const double maximumLeft = content.left + content.width - rect.width;
    const double maximumTop = content.top + content.height - rect.height;
    result.left = std::clamp(rect.left, content.left, maximumLeft);
    result.top = std::clamp(rect.top, content.top, maximumTop);
    return result;
}

bool sameRect(const MoonlightControllerNormalizedRect& left,
              const MoonlightControllerNormalizedRect& right) noexcept {
    return left.left == right.left && left.top == right.top &&
        left.width == right.width && left.height == right.height;
}

bool conflicts(const MoonlightControllerNormalizedRect& rect,
               const MoonlightControllerLayoutEnvironment& environment,
               const MoonlightVirtualControllerLayout& placed) noexcept {
    for (std::size_t index = 0U; index < environment.conflictZoneCount;
         ++index) {
        if (intersects(rect, environment.conflictZones[index])) {
            return true;
        }
    }
    for (std::size_t index = 0U; index < placed.elementCount; ++index) {
        if (intersects(rect, placed.elements[index].bounds)) {
            return true;
        }
    }
    return false;
}

bool hasKind(const MoonlightVirtualControllerLayout& layout,
             MoonlightVirtualControllerElementKind kind) noexcept {
    for (std::size_t index = 0U; index < layout.elementCount; ++index) {
        if (layout.elements[index].kind == kind) {
            return true;
        }
    }
    return false;
}

bool completeLayout(const MoonlightVirtualControllerLayout& layout) noexcept {
    const bool cluster = hasKind(
        layout, MoonlightVirtualControllerElementKind::DpadCluster);
    const bool split = hasKind(layout, MoonlightVirtualControllerElementKind::DpadUp) &&
        hasKind(layout, MoonlightVirtualControllerElementKind::DpadDown) &&
        hasKind(layout, MoonlightVirtualControllerElementKind::DpadLeft) &&
        hasKind(layout, MoonlightVirtualControllerElementKind::DpadRight);
    if (cluster == split) {
        return false;
    }
    constexpr std::array<MoonlightVirtualControllerElementKind, 15U> required{{
        MoonlightVirtualControllerElementKind::FaceA,
        MoonlightVirtualControllerElementKind::FaceB,
        MoonlightVirtualControllerElementKind::FaceX,
        MoonlightVirtualControllerElementKind::FaceY,
        MoonlightVirtualControllerElementKind::LeftStick,
        MoonlightVirtualControllerElementKind::RightStick,
        MoonlightVirtualControllerElementKind::LeftTrigger,
        MoonlightVirtualControllerElementKind::RightTrigger,
        MoonlightVirtualControllerElementKind::LeftShoulder,
        MoonlightVirtualControllerElementKind::RightShoulder,
        MoonlightVirtualControllerElementKind::LeftStickClick,
        MoonlightVirtualControllerElementKind::RightStickClick,
        MoonlightVirtualControllerElementKind::Menu,
        MoonlightVirtualControllerElementKind::Back,
        MoonlightVirtualControllerElementKind::Special,
    }};
    for (const auto kind : required) {
        if (!hasKind(layout, kind)) {
            return false;
        }
    }
    return true;
}

bool structurallyValid(const MoonlightVirtualControllerLayout& candidate) noexcept {
    if (candidate.version != kMoonlightVirtualControllerLayoutVersion ||
        candidate.elementCount == 0U ||
        candidate.elementCount > kMoonlightMaximumVirtualControllerElements) {
        return false;
    }
    for (std::size_t index = 0U; index < candidate.elementCount; ++index) {
        if (!validElementShape(candidate.elements[index])) {
            return false;
        }
        for (std::size_t prior = 0U; prior < index; ++prior) {
            if (candidate.elements[index].id == candidate.elements[prior].id ||
                candidate.elements[index].kind == candidate.elements[prior].kind) {
                return false;
            }
        }
    }
    return completeLayout(candidate);
}

constexpr std::array<MoonlightVirtualControllerElement, 16U>
kFallbackElements{{
    {1U, MoonlightVirtualControllerElementKind::LeftTrigger,
     {0.06, 0.05, 0.10, 0.08}},
    {2U, MoonlightVirtualControllerElementKind::LeftShoulder,
     {0.19, 0.05, 0.10, 0.08}},
    {3U, MoonlightVirtualControllerElementKind::Menu,
     {0.46, 0.05, 0.08, 0.08}},
    {4U, MoonlightVirtualControllerElementKind::RightShoulder,
     {0.71, 0.05, 0.10, 0.08}},
    {5U, MoonlightVirtualControllerElementKind::RightTrigger,
     {0.84, 0.05, 0.10, 0.08}},
    {6U, MoonlightVirtualControllerElementKind::DpadCluster,
     {0.05, 0.62, 0.18, 0.18}},
    {7U, MoonlightVirtualControllerElementKind::LeftStick,
     {0.27, 0.60, 0.16, 0.16}},
    {8U, MoonlightVirtualControllerElementKind::LeftStickClick,
     {0.31, 0.80, 0.08, 0.08}},
    {9U, MoonlightVirtualControllerElementKind::RightStick,
     {0.55, 0.60, 0.16, 0.16}},
    {10U, MoonlightVirtualControllerElementKind::RightStickClick,
     {0.59, 0.80, 0.08, 0.08}},
    {11U, MoonlightVirtualControllerElementKind::FaceX,
     {0.77, 0.64, 0.08, 0.08}},
    {12U, MoonlightVirtualControllerElementKind::FaceY,
     {0.85, 0.55, 0.08, 0.08}},
    {13U, MoonlightVirtualControllerElementKind::FaceA,
     {0.85, 0.73, 0.08, 0.08}},
    {14U, MoonlightVirtualControllerElementKind::FaceB,
     {0.91, 0.64, 0.08, 0.08}},
    {15U, MoonlightVirtualControllerElementKind::Back,
     {0.34, 0.05, 0.08, 0.08}},
    {16U, MoonlightVirtualControllerElementKind::Special,
     {0.58, 0.05, 0.08, 0.08}},
}};

bool placeFallbackElement(
    const MoonlightVirtualControllerElement& requested,
    const MoonlightControllerNormalizedRect& content,
    const MoonlightControllerLayoutEnvironment& environment,
    MoonlightVirtualControllerLayout& placed) noexcept {
    if (requested.bounds.width > content.width ||
        requested.bounds.height > content.height ||
        placed.elementCount >= placed.elements.size()) {
        return false;
    }
    const auto preferred = clampToContent(requested.bounds, content);
    MoonlightControllerNormalizedRect selected = preferred;
    bool selectedValid = !conflicts(preferred, environment, placed);
    double bestDistance = selectedValid ? 0.0 :
        std::numeric_limits<double>::infinity();
    const double maximumLeft = content.left + content.width - requested.bounds.width;
    const double maximumTop = content.top + content.height - requested.bounds.height;
    const std::size_t horizontalSteps = static_cast<std::size_t>(
        std::ceil((maximumLeft - content.left) / kFallbackGridStep));
    const std::size_t verticalSteps = static_cast<std::size_t>(
        std::ceil((maximumTop - content.top) / kFallbackGridStep));
    for (std::size_t row = 0U; row <= verticalSteps; ++row) {
        const double top = std::min(
            content.top + static_cast<double>(row) * kFallbackGridStep,
            maximumTop);
        for (std::size_t column = 0U; column <= horizontalSteps; ++column) {
            const double left = std::min(
                content.left + static_cast<double>(column) * kFallbackGridStep,
                maximumLeft);
            MoonlightControllerNormalizedRect candidate{
                left, top, requested.bounds.width, requested.bounds.height};
            if (conflicts(candidate, environment, placed)) {
                continue;
            }
            const double deltaX = left - preferred.left;
            const double deltaY = top - preferred.top;
            const double distance = deltaX * deltaX + deltaY * deltaY;
            if (!selectedValid || distance < bestDistance - kLayoutEpsilon) {
                selected = candidate;
                selectedValid = true;
                bestDistance = distance;
            }
        }
    }
    if (!selectedValid) {
        return false;
    }
    auto element = requested;
    element.bounds = selected;
    placed.elements[placed.elementCount++] = element;
    return true;
}

MoonlightVirtualControllerLayoutResult fallbackLayout(
    std::uint64_t generation,
    const MoonlightControllerLayoutEnvironment& environment,
    const MoonlightControllerNormalizedRect& content) noexcept {
    MoonlightVirtualControllerLayoutResult result;
    result.layout.version = kMoonlightVirtualControllerLayoutVersion;
    result.layout.generation = generation;
    for (const auto& element : kFallbackElements) {
        if (!placeFallbackElement(element, content, environment, result.layout)) {
            result.layout = {};
            result.layout.generation = generation;
            result.status = MoonlightVirtualControllerLayoutStatus::Unavailable;
            result.fallbackUsed = true;
            return result;
        }
    }
    result.status = MoonlightVirtualControllerLayoutStatus::Fallback;
    result.fallbackUsed = true;
    return result;
}

std::uint32_t buttonFlag(MoonlightVirtualControllerElementKind kind) noexcept {
    switch (kind) {
        case MoonlightVirtualControllerElementKind::FaceA:
            return kMoonlightControllerButtonA;
        case MoonlightVirtualControllerElementKind::FaceB:
            return kMoonlightControllerButtonB;
        case MoonlightVirtualControllerElementKind::FaceX:
            return kMoonlightControllerButtonX;
        case MoonlightVirtualControllerElementKind::FaceY:
            return kMoonlightControllerButtonY;
        case MoonlightVirtualControllerElementKind::DpadUp:
            return kMoonlightControllerButtonUp;
        case MoonlightVirtualControllerElementKind::DpadDown:
            return kMoonlightControllerButtonDown;
        case MoonlightVirtualControllerElementKind::DpadLeft:
            return kMoonlightControllerButtonLeft;
        case MoonlightVirtualControllerElementKind::DpadRight:
            return kMoonlightControllerButtonRight;
        case MoonlightVirtualControllerElementKind::LeftShoulder:
            return kMoonlightControllerButtonLeftShoulder;
        case MoonlightVirtualControllerElementKind::RightShoulder:
            return kMoonlightControllerButtonRightShoulder;
        case MoonlightVirtualControllerElementKind::LeftStickClick:
            return kMoonlightControllerButtonLeftStick;
        case MoonlightVirtualControllerElementKind::RightStickClick:
            return kMoonlightControllerButtonRightStick;
        case MoonlightVirtualControllerElementKind::Menu:
            return kMoonlightControllerButtonPlay;
        case MoonlightVirtualControllerElementKind::Back:
            return kMoonlightControllerButtonBack;
        case MoonlightVirtualControllerElementKind::Special:
            return kMoonlightControllerButtonSpecial;
        case MoonlightVirtualControllerElementKind::Invalid:
        case MoonlightVirtualControllerElementKind::DpadCluster:
        case MoonlightVirtualControllerElementKind::LeftStick:
        case MoonlightVirtualControllerElementKind::RightStick:
        case MoonlightVirtualControllerElementKind::LeftTrigger:
        case MoonlightVirtualControllerElementKind::RightTrigger:
            return 0U;
    }
    return 0U;
}

MoonlightControllerProfile virtualProfile(
    const MoonlightVirtualControllerLayout& layout) noexcept {
    MoonlightControllerProfile profile;
    profile.type = MoonlightControllerType::Unknown;
    for (std::size_t index = 0U; index < layout.elementCount; ++index) {
        const auto kind = layout.elements[index].kind;
        profile.supportedButtonFlags |= buttonFlag(kind);
        if (kind == MoonlightVirtualControllerElementKind::DpadCluster) {
            profile.supportedButtonFlags |= kMoonlightControllerDpadMask;
        }
        if (kind == MoonlightVirtualControllerElementKind::LeftTrigger ||
            kind == MoonlightVirtualControllerElementKind::RightTrigger) {
            profile.analogTriggers = true;
        }
    }
    return profile;
}

bool sameProfile(const MoonlightControllerProfile& left,
                 const MoonlightControllerProfile& right) noexcept {
    return left.type == right.type &&
        left.supportedButtonFlags == right.supportedButtonFlags &&
        left.analogTriggers == right.analogTriggers;
}

bool sameSample(const MoonlightControllerSample& left,
                const MoonlightControllerSample& right) noexcept {
    return left.buttonFlags == right.buttonFlags &&
        left.leftStickX == right.leftStickX &&
        left.leftStickY == right.leftStickY &&
        left.rightStickX == right.rightStickX &&
        left.rightStickY == right.rightStickY &&
        left.leftTrigger == right.leftTrigger &&
        left.rightTrigger == right.rightTrigger &&
        left.hasHatAxes == right.hasHatAxes &&
        left.hatX == right.hatX && left.hatY == right.hatY;
}

bool sameSourceContext(const MoonlightControllerSourceContext& left,
                       const MoonlightControllerSourceContext& right) noexcept {
    return left.identity == right.identity && left.kind == right.kind &&
        left.deviceId == right.deviceId &&
        left.sourceGeneration == right.sourceGeneration &&
        left.sourceSequence == right.sourceSequence &&
        left.monotonicTimestampUs == right.monotonicTimestampUs &&
        left.layoutGeneration == right.layoutGeneration;
}

template <typename Context>
bool sameMapperContext(const Context& left, const Context& right) noexcept {
    return left.identity == right.identity && left.deviceId == right.deviceId &&
        left.source == right.source &&
        left.sourceGeneration == right.sourceGeneration &&
        left.sourceSequence == right.sourceSequence &&
        left.monotonicTimestampUs == right.monotonicTimestampUs;
}

bool sameFlushContext(const MoonlightInputFlushContext& left,
                      const MoonlightInputFlushContext& right) noexcept {
    return left.identity == right.identity &&
        left.operationGeneration == right.operationGeneration &&
        left.monotonicTimestampUs == right.monotonicTimestampUs &&
        sameMapperContext(left.touch, right.touch) &&
        sameMapperContext(left.pointer, right.pointer) &&
        sameMapperContext(left.keyboard, right.keyboard) &&
        left.controllerContextPresent == right.controllerContextPresent &&
        (!left.controllerContextPresent ||
         sameMapperContext(left.controller, right.controller));
}

bool sameVirtualEvent(const MoonlightVirtualControllerEvent& left,
                      const MoonlightVirtualControllerEvent& right) noexcept {
    return sameSourceContext(left.context, right.context) &&
        left.elementId == right.elementId && left.pointerId == right.pointerId &&
        left.phase == right.phase && left.primary == right.primary &&
        left.secondary == right.secondary;
}

bool sameHandoff(const MoonlightControllerHandoffRequest& left,
                 const MoonlightControllerHandoffRequest& right) noexcept {
    return sameSourceContext(left.target, right.target) &&
        sameProfile(left.targetPhysicalProfile, right.targetPhysicalProfile) &&
        sameFlushContext(left.disconnectFlush, right.disconnectFlush) &&
        left.boundaryRetryOperationGeneration ==
            right.boundaryRetryOperationGeneration &&
        left.boundaryRetryTimestampUs == right.boundaryRetryTimestampUs &&
        left.resumeOperationGeneration == right.resumeOperationGeneration &&
        sameFlushContext(left.terminalFlush, right.terminalFlush);
}

MoonlightControllerEventContext mapperContext(
    const MoonlightControllerSourceContext& context) noexcept {
    return {context.identity, context.deviceId,
            moonlightControllerInputSource(context.kind),
            context.sourceGeneration, context.sourceSequence,
            context.monotonicTimestampUs};
}

bool success(MoonlightControllerStatus status) noexcept {
    return status == MoonlightControllerStatus::Applied ||
        status == MoonlightControllerStatus::AppliedLocally ||
        status == MoonlightControllerStatus::AlreadyApplied;
}

bool flushSuccess(MoonlightInputFlushStatus status) noexcept {
    return status == MoonlightInputFlushStatus::Applied ||
        status == MoonlightInputFlushStatus::AppliedLocally ||
        status == MoonlightInputFlushStatus::AlreadyApplied;
}

MoonlightControllerAggregatorStatus aggregateStatus(
    MoonlightControllerStatus status) noexcept {
    switch (status) {
        case MoonlightControllerStatus::Applied:
            return MoonlightControllerAggregatorStatus::Applied;
        case MoonlightControllerStatus::AppliedLocally:
            return MoonlightControllerAggregatorStatus::AppliedLocally;
        case MoonlightControllerStatus::AlreadyApplied:
            return MoonlightControllerAggregatorStatus::AlreadyApplied;
        case MoonlightControllerStatus::Backpressure:
            return MoonlightControllerAggregatorStatus::Pending;
        case MoonlightControllerStatus::Duplicate:
            return MoonlightControllerAggregatorStatus::Duplicate;
        case MoonlightControllerStatus::StaleOwner:
            return MoonlightControllerAggregatorStatus::StaleOwner;
        case MoonlightControllerStatus::StaleEvent:
            return MoonlightControllerAggregatorStatus::StaleSource;
        case MoonlightControllerStatus::PortUnsupported:
            return MoonlightControllerAggregatorStatus::PortUnsupported;
        case MoonlightControllerStatus::PortFailure:
            return MoonlightControllerAggregatorStatus::PortFailure;
        case MoonlightControllerStatus::FlushRequired:
        case MoonlightControllerStatus::NotActive:
        case MoonlightControllerStatus::SlotCapacity:
        case MoonlightControllerStatus::SourceCapacity:
            return MoonlightControllerAggregatorStatus::InvalidState;
        case MoonlightControllerStatus::InvalidRequest:
        case MoonlightControllerStatus::InvalidState:
            return MoonlightControllerAggregatorStatus::InvalidRequest;
    }
    return MoonlightControllerAggregatorStatus::PortFailure;
}

MoonlightControllerAggregatorResult controllerResult(
    const MoonlightControllerResult& result) noexcept {
    return {aggregateStatus(result.status), result.status,
            MoonlightInputFlushStatus::InvalidRequest,
            result.status == MoonlightControllerStatus::Backpressure};
}

MoonlightControllerAggregatorResult flushResult(
    const MoonlightInputFlushResult& result) noexcept {
    MoonlightControllerAggregatorStatus status =
        MoonlightControllerAggregatorStatus::InvalidState;
    switch (result.status) {
        case MoonlightInputFlushStatus::Applied:
            status = MoonlightControllerAggregatorStatus::Applied;
            break;
        case MoonlightInputFlushStatus::AppliedLocally:
            status = MoonlightControllerAggregatorStatus::AppliedLocally;
            break;
        case MoonlightInputFlushStatus::AlreadyApplied:
            status = MoonlightControllerAggregatorStatus::AlreadyApplied;
            break;
        case MoonlightInputFlushStatus::Pending:
            status = MoonlightControllerAggregatorStatus::Pending;
            break;
        case MoonlightInputFlushStatus::StaleOwner:
            status = MoonlightControllerAggregatorStatus::StaleOwner;
            break;
        case MoonlightInputFlushStatus::StaleOperation:
            status = MoonlightControllerAggregatorStatus::StaleSource;
            break;
        case MoonlightInputFlushStatus::InvalidRequest:
            status = MoonlightControllerAggregatorStatus::InvalidRequest;
            break;
        case MoonlightInputFlushStatus::InvalidState:
        case MoonlightInputFlushStatus::ComponentFailure:
        case MoonlightInputFlushStatus::BoundaryFailure:
            status = MoonlightControllerAggregatorStatus::InvalidState;
            break;
    }
    return {status, MoonlightControllerStatus::InvalidRequest,
            result.status, result.retryable ||
                result.status == MoonlightInputFlushStatus::Pending,
            result.remoteReleaseComplete, result.boundaryApplied};
}

bool validUnit(double value) noexcept {
    return finite(value) && value >= -1.0 && value <= 1.0;
}

bool validTrigger(double value) noexcept {
    return finite(value) && value >= 0.0 && value <= 1.0;
}

bool knownPhase(MoonlightVirtualControllerPhase phase) noexcept {
    switch (phase) {
        case MoonlightVirtualControllerPhase::Begin:
        case MoonlightVirtualControllerPhase::Change:
        case MoonlightVirtualControllerPhase::End:
        case MoonlightVirtualControllerPhase::Cancel:
            return true;
        case MoonlightVirtualControllerPhase::Invalid:
            return false;
    }
    return false;
}

bool zeroValues(const MoonlightVirtualControllerEvent& event) noexcept {
    return event.primary == 0.0 && event.secondary == 0.0;
}

struct ContactLane final {
    bool occupied = false;
    std::uint64_t pointerId = 0U;
    std::uint16_t elementId = 0U;
};

using ContactArray = std::array<ContactLane,
    kMoonlightMaximumVirtualControllerContacts>;

std::size_t contactCount(const ContactArray& contacts) noexcept {
    std::size_t count = 0U;
    for (const auto& contact : contacts) {
        count += contact.occupied ? 1U : 0U;
    }
    return count;
}

const MoonlightVirtualControllerElement* findElement(
    const MoonlightVirtualControllerLayout& layout,
    std::uint16_t id) noexcept {
    for (std::size_t index = 0U; index < layout.elementCount; ++index) {
        if (layout.elements[index].id == id) {
            return &layout.elements[index];
        }
    }
    return nullptr;
}

ContactLane* findPointer(ContactArray& contacts, std::uint64_t pointerId) noexcept {
    for (auto& contact : contacts) {
        if (contact.occupied && contact.pointerId == pointerId) {
            return &contact;
        }
    }
    return nullptr;
}

bool elementOccupied(const ContactArray& contacts, std::uint16_t elementId) noexcept {
    for (const auto& contact : contacts) {
        if (contact.occupied && contact.elementId == elementId) {
            return true;
        }
    }
    return false;
}

ContactLane* freeContact(ContactArray& contacts) noexcept {
    for (auto& contact : contacts) {
        if (!contact.occupied) {
            return &contact;
        }
    }
    return nullptr;
}

bool applyVirtualSemantic(const MoonlightVirtualControllerEvent& event,
                          const MoonlightVirtualControllerElement& element,
                          MoonlightControllerSample& sample,
                          ContactArray& contacts) noexcept {
    if (event.pointerId == 0U || !knownPhase(event.phase)) {
        return false;
    }
    ContactLane* contact = findPointer(contacts, event.pointerId);
    if (event.phase == MoonlightVirtualControllerPhase::Begin) {
        if (contact != nullptr || elementOccupied(contacts, element.id)) {
            return false;
        }
        contact = freeContact(contacts);
        if (contact == nullptr) {
            return false;
        }
        *contact = {true, event.pointerId, element.id};
    } else if (contact == nullptr || contact->elementId != element.id) {
        return false;
    }

    const bool ending = event.phase == MoonlightVirtualControllerPhase::End ||
        event.phase == MoonlightVirtualControllerPhase::Cancel;
    const std::uint32_t flag = buttonFlag(element.kind);
    if (flag != 0U) {
        if (event.phase == MoonlightVirtualControllerPhase::Change ||
            !zeroValues(event)) {
            return false;
        }
        if (ending) {
            sample.buttonFlags &= ~flag;
        } else {
            sample.buttonFlags |= flag;
        }
    } else {
        if (ending && !zeroValues(event)) {
            return false;
        }
        switch (element.kind) {
            case MoonlightVirtualControllerElementKind::DpadCluster:
                if (!ending && (!validUnit(event.primary) ||
                                !validUnit(event.secondary))) {
                    return false;
                }
                sample.buttonFlags &= ~kMoonlightControllerDpadMask;
                if (!ending) {
                    if (event.primary < -0.35) {
                        sample.buttonFlags |= kMoonlightControllerButtonLeft;
                    } else if (event.primary > 0.35) {
                        sample.buttonFlags |= kMoonlightControllerButtonRight;
                    }
                    if (event.secondary < -0.35) {
                        sample.buttonFlags |= kMoonlightControllerButtonUp;
                    } else if (event.secondary > 0.35) {
                        sample.buttonFlags |= kMoonlightControllerButtonDown;
                    }
                }
                break;
            case MoonlightVirtualControllerElementKind::LeftStick:
                if (!ending && (!validUnit(event.primary) ||
                                !validUnit(event.secondary))) {
                    return false;
                }
                sample.leftStickX = ending ? 0.0 : event.primary;
                sample.leftStickY = ending ? 0.0 : event.secondary;
                break;
            case MoonlightVirtualControllerElementKind::RightStick:
                if (!ending && (!validUnit(event.primary) ||
                                !validUnit(event.secondary))) {
                    return false;
                }
                sample.rightStickX = ending ? 0.0 : event.primary;
                sample.rightStickY = ending ? 0.0 : event.secondary;
                break;
            case MoonlightVirtualControllerElementKind::LeftTrigger:
                if ((!ending && (!validTrigger(event.primary) ||
                                 event.secondary != 0.0))) {
                    return false;
                }
                sample.leftTrigger = ending ? 0.0 : event.primary;
                break;
            case MoonlightVirtualControllerElementKind::RightTrigger:
                if ((!ending && (!validTrigger(event.primary) ||
                                 event.secondary != 0.0))) {
                    return false;
                }
                sample.rightTrigger = ending ? 0.0 : event.primary;
                break;
            case MoonlightVirtualControllerElementKind::Invalid:
            case MoonlightVirtualControllerElementKind::FaceA:
            case MoonlightVirtualControllerElementKind::FaceB:
            case MoonlightVirtualControllerElementKind::FaceX:
            case MoonlightVirtualControllerElementKind::FaceY:
            case MoonlightVirtualControllerElementKind::DpadUp:
            case MoonlightVirtualControllerElementKind::DpadDown:
            case MoonlightVirtualControllerElementKind::DpadLeft:
            case MoonlightVirtualControllerElementKind::DpadRight:
            case MoonlightVirtualControllerElementKind::LeftShoulder:
            case MoonlightVirtualControllerElementKind::RightShoulder:
            case MoonlightVirtualControllerElementKind::LeftStickClick:
            case MoonlightVirtualControllerElementKind::RightStickClick:
            case MoonlightVirtualControllerElementKind::Menu:
            case MoonlightVirtualControllerElementKind::Back:
            case MoonlightVirtualControllerElementKind::Special:
                return false;
        }
    }
    if (ending) {
        *contact = {};
    }
    return true;
}

bool contextMatchesActive(const MoonlightControllerSourceContext& context,
                          const MoonlightControllerSourceContext& active) noexcept {
    return context.identity == active.identity && context.kind == active.kind &&
        context.deviceId == active.deviceId &&
        context.sourceGeneration == active.sourceGeneration &&
        context.layoutGeneration == active.layoutGeneration;
}

bool controllerContextMatchesSource(
    const MoonlightControllerEventContext& context,
    const MoonlightControllerSourceContext& source) noexcept {
    return context.identity == source.identity &&
        context.deviceId == source.deviceId &&
        context.source == moonlightControllerInputSource(source.kind) &&
        context.sourceGeneration == source.sourceGeneration;
}

} // namespace

MoonlightVirtualControllerLayoutResult validateMoonlightVirtualControllerLayout(
    const MoonlightVirtualControllerLayout& candidate,
    const MoonlightControllerLayoutEnvironment& environment) noexcept {
    MoonlightVirtualControllerLayoutResult result;
    result.layout.generation = candidate.generation;
    if (candidate.generation == 0U) {
        result.status = MoonlightVirtualControllerLayoutStatus::StaleGeneration;
        return result;
    }
    MoonlightControllerNormalizedRect content;
    if (!validEnvironment(environment, content)) {
        result.status = MoonlightVirtualControllerLayoutStatus::InvalidEnvironment;
        return result;
    }
    if (!structurallyValid(candidate)) {
        return fallbackLayout(candidate.generation, environment, content);
    }

    result.layout.version = kMoonlightVirtualControllerLayoutVersion;
    result.layout.generation = candidate.generation;
    for (std::size_t index = 0U; index < candidate.elementCount; ++index) {
        auto element = candidate.elements[index];
        if (element.bounds.width > content.width ||
            element.bounds.height > content.height) {
            return fallbackLayout(candidate.generation, environment, content);
        }
        const auto clamped = clampToContent(element.bounds, content);
        if (!sameRect(element.bounds, clamped)) {
            result.clampedElements += 1U;
            element.bounds = clamped;
        }
        if (conflicts(element.bounds, environment, result.layout)) {
            return fallbackLayout(candidate.generation, environment, content);
        }
        result.layout.elements[result.layout.elementCount++] = element;
    }
    result.status = result.clampedElements == 0U
        ? MoonlightVirtualControllerLayoutStatus::Accepted
        : MoonlightVirtualControllerLayoutStatus::Clamped;
    return result;
}

MoonlightInputSource moonlightControllerInputSource(
    MoonlightControllerSourceKind kind) noexcept {
    switch (kind) {
        case MoonlightControllerSourceKind::Physical:
            return MoonlightInputSource::GameController;
        case MoonlightControllerSourceKind::Virtual:
            return MoonlightInputSource::VirtualController;
        case MoonlightControllerSourceKind::Invalid:
            return MoonlightInputSource::Invalid;
    }
    return MoonlightInputSource::Invalid;
}

struct MoonlightControllerAggregator::Impl final {
    struct ActiveSource final {
        bool valid = false;
        MoonlightControllerSourceContext context{};
        MoonlightControllerProfile profile{};
        MoonlightControllerSample sample{};
    };

    struct ConnectRequest final {
        MoonlightControllerSourceContext context{};
        MoonlightControllerProfile profile{};
    };

    struct PendingFrame final {
        bool virtualEvent = false;
        MoonlightControllerSourceContext context{};
        MoonlightControllerSample originalPhysicalSample{};
        MoonlightVirtualControllerEvent originalVirtualEvent{};
        MoonlightControllerSample candidateSample{};
        ContactArray candidateContacts{};
    };

    struct LifecycleRequest final {
        MoonlightInputFlushTrigger trigger = MoonlightInputFlushTrigger::Invalid;
        MoonlightInputFlushContext context{};
    };

    Impl(std::shared_ptr<MoonlightControllerMapper> inputMapper,
         std::shared_ptr<MoonlightInputFlushPolicy> inputFlushPolicy,
         MoonlightInputIdentity inputIdentity) noexcept
        : mapper(std::move(inputMapper)), flushPolicy(std::move(inputFlushPolicy)),
          identity(inputIdentity) {
        snapshotState.matched = true;
        snapshotState.identity = identity;
    }

    MoonlightControllerAggregatorResult reject(
        MoonlightControllerAggregatorStatus status) noexcept {
        snapshotState.rejectedEvents = saturatingIncrement(
            snapshotState.rejectedEvents);
        return {status, MoonlightControllerStatus::InvalidRequest,
                MoonlightInputFlushStatus::InvalidRequest, false};
    }

    void clearContactsAndSample() noexcept {
        contacts = {};
        if (active.valid) {
            active.sample = {};
        }
    }

    void clearActive() noexcept {
        active = {};
        contacts = {};
        pendingFrame.reset();
    }

    void commitFrame(const PendingFrame& frame,
                     MoonlightControllerStatus status) noexcept {
        active.context = frame.context;
        active.sample = frame.candidateSample;
        contacts = frame.candidateContacts;
        if (status == MoonlightControllerStatus::AppliedLocally ||
            status == MoonlightControllerStatus::AlreadyApplied) {
            snapshotState.localOnlyFrames = saturatingIncrement(
                snapshotState.localOnlyFrames);
        } else {
            snapshotState.acceptedFrames = saturatingIncrement(
                snapshotState.acceptedFrames);
        }
        pendingFrame.reset();
    }

    MoonlightControllerAggregatorResult dispatchPendingFrame() noexcept {
        if (!pendingFrame.has_value()) {
            return reject(MoonlightControllerAggregatorStatus::InvalidState);
        }
        const auto result = mapper->update(
            mapperContext(pendingFrame->context),
            pendingFrame->candidateSample);
        auto aggregated = controllerResult(result);
        if (success(result.status)) {
            commitFrame(*pendingFrame, result.status);
        }
        return aggregated;
    }

    MoonlightControllerAggregatorResult terminalize(
        const MoonlightControllerHandoffRequest& request) noexcept {
        snapshotState.state = MoonlightControllerAggregatorState::Terminating;
        const auto result = flushPolicy->flush(
            MoonlightInputFlushTrigger::SessionStop, request.terminalFlush);
        auto aggregated = flushResult(result);
        if (flushSuccess(result.status)) {
            clearActive();
            pendingConnect.reset();
            pendingLifecycle.reset();
            handoff.reset();
            snapshotState.state = MoonlightControllerAggregatorState::Stopped;
            snapshotState.terminalStops = saturatingIncrement(
                snapshotState.terminalStops);
            aggregated.status = MoonlightControllerAggregatorStatus::SessionTerminated;
            aggregated.retryable = false;
        } else {
            aggregated.retryable = true;
        }
        return aggregated;
    }

    mutable std::mutex mutex;
    std::shared_ptr<MoonlightControllerMapper> mapper;
    std::shared_ptr<MoonlightInputFlushPolicy> flushPolicy;
    MoonlightInputIdentity identity{};
    MoonlightVirtualControllerLayout layout{};
    ActiveSource active{};
    ContactArray contacts{};
    std::optional<ConnectRequest> pendingConnect;
    std::optional<PendingFrame> pendingFrame;
    std::optional<LifecycleRequest> pendingLifecycle;
    std::optional<MoonlightControllerHandoffRequest> handoff;
    MoonlightControllerAggregatorSnapshot snapshotState{};
};

MoonlightControllerAggregator::MoonlightControllerAggregator(
    std::unique_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}

MoonlightControllerAggregator::~MoonlightControllerAggregator() = default;

std::shared_ptr<MoonlightControllerAggregator>
MoonlightControllerAggregator::create(
    std::shared_ptr<MoonlightControllerMapper> mapper,
    std::shared_ptr<MoonlightInputFlushPolicy> flushPolicy,
    const MoonlightInputIdentity& identity) noexcept {
    if (!mapper || !flushPolicy || !identity.valid()) {
        return nullptr;
    }
    std::unique_ptr<Impl> impl(new (std::nothrow)
        Impl(std::move(mapper), std::move(flushPolicy), identity));
    if (!impl) {
        return nullptr;
    }
    return std::shared_ptr<MoonlightControllerAggregator>(
        new (std::nothrow) MoonlightControllerAggregator(std::move(impl)));
}

MoonlightControllerAggregatorResult MoonlightControllerAggregator::setEditing(
    const MoonlightInputIdentity& identity,
    bool editing,
    std::uint64_t controlGeneration) noexcept {
    if (impl_ == nullptr || !identity.valid() || controlGeneration == 0U) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (identity != impl_->identity) {
        return impl_->reject(MoonlightControllerAggregatorStatus::StaleOwner);
    }
    const auto requestedState = editing
        ? MoonlightControllerAggregatorState::Editing
        : MoonlightControllerAggregatorState::Idle;
    if (controlGeneration == impl_->snapshotState.lastControlGeneration &&
        impl_->snapshotState.state == requestedState) {
        return {MoonlightControllerAggregatorStatus::AlreadyApplied,
                MoonlightControllerStatus::AlreadyApplied,
                MoonlightInputFlushStatus::InvalidRequest, false};
    }
    if (controlGeneration <= impl_->snapshotState.lastControlGeneration) {
        return impl_->reject(MoonlightControllerAggregatorStatus::StaleSource);
    }
    if (impl_->active.valid || impl_->pendingConnect.has_value() ||
        impl_->pendingFrame.has_value() || impl_->handoff.has_value() ||
        (impl_->snapshotState.state != MoonlightControllerAggregatorState::Idle &&
         impl_->snapshotState.state != MoonlightControllerAggregatorState::Editing)) {
        return impl_->reject(MoonlightControllerAggregatorStatus::InvalidState);
    }
    impl_->clearContactsAndSample();
    impl_->snapshotState.state = requestedState;
    impl_->snapshotState.lastControlGeneration = controlGeneration;
    return {MoonlightControllerAggregatorStatus::Applied,
            MoonlightControllerStatus::Applied,
            MoonlightInputFlushStatus::InvalidRequest, false};
}

MoonlightVirtualControllerLayoutResult
MoonlightControllerAggregator::installLayout(
    const MoonlightInputIdentity& identity,
    const MoonlightVirtualControllerLayout& candidate,
    const MoonlightControllerLayoutEnvironment& environment) noexcept {
    MoonlightVirtualControllerLayoutResult result;
    if (impl_ == nullptr || !identity.valid()) {
        return result;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (identity != impl_->identity) {
        result.status = MoonlightVirtualControllerLayoutStatus::StaleOwner;
        return result;
    }
    if (impl_->snapshotState.state != MoonlightControllerAggregatorState::Editing ||
        impl_->active.valid || impl_->pendingFrame.has_value()) {
        result.status = MoonlightVirtualControllerLayoutStatus::InvalidState;
        return result;
    }
    if (candidate.generation == 0U ||
        candidate.generation <= impl_->layout.generation) {
        result.status = MoonlightVirtualControllerLayoutStatus::StaleGeneration;
        return result;
    }
    result = validateMoonlightVirtualControllerLayout(candidate, environment);
    if (result.status == MoonlightVirtualControllerLayoutStatus::Accepted ||
        result.status == MoonlightVirtualControllerLayoutStatus::Clamped ||
        result.status == MoonlightVirtualControllerLayoutStatus::Fallback) {
        impl_->layout = result.layout;
        impl_->snapshotState.layoutGeneration = result.layout.generation;
    }
    return result;
}

MoonlightControllerAggregatorResult MoonlightControllerAggregator::connectPhysical(
    const MoonlightControllerSourceContext& context,
    const MoonlightControllerProfile& profile) noexcept {
    if (impl_ == nullptr || !context.valid() ||
        context.kind != MoonlightControllerSourceKind::Physical) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (context.identity != impl_->identity) {
        return impl_->reject(MoonlightControllerAggregatorStatus::StaleOwner);
    }
    Impl::ConnectRequest request{context, profile};
    if (impl_->pendingConnect.has_value()) {
        if (!sameSourceContext(impl_->pendingConnect->context, context) ||
            !sameProfile(impl_->pendingConnect->profile, profile)) {
            return impl_->reject(MoonlightControllerAggregatorStatus::Pending);
        }
    } else {
        if (impl_->snapshotState.state != MoonlightControllerAggregatorState::Idle ||
            impl_->active.valid ||
            context.sourceGeneration <= impl_->snapshotState.sourceGeneration) {
            return impl_->reject(MoonlightControllerAggregatorStatus::InvalidState);
        }
        impl_->pendingConnect = request;
        impl_->snapshotState.state = MoonlightControllerAggregatorState::Connecting;
    }
    const auto result = impl_->mapper->connect(mapperContext(context), profile);
    auto aggregated = controllerResult(result);
    if (success(result.status)) {
        impl_->active = {true, context, profile, {}};
        impl_->pendingConnect.reset();
        impl_->snapshotState.state = MoonlightControllerAggregatorState::Active;
        impl_->snapshotState.sourceGeneration = context.sourceGeneration;
    } else if (result.status != MoonlightControllerStatus::Backpressure) {
        impl_->pendingConnect.reset();
        impl_->snapshotState.state = MoonlightControllerAggregatorState::Idle;
    }
    return aggregated;
}

MoonlightControllerAggregatorResult MoonlightControllerAggregator::connectVirtual(
    const MoonlightControllerSourceContext& context) noexcept {
    if (impl_ == nullptr || !context.valid() ||
        context.kind != MoonlightControllerSourceKind::Virtual) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (context.identity != impl_->identity) {
        return impl_->reject(MoonlightControllerAggregatorStatus::StaleOwner);
    }
    if (impl_->layout.generation == 0U ||
        context.layoutGeneration != impl_->layout.generation) {
        return impl_->reject(MoonlightControllerAggregatorStatus::StaleLayout);
    }
    const auto profile = virtualProfile(impl_->layout);
    Impl::ConnectRequest request{context, profile};
    if (impl_->pendingConnect.has_value()) {
        if (!sameSourceContext(impl_->pendingConnect->context, context) ||
            !sameProfile(impl_->pendingConnect->profile, profile)) {
            return impl_->reject(MoonlightControllerAggregatorStatus::Pending);
        }
    } else {
        if (impl_->snapshotState.state != MoonlightControllerAggregatorState::Idle ||
            impl_->active.valid ||
            context.sourceGeneration <= impl_->snapshotState.sourceGeneration) {
            return impl_->reject(MoonlightControllerAggregatorStatus::InvalidState);
        }
        impl_->pendingConnect = request;
        impl_->snapshotState.state = MoonlightControllerAggregatorState::Connecting;
    }
    const auto result = impl_->mapper->connect(mapperContext(context), profile);
    auto aggregated = controllerResult(result);
    if (success(result.status)) {
        impl_->active = {true, context, profile, {}};
        impl_->pendingConnect.reset();
        impl_->snapshotState.state = MoonlightControllerAggregatorState::Active;
        impl_->snapshotState.sourceGeneration = context.sourceGeneration;
    } else if (result.status != MoonlightControllerStatus::Backpressure) {
        impl_->pendingConnect.reset();
        impl_->snapshotState.state = MoonlightControllerAggregatorState::Idle;
    }
    return aggregated;
}

MoonlightControllerAggregatorResult MoonlightControllerAggregator::ingestPhysical(
    const MoonlightControllerSourceContext& context,
    const MoonlightControllerSample& sample) noexcept {
    if (impl_ == nullptr || !context.valid() ||
        context.kind != MoonlightControllerSourceKind::Physical) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (context.identity != impl_->identity) {
        return impl_->reject(MoonlightControllerAggregatorStatus::StaleOwner);
    }
    if (impl_->snapshotState.state == MoonlightControllerAggregatorState::Editing) {
        return impl_->reject(MoonlightControllerAggregatorStatus::Editing);
    }
    if (impl_->snapshotState.state != MoonlightControllerAggregatorState::Active ||
        !impl_->active.valid ||
        !contextMatchesActive(context, impl_->active.context)) {
        return impl_->reject(MoonlightControllerAggregatorStatus::StaleSource);
    }
    if (impl_->pendingFrame.has_value()) {
        if (impl_->pendingFrame->virtualEvent ||
            !sameSourceContext(impl_->pendingFrame->context, context) ||
            !sameSample(impl_->pendingFrame->originalPhysicalSample, sample)) {
            return impl_->reject(MoonlightControllerAggregatorStatus::Pending);
        }
        return impl_->dispatchPendingFrame();
    }
    Impl::PendingFrame frame;
    frame.context = context;
    frame.originalPhysicalSample = sample;
    frame.candidateSample = sample;
    frame.candidateContacts = impl_->contacts;
    const auto result = impl_->mapper->update(mapperContext(context), sample);
    auto aggregated = controllerResult(result);
    if (success(result.status)) {
        impl_->pendingFrame = frame;
        impl_->commitFrame(frame, result.status);
    } else if (result.status == MoonlightControllerStatus::Backpressure) {
        impl_->pendingFrame = frame;
    }
    return aggregated;
}

MoonlightControllerAggregatorResult MoonlightControllerAggregator::ingestVirtual(
    const MoonlightVirtualControllerEvent& event) noexcept {
    if (impl_ == nullptr || !event.context.valid() || event.elementId == 0U ||
        event.pointerId == 0U ||
        event.context.kind != MoonlightControllerSourceKind::Virtual) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (event.context.identity != impl_->identity) {
        return impl_->reject(MoonlightControllerAggregatorStatus::StaleOwner);
    }
    if (impl_->snapshotState.state == MoonlightControllerAggregatorState::Editing) {
        return impl_->reject(MoonlightControllerAggregatorStatus::Editing);
    }
    if (event.context.layoutGeneration != impl_->layout.generation) {
        return impl_->reject(MoonlightControllerAggregatorStatus::StaleLayout);
    }
    if (impl_->snapshotState.state != MoonlightControllerAggregatorState::Active ||
        !impl_->active.valid ||
        !contextMatchesActive(event.context, impl_->active.context)) {
        return impl_->reject(MoonlightControllerAggregatorStatus::StaleSource);
    }
    if (impl_->pendingFrame.has_value()) {
        if (!impl_->pendingFrame->virtualEvent ||
            !sameVirtualEvent(impl_->pendingFrame->originalVirtualEvent, event)) {
            return impl_->reject(MoonlightControllerAggregatorStatus::Pending);
        }
        return impl_->dispatchPendingFrame();
    }
    const auto* element = findElement(impl_->layout, event.elementId);
    if (element == nullptr) {
        return impl_->reject(MoonlightControllerAggregatorStatus::InvalidRequest);
    }
    Impl::PendingFrame frame;
    frame.virtualEvent = true;
    frame.context = event.context;
    frame.originalVirtualEvent = event;
    frame.candidateSample = impl_->active.sample;
    frame.candidateContacts = impl_->contacts;
    if (!applyVirtualSemantic(event, *element, frame.candidateSample,
                              frame.candidateContacts)) {
        return impl_->reject(MoonlightControllerAggregatorStatus::InvalidRequest);
    }
    const auto result = impl_->mapper->update(
        mapperContext(event.context), frame.candidateSample);
    auto aggregated = controllerResult(result);
    if (success(result.status)) {
        impl_->pendingFrame = frame;
        impl_->commitFrame(frame, result.status);
    } else if (result.status == MoonlightControllerStatus::Backpressure) {
        impl_->pendingFrame = frame;
    }
    return aggregated;
}

MoonlightControllerAggregatorResult MoonlightControllerAggregator::handleLifecycle(
    MoonlightInputFlushTrigger trigger,
    const MoonlightInputFlushContext& context) noexcept {
    if (impl_ == nullptr || trigger == MoonlightInputFlushTrigger::Invalid ||
        !context.identity.valid()) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (context.identity != impl_->identity) {
        return impl_->reject(MoonlightControllerAggregatorStatus::StaleOwner);
    }
    if (impl_->handoff.has_value()) {
        return impl_->reject(MoonlightControllerAggregatorStatus::InvalidState);
    }
    if (impl_->snapshotState.state == MoonlightControllerAggregatorState::Stopped) {
        if (moonlightInputFlushDisposition(trigger) ==
            MoonlightInputFlushDisposition::Stop) {
            // Keep terminal teardown idempotent. Product stop still treats
            // this as an ambiguous replay rather than fresh remote proof.
            return {MoonlightControllerAggregatorStatus::AlreadyApplied,
                    MoonlightControllerStatus::AlreadyApplied,
                    MoonlightInputFlushStatus::AlreadyApplied, false, false,
                    false};
        }
        return impl_->reject(MoonlightControllerAggregatorStatus::InvalidState);
    }
    if (impl_->active.valid &&
        (!context.controllerContextPresent ||
         !controllerContextMatchesSource(context.controller,
                                         impl_->active.context))) {
        return impl_->reject(MoonlightControllerAggregatorStatus::StaleSource);
    }
    if (impl_->pendingLifecycle.has_value()) {
        const bool exact = impl_->pendingLifecycle->trigger == trigger &&
            sameFlushContext(impl_->pendingLifecycle->context, context);
        const bool terminalEscalation =
            moonlightInputFlushDisposition(trigger) ==
                MoonlightInputFlushDisposition::Stop &&
            context.operationGeneration >
                impl_->pendingLifecycle->context.operationGeneration;
        if (!exact && !terminalEscalation) {
            return impl_->reject(MoonlightControllerAggregatorStatus::Pending);
        }
    }
    const auto result = impl_->flushPolicy->flush(trigger, context);
    auto aggregated = flushResult(result);
    if (result.status == MoonlightInputFlushStatus::Pending ||
        result.status == MoonlightInputFlushStatus::ComponentFailure ||
        result.status == MoonlightInputFlushStatus::BoundaryFailure) {
        impl_->pendingFrame.reset();
        impl_->pendingLifecycle = Impl::LifecycleRequest{trigger, context};
        impl_->snapshotState.state =
            moonlightInputFlushDisposition(trigger) ==
                    MoonlightInputFlushDisposition::Stop
                ? MoonlightControllerAggregatorState::Terminating
                : MoonlightControllerAggregatorState::LifecyclePending;
        return aggregated;
    }
    if (!flushSuccess(result.status)) {
        return aggregated;
    }
    impl_->pendingFrame.reset();
    impl_->pendingLifecycle.reset();
    impl_->clearContactsAndSample();
    impl_->snapshotState.lastControlGeneration = context.operationGeneration;
    impl_->snapshotState.lifecycleFlushes = saturatingIncrement(
        impl_->snapshotState.lifecycleFlushes);
    const auto disposition = moonlightInputFlushDisposition(trigger);
    if (disposition == MoonlightInputFlushDisposition::Stop) {
        impl_->clearActive();
        impl_->snapshotState.state = MoonlightControllerAggregatorState::Stopped;
        impl_->snapshotState.terminalStops = saturatingIncrement(
            impl_->snapshotState.terminalStops);
    } else {
        if (trigger == MoonlightInputFlushTrigger::ControllerDisconnected) {
            impl_->clearActive();
        }
        impl_->snapshotState.state = MoonlightControllerAggregatorState::Suspended;
    }
    return aggregated;
}

MoonlightControllerAggregatorResult
MoonlightControllerAggregator::retryLifecycleBoundary(
    const MoonlightInputIdentity& identity,
    std::uint64_t operationGeneration,
    std::uint64_t monotonicTimestampUs) noexcept {
    if (impl_ == nullptr || !identity.valid() || operationGeneration == 0U ||
        monotonicTimestampUs == 0U) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (identity != impl_->identity) {
        return impl_->reject(MoonlightControllerAggregatorStatus::StaleOwner);
    }
    if (impl_->snapshotState.state !=
            MoonlightControllerAggregatorState::LifecyclePending ||
        !impl_->pendingLifecycle.has_value() ||
        moonlightInputFlushDisposition(impl_->pendingLifecycle->trigger) !=
            MoonlightInputFlushDisposition::Suspend ||
        operationGeneration <=
            impl_->pendingLifecycle->context.operationGeneration ||
        monotonicTimestampUs <
            impl_->pendingLifecycle->context.monotonicTimestampUs) {
        return impl_->reject(MoonlightControllerAggregatorStatus::InvalidState);
    }
    const auto pending = *impl_->pendingLifecycle;
    const auto result = impl_->flushPolicy->retryBoundary(
        identity, operationGeneration, monotonicTimestampUs);
    auto aggregated = flushResult(result);
    if (!flushSuccess(result.status)) {
        return aggregated;
    }
    impl_->pendingFrame.reset();
    impl_->pendingLifecycle.reset();
    impl_->clearContactsAndSample();
    impl_->snapshotState.lastControlGeneration = operationGeneration;
    impl_->snapshotState.lifecycleFlushes = saturatingIncrement(
        impl_->snapshotState.lifecycleFlushes);
    if (pending.trigger ==
        MoonlightInputFlushTrigger::ControllerDisconnected) {
        impl_->clearActive();
    }
    impl_->snapshotState.state = MoonlightControllerAggregatorState::Suspended;
    return aggregated;
}

MoonlightControllerAggregatorResult
MoonlightControllerAggregator::resumeLifecycle(
    const MoonlightInputIdentity& identity,
    std::uint64_t operationGeneration) noexcept {
    if (impl_ == nullptr || !identity.valid() || operationGeneration == 0U) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (identity != impl_->identity) {
        return impl_->reject(MoonlightControllerAggregatorStatus::StaleOwner);
    }
    if (impl_->snapshotState.state != MoonlightControllerAggregatorState::Suspended ||
        operationGeneration <= impl_->snapshotState.lastControlGeneration) {
        return impl_->reject(MoonlightControllerAggregatorStatus::InvalidState);
    }
    const auto result = impl_->flushPolicy->resume(identity, operationGeneration);
    auto aggregated = flushResult(result);
    if (flushSuccess(result.status)) {
        impl_->snapshotState.lastControlGeneration = operationGeneration;
        impl_->snapshotState.state = impl_->active.valid
            ? MoonlightControllerAggregatorState::Active
            : MoonlightControllerAggregatorState::Idle;
    }
    return aggregated;
}

MoonlightControllerAggregatorResult MoonlightControllerAggregator::switchSource(
    const MoonlightControllerHandoffRequest& request) noexcept {
    if (impl_ == nullptr || !request.target.valid() ||
        request.disconnectFlush.operationGeneration == 0U ||
        request.boundaryRetryOperationGeneration == 0U ||
        request.boundaryRetryTimestampUs == 0U ||
        request.resumeOperationGeneration == 0U ||
        request.terminalFlush.operationGeneration == 0U) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (request.target.identity != impl_->identity ||
        request.disconnectFlush.identity != impl_->identity ||
        request.terminalFlush.identity != impl_->identity) {
        return impl_->reject(MoonlightControllerAggregatorStatus::StaleOwner);
    }
    if (impl_->snapshotState.state == MoonlightControllerAggregatorState::Terminating &&
        impl_->handoff.has_value()) {
        if (!sameHandoff(*impl_->handoff, request)) {
            return impl_->reject(MoonlightControllerAggregatorStatus::Pending);
        }
        return impl_->terminalize(request);
    }
    if (impl_->handoff.has_value()) {
        if (!sameHandoff(*impl_->handoff, request)) {
            return impl_->reject(MoonlightControllerAggregatorStatus::Pending);
        }
    } else {
        if (impl_->snapshotState.state != MoonlightControllerAggregatorState::Active ||
            !impl_->active.valid || request.target.kind == impl_->active.context.kind ||
            request.target.sourceGeneration <= impl_->active.context.sourceGeneration ||
            request.target.sourceGeneration <= impl_->snapshotState.sourceGeneration ||
            !request.disconnectFlush.controllerContextPresent ||
            !request.terminalFlush.controllerContextPresent ||
            !controllerContextMatchesSource(request.disconnectFlush.controller,
                                            impl_->active.context) ||
            !controllerContextMatchesSource(request.terminalFlush.controller,
                                            impl_->active.context) ||
            request.boundaryRetryOperationGeneration <=
                request.disconnectFlush.operationGeneration ||
            request.resumeOperationGeneration <=
                request.boundaryRetryOperationGeneration ||
            request.terminalFlush.operationGeneration <=
                request.resumeOperationGeneration ||
            request.boundaryRetryTimestampUs <
                request.disconnectFlush.monotonicTimestampUs ||
            request.terminalFlush.monotonicTimestampUs <
                request.boundaryRetryTimestampUs ||
            request.target.monotonicTimestampUs <
                request.disconnectFlush.monotonicTimestampUs ||
            (request.target.kind == MoonlightControllerSourceKind::Virtual &&
             request.target.layoutGeneration != impl_->layout.generation)) {
            return impl_->reject(MoonlightControllerAggregatorStatus::InvalidRequest);
        }
        impl_->handoff = request;
        impl_->pendingFrame.reset();
        impl_->snapshotState.state =
            MoonlightControllerAggregatorState::HandoffRemoving;
    }

    bool removalComplete = false;
    if (impl_->snapshotState.state ==
        MoonlightControllerAggregatorState::HandoffRemoving) {
        const auto removal = impl_->flushPolicy->flush(
            MoonlightInputFlushTrigger::ControllerDisconnected,
            request.disconnectFlush);
        if (!flushSuccess(removal.status)) {
            if (removal.status == MoonlightInputFlushStatus::BoundaryFailure &&
                removal.retryable) {
                impl_->snapshotState.state =
                    MoonlightControllerAggregatorState::HandoffBoundaryPending;
                return flushResult(removal);
            }
            if (removal.status == MoonlightInputFlushStatus::Pending ||
                removal.retryable) {
                return flushResult(removal);
            }
            return impl_->terminalize(request);
        }
        removalComplete = true;
    }

    if (impl_->snapshotState.state ==
        MoonlightControllerAggregatorState::HandoffBoundaryPending) {
        const auto boundary = impl_->flushPolicy->retryBoundary(
            impl_->identity, request.boundaryRetryOperationGeneration,
            request.boundaryRetryTimestampUs);
        if (!flushSuccess(boundary.status)) {
            if (boundary.retryable) {
                return flushResult(boundary);
            }
            return impl_->terminalize(request);
        }
        removalComplete = true;
    }

    if (removalComplete) {
        const auto mapperSnapshot = impl_->mapper->snapshot(impl_->identity);
        if (!mapperSnapshot.matched || mapperSnapshot.active ||
            mapperSnapshot.deviceId != 0U ||
            mapperSnapshot.source != MoonlightInputSource::Invalid ||
            mapperSnapshot.sourceGeneration != 0U) {
            return impl_->terminalize(request);
        }
        impl_->clearActive();
        impl_->snapshotState.state =
            MoonlightControllerAggregatorState::HandoffResuming;
    }

    if (impl_->snapshotState.state ==
        MoonlightControllerAggregatorState::HandoffResuming) {
        const auto resumed = impl_->flushPolicy->resume(
            impl_->identity, request.resumeOperationGeneration);
        if (!flushSuccess(resumed.status)) {
            if (resumed.retryable) {
                return flushResult(resumed);
            }
            return impl_->terminalize(request);
        }
        impl_->snapshotState.lastControlGeneration =
            request.resumeOperationGeneration;
        impl_->snapshotState.state =
            MoonlightControllerAggregatorState::HandoffConnecting;
    }

    if (impl_->snapshotState.state ==
        MoonlightControllerAggregatorState::HandoffConnecting) {
        const auto profile = request.target.kind ==
                MoonlightControllerSourceKind::Virtual
            ? virtualProfile(impl_->layout)
            : request.targetPhysicalProfile;
        const auto connected = impl_->mapper->connect(
            mapperContext(request.target), profile);
        auto aggregated = controllerResult(connected);
        if (connected.status == MoonlightControllerStatus::Backpressure) {
            return aggregated;
        }
        if (!success(connected.status)) {
            return impl_->terminalize(request);
        }
        impl_->active = {true, request.target, profile, {}};
        impl_->snapshotState.state = MoonlightControllerAggregatorState::Active;
        impl_->snapshotState.sourceGeneration = request.target.sourceGeneration;
        impl_->snapshotState.handoffs = saturatingIncrement(
            impl_->snapshotState.handoffs);
        impl_->handoff.reset();
        return aggregated;
    }
    return impl_->reject(MoonlightControllerAggregatorStatus::InvalidState);
}

MoonlightControllerAggregatorSnapshot MoonlightControllerAggregator::snapshot(
    const MoonlightInputIdentity& identity) const noexcept {
    MoonlightControllerAggregatorSnapshot snapshot;
    if (impl_ == nullptr) {
        return snapshot;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    snapshot = impl_->snapshotState;
    if (identity != impl_->identity) {
        snapshot.matched = false;
        return snapshot;
    }
    snapshot.activeSource = impl_->active.valid
        ? impl_->active.context.kind : MoonlightControllerSourceKind::Invalid;
    snapshot.deviceId = impl_->active.valid ? impl_->active.context.deviceId : 0U;
    snapshot.sourceGeneration = impl_->active.valid
        ? impl_->active.context.sourceGeneration
        : impl_->snapshotState.sourceGeneration;
    snapshot.layoutGeneration = impl_->layout.generation;
    snapshot.sample = impl_->active.valid ? impl_->active.sample
                                          : MoonlightControllerSample{};
    snapshot.activeContacts = contactCount(impl_->contacts);
    snapshot.pendingFrame = impl_->pendingFrame.has_value();
    return snapshot;
}

} // namespace remotedesk::moonlight
