#ifndef REMOTEDESK_SSH_TERMINAL_DIAGNOSTICS_H
#define REMOTEDESK_SSH_TERMINAL_DIAGNOSTICS_H

#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <string>

// SSH terminal diagnostics deliberately contain counters and timestamps only.
// They must never retain terminal bytes, commands, credentials, or output.
struct SshTerminalDiagnosticsSnapshot {
    uint64_t schemaVersion = 1;
    uint64_t sessionId = 0;
    uint64_t sessionGeneration = 0;
    std::string channelId = "pty";

    uint64_t inputEvents = 0;
    uint64_t inputBytes = 0;
    uint64_t nativeEnqueueEvents = 0;
    uint64_t writeAttempts = 0;
    uint64_t writeCompleteEvents = 0;
    uint64_t writeBytes = 0;
    uint64_t writeEagain = 0;
    uint64_t remoteReadEvents = 0;
    uint64_t remoteReadBytes = 0;
    uint64_t callbackAcceptedEvents = 0;
    uint64_t callbackAcceptedBytes = 0;
    uint64_t callbackQueueFull = 0;
    uint64_t inputDuplicate = 0;
    uint64_t inputLoss = 0;
    uint64_t inputReorder = 0;
    uint64_t ownerStallEvents = 0;

    uint64_t inputQueueDepth = 0;
    uint64_t inputQueueBytes = 0;
    uint64_t inputQueueMaxDepth = 0;
    uint64_t inputQueueMaxBytes = 0;

    uint64_t lastInputSequence = 0;
    uint64_t lastInputCapturedAtNs = 0;
    uint64_t lastNativeEnqueueAtNs = 0;
    uint64_t lastWriteAttemptAtNs = 0;
    uint64_t lastWriteCompleteAtNs = 0;
    uint64_t lastRemoteReadAtNs = 0;
    uint64_t maxInputToWriteAttemptNs = 0;
    uint64_t maxInputToWriteCompleteNs = 0;
};

class SshTerminalDiagnostics final {
public:
    static constexpr uint64_t kSchemaVersion = 1;

    void setSessionIdentity(uint64_t sessionId) noexcept {
        sessionId_.store(sessionId, std::memory_order_release);
    }

    void setSessionGeneration(uint64_t generation) noexcept {
        sessionGeneration_.store(generation, std::memory_order_release);
    }

    // This is the native arrival point until WP-T1 supplies an explicit
    // ArkUI envelope. It is intentionally payload-free and non-blocking.
    uint64_t beginInput(size_t byteCount) noexcept {
        const uint64_t sequence = nextSequence_.fetch_add(1, std::memory_order_relaxed);
        const uint64_t now = monotonicNowNs();
        inputEvents_.fetch_add(1, std::memory_order_relaxed);
        inputBytes_.fetch_add(static_cast<uint64_t>(byteCount), std::memory_order_relaxed);
        updateMax(lastInputSequence_, sequence);
        updateMax(lastInputCapturedAtNs_, now);
        return sequence;
    }

    void recordNativeEnqueue(uint64_t sequence) noexcept {
        nativeEnqueueEvents_.fetch_add(1, std::memory_order_relaxed);
        updateMax(lastNativeEnqueueAtNs_, monotonicNowNs());
        updateMax(lastInputSequence_, sequence);
    }

    void recordWriteAttempt(uint64_t sequence) noexcept {
        const uint64_t now = monotonicNowNs();
        writeAttempts_.fetch_add(1, std::memory_order_relaxed);
        updateMax(lastWriteAttemptAtNs_, now);
        recordInputAge(sequence, now, maxInputToWriteAttemptNs_);
    }

    void recordWriteEagain() noexcept {
        writeEagain_.fetch_add(1, std::memory_order_relaxed);
    }

    void recordWriteComplete(uint64_t sequence, size_t byteCount) noexcept {
        const uint64_t now = monotonicNowNs();
        writeCompleteEvents_.fetch_add(1, std::memory_order_relaxed);
        writeBytes_.fetch_add(static_cast<uint64_t>(byteCount), std::memory_order_relaxed);
        updateMax(lastWriteCompleteAtNs_, now);
        recordInputAge(sequence, now, maxInputToWriteCompleteNs_);
    }

