/**
 * ssh_terminal_diagnostics_test.cpp - payload-free SSH terminal telemetry
 * tests.
 */

#include "test_runner.h"
#include "ssh/ssh_terminal_diagnostics.h"

#include <chrono>
#include <thread>
#include <vector>

RDP_TEST_CASE(ssh_terminal_diagnostics_preserves_session_identity) {
    SshTerminalDiagnostics diagnostics;
    diagnostics.setSessionIdentity(42);
    diagnostics.setSessionGeneration(9001);

    const SshTerminalDiagnosticsSnapshot snapshot = diagnostics.snapshot();
    RDP_ASSERT_EQ(snapshot.schemaVersion, 1ULL);
    RDP_ASSERT_EQ(snapshot.sessionId, 42ULL);
    RDP_ASSERT_EQ(snapshot.sessionGeneration, 9001ULL);
    RDP_ASSERT(snapshot.channelId == "pty");
    RDP_ASSERT_EQ(snapshot.inputEvents, 0ULL);
    RDP_ASSERT_EQ(snapshot.inputBytes, 0ULL);
}

RDP_TEST_CASE(ssh_terminal_diagnostics_tracks_input_write_and_read_counters) {
    SshTerminalDiagnostics diagnostics;
    const uint64_t sequence = diagnostics.beginInput(3);
    diagnostics.recordNativeEnqueue(sequence);
    diagnostics.recordWriteAttempt(sequence);
    diagnostics.recordWriteEagain();
    diagnostics.recordWriteComplete(sequence, 3);
    diagnostics.recordRemoteBytesRead(5);
    diagnostics.recordCallbackAccepted(5);
    diagnostics.recordCallbackQueueFull();
    diagnostics.recordDuplicate();
    diagnostics.recordLoss();
    diagnostics.recordReorder();
    diagnostics.recordOwnerStall();
    diagnostics.recordInputQueue(2, 7);
    diagnostics.recordInputQueue(1, 4);

    const SshTerminalDiagnosticsSnapshot snapshot = diagnostics.snapshot();
    RDP_ASSERT_EQ(snapshot.inputEvents, 1ULL);
    RDP_ASSERT_EQ(snapshot.inputBytes, 3ULL);
    RDP_ASSERT_EQ(snapshot.nativeEnqueueEvents, 1ULL);
    RDP_ASSERT_EQ(snapshot.writeAttempts, 1ULL);
    RDP_ASSERT_EQ(snapshot.writeCompleteEvents, 1ULL);
    RDP_ASSERT_EQ(snapshot.writeBytes, 3ULL);
    RDP_ASSERT_EQ(snapshot.writeEagain, 1ULL);
    RDP_ASSERT_EQ(snapshot.remoteReadEvents, 1ULL);
    RDP_ASSERT_EQ(snapshot.remoteReadBytes, 5ULL);
    RDP_ASSERT_EQ(snapshot.callbackAcceptedEvents, 1ULL);
    RDP_ASSERT_EQ(snapshot.callbackAcceptedBytes, 5ULL);
    RDP_ASSERT_EQ(snapshot.callbackQueueFull, 1ULL);
    RDP_ASSERT_EQ(snapshot.inputDuplicate, 1ULL);
    RDP_ASSERT_EQ(snapshot.inputLoss, 1ULL);
    RDP_ASSERT_EQ(snapshot.inputReorder, 1ULL);
    RDP_ASSERT_EQ(snapshot.ownerStallEvents, 1ULL);
    RDP_ASSERT_EQ(snapshot.inputQueueDepth, 1ULL);
    RDP_ASSERT_EQ(snapshot.inputQueueBytes, 4ULL);
    RDP_ASSERT_EQ(snapshot.inputQueueMaxDepth, 2ULL);
    RDP_ASSERT_EQ(snapshot.inputQueueMaxBytes, 7ULL);
    RDP_ASSERT_EQ(snapshot.lastInputSequence, sequence);
    RDP_ASSERT(snapshot.lastInputCapturedAtNs > 0);
    RDP_ASSERT(snapshot.lastNativeEnqueueAtNs > 0);
    RDP_ASSERT(snapshot.lastWriteAttemptAtNs > 0);
    RDP_ASSERT(snapshot.lastWriteCompleteAtNs > 0);
    RDP_ASSERT(snapshot.lastRemoteReadAtNs > 0);
    RDP_ASSERT(snapshot.maxInputToWriteAttemptNs <= snapshot.maxInputToWriteCompleteNs);
}

