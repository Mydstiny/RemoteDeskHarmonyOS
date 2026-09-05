#ifndef SSH_OPERATION_EXECUTOR_H
#define SSH_OPERATION_EXECUTOR_H

#include "ssh_key_tool.h"
#include "ssh_operation_control.h"
#include "ssh_operation_transport.h"

#include <chrono>
#include <functional>
#include <memory>
#include <string>

struct SshOperationPrivateKeyValidation {
    bool ok = false;
    std::string error;
};

using SshOperationTransportFactory =
    std::function<std::shared_ptr<SshOperationTransport>()>;
using SshOperationPrivateKeyValidator = std::function<
    SshOperationPrivateKeyValidation(const std::string&, const std::string&)>;
using SshOperationPublicKeyValidator =
    std::function<bool(const std::string&)>;

enum class SshOperationNetworkRetryResult {
    Finished,
    Cancelled,
    Deadline,
    NetworkChanged,
};

enum class SshOperationNewSessionPolicy {
    RetrySafe,
    RequiresFreshAuthentication,
};

using SshOperationNetworkSnapshotProvider = std::function<
    remotedesk::net::NetworkGenerationSnapshot()>;
using SshOperationNetworkAttempt = std::function<void(
    remotedesk::net::NetworkGenerationSnapshot)>;

/** Run complete operation attempts under one immutable absolute deadline. */
SshOperationNetworkRetryResult runSshOperationNetworkAttempts(
    remotedesk::net::NetworkGenerationSnapshot initialSnapshot,
    std::chrono::steady_clock::time_point deadline,
    const std::shared_ptr<SshOperationControl>& control,
    const SshOperationNetworkSnapshotProvider& snapshotProvider,
    SshOperationNewSessionPolicy newSessionPolicy,
    const SshOperationNetworkAttempt& attempt);

SshHostKeyInfo probeSshHostKeyWithTransportForOperation(
    const ConnectionConfig& config,
    const std::shared_ptr<SshOperationControl>& control,
    remotedesk::net::NetworkGenerationSnapshot networkSnapshot,
    const SshOperationTransportFactory& transportFactory,
    std::chrono::steady_clock::time_point deadline =
        std::chrono::steady_clock::time_point::max());

SshAuthTestResult testSshKeyAuthWithTransportForOperation(
    const ConnectionConfig& config,
    const std::shared_ptr<SshOperationControl>& control,
    remotedesk::net::NetworkGenerationSnapshot networkSnapshot,
    const SshOperationTransportFactory& transportFactory,
    const SshOperationPrivateKeyValidator& privateKeyValidator,
    std::chrono::steady_clock::time_point deadline =
        std::chrono::steady_clock::time_point::max());

SshPublicKeyInstallResult installSshPublicKeyWithTransportForOperation(
    const ConnectionConfig& config,
    const std::string& publicKey,
    const std::shared_ptr<SshOperationControl>& control,
    remotedesk::net::NetworkGenerationSnapshot networkSnapshot,
    const SshOperationTransportFactory& transportFactory,
    const SshOperationPublicKeyValidator& publicKeyValidator,
    std::chrono::steady_clock::time_point deadline =
        std::chrono::steady_clock::time_point::max());

#endif // SSH_OPERATION_EXECUTOR_H
