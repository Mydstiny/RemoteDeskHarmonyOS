#include "transfer/transfer_export_files.h"
#include "test_runner.h"

#include <atomic>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <filesystem>
#include <string>
#include <sys/stat.h>
#include <thread>
#include <unistd.h>
#include <vector>

namespace {
class TempExport {
public:
    TempExport() {
        char pattern[] = "/tmp/rdp-export-test-XXXXXX";
        char* value = mkdtemp(pattern);
        if (value) { path = value; fd = open(value, O_RDONLY | O_DIRECTORY | O_CLOEXEC); }
    }
    ~TempExport() { if (fd >= 0) close(fd); if (!path.empty()) std::filesystem::remove_all(path); }
    std::string path;
    int fd = -1;
};
std::string readFile(int parent, const char* name) {
    const int fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return {};
    char value[128] {}; const auto count = read(fd, value, sizeof(value)); close(fd);
    return count > 0 ? std::string(value, static_cast<size_t>(count)) : std::string();
}
void makeFile(int parent, const char* name, const std::string& content) {
    const int fd = openat(parent, name, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600);
    RDP_ASSERT(fd >= 0);
    RDP_ASSERT_EQ(write(fd, content.data(), content.size()), static_cast<ssize_t>(content.size()));
    close(fd);
}
std::string nested(size_t depth) {
    std::string result;
    for (size_t i = 0; i < depth; ++i) { if (!result.empty()) result += '/'; result += "d"; }
    return result;
}
}

