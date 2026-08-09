/**
 * software_decode_latency_policy_test.cpp — 软件解码积压展示策略测试
 */

#include "test_runner.h"
#include "render/software_decode_latency_policy.h"

using Render::shouldPresentSoftwareDecodedFrame;
using Render::SoftwareDecodeQueueAction;
using Render::SoftwareDecodeQueueRecoveryPolicy;

RDP_TEST_CASE(software_decode_presents_when_queue_is_caught_up) {
    RDP_ASSERT(shouldPresentSoftwareDecodedFrame(0));
    RDP_ASSERT(shouldPresentSoftwareDecodedFrame(1));
}

RDP_TEST_CASE(software_decode_skips_expensive_present_for_stale_backlog) {
    RDP_ASSERT(!shouldPresentSoftwareDecodedFrame(2));
    RDP_ASSERT(!shouldPresentSoftwareDecodedFrame(14));
}

RDP_TEST_CASE(software_decode_overflow_requests_one_keyframe_until_recovery) {
    SoftwareDecodeQueueRecoveryPolicy recovery;

    RDP_ASSERT(recovery.classify(false, false) == SoftwareDecodeQueueAction::Queue);
    RDP_ASSERT(recovery.classify(true, false) ==
               SoftwareDecodeQueueAction::DropAndRequestKeyframe);
    RDP_ASSERT(recovery.waitingForKeyframe());
    RDP_ASSERT(recovery.classify(false, false) ==
               SoftwareDecodeQueueAction::DropWaitingKeyframe);
    RDP_ASSERT(recovery.classify(true, false) ==
               SoftwareDecodeQueueAction::DropWaitingKeyframe);
    RDP_ASSERT(recovery.classify(false, true) ==
               SoftwareDecodeQueueAction::QueueAfterReset);
    RDP_ASSERT(!recovery.waitingForKeyframe());
    RDP_ASSERT(recovery.classify(false, false) == SoftwareDecodeQueueAction::Queue);
}

RDP_TEST_CASE(software_decode_full_queue_accepts_keyframe_as_fresh_restart) {
    SoftwareDecodeQueueRecoveryPolicy recovery;

    RDP_ASSERT(recovery.classify(true, true) ==
               SoftwareDecodeQueueAction::QueueAfterReset);
    RDP_ASSERT(!recovery.waitingForKeyframe());
}

RDP_TEST_CASE(software_decode_recovery_reset_allows_new_overflow_request) {
    SoftwareDecodeQueueRecoveryPolicy recovery;

    RDP_ASSERT(recovery.classify(true, false) ==
               SoftwareDecodeQueueAction::DropAndRequestKeyframe);
    recovery.reset();
    RDP_ASSERT(!recovery.waitingForKeyframe());
    RDP_ASSERT(recovery.classify(true, false) ==
               SoftwareDecodeQueueAction::DropAndRequestKeyframe);
}
