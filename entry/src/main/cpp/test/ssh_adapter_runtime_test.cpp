#include "test_runner.h"

#include "common/network_generation_fence.h"
#include "ssh/ssh_adapter.h"
#include "ssh/ssh_libssh2_session.h"
#include "ssh/ssh_sensitive_buffer.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <future>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#ifndef REMOTEDESK_NATIVE_SOURCE_DIR
#error "REMOTEDESK_NATIVE_SOURCE_DIR is required for SSH runtime tests"
#endif

class SshAdapterRuntimeTestAccess final {
public:
    static void preparePartialSession(
        SshAdapter& adapter, LIBSSH2_SESSION* session, int socketFd,
        remotedesk::net::NetworkGenerationSnapshot snapshot) {
        adapter.session_ = session;
        adapter.sockFd_ = socketFd;
        adapter.connectNetworkSnapshot_ = snapshot;
        adapter.reactorThreadId_ = std::this_thread::get_id();
        adapter.setConnectRouteDeadline(
            std::chrono::steady_clock::now() + std::chrono::seconds(2));
    }

    static int handshakePartialSession(SshAdapter& adapter) {
        return adapter.handshakeSessionOnRoute(
            adapter.session_, adapter.sockFd_, 1);
    }

    static void teardownPartialSession(SshAdapter& adapter) {
        adapter.teardownSessionHandlesLocked("runtime test teardown");
        adapter.reactorThreadId_ = std::thread::id {};
    }

    static void setHandshakeEagainHook(
        SshAdapter& adapter, std::function<void()> hook) {
        adapter.handshakeEagainHookForTesting_ = std::move(hook);
    }

    static void setKeyboardInteractiveRoundHook(
        SshAdapter& adapter, std::function<void()> hook) {
        adapter.keyboardInteractiveRoundHookForTesting_ = std::move(hook);
    }

    static void setChannelReadHook(
        SshAdapter& adapter, std::function<void(ssize_t)> hook) {
        adapter.channelReadHookForTesting_ = std::move(hook);
    }

    static void setTransportHooks(
        SshAdapter& adapter, std::function<void()> shutdownHook,
        std::function<void()> closeHook) {
        adapter.transportShutdownHookForTesting_ = std::move(shutdownHook);
        adapter.transportCloseHookForTesting_ = std::move(closeHook);
    }

    static int quarantineConnectedSession(
        SshAdapter& adapter,
        SshLibssh2SessionFreeFunction firstFree,
        int& retiredDescriptor) {
        adapter.authPromptBroker_.cancelAll();
        adapter.rejectTerminalInput();
        adapter.requestConnectCancel();
        adapter.stopTerminalInput();
        adapter.stopReader();
        adapter.stopSshJumpRelay();

        std::lock_guard<std::recursive_mutex> lifecycleLock(
            adapter.lifecycleMutex_);
        std::lock_guard<std::mutex> sftpLock(adapter.sftpOperationMutex_);
        std::unique_lock<std::mutex> sessionLock(adapter.sessionMutex_);
        std::lock_guard<std::mutex> writeFence(
            adapter.inputWriteFenceMutex_);
        if (adapter.session_ == nullptr || adapter.channel_ == nullptr ||
            adapter.sftp_ != nullptr || adapter.sockFd_ < 0) {
            return LIBSSH2_ERROR_INVAL;
        }

        retiredDescriptor = adapter.sockFd_;
        (void)::shutdown(retiredDescriptor, SHUT_RDWR);
        const int result = sshRetireTrackedLibssh2SessionWith(
            adapter.session_, firstFree);
        if (adapter.session_ != nullptr) {
            return result;
        }

        // The quarantined session still owns the live channel. Clear only the
        // adapter aliases so its destructor cannot free the same objects.
        adapter.channel_ = nullptr;
        adapter.sockFd_ = -1;
        ::close(retiredDescriptor);
        adapter.ioGeneration_.fetch_add(1, std::memory_order_acq_rel);
        adapter.authenticated_ = false;
        adapter.state_.store(
            ConnectionState::DISCONNECTED, std::memory_order_release);
        adapter.reactorThreadId_ = std::thread::id {};
        return result;
    }
};