RDP_TEST_CASE(transfer_export_creates_unique_private_root_and_exclusive_rdwr_file) {
    TempExport fixture; RDP_ASSERT(fixture.fd >= 0);
    const int root = openExclusiveTransferDirectory(fixture.fd, "batch"); RDP_ASSERT(root >= 0);
    struct stat identity {}; RDP_ASSERT_EQ(fstat(root, &identity), 0); RDP_ASSERT(S_ISDIR(identity.st_mode));
    RDP_ASSERT_EQ(identity.st_mode & 0777, 0700U); RDP_ASSERT((fcntl(root, F_GETFD) & FD_CLOEXEC) != 0);
    RDP_ASSERT(ensureTransferExportDirectory(root, "folder/nested"));
    RDP_ASSERT(ensureTransferExportDirectory(root, "folder/nested"));
    const int file = openExclusiveTransferFile(root, "folder/nested/content"); RDP_ASSERT(file >= 0);
    RDP_ASSERT_EQ(fcntl(file, F_GETFL) & O_ACCMODE, O_RDWR); RDP_ASSERT((fcntl(file, F_GETFD) & FD_CLOEXEC) != 0);
    RDP_ASSERT_EQ(fstat(file, &identity), 0); RDP_ASSERT_EQ(identity.st_mode & 0777, 0600U);
    RDP_ASSERT_EQ(write(file, "bytes", 5), 5); RDP_ASSERT_EQ(lseek(file, 0, SEEK_SET), 0);
    char output[5] {}; RDP_ASSERT_EQ(read(file, output, 5), 5); RDP_ASSERT(std::memcmp(output, "bytes", 5) == 0);
    close(file); close(root);
}
RDP_TEST_CASE(transfer_export_existing_root_or_file_is_never_reopened_or_truncated) {
    TempExport fixture; RDP_ASSERT(ensureTransferExportDirectory(fixture.fd, "existing"));
    RDP_ASSERT_EQ(openExclusiveTransferDirectory(fixture.fd, "existing"), -1);
    makeFile(fixture.fd, "occupied", "original"); makeFile(fixture.fd, "empty", "");
    RDP_ASSERT_EQ(openExclusiveTransferFile(fixture.fd, "occupied"), -1);
    RDP_ASSERT_EQ(openExclusiveTransferFile(fixture.fd, "empty"), -1);
    RDP_ASSERT(readFile(fixture.fd, "occupied") == "original");
    struct stat empty {}; RDP_ASSERT_EQ(fstatat(fixture.fd, "empty", &empty, AT_SYMLINK_NOFOLLOW), 0); RDP_ASSERT_EQ(empty.st_size, 0);
}
RDP_TEST_CASE(transfer_export_rejects_invalid_paths_before_any_creation) {
    TempExport fixture;
    const std::vector<std::string> invalid = {"", "/absolute", "C:/absolute", "C:relative", "..", ".", "a/../b", "a/./b", "a//b", "a/", "a\\b", std::string("a\0b", 3), std::string(4097, 'a'), nested(33)};
    for (const auto& path : invalid) {
        RDP_ASSERT_EQ(openExclusiveTransferFile(fixture.fd, path), -1);
        RDP_ASSERT(!ensureTransferExportDirectory(fixture.fd, path));
    }
    RDP_ASSERT_EQ(openExclusiveTransferDirectory(fixture.fd, "one/two"), -1);
    RDP_ASSERT(std::filesystem::is_empty(fixture.path));
}
RDP_TEST_CASE(transfer_export_depth_boundary_and_missing_parent_are_explicit) {
    TempExport fixture; const auto maximum = nested(32);
    RDP_ASSERT(ensureTransferExportDirectory(fixture.fd, maximum));
    RDP_ASSERT(!ensureTransferExportDirectory(fixture.fd, maximum + "/overflow"));
    RDP_ASSERT_EQ(openExclusiveTransferFile(fixture.fd, "missing/file"), -1);
    RDP_ASSERT(!std::filesystem::exists(fixture.path + "/missing"));
}
RDP_TEST_CASE(transfer_export_rejects_symlink_roots_files_and_every_directory_component) {
    TempExport fixture, outside; makeFile(outside.fd, "keep", "untouched");
    RDP_ASSERT_EQ(symlinkat(outside.path.c_str(), fixture.fd, "link"), 0);
    RDP_ASSERT_EQ(openExclusiveTransferDirectory(fixture.fd, "link"), -1);
    RDP_ASSERT(!ensureTransferExportDirectory(fixture.fd, "link/nested"));
    RDP_ASSERT_EQ(openExclusiveTransferFile(fixture.fd, "link/new"), -1);
    RDP_ASSERT(ensureTransferExportDirectory(fixture.fd, "safe"));
    const std::string target = outside.path + "/keep";
    RDP_ASSERT_EQ(symlinkat(target.c_str(), fixture.fd, "safe/target"), 0);
    RDP_ASSERT_EQ(openExclusiveTransferFile(fixture.fd, "safe/target"), -1);
    RDP_ASSERT_EQ(symlinkat(outside.path.c_str(), fixture.fd, "safe/inner"), 0);
    RDP_ASSERT(!ensureTransferExportDirectory(fixture.fd, "safe/inner/new"));
    RDP_ASSERT(readFile(outside.fd, "keep") == "untouched"); RDP_ASSERT(!std::filesystem::exists(outside.path + "/new"));
}
RDP_TEST_CASE(transfer_export_root_fd_is_authoritative_after_root_rename_and_name_replacement) {
    TempExport fixture, outside;
    const int root = openExclusiveTransferDirectory(fixture.fd, "batch"); RDP_ASSERT(root >= 0);
    struct stat before {}; RDP_ASSERT_EQ(fstat(root, &before), 0);
    RDP_ASSERT_EQ(renameat(fixture.fd, "batch", fixture.fd, "moved"), 0);
    RDP_ASSERT_EQ(symlinkat(outside.path.c_str(), fixture.fd, "batch"), 0);
    RDP_ASSERT(ensureTransferExportDirectory(root, "dir"));
    const int file = openExclusiveTransferFile(root, "dir/file"); RDP_ASSERT(file >= 0); close(file);
    struct stat after {}; RDP_ASSERT_EQ(fstat(root, &after), 0); RDP_ASSERT_EQ(after.st_ino, before.st_ino);
    RDP_ASSERT(std::filesystem::exists(fixture.path + "/moved/dir/file")); RDP_ASSERT(std::filesystem::is_empty(outside.path)); close(root);
}
RDP_TEST_CASE(transfer_export_authorized_parent_fd_survives_parent_rename_without_following_its_old_path) {
    TempExport fixture, outside;
    RDP_ASSERT(ensureTransferExportDirectory(fixture.fd, "authorized"));
    const int parent = openat(fixture.fd, "authorized", O_RDONLY | O_DIRECTORY | O_CLOEXEC); RDP_ASSERT(parent >= 0);
    RDP_ASSERT_EQ(renameat(fixture.fd, "authorized", fixture.fd, "moved"), 0);
    RDP_ASSERT_EQ(symlinkat(outside.path.c_str(), fixture.fd, "authorized"), 0);
    const int root = openExclusiveTransferDirectory(parent, "batch"); RDP_ASSERT(root >= 0); close(root); close(parent);
    RDP_ASSERT(std::filesystem::is_directory(fixture.path + "/moved/batch")); RDP_ASSERT(std::filesystem::is_empty(outside.path));
}
RDP_TEST_CASE(transfer_export_rejects_source_regular_file_and_invalid_descriptors_as_roots) {
    TempExport fixture; makeFile(fixture.fd, "source", "source bytes");
    const int source = openat(fixture.fd, "source", O_RDWR | O_CLOEXEC); RDP_ASSERT(source >= 0);
    for (const int root : {source, -1}) {
        RDP_ASSERT_EQ(openExclusiveTransferDirectory(root, "child"), -1);
        RDP_ASSERT_EQ(openExclusiveTransferFile(root, "child"), -1);
        RDP_ASSERT(!ensureTransferExportDirectory(root, "child"));
    }
    close(source); RDP_ASSERT(readFile(fixture.fd, "source") == "source bytes");
}
RDP_TEST_CASE(transfer_export_two_concurrent_creators_cannot_share_the_same_output_file) {
    TempExport fixture; std::atomic<int> success {0};
    auto create = [&] { const int fd = openExclusiveTransferFile(fixture.fd, "raced"); if (fd >= 0) { ++success; write(fd, "one", 3); close(fd); } };
    std::thread first(create), second(create); first.join(); second.join();
    RDP_ASSERT_EQ(success.load(), 1); RDP_ASSERT(readFile(fixture.fd, "raced") == "one");
}
RDP_TEST_CASE(transfer_export_concurrent_existing_file_replacement_never_modifies_an_existing_inode) {
    TempExport fixture; makeFile(fixture.fd, "original", "preserve");
    const int original = openat(fixture.fd, "original", O_RDONLY | O_CLOEXEC); RDP_ASSERT(original >= 0);
    RDP_ASSERT_EQ(linkat(fixture.fd, "original", fixture.fd, "target", 0), 0);
    std::atomic<bool> run {true};
    std::thread replace([&] { while (run.load()) {
        (void)unlinkat(fixture.fd, "target", 0); (void)linkat(fixture.fd, "original", fixture.fd, "target", 0);
    } });
    for (size_t i = 0; i < 1000; ++i) {
        const int fd = openExclusiveTransferFile(fixture.fd, "target");
        if (fd >= 0) { RDP_ASSERT_EQ(write(fd, "export", 6), 6); close(fd); }
    }
    run.store(false); replace.join();
    char bytes[8] {}; RDP_ASSERT_EQ(read(original, bytes, sizeof(bytes)), 8); RDP_ASSERT(std::memcmp(bytes, "preserve", 8) == 0); close(original);
}
RDP_TEST_CASE(transfer_export_concurrent_symlink_swap_never_follows_the_target) {
    TempExport fixture, outside; makeFile(outside.fd, "keep", "original");
    const std::string target = outside.path + "/keep";
    std::atomic<bool> run {true};
    std::thread replace([&] { while (run.load()) {
        (void)unlinkat(fixture.fd, "target", 0); (void)symlinkat(target.c_str(), fixture.fd, "target");
    } });
    for (size_t i = 0; i < 1000; ++i) {
        const int fd = openExclusiveTransferFile(fixture.fd, "target");
        if (fd >= 0) { RDP_ASSERT_EQ(write(fd, "export", 6), 6); close(fd); }
    }
    run.store(false); replace.join(); RDP_ASSERT(readFile(outside.fd, "keep") == "original");
}
RDP_TEST_CASE(transfer_export_concurrent_parent_symlink_substitution_cannot_escape_directory_fd_walk) {
    TempExport fixture, outside; RDP_ASSERT(ensureTransferExportDirectory(fixture.fd, "parent"));
    std::atomic<bool> run {true};
    std::thread replace([&] { while (run.load()) {
        if (renameat(fixture.fd, "parent", fixture.fd, "held") == 0) {
            (void)symlinkat(outside.path.c_str(), fixture.fd, "parent");
            (void)unlinkat(fixture.fd, "parent", 0); (void)renameat(fixture.fd, "held", fixture.fd, "parent");
        }
    } });
    for (size_t i = 0; i < 1000; ++i) {
        const auto path = std::string("parent/file-") + std::to_string(i);
        const int fd = openExclusiveTransferFile(fixture.fd, path); if (fd >= 0) close(fd);
    }
    run.store(false); replace.join(); RDP_ASSERT(std::filesystem::is_empty(outside.path));
}
RDP_TEST_CASE(transfer_export_two_concurrent_root_creators_have_one_owned_directory) {
    TempExport fixture; std::atomic<int> success {0};
    auto create = [&] { const int fd = openExclusiveTransferDirectory(fixture.fd, "batch"); if (fd >= 0) { ++success; close(fd); } };
    std::thread first(create), second(create); first.join(); second.join();
    RDP_ASSERT_EQ(success.load(), 1); RDP_ASSERT(std::filesystem::is_directory(fixture.path + "/batch"));
}
RDP_TEST_CASE(transfer_export_failure_paths_close_every_duplicated_descriptor) {
    TempExport fixture; makeFile(fixture.fd, "existing", "keep");
    const int before = fcntl(fixture.fd, F_DUPFD_CLOEXEC, 0); RDP_ASSERT(before >= 0); close(before);
    for (size_t index = 0; index < 1000; ++index) {
        RDP_ASSERT_EQ(openExclusiveTransferDirectory(fixture.fd, "existing"), -1);
        RDP_ASSERT_EQ(openExclusiveTransferFile(fixture.fd, "existing"), -1);
        RDP_ASSERT_EQ(openExclusiveTransferFile(fixture.fd, "missing/file"), -1);
        RDP_ASSERT(!ensureTransferExportDirectory(fixture.fd, "existing/child"));
    }
    const int after = fcntl(fixture.fd, F_DUPFD_CLOEXEC, 0); RDP_ASSERT_EQ(after, before); close(after);
    RDP_ASSERT(readFile(fixture.fd, "existing") == "keep");
}
