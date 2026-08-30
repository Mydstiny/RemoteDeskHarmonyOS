#ifndef SSH_OPERATION_EXECUTOR_H
#define SSH_OPERATION_EXECUTOR_H

#include "ssh_key_tool.h"
#include "ssh_operation_control.h"
#include "ssh_operation_transport.h"

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

SshHostKeyInfo probeSshHostKeyWithTransportForOperation(
    const ConnectionConfig& config,
    const std::shared_ptr<SshOperationControl>& control,
    const SshOperationTransportFactory& transportFactory);

SshAuthTestResult testSshKeyAuthWithTransportForOperation(
    const ConnectionConfig& config,
    const std::shared_ptr<SshOperationControl>& control,
    const SshOperationTransportFactory& transportFactory,
    const SshOperationPrivateKeyValidator& privateKeyValidator);

SshPublicKeyInstallResult installSshPublicKeyWithTransportForOperation(
    const ConnectionConfig& config,
    const std::string& publicKey,
    const std::shared_ptr<SshOperationControl>& control,
    const SshOperationTransportFactory& transportFactory,
    const SshOperationPublicKeyValidator& publicKeyValidator);

#endif // SSH_OPERATION_EXECUTOR_H
