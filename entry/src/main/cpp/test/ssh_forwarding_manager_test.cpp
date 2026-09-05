#include "test_runner.h"
#include "ssh/ssh_forwarding_manager.h"

namespace {

SshForwardingConfig localConfig(const char* id = "local-shell") {
    SshForwardingConfig config;
    config.id = id;
    config.mode = SshForwardingMode::Local;
    config.bindPort = 8022;
    config.targetHost = "10.0.0.8";
    config.targetPort = 22;
    config.maxConnections = 2;
    return config;
}

} // namespace

RDP_TEST_CASE(ssh_forwarding_manager_validates_modes_and_bindings) {
    SshForwardingConfig config = localConfig();
    RDP_ASSERT(SshForwardingManager::validateAndNormalize(config) == SshForwardingResult::Ok);
    RDP_ASSERT(config.bindHost == "127.0.0.1");

    config.bindHost = "0.0.0.0";
    RDP_ASSERT(SshForwardingManager::validateAndNormalize(config) ==
               SshForwardingResult::PublicBindNotAllowed);
    config.allowPublicBind = true;
    RDP_ASSERT(SshForwardingManager::validateAndNormalize(config) == SshForwardingResult::Ok);

    config = localConfig();
    config.bindHost = "127.example.com";
    RDP_ASSERT(SshForwardingManager::validateAndNormalize(config) ==
               SshForwardingResult::PublicBindNotAllowed);
    config.bindHost = "127.0.0.2";
    RDP_ASSERT(SshForwardingManager::validateAndNormalize(config) ==
               SshForwardingResult::Ok);

    config = {};
    config.id = "dynamic";
    config.mode = SshForwardingMode::Dynamic;
    config.bindPort = 1080;
    RDP_ASSERT(SshForwardingManager::validateAndNormalize(config) == SshForwardingResult::Ok);
    config.targetHost = "unexpected";
    RDP_ASSERT(SshForwardingManager::validateAndNormalize(config) ==
               SshForwardingResult::DynamicTargetSet);
}

RDP_TEST_CASE(ssh_forwarding_manager_rejects_invalid_limits_and_profiles) {
    SshForwardingConfig config = localConfig();
    config.bindPort = 0;
    RDP_ASSERT(SshForwardingManager::validateAndNormalize(config) ==
               SshForwardingResult::InvalidBindPort);

    config = localConfig();
    config.maxConnections = SshForwardingManager::kMaxConnections + 1;
    RDP_ASSERT(SshForwardingManager::validateAndNormalize(config) ==
               SshForwardingResult::InvalidConnectionLimit);

    SshForwardingManager manager;
    RDP_ASSERT(manager.upsert(localConfig()) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.upsert(localConfig()) == SshForwardingResult::Ok);
    SshForwardingConfig duplicate = localConfig("other");
    RDP_ASSERT(manager.upsert(duplicate) == SshForwardingResult::Ok);
    RDP_ASSERT_EQ(manager.size(), static_cast<size_t>(2));
}

RDP_TEST_CASE(ssh_forwarding_manager_enforces_endpoint_v2_without_truncation) {
    SshForwardingConfig config = localConfig();
    config.bindHost = "[::1]";
    config.targetHost = "[2001:0DB8:0:0::20]";
    RDP_ASSERT(SshForwardingManager::validateAndNormalize(config) ==
               SshForwardingResult::Ok);
    RDP_ASSERT(config.bindHost == "::1");
    RDP_ASSERT(config.targetHost == "2001:db8::20");

    config = localConfig();
    config.targetHost = "fe80::20%wlan0";
    RDP_ASSERT(SshForwardingManager::validateAndNormalize(config) ==
               SshForwardingResult::InvalidTargetHost);

    config = localConfig();
    config.mode = SshForwardingMode::Remote;
    config.targetHost = "fe80::20%wlan0";
    RDP_ASSERT(SshForwardingManager::validateAndNormalize(config) ==
               SshForwardingResult::Ok);
    RDP_ASSERT(config.targetHost == "fe80::20%wlan0");
    config.bindHost = "fe80::10%wlan0";
    config.allowPublicBind = true;
    RDP_ASSERT(SshForwardingManager::validateAndNormalize(config) ==
               SshForwardingResult::InvalidBindHost);

    config = localConfig();
    config.targetHost = "fe80::20%12";
    RDP_ASSERT(SshForwardingManager::validateAndNormalize(config) ==
               SshForwardingResult::InvalidTargetHost);
    config = localConfig();
    config.targetHost = "target.example:22";
    RDP_ASSERT(SshForwardingManager::validateAndNormalize(config) ==
               SshForwardingResult::InvalidTargetHost);
    config = localConfig();
    config.id.assign(97U, 'i');
    RDP_ASSERT(SshForwardingManager::validateAndNormalize(config) ==
               SshForwardingResult::InvalidId);
    config = localConfig();
    config.targetHost.assign(256U, 'a');
    RDP_ASSERT(SshForwardingManager::validateAndNormalize(config) ==
               SshForwardingResult::InvalidTargetHost);

    std::string runtimeHost = "Runtime.Example.";
    RDP_ASSERT(SshForwardingManager::normalizeRuntimeTargetHost(runtimeHost));
    RDP_ASSERT(runtimeHost == "runtime.example");
    runtimeHost = "runtime.example:22";
    RDP_ASSERT(!SshForwardingManager::normalizeRuntimeTargetHost(runtimeHost));
}

