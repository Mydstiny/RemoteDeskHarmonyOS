#include "local_name_resolver.h"

#include <algorithm>
#include <arpa/inet.h>
#include <cctype>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <poll.h>
#include <random>
#include <sys/socket.h>
#include <unistd.h>

namespace remotedesk::net {
namespace {

constexpr uint16_t kTypeA = 1;
constexpr uint16_t kTypeAaaa = 28;
constexpr uint16_t kTypeNb = 0x0020;
constexpr uint16_t kClassIn = 1;
constexpr uint16_t kMdnsPort = 5353;
constexpr uint16_t kLlmnrPort = 5355;
constexpr uint16_t kNetbiosPort = 137;
constexpr auto kCollectAfterFirstAnswer = std::chrono::milliseconds(150);

std::string Lower(const std::string& value) {
    std::string out = value;
    std::transform(out.begin(), out.end(), out.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return out;
}

bool LabelIsValid(const std::string& label) {
    if (label.empty() || label.size() > 63 || label.front() == '-' || label.back() == '-') { return false; }
    return std::all_of(label.begin(), label.end(), [](unsigned char c) {
        return std::isalnum(c) != 0 || c == '-';
    });
}

void Put16(std::vector<uint8_t>& out, uint16_t value) {
    out.push_back(static_cast<uint8_t>(value >> 8));
    out.push_back(static_cast<uint8_t>(value & 0xff));
}

uint16_t Get16(const uint8_t* data) {
    return static_cast<uint16_t>((data[0] << 8) | data[1]);
}

/** Read a (possibly compressed) DNS name starting at `offset`; `next` is the offset after it in place. */
bool ReadName(const uint8_t* data, size_t size, size_t offset, std::string& name, size_t& next) {
    name.clear();
    size_t cursor = offset;
    bool jumped = false;
    int guard = 0;
    while (true) {
        if (cursor >= size || ++guard > 128) { return false; }
        const uint8_t length = data[cursor];
        if ((length & 0xc0) == 0xc0) {
            if (cursor + 1 >= size) { return false; }
            const size_t pointer = static_cast<size_t>(((length & 0x3f) << 8) | data[cursor + 1]);
            if (!jumped) { next = cursor + 2; }
            jumped = true;
            cursor = pointer;
            continue;
        }
        if ((length & 0xc0) != 0) { return false; }
        if (length == 0) {
            if (!jumped) { next = cursor + 1; }
            return true;
        }
        if (cursor + 1 + length > size) { return false; }
        if (!name.empty()) { name.push_back('.'); }
        name.append(reinterpret_cast<const char*>(data + cursor + 1), length);
        cursor += 1 + length;
    }
}

bool UsableIpv6(const in6_addr& address) {
    // fe80::/10 needs an interface scope; ::1 and :: are never the remote host.
    if (address.s6_addr[0] == 0xfe && (address.s6_addr[1] & 0xc0) == 0x80) { return false; }
    static const in6_addr any = IN6ADDR_ANY_INIT;
    static const in6_addr loopback = IN6ADDR_LOOPBACK_INIT;
    return std::memcmp(&address, &any, sizeof(address)) != 0 &&
        std::memcmp(&address, &loopback, sizeof(address)) != 0;
}

/** An IPv4 answer that can be a remote host: not 0/8, loopback, multicast, reserved or broadcast. */
bool UsableIpv4(const in_addr& address) {
    const uint32_t value = ntohl(address.s_addr);
    const uint32_t first = value >> 24;
    return first != 0 && first != 127 && first < 224 && value != 0xffffffffU;
}

void AddUnique(std::vector<std::string>& addresses, const std::string& address) {
    if (!address.empty() && std::find(addresses.begin(), addresses.end(), address) == addresses.end()) {
        addresses.push_back(address);
    }
}

int OpenUdp(bool broadcast, int multicastTtl) {
    const int fd = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0) { return -1; }
    const int fileFlags = ::fcntl(fd, F_GETFL, 0);
    if (fileFlags < 0 || ::fcntl(fd, F_SETFL, fileFlags | O_NONBLOCK) != 0 ||
        ::fcntl(fd, F_SETFD, FD_CLOEXEC) != 0) { ::close(fd); return -1; }
    sockaddr_in local {};
    local.sin_family = AF_INET;
    local.sin_addr.s_addr = htonl(INADDR_ANY);
    local.sin_port = 0;
    if (::bind(fd, reinterpret_cast<sockaddr*>(&local), sizeof(local)) != 0) { ::close(fd); return -1; }
    if (broadcast) {
        const int on = 1;
        ::setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, sizeof(on));
    }
    if (multicastTtl > 0) {
        const unsigned char ttl = static_cast<unsigned char>(multicastTtl);
        const unsigned char loop = 0;
        ::setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, sizeof(ttl));
        ::setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, sizeof(loop));
    }
    return fd;
}

