/**
 * rdp_frame_pump_contract_test.cpp - contract checks for RDP render pump fallback
 */

#include "test_runner.h"
#include "rdp/rdp_frame_pump.h"

#include <cstdint>
#include <type_traits>
#include <utility>

static_assert(std::is_same<decltype(&RdpFramePump::isRunning),
    bool (RdpFramePump::*)() const>::value,
    "RdpFramePump must expose running state so FreeRDP can fall back safely");

static_assert(std::is_same<decltype(&RdpFramePump::submitLatest),
    bool (RdpFramePump::*)(RdpFrameSubmission&&)>::value,
    "RdpFramePump must take ownership of queued pixel storage");

static_assert(std::is_same<decltype(&RdpFramePump::invalidatePending),
    void (RdpFramePump::*)()>::value,
    "RdpFramePump must invalidate pending work during detach and resize");

RDP_TEST_CASE(rdp_frame_pump_contract_supports_safe_fallback) {
    RDP_ASSERT(true);
}
