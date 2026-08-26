#include "test_runner.h"
#include "render/gl_surface_lifecycle_policy.h"

RDP_TEST_CASE(gl_surface_policy_reuses_same_attached_surface) {
    const bool replace = Render::ShouldReplaceSurfaceWindow(
        true, 6163278072342ULL, 6163278072342ULL, false);
    RDP_ASSERT(!replace);
}

RDP_TEST_CASE(gl_surface_policy_replaces_changed_surface_id) {
    const bool replace = Render::ShouldReplaceSurfaceWindow(
        true, 100ULL, 200ULL, false);
    RDP_ASSERT(replace);
}

RDP_TEST_CASE(gl_surface_policy_replaces_detached_surface) {
    const bool replace = Render::ShouldReplaceSurfaceWindow(
        true, 6163278072342ULL, 6163278072342ULL, true);
    RDP_ASSERT(replace);
}

RDP_TEST_CASE(gl_surface_policy_reuses_background_preserved_surface) {
    const bool replace = Render::ShouldReplaceSurfaceWindow(
        true, 6163278072381ULL, 6163278072381ULL, false);
    RDP_ASSERT(!replace);
}

RDP_TEST_CASE(gl_surface_policy_creates_when_missing_window) {
    const bool replace = Render::ShouldReplaceSurfaceWindow(
        false, 0ULL, 6163278072342ULL, false);
    RDP_ASSERT(replace);
}

RDP_TEST_CASE(gl_renderer_generation_is_idempotent_for_exact_live_owner) {
    RDP_ASSERT(!Render::ShouldAdvanceRendererGeneration(
        7, 7, true, false, true, 11U));
}

RDP_TEST_CASE(gl_renderer_generation_advances_for_real_token_transfer) {
    RDP_ASSERT(Render::ShouldAdvanceRendererGeneration(
        7, 8, true, false, true, 11U));
    RDP_ASSERT(Render::ShouldAdvanceRendererGeneration(
        8, 8, false, true, true, 11U));
    RDP_ASSERT(Render::ShouldAdvanceRendererGeneration(
        8, 8, true, false, false, 11U));
    RDP_ASSERT(Render::ShouldAdvanceRendererGeneration(
        8, 8, true, false, true, 0U));
}
