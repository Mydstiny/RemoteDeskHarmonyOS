#ifndef TRANSFER_EXPORT_FILES_H
#define TRANSFER_EXPORT_FILES_H

#include <string>

// Directory descriptors are capabilities already authorized by the system
// picker/caller. These functions never resolve an absolute path or reopen a
// root by its name. Returned descriptors belong to the caller and are CLOEXEC.
// Failure returns -1/false and leaves errno set; no existing entry is truncated
// or removed, including failed attempts and partial directory creation.

// Create exactly one new root directory (0700). An existing leaf always fails.
// The returned directory's fstat identity is authoritative if it is renamed.
int openExclusiveTransferDirectory(int authorizedParentFd, const std::string& leaf);

// Create missing directories beneath this root (0700); existing real
// directories are allowed. Every opened component rejects symbolic links.
bool ensureTransferExportDirectory(int authorizedRootFd, const std::string& relativePath);

// Create one new regular file (0600), opened read/write. Parent directories
// must already exist, e.g. via ensureTransferExportDirectory. Existing files,
// including zero-length files and symbolic links, always fail O_EXCL.
int openExclusiveTransferFile(int authorizedRootFd, const std::string& relativePath);

#endif
