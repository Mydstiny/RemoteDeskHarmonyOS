#include "moonlight/input/MoonlightCommonCInputPort.h"
#include "moonlight/input/MoonlightCommonCInputResult.h"

#include "moonlight/input/MoonlightControllerMapper.h"
#include "moonlight/input/MoonlightKeyboardMapper.h"
#include "moonlight/input/MoonlightPointerMapper.h"
#include "moonlight/input/MoonlightTouchMapper.h"

#include <limits>
#include <new>

namespace remotedesk::moonlight {
namespace {

class CommonCInputPort final : public MoonlightInputPort {
  public:
    MoonlightInputPortStatus send(const MoonlightInputEvent& event) noexcept override {
        switch (event.kind) {
            case MoonlightInputCommandKind::Keyboard: return sendKeyboard(event);
            case MoonlightInputCommandKind::Text: return sendText(event);
            case MoonlightInputCommandKind::RelativePointer:
                return sendRelativePointer(event);
            case MoonlightInputCommandKind::AbsolutePointer:
                return sendAbsolutePointer(event);
            case MoonlightInputCommandKind::PointerButton:
                return sendPointerButton(event);
            case MoonlightInputCommandKind::VerticalScroll:
            case MoonlightInputCommandKind::HorizontalScroll:
                return sendScroll(event);
            case MoonlightInputCommandKind::Touch: return sendTouch(event);
            case MoonlightInputCommandKind::Controller: return sendController(event);
            case MoonlightInputCommandKind::Invalid:
                return MoonlightInputPortStatus::Failed;
        }
        return MoonlightInputPortStatus::Failed;
    }

    bool flushNeutral(const MoonlightInputFlushRequest& request) noexcept override {
        if (!request.identity.valid() || request.operationGeneration == 0U ||
            request.monotonicTimestampUs == 0U) {
            return false;
        }
        const int result = LiSendTouchEvent(
            LI_TOUCH_EVENT_CANCEL_ALL, 0U, 0.0F, 0.0F, 0.0F, 0.0F, 0.0F,
            LI_ROT_UNKNOWN);
        // A host without direct-touch support has no touch state to clear.
        // The stateful mappers already emitted keyboard/pointer/controller
        // releases before this final boundary.
        return result == 0 || result == LI_ERR_UNSUPPORTED;
    }

    MoonlightInputPortStatus resetRemoteState(
        const MoonlightInputRecoveryResetRequest& request) noexcept override {
        if (!request.valid()) { return MoonlightInputPortStatus::Failed; }
        if (!recoveryResetBound_) {
            recoveryResetBound_ = true;
            recoveryResetIdentity_ = request.identity;
            recoveryResetOperationGeneration_ = request.operationGeneration;
            recoveryResetActiveGamepadMask_ = request.activeGamepadMask;
            recoveryResetControllerSlots_ = request.controllerSlots;
        } else if (recoveryResetIdentity_ != request.identity ||
                   recoveryResetOperationGeneration_ != request.operationGeneration ||
                   recoveryResetActiveGamepadMask_ != request.activeGamepadMask ||
                   recoveryResetControllerSlots_ != request.controllerSlots) {
            return MoonlightInputPortStatus::Failed;
        }

        constexpr std::size_t kTouchStep = 0U;
        constexpr std::size_t kKeyboardFirstStep = 1U;
        constexpr std::size_t kKeyboardSteps = 255U;
        constexpr std::size_t kPointerFirstStep =
            kKeyboardFirstStep + kKeyboardSteps;
        constexpr std::size_t kPointerSteps = 5U;
        constexpr std::size_t kControllerFirstStep =
            kPointerFirstStep + kPointerSteps;
        const std::size_t terminalStep = kControllerFirstStep +
            static_cast<std::size_t>(recoveryResetControllerSlots_);

        while (recoveryResetStep_ < terminalStep) {
            int result = 0;
            if (recoveryResetStep_ == kTouchStep) {
                result = LiSendTouchEvent(
                    LI_TOUCH_EVENT_CANCEL_ALL, 0U, 0.0F, 0.0F, 0.0F,
                    0.0F, 0.0F, LI_ROT_UNKNOWN);
                if (result == LI_ERR_UNSUPPORTED) {
                    ++recoveryResetStep_;
                    continue;
                }
            } else if (recoveryResetStep_ < kPointerFirstStep) {
                const auto virtualKey = static_cast<std::uint16_t>(
                    recoveryResetStep_ - kKeyboardFirstStep + 1U);
                result = LiSendKeyboardEvent2(
                    static_cast<short>(kMoonlightKeyboardKeyPrefix | virtualKey),
                    static_cast<char>(kMoonlightKeyboardActionUp), 0, 0);
            } else if (recoveryResetStep_ < kControllerFirstStep) {
                const auto button = static_cast<int>(
                    recoveryResetStep_ - kPointerFirstStep + 1U);
                result = LiSendMouseButtonEvent(
                    static_cast<char>(kMoonlightPointerActionRelease), button);
            } else {
                const auto controller = static_cast<std::uint8_t>(
                    recoveryResetStep_ - kControllerFirstStep);
                const auto bit = static_cast<std::uint16_t>(1U << controller);
                if ((recoveryResetActiveGamepadMask_ & bit) == 0U) {
                    ++recoveryResetStep_;
                    continue;
                }
                result = LiSendMultiControllerEvent(
                    static_cast<short>(controller),
                    static_cast<short>(recoveryResetActiveGamepadMask_),
                    0, 0U, 0U, 0, 0, 0, 0);
            }
            const auto status = moonlightCommonCInputResult(result);
            if (status != MoonlightInputPortStatus::Accepted) { return status; }
            ++recoveryResetStep_;
        }
        return MoonlightInputPortStatus::Accepted;
    }

