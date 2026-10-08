#pragma once

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace remotedesk::net {

/**
 * Names a Windows client resolves without DNS: a computer name ("DESKTOP-1A2B",
 * "office-pc") through LLMNR or NetBIOS, and "<name>.local" through multicast
 * DNS. mstsc reaches such hosts on a home or office LAN; getaddrinfo on
 * HarmonyOS only asks DNS. This resolver asks the local network directly.
 */
enum class LocalNameKind { None, SingleLabel, MdnsLocal };

/** Single DNS label of letters, digits and hyphens (1..63), or a dotted name ending in ".local". */
LocalNameKind ClassifyLocalName(const std::string& name);

struct LocalNameResolution {
    std::vector<std::string> addresses;  // numeric IPv4 / global IPv6, de-duplicated, first answer first
    std::string method;                  // "mdns", "llmnr", "netbios" (the first that answered)
};

/**
 * Query mDNS (one-shot, unicast reply to our port), LLMNR (A and AAAA) and
 * NetBIOS name service (broadcast, <20> and <00>) at once and collect answers
 * until `timeout`, returning shortly after the first answer. Link-local IPv6
 * answers are dropped (they need an interface scope RDP cannot use).
 */
LocalNameResolution ResolveLocalHostName(const std::string& name, std::chrono::milliseconds timeout,
                                         const std::function<bool()>& cancelled = {});

// ---- Packet helpers (exposed for tests) ----

/** A DNS question packet (no recursion), class IN with the mDNS unicast-response bit when asked. */
std::vector<uint8_t> BuildDnsQuery(uint16_t id, const std::string& name, uint16_t type, bool unicastResponse);

/** A and AAAA answers for `name` in a DNS/mDNS/LLMNR response; `id` is checked unless `anyId`. */
bool ParseDnsAnswers(const uint8_t* data, size_t size, uint16_t id, bool anyId, const std::string& name,
                     std::vector<std::string>& addresses);

/** RFC 1001 first-level encoding of a NetBIOS name (uppercased, space padded to 15, then `suffix`). */
std::string EncodeNetbiosName(const std::string& name, uint8_t suffix);

/** A broadcast NetBIOS name query (NB, IN) for `name` with `suffix`. */
std::vector<uint8_t> BuildNetbiosNameQuery(uint16_t id, const std::string& name, uint8_t suffix);

/** IPv4 addresses from a positive NetBIOS name query response with transaction `id` for `name`. */
bool ParseNetbiosNameResponse(const uint8_t* data, size_t size, uint16_t id, const std::string& name,
                              std::vector<std::string>& addresses);

} // namespace remotedesk::net