void SendTo(int fd, const std::vector<uint8_t>& packet, in_addr_t address, uint16_t port) {
    if (fd < 0) { return; }
    sockaddr_in target {};
    target.sin_family = AF_INET;
    target.sin_addr.s_addr = address;
    target.sin_port = htons(port);
    (void)::sendto(fd, packet.data(), packet.size(), 0, reinterpret_cast<sockaddr*>(&target), sizeof(target));
}

/** Local addresses of the up, non-loopback, multicast-capable IPv4 interfaces. */
std::vector<in_addr> MulticastInterfaces() {
    std::vector<in_addr> out;
    ifaddrs* list = nullptr;
    if (::getifaddrs(&list) != 0 || list == nullptr) { return out; }
    for (ifaddrs* entry = list; entry != nullptr; entry = entry->ifa_next) {
        if (entry->ifa_addr == nullptr || entry->ifa_addr->sa_family != AF_INET) { continue; }
        if ((entry->ifa_flags & IFF_UP) == 0 || (entry->ifa_flags & IFF_LOOPBACK) != 0 ||
            (entry->ifa_flags & IFF_MULTICAST) == 0) { continue; }
        const in_addr address = reinterpret_cast<sockaddr_in*>(entry->ifa_addr)->sin_addr;
        const bool seen = std::any_of(out.begin(), out.end(),
            [&address](const in_addr& known) { return known.s_addr == address.s_addr; });
        if (!seen) { out.push_back(address); }
    }
    ::freeifaddrs(list);
    return out;
}

/**
 * Send a multicast query out of every IPv4 interface: with a VPN or a cellular
 * default route the system's own choice may have no multicast route at all.
 */
void SendMulticast(int fd, const std::vector<uint8_t>& packet, in_addr_t group, uint16_t port,
                   const std::vector<in_addr>& interfaces) {
    if (fd < 0) { return; }
    if (interfaces.empty()) { SendTo(fd, packet, group, port); return; }
    for (const in_addr& local : interfaces) {
        (void)::setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &local, sizeof(local));
        SendTo(fd, packet, group, port);
    }
}

/** Directed broadcast addresses of the up, non-loopback IPv4 interfaces (plus the limited broadcast). */
std::vector<in_addr_t> BroadcastAddresses() {
    std::vector<in_addr_t> out { htonl(INADDR_BROADCAST) };
    ifaddrs* list = nullptr;
    if (::getifaddrs(&list) != 0 || list == nullptr) { return out; }
    for (ifaddrs* entry = list; entry != nullptr; entry = entry->ifa_next) {
        if (entry->ifa_addr == nullptr || entry->ifa_addr->sa_family != AF_INET) { continue; }
        if ((entry->ifa_flags & IFF_UP) == 0 || (entry->ifa_flags & IFF_LOOPBACK) != 0 ||
            (entry->ifa_flags & IFF_BROADCAST) == 0 || entry->ifa_broadaddr == nullptr) { continue; }
        const in_addr_t address = reinterpret_cast<sockaddr_in*>(entry->ifa_broadaddr)->sin_addr.s_addr;
        if (std::find(out.begin(), out.end(), address) == out.end()) { out.push_back(address); }
    }
    ::freeifaddrs(list);
    return out;
}

uint16_t RandomId() {
    std::random_device device;
    return static_cast<uint16_t>(device() & 0xffff);
}

} // namespace

