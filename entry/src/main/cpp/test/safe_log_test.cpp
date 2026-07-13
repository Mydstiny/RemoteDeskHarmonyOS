/**
 * safe_log_test.cpp - native log redaction helpers
 */

#include "common/safe_log.h"
#include "test_runner.h"

RDP_TEST_CASE(safe_log_masks_host_without_full_address) {
    RDP_ASSERT(SafeLog::MaskHost("192.168.31.177") == "192.168.*.177");
    RDP_ASSERT(SafeLog::MaskHost("rdp.office.example.com") == "rdp...com");
    RDP_ASSERT(SafeLog::MaskHost("pc") == "p*");
}

RDP_TEST_CASE(safe_log_masks_user_without_full_identity) {
    RDP_ASSERT(SafeLog::MaskUser("alice@example.com") == "a***e@e***e.com");
    RDP_ASSERT(SafeLog::MaskUser("DOMAIN\\administrator") == "D***N\\a***r");
    RDP_ASSERT(SafeLog::MaskUser("li") == "l*");
}

RDP_TEST_CASE(safe_log_masks_secret_by_length_only) {
    RDP_ASSERT(SafeLog::MaskSecretLenOnly("") == "<empty>");
    RDP_ASSERT(SafeLog::MaskSecretLenOnly("abc") == "<secret:3>");
    RDP_ASSERT(SafeLog::MaskSecretLenOnly("super-long-password") == "<secret:19>");
}

RDP_TEST_CASE(safe_log_hash_is_stable_without_revealing_value) {
    const std::string first = SafeLog::HashForLog("rdp.office.example.com");
    const std::string second = SafeLog::HashForLog("rdp.office.example.com");
    RDP_ASSERT(first == second);
    RDP_ASSERT(first != "rdp.office.example.com");
    RDP_ASSERT(first.size() == 8);
}
