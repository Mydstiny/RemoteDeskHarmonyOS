#ifndef RUSTDESK_MULTI_CANVAS_POLICY_H
#define RUSTDESK_MULTI_CANVAS_POLICY_H

#include <algorithm>
#include <cstdint>
#include <string>
#include <unordered_set>
#include <vector>

struct RustDeskMultiCanvasDisplayBudgetInput {
    int display = -1;
    int width = 0;
    int height = 0;
    bool online = false;
};

struct RustDeskMultiCanvasBudgetDecision {
    bool accepted = false;
    bool degraded = false;
    std::string reason;
    std::vector<int> displays;
    uint64_t totalPixels = 0;
};

constexpr size_t kRustDeskMultiCanvasMaxDisplays = 2;
constexpr uint64_t kRustDeskMultiCanvasMaxPixels =
    2ULL * 3840ULL * 2160ULL;

inline bool RustDeskShouldRouteMultiCanvasPreview(
    int frameDisplay, int confirmedDisplay, int pendingDisplay,
    bool inputBlocked, bool explicitlyCaptured) {
    // Before the control plane establishes its first confirmed display, the
    // same frame must flow only through the interactive dispatch gate. Routing
    // it speculatively as a preview would submit the first frame twice.
    return frameDisplay >= 0 && confirmedDisplay >= 0 && explicitlyCaptured &&
        frameDisplay != confirmedDisplay &&
        !(inputBlocked && frameDisplay == pendingDisplay);
}

inline RustDeskMultiCanvasBudgetDecision RustDeskSelectMultiCanvasDisplays(
    int focusedDisplay,
    const std::vector<int>& requested,
    const std::vector<RustDeskMultiCanvasDisplayBudgetInput>& catalog) {
    RustDeskMultiCanvasBudgetDecision result;
    std::unordered_set<int> seen;
    std::vector<int> ordered;
    if (focusedDisplay >= 0) {
        ordered.push_back(focusedDisplay);
    }
    ordered.insert(ordered.end(), requested.begin(), requested.end());
    for (const int candidate : ordered) {
        if (candidate < 0 || !seen.insert(candidate).second) {
            continue;
        }
        const auto found = std::find_if(catalog.begin(), catalog.end(),
            [candidate](const RustDeskMultiCanvasDisplayBudgetInput& item) {
                return item.display == candidate && item.online &&
                    item.width > 0 && item.height > 0;
            });
        if (found == catalog.end()) {
            result.degraded = true;
            continue;
        }
        const uint64_t pixels = static_cast<uint64_t>(found->width) *
            static_cast<uint64_t>(found->height);
        if (result.displays.size() >= kRustDeskMultiCanvasMaxDisplays ||
            pixels > kRustDeskMultiCanvasMaxPixels - result.totalPixels) {
            result.degraded = true;
            continue;
        }
        result.displays.push_back(candidate);
        result.totalPixels += pixels;
    }
    result.accepted = !result.displays.empty() &&
        (focusedDisplay < 0 || result.displays.front() == focusedDisplay);
    if (!result.accepted) {
        result.reason = "focused_display_unavailable";
    } else if (result.degraded) {
        result.reason = "resource_budget";
    } else {
        result.reason = "ok";
    }
    return result;
}

#endif // RUSTDESK_MULTI_CANVAS_POLICY_H
