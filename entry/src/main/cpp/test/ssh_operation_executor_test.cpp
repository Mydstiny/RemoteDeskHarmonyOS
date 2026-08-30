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
    std::function<bool(remotedesk::net::NetworkGenerationSnapshot)>
        routeCancelled;

    std::string host;
    int port = 0;
    std::string username;
    std::string authMethod;
    SshRoute route;
    std::string proxyType;
    std::string proxyHost;
    int proxyPort = 0;
    std::string proxyUsername;
    std::string proxyAuthMethod;
    std::string proxyPassword;
    std::string proxyPrivateKey;
    std::string proxyPrivateKeyPassphrase;
    std::vector<std::string> proxyResponses;
    std::vector<SshJumpHopHandoff> handoffs;
    SshOperationTransportMode mode = SshOperationTransportMode::ProbeOnly;
    remotedesk::net::NetworkGenerationSnapshot networkSnapshot {};
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
        remotedesk::net::NetworkGenerationSnapshot networkSnapshot,
        SshOperationTransportHostKey& hostKey) override {
        state_->events.push_back("connect");
        state_->host = config.host;
        state_->port = config.port;
        state_->username = config.username;
        state_->authMethod = config.authMethod;
        state_->route = config.sshRoute;
        state_->proxyType = config.sshProxyType;
        state_->proxyHost = config.sshProxyHost;
        state_->proxyPort = config.sshProxyPort;
        state_->proxyUsername = config.sshProxyUsername;
        state_->proxyAuthMethod = config.sshProxyAuthMethod;
        state_->proxyPassword = config.sshProxyPassword;
        state_->proxyPrivateKey = config.sshProxyPrivateKeyPem;
        state_->proxyPrivateKeyPassphrase = config.sshProxyPrivateKeyPassphrase;
        state_->proxyResponses = config.sshProxyKeyboardInteractiveResponses;
        state_->handoffs = config.sshJumpHopHandoffs;
        state_->mode = mode;
        state_->networkSnapshot = networkSnapshot;
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
        const int connectCode = state_->routeCancelled &&
            state_->routeCancelled(networkSnapshot)
                ? ERR_SSH_SESSION_CLOSED : state_->connectCode;
        if (connectCode == 0) {
            hostKey.ok = true;
            hostKey.algorithm = "ssh-ed25519";
            hostKey.fingerprintSha256 = "SHA256:fake";
            hostKey.rawBase64 = "fake-raw";
            hostKey.serverBanner = "SSH-2.0-fake";
        }
        return connectCode;
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
    const std::shared_ptr<FakeSshOperationState>& state,
    std::shared_ptr<SshOperationTransport>* retainedTransport = nullptr) {
    return [state, retainedTransport]() {
        state->events.push_back("factory");
        std::shared_ptr<SshOperationTransport> transport =
            std::make_shared<FakeSshOperationTransport>(state);
        if (retainedTransport) { *retainedTransport = transport; }
        return transport;
    };
}

remotedesk::net::NetworkGenerationSnapshot operationNetworkSnapshot(
    std::uint64_t generation = 7001) {
    return remotedesk::net::NetworkGenerationSnapshot {generation, true};
}

ConnectionConfig operationCredentials() {
    ConnectionConfig config;
    config.username = "alice";
    config.password = "target-password";
    config.authMethod = "kbd-interactive";
    config.privateKeyPem = "target-private-key";
    config.privateKeyPassphrase = "target-passphrase";
    config.sshKeyboardInteractiveResponses = {"target-otp"};
    config.expectedHostKeyRawBase64 = "target-host-key";
    config.sshHostKeyPromptEnabled = true;
    return config;
}

ConnectionConfig directScopedIpv6OperationConfig() {
    ConnectionConfig config = operationCredentials();
    config.host = "fe80::1234%wlan0";
    config.port = 2222;
    config.sshProxyType = "direct";
    config.sshRouteExplicit = true;
    config.sshRoute.schemaVersion = 1;
    config.sshRoute.kind = SshRouteKind::Direct;
    config.sshRoute.endpointHost = config.host;
    config.sshRoute.endpointPort = config.port;
    config.sshRoute.controlId = "direct-scoped-control";
    config.sshRoute.connectTimeoutMs = 12000;
    return config;
}

