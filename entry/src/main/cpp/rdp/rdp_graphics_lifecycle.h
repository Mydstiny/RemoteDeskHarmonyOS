#ifndef RDP_GRAPHICS_LIFECYCLE_H
#define RDP_GRAPHICS_LIFECYCLE_H

#include <atomic>
#include <cstdint>
#include <mutex>

enum class RdpGfxChannelAction {
    Initialize,
    Release,
    Ignore,
    Reject,
};

struct RdpResizeTicket {
    bool accepted = false;
    uint64_t epoch = 0;
    int width = 0;
    int height = 0;
};

struct RdpGraphicsLifecycleSnapshot {
    bool presentationAllowed = false;
    bool resizeInProgress = false;
    bool gfxRequested = false;
    bool gfxInitialized = false;
    int desktopWidth = 0;
    int desktopHeight = 0;
    uint64_t epoch = 0;
    uint64_t resizeCount = 0;
    uint64_t resizeFailures = 0;
    uintptr_t gfxChannelContext = 0;
};

class RdpGraphicsLifecycle {
public:
    static constexpr int kMaxDesktopDimension = 16384;

    void reset(int width, int height, bool gfxRequested);
    RdpResizeTicket beginResize(int width, int height);
    bool completeResize(uint64_t epoch, bool success);

    RdpGfxChannelAction onChannelConnected(uintptr_t context);
    void completeChannelInitialization(uintptr_t context, bool success);
    RdpGfxChannelAction onChannelDisconnected(uintptr_t context);

    RdpGraphicsLifecycleSnapshot snapshot() const;

private:
    static bool ValidDesktopSize(int width, int height);

    mutable std::mutex mutex_;
    RdpGraphicsLifecycleSnapshot snapshot_;
    int pendingWidth_ = 0;
    int pendingHeight_ = 0;
    uint64_t nextResizeEpoch_ = 0;
    bool channelInitializing_ = false;
};

class RdpNextConnectionGfxFallback {
public:
    void mark();
    bool consume();
    bool pending() const;

private:
    std::atomic<bool> pending_ {false};
};

#endif // RDP_GRAPHICS_LIFECYCLE_H