  private:
    static MoonlightInputPortStatus sendKeyboard(
        const MoonlightInputEvent& event) noexcept {
        MoonlightKeyboardWireCommand command;
        if (!decodeMoonlightKeyboardCommand(event, command)) {
            return MoonlightInputPortStatus::Failed;
        }
        return moonlightCommonCInputResult(LiSendKeyboardEvent2(
            static_cast<short>(command.protocolKeyCode),
            static_cast<char>(command.action),
            static_cast<char>(command.modifiers),
            static_cast<char>(command.flags)));
    }

    static MoonlightInputPortStatus sendText(
        const MoonlightInputEvent& event) noexcept {
        if (event.commandVersion != 1U || event.payloadSize == 0U ||
            event.payloadSize > static_cast<std::size_t>(
                std::numeric_limits<unsigned int>::max()) ||
            !validateMoonlightUtf8Text(event.payload.data(), event.payloadSize)) {
            return MoonlightInputPortStatus::Failed;
        }
        return moonlightCommonCInputResult(LiSendUtf8TextEvent(
            reinterpret_cast<const char*>(event.payload.data()),
            static_cast<unsigned int>(event.payloadSize)));
    }

    static MoonlightInputPortStatus sendRelativePointer(
        const MoonlightInputEvent& event) noexcept {
        MoonlightRelativePointerWireCommand command;
        if (!decodeMoonlightRelativePointerCommand(event, command)) {
            return MoonlightInputPortStatus::Failed;
        }
        return moonlightCommonCInputResult(
            LiSendMouseMoveEvent(command.deltaX, command.deltaY));
    }

    static MoonlightInputPortStatus sendAbsolutePointer(
        const MoonlightInputEvent& event) noexcept {
        MoonlightAbsolutePointerWireCommand command;
        if (!decodeMoonlightAbsolutePointerCommand(event, command)) {
            return MoonlightInputPortStatus::Failed;
        }
        return moonlightCommonCInputResult(LiSendMousePositionEvent(
            command.x, command.y, static_cast<short>(command.referenceWidth),
            static_cast<short>(command.referenceHeight)));
    }

    static MoonlightInputPortStatus sendPointerButton(
        const MoonlightInputEvent& event) noexcept {
        MoonlightPointerButtonWireCommand command;
        if (!decodeMoonlightPointerButtonCommand(event, command)) {
            return MoonlightInputPortStatus::Failed;
        }
        return moonlightCommonCInputResult(LiSendMouseButtonEvent(
            static_cast<char>(command.action), static_cast<int>(command.button)));
    }

    static MoonlightInputPortStatus sendScroll(
        const MoonlightInputEvent& event) noexcept {
        MoonlightPointerScrollWireCommand command;
        if (!decodeMoonlightPointerScrollCommand(event, command)) {
            return MoonlightInputPortStatus::Failed;
        }
        return moonlightCommonCInputResult(command.horizontal
            ? LiSendHighResHScrollEvent(command.amount)
            : LiSendHighResScrollEvent(command.amount));
    }

    static MoonlightInputPortStatus sendTouch(
        const MoonlightInputEvent& event) noexcept {
        MoonlightTouchWireCommand command;
        if (!decodeMoonlightTouchCommand(event, command)) {
            return MoonlightInputPortStatus::Failed;
        }
        return moonlightCommonCInputResult(LiSendTouchEvent(
            command.eventType, command.pointerId, command.x, command.y,
            command.pressureOrDistance, command.contactAreaMajor,
            command.contactAreaMinor, command.rotation));
    }

    static MoonlightInputPortStatus sendController(
        const MoonlightInputEvent& event) noexcept {
        MoonlightControllerWireCommand command;
        if (!decodeMoonlightControllerCommand(event, command)) {
            return MoonlightInputPortStatus::Failed;
        }
        if (command.operation == MoonlightControllerCommandOperation::Arrival) {
            return moonlightCommonCInputResult(LiSendControllerArrivalEvent(
                command.controllerNumber, command.activeGamepadMask,
                static_cast<std::uint8_t>(command.type),
                command.supportedButtonFlags, command.capabilities));
        }
        return moonlightCommonCInputResult(LiSendMultiControllerEvent(
            static_cast<short>(command.controllerNumber),
            static_cast<short>(command.activeGamepadMask),
            static_cast<int>(command.state.buttonFlags),
            command.state.leftTrigger, command.state.rightTrigger,
            command.state.leftStickX, command.state.leftStickY,
            command.state.rightStickX, command.state.rightStickY));
    }

    bool recoveryResetBound_ = false;
    MoonlightInputIdentity recoveryResetIdentity_{};
    std::uint64_t recoveryResetOperationGeneration_ = 0U;
    std::uint16_t recoveryResetActiveGamepadMask_ = 0U;
    std::uint8_t recoveryResetControllerSlots_ = 0U;
    std::size_t recoveryResetStep_ = 0U;
};

} // namespace

std::shared_ptr<MoonlightInputPort> createMoonlightCommonCInputPort() noexcept {
    try {
        return std::shared_ptr<MoonlightInputPort>(new (std::nothrow) CommonCInputPort());
    } catch (...) {
        return nullptr;
    }
}

bool moonlightCommonCDirectTouchAvailable() noexcept {
    return (LiGetHostFeatureFlags() & LI_FF_PEN_TOUCH_EVENTS) != 0U;
}

} // namespace remotedesk::moonlight
