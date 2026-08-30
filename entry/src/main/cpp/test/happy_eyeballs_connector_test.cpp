#include "common/happy_eyeballs_connector.h"
#include "test_runner.h"

#include <arpa/inet.h>
#include <atomic>
#include <chrono>
#include <cstring>
#include <sys/socket.h>
#include <unistd.h>

namespace {

remotedesk::net::ResolvedAddress address4(const char* host, std::uint16_t port) {
    remotedesk::net::ResolvedAddress result;
    auto* value = reinterpret_cast<sockaddr_in*>(&result.storage);
    value->sin_family = AF_INET;
    value->sin_port = htons(port);
    RDP_ASSERT(inet_pton(AF_INET, host, &value->sin_addr) == 1);
    result.length = sizeof(sockaddr_in);
    result.family = AF_INET;
    return result;
}

remotedesk::net::ResolvedAddress address6(const char* host, std::uint16_t port) {
    remotedesk::net::ResolvedAddress result;
    auto* value = reinterpret_cast<sockaddr_in6*>(&result.storage);
    value->sin6_family = AF_INET6;
    value->sin6_port = htons(port);
    RDP_ASSERT(inet_pton(AF_INET6, host, &value->sin6_addr) == 1);
    result.length = sizeof(sockaddr_in6);
    result.family = AF_INET6;
    return result;
}

} // namespace

RDP_TEST_CASE(happy_eyeballs_interleaves_families_and_deduplicates) {
    const auto v6a = address6("2001:db8::1", 443);
    const auto v6b = address6("2001:db8::2", 443);
    const auto v4a = address4("192.0.2.1", 443);
    const auto v4b = address4("192.0.2.2", 443);
    const auto ordered = remotedesk::net::InterleaveAddresses(
        {v6a, v6a, v6b, v4a, v4b});
    RDP_ASSERT(ordered.size() == 4U);
    RDP_ASSERT(ordered[0].family == AF_INET6);
    RDP_ASSERT(ordered[1].family == AF_INET);
    RDP_ASSERT(ordered[2].family == AF_INET6);
    RDP_ASSERT(ordered[3].family == AF_INET);
}

RDP_TEST_CASE(happy_eyeballs_keeps_late_alternate_family_before_candidate_cap) {
    std::vector<remotedesk::net::ResolvedAddress> addresses;
    for (std::uint16_t index = 1; index <= 8; ++index) {
        const std::string host = "2001:db8::" + std::to_string(index);
        addresses.push_back(address6(host.c_str(), 443));
    }
    addresses.push_back(address4("192.0.2.1", 443));

    const auto ordered = remotedesk::net::InterleaveAddresses(addresses, 8U);
    RDP_ASSERT(ordered.size() == 8U);
    RDP_ASSERT(ordered[0].family == AF_INET6);
    RDP_ASSERT(ordered[1].family == AF_INET);
}

RDP_TEST_CASE(happy_eyeballs_falls_back_to_reachable_family) {
    const int listener = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    RDP_ASSERT(listener >= 0);
    int reuse = 1;
    (void)::setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    sockaddr_in bound{};
    bound.sin_family = AF_INET;
    bound.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    bound.sin_port = 0;
    RDP_ASSERT(::bind(listener, reinterpret_cast<sockaddr*>(&bound), sizeof(bound)) == 0);
    RDP_ASSERT(::listen(listener, 1) == 0);
    socklen_t boundLength = sizeof(bound);
    RDP_ASSERT(::getsockname(listener, reinterpret_cast<sockaddr*>(&bound),
                             &boundLength) == 0);
    const std::uint16_t port = ntohs(bound.sin_port);

    remotedesk::net::ConnectOptions options;
    options.deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    options.fallbackDelay = std::chrono::milliseconds(20);
    const auto result = remotedesk::net::ConnectTcpCandidates(
        {address6("::1", port), address4("127.0.0.1", port)}, options);
    RDP_ASSERT(result.status == remotedesk::net::ConnectStatus::Connected);
    RDP_ASSERT(result.family == AF_INET);
    RDP_ASSERT(result.descriptor >= 0);
    RDP_ASSERT(result.attemptedCandidates == 2U);
    ::close(result.descriptor);
    ::close(listener);
}

RDP_TEST_CASE(happy_eyeballs_falls_back_from_ipv4_to_ipv6) {
    const int listener = ::socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP);
    RDP_ASSERT(listener >= 0);
    int v6Only = 1;
    RDP_ASSERT(::setsockopt(listener, IPPROTO_IPV6, IPV6_V6ONLY,
                            &v6Only, sizeof(v6Only)) == 0);
    sockaddr_in6 bound{};
    bound.sin6_family = AF_INET6;
    bound.sin6_addr = in6addr_loopback;
    bound.sin6_port = 0;
    RDP_ASSERT(::bind(listener, reinterpret_cast<sockaddr*>(&bound), sizeof(bound)) == 0);
    RDP_ASSERT(::listen(listener, 1) == 0);
    socklen_t boundLength = sizeof(bound);
    RDP_ASSERT(::getsockname(listener, reinterpret_cast<sockaddr*>(&bound),
                             &boundLength) == 0);
    const std::uint16_t port = ntohs(bound.sin6_port);

    remotedesk::net::ConnectOptions options;
    options.deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    options.fallbackDelay = std::chrono::milliseconds(20);
    const auto result = remotedesk::net::ConnectTcpCandidates(
        {address4("127.0.0.1", port), address6("::1", port)}, options);
    RDP_ASSERT(result.status == remotedesk::net::ConnectStatus::Connected);
    RDP_ASSERT(result.family == AF_INET6);
    RDP_ASSERT(result.descriptor >= 0);
    RDP_ASSERT(result.attemptedCandidates == 2U);
    ::close(result.descriptor);
    ::close(listener);
}

RDP_TEST_CASE(happy_eyeballs_honors_cancellation_before_socket_creation) {
    remotedesk::net::ConnectOptions options;
    options.deadline = std::chrono::steady_clock::now() + std::chrono::seconds(1);
    options.cancelled = []() { return true; };
    const auto result = remotedesk::net::ConnectTcpCandidates(
        {address4("127.0.0.1", 9)}, options);
    RDP_ASSERT(result.status == remotedesk::net::ConnectStatus::Cancelled);
    RDP_ASSERT(result.descriptor < 0);
    RDP_ASSERT(result.attemptedCandidates == 0U);
}

RDP_TEST_CASE(happy_eyeballs_resolves_ipv6_literal_without_dns_worker) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(1);
    const auto result = remotedesk::net::ResolveTcpAddresses(
        "[::1]", "443", deadline, {}, AF_UNSPEC);
    RDP_ASSERT(result.status == remotedesk::net::ResolveStatus::Ready);
    RDP_ASSERT(!result.addresses.empty());
    RDP_ASSERT(result.addresses.front().family == AF_INET6);
}
