#include "test_runner.h"
#include "rustdesk/rustdesk_display_switch_gate.h"

RDP_TEST_CASE(rustdesk_display_switch_requires_ack_then_target_keyframe) {
    RustDeskDisplaySwitchGate gate;
    const auto initial = gate.observeDisplay(0);
    RDP_ASSERT(initial.publishDisplay);
    RDP_ASSERT_EQ(initial.display, 0);

    const uint64_t generation = gate.begin(1);
    RDP_ASSERT_EQ(generation, 1);
    RDP_ASSERT(gate.snapshot().inputBlocked);

    RDP_ASSERT(!gate.observeDisplay(0).publishDisplay);
    RDP_ASSERT(!gate.observeFrame(1, true).acceptFrame);
    RDP_ASSERT(!gate.observeDisplay(1).publishDisplay);
    RDP_ASSERT(!gate.observeFrame(1, false).acceptFrame);

    const auto committed = gate.observeFrame(1, true);
    RDP_ASSERT(committed.acceptFrame);
    RDP_ASSERT(committed.publishDisplay);
    RDP_ASSERT_EQ(committed.display, 1);
    RDP_ASSERT_EQ(gate.snapshot().readyGeneration, generation);
    RDP_ASSERT(!gate.snapshot().inputBlocked);
}

RDP_TEST_CASE(rustdesk_display_switch_latest_generation_wins) {
    RustDeskDisplaySwitchGate gate;
    gate.observeDisplay(0);
    const uint64_t first = gate.begin(1);
    const uint64_t latest = gate.begin(2);
    RDP_ASSERT(latest > first);

    RDP_ASSERT(!gate.observeDisplay(1).publishDisplay);
    RDP_ASSERT(!gate.observeFrame(1, true).acceptFrame);
    RDP_ASSERT(!gate.observeFrame(2, true).acceptFrame);
    RDP_ASSERT(!gate.observeDisplay(2).publishDisplay);

    const auto committed = gate.observeFrame(2, true);
    RDP_ASSERT(committed.acceptFrame);
    RDP_ASSERT_EQ(gate.snapshot().readyGeneration, latest);
    RDP_ASSERT_EQ(gate.snapshot().confirmedDisplay, 2);

    RDP_ASSERT(gate.observeFrame(2, false).acceptFrame);
}

RDP_TEST_CASE(rustdesk_display_switch_accepts_authoritative_post_commit_fallback) {
    RustDeskDisplaySwitchGate gate;
    gate.observeDisplay(0);
    gate.begin(2);
    gate.observeDisplay(2);
    RDP_ASSERT(gate.observeFrame(2, true).acceptFrame);

    const auto fallback = gate.observeDisplay(1);
    RDP_ASSERT(fallback.publishDisplay);
    RDP_ASSERT_EQ(fallback.display, 1);
    RDP_ASSERT(gate.observeFrame(1, true).acceptFrame);
    RDP_ASSERT(!gate.observeFrame(2, true).acceptFrame);
}

RDP_TEST_CASE(rustdesk_display_switch_can_return_to_the_confirmed_display) {
    RustDeskDisplaySwitchGate gate;
    gate.observeDisplay(0);
    gate.begin(1);
    const uint64_t returnGeneration = gate.begin(0);

    gate.observeDisplay(0);
    const auto committed = gate.observeFrame(0, true);
    RDP_ASSERT(committed.acceptFrame);
    RDP_ASSERT_EQ(gate.snapshot().readyGeneration, returnGeneration);
    RDP_ASSERT_EQ(gate.snapshot().confirmedDisplay, 0);
}