RDP_TEST_CASE(ssh_terminal_diagnostics_sequences_are_monotonic_and_payload_free) {
    SshTerminalDiagnostics diagnostics;
    const uint64_t first = diagnostics.beginInput(1);
    const SshTerminalDiagnosticsSnapshot firstSnapshot = diagnostics.snapshot();

    std::this_thread::sleep_for(std::chrono::microseconds(1));
    const uint64_t second = diagnostics.beginInput(2);
    diagnostics.recordNativeEnqueue(second);
    diagnostics.recordWriteAttempt(second);
    const SshTerminalDiagnosticsSnapshot secondSnapshot = diagnostics.snapshot();

    RDP_ASSERT(second > first);
    RDP_ASSERT_EQ(firstSnapshot.lastInputSequence, first);
    RDP_ASSERT_EQ(secondSnapshot.lastInputSequence, second);
    RDP_ASSERT(secondSnapshot.lastInputCapturedAtNs >= firstSnapshot.lastInputCapturedAtNs);
    RDP_ASSERT(secondSnapshot.lastNativeEnqueueAtNs >= firstSnapshot.lastNativeEnqueueAtNs);
    RDP_ASSERT(secondSnapshot.lastWriteAttemptAtNs >= firstSnapshot.lastWriteAttemptAtNs);
    // The contract intentionally has counters/timestamps only: no input or
    // output byte buffer is retained by SshTerminalDiagnostics.
    RDP_ASSERT(secondSnapshot.channelId == "pty");
}

RDP_TEST_CASE(ssh_terminal_diagnostics_keeps_sequence_and_clock_monotonic_under_concurrency) {
    SshTerminalDiagnostics diagnostics;
    constexpr int kWorkers = 4;
    constexpr int kEventsPerWorker = 250;
    std::vector<std::thread> workers;
    workers.reserve(kWorkers);
    for (int worker = 0; worker < kWorkers; ++worker) {
        workers.emplace_back([&diagnostics]() {
            for (int event = 0; event < kEventsPerWorker; ++event) {
                const uint64_t sequence = diagnostics.beginInput(1);
                diagnostics.recordNativeEnqueue(sequence);
                diagnostics.recordWriteAttempt(sequence);
            }
        });
    }
    for (auto& worker : workers) {
        worker.join();
    }

    const SshTerminalDiagnosticsSnapshot snapshot = diagnostics.snapshot();
    RDP_ASSERT_EQ(snapshot.inputEvents, static_cast<uint64_t>(kWorkers * kEventsPerWorker));
    RDP_ASSERT_EQ(snapshot.inputBytes, static_cast<uint64_t>(kWorkers * kEventsPerWorker));
    RDP_ASSERT_EQ(snapshot.nativeEnqueueEvents,
                  static_cast<uint64_t>(kWorkers * kEventsPerWorker));
    RDP_ASSERT_EQ(snapshot.writeAttempts, static_cast<uint64_t>(kWorkers * kEventsPerWorker));
    RDP_ASSERT_EQ(snapshot.lastInputSequence,
                  static_cast<uint64_t>(kWorkers * kEventsPerWorker));
    RDP_ASSERT(snapshot.lastInputCapturedAtNs > 0);
    RDP_ASSERT(snapshot.lastNativeEnqueueAtNs >= snapshot.lastInputCapturedAtNs);
    RDP_ASSERT(snapshot.lastWriteAttemptAtNs >= snapshot.lastNativeEnqueueAtNs);
}