RDP_TEST_CASE(ssh_forwarding_manager_enforces_generation_and_connection_limit) {
    SshForwardingManager manager;
    SshForwardingConfig config = localConfig();
    RDP_ASSERT(manager.upsert(config) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.start(config.id, 0) == SshForwardingResult::MissingGeneration);
    RDP_ASSERT(manager.start(config.id, 10) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.markListening(config.id, 9) == SshForwardingResult::StaleSession);
    RDP_ASSERT(manager.markListening(config.id, 10, "::1", 8022, 10) ==
               SshForwardingResult::Ok);
    SshForwardingSnapshot listeningSnapshot;
    RDP_ASSERT(manager.snapshot(config.id, listeningSnapshot));
    RDP_ASSERT(listeningSnapshot.actualBindHost == "::1");
    RDP_ASSERT_EQ(listeningSnapshot.actualBindPort, 8022);
    RDP_ASSERT_EQ(listeningSnapshot.actualBindFamily, 10);
    RDP_ASSERT(manager.acquireConnection(config.id, 10) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.acquireConnection(config.id, 10) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.acquireConnection(config.id, 10) == SshForwardingResult::ConnectionLimit);
    RDP_ASSERT(manager.releaseConnection(config.id, 9) == SshForwardingResult::StaleSession);
    RDP_ASSERT(manager.releaseConnection(config.id, 10) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.requestStop(config.id, 10) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.acquireConnection(config.id, 10) == SshForwardingResult::InvalidState);
    RDP_ASSERT(manager.completeStop(config.id) == SshForwardingResult::Busy);
    RDP_ASSERT(manager.releaseConnection(config.id, 10) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.completeStop(config.id) == SshForwardingResult::Ok);

    SshForwardingSnapshot snapshot;
    RDP_ASSERT(manager.snapshot(config.id, snapshot));
    RDP_ASSERT(snapshot.state == SshForwardingState::Stopped);
    RDP_ASSERT_EQ(snapshot.sessionGeneration, 0U);
    RDP_ASSERT_EQ(snapshot.activeConnections, 0U);
    RDP_ASSERT(snapshot.actualBindHost.empty());
    RDP_ASSERT_EQ(snapshot.actualBindPort, 0);
    RDP_ASSERT_EQ(snapshot.actualBindFamily, 0);
}

RDP_TEST_CASE(ssh_forwarding_manager_supports_remote_and_dynamic_runtime_profiles) {
    SshForwardingManager manager;

    SshForwardingConfig remote = localConfig("remote-shell");
    remote.mode = SshForwardingMode::Remote;
    remote.bindHost = "127.0.0.1";
    remote.bindPort = 9022;
    remote.targetHost = "127.0.0.1";
    remote.targetPort = 22;
    RDP_ASSERT(manager.upsert(remote) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.start(remote.id, 41) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.markListening(remote.id, 41) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.acquireConnection(remote.id, 41) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.requestStop(remote.id, 41) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.releaseConnection(remote.id, 41) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.completeStop(remote.id) == SshForwardingResult::Ok);

    SshForwardingConfig dynamic;
    dynamic.id = "dynamic-shell";
    dynamic.mode = SshForwardingMode::Dynamic;
    dynamic.bindPort = 1080;
    dynamic.maxConnections = 1;
    RDP_ASSERT(manager.upsert(dynamic) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.start(dynamic.id, 42) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.markListening(dynamic.id, 42) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.acquireConnection(dynamic.id, 42) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.acquireConnection(dynamic.id, 42) ==
               SshForwardingResult::ConnectionLimit);
    RDP_ASSERT(manager.releaseConnection(dynamic.id, 42) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.requestStop(dynamic.id, 42) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.completeStop(dynamic.id) == SshForwardingResult::Ok);
}

RDP_TEST_CASE(ssh_forwarding_manager_rejects_mutation_while_active) {
    SshForwardingManager manager;
    SshForwardingConfig config = localConfig();
    RDP_ASSERT(manager.upsert(config) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.start(config.id, 20) == SshForwardingResult::Ok);
    SshForwardingConfig changed = config;
    changed.targetPort = 2222;
    RDP_ASSERT(manager.upsert(changed) == SshForwardingResult::Busy);
    RDP_ASSERT(manager.remove(config.id) == SshForwardingResult::Busy);
    RDP_ASSERT(manager.requestStop(config.id, 20) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.completeStop(config.id) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.remove(config.id) == SshForwardingResult::Ok);
}

