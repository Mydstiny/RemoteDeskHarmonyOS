#include "test_runner.h"

#include "ssh/ssh_error.h"
#include "ssh/ssh_operation_executor.h"

#include <functional>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace {

struct FakeSshOperationState {
    std::vector<std::string> events;
    int connectCode = 0;
    int commandCode = 0;
    int commandExitCode = 0;
    std::string commandOutput = "REMOTEDESK_KEY_INSTALLED\n";
    std::function<void()> onConnect;

    std::string host;
    int port = 0;
    std::string routeEndpointHost;
    SshOperationTransportMode mode = SshOperationTransportMode::ProbeOnly;
    bool targetPasswordEmpty = false;
    bool targetPrivateKeyEmpty = false;
    bool targetPassphraseEmpty = false;
    bool targetResponsesEmpty = false;
    bool targetPinPresent = false;
    bool promptDisabled = false;
    bool proxyPasswordPresent = false;
    bool jumpSecretPresent = false;
    int cancelRequests = 0;
    std::string command;
    int commandTimeoutMs = 0;
};

class FakeSshOperationTransport final : public SshOperationTransport {
public:
    explicit FakeSshOperationTransport(
        std::shared_ptr<FakeSshOperationState> state)
        : state_(std::move(state)) {}

    void requestConnectCancel() override {
        state_->events.push_back("cancel");
        ++state_->cancelRequests;
    }

    int connectForOperation(
        const ConnectionConfig& config, SshOperationTransportMode mode,
        SshOperationTransportHostKey& hostKey) override {
        state_->events.push_back("connect");
        state_->host = config.host;
        state_->port = config.port;
        state_->routeEndpointHost = config.sshRoute.endpointHost;
        state_->mode = mode;
        state_->targetPasswordEmpty = config.password.empty();
        state_->targetPrivateKeyEmpty = config.privateKeyPem.empty();
        state_->targetPassphraseEmpty = config.privateKeyPassphrase.empty();
        state_->targetResponsesEmpty =
            config.sshKeyboardInteractiveResponses.empty();
        state_->targetPinPresent =
            !config.expectedHostKeyRawBase64.empty() ||
            !config.expectedHostKeyFingerprintSha256.empty();
        state_->promptDisabled = !config.sshHostKeyPromptEnabled;
        state_->proxyPasswordPresent = !config.sshProxyPassword.empty();
        state_->jumpSecretPresent = !config.sshJumpHopHandoffs.empty() &&
            !config.sshJumpHopHandoffs.front().password.empty();
        if (state_->onConnect) { state_->onConnect(); }
        if (state_->connectCode == 0) {
            hostKey.ok = true;
            hostKey.algorithm = "ssh-ed25519";
            hostKey.fingerprintSha256 = "SHA256:fake";
            hostKey.rawBase64 = "fake-raw";
            hostKey.serverBanner = "SSH-2.0-fake";
        }
        return state_->connectCode;
    }

    int executeCommand(
        const std::string& command,
        SshOperationTransportCommandResult& result,
        int timeoutMs) override {
        state_->events.push_back("execute");
        state_->command = command;
        state_->commandTimeoutMs = timeoutMs;
        result.exitCode = state_->commandExitCode;
        result.stdoutBytes.assign(
            state_->commandOutput.begin(), state_->commandOutput.end());
        return state_->commandCode;
    }

    void disconnect() override {
        state_->events.push_back("disconnect");
    }

private:
    std::shared_ptr<FakeSshOperationState> state_;
};

SshOperationTransportFactory fakeFactory(
    const std::shared_ptr<FakeSshOperationState>& state) {
    return [state]() {
        state->events.push_back("factory");
        return std::make_shared<FakeSshOperationTransport>(state);
    };
}

