#include "ssh_operation_executor.h"

#include "ssh_error.h"
#include "ssh_network_generation_policy.h"

#include <algorithm>
#include <utility>

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
        case SshOperationCancelReason::NetworkChanged:
            return ERR_SSH_SESSION_CLOSED;
        case SshOperationCancelReason::None:
            return fallback;
    }
    return fallback;
}

std::string operationErrorMessage(int code) {
    if (code == ERR_SSH_AUTH_CANCELLED || code == ERR_SSH_SESSION_CLOSED ||
        code == ERR_SSH_DNS_CANCELLED || code == ERR_SSH_CONNECT_CANCELLED) {
        return "SSH operation cancelled";
    }
    if (code == ERR_SSH_CONNECT_TIMEOUT || code == ERR_SSH_DNS_TIMEOUT ||
        code == ERR_SSH_KEX_TIMEOUT ||
        code == ERR_SSH_AUTH_TIMEOUT || code == ERR_SSH_COMMAND_TIMEOUT) {
        return "SSH operation deadline exceeded";
    }
    if (code == ERR_SSH_DNS_RESOURCE_EXHAUSTED) {
        return "SSH resolver capacity exhausted";
    }
    if (code == ERR_SSH_CONNECT_REFUSED) {
        return "SSH connection refused";
    }
    if (code == ERR_SSH_CONNECT_NO_ROUTE) {
        return "SSH network route unavailable";
    }
    if (code == ERR_SSH_HOSTKEY_MISMATCH) {
        return "target host key trust is missing or no longer matches this route";
    }
    return "SSH operation failed [" + std::to_string(code) + "]";
}

class OperationTransportGuard final {
public:
    OperationTransportGuard(
        const std::shared_ptr<SshOperationControl>& control,
        const SshOperationTransportFactory& factory)
        : control_(control), transport_(factory ? factory() : nullptr) {
        if (!control_ || !transport_) { return; }
        const std::weak_ptr<SshOperationTransport> weakTransport = transport_;
        bound_ = control_->bindTransportCancel([weakTransport]() {
            const std::shared_ptr<SshOperationTransport> transport =
                weakTransport.lock();
            if (transport) { transport->requestConnectCancel(); }
        });
    }

    ~OperationTransportGuard() {
        if (control_ && bound_) { control_->clearTransportCancel(); }
        if (transport_) { transport_->disconnect(); }
    }

    bool ready() const noexcept { return transport_ != nullptr && bound_; }
    SshOperationTransport& transport() { return *transport_; }

private:
    std::shared_ptr<SshOperationControl> control_;
    std::shared_ptr<SshOperationTransport> transport_;
    bool bound_ = false;
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

SshPublicKeyInstallResult installFailure(int code,
                                         const std::string& message = "") {
    return SshPublicKeyInstallResult {
        false, false, false, code,
        message.empty() ? operationErrorMessage(code) : message};
}

} // namespace

