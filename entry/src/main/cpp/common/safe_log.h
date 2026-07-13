/**
 * safe_log.h - native helpers for log-safe identifiers.
 */

#pragma once

#include <string>

class SafeLog final {
public:
    SafeLog() = delete;

    static std::string MaskHost(const std::string& host);
    static std::string MaskUser(const std::string& user);
    static std::string MaskSecretLenOnly(const std::string& secret);
    static std::string HashForLog(const std::string& value);
};
