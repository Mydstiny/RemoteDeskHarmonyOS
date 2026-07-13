/**
 * safe_log.cpp - native helpers for log-safe identifiers.
 */

#include "common/safe_log.h"

#include <cctype>
#include <cstdint>
#include <iomanip>
#include <sstream>
#include <string>
#include <vector>

namespace {

std::vector<std::string> Split(const std::string& value, char delimiter)
{
    std::vector<std::string> parts;
    std::string current;
    for (char ch : value) {
        if (ch == delimiter) {
            parts.push_back(current);
            current.clear();
        } else {
            current.push_back(ch);
        }
    }
    parts.push_back(current);
    return parts;
}

bool IsDigitsOnly(const std::string& value)
{
    if (value.empty()) {
        return false;
    }
    for (unsigned char ch : value) {
        if (!std::isdigit(ch)) {
            return false;
        }
    }
    return true;
}

bool LooksLikeIpv4(const std::vector<std::string>& parts)
{
    if (parts.size() != 4) {
        return false;
    }
    for (const std::string& part : parts) {
        if (!IsDigitsOnly(part) || part.size() > 3) {
            return false;
        }
    }
    return true;
}

std::string MaskToken(const std::string& value)
{
    if (value.empty()) {
        return "<empty>";
    }
    if (value.size() <= 2) {
        return std::string(1, value.front()) + "*";
    }
    return std::string(1, value.front()) + "***" + value.back();
}

} // namespace

std::string SafeLog::MaskHost(const std::string& host)
{
    if (host.empty()) {
        return "<empty>";
    }

    const std::vector<std::string> parts = Split(host, '.');
    if (LooksLikeIpv4(parts)) {
        return parts[0] + "." + parts[1] + ".*." + parts[3];
    }
    if (parts.size() >= 2) {
        return parts.front() + "..." + parts.back();
    }
    return MaskToken(host);
}

std::string SafeLog::MaskUser(const std::string& user)
{
    if (user.empty()) {
        return "<empty>";
    }

    const std::size_t slash = user.find('\\');
    if (slash != std::string::npos) {
        return MaskToken(user.substr(0, slash)) + "\\" + MaskToken(user.substr(slash + 1));
    }

    const std::size_t at = user.find('@');
    if (at != std::string::npos) {
        const std::string local = user.substr(0, at);
        const std::string domain = user.substr(at + 1);
        const std::vector<std::string> domainParts = Split(domain, '.');
        if (domainParts.size() >= 2) {
            std::string maskedDomain = MaskToken(domainParts.front());
            for (std::size_t i = 1; i < domainParts.size(); ++i) {
                maskedDomain += "." + domainParts[i];
            }
            return MaskToken(local) + "@" + maskedDomain;
        }
        return MaskToken(local) + "@" + MaskToken(domain);
    }

    return MaskToken(user);
}

std::string SafeLog::MaskSecretLenOnly(const std::string& secret)
{
    if (secret.empty()) {
        return "<empty>";
    }
    return "<secret:" + std::to_string(secret.size()) + ">";
}

std::string SafeLog::HashForLog(const std::string& value)
{
    uint64_t hash = 1469598103934665603ULL;
    for (unsigned char ch : value) {
        hash ^= ch;
        hash *= 1099511628211ULL;
    }

    std::ostringstream out;
    out << std::hex << std::nouppercase << std::setw(8) << std::setfill('0')
        << static_cast<uint32_t>(hash & 0xffffffffU);
    return out.str();
}
