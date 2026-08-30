#pragma once

#include <chrono>
#include <cstddef>
#include <functional>
#include <string>
#include <vector>

#include <netdb.h>
#include <sys/socket.h>

namespace remotedesk::net {

struct ResolvedAddress final {
    sockaddr_storage storage{};
    socklen_t length = 0;
    int family = AF_UNSPEC;
    int socktype = SOCK_STREAM;
    int protocol = IPPROTO_TCP;
};

enum class ResolveStatus {
    Ready,
    Failed,
    TimedOut,
    Cancelled,
    ResourceExhausted,
};

struct ResolveResult final {
    ResolveStatus status = ResolveStatus::Failed;
    int gaiError = EAI_FAIL;
    std::vector<ResolvedAddress> addresses;
};

enum class ConnectStatus {
    Connected,
    Failed,
    TimedOut,
    Cancelled,
};

struct ConnectOptions final {
    std::chrono::steady_clock::time_point deadline;
    std::chrono::milliseconds fallbackDelay{250};
    std::function<bool()> cancelled;
    std::size_t maxCandidates = 16;
    bool restoreBlocking = true;
};

struct ConnectResult final {
    ConnectStatus status = ConnectStatus::Failed;
    int descriptor = -1;
    int family = AF_UNSPEC;
    int lastError = 0;
    std::size_t attemptedCandidates = 0;
    std::string numericAddress;
};

// RFC 8305-style family interleaving while preserving the resolver's first
// family and the order within each family. Duplicate socket addresses are
// removed before dialing.
std::vector<ResolvedAddress> InterleaveAddresses(
    const std::vector<ResolvedAddress>& addresses,
    std::size_t maxCandidates = 16);

// getaddrinfo() has no portable cancellation API. Resolution therefore runs
// in a lifetime-safe worker behind a process-wide hard cap. The caller never
// waits past deadline and an abandoned worker cannot access caller storage.
ResolveResult ResolveTcpAddresses(
    const std::string& host,
    const std::string& service,
    std::chrono::steady_clock::time_point deadline,
    const std::function<bool()>& cancelled = {},
    int family = AF_UNSPEC,
    std::size_t maxCandidates = 16);

// Races non-blocking sockets under one absolute deadline. The first success
// wins and every losing descriptor is closed before this function returns.
ConnectResult ConnectTcpCandidates(
    const std::vector<ResolvedAddress>& addresses,
    const ConnectOptions& options);

ResolveResult ResolveAndConnectTcp(
    const std::string& host,
    const std::string& service,
    const ConnectOptions& options,
    ConnectResult& connection,
    int family = AF_UNSPEC);

} // namespace remotedesk::net