ConnectionConfig proxyJumpIpv6OperationConfig() {
    ConnectionConfig config = operationCredentials();
    config.host = "2001:db8::40";
    config.port = 2222;
    config.sshProxyType = "ssh_jump";
    config.sshProxyHost = "fe80::30%wlan0";
    config.sshProxyPort = 2201;
    config.sshProxyUsername = "jump-user-0";
    config.sshProxyAuthMethod = "publickey";
    config.sshProxyPrivateKeyPem = "legacy-jump-key";
    config.sshProxyPrivateKeyPassphrase = "legacy-jump-passphrase";
    config.sshProxyKeyboardInteractiveResponses = {"legacy-jump-response"};
    config.sshRouteExplicit = true;
    config.sshRoute.schemaVersion = 1;
    config.sshRoute.kind = SshRouteKind::SshJump;
    config.sshRoute.endpointHost = config.host;
    config.sshRoute.endpointPort = config.port;
    config.sshRoute.controlId = "jump-route-control";
    config.sshRoute.connectTimeoutMs = 13000;
    config.sshRoute.hops.push_back(SshJumpHop {
        "fe80::30%wlan0", 2201, "jump-user-0", "publickey",
        "jump-host-key-0", "", 7000});
    config.sshRoute.hops.push_back(SshJumpHop {
        "2001:db8::31", 2202, "jump-user-1", "password",
        "", "SHA256:jump-host-key-1", 8000});
    SshJumpHopHandoff firstHandoff;
    firstHandoff.privateKeyPem = "jump-private-key-0";
    firstHandoff.privateKeyPassphrase = "jump-passphrase-0";
    config.sshJumpHopHandoffs.push_back(std::move(firstHandoff));
    SshJumpHopHandoff secondHandoff;
    secondHandoff.password = "jump-password-1";
    secondHandoff.keyboardInteractiveResponses = {"jump-response-1"};
    config.sshJumpHopHandoffs.push_back(std::move(secondHandoff));
    return config;
}

bool jumpHopEquals(const SshJumpHop& left, const SshJumpHop& right) {
    return left.host == right.host && left.port == right.port &&
        left.username == right.username && left.authMethod == right.authMethod &&
        left.expectedHostKeyRawBase64 == right.expectedHostKeyRawBase64 &&
        left.expectedHostKeyFingerprintSha256 ==
            right.expectedHostKeyFingerprintSha256 &&
        left.connectTimeoutMs == right.connectTimeoutMs;
}

bool routeEquals(const SshRoute& left, const SshRoute& right) {
    if (left.schemaVersion != right.schemaVersion || left.kind != right.kind ||
        left.endpointHost != right.endpointHost ||
        left.endpointPort != right.endpointPort ||
        left.controlId != right.controlId ||
        left.connectTimeoutMs != right.connectTimeoutMs ||
        left.hops.size() != right.hops.size()) {
        return false;
    }
    for (std::size_t index = 0; index < left.hops.size(); ++index) {
        if (!jumpHopEquals(left.hops[index], right.hops[index])) { return false; }
    }
    return true;
}

bool handoffEquals(const SshJumpHopHandoff& left,
                   const SshJumpHopHandoff& right) {
    return left.password == right.password &&
        left.privateKeyPem == right.privateKeyPem &&
        left.privateKeyPassphrase == right.privateKeyPassphrase &&
        left.keyboardInteractiveResponses == right.keyboardInteractiveResponses;
}

bool handoffsEqual(const std::vector<SshJumpHopHandoff>& left,
                   const std::vector<SshJumpHopHandoff>& right) {
    if (left.size() != right.size()) { return false; }
    for (std::size_t index = 0; index < left.size(); ++index) {
        if (!handoffEquals(left[index], right[index])) { return false; }
    }
    return true;
}

} // namespace

