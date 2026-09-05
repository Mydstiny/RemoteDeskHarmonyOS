#include "common/network_generation_fence.h"
#include "vnc/vnc_network_recovery_policy.h"
#include "vnc/vnc_rfb_engine.h"
#include "vnc/vnc_transport.h"
#include "test_runner.h"

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <netinet/in.h>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>

RDP_TEST_CASE(vnc_network_recovery_rejects_stale_and_unowned_events) {
    VncNetworkRecoveryPolicy policy;

    RDP_ASSERT(!policy.onNetworkChanged(false, 7).accepted);
    RDP_ASSERT_EQ(policy.networkGeneration(), static_cast<uint64_t>(7));
    RDP_ASSERT(!policy.networkAvailable());

    const uint64_t owner = policy.admitConnectionOwner();
    RDP_ASSERT(policy.isCurrent(owner));
    RDP_ASSERT(!policy.isCurrent(owner, true));
    RDP_ASSERT(!policy.onNetworkChanged(true, 7).accepted);
    RDP_ASSERT(!policy.onNetworkChanged(true, 6).accepted);

    const VncNetworkRecoveryAction restored =
        policy.onNetworkChanged(true, 8);
    RDP_ASSERT(restored.accepted);
    RDP_ASSERT(restored.cancelTransport);
    RDP_ASSERT(restored.reconnectAfterRetirement);
    RDP_ASSERT_EQ(restored.networkGeneration, static_cast<uint64_t>(8));
    RDP_ASSERT(policy.isCurrent(restored.token, true));
}

RDP_TEST_CASE(vnc_network_recovery_waits_offline_without_reconnect) {
    VncNetworkRecoveryPolicy policy;
    policy.admitConnectionOwner();

    const VncNetworkRecoveryAction unavailable =
        policy.onNetworkChanged(false, 20);
    RDP_ASSERT(unavailable.accepted);
    RDP_ASSERT(unavailable.cancelTransport);
    RDP_ASSERT(!unavailable.reconnectAfterRetirement);
    RDP_ASSERT(policy.isCurrent(unavailable.token));
    RDP_ASSERT(!policy.isCurrent(unavailable.token, true));

    const VncNetworkRecoveryAction available =
        policy.onNetworkChanged(true, 21);
    RDP_ASSERT(available.accepted);
    RDP_ASSERT(available.reconnectAfterRetirement);
    RDP_ASSERT(!policy.isCurrent(unavailable.token));
    RDP_ASSERT(policy.isCurrent(available.token, true));
}

RDP_TEST_CASE(vnc_network_recovery_user_action_retires_queued_reconnect) {
    VncNetworkRecoveryPolicy policy;
    policy.admitConnectionOwner();
    const VncNetworkRecoveryAction action =
        policy.onNetworkChanged(true, 30);
    RDP_ASSERT(action.accepted);

    std::mutex mutex;
    std::condition_variable condition;
    bool workerReady = false;
    bool releaseWorker = false;
    std::atomic<bool> reconnectAdmitted {true};
    std::thread worker([&]() {
        {
            std::lock_guard<std::mutex> lock(mutex);
            workerReady = true;
        }
        condition.notify_all();
        {
            std::unique_lock<std::mutex> lock(mutex);
            condition.wait(lock, [&]() { return releaseWorker; });
        }
        reconnectAdmitted.store(
            policy.isCurrent(action.token, true), std::memory_order_release);
    });
    {
        std::unique_lock<std::mutex> lock(mutex);
        condition.wait(lock, [&]() { return workerReady; });
    }

    const uint64_t retired = policy.retireConnectionOwner();
    RDP_ASSERT(policy.isRetired(retired));
    {
        std::lock_guard<std::mutex> lock(mutex);
        releaseWorker = true;
    }
    condition.notify_all();
    worker.join();

    RDP_ASSERT(!reconnectAdmitted.load(std::memory_order_acquire));
}

RDP_TEST_CASE(vnc_network_recovery_new_connect_invalidates_old_action) {
    VncNetworkRecoveryPolicy policy;
    policy.admitConnectionOwner();
    const VncNetworkRecoveryAction oldAction =
        policy.onNetworkChanged(true, 40);
    RDP_ASSERT(oldAction.accepted);

    const uint64_t replacement = policy.admitConnectionOwner();
    RDP_ASSERT(!policy.isCurrent(oldAction.token));
    RDP_ASSERT(policy.isCurrent(replacement, true));

    const VncNetworkRecoveryAction nextAction =
        policy.onNetworkChanged(true, 41);
    RDP_ASSERT(nextAction.accepted);
    RDP_ASSERT(policy.isCurrent(nextAction.token, true));
}

RDP_TEST_CASE(vnc_network_recovery_terminal_retirement_is_exact) {
    VncNetworkRecoveryPolicy policy;
    const uint64_t first = policy.admitConnectionOwner();
    const uint64_t replacement = policy.admitConnectionOwner();

    RDP_ASSERT(!policy.retireConnectionOwnerIfCurrent(first));
    RDP_ASSERT(policy.isCurrent(replacement));
    RDP_ASSERT(policy.retireConnectionOwnerIfCurrent(replacement));
    RDP_ASSERT(!policy.isCurrent(replacement));
}