namespace {

using namespace std::chrono_literals;

int returnRuntimeSessionFreeEagain(LIBSSH2_SESSION*) {
    return LIBSSH2_ERROR_EAGAIN;
}

remotedesk::net::NetworkGenerationSnapshot freshNetworkSnapshot() {
    auto& fence = remotedesk::net::ProcessNetworkGenerationFence();
    const auto current = fence.snapshot();
    const uint64_t nextGeneration =
        current.generation == 0 ? 1 : current.generation + 1;
    RDP_ASSERT(nextGeneration > current.generation);
    RDP_ASSERT(fence.update(true, nextGeneration));
    return fence.snapshot();
}

size_t drainSocket(int socketFd) {
    size_t total = 0;
    char buffer[4096];
    while (true) {
        const ssize_t received = ::recv(socketFd, buffer, sizeof(buffer), 0);
        if (received > 0) {
            total += static_cast<size_t>(received);
            continue;
        }
        if (received < 0 && errno == EINTR) {
            continue;
        }
        return total;
    }
}

bool setNonBlocking(int socketFd) {
    const int flags = ::fcntl(socketFd, F_GETFL, 0);
    return flags >= 0 &&
        ::fcntl(socketFd, F_SETFL, flags | O_NONBLOCK) == 0;
}

std::string temporaryPath(const char* label) {
    std::string pattern = std::string("/private/tmp/") + label + ".XXXXXX";
    std::vector<char> writable(pattern.begin(), pattern.end());
    writable.push_back('\0');
    const int descriptor = ::mkstemp(writable.data());
    if (descriptor < 0) {
        return {};
    }
    ::close(descriptor);
    ::unlink(writable.data());
    return std::string(writable.data());
}

int reserveIpv6LoopbackPort() {
    const int socketFd = ::socket(AF_INET6, SOCK_STREAM, 0);
    if (socketFd < 0) {
        return 0;
    }
    int onlyIpv6 = 1;
    (void)::setsockopt(
        socketFd, IPPROTO_IPV6, IPV6_V6ONLY, &onlyIpv6, sizeof(onlyIpv6));
    sockaddr_in6 address {};
    address.sin6_family = AF_INET6;
    address.sin6_addr = in6addr_loopback;
    address.sin6_port = 0;
    if (::bind(socketFd, reinterpret_cast<sockaddr*>(&address),
               sizeof(address)) != 0) {
        ::close(socketFd);
        return 0;
    }
    socklen_t length = sizeof(address);
    const bool named = ::getsockname(
        socketFd, reinterpret_cast<sockaddr*>(&address), &length) == 0;
    const int port = named ? static_cast<int>(ntohs(address.sin6_port)) : 0;
    ::close(socketFd);
    return port;
}

bool fileContains(const std::string& path, const std::string& marker) {
    std::ifstream input(path, std::ios::binary);
    const std::string contents{
        std::istreambuf_iterator<char>(input),
        std::istreambuf_iterator<char>()};
    return contents.find(marker) != std::string::npos;
}

bool waitForFileMarker(
    const std::string& path, const std::string& marker,
    std::chrono::milliseconds timeout) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (std::chrono::steady_clock::now() < deadline) {
        if (fileContains(path, marker)) {
            return true;
        }
        std::this_thread::sleep_for(5ms);
    }
    return fileContains(path, marker);
}

class ParamikoSshFixture final {
public:
    ParamikoSshFixture()
        : readyPath_(temporaryPath("remotedesktop-ssh-ready")),
          eventsPath_(temporaryPath("remotedesktop-ssh-events")),
          logPath_(temporaryPath("remotedesktop-ssh-log")) {}

