#ifndef RUSTDESK_DISPLAY_CONTROL_PLANE_H
#define RUSTDESK_DISPLAY_CONTROL_PLANE_H

#include "rustdesk_display_switch_gate.h"
#include "rustdesk_ffi_handle_gate.h"

#include <cstdint>
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
        {
            auto displayLease = displayCoordinator_.acquire();
            result.generation = displayLease.begin(display);
        }
        // Keep the opaque handle pinned through the FFI call, but release the
        // non-reentrant display coordinator before crossing the external
        // callback boundary. A synchronous pressure/disconnect callback may
        // therefore reacquire the display boundary safely.
        result.accepted = switchDisplay(handleLease.get(), display);
        if (!result.accepted) {
            auto displayLease = displayCoordinator_.acquire();
            displayLease.reject(result.generation);
        }
        return result;
    }

    template<typename IsValid, typename Query>
    bool queryDisplayState(
        IsValid&& isValid,
        Query&& query,
    RustDeskDisplaySwitchGateSnapshot& gateSnapshot) {
        if (!isValid()) {
            return false;
        }
        auto handleLease = handleGate_.acquire();
        if (!handleLease || !isValid() || !query(handleLease.get())) {
            return false;
        }
        // The handle lease pins the Rust client through the external query;
        // take only a short display snapshot lease after the query returns.
        auto displayLease = displayCoordinator_.acquire();
        gateSnapshot = displayLease.snapshot();
        return true;
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