RDP_TEST_CASE(ssh_forwarding_manager_rejects_replace_with_failed_connections) {
    SshForwardingManager manager;
    SshForwardingConfig config = localConfig("failed-active");
    RDP_ASSERT(manager.upsert(config) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.start(config.id, 25) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.markListening(config.id, 25) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.acquireConnection(config.id, 25) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.fail(config.id, 25, -9001) == SshForwardingResult::Ok);

    SshForwardingConfig replacement = config;
    replacement.targetPort = 2222;
    RDP_ASSERT(manager.upsert(replacement) == SshForwardingResult::Busy);

    RDP_ASSERT(manager.releaseConnection(config.id, 25) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.completeStop(config.id) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.upsert(replacement) == SshForwardingResult::Ok);
}

RDP_TEST_CASE(ssh_forwarding_manager_resets_runtime_but_keeps_profiles) {
    SshForwardingManager manager;
    SshForwardingConfig config = localConfig("persistent");
    RDP_ASSERT(manager.upsert(config) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.start(config.id, 30) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.markListening(config.id, 30) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.acquireConnection(config.id, 30) == SshForwardingResult::Ok);

    manager.resetRuntimeAfterTransportClose();

    SshForwardingSnapshot snapshot;
    RDP_ASSERT(manager.snapshot(config.id, snapshot));
    RDP_ASSERT(snapshot.state == SshForwardingState::Stopped);
    RDP_ASSERT_EQ(snapshot.sessionGeneration, 0U);
    RDP_ASSERT_EQ(snapshot.activeConnections, 0U);
    RDP_ASSERT(snapshot.config.id == "persistent");
    RDP_ASSERT(manager.start(config.id, 0) == SshForwardingResult::MissingGeneration);
    RDP_ASSERT(manager.start(config.id, 31) == SshForwardingResult::Ok);
}

RDP_TEST_CASE(ssh_forwarding_manager_rejects_late_release_after_transport_reset) {
    SshForwardingManager manager;
    SshForwardingConfig config = localConfig("late-release");
    RDP_ASSERT(manager.upsert(config) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.start(config.id, 60) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.markListening(config.id, 60) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.acquireConnection(config.id, 60) == SshForwardingResult::Ok);

    manager.resetRuntimeAfterTransportClose();

    // A callback from the old reactor must not decrement the new runtime's
    // counter or become valid after the transport generation is reset.
    RDP_ASSERT(manager.releaseConnection(config.id, 60) ==
               SshForwardingResult::StaleSession);
    RDP_ASSERT(manager.start(config.id, 61) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.markListening(config.id, 61) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.acquireConnection(config.id, 61) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.releaseConnection(config.id, 61) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.requestStop(config.id, 61) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.completeStop(config.id) == SshForwardingResult::Ok);
}

RDP_TEST_CASE(ssh_forwarding_manager_enforces_byte_budget_and_expiry) {
    SshForwardingManager manager;
    SshForwardingConfig config = localConfig("budgeted");
    config.maxBytes = 8;
    config.expiresAtMs = 0;
    RDP_ASSERT(manager.upsert(config) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.start(config.id, 50) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.markListening(config.id, 50) == SshForwardingResult::Ok);
    RDP_ASSERT_EQ(manager.remainingBytes(config.id, 50), 8U);
    RDP_ASSERT(manager.recordBytes(config.id, 50, 5) == SshForwardingResult::Ok);
    RDP_ASSERT_EQ(manager.remainingBytes(config.id, 50), 3U);
    RDP_ASSERT(manager.recordBytes(config.id, 50, 3) == SshForwardingResult::Ok);
    RDP_ASSERT_EQ(manager.remainingBytes(config.id, 50), 0U);
    RDP_ASSERT(manager.checkRuntimeLimits(config.id, 50) == SshForwardingResult::ByteLimit);
    SshForwardingSnapshot snapshot;
    RDP_ASSERT(manager.snapshot(config.id, snapshot));
    RDP_ASSERT(snapshot.state == SshForwardingState::Failed);
    RDP_ASSERT_EQ(snapshot.transferredBytes, 8U);
    RDP_ASSERT_EQ(snapshot.config.maxBytes, 8U);

    SshForwardingConfig expired = localConfig("expired");
    expired.expiresAtMs = 1;
    RDP_ASSERT(manager.upsert(expired) == SshForwardingResult::Ok);
    RDP_ASSERT(manager.start(expired.id, 51) == SshForwardingResult::Expired);
}
