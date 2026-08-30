#include "ssh_operation_client.h"

#include "ssh_adapter.h"

#include <new>

namespace {

void secureClear(std::string& value) {
    if (!value.empty()) {
        volatile char* bytes = value.data();
        for (std::size_t index = 0; index < value.size(); ++index) {
            bytes[index] = '\0';
        }
    }
    value.clear();
}

void clearOperationSecrets(ConnectionConfig& config) {
    secureClear(config.password);
    secureClear(config.privateKeyPem);
    secureClear(config.privateKeyPassphrase);
    secureClear(config.sshProxyPassword);
    secureClear(config.sshProxyPrivateKeyPem);
    secureClear(config.sshProxyPrivateKeyPassphrase);
    for (std::string& response : config.sshKeyboardInteractiveResponses) {
        secureClear(response);
    }
    config.sshKeyboardInteractiveResponses.clear();
    for (std::string& response : config.sshProxyKeyboardInteractiveResponses) {
        secureClear(response);
    }
    config.sshProxyKeyboardInteractiveResponses.clear();
    for (SshJumpHopHandoff& handoff : config.sshJumpHopHandoffs) {
        secureClear(handoff.password);
        secureClear(handoff.privateKeyPem);
        secureClear(handoff.privateKeyPassphrase);
        for (std::string& response : handoff.keyboardInteractiveResponses) {
            secureClear(response);
        }
        handoff.keyboardInteractiveResponses.clear();
    }
    config.sshJumpHopHandoffs.clear();
}

class OperationSecretGuard final {
public:
    explicit OperationSecretGuard(ConnectionConfig& config) : config_(config) {}
    ~OperationSecretGuard() { clearOperationSecrets(config_); }

private:
    ConnectionConfig& config_;
};

int effectiveOperationError(const std::shared_ptr<SshOperationControl>& control,
                            int fallback) {
    if (!control) { return fallback; }
    switch (control->cancelReason()) {
        case SshOperationCancelReason::User:
            return ERR_SSH_AUTH_CANCELLED;
        case SshOperationCancelReason::Deadline:
            return ERR_SSH_CONNECT_TIMEOUT;
        case SshOperationCancelReason::None:
            return fallback;
    }
    return fallback;
}

std::string operationErrorMessage(int code) {
    if (code == ERR_SSH_AUTH_CANCELLED || code == ERR_SSH_SESSION_CLOSED) {
        return "SSH operation cancelled";
    }
    if (code == ERR_SSH_CONNECT_TIMEOUT || code == ERR_SSH_KEX_TIMEOUT ||
        code == ERR_SSH_AUTH_TIMEOUT || code == ERR_SSH_COMMAND_TIMEOUT) {
        return "SSH operation deadline exceeded";
    }
    if (code == ERR_SSH_HOSTKEY_MISMATCH) {
        return "target host key trust is missing or no longer matches this route";
    }
    return "SSH operation failed [" + std::to_string(code) + "]";
}

class OperationAdapter final {
public:
    explicit OperationAdapter(const std::shared_ptr<SshOperationControl>& control)
        : control_(control), adapter_(std::make_shared<SshAdapter>()) {
        const std::weak_ptr<SshAdapter> weakAdapter = adapter_;
        if (control_) {
            control_->bindTransportCancel([weakAdapter]() {
                const std::shared_ptr<SshAdapter> adapter = weakAdapter.lock();
                if (adapter) { adapter->requestConnectCancel(); }
            });
        }
    }

    ~OperationAdapter() {
        if (control_) { control_->clearTransportCancel(); }
        if (adapter_) { adapter_->disconnect(); }
    }

    SshAdapter& adapter() { return *adapter_; }

private:
    std::shared_ptr<SshOperationControl> control_;
    std::shared_ptr<SshAdapter> adapter_;
};

bool hasTargetHostKeyBinding(const ConnectionConfig& config) {
    return !config.expectedHostKeyRawBase64.empty() ||
        !config.expectedHostKeyFingerprintSha256.empty();
}

void clearTargetAuthentication(ConnectionConfig& config) {
    config.username = "probe";
    secureClear(config.password);
    secureClear(config.privateKeyPem);
    secureClear(config.privateKeyPassphrase);
    for (std::string& response : config.sshKeyboardInteractiveResponses) {
        secureClear(response);
    }
    config.sshKeyboardInteractiveResponses.clear();
    config.authMethod = "password";
    config.expectedHostKeyRawBase64.clear();
    config.expectedHostKeyFingerprintSha256.clear();
    config.sshHostKeyPromptEnabled = false;
}

SshHostKeyInfo hostKeyFailure(const ConnectionConfig& config, int code) {
    SshHostKeyInfo result {};
    result.host = config.host;
    result.port = config.port;
    result.errorCode = code;
    result.errorMessage = operationErrorMessage(code);
    return result;
}

SshAuthTestResult authFailure(int code) {
    return SshAuthTestResult {false, code, operationErrorMessage(code)};
}

SshPublicKeyInstallResult installFailure(int code, const std::string& message = "") {
    return SshPublicKeyInstallResult {
        false, false, false, code,
        message.empty() ? operationErrorMessage(code) : message};
}

} // namespace

