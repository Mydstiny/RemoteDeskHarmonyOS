/**
 * One-shot SSH owner prompt broker.
 *
 * libssh2 invokes its callback on the SSH owner reactor.  The broker exposes
 * the current prompt to NAPI, waits for one response round, and clears all
 * response material before returning. Keyboard-interactive responses remain
 * transient; Host Key decisions carry public key metadata for ArkUI persistence.
 */
#ifndef SSH_AUTH_PROMPT_BROKER_H
#define SSH_AUTH_PROMPT_BROKER_H

#include "ssh_sensitive_buffer.h"

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

struct SshAuthPrompt {
    std::string text;
    bool echo = false;
};

struct SshAuthPromptRequest {
    uint32_t schemaVersion = 1;
    uint64_t requestId = 0;
    uint64_t sessionId = 0;
    uint64_t generation = 0;
    std::string targetHost;
    std::string hop;
    uint32_t round = 0;
    std::string name;
    std::string instruction;
    std::vector<SshAuthPrompt> prompts;
    uint64_t expiresAtMs = 0;
    std::string kind = "keyboard_interactive";
    std::string trustHostId;
    std::string routeIdentity;
    std::string endpointHost;
    int endpointPort = 0;
    int hostKeyHopIndex = -1;
    std::string hostKeyAlgorithm;
    std::string hostKeyFingerprintSha256;
    std::string hostKeyRawBase64;
    std::string expectedHostKeyFingerprintSha256;
    bool hostKeyChanged = false;
};

struct SshAuthPromptResponse {
    uint32_t schemaVersion = 1;
    uint64_t requestId = 0;
    uint64_t sessionId = 0;
    uint64_t generation = 0;
    std::vector<std::string> responses;
    bool cancelled = false;

    SshAuthPromptResponse() = default;
    SshAuthPromptResponse(
        uint32_t responseSchemaVersion, uint64_t responseRequestId,
        uint64_t responseSessionId, uint64_t responseGeneration,
        std::vector<std::string> responseValues, bool responseCancelled)
        : schemaVersion(responseSchemaVersion),
          requestId(responseRequestId),
          sessionId(responseSessionId),
          generation(responseGeneration),
          responses(std::move(responseValues)),
          cancelled(responseCancelled) {}

    SshAuthPromptResponse(const SshAuthPromptResponse& other)
        : schemaVersion(other.schemaVersion),
          requestId(other.requestId),
          sessionId(other.sessionId),
          generation(other.generation),
          responses(other.responses),
          cancelled(other.cancelled) {}

    SshAuthPromptResponse(SshAuthPromptResponse&& other) noexcept
        : schemaVersion(other.schemaVersion),
          requestId(other.requestId),
          sessionId(other.sessionId),
          generation(other.generation),
          responses(std::move(other.responses)),
          cancelled(other.cancelled) {}

    SshAuthPromptResponse& operator=(const SshAuthPromptResponse& other) {
        if (this == &other) { return *this; }
        wipeResponses();
        schemaVersion = other.schemaVersion;
        requestId = other.requestId;
        sessionId = other.sessionId;
        generation = other.generation;
        responses = other.responses;
        cancelled = other.cancelled;
        return *this;
    }

    SshAuthPromptResponse& operator=(SshAuthPromptResponse&& other) noexcept {
        if (this == &other) { return *this; }
        wipeResponses();
        schemaVersion = other.schemaVersion;
        requestId = other.requestId;
        sessionId = other.sessionId;
        generation = other.generation;
        responses = std::move(other.responses);
        cancelled = other.cancelled;
        return *this;
    }

    ~SshAuthPromptResponse() noexcept { wipeResponses(); }

    void wipeResponses() noexcept {
        sshWipeSensitiveStrings(responses);
    }
};

enum class SshAuthPromptWaitResult : uint8_t {
    Responded = 0,
    Cancelled,
    TimedOut,
    Closed,
};

class SshAuthPromptBroker final {
public:
    static constexpr uint32_t kMaxPrompts = 32;
    static constexpr size_t kMaxPromptBytes = 4096;
    static constexpr std::chrono::seconds kTimeout {120};

    SshAuthPromptBroker() = default;
    SshAuthPromptBroker(const SshAuthPromptBroker&) = delete;
    SshAuthPromptBroker& operator=(const SshAuthPromptBroker&) = delete;