    void recordRemoteBytesRead(size_t byteCount) noexcept {
        if (byteCount == 0) {
            return;
        }
        remoteReadEvents_.fetch_add(1, std::memory_order_relaxed);
        remoteReadBytes_.fetch_add(static_cast<uint64_t>(byteCount), std::memory_order_relaxed);
        updateMax(lastRemoteReadAtNs_, monotonicNowNs());
    }

    void recordCallbackAccepted(size_t byteCount) noexcept {
        callbackAcceptedEvents_.fetch_add(1, std::memory_order_relaxed);
        callbackAcceptedBytes_.fetch_add(static_cast<uint64_t>(byteCount), std::memory_order_relaxed);
    }

    void recordCallbackQueueFull() noexcept {
        callbackQueueFull_.fetch_add(1, std::memory_order_relaxed);
    }

    void recordDuplicate() noexcept {
        inputDuplicate_.fetch_add(1, std::memory_order_relaxed);
    }

    void recordLoss() noexcept {
        inputLoss_.fetch_add(1, std::memory_order_relaxed);
    }

    void recordReorder() noexcept {
        inputReorder_.fetch_add(1, std::memory_order_relaxed);
    }

    void recordOwnerStall() noexcept {
        ownerStallEvents_.fetch_add(1, std::memory_order_relaxed);
    }

    void recordInputQueue(uint64_t depth, uint64_t bytes) noexcept {
        inputQueueDepth_.store(depth, std::memory_order_release);
        inputQueueBytes_.store(bytes, std::memory_order_release);
        updateMax(inputQueueMaxDepth_, depth);
        updateMax(inputQueueMaxBytes_, bytes);
    }

