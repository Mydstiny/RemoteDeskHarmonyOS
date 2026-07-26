/**
 * remote_cursor_snapshot_test.cpp — protocol-neutral remote cursor state tests
 */

#include "test_runner.h"
#include "input/remote_cursor_snapshot.h"

#include <vector>

RDP_TEST_CASE(remote_cursor_shape_revision_changes_only_for_valid_shape) {
    RemoteCursorStore store;
    store.reset(42, "rustdesk");
    const std::vector<uint8_t> rgba(16 * 16 * 4, 0xFF);

    RDP_ASSERT(store.setShape(7, 16, 16, 2, 3, rgba));
    const RemoteCursorSnapshot first = store.snapshot(true);
    RDP_ASSERT_EQ(first.sessionId, 42);
    RDP_ASSERT_EQ(first.generation, 42);
    RDP_ASSERT(first.shapeSource == "protocol");
    RDP_ASSERT(first.protocolShapeAvailable);
    RDP_ASSERT_EQ(first.shapeRevision, 1);
    RDP_ASSERT_EQ(first.hotX, 2);
    RDP_ASSERT_EQ(first.hotY, 3);
    RDP_ASSERT_EQ(first.rgba.size(), rgba.size());

    RDP_ASSERT(!store.setShape(8, 16, 16, 0, 0, std::vector<uint8_t>(3)));
    RDP_ASSERT_EQ(store.snapshot(false).shapeRevision, 1);
}

RDP_TEST_CASE(remote_cursor_position_does_not_copy_or_rev_shape) {
    RemoteCursorStore store;
    store.reset(9, "rdp");
    RDP_ASSERT(!store.snapshot(false).positionAvailable);
    store.setPosition(100, 200);

    const RemoteCursorSnapshot snapshot = store.snapshot(false);
    RDP_ASSERT(snapshot.positionAvailable);
    RDP_ASSERT_EQ(snapshot.positionRevision, 1);
    RDP_ASSERT_EQ(snapshot.shapeRevision, 0);
    RDP_ASSERT_EQ(snapshot.x, 100);
    RDP_ASSERT_EQ(snapshot.y, 200);
    RDP_ASSERT(snapshot.rgba.empty());
}

RDP_TEST_CASE(remote_cursor_default_shape_replaces_previous_shape) {
    RemoteCursorStore store;
    store.reset(17, "rdp");
    RDP_ASSERT(store.setShape(99, 2, 2, 1, 1, std::vector<uint8_t>(16, 0xFF)));

    RDP_ASSERT(store.setDefaultShape());
    const RemoteCursorSnapshot snapshot = store.snapshot(true);
    RDP_ASSERT_EQ(snapshot.shapeId, 0x72656D6F74656466ULL);
    RDP_ASSERT_EQ(snapshot.width, 16);
    RDP_ASSERT_EQ(snapshot.height, 16);
    RDP_ASSERT_EQ(snapshot.hotX, 0);
    RDP_ASSERT_EQ(snapshot.hotY, 0);
    RDP_ASSERT(snapshot.shapeSource == "default");
    RDP_ASSERT(!snapshot.protocolShapeAvailable);
    RDP_ASSERT_EQ(snapshot.rgba.size(), static_cast<size_t>(16 * 16 * 4));
    RDP_ASSERT_EQ(snapshot.shapeRevision, 2);
    RDP_ASSERT(!snapshot.fallbackShape);
}

