#include "rdp_graphics_lifecycle.h"

bool RdpGraphicsLifecycle::ValidDesktopSize(int width, int height) {
    return width > 0 && height > 0 &&
        width <= kMaxDesktopDimension && height <= kMaxDesktopDimension;
}

void RdpGraphicsLifecycle::reset(int width, int height, bool gfxRequested) {
    std::lock_guard<std::mutex> lock(mutex_);
    snapshot_ = RdpGraphicsLifecycleSnapshot();
    if (ValidDesktopSize(width, height)) {
        snapshot_.desktopWidth = width;
        snapshot_.desktopHeight = height;
        snapshot_.presentationAllowed = true;
    }
    snapshot_.gfxRequested = gfxRequested;
    pendingWidth_ = 0;
    pendingHeight_ = 0;
    channelInitializing_ = false;
}

RdpResizeTicket RdpGraphicsLifecycle::beginResize(int width, int height) {
    std::lock_guard<std::mutex> lock(mutex_);
    RdpResizeTicket ticket;
    if (!ValidDesktopSize(width, height) || snapshot_.resizeInProgress) {
        return ticket;
    }
    snapshot_.resizeInProgress = true;
    snapshot_.presentationAllowed = false;
    ++nextResizeEpoch_;
    if (nextResizeEpoch_ == 0) {
        ++nextResizeEpoch_;
    }
    snapshot_.epoch = nextResizeEpoch_;
    pendingWidth_ = width;
    pendingHeight_ = height;
    ticket.accepted = true;
    ticket.epoch = snapshot_.epoch;
    ticket.width = width;
    ticket.height = height;
    return ticket;
}

bool RdpGraphicsLifecycle::completeResize(uint64_t epoch, bool success) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!snapshot_.resizeInProgress || epoch == 0 || epoch != snapshot_.epoch) {
        return false;
    }
    snapshot_.resizeInProgress = false;
    if (success) {
        snapshot_.desktopWidth = pendingWidth_;
        snapshot_.desktopHeight = pendingHeight_;
        snapshot_.presentationAllowed = true;
        ++snapshot_.resizeCount;
    } else {
        snapshot_.presentationAllowed = false;
        ++snapshot_.resizeFailures;
    }
    pendingWidth_ = 0;
    pendingHeight_ = 0;
    return true;
}

RdpGfxChannelAction RdpGraphicsLifecycle::onChannelConnected(uintptr_t context) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!snapshot_.gfxRequested || context == 0) {
        return RdpGfxChannelAction::Reject;
    }
    if (snapshot_.gfxChannelContext == context) {
        return RdpGfxChannelAction::Ignore;
    }
    if (snapshot_.gfxChannelContext != 0) {
        return RdpGfxChannelAction::Reject;
    }
    snapshot_.gfxChannelContext = context;
    channelInitializing_ = true;
    return RdpGfxChannelAction::Initialize;
}

void RdpGraphicsLifecycle::completeChannelInitialization(uintptr_t context, bool success) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!channelInitializing_ || context == 0 || snapshot_.gfxChannelContext != context) {
        return;
    }
    channelInitializing_ = false;
    snapshot_.gfxInitialized = success;
    if (!success) {
        snapshot_.gfxChannelContext = 0;
    }
}

RdpGfxChannelAction RdpGraphicsLifecycle::onChannelDisconnected(uintptr_t context) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (context == 0 || snapshot_.gfxChannelContext != context) {
        return RdpGfxChannelAction::Ignore;
    }
    const bool release = snapshot_.gfxInitialized;
    snapshot_.gfxChannelContext = 0;
    snapshot_.gfxInitialized = false;
    channelInitializing_ = false;
    return release ? RdpGfxChannelAction::Release : RdpGfxChannelAction::Ignore;
}

RdpGraphicsLifecycleSnapshot RdpGraphicsLifecycle::snapshot() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return snapshot_;
}

void RdpNextConnectionGfxFallback::mark() {
    pending_.store(true, std::memory_order_release);
}

bool RdpNextConnectionGfxFallback::consume() {
    return pending_.exchange(false, std::memory_order_acq_rel);
}

bool RdpNextConnectionGfxFallback::pending() const {
    return pending_.load(std::memory_order_acquire);
}