LocalNameKind ClassifyLocalName(const std::string& rawName) {
    std::string name = rawName;
    if (!name.empty() && name.back() == '.') { name.pop_back(); }
    if (name.empty() || name.size() > 253) { return LocalNameKind::None; }
    if (name.find('.') == std::string::npos) {
        return LabelIsValid(name) ? LocalNameKind::SingleLabel : LocalNameKind::None;
    }
    const std::string lower = Lower(name);
    const std::string suffix = ".local";
    if (lower.size() <= suffix.size() || lower.compare(lower.size() - suffix.size(), suffix.size(), suffix) != 0) {
        return LocalNameKind::None;
    }
    size_t start = 0;
    while (start <= name.size()) {
        const size_t dot = name.find('.', start);
        const std::string label = name.substr(start, dot == std::string::npos ? std::string::npos : dot - start);
        if (!LabelIsValid(label)) { return LocalNameKind::None; }
        if (dot == std::string::npos) { break; }
        start = dot + 1;
    }
    return LocalNameKind::MdnsLocal;
}

std::vector<uint8_t> BuildDnsQuery(uint16_t id, const std::string& name, uint16_t type, bool unicastResponse) {
    std::vector<uint8_t> out;
    Put16(out, id);
    Put16(out, 0);  // standard query, no recursion
    Put16(out, 1);  // one question
    Put16(out, 0);
    Put16(out, 0);
    Put16(out, 0);
    size_t start = 0;
    while (start < name.size()) {
        size_t dot = name.find('.', start);
        if (dot == std::string::npos) { dot = name.size(); }
        const size_t length = std::min<size_t>(dot - start, 63);
        out.push_back(static_cast<uint8_t>(length));
        out.insert(out.end(), name.begin() + static_cast<std::ptrdiff_t>(start),
                   name.begin() + static_cast<std::ptrdiff_t>(start + length));
        start = dot + 1;
    }
    out.push_back(0);
    Put16(out, type);
    Put16(out, static_cast<uint16_t>(kClassIn | (unicastResponse ? 0x8000 : 0)));
    return out;
}

bool ParseDnsAnswers(const uint8_t* data, size_t size, uint16_t id, bool anyId, const std::string& name,
                     std::vector<std::string>& addresses) {
    if (data == nullptr || size < 12) { return false; }
    if (!anyId && Get16(data) != id) { return false; }
    const uint16_t flags = Get16(data + 2);
    if ((flags & 0x8000) == 0 || (flags & 0x000f) != 0) { return false; }  // a response without error
    const uint16_t questions = Get16(data + 4);
    const uint32_t records = static_cast<uint32_t>(Get16(data + 6)) + Get16(data + 8) + Get16(data + 10);
    size_t cursor = 12;
    std::string field;
    for (uint16_t index = 0; index < questions; ++index) {
        size_t next = 0;
        if (!ReadName(data, size, cursor, field, next) || next + 4 > size) { return false; }
        cursor = next + 4;
    }
    const std::string wanted = Lower(name);
    bool found = false;
    for (uint32_t index = 0; index < records; ++index) {
        size_t next = 0;
        if (!ReadName(data, size, cursor, field, next) || next + 10 > size) { break; }
        const uint16_t type = Get16(data + next);
        const uint16_t recordClass = static_cast<uint16_t>(Get16(data + next + 2) & 0x7fff);
        const uint16_t length = Get16(data + next + 8);
        const size_t rdata = next + 10;
        if (rdata + length > size) { break; }
        if (recordClass == kClassIn && Lower(field) == wanted) {
            char text[INET6_ADDRSTRLEN] = {};
            if (type == kTypeA && length == 4) {
                in_addr address {};
                std::memcpy(&address, data + rdata, 4);
                if (UsableIpv4(address) && ::inet_ntop(AF_INET, &address, text, sizeof(text)) != nullptr) {
                    AddUnique(addresses, text);
                    found = true;
                }
            } else if (type == kTypeAaaa && length == 16) {
                in6_addr address {};
                std::memcpy(&address, data + rdata, 16);
                if (UsableIpv6(address) && ::inet_ntop(AF_INET6, &address, text, sizeof(text)) != nullptr) {
                    AddUnique(addresses, text);
                    found = true;
                }
            }
        }
        cursor = rdata + length;
    }
    return found;
}

