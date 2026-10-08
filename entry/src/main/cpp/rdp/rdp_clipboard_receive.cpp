#include "rdp_clipboard_receive.h"
#include "rdp_remote_file_offer.h"
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <dirent.h>
#include <fcntl.h>
#include <map>
#include <mutex>
#include <set>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>

struct RdpClipboardReceive::State {
    mutable std::mutex mutex;
    std::mutex sendMutex;
    std::condition_variable cv;
    RemoteClipboardReceiveStatus status;
    RdpClipboardReceiveOptions options;
    std::vector<RemoteClipboardFileEntry> entries;
    Sender sender;
    Unlocker unlocker;
    int stageFd = -1;
    uint32_t clipDataId = 0;
    bool cancelled = false;
    bool started = false;
    bool hugeFileSupported = false;
    bool responseReady = false;
    bool responseSuccess = false;
    RdpClipboardFileRequest pending;
    std::vector<uint8_t> responseData;
    std::chrono::steady_clock::time_point deadline;
    ~State() { if (stageFd >= 0) close(stageFd); }
};
namespace {
// One request per 512 KiB (it used to be 64 KiB, one round trip each): a shorter answer near a file's end, or from
// a peer that caps its answers, is continued from where it stopped.
constexpr uint32_t kBlockBytes = 512 * 1024;
std::atomic<uint64_t> nextStream {1};
bool terminal(const std::string& phase) {
    return phase == "completed" || phase == "failed" || phase == "cancelled";
}
struct Fd {
    int value = -1;
    explicit Fd(int fd = -1) : value(fd) {}
    ~Fd() { if (value >= 0) close(value); }
    Fd(const Fd&) = delete;
    Fd& operator=(const Fd&) = delete;
};
uint64_t le64(const uint8_t* data) {
    uint64_t result = 0; for (int i = 7; i >= 0; --i) result = (result << 8) | data[i]; return result;
}
bool isCancelled(const std::shared_ptr<RdpClipboardReceive::State>& state) {
    std::lock_guard<std::mutex> lock(state->mutex); return state->cancelled;
}
int directory(int root, const std::string& path, bool create) {
    int fd = fcntl(root, F_DUPFD_CLOEXEC, 0);
    size_t start = 0;
    while (fd >= 0 && start < path.size()) {
        const auto slash = path.find('/', start);
        const auto part = path.substr(start, slash == std::string::npos ? slash : slash - start);
        if (create && mkdirat(fd, part.c_str(), 0700) != 0 && errno != EEXIST) { close(fd); return -1; }
        const int next = openat(fd, part.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        close(fd); fd = next;
        if (slash == std::string::npos) break;
        start = slash + 1;
    }
    return fd;
}
bool cleanOwnedTree(int fd, unsigned depth = 0) {
    if (depth > 36) return false;
    const int duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 0);
    if (duplicate < 0) return false;
    DIR* dir = fdopendir(duplicate);
    if (!dir) { close(duplicate); return false; }
    bool ok = true;
    for (dirent* entry = readdir(dir); entry; entry = readdir(dir)) {
        const std::string name = entry->d_name;
        if (name == "." || name == "..") continue;
        struct stat info {};
        if (fstatat(fd, name.c_str(), &info, AT_SYMLINK_NOFOLLOW) != 0) { ok = false; continue; }
        if (S_ISDIR(info.st_mode)) {
            Fd child(openat(fd, name.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
            if (child.value < 0 || !cleanOwnedTree(child.value, depth + 1) || unlinkat(fd, name.c_str(), AT_REMOVEDIR) != 0) ok = false;
        } else if (unlinkat(fd, name.c_str(), 0) != 0) ok = false;
    }
    closedir(dir); return ok;
}
bool request(const std::shared_ptr<RdpClipboardReceive::State>& state,
    uint32_t index, uint64_t offset, uint32_t bytes, bool sizeQuery,
    std::vector<uint8_t>& result, std::string& error) {
    const uint64_t stream = nextStream.fetch_add(1, std::memory_order_relaxed);
    if (stream > UINT32_MAX) { error = "stream_ids_exhausted"; return false; }
    RdpClipboardFileRequest value {uint32_t(stream), index, offset, bytes, sizeQuery, state->clipDataId};
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        if (state->cancelled) return false;
        if (std::chrono::steady_clock::now() >= state->deadline) { error = "receive_overall_timeout"; return false; }
        state->pending = value; state->responseReady = false; state->responseData.clear();
    }
    bool sent = false;
    {
        // Cancellation drains this short send admission before it returns.
        // Never hold the state mutex while calling channel code: a test/peer
        // may deliver an immediate response on the sending thread.
        std::lock_guard<std::mutex> sendLock(state->sendMutex);
        if (!isCancelled(state)) sent = state->sender && state->sender(value);
    }
    if (!sent) { error = "file_request_send_failed"; return false; }
    std::unique_lock<std::mutex> lock(state->mutex);
    const auto deadline = std::min(state->deadline, std::chrono::steady_clock::now() +
        std::chrono::milliseconds(state->options.requestTimeoutMs));
    if (!state->cv.wait_until(lock, deadline, [&] { return state->cancelled || state->responseReady; })) {
        state->pending = {}; error = "file_request_timeout"; return false;
    }
    if (state->cancelled) return false;
    state->pending = {};
    if (!state->responseSuccess) { error = "remote_file_response_failed"; return false; }
    result = std::move(state->responseData); return true;
}
bool writeAll(int fd, const uint8_t* bytes, size_t count, uint64_t offset) {
    while (count) {
        const ssize_t written = pwrite(fd, bytes, count, static_cast<off_t>(offset));
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return false;
        bytes += written; count -= size_t(written); offset += uint64_t(written);
    }
    return true;
}
void run(const std::shared_ptr<RdpClipboardReceive::State>& state) {
    const auto rootName = "receive-" + std::to_string(state->status.taskId);
    std::string error;
    std::vector<RemoteClipboardArtifact> artifacts;
    bool created = false, complete = false;
    Fd root;
    // Keep all failures in one finish path so lock, descriptors and temporary
    // artifacts have one owner regardless of how far the transfer progressed.
    auto work = [&]() -> bool {
        if (isCancelled(state)) return false;
        if (mkdirat(state->stageFd, rootName.c_str(), 0700) != 0) { error = "private_stage_create_failed"; return false; }
        created = true;
        root.value = openat(state->stageFd, rootName.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (root.value < 0) { error = "private_stage_open_failed"; return false; }
        Fd partial(directory(root.value, "partial", true)), files(directory(root.value, "files", true));
        if (partial.value < 0 || files.value < 0) { error = "private_stage_open_failed"; return false; }
        const uint64_t limit = std::min(state->options.maxTotalBytes, RdpRemoteFileOffer::kMaxTotalBytes);
        uint64_t total = 0;
        for (auto& entry : state->entries) {
            if (isCancelled(state)) return false;
            if (!entry.sizeKnown && !entry.directory) {
                std::vector<uint8_t> bytes;
                if (!request(state, entry.index, 0, 8, true, bytes, error)) return false;
                if (bytes.size() != 8) { error = "invalid_file_size_response"; return false; }
                entry.size = le64(bytes.data()); entry.sizeKnown = true;
            }
            if ((!state->hugeFileSupported && entry.size >= 0x80000000ULL) ||
                entry.size > limit - total) { error = "file_size_budget_exceeded"; return false; }
            total += entry.size;
        }
        struct statvfs space {};
        if (fstatvfs(state->stageFd, &space) != 0 || space.f_frsize == 0) { error = "storage_probe_failed"; return false; }
        if (total / space.f_frsize + (total % space.f_frsize != 0) > space.f_bavail) { error = "insufficient_storage"; return false; }
        {
            std::lock_guard<std::mutex> lock(state->mutex);
            if (state->cancelled) return false;
            state->status.totalBytes = total; state->status.totalKnown = true; state->status.phase = "receiving";
        }
        for (const auto& entry : state->entries) {
            if (isCancelled(state)) return false;
            { std::lock_guard<std::mutex> lock(state->mutex); state->status.currentIndex = entry.index; }
            if (entry.directory) {
                Fd dir(directory(files.value, entry.relativeName, true));
                if (dir.value < 0 || fsync(dir.value) != 0) { error = "directory_create_failed"; return false; }
            } else {
                const auto slash = entry.relativeName.rfind('/');
                const std::string parent = slash == std::string::npos ? "" : entry.relativeName.substr(0, slash);
                const std::string leaf = slash == std::string::npos ? entry.relativeName : entry.relativeName.substr(slash + 1);
                Fd parentFd(directory(files.value, parent, true));
                if (parentFd.value < 0) { error = "directory_create_failed"; return false; }
                const std::string temporary = std::to_string(entry.index);
                Fd file(openat(partial.value, temporary.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600));
                if (file.value < 0) { error = "partial_create_failed"; return false; }
                uint64_t offset = 0;
                while (offset < entry.size) {
                    if (isCancelled(state)) return false;
                    const uint32_t count = uint32_t(std::min<uint64_t>(kBlockBytes, entry.size - offset));
                    std::vector<uint8_t> bytes;
                    if (!request(state, entry.index, offset, count, false, bytes, error)) return false;
                    if (bytes.empty() || bytes.size() > count) { error = "premature_file_eof"; return false; }
                    {
                        std::lock_guard<std::mutex> lock(state->mutex);
                        if (state->status.transferredBytes > limit || bytes.size() > limit - state->status.transferredBytes) {
                            error = "file_size_budget_exceeded"; return false;
                        }
                    }
                    if (!writeAll(file.value, bytes.data(), bytes.size(), offset)) { error = "partial_write_failed"; return false; }
                    offset += bytes.size();
                    { std::lock_guard<std::mutex> lock(state->mutex); state->status.transferredBytes += bytes.size(); }
                }
                if (isCancelled(state)) return false;
                { std::lock_guard<std::mutex> lock(state->mutex); state->status.phase = "verifying"; }
                struct stat info {};
                if (fstat(file.value, &info) != 0 || uint64_t(info.st_size) != entry.size || fsync(file.value) != 0) {
                    error = "partial_verify_failed"; return false;
                }
                // linkat is an atomic no-replace publication on this same
                // filesystem; unlike renameat it cannot overwrite an existing file.
                if (linkat(partial.value, temporary.c_str(), parentFd.value, leaf.c_str(), 0) != 0 ||
                    unlinkat(partial.value, temporary.c_str(), 0) != 0 || fsync(parentFd.value) != 0) {
                    error = "artifact_commit_failed"; return false;
                }
            }
            artifacts.push_back({entry.index, rootName + "/files/" + entry.relativeName, entry.directory, entry.size});
        }
        if (isCancelled(state)) return false;
        if (fsync(files.value) != 0 || fsync(root.value) != 0 || fsync(state->stageFd) != 0) { error = "artifact_commit_failed"; return false; }
        return true;
    };
    try { complete = work(); } catch (...) { error = "receive_worker_exception"; }
    std::lock_guard<std::mutex> finishLock(state->sendMutex);
    bool cancelled = isCancelled(state);
    if (!complete || cancelled) {
        if (root.value >= 0) (void)cleanOwnedTree(root.value);
        if (created) (void)unlinkat(state->stageFd, rootName.c_str(), AT_REMOVEDIR);
        artifacts.clear(); complete = false;
    }
    {
        try { if (state->clipDataId && state->unlocker) state->unlocker(state->clipDataId); }
        catch (...) { if (error.empty()) error = "clipboard_unlock_failed"; }
        std::lock_guard<std::mutex> lock(state->mutex);
        state->clipDataId = 0;
        state->pending = {};
        cancelled = state->cancelled;
        state->status.phase = complete && !cancelled ? "completed" : cancelled ? "cancelled" : "failed";
        if (state->status.diagnosticCode.empty()) state->status.diagnosticCode = error;
        if (complete && !cancelled) state->status.artifacts = std::move(artifacts);
        state->sender = {}; state->unlocker = {};
    }
    state->cv.notify_all();
}
}
RdpClipboardReceive::RdpClipboardReceive(RdpClipboardReceiveOptions options) : state_(std::make_shared<State>()) {
    state_->options = options;
}
RdpClipboardReceive::~RdpClipboardReceive() { cancel("receiver_closed"); }
bool RdpClipboardReceive::start(uint64_t taskId, const RemoteClipboardFileOffer& offer,
    const std::vector<uint32_t>& selected, int stageDirectoryFd, uint32_t clipDataId,
    Sender sender, Unlocker unlocker) {
    if (!taskId || offer.state != "ready" || !offer.streamSupported || offer.entries.empty() || offer.entries.size() > 1024 || selected.empty() || !sender) return false;
    struct stat info {};
    if (fstat(stageDirectoryFd, &info) != 0 || !S_ISDIR(info.st_mode) || info.st_uid != getuid()) return false;
    const int fd = fcntl(stageDirectoryFd, F_DUPFD_CLOEXEC, 0);
    if (fd < 0) return false;
    std::vector<RemoteClipboardFileEntry> entries;
    for (const auto index : selected) if (index >= offer.entries.size()) { close(fd); return false; }
    for (const auto& entry : offer.entries) {
        bool include = std::find(selected.begin(), selected.end(), entry.index) != selected.end();
        for (const auto index : selected) {
            const auto& parent = offer.entries[index];
            if (parent.directory && entry.relativeName.compare(0, parent.relativeName.size() + 1, parent.relativeName + "/") == 0) include = true;
        }
        std::string normalized;
        if (include && (!RdpRemoteFileOffer::safeRelativeName(entry.relativeName, normalized) || normalized != entry.relativeName)) { close(fd); return false; }
        if (include) entries.push_back(entry);
    }
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (state_->started || entries.empty()) { close(fd); return false; }
    state_->started = true; state_->stageFd = fd; state_->clipDataId = clipDataId;
    state_->hugeFileSupported = offer.hugeFileSupported;
    state_->entries = std::move(entries); state_->sender = std::move(sender); state_->unlocker = std::move(unlocker);
    state_->status.taskId = taskId; state_->status.sequence = offer.sequence; state_->status.phase = "queued";
    state_->deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(state_->options.overallTimeoutMs);
    try {
        if (worker_.enqueue([state = state_] { run(state); }) != 0) return true;
    } catch (...) {}
    close(state_->stageFd); state_->stageFd = -1; state_->started = false; state_->sender = {}; state_->unlocker = {};
    state_->status.phase = "failed"; state_->status.diagnosticCode = "worker_admission_failed"; return false;
}
bool RdpClipboardReceive::response(uint32_t streamId, bool success, const uint8_t* data, size_t size) {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (!state_->started || state_->cancelled || !streamId || state_->pending.streamId != streamId || state_->responseReady) return false;
    state_->responseReady = true;
    state_->responseSuccess = success && size <= state_->pending.requested && (data || size == 0);
    if (state_->responseSuccess && size) state_->responseData.assign(data, data + size);
    else state_->responseData.clear();
    state_->cv.notify_all(); return true;
}
bool RdpClipboardReceive::cancel(const std::string& reason) {
    std::lock_guard<std::mutex> sendLock(state_->sendMutex);
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (!state_->started || terminal(state_->status.phase)) return false;
    state_->cancelled = true; state_->status.phase = "cancelling"; state_->status.diagnosticCode = reason;
    state_->cv.notify_all(); return true;
}
void RdpClipboardReceive::offerChanged(uint64_t sequence) {
    bool cancelTask = false;
    { std::lock_guard<std::mutex> lock(state_->mutex); cancelTask = state_->started && !state_->clipDataId && state_->status.sequence != sequence; }
    if (cancelTask) cancel("clipboard_changed_without_lock");
}
RemoteClipboardReceiveStatus RdpClipboardReceive::status() const { std::lock_guard<std::mutex> lock(state_->mutex); return state_->status; }