SshHostKeyInfo probeSshHostKeyForOperation(
    const ConnectionConfig& source,
    const std::shared_ptr<SshOperationControl>& control) {
    ConnectionConfig config = source;
    OperationSecretGuard secretGuard(config);
    clearTargetAuthentication(config);
    if (!control || control->cancelled()) {
        return hostKeyFailure(config, effectiveOperationError(
            control, ERR_SSH_AUTH_CANCELLED));
    }

    OperationAdapter operation(control);
    SshOperationHostKeySnapshot snapshot;
    int code = operation.adapter().connectForOperation(
        config, SshOperationSessionMode::ProbeOnly, snapshot);
    code = effectiveOperationError(control, code);
    if (code != 0 || !snapshot.ok) {
        return hostKeyFailure(config, code == 0 ? ERR_SSH_HOSTKEY_MISMATCH : code);
    }

    SshHostKeyInfo result {};
    result.ok = true;
    result.host = config.host;
    result.port = config.port;
    result.algorithm = snapshot.algorithm;
    result.fingerprintSha256 = snapshot.fingerprintSha256;
    result.rawBase64 = snapshot.rawBase64;
    result.serverBanner = snapshot.serverBanner;
    return result;
}

SshAuthTestResult testSshKeyAuthForOperation(
    const ConnectionConfig& source,
    const std::shared_ptr<SshOperationControl>& control) {
    if (!hasTargetHostKeyBinding(source)) {
        return authFailure(ERR_SSH_HOSTKEY_MISMATCH);
    }
    if (!control || control->cancelled()) {
        return authFailure(effectiveOperationError(control, ERR_SSH_AUTH_CANCELLED));
    }

    ConnectionConfig config = source;
    OperationSecretGuard secretGuard(config);
    config.authMethod = "publickey";
    secureClear(config.password);
    for (std::string& response : config.sshKeyboardInteractiveResponses) {
        secureClear(response);
    }
    config.sshKeyboardInteractiveResponses.clear();
    config.sshHostKeyPromptEnabled = false;
    const SshPrivateKeyInfo keyInfo = inspectSshPrivateKey(
        config.privateKeyPem, config.privateKeyPassphrase);
    if (!keyInfo.ok) {
        return SshAuthTestResult {
            false, ERR_SSH_AUTH_FAILED,
            keyInfo.error.empty() ? "private key inspect failed" : keyInfo.error};
    }

    OperationAdapter operation(control);
    SshOperationHostKeySnapshot snapshot;
    int code = operation.adapter().connectForOperation(
        config, SshOperationSessionMode::Authenticated, snapshot);
    code = effectiveOperationError(control, code);
    if (code != 0) { return authFailure(code); }
    return SshAuthTestResult {true, 0, "key auth succeeded"};
}

SshPublicKeyInstallResult installSshPublicKeyForOperation(
    const ConnectionConfig& source, const std::string& publicKey,
    const std::shared_ptr<SshOperationControl>& control) {
    if (!validatePublicKeyForAuthorizedKeys(publicKey)) {
        return installFailure(-1, "public key failed validation");
    }
    if (!hasTargetHostKeyBinding(source)) {
        return installFailure(ERR_SSH_HOSTKEY_MISMATCH);
    }
    if (!control || control->cancelled()) {
        return installFailure(effectiveOperationError(control, ERR_SSH_AUTH_CANCELLED));
    }

    ConnectionConfig config = source;
    OperationSecretGuard secretGuard(config);
    config.sshHostKeyPromptEnabled = false;
    OperationAdapter operation(control);
    SshOperationHostKeySnapshot snapshot;
    int code = operation.adapter().connectForOperation(
        config, SshOperationSessionMode::Authenticated, snapshot);
    code = effectiveOperationError(control, code);
    if (code != 0) { return installFailure(code); }
    if (control->cancelled()) {
        return installFailure(effectiveOperationError(control, ERR_SSH_AUTH_CANCELLED));
    }

    // validatePublicKeyForAuthorizedKeys() rejects quotes and shell metacharacters.
    // The marker makes the operation idempotent and lets the caller distinguish
    // an existing line from a newly installed line without returning remote data.
    const std::string command =
        "umask 077; mkdir -p \"$HOME/.ssh\" && "
        "touch \"$HOME/.ssh/authorized_keys\" && "
        "chmod 700 \"$HOME/.ssh\" && chmod 600 \"$HOME/.ssh/authorized_keys\" && "
        "if grep -Fqx '" + publicKey + "' \"$HOME/.ssh/authorized_keys\"; then "
        "printf 'REMOTEDESK_KEY_ALREADY\\n'; else "
        "printf '%s\\n' '" + publicKey + "' >> \"$HOME/.ssh/authorized_keys\" && "
        "grep -Fqx '" + publicKey + "' \"$HOME/.ssh/authorized_keys\" && "
        "printf 'REMOTEDESK_KEY_INSTALLED\\n'; fi";
    SshCommandResult commandResult;
    code = operation.adapter().executeCommand(command, commandResult, 30000);
    code = effectiveOperationError(control, code);
    if (code != 0 || commandResult.exitCode != 0) {
        return installFailure(code != 0 ? code : ERR_SSH_SUBSYSTEM_FAILED,
                              "authorized_keys update failed");
    }
    const std::string output(
        commandResult.stdoutBytes.begin(), commandResult.stdoutBytes.end());
    const bool already = output.find("REMOTEDESK_KEY_ALREADY") != std::string::npos;
    const bool installed = output.find("REMOTEDESK_KEY_INSTALLED") != std::string::npos;
    if (!already && !installed) {
        return installFailure(ERR_SSH_SUBSYSTEM_FAILED,
                              "authorized_keys update could not be verified");
    }
    return SshPublicKeyInstallResult {
        true, already, true, 0,
        already ? "public key already installed" : "public key installed"};
}
