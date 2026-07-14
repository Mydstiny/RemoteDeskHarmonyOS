#include "test_runner.h"
#include "rdp/rdp_damage_accumulator.h"

#include <cstdint>
#include <limits>
#include <vector>

namespace {

std::vector<uint8_t> MakeFrame(int width, int height, int stride, uint8_t seed) {
    std::vector<uint8_t> frame(static_cast<size_t>(stride) * static_cast<size_t>(height), 0xEE);
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const size_t offset = static_cast<size_t>(y) * static_cast<size_t>(stride) +
                static_cast<size_t>(x) * 4U;
            frame[offset] = static_cast<uint8_t>(seed + y * width + x);
            frame[offset + 1] = static_cast<uint8_t>(x);
            frame[offset + 2] = static_cast<uint8_t>(y);
            frame[offset + 3] = 0xFF;
        }
    }
    return frame;
}

} // namespace

RDP_TEST_CASE(rdp_damage_accumulator_clips_rect_to_frame) {
    const RdpDamageRect clipped = RdpDamageAccumulator::ClipRect(10, 8, -2, 6, 6, 5);
    RDP_ASSERT(clipped.valid);
    RDP_ASSERT_EQ(clipped.x, 0);
    RDP_ASSERT_EQ(clipped.y, 6);
    RDP_ASSERT_EQ(clipped.width, 4);
    RDP_ASSERT_EQ(clipped.height, 2);
}

RDP_TEST_CASE(rdp_damage_accumulator_unions_replacements_from_latest_staging) {
    RdpDamageAccumulator accumulator;
    std::vector<uint8_t> frame = MakeFrame(4, 3, 16, 10);
    RDP_ASSERT(accumulator.update(frame.data(), frame.size(), 4, 3, 16,
                                  0, 0, 4, 3, 1, false).accepted);
    RDP_ASSERT(accumulator.takeSnapshot().fullFrame);

    frame = MakeFrame(4, 3, 16, 40);
    RDP_ASSERT(accumulator.update(frame.data(), frame.size(), 4, 3, 16,
                                  1, 1, 2, 1, 1, false).accepted);
    RDP_ASSERT(accumulator.update(frame.data(), frame.size(), 4, 3, 16,
                                  0, 2, 1, 1, 1, false).accepted);
    const RdpDamageSnapshot snapshot = accumulator.takeSnapshot();

    RDP_ASSERT(snapshot.valid);
    RDP_ASSERT(!snapshot.fullFrame);
    RDP_ASSERT_EQ(snapshot.damage.x, 0);
    RDP_ASSERT_EQ(snapshot.damage.y, 1);
    RDP_ASSERT_EQ(snapshot.damage.width, 3);
    RDP_ASSERT_EQ(snapshot.damage.height, 2);
    RDP_ASSERT_EQ(snapshot.stride, 12);
    RDP_ASSERT_EQ(snapshot.pixels[4], static_cast<uint8_t>(45));
    RDP_ASSERT_EQ(snapshot.pixels[8], static_cast<uint8_t>(46));
    RDP_ASSERT_EQ(snapshot.pixels[12], static_cast<uint8_t>(48));
}

RDP_TEST_CASE(rdp_damage_accumulator_generation_change_forces_full_resync) {
    RdpDamageAccumulator accumulator;
    std::vector<uint8_t> frame = MakeFrame(4, 4, 16, 1);
    accumulator.update(frame.data(), frame.size(), 4, 4, 16, 0, 0, 4, 4, 1, false);
    accumulator.takeSnapshot();

    const RdpDamageUpdateResult update = accumulator.update(
        frame.data(), frame.size(), 4, 4, 16, 1, 1, 1, 1, 2, false);
    RDP_ASSERT(update.accepted);
    RDP_ASSERT(update.fullResync);
    RDP_ASSERT(accumulator.takeSnapshot().fullFrame);
}