RDP_TEST_CASE(ssh_operation_probe_keeps_scoped_ipv6_route_but_strips_target_auth) {
    auto state = std::make_shared<FakeSshOperationState>();
    const ConnectionConfig config = directScopedIpv6OperationConfig();
    auto control = std::make_shared<SshOperationControl>(5001);
    std::shared_ptr<SshOperationTransport> retainedTransport;

    const SshHostKeyInfo result = probeSshHostKeyWithTransportForOperation(
        config, control, operationNetworkSnapshot(),
        fakeFactory(state, &retainedTransport));

    RDP_ASSERT(result.ok);
    RDP_ASSERT(result.host == "fe80::1234%wlan0");
    RDP_ASSERT(result.port == 2222);
    RDP_ASSERT(result.fingerprintSha256 == "SHA256:fake");
    RDP_ASSERT(state->host == "fe80::1234%wlan0");
    RDP_ASSERT(state->port == 2222);
    RDP_ASSERT(state->username == "probe");
    RDP_ASSERT(state->authMethod == "password");
    RDP_ASSERT(routeEquals(state->route, config.sshRoute));
    RDP_ASSERT(state->proxyType == "direct");
    RDP_ASSERT(state->mode == SshOperationTransportMode::ProbeOnly);
    RDP_ASSERT(state->networkSnapshot.generation == 7001);
    RDP_ASSERT(state->networkSnapshot.available);
    RDP_ASSERT(state->targetPasswordEmpty);
    RDP_ASSERT(state->targetPrivateKeyEmpty);
    RDP_ASSERT(state->targetPassphraseEmpty);
    RDP_ASSERT(state->targetResponsesEmpty);
    RDP_ASSERT(!state->targetPinPresent);
    RDP_ASSERT(state->promptDisabled);
    RDP_ASSERT(!state->proxyPasswordPresent);
    RDP_ASSERT(!state->jumpSecretPresent);
    const std::vector<std::string> expected {
        "factory", "connect", "disconnect"};
    RDP_ASSERT(state->events == expected);
    RDP_ASSERT(retainedTransport != nullptr);
    RDP_ASSERT(control->cancel(SshOperationCancelReason::User));
    RDP_ASSERT(state->cancelRequests == 0);
    RDP_ASSERT(state->events == expected);
}

RDP_TEST_CASE(ssh_operation_auth_requires_host_key_before_validation_or_transport) {
    auto state = std::make_shared<FakeSshOperationState>();
    ConnectionConfig config = proxyJumpIpv6OperationConfig();
    config.expectedHostKeyRawBase64.clear();
    int validationCalls = 0;
    auto control = std::make_shared<SshOperationControl>(5002);

    const SshAuthTestResult result = testSshKeyAuthWithTransportForOperation(
        config, control, operationNetworkSnapshot(), fakeFactory(state),
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
    const ConnectionConfig config = proxyJumpIpv6OperationConfig();
    auto control = std::make_shared<SshOperationControl>(5003);

    const SshAuthTestResult result = testSshKeyAuthWithTransportForOperation(
        config, control, operationNetworkSnapshot(), fakeFactory(state),
        [state](const std::string& privateKey, const std::string& passphrase) {
            state->events.push_back("validate-private-key");
            return SshOperationPrivateKeyValidation {
                privateKey == "target-private-key" &&
                    passphrase == "target-passphrase",
                "unexpected private key"};
        });

    RDP_ASSERT(result.ok);
    RDP_ASSERT(state->host == config.host);
    RDP_ASSERT(state->port == config.port);
    RDP_ASSERT(state->username == config.username);
    RDP_ASSERT(state->authMethod == "publickey");
    RDP_ASSERT(routeEquals(state->route, config.sshRoute));
    RDP_ASSERT(state->route.hops.size() == 2);
    RDP_ASSERT(state->route.hops[0].host == "fe80::30%wlan0");
    RDP_ASSERT(state->route.hops[1].host == "2001:db8::31");
    RDP_ASSERT(state->proxyType == config.sshProxyType);
    RDP_ASSERT(state->proxyHost == config.sshProxyHost);
    RDP_ASSERT(state->proxyPort == config.sshProxyPort);
    RDP_ASSERT(state->proxyUsername == config.sshProxyUsername);
    RDP_ASSERT(state->proxyAuthMethod == config.sshProxyAuthMethod);
    RDP_ASSERT(state->proxyPassword == config.sshProxyPassword);
    RDP_ASSERT(state->proxyPrivateKey == config.sshProxyPrivateKeyPem);
    RDP_ASSERT(state->proxyPrivateKeyPassphrase ==
        config.sshProxyPrivateKeyPassphrase);
    RDP_ASSERT(state->proxyResponses ==
        config.sshProxyKeyboardInteractiveResponses);
    RDP_ASSERT(handoffsEqual(state->handoffs, config.sshJumpHopHandoffs));
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
            directScopedIpv6OperationConfig(), control,
            operationNetworkSnapshot(), fakeFactory(state));

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
            directScopedIpv6OperationConfig(), control,
            operationNetworkSnapshot(), fakeFactory(state));

        RDP_ASSERT(!result.ok);
        RDP_ASSERT(result.errorCode == ERR_SSH_CONNECT_TIMEOUT);
        RDP_ASSERT(state->cancelRequests == 1);
    }
}

