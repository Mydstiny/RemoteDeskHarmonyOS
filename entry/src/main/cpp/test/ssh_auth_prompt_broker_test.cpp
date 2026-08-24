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

RDP_TEST_CASE(ssh_auth_prompt_broker_accepts_new_session_after_cancellation) {
    SshAuthPromptBroker broker;
    std::vector<SshAuthPrompt> prompts {{"OTP:", true}};
    std::vector<std::string> responses;
    SshAuthPromptWaitResult firstResult = SshAuthPromptWaitResult::Closed;
    SshAuthPromptWaitResult secondResult = SshAuthPromptWaitResult::Closed;
    std::thread cancelledWorker([&]() {
        firstResult = broker.waitForResponse(
            51, 9101, "target.example", "target", "", 0, "", 0,
            prompts, responses);
    });
    SshAuthPromptRequest staleRequest;
    for (int attempt = 0; attempt < 100 && !broker.snapshot(staleRequest); ++attempt) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    RDP_ASSERT(broker.cancel(staleRequest.requestId, 51, 9101));
    cancelledWorker.join();
    RDP_ASSERT(firstResult == SshAuthPromptWaitResult::Cancelled);
    RDP_ASSERT(!broker.respond(SshAuthPromptResponse {
        1, staleRequest.requestId, 51, 9101, {"123456"}, false}));

    std::thread activeWorker([&]() {
        secondResult = broker.waitForResponse(
            52, 9102, "target.example", "target", "", 0, "", 0,
            prompts, responses);
    });
    SshAuthPromptRequest activeRequest;
    for (int attempt = 0; attempt < 100 && !broker.snapshot(activeRequest); ++attempt) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    RDP_ASSERT(activeRequest.sessionId == 52);
    RDP_ASSERT(activeRequest.generation == 9102);
    RDP_ASSERT(activeRequest.round == 2);
    RDP_ASSERT(broker.respond(SshAuthPromptResponse {
        1, activeRequest.requestId, 52, 9102, {"654321"}, false}));
    activeWorker.join();
    RDP_ASSERT(secondResult == SshAuthPromptWaitResult::Responded);
    RDP_ASSERT(responses.size() == 1);
    RDP_ASSERT(responses[0] == "654321");
}

RDP_TEST_CASE(ssh_auth_prompt_broker_host_key_decision_is_bound_and_has_no_secret_prompt) {
    SshAuthPromptBroker broker;
    SshAuthPromptWaitResult waitResult = SshAuthPromptWaitResult::Closed;
    std::thread worker([&]() {
        waitResult = broker.waitForHostKeyDecision(
            61, 9201, "target.example", "hop-2", "host-record-1",
            "jump-2.example", 2222, 1, "ssh-ed25519", "SHA256:new",
            "AAAAC3NzaC1lZDI1NTE5AAAA", "SHA256:old", true);
    });

    SshAuthPromptRequest request;
    for (int attempt = 0; attempt < 100 && !broker.snapshot(request); ++attempt) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    RDP_ASSERT(request.kind == "host_key");
    RDP_ASSERT(request.sessionId == 61);
    RDP_ASSERT(request.generation == 9201);
    RDP_ASSERT(request.trustHostId == "host-record-1");
    RDP_ASSERT(request.endpointHost == "jump-2.example");
    RDP_ASSERT(request.endpointPort == 2222);
    RDP_ASSERT(request.hostKeyHopIndex == 1);
    RDP_ASSERT(request.hostKeyChanged);
    RDP_ASSERT(request.hostKeyAlgorithm == "ssh-ed25519");
    RDP_ASSERT(request.hostKeyFingerprintSha256 == "SHA256:new");
    RDP_ASSERT(request.expectedHostKeyFingerprintSha256 == "SHA256:old");
    RDP_ASSERT(request.prompts.empty());
    RDP_ASSERT(broker.respond(SshAuthPromptResponse {
        1, request.requestId, 61, 9201, {}, false}));
    worker.join();
    RDP_ASSERT(waitResult == SshAuthPromptWaitResult::Responded);
}