    SshAuthPromptWaitResult waitForResponse(
        uint64_t sessionId, uint64_t generation, const std::string& targetHost,
        const std::string& hop, const char* name, int nameLen,
        const char* instruction, int instructionLen,
        const std::vector<SshAuthPrompt>& prompts,
        std::vector<std::string>& responses,
        std::chrono::steady_clock::time_point absoluteDeadline =
            std::chrono::steady_clock::time_point::max()) {
        sshWipeSensitiveStrings(responses);
        responses.clear();
        if (prompts.empty()) {
            return SshAuthPromptWaitResult::Responded;
        }
        const auto startedAt = std::chrono::steady_clock::now();
        const auto deadline = std::min(startedAt + kTimeout, absoluteDeadline);
        if (deadline <= startedAt) {
            return SshAuthPromptWaitResult::TimedOut;
        }
        const auto remainingMilliseconds =
            std::chrono::duration_cast<std::chrono::milliseconds>(
                deadline - startedAt).count();

        SshAuthPromptRequest request;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (closed_ || pending_) {
                return closed_ ? SshAuthPromptWaitResult::Closed
                               : SshAuthPromptWaitResult::Cancelled;
            }
            request.requestId = ++nextRequestId_;
            request.sessionId = sessionId;
            request.generation = generation;
            request.targetHost = bounded(targetHost, 255);
            request.hop = bounded(hop, 96);
            request.round = ++round_;
            request.name = bounded(name, nameLen, 512);
            request.instruction = bounded(instruction, instructionLen, 4096);
            request.prompts = prompts;
            if (request.prompts.size() > kMaxPrompts) {
                request.prompts.resize(kMaxPrompts);
            }
            request.expiresAtMs = nowMs() +
                static_cast<uint64_t>(
                    std::max<int64_t>(0, remainingMilliseconds));
            pendingRequest_ = request;
            pending_ = true;
            responseReady_ = false;
            cancelled_ = false;
            responseValues_.clear();
        }
        cv_.notify_all();