RDP_TEST_CASE(remote_cursor_fallback_shape_can_bootstrap_a_visible_rustdesk_session) {
    RemoteCursorStore store;
    store.reset(23, "rustdesk");
    RDP_ASSERT(store.setFallbackShape());
    store.setVisible(true);

    const RemoteCursorSnapshot snapshot = store.snapshot(true);
    RDP_ASSERT_EQ(snapshot.sessionId, 23);
    RDP_ASSERT(snapshot.visible);
    RDP_ASSERT_EQ(snapshot.shapeRevision, 1);
    RDP_ASSERT_EQ(snapshot.positionRevision, 0);
    RDP_ASSERT_EQ(snapshot.visibilityRevision, 1);
    RDP_ASSERT_EQ(snapshot.width, 16);
    RDP_ASSERT_EQ(snapshot.height, 16);
    RDP_ASSERT(snapshot.fallbackShape);
    RDP_ASSERT(snapshot.shapeSource == "fallback");
    RDP_ASSERT(!snapshot.protocolShapeAvailable);
}

RDP_TEST_CASE(remote_cursor_protocol_default_replaces_identical_fallback_shape) {
    RemoteCursorStore store;
    store.reset(26, "rustdesk");
    RDP_ASSERT(store.setFallbackShape());
    const RemoteCursorSnapshot fallback = store.snapshot(true);
    RDP_ASSERT(fallback.fallbackShape);
    RDP_ASSERT_EQ(fallback.shapeRevision, 1);

    RDP_ASSERT(store.setDefaultShape());
    const RemoteCursorSnapshot protocolDefault = store.snapshot(true);
    RDP_ASSERT(!protocolDefault.fallbackShape);
    RDP_ASSERT(protocolDefault.shapeSource == "default");
    RDP_ASSERT(!protocolDefault.protocolShapeAvailable);
    RDP_ASSERT_EQ(protocolDefault.shapeRevision, 2);
    RDP_ASSERT(protocolDefault.rgba == fallback.rgba);
}

RDP_TEST_CASE(remote_cursor_visibility_does_not_revise_or_replace_position) {
    RemoteCursorStore store;
    store.reset(24, "rustdesk");
    store.setPosition(320, 240);
    store.setVisible(true);
    const RemoteCursorSnapshot first = store.snapshot(false);

    store.setVisible(false);
    const RemoteCursorSnapshot hidden = store.snapshot(false);
    RDP_ASSERT_EQ(hidden.x, 320);
    RDP_ASSERT_EQ(hidden.y, 240);
    RDP_ASSERT_EQ(hidden.positionRevision, first.positionRevision);
    RDP_ASSERT_EQ(hidden.visibilityRevision, first.visibilityRevision + 1);
}

RDP_TEST_CASE(remote_cursor_first_top_left_position_is_not_lost_to_default_storage) {
    RemoteCursorStore store;
    store.reset(25, "rustdesk");
    const RemoteCursorSnapshot before = store.snapshot(false);
    RDP_ASSERT(!before.positionAvailable);
    RDP_ASSERT_EQ(before.positionRevision, 0);

    store.setPosition(0, 0);
    const RemoteCursorSnapshot after = store.snapshot(false);
    RDP_ASSERT(after.positionAvailable);
    RDP_ASSERT_EQ(after.positionRevision, 1);
    RDP_ASSERT_EQ(after.x, 0);
    RDP_ASSERT_EQ(after.y, 0);
}

RDP_TEST_CASE(remote_cursor_rejects_invalid_dimensions_and_hotspot) {
    RemoteCursorStore store;
    store.reset(3, "rdp");
    const std::vector<uint8_t> pixel(4, 0xFF);

    RDP_ASSERT(!store.setShape(1, 0, 1, 0, 0, pixel));
    RDP_ASSERT(!store.setShape(2, 385, 1, 0, 0, std::vector<uint8_t>(385 * 4)));
    RDP_ASSERT(!store.setShape(3, 1, 1, 1, 0, pixel));
    RDP_ASSERT_EQ(store.snapshot(false).shapeRevision, 0);
}

