#include "test_runner.h"
#include "ssh/ssh_sftp_operation_policy.h"

#include <deque>
#include <functional>
#include <string>
#include <vector>

RDP_TEST_CASE(ssh_sftp_operation_classifies_before_queued_recovery) {
    std::vector<std::string> trace;
    std::deque<std::function<void()>> ownerCommands;
    SshSftpOperationObservation observed;

    ownerCommands.emplace_back([&]() {
        observed = ObserveSshSftpOperationOnOwner(
            [&]() {
                trace.emplace_back("operation");
                return -41;
            },
            [&](int errorCode) {
                trace.emplace_back("classification");
                return errorCode == -41;
            });
    });
    ownerCommands.emplace_back([&]() {
        trace.emplace_back("recovery");
    });

    while (!ownerCommands.empty()) {
        std::function<void()> command = std::move(ownerCommands.front());
        ownerCommands.pop_front();
        command();
    }

    RDP_ASSERT_EQ(observed.errorCode, -41);
    RDP_ASSERT(observed.transportLost);
    RDP_ASSERT_EQ(trace.size(), static_cast<size_t>(3));
    RDP_ASSERT(trace[0] == "operation");
    RDP_ASSERT(trace[1] == "classification");
    RDP_ASSERT(trace[2] == "recovery");
}
