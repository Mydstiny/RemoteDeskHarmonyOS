#ifndef RDP_FILE_CLIPBOARD_OFFER_H
#define RDP_FILE_CLIPBOARD_OFFER_H

#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

enum class RdpFileClipboardOfferResult {
    Ready,
    Empty,
    TooManyFiles,
    InvalidPath
};

struct RdpFileClipboardOfferSnapshot {
    uint64_t generation = 0;
    std::vector<std::string> paths;
    std::string uriList;

    bool ready() const {
        return generation != 0 && !paths.empty() && !uriList.empty();
    }
};

class RdpFileClipboardOffer {
public:
    static constexpr size_t kMaxFilesPerOffer = 15;

    RdpFileClipboardOfferResult replace(const std::vector<std::string>& paths);
    void clear();
    RdpFileClipboardOfferSnapshot snapshot() const;
    bool isCurrent(uint64_t generation) const;

private:
    static bool isStableAbsolutePath(const std::string& path);
    static std::string buildUriList(const std::vector<std::string>& paths);
    void invalidateLocked();

    mutable std::mutex mutex_;
    uint64_t generation_ = 0;
    std::vector<std::string> paths_;
    std::string uriList_;
};

#endif // RDP_FILE_CLIPBOARD_OFFER_H
