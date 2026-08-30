#pragma once

#include "common/network_generation_fence.h"

#include <optional>
#include <utility>

/**
 * Splits one libssh2 keyboard-interactive call into two short route-admission
 * phases. The call lease covers any request packet emitted before libssh2
 * enters the application callback. The callback releases that lease while it
 * may wait for MFA/user input, then a response lease covers the callback
 * return and libssh2's response packet.
 *
 * The two leases must never overlap: NetworkGenerationFence is intentionally
 * non-recursive, so reacquiring it from the callback would self-deadlock.
 */
class SshKeyboardInteractiveRouteAdmission final {
public:
    template <typename CancelPredicate>
    bool beginCall(
        const remotedesk::net::NetworkGenerationFence& fence,
        const remotedesk::net::NetworkGenerationSnapshot& snapshot,
        CancelPredicate&& cancelled) {
        endCall();
        return acquire(
            callAdmission_, fence, snapshot,
            std::forward<CancelPredicate>(cancelled));
    }

    /** Called synchronously at callback entry, before any prompt can block. */
    void enterCallback() noexcept {
        callAdmission_.reset();
        // A server may issue multiple challenge rounds in one libssh2 call.
        // The previous round has been consumed before the next callback, so
        // release its lease before waiting for another answer.
        responseAdmission_.reset();
    }

    template <typename CancelPredicate>
    bool holdResponse(
        const remotedesk::net::NetworkGenerationFence& fence,
        const remotedesk::net::NetworkGenerationSnapshot& snapshot,
        CancelPredicate&& cancelled) {
        responseAdmission_.reset();
        return acquire(
            responseAdmission_, fence, snapshot,
            std::forward<CancelPredicate>(cancelled));
    }

    /** Called immediately after the enclosing non-blocking libssh2 call. */
    void endCall() noexcept {
        responseAdmission_.reset();
        callAdmission_.reset();
    }

private:
    template <typename CancelPredicate>
    static bool acquire(
        std::optional<remotedesk::net::NetworkGenerationAdmission>& slot,
        const remotedesk::net::NetworkGenerationFence& fence,
        const remotedesk::net::NetworkGenerationSnapshot& snapshot,
        CancelPredicate&& cancelled) {
        remotedesk::net::NetworkGenerationAdmission admission =
            fence.acquireAdmission(snapshot);
        if (!admission || cancelled()) { return false; }
        slot.emplace(std::move(admission));
        return true;
    }

    std::optional<remotedesk::net::NetworkGenerationAdmission> callAdmission_;
    std::optional<remotedesk::net::NetworkGenerationAdmission> responseAdmission_;
};
