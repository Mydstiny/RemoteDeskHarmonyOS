/**
 * rdp_certificate_policy.h - RDP certificate fingerprint formatting policy
 */

#pragma once

#include <cctype>
#include <string>

class RdpCertificatePolicy {
public:
    static std::string NormalizeFingerprint(const std::string& value) {
        std::string trimmed = trimAscii(value);
        const std::string shaPrefix = "sha256:";
        const std::string fingerprintPrefix = "fingerprint:";
        std::string lower = toLowerAscii(trimmed);
        if (lower.rfind(fingerprintPrefix, 0) == 0) {
            trimmed = trimmed.substr(fingerprintPrefix.size());
            lower = toLowerAscii(trimmed);
        }
        if (lower.rfind(shaPrefix, 0) == 0) {
            trimmed = trimmed.substr(shaPrefix.size());
        }

        std::string out;
        for (char ch : trimmed) {
            if (std::isxdigit(static_cast<unsigned char>(ch))) {
                out.push_back(static_cast<char>(
                    std::tolower(static_cast<unsigned char>(ch))));
            } else if (ch == ':' || ch == '-' || std::isspace(static_cast<unsigned char>(ch))) {
                continue;
            } else {
                return "";
            }
        }
        return out.size() == 64 ? out : "";
    }

    static bool FingerprintMatches(const std::string& expected, const std::string& actual) {
        const std::string lhs = NormalizeFingerprint(expected);
        const std::string rhs = NormalizeFingerprint(actual);
        return !lhs.empty() && lhs == rhs;
    }

    static std::string ToFreeRdpAcceptedFingerprint(const std::string& value) {
        const std::string normalized = NormalizeFingerprint(value);
        return normalized.empty() ? "" : "sha256:" + normalized;
    }

private:
    static std::string trimAscii(const std::string& value) {
        size_t begin = 0;
        while (begin < value.size() &&
               std::isspace(static_cast<unsigned char>(value[begin]))) {
            ++begin;
        }
        size_t end = value.size();
        while (end > begin &&
               std::isspace(static_cast<unsigned char>(value[end - 1]))) {
            --end;
        }
        return value.substr(begin, end - begin);
    }

    static std::string toLowerAscii(const std::string& value) {
        std::string out = value;
        for (char& ch : out) {
            ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
        }
        return out;
    }
};
