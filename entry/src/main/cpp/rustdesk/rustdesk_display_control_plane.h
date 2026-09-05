#ifndef RUSTDESK_DISPLAY_CONTROL_PLANE_H
#define RUSTDESK_DISPLAY_CONTROL_PLANE_H

#include "rustdesk_display_switch_gate.h"
#include "rustdesk_ffi_handle_gate.h"

#include <cstdint>
#include <mutex>
#include <utility>

struct RustDeskDisplayControlRequest {
    bool accepted = false;
    uint64_t generation = 0;
};

/**
 * Production RustDesk display-switch transaction boundary.
 *
 * The class combines the generation/dispatch coordinator with the opaque FFI
 * handle lifetime gate. Host tests call these same methods with fake FFI
 * functions, so shortening a production lease reopens a deterministic test.
 */
class RustDeskDisplayControlPlane {
public:
    /**
     * Serialize a non-reentrant outbound FFI send with continuity admission.
     *
     * Network retirement takes the same admission mutex before detaching the
     * handle. The fixed admission -> shared handle lease order therefore
     * prevents an old input/file/clipboard operation from entering after the
     * stream token has been retired.
     */
    template<typename IsAllowed, typename Operation>
    bool dispatchOutbound(
        std::mutex& admissionMutex, IsAllowed&& isAllowed,
        Operation&& operation) {
        std::lock_guard<std::mutex> admissionLock(admissionMutex);
        if (!isAllowed()) {
            return false;
        }
        auto handleLease = handleGate_.acquire();
        if (!handleLease || !isAllowed()) {
            return false;
        }
        return std::forward<Operation>(operation)(handleLease.get());
    }

    template<typename IsValid, typename Dispatch>
    bool dispatchFrame(int display, bool keyFrame, IsValid&& isValid, Dispatch&& dispatch) {
        if (!isValid()) {
            return false;
        }
        RustDeskDisplaySwitchGateDecision decision;
        {
            auto displayLease = displayCoordinator_.acquire();
            decision = displayLease.observeFrame(display, keyFrame);
        }
        // The callback may synchronously report pressure, disconnect, or
        // activate the next session. Re-check before crossing the external
        // boundary, but never hold the non-reentrant display coordinator while
        // invoking user/FFI code.
        if (!decision.acceptFrame || !isValid()) {
            return false;
        }
        dispatch(decision);
        return true;
    }

    template<typename IsValid, typename Dispatch>
    bool dispatchDisplay(int display, IsValid&& isValid, Dispatch&& dispatch) {
        if (!isValid()) {
            return false;
        }
        RustDeskDisplaySwitchGateDecision decision;
        {
            auto displayLease = displayCoordinator_.acquire();
            decision = displayLease.observeDisplay(display);
        }
        if (!decision.publishDisplay || !isValid()) {
            return false;
        }
        dispatch(decision);
        return true;
    }

    template<typename IsValid, typename SwitchDisplay>
    RustDeskDisplayControlRequest beginDisplaySwitch(
        int display, IsValid&& isValid, SwitchDisplay&& switchDisplay) {
        RustDeskDisplayControlRequest result;
        if (display < 0 || !isValid()) {
            return result;
        }
        auto handleLease = handleGate_.acquire();
        if (!handleLease) {
            return result;
        }
        if (!isValid()) {
            return result;
        }
        return beginDisplaySwitchWithHandle(
            display, handleLease.get(), std::forward<SwitchDisplay>(switchDisplay));
    }

    /**
     * Begin one display-switch transaction with an already pinned handle.
     *
     * The bridge uses this variant from dispatchOutbound(), where continuity
     * admission and the shared handle lease already span the complete FFI
     * enqueue. Keeping handle acquisition out of this helper avoids nesting
     * the non-recursive handle gate while preserving the display-generation
     * rollback used by the standalone path above.
     */
    template<typename SwitchDisplay>
    RustDeskDisplayControlRequest beginDisplaySwitchWithHandle(
        int display, void* handle, SwitchDisplay&& switchDisplay) {
        RustDeskDisplayControlRequest result;
        if (display < 0 || handle == nullptr) {
            return result;
        }
        {
            auto displayLease = displayCoordinator_.acquire();
            result.generation = displayLease.begin(display);
        }
        // Keep the opaque handle pinned through the FFI call, but release the
        // non-reentrant display coordinator before crossing the external
        // callback boundary. A synchronous pressure/disconnect callback may
        // therefore reacquire the display boundary safely.
        result.accepted = std::forward<SwitchDisplay>(switchDisplay)(handle, display);
        if (!result.accepted) {
            auto displayLease = displayCoordinator_.acquire();
            displayLease.reject(result.generation);
        }
        return result;
    }

    template<typename IsValid, typename Query, typename BeforeSnapshot>
    bool queryDisplayState(
        IsValid&& isValid,
        Query&& query,
        BeforeSnapshot&& beforeSnapshot,
        RustDeskDisplaySwitchGateSnapshot& gateSnapshot) {
        if (!isValid()) {
            return false;
        }
        {
            auto handleLease = handleGate_.acquire();
            if (!handleLease || !isValid() || !query(handleLease.get())) {
                return false;
            }
        }
        // Release the handle before taking the display snapshot. Network and
        // explicit retirement hold the display boundary while detaching the
        // handle, so retaining both here would invert that production order.
        std::forward<BeforeSnapshot>(beforeSnapshot)();
        auto displayLease = displayCoordinator_.acquire();
        if (!isValid()) {
            return false;
        }
        gateSnapshot = displayLease.snapshot();
        return true;
    }

    template<typename IsValid, typename Query>
    bool queryDisplayState(
        IsValid&& isValid,
        Query&& query,
        RustDeskDisplaySwitchGateSnapshot& gateSnapshot) {
        return queryDisplayState(
            std::forward<IsValid>(isValid),
            std::forward<Query>(query),
            []() {},
            gateSnapshot);
    }

    RustDeskDisplaySwitchCoordinator::Lease acquireDisplayLease() {
        return displayCoordinator_.acquire();
    }

    RustDeskFfiHandleGate::Lease acquireHandle() const {
        return handleGate_.acquire();
    }

    bool attachHandle(void* handle) {
        return handleGate_.attach(handle);
    }

    void* detachHandle() {
        return handleGate_.detach();
    }

    void* detachHandleIf(void* expected) {
        return handleGate_.detachIf(expected);
    }

    bool ownsHandle(void* expected) const {
        return handleGate_.owns(expected);
    }

    bool hasHandle() const {
        return handleGate_.hasHandle();
    }

    RustDeskDisplaySwitchGateSnapshot snapshot() {
        return displayCoordinator_.snapshot();
    }

    void resetDisplayState() {
        displayCoordinator_.reset();
    }

private:
    RustDeskDisplaySwitchCoordinator displayCoordinator_;
    RustDeskFfiHandleGate handleGate_;
};

#endif // RUSTDESK_DISPLAY_CONTROL_PLANE_H
