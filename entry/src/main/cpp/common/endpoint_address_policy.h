#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace remotedesk::endpoint {

enum class AddressFamily {
    Hostname,
    Ipv4,
    Ipv6,
};

enum class ScopeKind {
    None,
    Interface,
    Numeric,
};

enum class ParseMode {
    Persisted,
    Runtime,
};

enum class ServerIdentityKind {
    None,
    Dns,
    Ip,
};

enum class AddressError {
    None,
    Empty,
    InvalidSyntax,
    InvalidHostname,
    InvalidIpv4,
    InvalidIpv6,
    InvalidPort,
    ScopeRequired,
    ScopeNotAllowed,
    ScopeNotPortable,
    AddressNotConnectable,
    InputTooLong,
};

enum class IdentityError {
    None,
    InvalidEndpoint,
    InvalidServerIdentity,
};

inline constexpr std::uint32_t kAddressVersion = 2U;
inline constexpr std::size_t kMaxInputLength = 512U;

class Address final {
public:
    Address() = default;
    Address(
        std::string canonicalHost,
        AddressFamily family,
        std::uint16_t port = 0U,
        std::string scope = {},
        ScopeKind scopeKind = ScopeKind::None,
        std::uint32_t version = kAddressVersion);

    std::uint32_t version() const noexcept;
    const std::string& canonicalHost() const noexcept;
    AddressFamily family() const noexcept;
    std::uint16_t port() const noexcept;
    const std::string& scope() const noexcept;
    ScopeKind scopeKind() const noexcept;

private:
    std::uint32_t version_ = kAddressVersion;
    std::string canonicalHost_;
    AddressFamily family_ = AddressFamily::Hostname;
    std::uint16_t port_ = 0U;
    std::string scope_;
    ScopeKind scopeKind_ = ScopeKind::None;
};

struct ParseResult {
    bool ok = false;
    Address endpoint;
    AddressError error = AddressError::InvalidSyntax;
};

class ServerIdentity final {
public:
    ServerIdentity() = default;
    ServerIdentity(ServerIdentityKind kind, std::string canonicalName);

    ServerIdentityKind kind() const noexcept;
    const std::string& canonicalName() const noexcept;

private:
    ServerIdentityKind kind_ = ServerIdentityKind::None;
    std::string canonicalName_;
};

struct ServerIdentityResult {
    bool ok = false;
    ServerIdentity identity;
    IdentityError error = IdentityError::InvalidServerIdentity;
};

struct IdentityResult {
    bool ok = false;
    std::string identity;
    IdentityError error = IdentityError::InvalidEndpoint;
};

ParseResult ParseHost(const std::string& input, ParseMode mode = ParseMode::Persisted);
ParseResult ParseAuthority(
    const std::string& input,
    std::uint16_t defaultPort,
    ParseMode mode = ParseMode::Persisted);
ParseResult ParseFields(
    const std::string& hostInput,
    std::uint16_t port,
    ParseMode mode = ParseMode::Persisted);

std::string TransportHost(const Address& endpoint);
std::string FormatHostPort(const Address& endpoint);
std::string FormatUriAuthority(const Address& endpoint);
ServerIdentityResult ParseServerIdentity(const std::string& input);
IdentityResult IdentityV2(const Address& endpoint, const ServerIdentity& serverIdentity = {});

} // namespace remotedesk::endpoint
