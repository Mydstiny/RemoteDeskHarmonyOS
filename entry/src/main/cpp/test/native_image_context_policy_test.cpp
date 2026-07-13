#include "test_runner.h"
#include "render/native_image_context_policy.h"

RDP_TEST_CASE(native_image_policy_detaches_before_releasing_current_context) {
    RDP_ASSERT(Render::ShouldDetachNativeImageOnRenderThreadStop(true, true));
}

RDP_TEST_CASE(native_image_policy_skips_detach_when_not_attached) {
    RDP_ASSERT(!Render::ShouldDetachNativeImageOnRenderThreadStop(false, true));
    RDP_ASSERT(!Render::ShouldDetachNativeImageOnRenderThreadStop(true, false));
}

RDP_TEST_CASE(native_image_policy_retries_failed_attach_once) {
    RDP_ASSERT(Render::ShouldRetryNativeImageAttach(60001000, false));
    RDP_ASSERT(!Render::ShouldRetryNativeImageAttach(60001000, true));
    RDP_ASSERT(!Render::ShouldRetryNativeImageAttach(0, false));
}
