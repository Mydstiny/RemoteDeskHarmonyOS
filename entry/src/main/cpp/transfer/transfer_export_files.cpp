#include "transfer_export_files.h"

#include <cerrno>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace {
constexpr size_t kMaxRelativeBytes = 4096;
constexpr size_t kMaxRelativeDepth = 32;
constexpr int kDirectoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC;

class OwnedFd {
public:
    explicit OwnedFd(int value = -1) : value_(value) {}
    ~OwnedFd() { reset(); }
    OwnedFd(const OwnedFd&) = delete;
    OwnedFd& operator=(const OwnedFd&) = delete;
    int get() const { return value_; }
    int release() { const int result = value_; value_ = -1; return result; }
    void reset(int next = -1) {
        const int saved = errno;
        if (value_ >= 0) (void)close(value_);
        value_ = next;
        errno = saved;
    }
private:
    int value_;
};

bool splitRelative(const std::string& path, std::vector<std::string>& parts) {
    parts.clear();
    const bool drivePrefix = path.size() >= 2 && path[1] == ':' &&
        ((path[0] >= 'A' && path[0] <= 'Z') || (path[0] >= 'a' && path[0] <= 'z'));
    if (drivePrefix || path.empty() || path.size() > kMaxRelativeBytes || path.front() == '/' ||
        path.find('\0') != std::string::npos || path.find('\\') != std::string::npos) {
        errno = EINVAL;
        return false;
    }
    size_t start = 0;
    while (start <= path.size()) {
        const size_t slash = path.find('/', start);
        const size_t end = slash == std::string::npos ? path.size() : slash;
        const std::string component = path.substr(start, end - start);
        if (component.empty() || component == "." || component == ".." || parts.size() >= kMaxRelativeDepth) {
            errno = EINVAL;
            return false;
        }
        parts.push_back(component);
        if (slash == std::string::npos) return true;
        start = slash + 1;
    }
    errno = EINVAL;
    return false;
}

bool directoryIdentity(int fd, struct stat& identity) {
    if (fstat(fd, &identity) != 0) return false;
    if (!S_ISDIR(identity.st_mode)) { errno = ENOTDIR; return false; }
    return true;
}

int duplicateDirectory(int fd) {
    // Duplicate first so a caller closing/reusing its descriptor cannot retarget
    // a traversal once this operation has captured the capability.
    OwnedFd duplicate(fcntl(fd, F_DUPFD_CLOEXEC, 0));
    if (duplicate.get() < 0) return -1;
    struct stat identity {};
    if (!directoryIdentity(duplicate.get(), identity)) return -1;
    return duplicate.release();
}

int walkDirectories(int root, const std::vector<std::string>& parts, size_t count, bool create) {
    OwnedFd current(duplicateDirectory(root));
    if (current.get() < 0) return -1;
    for (size_t index = 0; index < count; ++index) {
        const char* name = parts[index].c_str();
        if (create && mkdirat(current.get(), name, 0700) != 0 && errno != EEXIST) return -1;
        OwnedFd next(openat(current.get(), name, kDirectoryFlags));
        if (next.get() < 0) return -1;
        struct stat identity {};
        if (!directoryIdentity(next.get(), identity)) return -1;
        current.reset(next.release());
    }
    return current.release();
}
}

int openExclusiveTransferDirectory(int authorizedParentFd, const std::string& leaf) {
    std::vector<std::string> parts;
    if (!splitRelative(leaf, parts) || parts.size() != 1) { errno = EINVAL; return -1; }
    OwnedFd parent(duplicateDirectory(authorizedParentFd));
    if (parent.get() < 0) return -1;
    if (mkdirat(parent.get(), leaf.c_str(), 0700) != 0) return -1;

    // Catch a replaced/symlinked name during the open. After a successful open,
    // the object identified by fstat(fd), not its current pathname, is the root.
    struct stat created {};
    if (fstatat(parent.get(), leaf.c_str(), &created, AT_SYMLINK_NOFOLLOW) != 0) return -1;
    if (!S_ISDIR(created.st_mode)) { errno = ENOTDIR; return -1; }
    OwnedFd root(openat(parent.get(), leaf.c_str(), kDirectoryFlags));
    if (root.get() < 0) return -1;
    struct stat actual {};
    if (!directoryIdentity(root.get(), actual)) return -1;
    if (actual.st_dev != created.st_dev || actual.st_ino != created.st_ino) { errno = ESTALE; return -1; }
    return root.release();
}

bool ensureTransferExportDirectory(int authorizedRootFd, const std::string& relativePath) {
    std::vector<std::string> parts;
    if (!splitRelative(relativePath, parts)) return false;
    OwnedFd directory(walkDirectories(authorizedRootFd, parts, parts.size(), true));
    return directory.get() >= 0;
}

int openExclusiveTransferFile(int authorizedRootFd, const std::string& relativePath) {
    std::vector<std::string> parts;
    if (!splitRelative(relativePath, parts)) return -1;
    OwnedFd parent(walkDirectories(authorizedRootFd, parts, parts.size() - 1, false));
    if (parent.get() < 0) return -1;
    OwnedFd file(openat(parent.get(), parts.back().c_str(), O_CREAT | O_EXCL | O_NOFOLLOW | O_RDWR | O_CLOEXEC, 0600));
    if (file.get() < 0) return -1;
    struct stat identity {};
    if (fstat(file.get(), &identity) != 0) return -1;
    if (!S_ISREG(identity.st_mode)) { errno = EINVAL; return -1; }
    return file.release();
}
