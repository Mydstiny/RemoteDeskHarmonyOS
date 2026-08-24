/**
 * ssh_terminal_diagnostics_test.cpp - payload-free SSH terminal telemetry
 * tests.
 */

#include "test_runner.h"
#include "ssh/ssh_terminal_diagnostics.h"
#include "ssh/ssh_terminal_input_queue_policy.h"
#include "ssh/ssh_terminal_keepalive_policy.h"
#include "ssh/ssh_terminal_resume_policy.h"

#include <chrono>
#include <thread>
#include <vector>

RDP_TEST_CASE(ssh_terminal_keepalive_uses_interval_and_retries_transient_failures) {
    using Policy = SshTerminalKeepalivePolicy;
    RDP_ASSERT_EQ(Policy::intervalSeconds(0), Policy::kIntervalSeconds);
    RDP_ASSERT_EQ(Policy::intervalSeconds(12), 12);
    RDP_ASSERT(Policy::retryableFailure(1));
    RDP_ASSERT(Policy::retryableFailure(2));
    RDP_ASSERT(!Policy::retryableFailure(Policy::kMaxConsecutiveFailures));
}

RDP_TEST_CASE(ssh_terminal_resume_policy_keeps_reconnecting_page_bound) {
    namespace Policy = SshTerminalResumePolicy;
    RDP_ASSERT(!Policy::acceptsPageBinding(ConnectionState::CONNECTED, false));
    RDP_ASSERT(Policy::acceptsPageBinding(ConnectionState::CONNECTING, true));
    RDP_ASSERT(Policy::acceptsPageBinding(ConnectionState::CONNECTED, true));
    RDP_ASSERT(Policy::acceptsPageBinding(ConnectionState::RECONNECTING, true));
    RDP_ASSERT(!Policy::acceptsPageBinding(ConnectionState::ERROR, true));
    RDP_ASSERT(Policy::shouldResumeInput(ConnectionState::CONNECTED));
    RDP_ASSERT(!Policy::shouldResumeInput(ConnectionState::RECONNECTING));
    RDP_ASSERT(Policy::acceptsSharedSinkActivation(false, false));
    RDP_ASSERT(Policy::acceptsSharedSinkActivation(false, true));
    RDP_ASSERT(Policy::acceptsSharedSinkActivation(true, true));
    RDP_ASSERT(!Policy::acceptsSharedSinkActivation(true, false));
    RDP_ASSERT(Policy::shouldReleaseSharedSinkOnDetach(true, true));
    RDP_ASSERT(!Policy::shouldReleaseSharedSinkOnDetach(true, false));
    RDP_ASSERT(!Policy::shouldReleaseSharedSinkOnDetach(false, true));
    RDP_ASSERT(Policy::acceptsDetachSharedSinkRelease(true, false, false));
    RDP_ASSERT(Policy::acceptsDetachSharedSinkRelease(false, true, false));
    RDP_ASSERT(Policy::acceptsDetachSharedSinkRelease(true, true, true));
    RDP_ASSERT(!Policy::acceptsDetachSharedSinkRelease(true, true, false));
    RDP_ASSERT(!Policy::shouldRedeliverCallback(true, false));
    RDP_ASSERT(!Policy::shouldRedeliverCallback(true, true));
    RDP_ASSERT(!Policy::shouldRedeliverCallback(false, false));
    RDP_ASSERT(Policy::shouldRedeliverCallback(false, true));
}

RDP_TEST_CASE(ssh_terminal_input_queue_policy_reserves_control_capacity) {
    using Policy = SshTerminalInputQueuePolicy;
    const auto dataFull = Policy::admit(
        Policy::kMaxDataItems, Policy::kMaxDataBytes,
        0, 0, Policy::kMaxDataItems, Policy::kMaxDataBytes,
        1, false, 7, 7);
    RDP_ASSERT(dataFull == Policy::Admission::QUEUE_FULL);

    const auto controlAccepted = Policy::admit(
        Policy::kMaxDataItems, Policy::kMaxDataBytes,
        0, 0, Policy::kMaxDataItems, Policy::kMaxDataBytes,
        2, true, 7, 7);
    RDP_ASSERT(controlAccepted == Policy::Admission::ACCEPTED);

    const auto controlFull = Policy::admit(
        Policy::kMaxItems, Policy::kMaxBytes,
        Policy::kMaxControlItems, Policy::kMaxControlBytes,
        0, 0, 1, true, 7, 7);
    RDP_ASSERT(controlFull == Policy::Admission::QUEUE_FULL);
}

RDP_TEST_CASE(ssh_terminal_input_queue_policy_rejects_stale_and_invalid) {
    using Policy = SshTerminalInputQueuePolicy;
    const auto stale = Policy::admit(0, 0, 0, 0, 0, 0,
                                     1, false, 9, 10);
    RDP_ASSERT(stale == Policy::Admission::STALE_GENERATION);
    const auto invalid = Policy::admit(0, 0, 0, 0, 0, 0,
                                       0, false, 10, 10);
    RDP_ASSERT(invalid == Policy::Admission::INVALID);
}

RDP_TEST_CASE(ssh_terminal_input_queue_policy_rejects_oversized_quota_item) {
    using Policy = SshTerminalInputQueuePolicy;
    const auto oversizedControl = Policy::admit(
        0, 0, 0, 0, 0, 0, Policy::kMaxControlBytes + 1,
        true, 11, 11);
    RDP_ASSERT(oversizedControl == Policy::Admission::QUEUE_FULL);

    const auto oversizedData = Policy::admit(
        0, 0, 0, 0, 0, 0, Policy::kMaxDataBytes + 1,
        false, 11, 11);
    RDP_ASSERT(oversizedData == Policy::Admission::QUEUE_FULL);
}

