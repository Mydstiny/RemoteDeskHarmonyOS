#include "test_runner.h"
#include "ssh/ssh_auth_prompt_broker.h"

#include <chrono>
#include <thread>

RDP_TEST_CASE(ssh_auth_prompt_broker_round_trip_preserves_prompt_metadata) {
    SshAuthPromptBroker broker;
    std::vector<SshAuthPrompt> prompts {
        {"Password:", false}, {"Verification code:", true}
    };
    std::vector<std::string> responses;
    SshAuthPromptWaitResult waitResult = SshAuthPromptWaitResult::Closed;
    std::thread worker([&]() {
        waitResult = broker.waitForResponse(
            41, 9001, "target.example", "jump", "name", 4,
            "instruction", 11, prompts, responses);
    });

    SshAuthPromptRequest request;
    for (int attempt = 0; attempt < 100 && !broker.snapshot(request); ++attempt) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    RDP_ASSERT(request.sessionId == 41);
    RDP_ASSERT(request.generation == 9001);
    RDP_ASSERT(request.hop == "jump");
    RDP_ASSERT(request.round == 1);
    RDP_ASSERT(request.prompts.size() == 2);
    RDP_ASSERT(broker.respond(SshAuthPromptResponse {
        1, request.requestId, 41, 9001, {"secret", "123456"}, false}));
    worker.join();

    RDP_ASSERT(waitResult == SshAuthPromptWaitResult::Responded);
    RDP_ASSERT(responses.size() == 2);
    RDP_ASSERT(responses[0] == "secret");
    RDP_ASSERT(responses[1] == "123456");
}

RDP_TEST_CASE(ssh_auth_prompt_broker_cancellation_wakes_owner) {
    SshAuthPromptBroker broker;
    std::vector<SshAuthPrompt> prompts {{"OTP:", true}};
    std::vector<std::string> responses;
    SshAuthPromptWaitResult waitResult = SshAuthPromptWaitResult::Closed;
    std::thread worker([&]() {
        waitResult = broker.waitForResponse(
            42, 9002, "target.example", "target", "", 0, "", 0,
            prompts, responses);
    });
    SshAuthPromptRequest request;
    for (int attempt = 0; attempt < 100 && !broker.snapshot(request); ++attempt) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    RDP_ASSERT(request.requestId != 0);
    RDP_ASSERT(broker.cancel(request.requestId, 42, 9002));
    worker.join();
    RDP_ASSERT(waitResult == SshAuthPromptWaitResult::Cancelled);
}