    ~ParamikoSshFixture() {
        stop();
        if (!readyPath_.empty()) { (void)::unlink(readyPath_.c_str()); }
        if (!eventsPath_.empty()) { (void)::unlink(eventsPath_.c_str()); }
        if (!logPath_.empty()) { (void)::unlink(logPath_.c_str()); }
    }

    bool start() {
        const char* pythonPath =
            std::getenv("REMOTEDESK_SSH_RUNTIME_PYTHONPATH");
        if (pythonPath == nullptr || pythonPath[0] == '\0' ||
            readyPath_.empty() || eventsPath_.empty() || logPath_.empty()) {
            return false;
        }
        port_ = reserveIpv6LoopbackPort();
        if (port_ == 0) {
            return false;
        }
        const std::string script =
            std::string(REMOTEDESK_NATIVE_SOURCE_DIR) +
            "/test/fixtures/ssh_paramiko_server.py";
        const std::string portText = std::to_string(port_);
        child_ = ::fork();
        if (child_ < 0) {
            return false;
        }
        if (child_ == 0) {
            (void)::setenv("PYTHONPATH", pythonPath, 1);
            const int logDescriptor = ::open(
                logPath_.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
            if (logDescriptor >= 0) {
                (void)::dup2(logDescriptor, STDOUT_FILENO);
                (void)::dup2(logDescriptor, STDERR_FILENO);
                ::close(logDescriptor);
            }
            ::execlp(
                "python3", "python3", script.c_str(),
                "--port", portText.c_str(),
                "--ready-file", readyPath_.c_str(),
                "--events-file", eventsPath_.c_str(),
                static_cast<char*>(nullptr));
            ::_exit(127);
        }

        const auto deadline = std::chrono::steady_clock::now() + 8s;
        while (std::chrono::steady_clock::now() < deadline) {
            if (::access(readyPath_.c_str(), F_OK) == 0) {
                return true;
            }
            int status = 0;
            if (::waitpid(child_, &status, WNOHANG) == child_) {
                child_ = -1;
                return false;
            }
            std::this_thread::sleep_for(10ms);
        }
        stop();
        return false;
    }

    void stop() {
        if (child_ <= 0) {
            return;
        }
        (void)::kill(child_, SIGTERM);
        for (int attempt = 0; attempt < 100; ++attempt) {
            int status = 0;
            const pid_t waited = ::waitpid(child_, &status, WNOHANG);
            if (waited == child_) {
                child_ = -1;
                return;
            }
            std::this_thread::sleep_for(10ms);
        }
        (void)::kill(child_, SIGKILL);
        (void)::waitpid(child_, nullptr, 0);
        child_ = -1;
    }

    int port() const { return port_; }
    const std::string& eventsPath() const { return eventsPath_; }

private:
    pid_t child_ = -1;
    int port_ = 0;
    std::string readyPath_;
    std::string eventsPath_;
    std::string logPath_;
};

bool startRuntimeFixture(ParamikoSshFixture& fixture) {
    if (fixture.start()) {
        return true;
    }
    const char* required =
        std::getenv("REMOTEDESK_REQUIRE_SSH_RUNTIME_FIXTURE");
    if (required != nullptr && std::string(required) == "1") {
        RDP_ASSERT(false && "required Paramiko SSH runtime fixture unavailable");
    }
    std::fprintf(stderr,
        "  SKIP: set REMOTEDESK_SSH_RUNTIME_PYTHONPATH for SSH server runtime coverage\n");
    return false;
}

ConnectionConfig keyboardInteractiveConfig(
    int port, std::vector<std::string> responses = {}) {
    ConnectionConfig config;
    config.host = "::1";
    config.port = port;
    config.username = "runtime-user";
    config.authMethod = "kbd-interactive";
    config.sshKeyboardInteractiveResponses = std::move(responses);
    return config;
}

} // namespace