RDP_TEST_CASE(ssh_terminal_diagnostics_preserves_session_identity) {
    SshTerminalDiagnostics diagnostics;
    diagnostics.setSessionIdentity(42);
    diagnostics.setSessionGeneration(9001);

    const SshTerminalDiagnosticsSnapshot snapshot = diagnostics.snapshot();
    RDP_ASSERT_EQ(snapshot.schemaVersion, 2ULL);
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
    diagnostics.markCallbackInstrumentation();
    diagnostics.recordCallbackAccepted(5);
    diagnostics.recordCallbackQueueFull();
    diagnostics.recordCallbackDeliveryError(false);
    diagnostics.recordCallbackDeliveryError(true);
    diagnostics.recordDuplicate();
    diagnostics.recordLoss();
    diagnostics.recordReorder();
    diagnostics.recordOwnerStall();
    diagnostics.markInputQueueInstrumentation();
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
    RDP_ASSERT_EQ(snapshot.callbackDeliveryErrors, 2ULL);
    RDP_ASSERT_EQ(snapshot.callbackClosed, 1ULL);
    RDP_ASSERT_EQ(snapshot.inputDuplicate, 1ULL);
    RDP_ASSERT_EQ(snapshot.inputLoss, 1ULL);
    RDP_ASSERT_EQ(snapshot.inputReorder, 1ULL);
    RDP_ASSERT_EQ(snapshot.ownerStallEvents, 1ULL);
    RDP_ASSERT((snapshot.coverageMask & SshTerminalDiagnostics::kCoverageInputCapture) != 0);
    RDP_ASSERT((snapshot.coverageMask & SshTerminalDiagnostics::kCoverageNativeEnqueue) != 0);
    RDP_ASSERT((snapshot.coverageMask & SshTerminalDiagnostics::kCoverageWriteAttempt) != 0);
    RDP_ASSERT((snapshot.coverageMask & SshTerminalDiagnostics::kCoverageRemoteRead) != 0);
    RDP_ASSERT((snapshot.coverageMask & SshTerminalDiagnostics::kCoverageCallbackAccepted) != 0);
    RDP_ASSERT((snapshot.coverageMask & SshTerminalDiagnostics::kCoverageCallbackQueueFull) != 0);
    RDP_ASSERT((snapshot.coverageMask & SshTerminalDiagnostics::kCoverageInputQueue) != 0);
    RDP_ASSERT(snapshot.coverageComplete);
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

RDP_TEST_CASE(ssh_terminal_diagnostics_tracks_older_concurrent_input_age) {
    SshTerminalDiagnostics diagnostics;
    const uint64_t first = diagnostics.beginInput(1);
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
    const uint64_t second = diagnostics.beginInput(1);
    diagnostics.recordWriteAttempt(second);
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
    diagnostics.recordWriteAttempt(first);

    const SshTerminalDiagnosticsSnapshot snapshot = diagnostics.snapshot();
    RDP_ASSERT(second > first);
    RDP_ASSERT(snapshot.maxInputToWriteAttemptNs >= 4'000'000ULL);
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

RDP_TEST_CASE(ssh_terminal_adapter_enqueue_publishes_assigned_sequence) {
    // SshAdapter::enqueueTerminalInput assigns the sequence returned by
    // beginInput() to the accepted queue item before publishing the native
    // enqueue event. Keep two accepted events here so publishing the default
    // result value (zero) regresses as a duplicate immediately.
    SshTerminalDiagnostics diagnostics;
    const uint64_t first = diagnostics.beginInput(1);
    const uint64_t second = diagnostics.beginInput(1);
    diagnostics.recordNativeEnqueue(first);
    diagnostics.recordNativeEnqueue(second);

    const SshTerminalDiagnosticsSnapshot snapshot = diagnostics.snapshot();
    RDP_ASSERT_EQ(snapshot.nativeEnqueueEvents, 2ULL);
    RDP_ASSERT_EQ(snapshot.inputDuplicate, 0ULL);
    RDP_ASSERT_EQ(snapshot.inputReorder, 0ULL);
    RDP_ASSERT_EQ(snapshot.lastInputSequence, second);
}

RDP_TEST_CASE(ssh_terminal_diagnostics_does_not_infer_loss_from_concurrent_order) {
    SshTerminalDiagnostics diagnostics;
    const uint64_t first = diagnostics.beginInput(1);
    const uint64_t second = diagnostics.beginInput(1);
    const uint64_t third = diagnostics.beginInput(1);
    diagnostics.recordNativeEnqueue(first);
    diagnostics.recordNativeEnqueue(third);
    diagnostics.recordNativeEnqueue(second);
    diagnostics.recordNativeEnqueue(second);

    const SshTerminalDiagnosticsSnapshot snapshot = diagnostics.snapshot();
    RDP_ASSERT_EQ(snapshot.inputLoss, 0ULL);
    RDP_ASSERT_EQ(snapshot.inputReorder, 1ULL);
    RDP_ASSERT_EQ(snapshot.inputDuplicate, 1ULL);
}

RDP_TEST_CASE(ssh_terminal_diagnostics_rejects_wrapped_timestamp_slot) {
    SshTerminalDiagnostics diagnostics;
    const uint64_t first = diagnostics.beginInput(1);
    constexpr size_t kSlots = 4096;
    for (size_t index = 0; index < kSlots; ++index) {
        diagnostics.beginInput(1);
    }
    diagnostics.recordWriteAttempt(first);
    const SshTerminalDiagnosticsSnapshot snapshot = diagnostics.snapshot();
    // The first sequence's slot has been reused. A timestamp from the newer
    // event must not be attributed to the old event.
    RDP_ASSERT_EQ(snapshot.maxInputToWriteAttemptNs, 0ULL);
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
