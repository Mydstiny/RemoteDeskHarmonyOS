#include "test_runner.h"
#include "render/presentation_geometry_policy.h"

RDP_TEST_CASE(presentation_geometry_policy_prefers_current_raw_frame_size) {
    const auto selected = Render::SelectPresentationGeometry(
        Render::PresentationPathKind::RawBgra,
        2560, 1600,
        1280, 720,
        1600, 900,
        1920, 1080);
    RDP_ASSERT_EQ(selected.width, 1280);
    RDP_ASSERT_EQ(selected.height, 720);
}

RDP_TEST_CASE(presentation_geometry_policy_keeps_oes_logical_size) {
    const auto selected = Render::SelectPresentationGeometry(
        Render::PresentationPathKind::Oes,
        2560, 1440,
        1600, 900,
        1600, 900,
        1920, 1080);
    RDP_ASSERT_EQ(selected.width, 2560);
    RDP_ASSERT_EQ(selected.height, 1440);
}

RDP_TEST_CASE(presentation_geometry_policy_uses_path_fallback_before_first_frame) {
    const auto raw = Render::SelectPresentationGeometry(
        Render::PresentationPathKind::RawBgra,
        0, 0,
        0, 0,
        1600, 900,
        1920, 1080);
    RDP_ASSERT_EQ(raw.width, 1600);
    RDP_ASSERT_EQ(raw.height, 900);

    const auto oes = Render::SelectPresentationGeometry(
        Render::PresentationPathKind::Oes,
        0, 0,
        0, 0,
        1600, 900,
        1920, 1080);
    RDP_ASSERT_EQ(oes.width, 1920);
    RDP_ASSERT_EQ(oes.height, 1080);
}

RDP_TEST_CASE(presentation_geometry_policy_raw_uses_logical_only_before_texture) {
    const auto selected = Render::SelectPresentationGeometry(
        Render::PresentationPathKind::RawBgra,
        2560, 1600,
        0, 0,
        0, 0,
        1920, 1080);
    RDP_ASSERT_EQ(selected.width, 2560);
    RDP_ASSERT_EQ(selected.height, 1600);
}

RDP_TEST_CASE(presentation_geometry_policy_does_not_cross_contaminate_paths) {
    const auto raw = Render::SelectPresentationGeometry(
        Render::PresentationPathKind::RawBgra,
        0, 0,
        1600, 900,
        1600, 900,
        1920, 1080);
    const auto oes = Render::SelectPresentationGeometry(
        Render::PresentationPathKind::Oes,
        0, 0,
        1600, 900,
        1600, 900,
        1920, 1080);
    RDP_ASSERT(raw.width != oes.width);
    RDP_ASSERT(raw.height != oes.height);
}
