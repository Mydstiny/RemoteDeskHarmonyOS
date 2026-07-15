#include "rdp_file_clipboard_offer.h"

#include <limits>

bool RdpFileClipboardOffer::isStableAbsolutePath(const std::string& path) {
    if (path.empty() || path.front() != '/') {
        return false;
    }
    return path.find('\0') == std::string::npos &&
           path.find('\r') == std::string::npos &&
           path.find('\n') == std::string::npos;
}

std::string RdpFileClipboardOffer::buildUriList(const std::vector<std::string>& paths) {
    std::string result;
    for (const auto& path : paths) {
        result.append("file://");
        result.append(path);
        result.append("\r\n");
    }
    return result;
}

void RdpFileClipboardOffer::invalidateLocked() {
    if (generation_ == std::numeric_limits<uint64_t>::max()) {
        generation_ = 1;
    } else {
        ++generation_;
    }
    paths_.clear();
    uriList_.clear();
}

RdpFileClipboardOfferResult RdpFileClipboardOffer::replace(
    const std::vector<std::string>& paths) {
    std::lock_guard<std::mutex> lock(mutex_);
    invalidateLocked();
    if (paths.empty()) {
        return RdpFileClipboardOfferResult::Empty;
    }
    if (paths.size() > kMaxFilesPerOffer) {
        return RdpFileClipboardOfferResult::TooManyFiles;
    }
    for (const auto& path : paths) {
        if (!isStableAbsolutePath(path)) {
            return RdpFileClipboardOfferResult::InvalidPath;
        }
    }
    paths_ = paths;
    uriList_ = buildUriList(paths_);
    return RdpFileClipboardOfferResult::Ready;
}

void RdpFileClipboardOffer::clear() {
    std::lock_guard<std::mutex> lock(mutex_);
    invalidateLocked();
}

RdpFileClipboardOfferSnapshot RdpFileClipboardOffer::snapshot() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return {generation_, paths_, uriList_};
}

bool RdpFileClipboardOffer::isCurrent(uint64_t generation) const {
    std::lock_guard<std::mutex> lock(mutex_);
    return generation != 0 && generation == generation_ &&
           !paths_.empty() && !uriList_.empty();
}
