#include "test_runner.h"
#include "rdp/rdp_damage_accumulator.h"
#include "rdp/rdp_visual_commit_policy.h"

#include <cstdint>
#include <chrono>
#include <limits>
#include <thread>
#include <utility>
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

RdpDamageSnapshot TakeCommittedSnapshot(RdpDamageAccumulator& accumulator) {
    for (int attempt = 0; attempt < 250; ++attempt) {
        RdpDamageSnapshot snapshot = accumulator.takeSnapshot();
        if (snapshot.valid) {
            return snapshot;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return {};
}

bool TakeFullAndRecycle(RdpDamageAccumulator& accumulator) {
    RdpDamageSnapshot snapshot = TakeCommittedSnapshot(accumulator);
    const bool full = snapshot.valid && snapshot.fullFrame;
    accumulator.recycleSnapshot(std::move(snapshot));
    return full;
}

void RecycleCommitted(RdpDamageAccumulator& accumulator) {
    RdpDamageSnapshot snapshot = TakeCommittedSnapshot(accumulator);
    accumulator.recycleSnapshot(std::move(snapshot));
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
    RDP_ASSERT(TakeFullAndRecycle(accumulator));

    frame = MakeFrame(4, 3, 16, 40);
    RDP_ASSERT(accumulator.update(frame.data(), frame.size(), 4, 3, 16,
                                  1, 1, 2, 1, 1, false).accepted);
    RDP_ASSERT(accumulator.update(frame.data(), frame.size(), 4, 3, 16,
                                  0, 2, 1, 1, 1, false).accepted);
    RdpDamageSnapshot snapshot = TakeCommittedSnapshot(accumulator);

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
    accumulator.recycleSnapshot(std::move(snapshot));
}

RDP_TEST_CASE(rdp_damage_accumulator_generation_change_forces_full_resync) {
    RdpDamageAccumulator accumulator;
    std::vector<uint8_t> frame = MakeFrame(4, 4, 16, 1);
    accumulator.update(frame.data(), frame.size(), 4, 4, 16, 0, 0, 4, 4, 1, false);
    RecycleCommitted(accumulator);

    const RdpDamageUpdateResult update = accumulator.update(
        frame.data(), frame.size(), 4, 4, 16, 1, 1, 1, 1, 2, false);
    RDP_ASSERT(update.accepted);
    RDP_ASSERT(update.fullResync);
    RDP_ASSERT(TakeFullAndRecycle(accumulator));
}

RDP_TEST_CASE(rdp_damage_accumulator_invalid_rect_recovers_current_full_frame) {
    RdpDamageAccumulator accumulator;
    std::vector<uint8_t> frame = MakeFrame(4, 3, 16, 1);
    accumulator.update(frame.data(), frame.size(), 4, 3, 16, 0, 0, 4, 3, 1, false);
    RecycleCommitted(accumulator);

    frame = MakeFrame(4, 3, 16, 30);
    const RdpDamageUpdateResult update = accumulator.update(
        frame.data(), frame.size(), 4, 3, 16, 8, 8, 2, 2, 1, false);
    RDP_ASSERT(update.accepted);
    RDP_ASSERT(update.fullResync);
    RdpDamageSnapshot snapshot = TakeCommittedSnapshot(accumulator);
    RDP_ASSERT(snapshot.fullFrame);
    RDP_ASSERT_EQ(snapshot.pixels[0], static_cast<uint8_t>(30));
    accumulator.recycleSnapshot(std::move(snapshot));
}

RDP_TEST_CASE(rdp_damage_accumulator_refresh_uses_owned_staging) {
    RdpDamageAccumulator accumulator;
    std::vector<uint8_t> frame = MakeFrame(3, 2, 12, 9);
    accumulator.update(frame.data(), frame.size(), 3, 2, 12, 0, 0, 3, 2, 1, false);
    RecycleCommitted(accumulator);

    frame.assign(frame.size(), 0xFE);
    RDP_ASSERT(accumulator.requestFullSnapshot(2));
    RdpDamageSnapshot snapshot = accumulator.takeSnapshot();
    RDP_ASSERT(snapshot.valid);
    RDP_ASSERT(snapshot.fullFrame);
    RDP_ASSERT_EQ(snapshot.rendererGeneration, static_cast<uint64_t>(2));
    RDP_ASSERT_EQ(snapshot.pixels[0], static_cast<uint8_t>(9));
    RDP_ASSERT_EQ(snapshot.pixels[12], static_cast<uint8_t>(12));
    accumulator.recycleSnapshot(std::move(snapshot));
}

RDP_TEST_CASE(rdp_damage_accumulator_reuses_retained_full_frame_for_refresh) {
    RdpDamageAccumulator accumulator;
    std::vector<uint8_t> frame = MakeFrame(3, 2, 12, 9);
    RDP_ASSERT(accumulator.update(frame.data(), frame.size(), 3, 2, 12,
                                  0, 0, 3, 2, 1, false).accepted);

    RdpDamageSnapshot first = TakeCommittedSnapshot(accumulator);
    RDP_ASSERT(first.valid);
    accumulator.recycleSnapshot(std::move(first));

    RDP_ASSERT(accumulator.requestFullSnapshot(1));
    RdpDamageSnapshot second = TakeCommittedSnapshot(accumulator);
    RDP_ASSERT(second.valid);
    RDP_ASSERT(second.fullFrame);
    accumulator.recycleSnapshot(std::move(second));

    // The producer has been quiet and the staging buffer was handed to the
    // renderer, so the next refresh must come from retained storage.
    RDP_ASSERT(accumulator.requestFullSnapshot(2));
    RdpDamageSnapshot retained = accumulator.takeSnapshot();
    RDP_ASSERT(retained.valid);
    RDP_ASSERT(retained.fullFrame);
    RDP_ASSERT_EQ(retained.rendererGeneration, static_cast<uint64_t>(2));
    RDP_ASSERT_EQ(retained.pixels[0], static_cast<uint8_t>(9));
    accumulator.recycleSnapshot(std::move(retained));

    // A new dirty callback after a retained-only refresh promotes the
    // complete retained frame back to staging and updates only its dirty
    // rectangle. The old implementation copied the entire source frame here.
    frame = MakeFrame(3, 2, 12, 40);
    const RdpDamageUpdateResult update = accumulator.update(
        frame.data(), frame.size(), 3, 2, 12, 1, 0, 1, 1, 2, false);
    RDP_ASSERT(update.accepted);
    RDP_ASSERT(!update.fullResync);
    RdpDamageSnapshot dirty = TakeCommittedSnapshot(accumulator);
    RDP_ASSERT(dirty.valid);
    RDP_ASSERT(!dirty.fullFrame);
    RDP_ASSERT_EQ(dirty.damage.x, 1);
    RDP_ASSERT_EQ(dirty.damage.y, 0);
    RDP_ASSERT_EQ(dirty.damage.width, 1);
    RDP_ASSERT_EQ(dirty.damage.height, 1);
    RDP_ASSERT_EQ(dirty.pixels[0], static_cast<uint8_t>(41));
    accumulator.recycleSnapshot(std::move(dirty));

    // The retained pixels outside the dirty rectangle remain intact, while
    // the changed pixel is now part of the current full staging frame.
    RDP_ASSERT(accumulator.requestFullSnapshot(2));
    RdpDamageSnapshot rebuilt = TakeCommittedSnapshot(accumulator);
    RDP_ASSERT(rebuilt.valid);
    RDP_ASSERT(rebuilt.fullFrame);
    RDP_ASSERT_EQ(rebuilt.pixels[0], static_cast<uint8_t>(9));
    RDP_ASSERT_EQ(rebuilt.pixels[4], static_cast<uint8_t>(41));
    RDP_ASSERT_EQ(rebuilt.pixels[8], static_cast<uint8_t>(11));
    accumulator.recycleSnapshot(std::move(rebuilt));
}

RDP_TEST_CASE(rdp_damage_accumulator_resize_copies_tight_rows_without_padding) {
    RdpDamageAccumulator accumulator;
    std::vector<uint8_t> first = MakeFrame(2, 2, 12, 1);
    accumulator.update(first.data(), first.size(), 2, 2, 12, 0, 0, 2, 2, 1, false);
    RdpDamageSnapshot snapshot = TakeCommittedSnapshot(accumulator);
    RDP_ASSERT_EQ(snapshot.stride, 8);
    RDP_ASSERT_EQ(snapshot.pixels.size(), static_cast<size_t>(16));
    accumulator.recycleSnapshot(std::move(snapshot));

    std::vector<uint8_t> resized = MakeFrame(3, 2, 16, 20);
    const RdpDamageUpdateResult update = accumulator.update(
        resized.data(), resized.size(), 3, 2, 16, 2, 1, 1, 1, 1, false);
    RDP_ASSERT(update.fullResync);
    snapshot = TakeCommittedSnapshot(accumulator);
    RDP_ASSERT(snapshot.fullFrame);
    RDP_ASSERT_EQ(snapshot.stride, 12);
    RDP_ASSERT_EQ(snapshot.pixels.size(), static_cast<size_t>(24));
    RDP_ASSERT_EQ(snapshot.pixels[12], static_cast<uint8_t>(23));
    accumulator.recycleSnapshot(std::move(snapshot));
}

RDP_TEST_CASE(rdp_damage_accumulator_escalates_union_at_seventy_percent) {
    RdpDamageAccumulator accumulator;
    std::vector<uint8_t> frame = MakeFrame(10, 10, 40, 1);
    accumulator.update(frame.data(), frame.size(), 10, 10, 40, 0, 0, 10, 10, 1, false);
    RecycleCommitted(accumulator);
    accumulator.update(frame.data(), frame.size(), 10, 10, 40, 0, 0, 8, 9, 1, false);
    RDP_ASSERT(TakeFullAndRecycle(accumulator));
}

RDP_TEST_CASE(rdp_damage_accumulator_commits_broad_refresh_bands_without_waiting) {
    RdpDamageAccumulator accumulator;
    std::vector<uint8_t> frame = MakeFrame(10, 10, 40, 1);
    accumulator.update(frame.data(), frame.size(), 10, 10, 40, 0, 0, 10, 10, 1, false);
    RecycleCommitted(accumulator);

    accumulator.update(frame.data(), frame.size(), 10, 10, 40, 0, 0, 10, 2, 1, false);
    RdpDamageSnapshot snapshot = accumulator.takeSnapshot();
    RDP_ASSERT(snapshot.valid);
    RDP_ASSERT(!snapshot.fullFrame);
    accumulator.recycleSnapshot(std::move(snapshot));
}

RDP_TEST_CASE(rdp_damage_accumulator_commits_medium_refresh_bands_and_cursor_updates) {
    RdpDamageAccumulator accumulator;
    std::vector<uint8_t> frame = MakeFrame(10, 10, 40, 1);
    accumulator.update(frame.data(), frame.size(), 10, 10, 40, 0, 0, 10, 10, 1, false);
    RDP_ASSERT(TakeFullAndRecycle(accumulator));

    // Bands that cover 20% to 70% of the width use the low-latency dirty path.
    accumulator.update(frame.data(), frame.size(), 10, 10, 40, 0, 2, 5, 2, 1, false);
    RdpDamageSnapshot band = accumulator.takeSnapshot();
    RDP_ASSERT(band.valid);
    accumulator.recycleSnapshot(std::move(band));

    // A small cursor/toolbar update inside the continuation tail stays
    // dirty-only and does not reopen a costly full-frame fence.
    accumulator.update(frame.data(), frame.size(), 10, 10, 40, 1, 8, 1, 1, 1, false);
    RdpDamageSnapshot cursor = accumulator.takeSnapshot();
    RDP_ASSERT(cursor.valid);
    RDP_ASSERT(!cursor.fullFrame);
    accumulator.recycleSnapshot(std::move(cursor));
}

RDP_TEST_CASE(rdp_damage_accumulator_commits_one_row_burst_and_tail_updates) {
    RdpDamageAccumulator accumulator;
    std::vector<uint8_t> frame = MakeFrame(10, 10, 40, 1);
    accumulator.update(frame.data(), frame.size(), 10, 10, 40, 0, 0, 10, 10, 1, false);
    RDP_ASSERT(TakeFullAndRecycle(accumulator));

    // FreeRDP may report a page repaint as one full-width row at a time.
    accumulator.update(frame.data(), frame.size(), 10, 10, 40, 0, 3, 10, 1, 1, false);
    RdpDamageSnapshot row = accumulator.takeSnapshot();
    RDP_ASSERT(row.valid);
    accumulator.recycleSnapshot(std::move(row));

    // A strip arriving immediately after the row is also presented as a
    // dirty rect instead of waiting behind a burst fence.
    accumulator.update(frame.data(), frame.size(), 10, 10, 40, 2, 4, 5, 2, 1, false);
    RdpDamageSnapshot tail = accumulator.takeSnapshot();
    RDP_ASSERT(tail.valid);
    accumulator.recycleSnapshot(std::move(tail));
}

RDP_TEST_CASE(rdp_damage_accumulator_keeps_narrow_bands_low_latency) {
    RdpDamageAccumulator accumulator;
    std::vector<uint8_t> frame = MakeFrame(100, 100, 400, 1);
    accumulator.update(frame.data(), frame.size(), 100, 100, 400,
                       0, 0, 100, 100, 1, false);
    RDP_ASSERT(TakeFullAndRecycle(accumulator));

    // A later page-repaint strip can be narrower than the first broad band;
    // it is committed immediately as a dirty rect.
    accumulator.update(frame.data(), frame.size(), 100, 100, 400,
                       8, 20, 8, 2, 1, false);
    RdpDamageSnapshot initialNarrow = accumulator.takeSnapshot();
    RDP_ASSERT(initialNarrow.valid);
    RDP_ASSERT(!initialNarrow.fullFrame);
    accumulator.recycleSnapshot(std::move(initialNarrow));

    // A broad repaint does not establish a blocking burst fence.
    accumulator.update(frame.data(), frame.size(), 100, 100, 400,
                       0, 0, 80, 2, 1, false);
    RdpDamageSnapshot broad = accumulator.takeSnapshot();
    RDP_ASSERT(broad.valid);
    accumulator.recycleSnapshot(std::move(broad));

    // A later narrow strip remains on the low-latency path.
    accumulator.update(frame.data(), frame.size(), 100, 100, 400,
                       8, 20, 8, 2, 1, false);
    RdpDamageSnapshot laterNarrow = accumulator.takeSnapshot();
    RDP_ASSERT(laterNarrow.valid);
    accumulator.recycleSnapshot(std::move(laterNarrow));

    // A square whose thickness exceeds 12% in both directions is not a
    // continuation strip and remains dirty-only.
    accumulator.update(frame.data(), frame.size(), 100, 100, 400,
                       8, 20, 13, 13, 1, false);
    RdpDamageSnapshot thickStrip = accumulator.takeSnapshot();
    RDP_ASSERT(thickStrip.valid);
    RDP_ASSERT(!thickStrip.fullFrame);
    accumulator.recycleSnapshot(std::move(thickStrip));

    // A single-pixel cursor update must not reopen the full-frame fence.
    accumulator.update(frame.data(), frame.size(), 100, 100, 400,
                       40, 40, 1, 1, 1, false);
    RdpDamageSnapshot cursor = accumulator.takeSnapshot();
    RDP_ASSERT(cursor.valid);
    RDP_ASSERT(!cursor.fullFrame);
    accumulator.recycleSnapshot(std::move(cursor));
}

RDP_TEST_CASE(rdp_damage_accumulator_snapshot_failure_keeps_pending_damage) {
    RdpDamageAccumulator accumulator;
    std::vector<uint8_t> frame = MakeFrame(4, 4, 16, 1);
    accumulator.update(frame.data(), frame.size(), 4, 4, 16, 0, 0, 4, 4, 1, false);
    RecycleCommitted(accumulator);
    accumulator.update(frame.data(), frame.size(), 4, 4, 16, 1, 1, 1, 1, 1, false);

    accumulator.setSnapshotAllocationLimitForTest(1);
    RDP_ASSERT(!accumulator.takeSnapshot().valid);
    RDP_ASSERT(accumulator.hasPending());
    accumulator.setSnapshotAllocationLimitForTest(std::numeric_limits<size_t>::max());
    RDP_ASSERT(accumulator.takeSnapshot().valid);
    RDP_ASSERT(!accumulator.hasPending());
}

RDP_TEST_CASE(rdp_visual_commit_policy_waits_for_quiet_period_but_has_a_deadline) {
    const RdpVisualCommitDecision active = RdpVisualCommitPolicy::Evaluate(
        120000, 100000, 110000);
    RDP_ASSERT(active.defer);
    RDP_ASSERT_EQ(active.retryAtUs, 150000);

    const RdpVisualCommitDecision quiet = RdpVisualCommitPolicy::Evaluate(
        150000, 100000, 110000);
    RDP_ASSERT(!quiet.defer);

    const RdpVisualCommitDecision deadline = RdpVisualCommitPolicy::Evaluate(
        260000, 100000, 250000);
    RDP_ASSERT(!deadline.defer);

    RDP_ASSERT(RdpVisualCommitPolicy::InBurstContinuation(300000, 200000));
    RDP_ASSERT(!RdpVisualCommitPolicy::InBurstContinuation(950000, 200000));

    const RdpVisualCommitDecision continuation = RdpVisualCommitPolicy::Evaluate(
        350000, 100000, 300000,
        RdpVisualCommitPolicy::kBurstContinuationQuietPeriodUs,
        RdpVisualCommitPolicy::kBurstContinuationMaximumWindowUs);
    RDP_ASSERT(continuation.defer);
    RDP_ASSERT_EQ(continuation.retryAtUs, 500000);

    const RdpVisualCommitDecision continuationQuiet = RdpVisualCommitPolicy::Evaluate(
        520000, 100000, 300000,
        RdpVisualCommitPolicy::kBurstContinuationQuietPeriodUs,
        RdpVisualCommitPolicy::kBurstContinuationMaximumWindowUs);
    RDP_ASSERT(!continuationQuiet.defer);
}