RDP_TEST_CASE(vnc_transport_rejects_a_retired_network_generation_before_dns) {
    remotedesk::net::NetworkGenerationFence& fence =
        remotedesk::net::ProcessNetworkGenerationFence();
    const remotedesk::net::NetworkGenerationSnapshot captured =
        fence.snapshot();
    RDP_ASSERT(captured.generation != 0);
    RDP_ASSERT(fence.update(true, captured.generation + 1));

    VncTransportConfig config;
    config.host = "network-generation.invalid";
    config.port = 5900;
    config.transport = "direct_tcp";
    config.networkGeneration = captured.generation;
    config.cancelled = std::make_shared<std::atomic_bool>(false);
    VncTransport transport;
    std::string error;

    RDP_ASSERT(!transport.connect(config, error));
    RDP_ASSERT(error == "E-VNC-CERT-CANCELLED");
}

RDP_TEST_CASE(vnc_transport_cancels_established_read_and_write_generation) {
    int readSockets[2] = {-1, -1};
    int writeSockets[2] = {-1, -1};
    RDP_ASSERT_EQ(::socketpair(AF_UNIX, SOCK_STREAM, 0, readSockets), 0);
    RDP_ASSERT_EQ(::socketpair(AF_UNIX, SOCK_STREAM, 0, writeSockets), 0);

    remotedesk::net::NetworkGenerationFence& fence =
        remotedesk::net::ProcessNetworkGenerationFence();
    const remotedesk::net::NetworkGenerationSnapshot captured =
        fence.snapshot();
    VncTransport readTransport;
    VncTransport writeTransport;
    readTransport.adoptConnectedSocketForTesting(
        readSockets[0], captured.generation);
    writeTransport.adoptConnectedSocketForTesting(
        writeSockets[0], captured.generation);
    readSockets[0] = -1;
    writeSockets[0] = -1;
    RDP_ASSERT(fence.update(true, captured.generation + 1));

    uint8_t byte = 0;
    std::string readError;
    RDP_ASSERT(!readTransport.readExact(&byte, 1, 1000, readError));
    RDP_ASSERT(readError == "E-VNC-CERT-CANCELLED");

    const uint8_t payload = 0x5A;
    std::string writeError;
    RDP_ASSERT(!writeTransport.writeAll(&payload, 1, writeError));
    RDP_ASSERT(writeError == "E-VNC-CERT-CANCELLED");

    readTransport.close();
    writeTransport.close();
    ::close(readSockets[1]);
    ::close(writeSockets[1]);
}

RDP_TEST_CASE(vnc_transport_happy_eyeballs_winner_is_generation_fenced) {
    const int listener = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    RDP_ASSERT(listener >= 0);
    sockaddr_in address {};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    RDP_ASSERT_EQ(::bind(listener,
                         reinterpret_cast<sockaddr*>(&address),
                         sizeof(address)), 0);
    RDP_ASSERT_EQ(::listen(listener, 1), 0);
    socklen_t addressLength = sizeof(address);
    RDP_ASSERT_EQ(::getsockname(
        listener, reinterpret_cast<sockaddr*>(&address),
        &addressLength), 0);

    remotedesk::net::NetworkGenerationFence& fence =
        remotedesk::net::ProcessNetworkGenerationFence();
    const remotedesk::net::NetworkGenerationSnapshot captured =
        fence.snapshot();
    VncTransportConfig config;
    config.host = "127.0.0.1";
    config.port = ntohs(address.sin_port);
    config.transport = "direct_tcp";
    config.networkGeneration = captured.generation;
    config.afterConnectRestoreForTesting = [&fence, captured]() {
        RDP_ASSERT(fence.update(true, captured.generation + 1));
    };
    VncTransport transport;
    std::string error;

    RDP_ASSERT(!transport.connect(config, error));
    RDP_ASSERT(error == "E-VNC-CERT-CANCELLED");
    RDP_ASSERT(!transport.isOpen());
    ::close(listener);
}

RDP_TEST_CASE(vnc_engine_releases_callback_owner_cycle_after_worker_exit) {
    ConnectionConfig config;
    config.vncSecurityPolicy = "secure_only";
    config.vncTls = false;

    auto holder =
        std::make_shared<std::shared_ptr<VncRfbEngine>>();
    std::shared_ptr<VncRfbEngine> engine = std::make_shared<VncRfbEngine>(
        config,
        [holder](const VideoFrame&) {
            (void)holder;
        },
        nullptr, nullptr);
    *holder = engine;
    const std::weak_ptr<VncRfbEngine> weakEngine = engine;

    RDP_ASSERT_EQ(engine->start(), 0);
    engine->waitForWorkerDone();
    engine->joinAfterWorkerDone();
    engine.reset();
    holder.reset();

    RDP_ASSERT(weakEngine.expired());
}
