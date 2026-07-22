/**
 * rdp_input_queue_test.cpp - lossless remote input queue contracts
 */

#include "test_runner.h"
#include "rdp/rdp_input_queue.h"
#include "rdp/rdp_keymap.h"

#include <string>
#include <vector>

RDP_TEST_CASE(rdp_input_queue_keeps_large_text_batch_atomic) {
    RdpInputQueue queue;
    std::u16string text(8000, u'\u4e2d');
    RDP_ASSERT(queue.enqueue(RdpQueuedInputEvent::Text(text)) == RdpInputEnqueueResult::Enqueued);
    RDP_ASSERT_EQ(queue.depth(), 1U);
    RDP_ASSERT_EQ(queue.textUnitDepth(), 8000U);
    RdpQueuedInputEvent event;
    RDP_ASSERT(queue.pop(event));
    RDP_ASSERT_EQ(event.text.size(), 8000U);
}

RDP_TEST_CASE(rdp_input_queue_keeps_text_cursor_text_order) {
    RdpInputQueue queue;
    RDP_ASSERT(queue.enqueue(RdpQueuedInputEvent::Text(u"alpha")) == RdpInputEnqueueResult::Enqueued);
    RDP_ASSERT(queue.enqueue(RdpQueuedInputEvent::Key(0, 2014)) == RdpInputEnqueueResult::Enqueued);
    RDP_ASSERT(queue.enqueue(RdpQueuedInputEvent::Text(u"omega")) == RdpInputEnqueueResult::Enqueued);
    RdpQueuedInputEvent event;
    RDP_ASSERT(queue.pop(event));
    RDP_ASSERT_EQ(event.type, RdpInputEventType::TextBatch);
    RDP_ASSERT(queue.pop(event));
    RDP_ASSERT_EQ(event.code, 2014U);
    RDP_ASSERT(queue.pop(event));
    RDP_ASSERT_EQ(event.text.size(), 5U);
}

RDP_TEST_CASE(rdp_input_queue_never_evicts_priority_input) {
    RdpInputQueue queue;
    for (int i = 0; i < 300; ++i) {
        RDP_ASSERT(queue.enqueue(RdpQueuedInputEvent::Key(0, static_cast<uint16_t>(i))) ==
                   RdpInputEnqueueResult::Enqueued);
    }
    RDP_ASSERT_EQ(queue.depth(), 300U);
    RDP_ASSERT_EQ(queue.droppedNonDisposable(), 0U);
    RDP_ASSERT_EQ(queue.nonDisposableOverflow(), 44U);
}

RDP_TEST_CASE(rdp_input_queue_coalesces_and_drops_only_mouse_moves) {
    RdpInputQueue queue;
    RDP_ASSERT(queue.enqueue(RdpQueuedInputEvent::Mouse(0, 0, 10, 20, true)) ==
               RdpInputEnqueueResult::Enqueued);
    RDP_ASSERT(queue.enqueue(RdpQueuedInputEvent::Mouse(0, 0, 30, 40, true)) ==
               RdpInputEnqueueResult::ReplacedMouseMove);
    RDP_ASSERT_EQ(queue.depth(), 1U);
    for (int i = 0; i < 256; ++i) {
        RDP_ASSERT(queue.enqueue(RdpQueuedInputEvent::Key(0, static_cast<uint16_t>(i))) ==
                   RdpInputEnqueueResult::Enqueued);
    }
    RDP_ASSERT(queue.enqueue(RdpQueuedInputEvent::Mouse(0, 0, 50, 60, true)) ==
               RdpInputEnqueueResult::DroppedMouseMove);
    RDP_ASSERT_EQ(queue.droppedMouseMoves(), 3U);
}

RDP_TEST_CASE(rdp_text_dispatch_keeps_down_release_pairs) {
    std::u16string text = { static_cast<char16_t>(0xD83D), static_cast<char16_t>(0xDE00) };
    std::vector<RdpUnicodeDispatch> calls;
    DispatchTextBatch(text, 0x8000, [&calls](uint16_t flags, uint16_t code) {
        calls.push_back({ flags, code });
    });
    RDP_ASSERT_EQ(calls.size(), 4U);
    RDP_ASSERT_EQ(calls[0].flags, 0U);
    RDP_ASSERT_EQ(calls[1].flags, 0x8000U);
    RDP_ASSERT_EQ(calls[0].code, 0xD83DU);
    RDP_ASSERT_EQ(calls[1].code, 0xD83DU);
    RDP_ASSERT_EQ(calls[2].code, 0xDE00U);
    RDP_ASSERT_EQ(calls[3].flags, 0x8000U);
}

RDP_TEST_CASE(rdp_keymap_covers_f13_through_f24_and_extended_keys) {
    RDP_ASSERT_EQ(mapHarmonyKeyCodeToRdpScancode(2816), 0x64U);
    RDP_ASSERT_EQ(mapHarmonyKeyCodeToRdpScancode(2821), 0x69U);
    RDP_ASSERT_EQ(mapHarmonyKeyCodeToRdpScancode(2827), 0x6FU);
    RDP_ASSERT_EQ(mapHarmonyKeyCodeToRdpScancode(2073), 0xE01DU);
    RDP_ASSERT_EQ(mapHarmonyKeyCodeToRdpScancode(2076), 0xE05BU);
    RDP_ASSERT_EQ(mapHarmonyKeyCodeToRdpScancode(2119), 0xE01CU);
}

RDP_TEST_CASE(rdp_pause_is_a_dedicated_atomic_input_event) {
    RDP_ASSERT(isHarmonyPauseKeyCode(2080));
    RDP_ASSERT_EQ(mapHarmonyKeyCodeToRdpScancode(2080), 0U);
    RDP_ASSERT_EQ(mapHarmonyKeyCodeToRdpScancode(2102), 0x45U);

    RdpInputQueue queue;
    RDP_ASSERT(queue.enqueue(RdpQueuedInputEvent::Pause()) == RdpInputEnqueueResult::Enqueued);
    RdpQueuedInputEvent event;
    RDP_ASSERT(queue.pop(event));
    RDP_ASSERT_EQ(event.type, RdpInputEventType::Pause);
}
