/**
 * rdp_input_queue_test.cpp - lossless remote input queue contracts
 */

#include "test_runner.h"
#include "rdp/rdp_input_queue.h"
#include "rdp/rdp_keymap.h"
#include "extensions/key_sequence_dispatch.h"

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

RDP_TEST_CASE(rdp_input_queue_coalesces_high_rate_mouse_moves_without_a_backlog) {
    RdpInputQueue queue;
    for (int i = 0; i < 1000; ++i) {
        const RdpInputEnqueueResult result = queue.enqueue(
            RdpQueuedInputEvent::Mouse(0, 0, i, i + 1, true));
        RDP_ASSERT(result == (i == 0 ? RdpInputEnqueueResult::Enqueued :
                                     RdpInputEnqueueResult::ReplacedMouseMove));
    }
    RDP_ASSERT_EQ(queue.depth(), 1U);
    RDP_ASSERT_EQ(queue.droppedMouseMoves(), 999U);
    RdpQueuedInputEvent event;
    RDP_ASSERT(queue.pop(event));
    RDP_ASSERT(event.isMouseMove);
    RDP_ASSERT_EQ(event.x, 999);
    RDP_ASSERT_EQ(event.y, 1000);
}

RDP_TEST_CASE(rdp_input_queue_flushes_latest_target_before_click_barrier) {
    RdpInputQueue queue;
    RDP_ASSERT(queue.enqueue(RdpQueuedInputEvent::Mouse(0, 0, 10, 20, true)) ==
               RdpInputEnqueueResult::Enqueued);
    RDP_ASSERT(queue.enqueue(RdpQueuedInputEvent::Mouse(0, 0, 30, 40, true)) ==
               RdpInputEnqueueResult::ReplacedMouseMove);
    RDP_ASSERT(queue.enqueue(RdpQueuedInputEvent::Mouse(0x9000, 0, 30, 40, false)) ==
               RdpInputEnqueueResult::Enqueued);

    RdpQueuedInputEvent event;
    RDP_ASSERT(queue.pop(event));
    RDP_ASSERT(event.isMouseMove);
    RDP_ASSERT_EQ(event.x, 30);
    RDP_ASSERT_EQ(event.y, 40);
    RDP_ASSERT(queue.pop(event));
    RDP_ASSERT(!event.isMouseMove);
    RDP_ASSERT_EQ(event.flags, 0x9000U);
}

RDP_TEST_CASE(rdp_input_queue_preserves_wheel_text_and_move_order) {
    RdpInputQueue queue;
    RDP_ASSERT(queue.enqueue(RdpQueuedInputEvent::Mouse(0, 0, 11, 12, true)) ==
               RdpInputEnqueueResult::Enqueued);
    RDP_ASSERT(queue.enqueue(RdpQueuedInputEvent::Text(u"first")) ==
               RdpInputEnqueueResult::Enqueued);
    RDP_ASSERT(queue.enqueue(RdpQueuedInputEvent::Mouse(0, 0, 21, 22, true)) ==
               RdpInputEnqueueResult::Enqueued);
    RDP_ASSERT(queue.enqueue(RdpQueuedInputEvent::MouseWheel(0x0200, 0, 21, 22)) ==
               RdpInputEnqueueResult::Enqueued);
    RDP_ASSERT(queue.enqueue(RdpQueuedInputEvent::Text(u"second")) ==
               RdpInputEnqueueResult::Enqueued);

    RdpQueuedInputEvent event;
    RDP_ASSERT(queue.pop(event));
    RDP_ASSERT(event.isMouseMove);
    RDP_ASSERT_EQ(event.x, 11);
    RDP_ASSERT(queue.pop(event));
    RDP_ASSERT_EQ(event.type, RdpInputEventType::TextBatch);
    RDP_ASSERT(queue.pop(event));
    RDP_ASSERT(event.isMouseMove);
    RDP_ASSERT_EQ(event.x, 21);
    RDP_ASSERT(queue.pop(event));
    RDP_ASSERT_EQ(event.type, RdpInputEventType::MouseWheel);
    RDP_ASSERT(queue.pop(event));
    RDP_ASSERT_EQ(event.type, RdpInputEventType::TextBatch);
    RDP_ASSERT_EQ(event.text.size(), 6U);
}

