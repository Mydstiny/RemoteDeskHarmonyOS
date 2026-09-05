#pragma once

#include <atomic>
#include <chrono>
#include <future>
#include <memory>
#include <string>

#if defined(RDP_TESTS_ONLY)
#include <functional>
#endif

struct SshForwardTargetConnectResult final {
    int descriptor = -1;
    int errorCode = 0;
};

// Owns one remote-forward target connection attempt. The network work runs
// outside the libssh2 owner reactor; the reactor only polls ready() and takes
// the completed descriptor. Destruction cooperatively cancels and closes any
// descriptor that was not transferred to the caller.
class SshForwardTargetConnectTask final {
public:
    SshForwardTargetConnectTask() noexcept = default;
    ~SshForwardTargetConnectTask();

    SshForwardTargetConnectTask(const SshForwardTargetConnectTask&) = delete;
    SshForwardTargetConnectTask& operator=(const SshForwardTargetConnectTask&) = delete;
    SshForwardTargetConnectTask(SshForwardTargetConnectTask&& other) noexcept;
    SshForwardTargetConnectTask& operator=(SshForwardTargetConnectTask&& other) noexcept;

    bool start(const std::string& host, int port,
               std::chrono::milliseconds timeout = std::chrono::seconds(10)) noexcept;
    bool pending() const noexcept;
    bool ready() const noexcept;
    SshForwardTargetConnectResult take() noexcept;
    void cancelAndClose() noexcept;

#if defined(RDP_TESTS_ONLY)
    using TestConnector = std::function<SshForwardTargetConnectResult(
        const std::shared_ptr<std::atomic<bool>>&)>;
    bool startForTest(TestConnector connector) noexcept;
#endif

private:
    std::shared_ptr<std::atomic<bool>> cancellation_;
    std::future<SshForwardTargetConnectResult> completion_;
};