RDP_TEST_CASE(remote_cursor_reset_isolates_sessions_and_revisions) {
    RemoteCursorStore store;
    store.reset(11, "rustdesk");
    store.setPosition(10, 20);
    store.setVisible(true);
    RDP_ASSERT(store.setShape(5, 1, 1, 0, 0, std::vector<uint8_t>(4, 0xFF)));

    store.reset(12, "rdp");
    const RemoteCursorSnapshot snapshot = store.snapshot(true);
    RDP_ASSERT_EQ(snapshot.sessionId, 12);
    RDP_ASSERT(snapshot.protocol == "rdp");
    RDP_ASSERT_EQ(snapshot.shapeRevision, 0);
    RDP_ASSERT_EQ(snapshot.positionRevision, 0);
    RDP_ASSERT(!snapshot.positionAvailable);
    RDP_ASSERT(!snapshot.fallbackShape);
    RDP_ASSERT(!snapshot.visible);
    RDP_ASSERT(snapshot.rgba.empty());
}

RDP_TEST_CASE(remote_cursor_generation_invalidates_late_reconnect_results) {
    RemoteCursorStore store;
    store.reset(31, "rdp", 701);
    store.setDefaultShape();
    const RemoteCursorSnapshot before = store.snapshot(false);
    RDP_ASSERT_EQ(before.generation, 701);
    RDP_ASSERT_EQ(before.shapeRevision, 1);

    store.setGeneration(702);
    const RemoteCursorSnapshot after = store.snapshot(false);
    RDP_ASSERT_EQ(after.generation, 702);
    RDP_ASSERT_EQ(after.shapeRevision, before.shapeRevision);
    RDP_ASSERT(after.shapeSource == "default");
}

RDP_TEST_CASE(remote_cursor_generation_guard_covers_shape_position_and_visibility_mutations) {
    RemoteCursorStore store;
    const std::vector<uint8_t> firstPixels(4 * 4 * 4, 0x11);
    const std::vector<uint8_t> stalePixels(4 * 4 * 4, 0x22);
    store.reset(41, "rdp", 801);
    RDP_ASSERT(store.setShapeIfGeneration(801, 7, 4, 4, 1, 2, firstPixels));
    RDP_ASSERT(store.setPositionIfGeneration(801, 100, 200));
    RDP_ASSERT(store.setVisibleIfGeneration(801, true));

    // A reset can happen after a callback's fast-path check. The conditional
    // store APIs must reject the old callback while leaving the new session
    // untouched.
    store.reset(42, "rdp", 802);
    RDP_ASSERT(!store.setShapeIfGeneration(801, 8, 4, 4, 0, 0, stalePixels));
    RDP_ASSERT(!store.setPositionIfGeneration(801, 1, 2));
    RDP_ASSERT(!store.setVisibleIfGeneration(801, false));

    const RemoteCursorSnapshot snapshot = store.snapshot(true);
    RDP_ASSERT_EQ(snapshot.sessionId, 42);
    RDP_ASSERT_EQ(snapshot.generation, 802);
    RDP_ASSERT_EQ(snapshot.shapeRevision, 0);
    RDP_ASSERT_EQ(snapshot.positionRevision, 0);
    RDP_ASSERT_EQ(snapshot.visibilityRevision, 0);
    RDP_ASSERT(snapshot.rgba.empty());
}

RDP_TEST_CASE(remote_cursor_protocol_shape_is_authoritative_over_local_default) {
    RemoteCursorStore store;
    store.reset(32, "rdp");
    RDP_ASSERT(store.setDefaultShape());
    const std::vector<uint8_t> protocolPixels(4 * 4 * 4, 0x11);
    RDP_ASSERT(store.setShape(0xFFFFFFFFFFFFFFFFULL, 4, 4, 1, 2, protocolPixels));

    const RemoteCursorSnapshot snapshot = store.snapshot(true);
    RDP_ASSERT(snapshot.protocolShapeAvailable);
    RDP_ASSERT(!snapshot.fallbackShape);
    RDP_ASSERT(snapshot.shapeSource == "protocol");
    RDP_ASSERT_EQ(snapshot.hotX, 1);
    RDP_ASSERT_EQ(snapshot.hotY, 2);
    RDP_ASSERT(snapshot.rgba == protocolPixels);
}