        std::unique_lock<std::mutex> lock(mutex_);
        while (!responseReady_ && !cancelled_ && !closed_) {
            if (cv_.wait_until(lock, deadline) == std::cv_status::timeout) {
                break;
            }
        }
        SshAuthPromptWaitResult result = SshAuthPromptWaitResult::Responded;
        if (closed_) {
            result = SshAuthPromptWaitResult::Closed;
        } else if (cancelled_) {
            result = SshAuthPromptWaitResult::Cancelled;
        } else if (!responseReady_) {
            result = SshAuthPromptWaitResult::TimedOut;
        } else {
            responses.swap(responseValues_);
        }
        clearPendingLocked();
        return result;
    }

    SshAuthPromptWaitResult waitForHostKeyDecision(
        uint64_t sessionId, uint64_t generation, const std::string& targetHost,
        const std::string& hop, const std::string& trustHostId,
        const std::string& routeIdentity,
        const std::string& endpointHost, int endpointPort, int hopIndex,
        const std::string& algorithm, const std::string& fingerprintSha256,
        const std::string& rawBase64, const std::string& expectedFingerprintSha256,
        bool changed,
        std::chrono::steady_clock::time_point absoluteDeadline =
            std::chrono::steady_clock::time_point::max()) {
        const auto startedAt = std::chrono::steady_clock::now();
        const auto deadline = std::min(startedAt + kTimeout, absoluteDeadline);
        if (deadline <= startedAt) {
            return SshAuthPromptWaitResult::TimedOut;
        }
        const auto remainingMilliseconds =
            std::chrono::duration_cast<std::chrono::milliseconds>(
                deadline - startedAt).count();
        SshAuthPromptRequest request;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (closed_ || pending_) {
                return closed_ ? SshAuthPromptWaitResult::Closed
                               : SshAuthPromptWaitResult::Cancelled;
            }
            request.requestId = ++nextRequestId_;
            request.sessionId = sessionId;
            request.generation = generation;
            request.targetHost = bounded(targetHost, 255);
            request.hop = bounded(hop, 96);
            request.round = ++round_;
            request.kind = "host_key";
            request.trustHostId = bounded(trustHostId, 128);
            request.routeIdentity = bounded(routeIdentity, 4096);
            request.endpointHost = bounded(endpointHost, 255);
            request.endpointPort = endpointPort;
            request.hostKeyHopIndex = hopIndex;
            request.hostKeyAlgorithm = bounded(algorithm, 96);
            request.hostKeyFingerprintSha256 = bounded(fingerprintSha256, 255);
            request.hostKeyRawBase64 = bounded(rawBase64, 64 * 1024);
            request.expectedHostKeyFingerprintSha256 = bounded(expectedFingerprintSha256, 255);
            request.hostKeyChanged = changed;
            request.expiresAtMs = nowMs() +
                static_cast<uint64_t>(
                    std::max<int64_t>(0, remainingMilliseconds));
            pendingRequest_ = request;
            pending_ = true;
            responseReady_ = false;
            cancelled_ = false;
            responseValues_.clear();
        }
        cv_.notify_all();

        std::unique_lock<std::mutex> lock(mutex_);
        while (!responseReady_ && !cancelled_ && !closed_) {
            if (cv_.wait_until(lock, deadline) == std::cv_status::timeout) {
                break;
            }
        }
        SshAuthPromptWaitResult result = SshAuthPromptWaitResult::Responded;
        if (closed_) {
            result = SshAuthPromptWaitResult::Closed;
        } else if (cancelled_) {
            result = SshAuthPromptWaitResult::Cancelled;
        } else if (!responseReady_) {
            result = SshAuthPromptWaitResult::TimedOut;
        }
        clearPendingLocked();
        return result;
    }

    bool snapshot(SshAuthPromptRequest& out) const {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!pending_ || closed_) { return false; }
        out = pendingRequest_;
        return true;
    }

    bool respond(SshAuthPromptResponse response) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!pending_ || closed_ || response.requestId != pendingRequest_.requestId ||
            response.sessionId != pendingRequest_.sessionId ||
            response.generation != pendingRequest_.generation || response.cancelled ||
            responseReady_ ||
            response.responses.size() != pendingRequest_.prompts.size()) {
            return false;
        }
        for (const std::string& value : response.responses) {
            if (value.size() > kMaxPromptBytes) { return false; }
        }
        sshWipeSensitiveStrings(responseValues_);
        responseValues_ = std::move(response.responses);
        responseReady_ = true;
        cv_.notify_all();
        return true;
    }

    bool cancel(uint64_t requestId, uint64_t sessionId, uint64_t generation) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!pending_ || closed_ || requestId != pendingRequest_.requestId ||
            sessionId != pendingRequest_.sessionId ||
            generation != pendingRequest_.generation) {
            return false;
        }
        cancelled_ = true;
        cv_.notify_all();
        return true;
    }

    void cancelAll() {
        std::lock_guard<std::mutex> lock(mutex_);
        cancelled_ = true;
        cv_.notify_all();
    }

    void close() {
        std::lock_guard<std::mutex> lock(mutex_);
        closed_ = true;
        cancelled_ = true;
        clearPendingLocked();
        cv_.notify_all();
    }

    void resetForNewConnection() {
        std::lock_guard<std::mutex> lock(mutex_);
        closed_ = false;
        cancelled_ = false;
        round_ = 0;
        clearPendingLocked();
    }

private:
    static uint64_t nowMs() {
        return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::system_clock::now().time_since_epoch()).count());
    }

    static std::string bounded(const char* value, int length, size_t maxLength) {
        if (value == nullptr || length <= 0) { return {}; }
        return std::string(value, std::min<size_t>(static_cast<size_t>(length), maxLength));
    }

    static std::string bounded(const std::string& value, size_t maxLength) {
        return value.substr(0, maxLength);
    }

    void clearPendingLocked() {
        pending_ = false;
        responseReady_ = false;
        sshWipeSensitiveStrings(responseValues_);
        responseValues_.clear();
        pendingRequest_ = {};
    }

    mutable std::mutex mutex_;
    std::condition_variable cv_;
    bool pending_ = false;
    bool responseReady_ = false;
    bool cancelled_ = false;
    bool closed_ = false;
    uint64_t nextRequestId_ = 0;
    uint32_t round_ = 0;
    SshAuthPromptRequest pendingRequest_;
    std::vector<std::string> responseValues_;
};

#endif // SSH_AUTH_PROMPT_BROKER_H