RDP_TEST_CASE(ssh_operation_install_authenticates_before_authorized_keys_command) {
    auto state = std::make_shared<FakeSshOperationState>();
    const ConnectionConfig config = proxyJumpIpv6OperationConfig();
    auto control = std::make_shared<SshOperationControl>(5006);
    const std::string publicKey = "ssh-ed25519 AAAATEST remotedesk@test";

    const SshPublicKeyInstallResult result =
        installSshPublicKeyWithTransportForOperation(
            config, publicKey, control, operationNetworkSnapshot(),
            fakeFactory(state),
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
            proxyJumpIpv6OperationConfig(), "ssh-ed25519 AAAATEST", control,
            operationNetworkSnapshot(), fakeFactory(state),
            [](const std::string&) { return true; });

    RDP_ASSERT(!result.ok);
    RDP_ASSERT(result.code == ERR_SSH_AUTH_CANCELLED);
    RDP_ASSERT(state->command.empty());
    const std::vector<std::string> expected {
        "factory", "connect", "cancel", "disconnect"};
    RDP_ASSERT(state->events == expected);
}

RDP_TEST_CASE(ssh_operation_install_keeps_queue_generation_before_mutation) {
    auto state = std::make_shared<FakeSshOperationState>();
    auto control = std::make_shared<SshOperationControl>(5008);
    remotedesk::net::NetworkGenerationFence fence(8100, true);
    const remotedesk::net::NetworkGenerationSnapshot admitted = fence.snapshot();
    state->onConnect = [&fence]() {
        RDP_ASSERT(fence.update(true, 8101));
    };
    state->routeCancelled = [&fence](
        remotedesk::net::NetworkGenerationSnapshot networkSnapshot) {
        return fence.shouldCancel(networkSnapshot);
    };

    const SshPublicKeyInstallResult result =
        installSshPublicKeyWithTransportForOperation(
            proxyJumpIpv6OperationConfig(), "ssh-ed25519 AAAATEST", control,
            admitted, fakeFactory(state),
            [](const std::string&) { return true; });

    RDP_ASSERT(!result.ok);
    RDP_ASSERT(result.code == ERR_SSH_SESSION_CLOSED);
    RDP_ASSERT(state->networkSnapshot.generation == 8100);
    RDP_ASSERT(state->networkSnapshot.available);
    RDP_ASSERT(state->command.empty());
    const std::vector<std::string> expected {
        "factory", "connect", "disconnect"};
    RDP_ASSERT(state->events == expected);
}
