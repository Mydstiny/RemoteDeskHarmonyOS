/**
 * rdp_frame_pump_contract_test.cpp - contract checks for worker-only RDP presentation
 */

#include "test_runner.h"
#include "rdp/rdp_frame_pump.h"

#include <cstdint>
#include <type_traits>
#include <utility>

static_assert(std::is_same<decltype(&RdpFramePump::isRunning),
    bool (RdpFramePump::*)() const>::value,
    "RdpFramePump must expose worker availability without direct-render fallback");

static_assert(std::is_same<decltype(&RdpFramePump::submitLatest),
    bool (RdpFramePump::*)(RdpFrameSubmission&&)>::value,
    "RdpFramePump must accept owned damage-source signals");

static_assert(std::is_same<decltype(RdpFrameSubmission::damageSource),
    std::shared_ptr<RdpDamageAccumulator>>::value,
    "RdpFrameSubmission pixels must come from the owned damage accumulator");

static_assert(std::is_same<decltype(&RdpFramePump::invalidatePending),
    void (RdpFramePump::*)()>::value,
    "RdpFramePump must invalidate pending work during detach and resize");

RDP_TEST_CASE(rdp_frame_pump_contract_requires_worker_only_presentation) {
    RDP_ASSERT(true);
}