std::string EncodeNetbiosName(const std::string& name, uint8_t suffix) {
    std::string padded = name.substr(0, 15);
    std::transform(padded.begin(), padded.end(), padded.begin(),
                   [](unsigned char c) { return static_cast<char>(std::toupper(c)); });
    padded.resize(15, ' ');
    padded.push_back(static_cast<char>(suffix));
    std::string encoded;
    encoded.reserve(32);
    for (unsigned char c : padded) {
        encoded.push_back(static_cast<char>('A' + (c >> 4)));
        encoded.push_back(static_cast<char>('A' + (c & 0x0f)));
    }
    return encoded;
}

std::vector<uint8_t> BuildNetbiosNameQuery(uint16_t id, const std::string& name, uint8_t suffix) {
    std::vector<uint8_t> out;
    Put16(out, id);
    Put16(out, 0x0110);  // query, recursion desired, broadcast
    Put16(out, 1);
    Put16(out, 0);
    Put16(out, 0);
    Put16(out, 0);
    const std::string encoded = EncodeNetbiosName(name, suffix);
    out.push_back(32);
    out.insert(out.end(), encoded.begin(), encoded.end());
    out.push_back(0);
    Put16(out, kTypeNb);
    Put16(out, kClassIn);
    return out;
}

bool ParseNetbiosNameResponse(const uint8_t* data, size_t size, uint16_t id, const std::string& name,
                              std::vector<std::string>& addresses) {
    if (data == nullptr || size < 12 || Get16(data) != id) { return false; }
    // The answer must be for the name asked, with any suffix byte.
    const std::string expected = EncodeNetbiosName(name, 0).substr(0, 30);
    const uint16_t flags = Get16(data + 2);
    if ((flags & 0x8000) == 0 || (flags & 0x000f) != 0) { return false; }
    const uint16_t answers = Get16(data + 6);
    size_t cursor = 12;
    std::string field;
    for (uint16_t index = 0; index < Get16(data + 4); ++index) {
        size_t next = 0;
        if (!ReadName(data, size, cursor, field, next) || next + 4 > size) { return false; }
        cursor = next + 4;
    }
    bool found = false;
    for (uint16_t index = 0; index < answers; ++index) {
        size_t next = 0;
        if (!ReadName(data, size, cursor, field, next) || next + 10 > size) { break; }
        const uint16_t type = Get16(data + next);
        const uint16_t length = Get16(data + next + 8);
        const size_t rdata = next + 10;
        if (rdata + length > size) { break; }
        const bool sameName = field.size() == 32 && field.compare(0, 30, expected) == 0;
        if (type == kTypeNb && sameName) {
            for (size_t entry = 0; entry + 6 <= length; entry += 6) {
                in_addr address {};
                std::memcpy(&address, data + rdata + entry + 2, 4);
                char text[INET_ADDRSTRLEN] = {};
                if (UsableIpv4(address) && ::inet_ntop(AF_INET, &address, text, sizeof(text)) != nullptr) {
                    AddUnique(addresses, text);
                    found = true;
                }
            }
        }
        cursor = rdata + length;
    }
    return found;
}