ConnectionConfig scopedIpv6OperationConfig() {
    ConnectionConfig config;
    config.host = "fe80::1234%wlan0";
    config.port = 2222;
    config.username = "alice";
    config.password = "target-password";
    config.authMethod = "kbd-interactive";
    config.privateKeyPem = "target-private-key";
    config.privateKeyPassphrase = "target-passphrase";
    config.sshKeyboardInteractiveResponses = {"target-otp"};
    config.expectedHostKeyRawBase64 = "target-host-key";
    config.sshHostKeyPromptEnabled = true;
    config.sshProxyPassword = "proxy-password";
    config.sshRoute.kind = SshRouteKind::SshJump;
    config.sshRoute.endpointHost = "2001:db8::40";
    config.sshRoute.endpointPort = 22;
    config.sshRoute.hops.push_back(SshJumpHop {
        "2001:db8::30", 22, "jump-user", "password",
        "jump-host-key", "", 10000});
    SshJumpHopHandoff handoff;
    handoff.password = "jump-password";
    config.sshJumpHopHandoffs.push_back(std::move(handoff));
    return config;
}

} // namespace

RDP_TEST_CASE(ssh_operation_probe_keeps_scoped_ipv6_route_but_strips_target_auth) {
    auto state = std::make_shared<FakeSshOperationState>();
    const ConnectionConfig config = scopedIpv6OperationConfig();
    auto control = std::make_shared<SshOperationControl>(5001);

    const SshHostKeyInfo result = probeSshHostKeyWithTransportForOperation(
        config, control, fakeFactory(state));

    RDP_ASSERT(result.ok);
    RDP_ASSERT(result.host == "fe80::1234%wlan0");
    RDP_ASSERT(result.port == 2222);
    RDP_ASSERT(result.fingerprintSha256 == "SHA256:fake");
    RDP_ASSERT(state->host == "fe80::1234%wlan0");
    RDP_ASSERT(state->routeEndpointHost == "2001:db8::40");
    RDP_ASSERT(state->mode == SshOperationTransportMode::ProbeOnly);
    RDP_ASSERT(state->targetPasswordEmpty);
    RDP_ASSERT(state->targetPrivateKeyEmpty);
    RDP_ASSERT(state->targetPassphraseEmpty);
    RDP_ASSERT(state->targetResponsesEmpty);
    RDP_ASSERT(!state->targetPinPresent);
    RDP_ASSERT(state->promptDisabled);
    RDP_ASSERT(state->proxyPasswordPresent);
    RDP_ASSERT(state->jumpSecretPresent);
    const std::vector<std::string> expected {
        "factory", "connect", "disconnect"};
    RDP_ASSERT(state->events == expected);
}

RDP_TEST_CASE(ssh_operation_auth_requires_host_key_before_validation_or_transport) {
    auto state = std::make_shared<FakeSshOperationState>();
    ConnectionConfig config = scopedIpv6OperationConfig();
    config.expectedHostKeyRawBase64.clear();
    int validationCalls = 0;
    auto control = std::make_shared<SshOperationControl>(5002);

    const SshAuthTestResult result = testSshKeyAuthWithTransportForOperation(
        config, control, fakeFactory(state),
        [&validationCalls](const std::string&, const std::string&) {
            ++validationCalls;
            return SshOperationPrivateKeyValidation {true, ""};
        });

    RDP_ASSERT(!result.ok);
    RDP_ASSERT(result.code == ERR_SSH_HOSTKEY_MISMATCH);
    RDP_ASSERT(validationCalls == 0);
    RDP_ASSERT(state->events.empty());
}

RDP_TEST_CASE(ssh_operation_auth_sanitizes_config_before_authenticated_transport) {
    auto state = std::make_shared<FakeSshOperationState>();
    const ConnectionConfig config = scopedIpv6OperationConfig();
    auto control = std::make_shared<SshOperationControl>(5003);

    const SshAuthTestResult result = testSshKeyAuthWithTransportForOperation(
        config, control, fakeFactory(state),
        [state](const std::string& privateKey, const std::string& passphrase) {
            state->events.push_back("validate-private-key");
            return SshOperationPrivateKeyValidation {
                privateKey == "target-private-key" &&
                    passphrase == "target-passphrase",
                "unexpected private key"};
        });

    RDP_ASSERT(result.ok);
    RDP_ASSERT(state->mode == SshOperationTransportMode::Authenticated);
    RDP_ASSERT(state->targetPasswordEmpty);
    RDP_ASSERT(!state->targetPrivateKeyEmpty);
    RDP_ASSERT(!state->targetPassphraseEmpty);
    RDP_ASSERT(state->targetResponsesEmpty);
    RDP_ASSERT(state->targetPinPresent);
    RDP_ASSERT(state->promptDisabled);
    RDP_ASSERT(config.password == "target-password");
    RDP_ASSERT(config.privateKeyPem == "target-private-key");
    const std::vector<std::string> expected {
        "validate-private-key", "factory", "connect", "disconnect"};
    RDP_ASSERT(state->events == expected);
}

