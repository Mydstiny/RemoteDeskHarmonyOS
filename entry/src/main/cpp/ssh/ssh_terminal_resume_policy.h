/**
 * Rebinding a detached SSH page is a callback-lifecycle operation. The page
 * may be rebound while the transport is reconnecting; input is resumed only
 * after the transport reaches CONNECTED.
 */
#ifndef SSH_TERMINAL_RESUME_POLICY_H
#define SSH_TERMINAL_RESUME_POLICY_H

#include "extensions/protocol_adapter.h"

namespace SshTerminalResumePolicy {

inline bool acceptsPageBinding(ConnectionState state, bool hasCallbackRegistration) {
    if (!hasCallbackRegistration) {
        return false;
    }
    return state == ConnectionState::CONNECTING ||
        state == ConnectionState::CONNECTED ||
        state == ConnectionState::RECONNECTING;
}

inline bool shouldResumeInput(ConnectionState state) {
    return state == ConnectionState::CONNECTED;
}

/**
 * A normal in-app terminal still owns the legacy process-wide input/sink
 * target. An independent PC window uses only the explicit SSH session id for
 * callback, input, PTY and SFTP operations, so it must not contend for that
 * singleton owner with another already-open window.
 */
inline bool acceptsSharedSinkActivation(bool foreground,
                                        bool sharedSinkActivationSucceeded) {
    return !foreground || sharedSinkActivationSucceeded;
}

/**
 * Detaching an in-app foreground terminal keeps its SSH reactor alive, but it
 * must release the singleton sink/input owner before another tab can become
 * foreground. Detached independent-window/SFTP sessions never own that
 * singleton and must not mutate it.
 */
inline bool shouldReleaseSharedSinkOnDetach(bool foreground,
                                            bool activeOwnerMatches) {
    return foreground && activeOwnerMatches;
}

inline bool acceptsDetachSharedSinkRelease(bool foreground,
                                           bool activeOwnerMatches,
                                           bool releaseSucceeded) {
    return !shouldReleaseSharedSinkOnDetach(foreground, activeOwnerMatches) ||
        releaseSucceeded;
}

/** A queued callback owned by a detached page must return its bytes to the session. */
inline bool shouldRedeliverCallback(bool registrationAccepting,
                                    bool redeliverOnStop) {
    return !registrationAccepting && redeliverOnStop;
}

} // namespace SshTerminalResumePolicy

#endif // SSH_TERMINAL_RESUME_POLICY_H
