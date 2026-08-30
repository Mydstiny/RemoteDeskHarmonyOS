#include "ssh_operation_client.h"

#include "ssh_adapter.h"
#include "ssh_operation_executor.h"

#include <memory>
#include <utility>

namespace {

class SshAdapterOperationTransport final : public SshOperationTransport {
public:
    SshAdapterOperationTransport() : adapter_(std::make_shared<SshAdapter>()) {}

    void requestConnectCancel() override {
        adapter_->requestConnectCancel();
    }

    int connectForOperation(
        const ConnectionConfig& config, SshOperationTransportMode mode,
        remotedesk::net::NetworkGenerationSnapshot networkSnapshot,
        SshOperationTransportHostKey& hostKey) override {
        SshOperationHostKeySnapshot snapshot;
        const int code = adapter_->connectForOperation(
            config,
            mode == SshOperationTransportMode::Authenticated
                ? SshOperationSessionMode::Authenticated
                : SshOperationSessionMode::ProbeOnly,
            networkSnapshot,
            snapshot);
        hostKey.ok = snapshot.ok;
        hostKey.algorithm = std::move(snapshot.algorithm);
        hostKey.fingerprintSha256 = std::move(snapshot.fingerprintSha256);
        hostKey.rawBase64 = std::move(snapshot.rawBase64);
        hostKey.serverBanner = std::move(snapshot.serverBanner);
        return code;
    }

    int executeCommand(
        const std::string& command,
        remotedesk::net::NetworkGenerationSnapshot networkSnapshot,
        SshOperationTransportCommandResult& result,
        int timeoutMs) override {
        SshCommandResult adapterResult;
        const int code = adapter_->executeCommandForOperation(
            command, adapterResult, networkSnapshot, timeoutMs);
        result.exitCode = adapterResult.exitCode;
        result.signaled = adapterResult.signaled;
        result.signal = std::move(adapterResult.signal);
        result.stdoutBytes = std::move(adapterResult.stdoutBytes);
        result.stderrBytes = std::move(adapterResult.stderrBytes);
        return code;
    }

    void disconnect() override {
        adapter_->disconnect();
    }

private:
    std::shared_ptr<SshAdapter> adapter_;
};

std::shared_ptr<SshOperationTransport> makeOperationTransport() {
    return std::make_shared<SshAdapterOperationTransport>();
}

} // namespace

SshHostKeyInfo probeSshHostKeyForOperation(
    const ConnectionConfig& config,
    const std::shared_ptr<SshOperationControl>& control,
    remotedesk::net::NetworkGenerationSnapshot networkSnapshot) {
    return probeSshHostKeyWithTransportForOperation(
        config, control, networkSnapshot, makeOperationTransport);
}

SshAuthTestResult testSshKeyAuthForOperation(
    const ConnectionConfig& config,
    const std::shared_ptr<SshOperationControl>& control,
    remotedesk::net::NetworkGenerationSnapshot networkSnapshot) {
    return testSshKeyAuthWithTransportForOperation(
        config, control, networkSnapshot, makeOperationTransport,
        [](const std::string& privateKeyPem,
           const std::string& privateKeyPassphrase) {
            const SshPrivateKeyInfo info = inspectSshPrivateKey(
                privateKeyPem, privateKeyPassphrase);
            return SshOperationPrivateKeyValidation {info.ok, info.error};
        });
}

SshPublicKeyInstallResult installSshPublicKeyForOperation(
    const ConnectionConfig& config, const std::string& publicKey,
    const std::shared_ptr<SshOperationControl>& control,
    remotedesk::net::NetworkGenerationSnapshot networkSnapshot) {
    return installSshPublicKeyWithTransportForOperation(
        config, publicKey, control, networkSnapshot, makeOperationTransport,
        validatePublicKeyForAuthorizedKeys);
}
