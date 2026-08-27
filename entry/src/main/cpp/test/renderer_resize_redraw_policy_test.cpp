#include "test_runner.h"
#include "render/renderer_resize_redraw_policy.h"

RDP_TEST_CASE(renderer_resize_redraws_once_after_each_new_valid_geometry) {
    int currentWidth = 0;
    int currentHeight = 0;
    int redraws = 0;
    bool commitActive = false;

    auto apply = [&](int width, int height) {
        return Render::CommitRendererResizeAndRedraw(
            [&]() {
                commitActive = true;
                const bool committed = Render::CommitRendererResizeGeometry(
                    currentWidth, currentHeight, width, height);
                commitActive = false;
                return committed;
            },
            [&]() {
                RDP_ASSERT(!commitActive);
                ++redraws;
            });
    };

    RDP_ASSERT(apply(1280, 720));
    RDP_ASSERT(currentWidth == 1280);
    RDP_ASSERT(currentHeight == 720);
    RDP_ASSERT(redraws == 1);

    RDP_ASSERT(!apply(1280, 720));
    RDP_ASSERT(!apply(0, 720));
    RDP_ASSERT(!apply(1280, -1));
    RDP_ASSERT(redraws == 1);

    RDP_ASSERT(apply(1920, 1080));
    RDP_ASSERT(currentWidth == 1920);
    RDP_ASSERT(currentHeight == 1080);
    RDP_ASSERT(redraws == 2);
}
