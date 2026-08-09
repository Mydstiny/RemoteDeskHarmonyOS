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

} // namespace SshTerminalResumePolicy

#endif // SSH_TERMINAL_RESUME_POLICY_H