RDP_TEST_CASE(rdp_input_queue_clear_drops_pending_move_with_the_generation) {
    RdpInputQueue queue;
    RDP_ASSERT(queue.enqueue(RdpQueuedInputEvent::Mouse(0, 0, 55, 66, true)) ==
               RdpInputEnqueueResult::Enqueued);
    queue.clear();
    RdpQueuedInputEvent event;
    RDP_ASSERT(!queue.pop(event));
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

RDP_TEST_CASE(rdp_keymap_maps_harmony_consumer_keys_to_extended_scancodes) {
    RDP_ASSERT_EQ(mapHarmonyKeyCodeToRdpScancode(10), 0xE022U);
    RDP_ASSERT_EQ(mapHarmonyKeyCodeToRdpScancode(12), 0xE019U);
    RDP_ASSERT_EQ(mapHarmonyKeyCodeToRdpScancode(13), 0xE010U);
    RDP_ASSERT_EQ(mapHarmonyKeyCodeToRdpScancode(16), 0xE030U);
    RDP_ASSERT_EQ(mapHarmonyKeyCodeToRdpScancode(17), 0xE02EU);
}

RDP_TEST_CASE(rdp_keymap_covers_every_key_family_used_by_shortcut_catalogs) {
    for (uint32_t keyCode = 2017; keyCode <= 2042; ++keyCode) {
        RDP_ASSERT(mapHarmonyKeyCodeToRdpScancode(keyCode) != 0U);
    }
    for (uint32_t keyCode = 2000; keyCode <= 2009; ++keyCode) {
        RDP_ASSERT(mapHarmonyKeyCodeToRdpScancode(keyCode) != 0U);
    }
    for (uint32_t keyCode = 2090; keyCode <= 2101; ++keyCode) {
        RDP_ASSERT(mapHarmonyKeyCodeToRdpScancode(keyCode) != 0U);
    }
    for (uint32_t keyCode = 2816; keyCode <= 2827; ++keyCode) {
        RDP_ASSERT(mapHarmonyKeyCodeToRdpScancode(keyCode) != 0U);
    }
    const std::vector<uint32_t> catalogControls {
        2012U, 2013U, 2014U, 2015U, 2043U, 2044U, 2045U, 2047U,
        2049U, 2050U, 2054U, 2055U, 2056U, 2057U, 2058U, 2059U,
        2060U, 2070U, 2071U, 2072U, 2076U, 2079U, 2081U, 2082U
    };
    for (uint32_t keyCode : catalogControls) {
        RDP_ASSERT(mapHarmonyKeyCodeToRdpScancode(keyCode) != 0U);
    }
}

RDP_TEST_CASE(remote_key_sequence_dispatches_all_down_then_reverse_up) {
    struct KeyStep {
        uint32_t keyCode;
        bool pressed;
    };
    const std::vector<uint32_t> chord {2076U, 2072U, 2047U, 2018U};
    std::vector<KeyStep> steps;
    DispatchKeySequence(chord, [&steps](uint32_t keyCode, bool pressed) {
        steps.push_back({keyCode, pressed});
    });
    RDP_ASSERT_EQ(steps.size(), 8U);
    RDP_ASSERT_EQ(steps[0].keyCode, 2076U);
    RDP_ASSERT(steps[0].pressed);
    RDP_ASSERT_EQ(steps[3].keyCode, 2018U);
    RDP_ASSERT(steps[3].pressed);
    RDP_ASSERT_EQ(steps[4].keyCode, 2018U);
    RDP_ASSERT(!steps[4].pressed);
    RDP_ASSERT_EQ(steps[7].keyCode, 2076U);
    RDP_ASSERT(!steps[7].pressed);
}

RDP_TEST_CASE(rdp_remote_security_chord_keys_have_extended_scancodes) {
    RDP_ASSERT_EQ(mapHarmonyKeyCodeToRdpScancode(2072), 0x1DU);
    RDP_ASSERT_EQ(mapHarmonyKeyCodeToRdpScancode(2045), 0x38U);
    RDP_ASSERT_EQ(mapHarmonyKeyCodeToRdpScancode(2082), 0xE04FU);
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

RDP_TEST_CASE(rdp_input_geometry_fence_rejects_old_pointer_epochs_across_unsolicited_resize) {
    RdpInputGeometryFence fence;
    fence.reset(0, 1600, 1000);
    RDP_ASSERT(fence.snapshot().ready);
    const RdpInputGeometrySnapshot oldGeometry = fence.captureGeometry();
    RDP_ASSERT_EQ(oldGeometry.epoch, 0ULL);
    RDP_ASSERT_EQ(oldGeometry.width, 1600);
    RDP_ASSERT_EQ(oldGeometry.height, 1000);

    // A server-initiated resize closes the native gate synchronously, before
    // ArkTS's next 500 ms geometry poll can observe the new desktop.
    fence.beginResize(1, 3200, 2000);
    RDP_ASSERT(!fence.snapshot().ready);
    int moveX = 1599;
    int moveY = 999;
    RDP_ASSERT(!fence.preparePointer(
        oldGeometry.epoch, oldGeometry.width, oldGeometry.height,
        false, moveX, moveY));
    int releaseX = 1599;
    int releaseY = 999;
    RDP_ASSERT(fence.preparePointer(
        oldGeometry.epoch, oldGeometry.width, oldGeometry.height,
        true, releaseX, releaseY));
    RDP_ASSERT_EQ(releaseX, 3199);
    RDP_ASSERT_EQ(releaseY, 1999);
    RDP_ASSERT(!fence.acknowledge(0, 1600, 1000));
    RDP_ASSERT(fence.acknowledge(1, 3200, 2000));
    RDP_ASSERT(fence.snapshot().ready);
    int currentX = 3199;
    int currentY = 1999;
    RDP_ASSERT(fence.preparePointer(1, 3200, 2000, false, currentX, currentY));

    // An event captured immediately before the next resize is rejected by
    // the worker even if it was already queued when the epoch advanced.
    const RdpInputGeometrySnapshot firstGeometry = fence.captureGeometry();
    fence.beginResize(2, 2560, 1600);
    int staleX = 100;
    int staleY = 100;
    RDP_ASSERT(!fence.preparePointer(
        firstGeometry.epoch, firstGeometry.width, firstGeometry.height,
        false, staleX, staleY));
    RDP_ASSERT(!fence.acknowledge(1, 3200, 2000));
    RDP_ASSERT(fence.acknowledge(2, 2560, 1600));
    const RdpInputGeometryFenceSnapshot snapshot = fence.snapshot();
    RDP_ASSERT(snapshot.ready);
    RDP_ASSERT_EQ(snapshot.acknowledgedEpoch, 2ULL);
    RDP_ASSERT_EQ(snapshot.droppedPointerEvents, 2ULL);
}

RDP_TEST_CASE(rdp_final_pointer_queue_rechecks_epoch_at_transport_dispatch) {
    RdpInputGeometryFence fence;
    fence.reset(0, 1600, 1000);
    const RdpInputGeometrySnapshot captured = fence.captureGeometry();
    RdpFinalPointerQueue finalQueue;
    finalQueue.push(RdpQueuedInputEvent::Mouse(
        0, 0, 1599, 999, true, captured.epoch,
        captured.width, captured.height));

    // Model the exact production interleave: the input worker has already
    // posted its notification, then DesktopResize advances the epoch before
    // the event loop performs the final FreeRDP send.
    fence.beginResize(1, 3200, 2000);
    RdpQueuedInputEvent staleMove;
    RDP_ASSERT(finalQueue.pop(staleMove));
    int staleX = staleMove.x;
    int staleY = staleMove.y;
    RDP_ASSERT(!fence.preparePointer(
        staleMove.geometryEpoch, staleMove.geometryWidth,
        staleMove.geometryHeight, false, staleX, staleY));

    finalQueue.push(RdpQueuedInputEvent::Mouse(
        0, 0, 1599, 999, false, captured.epoch,
        captured.width, captured.height));
    RdpQueuedInputEvent release;
    RDP_ASSERT(finalQueue.pop(release));
    int releaseX = release.x;
    int releaseY = release.y;
    RDP_ASSERT(fence.preparePointer(
        release.geometryEpoch, release.geometryWidth,
        release.geometryHeight, true, releaseX, releaseY));
    RDP_ASSERT_EQ(releaseX, 3199);
    RDP_ASSERT_EQ(releaseY, 1999);
    RDP_ASSERT_EQ(finalQueue.depth(), 0U);
}
