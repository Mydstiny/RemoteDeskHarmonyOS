/**
 * Stable SSH session identities shared by the native adapter and NAPI.
 *
 * SSH is a multi-session protocol in this app.  These types deliberately do
 * not contain credentials or terminal payloads; every operation is addressed
 * by the numeric session, channel and generation tuple.
 */
#ifndef SSH_SESSION_TYPES_H
#define SSH_SESSION_TYPES_H

#include <cstdint>
#include <string>

enum class SshSessionLifecycleState : uint8_t {
    Created = 0,
    Connecting,
    Authenticating,
    Ready,
    NetworkLost,
    ReconnectScheduled,
    Reconnecting,
    NeedsAuthentication,
    Failed,
    Closing,
    Closed,
};

inline const char* sshSessionLifecycleStateName(SshSessionLifecycleState state) noexcept {
    switch (state) {
        case SshSessionLifecycleState::Created: return "Created";
        case SshSessionLifecycleState::Connecting: return "Connecting";
        case SshSessionLifecycleState::Authenticating: return "Authenticating";
        case SshSessionLifecycleState::Ready: return "Ready";
        case SshSessionLifecycleState::NetworkLost: return "NetworkLost";
        case SshSessionLifecycleState::ReconnectScheduled: return "ReconnectScheduled";
        case SshSessionLifecycleState::Reconnecting: return "Reconnecting";
        case SshSessionLifecycleState::NeedsAuthentication: return "NeedsAuthentication";
        case SshSessionLifecycleState::Failed: return "Failed";
        case SshSessionLifecycleState::Closing: return "Closing";
        case SshSessionLifecycleState::Closed: return "Closed";
    }
    return "Failed";
}

/** Metadata for one ordered SSH event. Payloads are kept outside this type. */
struct SshEventEnvelope {
    uint32_t schemaVersion = 1;
    uint64_t sessionId = 0;
    uint64_t generation = 0;
    std::string channelId = "shell";
    std::string taskId;
    std::string requestId;
    uint64_t sequence = 0;
    uint64_t timestampMs = 0;
    uint8_t priority = 0;
    std::string type;
    // Payload is deliberately opaque to the native lifecycle layer. Callers
    // may serialize a bounded JSON object without putting credentials here.
    std::string payloadJson;
};

struct SshSessionSnapshot {
    uint32_t schemaVersion = 1;
    uint64_t sessionId = 0;
    uint64_t generation = 0;
    std::string channelId = "shell";
    SshSessionLifecycleState state = SshSessionLifecycleState::Created;
    uint64_t eventSequence = 0;
    std::string host;
    int port = 22;
    bool backgroundLimited = false;
    std::string lastEventType;
};

#endif // SSH_SESSION_TYPES_H
