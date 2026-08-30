#ifndef SSH_OPERATION_TRANSPORT_H
#define SSH_OPERATION_TRANSPORT_H

#include "common/network_generation_fence.h"
#include "extensions/protocol_adapter.h"

#include <chrono>
#include <cstdint>
#include <string>
#include <vector>

struct SshOperationTransportHostKey {
    bool ok = false;
    std::string algorithm;
    std::string fingerprintSha256;
    std::string rawBase64;
    std::string serverBanner;
};

struct SshOperationTransportCommandResult {
    int exitCode = -1;
    bool signaled = false;
    std::string signal;
    std::vector<std::uint8_t> stdoutBytes;
    std::vector<std::uint8_t> stderrBytes;
};

enum class SshOperationTransportMode {
    ProbeOnly,
    Authenticated,
};

/**
 * Narrow transport boundary for cancellable SSH auxiliary operations.
 * Production wraps SshAdapter; host tests inject a deterministic fake.
 */
class SshOperationTransport {
public:
    virtual ~SshOperationTransport() = default;

    virtual void requestConnectCancel() = 0;
    virtual int connectForOperation(
        const ConnectionConfig& config,
        SshOperationTransportMode mode,
        remotedesk::net::NetworkGenerationSnapshot networkSnapshot,
        SshOperationTransportHostKey& hostKey,
        std::chrono::steady_clock::time_point deadline) = 0;
    virtual int executeCommand(
        const std::string& command,
        remotedesk::net::NetworkGenerationSnapshot networkSnapshot,
        SshOperationTransportCommandResult& result,
        int timeoutMs) = 0;
    virtual void disconnect() = 0;
};

#endif // SSH_OPERATION_TRANSPORT_H