SshOperationNetworkRetryResult runSshOperationNetworkAttempts(
    remotedesk::net::NetworkGenerationSnapshot initialSnapshot,
    std::chrono::steady_clock::time_point deadline,
    const std::shared_ptr<SshOperationControl>& control,
    const SshOperationNetworkSnapshotProvider& snapshotProvider,
    SshOperationNewSessionPolicy newSessionPolicy,
    const SshOperationNetworkAttempt& attempt) {
    if (!control || !snapshotProvider || !attempt) {
        return SshOperationNetworkRetryResult::Cancelled;
    }

    auto cancelledResult = [&control]() {
        switch (control->cancelReason()) {
            case SshOperationCancelReason::Deadline:
                return SshOperationNetworkRetryResult::Deadline;
            case SshOperationCancelReason::NetworkChanged:
                return SshOperationNetworkRetryResult::NetworkChanged;
            case SshOperationCancelReason::User:
            case SshOperationCancelReason::None:
                return SshOperationNetworkRetryResult::Cancelled;
        }
        return SshOperationNetworkRetryResult::Cancelled;
    };

    remotedesk::net::NetworkGenerationSnapshot captured = initialSnapshot;
    std::uint32_t attemptsStarted = 0;
    while (true) {
        if (control->cancelled()) { return cancelledResult(); }
        if (std::chrono::steady_clock::now() >= deadline) {
            (void)control->cancel(SshOperationCancelReason::Deadline);
            return SshOperationNetworkRetryResult::Deadline;
        }

        ++attemptsStarted;
        attempt(captured);

        remotedesk::net::NetworkGenerationSnapshot current = snapshotProvider();
        SshNetworkRetryDecision decision =
            SshNetworkGenerationPolicy::retryDecision(
                attemptsStarted, control->cancelled(),
                std::chrono::steady_clock::now() >= deadline,
                captured, current);
        if (newSessionPolicy ==
                SshOperationNewSessionPolicy::RequiresFreshAuthentication &&
            (decision == SshNetworkRetryDecision::RetryCurrentNetwork ||
             decision == SshNetworkRetryDecision::WaitForAvailableNetwork)) {
            (void)control->cancel(SshOperationCancelReason::NetworkChanged);
            return SshOperationNetworkRetryResult::NetworkChanged;
        }
        while (decision == SshNetworkRetryDecision::WaitForAvailableNetwork) {
            const auto now = std::chrono::steady_clock::now();
            if (now >= deadline) {
                (void)control->cancel(SshOperationCancelReason::Deadline);
                return SshOperationNetworkRetryResult::Deadline;
            }
            const auto nextWake = std::min(
                deadline, now + std::chrono::milliseconds(
                    SshNetworkGenerationPolicy::kRetryPollMilliseconds));
            (void)control->waitUntilFinishedOrCancelled(nextWake);
            current = snapshotProvider();
            decision = SshNetworkGenerationPolicy::retryDecision(
                attemptsStarted, control->cancelled(),
                std::chrono::steady_clock::now() >= deadline,
                captured, current);
        }

        switch (decision) {
            case SshNetworkRetryDecision::Complete:
                return SshOperationNetworkRetryResult::Finished;
            case SshNetworkRetryDecision::RetryCurrentNetwork:
                captured = current;
                break;
            case SshNetworkRetryDecision::StopCancelled:
                return cancelledResult();
            case SshNetworkRetryDecision::StopDeadline:
                (void)control->cancel(SshOperationCancelReason::Deadline);
                return SshOperationNetworkRetryResult::Deadline;
            case SshNetworkRetryDecision::StopExhausted:
                (void)control->cancel(SshOperationCancelReason::NetworkChanged);
                return SshOperationNetworkRetryResult::NetworkChanged;
            case SshNetworkRetryDecision::WaitForAvailableNetwork:
                break;
        }
    }
}

SshHostKeyInfo probeSshHostKeyWithTransportForOperation(
    const ConnectionConfig& source,
    const std::shared_ptr<SshOperationControl>& control,
    remotedesk::net::NetworkGenerationSnapshot networkSnapshot,
    const SshOperationTransportFactory& transportFactory,
    std::chrono::steady_clock::time_point deadline) {
    ConnectionConfig config = source;
    OperationSecretGuard secretGuard(config);
    clearTargetAuthentication(config);
    if (!control || control->cancelled()) {
        return hostKeyFailure(config, effectiveOperationError(
            control, ERR_SSH_AUTH_CANCELLED));
    }

    OperationTransportGuard operation(control, transportFactory);
    if (!operation.ready()) {
        return hostKeyFailure(config, effectiveOperationError(
            control, ERR_SSH_SESSION_INIT));
    }
    SshOperationTransportHostKey snapshot;
    int code = operation.transport().connectForOperation(
        config, SshOperationTransportMode::ProbeOnly, networkSnapshot, snapshot,
        deadline);
    code = effectiveOperationError(control, code);
    if (code != 0 || !snapshot.ok) {
        return hostKeyFailure(config, code == 0 ? ERR_SSH_HOSTKEY_MISMATCH : code);
    }

    SshHostKeyInfo result {};
    result.ok = true;
    result.host = config.host;
    result.port = config.port;
    result.algorithm = std::move(snapshot.algorithm);
    result.fingerprintSha256 = std::move(snapshot.fingerprintSha256);
    result.rawBase64 = std::move(snapshot.rawBase64);
    result.serverBanner = std::move(snapshot.serverBanner);
    return result;
}

