#ifndef SSH_OPERATION_CLIENT_H
#define SSH_OPERATION_CLIENT_H

#include "common/network_generation_fence.h"
#include "extensions/protocol_adapter.h"
#include "ssh_key_tool.h"
#include "ssh_operation_control.h"

#include <memory>

SshHostKeyInfo probeSshHostKeyForOperation(
    const ConnectionConfig& config,
    const std::shared_ptr<SshOperationControl>& control,
    remotedesk::net::NetworkGenerationSnapshot networkSnapshot);

SshAuthTestResult testSshKeyAuthForOperation(
    const ConnectionConfig& config,
    const std::shared_ptr<SshOperationControl>& control,
    remotedesk::net::NetworkGenerationSnapshot networkSnapshot);

SshPublicKeyInstallResult installSshPublicKeyForOperation(
    const ConnectionConfig& config,
    const std::string& publicKey,
    const std::shared_ptr<SshOperationControl>& control,
    remotedesk::net::NetworkGenerationSnapshot networkSnapshot);

#endif // SSH_OPERATION_CLIENT_H
