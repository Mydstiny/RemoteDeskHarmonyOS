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
