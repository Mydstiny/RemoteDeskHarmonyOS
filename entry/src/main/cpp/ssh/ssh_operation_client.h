#ifndef SSH_OPERATION_CLIENT_H
#define SSH_OPERATION_CLIENT_H

#include "extensions/protocol_adapter.h"
#include "ssh_key_tool.h"
#include "ssh_operation_control.h"

#include <memory>

SshHostKeyInfo probeSshHostKeyForOperation(
    const ConnectionConfig& config,
    const std::shared_ptr<SshOperationControl>& control);

SshAuthTestResult testSshKeyAuthForOperation(
    const ConnectionConfig& config,
    const std::shared_ptr<SshOperationControl>& control);

SshPublicKeyInstallResult installSshPublicKeyForOperation(
    const ConnectionConfig& config,
    const std::string& publicKey,
    const std::shared_ptr<SshOperationControl>& control);

#endif // SSH_OPERATION_CLIENT_H