RDP_TEST_CASE(ssh_operation_cancel_and_deadline_reach_transport_and_override_error) {
    {
        auto state = std::make_shared<FakeSshOperationState>();
        auto control = std::make_shared<SshOperationControl>(5004);
        state->connectCode = ERR_SSH_SOCKET_CONNECT;
        state->onConnect = [control]() {
            RDP_ASSERT(control->cancel(SshOperationCancelReason::User));
        };

        const SshHostKeyInfo result = probeSshHostKeyWithTransportForOperation(
            scopedIpv6OperationConfig(), control, fakeFactory(state));

        RDP_ASSERT(!result.ok);
        RDP_ASSERT(result.errorCode == ERR_SSH_AUTH_CANCELLED);
        RDP_ASSERT(state->cancelRequests == 1);
        const std::vector<std::string> expected {
            "factory", "connect", "cancel", "disconnect"};
        RDP_ASSERT(state->events == expected);
    }

    {
        auto state = std::make_shared<FakeSshOperationState>();
        auto control = std::make_shared<SshOperationControl>(5005);
        state->connectCode = ERR_SSH_KEX_FAILED;
        state->onConnect = [control]() {
            RDP_ASSERT(control->cancel(SshOperationCancelReason::Deadline));
        };

        const SshHostKeyInfo result = probeSshHostKeyWithTransportForOperation(
            scopedIpv6OperationConfig(), control, fakeFactory(state));

        RDP_ASSERT(!result.ok);
        RDP_ASSERT(result.errorCode == ERR_SSH_CONNECT_TIMEOUT);
        RDP_ASSERT(state->cancelRequests == 1);
    }
}

RDP_TEST_CASE(ssh_operation_install_authenticates_before_authorized_keys_command) {
    auto state = std::make_shared<FakeSshOperationState>();
    const ConnectionConfig config = scopedIpv6OperationConfig();
    auto control = std::make_shared<SshOperationControl>(5006);
    const std::string publicKey = "ssh-ed25519 AAAATEST remotedesk@test";

    const SshPublicKeyInstallResult result =
        installSshPublicKeyWithTransportForOperation(
            config, publicKey, control, fakeFactory(state),
            [state](const std::string& candidate) {
                state->events.push_back("validate-public-key");
                return candidate == "ssh-ed25519 AAAATEST remotedesk@test";
            });

    RDP_ASSERT(result.ok);
    RDP_ASSERT(!result.alreadyInstalled);
    RDP_ASSERT(result.verified);
    RDP_ASSERT(state->mode == SshOperationTransportMode::Authenticated);
    RDP_ASSERT(state->targetPinPresent);
    RDP_ASSERT(state->promptDisabled);
    RDP_ASSERT(state->command.find(publicKey) != std::string::npos);
    RDP_ASSERT(state->commandTimeoutMs == 30000);
    const std::vector<std::string> expected {
        "validate-public-key", "factory", "connect", "execute", "disconnect"};
    RDP_ASSERT(state->events == expected);
}

RDP_TEST_CASE(ssh_operation_install_cancellation_after_auth_never_runs_command) {
    auto state = std::make_shared<FakeSshOperationState>();
    auto control = std::make_shared<SshOperationControl>(5007);
    state->onConnect = [control]() {
        RDP_ASSERT(control->cancel(SshOperationCancelReason::User));
    };

    const SshPublicKeyInstallResult result =
        installSshPublicKeyWithTransportForOperation(
            scopedIpv6OperationConfig(), "ssh-ed25519 AAAATEST", control,
            fakeFactory(state), [](const std::string&) { return true; });

    RDP_ASSERT(!result.ok);
    RDP_ASSERT(result.code == ERR_SSH_AUTH_CANCELLED);
    RDP_ASSERT(state->command.empty());
    const std::vector<std::string> expected {
        "factory", "connect", "cancel", "disconnect"};
    RDP_ASSERT(state->events == expected);
}
