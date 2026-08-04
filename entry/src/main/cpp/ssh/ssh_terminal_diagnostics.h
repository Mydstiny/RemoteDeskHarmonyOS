#ifndef REMOTEDESK_SSH_TERMINAL_DIAGNOSTICS_H
#define REMOTEDESK_SSH_TERMINAL_DIAGNOSTICS_H

#include <atomic>
#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <string>

// SSH terminal diagnostics deliberately contain counters and timestamps only.
// They must never retain terminal bytes, commands, credentials, or output.
struct SshTerminalDiagnosticsSnapshot {
    uint64_t schemaVersion = 2;
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
    uint64_t callbackDeliveryErrors = 0;
    uint64_t callbackClosed = 0;
    uint64_t inputDuplicate = 0;
    uint64_t inputLoss = 0;
    uint64_t inputReorder = 0;
    uint64_t ownerStallEvents = 0;
    uint64_t coverageMask = 0;
    bool coverageComplete = false;

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
    static constexpr uint64_t kSchemaVersion = 2;
    // Coverage describes instrumentation compiled into this SSH pipeline, not
    // whether an event has happened in the current snapshot. The three
    // renderer-stage bits are intentionally not SSH requirements: terminal
    // bytes are parsed/presented by terminal_core and do not enter the remote
    // desktop reactor/frame pipeline.
    static constexpr uint64_t kCoverageInputCapture = 1ULL << 0;
    static constexpr uint64_t kCoverageNativeEnqueue = 1ULL << 1;
    static constexpr uint64_t kCoverageWriteAttempt = 1ULL << 2;
    static constexpr uint64_t kCoverageWriteComplete = 1ULL << 3;
    static constexpr uint64_t kCoverageRemoteRead = 1ULL << 4;
    static constexpr uint64_t kCoverageCallbackAccepted = 1ULL << 5;
    static constexpr uint64_t kCoverageCallbackQueueFull = 1ULL << 6;
    static constexpr uint64_t kCoverageInputQueue = 1ULL << 7;
    static constexpr uint64_t kCoverageReactorDequeue = 1ULL << 8;
    static constexpr uint64_t kCoverageCoreParse = 1ULL << 9;
    static constexpr uint64_t kCoverageFramePresent = 1ULL << 10;
    static constexpr uint64_t kRequiredCoverageMask =
        kCoverageInputCapture | kCoverageNativeEnqueue | kCoverageWriteAttempt |
        kCoverageWriteComplete | kCoverageRemoteRead | kCoverageCallbackAccepted |
        kCoverageCallbackQueueFull | kCoverageInputQueue;

    void setSessionIdentity(uint64_t sessionId) noexcept {
        sessionId_.store(sessionId, std::memory_order_release);
    }

    void setSessionGeneration(uint64_t generation) noexcept {
        sessionGeneration_.store(generation, std::memory_order_release);
    }

    uint64_t sessionGeneration() const noexcept {
        return sessionGeneration_.load(std::memory_order_acquire);
    }

    void markCallbackInstrumentation() noexcept {
        coverageMask_.fetch_or(kCoverageCallbackAccepted | kCoverageCallbackQueueFull,
                               std::memory_order_release);
    }

    void markInputQueueInstrumentation() noexcept {
        coverageMask_.fetch_or(kCoverageInputQueue, std::memory_order_release);
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
        const size_t slot = static_cast<size_t>(sequence % kInputTimestampSlots);
        uint64_t version = inputTimestampVersions_[slot].load(std::memory_order_relaxed);
        if ((version & 1ULL) != 0 ||
            !inputTimestampVersions_[slot].compare_exchange_strong(
                version, version + 1, std::memory_order_acq_rel,
                std::memory_order_relaxed)) {
            // A concurrent writer owns this reused slot. Do not spin on the
            // ArkUI path; counters remain valid and this event simply has no
            // age sample.
            return sequence;
        }
        inputTimestampSlots_[slot].store(now, std::memory_order_relaxed);
        inputSequenceSlots_[slot].store(sequence, std::memory_order_release);
        inputTimestampVersions_[slot].store(version + 2, std::memory_order_release);
        return sequence;
    }

