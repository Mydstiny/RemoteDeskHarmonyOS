#pragma once

#include <string_view>

namespace remotedesk::extensions {

struct ConnectionPortPolicyInput {
    std::string_view protocol;
    std::string_view rdpGatewayHost;
    std::string_view sshProxyType;
    bool rustDeskDirect = false;
    std::string_view vncTransport;

    bool hasGatewayPort = false;
    int gatewayPort = 0;
    bool hasRustDeskDirectPort = false;
    int rustDeskDirectPort = 0;
    bool hasRustDeskRelayPort = false;
    int rustDeskRelayPort = 0;
    bool hasVncGatewayPort = false;
    int vncGatewayPort = 0;
};

inline bool ConnectionPortIsInvalid(int port) noexcept
{
    return port <= 0 || port > 65535;
}

inline bool HasInvalidActiveOptionalPort(
    const ConnectionPortPolicyInput& input) noexcept
{
    const bool usesGenericGateway =
        (input.protocol == "rdp" && !input.rdpGatewayHost.empty()) ||
        (input.protocol == "ssh" && input.sshProxyType == "legacy_gateway");
    if (usesGenericGateway && input.hasGatewayPort &&
        ConnectionPortIsInvalid(input.gatewayPort)) {
        return true;
    }
    if (input.protocol == "rustdesk") {
        if (input.rustDeskDirect && input.hasRustDeskDirectPort &&
            ConnectionPortIsInvalid(input.rustDeskDirectPort)) {
            return true;
        }
        if (!input.rustDeskDirect && input.hasRustDeskRelayPort &&
            ConnectionPortIsInvalid(input.rustDeskRelayPort)) {
            return true;
        }
    }
    return input.protocol == "vnc" && input.vncTransport != "direct_tcp" &&
        input.hasVncGatewayPort && ConnectionPortIsInvalid(input.vncGatewayPort);
}

} // namespace remotedesk::extensions