    SshTerminalDiagnosticsSnapshot snapshot() const {
        SshTerminalDiagnosticsSnapshot result;
        result.schemaVersion = kSchemaVersion;
        result.sessionId = sessionId_.load(std::memory_order_acquire);
        result.sessionGeneration = sessionGeneration_.load(std::memory_order_acquire);
        result.inputEvents = inputEvents_.load(std::memory_order_relaxed);
        result.inputBytes = inputBytes_.load(std::memory_order_relaxed);
        result.nativeEnqueueEvents = nativeEnqueueEvents_.load(std::memory_order_relaxed);
        result.writeAttempts = writeAttempts_.load(std::memory_order_relaxed);
        result.writeCompleteEvents = writeCompleteEvents_.load(std::memory_order_relaxed);
        result.writeBytes = writeBytes_.load(std::memory_order_relaxed);
        result.writeEagain = writeEagain_.load(std::memory_order_relaxed);
        result.remoteReadEvents = remoteReadEvents_.load(std::memory_order_relaxed);
        result.remoteReadBytes = remoteReadBytes_.load(std::memory_order_relaxed);
        result.callbackAcceptedEvents = callbackAcceptedEvents_.load(std::memory_order_relaxed);
        result.callbackAcceptedBytes = callbackAcceptedBytes_.load(std::memory_order_relaxed);
        result.callbackQueueFull = callbackQueueFull_.load(std::memory_order_relaxed);
        result.inputDuplicate = inputDuplicate_.load(std::memory_order_relaxed);
        result.inputLoss = inputLoss_.load(std::memory_order_relaxed);
        result.inputReorder = inputReorder_.load(std::memory_order_relaxed);
        result.ownerStallEvents = ownerStallEvents_.load(std::memory_order_relaxed);
        result.inputQueueDepth = inputQueueDepth_.load(std::memory_order_acquire);
        result.inputQueueBytes = inputQueueBytes_.load(std::memory_order_acquire);
        result.inputQueueMaxDepth = inputQueueMaxDepth_.load(std::memory_order_relaxed);
        result.inputQueueMaxBytes = inputQueueMaxBytes_.load(std::memory_order_relaxed);
        result.lastInputSequence = lastInputSequence_.load(std::memory_order_acquire);
        result.lastInputCapturedAtNs = lastInputCapturedAtNs_.load(std::memory_order_acquire);
        result.lastNativeEnqueueAtNs = lastNativeEnqueueAtNs_.load(std::memory_order_acquire);
        result.lastWriteAttemptAtNs = lastWriteAttemptAtNs_.load(std::memory_order_acquire);
        result.lastWriteCompleteAtNs = lastWriteCompleteAtNs_.load(std::memory_order_acquire);
        result.lastRemoteReadAtNs = lastRemoteReadAtNs_.load(std::memory_order_acquire);
        result.maxInputToWriteAttemptNs = maxInputToWriteAttemptNs_.load(std::memory_order_relaxed);
        result.maxInputToWriteCompleteNs = maxInputToWriteCompleteNs_.load(std::memory_order_relaxed);
        return result;
    }

private:
    static uint64_t monotonicNowNs() noexcept {
        return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count());
    }

    static void updateMax(std::atomic<uint64_t>& target, uint64_t value) noexcept {
        uint64_t current = target.load(std::memory_order_relaxed);
        while (current < value && !target.compare_exchange_weak(
            current, value, std::memory_order_relaxed, std::memory_order_relaxed)) {
        }
    }

    void recordInputAge(uint64_t sequence, uint64_t now,
                        std::atomic<uint64_t>& maximum) noexcept {
        if (sequence != lastInputSequence_.load(std::memory_order_acquire)) {
            return;
        }
        const uint64_t captured = lastInputCapturedAtNs_.load(std::memory_order_acquire);
        if (captured > 0 && now >= captured) {
            updateMax(maximum, now - captured);
        }
    }

    std::atomic<uint64_t> sessionId_ {0};
    std::atomic<uint64_t> sessionGeneration_ {0};
    std::atomic<uint64_t> nextSequence_ {1};

    std::atomic<uint64_t> inputEvents_ {0};
    std::atomic<uint64_t> inputBytes_ {0};
    std::atomic<uint64_t> nativeEnqueueEvents_ {0};
    std::atomic<uint64_t> writeAttempts_ {0};
    std::atomic<uint64_t> writeCompleteEvents_ {0};
    std::atomic<uint64_t> writeBytes_ {0};
    std::atomic<uint64_t> writeEagain_ {0};
    std::atomic<uint64_t> remoteReadEvents_ {0};
    std::atomic<uint64_t> remoteReadBytes_ {0};
    std::atomic<uint64_t> callbackAcceptedEvents_ {0};
    std::atomic<uint64_t> callbackAcceptedBytes_ {0};
    std::atomic<uint64_t> callbackQueueFull_ {0};
    std::atomic<uint64_t> inputDuplicate_ {0};
    std::atomic<uint64_t> inputLoss_ {0};
    std::atomic<uint64_t> inputReorder_ {0};
    std::atomic<uint64_t> ownerStallEvents_ {0};

    std::atomic<uint64_t> inputQueueDepth_ {0};
    std::atomic<uint64_t> inputQueueBytes_ {0};
    std::atomic<uint64_t> inputQueueMaxDepth_ {0};
    std::atomic<uint64_t> inputQueueMaxBytes_ {0};

    std::atomic<uint64_t> lastInputSequence_ {0};
    std::atomic<uint64_t> lastInputCapturedAtNs_ {0};
    std::atomic<uint64_t> lastNativeEnqueueAtNs_ {0};
    std::atomic<uint64_t> lastWriteAttemptAtNs_ {0};
    std::atomic<uint64_t> lastWriteCompleteAtNs_ {0};
    std::atomic<uint64_t> lastRemoteReadAtNs_ {0};
    std::atomic<uint64_t> maxInputToWriteAttemptNs_ {0};
    std::atomic<uint64_t> maxInputToWriteCompleteNs_ {0};
};

#endif // REMOTEDESK_SSH_TERMINAL_DIAGNOSTICS_H