RDP_TEST_CASE(ssh_adapter_runtime_links_expected_libssh2_version) {
    const char* version = libssh2_version(0);
    RDP_ASSERT(version != nullptr);
    RDP_ASSERT(std::string(version).rfind("1.11.1", 0) == 0);
}

RDP_TEST_CASE(ssh_session_reaper_never_writes_through_reused_descriptor) {
    (void)::signal(SIGPIPE, SIG_IGN);
    const bool previousAutoReap =
        sshSetDeferredTrackedLibssh2AutoReapForTesting(false);
    RDP_ASSERT(sshWaitForDeferredTrackedLibssh2ReaperIdleForTesting(2s));
    sshReapDeferredTrackedLibssh2Sessions();
    ParamikoSshFixture fixture;
    if (!startRuntimeFixture(fixture)) {
        (void)sshSetDeferredTrackedLibssh2AutoReapForTesting(
            previousAutoReap);
        return;
    }
    const size_t allocationBaseline =
        sshSensitiveAllocationRegistry().pendingCount();
    const size_t contextBaseline = sshTrackedLibssh2ContextCount();
    const size_t deferredBaseline =
        sshDeferredTrackedLibssh2SessionCount();

    const auto captured = freshNetworkSnapshot();
    (void)captured;
    SshAdapter adapter;
    adapter.setSessionIdentity(7000);
    adapter.setSessionGeneration(7100);
    ConnectionConfig config = keyboardInteractiveConfig(
        fixture.port(), {"alpha-secret", "beta-secret"});
    RDP_ASSERT_EQ(
        adapter.connect(config), 0);

    sshResetLibssh2RetiredTransportInvocationsForTesting();
    int retiredDescriptor = -1;
    RDP_ASSERT_EQ(
        SshAdapterRuntimeTestAccess::quarantineConnectedSession(
            adapter, &returnRuntimeSessionFreeEagain,
            retiredDescriptor),
        LIBSSH2_ERROR_EAGAIN);
    RDP_ASSERT(retiredDescriptor >= 0);
    RDP_ASSERT_EQ(
        sshDeferredTrackedLibssh2SessionCount(), deferredBaseline + 1);

    int replacementSockets[2] = {-1, -1};
    RDP_ASSERT(::socketpair(AF_UNIX, SOCK_STREAM, 0, replacementSockets) == 0);
    int reusedDescriptor = replacementSockets[0];
    int replacementPeer = replacementSockets[1];
    if (replacementPeer == retiredDescriptor &&
        reusedDescriptor != retiredDescriptor) {
        const int movedPeer = ::fcntl(
            replacementPeer, F_DUPFD, retiredDescriptor + 1);
        RDP_ASSERT(movedPeer >= 0);
        ::close(replacementPeer);
        replacementPeer = movedPeer;
    }
    if (reusedDescriptor != retiredDescriptor) {
        RDP_ASSERT(::dup2(reusedDescriptor, retiredDescriptor) ==
            retiredDescriptor);
        ::close(reusedDescriptor);
        reusedDescriptor = retiredDescriptor;
    }
    RDP_ASSERT_EQ(reusedDescriptor, retiredDescriptor);
    RDP_ASSERT(setNonBlocking(replacementPeer));

    // This is the real libssh2_session_free path over an authenticated session
    // with a live channel. Channel teardown must hit the fail-closed transport
    // callback while the remembered integer fd belongs to an unrelated peer.
    sshReapDeferredTrackedLibssh2Sessions();
    RDP_ASSERT(
        sshLibssh2RetiredTransportInvocationsForTesting() > 0);
    RDP_ASSERT_EQ(drainSocket(replacementPeer), static_cast<size_t>(0));
    RDP_ASSERT_EQ(
        sshDeferredTrackedLibssh2SessionCount(), deferredBaseline);
    RDP_ASSERT_EQ(
        sshSensitiveAllocationRegistry().pendingCount(), allocationBaseline);
    RDP_ASSERT_EQ(sshTrackedLibssh2ContextCount(), contextBaseline);

    ::close(reusedDescriptor);
    ::close(replacementPeer);
    adapter.disconnect();
    fixture.stop();
    RDP_ASSERT(sshWaitForDeferredTrackedLibssh2ReaperIdleForTesting(2s));
    (void)sshSetDeferredTrackedLibssh2AutoReapForTesting(previousAutoReap);
}