    void recordNativeEnqueue(uint64_t sequence) noexcept {
        nativeEnqueueEvents_.fetch_add(1, std::memory_order_relaxed);
        updateMax(lastNativeEnqueueAtNs_, monotonicNowNs());
        updateMax(lastInputSequence_, sequence);
        // Input producers may run concurrently. A high-water mark alone would
        // report a false loss for an arrival pattern such as 1,3,2. Track
        // observed sequences in a fixed atomic table; this path is lock-free
        // and allocation-free so it can stay on the ArkUI input fast path.
        const size_t mask = kMaxTrackedEnqueueSequences - 1;
        size_t slot = static_cast<size_t>((sequence * kSequenceHashMultiplier) & mask);
        for (size_t probe = 0; probe < kMaxTrackedEnqueueSequences; ++probe) {
            uint64_t observed = enqueuedSequenceSlots_[slot].load(std::memory_order_acquire);
            if (observed == sequence) {
                recordDuplicate();
                return;
            }
            const bool stale = (sequence > observed &&
                sequence - observed >= kMaxTrackedEnqueueSequences) ||
                (observed > sequence &&
                observed - sequence >= kMaxTrackedEnqueueSequences);
            if (observed == 0 || stale) {
                if (!enqueuedSequenceSlots_[slot].compare_exchange_weak(
                        observed, sequence, std::memory_order_acq_rel,
                        std::memory_order_acquire)) {
                    continue;
                }
                const uint64_t last = lastEnqueuedSequence_.load(std::memory_order_acquire);
                if (last != 0 && sequence < last) {
                    recordReorder();
                }
                updateMax(lastEnqueuedSequence_, sequence);
                return;
            }
            slot = (slot + 1) & mask;
        }
        // Saturation is a bounded diagnostic sampling limit, not an input
        // failure. Replace one slot and continue without allocation.
        const uint64_t replaced = enqueuedSequenceSlots_[slot].exchange(
            sequence, std::memory_order_acq_rel);
        const uint64_t last = lastEnqueuedSequence_.load(std::memory_order_acquire);
        if (replaced != sequence && last != 0 && sequence < last) {
            recordReorder();
        }
        updateMax(lastEnqueuedSequence_, sequence);
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

    void recordCallbackDeliveryError(bool closing) noexcept {
        callbackDeliveryErrors_.fetch_add(1, std::memory_order_relaxed);
        if (closing) {
            callbackClosed_.fetch_add(1, std::memory_order_relaxed);
        }
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
        coverageMask_.fetch_or(kCoverageInputQueue, std::memory_order_release);
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
        result.callbackDeliveryErrors =
            callbackDeliveryErrors_.load(std::memory_order_relaxed);
        result.callbackClosed = callbackClosed_.load(std::memory_order_relaxed);
        result.inputDuplicate = inputDuplicate_.load(std::memory_order_relaxed);
        result.inputLoss = inputLoss_.load(std::memory_order_relaxed);
        result.inputReorder = inputReorder_.load(std::memory_order_relaxed);
        result.ownerStallEvents = ownerStallEvents_.load(std::memory_order_relaxed);
        result.coverageMask = coverageMask_.load(std::memory_order_relaxed);
        result.coverageComplete =
            (result.coverageMask & kRequiredCoverageMask) == kRequiredCoverageMask;
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
        const size_t slot = static_cast<size_t>(sequence % kInputTimestampSlots);
        // A slot can be reused while it is being sampled. The version is odd
        // during publication and even only after timestamp+sequence are both
        // visible, so an old sequence cannot be paired with a newer timestamp.
        for (int attempt = 0; attempt < 2; ++attempt) {
            const uint64_t versionBefore = inputTimestampVersions_[slot].load(
                std::memory_order_acquire);
            if ((versionBefore & 1ULL) != 0) {
                continue;
            }
            const uint64_t before = inputSequenceSlots_[slot].load(std::memory_order_acquire);
            if (before != sequence) {
                return;
            }
            const uint64_t captured = inputTimestampSlots_[slot].load(std::memory_order_relaxed);
            const uint64_t after = inputSequenceSlots_[slot].load(std::memory_order_acquire);
            const uint64_t versionAfter = inputTimestampVersions_[slot].load(
                std::memory_order_acquire);
            if (before != after || versionBefore != versionAfter ||
                (versionAfter & 1ULL) != 0) {
                continue;
            }
            if (captured > 0 && now >= captured) {
                updateMax(maximum, now - captured);
            }
            return;
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
    std::atomic<uint64_t> callbackDeliveryErrors_ {0};
    std::atomic<uint64_t> callbackClosed_ {0};
    std::atomic<uint64_t> inputDuplicate_ {0};
    std::atomic<uint64_t> inputLoss_ {0};
    std::atomic<uint64_t> inputReorder_ {0};
    std::atomic<uint64_t> ownerStallEvents_ {0};
    std::atomic<uint64_t> lastEnqueuedSequence_ {0};
    static constexpr uint64_t kSequenceHashMultiplier = 11400714819323198485ull;
    static constexpr size_t kMaxTrackedEnqueueSequences = 8192;
    std::array<std::atomic<uint64_t>, kMaxTrackedEnqueueSequences> enqueuedSequenceSlots_ {};
    std::atomic<uint64_t> coverageMask_ {
        kCoverageInputCapture | kCoverageNativeEnqueue | kCoverageWriteAttempt |
        kCoverageWriteComplete | kCoverageRemoteRead | kCoverageCallbackAccepted |
        kCoverageCallbackQueueFull | kCoverageInputQueue
    };

    static constexpr size_t kInputTimestampSlots = 4096;
    std::array<std::atomic<uint64_t>, kInputTimestampSlots> inputSequenceSlots_ {};
    std::array<std::atomic<uint64_t>, kInputTimestampSlots> inputTimestampSlots_ {};
    std::array<std::atomic<uint64_t>, kInputTimestampSlots> inputTimestampVersions_ {};

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
