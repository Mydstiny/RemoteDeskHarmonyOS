#ifndef SSH_FORWARDING_MANAGER_H
#define SSH_FORWARDING_MANAGER_H

#include <cstdint>
#include <map>
#include <mutex>
#include <string>
#include <vector>

enum class SshForwardingMode : uint8_t {
    Local = 0,
    Remote = 1,
    Dynamic = 2,
};

enum class SshForwardingState : uint8_t {
    Stopped = 0,
    Starting = 1,
    Listening = 2,
    Stopping = 3,
    Failed = 4,
};

// Keep forwarding failures separate from the existing SSH protocol errors.
// The values are stable for the future NAPI bridge and diagnostics layer.
enum class SshForwardingResult : int {
    Ok = 0,
    InvalidId = -61,
    InvalidMode = -62,
    InvalidBindHost = -63,
    PublicBindNotAllowed = -64,
    InvalidBindPort = -65,
    InvalidTargetHost = -66,
    InvalidTargetPort = -67,
    InvalidConnectionLimit = -68,
    DynamicTargetSet = -69,
    ProfileLimit = -70,
    DuplicateId = -71,
    NotFound = -72,
    Busy = -73,
    InvalidState = -74,
    StaleSession = -75,
    Disabled = -76,
    ConnectionLimit = -77,
    MissingGeneration = -78,
    UnsupportedMode = -79,
    TransportFailure = -80,
    ByteLimit = -81,
    Expired = -82,
};

struct SshForwardingConfig {
    uint32_t schemaVersion = 1;
    std::string id;
    SshForwardingMode mode = SshForwardingMode::Local;
    std::string bindHost = "127.0.0.1";
    int bindPort = 0;
    std::string targetHost;
    int targetPort = 0;
    uint32_t maxConnections = 16;
    bool enabled = true;
    bool allowPublicBind = false;
    uint16_t minBindPort = 1;
    uint16_t maxBindPort = 65535;
    uint64_t maxBytes = 0;
    uint64_t expiresAtMs = 0;
    uint64_t ownerSessionId = 0;
    std::string ownerChannelId = "shell";
    uint64_t ownerGeneration = 0;
};

using SshForwardingProfile = SshForwardingConfig;

struct SshForwardingSnapshot {
    SshForwardingConfig config;
    SshForwardingState state = SshForwardingState::Stopped;
    uint64_t sessionGeneration = 0;
    uint32_t activeConnections = 0;
    int lastError = 0;
    uint64_t transferredBytes = 0;
    uint64_t expiresAtMs = 0;
    std::string actualBindHost;
    int actualBindPort = 0;
    int actualBindFamily = 0; // AF_UNSPEC/AF_INET/AF_INET6 numeric value
};

struct SshForwardingRuntime {
    uint32_t schemaVersion = 1;
    std::string id;
    SshForwardingState state = SshForwardingState::Stopped;
    uint64_t sessionId = 0;
    std::string channelId = "shell";
    uint64_t generation = 0;
    uint32_t activeConnections = 0;
    uint64_t transferredBytes = 0;
    int lastError = 0;
};

class SshForwardingManager final {
public:
    static constexpr size_t kMaxProfiles = 32;
    static constexpr uint32_t kMaxConnections = 64;
    static constexpr uint32_t kDefaultMaxConnections = 16;
    static constexpr const char* kDefaultBindHost = "127.0.0.1";

    static SshForwardingResult validateAndNormalize(SshForwardingConfig& config);
    // SOCKS destinations are wire input, not persisted profile fields.
    static bool normalizeRuntimeTargetHost(std::string& host);

    SshForwardingResult upsert(const SshForwardingConfig& config);
    SshForwardingResult remove(const std::string& id);

    // Start and stop only update ownership state. Socket/channel work is
    // performed by the SSH session owner reactor in a later integration step.
    SshForwardingResult start(const std::string& id, uint64_t sessionGeneration);
    SshForwardingResult markListening(const std::string& id, uint64_t sessionGeneration,
                                      const std::string& actualBindHost = "",
                                      int actualBindPort = 0,
                                      int actualBindFamily = 0);
    SshForwardingResult fail(const std::string& id, uint64_t sessionGeneration, int error);
    SshForwardingResult requestStop(const std::string& id, uint64_t sessionGeneration);
    SshForwardingResult completeStop(const std::string& id);

    SshForwardingResult acquireConnection(const std::string& id, uint64_t sessionGeneration);
    SshForwardingResult releaseConnection(const std::string& id, uint64_t sessionGeneration);

    // Traffic accounting is owned by the session reactor, while the manager
    // remains the single authority for a profile-wide byte budget.
    SshForwardingResult recordBytes(const std::string& id,
                                    uint64_t sessionGeneration,
                                    uint64_t bytes);
    uint64_t remainingBytes(const std::string& id, uint64_t sessionGeneration) const;
    SshForwardingResult checkRuntimeLimits(const std::string& id,
                                           uint64_t sessionGeneration);

    // Called only after the SSH transport owner has closed all forwarding
    // sockets/channels. Profiles remain configured for the next session.
    void resetRuntimeAfterTransportClose();

    std::vector<SshForwardingSnapshot> snapshots() const;
    bool snapshot(const std::string& id, SshForwardingSnapshot& out) const;
    size_t size() const;

private:
    struct Entry {
        SshForwardingConfig config;
        SshForwardingState state = SshForwardingState::Stopped;
        uint64_t sessionGeneration = 0;
        uint32_t activeConnections = 0;
        int lastError = 0;
        uint64_t transferredBytes = 0;
        std::string actualBindHost;
        int actualBindPort = 0;
        int actualBindFamily = 0;
    };

    static bool isValidMode(SshForwardingMode mode);
    static bool isLoopbackHost(const std::string& host);
    static bool isValidPort(int port);
    static SshForwardingSnapshot toSnapshot(const Entry& entry);
    static bool generationMatches(const Entry& entry, uint64_t sessionGeneration);
    static uint64_t nowMs();
    static SshForwardingResult checkRuntimeLimitsLocked(Entry& entry,
                                                        uint64_t sessionGeneration);

    mutable std::mutex mutex_;
    std::map<std::string, Entry> entries_;
};

#endif // SSH_FORWARDING_MANAGER_H