RDP_TEST_CASE(rdp_damage_accumulator_invalid_rect_recovers_current_full_frame) {
    RdpDamageAccumulator accumulator;
    std::vector<uint8_t> frame = MakeFrame(4, 3, 16, 1);
    accumulator.update(frame.data(), frame.size(), 4, 3, 16, 0, 0, 4, 3, 1, false);
    accumulator.takeSnapshot();

    frame = MakeFrame(4, 3, 16, 30);
    const RdpDamageUpdateResult update = accumulator.update(
        frame.data(), frame.size(), 4, 3, 16, 8, 8, 2, 2, 1, false);
    RDP_ASSERT(update.accepted);
    RDP_ASSERT(update.fullResync);
    const RdpDamageSnapshot snapshot = accumulator.takeSnapshot();
    RDP_ASSERT(snapshot.fullFrame);
    RDP_ASSERT_EQ(snapshot.pixels[0], static_cast<uint8_t>(30));
}

RDP_TEST_CASE(rdp_damage_accumulator_refresh_uses_owned_staging) {
    RdpDamageAccumulator accumulator;
    std::vector<uint8_t> frame = MakeFrame(3, 2, 12, 9);
    accumulator.update(frame.data(), frame.size(), 3, 2, 12, 0, 0, 3, 2, 1, false);
    accumulator.takeSnapshot();

    frame.assign(frame.size(), 0xFE);
    RDP_ASSERT(accumulator.requestFullSnapshot(2));
    const RdpDamageSnapshot snapshot = accumulator.takeSnapshot();
    RDP_ASSERT(snapshot.valid);
    RDP_ASSERT(snapshot.fullFrame);
    RDP_ASSERT_EQ(snapshot.rendererGeneration, static_cast<uint64_t>(2));
    RDP_ASSERT_EQ(snapshot.pixels[0], static_cast<uint8_t>(9));
    RDP_ASSERT_EQ(snapshot.pixels[12], static_cast<uint8_t>(12));
}

RDP_TEST_CASE(rdp_damage_accumulator_resize_copies_tight_rows_without_padding) {
    RdpDamageAccumulator accumulator;
    std::vector<uint8_t> first = MakeFrame(2, 2, 12, 1);
    accumulator.update(first.data(), first.size(), 2, 2, 12, 0, 0, 2, 2, 1, false);
    RdpDamageSnapshot snapshot = accumulator.takeSnapshot();
    RDP_ASSERT_EQ(snapshot.stride, 8);
    RDP_ASSERT_EQ(snapshot.pixels.size(), static_cast<size_t>(16));

    std::vector<uint8_t> resized = MakeFrame(3, 2, 16, 20);
    const RdpDamageUpdateResult update = accumulator.update(
        resized.data(), resized.size(), 3, 2, 16, 2, 1, 1, 1, 1, false);
    RDP_ASSERT(update.fullResync);
    snapshot = accumulator.takeSnapshot();
    RDP_ASSERT(snapshot.fullFrame);
    RDP_ASSERT_EQ(snapshot.stride, 12);
    RDP_ASSERT_EQ(snapshot.pixels.size(), static_cast<size_t>(24));
    RDP_ASSERT_EQ(snapshot.pixels[12], static_cast<uint8_t>(23));
}

RDP_TEST_CASE(rdp_damage_accumulator_escalates_union_at_seventy_percent) {
    RdpDamageAccumulator accumulator;
    std::vector<uint8_t> frame = MakeFrame(10, 10, 40, 1);
    accumulator.update(frame.data(), frame.size(), 10, 10, 40, 0, 0, 10, 10, 1, false);
    accumulator.takeSnapshot();
    accumulator.update(frame.data(), frame.size(), 10, 10, 40, 0, 0, 8, 9, 1, false);
    RDP_ASSERT(accumulator.takeSnapshot().fullFrame);
}

RDP_TEST_CASE(rdp_damage_accumulator_snapshot_failure_keeps_pending_damage) {
    RdpDamageAccumulator accumulator;
    std::vector<uint8_t> frame = MakeFrame(4, 4, 16, 1);
    accumulator.update(frame.data(), frame.size(), 4, 4, 16, 0, 0, 4, 4, 1, false);
    accumulator.takeSnapshot();
    accumulator.update(frame.data(), frame.size(), 4, 4, 16, 1, 1, 1, 1, 1, false);

    accumulator.setSnapshotAllocationLimitForTest(1);
    RDP_ASSERT(!accumulator.takeSnapshot().valid);
    RDP_ASSERT(accumulator.hasPending());
    accumulator.setSnapshotAllocationLimitForTest(std::numeric_limits<size_t>::max());
    RDP_ASSERT(accumulator.takeSnapshot().valid);
    RDP_ASSERT(!accumulator.hasPending());
}
