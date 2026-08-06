#ifndef SSH_SESSION_MANAGER_H
#define SSH_SESSION_MANAGER_H

#include "ssh_session_types.h"

#include <cstdint>
#include <memory>
#include <map>
#include <mutex>
#include <string>
#include <vector>

class SshAdapter;

/** The identity every SSH native operation must carry. */
struct SshSessionHandle {
    uint64_t sessionId = 0;
    std::string channelId = "shell";
    uint64_t generation = 0;

    bool valid() const noexcept {
        return sessionId != 0 && generation != 0 && !channelId.empty();
    }
};

enum class SshSessionManagerResult : int {
    Ok = 0,
    InvalidIdentity = -81,
    NotFound = -82,
    StaleSession = -83,
    InvalidTransition = -84,
    AlreadyExists = -85,
    LimitReached = -86,
};

/**
 * Session-owned state shared by NAPI, background work and terminal views.
 * Credentials and adapter payloads are intentionally absent from this type.
 */
struct SshSessionContext final {
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
    std::weak_ptr<SshAdapter> adapter;
};

class SshSessionManager final {
public:
    static constexpr size_t kMaxSessions = 32;
    static constexpr size_t kMaxEventsPerSession = 128;

    SshSessionManager() = default;
    ~SshSessionManager() = default;

    SshSessionManagerResult registerSession(const SshSessionHandle& handle,
        const std::string& host, int port,
        const std::shared_ptr<SshAdapter>& adapter = nullptr);
    SshSessionManagerResult closeSession(const SshSessionHandle& handle,
        bool remove = true);
    SshSessionManagerResult transition(const SshSessionHandle& handle,
        SshSessionLifecycleState state, const std::string& eventType,
        const std::string& payloadJson = "", uint8_t priority = 0);
    SshSessionManagerResult setBackgroundLimited(const SshSessionHandle& handle,
        bool limited, const std::string& reason = "");

    bool accepts(const SshSessionHandle& handle) const;
    bool snapshot(const SshSessionHandle& handle, SshSessionSnapshot& out,
        SshSessionManagerResult* result = nullptr) const;
    std::vector<SshSessionSnapshot> snapshots() const;
    std::vector<SshEventEnvelope> events(const SshSessionHandle& handle,
        uint64_t afterSequence = 0) const;
    size_t size() const;

private:
    struct Entry {
        SshSessionContext context;
        std::vector<SshEventEnvelope> events;
    };

    static bool validTransition(SshSessionLifecycleState from,
        SshSessionLifecycleState to);
    static uint64_t timestampMs();
    static SshSessionSnapshot toSnapshot(const Entry& entry);
    static SshSessionManagerResult resolveLocked(
        const std::map<uint64_t, Entry>& entries,
        const SshSessionHandle& handle,
        const Entry*& out);

    mutable std::mutex mutex_;
    std::map<uint64_t, Entry> entries_;
};

/**
 * Narrow facade used at native boundaries. It prevents callers from
 * accidentally addressing an SSH adapter by a process-global active pointer.
 */
class SshNativeFacade final {
public:
    explicit SshNativeFacade(SshSessionManager& manager) : manager_(manager) {}

    SshSessionManagerResult registerSession(const SshSessionHandle& handle,
        const std::string& host, int port,
        const std::shared_ptr<SshAdapter>& adapter = nullptr) {
        return manager_.registerSession(handle, host, port, adapter);
    }
    SshSessionManagerResult closeSession(const SshSessionHandle& handle) {
        return manager_.closeSession(handle);
    }
    SshSessionManagerResult transition(const SshSessionHandle& handle,
        SshSessionLifecycleState state, const std::string& eventType,
        const std::string& payloadJson = "", uint8_t priority = 0) {
        return manager_.transition(handle, state, eventType, payloadJson, priority);
    }
    SshSessionManagerResult setBackgroundLimited(const SshSessionHandle& handle,
        bool limited, const std::string& reason = "") {
        return manager_.setBackgroundLimited(handle, limited, reason);
    }
    bool accepts(const SshSessionHandle& handle) const {
        return manager_.accepts(handle);
    }
    bool snapshot(const SshSessionHandle& handle, SshSessionSnapshot& out,
        SshSessionManagerResult* result = nullptr) const {
        return manager_.snapshot(handle, out, result);
    }
    std::vector<SshSessionSnapshot> snapshots() const { return manager_.snapshots(); }
    std::vector<SshEventEnvelope> events(const SshSessionHandle& handle,
        uint64_t afterSequence = 0) const {
        return manager_.events(handle, afterSequence);
    }

private:
    SshSessionManager& manager_;
};

#endif // SSH_SESSION_MANAGER_H
