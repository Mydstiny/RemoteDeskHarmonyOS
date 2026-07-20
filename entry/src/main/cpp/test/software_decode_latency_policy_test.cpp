/**
 * software_decode_latency_policy_test.cpp — 软件解码积压展示策略测试
 */

#include "test_runner.h"
#include "render/software_decode_latency_policy.h"

using Render::shouldPresentSoftwareDecodedFrame;

RDP_TEST_CASE(software_decode_presents_when_queue_is_caught_up) {
    RDP_ASSERT(shouldPresentSoftwareDecodedFrame(0));
    RDP_ASSERT(shouldPresentSoftwareDecodedFrame(1));
}

RDP_TEST_CASE(software_decode_skips_expensive_present_for_stale_backlog) {
    RDP_ASSERT(!shouldPresentSoftwareDecodedFrame(2));
    RDP_ASSERT(!shouldPresentSoftwareDecodedFrame(14));
}