RDP_TEST_CASE(ssh_adapter_real_handshake_eagain_cuts_over_without_old_route_retry) {
    (void)::signal(SIGPIPE, SIG_IGN);
    sshReapDeferredTrackedLibssh2Sessions();
    const size_t allocationBaseline =
        sshSensitiveAllocationRegistry().pendingCount();
    const size_t contextBaseline = sshTrackedLibssh2ContextCount();
    const size_t deferredBaseline =
        sshDeferredTrackedLibssh2SessionCount();
    int sockets[2] = {-1, -1};
    RDP_ASSERT(::socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
    RDP_ASSERT(setNonBlocking(sockets[0]));
    RDP_ASSERT(setNonBlocking(sockets[1]));

    const auto captured = freshNetworkSnapshot();
    SshAdapter adapter;
    LIBSSH2_SESSION* session = sshCreateTrackedLibssh2Session();
    RDP_ASSERT(session != nullptr);
    libssh2_session_set_blocking(session, 0);
    SshAdapterRuntimeTestAccess::preparePartialSession(
        adapter, session, sockets[0], captured);

    size_t bytesBeforeCutover = 0;
    std::atomic<int> eagainCalls {0};
    SshAdapterRuntimeTestAccess::setHandshakeEagainHook(adapter, [&]() {
        if (eagainCalls.fetch_add(1, std::memory_order_acq_rel) != 0) {
            return;
        }
        bytesBeforeCutover += drainSocket(sockets[1]);
        auto& fence = remotedesk::net::ProcessNetworkGenerationFence();
        RDP_ASSERT(fence.update(true, captured.generation + 1));
    });
    std::vector<std::string> teardownEvents;
    SshAdapterRuntimeTestAccess::setTransportHooks(
        adapter,
        [&]() { teardownEvents.emplace_back("shutdown"); },
        [&]() { teardownEvents.emplace_back("close"); });

    const auto startedAt = std::chrono::steady_clock::now();
    const int handshakeResult =
        SshAdapterRuntimeTestAccess::handshakePartialSession(adapter);
    const auto elapsed = std::chrono::steady_clock::now() - startedAt;
    RDP_ASSERT(handshakeResult == ERR_SSH_SESSION_CLOSED);
    RDP_ASSERT(elapsed < 1s);
    RDP_ASSERT_EQ(eagainCalls.load(std::memory_order_acquire), 1);
    RDP_ASSERT(bytesBeforeCutover > 0);
    RDP_ASSERT_EQ(drainSocket(sockets[1]), static_cast<size_t>(0));

    SshAdapterRuntimeTestAccess::teardownPartialSession(adapter);
    RDP_ASSERT(teardownEvents.size() == 2);
    RDP_ASSERT(teardownEvents[0] == "shutdown");
    RDP_ASSERT(teardownEvents[1] == "close");
    RDP_ASSERT_EQ(drainSocket(sockets[1]), static_cast<size_t>(0));
    ::close(sockets[1]);
    RDP_ASSERT_EQ(
        sshSensitiveAllocationRegistry().pendingCount(), allocationBaseline);
    RDP_ASSERT_EQ(sshTrackedLibssh2ContextCount(), contextBaseline);
    RDP_ASSERT_EQ(
        sshDeferredTrackedLibssh2SessionCount(), deferredBaseline);
}

RDP_TEST_CASE(ssh_adapter_real_kbi_completes_two_server_rounds) {
    ParamikoSshFixture fixture;
    if (!startRuntimeFixture(fixture)) {
        return;
    }
    sshReapDeferredTrackedLibssh2Sessions();
    const size_t allocationBaseline =
        sshSensitiveAllocationRegistry().pendingCount();
    const size_t contextBaseline = sshTrackedLibssh2ContextCount();
    const size_t deferredBaseline =
        sshDeferredTrackedLibssh2SessionCount();
    const auto captured = freshNetworkSnapshot();
    (void)captured;
    SshAdapter adapter;
    adapter.setSessionIdentity(7001);
    adapter.setSessionGeneration(7101);
    std::atomic<int> rounds {0};
    SshAdapterRuntimeTestAccess::setKeyboardInteractiveRoundHook(
        adapter, [&]() { rounds.fetch_add(1, std::memory_order_acq_rel); });
    ConnectionConfig config = keyboardInteractiveConfig(
        fixture.port(), {"alpha-secret", "beta-secret"});

    RDP_ASSERT_EQ(adapter.connect(config), 0);
    RDP_ASSERT_EQ(rounds.load(std::memory_order_acquire), 2);
    RDP_ASSERT(waitForFileMarker(
        fixture.eventsPath(), "response:2:accepted", 2s));
    RDP_ASSERT(fileContains(fixture.eventsPath(), "prompt:1"));
    RDP_ASSERT(fileContains(fixture.eventsPath(), "response:1:accepted"));
    RDP_ASSERT(fileContains(fixture.eventsPath(), "prompt:2"));
    adapter.disconnect();
    fixture.stop();
    RDP_ASSERT_EQ(
        sshSensitiveAllocationRegistry().pendingCount(), allocationBaseline);
    RDP_ASSERT_EQ(sshTrackedLibssh2ContextCount(), contextBaseline);
    RDP_ASSERT_EQ(
        sshDeferredTrackedLibssh2SessionCount(), deferredBaseline);
}

RDP_TEST_CASE(ssh_adapter_real_kbi_wait_cutover_sends_no_info_response) {
    ParamikoSshFixture fixture;
    if (!startRuntimeFixture(fixture)) {
        return;
    }
    sshReapDeferredTrackedLibssh2Sessions();
    const size_t allocationBaseline =
        sshSensitiveAllocationRegistry().pendingCount();
    const size_t contextBaseline = sshTrackedLibssh2ContextCount();
    const size_t deferredBaseline =
        sshDeferredTrackedLibssh2SessionCount();
    const auto captured = freshNetworkSnapshot();
    SshAdapter adapter;
    adapter.setSessionIdentity(7002);
    adapter.setSessionGeneration(7102);
    std::atomic<int> rounds {0};
    SshAdapterRuntimeTestAccess::setKeyboardInteractiveRoundHook(
        adapter, [&]() { rounds.fetch_add(1, std::memory_order_acq_rel); });
    ConnectionConfig config = keyboardInteractiveConfig(fixture.port());
    auto connection = std::async(std::launch::async, [&]() {
        return adapter.connect(config);
    });

    SshAuthPromptRequest request;
    const auto promptDeadline = std::chrono::steady_clock::now() + 5s;
    while (!adapter.getAuthPrompt(request) &&
           std::chrono::steady_clock::now() < promptDeadline) {
        std::this_thread::sleep_for(5ms);
    }
    RDP_ASSERT(request.requestId != 0);
    RDP_ASSERT_EQ(request.round, static_cast<uint32_t>(1));
    RDP_ASSERT(waitForFileMarker(fixture.eventsPath(), "prompt:1", 2s));

    auto& fence = remotedesk::net::ProcessNetworkGenerationFence();
    RDP_ASSERT(fence.update(true, captured.generation + 1));
    RDP_ASSERT(adapter.respondAuthPrompt(SshAuthPromptResponse {
        1, request.requestId, request.sessionId, request.generation,
        {"alpha-secret"}, false}));
    RDP_ASSERT(connection.wait_for(3s) == std::future_status::ready);
    RDP_ASSERT(connection.get() != 0);
    adapter.disconnect();
    std::this_thread::sleep_for(100ms);
    RDP_ASSERT_EQ(rounds.load(std::memory_order_acquire), 1);
    RDP_ASSERT(!fileContains(fixture.eventsPath(), "response:1:"));
    fixture.stop();
    RDP_ASSERT_EQ(
        sshSensitiveAllocationRegistry().pendingCount(), allocationBaseline);
    RDP_ASSERT_EQ(sshTrackedLibssh2ContextCount(), contextBaseline);
    RDP_ASSERT_EQ(
        sshDeferredTrackedLibssh2SessionCount(), deferredBaseline);
}

RDP_TEST_CASE(ssh_adapter_real_channel_read_stops_before_post_cutover_window_adjust) {
    ParamikoSshFixture fixture;
    if (!startRuntimeFixture(fixture)) {
        return;
    }
    sshReapDeferredTrackedLibssh2Sessions();
    const size_t allocationBaseline =
        sshSensitiveAllocationRegistry().pendingCount();
    const size_t contextBaseline = sshTrackedLibssh2ContextCount();
    const size_t deferredBaseline =
        sshDeferredTrackedLibssh2SessionCount();
    const auto captured = freshNetworkSnapshot();
    SshAdapter adapter;
    adapter.setSessionIdentity(7003);
    adapter.setSessionGeneration(7103);
    ConnectionConfig config = keyboardInteractiveConfig(
        fixture.port(), {"alpha-secret", "beta-secret"});
    RDP_ASSERT_EQ(adapter.connect(config), 0);

    std::atomic<size_t> readCalls {0};
    std::atomic<size_t> bytesRead {0};
    std::atomic<size_t> callsAtCutover {0};
    std::atomic<bool> cutover {false};
    SshAdapterRuntimeTestAccess::setChannelReadHook(
        adapter, [&](ssize_t result) {
            const size_t calls = readCalls.fetch_add(
                1, std::memory_order_acq_rel) + 1;
            if (result <= 0) {
                return;
            }
            const size_t total = bytesRead.fetch_add(
                static_cast<size_t>(result), std::memory_order_acq_rel) +
                static_cast<size_t>(result);
            if (total < 256 * 1024 ||
                cutover.exchange(true, std::memory_order_acq_rel)) {
                return;
            }
            auto& fence = remotedesk::net::ProcessNetworkGenerationFence();
            RDP_ASSERT(fence.update(true, captured.generation + 1));
            callsAtCutover.store(calls, std::memory_order_release);
        });

    SshCommandResult result;
    const auto startedAt = std::chrono::steady_clock::now();
    const int commandResult = adapter.executeCommand(
        "runtime-window-adjust", result, 5000);
    const auto elapsed = std::chrono::steady_clock::now() - startedAt;
    RDP_ASSERT(cutover.load(std::memory_order_acquire));
    RDP_ASSERT(commandResult == ERR_SSH_SESSION_CLOSED);
    RDP_ASSERT(elapsed < 3s);
    const size_t observedAtCutover =
        callsAtCutover.load(std::memory_order_acquire);
    RDP_ASSERT(observedAtCutover > 0);
    std::this_thread::sleep_for(50ms);
    RDP_ASSERT_EQ(
        readCalls.load(std::memory_order_acquire), observedAtCutover);
    RDP_ASSERT(bytesRead.load(std::memory_order_acquire) >= 256 * 1024);
    adapter.disconnect();
    fixture.stop();
    RDP_ASSERT_EQ(
        sshSensitiveAllocationRegistry().pendingCount(), allocationBaseline);
    RDP_ASSERT_EQ(sshTrackedLibssh2ContextCount(), contextBaseline);
    RDP_ASSERT_EQ(
        sshDeferredTrackedLibssh2SessionCount(), deferredBaseline);
}
