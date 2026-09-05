#pragma once

#include "common/happy_eyeballs_connector.h"
#include "ssh_error.h"

#include <cerrno>
#include <netdb.h>

/**
 * Stable SSH-facing classification for resolver and TCP racing outcomes.
 *
 * The common Happy Eyeballs connector intentionally exposes native resolver
 * and errno details. Do not leak those platform-specific values through the
 * ArkTS SSH contract: classify only the failure classes callers can act on.
 */
class SshConnectErrorPolicy final {
public:
    static int fromResolution(
        const remotedesk::net::ResolveResult& resolution) noexcept {
        switch (resolution.status) {
            case remotedesk::net::ResolveStatus::Ready:
                return ERR_SSH_SUCCESS;
            case remotedesk::net::ResolveStatus::TimedOut:
                return ERR_SSH_DNS_TIMEOUT;
            case remotedesk::net::ResolveStatus::Cancelled:
                return ERR_SSH_DNS_CANCELLED;
            case remotedesk::net::ResolveStatus::ResourceExhausted:
                return ERR_SSH_DNS_RESOURCE_EXHAUSTED;
            case remotedesk::net::ResolveStatus::Failed:
                // A resolver worker can report allocation failure after it
                // starts, in which case ResolveStatus remains Failed.
                return resolution.gaiError == EAI_MEMORY
                    ? ERR_SSH_DNS_RESOURCE_EXHAUSTED
                    : ERR_SSH_DNS_RESOLVE;
        }
        return ERR_SSH_DNS_RESOLVE;
    }

    static int fromConnection(
        const remotedesk::net::ConnectResult& connection) noexcept {
        switch (connection.status) {
            case remotedesk::net::ConnectStatus::Connected:
                return connection.descriptor >= 0
                    ? ERR_SSH_SUCCESS : ERR_SSH_SOCKET_CONNECT;
            case remotedesk::net::ConnectStatus::TimedOut:
                return ERR_SSH_CONNECT_TIMEOUT;
            case remotedesk::net::ConnectStatus::Cancelled:
                return ERR_SSH_CONNECT_CANCELLED;
            case remotedesk::net::ConnectStatus::Failed:
                break;
        }
        if (connection.lastError == ECONNREFUSED) {
            return ERR_SSH_CONNECT_REFUSED;
        }
        if (connection.lastError == ETIMEDOUT) {
            return ERR_SSH_CONNECT_TIMEOUT;
        }
        if (connection.lastError == ECANCELED) {
            return ERR_SSH_CONNECT_CANCELLED;
        }
        if (isNoRoute(connection.lastError)) {
            return ERR_SSH_CONNECT_NO_ROUTE;
        }
        return ERR_SSH_SOCKET_CONNECT;
    }

private:
    static bool isNoRoute(int error) noexcept {
        if (error == ENETUNREACH || error == EHOSTUNREACH) {
            return true;
        }
#if defined(ENETDOWN)
        if (error == ENETDOWN) { return true; }
#endif
#if defined(EHOSTDOWN)
        if (error == EHOSTDOWN) { return true; }
#endif
        return false;
    }
};
