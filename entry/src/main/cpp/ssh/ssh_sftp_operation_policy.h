#pragma once

#include <utility>

struct SshSftpOperationObservation {
    int errorCode = 0;
    bool transportLost = false;
};

/**
 * Execute and classify an SFTP result synchronously inside one owner command.
 * The classifier runs before this function returns, so a queued recovery
 * command cannot be interposed between the libssh2 failure and its snapshot.
 */
template <typename Operation, typename Classifier>
SshSftpOperationObservation ObserveSshSftpOperationOnOwner(
        Operation&& operation, Classifier&& classifier) {
    const int errorCode = std::forward<Operation>(operation)();
    return {
        errorCode,
        std::forward<Classifier>(classifier)(errorCode)
    };
}