SshAuthTestResult testSshKeyAuthWithTransportForOperation(
    const ConnectionConfig& source,
    const std::shared_ptr<SshOperationControl>& control,
    remotedesk::net::NetworkGenerationSnapshot networkSnapshot,
    const SshOperationTransportFactory& transportFactory,
    const SshOperationPrivateKeyValidator& privateKeyValidator,
    std::chrono::steady_clock::time_point deadline) {
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
    const SshOperationPrivateKeyValidation validation = privateKeyValidator
        ? privateKeyValidator(config.privateKeyPem, config.privateKeyPassphrase)
        : SshOperationPrivateKeyValidation {};
    if (!validation.ok) {
        return SshAuthTestResult {
            false, ERR_SSH_AUTH_FAILED,
            validation.error.empty() ? "private key inspect failed" : validation.error};
    }

    OperationTransportGuard operation(control, transportFactory);
    if (!operation.ready()) {
        return authFailure(effectiveOperationError(control, ERR_SSH_SESSION_INIT));
    }
    SshOperationTransportHostKey snapshot;
    int code = operation.transport().connectForOperation(
        config, SshOperationTransportMode::Authenticated, networkSnapshot, snapshot,
        deadline);
    code = effectiveOperationError(control, code);
    if (code != 0) { return authFailure(code); }
    return SshAuthTestResult {true, 0, "key auth succeeded"};
}

SshPublicKeyInstallResult installSshPublicKeyWithTransportForOperation(
    const ConnectionConfig& source, const std::string& publicKey,
    const std::shared_ptr<SshOperationControl>& control,
    remotedesk::net::NetworkGenerationSnapshot networkSnapshot,
    const SshOperationTransportFactory& transportFactory,
    const SshOperationPublicKeyValidator& publicKeyValidator,
    std::chrono::steady_clock::time_point deadline) {
    if (!publicKeyValidator || !publicKeyValidator(publicKey)) {
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
    OperationTransportGuard operation(control, transportFactory);
    if (!operation.ready()) {
        return installFailure(effectiveOperationError(control, ERR_SSH_SESSION_INIT));
    }
    SshOperationTransportHostKey snapshot;
    int code = operation.transport().connectForOperation(
        config, SshOperationTransportMode::Authenticated, networkSnapshot, snapshot,
        deadline);
    code = effectiveOperationError(control, code);
    if (code != 0) { return installFailure(code); }
    if (control->cancelled()) {
        return installFailure(effectiveOperationError(control, ERR_SSH_AUTH_CANCELLED));
    }

    // The validator must reject quotes and shell metacharacters. The marker
    // makes the operation idempotent without returning remote file content.
    const std::string command =
        "umask 077; mkdir -p \"$HOME/.ssh\" && "
        "touch \"$HOME/.ssh/authorized_keys\" && "
        "chmod 700 \"$HOME/.ssh\" && chmod 600 \"$HOME/.ssh/authorized_keys\" && "
        "if grep -Fqx '" + publicKey + "' \"$HOME/.ssh/authorized_keys\"; then "
        "printf 'REMOTEDESK_KEY_ALREADY\\n'; else "
        "printf '%s\\n' '" + publicKey + "' >> \"$HOME/.ssh/authorized_keys\" && "
        "grep -Fqx '" + publicKey + "' \"$HOME/.ssh/authorized_keys\" && "
        "printf 'REMOTEDESK_KEY_INSTALLED\\n'; fi";
    SshOperationTransportCommandResult commandResult;
    code = operation.transport().executeCommand(
        command, networkSnapshot, commandResult, 30000);
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