LocalNameResolution ResolveLocalHostName(const std::string& rawName, std::chrono::milliseconds timeout,
                                         const std::function<bool()>& cancelled) {
    LocalNameResolution result;
    std::string name = rawName;
    if (!name.empty() && name.back() == '.') { name.pop_back(); }
    const LocalNameKind kind = ClassifyLocalName(name);
    if (kind == LocalNameKind::None) { return result; }
    const std::string label = kind == LocalNameKind::SingleLabel ? name : std::string();
    const std::string mdnsName = kind == LocalNameKind::SingleLabel ? name + ".local" : name;

    const int mdns = OpenUdp(false, 255);
    const int llmnr = label.empty() ? -1 : OpenUdp(false, 1);
    const int netbios = label.empty() || label.size() > 15 ? -1 : OpenUdp(true, 0);
    const uint16_t mdnsId = RandomId();
    const uint16_t llmnrIdA = RandomId();
    const uint16_t llmnrIdAaaa = static_cast<uint16_t>(llmnrIdA + 1);
    const uint16_t netbiosId20 = RandomId();
    const uint16_t netbiosId00 = static_cast<uint16_t>(netbiosId20 + 1);

    const in_addr_t mdnsGroup = inet_addr("224.0.0.251");
    const in_addr_t llmnrGroup = inet_addr("224.0.0.252");
    const std::vector<in_addr> interfaces = MulticastInterfaces();
    SendMulticast(mdns, BuildDnsQuery(mdnsId, mdnsName, kTypeA, true), mdnsGroup, kMdnsPort, interfaces);
    SendMulticast(mdns, BuildDnsQuery(mdnsId, mdnsName, kTypeAaaa, true), mdnsGroup, kMdnsPort, interfaces);
    if (llmnr >= 0) {
        SendMulticast(llmnr, BuildDnsQuery(llmnrIdA, label, kTypeA, false), llmnrGroup, kLlmnrPort, interfaces);
        SendMulticast(llmnr, BuildDnsQuery(llmnrIdAaaa, label, kTypeAaaa, false), llmnrGroup, kLlmnrPort,
                      interfaces);
    }
    if (netbios >= 0) {
        for (const in_addr_t broadcast : BroadcastAddresses()) {
            SendTo(netbios, BuildNetbiosNameQuery(netbiosId20, label, 0x20), broadcast, kNetbiosPort);
            SendTo(netbios, BuildNetbiosNameQuery(netbiosId00, label, 0x00), broadcast, kNetbiosPort);
        }
    }

    auto deadline = std::chrono::steady_clock::now() + timeout;
    bool answered = false;
    uint8_t buffer[1500];
    while (true) {
        if (cancelled && cancelled()) { break; }
        const auto now = std::chrono::steady_clock::now();
        if (now >= deadline) { break; }
        pollfd fds[3] = { { mdns, POLLIN, 0 }, { llmnr, POLLIN, 0 }, { netbios, POLLIN, 0 } };
        const int wait = static_cast<int>(std::min<long long>(
            50, std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count() + 1));
        const int ready = ::poll(fds, 3, wait);
        if (ready < 0 && errno != EINTR) { break; }
        if (ready <= 0) { continue; }
        for (size_t index = 0; index < 3; ++index) {
            if (fds[index].fd < 0 || (fds[index].revents & POLLIN) == 0) { continue; }
            while (true) {
                const ssize_t received = ::recv(fds[index].fd, buffer, sizeof(buffer), 0);
                if (received <= 0) { break; }
                const size_t length = static_cast<size_t>(received);
                bool got = false;
                if (index == 0) {
                    // One-shot mDNS replies echo the ID; some responders send 0.
                    got = ParseDnsAnswers(buffer, length, mdnsId, true, mdnsName, result.addresses);
                    if (got && result.method.empty()) { result.method = "mdns"; }
                } else if (index == 1) {
                    got = ParseDnsAnswers(buffer, length, llmnrIdA, false, label, result.addresses) ||
                        ParseDnsAnswers(buffer, length, llmnrIdAaaa, false, label, result.addresses);
                    if (got && result.method.empty()) { result.method = "llmnr"; }
                } else {
                    got = ParseNetbiosNameResponse(buffer, length, netbiosId20, label, result.addresses) ||
                        ParseNetbiosNameResponse(buffer, length, netbiosId00, label, result.addresses);
                    if (got && result.method.empty()) { result.method = "netbios"; }
                }
                if (got && !answered) {
                    answered = true;
                    deadline = std::min(deadline, std::chrono::steady_clock::now() + kCollectAfterFirstAnswer);
                }
            }
        }
    }
    for (const int fd : { mdns, llmnr, netbios }) {
        if (fd >= 0) { ::close(fd); }
    }
    return result;
}

} // namespace remotedesk::net
